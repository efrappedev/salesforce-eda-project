@isTest
private class BulkRecordTypeControllerTest {

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
        Id rt2 = activeInfos[1].getRecordTypeId();

        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 3; i++) {
            accounts.add(new Account(Name = 'BRT Lopez RT1 ' + i, RecordTypeId = rt1));
        }
        for (Integer i = 0; i < 3; i++) {
            accounts.add(new Account(Name = 'BRT Other RT2 ' + i, RecordTypeId = rt2));
        }
        insert accounts;
    }

    @isTest
    static void testGetRecordTypesForObject_excludesMasterAndInactive() {
        Test.startTest();
        List<BulkEditWrappers.RecordTypeOption> options = BulkRecordTypeController.getRecordTypesForObject();
        Test.stopTest();

        List<Schema.RecordTypeInfo> expected = getActiveNonMasterRecordTypeInfos();
        System.assertEquals(expected.size(), options.size(), 'Should return exactly the active, non-Master Record Types');

        Set<Id> returnedIds = new Set<Id>();
        for (BulkEditWrappers.RecordTypeOption opt : options) {
            returnedIds.add(opt.recordTypeId);
        }
        for (Schema.RecordTypeInfo info : expected) {
            System.assert(returnedIds.contains(info.getRecordTypeId()), 'Expected Record Type ' + info.getName() + ' to be included');
        }
    }

    @isTest
    static void testGetRecordTypesForObject_forcedException_throws() {
        BulkRecordTypeService.TEST_FORCE_SERVICE_EXCEPTION = true;
        Boolean threw = false;
        try {
            BulkRecordTypeController.getRecordTypesForObject();
        } catch (AuraHandledException ex) {
            threw = true;
        } finally {
            BulkRecordTypeService.TEST_FORCE_SERVICE_EXCEPTION = false;
        }
        System.assert(threw, 'Expected the forced service exception to surface as an AuraHandledException');
    }

    @isTest
    static void testGetSearchableFields_noAccountAccess_throws() {
        BulkRecordTypeService.TEST_FORCE_ACCOUNT_NOT_ACCESSIBLE = true;
        Boolean threw = false;
        try {
            BulkRecordTypeController.getSearchableFields();
        } catch (AuraHandledException ex) {
            threw = true;
        } finally {
            BulkRecordTypeService.TEST_FORCE_ACCOUNT_NOT_ACCESSIBLE = false;
        }
        System.assert(threw, 'Expected an exception when the running user has no read access to Account');
    }

    @isTest
    static void testSearchRecords_noAccountAccess_throws() {
        BulkRecordTypeService.TEST_FORCE_ACCOUNT_NOT_ACCESSIBLE = true;
        Boolean threw = false;
        try {
            BulkRecordTypeController.searchRecords(null, 'Name', 'Lopez');
        } catch (AuraHandledException ex) {
            threw = true;
        } finally {
            BulkRecordTypeService.TEST_FORCE_ACCOUNT_NOT_ACCESSIBLE = false;
        }
        System.assert(threw, 'Expected an exception when the running user has no read access to Account');
    }

    @isTest
    static void testGetSearchableFields() {
        Test.startTest();
        List<BulkEditWrappers.FieldOption> fields = BulkRecordTypeController.getSearchableFields();
        Test.stopTest();

        Set<String> apiNames = new Set<String>();
        for (BulkEditWrappers.FieldOption f : fields) {
            apiNames.add(f.apiName);
        }
        System.assert(apiNames.contains('Name'), 'Name should be searchable');
        System.assert(!apiNames.contains('AnnualRevenue'), 'Numeric fields should not be offered for text search');
        System.assert(!apiNames.contains('Id'), 'Id should never be offered');
    }

    @isTest
    static void testGetSearchableFields_forcedException_throws() {
        BulkRecordTypeService.TEST_FORCE_SERVICE_EXCEPTION = true;
        Boolean threw = false;
        try {
            BulkRecordTypeController.getSearchableFields();
        } catch (AuraHandledException ex) {
            threw = true;
        } finally {
            BulkRecordTypeService.TEST_FORCE_SERVICE_EXCEPTION = false;
        }
        System.assert(threw, 'Expected the forced service exception to surface as an AuraHandledException');
    }

    @isTest
    static void testSearchRecords_byRecordTypeOnly() {
        Id rt1 = getActiveNonMasterRecordTypeInfos()[0].getRecordTypeId();

        Test.startTest();
        List<BulkEditWrappers.RecordSearchResult> results = BulkRecordTypeController.searchRecords(rt1, null, null);
        Test.stopTest();

        System.assertEquals(3, results.size(), 'Only the 3 accounts tagged with the first Record Type should match');
        for (BulkEditWrappers.RecordSearchResult r : results) {
            System.assertEquals(rt1, r.recordTypeId);
        }
    }

    @isTest
    static void testSearchRecords_byTermOnly() {
        Test.startTest();
        List<BulkEditWrappers.RecordSearchResult> results = BulkRecordTypeController.searchRecords(null, 'Name', 'Lopez');
        Test.stopTest();

        System.assertEquals(3, results.size(), 'Only the 3 Lopez-named accounts should match');
    }

    @isTest
    static void testSearchRecords_combined() {
        Id rt2 = getActiveNonMasterRecordTypeInfos()[1].getRecordTypeId();

        Test.startTest();
        List<BulkEditWrappers.RecordSearchResult> results = BulkRecordTypeController.searchRecords(rt2, 'Name', 'Other');
        Test.stopTest();

        System.assertEquals(3, results.size());
    }

    @isTest
    static void testSearchRecords_noCriteria_throws() {
        Boolean threw = false;
        try {
            BulkRecordTypeController.searchRecords(null, null, null);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Expected an exception when neither Record Type nor search term is given');
    }

    @isTest
    static void testSearchRecords_disallowedFieldType_throws() {
        Boolean threw = false;
        try {
            BulkRecordTypeController.searchRecords(null, 'AnnualRevenue', 'foo');
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Expected an exception for a non-whitelisted search field type');
    }

    @isTest
    static void testSearchRecords_unknownField_throws() {
        Boolean threw = false;
        try {
            BulkRecordTypeController.searchRecords(null, 'Not_A_Real_Field__c', 'foo');
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Expected an exception for an unknown field');
    }

    @isTest
    static void testStartRecordTypeChange_createsLogAndUpdatesRecords() {
        List<Account> toChange = [SELECT Id FROM Account WHERE Name LIKE 'BRT Lopez RT1%'];
        List<Schema.RecordTypeInfo> rts = getActiveNonMasterRecordTypeInfos();
        Id newRt = rts[1].getRecordTypeId();
        String newRtLabel = rts[1].getName();

        List<Id> ids = new List<Id>();
        for (Account a : toChange) {
            ids.add(a.Id);
        }
        String csv = String.join(ids, ',');

        Test.startTest();
        BulkEditWrappers.BulkEditJobResult jobResult = BulkRecordTypeController.startRecordTypeChange(
            csv, ids.size(), newRt, newRtLabel, 'Record Type = RT1'
        );
        Test.stopTest();

        System.assertNotEquals(null, jobResult.logId);
        System.assertNotEquals(null, jobResult.batchJobId);

        List<Account> updated = [SELECT RecordTypeId FROM Account WHERE Id IN :ids];
        for (Account a : updated) {
            System.assertEquals(newRt, a.RecordTypeId);
        }

        Bulk_Edit_Log__c logRec = [
            SELECT Field_API_Name__c, Field_Label__c, Object_Type__c, Status__c, Records_Affected__c
            FROM Bulk_Edit_Log__c
            WHERE Id = :jobResult.logId
        ];
        System.assertEquals('RecordTypeId', logRec.Field_API_Name__c);
        System.assertEquals('Record Type', logRec.Field_Label__c);
        System.assertEquals('Account', logRec.Object_Type__c);
        System.assertEquals('Completed', logRec.Status__c);
        System.assertEquals(3, logRec.Records_Affected__c.intValue());
    }

    @isTest
    static void testStartRecordTypeChange_longSearchSummary_truncatedSafely() {
        // searchSummary is a free-form description built client-side from the
        // user's search term, which is not itself length-bound like a real
        // field value — a term long enough to push the wrapped summary past
        // Old_Value_Display__c's 255-char limit must be truncated for
        // storage rather than fail the log insert outright.
        List<Account> toChange = [SELECT Id FROM Account WHERE Name LIKE 'BRT Lopez RT1%'];
        List<Schema.RecordTypeInfo> rts = getActiveNonMasterRecordTypeInfos();
        Id newRt = rts[1].getRecordTypeId();

        List<Id> ids = new List<Id>();
        for (Account a : toChange) {
            ids.add(a.Id);
        }
        String csv = String.join(ids, ',');
        String longSummary = 'Name contains \'' + ''.rightPad(300, 'X') + '\'';
        System.assert(longSummary.length() > 255, 'Test setup should produce a summary longer than the field limit');

        Test.startTest();
        BulkEditWrappers.BulkEditJobResult jobResult = BulkRecordTypeController.startRecordTypeChange(
            csv, ids.size(), newRt, rts[1].getName(), longSummary
        );
        Test.stopTest();

        Bulk_Edit_Log__c logRec = [SELECT Old_Value_Display__c FROM Bulk_Edit_Log__c WHERE Id = :jobResult.logId];
        System.assertEquals(255, logRec.Old_Value_Display__c.length());
        System.assertEquals(longSummary.substring(0, 255), logRec.Old_Value_Display__c);
    }

    @isTest
    static void testStartRecordTypeChange_noSelection_throws() {
        Boolean threw = false;
        try {
            BulkRecordTypeController.startRecordTypeChange(null, 0, null, null, null);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Expected an exception when no records are selected');
    }

    @isTest
    static void testStartRecordTypeChange_noNewRecordType_throws() {
        Boolean threw = false;
        try {
            BulkRecordTypeController.startRecordTypeChange('001000000000001AAA', 1, null, null, null);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Expected an exception when no target Record Type is given');
    }

    @isTest
    static void testStartRecordTypeChange_unexpectedException_forced_throws() {
        // Forces the generic catch(Exception) branch (as opposed to the
        // catch(AuraHandledException)/rethrow branch) by making the
        // downstream resolveObjectType() call throw a plain BulkEditException.
        BulkEditService.TEST_FORCE_OBJECT_NOT_EDITABLE = true;
        Boolean threw = false;
        try {
            BulkRecordTypeController.startRecordTypeChange('001000000000001AAA', 1, UserInfo.getUserId(), 'x', 'y');
        } catch (AuraHandledException ex) {
            threw = true;
        } finally {
            BulkEditService.TEST_FORCE_OBJECT_NOT_EDITABLE = false;
        }
        System.assert(threw, 'Expected the generic Exception branch to wrap and rethrow as an AuraHandledException');
    }

    @isTest
    static void testStartRecordTypeChange_noCreateAccess_forced_throws() {
        BulkRecordTypeController.TEST_FORCE_NO_CREATE_ACCESS = true;
        Boolean threw = false;
        try {
            BulkRecordTypeController.startRecordTypeChange('001000000000001AAA', 1, UserInfo.getUserId(), 'x', 'y');
        } catch (AuraHandledException ex) {
            threw = true;
        } finally {
            BulkRecordTypeController.TEST_FORCE_NO_CREATE_ACCESS = false;
        }
        System.assert(threw, 'Expected the forced no-create-access branch to throw');
    }
}
