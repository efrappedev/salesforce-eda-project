public without sharing class BulkEditBatch implements Database.Batchable<SObject>, Database.Stateful {

    // Database.Stateful only reliably round-trips primitives (String,
    // Integer, Boolean, Id) and Map<String,String> across async chunk
    // boundaries — never Schema.* objects, Set<String>, or List<String>.
    // Schema.SObjectType / Schema.DescribeFieldResult are therefore
    // re-resolved from these primitive strings inside every execute().
    private Id logId;
    private String objectApiName;
    private String fieldApiName;
    private String oldValue;
    private Boolean oldValueIsBlank;
    private String newValue;
    private Boolean newValueIsBlank;

    // Optional cross-filter criterion (e.g. only rows where Mailing State =
    // Quebec) ANDed into the WHERE clause built in start(). Left blank when
    // no filter was configured.
    private String filterFieldApiName;
    private String filterValue;
    private Boolean filterIsBlank;

    private Integer successCount = 0;
    private Integer errorCount = 0;
    @TestVisible private String errorLog = '';

    private static final Integer MAX_ERROR_LOG_LENGTH = 25000;

    public BulkEditBatch(
        Id logId, String objectApiName, String fieldApiName, String oldValue, Boolean oldValueIsBlank, String newValue, Boolean newValueIsBlank,
        String filterFieldApiName, String filterValue, Boolean filterIsBlank
    ) {
        this.logId = logId;
        this.objectApiName = objectApiName;
        this.fieldApiName = fieldApiName;
        this.oldValue = oldValue;
        this.oldValueIsBlank = oldValueIsBlank;
        this.newValue = newValue;
        this.newValueIsBlank = newValueIsBlank;
        this.filterFieldApiName = filterFieldApiName;
        this.filterValue = filterValue;
        this.filterIsBlank = filterIsBlank;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        Schema.SObjectType sType = BulkEditService.resolveObjectType(objectApiName);
        Schema.DescribeFieldResult dfr = BulkEditService.resolveFieldDescribe(sType, fieldApiName);

        update new Bulk_Edit_Log__c(Id = logId, Status__c = 'In Progress');

        String whereClause = BulkEditService.buildWhereClause(dfr, oldValue, oldValueIsBlank);
        if (String.isNotBlank(filterFieldApiName)) {
            Schema.DescribeFieldResult filterDfr = BulkEditService.resolveFilterFieldDescribe(sType, filterFieldApiName);
            whereClause += ' AND ' + BulkEditService.buildWhereClause(filterDfr, filterValue, filterIsBlank);
        }
        String fieldName = String.escapeSingleQuotes(dfr.getName());
        String objectName = String.escapeSingleQuotes(sType.getDescribe().getName());
        String query = 'SELECT Id, ' + fieldName + ' FROM ' + objectName + ' WHERE ' + whereClause;

        return Database.getQueryLocator(query);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        Schema.SObjectType sType = BulkEditService.resolveObjectType(objectApiName);
        Schema.DescribeFieldResult dfr = BulkEditService.resolveFieldDescribe(sType, fieldApiName);

        Map<Id, String> oldValuesById = new Map<Id, String>();
        List<SObject> toUpdate = new List<SObject>();
        Object newTypedValue = BulkEditService.toApexValue(dfr.getType(), newValue, newValueIsBlank);

        for (SObject record : scope) {
            Object currentVal = record.get(dfr.getName());
            oldValuesById.put(record.Id, currentVal == null ? null : String.valueOf(currentVal));

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
