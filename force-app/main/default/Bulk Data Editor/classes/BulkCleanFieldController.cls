public with sharing class BulkCleanFieldController {

    // 2000 (platform max) minimizes async queue round-trips but leaves the
    // progress bar stuck showing "0 of N" for the whole first chunk on large
    // jobs. 400 mirrors BulkEditController's choice — see its comment.
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

    @AuraEnabled(cacheable=true)
    public static List<BulkEditWrappers.FieldOption> getCleanableFields(String objectApiName) {
        try {
            return BulkCleanFieldService.getCleanableFields(objectApiName);
        } catch (Exception ex) {
            throw asAuraException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static BulkEditWrappers.CleanPreviewResult previewCleanup(
        String objectApiName,
        String fieldApiName,
        String filterFieldApiName,
        String filterValue,
        Boolean filterIsBlankValue,
        Boolean normalizeSpaces,
        Boolean collapseSpaces,
        Boolean trimEdges,
        String customCharsToStrip
    ) {
        try {
            return BulkCleanFieldService.previewCleanup(
                objectApiName, fieldApiName, filterFieldApiName, filterValue, filterIsBlankValue,
                normalizeSpaces, collapseSpaces, trimEdges, customCharsToStrip
            );
        } catch (Exception ex) {
            throw asAuraException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static BulkEditWrappers.BulkEditJobResult startCleanField(
        String objectApiName,
        String objectLabel,
        String fieldApiName,
        String fieldLabel,
        String filterFieldApiName,
        String filterFieldLabel,
        String filterValue,
        Boolean filterIsBlankValue,
        Boolean normalizeSpaces,
        Boolean collapseSpaces,
        Boolean trimEdges,
        String customCharsToStrip
    ) {
        try {
            if (TEST_FORCE_NO_CREATE_ACCESS || !Schema.sObjectType.Bulk_Edit_Log__c.isCreateable()) {
                throw asAuraException('You do not have permission to create Bulk Edit Log records.');
            }

            // Validate object/field/filter shape up front so a bad request
            // fails fast instead of surfacing inside the async batch.
            Schema.SObjectType sType = BulkEditService.resolveObjectType(objectApiName);
            Schema.DescribeFieldResult dfr = BulkEditService.resolveFieldDescribe(sType, fieldApiName);
            BulkCleanFieldService.buildWhereForCandidates(sType, dfr, filterFieldApiName, filterValue, filterIsBlankValue);

            Bulk_Edit_Log__c logRec = new Bulk_Edit_Log__c(
                Object_Type__c = objectApiName,
                Object_Label__c = objectLabel,
                Field_API_Name__c = fieldApiName,
                Field_Label__c = fieldLabel,
                Old_Value_Display__c = '(varies per record — auto-cleaned)',
                New_Value__c = buildRulesSummary(normalizeSpaces, collapseSpaces, trimEdges, customCharsToStrip),
                Filter_Field_Label__c = String.isBlank(filterFieldApiName) ? null : filterFieldLabel,
                Filter_Value_Display__c = String.isBlank(filterFieldApiName) ? null : ((filterIsBlankValue == true) ? '(Blank)' : filterValue),
                Status__c = 'Queued'
            );
            insert logRec;

            Id batchJobId = Database.executeBatch(
                new BulkCleanFieldBatch(
                    logRec.Id, objectApiName, fieldApiName, filterFieldApiName, filterValue, filterIsBlankValue,
                    normalizeSpaces, collapseSpaces, trimEdges, customCharsToStrip
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

    // Human-readable New_Value__c summary for the History list, since a
    // Clean Field job has no single new value the way Bulk Edit does.
    private static String buildRulesSummary(Boolean normalizeSpaces, Boolean collapseSpaces, Boolean trimEdges, String customCharsToStrip) {
        List<String> parts = new List<String>();
        if (normalizeSpaces == true) {
            parts.add('Normalize spaces');
        }
        if (collapseSpaces == true) {
            parts.add('Collapse spaces');
        }
        if (trimEdges == true) {
            parts.add('Trim edges');
        }
        // Not String.isNotBlank() — see the same note in
        // BulkCleanFieldService.cleanValue(): a whitespace-only value (e.g.
        // a single space) is a legitimate strip target, not a blank input.
        // customCharsToStrip is a comma-separated list of literal items
        // (single characters or whole words/phrases) — see cleanValue().
        if (customCharsToStrip != null && customCharsToStrip.length() > 0) {
            parts.add('Remove: ' + customCharsToStrip);
        }
        return parts.isEmpty() ? '(no rules selected)' : String.join(parts, '; ');
    }
}
