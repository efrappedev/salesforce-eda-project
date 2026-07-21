public without sharing class BulkRecordTypeChangeBatch implements Database.Batchable<SObject>, Database.Stateful {

    // See BulkEditBatch for the Database.Stateful serialization contract —
    // only primitives (String, Integer, Boolean, Id) round-trip reliably
    // across async chunk boundaries, so the selected record IDs are passed
    // as a comma-joined String rather than a List<Id>/Set<Id>.
    private Id logId;
    private String recordIdsCsv;
    private Id newRecordTypeId;

    private Integer successCount = 0;
    private Integer errorCount = 0;
    @TestVisible private String errorLog = '';

    private static final Integer MAX_ERROR_LOG_LENGTH = 25000;

    public BulkRecordTypeChangeBatch(Id logId, String recordIdsCsv, Id newRecordTypeId) {
        this.logId = logId;
        this.recordIdsCsv = recordIdsCsv;
        this.newRecordTypeId = newRecordTypeId;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        update new Bulk_Edit_Log__c(Id = logId, Status__c = 'In Progress');

        Set<Id> ids = new Set<Id>();
        for (String rawId : recordIdsCsv.split(',')) {
            if (String.isNotBlank(rawId)) {
                ids.add((Id) rawId);
            }
        }

        return Database.getQueryLocator([SELECT Id, RecordTypeId FROM Account WHERE Id IN :ids]);
    }

    public void execute(Database.BatchableContext bc, List<Account> scope) {
        Map<Id, String> oldValuesById = new Map<Id, String>();
        List<Account> toUpdate = new List<Account>();

        for (Account acc : scope) {
            oldValuesById.put(acc.Id, acc.RecordTypeId);
            toUpdate.add(new Account(Id = acc.Id, RecordTypeId = newRecordTypeId));
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
