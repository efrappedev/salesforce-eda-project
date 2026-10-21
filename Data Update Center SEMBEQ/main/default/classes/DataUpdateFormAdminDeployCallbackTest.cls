/**
 * DataUpdateFormAdminDeployCallbackTest.cls
 * Calls handleResult() directly with hand-built DeployResults — the real callback only fires
 * after an actual async metadata deploy, which tests cannot trigger.
 */
@IsTest
private class DataUpdateFormAdminDeployCallbackTest {

    private class TestContext extends Metadata.DeployCallbackContext {
        private Id jobId;
        TestContext(Id jobId) {
            this.jobId = jobId;
        }
        public override Id getCallbackJobId() {
            return jobId;
        }
    }

    private static Data_Update_Form_Deploy_Job__c jobFor(String jobId) {
        return [
            SELECT Status__c, Error_Message__c, Form_Developer_Name__c
            FROM Data_Update_Form_Deploy_Job__c
            WHERE Job_Id__c = :jobId
        ];
    }

    @IsTest
    static void succeeded_CreatesJobRowWithForm() {
        DataUpdateFormAdminDeployCallback cb = new DataUpdateFormAdminDeployCallback();
        cb.jobId = 'corr-success';
        cb.formDeveloperName = 'SEMBEQ_Contact_Update';
        Metadata.DeployResult result = new Metadata.DeployResult();
        result.status = Metadata.DeployStatus.Succeeded;

        cb.handleResult(result, new TestContext('0Af000000000001AAA'));

        Data_Update_Form_Deploy_Job__c job = jobFor('corr-success');
        System.assertEquals('Succeeded', job.Status__c);
        System.assertEquals(null, job.Error_Message__c);
        System.assertEquals('SEMBEQ_Contact_Update', job.Form_Developer_Name__c);
    }

    @IsTest
    static void failed_UpdatesExistingRowWithComponentErrors() {
        insert new Data_Update_Form_Deploy_Job__c(Job_Id__c = 'corr-failed', Status__c = 'Pending',
            Form_Developer_Name__c = 'Kept_Form');

        Metadata.DeployMessage msg = new Metadata.DeployMessage();
        msg.fullName = 'Data_Update_Form_Field__mdt.Bad';
        msg.problem = 'Field is invalid';
        Metadata.DeployDetails details = new Metadata.DeployDetails();
        details.componentFailures = new List<Metadata.DeployMessage>{ msg };
        Metadata.DeployResult result = new Metadata.DeployResult();
        result.status = Metadata.DeployStatus.Failed;
        result.details = details;

        DataUpdateFormAdminDeployCallback cb = new DataUpdateFormAdminDeployCallback();
        cb.jobId = 'corr-failed';
        cb.formDeveloperName = 'Other_Form';
        cb.handleResult(result, new TestContext('0Af000000000002AAA'));

        Data_Update_Form_Deploy_Job__c job = jobFor('corr-failed');
        System.assertEquals('Failed', job.Status__c);
        System.assertEquals('Data_Update_Form_Field__mdt.Bad: Field is invalid', job.Error_Message__c);
        System.assertEquals('Kept_Form', job.Form_Developer_Name__c, 'Existing form name is not overwritten');
    }

    @IsTest
    static void nullResultWithoutToken_FallsBackToContextJobId() {
        DataUpdateFormAdminDeployCallback cb = new DataUpdateFormAdminDeployCallback();
        cb.handleResult(null, new TestContext('0Af000000000003AAA'));

        Data_Update_Form_Deploy_Job__c job = jobFor('0Af000000000003AAA');
        System.assertEquals('Unknown', job.Status__c);
        System.assertEquals(null, job.Form_Developer_Name__c);
    }
}
