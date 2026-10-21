/**
 * DataUpdateFormDeleteVfController.cls
 * Controller for the hidden DataUpdateFormDelete Visualforce page, loaded in an iframe by
 * dataUpdateFormBuilder after the admin confirms a permanent form delete.
 *
 * This exists only because UserInfo.getSessionId() returns a real, API-usable session ID when
 * Apex runs inside a Visualforce page request — unlike @AuraEnabled/LWC invocations, where it
 * does not. That lets the hard-delete SOAP callout (DataUpdateFormAdminMetadataDeleteService)
 * authenticate as whichever System Administrator is actually logged in and confirmed the
 * delete, instead of a shared Named Credential/OAuth service account — Client Credentials Flow
 * tokens do not create a session Salesforce's legacy SOAP session-validation layer recognizes
 * (INVALID_SESSION_ID, confirmed empirically — see memory-bank rondas 103/104).
 *
 * The outcome is also written to Data_Update_Form_Deploy_Job__c under the jobId the LWC passes
 * in, so the LWC can learn it by polling checkDeployStatus() — the page's postMessage never
 * reaches the parent when clickjack protection for headerless Visualforce pages is enabled
 * (the browser refuses to render the framed response, but this action has already run).
 */
public with sharing class DataUpdateFormDeleteVfController {

    public Boolean success { get; private set; }
    public String resultMessage { get; private set; }

    public DataUpdateFormDeleteVfController() {
        success = false;
        resultMessage = '';
    }

    public PageReference doDelete() {
        String formDeveloperName = ApexPages.currentPage().getParameters().get('formDeveloperName');
        String jobId = ApexPages.currentPage().getParameters().get('jobId');
        // The page runs its action on a plain GET, so it only deletes with the one-time token
        // Settings issued when the admin confirmed (DataUpdateFormAdminController.requestFormDelete)
        // — a bare link to this page deletes nothing.
        Data_Update_Form_Deploy_Job__c request = findDeleteRequest(jobId, formDeveloperName);
        if (request == null) {
            success = false;
            resultMessage = 'Delete not confirmed. Use the Delete button in Settings.';
            return null;
        }
        try {
            DataUpdateFormAdminController.deleteFormPermanently(formDeveloperName, UserInfo.getSessionId());
            success = true;
            resultMessage = 'Deleted ' + formDeveloperName + '.';
        } catch (Exception e) {
            success = false;
            resultMessage = e.getMessage();
        }
        recordOutcome(request);
        return null;
    }

    // Fresh (5 min), unused, issued to this same user for this same form.
    private static Data_Update_Form_Deploy_Job__c findDeleteRequest(String jobId, String formDeveloperName) {
        if (String.isBlank(jobId) || String.isBlank(formDeveloperName)) return null;
        Datetime oldest = Datetime.now().addMinutes(-5);
        Id userId = UserInfo.getUserId();
        String formName = formDeveloperName.left(100);
        List<Data_Update_Form_Deploy_Job__c> rows = [
            SELECT Id FROM Data_Update_Form_Deploy_Job__c
            WHERE Job_Id__c = :jobId
              AND Status__c = :DataUpdateFormAdminController.DELETE_REQUESTED
              AND Form_Developer_Name__c = :formName
              AND CreatedById = :userId
              AND CreatedDate >= :oldest
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    // Runs after the SOAP callouts, so this DML can't trigger "uncommitted work pending".
    // Also uses up the token: the row is no longer Delete Requested.
    private void recordOutcome(Data_Update_Form_Deploy_Job__c request) {
        request.Status__c = success ? 'Succeeded' : 'Failed';
        request.Error_Message__c = success ? null : resultMessage;
        update request;
    }
}
