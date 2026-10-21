/**
 * DataUpdateFormAdminDeployCallback.cls
 * Required constructor argument for Metadata.Operations.enqueueDeployment(). There is no
 * synchronous "checkDeployStatus" on Metadata.Operations for this async CMDT deploy path —
 * this callback firing is the ONLY signal Salesforce gives that the job is done, so it
 * persists the outcome to Data_Update_Form_Deploy_Job__c for
 * DataUpdateFormAdminController.checkDeployStatus() to poll, and clears the Platform Cache
 * entry for the affected form the moment a Settings-screen change actually lands.
 *
 * jobId is NOT the id Metadata.Operations.enqueueDeployment() returns to the caller — it's a
 * correlation token DataUpdateFormAdminController.deploy() generates and assigns to this
 * callback BEFORE calling enqueueDeployment(), then also returns to the LWC to poll with.
 * That "before" is load-bearing: Salesforce serializes this callback instance's state at the
 * moment enqueueDeployment() is called, not at transaction end, so a field only assigned AFTER
 * that call (empirically tried: the real enqueueDeployment() return value) is silently lost by
 * the time handleResult() runs later. And that real return value can't be used as the poll key
 * anyway — it was empirically observed to differ from context.getCallbackJobId() (a "0Af..."
 * id vs. a "707..." id), so the two ends could never agree on one id. Our own pre-assigned
 * token sidesteps both problems.
 */
public class DataUpdateFormAdminDeployCallback implements Metadata.DeployCallback {
    public String jobId;
    public String formDeveloperName;
    // The publish lock this deploy holds (see DataUpdateFormAdminController "Publish lock").
    public Datetime lockStamp;

    public void handleResult(Metadata.DeployResult result, Metadata.DeployCallbackContext context) {
        String effectiveJobId = String.isNotBlank(jobId) ? jobId : context.getCallbackJobId();
        String status = (result != null && result.status != null) ? result.status.name() : 'Unknown';
        String errorMessage = null;

        if (result != null && result.status == Metadata.DeployStatus.Failed
                && result.details != null && result.details.componentFailures != null) {
            List<String> msgs = new List<String>();
            for (Metadata.DeployMessage dm : result.details.componentFailures) {
                msgs.add(dm.fullName + ': ' + dm.problem);
            }
            errorMessage = String.join(msgs, ' | ');
        }

        List<Data_Update_Form_Deploy_Job__c> existing = [
            SELECT Id, Form_Developer_Name__c
            FROM Data_Update_Form_Deploy_Job__c
            WHERE Job_Id__c = :effectiveJobId
            LIMIT 1
        ];
        Data_Update_Form_Deploy_Job__c job = !existing.isEmpty()
            ? existing[0]
            : new Data_Update_Form_Deploy_Job__c(Job_Id__c = effectiveJobId);
        job.Status__c = status;
        job.Error_Message__c = errorMessage;
        if (String.isBlank(job.Form_Developer_Name__c) && String.isNotBlank(formDeveloperName)) {
            job.Form_Developer_Name__c = formDeveloperName;
        }
        upsert job;
        DataUpdateFormAdminController.releasePublishLockAfterDeploy(lockStamp);

        if (status == 'Succeeded' && String.isNotBlank(job.Form_Developer_Name__c)) {
            DataUpdateFormConfigService.clearCache(job.Form_Developer_Name__c);
        }
    }
}
