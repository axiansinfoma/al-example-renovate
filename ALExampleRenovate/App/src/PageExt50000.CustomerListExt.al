pageextension 50000 "Customer List Ext." extends "Customer List"
{
    layout
    {
        addafter(Name)
        {
            field("Credit Limit (LCY)"; Rec."Credit Limit (LCY)")
            {
                ApplicationArea = All;
                ToolTip = 'Specifies the maximum amount you allow the customer to exceed the payment balance before warnings are issued.';
            }
        }
    }
}
