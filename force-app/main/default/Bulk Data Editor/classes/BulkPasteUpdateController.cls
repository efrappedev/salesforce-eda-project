public with sharing class BulkPasteUpdateController {

    // Mirrors BulkEditController.BATCH_CHUNK_SIZE — kept as its own local
    // constant since the controllers aren't otherwise coupled.
    private static final Integer BATCH_CHUNK_SIZE = 400;

    @TestVisible private static Boolean TEST_FORCE_NO_CREATE_ACCESS = false;

    // See BulkEditController.asAuraException() — same AuraHandledException
    // setMessage() quirk, duplicated locally rather than sharing a base
    // class for a single helper method.
    private static AuraHandledException asAuraException(String message) {
        String safeMessage = String.isNotBlank(message) ? message : 'An unexpected error occurred with no message. Check debug logs.';
        AuraHandledException ex = new AuraHandledException(safeMessage);
        ex.setMessage(safeMessage);
        return ex;
    }

    // See BulkRecordTypeController.truncateForLog() — searchSummary is a
    // free-form log annotation built client-side, not the data being
    // written, so it's safe to truncate rather than reject.
    private static String truncateForLog(String value, Integer maxLen) {
        if (value == null || value.length() <= maxLen) {
            return value;
        }
        return value.substring(0, maxLen);
    }

    @AuraEnabled(cacheable=true)
    public static List<BulkEditWrappers.FieldOption> getSearchableFields(String objectApiName) {
        try {
            return BulkPasteUpdateService.getSearchableFields(objectApiName);
        } catch (Exception ex) {
            throw asAuraException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static List<BulkEditWrappers.MatchResult> matchRecords(String objectApiName, String searchFieldApiName, List<String> searchValues, String targetFieldApiName) {
        try {
            return BulkPasteUpdateService.matchRecords(objectApiName, searchFieldApiName, searchValues, targetFieldApiName);
        } catch (Exception ex) {
            throw asAuraException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static BulkEditWrappers.BulkEditJobResult startPasteUpdate(
        String objectApiName,
        String objectLabel,
        String fieldApiName,
        String fieldLabel,
        String searchFieldLabel,
        Map<String, String> newValueByRecordId,
        Integer matchedCount,
        String searchSummary
    ) {
        try {
            if (TEST_FORCE_NO_CREATE_ACCESS || !Schema.sObjectType.Bulk_Edit_Log__c.isCreateable()) {
                throw asAuraException('You do not have permission to create Bulk Edit Log records.');
            }
            if (newValueByRecordId == null || newValueByRecordId.isEmpty() || matchedCount == null || matchedCount <= 0) {
                throw asAuraException('Please match at least one record before running this update.');
            }

            // Validate up front so a bad request fails fast instead of
            // surfacing inside the async batch.
            Schema.SObjectType sType = BulkEditService.resolveObjectType(objectApiName);
            Schema.DescribeFieldResult dfr = BulkEditService.resolveFieldDescribe(sType, fieldApiName);

            if (dfr.getLength() > 0) {
                for (String recordId : newValueByRecordId.keySet()) {
                    String newValue = newValueByRecordId.get(recordId);
                    if (String.isNotBlank(newValue) && newValue.length() > dfr.getLength()) {
                        throw asAuraException('The new value "' + newValue + '" is too long for this field (maximum ' + dfr.getLength() + ' characters).');
                    }
                }
            }

            Bulk_Edit_Log__c logRec = new Bulk_Edit_Log__c(
                Object_Type__c = objectApiName,
                Object_Label__c = objectLabel,
                Field_API_Name__c = fieldApiName,
                Field_Label__c = fieldLabel,
                Old_Value_Display__c = '(varies per record — matched by ' + searchFieldLabel + ')',
                New_Value__c = truncateForLog(searchSummary, 255),
                Status__c = 'Queued'
            );
            insert logRec;

            Id batchJobId = Database.executeBatch(
                new BulkPasteUpdateBatch(logRec.Id, objectApiName, fieldApiName, newValueByRecordId),
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
}
