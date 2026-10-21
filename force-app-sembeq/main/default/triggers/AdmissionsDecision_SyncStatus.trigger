trigger AdmissionsDecision_SyncStatus on Admissions_Decision__c (after insert, after update) {
    AdmissionsDecisionHandler.handle(Trigger.new, Trigger.oldMap);
}
