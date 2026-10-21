@IsTest(SeeAllData=false)
private class DataUpdateAuditServiceTest {

    private static final String FORM_NAME = 'SEMBEQ_Contact_Update';

    private static String uniq() {
        return String.valueOf(DateTime.now().getTime()) + String.valueOf(Crypto.getRandomInteger());
    }

    private static void applyDupBypass(Database.DMLOptions dmo) {
        dmo.DuplicateRuleHeader.allowSave = true;
        dmo.DuplicateRuleHeader.runAsCurrentUser = true;
    }

    private static Contact insertResilient(Contact a) {
        Database.DMLOptions dmo = new Database.DMLOptions();
        applyDupBypass(dmo);
        Database.SaveResult sr = Database.insert(new List<SObject>{ a }, dmo)[0];
        System.assert(sr.isSuccess(), 'Insert failed: ' +
            (sr.getErrors().isEmpty() ? 'unknown' : sr.getErrors()[0].getMessage()));
        a.Id = sr.getId();
        return a;
    }

    private static Contact createTestContact(String lastName, String firstName) {
        Contact a = new Contact(LastName = lastName, FirstName = firstName);
        a.put('Alternative_Email_1__c', 'audit' + uniq() + '@example.com');
        return insertResilient(a);
    }

    private static String getEmail(SObject rec) {
        return (String) rec.get('Alternative_Email_1__c');
    }

    private static Contact queryContactWithEmail(Id recId) {
        return (Contact) Database.query('SELECT Id, Alternative_Email_1__c FROM Contact WHERE Id = :recId LIMIT 1');
    }

    private static Data_Update_Request__c createRequest(Id accountId) {
        Data_Update_Request__c t = new Data_Update_Request__c(
            Target_Object_API_Name__c = 'Contact',
            Target_Record_Id__c = accountId,
            Update_Form_DeveloperName__c = FORM_NAME,
            Status__c = 'New',
            Subject__c = 'Audit test ' + uniq()
        );
        insert t;
        return t;
    }

    @IsTest
    static void createSubmitLog_Success_CapturesBeforeSnapshotAndLinksRequest() {
        String U = uniq();
        Contact a = createTestContact('Audit' + U, 'Before');
        a = queryContactWithEmail(a.Id);
        Data_Update_Request__c t = createRequest(a.Id);

        Test.startTest();
        Data_Update_Log__c log = DataUpdateAuditService.createSubmitLog(t.Id, 'Contact', a.Id, a);
        Test.stopTest();

        System.assertNotEquals(null, log.Id);
        Data_Update_Log__c saved = [
            SELECT Request__c, Action_Type__c, Target_Object_API_Name__c, Target_Record_Id__c, Before_Snapshot_JSON__c
            FROM Data_Update_Log__c WHERE Id = :log.Id LIMIT 1
        ];
        System.assertEquals(t.Id, saved.Request__c);
        System.assertEquals('SUBMIT_PENDING', saved.Action_Type__c);
        System.assertEquals('Contact', saved.Target_Object_API_Name__c);
        System.assertEquals(a.Id, Id.valueOf(saved.Target_Record_Id__c));
        System.assert(saved.Before_Snapshot_JSON__c.contains(getEmail(a)));
    }

    @IsTest
    static void recordApplySuccess_Success_SealsLogWithAfterSnapshotAndDiff() {
        String U = uniq();
        Contact a = createTestContact('Audit' + U, 'After');
        Contact before = queryContactWithEmail(a.Id);
        Data_Update_Request__c t = createRequest(a.Id);
        Data_Update_Log__c log = DataUpdateAuditService.createSubmitLog(t.Id, 'Contact', a.Id, before);

        String newEmail = 'sealed' + U + '@example.com';
        a.put('Alternative_Email_1__c', newEmail);
        update a;
        Contact after = queryContactWithEmail(a.Id);

        Test.startTest();
        DataUpdateAuditService.recordApplySuccess(log.Id, after, new Map<String, Object>{ 'Alternative_Email_1__c' => newEmail });
        Test.stopTest();

        Data_Update_Log__c sealed = [
            SELECT Action_Type__c, After_Snapshot_JSON__c, Field_Decisions_JSON__c
            FROM Data_Update_Log__c WHERE Id = :log.Id LIMIT 1
        ];
        System.assertEquals('APPLY_COMPLETED', sealed.Action_Type__c);
        System.assert(sealed.After_Snapshot_JSON__c.contains(newEmail));
        Map<String, Object> decisions = (Map<String, Object>) JSON.deserializeUntyped(sealed.Field_Decisions_JSON__c);
        System.assert(decisions.containsKey('Alternative_Email_1__c'));
    }

    @IsTest
    static void recordApplyError_Success_MarksLogAndRequestError() {
        String U = uniq();
        Contact a = createTestContact('Audit' + U, 'Error');
        Data_Update_Request__c t = createRequest(a.Id);
        Data_Update_Log__c log = DataUpdateAuditService.createSubmitLog(t.Id, 'Contact', a.Id, a);

        Test.startTest();
        DataUpdateAuditService.recordApplyError(log.Id, t.Id, 'Something went wrong during apply');
        Test.stopTest();

        Data_Update_Log__c erroredLog = [SELECT Action_Type__c FROM Data_Update_Log__c WHERE Id = :log.Id LIMIT 1];
        System.assertEquals('APPLY_ERROR', erroredLog.Action_Type__c);

        Data_Update_Request__c erroredRequest = [SELECT Status__c, Error_Message__c FROM Data_Update_Request__c WHERE Id = :t.Id LIMIT 1];
        System.assertEquals('Error', erroredRequest.Status__c);
        System.assertEquals('Something went wrong during apply', erroredRequest.Error_Message__c);
    }

    @IsTest
    static void recordApplyError_NullLogId_OnlyUpdatesRequest() {
        String U = uniq();
        Contact a = createTestContact('Audit' + U, 'NullLog');
        Data_Update_Request__c t = createRequest(a.Id);

        Test.startTest();
        DataUpdateAuditService.recordApplyError(null, t.Id, 'Request-only error');
        Test.stopTest();

        Data_Update_Request__c erroredRequest = [SELECT Status__c, Error_Message__c FROM Data_Update_Request__c WHERE Id = :t.Id LIMIT 1];
        System.assertEquals('Error', erroredRequest.Status__c);
        System.assertEquals('Request-only error', erroredRequest.Error_Message__c);
    }

    @IsTest
    static void recordApplyError_NullRequestId_OnlyUpdatesLog() {
        String U = uniq();
        Contact a = createTestContact('Audit' + U, 'NullRequest');
        Data_Update_Request__c t = createRequest(a.Id);
        Data_Update_Log__c log = DataUpdateAuditService.createSubmitLog(t.Id, 'Contact', a.Id, a);

        Test.startTest();
        DataUpdateAuditService.recordApplyError(log.Id, null, 'Log-only error');
        Test.stopTest();

        Data_Update_Log__c erroredLog = [SELECT Action_Type__c FROM Data_Update_Log__c WHERE Id = :log.Id LIMIT 1];
        System.assertEquals('APPLY_ERROR', erroredLog.Action_Type__c);
    }

    @IsTest
    static void recordRollback_InsertsCompletedLogWithDecisions() {
        String U = uniq();
        Contact a = createTestContact('Rollback' + U, 'Test');
        Data_Update_Request__c t = createRequest(a.Id);
        Contact before = queryContactWithEmail(a.Id);
        Contact after  = before.clone(true, true, true, true);
        after.put('Alternative_Email_1__c', 'restored' + U + '@example.com');

        Test.startTest();
        DataUpdateAuditService.recordRollback(t.Id, 'Contact', a.Id, before, after,
            new Map<String, Object>{ 'Alternative_Email_1__c' => 'restored' + U + '@example.com' });
        Test.stopTest();

        Data_Update_Log__c log = [
            SELECT Action_Type__c, Field_Decisions_JSON__c FROM Data_Update_Log__c
            WHERE Request__c = :t.Id AND Action_Type__c = 'ROLLBACK_COMPLETED' LIMIT 1
        ];
        System.assert(log.Field_Decisions_JSON__c.contains('Alternative_Email_1__c'));
    }

    @IsTest
    static void snapshotService_BulkAndUnknownObject() {
        String U = uniq();
        Contact a = createTestContact('Bulk' + U, 'Snap');
        List<SObject> recs = new List<SObject>{ queryContactWithEmail(a.Id) };

        Test.startTest();
        Map<String, Map<String, Object>> bulkSnaps = DataUpdateSnapshotService.captureSnapshotsBulk(recs);
        String bulkJson = DataUpdateSnapshotService.serializeBulkSnapshots(recs);
        Map<String, Schema.SObjectField> none = DataUpdateSnapshotService.getDescribeMap('Nope_Not_An_Object__c');
        Test.stopTest();

        System.assert(bulkSnaps.containsKey(String.valueOf(a.Id)));
        System.assert(bulkJson.contains(String.valueOf(a.Id)));
        System.assert(none.isEmpty());
    }
}
