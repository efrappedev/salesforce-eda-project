/**
 * DataUpdateFormDeleteVfControllerTest.cls
 * The hidden DataUpdateFormDelete page's action: success and failure both land in
 * success/resultMessage instead of escaping as an exception.
 */
@IsTest
private class DataUpdateFormDeleteVfControllerTest {

    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"><soapenv:Body>'
                + '<deleteMetadataResponse><result><fullName>X</fullName><success>true</success></result>'
                + '</deleteMetadataResponse></soapenv:Body></soapenv:Envelope>');
            return res;
        }
    }

    private static User deleter() {
        User usr;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            String U = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
            usr = new User(
                ProfileId = UserInfo.getProfileId(),
                Username = 'dud' + U + '@example.com.test',
                Email = 'dud' + U + '@example.com',
                LastName = 'DataUpdateDelete', Alias = 'dudt',
                TimeZoneSidKey = 'America/Toronto', LocaleSidKey = 'fr_CA',
                EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
            );
            insert usr;
            insert new PermissionSetAssignment(
                AssigneeId = usr.Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Data_Update_Center_Delete_Access' LIMIT 1].Id
            );
        }
        return usr;
    }

    private static DataUpdateFormDeleteVfController openPage(String formDeveloperName) {
        return openPage(formDeveloperName, null);
    }

    private static DataUpdateFormDeleteVfController openPage(String formDeveloperName, String jobId) {
        PageReference pr = Page.DataUpdateFormDelete;
        pr.getParameters().put('formDeveloperName', formDeveloperName);
        if (jobId != null) pr.getParameters().put('jobId', jobId);
        Test.setCurrentPage(pr);
        return new DataUpdateFormDeleteVfController();
    }

    @IsTest
    static void doDelete_Success() {
        User usr = deleter();
        String token;
        // The token row is DML: issued before startTest so the callout below is allowed.
        System.runAs(usr) {
            token = DataUpdateFormAdminController.requestFormDelete('Fake_Vf_Form');
        }
        Test.startTest();
        System.runAs(usr) {
            DataUpdateFormAdminController.testFormMdt = (Data_Update_Form__mdt) JSON.deserialize(
                '{"DeveloperName":"Fake_Vf_Form","Is_Core_Form__c":false}', Data_Update_Form__mdt.class);
            Test.setMock(HttpCalloutMock.class, new SuccessMock());

            DataUpdateFormDeleteVfController ctrl = openPage('Fake_Vf_Form', token);
            System.assertEquals(false, ctrl.success);
            System.assertEquals(null, ctrl.doDelete());
            System.assertEquals(true, ctrl.success, ctrl.resultMessage);
            System.assertEquals('Deleted Fake_Vf_Form.', ctrl.resultMessage);
        }
        Test.stopTest();

        // Polling fallback for when clickjack protection blocks the iframe's postMessage
        DataUpdateWrapper.DeployStatusResult r = DataUpdateFormAdminController.checkDeployStatus(token);
        System.assertEquals(true, r.done);
        System.assertEquals('Succeeded', r.status);
        System.assertEquals('Fake_Vf_Form', r.formDeveloperName);
    }

    @IsTest
    static void doDelete_WithoutTokenDeletesNothing() {
        User usr = deleter();
        System.runAs(usr) {
            DataUpdateFormAdminController.testFormMdt = (Data_Update_Form__mdt) JSON.deserialize(
                '{"DeveloperName":"Fake_Vf_Form","Is_Core_Form__c":false}', Data_Update_Form__mdt.class);
            String otherFormToken = DataUpdateFormAdminController.requestFormDelete('Other_Form');

            // A forged link, a link without jobId, and a token issued for another form.
            for (DataUpdateFormDeleteVfController ctrl : new List<DataUpdateFormDeleteVfController>{
                    openPage('Fake_Vf_Form', 'del-forged'), openPage('Fake_Vf_Form'), openPage('Fake_Vf_Form', otherFormToken) }) {
                ctrl.doDelete();
                System.assertEquals(false, ctrl.success);
                System.assert(ctrl.resultMessage.contains('not confirmed'), ctrl.resultMessage);
            }
            // The other form's token is still unused.
            System.assertEquals(false, DataUpdateFormAdminController.checkDeployStatus(otherFormToken).done);
        }
    }

    @IsTest
    static void requestFormDelete_NeedsPermission() {
        Boolean refused = false;
        try {
            DataUpdateFormAdminController.requestFormDelete('Fake_Vf_Form');
        } catch (AuraHandledException e) {
            refused = true;
        }
        System.assertEquals(!FeatureManagement.checkPermission('Data_Update_Delete_Forms'), refused);
    }

    @IsTest
    static void doDelete_CoreFormFailsGracefully() {
        User usr = deleter();
        System.runAs(usr) {
            String token = DataUpdateFormAdminController.requestFormDelete('AEBEQ_Account_Update');
            DataUpdateFormDeleteVfController ctrl = openPage('AEBEQ_Account_Update', token);
            ctrl.doDelete();
            System.assertEquals(false, ctrl.success);
            System.assert(ctrl.resultMessage.contains('core form'), ctrl.resultMessage);

            DataUpdateWrapper.DeployStatusResult r = DataUpdateFormAdminController.checkDeployStatus(token);
            System.assertEquals('Failed', r.status);
            System.assert(r.errorMessage.contains('core form'), r.errorMessage);
        }
    }
}
