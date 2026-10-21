@isTest
private class BulkCleanFieldControllerTest {

    @TestSetup
    static void setup() {
        List<Account> accounts = new List<Account>();
        // U+202F narrow no-break space = decimal 8239 (Apex Integer literals don't support 0x hex notation).
        accounts.add(new Account(Name = 'Clean Ctrl 0', AccountNumber = '1' + String.fromCharArray(new List<Integer>{ 8239 }) + '799', Industry = 'Technology'));
        accounts.add(new Account(Name = 'Clean Ctrl 1', AccountNumber = 'ALREADY-CLEAN', Industry = 'Banking'));
        insert accounts;
    }

    @isTest
    static void testGetCleanableFields() {
        Test.startTest();
        List<BulkEditWrappers.FieldOption> fields = BulkCleanFieldController.getCleanableFields('Account');
        Test.stopTest();

        Set<String> apiNames = new Set<String>();
        for (BulkEditWrappers.FieldOption f : fields) {
            apiNames.add(f.apiName);
        }
        System.assert(apiNames.contains('AccountNumber'));
        System.assert(!apiNames.contains('Industry'));
    }

    @isTest
    static void testGetCleanableFields_invalidObject_throws() {
        Boolean threw = false;
        try {
            BulkCleanFieldController.getCleanableFields('Not_A_Real_Object__c');
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw);
    }

    @isTest
    static void testPreviewCleanup() {
        Test.startTest();
        BulkEditWrappers.CleanPreviewResult result = BulkCleanFieldController.previewCleanup(
            'Account', 'AccountNumber', null, null, null,
            true, true, true, null
        );
        Test.stopTest();

        System.assertEquals(2, result.totalMatching);
        System.assertEquals(1, result.sampleWouldChange);
    }

    @isTest
    static void testPreviewCleanup_invalidField_throws() {
        Boolean threw = false;
        try {
            BulkCleanFieldController.previewCleanup(
                'Account', 'Not_A_Real_Field__c', null, null, null,
                true, true, true, null
            );
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw);
    }

    @isTest
    static void testStartCleanField_jobStatusAndHistory() {
        Test.startTest();
        BulkEditWrappers.BulkEditJobResult jobResult = BulkCleanFieldController.startCleanField(
            'Account', 'Account', 'AccountNumber', 'Account Number',
            null, null, null, null,
            true, true, true, null
        );
        Test.stopTest();

        System.assertNotEquals(null, jobResult.logId);
        System.assertNotEquals(null, jobResult.batchJobId);

        Account cleaned = [SELECT AccountNumber FROM Account WHERE Name = 'Clean Ctrl 0'];
        System.assertEquals('1 799', cleaned.AccountNumber);

        Bulk_Edit_Log__c logRec = [SELECT Status__c, Records_Affected__c, New_Value__c, Old_Value_Display__c FROM Bulk_Edit_Log__c WHERE Id = :jobResult.logId];
        System.assertEquals('Completed', logRec.Status__c);
        System.assertEquals(1, logRec.Records_Affected__c.intValue());
        System.assert(logRec.New_Value__c.contains('Normalize spaces'));
        System.assertEquals('(varies per record — auto-cleaned)', logRec.Old_Value_Display__c);

        List<BulkEditWrappers.EditHistoryEntry> history = BulkEditController.getEditHistory(5);
        System.assertEquals(jobResult.logId, history[0].logId);
    }

    @isTest
    static void testStartCleanField_withFilter() {
        Test.startTest();
        BulkEditWrappers.BulkEditJobResult jobResult = BulkCleanFieldController.startCleanField(
            'Account', 'Account', 'AccountNumber', 'Account Number',
            'Industry', 'Industry', 'Technology', false,
            true, false, false, null
        );
        Test.stopTest();

        Bulk_Edit_Log__c logRec = [SELECT Filter_Field_Label__c, Filter_Value_Display__c FROM Bulk_Edit_Log__c WHERE Id = :jobResult.logId];
        System.assertEquals('Industry', logRec.Filter_Field_Label__c);
        System.assertEquals('Technology', logRec.Filter_Value_Display__c);
    }

    @isTest
    static void testStartCleanField_noRulesSelected_summaryFallback() {
        Test.startTest();
        BulkEditWrappers.BulkEditJobResult jobResult = BulkCleanFieldController.startCleanField(
            'Account', 'Account', 'AccountNumber', 'Account Number',
            null, null, null, null,
            false, false, false, null
        );
        Test.stopTest();

        Bulk_Edit_Log__c logRec = [SELECT New_Value__c FROM Bulk_Edit_Log__c WHERE Id = :jobResult.logId];
        System.assertEquals('(no rules selected)', logRec.New_Value__c);
    }

    @isTest
    static void testStartCleanField_customCharsSummary() {
        Test.startTest();
        BulkEditWrappers.BulkEditJobResult jobResult = BulkCleanFieldController.startCleanField(
            'Account', 'Account', 'AccountNumber', 'Account Number',
            null, null, null, null,
            false, false, false, '!@#'
        );
        Test.stopTest();

        Bulk_Edit_Log__c logRec = [SELECT New_Value__c FROM Bulk_Edit_Log__c WHERE Id = :jobResult.logId];
        System.assertEquals('Remove: !@#', logRec.New_Value__c);
    }

    @isTest
    static void testStartCleanField_whitespaceOnlyCustomChars_notTreatedAsBlank() {
        // Same isBlank()/isNotBlank() pitfall as BulkCleanFieldServiceTest's
        // whitespace-only test — buildRulesSummary() must still show the
        // strip rule (and the batch must still apply it) when the user
        // typed only a space character.
        Test.startTest();
        BulkEditWrappers.BulkEditJobResult jobResult = BulkCleanFieldController.startCleanField(
            'Account', 'Account', 'AccountNumber', 'Account Number',
            null, null, null, null,
            false, false, false, ' '
        );
        Test.stopTest();

        // The value built in Apex is 'Remove: ' + ' ' = 'Remove:  ' (trailing
        // whitespace), but Salesforce Text fields silently trim ALL
        // trailing whitespace on save — a platform behavior, not an Apex
        // bug — so the persisted value ends up trimmed to 'Remove:'. This
        // only affects the cosmetic log summary; buildRulesSummary() still
        // correctly added the "Remove:" part instead of skipping it, which
        // is what this test actually guards against.
        Bulk_Edit_Log__c logRec = [SELECT New_Value__c FROM Bulk_Edit_Log__c WHERE Id = :jobResult.logId];
        System.assertEquals('Remove:', logRec.New_Value__c);

        Account cleaned = [SELECT AccountNumber FROM Account WHERE Name = 'Clean Ctrl 1'];
        System.assertEquals('ALREADY-CLEAN', cleaned.AccountNumber, 'No spaces in this value, so stripping spaces must be a no-op');
    }

    @isTest
    static void testStartCleanField_invalidObject_throws() {
        Boolean threw = false;
        try {
            BulkCleanFieldController.startCleanField(
                'Not_A_Real_Object__c', 'Not Real', 'AccountNumber', 'Account Number',
                null, null, null, null,
                true, true, true, null
            );
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw);

        List<Bulk_Edit_Log__c> logs = [SELECT Id FROM Bulk_Edit_Log__c];
        System.assertEquals(0, logs.size(), 'No log should have been created for an invalid object');
    }

    @isTest
    static void testStartCleanField_invalidFilterField_throws() {
        Boolean threw = false;
        try {
            BulkCleanFieldController.startCleanField(
                'Account', 'Account', 'AccountNumber', 'Account Number',
                'Not_A_Real_Field__c', 'Not A Real Field', 'foo', false,
                true, true, true, null
            );
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw);
    }

    @isTest
    static void testStartCleanField_noCreateAccess_forced_throws() {
        BulkCleanFieldController.TEST_FORCE_NO_CREATE_ACCESS = true;
        Boolean threw = false;
        try {
            BulkCleanFieldController.startCleanField(
                'Account', 'Account', 'AccountNumber', 'Account Number',
                null, null, null, null,
                true, true, true, null
            );
        } catch (AuraHandledException ex) {
            threw = true;
        } finally {
            BulkCleanFieldController.TEST_FORCE_NO_CREATE_ACCESS = false;
        }
        System.assert(threw, 'Expected the forced no-create-access check to throw and re-propagate via the AuraHandledException catch');
    }
}
