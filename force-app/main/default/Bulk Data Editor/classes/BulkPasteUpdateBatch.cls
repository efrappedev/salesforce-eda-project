public without sharing class BulkPasteUpdateBatch implements Database.Batchable<SObject>, Database.Stateful {

    // See BulkEditBatch for the Database.Stateful serialization contract —
    // only primitives (String, Integer, Boolean, Id) and Map<String,String>
    // round-trip reliably across async chunk boundaries. newValueByRecordId
    // is keyed by record Id (as String) so it doubles as the source of the
    // record set to update — no separate id list is needed.
    private Id logId;
    private String objectApiName;
    private String fieldApiName;
    private Map<String, String> newValueByRecordId;

    private Integer successCount = 0;
    private Integer errorCount = 0;
    @TestVisible private String errorLog = '';

    private static final Integer MAX_ERROR_LOG_LENGTH = 25000;

    public BulkPasteUpdateBatch(Id logId, String objectApiName, String fieldApiName, Map<String, String> newValueByRecordId) {
        this.logId = logId;
        this.objectApiName = objectApiName;
        this.fieldApiName = fieldApiName;
        this.newValueByRecordId = newValueByRecordId;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        Schema.SObjectType sType = BulkEditService.resolveObjectType(objectApiName);
        Schema.DescribeFieldResult dfr = BulkEditService.resolveFieldDescribe(sType, fieldApiName);

        update new Bulk_Edit_Log__c(Id = logId, Status__c = 'In Progress');

        Set<Id> ids = new Set<Id>();
        for (String recordId : newValueByRecordId.keySet()) {
            if (String.isNotBlank(recordId)) {
                ids.add((Id) recordId);
            }
        }

        String fieldName = String.escapeSingleQuotes(dfr.getName());
        String objectName = String.escapeSingleQuotes(sType.getDescribe().getName());
        String query = 'SELECT Id, ' + fieldName + ' FROM ' + objectName + ' WHERE Id IN :ids';

        return Database.getQueryLocator(query);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        Schema.SObjectType sType = BulkEditService.resolveObjectType(objectApiName);
        Schema.DescribeFieldResult dfr = BulkEditService.resolveFieldDescribe(sType, fieldApiName);

        Map<Id, String> oldValuesById = new Map<Id, String>();
        List<SObject> toUpdate = new List<SObject>();

        for (SObject record : scope) {
            Object currentVal = record.get(dfr.getName());
            oldValuesById.put(record.Id, currentVal == null ? null : String.valueOf(currentVal));

            String rawNewValue = newValueByRecordId.get(String.valueOf(record.Id));
            Object newTypedValue = BulkEditService.toApexValue(dfr.getType(), rawNewValue, String.isBlank(rawNewValue));

            SObject clean = sType.newSObject(record.Id);
            clean.put(dfr.getName(), newTypedValue);
            toUpdate.add(clean);
        }

        List<Database.SaveResult> results = Database.update(toUpdate, false);
        List<Bulk_Edit_Snapshot__c> snapshots = new List<Bulk_Edit_Snapshot__c>();

        for (Integer i = 0; i < results.size(); i++) {
            Database.SaveResult sr = results[i];
            Id recordId = toUpdate[i].Id;

            if (sr.isSuccess()) {
                successCount++;
                snapshots.add(new Bulk_Edit_Snapshot__c(
                    Bulk_Edit_Log__c = logId,
                    Record_Id__c = recordId,
                    Old_Value__c = oldValuesById.get(recordId)
                ));
            } else {
                errorCount++;
                for (Database.Error err : sr.getErrors()) {
                    appendError(recordId + ': ' + err.getMessage());
                }
            }
        }

        if (!snapshots.isEmpty()) {
            insert snapshots;
        }
    }

    public void finish(Database.BatchableContext bc) {
        String status = errorCount == 0 ? 'Completed' : (successCount == 0 ? 'Failed' : 'Completed with Errors');

        update new Bulk_Edit_Log__c(
            Id = logId,
            Status__c = status,
            Records_Affected__c = successCount,
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
