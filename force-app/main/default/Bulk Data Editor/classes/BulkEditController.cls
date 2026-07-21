public with sharing class BulkEditController {

    // 2000 (platform max) minimizes async queue round-trips but leaves the
    // progress bar stuck showing "0 of N" for the whole first chunk on large
    // jobs, since there's no way to report partial progress within a chunk —
    // it reads as frozen. 400 is a middle ground: still far fewer round-trips
    // than the original 200, but enough chunks that the progress bar visibly
    // advances instead of appearing stuck.
    private static final Integer BATCH_CHUNK_SIZE = 400;

    // Test-only hooks for permission/error branches an admin test-running user
    // can't naturally trigger. Always false in production; each test resets
    // it in a finally.
    @TestVisible private static Boolean TEST_FORCE_NO_CREATE_ACCESS = false;
    @TestVisible private static Boolean TEST_FORCE_HISTORY_ERROR = false;

    // AuraHandledException does not reliably deliver the message passed to its
    // constructor to the client — Salesforce requires an explicit setMessage()
    // call after construction, or the LWC side receives the generic
    // "Script-thrown exception" string instead of the real error. This is a
    // documented platform quirk, not specific to this org. Every throw site in
    // this class must go through this helper.
    private static AuraHandledException asAuraException(String message) {
        String safeMessage = String.isNotBlank(message) ? message : 'An unexpected error occurred with no message. Check debug logs.';
        AuraHandledException ex = new AuraHandledException(safeMessage);
        ex.setMessage(safeMessage);
        return ex;
    }

    @AuraEnabled(cacheable=true)
    public static List<BulkEditWrappers.ObjectOption> getEditableObjects() {
        try {
            return BulkEditService.getEditableObjects();
        } catch (Exception ex) {
            throw asAuraException(ex.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<BulkEditWrappers.FieldOption> getEditableFields(String objectApiName) {
        try {
            return BulkEditService.getEditableFields(objectApiName);
        } catch (Exception ex) {
            throw asAuraException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static BulkEditWrappers.ValueDistributionResult getValueDistribution(
        String objectApiName,
        String fieldApiName,
        String filterFieldApiName,
        String filterValue,
        Boolean filterIsBlankValue
    ) {
        try {
            return BulkEditService.getValueDistribution(objectApiName, fieldApiName, filterFieldApiName, filterValue, filterIsBlankValue);
        } catch (Exception ex) {
            throw asAuraException(ex.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<BulkEditWrappers.FieldOption> getFilterableFields(String objectApiName, String excludeFieldApiName) {
        try {
            return BulkEditService.getFilterableFields(objectApiName, excludeFieldApiName);
        } catch (Exception ex) {
            throw asAuraException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static BulkEditWrappers.ValueDistributionResult getFilterFieldValueDistribution(String objectApiName, String fieldApiName) {
        try {
            return BulkEditService.getFilterFieldValueDistribution(objectApiName, fieldApiName);
        } catch (Exception ex) {
            throw asAuraException(ex.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<String> getPicklistValues(String objectApiName, String fieldApiName) {
        try {
            return BulkEditService.getPicklistValues(objectApiName, fieldApiName);
        } catch (Exception ex) {
            throw asAuraException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static Integer previewCount(String objectApiName, String fieldApiName, String oldValue, Boolean isBlankValue) {
        try {
            return BulkEditService.previewCount(objectApiName, fieldApiName, oldValue, isBlankValue);
        } catch (Exception ex) {
            throw asAuraException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static BulkEditWrappers.BulkEditJobResult startBulkEdit(
        String objectApiName,
        String fieldApiName,
        String objectLabel,
        String fieldLabel,
        String oldValue,
        Boolean isBlankValue,
        String newValue,
        Boolean newValueIsBlank,
        String filterFieldApiName,
        String filterFieldLabel,
        String filterValue,
        Boolean filterIsBlankValue
    ) {
        try {
            if (TEST_FORCE_NO_CREATE_ACCESS || !Schema.sObjectType.Bulk_Edit_Log__c.isCreateable()) {
                throw asAuraException('You do not have permission to create Bulk Edit Log records.');
            }

            // Validate object/field/value shape up front so a bad request
            // fails fast instead of surfacing inside the async batch.
            Schema.SObjectType sType = BulkEditService.resolveObjectType(objectApiName);
            Schema.DescribeFieldResult dfr = BulkEditService.resolveFieldDescribe(sType, fieldApiName);

            // The new value is free-typed by the user with no client-side
            // cap, but it's stored on Bulk_Edit_Log__c.New_Value__c (Text,
            // 255 chars) before the batch ever runs. Checking against the
            // target field's own max length (always <= 255 for the text-like
            // types this app allows) fails fast with a clear message instead
            // of the log insert throwing a raw STRING_TOO_LONG DmlException.
            if (newValueIsBlank != true && String.isNotBlank(newValue) && dfr.getLength() > 0 && newValue.length() > dfr.getLength()) {
                throw asAuraException('The new value is too long for this field (maximum ' + dfr.getLength() + ' characters).');
            }

            BulkEditService.buildWhereClause(dfr, oldValue, isBlankValue);
            BulkEditService.toApexValue(dfr.getType(), newValue, newValueIsBlank);

            if (String.isNotBlank(filterFieldApiName)) {
                Schema.DescribeFieldResult filterDfr = BulkEditService.resolveFilterFieldDescribe(sType, filterFieldApiName);
                BulkEditService.buildWhereClause(filterDfr, filterValue, filterIsBlankValue);
            }

            Bulk_Edit_Log__c logRec = new Bulk_Edit_Log__c(
                Object_Type__c = objectApiName,
                Object_Label__c = objectLabel,
                Field_API_Name__c = fieldApiName,
                Field_Label__c = fieldLabel,
                Old_Value_Display__c = (isBlankValue == true) ? '(Blank)' : oldValue,
                New_Value__c = (newValueIsBlank == true) ? '(Blank)' : newValue,
                Filter_Field_Label__c = String.isBlank(filterFieldApiName) ? null : filterFieldLabel,
                Filter_Value_Display__c = String.isBlank(filterFieldApiName) ? null : ((filterIsBlankValue == true) ? '(Blank)' : filterValue),
                Status__c = 'Queued'
            );
            insert logRec;

            Id batchJobId = Database.executeBatch(
                new BulkEditBatch(
                    logRec.Id, objectApiName, fieldApiName, oldValue, isBlankValue, newValue, newValueIsBlank,
                    filterFieldApiName, filterValue, filterIsBlankValue
                ),
                BATCH_CHUNK_SIZE
            );

            logRec.Batch_Job_Id__c = batchJobId;
            update logRec;

            return new BulkEditWrappers.BulkEditJobResult(logRec.Id, batchJobId);
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            throw asAuraException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static BulkEditWrappers.JobStatusResult getJobStatus(Id logId) {
        try {
            List<Bulk_Edit_Log__c> logs = [
                SELECT Id, Status__c, Records_Affected__c, Error_Message__c, Batch_Job_Id__c
                FROM Bulk_Edit_Log__c
                WHERE Id = :logId
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];
            if (logs.isEmpty()) {
                throw asAuraException('This bulk edit job was not found. It may have been deleted.');
            }
            Bulk_Edit_Log__c logRec = logs[0];

            BulkEditWrappers.JobStatusResult result = new BulkEditWrappers.JobStatusResult();
            result.logId = logRec.Id;
            result.status = logRec.Status__c;
            result.recordsAffected = logRec.Records_Affected__c != null ? logRec.Records_Affected__c.intValue() : 0;
            result.errorMessage = logRec.Error_Message__c;
            result.canUndo = (logRec.Status__c == 'Completed' || logRec.Status__c == 'Completed with Errors');
            result.isDone = true;
            result.totalRecords = 0;
            result.processedRecords = 0;
            result.numberOfErrors = 0;
            result.batchJobId = logRec.Batch_Job_Id__c;

            if (String.isNotBlank(logRec.Batch_Job_Id__c)) {
                List<AsyncApexJob> jobs = [
                    SELECT Status, JobItemsProcessed, TotalJobItems, NumberOfErrors
                    FROM AsyncApexJob
                    WHERE Id = :logRec.Batch_Job_Id__c
                    LIMIT 1
                ];
                if (!jobs.isEmpty()) {
                    AsyncApexJob job = jobs[0];
                    result.totalRecords = job.TotalJobItems;
                    result.processedRecords = job.JobItemsProcessed;
                    result.numberOfErrors = job.NumberOfErrors;
                    result.isDone = (job.Status == 'Completed' || job.Status == 'Failed' || job.Status == 'Aborted');
                }
            }

            return result;
        } catch (Exception ex) {
            throw asAuraException(ex.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<BulkEditWrappers.EditHistoryEntry> getEditHistory(Integer limitCount) {
        try {
            if (TEST_FORCE_HISTORY_ERROR) {
                throw new BulkEditException('Forced error for test coverage.');
            }
            Integer safeLimit = (limitCount == null || limitCount <= 0) ? 50 : Math.min(limitCount, 200);

            List<Bulk_Edit_Log__c> logs = [
                SELECT Id, Name, Object_Label__c, Field_Label__c, Old_Value_Display__c,
                       New_Value__c, Records_Affected__c, Status__c, CreatedDate,
                       Filter_Field_Label__c, Filter_Value_Display__c
                FROM Bulk_Edit_Log__c
                WITH SECURITY_ENFORCED
                ORDER BY CreatedDate DESC
                LIMIT :safeLimit
            ];

            List<BulkEditWrappers.EditHistoryEntry> entries = new List<BulkEditWrappers.EditHistoryEntry>();
            for (Bulk_Edit_Log__c logRec : logs) {
                BulkEditWrappers.EditHistoryEntry entry = new BulkEditWrappers.EditHistoryEntry();
                entry.logId = logRec.Id;
                entry.name = logRec.Name;
                entry.objectLabel = logRec.Object_Label__c;
                entry.fieldLabel = logRec.Field_Label__c;
                entry.oldValueDisplay = logRec.Old_Value_Display__c;
                entry.newValue = logRec.New_Value__c;
                entry.recordsAffected = logRec.Records_Affected__c != null ? logRec.Records_Affected__c.intValue() : 0;
                entry.status = logRec.Status__c;
                entry.createdDate = logRec.CreatedDate;
                entry.canUndo = (logRec.Status__c == 'Completed' || logRec.Status__c == 'Completed with Errors');
                entry.filterFieldLabel = logRec.Filter_Field_Label__c;
                entry.filterValueDisplay = logRec.Filter_Value_Display__c;
                entries.add(entry);
            }
            return entries;
        } catch (Exception ex) {
            throw asAuraException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static Id undoBulkEdit(Id logId) {
        try {
            Id batchJobId = Database.executeBatch(new BulkEditUndoBatch(logId), BATCH_CHUNK_SIZE);
            // Repoint Batch_Job_Id__c at this undo job so getJobStatus polls the
            // job that's actually running instead of the original edit's (already
            // completed) job.
            update new Bulk_Edit_Log__c(Id = logId, Batch_Job_Id__c = batchJobId);
            return batchJobId;
        } catch (Exception ex) {
            throw asAuraException(ex.getMessage());
        }
    }
}
