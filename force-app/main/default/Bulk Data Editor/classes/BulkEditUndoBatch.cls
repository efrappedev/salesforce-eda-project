public without sharing class BulkEditUndoBatch implements Database.Batchable<SObject>, Database.Stateful {

    // See BulkEditBatch for the Database.Stateful serialization contract
    // this class follows: only primitives round-trip reliably.
    private Id logId;
    private String cachedObjectType;
    private String cachedFieldApiName;

    private Integer successCount = 0;
    private Integer errorCount = 0;
    @TestVisible private String errorLog = '';

    private static final Integer MAX_ERROR_LOG_LENGTH = 25000;

    public BulkEditUndoBatch(Id logId) {
        this.logId = logId;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        List<Bulk_Edit_Log__c> logs = [
            SELECT Id, Object_Type__c, Field_API_Name__c, Status__c
            FROM Bulk_Edit_Log__c
            WHERE Id = :logId
            LIMIT 1
        ];
        if (logs.isEmpty()) {
            throw new BulkEditException('This bulk edit log was not found. It may have been deleted.');
        }
        Bulk_Edit_Log__c logRec = logs[0];

        if (logRec.Status__c != 'Completed' && logRec.Status__c != 'Completed with Errors') {
            throw new BulkEditException('This bulk edit cannot be undone from its current status: ' + logRec.Status__c);
        }

        Schema.SObjectType sType = BulkEditService.resolveObjectType(logRec.Object_Type__c);
        BulkEditService.resolveFieldDescribe(sType, logRec.Field_API_Name__c);

        cachedObjectType = logRec.Object_Type__c;
        cachedFieldApiName = logRec.Field_API_Name__c;

        update new Bulk_Edit_Log__c(Id = logId, Status__c = 'Undo In Progress');

        return Database.getQueryLocator([
            SELECT Id, Record_Id__c, Old_Value__c
            FROM Bulk_Edit_Snapshot__c
            WHERE Bulk_Edit_Log__c = :logId
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Bulk_Edit_Snapshot__c> scope) {
        Schema.SObjectType sType = BulkEditService.resolveObjectType(cachedObjectType);
        Schema.DescribeFieldResult dfr = BulkEditService.resolveFieldDescribe(sType, cachedFieldApiName);

        List<SObject> toUpdate = new List<SObject>();
        for (Bulk_Edit_Snapshot__c snap : scope) {
            if (String.isBlank(snap.Record_Id__c)) {
                continue;
            }
            Boolean wasBlank = String.isBlank(snap.Old_Value__c);
            Object restoredValue = BulkEditService.toApexValue(dfr.getType(), snap.Old_Value__c, wasBlank);

            SObject clean = sType.newSObject((Id) snap.Record_Id__c);
            clean.put(dfr.getName(), restoredValue);
            toUpdate.add(clean);
        }

        List<Database.SaveResult> results = Database.update(toUpdate, false);
        for (Integer i = 0; i < results.size(); i++) {
            Database.SaveResult sr = results[i];
            if (sr.isSuccess()) {
                successCount++;
            } else {
                errorCount++;
                for (Database.Error err : sr.getErrors()) {
                    appendError(toUpdate[i].Id + ': ' + err.getMessage());
                }
            }
        }
    }

    public void finish(Database.BatchableContext bc) {
        String status = (successCount > 0 || errorCount == 0) ? 'Undone' : 'Undo Failed';

        update new Bulk_Edit_Log__c(
            Id = logId,
            Status__c = status,
            Error_Message__c = String.isBlank(errorLog) ? null : errorLog
        );
    }

    @TestVisible
    private void appendError(String message) {
        if (errorLog.length() >= MAX_ERROR_LOG_LENGTH) {
            return;
        }
        errorLog += (String.isBlank(errorLog) ? '' : '\n') + message;
    }
}
