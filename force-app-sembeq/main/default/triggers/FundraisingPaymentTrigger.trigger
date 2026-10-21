trigger FundraisingPaymentTrigger on Scholarship_Payment__c (
    after insert, after update, after delete, after undelete
) {
    Set<Id> allocationIds = new Set<Id>();

    List<Scholarship_Payment__c> records = Trigger.isDelete ? Trigger.old : Trigger.new;
    for (Scholarship_Payment__c p : records) {
        if (p.Allocation__c != null) allocationIds.add(p.Allocation__c);
    }

    if (Trigger.isUpdate) {
        for (Scholarship_Payment__c p : Trigger.old) {
            if (p.Allocation__c != null) allocationIds.add(p.Allocation__c);
        }
    }

    FundraisingScholarshipService.rollupPayments(allocationIds);
}
