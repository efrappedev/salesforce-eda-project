@isTest
private class BulkCleanFieldBatchTest {

    // U+202F (narrow no-break space, decimal 8239 — Apex Integer literals
    // don't support 0x hex notation) via String.fromCharArray, which avoids
    // embedding the literal invisible character directly in source, easy to
    // get wrong when transcribed instead of computed.
    private static String narrowNbsp() {
        return String.fromCharArray(new List<Integer>{ 8239 });
    }

    @TestSetup
    static void setup() {
        List<Account> accounts = new List<Account>();
        accounts.add(new Account(Name = 'Clean Batch 0', AccountNumber = '1' + narrowNbsp() + '799', Industry = 'Technology'));
        accounts.add(new Account(Name = 'Clean Batch 1', AccountNumber = '2' + narrowNbsp() + '345', Industry = 'Banking'));
        accounts.add(new Account(Name = 'Clean Batch 2', AccountNumber = 'ALREADY-CLEAN', Industry = 'Technology'));
        accounts.add(new Account(Name = 'Clean Batch 3', AccountNumber = null, Industry = 'Technology'));
        insert accounts;
    }

    private static Bulk_Edit_Log__c createLog() {
        Bulk_Edit_Log__c logRec = new Bulk_Edit_Log__c(
            Object_Type__c = 'Account',
            Object_Label__c = 'Account',
            Field_API_Name__c = 'AccountNumber',
            Field_Label__c = 'Account Number',
            Old_Value_Display__c = '(varies per record — auto-cleaned)',
            New_Value__c = 'Normalize spaces',
            Status__c = 'Queued'
        );
        insert logRec;
        return logRec;
    }

    @isTest
    static void testBatchCleansOnlyDirtyRecords_andCreatesSnapshots() {
        Bulk_Edit_Log__c logRec = createLog();

        Test.startTest();
        Database.executeBatch(new BulkCleanFieldBatch(logRec.Id, 'Account', 'AccountNumber', null, null, null, true, true, true, null), 200);
        Test.stopTest();

        Map<String, Account> byName = new Map<String, Account>();
        for (Account a : [SELECT Name, AccountNumber FROM Account]) {
            byName.put(a.Name, a);
        }
        System.assertEquals('1 799', byName.get('Clean Batch 0').AccountNumber);
        System.assertEquals('2 345', byName.get('Clean Batch 1').AccountNumber);
        System.assertEquals('ALREADY-CLEAN', byName.get('Clean Batch 2').AccountNumber, 'Already-clean value must be left untouched');

        // Records_Affected__c must count only the 2 records that actually
        // changed — not the 3 candidates scanned (blank AccountNumber is
        // excluded from candidacy entirely by the WHERE clause).
        Bulk_Edit_Log__c refreshed = [SELECT Status__c, Records_Affected__c FROM Bulk_Edit_Log__c WHERE Id = :logRec.Id];
        System.assertEquals('Completed', refreshed.Status__c);
        System.assertEquals(2, refreshed.Records_Affected__c.intValue());

        List<Bulk_Edit_Snapshot__c> snapshots = [SELECT Record_Id__c, Old_Value__c FROM Bulk_Edit_Snapshot__c WHERE Bulk_Edit_Log__c = :logRec.Id];
        System.assertEquals(2, snapshots.size(), 'Only the 2 changed records should have a snapshot');
        Set<String> oldValues = new Set<String>();
        for (Bulk_Edit_Snapshot__c snap : snapshots) {
            oldValues.add(snap.Old_Value__c);
        }
        System.assert(oldValues.contains('1' + narrowNbsp() + '799'));
        System.assert(oldValues.contains('2' + narrowNbsp() + '345'));
    }

    @isTest
    static void testBatchAppliesFilter() {
        Bulk_Edit_Log__c logRec = createLog();

        Test.startTest();
        Database.executeBatch(
            new BulkCleanFieldBatch(logRec.Id, 'Account', 'AccountNumber', 'Industry', 'Technology', false, true, true, true, null),
            200
        );
        Test.stopTest();

        Account cleaned = [SELECT AccountNumber FROM Account WHERE Name = 'Clean Batch 0'];
        System.assertEquals('1 799', cleaned.AccountNumber);

        Account stillDirty = [SELECT AccountNumber FROM Account WHERE Name = 'Clean Batch 1'];
        System.assertEquals('2' + narrowNbsp() + '345', stillDirty.AccountNumber, 'Banking record must be excluded by the Technology filter');
    }

    @isTest
    static void testBatchNoDirtyRecords_zeroAffectedNoSnapshots() {
        Bulk_Edit_Log__c logRec = createLog();

        Test.startTest();
        // Filter to a value with no matching records at all — every
        // candidate is excluded before cleanValue() even runs.
        Database.executeBatch(
            new BulkCleanFieldBatch(logRec.Id, 'Account', 'AccountNumber', 'Industry', 'No Such Industry', false, true, true, true, null),
            200
        );
        Test.stopTest();

        Bulk_Edit_Log__c refreshed = [SELECT Status__c, Records_Affected__c FROM Bulk_Edit_Log__c WHERE Id = :logRec.Id];
        System.assertEquals('Completed', refreshed.Status__c);
        System.assertEquals(0, refreshed.Records_Affected__c.intValue());

        List<Bulk_Edit_Snapshot__c> snapshots = [SELECT Id FROM Bulk_Edit_Snapshot__c WHERE Bulk_Edit_Log__c = :logRec.Id];
        System.assertEquals(0, snapshots.size());
    }

    @isTest
    static void testBatchExecute_dmlFailure_appendsError() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Clean Batch 0' LIMIT 1];
        Id deletedId = acc.Id;
        String dirtyValue = '1' + narrowNbsp() + '799';
        delete acc;

        Bulk_Edit_Log__c logRec = createLog();
        BulkCleanFieldBatch batch = new BulkCleanFieldBatch(logRec.Id, 'Account', 'AccountNumber', null, null, null, true, true, true, null);

        List<Account> scope = new List<Account>{ new Account(Id = deletedId, AccountNumber = dirtyValue) };
        batch.execute(null, scope);
        batch.finish(null);

        Bulk_Edit_Log__c refreshed = [SELECT Status__c, Error_Message__c FROM Bulk_Edit_Log__c WHERE Id = :logRec.Id];
        System.assertEquals('Failed', refreshed.Status__c);
        System.assert(refreshed.Error_Message__c.contains(String.valueOf(deletedId)));
    }

    @isTest
    static void testBatchExecute_emptyScopeAfterUnchangedSkip_noOp() {
        Bulk_Edit_Log__c logRec = createLog();
        BulkCleanFieldBatch batch = new BulkCleanFieldBatch(logRec.Id, 'Account', 'AccountNumber', null, null, null, true, true, true, null);

        List<Account> scope = new List<Account>{ new Account(Id = [SELECT Id FROM Account WHERE Name = 'Clean Batch 2' LIMIT 1].Id, AccountNumber = 'ALREADY-CLEAN') };
        batch.execute(null, scope);
        batch.finish(null);

        Bulk_Edit_Log__c refreshed = [SELECT Status__c, Records_Affected__c FROM Bulk_Edit_Log__c WHERE Id = :logRec.Id];
        System.assertEquals('Completed', refreshed.Status__c);
        System.assertEquals(0, refreshed.Records_Affected__c.intValue());
    }

    @isTest
    static void testBatchAppendError_truncatesAtMaxLength() {
        BulkCleanFieldBatch batch = new BulkCleanFieldBatch(null, 'Account', 'AccountNumber', null, null, null, true, true, true, null);
        batch.errorLog = ''.rightPad(25000, 'X');
        batch.appendError('this should be dropped');
        System.assertEquals(25000, batch.errorLog.length(), 'Expected appendError to no-op once at the cap');
    }

    @isTest
    static void testUndoRoundTrip_restoresOriginalDirtyValue() {
        Bulk_Edit_Log__c logRec = createLog();

        Test.startTest();
        Database.executeBatch(new BulkCleanFieldBatch(logRec.Id, 'Account', 'AccountNumber', null, null, null, true, true, true, null), 200);
        Test.stopTest();

        Bulk_Edit_Log__c afterClean = [SELECT Status__c FROM Bulk_Edit_Log__c WHERE Id = :logRec.Id];
        System.assertEquals('Completed', afterClean.Status__c);

        // See BulkEditBatchTest.testUndoBatchRestoresOriginalValues — direct
        // start()/execute()/finish() calls, since only one startTest/stopTest
        // pair is allowed per test method. BulkEditUndoBatch is unmodified.
        BulkEditUndoBatch undoBatch = new BulkEditUndoBatch(logRec.Id);
        undoBatch.start(null);
        List<Bulk_Edit_Snapshot__c> scope = [
            SELECT Id, Record_Id__c, Old_Value__c FROM Bulk_Edit_Snapshot__c WHERE Bulk_Edit_Log__c = :logRec.Id
        ];
        undoBatch.execute(null, scope);
        undoBatch.finish(null);

        Account restored = [SELECT AccountNumber FROM Account WHERE Name = 'Clean Batch 0'];
        System.assertEquals('1' + narrowNbsp() + '799', restored.AccountNumber);

        Bulk_Edit_Log__c refreshed = [SELECT Status__c FROM Bulk_Edit_Log__c WHERE Id = :logRec.Id];
        System.assertEquals('Undone', refreshed.Status__c);
    }
}
