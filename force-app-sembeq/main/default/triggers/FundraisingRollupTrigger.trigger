trigger FundraisingRollupTrigger on Gift_Transaction__c (
    after insert, after update, after delete, after undelete
) {
    Set<Id> contactIds     = new Set<Id>();
    Set<Id> designationIds = new Set<Id>();
    Set<Id> commitmentIds  = new Set<Id>();

    List<Gift_Transaction__c> records = Trigger.isDelete ? Trigger.old : Trigger.new;

    for (Gift_Transaction__c g : records) {
        if (g.Donor__c != null)             contactIds.add(g.Donor__c);
        if (g.Gift_Designation__c != null)  designationIds.add(g.Gift_Designation__c);
        if (g.Recurring_Gift__c != null)    commitmentIds.add(g.Recurring_Gift__c);
    }

    // On update, also recalculate old parents in case lookup fields changed
    if (Trigger.isUpdate) {
        for (Gift_Transaction__c g : Trigger.old) {
            if (g.Donor__c != null)             contactIds.add(g.Donor__c);
            if (g.Gift_Designation__c != null)  designationIds.add(g.Gift_Designation__c);
            if (g.Recurring_Gift__c != null)    commitmentIds.add(g.Recurring_Gift__c);
        }
    }

    FundraisingRollupService.recalculateByParents(contactIds, designationIds, commitmentIds);
}
