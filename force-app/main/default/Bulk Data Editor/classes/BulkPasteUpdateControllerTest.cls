@isTest
private class BulkPasteUpdateControllerTest {

    @TestSetup
    static void setup() {
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 5; i++) {
            accounts.add(new Account(Name = 'PU Account ' + i, AccountNumber = 'PU-' + i));
        }
        accounts.add(new Account(Name = 'PU Dup A', AccountNumber = 'PU-DUP'));
        accounts.add(new Account(Name = 'PU Dup B', AccountNumber = 'PU-DUP'));
        accounts.add(new Account(Name = 'PU Revenue', AccountNumber = 'PU-REV', AnnualRevenue = 5000));
        insert accounts;
    }

    // ---------------------------------------------------------------
    // getSearchableFields
    // ---------------------------------------------------------------

    @isTest
    static void testGetSearchableFields_includesSyntheticIdAndRealFields() {
        Test.startTest();
        List<BulkEditWrappers.FieldOption> fields = BulkPasteUpdateController.getSearchableFields('Account');
        Test.stopTest();

        System.assertEquals('Id', fields[0].apiName, 'Id should be prepended as the first, synthetic option');
        Set<String> apiNames = new Set<String>();
        for (BulkEditWrappers.FieldOption f : fields) {
            apiNames.add(f.apiName);
        }
        System.assert(apiNames.contains('AccountNumber'), 'Real filterable fields should still be included');
    }

    @isTest
    static void testGetSearchableFields_forcedException_throws() {
        BulkPasteUpdateService.TEST_FORCE_SERVICE_EXCEPTION = true;
        Boolean threw = false;
        try {
            BulkPasteUpdateController.getSearchableFields('Account');
        } catch (AuraHandledException ex) {
            threw = true;
        } finally {
            BulkPasteUpdateService.TEST_FORCE_SERVICE_EXCEPTION = false;
        }
        System.assert(threw, 'Expected the forced service exception to surface as an AuraHandledException');
    }

    // ---------------------------------------------------------------
    // matchRecords
    // ---------------------------------------------------------------

    @isTest
    static void testMatchRecords_bySearchField_matchedNotFoundDuplicate() {
        Test.startTest();
        List<BulkEditWrappers.MatchResult> results = BulkPasteUpdateController.matchRecords(
            'Account', 'AccountNumber', new List<String>{ 'PU-0', 'PU-1', 'PU-NOTFOUND', 'PU-DUP' }, null
        );
        Test.stopTest();

        Map<String, String> statusByValue = new Map<String, String>();
        Integer dupCount = 0;
        for (BulkEditWrappers.MatchResult r : results) {
            if (r.status == 'Duplicate') {
                dupCount++;
            } else {
                statusByValue.put(r.searchValue, r.status);
            }
            System.assertEquals(null, r.currentValue, 'No target field was requested, so currentValue should stay null on every row');
        }
        System.assertEquals('Matched', statusByValue.get('PU-0'));
        System.assertEquals('Matched', statusByValue.get('PU-1'));
        System.assertEquals('NotFound', statusByValue.get('PU-NOTFOUND'));
        System.assertEquals(2, dupCount, 'Both accounts sharing PU-DUP should be classified as Duplicate rows');
    }

    @isTest
    static void testMatchRecords_bySearchField_withTargetField_returnsCurrentValue() {
        List<Account> accts = [SELECT Id FROM Account WHERE AccountNumber IN ('PU-0', 'PU-DUP')];
        List<Account> toUpdate = new List<Account>();
        for (Account a : accts) {
            toUpdate.add(new Account(Id = a.Id, Site = 'Old Site — ' + a.Id));
        }
        update toUpdate;

        Test.startTest();
        List<BulkEditWrappers.MatchResult> results = BulkPasteUpdateController.matchRecords(
            'Account', 'AccountNumber', new List<String>{ 'PU-0', 'PU-DUP', 'PU-NOTFOUND' }, 'Site'
        );
        Test.stopTest();

        for (BulkEditWrappers.MatchResult r : results) {
            if (r.status == 'Matched' || r.status == 'Duplicate') {
                System.assert(r.currentValue.startsWith('Old Site — '), 'Matched/Duplicate rows should carry the target field\'s current value: ' + r.currentValue);
            } else {
                System.assertEquals(null, r.currentValue, 'A NotFound row has no record to read a current value from');
            }
        }
    }

    @isTest
    static void testMatchRecords_targetFieldSameAsDisplayField_dedupedInSelect() {
        // Target field == the object's own display field (Name) — exercises
        // buildSelectClause's dedup so the query doesn't request "Name"
        // twice and fail with a duplicate-field SOQL error.
        Test.startTest();
        List<BulkEditWrappers.MatchResult> results = BulkPasteUpdateController.matchRecords(
            'Account', 'AccountNumber', new List<String>{ 'PU-0' }, 'Name'
        );
        Test.stopTest();

        System.assertEquals('Matched', results[0].status);
        System.assertEquals('PU Account 0', results[0].currentValue);
        System.assertEquals(results[0].recordDisplay, results[0].currentValue, 'Name is both the display field and the target field here, so both should read the same value');
    }

    @isTest
    static void testMatchRecords_unknownTargetField_throws() {
        Boolean threw = false;
        try {
            BulkPasteUpdateController.matchRecords('Account', 'AccountNumber', new List<String>{ 'PU-0' }, 'Not_A_Real_Field__c');
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Expected an exception for an unknown target field');
    }

    @isTest
    static void testMatchRecords_byId_validNotFoundAndInvalidString() {
        Account acc = [SELECT Id FROM Account WHERE AccountNumber = 'PU-0' LIMIT 1];

        Test.startTest();
        List<BulkEditWrappers.MatchResult> results = BulkPasteUpdateController.matchRecords(
            'Account', 'Id', new List<String>{ String.valueOf(acc.Id), 'not-a-valid-id' }, null
        );
        Test.stopTest();

        Map<String, String> statusByValue = new Map<String, String>();
        for (BulkEditWrappers.MatchResult r : results) {
            statusByValue.put(r.searchValue, r.status);
        }
        System.assertEquals('Matched', statusByValue.get(String.valueOf(acc.Id)));
        System.assertEquals('NotFound', statusByValue.get('not-a-valid-id'));
    }

    @isTest
    static void testMatchRecords_byId_withTargetField_returnsCurrentValue() {
        Account acc = [SELECT Id FROM Account WHERE AccountNumber = 'PU-0' LIMIT 1];
        update new Account(Id = acc.Id, Site = 'Old Site By Id');

        Test.startTest();
        List<BulkEditWrappers.MatchResult> results = BulkPasteUpdateController.matchRecords(
            'Account', 'Id', new List<String>{ String.valueOf(acc.Id) }, 'Site'
        );
        Test.stopTest();

        System.assertEquals('Matched', results[0].status);
        System.assertEquals('Old Site By Id', results[0].currentValue);
    }

    @isTest
    static void testMatchRecords_byId_allInvalid_noQueryRun() {
        Test.startTest();
        List<BulkEditWrappers.MatchResult> results = BulkPasteUpdateController.matchRecords(
            'Account', 'Id', new List<String>{ 'nope', 'still-nope' }, null
        );
        Test.stopTest();

        for (BulkEditWrappers.MatchResult r : results) {
            System.assertEquals('NotFound', r.status);
        }
    }

    @isTest
    static void testMatchRecords_numericSearchField() {
        Test.startTest();
        List<BulkEditWrappers.MatchResult> results = BulkPasteUpdateController.matchRecords(
            'Account', 'AnnualRevenue', new List<String>{ '5000', 'not-a-number' }, null
        );
        Test.stopTest();

        Map<String, String> statusByValue = new Map<String, String>();
        for (BulkEditWrappers.MatchResult r : results) {
            statusByValue.put(r.searchValue, r.status);
        }
        System.assertEquals('Matched', statusByValue.get('5000'), 'A valid numeric literal should match the seeded revenue account');
        System.assertEquals('NotFound', statusByValue.get('not-a-number'), 'A value that fails numeric conversion should be excluded from the query and end up NotFound');
    }

    @isTest
    static void testMatchRecords_booleanSearchField() {
        // Case.IsEscalated instead of an Account field: Account has no
        // boolean field that's actually DML-writable in this org (IsPartner
        // and IsCustomerPortal both describe as updateable but are
        // system-managed and reject direct writes; Excl__c is SEMBEQ-only).
        // Same precedent as testMatchRecords_objectWithoutNameField_stillWorks
        // below, which also reaches for Case to cover a case Account can't.
        insert new List<Case>{
            new Case(Subject = 'PU Escalated', IsEscalated = true),
            new Case(Subject = 'PU Not Escalated 1', IsEscalated = false),
            new Case(Subject = 'PU Not Escalated 2', IsEscalated = false)
        };

        Test.startTest();
        List<BulkEditWrappers.MatchResult> results = BulkPasteUpdateController.matchRecords(
            'Case', 'IsEscalated', new List<String>{ 'true', 'false' }, null
        );
        Test.stopTest();

        Map<String, String> statusByValue = new Map<String, String>();
        for (BulkEditWrappers.MatchResult r : results) {
            statusByValue.put(r.searchValue, r.status);
        }
        System.assertEquals('Matched', statusByValue.get('true'), 'Only the seeded escalated Case has IsEscalated = true');
        // Two seeded Cases share IsEscalated = false — asserting the
        // Duplicate branch, not a NotFound one.
        System.assertEquals('Duplicate', statusByValue.get('false'));
    }

    @isTest
    static void testMatchRecords_dateSearchField_matchedAndNotFound() {
        // Contact.Birthdate instead of an Account field: Account has no
        // standard DATE-type field, and this is the only path that exercises
        // BulkPasteUpdateService.normalizeFieldValue's DATE cast branch
        // (SObject.get() boxes a Date as a Datetime-at-midnight string) and
        // toSearchLiteral's DATE branch (Date.valueOf on the pasted string).
        insert new Contact(LastName = 'PU Birthdate Test', Birthdate = Date.newInstance(1990, 5, 15));

        Test.startTest();
        List<BulkEditWrappers.MatchResult> results = BulkPasteUpdateController.matchRecords(
            'Contact', 'Birthdate', new List<String>{ '1990-05-15', '2000-01-01' }, null
        );
        Test.stopTest();

        Map<String, String> statusByValue = new Map<String, String>();
        for (BulkEditWrappers.MatchResult r : results) {
            statusByValue.put(r.searchValue, r.status);
        }
        System.assertEquals('Matched', statusByValue.get('1990-05-15'), 'Existing Contact Birthdate should match the pasted date literal');
        System.assertEquals('NotFound', statusByValue.get('2000-01-01'), 'No Contact has this Birthdate');
    }

    @isTest
    static void testMatchRecords_duplicatePastedLinesDeduped() {
        Test.startTest();
        List<BulkEditWrappers.MatchResult> results = BulkPasteUpdateController.matchRecords(
            'Account', 'AccountNumber', new List<String>{ 'PU-0', 'PU-0', ' PU-0 ', '' }, null
        );
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Repeated/blank/whitespace-only pasted lines should collapse to a single match row');
        System.assertEquals('Matched', results[0].status);
    }

    @isTest
    static void testMatchRecords_blankSearchValues_throws() {
        Boolean threw = false;
        try {
            BulkPasteUpdateController.matchRecords('Account', 'AccountNumber', new List<String>(), null);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Expected an exception when no values are pasted');
    }

    @isTest
    static void testMatchRecords_blankSearchField_throws() {
        Boolean threw = false;
        try {
            BulkPasteUpdateController.matchRecords('Account', '', new List<String>{ 'PU-0' }, null);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Expected an exception when no search field is chosen');
    }

    @isTest
    static void testMatchRecords_tooManyValues_throws() {
        List<String> tooMany = new List<String>();
        for (Integer i = 0; i < 5001; i++) {
            tooMany.add('V-' + i);
        }
        Boolean threw = false;
        try {
            BulkPasteUpdateController.matchRecords('Account', 'AccountNumber', tooMany, null);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Expected an exception when too many values are pasted');
    }

    @isTest
    static void testMatchRecords_unknownSearchField_throws() {
        Boolean threw = false;
        try {
            BulkPasteUpdateController.matchRecords('Account', 'Not_A_Real_Field__c', new List<String>{ 'x' }, null);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Expected an exception for an unknown search field');
    }

    @isTest
    static void testMatchRecords_allBlankAfterTrim_throws() {
        // Distinct from the earlier isEmpty() case — this list is non-empty
        // but every line collapses to blank after trim, so it only throws
        // once dedup has run.
        Boolean threw = false;
        try {
            BulkPasteUpdateController.matchRecords('Account', 'AccountNumber', new List<String>{ '   ', '', '  ' }, null);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Expected an exception when every pasted line is blank/whitespace-only');
    }

    @isTest
    static void testMatchRecords_allValuesFailTypeConversion_allNotFound() {
        Test.startTest();
        List<BulkEditWrappers.MatchResult> results = BulkPasteUpdateController.matchRecords(
            'Account', 'AnnualRevenue', new List<String>{ 'abc', 'xyz' }, null
        );
        Test.stopTest();

        System.assertEquals(2, results.size());
        for (BulkEditWrappers.MatchResult r : results) {
            System.assertEquals('NotFound', r.status, 'When every pasted value fails numeric conversion, no query should even run and all rows end up NotFound');
        }
    }

    @isTest
    static void testMatchRecords_caseMismatchedTextValue_notFound() {
        Test.startTest();
        List<BulkEditWrappers.MatchResult> results = BulkPasteUpdateController.matchRecords(
            'Account', 'AccountNumber', new List<String>{ 'pu-0' }, null
        );
        Test.stopTest();

        // SOQL's IN clause matches text case-insensitively, so this query
        // does find the seeded 'PU-0' account, but resultsByValue is keyed
        // by the exact-case pasted string — the Map lookup misses, so the
        // row is classified NotFound rather than Matched.
        System.assertEquals('NotFound', results[0].status);
    }

    @isTest
    static void testMatchRecords_objectWithoutNameField_stillWorks() {
        Test.startTest();
        List<BulkEditWrappers.MatchResult> results = BulkPasteUpdateController.matchRecords(
            'Case', 'Subject', new List<String>{ 'no-such-subject-xyz' }, null
        );
        Test.stopTest();

        // Case has no Name field — resolveDisplayFieldName() falls back to
        // null and the search still completes normally.
        System.assertEquals('NotFound', results[0].status);
    }

    // ---------------------------------------------------------------
    // startPasteUpdate
    // ---------------------------------------------------------------

    @isTest
    static void testStartPasteUpdate_perRowDistinctValues() {
        List<Account> accts = [SELECT Id, AccountNumber FROM Account WHERE AccountNumber IN ('PU-0', 'PU-1', 'PU-2')];
        Map<String, String> newValueByRecordId = new Map<String, String>();
        Integer i = 0;
        for (Account a : accts) {
            newValueByRecordId.put(String.valueOf(a.Id), 'NewSite-' + i);
            i++;
        }

        Test.startTest();
        BulkEditWrappers.BulkEditJobResult jobResult = BulkPasteUpdateController.startPasteUpdate(
            'Account', 'Account', 'Site', 'Site', 'Account Number', newValueByRecordId, accts.size(), 'AccountNumber IN (...)'
        );
        Test.stopTest();

        System.assertNotEquals(null, jobResult.logId);
        System.assertNotEquals(null, jobResult.batchJobId);

        Map<Id, Account> updated = new Map<Id, Account>([SELECT Id, Site FROM Account WHERE Id IN :newValueByRecordId.keySet()]);
        for (Id recId : newValueByRecordId.keySet()) {
            System.assertEquals(newValueByRecordId.get(recId), updated.get(recId).Site);
        }

        Bulk_Edit_Log__c logRec = [SELECT Status__c, Records_Affected__c, Field_API_Name__c FROM Bulk_Edit_Log__c WHERE Id = :jobResult.logId];
        System.assertEquals('Completed', logRec.Status__c);
        System.assertEquals(accts.size(), logRec.Records_Affected__c.intValue());
        System.assertEquals('Site', logRec.Field_API_Name__c);
    }

    @isTest
    static void testStartPasteUpdate_uniformBlankValueClearsField() {
        List<Account> accts = [SELECT Id FROM Account WHERE AccountNumber IN ('PU-0', 'PU-1')];
        update new List<Account>{
            new Account(Id = accts[0].Id, Site = 'Old Site A'),
            new Account(Id = accts[1].Id, Site = 'Old Site B')
        };

        Map<String, String> newValueByRecordId = new Map<String, String>();
        for (Account a : accts) {
            newValueByRecordId.put(String.valueOf(a.Id), '');
        }

        Test.startTest();
        BulkPasteUpdateController.startPasteUpdate(
            'Account', 'Account', 'Site', 'Site', 'Account Number', newValueByRecordId, accts.size(), 'blank run'
        );
        Test.stopTest();

        List<Account> updated = [SELECT Site FROM Account WHERE Id IN :newValueByRecordId.keySet()];
        for (Account a : updated) {
            System.assertEquals(null, a.Site);
        }
    }

    @isTest
    static void testStartPasteUpdate_emptyMap_throws() {
        Boolean threw = false;
        try {
            BulkPasteUpdateController.startPasteUpdate('Account', 'Account', 'Site', 'Site', 'Account Number', new Map<String, String>(), 0, 'x');
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Expected an exception when no records were matched');
    }

    @isTest
    static void testStartPasteUpdate_valueTooLong_throws() {
        Account acc = [SELECT Id FROM Account WHERE AccountNumber = 'PU-0' LIMIT 1];
        Map<String, String> newValueByRecordId = new Map<String, String>{
            String.valueOf(acc.Id) => ''.rightPad(300, 'X')
        };

        Boolean threw = false;
        try {
            BulkPasteUpdateController.startPasteUpdate('Account', 'Account', 'Site', 'Site', 'Account Number', newValueByRecordId, 1, 'x');
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Expected an exception when a pasted new value exceeds the target field length');
    }

    @isTest
    static void testStartPasteUpdate_noCreateAccess_throws() {
        Account acc = [SELECT Id FROM Account WHERE AccountNumber = 'PU-0' LIMIT 1];
        Map<String, String> newValueByRecordId = new Map<String, String>{ String.valueOf(acc.Id) => 'x' };

        BulkPasteUpdateController.TEST_FORCE_NO_CREATE_ACCESS = true;
        Boolean threw = false;
        try {
            BulkPasteUpdateController.startPasteUpdate('Account', 'Account', 'Site', 'Site', 'Account Number', newValueByRecordId, 1, 'x');
        } catch (AuraHandledException ex) {
            threw = true;
        } finally {
            BulkPasteUpdateController.TEST_FORCE_NO_CREATE_ACCESS = false;
        }
        System.assert(threw, 'Expected the forced no-create-access branch to throw');
    }

    @isTest
    static void testStartPasteUpdate_unexpectedException_forced_throws() {
        Account acc = [SELECT Id FROM Account WHERE AccountNumber = 'PU-0' LIMIT 1];
        Map<String, String> newValueByRecordId = new Map<String, String>{ String.valueOf(acc.Id) => 'x' };

        BulkEditService.TEST_FORCE_OBJECT_NOT_EDITABLE = true;
        Boolean threw = false;
        try {
            BulkPasteUpdateController.startPasteUpdate('Account', 'Account', 'Site', 'Site', 'Account Number', newValueByRecordId, 1, 'x');
        } catch (AuraHandledException ex) {
            threw = true;
        } finally {
            BulkEditService.TEST_FORCE_OBJECT_NOT_EDITABLE = false;
        }
        System.assert(threw, 'Expected the generic Exception branch to wrap and rethrow as an AuraHandledException');
    }

    @isTest
    static void testStartPasteUpdate_longSearchSummary_truncatedForLog() {
        Account acc = [SELECT Id FROM Account WHERE AccountNumber = 'PU-0' LIMIT 1];
        Map<String, String> newValueByRecordId = new Map<String, String>{ String.valueOf(acc.Id) => 'x' };
        String longSummary = ''.rightPad(300, 'S');

        Test.startTest();
        BulkEditWrappers.BulkEditJobResult jobResult = BulkPasteUpdateController.startPasteUpdate(
            'Account', 'Account', 'Site', 'Site', 'Account Number', newValueByRecordId, 1, longSummary
        );
        Test.stopTest();

        Bulk_Edit_Log__c logRec = [SELECT New_Value__c FROM Bulk_Edit_Log__c WHERE Id = :jobResult.logId];
        System.assertEquals(255, logRec.New_Value__c.length(), 'A searchSummary longer than 255 chars must be truncated before being written to the log');
    }

    // ---------------------------------------------------------------
    // startPasteUpdate -> Account_GenerateID trigger reuse (Regenerate ID tab)
    // ---------------------------------------------------------------

    // Proves the "Regenerate ID" tab's core design claim for Account: it does
    // NOT need any new Apex, because Account_GenerateID.trigger's before-update
    // branch already reassigns ID_Account__c for us as soon as
    // startPasteUpdate() writes a blank value to it — see RegenerateIdService's
    // class comment. Account_GenerateID always assigns ID_Account__c on insert
    // for a recognized RecordType (Trigger.isInsert short-circuits mustAssign),
    // so there is no way to leave a freshly inserted test Account's
    // ID_Account__c genuinely null; instead this proves the same mechanism the
    // real workflow relies on — blanking an existing value and updating causes
    // a fresh one to be assigned in that same transaction.
    @isTest
    static void testStartPasteUpdate_accountIdField_blankValueTriggersRegeneration() {
        // "Eglise" is the only Account RecordType DeveloperName present — and recognized by
        // Account_GenerateID — in both SEMBEQ and AEBEQ (each org ships its own divergent
        // trigger with org-specific RecordType prefixes), so it's the one portable choice
        // for a test that must pass against either org's production trigger.
        Id rtEglise = [SELECT Id FROM RecordType WHERE SObjectType = 'Account' AND DeveloperName = 'Eglise' LIMIT 1].Id;

        Database.DMLOptions dmo = new Database.DMLOptions();
        dmo.DuplicateRuleHeader.allowSave = true;
        dmo.DuplicateRuleHeader.runAsCurrentUser = true;
        Account acc = new Account(Name = 'RegenId Business Account', RecordTypeId = rtEglise);
        Database.SaveResult sr = Database.insert(new List<SObject>{ acc }, dmo)[0];
        System.assert(sr.isSuccess(), 'Account insert failed: ' + (sr.getErrors().isEmpty() ? 'unknown' : sr.getErrors()[0].getMessage()));
        acc.Id = sr.getId();

        acc = [SELECT Id, ID_Account__c FROM Account WHERE Id = :acc.Id LIMIT 1];
        System.assert(String.isNotBlank(acc.ID_Account__c), 'Account_GenerateID must assign ID_Account__c on insert for a recognized RecordType');
        String originalValue = acc.ID_Account__c;

        Map<String, String> newValueByRecordId = new Map<String, String>{ String.valueOf(acc.Id) => '' };

        Test.startTest();
        BulkPasteUpdateController.startPasteUpdate(
            'Account', 'Account', 'ID_Account__c', 'ID Account', 'Id', newValueByRecordId, 1, 'regen id test'
        );
        Test.stopTest();

        Account updated = [SELECT ID_Account__c FROM Account WHERE Id = :acc.Id LIMIT 1];
        System.assert(String.isNotBlank(updated.ID_Account__c), 'Blanking ID_Account__c via startPasteUpdate must cause Account_GenerateID to reassign a fresh value in the same transaction');
        System.assertNotEquals(originalValue, updated.ID_Account__c, 'The reassigned value should be freshly generated, not the original leftover value');
    }
}
