codeunit 50000 "Customer List Ext. Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryVariableStorage: Codeunit "Library - Variable Storage";
        IsInitialized: Boolean;

    [Test]
    procedure TestCustomerListPageOpens()
    var
        CustomerListPage: TestPage "Customer List";
    begin
        // [GIVEN] The Business Central environment is set up
        Initialize();

        // [WHEN] The Customer List page is opened
        CustomerListPage.OpenView();

        // [THEN] The page opens successfully
        CustomerListPage.Close();
    end;

    [Test]
    procedure TestCreditLimitFieldVisible()
    var
        CustomerListPage: TestPage "Customer List";
    begin
        // [GIVEN] The Business Central environment is set up
        Initialize();

        // [WHEN] The Customer List page is opened
        CustomerListPage.OpenView();

        // [THEN] The Credit Limit (LCY) field is visible on the page
        Assert.IsTrue(CustomerListPage."Credit Limit (LCY)".Visible(), 'Credit Limit (LCY) field should be visible on Customer List page.');

        CustomerListPage.Close();
    end;

    local procedure Initialize()
    begin
        LibraryVariableStorage.Clear();
        if IsInitialized then
            exit;
        IsInitialized := true;
        Commit();
    end;

    var
        Assert: Codeunit Assert;
}
