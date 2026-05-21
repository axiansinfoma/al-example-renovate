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

Business Central `app.json` files store all dependency versions in a mandatory 4-part format: `major.minor.build.revision` (e.g. `25.0.0.0`). NuGet normalizes trailing-zero revisions on the feed, so `27.0.0.0` is published as `27.0.0` (3-part). When Renovate fetches the latest version and writes it back to `app.json`, it writes the NuGet-normalized form — which the BC compiler rejects.

### The fix: `postUpgradeTasks`

`renovate.json` includes a `postUpgradeTasks` command that runs after each update and normalizes any 3-part version back to 4-part:

```bash
sed -i -E 's/("(version|application|platform)": ")([0-9]+\.[0-9]+\.[0-9]+)"/\1\3.0"/g'
```

This only appends `.0` when the version ends immediately after the third segment (3-part). Versions with a non-zero revision (e.g. `26.0.0.1` → `26.0.0.2`) are left unchanged.

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

All managers use `versioningTemplate: "nuget"`. The `nuget` versioning scheme treats trailing-zero revisions as equivalent (e.g. `27.0.0` = `27.0.0.0`), preventing false "update available" noise when the installed version is already current.

### NuGet Feeds

- **MSSymbolsV2**: `https://pkgs.dev.azure.com/dynamicssmb2/DynamicsBCPublicFeeds/_packaging/MSSymbolsV2/nuget/v3/index.json`
- **AppSourceSymbols**: `https://pkgs.dev.azure.com/dynamicssmb2/DynamicsBCPublicFeeds/_packaging/AppSourceSymbols/nuget/v3/index.json`

### Package Rules

- All AL deps are grouped into a single PR: **Business Central AL dependencies**
- `Microsoft.Application.symbols` and `Microsoft.Platform.symbols` are additionally grouped as **Business Central core symbols**
- Dependencies where `publisher` is not `Microsoft` and the package is not published on AppSourceSymbols (e.g. intra-repo dependencies) should be explicitly disabled via a `packageRule` with `matchDepNames`

### Design Decisions

- **Application/Platform in `dependencies` array**: Some `app.json` files list `Application` or `Platform` explicitly in their `dependencies` array. These are handled by the Application/Platform managers (not the generic Microsoft deps manager) to avoid GUID-suffixed package names that don't exist on the feed.
- **`$append()` pattern**: Each of the Application and Platform managers uses JSONata's `$append()` to cover both the top-level field and any matching entry in the `dependencies` array in a single manager.
- **`nuget` versioning**: BC uses 4-part versions (`major.minor.build.revision`). Renovate's `nuget` versioning scheme handles trailing-zero normalization correctly (unlike `loose`).
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

[`.github/workflows/Renovate.yaml`](.github/workflows/Renovate.yaml) runs daily at 04:00 UTC and can be triggered manually from the Actions tab:

```yaml
env:
  RENOVATE_REPOSITORIES: ${{ github.repository }}
  RENOVATE_ALLOWED_POST_UPGRADE_COMMANDS: '["^sed\\s+-i"]'
```

`RENOVATE_REPOSITORIES` tells Renovate which repo to process. `RENOVATE_ALLOWED_POST_UPGRADE_COMMANDS` whitelists the `sed` normalization command from `postUpgradeTasks`.

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
```

## Renovate Configuration

[`renovate.json`](renovate.json) uses four JSONata custom managers to extract AL dependencies from `app.json` files and map them to NuGet packages on Microsoft's public Azure Artifact feeds.

### Custom Managers

| Manager | Source field | NuGet package | Feed |
|---|---|---|---|
| Application | `application` + `dependencies[name='Application']` | `Microsoft.Application.symbols` | MSSymbolsV2 |
| Platform | `platform` + `dependencies[name='Platform']` | `Microsoft.Platform.symbols` | MSSymbolsV2 |
| Microsoft deps | `dependencies[publisher='Microsoft']` (excl. Application/Platform) | `Microsoft.<Name>.symbols.<id>` | MSSymbolsV2 |
| AppSource deps | `dependencies[publisher!='Microsoft']` | `<Publisher>.<Name>.symbols.<id>` | AppSourceSymbols |

All managers use the `nuget` datasource with `loose` versioning to support BC's 4-part version format (e.g. `25.0.0.0`).

### NuGet Feeds

- **MSSymbolsV2**: `https://pkgs.dev.azure.com/dynamicssmb2/DynamicsBCPublicFeeds/_packaging/MSSymbolsV2/nuget/v3/index.json`
- **AppSourceSymbols**: `https://pkgs.dev.azure.com/dynamicssmb2/DynamicsBCPublicFeeds/_packaging/AppSourceSymbols/nuget/v3/index.json`

### Package Rules

- All AL deps are grouped into a single PR: **Business Central AL dependencies**
- `Microsoft.Application.symbols` and `Microsoft.Platform.symbols` are additionally grouped as **Business Central core symbols**
- Dependencies where `publisher` is not `Microsoft` and the package is not published on AppSourceSymbols (e.g. intra-repo dependencies) should be explicitly disabled via a `packageRule` with `matchDepNames`

### Design Decisions

- **Application/Platform in `dependencies` array**: Some `app.json` files list `Application` or `Platform` explicitly in their `dependencies` array. These are handled by the Application/Platform managers (not the generic Microsoft deps manager) to avoid GUID-suffixed package names that don't exist on the feed.
- **`$append()` pattern**: Each of the Application and Platform managers uses JSONata's `$append()` to cover both the top-level field and any matching entry in the `dependencies` array in a single manager.
- **Loose versioning**: BC uses 4-part versions (`major.minor.build.revision`). Renovate's `loose` versioning scheme handles these correctly.
- **`runtime` field**: Automating `runtime` updates is non-trivial as it requires a mapping from `application` version to runtime version. Not currently implemented.

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
  "versioningTemplate": "loose"
}
```

Also remove that publisher from the catch-all `dependencies[publisher!='Microsoft']` manager (or it will be picked up twice), and remove any `enabled: false` packageRule that would suppress it.

### 2. Configure authentication in the global Renovate config

Credentials must **not** go in the repository's `renovate.json` — they belong in the self-hosted Renovate global config (e.g. `config.js` or the `RENOVATE_CONFIG_FILE`). Azure Artifacts feeds use HTTP Basic auth with a Personal Access Token (PAT) that has the **Packaging (Read)** scope:

```json
{
  "hostRules": [
    {
      "matchHost": "pkgs.dev.azure.com/<org>/",
      "username": "renovate",
      "password": "YOUR_AZURE_DEVOPS_PAT"
    }
  ]
}
```

In a GitHub Actions self-hosted Renovate workflow, pass the PAT as an environment variable and reference it:

```yaml
env:
  RENOVATE_CONFIG_FILE: global-config.json
  AZURE_DEVOPS_PAT: ${{ secrets.AZURE_DEVOPS_PAT }}
```

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
