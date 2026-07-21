public with sharing class BulkRecordTypeController {

    // Mirrors BulkEditController.BATCH_CHUNK_SIZE — kept as its own local
    // constant since the two controllers aren't otherwise coupled.
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

    // Old_Value_Display__c is a 255-char Text field. Unlike the value-edit
    // flow, searchSummary here is a free-form description built from a
    // user-typed search term (itself possibly up to 255 chars, e.g. an
    // Account Name) plus wrapping text, so it can exceed 255 on its own —
    // it's a log annotation, not the data being written, so truncating it
    // for storage is safe (no data-correctness impact, unlike newValue in
    // BulkEditController which must be rejected, not truncated).
    private static String truncateForLog(String value, Integer maxLen) {
        if (value == null || value.length() <= maxLen) {
            return value;
        }
        return value.substring(0, maxLen);
    }

    @AuraEnabled(cacheable=true)
    public static List<BulkEditWrappers.RecordTypeOption> getRecordTypesForObject() {
        try {
            return BulkRecordTypeService.getRecordTypesForObject();
        } catch (Exception ex) {
            throw asAuraException(ex.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<BulkEditWrappers.FieldOption> getSearchableFields() {
        try {
            return BulkRecordTypeService.getSearchableFields();
        } catch (Exception ex) {
            throw asAuraException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static List<BulkEditWrappers.RecordSearchResult> searchRecords(Id recordTypeIdFilter, String searchFieldApiName, String searchTerm) {
        try {
            return BulkRecordTypeService.searchRecords(recordTypeIdFilter, searchFieldApiName, searchTerm);
        } catch (Exception ex) {
            throw asAuraException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static BulkEditWrappers.BulkEditJobResult startRecordTypeChange(
        String recordIdsCsv,
        Integer selectedCount,
        Id newRecordTypeId,
        String newRecordTypeLabel,
        String searchSummary
    ) {
        try {
            if (TEST_FORCE_NO_CREATE_ACCESS || !Schema.sObjectType.Bulk_Edit_Log__c.isCreateable()) {
                throw asAuraException('You do not have permission to create Bulk Edit Log records.');
            }
            if (String.isBlank(recordIdsCsv) || selectedCount == null || selectedCount <= 0) {
                throw asAuraException('Please select at least one record.');
            }
            if (newRecordTypeId == null) {
                throw asAuraException('Please choose a Record Type to apply.');
            }

            // Validate up front so a bad request fails fast instead of
            // surfacing inside the async batch.
            Schema.SObjectType sType = BulkEditService.resolveObjectType('Account');
            BulkEditService.resolveFieldDescribe(sType, 'RecordTypeId');

            Bulk_Edit_Log__c logRec = new Bulk_Edit_Log__c(
                Object_Type__c = 'Account',
                Object_Label__c = 'Account',
                Field_API_Name__c = 'RecordTypeId',
                Field_Label__c = 'Record Type',
                Old_Value_Display__c = truncateForLog(searchSummary, 255),
                New_Value__c = newRecordTypeLabel,
                Status__c = 'Queued'
            );
            insert logRec;

            Id batchJobId = Database.executeBatch(
                new BulkRecordTypeChangeBatch(logRec.Id, recordIdsCsv, newRecordTypeId),
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
