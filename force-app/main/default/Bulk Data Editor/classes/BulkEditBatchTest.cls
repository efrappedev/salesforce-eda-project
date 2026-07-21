@isTest
private class BulkEditBatchTest {

    @TestSetup
    static void setup() {
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 5; i++) {
            accounts.add(new Account(Name = 'Batch Test ' + i, Industry = 'Technology'));
        }
        insert accounts;
    }

    private static Bulk_Edit_Log__c createLog(String objectType, String fieldApi, String oldDisplay, String newValue) {
        Bulk_Edit_Log__c logRec = new Bulk_Edit_Log__c(
            Object_Type__c = objectType,
            Object_Label__c = objectType,
            Field_API_Name__c = fieldApi,
            Field_Label__c = fieldApi,
            Old_Value_Display__c = oldDisplay,
            New_Value__c = newValue,
            Status__c = 'Queued'
        );
        insert logRec;
        return logRec;
    }

    @isTest
    static void testBatchUpdatesRecordsAndCreatesSnapshots() {
        Bulk_Edit_Log__c logRec = createLog('Account', 'Industry', 'Technology', 'Banking');

        Test.startTest();
        Database.executeBatch(new BulkEditBatch(logRec.Id, 'Account', 'Industry', 'Technology', false, 'Banking', false, null, null, null), 200);
        Test.stopTest();

        List<Account> updated = [SELECT Industry FROM Account WHERE Industry = 'Banking'];
        System.assertEquals(5, updated.size());

        List<Bulk_Edit_Snapshot__c> snapshots = [SELECT Old_Value__c, Record_Id__c FROM Bulk_Edit_Snapshot__c WHERE Bulk_Edit_Log__c = :logRec.Id];
        System.assertEquals(5, snapshots.size());
        for (Bulk_Edit_Snapshot__c snap : snapshots) {
            System.assertEquals('Technology', snap.Old_Value__c);
        }

        Bulk_Edit_Log__c refreshed = [SELECT Status__c, Records_Affected__c FROM Bulk_Edit_Log__c WHERE Id = :logRec.Id];
        System.assertEquals('Completed', refreshed.Status__c);
        System.assertEquals(5, refreshed.Records_Affected__c.intValue());
    }

    @isTest
    static void testBatchFromBlankValue() {
        insert new Account(Name = 'Blank Industry Account');

        Bulk_Edit_Log__c logRec = createLog('Account', 'Industry', '(Blank)', 'Technology');

        Test.startTest();
        Database.executeBatch(new BulkEditBatch(logRec.Id, 'Account', 'Industry', null, true, 'Technology', false, null, null, null), 200);
        Test.stopTest();

        Account result = [SELECT Industry FROM Account WHERE Name = 'Blank Industry Account'];
        System.assertEquals('Technology', result.Industry);
    }

    @isTest
    static void testBatchToBlankValue() {
        Bulk_Edit_Log__c logRec = createLog('Account', 'Industry', 'Technology', '(Blank)');

        Test.startTest();
        Database.executeBatch(new BulkEditBatch(logRec.Id, 'Account', 'Industry', 'Technology', false, null, true, null, null, null), 200);
        Test.stopTest();

        List<Account> updated = [SELECT Industry FROM Account WHERE Industry = null];
        System.assertEquals(5, updated.size());
    }

    @isTest
    static void testBatchAppliesFilter() {
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 6; i++) {
            accounts.add(new Account(
                Name = 'Filter Batch ' + i,
                Industry = (Math.mod(i, 2) == 0) ? 'Technology' : 'Banking',
                AccountNumber = 'OLD-VALUE'
            ));
        }
        insert accounts;

        Bulk_Edit_Log__c logRec = createLog('Account', 'AccountNumber', 'OLD-VALUE', 'NEW-VALUE');

        Test.startTest();
        Database.executeBatch(
            new BulkEditBatch(logRec.Id, 'Account', 'AccountNumber', 'OLD-VALUE', false, 'NEW-VALUE', false, 'Industry', 'Technology', false),
            200
        );
        Test.stopTest();

        List<Account> updated = [SELECT AccountNumber FROM Account WHERE AccountNumber = 'NEW-VALUE'];
        System.assertEquals(3, updated.size());

        List<Account> untouched = [SELECT AccountNumber FROM Account WHERE AccountNumber = 'OLD-VALUE'];
        System.assertEquals(3, untouched.size());
    }

    @isTest
    static void testUndoBatchRestoresOriginalValues() {
        Bulk_Edit_Log__c logRec = createLog('Account', 'Industry', 'Technology', 'Banking');

        Test.startTest();
        Database.executeBatch(new BulkEditBatch(logRec.Id, 'Account', 'Industry', 'Technology', false, 'Banking', false, null, null, null), 200);
        Test.stopTest();

        Bulk_Edit_Log__c afterEdit = [SELECT Status__c FROM Bulk_Edit_Log__c WHERE Id = :logRec.Id];
        System.assertEquals('Completed', afterEdit.Status__c);

        // Run the undo batch synchronously via direct method calls instead
        // of a second Database.executeBatch: only one startTest/stopTest
        // pair is allowed per test method, and the platform does not
        // guarantee a second enqueued job's start() runs only after the
        // first job's finish() when both are queued in the same window.
        // bc is unused in the batch body, so null is safe here.
        BulkEditUndoBatch undoBatch = new BulkEditUndoBatch(logRec.Id);
        undoBatch.start(null);
        List<Bulk_Edit_Snapshot__c> scope = [
            SELECT Id, Record_Id__c, Old_Value__c FROM Bulk_Edit_Snapshot__c WHERE Bulk_Edit_Log__c = :logRec.Id
        ];
        undoBatch.execute(null, scope);
        undoBatch.finish(null);

        List<Account> restored = [SELECT Industry FROM Account WHERE Industry = 'Technology'];
        System.assertEquals(5, restored.size());

        Bulk_Edit_Log__c refreshed = [SELECT Status__c FROM Bulk_Edit_Log__c WHERE Id = :logRec.Id];
        System.assertEquals('Undone', refreshed.Status__c);
    }

    @isTest
    static void testUndoBatchRejectsWrongStatus() {
        Bulk_Edit_Log__c logRec = createLog('Account', 'Industry', 'Technology', 'Banking');
        // Status__c stays 'Queued' — never actually run through BulkEditBatch.

        // A batch's start() exception surfaces synchronously from stopTest()
        // in test context, so the assertion must wrap stopTest(), not query
        // AsyncApexJob afterward.
        Boolean threw = false;
        Test.startTest();
        Database.executeBatch(new BulkEditUndoBatch(logRec.Id), 200);
        try {
            Test.stopTest();
        } catch (BulkEditException ex) {
            threw = true;
        }

        System.assert(threw, 'Expected the undo batch to reject an undo from a non-completed status');
    }

    @isTest
    static void testServiceResolveObjectType_blankAndBlacklisted() {
        Boolean blankThrew = false;
        try {
            BulkEditService.resolveObjectType('');
        } catch (BulkEditException ex) {
            blankThrew = true;
        }
        System.assert(blankThrew);

        Boolean blacklistThrew = false;
        try {
            BulkEditService.resolveObjectType('Profile');
        } catch (BulkEditException ex) {
            blacklistThrew = true;
        }
        System.assert(blacklistThrew);

        Boolean unknownThrew = false;
        try {
            BulkEditService.resolveObjectType('Not_A_Real_Object__c');
        } catch (BulkEditException ex) {
            unknownThrew = true;
        }
        System.assert(unknownThrew);
    }

    @isTest
    static void testServiceResolveFieldDescribe_invalidField() {
        Schema.SObjectType sType = BulkEditService.resolveObjectType('Account');

        Boolean blankThrew = false;
        try {
            BulkEditService.resolveFieldDescribe(sType, '');
        } catch (BulkEditException ex) {
            blankThrew = true;
        }
        System.assert(blankThrew);

        Boolean unknownThrew = false;
        try {
            BulkEditService.resolveFieldDescribe(sType, 'Not_A_Real_Field__c');
        } catch (BulkEditException ex) {
            unknownThrew = true;
        }
        System.assert(unknownThrew);

        Boolean excludedThrew = false;
        try {
            BulkEditService.resolveFieldDescribe(sType, 'OwnerId');
        } catch (BulkEditException ex) {
            excludedThrew = true;
        }
        System.assert(excludedThrew);
    }

    @isTest
    static void testServiceToSoqlLiteral_invalidNumber() {
        Schema.SObjectType sType = BulkEditService.resolveObjectType('Account');
        Schema.DescribeFieldResult dfr = BulkEditService.resolveFieldDescribe(sType, 'AnnualRevenue');

        Boolean threw = false;
        try {
            BulkEditService.buildWhereClause(dfr, 'not-a-number', false);
        } catch (BulkEditException ex) {
            threw = true;
        }
        System.assert(threw);
    }

    @isTest
    static void testBatchExecute_dmlFailure_appendsError() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Batch Test 0' LIMIT 1];
        Id deletedId = acc.Id;
        delete acc;

        Bulk_Edit_Log__c logRec = createLog('Account', 'Industry', 'Technology', 'Banking');
        BulkEditBatch batch = new BulkEditBatch(
            logRec.Id, 'Account', 'Industry', 'Technology', false, 'Banking', false, null, null, null
        );

        List<Account> scope = new List<Account>{ new Account(Id = deletedId, Industry = 'Technology') };
        batch.execute(null, scope);
        batch.finish(null);

        Bulk_Edit_Log__c refreshed = [SELECT Status__c, Error_Message__c FROM Bulk_Edit_Log__c WHERE Id = :logRec.Id];
        System.assertEquals('Failed', refreshed.Status__c);
        System.assert(refreshed.Error_Message__c.contains(String.valueOf(deletedId)));
    }

    @isTest
    static void testBatchAppendError_truncatesAtMaxLength() {
        BulkEditBatch batch = new BulkEditBatch(
            null, 'Account', 'Industry', 'Technology', false, 'Banking', false, null, null, null
        );
        batch.errorLog = ''.rightPad(25000, 'X');
        batch.appendError('this should be dropped');
        System.assertEquals(25000, batch.errorLog.length(), 'Expected appendError to no-op once at the cap');
    }

    @isTest
    static void testUndoBatchStart_logNotFound_throws() {
        Bulk_Edit_Log__c logRec = createLog('Account', 'Industry', 'Technology', 'Banking');
        Id deletedLogId = logRec.Id;
        delete logRec;

        BulkEditUndoBatch undoBatch = new BulkEditUndoBatch(deletedLogId);
        Boolean threw = false;
        try {
            undoBatch.start(null);
        } catch (BulkEditException ex) {
            threw = true;
        }
        System.assert(threw, 'Expected an exception when the log to undo does not exist');
    }

    @isTest
    static void testUndoBatchExecute_blankRecordIdSkipped_andDmlFailure() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Batch Test 1' LIMIT 1];
        Id deletedAccountId = acc.Id;

        Bulk_Edit_Log__c logRec = createLog('Account', 'Industry', 'Technology', 'Banking');
        logRec.Status__c = 'Completed';
        update logRec;

        BulkEditUndoBatch undoBatch = new BulkEditUndoBatch(logRec.Id);
        undoBatch.start(null);

        delete acc;

        List<Bulk_Edit_Snapshot__c> scope = new List<Bulk_Edit_Snapshot__c>{
            new Bulk_Edit_Snapshot__c(Bulk_Edit_Log__c = logRec.Id, Record_Id__c = null, Old_Value__c = 'Technology'),
            new Bulk_Edit_Snapshot__c(Bulk_Edit_Log__c = logRec.Id, Record_Id__c = deletedAccountId, Old_Value__c = 'Technology')
        };
        undoBatch.execute(null, scope);
        undoBatch.finish(null);

        Bulk_Edit_Log__c refreshed = [SELECT Status__c, Error_Message__c FROM Bulk_Edit_Log__c WHERE Id = :logRec.Id];
        System.assertEquals('Undo Failed', refreshed.Status__c);
        System.assert(refreshed.Error_Message__c.contains(String.valueOf(deletedAccountId)));
    }

    @isTest
    static void testUndoBatchAppendError_truncatesAtMaxLength() {
        BulkEditUndoBatch undoBatch = new BulkEditUndoBatch(null);
        undoBatch.errorLog = ''.rightPad(25000, 'X');
        undoBatch.appendError('this should be dropped');
        System.assertEquals(25000, undoBatch.errorLog.length(), 'Expected appendError to no-op once at the cap');
    }

    @isTest
    static void testServiceResolveObjectType_notEditable_forced() {
        BulkEditService.TEST_FORCE_OBJECT_NOT_EDITABLE = true;
        Boolean threw = false;
        try {
            BulkEditService.resolveObjectType('Account');
        } catch (BulkEditException ex) {
            threw = true;
        } finally {
            BulkEditService.TEST_FORCE_OBJECT_NOT_EDITABLE = false;
        }
        System.assert(threw, 'Expected the CRUD-denial branch to throw when forced');
    }

    @isTest
    static void testServiceGetEditableFields_forcedCalculatedFieldSkipped() {
        BulkEditService.TEST_FORCE_FIELD_CALCULATED = true;
        List<BulkEditWrappers.FieldOption> fields;
        List<BulkEditWrappers.FieldOption> filterFields;
        try {
            fields = BulkEditService.getEditableFields('Account');
            filterFields = BulkEditService.getFilterableFields('Account', null);
        } finally {
            BulkEditService.TEST_FORCE_FIELD_CALCULATED = false;
        }
        System.assertEquals(0, fields.size(), 'Expected every field to be skipped when the calculated/auto-number check is forced true');
        System.assertEquals(0, filterFields.size(), 'Expected every filter field to be skipped when the calculated check is forced true');
    }

    @isTest
    static void testServiceResolveFieldDescribe_notUpdateable_andExcludedNameForced() {
        Schema.SObjectType sType = BulkEditService.resolveObjectType('Account');

        Boolean notUpdateableThrew = false;
        try {
            BulkEditService.resolveFieldDescribe(sType, 'IsDeleted');
        } catch (BulkEditException ex) {
            notUpdateableThrew = true;
        }
        System.assert(notUpdateableThrew, 'Expected the permission-denial branch for a non-updateable field like IsDeleted');

        BulkEditService.TEST_FORCE_BYPASS_FIELD_CHECKS = true;
        Boolean excludedThrew = false;
        try {
            BulkEditService.resolveFieldDescribe(sType, 'OwnerId');
        } catch (BulkEditException ex) {
            excludedThrew = true;
        } finally {
            BulkEditService.TEST_FORCE_BYPASS_FIELD_CHECKS = false;
        }
        System.assert(excludedThrew, 'Expected the excluded-field-name safety net to trigger once type/CRUD checks are bypassed');
    }

    @isTest
    static void testServiceResolveFilterFieldDescribe_allBranches() {
        Schema.SObjectType sType = BulkEditService.resolveObjectType('Account');

        Boolean blankThrew = false;
        try {
            BulkEditService.resolveFilterFieldDescribe(sType, '');
        } catch (BulkEditException ex) {
            blankThrew = true;
        }
        System.assert(blankThrew);

        Boolean typeThrew = false;
        try {
            BulkEditService.resolveFilterFieldDescribe(sType, 'OwnerId');
        } catch (BulkEditException ex) {
            typeThrew = true;
        }
        System.assert(typeThrew, 'Expected a Reference-type field to be rejected for filtering');

        BulkEditService.TEST_FORCE_FILTER_FIELD_NOT_ACCESSIBLE = true;
        Boolean accessThrew = false;
        try {
            BulkEditService.resolveFilterFieldDescribe(sType, 'Industry');
        } catch (BulkEditException ex) {
            accessThrew = true;
        } finally {
            BulkEditService.TEST_FORCE_FILTER_FIELD_NOT_ACCESSIBLE = false;
        }
        System.assert(accessThrew, 'Expected the forced not-accessible branch to trigger');

        Boolean excludedThrew = false;
        try {
            BulkEditService.resolveFilterFieldDescribe(sType, 'IsDeleted');
        } catch (BulkEditException ex) {
            excludedThrew = true;
        }
        System.assert(excludedThrew, 'Expected IsDeleted to be rejected by the excluded-field-name safety net');
    }

    @isTest
    static void testServiceBuildWhereClause_blankValueFieldTypeBranches() {
        Schema.DescribeFieldResult phoneDfr = Account.Phone.getDescribe();
        System.assertEquals('(Phone = null OR Phone = \'\')', BulkEditService.buildWhereClause(phoneDfr, null, true));

        Schema.DescribeFieldResult emailDfr = Contact.Email.getDescribe();
        System.assertEquals('(Email = null OR Email = \'\')', BulkEditService.buildWhereClause(emailDfr, null, true));

        Schema.DescribeFieldResult websiteDfr = Account.Website.getDescribe();
        System.assertEquals('(Website = null OR Website = \'\')', BulkEditService.buildWhereClause(websiteDfr, null, true));

        Schema.DescribeFieldResult revenueDfr = Account.AnnualRevenue.getDescribe();
        System.assertEquals('AnnualRevenue = null', BulkEditService.buildWhereClause(revenueDfr, null, true));
    }

    @isTest
    static void testServiceBuildWhereClause_nullRawValueAndTypedLiterals() {
        Schema.DescribeFieldResult industryDfr = Account.Industry.getDescribe();
        System.assertEquals('Industry = null', BulkEditService.buildWhereClause(industryDfr, null, false));

        Schema.DescribeFieldResult doNotCallDfr = Contact.DoNotCall.getDescribe();
        System.assertEquals('DoNotCall = true', BulkEditService.buildWhereClause(doNotCallDfr, 'true', false));

        Schema.DescribeFieldResult birthdateDfr = Contact.Birthdate.getDescribe();
        System.assertEquals('Birthdate = 2020-01-15', BulkEditService.buildWhereClause(birthdateDfr, '2020-01-15', false));
    }

    @isTest
    static void testServiceToApexValue_booleanAndDate() {
        System.assertEquals(true, BulkEditService.toApexValue(Schema.DisplayType.BOOLEAN, 'true', false));
        System.assertEquals(Date.valueOf('2020-01-15'), BulkEditService.toApexValue(Schema.DisplayType.DATE, '2020-01-15', false));
    }
}
