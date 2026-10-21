/**
 * DataUpdateFormAdminControllerTest.cls
 * Settings-screen controller: reads against the org's real CMDT (SEMBEQ_Contact_Update /
 * SEMBEQ_Eglise_Update), writes with skipEnqueueForTest (enqueueDeployment() cannot run in a
 * test), hard delete with an HttpCalloutMock standing in for the SOAP deleteMetadata() call.
 * SEMBEQ has no Attendance_History__c: the EDA object hed__Affiliation__c (lookup to Account,
 * Date columns) stands in for the history object in the mapping/table tests.
 */
@IsTest
private class DataUpdateFormAdminControllerTest {

    private static final String ACCOUNT_FORM = 'SEMBEQ_Contact_Update';
    private static final String EGLISE_FORM  = 'SEMBEQ_Eglise_Update';
    private static final String ACCOUNT_SITE = 'Mise à jour de compte SEMBEQ';

    private static String uniq() {
        return String.valueOf(Crypto.getRandomInteger()).replace('-', '');
    }

    private static User userWith(List<String> permissionSetNames) {
        User usr;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            String U = uniq();
            usr = new User(
                ProfileId = UserInfo.getProfileId(),
                Username = 'dua' + U + '@example.com.test',
                Email = 'dua' + U + '@example.com',
                LastName = 'DataUpdateAdmin', Alias = 'duat',
                TimeZoneSidKey = 'America/Toronto', LocaleSidKey = 'fr_CA',
                EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
            );
            insert usr;
            List<PermissionSetAssignment> psas = new List<PermissionSetAssignment>();
            for (PermissionSet ps : [SELECT Id FROM PermissionSet WHERE Name IN :permissionSetNames]) {
                psas.add(new PermissionSetAssignment(AssigneeId = usr.Id, PermissionSetId = ps.Id));
            }
            insert psas;
        }
        return usr;
    }

    private static Data_Update_Form__mdt fakeForm(String developerName, String targetObject, Boolean isCore) {
        return (Data_Update_Form__mdt) JSON.deserialize(
            '{"DeveloperName":"' + developerName + '","MasterLabel":"Fake","Target_Object_API_Name__c":"'
            + targetObject + '","Is_Core_Form__c":' + isCore + '}',
            Data_Update_Form__mdt.class);
    }

    private static void assertThrows(String expectedFragment, Exception e) {
        System.assertNotEquals(null, e, 'Expected an exception containing: ' + expectedFragment);
        System.assert(e instanceof DataUpdateFormAdminController.AdminException, e.getTypeName());
        System.assert(e.getMessage().contains(expectedFragment), e.getMessage());
    }

    // ─── Reads ───────────────────────────────────────────────────────────

    @IsTest
    static void getForms_ListsActiveForms() {
        List<DataUpdateWrapper.FormSummary> forms = DataUpdateFormAdminController.getForms();
        Set<String> names = new Set<String>();
        for (DataUpdateWrapper.FormSummary f : forms) {
            names.add(f.developerName);
            if (f.developerName == ACCOUNT_FORM) {
                System.assertEquals('Contact', f.targetObjectApiName);
                System.assertEquals(true, f.hasLockField);
                System.assertEquals(true, f.isCoreForm);
                System.assertEquals(false, f.isChurchForm, 'Contact form is not a church form');
            }
            if (f.developerName == EGLISE_FORM) {
                System.assertEquals(true, f.isChurchForm, 'Église form targets église Accounts');
            }
        }
        System.assert(names.contains(ACCOUNT_FORM));
        System.assert(names.contains(EGLISE_FORM));
    }

    @IsTest
    static void buildPublicUrl_AllShapes() {
        Id fakeNetworkId = UserInfo.getUserId();
        System.assertEquals(null, DataUpdateFormAdminController.buildPublicUrl(null, 'X', false));
        System.assertEquals(null, DataUpdateFormAdminController.buildPublicUrl(fakeNetworkId, '', false));

        DataUpdateFormAdminController.useTestLoginUrl = true;
        DataUpdateFormAdminController.testLoginUrl = null;
        System.assertEquals(null, DataUpdateFormAdminController.buildPublicUrl(fakeNetworkId, 'X', false));

        DataUpdateFormAdminController.testLoginUrl = 'https://site.example.com/majcompte/login';
        System.assertEquals('https://site.example.com/majcompte/',
            DataUpdateFormAdminController.buildPublicUrl(fakeNetworkId, 'Core_Form', true));
        System.assertEquals('https://site.example.com/majcompte/?form=Child+Form',
            DataUpdateFormAdminController.buildPublicUrl(fakeNetworkId, 'Child Form', false));

        DataUpdateFormAdminController.testLoginUrl = 'https://site.example.com/majeglise';
        System.assertEquals('https://site.example.com/majeglise/?form=X',
            DataUpdateFormAdminController.buildPublicUrl(fakeNetworkId, 'X', false));
    }

    @IsTest
    static void buildPublicUrl_RealNetworkLookup() {
        List<SObject> nets = DataUpdateFormAdminController.queryNetworks('SELECT Id FROM Network LIMIT 1', new Map<String, Object>());
        if (nets.isEmpty()) {
            return;
        }
        // Any real site: just exercises Network.getLoginUrl() without asserting a domain.
        String url = DataUpdateFormAdminController.buildPublicUrl(nets[0].Id, 'X', false);
        System.assert(url == null || url.contains('?form=X'), url);
    }

    @IsTest
    static void getNetworkOptions_ListsSitesWithStatus() {
        List<SObject> nets = DataUpdateFormAdminController.queryNetworks('SELECT Status FROM Network LIMIT 1', new Map<String, Object>());
        if (!nets.isEmpty()) {
            DataUpdateFormAdminController.liveNetworkStatus = (String) nets[0].get('Status');
        }
        List<DataUpdateWrapper.SchemaObjectOption> opts = DataUpdateFormAdminController.getNetworkOptions();
        System.assertEquals(nets.isEmpty() ? 0 : DataUpdateFormAdminController.queryNetworks(
            'SELECT Id FROM Network WHERE Status = :s', new Map<String, Object>{ 's' => nets[0].get('Status') }).size(), opts.size());
    }

    // Orgs without Digital Experiences have no Network: stand in Account rows (Id + Name).
    @IsTest
    static void networks_FakeSitesFeedFormsAndOptions() {
        Account site = new Account(Name = ACCOUNT_SITE);
        insert site;
        DataUpdateFormAdminController.testNetworks = new List<SObject>{ [SELECT Id, Name FROM Account WHERE Id = :site.Id] };
        System.assert(DataUpdateFormAdminController.getForms() != null);
        List<DataUpdateWrapper.SchemaObjectOption> opts = DataUpdateFormAdminController.getNetworkOptions();
        System.assertEquals(1, opts.size());
        System.assertEquals(ACCOUNT_SITE, opts[0].apiName);
    }

    @IsTest
    static void getCoreFormConfigForNetwork_KnownUnknownAndBlank() {
        DataUpdateWrapper.CoreFormConfig c = DataUpdateFormAdminController.getCoreFormConfigForNetwork(ACCOUNT_SITE);
        System.assertNotEquals(null, c);
        System.assertEquals('Contact', c.targetObjectApiName);
        System.assertEquals('ID_Contact__c', c.identityField1ApiName);
        System.assertEquals('Data_Update_Locked__c', c.lockFieldApiName);

        System.assertEquals(null, DataUpdateFormAdminController.getCoreFormConfigForNetwork('No Such Site ' + uniq()));

        Exception caught;
        try {
            DataUpdateFormAdminController.getCoreFormConfigForNetwork(' ');
        } catch (Exception e) {
            caught = e;
        }
        assertThrows('networkName is required', caught);
    }

    @IsTest
    static void getFormFields_ReturnsCatalogAndValidatesInput() {
        // The SEMBEQ église form ships no Historize question: one is published here.
        DucFormConfigStore.save(new List<Metadata.CustomMetadata>{ affiliationQuestion('Eglise_Historize_Seed', 'Description', 'Historize') });
        List<DataUpdateWrapper.AdminFieldConfig> fields = DataUpdateFormAdminController.getFormFields(EGLISE_FORM);
        System.assert(!fields.isEmpty());
        Boolean sawHistorize = false;
        for (DataUpdateWrapper.AdminFieldConfig c : fields) {
            System.assertNotEquals(null, c.historyMode);
            if (c.historyMode == 'Historize') {
                sawHistorize = true;
                System.assertEquals(HIST_OBJECT, c.historyTargetObjectApiName);
            }
        }
        System.assert(sawHistorize, 'Eglise form ships a Historize field');

        Exception blank;
        try {
            DataUpdateFormAdminController.getFormFields('');
        } catch (Exception e) {
            blank = e;
        }
        assertThrows('formDeveloperName is required', blank);

        Exception missing;
        try {
            DataUpdateFormAdminController.getFormFields('No_Such_Form_' + uniq());
        } catch (Exception e) {
            missing = e;
        }
        assertThrows('Form not found', missing);

        DataUpdateFormAdminController.testFormMdt = fakeForm('Fake_Form', 'Nope_Not_An_Object__c', false);
        Exception unknownObject;
        try {
            DataUpdateFormAdminController.getFormFields('Fake_Form');
        } catch (Exception e) {
            unknownObject = e;
        }
        assertThrows('Unknown object', unknownObject);
    }

    @IsTest
    static void getAvailableFields_SkipsCatalogedExcludedAndUnsupported() {
        List<DataUpdateWrapper.AvailableFieldOption> opts = DataUpdateFormAdminController.getAvailableFields(ACCOUNT_FORM);
        Set<String> apiNames = new Set<String>();
        for (DataUpdateWrapper.AvailableFieldOption o : opts) {
            apiNames.add(o.apiName.toLowerCase());
            System.assertNotEquals(null, o.inferredInputType);
        }
        System.assert(!apiNames.contains('personemail'), 'Already cataloged');
        System.assert(!apiNames.contains('ownerid'), 'Excluded system field');
        System.assert(!apiNames.contains('parentid'), 'Reference fields are not offered');

        Exception blank;
        try {
            DataUpdateFormAdminController.getAvailableFields(null);
        } catch (Exception e) {
            blank = e;
        }
        assertThrows('formDeveloperName is required', blank);

        DataUpdateFormAdminController.testFormMdt = fakeForm('Fake_Form', 'Nope_Not_An_Object__c', false);
        Exception unknownObject;
        try {
            DataUpdateFormAdminController.getAvailableFields('Fake_Form');
        } catch (Exception e) {
            unknownObject = e;
        }
        assertThrows('Unknown object', unknownObject);
    }

    @IsTest
    static void manageForms_RequiresFormAdminPermissionSet() {
        DataUpdateFormAdminController.enforceManageFormsForTest = true;
        User staff = userWith(new List<String>{ 'Data_Update_Center_Access' });
        User formAdmin = userWith(new List<String>{ 'Data_Update_Center_Access', 'Data_Update_Center_Form_Admin' });
        System.runAs(staff) {
            System.assertEquals(false, DataUpdateFormAdminController.getCanManageForms());
            Exception refused;
            try {
                DataUpdateFormAdminController.getBuilderForm(ACCOUNT_FORM);
            } catch (Exception e) {
                refused = e;
            }
            System.assert(refused instanceof AuraHandledException, String.valueOf(refused));
            System.assert(refused.getMessage().contains('permission to manage'), refused.getMessage());
            // The daily inbox still lists forms for its filter.
            System.assert(DataUpdateFormAdminController.getForms() != null);
        }
        System.runAs(formAdmin) {
            System.assertEquals(true, DataUpdateFormAdminController.getCanManageForms());
            DataUpdateFormAdminController.requireManageForms();
        }
    }

    @IsTest
    static void inferInputType_AllTypes() {
        System.assertEquals('Email', DataUpdateFormAdminController.inferInputType(Schema.DisplayType.EMAIL));
        System.assertEquals('Phone', DataUpdateFormAdminController.inferInputType(Schema.DisplayType.PHONE));
        System.assertEquals('Number', DataUpdateFormAdminController.inferInputType(Schema.DisplayType.CURRENCY));
        System.assertEquals('Date', DataUpdateFormAdminController.inferInputType(Schema.DisplayType.DATETIME));
        System.assertEquals('Checkbox', DataUpdateFormAdminController.inferInputType(Schema.DisplayType.BOOLEAN));
        System.assertEquals('Picklist', DataUpdateFormAdminController.inferInputType(Schema.DisplayType.PICKLIST));
        System.assertEquals('Text', DataUpdateFormAdminController.inferInputType(Schema.DisplayType.TEXTAREA));
    }

    @IsTest
    static void schemaPickers_ListObjectsAndFields() {
        Boolean sawAccount = false;
        Boolean sawShare = false;
        for (DataUpdateWrapper.SchemaObjectOption o : DataUpdateFormAdminController.getTargetObjectOptions()) {
            if (o.apiName == 'Account') sawAccount = true;
            if (o.apiName == 'AccountShare' || o.apiName == 'AccountHistory') sawShare = true;
        }
        System.assert(sawAccount);
        System.assert(!sawShare, 'sharing/history objects are not offered as form targets');
        System.assert(DataUpdateFormAdminController.isSystemObjectName('accountfeed'));
        System.assert(!DataUpdateFormAdminController.isSystemObjectName('hed__affiliation__c'));

        Boolean sawParentRef = false;
        for (DataUpdateWrapper.SchemaFieldOption f : DataUpdateFormAdminController.getObjectFields('Account')) {
            if (f.apiName == 'ParentId') {
                sawParentRef = f.referenceToApiNames.contains('Account');
            }
        }
        System.assert(sawParentRef, 'ParentId references Account');

        // The SEMBEQ forms don't map any related object, so one église question is published here.
        DucFormConfigStore.save(new List<Metadata.CustomMetadata>{ affiliationQuestion('Eglise_Affiliation_Seed', HO_KEY, 'History_Only') });
        Boolean sawAffiliation = false;
        for (DataUpdateWrapper.SchemaObjectOption o : DataUpdateFormAdminController.getRelatedObjects('Account')) {
            System.assert(o.apiName.endsWith('__c'), o.apiName);
            System.assert(!o.apiName.startsWith('Data_Update_'), o.apiName);
            System.assert(!o.apiName.startsWith('Zeffy_'), o.apiName);
            if (o.apiName == HIST_OBJECT) {
                sawAffiliation = true;
                System.assert(o.usedByForms != null && o.usedByForms.contains(EGLISE_FORM), 'The église form maps this object');
            }
        }
        System.assert(sawAffiliation, HIST_OBJECT + ' has a lookup to Account');

        try {
            DataUpdateFormAdminController.getRelatedObjects('');
            System.assert(false, 'expected AdminException');
        } catch (DataUpdateFormAdminController.AdminException e) {}
        try {
            DataUpdateFormAdminController.getRelatedObjects('No_Such_Object__c');
            System.assert(false, 'expected AdminException');
        } catch (DataUpdateFormAdminController.AdminException e) {}

        Exception blank;
        try {
            DataUpdateFormAdminController.getObjectFields('');
        } catch (Exception e) {
            blank = e;
        }
        assertThrows('objectApiName is required', blank);

        Exception unknownObject;
        try {
            DataUpdateFormAdminController.getObjectFields('Nope_Not_An_Object__c');
        } catch (Exception e) {
            unknownObject = e;
        }
        assertThrows('Unknown object', unknownObject);
    }

    private static Metadata.CustomMetadata affiliationQuestion(String developerName, String fieldKey, String historyMode) {
        Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
        cmd.fullName = 'Data_Update_Form_Field__mdt.' + developerName;
        cmd.label = 'Affiliation';
        for (String[] kv : new List<String[]>{
                new String[]{ 'Form__c', EGLISE_FORM },
                new String[]{ 'Field_API_Name__c', fieldKey },
                new String[]{ 'History_Mode__c', historyMode },
                new String[]{ 'History_Target_Object_API_Name__c', HIST_OBJECT } }) {
            Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
            v.field = kv[0];
            v.value = kv[1];
            cmd.values.add(v);
        }
        return cmd;
    }

    // ─── Create form ────────────────────────────────────────────────────

    @IsTest
    static void enqueueCreateForm_FullAndMinimal() {
        DataUpdateFormAdminController.skipEnqueueForTest = true;
        DataUpdateFormAdminController.bypassNetworkCheckForTest = true;

        String jobId = DataUpdateFormAdminController.enqueueCreateForm('Coverage Form ' + uniq(), 'Contact',
            'ID_Contact__c', 'Exact', 'LastName', 'Normalized_Text', '{RecordName}',
            'IsDeleted', 'false', 'Data_Update_Requests', 'Name',
            'Data_Update_Locked__c', 'Data_Update_Locked_Date__c', ACCOUNT_SITE, false);
        System.assertEquals(32, jobId.length(), 'Hex correlation token');

        String minimal = DataUpdateFormAdminController.enqueueCreateForm('Minimal', 'Contact',
            'ID_Contact__c', null, 'LastName', null, '{RecordName}',
            null, null, null, null, null, null, ACCOUNT_SITE, null);
        System.assertNotEquals(null, minimal);

        // Église-style core config: base filter is a relationship path, not a literal field
        String eglise = DataUpdateFormAdminController.enqueueCreateForm('Eglise Child', 'Account',
            'ID_Account__c', 'Exact', null, null, '{RecordName}',
            'RecordType.DeveloperName', 'Eglise', null, null, null, null, ACCOUNT_SITE, true);
        System.assertNotEquals(null, eglise);
    }

    @IsTest
    static void enqueueCreateForm_ValidationErrors() {
        DataUpdateFormAdminController.skipEnqueueForTest = true;
        Map<String, List<String>> cases = new Map<String, List<String>>{
            'Label is required'            => new List<String>{ '', 'Account', 'ID_Account__c', '{RecordName}', ACCOUNT_SITE },
            'Target object is required'    => new List<String>{ 'L', '', 'ID_Account__c', '{RecordName}', ACCOUNT_SITE },
            'Identity field 1 is required' => new List<String>{ 'L', 'Account', '', '{RecordName}', ACCOUNT_SITE },
            'Subject template is required' => new List<String>{ 'L', 'Account', 'ID_Account__c', '', ACCOUNT_SITE },
            'Site (Network) is required'   => new List<String>{ 'L', 'Account', 'ID_Account__c', '{RecordName}', '' },
            'non-live site'                => new List<String>{ 'L', 'Account', 'ID_Account__c', '{RecordName}', 'No Such Site ' + uniq() }
        };
        for (String expected : cases.keySet()) {
            List<String> a = cases.get(expected);
            Exception caught;
            try {
                DataUpdateFormAdminController.enqueueCreateForm(a[0], a[1], a[2], null, null, null, a[3],
                    null, null, null, null, null, null, a[4], false);
            } catch (Exception e) {
                caught = e;
            }
            assertThrows(expected, caught);
        }

        DataUpdateFormAdminController.bypassNetworkCheckForTest = true;
        Exception unknownObject;
        try {
            DataUpdateFormAdminController.enqueueCreateForm('L', 'Nope_Not_An_Object__c', 'Name', null, null, null,
                '{RecordName}', null, null, null, null, null, null, ACCOUNT_SITE, false);
        } catch (Exception e) {
            unknownObject = e;
        }
        assertThrows('Unknown object', unknownObject);

        Exception unknownField;
        try {
            DataUpdateFormAdminController.enqueueCreateForm('L', 'Account', 'Nope_Field__c', null, null, null,
                '{RecordName}', null, null, null, null, null, null, ACCOUNT_SITE, false);
        } catch (Exception e) {
            unknownField = e;
        }
        assertThrows('Identity field 1 Nope_Field__c does not exist', unknownField);

        Exception badFilterPath;
        try {
            DataUpdateFormAdminController.enqueueCreateForm('L', 'Account', 'ID_Account__c', null, null, null,
                '{RecordName}', 'RecordType.Nope_Field', 'X', null, null, null, null, ACCOUNT_SITE, false);
        } catch (Exception e) {
            badFilterPath = e;
        }
        assertThrows('Base filter field RecordType.Nope_Field does not exist', badFilterPath);
    }

    // ─── Delete form ────────────────────────────────────────────────────

    @IsTest
    static void deleteFormPermanently_RequiresCustomPermission() {
        User noDelete = userWith(new List<String>{ 'Data_Update_Center_Access' });
        Exception caught;
        System.runAs(noDelete) {
            System.assertEquals(false, DataUpdateFormAdminController.getCanDeleteForms());
            try {
                DataUpdateFormAdminController.deleteFormPermanently('Anything', 'SESSION');
            } catch (Exception e) {
                caught = e;
            }
        }
        assertThrows('do not have permission', caught);
    }

    @IsTest
    static void deleteFormPermanently_GuardsAndSuccess() {
        User deleter = userWith(new List<String>{ 'Data_Update_Center_Access', 'Data_Update_Center_Delete_Access' });
        Account a = new Account(Name = 'Delete guard ' + uniq());
        insert a;
        insert new Data_Update_Request__c(
            Target_Object_API_Name__c = 'Account',
            Target_Record_Id__c = a.Id,
            Update_Form_DeveloperName__c = 'Fake_Del_Form',
            Status__c = 'New',
            Subject__c = 'Open ticket on form being deleted'
        );

        Test.startTest();
        System.runAs(deleter) {
            System.assertEquals(true, DataUpdateFormAdminController.getCanDeleteForms());

            Exception blank;
            try {
                DataUpdateFormAdminController.deleteFormPermanently(' ', 'SESSION');
            } catch (Exception e) {
                blank = e;
            }
            assertThrows('formDeveloperName is required', blank);

            Exception notFound;
            try {
                DataUpdateFormAdminController.deleteFormPermanently('No_Such_Form_' + uniq(), 'SESSION');
            } catch (Exception e) {
                notFound = e;
            }
            assertThrows('Form not found', notFound);

            Exception core;
            try {
                DataUpdateFormAdminController.deleteFormPermanently(ACCOUNT_FORM, 'SESSION');
            } catch (Exception e) {
                core = e;
            }
            assertThrows('core form', core);

            DataUpdateFormAdminController.testFormMdt = fakeForm('Fake_Del_Form', 'Account', false);
            Exception openTickets;
            try {
                DataUpdateFormAdminController.deleteFormPermanently('Fake_Del_Form', 'SESSION');
            } catch (Exception e) {
                openTickets = e;
            }
            assertThrows('open ticket(s)', openTickets);

            // Non-core stand-in named like a form that has questions → form and questions hidden.
            DataUpdateFormAdminController.testFormMdt = fakeForm(EGLISE_FORM, 'Account', false);
            DataUpdateFormAdminController.deleteFormPermanently(EGLISE_FORM, 'SESSION');
            System.assertEquals(null, DucFormConfigStore.form(EGLISE_FORM));
            System.assertEquals(0, DucFormConfigStore.fields(EGLISE_FORM).size());

            // A name too long for the store makes the save fail: wrapped, not leaked.
            String tooLong = 'X'.repeat(45);
            DataUpdateFormAdminController.testFormMdt = fakeForm(tooLong, 'Account', false);
            Exception saveFailed;
            try {
                DataUpdateFormAdminController.deleteFormPermanently(tooLong, 'SESSION');
            } catch (Exception e) {
                saveFailed = e;
            }
            assertThrows('Could not delete form', saveFailed);
        }
        Test.stopTest();
    }

    // ─── History mapping validation ───────────────────────────────────────────────────

    @IsTest
    static void validateHistoryMappingInput_AllRules() {
        User usr = userWith(new List<String>{ 'Data_Update_Center_Access' });
        // expected message fragment → {object, value, date, account, log, dateSource}
        Map<String, List<String>> cases = new Map<String, List<String>>{
            'needs a history target'        => new List<String>{ HIST_OBJECT, '', null, null, null, null },
            'Unknown object'                => new List<String>{ 'Nope_Not_An_Object__c', HIST_VALUE, null, null, null, null },
            'Unknown history value field'   => new List<String>{ HIST_OBJECT, 'Nope__c', null, null, null, null },
            'is not a valid target field'   => new List<String>{ HIST_OBJECT, HIST_ACCOUNT, null, null, null, null },
            'Unknown history date field'    => new List<String>{ HIST_OBJECT, HIST_VALUE, 'Nope__c', null, null, null },
            'must be a Date or DateTime'    => new List<String>{ HIST_OBJECT, HIST_VALUE, HIST_VALUE, null, null, null },
            'Unknown field Nope__c'         => new List<String>{ HIST_OBJECT, HIST_VALUE, HIST_DATE, 'Nope__c', null, null },
            'must be a lookup'              => new List<String>{ HIST_OBJECT, HIST_VALUE, HIST_DATE, HIST_VALUE, null, null },
            'must reference Data_Update_Log__c' => new List<String>{ HIST_OBJECT, HIST_VALUE, HIST_DATE, HIST_ACCOUNT, HIST_ACCOUNT, null },
            'Unknown history date source'   => new List<String>{ HIST_OBJECT, HIST_VALUE, HIST_DATE, HIST_ACCOUNT, null, 'Nope__c' },
            'date source field Name'        => new List<String>{ HIST_OBJECT, HIST_VALUE, HIST_DATE, HIST_ACCOUNT, null, 'Name' }
        };
        System.runAs(usr) {
            for (String expected : cases.keySet()) {
                List<String> a = cases.get(expected);
                Exception caught;
                try {
                    DataUpdateFormAdminController.validateHistoryMappingInput(a[0], a[1], a[2], a[3], a[4], a[5], 'Account');
                } catch (Exception e) {
                    caught = e;
                }
                assertThrows(expected, caught);
            }
            // Fully valid mapping: no exception.
            DataUpdateFormAdminController.validateHistoryMappingInput(HIST_OBJECT, HIST_VALUE,
                HIST_DATE, HIST_ACCOUNT, null, 'Excl_date__c', 'Account');

            Exception blankRef;
            try {
                DataUpdateFormAdminController.assertReferenceFieldTo(
                    Schema.SObjectType.Account.fields.getMap(), '', 'Account', 'Account');
            } catch (Exception e) {
                blankRef = e;
            }
            assertThrows('Unknown field', blankRef);
        }
    }

    @IsTest
    static void deploy_SaveFailureIsWrapped() {
        DataUpdateFormAdminController.bypassNetworkCheckForTest = true;
        DataUpdateFormAdminController.TEST_FORCE_SAVE_ERROR = true;
        Exception caught;
        try {
            DataUpdateFormAdminController.enqueueCreateForm('Save Fail', 'Account', 'Name', 'Exact', null, null,
                '{RecordName}', null, null, null, 'Name', null, null, 'Fake Site', false);
        } catch (Exception e) {
            caught = e;
        }
        assertThrows('Could not save the form', caught);
        System.assertEquals(0, [SELECT COUNT() FROM DUC_Form_Config__c]);
    }

    @IsTest
    static void deploy_PublishesSynchronously() {
        DataUpdateFormAdminController.bypassNetworkCheckForTest = true;
        String jobId = DataUpdateFormAdminController.enqueueCreateForm('Sync Form', 'Account', 'Name', 'Exact', null, null,
            '{RecordName}', null, null, null, 'Name', null, null, 'Fake Site', false);
        DataUpdateWrapper.DeployStatusResult r = DataUpdateFormAdminController.checkDeployStatus(jobId);
        System.assertEquals('Succeeded', r.status);
        System.assertEquals(true, r.done);
        System.assertEquals('Sync_Form', r.formDeveloperName);
        Data_Update_Form__mdt created = DucFormConfigStore.form('Sync_Form');
        System.assertNotEquals(null, created, 'the new form is live as soon as the call returns');
        System.assertEquals('Sync Form', created.MasterLabel);
        System.assertEquals('Account', created.Target_Object_API_Name__c);
    }

    @IsTest
    static void deleteForm_StaffWithDeletePermission() {
        User deleter = userWith(new List<String>{ 'Data_Update_Center_Access', 'Data_Update_Center_Delete_Access' });
        System.runAs(deleter) {
            DataUpdateFormAdminController.testFormMdt = fakeForm('Fake_Aura_Del', 'Account', false);
            DataUpdateFormAdminController.deleteForm('Fake_Aura_Del');
        }
        System.assertEquals(1, [SELECT COUNT() FROM DUC_Form_Config__c
                                WHERE Config_Key__c = 'Data_Update_Form__mdt.Fake_Aura_Del' AND Is_Deleted__c = true]);
    }

    @IsTest
    static void setCoreForm_OneMainFormPerSite() {
        Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
        cmd.fullName = 'Data_Update_Form__mdt.Fake_Main';
        cmd.label = 'Fake Main';
        for (String[] kv : new List<String[]>{
                new String[]{ 'Target_Object_API_Name__c', 'Account' },
                new String[]{ 'Network_Name__c', ACCOUNT_SITE } }) {
            Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
            v.field = kv[0];
            v.value = kv[1];
            cmd.values.add(v);
        }
        DucFormConfigStore.save(new List<Metadata.CustomMetadata>{ cmd });
        System.assertEquals(true, DucFormConfigStore.form(ACCOUNT_FORM).Is_Core_Form__c);

        User deleter = userWith(new List<String>{ 'Data_Update_Center_Access', 'Data_Update_Center_Delete_Access' });
        System.runAs(deleter) {
            DataUpdateFormAdminController.setCoreForm('Fake_Main', true);
            System.assertEquals(true, DucFormConfigStore.form('Fake_Main').Is_Core_Form__c);
            System.assertEquals(false, DucFormConfigStore.form(ACCOUNT_FORM).Is_Core_Form__c,
                'The site keeps a single main form');
            DataUpdateFormAdminController.setCoreForm('Fake_Main', false);
            System.assertEquals(false, DucFormConfigStore.form('Fake_Main').Is_Core_Form__c);
            Exception missing;
            try {
                DataUpdateFormAdminController.setCoreForm('No_Such_Form', true);
            } catch (Exception e) {
                missing = e;
            }
            assertThrows('Form not found', missing);
        }

        Exception denied;
        System.runAs(userWith(new List<String>{ 'Data_Update_Center_Access' })) {
            try {
                DataUpdateFormAdminController.setCoreForm('Fake_Main', true);
            } catch (Exception e) {
                denied = e;
            }
        }
        assertThrows('permission', denied);
    }

    @IsTest
    static void deleteForm_BlockedWhileSomeoneElsePublishes() {
        DataUpdateFormAdminController.acquirePublishLock('Account Updates');
        User deleter = userWith(new List<String>{ 'Data_Update_Center_Access', 'Data_Update_Center_Delete_Access' });
        System.runAs(deleter) {
            DataUpdateFormAdminController.testFormMdt = fakeForm('Fake_Locked_Del', 'Account', false);
            try {
                DataUpdateFormAdminController.deleteForm('Fake_Locked_Del');
                System.assert(false, 'delete must wait for the other publish');
            } catch (DataUpdateFormAdminController.AdminException e) {
                System.assert(e.getMessage().contains('Another publish'), e.getMessage());
            }
        }
        System.assertEquals(0, [SELECT COUNT() FROM DUC_Form_Config__c WHERE Config_Key__c = 'Data_Update_Form__mdt.Fake_Locked_Del']);
    }

    // ─── Deploy status ──────────────────────────────────────────────────

    @IsTest
    static void checkDeployStatus_PendingDoneAndError() {
        DataUpdateWrapper.DeployStatusResult pending = DataUpdateFormAdminController.checkDeployStatus('job-' + uniq());
        System.assertEquals('Pending', pending.status);
        System.assertEquals(false, pending.done);

        String jobId = 'job-' + uniq();
        insert new Data_Update_Form_Deploy_Job__c(Job_Id__c = jobId, Status__c = 'Succeeded',
            Form_Developer_Name__c = ACCOUNT_FORM);
        DataUpdateWrapper.DeployStatusResult done = DataUpdateFormAdminController.checkDeployStatus(jobId);
        System.assertEquals('Succeeded', done.status);
        System.assertEquals(true, done.done);
        System.assertEquals(ACCOUNT_FORM, done.formDeveloperName);

        DataUpdateFormAdminController.TEST_FORCE_ERROR = true;
        DataUpdateWrapper.DeployStatusResult err = DataUpdateFormAdminController.checkDeployStatus(jobId);
        System.assertEquals('Unknown', err.status);
        System.assertEquals('TEST_FORCE_ERROR', err.errorMessage);
    }

    // ─── Naming helpers ─────────────────────────────────────────────────

    @IsTest
    static void truncateLabel_NullShortLong() {
        System.assertEquals('', DataUpdateFormAdminController.truncateLabel(null));
        System.assertEquals('Short', DataUpdateFormAdminController.truncateLabel('Short'));
        System.assertEquals(40, DataUpdateFormAdminController.truncateLabel('x'.repeat(55)).length());
    }

    @IsTest
    static void setValue_AddsFieldMissingFromRecord() {
        Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
        DataUpdateFormAdminController.setValue(cmd, 'Is_Active__c', true);
        DataUpdateFormAdminController.setValue(cmd, 'Is_Active__c', false);
        System.assertEquals(1, cmd.values.size());
        System.assertEquals(false, cmd.values[0].value);
    }

    @IsTest
    static void buildUniqueFormDeveloperName_SanitizesTruncatesAndSuffixes() {
        System.assertEquals('F_2026_Form', DataUpdateFormAdminController.buildUniqueFormDeveloperName('2026 Form!'));
        System.assertEquals('Has_Dog', DataUpdateFormAdminController.buildUniqueFormDeveloperName('Has -- Dog ?'));
        System.assertEquals('A'.repeat(39),
            DataUpdateFormAdminController.buildUniqueFormDeveloperName('A'.repeat(39) + ' tail'));
        System.assertEquals(ACCOUNT_FORM + '_2', DataUpdateFormAdminController.buildUniqueFormDeveloperName(ACCOUNT_FORM));
        // Accents are folded, never turned into a leading "_" (which used to yield "F__glise_2027").
        System.assertEquals('Eglise_2027', DataUpdateFormAdminController.buildUniqueFormDeveloperName('Église 2027'));
        System.assertEquals('Coeur_a_Ame', DataUpdateFormAdminController.buildUniqueFormDeveloperName('Cœur à Âme'));
        System.assertEquals('F_x', DataUpdateFormAdminController.buildUniqueFormDeveloperName('_x'));
    }

    @IsTest
    static void appendUniqueSuffix_TrimsUnderscoreLeftByTheCut() {
        String base = 'A'.repeat(37) + '_BC';
        String result = DataUpdateFormAdminController.appendUniqueSuffix(base, new Set<String>{ base.toLowerCase() });
        System.assertEquals('A'.repeat(37) + '_2', result, 'No "__" when the cut lands on an underscore');
    }

    @IsTest
    static void getAvailableFields_BusinessScopeHidesPersonAndLockFields() {
        Data_Update_Form__mdt eglise = new Data_Update_Form__mdt(
            DeveloperName = 'Fake_Eglise', Target_Object_API_Name__c = 'Account',
            Target_Base_Filter_Field__c = 'RecordType.DeveloperName', Target_Base_Filter_Value__c = 'Eglise',
            Lock_Field_API_Name__c = 'Data_Update_Locked__c');
        DataUpdateFormAdminController.testFormMdt = eglise;
        Test.startTest();
        List<DataUpdateWrapper.AvailableFieldOption> opts = DataUpdateFormAdminController.getAvailableFields('Fake_Eglise');
        Boolean rtScope = DataUpdateFormAdminController.isBusinessAccountScope(new Data_Update_Form__mdt(
            Target_Base_Filter_Field__c = 'RecordType.DeveloperName', Target_Base_Filter_Value__c = 'No_Such_RT_Xyz'));
        Test.stopTest();

        for (DataUpdateWrapper.AvailableFieldOption o : opts) {
            System.assert(!DataUpdateFormAdminController.isPersonAccountOnlyField(o.apiName), 'Person field offered: ' + o.apiName);
            System.assertNotEquals('data_update_locked__c', o.apiName.toLowerCase());
            System.assertNotEquals('jigsaw', o.apiName.toLowerCase());
        }
        System.assertEquals(false, rtScope, 'Unknown record type → not treated as business-only');
        System.assert(DataUpdateFormAdminController.isPersonAccountOnlyField('PersonEmail'));
        System.assert(DataUpdateFormAdminController.isPersonAccountOnlyField('Foo__pc'));
        System.assert(!DataUpdateFormAdminController.isPersonAccountOnlyField('Phone'));
        System.assertEquals(false, DataUpdateFormAdminController.isBusinessAccountScope(new Data_Update_Form__mdt()));
        System.assertEquals(true, DataUpdateFormAdminController.isBusinessAccountScope(new Data_Update_Form__mdt(
            Target_Base_Filter_Field__c = 'IsPersonAccount', Target_Base_Filter_Value__c = 'false')));
        System.assertEquals(false, DataUpdateFormAdminController.isBusinessAccountScope(new Data_Update_Form__mdt(
            Target_Base_Filter_Field__c = 'Type', Target_Base_Filter_Value__c = 'Church')));
    }

    // ─── History_Only ───────────────────────────────────────────────────────

    @IsTest
    static void validateHistoryOnlyInput_NeedsLookup() {
        Exception noAccount;
        try {
            DataUpdateFormAdminController.validateHistoryOnlyInput(HIST_OBJECT, HIST_VALUE, null, null, null, 'Account');
        } catch (Exception e) {
            noAccount = e;
        }
        assertThrows('needs the lookup', noAccount);
        DataUpdateFormAdminController.validateHistoryOnlyInput(HIST_OBJECT, HIST_VALUE,
            HIST_DATE, HIST_ACCOUNT, null, 'Account');
    }

    @IsTest
    static void isValidHistoryOnlyMapping_Cases() {
        Data_Update_Form_Field__mdt good = (Data_Update_Form_Field__mdt) JSON.deserialize(
            '{"Field_API_Name__c":"' + HO_KEY + '","History_Mode__c":"History_Only",'
            + '"History_Target_Object_API_Name__c":"' + HIST_OBJECT + '","History_Target_Value_Field_API_Name__c":"' + HIST_VALUE + '",'
            + '"History_Target_Account_Field_API_Name__c":"' + HIST_ACCOUNT + '"}', Data_Update_Form_Field__mdt.class);
        System.assert(DataUpdateFormAdminController.isValidHistoryOnlyMapping(good, 'Account'));

        Data_Update_Form_Field__mdt wrongKey = good.clone();
        wrongKey.Field_API_Name__c = HIST_OBJECT + '.Other__c';
        System.assert(!DataUpdateFormAdminController.isValidHistoryOnlyMapping(wrongKey, 'Account'));

        Data_Update_Form_Field__mdt noAccount = good.clone();
        noAccount.History_Target_Account_Field_API_Name__c = null;
        System.assert(!DataUpdateFormAdminController.isValidHistoryOnlyMapping(noAccount, 'Account'));
    }
    // ─── Visual builder ────────────────────────────────────────────────

    // The draft the builder would send if the admin opened the form and changed nothing.
    private static Map<String, Object> currentDraft(String formDeveloperName) {
        List<Object> questions = new List<Object>();
        for (DataUpdateWrapper.AdminFieldConfig c : DataUpdateFormAdminController.getFormFields(formDeveloperName)) {
            // History tables travel in draft.tables, never as questions (same split as the builder).
            if (c.isActive != true || c.historyMode == 'History_Table') continue;
            questions.add(new Map<String, Object>{
                'developerName' => c.developerName, 'fieldApiName' => c.fieldApiName,
                'labelFr' => c.labelFr, 'labelEn' => c.labelEn, 'helpFr' => c.helpFr, 'helpEn' => c.helpEn,
                'sectionLabelFr' => c.sectionLabelFr, 'sectionLabelEn' => c.sectionLabelEn,
                'inputType' => c.inputType, 'isRequired' => c.isRequired,
                'sameRowAsPrevious' => c.sameRowAsPrevious, 'historyMode' => c.historyMode,
                'isHidden' => c.isHidden, 'isReadOnly' => c.isReadOnly,
                'historyTargetObjectApiName' => c.historyTargetObjectApiName,
                'historyTargetValueFieldApiName' => c.historyTargetValueFieldApiName,
                'historyTargetDateFieldApiName' => c.historyTargetDateFieldApiName,
                'historyTargetAccountFieldApiName' => c.historyTargetAccountFieldApiName,
                'historyTargetLogFieldApiName' => c.historyTargetLogFieldApiName,
                'historyDateSourceFieldApiName' => c.historyDateSourceFieldApiName
            });
        }
        DataUpdateWrapper.BuilderFormInfo info = DataUpdateFormAdminController.getBuilderForm(formDeveloperName);
        return new Map<String, Object>{
            'portalTexts' => JSON.deserializeUntyped(JSON.serialize(info.portalTexts)),
            'questions' => questions
        };
    }

    private static Exception publishError(String formDeveloperName, Object draft) {
        try {
            DataUpdateFormAdminController.enqueuePublishBuilder(formDeveloperName,
                draft instanceof String ? (String) draft : JSON.serialize(draft));
        } catch (Exception e) {
            return e;
        }
        return null;
    }

    @IsTest
    static void getBuilderForm_ReturnsFormAndTexts() {
        DataUpdateWrapper.BuilderFormInfo info = DataUpdateFormAdminController.getBuilderForm(ACCOUNT_FORM);
        System.assertEquals(ACCOUNT_FORM, info.developerName);
        System.assertEquals('Contact', info.targetObjectApiName);
        System.assertNotEquals(null, info.portalTexts);

        Exception blank;
        try {
            DataUpdateFormAdminController.getBuilderForm('');
        } catch (Exception e) {
            blank = e;
        }
        assertThrows('is required', blank);

        Exception missing;
        try {
            DataUpdateFormAdminController.getBuilderForm('Not_A_Form_' + uniq());
        } catch (Exception e) {
            missing = e;
        }
        assertThrows('Form not found', missing);
    }

    @IsTest
    static void enqueuePublishBuilder_EditsReordersRemovesAndTexts() {
        DataUpdateFormAdminController.skipEnqueueForTest = true;
        Map<String, Object> draft = currentDraft(ACCOUNT_FORM);
        List<Object> questions = (List<Object>) draft.get('questions');
        System.assert(questions.size() > 2, 'Account form needs a few active questions');

        // Reorder (swap first two), edit text + help, remove the last one, change screen texts.
        Object first = questions.remove(0);
        questions.add(1, first);
        Map<String, Object> edited = (Map<String, Object>) questions[0];
        edited.put('labelFr', 'Prénom modifié');
        edited.put('helpEn', 'As written on your ID');
        edited.put('sectionLabelFr', 'Identité');
        edited.put('sectionLabelEn', 'Identity');
        questions.remove(questions.size() - 1);
        Map<String, Object> texts = (Map<String, Object>) draft.get('portalTexts');
        texts.put('formTitleFr', 'Vos informations');
        texts.put('lookupSubtitleEn', 'Enter your member number');
        System.assertNotEquals(null, DataUpdateFormAdminController.enqueuePublishBuilder(ACCOUNT_FORM, JSON.serialize(draft)));
    }

    @IsTest
    static void enqueuePublishBuilder_MultipleSubmissionsSwitch() {
        // The history objects are new on a first deploy: only the permission set grants their FLS.
        System.runAs(userWith(new List<String>{ 'Data_Update_Center_Access' })) {
            publishMultipleSubmissionsSwitch();
        }
    }

    private static void publishMultipleSubmissionsSwitch() {
        DataUpdateFormAdminController.skipEnqueueForTest = true;
        DataUpdateWrapper.BuilderFormInfo info = DataUpdateFormAdminController.getBuilderForm(EGLISE_FORM);
        System.assertEquals(true, info.isChurchForm);
        // No screen texts sent: the switch alone still rewrites the form record.
        Map<String, Object> draft = currentDraft(EGLISE_FORM);
        draft.put('tables', new List<Object>{ attendanceTableDraft('Assistance') });
        draft.put('allowMultipleSubmissions', info.allowMultipleSubmissions != true);
        draft.remove('portalTexts');
        System.assertNotEquals(null, DataUpdateFormAdminController.enqueuePublishBuilder(EGLISE_FORM, JSON.serialize(draft)));

        // Never on a non-church form.
        Map<String, Object> accountDraft = currentDraft(ACCOUNT_FORM);
        accountDraft.put('allowMultipleSubmissions', true);
        assertThrows('only available on church forms', publishError(ACCOUNT_FORM, accountDraft));
    }

    @IsTest
    static void enqueuePublishBuilder_HidesQuestionButNotAll() {
        DataUpdateFormAdminController.skipEnqueueForTest = true;
        Map<String, Object> draft = currentDraft(ACCOUNT_FORM);
        List<Object> questions = (List<Object>) draft.get('questions');
        ((Map<String, Object>) questions[0]).put('isHidden', !(((Map<String, Object>) questions[0]).get('isHidden') == true));
        System.assertNotEquals(null, DataUpdateFormAdminController.enqueuePublishBuilder(ACCOUNT_FORM, JSON.serialize(draft)));

        for (Object q : questions) ((Map<String, Object>) q).put('isHidden', true);
        assertThrows('must stay editable', publishError(ACCOUNT_FORM, draft));

        // "Only see" counts as not editable either.
        for (Object q : questions) {
            ((Map<String, Object>) q).put('isHidden', false);
            ((Map<String, Object>) q).put('isReadOnly', true);
        }
        assertThrows('must stay editable', publishError(ACCOUNT_FORM, draft));
        ((Map<String, Object>) questions[0]).put('isReadOnly', false);
        System.assertNotEquals(null, DataUpdateFormAdminController.enqueuePublishBuilder(ACCOUNT_FORM, JSON.serialize(draft)));
    }

    @IsTest
    static void enqueuePublishBuilder_KeepHistoryAndTextStyles() {
        DataUpdateFormAdminController.skipEnqueueForTest = true;
        Map<String, Object> draft = currentDraft(EGLISE_FORM);
        List<Object> questions = (List<Object>) draft.get('questions');

        // Existing Historize question back to Replace, and any Replace one switched to Historize.
        Map<String, Object> historyOnly;
        for (Object o : questions) {
            Map<String, Object> q = (Map<String, Object>) o;
            if (q.get('historyMode') == 'Historize') {
                q.put('historyMode', 'Replace');
            } else if (q.get('historyMode') == 'History_Only') {
                historyOnly = q;
            }
        }
        // New account-field question that keeps history, dated with the answer to a date question.
        questions.add(new Map<String, Object>{
            'fieldApiName' => 'Description', 'labelFr' => 'Description', 'labelEn' => 'Description',
            'inputType' => 'Number', 'historyMode' => 'Historize',
            'historyTargetObjectApiName' => HIST_OBJECT,
            'historyTargetValueFieldApiName' => HIST_VALUE,
            'historyTargetDateFieldApiName' => HIST_DATE,
            'historyTargetAccountFieldApiName' => HIST_ACCOUNT,
            'historyDateSourceFieldApiName' => 'Excl_date__c'
        });
        ((Map<String, Object>) draft.get('portalTexts')).put('stylesJson',
            '{"formTitle":{"style":{"b":true,"align":"center"},"marks":{"fr":[{"start":0,"end":3,"s":{"color":"#b42318"}}],"en":[]}}}');
        ((Map<String, Object>) draft.get('portalTexts')).put('blocksJson',
            '[{"id":"b1","type":"title","screen":"login","after":"@start","fr":"Bienvenue","en":"Welcome"},'
            + '{"id":"b2","type":"video","screen":"form","after":"@formTitle","url":"https://www.youtube.com/watch?v=abc"}]');
        System.assertNotEquals(null, DataUpdateFormAdminController.enqueuePublishBuilder(EGLISE_FORM, JSON.serialize(draft)));

        // Keep history on an existing question without a mapping is refused.
        Map<String, Object> first = (Map<String, Object>) questions[0];
        if (first.get('historyMode') == 'Replace' && first.get('developerName') != null) {
            Map<String, Object> bad = currentDraft(EGLISE_FORM);
            Map<String, Object> q0 = (Map<String, Object>) ((List<Object>) bad.get('questions'))[0];
            if (q0.get('historyMode') == 'Replace') {
                q0.put('historyMode', 'Historize');
                q0.put('historyTargetObjectApiName', null);
                assertThrows('needs a history target', publishError(EGLISE_FORM, bad));
                q0.put('historyMode', 'Signature');
                assertThrows('Unknown history mode', publishError(EGLISE_FORM, bad));
            }
        }

        // A History_Only question can't leave that mode.
        if (historyOnly != null) {
            Map<String, Object> bad = currentDraft(EGLISE_FORM);
            for (Object o : (List<Object>) bad.get('questions')) {
                Map<String, Object> q = (Map<String, Object>) o;
                if (q.get('historyMode') == 'History_Only') {
                    q.put('historyMode', 'Replace');
                    break;
                }
            }
            assertThrows('History Only', publishError(EGLISE_FORM, bad));
        }
    }

    @IsTest
    static void normalizeTextStyles_Cases() {
        System.assertEquals(null, DataUpdateFormAdminController.normalizeTextStyles(null));
        System.assertEquals(null, DataUpdateFormAdminController.normalizeTextStyles('  '));
        System.assertEquals(null, DataUpdateFormAdminController.normalizeTextStyles('{}'));
        System.assertEquals('{"formTitle":{"style":{"b":true}}}',
            DataUpdateFormAdminController.normalizeTextStyles('{"formTitle":{"style":{"b":true}}}'));
        Exception notJson;
        try {
            DataUpdateFormAdminController.normalizeTextStyles('{oops');
        } catch (Exception e) {
            notJson = e;
        }
        assertThrows('Invalid screen text styles', notJson);
        Exception notObject;
        try {
            DataUpdateFormAdminController.normalizeTextStyles('[1,2]');
        } catch (Exception e) {
            notObject = e;
        }
        assertThrows('Invalid screen text styles', notObject);
        Exception tooLong;
        try {
            DataUpdateFormAdminController.normalizeTextStyles('{"k":"' + 'x'.repeat(32001) + '"}');
        } catch (Exception e) {
            tooLong = e;
        }
        System.assertNotEquals(null, tooLong, 'over 32000 characters is refused');
    }

    @IsTest
    static void normalizeBlocks_Cases() {
        System.assertEquals(null, DataUpdateFormAdminController.normalizeBlocks(null));
        System.assertEquals(null, DataUpdateFormAdminController.normalizeBlocks('[]'));
        String ok = '[{"id":"a","type":"image","url":"https://x.sandbox.file.force.com/sfc/dist/version/download/?oid=1"},'
            + '{"id":"b","type":"video","url":"https://youtu.be/abc"},{"id":"c","type":"divider"}]';
        System.assertEquals(ok, DataUpdateFormAdminController.normalizeBlocks(ok));
        for (String bad : new List<String>{
            '{oops', '{"a":1}', '[1]', '[{"type":"script"}]',
            '[{"type":"image","url":"http://x.file.force.com/a.png"}]',
            '[{"type":"image","url":"https://evil.example.com/a.png"}]',
            '[{"type":"video","url":"https://notyoutube.com/v"}]'
        }) {
            Exception err;
            try {
                DataUpdateFormAdminController.normalizeBlocks(bad);
            } catch (Exception e) {
                err = e;
            }
            System.assertNotEquals(null, err, 'refused: ' + bad);
        }
        List<String> many = new List<String>();
        for (Integer i = 0; i < 81; i++) many.add('{"type":"spacer"}');
        Exception tooMany;
        try {
            DataUpdateFormAdminController.normalizeBlocks('[' + String.join(many, ',') + ']');
        } catch (Exception e) {
            tooMany = e;
        }
        assertThrows('Too many design blocks', tooMany);
        System.assert(DataUpdateFormAdminController.isAllowedBlockUrl('https://player.vimeo.com/video/1'));
        System.assert(!DataUpdateFormAdminController.isAllowedBlockUrl('https://'));
        System.assert(!DataUpdateFormAdminController.isAllowedBlockUrl('https://evil.com\\.force.com/x'), 'backslash host trick refused');
        System.assert(!DataUpdateFormAdminController.isAllowedBlockUrl('https://a.force.com@evil.com/x'), 'userinfo trick refused');
        System.assert(!DataUpdateFormAdminController.isAllowedBlockUrl('https://a.force.com /x'), 'whitespace refused');
    }

    @IsTest
    static void publishBlockImage_CreatesPublicLink() {
        ContentVersion img = new ContentVersion(Title = 'Logo', PathOnClient = 'logo.png',
            VersionData = EncodingUtil.base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='));
        ContentVersion txt = new ContentVersion(Title = 'Notes', PathOnClient = 'notes.txt',
            VersionData = Blob.valueOf('hello'));
        insert new List<ContentVersion>{ img, txt };
        Map<Id, Id> docIds = new Map<Id, Id>();
        for (ContentVersion cv : [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id IN :new List<Id>{ img.Id, txt.Id }]) {
            docIds.put(cv.Id, cv.ContentDocumentId);
        }
        Test.startTest();
        String url = DataUpdateFormAdminController.publishBlockImage(docIds.get(img.Id));
        Test.stopTest();
        System.assert(String.isNotBlank(url), 'public link returned');
        System.assertEquals(1, [SELECT COUNT() FROM ContentDistribution WHERE ContentVersionId = :img.Id]);
        System.assertEquals(url, DataUpdateFormAdminController.publishBlockImage(docIds.get(img.Id)), 'same link reused');
        System.assertEquals(1, [SELECT COUNT() FROM ContentDistribution WHERE ContentVersionId = :img.Id]);

        DataUpdateFormAdminController.blockImageUploadWindowMinutes = -60;
        Exception tooOld;
        try {
            DataUpdateFormAdminController.publishBlockImage(docIds.get(img.Id));
        } catch (Exception e) {
            tooOld = e;
        }
        assertThrows('just uploaded', tooOld);
        DataUpdateFormAdminController.blockImageUploadWindowMinutes = 60;

        Exception notImage;
        try {
            DataUpdateFormAdminController.publishBlockImage(docIds.get(txt.Id));
        } catch (Exception e) {
            notImage = e;
        }
        assertThrows('Only images', notImage);
        Exception blank;
        try {
            DataUpdateFormAdminController.publishBlockImage(null);
        } catch (Exception e) {
            blank = e;
        }
        assertThrows('contentDocumentId is required', blank);
        Exception missing;
        try {
            DataUpdateFormAdminController.publishBlockImage('069000000000000AAA');
        } catch (Exception e) {
            missing = e;
        }
        assertThrows('File not found', missing);
    }

    @IsTest
    static void enqueuePublishBuilder_AddsReplaceAndRelatedQuestions() {
        DataUpdateFormAdminController.skipEnqueueForTest = true;
        Map<String, Object> draft = currentDraft(EGLISE_FORM);
        List<Object> questions = (List<Object>) draft.get('questions');
        questions.add(new Map<String, Object>{
            'fieldApiName' => 'Description', 'labelFr' => 'Description', 'labelEn' => 'Description',
            'inputType' => 'Text', 'isRequired' => false, 'historyMode' => 'Replace'
        });
        questions.add(new Map<String, Object>{
            'labelFr' => 'Présence', 'labelEn' => 'Attendance', 'inputType' => 'Number',
            'historyMode' => 'History_Only',
            'historyTargetObjectApiName' => HIST_OBJECT,
            'historyTargetValueFieldApiName' => HIST_VALUE,
            'historyTargetDateFieldApiName' => HIST_DATE,
            'historyTargetAccountFieldApiName' => HIST_ACCOUNT
        });
        System.assertNotEquals(null, DataUpdateFormAdminController.enqueuePublishBuilder(EGLISE_FORM, JSON.serialize(draft)));
    }

    @IsTest
    static void enqueuePublishBuilder_ValidationErrors() {
        DataUpdateFormAdminController.skipEnqueueForTest = true;
        assertThrows('are required', publishError(ACCOUNT_FORM, ''));
        assertThrows('Invalid builder draft', publishError(ACCOUNT_FORM, '{not json'));
        assertThrows('at least one question', publishError(ACCOUNT_FORM, new Map<String, Object>{ 'questions' => new List<Object>() }));

        Map<String, Object> q = new Map<String, Object>{ 'fieldApiName' => 'Description', 'labelFr' => 'D', 'labelEn' => 'D' };
        Map<String, Object> draft = new Map<String, Object>{ 'questions' => new List<Object>{ q } };

        q.put('labelEn', '');
        assertThrows('French and English', publishError(ACCOUNT_FORM, draft));
        q.put('labelEn', 'D'.repeat(121));
        assertThrows('too long', publishError(ACCOUNT_FORM, draft));
        q.put('labelEn', 'D');
        q.put('inputType', 'Signature');
        assertThrows('Unknown question type', publishError(ACCOUNT_FORM, draft));
        q.put('inputType', 'Text');
        q.put('developerName', 'Not_A_Record_' + uniq());
        assertThrows('Field record not found', publishError(ACCOUNT_FORM, draft));
        q.remove('developerName');
        q.put('fieldApiName', 'Nope_Field__c');
        assertThrows('does not exist', publishError(ACCOUNT_FORM, draft));
        q.put('fieldApiName', '');
        assertThrows('has no field', publishError(ACCOUNT_FORM, draft));
        q.put('fieldApiName', 'Description');
        q.put('historyMode', 'Historize');
        assertThrows('needs a history target', publishError(ACCOUNT_FORM, draft));
        q.put('historyMode', 'Replace');
        ((List<Object>) draft.get('questions')).add(q.clone());
        assertThrows('appears twice', publishError(ACCOUNT_FORM, draft));

        Map<String, Object> related = new Map<String, Object>{
            'labelFr' => 'P', 'labelEn' => 'P', 'historyMode' => 'History_Only',
            'historyTargetObjectApiName' => HIST_OBJECT, 'historyTargetValueFieldApiName' => HIST_VALUE
        };
        assertThrows('History Only needs the lookup', publishError(EGLISE_FORM,
            new Map<String, Object>{ 'questions' => new List<Object>{ related } }));

        Map<String, Object> longText = currentDraft(ACCOUNT_FORM);
        ((Map<String, Object>) longText.get('portalTexts')).put('idHelpFr', 'x'.repeat(256));
        assertThrows('too long', publishError(ACCOUNT_FORM, longText));
    }

    @IsTest
    static void setIfChanged_ComparesAsText() {
        Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
        System.assert(DataUpdateFormAdminController.setIfChanged(cmd, 'Display_Order__c', 10), 'new value');
        System.assert(!DataUpdateFormAdminController.setIfChanged(cmd, 'Display_Order__c', 10), 'same value');
        cmd.values[0].value = Decimal.valueOf('10.0');
        System.assert(!DataUpdateFormAdminController.setIfChanged(cmd, 'Display_Order__c', 10), 'decimal vs integer');
        System.assert(DataUpdateFormAdminController.setIfChanged(cmd, 'Display_Order__c', null), 'cleared');
        System.assert(!DataUpdateFormAdminController.setIfChanged(cmd, 'Display_Order__c', null), 'still null');
        DataUpdateFormAdminController.setIfChanged(cmd, 'Label_FR__c', 'abc');
        System.assert(DataUpdateFormAdminController.setIfChanged(cmd, 'Label_FR__c', 'ABC'), 'case change counts');
    }

    // ─── History tables (églises) ───────────────────────────────────────────

    @IsTest
    static void detectHistoryTableSchema_PicksLogLookup() {
        // Stand-in log object: hed__Affiliation__c.hed__Contact__c plays the Data_Update_Log__c lookup.
        DataUpdateFormAdminController.logObjectApiName = 'Contact';
        DataUpdateWrapper.HistoryTableSchema hts = DataUpdateFormAdminController.detectHistoryTableSchema(HIST_OBJECT, 'Account');
        System.assertNotEquals(null, hts);
        System.assertEquals('hed__Contact__c', hts.logFieldApiName);
    }

    @IsTest
    static void getHistoryTableSchemas_DetectsAffiliationHistory() {
        // The lookup/date columns are only detected when the user can create them (FLS comes from the PS).
        List<DataUpdateWrapper.HistoryTableSchema> schemas;
        System.runAs(userWith(new List<String>{ 'Data_Update_Center_Access' })) {
            schemas = DataUpdateFormAdminController.getHistoryTableSchemas('Account');
        }
        DataUpdateWrapper.HistoryTableSchema att;
        for (DataUpdateWrapper.HistoryTableSchema s : schemas) {
            if (s.objectApiName == HIST_OBJECT) att = s;
        }
        System.assertNotEquals(null, att, HIST_OBJECT + ' must be offered as a history table');
        System.assertEquals(HIST_ACCOUNT, att.accountFieldApiName);
        System.assertEquals(null, att.logFieldApiName, 'No SEMBEQ object has a lookup to Data_Update_Log__c');
        System.assert(new Set<String>{ HIST_DATE, 'hed__EndDate__c' }.contains(att.dateFieldApiName), att.dateFieldApiName);
        Boolean dateRequired = false;
        for (DataUpdateWrapper.SchemaFieldOption c : att.columns) {
            System.assertNotEquals('REFERENCE', c.type, 'Lookups are never offered as columns');
            if (c.apiName == att.dateFieldApiName) dateRequired = c.isRequired == true;
        }
        System.assert(dateRequired, 'The date column is always locked');
        Exception caught;
        try {
            DataUpdateFormAdminController.getHistoryTableSchemas('Not_An_Object__c');
        } catch (Exception e) {
            caught = e;
        }
        assertThrows('Unknown object', caught);
    }

    private static Map<String, Object> attendanceTableDraft(String titleFr) {
        return new Map<String, Object>{
            'objectApiName' => HIST_OBJECT,
            'titleFr' => titleFr,
            'titleEn' => 'Attendance',
            'helpFr' => '',
            'helpEn' => 'One row per Sunday',
            'isHidden' => false,
            'inputMode' => 'Fields',
            'columns' => new List<Object>{
                new Map<String, Object>{ 'f' => HIST_DATE, 'fr' => 'Date', 'en' => 'Date' },
                new Map<String, Object>{ 'f' => 'hed__EndDate__c', 'fr' => 'Fin', 'en' => 'End' },
                new Map<String, Object>{ 'f' => HIST_VALUE, 'fr' => 'Personnes', 'en' => 'People' }
            }
        };
    }

    @IsTest
    static void enqueuePublishBuilder_HistoryTables() {
        System.runAs(userWith(new List<String>{ 'Data_Update_Center_Access' })) {
            publishHistoryTables();
        }
    }

    private static void publishHistoryTables() {
        DataUpdateFormAdminController.skipEnqueueForTest = true;
        DataUpdateWrapper.BuilderFormInfo info = DataUpdateFormAdminController.getBuilderForm(EGLISE_FORM);
        System.assertEquals(true, info.isChurchForm);

        Map<String, Object> draft = currentDraft(EGLISE_FORM);
        draft.put('tables', new List<Object>{ attendanceTableDraft('Assistance') });
        System.assertNotEquals(null, DataUpdateFormAdminController.enqueuePublishBuilder(EGLISE_FORM, JSON.serialize(draft)));

        // Missing title
        draft.put('tables', new List<Object>{ attendanceTableDraft('') });
        System.assertNotEquals(null, publishError(EGLISE_FORM, draft));

        // Date columns left out (only the value column)
        Map<String, Object> noDate = attendanceTableDraft('Assistance');
        List<Object> dateless = (List<Object>) noDate.get('columns');
        noDate.put('columns', new List<Object>{ dateless[dateless.size() - 1] });
        draft.put('tables', new List<Object>{ noDate });
        System.assertNotEquals(null, publishError(EGLISE_FORM, draft));

        // Same object twice
        draft.put('tables', new List<Object>{ attendanceTableDraft('A'), attendanceTableDraft('B') });
        assertThrows('appears twice', publishError(EGLISE_FORM, draft));

        // Not a related history object of the form
        Map<String, Object> unknown = attendanceTableDraft('X');
        unknown.put('objectApiName', 'Contact');
        draft.put('tables', new List<Object>{ unknown });
        System.assertNotEquals(null, publishError(EGLISE_FORM, draft));

        // Tables are églises-only
        Map<String, Object> accountDraft = currentDraft(ACCOUNT_FORM);
        accountDraft.put('tables', new List<Object>{ attendanceTableDraft('Assistance') });
        System.assertNotEquals(null, publishError(ACCOUNT_FORM, accountDraft));
    }

    @IsTest
    static void enqueuePublishBuilder_TableOnlyFormKeepsItsPlace() {
        System.runAs(userWith(new List<String>{ 'Data_Update_Center_Access' })) {
            publishTableOnlyForm();
        }
    }

    private static void publishTableOnlyForm() {
        DataUpdateFormAdminController.skipEnqueueForTest = true;
        Map<String, Object> draft = currentDraft(EGLISE_FORM);
        draft.put('questions', new List<Object>());
        Map<String, Object> table = attendanceTableDraft('Assistance');
        table.put('sectionLabelFr', 'Statistiques');
        table.put('sectionLabelEn', 'Statistics');
        table.put('position', 0);
        draft.put('tables', new List<Object>{ table });
        // A shown table is enough for a church form without questions.
        System.assertNotEquals(null, DataUpdateFormAdminController.enqueuePublishBuilder(EGLISE_FORM, JSON.serialize(draft)));

        // A form whose only table is taken off has nothing to fill.
        table.put('isHidden', true);
        assertThrows('at least one question', publishError(EGLISE_FORM, draft));

        System.assertEquals(10, DataUpdateFormAdminController.orderFor(0, 99));
        System.assertEquals(30, DataUpdateFormAdminController.orderFor(2, 99));
        System.assertEquals(99, DataUpdateFormAdminController.orderFor(null, 99));
    }

    // ─── Appearance (uniform font + colors) and its templates ────────────

    @IsTest
    static void normalizeAppearance_CanonicalAndValidated() {
        System.assertEquals(null, DataUpdateFormAdminController.normalizeAppearance(null));
        System.assertEquals(null, DataUpdateFormAdminController.normalizeAppearance('{}'));
        System.assertEquals(null, DataUpdateFormAdminController.normalizeAppearance('{"font":"standard","question":""}'));
        System.assertEquals('{"font":"georgia","question":"#112233","accent":"#abcdef"}',
            DataUpdateFormAdminController.normalizeAppearance(
                '{"accent":"#ABCDEF","other":"x","question":" #112233 ","font":"Georgia"}'));
        for (String bad : new List<String>{ 'not json', '[1]', '{"font":"comic"}', '{"section":"red"}', '{"accent":"#12345"}' }) {
            Exception caught;
            try {
                DataUpdateFormAdminController.normalizeAppearance(bad);
            } catch (Exception e) {
                caught = e;
            }
            assertThrows('Invalid appearance', caught);
        }
    }

    @IsTest
    static void enqueuePublishBuilder_SavesAppearance() {
        DataUpdateFormAdminController.skipEnqueueForTest = true;
        // Account form: the église questions can all be switched off in Settings (no question to publish).
        Map<String, Object> draft = currentDraft(ACCOUNT_FORM);
        Map<String, Object> texts = (Map<String, Object>) draft.get('portalTexts');
        texts.put('appearanceJson', '{"font":"verdana","section":"#0b5cab"}');
        System.assertNotEquals(null, DataUpdateFormAdminController.enqueuePublishBuilder(ACCOUNT_FORM, JSON.serialize(draft)));
        texts.put('appearanceJson', '{"font":"nope"}');
        assertThrows('Invalid appearance font', publishError(ACCOUNT_FORM, draft));
    }

    @IsTest
    static void normalizeMessages_CanonicalAndValidated() {
        System.assertEquals(null, DataUpdateFormAdminController.normalizeMessages(null));
        System.assertEquals(null, DataUpdateFormAdminController.normalizeMessages('{}'));
        System.assertEquals(null, DataUpdateFormAdminController.normalizeMessages('{"lockedTitle":{"fr":"  "},"other":{"fr":"x"}}'));
        System.assertEquals('{"lockedTitle":{"fr":"Bloqué","en":"Locked"},"errNoChanges":{"en":"Nothing changed"}}',
            DataUpdateFormAdminController.normalizeMessages(
                '{"errNoChanges":{"en":" Nothing changed ","fr":7},"lockedTitle":{"en":"Locked","fr":"Bloqué"},"pendingTitle":"x"}'));
        for (String bad : new List<String>{ 'not json', '[1]', '{"lockedMessage":{"fr":"' + 'x'.repeat(1001) + '"}}' }) {
            Exception caught;
            try {
                DataUpdateFormAdminController.normalizeMessages(bad);
            } catch (Exception e) {
                caught = e;
            }
            System.assertNotEquals(null, caught, bad.left(40));
        }
    }

    @IsTest
    static void enqueuePublishBuilder_SavesMessages() {
        DataUpdateFormAdminController.skipEnqueueForTest = true;
        Map<String, Object> draft = currentDraft(ACCOUNT_FORM);
        Map<String, Object> texts = (Map<String, Object>) draft.get('portalTexts');
        texts.put('messagesJson', '{"lockedTitle":{"fr":"Dossier verrouillé","en":"Record locked"}}');
        System.assertNotEquals(null, DataUpdateFormAdminController.enqueuePublishBuilder(ACCOUNT_FORM, JSON.serialize(draft)));
        texts.put('messagesJson', '[1]');
        assertThrows('Invalid portal messages', publishError(ACCOUNT_FORM, draft));
    }

    private static Data_Update_Appearance_Template__mdt fakeTemplate(String developerName, String label, Boolean active) {
        return (Data_Update_Appearance_Template__mdt) JSON.deserialize(
            '{"DeveloperName":"' + developerName + '","MasterLabel":"' + label
            + '","Appearance__c":"{\\"font\\":\\"georgia\\"}","Is_Active__c":' + active + '}',
            Data_Update_Appearance_Template__mdt.class);
    }

    @IsTest
    static void appearanceTemplates_ListSaveOverwriteDelete() {
        DataUpdateFormAdminController.skipEnqueueForTest = true;
        DataUpdateFormAdminController.testAppearanceTemplates = new List<Data_Update_Appearance_Template__mdt>{
            fakeTemplate('Bleu_AEBEQ', 'Bleu AEBEQ', true),
            fakeTemplate('Ancien', 'Ancien', false)
        };
        List<DataUpdateWrapper.AppearanceTemplate> listed = DataUpdateFormAdminController.getAppearanceTemplates();
        System.assertEquals(1, listed.size(), 'Inactive (deleted) templates are not listed');
        System.assertEquals('Bleu_AEBEQ', listed[0].developerName);
        System.assertEquals('Bleu AEBEQ', listed[0].label);
        System.assertEquals('{"font":"georgia"}', listed[0].appearanceJson);

        String look = '{"accent":"#8c2a3c"}';
        System.assertNotEquals(null, DataUpdateFormAdminController.enqueueSaveAppearanceTemplate('bleu aebeq', look), 'Overwrite');
        System.assertNotEquals(null, DataUpdateFormAdminController.enqueueSaveAppearanceTemplate('Vert église', look), 'New');
        System.assertNotEquals(null, DataUpdateFormAdminController.enqueueDeleteAppearanceTemplate('Bleu_AEBEQ'));

        Exception caught;
        try { DataUpdateFormAdminController.enqueueSaveAppearanceTemplate('  ', look); } catch (Exception e) { caught = e; }
        assertThrows('name is required', caught);
        caught = null;
        try { DataUpdateFormAdminController.enqueueSaveAppearanceTemplate('x'.repeat(41), look); } catch (Exception e) { caught = e; }
        assertThrows('40 characters', caught);
        caught = null;
        try { DataUpdateFormAdminController.enqueueSaveAppearanceTemplate('Std', '{"font":"standard"}'); } catch (Exception e) { caught = e; }
        assertThrows('standard one', caught);
        caught = null;
        try { DataUpdateFormAdminController.enqueueDeleteAppearanceTemplate('Missing'); } catch (Exception e) { caught = e; }
        assertThrows('Template not found', caught);

        DataUpdateFormAdminController.testAppearanceTemplates = null;
        System.assertNotEquals(null, DataUpdateFormAdminController.getAppearanceTemplates(), 'Real query path');
    }

    // ─── Seeded catalogs (History_Only / History_Table records the org's forms don't ship) ──

    private static final String HIST_OBJECT  = 'hed__Affiliation__c';
    private static final String HIST_VALUE   = 'hed__Description__c';
    private static final String HIST_DATE    = 'hed__StartDate__c';
    private static final String HIST_ACCOUNT = 'hed__Account__c';
    private static final String HO_KEY = HIST_OBJECT + '.' + HIST_VALUE;
    private static final String HT_KEY = HIST_OBJECT + '#table';
    private static final String HT_COLUMNS =
        '[{"f":"hed__StartDate__c","fr":"Date","en":"Date"},{"f":"hed__EndDate__c","fr":"Fin","en":"End"},'
        + '{"f":"hed__Description__c","fr":"Personnes","en":"People"}]';

    private static String fieldJson(String devName, String formDevName, String key, String mode, String extra) {
        return '{"DeveloperName":"' + devName + '","MasterLabel":"' + devName + '","Form__r":{"DeveloperName":"' + formDevName + '"},'
            + '"Field_API_Name__c":"' + key + '","Label_FR__c":"T","Label_EN__c":"T","Display_Order__c":10,'
            + '"Input_Type__c":"Text","Is_Active__c":true,"Is_Required__c":false,"Is_Hidden__c":false,'
            + '"Is_Read_Only__c":false,"Same_Row_As_Previous__c":false,"History_Mode__c":"' + mode + '"' + extra + '}';
    }

    private static String historyOnlyJson(String devName, String formDevName) {
        return fieldJson(devName, formDevName, HO_KEY, 'History_Only',
            ',"History_Target_Object_API_Name__c":"' + HIST_OBJECT + '","History_Target_Value_Field_API_Name__c":"' + HIST_VALUE + '",'
            + '"History_Target_Date_Field_API_Name__c":"' + HIST_DATE + '","History_Target_Account_Field_API_Name__c":"' + HIST_ACCOUNT + '"');
    }

    private static String historyTableJson(String devName, String formDevName) {
        return fieldJson(devName, formDevName, HT_KEY, 'History_Table',
            ',"History_Target_Object_API_Name__c":"' + HIST_OBJECT + '","History_Target_Date_Field_API_Name__c":"' + HIST_DATE + '",'
            + '"History_Target_Account_Field_API_Name__c":"' + HIST_ACCOUNT + '",'
            + '"History_Table_Columns__c":' + JSON.serialize(HT_COLUMNS));
    }

    private static void seedFields(List<String> jsonRecords) {
        DataUpdateFormAdminController.testFieldMdts = (List<Data_Update_Form_Field__mdt>) JSON.deserialize(
            '[' + String.join(jsonRecords, ',') + ']', List<Data_Update_Form_Field__mdt>.class);
    }

    @IsTest
    static void getFormFields_ValidatesHistoryOnlyAndTableMappings() {
        DataUpdateFormAdminController.testFormMdt = fakeForm('Fake_Form', 'Account', false);
        seedFields(new List<String>{
            fieldJson('F_Phone', 'Fake_Form', 'Phone', 'Replace', ''),
            historyOnlyJson('F_Hist', 'Fake_Form'),
            historyTableJson('F_Table', 'Fake_Form'),
            fieldJson('F_BadTable', 'Fake_Form', 'Other__c#table', 'History_Table', '')
        });
        List<DataUpdateWrapper.AdminFieldConfig> fields;
        System.runAs(userWith(new List<String>{ 'Data_Update_Center_Access' })) {
            fields = DataUpdateFormAdminController.getFormFields('Fake_Form');
        }
        System.assertEquals(4, fields.size());
        System.assertEquals(true, fields[0].isValidInSchema);
        System.assertEquals(true, fields[1].isValidInSchema, 'History_Only mapping holds');
        System.assertEquals(true, fields[2].isValidInSchema, 'History_Table mapping holds');
        System.assertEquals(false, fields[3].isValidInSchema, 'A broken table mapping is flagged');
        System.assertEquals(HT_COLUMNS, fields[2].historyTableColumns);
    }

    @IsTest
    static void isBusinessAccountScope_RecordTypeFilter() {
        Data_Update_Form__mdt form = fakeForm('Fake_Form', 'Account', false);
        form.Target_Base_Filter_Field__c = 'RecordType.DeveloperName';
        // SEMBEQ has no Person Accounts: every Account record type is a business one.
        List<RecordType> business = [SELECT DeveloperName FROM RecordType
                                     WHERE SobjectType = 'Account' AND IsActive = true LIMIT 2];
        if (!business.isEmpty()) {
            form.Target_Base_Filter_Value__c = business[0].DeveloperName;
            System.assertEquals(true, DataUpdateFormAdminController.isBusinessAccountScope(form));
            // Several record types (comma-separated) — all business, so still business scope.
            form.Target_Base_Filter_Value__c = business[0].DeveloperName + ', ' + business[business.size() - 1].DeveloperName;
            System.assertEquals(true, DataUpdateFormAdminController.isBusinessAccountScope(form));
        }
        form.Target_Base_Filter_Value__c = 'PersonAccount';
        System.assertEquals(false, DataUpdateFormAdminController.isBusinessAccountScope(form));
        form.Target_Base_Filter_Value__c = 'No_Such_Record_Type';
        System.assertEquals(false, DataUpdateFormAdminController.isBusinessAccountScope(form));
    }

    @IsTest
    static void requestFormDelete_BlankNameRefused() {
        User deleter = userWith(new List<String>{ 'Data_Update_Center_Access', 'Data_Update_Center_Delete_Access' });
        Exception caught;
        System.runAs(deleter) {
            try {
                DataUpdateFormAdminController.requestFormDelete('  ');
            } catch (Exception e) {
                caught = e;
            }
        }
        System.assertNotEquals(null, caught, 'A blank form name is refused');
    }

    @IsTest
    static void enqueuePublishBuilder_NullDraftAndNoChanges() {
        DataUpdateFormAdminController.skipEnqueueForTest = true;
        assertThrows('at least one question', publishError(ACCOUNT_FORM, 'null'));

        // Seeded form + catalog: a draft identical to the catalog has nothing to publish.
        DataUpdateFormAdminController.testFormMdt = fakeForm('Fake_Form', 'Account', false);
        seedFields(new List<String>{ fieldJson('F_Phone', 'Fake_Form', 'Phone', 'Replace', '') });
        Map<String, Object> same = new Map<String, Object>{
            'developerName' => 'F_Phone', 'fieldApiName' => 'Phone', 'labelFr' => 'T', 'labelEn' => 'T',
            'inputType' => 'Text', 'isRequired' => false, 'historyMode' => 'Replace'
        };
        assertThrows('No changes to publish', publishError('Fake_Form',
            new Map<String, Object>{ 'questions' => new List<Object>{ same } }));
    }

    @IsTest
    static void enqueuePublishBuilder_NewQuestionGuards() {
        DataUpdateFormAdminController.skipEnqueueForTest = true;
        Map<String, Object> q = new Map<String, Object>{
            'labelFr' => 'P', 'labelEn' => 'P', 'historyMode' => 'History_Only',
            'historyTargetObjectApiName' => 'X'.repeat(45) + '__c', 'historyTargetValueFieldApiName' => 'Y'.repeat(37) + '__c'
        };
        Map<String, Object> draft = new Map<String, Object>{ 'questions' => new List<Object>{ q } };
        assertThrows('too long', publishError(ACCOUNT_FORM, draft));

        q.put('historyMode', 'Bogus');
        q.put('fieldApiName', 'Description');
        assertThrows('Unknown history mode for a new question', publishError(ACCOUNT_FORM, draft));

        q.put('historyMode', 'Replace');
        q.put('fieldApiName', 'Data_Update_Locked__c');
        assertThrows('lock fields', publishError(ACCOUNT_FORM, draft));
    }

    @IsTest
    static void enqueuePublishBuilder_ExistingQuestionModeGuards() {
        DataUpdateFormAdminController.skipEnqueueForTest = true;
        Map<String, Object> draft = currentDraft(ACCOUNT_FORM);
        Map<String, Object> first = (Map<String, Object>) ((List<Object>) draft.get('questions'))[0];
        first.put('historyMode', 'History_Only');
        assertThrows('cannot be switched', publishError(ACCOUNT_FORM, draft));
        first.put('historyMode', 'Bogus');
        assertThrows('Unknown history mode', publishError(ACCOUNT_FORM, draft));
    }

    @IsTest
    static void enqueuePublishBuilder_TableGuardsAndExistingRecord() {
        System.runAs(userWith(new List<String>{ 'Data_Update_Center_Access' })) {
            publishTableGuardsAndExistingRecord();
        }
    }

    private static void publishTableGuardsAndExistingRecord() {
        DataUpdateFormAdminController.skipEnqueueForTest = true;
        Map<String, Object> table = attendanceTableDraft('Assistance');
        Map<String, Object> draft = new Map<String, Object>{
            'questions' => new List<Object>(), 'tables' => new List<Object>{ table }
        };

        table.put('objectApiName', '');
        assertThrows('needs its object', publishError(EGLISE_FORM, draft));

        table.put('objectApiName', 'Not_An_Object__c');
        assertThrows('cannot be used as a history table', publishError(EGLISE_FORM, draft));

        // The table already has a catalog record: it is rewritten in place.
        seedFields(new List<String>{ historyTableJson('Eglise_Table_Seed', EGLISE_FORM) });
        table.put('objectApiName', HIST_OBJECT);
        table.put('developerName', 'Eglise_Table_Seed');
        System.assertNotEquals(null, DataUpdateFormAdminController.enqueuePublishBuilder(EGLISE_FORM, JSON.serialize(draft)));
    }

    // ─── Publish lock ────────────────────────────────────────────────────

    private static Data_Update_Form_Deploy_Job__c publishLockRow() {
        return [SELECT Status__c, Form_Developer_Name__c, LastModifiedDate FROM Data_Update_Form_Deploy_Job__c
                WHERE Job_Id__c = :DataUpdateFormAdminController.PUBLISH_LOCK_ID];
    }

    @IsTest
    static void publishLock_AcquireBlocksSecondAndShowsHolder() {
        System.assertEquals(false, DataUpdateFormAdminController.getPublishLock().active);

        DataUpdateWrapper.PublishLockInfo first = DataUpdateFormAdminController.acquirePublishLock('Église Update');
        System.assert(first.acquired);
        System.assert(first.active);
        System.assert(first.mine);
        System.assertEquals('publishing', first.phase);
        System.assertEquals('Église Update', first.what);
        System.assertEquals(UserInfo.getName(), first.userName);

        DataUpdateWrapper.PublishLockInfo second = DataUpdateFormAdminController.acquirePublishLock('Account Updates');
        System.assertEquals(false, second.acquired);
        System.assert(second.active);
        System.assertEquals('Église Update', second.what);
    }

    @IsTest
    static void publishLock_DeployRequiresLockAndCallbackReleasesWithCooldown() {
        DataUpdateFormAdminController.skipEnqueueForTest = true;
        DataUpdateFormAdminController.enforcePublishLockForTest = true;
        try {
            DataUpdateFormAdminController.enqueueSaveAppearanceTemplate('Lock Test', '{"font":"georgia"}');
            System.assert(false, 'deploy without the lock must fail');
        } catch (DataUpdateFormAdminController.AdminException e) {
            System.assert(e.getMessage().contains('Another publish'));
        }

        DataUpdateFormAdminController.acquirePublishLock('Lock Test');
        System.assertNotEquals(null, DataUpdateFormAdminController.enqueueSaveAppearanceTemplate('Lock Test', '{"font":"georgia"}'));
        // The publish is synchronous: the lock is freed right away, no cooldown.
        System.assertEquals(DataUpdateFormAdminController.LOCK_FREE, publishLockRow().Status__c);
        System.assertEquals(false, DataUpdateFormAdminController.getPublishLock().active);

        // Legacy async callback: a callback from an older lock (other stamp) frees nothing.
        DataUpdateFormAdminController.acquirePublishLock('Lock Test 2');
        Data_Update_Form_Deploy_Job__c row = publishLockRow();
        DataUpdateFormAdminController.releasePublishLockAfterDeploy(row.LastModifiedDate.addSeconds(-1));
        System.assertEquals(DataUpdateFormAdminController.LOCK_PUBLISHING, publishLockRow().Status__c);
        DataUpdateFormAdminController.releasePublishLockAfterDeploy(null);

        DataUpdateFormAdminDeployCallback cb = new DataUpdateFormAdminDeployCallback();
        cb.jobId = 'corr-lock';
        cb.lockStamp = row.LastModifiedDate;
        Metadata.DeployResult result = new Metadata.DeployResult();
        result.status = Metadata.DeployStatus.Succeeded;
        cb.handleResult(result, null);
        System.assertEquals(DataUpdateFormAdminController.LOCK_RELEASED, publishLockRow().Status__c);

        DataUpdateWrapper.PublishLockInfo cooling = DataUpdateFormAdminController.getPublishLock();
        System.assert(cooling.active);
        System.assertEquals('cooldown', cooling.phase);
        System.assertEquals(false, DataUpdateFormAdminController.acquirePublishLock('Too soon').acquired);

        DataUpdateFormAdminController.lockNow = Datetime.now().addSeconds(DataUpdateFormAdminController.LOCK_COOLDOWN_SECS + 5);
        System.assertEquals(false, DataUpdateFormAdminController.getPublishLock().active);
        System.assert(DataUpdateFormAdminController.acquirePublishLock('After cooldown').acquired);
    }

    @IsTest
    static void publishLock_ReleaseAfterFailedEnqueueAndExpiry() {
        DataUpdateFormAdminController.acquirePublishLock('Failed one');
        DataUpdateFormAdminController.releasePublishLock();
        System.assertEquals(DataUpdateFormAdminController.LOCK_FREE, publishLockRow().Status__c);
        System.assertEquals(false, DataUpdateFormAdminController.getPublishLock().active);
        DataUpdateFormAdminController.releasePublishLock(); // nothing held: no-op

        // A lock whose callback never comes expires on its own.
        DataUpdateFormAdminController.acquirePublishLock('Stuck one');
        DataUpdateFormAdminController.lockNow = Datetime.now().addSeconds(DataUpdateFormAdminController.LOCK_MAX_SECS + 5);
        System.assertEquals(false, DataUpdateFormAdminController.getPublishLock().active);
        System.assert(DataUpdateFormAdminController.acquirePublishLock('Next one').acquired);

        // An expired lock no longer lets its holder deploy.
        DataUpdateFormAdminController.lockNow = Datetime.now().addSeconds(2 * DataUpdateFormAdminController.LOCK_MAX_SECS);
        DataUpdateFormAdminController.enforcePublishLockForTest = true;
        DataUpdateFormAdminController.skipEnqueueForTest = true;
        try {
            DataUpdateFormAdminController.enqueueSaveAppearanceTemplate('Expired', '{"font":"georgia"}');
            System.assert(false, 'expired lock must not deploy');
        } catch (DataUpdateFormAdminController.AdminException e) {
            System.assert(e.getMessage().contains('Another publish'));
        }
    }

    @IsTest
    static void publishLock_SameInstantCollision_NotAcquired() {
        DataUpdateFormAdminController.failLockUpsertForTest = true;
        DataUpdateWrapper.PublishLockInfo info = DataUpdateFormAdminController.acquirePublishLock('Collision');
        System.assertEquals(false, info.acquired == true, 'The other admin who created the row first keeps the lock');
    }

    @IsTest
    static void enqueuePublishBuilder_NewHistoryTable_CreatesRecord() {
        System.runAs(userWith(new List<String>{ 'Data_Update_Center_Access' })) {
            DataUpdateFormAdminController.skipEnqueueForTest = true;
            // The église form as it was before it had any table: the attendance table is new.
            List<Data_Update_Form_Field__mdt> noTables = new List<Data_Update_Form_Field__mdt>();
            for (Data_Update_Form_Field__mdt fm : DucFormConfigStore.fields(EGLISE_FORM)) {
                if (fm.History_Mode__c != 'History_Table') noTables.add(fm);
            }
            DataUpdateFormAdminController.testFieldMdts = noTables;

            Map<String, Object> draft = currentDraft(EGLISE_FORM);
            draft.put('tables', new List<Object>{ attendanceTableDraft('Assistance') });
            System.assertNotEquals(null, DataUpdateFormAdminController.enqueuePublishBuilder(EGLISE_FORM, JSON.serialize(draft)));
        }
    }
}
