@isTest
private class BulkEditControllerTest {

    @TestSetup
    static void setup() {
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 12; i++) {
            accounts.add(new Account(
                Name = 'BDE Test Account ' + i,
                AccountNumber = (i < 10) ? 'OLD-VALUE' : null,
                Industry = (Math.mod(i, 2) == 0) ? 'Technology' : 'Banking',
                AnnualRevenue = 1000
            ));
        }
        insert accounts;
    }

    @isTest
    static void testGetEditableObjects() {
        Test.startTest();
        List<BulkEditWrappers.ObjectOption> options = BulkEditController.getEditableObjects();
        Test.stopTest();

        Set<String> apiNames = new Set<String>();
        for (BulkEditWrappers.ObjectOption opt : options) {
            apiNames.add(opt.apiName);
        }
        System.assert(apiNames.contains('Account'), 'Account should be an editable object');
        System.assert(!apiNames.contains('User'), 'User must be blacklisted');
        System.assert(!apiNames.contains('Bulk_Edit_Log__c'), 'Bulk_Edit_Log__c must be self-excluded');
    }

    @isTest
    static void testGetEditableFields() {
        Test.startTest();
        List<BulkEditWrappers.FieldOption> fields = BulkEditController.getEditableFields('Account');
        Test.stopTest();

        Set<String> apiNames = new Set<String>();
        for (BulkEditWrappers.FieldOption f : fields) {
            apiNames.add(f.apiName);
        }
        System.assert(apiNames.contains('AccountNumber'), 'AccountNumber should be editable');
        System.assert(apiNames.contains('Industry'), 'Industry should be editable');
        System.assert(!apiNames.contains('Id'), 'Id must never be offered');
        System.assert(!apiNames.contains('OwnerId'), 'OwnerId must never be offered');
    }

    @isTest
    static void testGetEditableFields_blacklistedObject() {
        Boolean threw = false;
        try {
            BulkEditController.getEditableFields('User');
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Expected an exception for a blacklisted object');
    }

    @isTest
    static void testGetValueDistribution() {
        Test.startTest();
        BulkEditWrappers.ValueDistributionResult result = BulkEditController.getValueDistribution('Account', 'AccountNumber', null, null, null);
        Test.stopTest();

        System.assertEquals(12, result.totalRecords);
        System.assert(!result.buckets.isEmpty());

        Boolean foundBlank = false;
        Boolean foundOld = false;
        for (BulkEditWrappers.ValueBucket bucket : result.buckets) {
            if (bucket.isBlank) {
                foundBlank = true;
            }
            if (bucket.rawValue == 'OLD-VALUE') {
                foundOld = true;
                System.assertEquals(10, bucket.recordCount);
            }
        }
        System.assert(foundBlank, 'Expected a blank bucket');
        System.assert(foundOld, 'Expected the OLD-VALUE bucket');
    }

    @isTest
    static void testGetValueDistribution_withFilter() {
        // Setup: Technology accounts are i=0,2,4,6,8,10 -> 5 with
        // AccountNumber='OLD-VALUE' and 1 blank (i=10).
        Test.startTest();
        BulkEditWrappers.ValueDistributionResult result =
            BulkEditController.getValueDistribution('Account', 'AccountNumber', 'Industry', 'Technology', false);
        Test.stopTest();

        System.assertEquals(6, result.totalRecords);
        Boolean foundBlank = false;
        Boolean foundOld = false;
        for (BulkEditWrappers.ValueBucket bucket : result.buckets) {
            if (bucket.isBlank) {
                foundBlank = true;
                System.assertEquals(1, bucket.recordCount);
            }
            if (bucket.rawValue == 'OLD-VALUE') {
                foundOld = true;
                System.assertEquals(5, bucket.recordCount);
            }
        }
        System.assert(foundBlank, 'Expected a blank bucket restricted to Technology accounts');
        System.assert(foundOld, 'Expected the OLD-VALUE bucket restricted to Technology accounts');
    }

    @isTest
    static void testGetFilterableFields() {
        Test.startTest();
        List<BulkEditWrappers.FieldOption> fields = BulkEditController.getFilterableFields('Account', 'AccountNumber');
        Test.stopTest();

        Set<String> apiNames = new Set<String>();
        for (BulkEditWrappers.FieldOption f : fields) {
            apiNames.add(f.apiName);
        }
        System.assert(!apiNames.contains('AccountNumber'), 'The excluded field must not be offered as a filter');
        System.assert(apiNames.contains('Industry'), 'Industry should be offered as a filter field');
    }

    @isTest
    static void testGetFilterFieldValueDistribution() {
        Test.startTest();
        BulkEditWrappers.ValueDistributionResult result = BulkEditController.getFilterFieldValueDistribution('Account', 'Industry');
        Test.stopTest();

        System.assertEquals(12, result.totalRecords);
        Boolean foundTechnology = false;
        for (BulkEditWrappers.ValueBucket bucket : result.buckets) {
            if (bucket.rawValue == 'Technology') {
                foundTechnology = true;
                System.assertEquals(6, bucket.recordCount);
            }
        }
        System.assert(foundTechnology, 'Expected a Technology bucket');
    }

    @isTest
    static void testGetPicklistValues() {
        Test.startTest();
        List<String> values = BulkEditController.getPicklistValues('Account', 'Industry');
        Test.stopTest();

        System.assert(!values.isEmpty(), 'Industry should have active picklist values');
    }

    @isTest
    static void testGetPicklistValues_nonPicklistField() {
        Test.startTest();
        List<String> values = BulkEditController.getPicklistValues('Account', 'AccountNumber');
        Test.stopTest();

        System.assertEquals(0, values.size());
    }

    @isTest
    static void testPreviewCount() {
        Test.startTest();
        Integer countWithValue = BulkEditController.previewCount('Account', 'AccountNumber', 'OLD-VALUE', false);
        Integer countBlank = BulkEditController.previewCount('Account', 'AccountNumber', null, true);
        Test.stopTest();

        System.assertEquals(10, countWithValue);
        System.assertEquals(2, countBlank);
    }

    @isTest
    static void testStartBulkEdit_jobStatusAndHistory() {
        Test.startTest();
        BulkEditWrappers.BulkEditJobResult jobResult = BulkEditController.startBulkEdit(
            'Account', 'AccountNumber', 'Account', 'Account Number',
            'OLD-VALUE', false, 'NEW-VALUE', false,
            null, null, null, null
        );
        Test.stopTest();

        System.assertNotEquals(null, jobResult.logId);
        System.assertNotEquals(null, jobResult.batchJobId);

        List<Account> updated = [SELECT AccountNumber FROM Account WHERE AccountNumber = 'NEW-VALUE'];
        System.assertEquals(10, updated.size());

        BulkEditWrappers.JobStatusResult status = BulkEditController.getJobStatus(jobResult.logId);
        System.assertEquals('Completed', status.status);
        System.assertEquals(10, status.recordsAffected);
        System.assert(status.canUndo);

        List<BulkEditWrappers.EditHistoryEntry> history = BulkEditController.getEditHistory(5);
        System.assert(!history.isEmpty());
        System.assertEquals(jobResult.logId, history[0].logId);
        System.assertEquals(null, history[0].filterFieldLabel);
    }

    @isTest
    static void testGetJobStatus_abortedJob_reportsFailedInsteadOfSpinningForever() {
        // A genuinely 'Aborted' AsyncApexJob can't be produced inside a test
        // transaction (System.abortJob on a job that hasn't run yet leaves
        // AsyncApexJob.Status as 'Queued', not 'Aborted') — TEST_FORCE_JOB_ABORTED
        // simulates the branch directly, same pattern as the other TEST_FORCE_*
        // flags on this class.
        BulkEditController.TEST_FORCE_JOB_ABORTED = true;
        BulkEditWrappers.BulkEditJobResult jobResult;
        Test.startTest();
        jobResult = BulkEditController.startBulkEdit(
            'Account', 'AccountNumber', 'Account', 'Account Number',
            'OLD-VALUE', false, 'NEW-VALUE', false,
            null, null, null, null
        );
        Test.stopTest();

        // start()/execute()/finish() ran normally here (the flag only forces
        // getJobStatus to treat the job as aborted), so Status__c is really
        // 'Completed' — getJobStatus must still report 'Failed' once the
        // forced-abort branch overrides it, proving that branch runs and wins.
        BulkEditWrappers.JobStatusResult status = BulkEditController.getJobStatus(jobResult.logId);
        System.assert(status.isDone);
        System.assertEquals('Failed', status.status);
        System.assertNotEquals(null, status.errorMessage);
    }

    @isTest
    static void testStartBulkEdit_withFilter() {
        // Blank AccountNumber accounts are i=10 (Technology) and i=11
        // (Banking). Filtering to Industry='Technology' must restrict the
        // mass update to only the 1 matching record, leaving i=11 untouched.
        Test.startTest();
        BulkEditWrappers.BulkEditJobResult jobResult = BulkEditController.startBulkEdit(
            'Account', 'AccountNumber', 'Account', 'Account Number',
            null, true, 'FILLED', false,
            'Industry', 'Industry', 'Technology', false
        );
        Test.stopTest();

        List<Account> updated = [SELECT AccountNumber, Industry FROM Account WHERE AccountNumber = 'FILLED'];
        System.assertEquals(1, updated.size());
        System.assertEquals('Technology', updated[0].Industry);

        List<Account> stillBlank = [SELECT Id FROM Account WHERE AccountNumber = null];
        System.assertEquals(1, stillBlank.size());

        Bulk_Edit_Log__c logRec = [SELECT Filter_Field_Label__c, Filter_Value_Display__c FROM Bulk_Edit_Log__c WHERE Id = :jobResult.logId];
        System.assertEquals('Industry', logRec.Filter_Field_Label__c);
        System.assertEquals('Technology', logRec.Filter_Value_Display__c);

        List<BulkEditWrappers.EditHistoryEntry> history = BulkEditController.getEditHistory(5);
        System.assertEquals(jobResult.logId, history[0].logId);
        System.assertEquals('Industry', history[0].filterFieldLabel);
        System.assertEquals('Technology', history[0].filterValueDisplay);
    }

    @isTest
    static void testStartBulkEdit_andUndo() {
        // Simulate a completed edit (as BulkEditBatch would leave it) so the
        // undo path can be exercised deterministically through the public
        // controller API. Chaining a real edit batch + undo batch in one
        // startTest/stopTest window is not reliably ordered by the platform,
        // and only one such window is allowed per test method — see
        // BulkEditBatchTest for the batch-level undo coverage.
        List<Account> accounts = [SELECT Id, AccountNumber FROM Account WHERE AccountNumber = 'OLD-VALUE' LIMIT 10];
        Bulk_Edit_Log__c logRec = new Bulk_Edit_Log__c(
            Object_Type__c = 'Account',
            Object_Label__c = 'Account',
            Field_API_Name__c = 'AccountNumber',
            Field_Label__c = 'Account Number',
            Old_Value_Display__c = 'OLD-VALUE',
            New_Value__c = 'NEW-VALUE',
            Status__c = 'Completed',
            Records_Affected__c = accounts.size()
        );
        insert logRec;

        List<Bulk_Edit_Snapshot__c> snapshots = new List<Bulk_Edit_Snapshot__c>();
        for (Account acc : accounts) {
            snapshots.add(new Bulk_Edit_Snapshot__c(
                Bulk_Edit_Log__c = logRec.Id,
                Record_Id__c = acc.Id,
                Old_Value__c = 'OLD-VALUE'
            ));
            acc.AccountNumber = 'NEW-VALUE';
        }
        insert snapshots;
        update accounts;

        Test.startTest();
        Id undoJobId = BulkEditController.undoBulkEdit(logRec.Id);
        Test.stopTest();

        System.assertNotEquals(null, undoJobId);
        List<Account> restored = [SELECT AccountNumber FROM Account WHERE AccountNumber = 'OLD-VALUE'];
        System.assertEquals(10, restored.size());

        Bulk_Edit_Log__c logAfterUndo = [SELECT Status__c FROM Bulk_Edit_Log__c WHERE Id = :logRec.Id];
        System.assertEquals('Undone', logAfterUndo.Status__c);
    }

    @isTest
    static void testStartBulkEdit_numericField() {
        Test.startTest();
        BulkEditWrappers.BulkEditJobResult jobResult = BulkEditController.startBulkEdit(
            'Account', 'AnnualRevenue', 'Account', 'Annual Revenue',
            '1000', false, '2000', false,
            null, null, null, null
        );
        Test.stopTest();

        List<Account> updated = [SELECT AnnualRevenue FROM Account WHERE AnnualRevenue = 2000];
        System.assertEquals(12, updated.size());
    }

    @isTest
    static void testStartBulkEdit_newValueTooLong_throws() {
        // AccountNumber is a standard field capped at 40 characters — well
        // under Bulk_Edit_Log__c.New_Value__c's own 255-char limit, so this
        // exercises the field-specific length check (not the log's).
        String tooLong = ''.rightPad(41, 'X');
        Boolean threw = false;
        String message;
        try {
            BulkEditController.startBulkEdit(
                'Account', 'AccountNumber', 'Account', 'Account Number',
                'OLD-VALUE', false, tooLong, false,
                null, null, null, null
            );
        } catch (AuraHandledException ex) {
            threw = true;
            message = ex.getMessage();
        }
        System.assert(threw, 'Expected an exception when the new value exceeds the field\'s max length');
        System.assert(message.contains('too long'), 'Expected a clear too-long message, got: ' + message);

        List<Account> unchanged = [SELECT Id FROM Account WHERE AccountNumber = :tooLong];
        System.assertEquals(0, unchanged.size(), 'No records should have been touched — the log insert must never have been reached');
    }

    @isTest
    static void testStartBulkEdit_invalidValue() {
        Boolean threw = false;
        try {
            BulkEditController.startBulkEdit(
                'Account', 'AnnualRevenue', 'Account', 'Annual Revenue',
                '1000', false, 'not-a-number', false,
                null, null, null, null
            );
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Expected an exception for an invalid numeric value');
    }

    @isTest
    static void testStartBulkEdit_invalidFilterField() {
        Boolean threw = false;
        try {
            BulkEditController.startBulkEdit(
                'Account', 'AnnualRevenue', 'Account', 'Annual Revenue',
                '1000', false, '2000', false,
                'NotARealField__c', 'Not A Real Field', 'foo', false
            );
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Expected an exception for an unknown filter field');
    }

    @isTest
    static void testGetEditHistory_defaultLimit() {
        Test.startTest();
        List<BulkEditWrappers.EditHistoryEntry> history = BulkEditController.getEditHistory(null);
        Test.stopTest();
        System.assertNotEquals(null, history);
    }

    @isTest
    static void testGetEditableObjects_forcedException_throws() {
        BulkEditService.TEST_FORCE_SERVICE_EXCEPTION = true;
        Boolean threw = false;
        try {
            BulkEditController.getEditableObjects();
        } catch (AuraHandledException ex) {
            threw = true;
        } finally {
            BulkEditService.TEST_FORCE_SERVICE_EXCEPTION = false;
        }
        System.assert(threw, 'Expected the forced service exception to surface as an AuraHandledException');
    }

    @isTest
    static void testGetValueDistribution_ungroupableField_throws() {
        Boolean threw = false;
        try {
            BulkEditController.getValueDistribution('Account', 'AnnualRevenue', null, null, null);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Currency fields like AnnualRevenue cannot be grouped by value');
    }

    @isTest
    static void testGetFilterableFields_invalidObject_throws() {
        Boolean threw = false;
        try {
            BulkEditController.getFilterableFields('Not_A_Real_Object__c', null);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw);
    }

    @isTest
    static void testGetFilterFieldValueDistribution_ungroupableField_throws() {
        Boolean threw = false;
        try {
            BulkEditController.getFilterFieldValueDistribution('Account', 'AnnualRevenue');
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Currency fields like AnnualRevenue cannot be grouped by value');
    }

    @isTest
    static void testGetPicklistValues_invalidObject_throws() {
        Boolean threw = false;
        try {
            BulkEditController.getPicklistValues('Not_A_Real_Object__c', 'Industry');
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw);
    }

    @isTest
    static void testPreviewCount_invalidObject_throws() {
        Boolean threw = false;
        try {
            BulkEditController.previewCount('Not_A_Real_Object__c', 'Industry', 'Technology', false);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw);
    }

    @isTest
    static void testStartBulkEdit_noCreateAccess_forced_throws() {
        BulkEditController.TEST_FORCE_NO_CREATE_ACCESS = true;
        Boolean threw = false;
        try {
            BulkEditController.startBulkEdit(
                'Account', 'AccountNumber', 'Account', 'Account Number',
                'OLD-VALUE', false, 'NEW-VALUE', false,
                null, null, null, null
            );
        } catch (AuraHandledException ex) {
            threw = true;
        } finally {
            BulkEditController.TEST_FORCE_NO_CREATE_ACCESS = false;
        }
        System.assert(threw, 'Expected the forced no-create-access check to throw and re-propagate via the AuraHandledException catch');
    }

    @isTest
    static void testGetJobStatus_logNotFound_throws() {
        Bulk_Edit_Log__c logRec = new Bulk_Edit_Log__c(
            Object_Type__c = 'Account', Object_Label__c = 'Account',
            Field_API_Name__c = 'Industry', Field_Label__c = 'Industry',
            Old_Value_Display__c = 'Technology', New_Value__c = 'Banking',
            Status__c = 'Queued'
        );
        insert logRec;
        Id deletedLogId = logRec.Id;
        delete logRec;

        Boolean threw = false;
        try {
            BulkEditController.getJobStatus(deletedLogId);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Expected an exception when the job log no longer exists');
    }

    @isTest
    static void testGetEditHistory_forcedError_throws() {
        BulkEditController.TEST_FORCE_HISTORY_ERROR = true;
        Boolean threw = false;
        try {
            BulkEditController.getEditHistory(5);
        } catch (AuraHandledException ex) {
            threw = true;
        } finally {
            BulkEditController.TEST_FORCE_HISTORY_ERROR = false;
        }
        System.assert(threw, 'Expected the forced history error to surface as an AuraHandledException');
    }

    @isTest
    static void testUndoBulkEdit_deletedLog_throws() {
        Bulk_Edit_Log__c logRec = new Bulk_Edit_Log__c(
            Object_Type__c = 'Account', Object_Label__c = 'Account',
            Field_API_Name__c = 'Industry', Field_Label__c = 'Industry',
            Old_Value_Display__c = 'Technology', New_Value__c = 'Banking',
            Status__c = 'Completed'
        );
        insert logRec;
        Id deletedLogId = logRec.Id;
        delete logRec;

        // The batch enqueued by undoBulkEdit() before its DML failure stays
        // queued regardless — without Test.startTest()/stopTest(), it would
        // run after the whole test class finishes and its own (expected)
        // failure would surface as this test's result instead of the
        // synchronous assertion below. Wrapping forces it to run during
        // stopTest(), synchronously, like BulkEditBatchTest's
        // testUndoBatchRejectsWrongStatus.
        Boolean threw = false;
        Test.startTest();
        try {
            BulkEditController.undoBulkEdit(deletedLogId);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        try {
            Test.stopTest();
        } catch (Exception ex) {
            threw = true;
        }
        System.assert(threw, 'Expected the synchronous update against a deleted log to throw');
    }
}
