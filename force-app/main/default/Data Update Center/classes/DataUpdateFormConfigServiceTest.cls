@IsTest(SeeAllData=false)
private class DataUpdateFormConfigServiceTest {

    private static Integer activeFieldCount(String formDeveloperName) {
        Integer n = 0;
        for (Data_Update_Form_Field__mdt fm : DucFormConfigStore.fields(formDeveloperName)) {
            if (fm.Is_Active__c == true) n++;
        }
        return n;
    }

    private static final String FORM_NAME = 'AEBEQ_Account_Update';

    @IsTest
    static void getForm_Success_ReturnsConfigWithFieldsAndIds() {
        Test.startTest();
        DataUpdateFormConfigService.FormConfig config = DataUpdateFormConfigService.getForm(FORM_NAME);
        Test.stopTest();

        System.assertEquals('Account', config.targetObjectApiName);
        System.assertEquals('IsPersonAccount', config.targetBaseFilterField);
        System.assertEquals(true, config.targetBaseFilterIsBoolean);
        System.assertEquals('ID_Account__c', config.identityField1ApiName);
        System.assertEquals('Exact', config.identityField1Comparison);
        System.assertEquals('LastName', config.identityField2ApiName);
        System.assertEquals('Normalized_Text', config.identityField2Comparison);
        System.assertNotEquals(null, config.requestOwnerQueueId);
        System.assertEquals(activeFieldCount(FORM_NAME), config.fields.size());
        System.assertEquals('FirstName', config.fields[0].fieldApiName);
        System.assertEquals('Data_Update_Locked__c', config.lockFieldApiName);
        System.assertEquals('Data_Update_Locked_Date__c', config.lockDateFieldApiName);
    }

    @IsTest
    static void getForm_BlankName_ThrowsNotFound() {
        Boolean threw = false;
        Test.startTest();
        try {
            DataUpdateFormConfigService.getForm('');
        } catch (DataUpdateFormConfigService.FormNotFoundException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'Blank form name must throw FormNotFoundException');
    }

    @IsTest
    static void getForm_UnknownName_ThrowsNotFound() {
        Boolean threw = false;
        Test.startTest();
        try {
            DataUpdateFormConfigService.getForm('DOES_NOT_EXIST_' + DateTime.now().getTime());
        } catch (DataUpdateFormConfigService.FormNotFoundException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'Unknown form name must throw FormNotFoundException');
    }

    @IsTest
    static void normalizeText_FoldsAccentsCaseAndSpaces() {
        Test.startTest();
        String result = DataUpdateFormConfigService.normalizeText('  Hébert  Saint  Pierre ');
        Test.stopTest();
        System.assertEquals('HEBERT SAINT PIERRE', result);
    }

    @IsTest
    static void normalizeText_BlankInput_ReturnsEmptyString() {
        Test.startTest();
        System.assertEquals('', DataUpdateFormConfigService.normalizeText(null));
        System.assertEquals('', DataUpdateFormConfigService.normalizeText('   '));
        Test.stopTest();
    }

    @IsTest
    static void matchesIdentity_Exact_MatchAndMismatch() {
        Test.startTest();
        System.assert(DataUpdateFormConfigService.matchesIdentity('I-000123', 'I-000123', 'Exact'));
        System.assertEquals(false, DataUpdateFormConfigService.matchesIdentity('I-000123', 'I-000124', 'Exact'));
        Test.stopTest();
    }

    @IsTest
    static void matchesIdentity_NormalizedText_MatchAndMismatch() {
        Test.startTest();
        System.assert(DataUpdateFormConfigService.matchesIdentity('Hébert', 'hebert', 'Normalized_Text'));
        System.assertEquals(false, DataUpdateFormConfigService.matchesIdentity('Hébert', 'Gagnon', 'Normalized_Text'));
        Test.stopTest();
    }

    // ─── Test helpers ────────────────────────────────────────────────────

    private static Data_Update_Form__mdt fakeForm(String extraJson) {
        return (Data_Update_Form__mdt) JSON.deserialize(
            '{"DeveloperName":"Fake_Test_Form","MasterLabel":"Fake","Target_Object_API_Name__c":"Account",'
            + '"Identity_Field_1_API_Name__c":"Name","Identity_Field_1_Comparison__c":"Exact",'
            + '"Subject_Template__c":"{RecordName}","Is_Active__c":true' + extraJson + '}',
            Data_Update_Form__mdt.class);
    }

    private static List<Data_Update_Form_Field__mdt> fakeFields(String jsonArray) {
        return (List<Data_Update_Form_Field__mdt>) JSON.deserialize(jsonArray, List<Data_Update_Form_Field__mdt>.class);
    }

    private static DataUpdateFormConfigService.FormFieldConfig histFc(String obj, String valueF, String dateF,
            String acctF, String logF, String srcDate) {
        DataUpdateFormConfigService.FormFieldConfig fc = new DataUpdateFormConfigService.FormFieldConfig();
        fc.fieldApiName = 'Eglise_Attendance__c';
        fc.historyMode = 'Historize';
        fc.historyTargetObjectApiName = obj;
        fc.historyTargetValueFieldApiName = valueF;
        fc.historyTargetDateFieldApiName = dateF;
        fc.historyTargetAccountFieldApiName = acctF;
        fc.historyTargetLogFieldApiName = logF;
        fc.historyDateSourceFieldApiName = srcDate;
        return fc;
    }

    private static Boolean historyMappingThrows(DataUpdateFormConfigService.FormFieldConfig fc) {
        try {
            DataUpdateFormConfigService.validateHistoryMapping(fc, 'Account');
        } catch (DataUpdateFormConfigService.FormValidationException e) {
            return true;
        }
        return false;
    }

    private static Boolean filterThrows(String path) {
        try {
            DataUpdateFormConfigService.assertFilterFieldExists(Schema.SObjectType.Account.fields.getMap(), path, 'Account');
        } catch (DataUpdateFormConfigService.FormValidationException e) {
            return true;
        }
        return false;
    }

    private static Boolean schemaThrows(DataUpdateFormConfigService.FormConfig config) {
        try {
            DataUpdateFormConfigService.validateAgainstSchema(config);
        } catch (DataUpdateFormConfigService.FormValidationException e) {
            return true;
        }
        return false;
    }

    // ─── Real forms: relationship filter, Historize mapping, review mode ─

    @IsTest
    static void getForm_EgliseForm_ResolvesRelationshipFilterAndHistorize() {
        // The église questions can all be switched off in Settings: the real records, turned on.
        List<Data_Update_Form_Field__mdt> egliseFields = DucFormConfigStore.fields('AEBEQ_Eglise_Update');
        System.assert(!egliseFields.isEmpty(), 'The église form ships its catalog fields');
        DataUpdateFormConfigService.testFieldMdts = (List<Data_Update_Form_Field__mdt>) JSON.deserialize(
            JSON.serialize(egliseFields).replace('"Is_Active__c":false', '"Is_Active__c":true')
                .replace('"Is_Hidden__c":true', '"Is_Hidden__c":false'),
            List<Data_Update_Form_Field__mdt>.class);
        Test.startTest();
        DataUpdateFormConfigService.FormConfig config = DataUpdateFormConfigService.getForm('AEBEQ_Eglise_Update');
        // The église history fields can be switched off in Settings; the review catalog still lists them.
        DataUpdateFormConfigService.FormConfig catalog = DataUpdateFormConfigService.getFormForReview('AEBEQ_Eglise_Update');
        Test.stopTest();
        System.assertEquals('RecordType.DeveloperName', config.targetBaseFilterField);
        System.assertEquals(false, config.targetBaseFilterIsBoolean);
        Boolean hasHistorize = false;
        for (DataUpdateFormConfigService.FormFieldConfig fc : catalog.fields) {
            if (fc.historyMode == 'Historize') hasHistorize = true;
        }
        System.assert(hasHistorize, 'Église form must carry at least one Historize field');
    }

    @IsTest
    static void getFormForReview_IncludesInactiveCatalogFields() {
        Test.startTest();
        DataUpdateFormConfigService.FormConfig review = DataUpdateFormConfigService.getFormForReview(FORM_NAME);
        DataUpdateFormConfigService.FormConfig pub = DataUpdateFormConfigService.getForm(FORM_NAME);
        Test.stopTest();
        System.assert(review.fields.size() >= pub.fields.size(), 'Review mode never shows fewer fields than the public form');
    }

    @IsTest
    static void getFormBasic_RealUnknownAndBlank() {
        Test.startTest();
        DataUpdateFormConfigService.FormConfig basic = DataUpdateFormConfigService.getFormBasic(FORM_NAME);
        Integer notFound = 0;
        for (String name : new List<String>{ '', 'DOES_NOT_EXIST_' + DateTime.now().getTime() }) {
            try {
                DataUpdateFormConfigService.getFormBasic(name);
            } catch (DataUpdateFormConfigService.FormNotFoundException e) {
                notFound++;
            }
        }
        Test.stopTest();
        System.assertEquals('Account', basic.targetObjectApiName);
        System.assertEquals('Data_Update_Locked__c', basic.lockFieldApiName);
        System.assertEquals(0, basic.fields.size());
        System.assertEquals(2, notFound);
    }

    // ─── In-memory forms (test seams) ────────────────────────────────────

    @IsTest
    static void loadForm_NoActiveFields_PublicThrowsReviewAllowed() {
        DataUpdateFormConfigService.testFormMdt = fakeForm('');
        DataUpdateFormConfigService.testFieldMdts = new List<Data_Update_Form_Field__mdt>();
        Boolean threw = false;
        Test.startTest();
        try {
            DataUpdateFormConfigService.getForm('Fake_Test_Form');
        } catch (DataUpdateFormConfigService.FormValidationException e) {
            threw = true;
        }
        DataUpdateFormConfigService.FormConfig review = DataUpdateFormConfigService.getFormForReview('Fake_Test_Form');
        Test.stopTest();
        System.assert(threw, 'A form without active fields must not load publicly');
        System.assertEquals(0, review.fields.size());
        System.assertEquals('Name', review.recordNameFieldApiName);
        System.assertEquals(false, review.targetBaseFilterIsBoolean);
        System.assertEquals(null, review.requestOwnerQueueId);
    }

    @IsTest
    static void loadForm_HiddenField_OffPublicFormKeptInReview() {
        DataUpdateFormConfigService.testFormMdt = fakeForm('');
        DataUpdateFormConfigService.testFieldMdts = fakeFields('['
            + '{"Field_API_Name__c":"Phone","Is_Active__c":true,"Display_Order__c":1},'
            + '{"Field_API_Name__c":"Website","Is_Active__c":true,"Is_Hidden__c":true,"Display_Order__c":2}]');
        Test.startTest();
        DataUpdateFormConfigService.FormConfig pub = DataUpdateFormConfigService.getForm('Fake_Test_Form');
        DataUpdateFormConfigService.FormConfig review = DataUpdateFormConfigService.getFormForReview('Fake_Test_Form');
        Test.stopTest();
        System.assertEquals(1, pub.fields.size(), 'Hidden question must not be on the public form');
        System.assertEquals('Phone', pub.fields[0].fieldApiName);
        System.assertEquals(2, review.fields.size(), 'Review mode keeps the hidden question');
    }

    @IsTest
    static void loadForm_InactiveForm_PublicThrowsNotFound() {
        DataUpdateFormConfigService.testFormMdt = fakeForm(',"Is_Active__c":false');
        Boolean threw = false;
        Test.startTest();
        try {
            DataUpdateFormConfigService.getForm('Fake_Test_Form');
        } catch (DataUpdateFormConfigService.FormNotFoundException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'An inactive form must not load publicly');
    }

    @IsTest
    static void loadForm_ReviewMode_DropsInvalidInactiveFieldKeepsValidOne() {
        DataUpdateFormConfigService.testFormMdt = fakeForm('');
        DataUpdateFormConfigService.testFieldMdts = fakeFields('['
            + '{"Field_API_Name__c":"Phone","Is_Active__c":true,"Display_Order__c":1},'
            + '{"Field_API_Name__c":"Nope_Not_A_Field__c","Is_Active__c":false,"Display_Order__c":2},'
            + '{"Field_API_Name__c":"Website","Is_Active__c":false,"Display_Order__c":3}]');
        Test.startTest();
        DataUpdateFormConfigService.FormConfig review = DataUpdateFormConfigService.getFormForReview('Fake_Test_Form');
        DataUpdateFormConfigService.FormConfig pub = DataUpdateFormConfigService.getForm('Fake_Test_Form');
        Test.stopTest();
        System.assertEquals(2, review.fields.size(), 'Invalid inactive field dropped, valid one kept');
        System.assertEquals(1, pub.fields.size());
    }

    // ─── Schema validation branches ──────────────────────────────────────

    @IsTest
    static void validateAgainstSchema_UnknownObjectAndField_Throw() {
        DataUpdateFormConfigService.FormConfig badObject = new DataUpdateFormConfigService.FormConfig();
        badObject.targetObjectApiName = 'Nope_Not_An_Object__c';
        badObject.fields = new List<DataUpdateFormConfigService.FormFieldConfig>();

        DataUpdateFormConfigService.FormConfig badField = new DataUpdateFormConfigService.FormConfig();
        badField.targetObjectApiName = 'Account';
        badField.identityField1ApiName = 'Nope_Not_A_Field__c';
        badField.fields = new List<DataUpdateFormConfigService.FormFieldConfig>();

        Test.startTest();
        System.assert(schemaThrows(badObject));
        System.assert(schemaThrows(badField));
        Test.stopTest();
    }

    @IsTest
    static void validateHistoryMapping_EveryInvalidShape_Throws() {
        Test.startTest();
        System.assert(historyMappingThrows(histFc(null, null, null, null, null, null)), 'blank target');
        System.assert(historyMappingThrows(histFc('Nope_Not_An_Object__c', 'Value__c', null, null, null, null)), 'unknown object');
        System.assert(historyMappingThrows(histFc('Attendance_History__c', 'Account__c', null, null, null, null)), 'reference value field');
        System.assert(historyMappingThrows(histFc('Attendance_History__c', 'Value__c', 'Value__c', null, null, null)), 'non-date date field');
        System.assert(historyMappingThrows(histFc('Attendance_History__c', 'Value__c', 'Metric_Date__c', 'Value__c', null, null)), 'non-reference account field');
        System.assert(historyMappingThrows(histFc('Attendance_History__c', 'Value__c', 'Metric_Date__c', 'Account__c', 'Account__c', null)), 'log field pointing elsewhere');
        System.assertEquals(false, historyMappingThrows(histFc('Attendance_History__c', 'Value__c', 'Metric_Date__c', 'Account__c', 'Log__c', null)), 'valid mapping');
        Test.stopTest();
    }

    @IsTest
    static void validateField_NonDateHistorySource_Throws() {
        DataUpdateFormConfigService.FormFieldConfig fc =
            histFc('Attendance_History__c', 'Value__c', 'Metric_Date__c', 'Account__c', 'Log__c', 'Name');
        Boolean threw = false;
        Test.startTest();
        try {
            DataUpdateFormConfigService.validateField(fc, Schema.SObjectType.Account.fields.getMap(), 'Account');
        } catch (DataUpdateFormConfigService.FormValidationException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'A Text history date source must be rejected');
    }

    @IsTest
    static void assertFilterFieldExists_PathShapes() {
        Test.startTest();
        System.assert(filterThrows(''), 'blank path');
        System.assert(filterThrows('RecordType.Owner.Name'), 'too deep');
        System.assert(filterThrows('Nope_Rel.Name'), 'unknown relationship');
        System.assert(filterThrows('RecordType.Nope_Not_A_Field'), 'unknown leaf');
        System.assertEquals(false, filterThrows('RecordType.DeveloperName'));
        System.assertEquals(false, filterThrows('IsPersonAccount'));
        Test.stopTest();
    }

    @IsTest
    static void clearCache_BlankAndNamed_NeverThrow() {
        Test.startTest();
        DataUpdateFormConfigService.clearCache('');
        DataUpdateFormConfigService.clearCache(FORM_NAME);
        Test.stopTest();
        System.assert(true);
    }

    // ─── Postal codes ────────────────────────────────────────────────────

    @IsTest
    static void resolvePostalCountry_ProposedCurrentMissingAndNone() {
        Account inMemory = new Account();
        inMemory.put('PersonMailingCountry', 'Canada');
        User unqueried = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        Test.startTest();
        System.assertEquals('Canada', DataUpdateFormConfigService.resolvePostalCountry('PersonMailingPostalCode',
            new Map<String, Object>{ 'PersonMailingCountry' => 'Canada' }, null));
        System.assertEquals('Canada', DataUpdateFormConfigService.resolvePostalCountry('PersonMailingPostalCode',
            new Map<String, Object>{ 'PersonMailingCountry' => '' }, inMemory));
        System.assertEquals(null, DataUpdateFormConfigService.resolvePostalCountry('BillingPostalCode', null, unqueried));
        System.assertEquals(null, DataUpdateFormConfigService.resolvePostalCountry('BillingPostalCode', null, null));
        System.assertEquals(null, DataUpdateFormConfigService.resolvePostalCountry('BillingPostalCode', null, new Account()));
        Test.stopTest();
    }

    @IsTest
    static void formatPostalCode_AllCountryShapes() {
        Test.startTest();
        System.assertEquals('', DataUpdateFormConfigService.formatPostalCode('', 'Canada'));
        System.assertEquals('90210', DataUpdateFormConfigService.formatPostalCode('90210', 'USA'));
        System.assertEquals('H2X 1Y4', DataUpdateFormConfigService.formatPostalCode('h2x1y4', null));
        System.assertEquals('12345', DataUpdateFormConfigService.formatPostalCode('12345', null));
        System.assertEquals('H2X', DataUpdateFormConfigService.formatPostalCode('h2x', 'Canada'));
        System.assertEquals('H2X 1Y4', DataUpdateFormConfigService.formatPostalCode('h2x-1y4', 'CA'));
        Test.stopTest();
    }

    @IsTest
    static void isInvalidPostalCode_AllCountryShapes() {
        Test.startTest();
        System.assertEquals(false, DataUpdateFormConfigService.isInvalidPostalCode('', 'Canada'));
        System.assertEquals(false, DataUpdateFormConfigService.isInvalidPostalCode('H2X', 'USA'));
        System.assertEquals(false, DataUpdateFormConfigService.isInvalidPostalCode('H2X 1Y4', 'Canada'));
        System.assertEquals(true, DataUpdateFormConfigService.isInvalidPostalCode('H2X', 'Canada'));
        System.assertEquals(true, DataUpdateFormConfigService.isInvalidPostalCode('H2X', null));
        System.assertEquals(false, DataUpdateFormConfigService.isInvalidPostalCode('12345', null));
        Test.stopTest();
    }

    @IsTest
    static void findAndFormatPostalCodes_OnProposedMap() {
        Map<String, String> bad = new Map<String, String>{
            'FirstName' => 'Lucie', 'PersonMailingPostalCode' => 'H2X', 'PersonMailingCountry' => 'Canada'
        };
        Map<String, String> good = new Map<String, String>{
            'FirstName' => 'Lucie', 'PersonMailingPostalCode' => 'h2x1y4', 'PersonMailingCountry' => 'Canada'
        };
        Test.startTest();
        String invalidField = DataUpdateFormConfigService.findInvalidPostalCodeField(bad, null);
        String noneInvalid = DataUpdateFormConfigService.findInvalidPostalCodeField(good, null);
        DataUpdateFormConfigService.formatPostalCodes(good, null);
        Test.stopTest();
        System.assertEquals('PersonMailingPostalCode', invalidField);
        System.assertEquals(null, noneInvalid);
        System.assertEquals('H2X 1Y4', good.get('PersonMailingPostalCode'));
        System.assertEquals('Lucie', good.get('FirstName'));
    }

    // ─── History_Only ───────────────────────────────────────────────────────

    private static DataUpdateFormConfigService.FormFieldConfig histOnlyFc(String key, String acctF, String dateF) {
        DataUpdateFormConfigService.FormFieldConfig fc = histFc('Attendance_History__c', 'Value__c', dateF, acctF, 'Log__c', null);
        fc.fieldApiName = key;
        fc.historyMode = DataUpdateFormConfigService.HISTORY_ONLY;
        return fc;
    }

    private static Boolean historyOnlyThrows(DataUpdateFormConfigService.FormFieldConfig fc) {
        try {
            DataUpdateFormConfigService.validateField(fc, Schema.SObjectType.Account.fields.getMap(), 'Account');
        } catch (DataUpdateFormConfigService.FormValidationException e) {
            return true;
        }
        return false;
    }

    @IsTest
    static void historyOnly_ValidationAndHelpers() {
        String key = DataUpdateFormConfigService.buildHistoryOnlyKey('Attendance_History__c', 'Value__c');
        System.assertEquals('Attendance_History__c.Value__c', key);

        // Valid: virtual key (not a field on Account) + lookup to Account.
        System.assertEquals(false, historyOnlyThrows(histOnlyFc(key, 'Account__c', 'Metric_Date__c')));
        // No account lookup → orphan rows → rejected.
        System.assertEquals(true, historyOnlyThrows(histOnlyFc(key, null, 'Metric_Date__c')));
        // Key that doesn't match the mapping → rejected.
        System.assertEquals(true, historyOnlyThrows(histOnlyFc('Attendance_History__c.Other__c', 'Account__c', null)));
        // No mapping at all → rejected.
        DataUpdateFormConfigService.FormFieldConfig empty = histOnlyFc(key, 'Account__c', null);
        empty.historyTargetObjectApiName = null;
        System.assertEquals(true, historyOnlyThrows(empty));

        System.assertEquals(key + '@date', DataUpdateFormConfigService.historyDateKey(histOnlyFc(key, 'Account__c', 'Metric_Date__c')));
        System.assertEquals(null, DataUpdateFormConfigService.historyDateKey(histOnlyFc(key, 'Account__c', null)));
        System.assertEquals(false, DataUpdateFormConfigService.isHistoryOnly(null));

        Schema.DescribeFieldResult histValue = DataUpdateFormConfigService.describeValueField(histOnlyFc(key, 'Account__c', null), 'Account');
        System.assertEquals('Value__c', histValue.getName());
        DataUpdateFormConfigService.FormFieldConfig plain = new DataUpdateFormConfigService.FormFieldConfig();
        plain.fieldApiName = 'Phone';
        System.assertEquals('Phone', DataUpdateFormConfigService.describeValueField(plain, 'Account').getName());
        plain.fieldApiName = 'Nope_Not_A_Field__c';
        System.assertEquals(null, DataUpdateFormConfigService.describeValueField(plain, 'Account'));
        System.assertEquals(null, DataUpdateFormConfigService.describeValueField(plain, 'Nope_Not_An_Object__c'));
        System.assertEquals(null, DataUpdateFormConfigService.describeValueField(plain, null));
    }

    @IsTest
    static void historyOnly_GetFormAcceptsVirtualKey() {
        DataUpdateFormConfigService.testFormMdt = fakeForm('');
        DataUpdateFormConfigService.testFieldMdts = fakeFields(
            '[{"Field_API_Name__c":"Attendance_History__c.Value__c","Label_FR__c":"A","Label_EN__c":"A",'
            + '"Display_Order__c":1,"Input_Type__c":"Number","History_Mode__c":"History_Only","Is_Active__c":true,'
            + '"History_Target_Object_API_Name__c":"Attendance_History__c","History_Target_Value_Field_API_Name__c":"Value__c",'
            + '"History_Target_Account_Field_API_Name__c":"Account__c"}]');
        DataUpdateFormConfigService.FormConfig config = DataUpdateFormConfigService.getForm('Fake_Test_Form');
        System.assertEquals(1, config.fields.size());
        System.assert(DataUpdateFormConfigService.isHistoryOnly(config.fields[0]));
    }

    // ─── History_Table (églises: paste-from-Excel history) ──────────────────

    private static final String HT_KEY = 'Attendance_History__c#table';

    private static String htFieldJson(String columnsJson) {
        return '{"Field_API_Name__c":"' + HT_KEY + '","Label_FR__c":"Assistance","Label_EN__c":"Attendance",'
            + '"Display_Order__c":2,"Input_Type__c":"Text","History_Mode__c":"History_Table","Is_Active__c":true,'
            + '"History_Target_Object_API_Name__c":"Attendance_History__c","History_Target_Date_Field_API_Name__c":"Metric_Date__c",'
            + '"History_Target_Account_Field_API_Name__c":"Account__c","History_Target_Log_Field_API_Name__c":"Log__c",'
            + '"History_Table_Columns__c":' + JSON.serialize(columnsJson) + '}';
    }

    private static final String HT_COLUMNS =
        '[{"f":"Metric_Date__c","fr":"Date","en":"Date"},{"f":"Value__c","fr":"Personnes","en":"People"}]';

    private static void useHistoryTableFakeForm(String columnsJson) {
        DataUpdateFormConfigService.testFormMdt = (Data_Update_Form__mdt) JSON.deserialize(
            '{"DeveloperName":"Fake_Table_Form","MasterLabel":"Fake","Target_Object_API_Name__c":"Account",'
            + '"Identity_Field_1_API_Name__c":"Name","Identity_Field_1_Comparison__c":"Exact",'
            + '"Subject_Template__c":"{RecordName}","Is_Active__c":true,"Lock_Field_API_Name__c":"Data_Update_Locked__c"}',
            Data_Update_Form__mdt.class);
        DataUpdateFormConfigService.testFieldMdts = (List<Data_Update_Form_Field__mdt>) JSON.deserialize(
            '[{"Field_API_Name__c":"Phone","Label_FR__c":"T","Label_EN__c":"T","Display_Order__c":1,'
            + '"Input_Type__c":"Phone","History_Mode__c":"Replace","Is_Active__c":true},'
            + htFieldJson(columnsJson) + ']',
            List<Data_Update_Form_Field__mdt>.class);
    }

    @IsTest
    static void historyTable_LoadsKeyAndColumns() {
        useHistoryTableFakeForm(HT_COLUMNS);
        DataUpdateFormConfigService.FormConfig config = DataUpdateFormConfigService.getForm('Fake_Table_Form');
        System.assertEquals(1, config.fields.size(), 'The table is kept apart from the questions');
        System.assertEquals(1, config.tables.size());
        DataUpdateFormConfigService.FormFieldConfig tc = config.tables[0];
        System.assert(DataUpdateFormConfigService.isHistoryTableKey(tc.fieldApiName));
        System.assertEquals(HT_KEY, DataUpdateFormConfigService.buildHistoryTableKey('Attendance_History__c'));
        System.assertEquals(2, tc.tableColumns.size());
        System.assertEquals('People', tc.tableColumns[1].en);

        List<DataUpdateWrapper.TableColumnDefinition> cols = DataUpdateFormConfigService.describeTableColumns(tc);
        System.assertEquals(2, cols.size());
        System.assertEquals(true, cols[0].isDate);
        System.assertEquals('Date', cols[0].kind);
        System.assertEquals('Number', cols[1].kind);
        System.assertEquals(0, DataUpdateFormConfigService.parseTableColumns('not json').size());
        System.assertEquals(0, DataUpdateFormConfigService.parseTableColumns(null).size());
    }

    @IsTest
    static void historyTable_RejectsBrokenMappings() {
        useHistoryTableFakeForm(HT_COLUMNS);
        DataUpdateFormConfigService.FormFieldConfig tc = DataUpdateFormConfigService.getForm('Fake_Table_Form').tables[0];

        List<String> failures = new List<String>();
        // Date column unchecked
        tc.tableColumns = DataUpdateFormConfigService.parseTableColumns('[{"f":"Value__c","fr":"N","en":"N"}]');
        failures.add(validationError(tc));
        // No columns at all
        tc.tableColumns = new List<DataUpdateFormConfigService.TableColumn>();
        failures.add(validationError(tc));
        // Lookup column offered as a table column
        tc.tableColumns = DataUpdateFormConfigService.parseTableColumns(
            '[{"f":"Metric_Date__c","fr":"D","en":"D"},{"f":"Account__c","fr":"A","en":"A"}]');
        failures.add(validationError(tc));
        // Key that doesn't match the object
        tc.tableColumns = DataUpdateFormConfigService.parseTableColumns(HT_COLUMNS);
        tc.fieldApiName = 'Other__c#table';
        failures.add(validationError(tc));
        // No lookup back to the account
        tc.fieldApiName = HT_KEY;
        tc.historyTargetAccountFieldApiName = null;
        failures.add(validationError(tc));
        // Unknown object
        tc.historyTargetObjectApiName = 'Not_An_Object__c';
        failures.add(validationError(tc));

        for (String f : failures) System.assertNotEquals(null, f, 'Every broken mapping must be rejected: ' + failures);
    }

    private static String validationError(DataUpdateFormConfigService.FormFieldConfig tc) {
        try {
            DataUpdateFormConfigService.validateHistoryTable(tc, 'Account');
        } catch (DataUpdateFormConfigService.FormValidationException e) {
            return e.getMessage();
        }
        return null;
    }

    @IsTest
    static void validateFieldValue_ChecksTypeAndLength() {
        Map<String, Schema.SObjectField> c = Contact.SObjectType.getDescribe().fields.getMap();
        Map<String, Schema.SObjectField> acc = Account.SObjectType.getDescribe().fields.getMap();
        Schema.DescribeFieldResult birthdate = c.get('birthdate').getDescribe();
        Schema.DescribeFieldResult email = c.get('email').getDescribe();
        Schema.DescribeFieldResult doNotCall = c.get('donotcall').getDescribe();
        Schema.DescribeFieldResult employees = acc.get('numberofemployees').getDescribe();
        Schema.DescribeFieldResult revenue = acc.get('annualrevenue').getDescribe();
        Schema.DescribeFieldResult name = acc.get('name').getDescribe();

        System.assertEquals(null, DataUpdateFormConfigService.validateFieldValue(birthdate, '2026-12-31'));
        System.assertEquals('INVALID_DATE', DataUpdateFormConfigService.validateFieldValue(birthdate, '31/12/2026'));
        System.assertEquals(null, DataUpdateFormConfigService.validateFieldValue(email, 'a@b.ca'));
        System.assertEquals('INVALID_EMAIL', DataUpdateFormConfigService.validateFieldValue(email, 'a@b'));
        System.assertEquals(null, DataUpdateFormConfigService.validateFieldValue(doNotCall, 'FALSE'));
        System.assertEquals('INVALID_BOOLEAN', DataUpdateFormConfigService.validateFieldValue(doNotCall, 'oui'));
        System.assertEquals(null, DataUpdateFormConfigService.validateFieldValue(employees, '12'));
        System.assertEquals('INVALID_NUMBER', DataUpdateFormConfigService.validateFieldValue(employees, '12,5'));
        System.assertEquals(null, DataUpdateFormConfigService.validateFieldValue(revenue, '1250.50'));
        System.assertEquals('INVALID_NUMBER', DataUpdateFormConfigService.validateFieldValue(revenue, 'mille'));
        System.assertEquals('VALUE_TOO_LONG', DataUpdateFormConfigService.validateFieldValue(name, 'x'.repeat(name.getLength() + 1)));
        System.assertEquals(null, DataUpdateFormConfigService.validateFieldValue(name, ''));
        System.assertEquals(null, DataUpdateFormConfigService.validateFieldValue(null, 'anything'));
    }

    @IsTest
    static void historyTable_ReviewModeDropsBrokenTable() {
        // Date column unchecked: the public form fails closed, review mode just drops the table.
        useHistoryTableFakeForm('[{"f":"Value__c","fr":"N","en":"N"}]');
        DataUpdateFormConfigService.FormConfig config = DataUpdateFormConfigService.getFormForReview('Fake_Table_Form');
        System.assertEquals(0, config.tables.size(), 'A table whose mapping no longer holds is dropped in review mode');
        System.assertEquals(false, DataUpdateFormConfigService.isHistoryTable(null));
        System.assertEquals(false, DataUpdateFormConfigService.isHistoryTable(config.fields[0]));
    }

    @IsTest
    static void historyTable_MoreBrokenMappings() {
        useHistoryTableFakeForm(HT_COLUMNS);
        DataUpdateFormConfigService.FormFieldConfig tc = DataUpdateFormConfigService.getForm('Fake_Table_Form').tables[0];
        System.assert(DataUpdateFormConfigService.isHistoryTable(tc));

        // Date column that isn't a date
        tc.historyTargetDateFieldApiName = 'Value__c';
        System.assert(validationError(tc).contains('must be a Date'), validationError(tc));
        tc.historyTargetDateFieldApiName = 'Metric_Date__c';

        // No history object at all
        String obj = tc.historyTargetObjectApiName;
        tc.historyTargetObjectApiName = null;
        System.assert(validationError(tc).contains('has no history object'), validationError(tc));
        tc.historyTargetObjectApiName = obj;

        // A field Salesforce requires (Value__c) left unchecked — isCreateable needs the PS's FLS.
        tc.tableColumns = DataUpdateFormConfigService.parseTableColumns('[{"f":"Metric_Date__c","fr":"D","en":"D"}]');
        String err;
        System.runAs(userWithDataUpdateAccess()) {
            err = validationError(tc);
        }
        System.assertNotEquals(null, err);
        System.assert(err.contains('must include required field'), err);
    }

    @IsTest
    static void tableColumns_KindsAndPicklistOptions() {
        System.assertEquals('Checkbox', DataUpdateFormConfigService.tableColumnKind(Schema.DisplayType.BOOLEAN));
        System.assertEquals('Picklist', DataUpdateFormConfigService.tableColumnKind(Schema.DisplayType.PICKLIST));
        System.assertEquals('Text', DataUpdateFormConfigService.tableColumnKind(Schema.DisplayType.EMAIL));

        // describeTableColumns only describes: any object with a picklist + text column will do.
        DataUpdateFormConfigService.FormFieldConfig fc = new DataUpdateFormConfigService.FormFieldConfig();
        fc.historyTargetObjectApiName = 'Data_Update_Log__c';
        fc.tableColumns = DataUpdateFormConfigService.parseTableColumns(
            '[{"f":"Action_Type__c"},{"f":"Target_Object_API_Name__c","fr":"Objet","en":"Object"},{"f":"Gone__c"}]');
        List<DataUpdateWrapper.TableColumnDefinition> cols = DataUpdateFormConfigService.describeTableColumns(fc);
        System.assertEquals(2, cols.size(), 'Columns that no longer resolve are dropped');
        System.assertEquals('Picklist', cols[0].kind);
        System.assert(!cols[0].picklistOptions.isEmpty());
        System.assertEquals('Text', cols[1].kind);
        System.assertEquals('Objet', cols[1].labelFr);
        System.assertNotEquals(null, cols[1].maxLength);

        fc.historyTargetObjectApiName = 'Not_An_Object__c';
        System.assertEquals(0, DataUpdateFormConfigService.describeTableColumns(fc).size());
    }

    @IsTest
    static void validateFieldValue_DateTime() {
        Schema.DescribeFieldResult performed = Data_Update_Log__c.Performed_Date__c.getDescribe();
        System.assertEquals(null, DataUpdateFormConfigService.validateFieldValue(performed, '2026-10-09 10:00:00'));
        System.assertEquals('INVALID_DATE', DataUpdateFormConfigService.validateFieldValue(performed, 'demain'));
    }

    private static User userWithDataUpdateAccess() {
        User usr;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            String u = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
            usr = new User(
                ProfileId = UserInfo.getProfileId(),
                Username = 'ducs' + u + '@example.com.test',
                Email = 'ducs' + u + '@example.com',
                LastName = 'DataUpdateConfig', Alias = 'ducs',
                TimeZoneSidKey = 'America/Toronto', LocaleSidKey = 'fr_CA',
                EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
            );
            insert usr;
            List<PermissionSetAssignment> psas = new List<PermissionSetAssignment>();
            for (PermissionSet ps : [SELECT Id FROM PermissionSet WHERE Name = 'Data_Update_Center_Access']) {
                psas.add(new PermissionSetAssignment(AssigneeId = usr.Id, PermissionSetId = ps.Id));
            }
            insert psas;
        }
        return usr;
    }
}
