@IsTest(SeeAllData=false)
private class DataUpdatePortalControllerTest {

    private static Integer activeFieldCount(String formDeveloperName) {
        Integer n = 0;
        for (Data_Update_Form_Field__mdt fm : DucFormConfigStore.fields(formDeveloperName)) {
            if (fm.Is_Active__c == true) n++;
        }
        return n;
    }

    private static final String FORM_NAME = 'SEMBEQ_Contact_Update';

    private static String uniq() {
        return String.valueOf(DateTime.now().getTime()) + String.valueOf(Crypto.getRandomInteger());
    }

    // Why a form fails to load, for assertion messages (the portal hides it behind GENERIC_ERROR).
    private static String formError(String formName) {
        try {
            DataUpdateFormConfigService.getForm(formName);
            return 'form loads';
        } catch (Exception e) {
            return e.getTypeName() + ': ' + e.getMessage() + ' | ' + e.getStackTraceString();
        }
    }

    // Staff-like user with the app's permission set: the history objects and some Account fields are
    // new on a first deploy, so only the permission set grants their FLS (the running admin has none).
    private static User appUser() {
        User usr;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            String U = uniq();
            usr = new User(
                ProfileId = UserInfo.getProfileId(),
                Username = 'dup' + U + '@example.com.test',
                Email = 'dup' + U + '@example.com',
                LastName = 'DataUpdatePortal', Alias = 'dupt',
                TimeZoneSidKey = 'America/Toronto', LocaleSidKey = 'fr_CA',
                EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
            );
            insert usr;
            insert new PermissionSetAssignment(AssigneeId = usr.Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Data_Update_Center_Access' LIMIT 1].Id);
        }
        return usr;
    }

    private static void applyDupBypass(Database.DMLOptions dmo) {
        dmo.DuplicateRuleHeader.allowSave = true;
        dmo.DuplicateRuleHeader.runAsCurrentUser = true;
    }

    private static Contact insertResilient(Contact a) {
        Database.DMLOptions dmo = new Database.DMLOptions();
        applyDupBypass(dmo);
        Database.SaveResult sr = Database.insert(new List<SObject>{ a }, dmo)[0];
        System.assert(sr.isSuccess(), 'Insert failed: ' +
            (sr.getErrors().isEmpty() ? 'unknown' : sr.getErrors()[0].getMessage()));
        a.Id = sr.getId();
        return a;
    }

    // SEMBEQ: people are Contacts (no Person Accounts); ID_Contact__c comes from Contact_GenerateID.
    private static Contact createTestContact(String lastName, String firstName) {
        Contact a = new Contact(LastName = lastName, FirstName = firstName);
        a.put('Email', 'old' + uniq() + '@example.com');
        return insertResilient(a);
    }

    private static Data_Update_Request__c createOpenRequest(Id accountId, String proposedJson) {
        Data_Update_Request__c t = new Data_Update_Request__c(
            Target_Object_API_Name__c = 'Contact',
            Target_Record_Id__c = accountId,
            Update_Form_DeveloperName__c = FORM_NAME,
            Status__c = 'New',
            Subject__c = 'Pending request',
            Proposed_Values_JSON__c = proposedJson
        );
        insert t;
        return t;
    }

    @IsTest
    static void getFormDefinition_Success_ReturnsOrderedBilingualFields() {
        Test.startTest();
        DataUpdateWrapper.FormDefinition def = DataUpdatePortalController.getFormDefinition(FORM_NAME);
        Test.stopTest();

        System.assert(def.success);
        System.assert(def.requiresIdentityField2);
        System.assertEquals(activeFieldCount(FORM_NAME), def.fields.size());
        System.assertEquals('FirstName', def.fields[0].fieldApiName);
        System.assertEquals('Prénom', def.fields[0].labelFr);
        System.assertEquals('First Name', def.fields[0].labelEn);
    }

    @IsTest
    static void getFormDefinition_UnknownForm_ReturnsError() {
        Test.startTest();
        DataUpdateWrapper.FormDefinition def = DataUpdatePortalController.getFormDefinition('DOES_NOT_EXIST');
        Test.stopTest();

        System.assertEquals(false, def.success);
        System.assertEquals('GENERIC_ERROR', def.errorMessage);
    }

    @IsTest
    static void lookupRecord_Success_ReturnsRecordIdentityOnly() {
        String U = uniq();
        Contact a = createTestContact('Bertrand' + U, 'Marie');
        a = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a.Id LIMIT 1];

        Test.startTest();
        DataUpdateWrapper.LookupResult result = DataUpdatePortalController.lookupRecord(FORM_NAME, a.ID_Contact__c, 'Bertrand' + U, null);
        Test.stopTest();

        System.assert(result.success, 'Lookup should succeed with correct identity fields');
        System.assertEquals(false, result.alreadyPending);
        System.assertEquals(false, result.isLocked);
        System.assertEquals(a.Id, result.recordId);
    }

    @IsTest
    static void lookupRecord_AccentedLastName_Matches() {
        String U = uniq();
        Contact a = createTestContact('Hébert' + U, 'Élodie');
        a = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a.Id LIMIT 1];

        Test.startTest();
        DataUpdateWrapper.LookupResult result = DataUpdatePortalController.lookupRecord(FORM_NAME, a.ID_Contact__c, 'hebert' + U, null);
        Test.stopTest();

        System.assert(result.success, 'Accent-insensitive identity match must succeed');
    }

    @IsTest
    static void lookupRecord_WrongIdentity2_NotFound() {
        String U = uniq();
        Contact a = createTestContact('Gagnon' + U, 'Luc');
        a = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a.Id LIMIT 1];

        Test.startTest();
        DataUpdateWrapper.LookupResult result = DataUpdatePortalController.lookupRecord(FORM_NAME, a.ID_Contact__c, 'WrongName', null);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('NOT_FOUND', result.errorMessage);
    }

    @IsTest
    static void lookupRecord_NonexistentId_NotFound() {
        Test.startTest();
        DataUpdateWrapper.LookupResult result = DataUpdatePortalController.lookupRecord(FORM_NAME, 'I-DOESNOTEXIST', 'Someone', null);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('NOT_FOUND', result.errorMessage);
    }

    @IsTest
    static void lookupRecord_AlreadyPending_Blocks() {
        String U = uniq();
        Contact a = createTestContact('Roy' + U, 'Denis');
        a = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a.Id LIMIT 1];
        createOpenRequest(a.Id, '{"Email":"x@example.com"}');

        Test.startTest();
        DataUpdateWrapper.LookupResult result = DataUpdatePortalController.lookupRecord(FORM_NAME, a.ID_Contact__c, 'Roy' + U, null);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.alreadyPending);
        System.assertEquals('ALREADY_PENDING', result.errorMessage);
    }

    @IsTest
    static void lookupRecord_Locked_ReturnsIsLockedBeforePendingCheck() {
        String U = uniq();
        Contact a = createTestContact('Bouchard' + U, 'Sophie');
        a.put('Data_Update_Locked__c', true);
        a.put('Data_Update_Locked_Date__c', Datetime.now());
        update a;
        a = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a.Id LIMIT 1];

        Test.startTest();
        DataUpdateWrapper.LookupResult result = DataUpdatePortalController.lookupRecord(FORM_NAME, a.ID_Contact__c, 'Bouchard' + U, null);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.isLocked, 'A locked record must report isLocked = true');
        System.assertEquals('LOCKED', result.errorMessage);
    }

    @IsTest
    static void submitUpdate_Success_LocksTheRecord() {
        String U = uniq();
        Contact a = createTestContact('Michaud' + U, 'Julie');
        a = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a.Id LIMIT 1];

        Test.startTest();
        DataUpdateWrapper.SubmitResult result = DataUpdatePortalController.submitUpdate(
            FORM_NAME, a.ID_Contact__c, 'Michaud' + U, '{"Email":"locked' + U + '@example.com"}', null
        );
        Test.stopTest();

        System.assert(result.success, 'Submit should succeed');

        Contact locked = [SELECT Data_Update_Locked__c, Data_Update_Locked_Date__c FROM Contact WHERE Id = :a.Id LIMIT 1];
        System.assertEquals(true, locked.Data_Update_Locked__c);
        System.assertNotEquals(null, locked.Data_Update_Locked_Date__c);
    }

    @IsTest
    static void submitUpdate_LockFails_RollsBackRequestAndLog() {
        String U = uniq();
        Contact a = createTestContact('Atomique' + U, 'Paul');
        a = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a.Id LIMIT 1];
        DataUpdatePortalController.TEST_FORCE_LOCK_ERROR = true;

        Test.startTest();
        DataUpdateWrapper.SubmitResult result = DataUpdatePortalController.submitUpdate(
            FORM_NAME, a.ID_Contact__c, 'Atomique' + U, '{"Email":"atom' + U + '@example.com"}', null
        );
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('GENERIC_ERROR', result.errorMessage);
        System.assertEquals(0, [SELECT COUNT() FROM Data_Update_Request__c WHERE Target_Record_Id__c = :a.Id],
            'A failed submit must not leave a request behind');
        System.assertEquals(0, [SELECT COUNT() FROM Data_Update_Log__c WHERE Target_Record_Id__c = :a.Id]);
    }

    @IsTest
    static void submitUpdate_Locked_BlocksSecondSubmission() {
        String U = uniq();
        Contact a = createTestContact('Cloutier' + U, 'Marc');
        a.put('Data_Update_Locked__c', true);
        a.put('Data_Update_Locked_Date__c', Datetime.now());
        update a;
        a = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a.Id LIMIT 1];

        Test.startTest();
        DataUpdateWrapper.SubmitResult result = DataUpdatePortalController.submitUpdate(
            FORM_NAME, a.ID_Contact__c, 'Cloutier' + U, '{"Email":"blocked' + U + '@example.com"}', null
        );
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.isLocked, 'Submit on a locked record must report isLocked = true');
        System.assertEquals(0, [SELECT COUNT() FROM Data_Update_Request__c WHERE Target_Record_Id__c = :a.Id]);
    }

    @IsTest
    static void submitUpdate_Success_CreatesRequestWithWhitelistedJsonAndSubmitLog() {
        String U = uniq();
        Contact a = createTestContact('Simard' + U, 'Paul');
        a = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a.Id LIMIT 1];

        String proposedJson = JSON.serialize(new Map<String, String>{
            'Email' => 'new' + U + '@example.com',
            'MobilePhone' => '5145550000',
            'MailingStreet' => '123 rue Montréal'
        });

        Test.startTest();
        DataUpdateWrapper.SubmitResult result = DataUpdatePortalController.submitUpdate(FORM_NAME, a.ID_Contact__c, 'Simard' + U, proposedJson, null);
        Test.stopTest();

        System.assert(result.success, 'Submit should succeed');
        System.assert(String.isNotBlank(result.requestId));

        Data_Update_Request__c created = [
            SELECT Id, Target_Object_API_Name__c, Target_Record_Id__c, Update_Form_DeveloperName__c, Proposed_Values_JSON__c, Status__c,
                   Requested_Name__c, Requested_Email__c, Requested_Phone__c
            FROM Data_Update_Request__c WHERE Id = :result.requestId LIMIT 1
        ];
        System.assertEquals('Contact', created.Target_Object_API_Name__c);
        System.assert(created.Requested_Name__c.contains('Simard' + U), 'Requester name comes from the record');
        System.assertEquals('new' + U + '@example.com', created.Requested_Email__c);
        System.assert(String.isNotBlank(created.Requested_Phone__c), 'First phone value is kept');
        System.assertEquals(a.Id, Id.valueOf(created.Target_Record_Id__c));
        System.assertEquals(FORM_NAME, created.Update_Form_DeveloperName__c);
        System.assertEquals('New', created.Status__c);

        Map<String, Object> proposed = (Map<String, Object>) JSON.deserializeUntyped(created.Proposed_Values_JSON__c);
        System.assertEquals('123 rue Montréal', proposed.get('MailingStreet'));
        System.assert(!proposed.containsKey('HomePhone'), 'Fields not submitted must not appear in the proposed JSON');

        Data_Update_Log__c log = [
            SELECT Action_Type__c, Request__c, Before_Snapshot_JSON__c
            FROM Data_Update_Log__c WHERE Request__c = :result.requestId LIMIT 1
        ];
        System.assertEquals('SUBMIT_PENDING', log.Action_Type__c);
        System.assert(String.isNotBlank(log.Before_Snapshot_JSON__c));
    }

    @IsTest
    static void submitUpdate_WrongIdentity_NotFound_NoRequestCreated() {
        String U = uniq();
        Contact a = createTestContact('Cote' + U, 'Anne');
        a = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a.Id LIMIT 1];

        Test.startTest();
        DataUpdateWrapper.SubmitResult result = DataUpdatePortalController.submitUpdate(
            FORM_NAME, a.ID_Contact__c, 'WrongName', '{"Email":"x@example.com"}', null
        );
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('NOT_FOUND', result.errorMessage);
        System.assertEquals(0, [SELECT COUNT() FROM Data_Update_Request__c WHERE Target_Record_Id__c = :a.Id]);
    }

    @IsTest
    static void submitUpdate_AlreadyPending_BlocksSecondRequest() {
        String U = uniq();
        Contact a = createTestContact('Fortin' + U, 'Eric');
        a = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a.Id LIMIT 1];
        createOpenRequest(a.Id, '{"Email":"first@example.com"}');

        Test.startTest();
        DataUpdateWrapper.SubmitResult result = DataUpdatePortalController.submitUpdate(
            FORM_NAME, a.ID_Contact__c, 'Fortin' + U, '{"Email":"second@example.com"}', null
        );
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.alreadyPending);
        System.assertEquals(1, [SELECT COUNT() FROM Data_Update_Request__c WHERE Target_Record_Id__c = :a.Id]);
    }

    @IsTest
    static void submitUpdate_NoValues_ReturnsNoChangesError() {
        String U = uniq();
        Contact a = createTestContact('Levesque' + U, 'Nina');
        a = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a.Id LIMIT 1];

        Test.startTest();
        DataUpdateWrapper.SubmitResult result1 = DataUpdatePortalController.submitUpdate(FORM_NAME, a.ID_Contact__c, 'Levesque' + U, null, null);
        DataUpdateWrapper.SubmitResult result2 = DataUpdatePortalController.submitUpdate(FORM_NAME, a.ID_Contact__c, 'Levesque' + U, '{}', null);
        Test.stopTest();

        System.assertEquals('NO_CHANGES', result1.errorMessage);
        System.assertEquals('NO_CHANGES', result2.errorMessage);
    }

    private static void enableRecaptcha() {
        DataUpdateReCaptcha_Setting__c s = DataUpdateReCaptcha_Setting__c.getOrgDefaults();
        if (s.Id == null) {
            s.SetupOwnerId = UserInfo.getOrganizationId();
        }
        s.Is_Active__c = true;
        s.Site_Key__c = 'site-key';
        s.Secret_Key__c = 'secret-key';
        s.Signing_Secret__c = 'signing-secret';
        upsert s;
    }

    @IsTest
    static void getRecaptchaSiteKey_Disabled_ReturnsNull() {
        System.assertEquals(null, DataUpdatePortalController.getRecaptchaSiteKey());
    }

    @IsTest
    static void getRecaptchaSiteKey_Enabled_ReturnsConfiguredKey() {
        enableRecaptcha();
        System.assertEquals('site-key', DataUpdatePortalController.getRecaptchaSiteKey());
    }

    @IsTest
    static void lookupRecord_CaptchaEnabledInvalidToken_ReturnsInvalidCaptcha() {
        enableRecaptcha();
        String U = uniq();
        Contact a = createTestContact('Poulin' + U, 'Karine');
        a = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a.Id LIMIT 1];

        Test.startTest();
        DataUpdateWrapper.LookupResult result = DataUpdatePortalController.lookupRecord(FORM_NAME, a.ID_Contact__c, 'Poulin' + U, null);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('INVALID_CAPTCHA', result.errorMessage);
    }

    @IsTest
    static void lookupRecord_CaptchaEnabledValidToken_ReturnsLookupPass() {
        enableRecaptcha();
        DataUpdateReCaptchaService.TEST_FORCE_VERIFY_RESULT = true;
        String U = uniq();
        Contact a = createTestContact('Girard' + U, 'Olivier');
        a = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a.Id LIMIT 1];

        Test.startTest();
        DataUpdateWrapper.LookupResult result = DataUpdatePortalController.lookupRecord(FORM_NAME, a.ID_Contact__c, 'Girard' + U, 'good-token');
        Test.stopTest();
        DataUpdateReCaptchaService.TEST_FORCE_VERIFY_RESULT = null;

        System.assert(result.success, 'Lookup should succeed with a valid captcha token');
        System.assert(String.isNotBlank(result.lookupPass), 'A valid lookup should return a signed lookupPass');
    }

    @IsTest
    static void submitUpdate_CaptchaEnabledMissingLookupPass_ReturnsInvalidCaptcha_NoQueryRun() {
        enableRecaptcha();
        String U = uniq();
        Contact a = createTestContact('Bernier' + U, 'Simon');
        a = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a.Id LIMIT 1];

        Test.startTest();
        DataUpdateWrapper.SubmitResult result = DataUpdatePortalController.submitUpdate(
            FORM_NAME, a.ID_Contact__c, 'Bernier' + U, '{"Email":"x@example.com"}', null
        );
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('INVALID_CAPTCHA', result.errorMessage);
        System.assertEquals(0, [SELECT COUNT() FROM Data_Update_Request__c WHERE Target_Record_Id__c = :a.Id]);
    }

    @IsTest
    static void submitUpdate_CaptchaEnabledValidLookupPass_Succeeds() {
        enableRecaptcha();
        String U = uniq();
        Contact a = createTestContact('Lambert' + U, 'Chantal');
        a = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a.Id LIMIT 1];

        String pass = DataUpdateReCaptchaService.generateLookupPass(FORM_NAME, a.ID_Contact__c, 'Lambert' + U);

        Test.startTest();
        DataUpdateWrapper.SubmitResult result = DataUpdatePortalController.submitUpdate(
            FORM_NAME, a.ID_Contact__c, 'Lambert' + U, '{"Email":"x@example.com"}', pass
        );
        Test.stopTest();

        System.assert(result.success, 'Submit should succeed with a valid lookup pass');
    }

    @IsTest
    static void submitUpdate_ForcedError_ReturnsGenericError() {
        String U = uniq();
        Contact a = createTestContact('Belanger' + U, 'Sara');
        a = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a.Id LIMIT 1];

        DataUpdatePortalController.TEST_FORCE_ERROR = true;
        Test.startTest();
        DataUpdateWrapper.SubmitResult result = DataUpdatePortalController.submitUpdate(
            FORM_NAME, a.ID_Contact__c, 'Belanger' + U, '{"Email":"x@example.com"}', null
        );
        Test.stopTest();
        DataUpdatePortalController.TEST_FORCE_ERROR = false;

        System.assertEquals(false, result.success);
        System.assertEquals('GENERIC_ERROR', result.errorMessage);
    }

    @IsTest
    static void lookupRecord_ForcedError_ReturnsGenericError() {
        DataUpdatePortalController.TEST_FORCE_ERROR = true;
        DataUpdateWrapper.LookupResult result = DataUpdatePortalController.lookupRecord(FORM_NAME, 'X', 'Y', null);
        DataUpdatePortalController.TEST_FORCE_ERROR = false;
        System.assertEquals(false, result.success);
        System.assertEquals('GENERIC_ERROR', result.errorMessage);
    }

    @IsTest
    static void getFormDefinition_ForcedError_ReturnsGenericError() {
        DataUpdatePortalController.TEST_FORCE_ERROR = true;
        DataUpdateWrapper.FormDefinition def = DataUpdatePortalController.getFormDefinition(FORM_NAME);
        DataUpdatePortalController.TEST_FORCE_ERROR = false;
        System.assertEquals(false, def.success);
    }

    @IsTest
    static void lookupRecord_EgliseForm_NonBooleanBaseFilter_NotFound() {
        // Real église form settings with one active question: its questions can all be off in Settings.
        DataUpdateFormConfigService.testFormMdt = realForm('SEMBEQ_Eglise_Update');
        DataUpdateFormConfigService.testFieldMdts = (List<Data_Update_Form_Field__mdt>) JSON.deserialize(
            '[{"Field_API_Name__c":"Phone","Label_FR__c":"T","Label_EN__c":"T","Display_Order__c":1,'
            + '"Input_Type__c":"Phone","History_Mode__c":"Replace","Is_Active__c":true}]',
            List<Data_Update_Form_Field__mdt>.class);
        DataUpdateWrapper.LookupResult result;
        Test.startTest();
        System.runAs(appUser()) {
            result = DataUpdatePortalController.lookupRecord('SEMBEQ_Eglise_Update', 'I-DOESNOTEXIST', 'NOPE', null);
            if (result.errorMessage == 'GENERIC_ERROR') result.errorMessage += ' / ' + formError('SEMBEQ_Eglise_Update');
        }
        Test.stopTest();
        System.assertEquals(false, result.success);
        System.assertEquals('NOT_FOUND', result.errorMessage);
    }

    @IsTest
    static void findMatchingRecord_NormalizedIdentity1_SkipsNonMatchingCandidates() {
        String U = uniq();
        createTestContact('Nadeau' + U, 'Rene');
        DataUpdateFormConfigService.FormConfig config = DataUpdateFormConfigService.getForm(FORM_NAME);
        config.identityField1ApiName = 'LastName';
        config.identityField1Comparison = 'Normalized_Text';
        config.identityField2ApiName = null;

        Test.startTest();
        SObject miss = DataUpdatePortalController.findMatchingRecord(config, 'Nobody' + U, null);
        SObject hit  = DataUpdatePortalController.findMatchingRecord(config, 'nadeau' + U, null);
        Test.stopTest();

        System.assertEquals(null, miss);
        System.assertNotEquals(null, hit);
    }

    @IsTest
    static void findMatchingRecord_NonBooleanBaseFilter_KeepsOnlyListedValues() {
        String U = uniq();
        createTestContact('Nadeau' + U, 'Rene');
        DataUpdateFormConfigService.FormConfig config = DataUpdateFormConfigService.getForm(FORM_NAME);
        config.identityField1ApiName = 'LastName';
        config.identityField1Comparison = 'Normalized_Text';
        config.identityField2ApiName = null;
        config.targetBaseFilterField = 'FirstName';
        config.targetBaseFilterIsBoolean = false;

        config.targetBaseFilterValue = 'Rene';
        SObject hit = DataUpdatePortalController.findMatchingRecord(config, 'nadeau' + U, null);
        config.targetBaseFilterValue = 'Autre';
        SObject miss = DataUpdatePortalController.findMatchingRecord(config, 'nadeau' + U, null);

        System.assertNotEquals(null, hit, 'Record inside the base filter must match');
        System.assertEquals(null, miss, 'Record outside the base filter must not match');

        config.targetBaseFilterField = 'HasOptedOutOfEmail';
        config.targetBaseFilterIsBoolean = true;
        config.targetBaseFilterValue = 'false';
        System.assertNotEquals(null, DataUpdatePortalController.findMatchingRecord(config, 'nadeau' + U, null));
        config.targetBaseFilterValue = 'true';
        System.assertEquals(null, DataUpdatePortalController.findMatchingRecord(config, 'nadeau' + U, null));
    }

    @IsTest
    static void submitUpdate_InvalidCanadianPostalCode_ReturnsInvalidPostalCode() {
        String U = uniq();
        Contact a = createTestContact('Pelletier' + U, 'Guy');
        a = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a.Id LIMIT 1];

        Test.startTest();
        DataUpdateWrapper.SubmitResult result = DataUpdatePortalController.submitUpdate(
            FORM_NAME, a.ID_Contact__c, 'Pelletier' + U,
            '{"MailingPostalCode":"H2X","MailingCountry":"Canada"}', null
        );
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('INVALID_POSTAL_CODE', result.errorMessage);
        System.assertEquals('MailingPostalCode', result.invalidFieldApiName);
    }

    @IsTest
    static void submitUpdate_MalformedJson_ReturnsNoChanges() {
        String U = uniq();
        Contact a = createTestContact('Ouellet' + U, 'Lise');
        a = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a.Id LIMIT 1];

        Test.startTest();
        DataUpdateWrapper.SubmitResult result = DataUpdatePortalController.submitUpdate(
            FORM_NAME, a.ID_Contact__c, 'Ouellet' + U, '{not json', null
        );
        Test.stopTest();

        System.assertEquals('NO_CHANGES', result.errorMessage);
    }

    @IsTest
    static void submitUpdate_PicklistValues_InvalidDroppedValidKept() {
        String U = uniq();
        Contact a1 = createTestContact('Caron' + U, 'Yves');
        Contact a2 = createTestContact('Dube' + U, 'Joelle');
        a1 = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a1.Id LIMIT 1];
        a2 = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a2.Id LIMIT 1];

        String validValue = null;
        for (Schema.PicklistEntry pe : Contact.SObjectType.getDescribe().fields.getMap()
                .get('Excl_reason__c').getDescribe().getPicklistValues()) {
            if (pe.isActive()) { validValue = pe.getValue(); break; }
        }

        Test.startTest();
        DataUpdateWrapper.SubmitResult bad = DataUpdatePortalController.submitUpdate(
            FORM_NAME, a1.ID_Contact__c, 'Caron' + U,
            JSON.serialize(new Map<String, String>{ 'Excl_reason__c' => 'NOT_A_REAL_VALUE_' + U, 'Email' => 'c' + U + '@example.com' }), null
        );
        DataUpdateWrapper.SubmitResult good = DataUpdatePortalController.submitUpdate(
            FORM_NAME, a2.ID_Contact__c, 'Dube' + U,
            JSON.serialize(new Map<String, String>{ 'Excl_reason__c' => validValue }), null
        );
        Test.stopTest();

        System.assert(bad.success, 'Invalid picklist value is dropped, the rest still submits');
        Map<String, Object> badProposed = (Map<String, Object>) JSON.deserializeUntyped(
            [SELECT Proposed_Values_JSON__c FROM Data_Update_Request__c WHERE Id = :bad.requestId].Proposed_Values_JSON__c);
        System.assert(!badProposed.containsKey('Excl_reason__c'));

        System.assert(good.success, 'A real active picklist value is kept');
        Map<String, Object> goodProposed = (Map<String, Object>) JSON.deserializeUntyped(
            [SELECT Proposed_Values_JSON__c FROM Data_Update_Request__c WHERE Id = :good.requestId].Proposed_Values_JSON__c);
        System.assertEquals(validValue, goodProposed.get('Excl_reason__c'));
    }

    // ─── History_Only ───────────────────────────────────────────────────────

    private static final String HIST_ONLY_KEY = 'Task.CallDurationInSeconds';

    // A real form record with every field loadForm() reads (a missing one throws on access).
    private static Data_Update_Form__mdt realForm(String developerName) {
        return DucFormConfigStore.form(developerName);
    }

    // Real Contact form identity/lock settings, but with a History_Only field added (Task stands in
    // for the history object: SEMBEQ has no Attendance_History__c).
    private static void useHistoryOnlyForm() {
        DataUpdateFormConfigService.testFormMdt = realForm(FORM_NAME);
        DataUpdateFormConfigService.testFieldMdts = (List<Data_Update_Form_Field__mdt>) JSON.deserialize(
            '[{"Field_API_Name__c":"' + HIST_ONLY_KEY + '","Label_FR__c":"Assistance","Label_EN__c":"Attendance",'
            + '"Display_Order__c":1,"Input_Type__c":"Number","History_Mode__c":"History_Only","Is_Active__c":true,'
            + '"History_Target_Object_API_Name__c":"Task","History_Target_Value_Field_API_Name__c":"CallDurationInSeconds",'
            + '"History_Target_Date_Field_API_Name__c":"ActivityDate","History_Target_Account_Field_API_Name__c":"WhoId"},'
            + '{"Field_API_Name__c":"Email","Label_FR__c":"C","Label_EN__c":"E","Display_Order__c":2,'
            + '"Input_Type__c":"Email","History_Mode__c":"Replace","Is_Active__c":true}]',
            List<Data_Update_Form_Field__mdt>.class);
    }

    @IsTest
    static void historyOnly_FormDefinitionExposesDateKey() {
        useHistoryOnlyForm();
        DataUpdateWrapper.FormDefinition def;
        Test.startTest();
        System.runAs(appUser()) {
            def = DataUpdatePortalController.getFormDefinition(FORM_NAME);
            if (!def.success) def.errorMessage = formError(FORM_NAME);
        }
        Test.stopTest();

        System.assert(def.success, def.errorMessage);
        DataUpdateWrapper.FieldDefinition fd = def.fields[0];
        System.assertEquals(HIST_ONLY_KEY, fd.fieldApiName);
        System.assertEquals(true, fd.isHistoryOnly);
        System.assertEquals(HIST_ONLY_KEY + '@date', fd.historyDateKey);
        System.assertEquals(false, def.fields[1].isHistoryOnly);
    }

    @IsTest
    static void historyOnly_SubmitKeepsValidDateDropsBadDateAndBlankValue() {
        String U = uniq();
        Contact a1 = createTestContact('Hist' + U, 'Un');
        Contact a2 = createTestContact('Histo' + U, 'Deux');
        Contact a3 = createTestContact('Histor' + U, 'Trois');
        a1 = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a1.Id LIMIT 1];
        a2 = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a2.Id LIMIT 1];
        a3 = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a3.Id LIMIT 1];
        useHistoryOnlyForm();

        DataUpdateWrapper.SubmitResult dated, badDate, blank;
        Test.startTest();
        System.runAs(appUser()) {
            dated = DataUpdatePortalController.submitUpdate(FORM_NAME, a1.ID_Contact__c, 'Hist' + U,
                JSON.serialize(new Map<String, String>{ HIST_ONLY_KEY => '42', HIST_ONLY_KEY + '@date' => '2026-09-01' }), null);
            badDate = DataUpdatePortalController.submitUpdate(FORM_NAME, a2.ID_Contact__c, 'Histo' + U,
                JSON.serialize(new Map<String, String>{ HIST_ONLY_KEY => '7', HIST_ONLY_KEY + '@date' => '01/09/2026' }), null);
            blank = DataUpdatePortalController.submitUpdate(FORM_NAME, a3.ID_Contact__c, 'Histor' + U,
                JSON.serialize(new Map<String, String>{ HIST_ONLY_KEY => '', HIST_ONLY_KEY + '@date' => '2026-09-01',
                    'Email' => 'h' + U + '@example.com' }), null);
            if (!dated.success) dated.errorMessage += ' / ' + formError(FORM_NAME);
        }
        Test.stopTest();

        System.assert(dated.success, 'Dated submit should succeed: ' + dated.errorMessage);
        Map<String, Object> p1 = (Map<String, Object>) JSON.deserializeUntyped(
            [SELECT Proposed_Values_JSON__c FROM Data_Update_Request__c WHERE Id = :dated.requestId].Proposed_Values_JSON__c);
        System.assertEquals('42', p1.get(HIST_ONLY_KEY));
        System.assertEquals('2026-09-01', p1.get(HIST_ONLY_KEY + '@date'));

        System.assert(badDate.success, 'A malformed date is dropped, the value still submits');
        Map<String, Object> p2 = (Map<String, Object>) JSON.deserializeUntyped(
            [SELECT Proposed_Values_JSON__c FROM Data_Update_Request__c WHERE Id = :badDate.requestId].Proposed_Values_JSON__c);
        System.assertEquals('7', p2.get(HIST_ONLY_KEY));
        System.assert(!p2.containsKey(HIST_ONLY_KEY + '@date'));

        System.assert(blank.success);
        Map<String, Object> p3 = (Map<String, Object>) JSON.deserializeUntyped(
            [SELECT Proposed_Values_JSON__c FROM Data_Update_Request__c WHERE Id = :blank.requestId].Proposed_Values_JSON__c);
        System.assert(!p3.containsKey(HIST_ONLY_KEY), 'A blank history value is not a data point');
        System.assert(!p3.containsKey(HIST_ONLY_KEY + '@date'));
    }

    @IsTest
    static void isValidIsoDate_Cases() {
        System.assert(DataUpdatePortalController.isValidIsoDate('2026-09-01'));
        System.assert(!DataUpdatePortalController.isValidIsoDate(null));
        System.assert(!DataUpdatePortalController.isValidIsoDate('2026-9-1'));
        System.assert(!DataUpdatePortalController.isValidIsoDate('aaaa-bb-cc'));
    }

    private static DataUpdateFormConfigService.FormFieldConfig fieldConfig(String apiName, Boolean readOnly, String historyMode) {
        DataUpdateFormConfigService.FormFieldConfig fc = new DataUpdateFormConfigService.FormFieldConfig();
        fc.fieldApiName = apiName;
        fc.isReadOnly = readOnly;
        fc.historyMode = historyMode;
        fc.inputType = 'Text';
        return fc;
    }

    @IsTest
    static void buildReadOnlyValues_OnlyReadOnlyRecordValues() {
        DataUpdateFormConfigService.FormConfig config = new DataUpdateFormConfigService.FormConfig();
        config.targetObjectApiName = 'Account';
        config.fields = new List<DataUpdateFormConfigService.FormFieldConfig>{
            fieldConfig('Name', true, 'Replace'),
            fieldConfig('Phone', false, 'Replace'),
            fieldConfig('Website', true, 'Replace'),
            fieldConfig('CreatedDate', true, 'Replace'),
            fieldConfig('Task.CallDurationInSeconds', true, 'History_Only')
        };
        Account a = (Account) JSON.deserialize(
            '{"attributes":{"type":"Account"},"Name":"Église test","Phone":"514-555-0000","CreatedDate":"2026-03-05T10:00:00.000+0000"}',
            Account.class);
        Map<String, Object> values = (Map<String, Object>) JSON.deserializeUntyped(
            DataUpdatePortalController.buildReadOnlyValues(config, a));
        System.assertEquals('Église test', values.get('Name'));
        System.assert(!values.containsKey('Phone'), 'editable field is not sent');
        System.assert(!values.containsKey('Website'), 'blank value is left out');
        System.assert(String.valueOf(values.get('CreatedDate')).startsWith('2026-03-0'), 'datetime as a date');
        System.assert(!values.containsKey('Task.CallDurationInSeconds'), 'history-only key has no record value');

        // A Date is sent as yyyy-MM-dd, never with a time part.
        config.fields = new List<DataUpdateFormConfigService.FormFieldConfig>{ fieldConfig('Excl_date__c', true, 'Replace') };
        Account dated = new Account(Name = 'X');
        dated.put('Excl_date__c', Date.newInstance(2026, 3, 5));
        values = (Map<String, Object>) JSON.deserializeUntyped(DataUpdatePortalController.buildReadOnlyValues(config, dated));
        System.assertEquals('2026-03-05', values.get('Excl_date__c'));
    }

    @IsTest
    static void buildProposedValues_IgnoresReadOnlyFields() {
        DataUpdateFormConfigService.FormConfig config = new DataUpdateFormConfigService.FormConfig();
        config.targetObjectApiName = 'Account';
        config.fields = new List<DataUpdateFormConfigService.FormFieldConfig>{
            fieldConfig('Name', true, 'Replace'),
            fieldConfig('Phone', false, 'Replace')
        };
        config.tables = new List<DataUpdateFormConfigService.FormFieldConfig>();
        Map<String, String> proposed = DataUpdatePortalController.buildProposedValues(
            '{"Name":"Forged","Phone":"514-555-0000"}', config);
        System.assertEquals('514-555-0000', proposed.get('Phone'));
        System.assert(!proposed.containsKey('Name'), 'a read-only field never reaches the review');
    }

    // ─── History_Table (églises: paste-from-Excel history) ──────────────────

    private static final String HT_KEY = 'Task#table';

    private static String htFieldJson(String columnsJson) {
        return '{"Field_API_Name__c":"' + HT_KEY + '","Label_FR__c":"Assistance","Label_EN__c":"Attendance",'
            + '"Display_Order__c":2,"Input_Type__c":"Text","History_Mode__c":"History_Table","Is_Active__c":true,'
            + '"History_Target_Object_API_Name__c":"Task","History_Target_Date_Field_API_Name__c":"ActivityDate",'
            + '"History_Target_Account_Field_API_Name__c":"WhoId",'
            + '"History_Table_Columns__c":' + JSON.serialize(columnsJson) + '}';
    }

    private static final String HT_COLUMNS =
        '[{"f":"ActivityDate","fr":"Date","en":"Date"},{"f":"CallDurationInSeconds","fr":"Personnes","en":"People"}]';

    private static void useHistoryTableFakeForm(String columnsJson) {
        DataUpdateFormConfigService.testFormMdt = (Data_Update_Form__mdt) JSON.deserialize(
            '{"DeveloperName":"Fake_Table_Form","MasterLabel":"Fake","Target_Object_API_Name__c":"Contact",'
            + '"Identity_Field_1_API_Name__c":"Name","Identity_Field_1_Comparison__c":"Exact",'
            + '"Subject_Template__c":"{RecordName}","Is_Active__c":true,"Lock_Field_API_Name__c":"Data_Update_Locked__c"}',
            Data_Update_Form__mdt.class);
        DataUpdateFormConfigService.testFieldMdts = (List<Data_Update_Form_Field__mdt>) JSON.deserialize(
            '[{"Field_API_Name__c":"Phone","Label_FR__c":"T","Label_EN__c":"T","Display_Order__c":1,'
            + '"Input_Type__c":"Phone","History_Mode__c":"Replace","Is_Active__c":true},'
            + htFieldJson(columnsJson) + ']',
            List<Data_Update_Form_Field__mdt>.class);
    }

    private static List<Object> htRows(List<List<String>> rows) {
        return (List<Object>) JSON.deserializeUntyped(JSON.serialize(rows));
    }

    @IsTest
    static void buildTableValue_KeepsGoodLinesAndRejectsBadOnes() {
        useHistoryTableFakeForm(HT_COLUMNS);
        DataUpdateFormConfigService.FormFieldConfig tc = DataUpdateFormConfigService.getForm('Fake_Table_Form').tables[0];

        String stored = DataUpdatePortalController.buildTableValue(tc, htRows(new List<List<String>>{
            new List<String>{ '2026-08-02', '35' },
            new List<String>{ '', '' },
            new List<String>{ '2026-08-09', '40.5' }
        }));
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(stored);
        System.assertEquals(2, ((List<Object>) parsed.get('rows')).size(), 'Blank lines are dropped');
        System.assertEquals('ActivityDate', ((List<Object>) parsed.get('cols'))[0]);

        System.assertEquals(null, DataUpdatePortalController.buildTableValue(tc, htRows(new List<List<String>>{
            new List<String>{ '', '' }
        })));

        List<Object> bad = new List<Object>{
            'not a list',
            htRows(new List<List<String>>{ new List<String>{ '02/08/2026', '35' } }),
            htRows(new List<List<String>>{ new List<String>{ '2026-08-02', '1,5' } }),
            htRows(new List<List<String>>{ new List<String>{ '', '35' } }),
            htRows(new List<List<String>>{ new List<String>{ '2026-08-02', '1' }, new List<String>{ '2026-08-02', '2' } }),
            htRows(new List<List<String>>{ new List<String>{ '2026-08-02', '1', 'extra' } }),
            new List<Object>{ 'row not a list' }
        };
        for (Object rows : bad) {
            Boolean rejected = false;
            try {
                DataUpdatePortalController.buildTableValue(tc, rows);
            } catch (DataUpdatePortalController.TableValidationException e) {
                rejected = true;
            }
            System.assert(rejected, 'Must be rejected: ' + JSON.serialize(rows));
        }

        List<List<String>> tooMany = new List<List<String>>();
        Date d = Date.newInstance(2000, 1, 1);
        for (Integer i = 0; i <= DataUpdateFormConfigService.HISTORY_TABLE_MAX_ROWS; i++) {
            tooMany.add(new List<String>{ String.valueOf(d.addDays(i)), '1' });
        }
        Boolean limitHit = false;
        try {
            DataUpdatePortalController.buildTableValue(tc, htRows(tooMany));
        } catch (DataUpdatePortalController.TableValidationException e) {
            limitHit = true;
        }
        System.assert(limitHit, 'More than the maximum number of lines is rejected');
    }

    @IsTest
    static void isValidTableCell_ChecksEveryKind() {
        DataUpdateWrapper.TableColumnDefinition col = new DataUpdateWrapper.TableColumnDefinition();
        col.kind = 'Checkbox';
        System.assert(DataUpdatePortalController.isValidTableCell(col, 'true'));
        System.assert(!DataUpdatePortalController.isValidTableCell(col, 'oui'));

        col.kind = 'Picklist';
        DataUpdateWrapper.PicklistOption opt = new DataUpdateWrapper.PicklistOption();
        opt.label = 'Oui';
        opt.value = 'Yes';
        col.picklistOptions = new List<DataUpdateWrapper.PicklistOption>{ opt };
        System.assert(DataUpdatePortalController.isValidTableCell(col, 'Yes'));
        System.assert(!DataUpdatePortalController.isValidTableCell(col, 'Oui'));

        col.kind = 'Text';
        col.maxLength = 3;
        System.assert(DataUpdatePortalController.isValidTableCell(col, 'abc'));
        System.assert(!DataUpdatePortalController.isValidTableCell(col, 'abcd'));

        col.kind = 'Number';
        System.assert(DataUpdatePortalController.isValidTableCell(col, '-12.5'));
        System.assert(!DataUpdatePortalController.isValidTableCell(col, '12a'));

        col.kind = 'Date';
        System.assert(DataUpdatePortalController.isValidTableCell(col, '2026-02-28'));
        System.assert(!DataUpdatePortalController.isValidTableCell(col, '2026-02-30'));
    }

    @IsTest
    static void getFormDefinition_ExposesHistoryTable() {
        useHistoryTableFakeForm(HT_COLUMNS);
        DataUpdateWrapper.FormDefinition def = DataUpdatePortalController.getFormDefinition('Fake_Table_Form');
        System.assert(def.success, def.errorMessage);
        System.assertEquals(1, def.tables.size());
        System.assertEquals(HT_KEY, def.tables[0].key);
        System.assertEquals('People', def.tables[0].columns[1].labelEn);
        System.assertEquals(DataUpdateFormConfigService.HISTORY_TABLE_MAX_ROWS, def.tables[0].maxRows);
        System.assertEquals('Excel', def.tables[0].inputMode, 'A table published before the input-mode option stays a paste grid');
    }

    // ─── Type checks / editable checkboxes ──────────────────────────────────

    @IsTest
    static void submitUpdate_InvalidEmail_ReturnsInvalidValue_NoRequestCreated() {
        String U = uniq();
        Contact a = createTestContact('Typage' + U, 'Luc');
        a = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a.Id LIMIT 1];

        Test.startTest();
        DataUpdateWrapper.SubmitResult result = DataUpdatePortalController.submitUpdate(
            FORM_NAME, a.ID_Contact__c, 'Typage' + U, '{"Email":"pas-un-courriel"}', null
        );
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('INVALID_VALUE', result.errorMessage);
        System.assertEquals('Email', result.invalidFieldApiName);
        System.assertEquals(0, [SELECT COUNT() FROM Data_Update_Request__c WHERE Target_Record_Id__c = :a.Id]);
        System.assertEquals(false, [SELECT Data_Update_Locked__c FROM Contact WHERE Id = :a.Id].Data_Update_Locked__c);
    }

    @IsTest
    static void submitUpdate_Email_StoredLowercase() {
        String U = uniq();
        Contact a = createTestContact('Minus' + U, 'Luc');
        a = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :a.Id LIMIT 1];

        Test.startTest();
        DataUpdateWrapper.SubmitResult result = DataUpdatePortalController.submitUpdate(
            FORM_NAME, a.ID_Contact__c, 'Minus' + U, '{"Email":" Luc.Minus' + U + '@Example.COM "}', null
        );
        Test.stopTest();

        System.assert(result.success, result.errorMessage);
        String json = [SELECT Proposed_Values_JSON__c FROM Data_Update_Request__c WHERE Target_Record_Id__c = :a.Id LIMIT 1].Proposed_Values_JSON__c;
        System.assert(json.contains('"luc.minus' + U.toLowerCase() + '@example.com"'), json);
    }

    @IsTest
    static void buildReadOnlyValues_SendsEditableCheckboxState() {
        DataUpdateFormConfigService.FormConfig config = new DataUpdateFormConfigService.FormConfig();
        config.targetObjectApiName = 'Contact';
        DataUpdateFormConfigService.FormFieldConfig box = fieldConfig('Data_Update_Locked__c', false, 'Replace');
        box.inputType = 'Checkbox';
        config.fields = new List<DataUpdateFormConfigService.FormFieldConfig>{ box, fieldConfig('Phone', false, 'Replace') };
        Contact a = new Contact(LastName = 'X', Phone = '514-555-0000');
        a.put('Data_Update_Locked__c', true);

        Map<String, Object> values = (Map<String, Object>) JSON.deserializeUntyped(
            DataUpdatePortalController.buildReadOnlyValues(config, a));
        System.assertEquals('true', values.get('Data_Update_Locked__c'), 'the form starts the box checked');
        System.assert(!values.containsKey('Phone'), 'other editable fields are still not sent');
    }

    @IsTest
    static void submitUpdate_UncheckedBox_IsProposedAsFalse() {
        DataUpdateFormConfigService.FormConfig config = new DataUpdateFormConfigService.FormConfig();
        config.targetObjectApiName = 'Contact';
        DataUpdateFormConfigService.FormFieldConfig box = fieldConfig('Data_Update_Locked__c', false, 'Replace');
        box.inputType = 'Checkbox';
        config.fields = new List<DataUpdateFormConfigService.FormFieldConfig>{ box };
        config.tables = new List<DataUpdateFormConfigService.FormFieldConfig>();

        Map<String, String> proposed = DataUpdatePortalController.buildProposedValues('{"Data_Update_Locked__c":"false"}', config);
        System.assertEquals('false', proposed.get('Data_Update_Locked__c'));
    }

    // ─── Submit with a history table (fake form identified by Name) ────────

    private static String tableSubmitAccountName() {
        Contact a = createTestContact('Tableau' + uniq(), 'Luc');
        return [SELECT Name FROM Contact WHERE Id = :a.Id].Name;
    }

    @IsTest
    static void submitUpdate_HistoryTable_StoresCleanRows() {
        // Description is an optional column: the row may leave it blank.
        useHistoryTableFakeForm(HT_COLUMNS.removeEnd(']') + ',{"f":"Description","fr":"N","en":"N"}]');
        String name = tableSubmitAccountName();
        String payload = JSON.serialize(new Map<String, Object>{
            HT_KEY => new List<Object>{ new List<Object>{ '2026-08-02', '35' } }
        });

        Test.startTest();
        DataUpdateWrapper.SubmitResult result = DataUpdatePortalController.submitUpdate('Fake_Table_Form', name, null, payload, null);
        Test.stopTest();

        System.assert(result.success, result.errorMessage);
        Data_Update_Request__c t = [SELECT Proposed_Values_JSON__c FROM Data_Update_Request__c WHERE Id = :result.requestId];
        Map<String, Object> proposed = (Map<String, Object>) JSON.deserializeUntyped(t.Proposed_Values_JSON__c);
        System.assert(proposed.containsKey(HT_KEY), t.Proposed_Values_JSON__c);
    }

    @IsTest
    static void submitUpdate_HistoryTable_BadRowsReturnInvalidTable() {
        useHistoryTableFakeForm(HT_COLUMNS);
        String name = tableSubmitAccountName();
        String json = JSON.serialize(new Map<String, Object>{ HT_KEY => 'not a list' });

        Test.startTest();
        DataUpdateWrapper.SubmitResult result = DataUpdatePortalController.submitUpdate('Fake_Table_Form', name, null, json, null);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('INVALID_TABLE', result.errorMessage);
        System.assertEquals(0, [SELECT COUNT() FROM Data_Update_Request__c WHERE Update_Form_DeveloperName__c = 'Fake_Table_Form']);
    }

    @IsTest
    static void submitUpdate_OversizedValues_ReturnInvalidTable() {
        useHistoryTableFakeForm(HT_COLUMNS);
        String name = tableSubmitAccountName();
        DataUpdatePortalController.PROPOSED_VALUES_MAX_LENGTH = 10;

        Test.startTest();
        DataUpdateWrapper.SubmitResult result = DataUpdatePortalController.submitUpdate(
            'Fake_Table_Form', name, null, '{"Phone":"514-555-0101"}', null);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('INVALID_TABLE', result.errorMessage);
    }
}
