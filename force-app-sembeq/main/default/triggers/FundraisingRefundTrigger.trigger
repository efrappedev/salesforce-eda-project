trigger FundraisingRefundTrigger on Gift_Refund__c (
    after insert, after update, after delete, after undelete
) {
    Set<Id> giftIds = new Set<Id>();

    List<Gift_Refund__c> records = Trigger.isDelete ? Trigger.old : Trigger.new;
    for (Gift_Refund__c r : records) {
        if (r.Gift__c != null) giftIds.add(r.Gift__c);
    }

    if (Trigger.isUpdate) {
        for (Gift_Refund__c r : Trigger.old) {
            if (r.Gift__c != null) giftIds.add(r.Gift__c);
        }
    }

    FundraisingRollupService.rollupRefunds(giftIds);
}
