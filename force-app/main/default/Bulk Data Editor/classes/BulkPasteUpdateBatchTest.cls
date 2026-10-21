@isTest
private class BulkPasteUpdateBatchTest {

    @TestSetup
    static void setup() {
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 5; i++) {
            accounts.add(new Account(Name = 'PUB Account ' + i, AccountNumber = 'PUB-' + i, Site = 'Old Site ' + i));
        }
        insert accounts;
    }

    private static Bulk_Edit_Log__c createLog(String fieldApi, String searchFieldLabel, String summary) {
        Bulk_Edit_Log__c logRec = new Bulk_Edit_Log__c(
            Object_Type__c = 'Account',
            Object_Label__c = 'Account',
            Field_API_Name__c = fieldApi,
            Field_Label__c = fieldApi,
            Old_Value_Display__c = '(varies per record — matched by ' + searchFieldLabel + ')',
            New_Value__c = summary,
            Status__c = 'Queued'
        );
        insert logRec;
        return logRec;
    }

    @isTest
    static void testBatchUpdatesRecordsWithDistinctValuesAndCreatesSnapshots() {
        List<Account> accts = [SELECT Id FROM Account ORDER BY Name];
        Map<String, String> newValueByRecordId = new Map<String, String>();
        Integer i = 0;
        for (Account a : accts) {
            newValueByRecordId.put(String.valueOf(a.Id), 'New Site ' + i);
            i++;
        }

        Bulk_Edit_Log__c logRec = createLog('Site', 'Account Number', 'AccountNumber list');

        Test.startTest();
        Database.executeBatch(new BulkPasteUpdateBatch(logRec.Id, 'Account', 'Site', newValueByRecordId), 200);
        Test.stopTest();

        Map<Id, Account> updated = new Map<Id, Account>([SELECT Id, Site FROM Account WHERE Id IN :newValueByRecordId.keySet()]);
        for (Id recId : newValueByRecordId.keySet()) {
            System.assertEquals(newValueByRecordId.get(recId), updated.get(recId).Site);
        }

        List<Bulk_Edit_Snapshot__c> snapshots = [SELECT Old_Value__c, Record_Id__c FROM Bulk_Edit_Snapshot__c WHERE Bulk_Edit_Log__c = :logRec.Id];
        System.assertEquals(5, snapshots.size());

        Bulk_Edit_Log__c refreshed = [SELECT Status__c, Records_Affected__c FROM Bulk_Edit_Log__c WHERE Id = :logRec.Id];
        System.assertEquals('Completed', refreshed.Status__c);
        System.assertEquals(5, refreshed.Records_Affected__c.intValue());
    }

    @isTest
    static void testBatchBlankValueClearsField() {
        List<Account> accts = [SELECT Id FROM Account ORDER BY Name];
        Map<String, String> newValueByRecordId = new Map<String, String>();
        for (Account a : accts) {
            newValueByRecordId.put(String.valueOf(a.Id), '');
        }

        Bulk_Edit_Log__c logRec = createLog('Site', 'Account Number', 'blank run');

        Test.startTest();
        Database.executeBatch(new BulkPasteUpdateBatch(logRec.Id, 'Account', 'Site', newValueByRecordId), 200);
        Test.stopTest();

        List<Account> updated = [SELECT Site FROM Account WHERE Id IN :newValueByRecordId.keySet()];
        for (Account a : updated) {
            System.assertEquals(null, a.Site);
        }
    }

    @isTest
    static void testBatchExecute_dmlFailure_appendsError() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'PUB Account 0' LIMIT 1];
        Id deletedId = acc.Id;
        delete acc;

        Bulk_Edit_Log__c logRec = createLog('Site', 'Account Number', 'x');
        Map<String, String> newValueByRecordId = new Map<String, String>{ String.valueOf(deletedId) => 'New Site' };
        BulkPasteUpdateBatch batch = new BulkPasteUpdateBatch(logRec.Id, 'Account', 'Site', newValueByRecordId);

        List<Account> scope = new List<Account>{ new Account(Id = deletedId, Site = 'Old Site 0') };
        batch.execute(null, scope);
        batch.finish(null);

        Bulk_Edit_Log__c refreshed = [SELECT Status__c, Error_Message__c FROM Bulk_Edit_Log__c WHERE Id = :logRec.Id];
        System.assertEquals('Failed', refreshed.Status__c);
        System.assert(refreshed.Error_Message__c.contains(String.valueOf(deletedId)));
    }

    @isTest
    static void testBatchAppendError_truncatesAtMaxLength() {
        BulkPasteUpdateBatch batch = new BulkPasteUpdateBatch(null, 'Account', 'Site', new Map<String, String>());
        batch.errorLog = ''.rightPad(25000, 'X');
        batch.appendError('this should be dropped');
        System.assertEquals(25000, batch.errorLog.length(), 'Expected appendError to no-op once at the cap');
    }

    @isTest
    static void testUndoRoundTrip_restoresOriginalValues() {
        List<Account> accts = [SELECT Id, Site FROM Account ORDER BY Name];
        Map<String, String> originalByRecordId = new Map<String, String>();
        Map<String, String> newValueByRecordId = new Map<String, String>();
        Integer i = 0;
        for (Account a : accts) {
            originalByRecordId.put(String.valueOf(a.Id), a.Site);
            newValueByRecordId.put(String.valueOf(a.Id), 'Changed Site ' + i);
            i++;
        }

        Bulk_Edit_Log__c logRec = createLog('Site', 'Account Number', 'undo round trip');

        Test.startTest();
        Database.executeBatch(new BulkPasteUpdateBatch(logRec.Id, 'Account', 'Site', newValueByRecordId), 200);
        Test.stopTest();

        Bulk_Edit_Log__c afterEdit = [SELECT Status__c FROM Bulk_Edit_Log__c WHERE Id = :logRec.Id];
        System.assertEquals('Completed', afterEdit.Status__c);

        // See BulkEditBatchTest.testUndoBatchRestoresOriginalValues — direct
        // start()/execute()/finish() calls, since only one startTest/stopTest
        // pair is allowed per test method. BulkEditUndoBatch is unmodified
        // and only needs Bulk_Edit_Snapshot__c.Old_Value__c plus the log's
        // Object_Type__c/Field_API_Name__c, so it works for this new mode
        // exactly as it already does for value-edit and Record Type Change.
        BulkEditUndoBatch undoBatch = new BulkEditUndoBatch(logRec.Id);
        undoBatch.start(null);
        List<Bulk_Edit_Snapshot__c> scope = [
            SELECT Id, Record_Id__c, Old_Value__c FROM Bulk_Edit_Snapshot__c WHERE Bulk_Edit_Log__c = :logRec.Id
        ];
        undoBatch.execute(null, scope);
        undoBatch.finish(null);

        Map<Id, Account> restored = new Map<Id, Account>([SELECT Id, Site FROM Account WHERE Id IN :originalByRecordId.keySet()]);
        for (Id recId : originalByRecordId.keySet()) {
            System.assertEquals(originalByRecordId.get(recId), restored.get(recId).Site);
        }

        Bulk_Edit_Log__c refreshed = [SELECT Status__c FROM Bulk_Edit_Log__c WHERE Id = :logRec.Id];
        System.assertEquals('Undone', refreshed.Status__c);
    }
}
