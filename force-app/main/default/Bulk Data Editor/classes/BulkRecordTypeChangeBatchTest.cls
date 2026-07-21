@isTest
private class BulkRecordTypeChangeBatchTest {

    private static List<Schema.RecordTypeInfo> getActiveNonMasterRecordTypeInfos() {
        List<Schema.RecordTypeInfo> result = new List<Schema.RecordTypeInfo>();
        for (Schema.RecordTypeInfo info : Account.sObjectType.getDescribe().getRecordTypeInfos()) {
            if (info.isActive() && !info.isMaster()) {
                result.add(info);
            }
        }
        return result;
    }

    @TestSetup
    static void setup() {
        List<Schema.RecordTypeInfo> activeInfos = getActiveNonMasterRecordTypeInfos();
        System.assert(
            activeInfos.size() >= 2,
            'This test requires at least 2 active, non-Master Account Record Types in the org.'
        );

        Id rt1 = activeInfos[0].getRecordTypeId();

        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 5; i++) {
            accounts.add(new Account(Name = 'RTC Batch Test ' + i, RecordTypeId = rt1));
        }
        insert accounts;
    }

    private static Bulk_Edit_Log__c createLog(String oldDisplay, String newValue) {
        Bulk_Edit_Log__c logRec = new Bulk_Edit_Log__c(
            Object_Type__c = 'Account',
            Object_Label__c = 'Account',
            Field_API_Name__c = 'RecordTypeId',
            Field_Label__c = 'Record Type',
            Old_Value_Display__c = oldDisplay,
            New_Value__c = newValue,
            Status__c = 'Queued'
        );
        insert logRec;
        return logRec;
    }

    @isTest
    static void testBatchChangesRecordTypeAndCreatesSnapshots() {
        List<Schema.RecordTypeInfo> rts = getActiveNonMasterRecordTypeInfos();
        Id rt1 = rts[0].getRecordTypeId();
        Id rt2 = rts[1].getRecordTypeId();

        List<Account> accounts = [SELECT Id FROM Account WHERE Name LIKE 'RTC Batch Test%'];
        List<Id> ids = new List<Id>();
        for (Account a : accounts) {
            ids.add(a.Id);
        }
        // Trailing comma exercises the blank-segment skip in start().
        String csv = String.join(ids, ',') + ',';

        Bulk_Edit_Log__c logRec = createLog(rts[0].getName(), rts[1].getName());

        Test.startTest();
        Database.executeBatch(new BulkRecordTypeChangeBatch(logRec.Id, csv, rt2), 200);
        Test.stopTest();

        List<Account> updated = [SELECT RecordTypeId FROM Account WHERE Id IN :ids];
        System.assertEquals(5, updated.size());
        for (Account a : updated) {
            System.assertEquals(rt2, a.RecordTypeId);
        }

        List<Bulk_Edit_Snapshot__c> snapshots = [
            SELECT Old_Value__c, Record_Id__c FROM Bulk_Edit_Snapshot__c WHERE Bulk_Edit_Log__c = :logRec.Id
        ];
        System.assertEquals(5, snapshots.size());
        for (Bulk_Edit_Snapshot__c snap : snapshots) {
            System.assertEquals(String.valueOf(rt1), snap.Old_Value__c);
        }

        Bulk_Edit_Log__c refreshed = [SELECT Status__c, Records_Affected__c FROM Bulk_Edit_Log__c WHERE Id = :logRec.Id];
        System.assertEquals('Completed', refreshed.Status__c);
        System.assertEquals(5, refreshed.Records_Affected__c.intValue());
    }

    @isTest
    static void testBatchExecute_dmlFailure_appendsError() {
        Id rt2 = getActiveNonMasterRecordTypeInfos()[1].getRecordTypeId();

        Account acc = [SELECT Id FROM Account WHERE Name = 'RTC Batch Test 0' LIMIT 1];
        Id deletedId = acc.Id;
        delete acc;

        Bulk_Edit_Log__c logRec = createLog('Old', 'New');
        BulkRecordTypeChangeBatch batch = new BulkRecordTypeChangeBatch(logRec.Id, String.valueOf(deletedId), rt2);

        List<Account> scope = new List<Account>{ new Account(Id = deletedId) };
        batch.execute(null, scope);
        batch.finish(null);

        Bulk_Edit_Log__c refreshed = [SELECT Status__c, Error_Message__c FROM Bulk_Edit_Log__c WHERE Id = :logRec.Id];
        System.assertEquals('Failed', refreshed.Status__c);
        System.assert(refreshed.Error_Message__c.contains(String.valueOf(deletedId)));
    }

    @isTest
    static void testBatchAppendError_truncatesAtMaxLength() {
        BulkRecordTypeChangeBatch batch = new BulkRecordTypeChangeBatch(null, '', null);
        batch.errorLog = ''.rightPad(25000, 'X');
        batch.appendError('this should be dropped');
        System.assertEquals(25000, batch.errorLog.length(), 'Expected appendError to no-op once at the cap');
    }

    @isTest
    static void testUndoBatchRestoresOriginalRecordType() {
        List<Schema.RecordTypeInfo> rts = getActiveNonMasterRecordTypeInfos();
        Id rt1 = rts[0].getRecordTypeId();
        Id rt2 = rts[1].getRecordTypeId();

        List<Account> accounts = [SELECT Id FROM Account WHERE Name LIKE 'RTC Batch Test%'];
        List<Id> ids = new List<Id>();
        for (Account a : accounts) {
            ids.add(a.Id);
        }
        String csv = String.join(ids, ',');

        Bulk_Edit_Log__c logRec = createLog(rts[0].getName(), rts[1].getName());

        Test.startTest();
        Database.executeBatch(new BulkRecordTypeChangeBatch(logRec.Id, csv, rt2), 200);
        Test.stopTest();

        Bulk_Edit_Log__c afterChange = [SELECT Status__c FROM Bulk_Edit_Log__c WHERE Id = :logRec.Id];
        System.assertEquals('Completed', afterChange.Status__c);

        // Run the undo batch synchronously via direct method calls instead of
        // a second Database.executeBatch — only one startTest/stopTest pair
        // is allowed per test method, and ordering across two enqueued jobs
        // in the same window is not guaranteed (see BulkEditBatchTest).
        BulkEditUndoBatch undoBatch = new BulkEditUndoBatch(logRec.Id);
        undoBatch.start(null);
        List<Bulk_Edit_Snapshot__c> scope = [
            SELECT Id, Record_Id__c, Old_Value__c FROM Bulk_Edit_Snapshot__c WHERE Bulk_Edit_Log__c = :logRec.Id
        ];
        undoBatch.execute(null, scope);
        undoBatch.finish(null);

        List<Account> restored = [SELECT RecordTypeId FROM Account WHERE Id IN :ids];
        for (Account a : restored) {
            System.assertEquals(rt1, a.RecordTypeId);
        }

        Bulk_Edit_Log__c refreshed = [SELECT Status__c FROM Bulk_Edit_Log__c WHERE Id = :logRec.Id];
        System.assertEquals('Undone', refreshed.Status__c);
    }

    @isTest
    static void testServiceResolveFieldDescribe_allowsRecordTypeIdOnly() {
        Schema.SObjectType sType = BulkEditService.resolveObjectType('Account');

        Schema.DescribeFieldResult dfr = BulkEditService.resolveFieldDescribe(sType, 'RecordTypeId');
        System.assertEquals('RecordTypeId', dfr.getName());

        Boolean threw = false;
        try {
            BulkEditService.resolveFieldDescribe(sType, 'OwnerId');
        } catch (BulkEditException ex) {
            threw = true;
        }
        System.assert(threw, 'Expected another Reference field (OwnerId) to still be rejected');
    }
}
