trigger FundraisingScholarshipTrigger on Scholarship_Allocation__c (
    after insert, after update, after delete, after undelete
) {
    Set<Id> scholarshipIds = new Set<Id>();

    List<Scholarship_Allocation__c> records = Trigger.isDelete ? Trigger.old : Trigger.new;
    for (Scholarship_Allocation__c a : records) {
        if (a.Scholarship__c != null) scholarshipIds.add(a.Scholarship__c);
    }

    if (Trigger.isUpdate) {
        for (Scholarship_Allocation__c a : Trigger.old) {
            if (a.Scholarship__c != null) scholarshipIds.add(a.Scholarship__c);
        }
    }

    FundraisingScholarshipService.rollupAllocations(scholarshipIds);
}
