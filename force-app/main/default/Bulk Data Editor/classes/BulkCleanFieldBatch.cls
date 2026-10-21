public without sharing class BulkCleanFieldBatch implements Database.Batchable<SObject>, Database.Stateful {

    // Database.Stateful only reliably round-trips primitives (String,
    // Integer, Boolean, Id) and Map<String,String> across async chunk
    // boundaries — see the same note in BulkEditBatch.cls. Schema.*
    // objects are re-resolved from these primitive strings in every
    // execute().
    private Id logId;
    private String objectApiName;
    private String fieldApiName;

    private String filterFieldApiName;
    private String filterValue;
    private Boolean filterIsBlank;

    private Boolean normalizeSpaces;
    private Boolean collapseSpaces;
    private Boolean trimEdges;
    private String customCharsToStrip;

    private Integer successCount = 0;
    private Integer errorCount = 0;
    @TestVisible private String errorLog = '';

    private static final Integer MAX_ERROR_LOG_LENGTH = 25000;

    public BulkCleanFieldBatch(
        Id logId, String objectApiName, String fieldApiName,
        String filterFieldApiName, String filterValue, Boolean filterIsBlank,
        Boolean normalizeSpaces, Boolean collapseSpaces, Boolean trimEdges, String customCharsToStrip
    ) {
        this.logId = logId;
        this.objectApiName = objectApiName;
        this.fieldApiName = fieldApiName;
        this.filterFieldApiName = filterFieldApiName;
        this.filterValue = filterValue;
        this.filterIsBlank = filterIsBlank;
        this.normalizeSpaces = normalizeSpaces;
        this.collapseSpaces = collapseSpaces;
        this.trimEdges = trimEdges;
        this.customCharsToStrip = customCharsToStrip;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        Schema.SObjectType sType = BulkEditService.resolveObjectType(objectApiName);
        Schema.DescribeFieldResult dfr = BulkEditService.resolveFieldDescribe(sType, fieldApiName);

        update new Bulk_Edit_Log__c(Id = logId, Status__c = 'In Progress');

        String whereClause = BulkCleanFieldService.buildWhereForCandidates(sType, dfr, filterFieldApiName, filterValue, filterIsBlank);
        String fieldName = String.escapeSingleQuotes(dfr.getName());
        String objectName = String.escapeSingleQuotes(sType.getDescribe().getName());
        String query = 'SELECT Id, ' + fieldName + ' FROM ' + objectName + ' WHERE ' + whereClause;

        return Database.getQueryLocator(query);
    }

    // Unlike BulkEditBatch/BulkPasteUpdateBatch (which unconditionally
    // update every record the WHERE clause matched), the WHERE clause here
    // only bounds the *candidate* set — each record's cleaned value is
    // computed here, and a record whose value doesn't actually change is
    // skipped entirely: not updated, not counted, no snapshot row. So
    // Records_Affected__c on the finished log means "records that actually
    // had something to clean," not "records scanned."
    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        Schema.SObjectType sType = BulkEditService.resolveObjectType(objectApiName);
        Schema.DescribeFieldResult dfr = BulkEditService.resolveFieldDescribe(sType, fieldApiName);

        Map<Id, String> oldValuesById = new Map<Id, String>();
        List<SObject> toUpdate = new List<SObject>();

        for (SObject record : scope) {
            Object currentVal = record.get(dfr.getName());
            String currentStr = currentVal == null ? null : String.valueOf(currentVal);
            String cleaned = BulkCleanFieldService.cleanValue(currentStr, normalizeSpaces, collapseSpaces, trimEdges, customCharsToStrip);

            // Apex's == operator on String silently ignores zero-width /
            // format Unicode characters (e.g. U+200B) when comparing —
            // exactly the kind of character this batch exists to strip — so
            // it can report "unchanged" (returns true) for a value that
            // actually differs. Do NOT use == here even as a fallback:
            // .equals() alone is the only exact, codepoint-accurate check.
            Boolean unchanged = (currentStr == null) ? (cleaned == null) : currentStr.equals(cleaned);
            if (unchanged) {
                continue;
            }

            oldValuesById.put(record.Id, currentStr);
            SObject clean = sType.newSObject(record.Id);
            clean.put(dfr.getName(), cleaned);
            toUpdate.add(clean);
        }

        if (toUpdate.isEmpty()) {
            return;
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
