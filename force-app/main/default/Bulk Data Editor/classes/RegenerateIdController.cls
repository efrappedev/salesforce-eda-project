// Backs the "Regenerate ID" tab's Contact preview step. Account needs no
// method here: that flow calls BulkPasteUpdateController.matchRecords /
// startPasteUpdate directly, targeting ID_Account__c with a blank value,
// since Account_GenerateID.trigger's before-update branch already
// regenerates the field for us. See RegenerateIdService for why Contact
// needs this separate compute-only step instead.
public with sharing class RegenerateIdController {

    // See BulkPasteUpdateController.asAuraException() — same
    // AuraHandledException setMessage() quirk, duplicated locally rather
    // than sharing a base class for a single helper method.
    private static AuraHandledException asAuraException(String message) {
        String safeMessage = String.isNotBlank(message) ? message : 'An unexpected error occurred with no message. Check debug logs.';
        AuraHandledException ex = new AuraHandledException(safeMessage);
        ex.setMessage(safeMessage);
        return ex;
    }

    @AuraEnabled
    public static Map<Id, String> previewContactIdRegeneration(List<Id> contactIds) {
        try {
            return RegenerateIdService.computeNewContactIds(contactIds == null ? new Set<Id>() : new Set<Id>(contactIds));
        } catch (Exception ex) {
            throw asAuraException(ex.getMessage());
        }
    }
}
