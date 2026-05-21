# AL Example Renovate

An example Business Central Per Tenant Extension (PTE) demonstrating how to use [Renovate](https://docs.renovatebot.com/) to automate dependency updates in AL `app.json` files.

Based on the [AL-Go for GitHub](https://aka.ms/AL-Go) template.

## Repository Structure

```
ALExampleRenovate/
  App/
    app.json        # Main extension manifest
    src/            # AL source files
  Test/
    app.json        # Test extension manifest
    src/            # AL test source files
renovate.json       # Renovate configuration
.github/workflows/
  Renovate.yaml     # Self-hosted Renovate workflow
```

## How It Works

### The BC version format problem

Business Central `app.json` files store all dependency versions in a mandatory 4-part format: `major.minor.build.revision` (e.g. `25.0.0.0`). Two issues arise when using Renovate's built-in `nuget` versioner with BC versions:

1. **NuGet range treatment**: The `nuget` versioner treats a bare version like `25.0.0.0` as a minimum-version range (`>=25.0.0.0`). It resolves `currentVersion` to the latest version satisfying that range — which is always the latest version overall. Since `currentVersion == latestVersion`, Renovate sees no update available and creates no PR.

2. **3-part write-back**: NuGet normalizes trailing-zero revisions on the feed, so `28.0.0.0` may be published as `28.0.0` (3-part). When Renovate writes this back to `app.json`, the BC compiler rejects it because it expects 4-part versions.

### The fix: regex versioner + `postUpgradeTasks`

**Problem 1** is solved by overriding the `nuget` versioner with a regex versioner in `packageRules`:

```
regex:^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(\.(?<build>\d+))?$
```

This treats each version as an exact value (no range expansion), accepts both 3-part and 4-part BC versions, and correctly detects when a newer version is available.

**Problem 2** is solved by a `postUpgradeTasks` command in `renovate.json` that runs after each update and normalizes any 3-part version back to 4-part:

```bash
sed -i -E 's/("(version|application|platform)": ")([0-9]+\.[0-9]+\.[0-9]+)"/\1\3.0"/g'
```

This only appends `.0` when the version string ends immediately after the third segment. Versions that already have a non-zero fourth part (e.g. `26.0.0.1`) are left unchanged.

`postUpgradeTasks` requires `allowedPostUpgradeCommands` at the global config level, so **this only works with self-hosted Renovate** — it cannot be used with the Mend-hosted GitHub App.

## Renovate Configuration

[`renovate.json`](renovate.json) uses four JSONata custom managers to extract AL dependencies from `app.json` files and map them to NuGet packages on Microsoft's public Azure Artifact feeds.

### Custom Managers

| Manager | Source field | NuGet package | Feed |
|---|---|---|---|
| Application | `application` + `dependencies[name='Application']` | `Microsoft.Application.symbols` | MSSymbolsV2 |
| Platform | `platform` + `dependencies[name='Platform']` | `Microsoft.Platform.symbols` | MSSymbolsV2 |
| Microsoft deps | `dependencies[publisher='Microsoft']` (excl. Application/Platform) | `Microsoft.<Name>.symbols.<id>` | MSSymbolsV2 |
| AppSource deps | `dependencies[publisher!='Microsoft']` | `<Publisher>.<Name>.symbols.<id>` | AppSourceSymbols |

All managers set `versioningTemplate: "nuget"` as a baseline, but this is overridden for all packages by a `packageRule` that applies the regex versioner (see [Package Rules](#package-rules) below).

### NuGet Feeds

- **MSSymbolsV2**: `https://pkgs.dev.azure.com/dynamicssmb2/DynamicsBCPublicFeeds/_packaging/MSSymbolsV2/nuget/v3/index.json`
- **AppSourceSymbols**: `https://pkgs.dev.azure.com/dynamicssmb2/DynamicsBCPublicFeeds/_packaging/AppSourceSymbols/nuget/v3/index.json`

### Package Rules

- A broad rule applies `versioning: "regex:^(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)(\\.(?<build>\\d+))?$"` to **all** `custom.jsonata` packages. This overrides the `nuget` versioner and prevents the range-expansion issue.
- All Microsoft packages (matching `/^Microsoft\./`) are grouped into a single PR: **Business Central Microsoft dependencies**
- Dependencies that are not published on any of the configured feeds (e.g. intra-repo self-dependencies) should be explicitly disabled via a `packageRule` with `matchDepNames` and `enabled: false`

### Design Decisions

- **Application/Platform in `dependencies` array**: Some `app.json` files list `Application` or `Platform` explicitly in their `dependencies` array. These are handled by the Application/Platform managers (not the generic Microsoft deps manager) to avoid GUID-suffixed package names that don't exist on the feed.
- **`$append()` pattern**: Each of the Application and Platform managers uses JSONata's `$append()` to cover both the top-level field and any matching entry in the `dependencies` array in a single manager.
- **Regex versioner over nuget**: The `nuget` versioner's range treatment makes it unsuitable for BC's bare-version style. The regex versioner treats each version string as an exact comparable value with no range semantics.
- **`runtime` field**: Automating `runtime` updates is non-trivial as it requires a mapping from `application` version to runtime version. Not currently implemented.

## Self-Hosted Renovate Setup

This repository uses a self-hosted Renovate workflow ([`.github/workflows/Renovate.yaml`](.github/workflows/Renovate.yaml)) instead of the Mend-hosted GitHub App. Self-hosting is required to use `postUpgradeTasks`.

### 1. Create a fine-grained PAT

Go to **GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens** and create a new token with:

- **Resource owner**: the org/user that owns the repository
- **Repository access**: only this repository (or all repositories if you share it across repos)
- **Repository permissions**:

  | Permission | Level |
  |---|---|
  | Contents | Read and write |
  | Issues | Read and write |
  | Pull requests | Read and write |
  | Workflows | Read and write |
  | Metadata | Read (mandatory, auto-granted) |

> **Why not `GITHUB_TOKEN`?** PRs opened with the built-in `GITHUB_TOKEN` do not trigger `pull_request` workflows. This means CI (the Pull Request Build workflow) would never run on Renovate PRs, defeating the purpose of automated validation.

> **365-day expiry on enterprise?** Enterprise admins can remove the expiry limit at **Enterprise → Settings → Policies → Personal access tokens → Maximum lifetime for fine-grained tokens**.

### 2. Add the PAT as a repository secret

Go to **Repository → Settings → Secrets and variables → Actions** and add a new secret:

- **Name**: `RENOVATE_TOKEN`
- **Value**: the PAT from step 1

### 3. The workflow

[`.github/workflows/Renovate.yaml`](.github/workflows/Renovate.yaml) runs daily at 04:00 UTC and can be triggered manually from the Actions tab. The manual trigger includes a **Log level** dropdown (default: `info`, option: `debug`) for troubleshooting:

```yaml
env:
  RENOVATE_REPOSITORIES: ${{ github.repository }}
  RENOVATE_ALLOWED_POST_UPGRADE_COMMANDS: '["^sed\\s+-i"]'
  LOG_LEVEL: ${{ inputs.log_level || 'info' }}
```

`RENOVATE_REPOSITORIES` tells Renovate which repo to process. `RENOVATE_ALLOWED_POST_UPGRADE_COMMANDS` whitelists the `sed` normalization command from `postUpgradeTasks`. `LOG_LEVEL` enables debug output when selected in the manual trigger.

## Running a Local Dry Run

Renovate can be tested locally without pushing. The key gotcha when running in a GitHub Codespace is that the `CODESPACES` environment variable causes Renovate to prompt for a repository name interactively, which then fails with `platform=local`. Unset it:

```bash
cat > /tmp/renovate-global.json << 'EOF'
{
  "platform": "local",
  "dryRun": "full"
}
EOF

LOG_LEVEL=debug env -u CODESPACES RENOVATE_CONFIG_FILE=/tmp/renovate-global.json npx renovate
```

## Adding a Private NuGet Feed

If your dependencies include apps published to a private Azure Artifacts feed (e.g. your own organisation's BC apps, not on AppSourceSymbols), you need two things:

### 1. Add a custom manager in `renovate.json`

Add a new entry to `customManagers` targeting your private publishers and pointing at your private feed:

```json
{
  "customType": "jsonata",
  "fileFormat": "json",
  "managerFilePatterns": ["**/app.json"],
  "matchStrings": [
    "dependencies[publisher='My Company'].{\"depName\": publisher & '/' & name, \"packageName\": publisher & '.' & $replace(name, /\\s+/, '') & '.symbols.' & id, \"currentValue\": version}"
  ],
  "datasourceTemplate": "nuget",
  "registryUrlTemplate": "https://pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/nuget/v3/index.json",
  "versioningTemplate": "nuget"
}
```

Also remove that publisher from the catch-all `dependencies[publisher!='Microsoft']` manager (or it will be picked up twice), and remove any `enabled: false` packageRule that would suppress it.

### 2. Configure authentication in the global Renovate config

Credentials must **not** go in the repository's `renovate.json` — they belong in the self-hosted Renovate global config. Azure Artifacts feeds use HTTP Basic auth with a PAT that has the **Packaging (Read)** scope. Pass it as an environment variable in the workflow and reference it via `hostRules`:

```yaml
# .github/workflows/Renovate.yaml
env:
  RENOVATE_REPOSITORIES: ${{ github.repository }}
  RENOVATE_ALLOWED_POST_UPGRADE_COMMANDS: '["^sed\\s+-i"]'
  RENOVATE_HOST_RULES: '[{"matchHost":"pkgs.dev.azure.com/<org>/","username":"renovate","password":"${{ secrets.AZURE_DEVOPS_PAT }}"}]'
```

> **Note**: The public Microsoft feeds (MSSymbolsV2, AppSourceSymbols) used by this repository do not require authentication.

## Contributing

Please read [this](https://github.com/microsoft/AL-Go/blob/main/Scenarios/Contribute.md) description on how to contribute to AL-Go for GitHub.

```js
// global-config.js
module.exports = {
  hostRules: [
    {
      matchHost: "pkgs.dev.azure.com/<org>/",
      username: "renovate",
      password: process.env.AZURE_DEVOPS_PAT,
    },
  ],
};
```

**Azure Pipelines**: If you run Renovate as an Azure Pipelines job, you can use the pipeline's built-in `System.AccessToken` instead of a separate PAT. Enable it on the job and pass it through:

```yaml
# azure-pipelines.yml
jobs:
  - job: Renovate
    pool:
      vmImage: ubuntu-latest
    steps:
      - script: npx renovate
        env:
          RENOVATE_CONFIG_FILE: global-config.js
          AZURE_DEVOPS_TOKEN: $(System.AccessToken)
```

```js
// global-config.js
module.exports = {
  hostRules: [
    {
      matchHost: "pkgs.dev.azure.com/<org>/",
      username: "renovate",
      password: process.env.AZURE_DEVOPS_TOKEN,
    },
  ],
};
```

The `System.AccessToken` has access to all feeds within the same Azure DevOps organization without any additional scopes. For feeds in a different organization a PAT is still required.

> **Note**: The public Microsoft feeds (MSSymbolsV2, AppSourceSymbols) used by this repository do not require authentication.

## Notes
- The `runtime` field cannot be automated without a custom datasource mapping BC application versions to runtime versions.

## Contributing

Please read [this](https://github.com/microsoft/AL-Go/blob/main/Scenarios/Contribute.md) description on how to contribute to AL-Go for GitHub.
