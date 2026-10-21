@IsTest(SeeAllData=false)
private class DataUpdateReviewControllerTest {

    private static final String FORM_NAME = 'SEMBEQ_Contact_Update';
    private static final String FAKE_RECORD_ID = '003000000000000AAA';

    private static String uniq() {
        return String.valueOf(DateTime.now().getTime()) + String.valueOf(Crypto.getRandomInteger());
    }

    private static void applyDupBypass(Database.DMLOptions dmo) {
        dmo.DuplicateRuleHeader.allowSave = true;
        dmo.DuplicateRuleHeader.runAsCurrentUser = true;
    }

    private static SObject insertResilient(SObject a) {
        Database.DMLOptions dmo = new Database.DMLOptions();
        applyDupBypass(dmo);
        Database.SaveResult sr = Database.insert(new List<SObject>{ a }, dmo)[0];
        System.assert(sr.isSuccess(), 'Insert failed: ' +
            (sr.getErrors().isEmpty() ? 'unknown' : sr.getErrors()[0].getMessage()));
        a.Id = sr.getId();
        return a;
    }

    private static Contact createTestContact(String lastName, String firstName) {
        Contact a = new Contact(LastName = lastName, FirstName = firstName);
        a.put('Alternative_Email_1__c', 'current' + uniq() + '@example.com');
        a.put('MobilePhone', '5140000000');
        return (Contact) insertResilient(a);
    }

    // Contact.Email is not used as the test field: EDA's preferred-email rule (on in SEMBEQ)
    // copies hed__AlternateEmail__c back into Email, which would undo any direct change.
    private static String getEmail(SObject rec) {
        return (String) rec.get('Alternative_Email_1__c');
    }

    private static String getMobilePhone(SObject rec) {
        return (String) rec.get('MobilePhone');
    }

    private static Contact queryContactEmailAndPhone(Id recId) {
        return (Contact) Database.query('SELECT Id, Alternative_Email_1__c, MobilePhone FROM Contact WHERE Id = :recId LIMIT 1');
    }

    private static Contact queryContactEmailOnly(Id recId) {
        return (Contact) Database.query('SELECT Id, Alternative_Email_1__c FROM Contact WHERE Id = :recId LIMIT 1');
    }

    private static Data_Update_Request__c createReviewRequest(Id accountId, String proposedJson) {
        Data_Update_Request__c t = new Data_Update_Request__c(
            Target_Object_API_Name__c = 'Contact',
            Target_Record_Id__c = accountId,
            Update_Form_DeveloperName__c = FORM_NAME,
            Status__c = 'New',
            Subject__c = 'Review request ' + uniq(),
            Proposed_Values_JSON__c = proposedJson
        );
        insert t;
        return t;
    }

    // ─── getReviewSummary ───────────────────────────────────────────────────

    @IsTest
    static void getReviewSummary_CountsChangedFields() {
        String U = uniq();
        Contact a = createTestContact('Martin' + U, 'Lucie');
        a = queryContactEmailAndPhone(a.Id);
        String proposedJson = JSON.serialize(new Map<String, String>{
            'Alternative_Email_1__c' => 'brandnew' + U + '@example.com',
            'MobilePhone' => getMobilePhone(a)
        });
        Data_Update_Request__c t = createReviewRequest(a.Id, proposedJson);

        Test.startTest();
        DataUpdateWrapper.ReviewSummary summary = DataUpdateReviewController.getReviewSummary(t.Id);
        Test.stopTest();

        System.assert(summary.success);
        System.assertEquals(false, summary.requestClosed);
        System.assertEquals(1, summary.changedFieldCount, 'Only the email differs from the current value');
    }

    @IsTest
    static void getReviewSummary_RequestNotFound_ReturnsGenericError() {
        Test.startTest();
        DataUpdateWrapper.ReviewSummary summary = DataUpdateReviewController.getReviewSummary(UserInfo.getUserId());
        Test.stopTest();

        System.assertEquals(false, summary.success);
        System.assertEquals('GENERIC_ERROR', summary.errorMessage);
    }

    // ─── getComparisonData ──────────────────────────────────────────────────

    @IsTest
    static void getComparisonData_BuildsOnlyDifferingFields() {
        String U = uniq();
        Contact a = createTestContact('Martin' + U, 'Lucie');
        a = queryContactEmailAndPhone(a.Id);
        String proposedJson = JSON.serialize(new Map<String, String>{
            'Alternative_Email_1__c' => 'brandnew' + U + '@example.com',
            'MobilePhone' => getMobilePhone(a)
        });
        Data_Update_Request__c t = createReviewRequest(a.Id, proposedJson);

        Test.startTest();
        DataUpdateWrapper.ComparisonData data = DataUpdateReviewController.getComparisonData(t.Id);
        Test.stopTest();

        System.assert(data.success);
        System.assertEquals(a.Id, Id.valueOf(data.recordId));
        System.assertEquals(false, data.requestClosed);
        System.assertEquals(1, data.fields.size(), 'Only the differing field must be listed');
        System.assertEquals('Alternative_Email_1__c', data.fields[0].fieldApiName);
        System.assert(data.fields[0].isDifferent);
    }

    @IsTest
    static void getComparisonData_RequestNotFound_ReturnsGenericError() {
        Test.startTest();
        DataUpdateWrapper.ComparisonData data = DataUpdateReviewController.getComparisonData(UserInfo.getUserId());
        Test.stopTest();

        System.assertEquals(false, data.success);
        System.assertEquals('GENERIC_ERROR', data.errorMessage);
    }

    @IsTest
    static void getComparisonData_NoTargetRecord_ReturnsRecordNotFound() {
        Data_Update_Request__c t = new Data_Update_Request__c(
            Target_Object_API_Name__c = 'Contact',
            Target_Record_Id__c = FAKE_RECORD_ID,
            Update_Form_DeveloperName__c = FORM_NAME,
            Status__c = 'New',
            Subject__c = 'No target record',
            Proposed_Values_JSON__c = '{"Alternative_Email_1__c":"x@example.com"}'
        );
        insert t;

        Test.startTest();
        DataUpdateWrapper.ComparisonData data = DataUpdateReviewController.getComparisonData(t.Id);
        Test.stopTest();

        System.assertEquals(false, data.success);
        System.assertEquals('RECORD_NOT_FOUND', data.errorMessage);
    }

    @IsTest
    static void getComparisonData_MalformedJson_TreatedAsNoFields() {
        String U = uniq();
        Contact a = createTestContact('Vachon' + U, 'Renee');
        Data_Update_Request__c t = createReviewRequest(a.Id, 'not valid json {');

        Test.startTest();
        DataUpdateWrapper.ComparisonData data = DataUpdateReviewController.getComparisonData(t.Id);
        Test.stopTest();

        System.assert(data.success, 'Malformed JSON must not blow up the review — just yield no fields');
        System.assert(data.fields.isEmpty());
    }

    // ─── applySelectedUpdates ───────────────────────────────────────────────

    @IsTest
    static void applySelectedUpdates_PartialApply_OnlySelectedFieldsChange() {
        String U = uniq();
        Contact a = createTestContact('Poirier' + U, 'Chantal');
        a = queryContactEmailAndPhone(a.Id);
        String originalPhone = getMobilePhone(a);
        String newEmail = 'updated' + U + '@example.com';
        String newPhone = '5141234567';
        String proposedJson = JSON.serialize(new Map<String, String>{
            'Alternative_Email_1__c' => newEmail,
            'MobilePhone' => newPhone
        });
        Data_Update_Request__c t = createReviewRequest(a.Id, proposedJson);

        Test.startTest();
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Alternative_Email_1__c' });
        Test.stopTest();

        System.assert(result.success);
        System.assertEquals(1, result.updatedFieldCount);

        Contact updated = queryContactEmailAndPhone(a.Id);
        System.assertEquals(newEmail, getEmail(updated));
        System.assertEquals(originalPhone, getMobilePhone(updated), 'Unselected field must remain unchanged');

        Data_Update_Request__c closed = [SELECT Status__c, Final_Action__c, Closed_Reason__c FROM Data_Update_Request__c WHERE Id = :t.Id LIMIT 1];
        System.assertEquals('Applied', closed.Status__c, 'Request must be Applied after apply');
        System.assertEquals('Applied', closed.Final_Action__c);
        System.assertEquals('Applied', closed.Closed_Reason__c);
    }

    @IsTest
    static void applySelectedUpdates_FullApply_AllFieldsChange() {
        String U = uniq();
        Contact a = createTestContact('Bouchard' + U, 'Remi');
        String newEmail = 'full' + U + '@example.com';
        String newPhone = '5149998888';
        String proposedJson = JSON.serialize(new Map<String, String>{
            'Alternative_Email_1__c' => newEmail,
            'MobilePhone' => newPhone
        });
        Data_Update_Request__c t = createReviewRequest(a.Id, proposedJson);

        Test.startTest();
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.applySelectedUpdates(
            t.Id, new List<String>{ 'Alternative_Email_1__c', 'MobilePhone' }
        );
        Test.stopTest();

        System.assert(result.success);
        System.assertEquals(2, result.updatedFieldCount);

        Contact updated = queryContactEmailAndPhone(a.Id);
        System.assertEquals(newEmail, getEmail(updated));
        System.assertEquals(newPhone, getMobilePhone(updated));
    }

    @IsTest
    static void applySelectedUpdates_NoFieldsSelected_ClosesRequestWithoutAccountUpdate() {
        String U = uniq();
        Contact a = createTestContact('Girard' + U, 'Nadia');
        a = queryContactEmailOnly(a.Id);
        String originalEmail = getEmail(a);
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'Alternative_Email_1__c' => 'ignored@example.com' }));

        Test.startTest();
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.applySelectedUpdates(t.Id, null);
        Test.stopTest();

        System.assert(result.success);
        System.assertEquals(0, result.updatedFieldCount);

        Contact unchanged = queryContactEmailOnly(a.Id);
        System.assertEquals(originalEmail, getEmail(unchanged));

        Data_Update_Request__c closed = [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id LIMIT 1];
        System.assertEquals('Applied', closed.Status__c);
    }

    @IsTest
    static void applySelectedUpdates_IgnoresFieldNotInCatalogOrNotProposed() {
        String U = uniq();
        Contact a = createTestContact('Charest' + U, 'Olivier');
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'Alternative_Email_1__c' => 'x@example.com' }));

        Test.startTest();
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.applySelectedUpdates(
            t.Id, new List<String>{ 'Name', 'HomePhone' }
        );
        Test.stopTest();

        System.assert(result.success);
        System.assertEquals(0, result.updatedFieldCount);
    }

    @IsTest
    static void applySelectedUpdates_RequestNotFound_ReturnsGenericError() {
        Test.startTest();
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.applySelectedUpdates(UserInfo.getUserId(), new List<String>{ 'Alternative_Email_1__c' });
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('GENERIC_ERROR', result.errorMessage);
    }

    @IsTest
    static void applySelectedUpdates_AlreadyClosedRequest_ReturnsError() {
        String U = uniq();
        Contact a = createTestContact('Fournier' + U, 'Sophie');
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'Alternative_Email_1__c' => 'x@example.com' }));
        update new Data_Update_Request__c(Id = t.Id, Status__c = 'Closed', Closed_Reason__c = 'Applied');

        Test.startTest();
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Alternative_Email_1__c' });
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('TICKET_ALREADY_CLOSED', result.errorMessage);
    }

    @IsTest
    static void applySelectedUpdates_ForcedError_ReturnsGenericError() {
        String U = uniq();
        Contact a = createTestContact('Simoneau' + U, 'David');
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'Alternative_Email_1__c' => 'x@example.com' }));

        DataUpdateReviewController.TEST_FORCE_ERROR = true;
        Test.startTest();
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Alternative_Email_1__c' });
        Test.stopTest();
        DataUpdateReviewController.TEST_FORCE_ERROR = false;

        System.assertEquals(false, result.success);
        System.assertEquals('GENERIC_ERROR', result.errorMessage);
    }

    // ─── Audit log integration (new — no Case-based precedent) ─────────────

    @IsTest
    static void applySelectedUpdates_Success_CreatesCompletedLogWithSnapshots() {
        String U = uniq();
        Contact a = createTestContact('Ouellet' + U, 'Marc');
        String newEmail = 'audited' + U + '@example.com';
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'Alternative_Email_1__c' => newEmail }));

        Test.startTest();
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Alternative_Email_1__c' });
        Test.stopTest();

        System.assert(result.success);
        Data_Update_Log__c log = [
            SELECT Action_Type__c, Request__c, Before_Snapshot_JSON__c, After_Snapshot_JSON__c
            FROM Data_Update_Log__c WHERE Request__c = :t.Id LIMIT 1
        ];
        System.assertEquals('APPLY_COMPLETED', log.Action_Type__c);
        System.assert(String.isNotBlank(log.Before_Snapshot_JSON__c));
        System.assert(log.After_Snapshot_JSON__c.contains(newEmail));
    }

    @IsTest
    static void applySelectedUpdates_AfterReopen_CreatesDistinctSecondLog() {
        String U = uniq();
        Contact a = createTestContact('Tremblay' + U, 'Julie');
        String firstEmail = 'first' + U + '@example.com';
        String secondPhone = '5145551111';
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{
            'Alternative_Email_1__c'       => firstEmail,
            'MobilePhone' => secondPhone
        }));

        Test.startTest();
        DataUpdateWrapper.ApplyResult first = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Alternative_Email_1__c' });
        DataUpdateReviewController.reopenRequest(t.Id);
        DataUpdateWrapper.ApplyResult second = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'MobilePhone' });
        Test.stopTest();

        System.assert(first.success);
        System.assert(second.success);

        List<Data_Update_Log__c> logs = [
            SELECT Action_Type__c FROM Data_Update_Log__c WHERE Request__c = :t.Id ORDER BY CreatedDate ASC
        ];
        System.assertEquals(2, logs.size(), 'Reopen after Applied must create a fresh log, not reuse the sealed one');
        System.assertEquals('APPLY_COMPLETED', logs[0].Action_Type__c);
        System.assertEquals('APPLY_COMPLETED', logs[1].Action_Type__c);

        Contact updated = queryContactEmailAndPhone(a.Id);
        System.assertEquals(firstEmail, getEmail(updated));
        System.assertEquals(secondPhone, getMobilePhone(updated));
    }

    // ─── correctProposedValue ───────────────────────────────────────────────

    @IsTest
    static void correctProposedValue_Success_UpdatesJsonAndCreatesCorrectedLog() {
        String U = uniq();
        Contact a = createTestContact('Corrige' + U, 'Yvon');
        String typoEmail = 'tpyo' + U + '@example.com';
        String fixedEmail = 'fixed' + U + '@example.com';
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'Alternative_Email_1__c' => typoEmail }));

        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(t.Id, 'Alternative_Email_1__c', '  ' + fixedEmail + '  ');
        Test.stopTest();

        System.assert(result.success);
        System.assertEquals(fixedEmail, result.newValue, 'Value must be trimmed before saving');

        Data_Update_Request__c updated = [SELECT Proposed_Values_JSON__c FROM Data_Update_Request__c WHERE Id = :t.Id LIMIT 1];
        System.assert(updated.Proposed_Values_JSON__c.contains(fixedEmail));
        System.assert(!updated.Proposed_Values_JSON__c.contains(typoEmail));

        Data_Update_Log__c log = [
            SELECT Action_Type__c, Field_Decisions_JSON__c, Before_Snapshot_JSON__c, After_Snapshot_JSON__c
            FROM Data_Update_Log__c WHERE Request__c = :t.Id AND Action_Type__c = 'CORRECTED' LIMIT 1
        ];
        System.assert(String.isNotBlank(log.Before_Snapshot_JSON__c));
        System.assert(String.isNotBlank(log.After_Snapshot_JSON__c));
        System.assert(log.Field_Decisions_JSON__c.contains(typoEmail));
        System.assert(log.Field_Decisions_JSON__c.contains(fixedEmail));
    }

    @IsTest
    static void correctProposedValue_FieldNotPreviouslyProposed_OldValueTreatedAsBlank() {
        String U = uniq();
        Contact a = createTestContact('Corrige2' + U, 'Diane');
        String newPhone = '5145550000';
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'Alternative_Email_1__c' => 'x' + U + '@example.com' }));

        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(t.Id, 'MobilePhone', newPhone);
        Test.stopTest();

        System.assert(result.success);
        Data_Update_Log__c log = [
            SELECT Field_Decisions_JSON__c FROM Data_Update_Log__c WHERE Request__c = :t.Id AND Action_Type__c = 'CORRECTED' LIMIT 1
        ];
        System.assert(log.Field_Decisions_JSON__c.contains(newPhone));
    }

    @IsTest
    static void correctProposedValue_BlankProposedValuesJson_TreatsOldValueAsBlank() {
        String U = uniq();
        Contact a = createTestContact('Corrige9' + U, 'Simone');
        String newEmail = 'brandnew9' + U + '@example.com';
        Data_Update_Request__c t = createReviewRequest(a.Id, null);

        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(t.Id, 'Alternative_Email_1__c', newEmail);
        Test.stopTest();

        System.assert(result.success);
        Data_Update_Request__c updated = [SELECT Proposed_Values_JSON__c FROM Data_Update_Request__c WHERE Id = :t.Id LIMIT 1];
        System.assert(updated.Proposed_Values_JSON__c.contains(newEmail));
    }

    @IsTest
    static void correctProposedValue_UnchangedValue_NoOpAndNoLog() {
        String U = uniq();
        Contact a = createTestContact('Corrige3' + U, 'Marcel');
        String email = 'same' + U + '@example.com';
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'Alternative_Email_1__c' => email }));

        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(t.Id, 'Alternative_Email_1__c', email);
        Test.stopTest();

        System.assert(result.success);
        List<Data_Update_Log__c> logs = [SELECT Id FROM Data_Update_Log__c WHERE Request__c = :t.Id AND Action_Type__c = 'CORRECTED'];
        System.assert(logs.isEmpty(), 'Saving the same value must not create a CORRECTED log entry');
    }

    @IsTest
    static void correctProposedValue_BlankValue_ReturnsValueRequired() {
        String U = uniq();
        Contact a = createTestContact('Corrige4' + U, 'Helene');
        String originalEmail = 'orig' + U + '@example.com';
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'Alternative_Email_1__c' => originalEmail }));

        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(t.Id, 'Alternative_Email_1__c', '   ');
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('VALUE_REQUIRED', result.errorMessage);
        Data_Update_Request__c unchanged = [SELECT Proposed_Values_JSON__c FROM Data_Update_Request__c WHERE Id = :t.Id LIMIT 1];
        System.assert(unchanged.Proposed_Values_JSON__c.contains(originalEmail));
    }

    @IsTest
    static void correctProposedValue_TerminalRequest_ReturnsAlreadyClosed() {
        String U = uniq();
        Contact a = createTestContact('Corrige5' + U, 'Gilles');
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'Alternative_Email_1__c' => 'x' + U + '@example.com' }));
        update new Data_Update_Request__c(Id = t.Id, Status__c = 'Closed', Closed_Reason__c = 'Applied');

        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(t.Id, 'Alternative_Email_1__c', 'new' + U + '@example.com');
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('TICKET_ALREADY_CLOSED', result.errorMessage);
    }

    @IsTest
    static void correctProposedValue_FieldNotInFormConfig_ReturnsFieldNotEditable() {
        String U = uniq();
        Contact a = createTestContact('Corrige6' + U, 'Pauline');
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'Alternative_Email_1__c' => 'x' + U + '@example.com' }));

        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(t.Id, 'Name', 'Some New Name');
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('FIELD_NOT_EDITABLE', result.errorMessage);
    }

    @IsTest
    static void correctProposedValue_RequestNotFound_ReturnsGenericError() {
        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(UserInfo.getUserId(), 'Alternative_Email_1__c', 'x@example.com');
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('GENERIC_ERROR', result.errorMessage);
    }

    @IsTest
    static void correctProposedValue_ForcedError_ReturnsGenericError() {
        String U = uniq();
        Contact a = createTestContact('Corrige7' + U, 'Andre');
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'Alternative_Email_1__c' => 'x' + U + '@example.com' }));

        DataUpdateReviewController.TEST_FORCE_ERROR = true;
        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(t.Id, 'Alternative_Email_1__c', 'new' + U + '@example.com');
        Test.stopTest();
        DataUpdateReviewController.TEST_FORCE_ERROR = false;

        System.assertEquals(false, result.success);
        System.assertEquals('GENERIC_ERROR', result.errorMessage);
    }

    @IsTest
    static void getAuditLog_IncludesCorrectedEntry() {
        String U = uniq();
        Contact a = createTestContact('Corrige8' + U, 'Francine');
        String typoEmail = 'tpyo8' + U + '@example.com';
        String fixedEmail = 'fixed8' + U + '@example.com';
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'Alternative_Email_1__c' => typoEmail }));
        DataUpdateReviewController.correctProposedValue(t.Id, 'Alternative_Email_1__c', fixedEmail);

        Test.startTest();
        DataUpdateWrapper.AuditLogResult auditResult = DataUpdateReviewController.getAuditLog(t.Id);
        Test.stopTest();

        System.assert(auditResult.success);
        DataUpdateWrapper.AuditLogEntry correctedEntry = null;
        for (DataUpdateWrapper.AuditLogEntry e : auditResult.entries) {
            if (e.actionType == 'CORRECTED') correctedEntry = e;
        }
        System.assertNotEquals(null, correctedEntry, 'History must include the CORRECTED entry');
        System.assertEquals(1, correctedEntry.fieldChanges.size());
        System.assertEquals('Alternative_Email_1__c', correctedEntry.fieldChanges[0].fieldApiName);
        System.assertEquals(typoEmail, correctedEntry.fieldChanges[0].beforeValue);
        System.assertEquals(fixedEmail, correctedEntry.fieldChanges[0].afterValue);
        System.assertEquals(false, correctedEntry.fieldChanges[0].canRollback, 'A CORRECTED entry never touched the real record, so it cannot be rolled back');
    }

    // ─── Bandeja de entrada ─────────────────────────────────────────────────

    @IsTest
    static void getRequests_OpenFilter_ExcludesClosedRequests() {
        String U = uniq();
        Contact a = createTestContact('Bandeja' + U, 'Test');
        Data_Update_Request__c openRequest = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"x@example.com"}');
        Data_Update_Request__c closedRequest = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"y@example.com"}');
        update new Data_Update_Request__c(Id = closedRequest.Id, Status__c = 'Closed', Closed_Reason__c = 'Applied');

        Test.startTest();
        DataUpdateWrapper.RequestListResult result = DataUpdateReviewController.getRequests('Open', 'All', '', 50, 0);
        Test.stopTest();

        System.assert(result.success);
        Set<String> ids = new Set<String>();
        for (DataUpdateWrapper.RequestSummary ts : result.requests) ids.add(ts.id);
        System.assert(ids.contains(openRequest.Id), 'Open request must appear in the Open filter');
        System.assert(!ids.contains(closedRequest.Id), 'Closed request must not appear in the Open filter');
    }

    @IsTest
    static void getRequests_SearchTermFiltersBySubject() {
        String U = uniq();
        Contact a = createTestContact('BusquedaTest' + U, 'Search');
        Data_Update_Request__c t = new Data_Update_Request__c(
            Target_Object_API_Name__c = 'Contact',
            Target_Record_Id__c = a.Id,
            Update_Form_DeveloperName__c = FORM_NAME,
            Status__c = 'New',
            Subject__c = 'UniqueSubjectMarker' + U,
            Proposed_Values_JSON__c = '{"Alternative_Email_1__c":"x@example.com"}'
        );
        insert t;

        Test.startTest();
        DataUpdateWrapper.RequestListResult result = DataUpdateReviewController.getRequests('All', 'All', 'UniqueSubjectMarker' + U, 50, 0);
        Test.stopTest();

        System.assert(result.success);
        System.assertEquals(1, result.requests.size());
        System.assertEquals(t.Id, result.requests[0].id);
        System.assertEquals(1, result.totalCount);
    }

    @IsTest
    static void getRequestCount_MatchesFilterCriteria() {
        String U = uniq();
        Contact a = createTestContact('Conteo' + U, 'Test');
        createReviewRequest(a.Id, '{"Alternative_Email_1__c":"x@example.com"}');

        Test.startTest();
        Integer count = DataUpdateReviewController.getRequestCount('Open', 'All', '');
        Test.stopTest();

        System.assert(count >= 1);
    }

    // ─── search: accents, apostrophe, email, literal wildcards ────────────────

    @IsTest
    static void search_IgnoresAccentsMatchesEmailAndApostrophe() {
        String U = uniq();
        Contact a = createTestContact('Lacharite' + U, 'Test');
        Data_Update_Request__c t1 = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"x@example.com"}');
        Data_Update_Request__c t2 = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"y@example.com"}');
        Data_Update_Request__c t3 = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"z@example.com"}');
        update new List<Data_Update_Request__c>{
            new Data_Update_Request__c(Id = t1.Id, Requested_Name__c = 'Hélène Lacharité' + U),
            new Data_Update_Request__c(Id = t2.Id, Requested_Name__c = 'Paul O\'Neil' + U),
            new Data_Update_Request__c(Id = t3.Id, Requested_Name__c = 'Sans Nom' + U, Requested_Email__c = 'mail' + U + '@example.com')
        };

        Test.startTest();
        DataUpdateWrapper.RequestListResult accent = DataUpdateReviewController.getRequests('All', 'All', 'helene lacharite' + U, 50, 0);
        DataUpdateWrapper.RequestListResult quote = DataUpdateReviewController.getRequests('All', 'All', 'O\'Neil' + U, 50, 0);
        DataUpdateWrapper.RequestListResult email = DataUpdateReviewController.getRequests('All', 'All', 'MAIL' + U + '@', 50, 0);
        DataUpdateWrapper.RequestListResult literal = DataUpdateReviewController.getRequests('All', 'All', '%' + U, 50, 0);
        Integer accentCount = DataUpdateReviewController.getRequestCount('All', 'All', 'LACHARITÉ' + U);
        Test.stopTest();

        System.assert(accent.success);
        System.assertEquals(1, accent.requests.size(), 'Accent-free text finds the accented name');
        System.assertEquals(t1.Id, accent.requests[0].id);
        System.assertEquals(1, accent.totalCount);
        System.assertEquals(1, quote.requests.size(), 'An apostrophe is searched as typed');
        System.assertEquals(t2.Id, quote.requests[0].id);
        System.assertEquals(1, email.requests.size(), 'The requester email is searched too');
        System.assertEquals(t3.Id, email.requests[0].id);
        System.assertEquals(0, literal.requests.size(), 'A typed % is a literal, not a wildcard');
        System.assertEquals(1, accentCount);
    }

    @IsTest
    static void search_PagesOnMatches() {
        String U = uniq();
        Contact a = createTestContact('Pagina' + U, 'Test');
        List<Data_Update_Request__c> updates = new List<Data_Update_Request__c>();
        for (Integer i = 0; i < 3; i++) {
            Data_Update_Request__c t = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"p' + i + '@example.com"}');
            updates.add(new Data_Update_Request__c(Id = t.Id, Requested_Name__c = 'Page Élan' + U));
        }
        update updates;

        Test.startTest();
        DataUpdateWrapper.RequestListResult page2 = DataUpdateReviewController.getRequests('All', 'All', 'elan' + U, 2, 2);
        Test.stopTest();

        System.assertEquals(3, page2.totalCount);
        System.assertEquals(1, page2.requests.size(), 'Second page holds the last match');
    }

    @IsTest
    static void searchHelpers_FoldAndPattern() {
        System.assertEquals('', DataUpdateReviewController.foldAccents(null));
        System.assertEquals('francois cote', DataUpdateReviewController.foldAccents('François Côté'));
        System.assertEquals('%l_v_\\%\\_\\\\%', DataUpdateReviewController.searchLikePattern(' lévy%_\\ '));
        System.assertEquals(false, DataUpdateReviewController.matchesSearch('x', new List<String>{ null, 'abc' }));
    }

    // ─── reopen / hold / resume ─────────────────────────────────────────────

    @IsTest
    static void reopenRequest_ClearsFinalActionAndSetsReopened() {
        String U = uniq();
        Contact a = createTestContact('Reopen' + U, 'Test');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"x@example.com"}');
        update new Data_Update_Request__c(
            Id = t.Id, Status__c = 'Applied', Final_Action__c = 'Applied', Closed_Reason__c = 'Applied'
        );

        update new Contact(Id = a.Id, Data_Update_Locked__c = false);
        User usr = dataUpdateUser();

        Test.startTest();
        System.runAs(usr) {
            DataUpdateReviewController.reopenRequest(t.Id);
        }
        Test.stopTest();

        System.assertEquals(true, [SELECT Data_Update_Locked__c FROM Contact WHERE Id = :a.Id].Data_Update_Locked__c,
            'A reopened ticket puts the record back under lock');
        Data_Update_Request__c reopened = [
            SELECT Status__c, Final_Action__c, Closed_Reason__c, Notes__c
            FROM Data_Update_Request__c WHERE Id = :t.Id LIMIT 1
        ];
        System.assertEquals('Reopened', reopened.Status__c);
        System.assertEquals(null, reopened.Final_Action__c);
        System.assertEquals(null, reopened.Closed_Reason__c);
        System.assert(reopened.Notes__c.contains('[HIST:Reopened'));
    }

    @IsTest
    static void holdRequest_SetsOnHoldWithReasonInNotes() {
        String U = uniq();
        Contact a = createTestContact('Hold' + U, 'Test');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"x@example.com"}');

        Test.startTest();
        DataUpdateReviewController.holdRequest(t.Id, 'Waiting on requester confirmation');
        Test.stopTest();

        Data_Update_Request__c held = [SELECT Status__c, Notes__c FROM Data_Update_Request__c WHERE Id = :t.Id LIMIT 1];
        System.assertEquals('On Hold', held.Status__c);
        System.assert(held.Notes__c.contains('[HIST:On Hold'));
        System.assert(held.Notes__c.contains('Waiting on requester confirmation'));
    }

    @IsTest
    static void resumeRequest_SetsInReview() {
        String U = uniq();
        Contact a = createTestContact('Resume' + U, 'Test');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"x@example.com"}');
        update new Data_Update_Request__c(Id = t.Id, Status__c = 'On Hold');

        Test.startTest();
        DataUpdateReviewController.resumeRequest(t.Id);
        Test.stopTest();

        Data_Update_Request__c resumed = [SELECT Status__c, Notes__c FROM Data_Update_Request__c WHERE Id = :t.Id LIMIT 1];
        System.assertEquals('In Review', resumed.Status__c);
        System.assert(resumed.Notes__c.contains('[HIST:In Review'));
    }

    // ─── Candado (lock) ─────────────────────────────────────────────────────

    @IsTest
    static void getComparisonData_LockedAccount_ReportsIsLockedAndFormName() {
        String U = uniq();
        Contact a = createTestContact('Lavoie' + U, 'Isabelle');
        a.put('Data_Update_Locked__c', true);
        a.put('Data_Update_Locked_Date__c', Datetime.now());
        update a;
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"x@example.com"}');
        User usr = dataUpdateUser();

        DataUpdateWrapper.ComparisonData data;
        Test.startTest();
        System.runAs(usr) {
            data = DataUpdateReviewController.getComparisonData(t.Id);
        }
        Test.stopTest();

        System.assert(data.success);
        System.assertEquals(true, data.isLocked);
        System.assertEquals(FORM_NAME, data.formDeveloperName);
    }

    @IsTest
    static void getComparisonData_ClosedTicketWithOtherOpenTicket_ReportsOtherNumber() {
        String U = uniq();
        Contact a = createTestContact('Gagnon' + U, 'Marc');
        a.put('Data_Update_Locked__c', true);
        a.put('Data_Update_Locked_Date__c', Datetime.now());
        update a;
        Data_Update_Request__c closedT = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"x@example.com"}');
        closedT.Status__c = 'Applied';
        closedT.Closed_Reason__c = 'Applied';
        update closedT;
        Data_Update_Request__c openT = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"y@example.com"}');
        openT.Status__c = 'New';
        update openT;
        String openNumber = [SELECT Name FROM Data_Update_Request__c WHERE Id = :openT.Id].Name;
        User usr = dataUpdateUser();

        DataUpdateWrapper.ComparisonData data;
        Test.startTest();
        System.runAs(usr) {
            data = DataUpdateReviewController.getComparisonData(closedT.Id);
        }
        Test.stopTest();

        System.assert(data.success);
        System.assertEquals(true, data.requestClosed);
        System.assertEquals(openNumber, data.otherOpenRequestNumber);
    }

    @IsTest
    static void unlockRecord_ClearsLockFieldAndDate() {
        String U = uniq();
        Contact a = createTestContact('Desrosiers' + U, 'Alain');
        a.put('Data_Update_Locked__c', true);
        a.put('Data_Update_Locked_Date__c', Datetime.now());
        update a;

        Test.startTest();
        DataUpdateWrapper.UnlockResult result = DataUpdateReviewController.unlockRecord(a.Id, FORM_NAME);
        Test.stopTest();

        System.assert(result.success);
        Contact unlocked = [SELECT Data_Update_Locked__c, Data_Update_Locked_Date__c FROM Contact WHERE Id = :a.Id LIMIT 1];
        System.assertEquals(false, unlocked.Data_Update_Locked__c);
        System.assertEquals(null, unlocked.Data_Update_Locked_Date__c);
    }

    @IsTest
    static void unlockRecord_BlockedWhileLatestRequestStillOpen() {
        String U = uniq();
        Contact a = createTestContact('Charron' + U, 'Melanie');
        a.put('Data_Update_Locked__c', true);
        a.put('Data_Update_Locked_Date__c', Datetime.now());
        update a;
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"x@example.com"}');

        Test.startTest();
        DataUpdateWrapper.UnlockResult result = DataUpdateReviewController.unlockRecord(a.Id, FORM_NAME);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('REQUEST_STILL_OPEN', result.errorMessage);
        System.assertEquals(t.Id, result.openRequestId);
        Contact stillLocked = [SELECT Data_Update_Locked__c FROM Contact WHERE Id = :a.Id LIMIT 1];
        System.assertEquals(true, stillLocked.Data_Update_Locked__c);
    }

    @IsTest
    static void unlockAllRecords_ClearsAllLockedAccountsAndReturnsCount() {
        String U = uniq();
        Contact a1 = createTestContact('Pelletier' + U, 'Robert');
        Contact a2 = createTestContact('Pelletier' + U, 'Nathalie');
        a1.put('Data_Update_Locked__c', true);
        a1.put('Data_Update_Locked_Date__c', Datetime.now());
        a2.put('Data_Update_Locked__c', true);
        a2.put('Data_Update_Locked_Date__c', Datetime.now());
        update new List<Contact>{ a1, a2 };

        Test.startTest();
        DataUpdateWrapper.UnlockAllResult result = DataUpdateReviewController.unlockAllRecords(FORM_NAME);
        Test.stopTest();

        System.assert(result.success);
        System.assert(result.unlockedCount >= 2);
        List<Contact> stillLocked = [SELECT Id FROM Contact WHERE Id IN :new List<Id>{ a1.Id, a2.Id } AND Data_Update_Locked__c = true];
        System.assert(stillLocked.isEmpty(), 'unlockAllRecords must clear the lock on every currently-locked account');
    }

    @IsTest
    static void unlockAllRecords_SkipsAccountsWithStillOpenRequest() {
        String U = uniq();
        Contact blocked = createTestContact('Fontaine' + U, 'Yves');
        blocked.put('Data_Update_Locked__c', true);
        blocked.put('Data_Update_Locked_Date__c', Datetime.now());
        update blocked;
        createReviewRequest(blocked.Id, '{"Alternative_Email_1__c":"x@example.com"}');

        Contact unblocked = createTestContact('Fontaine' + U, 'Sylvie');
        unblocked.put('Data_Update_Locked__c', true);
        unblocked.put('Data_Update_Locked_Date__c', Datetime.now());
        update unblocked;

        Test.startTest();
        DataUpdateWrapper.UnlockAllResult result = DataUpdateReviewController.unlockAllRecords(FORM_NAME);
        Test.stopTest();

        System.assert(result.success);
        System.assert(result.skippedCount >= 1);
        Contact stillBlocked = [SELECT Data_Update_Locked__c FROM Contact WHERE Id = :blocked.Id LIMIT 1];
        System.assertEquals(true, stillBlocked.Data_Update_Locked__c);
        Contact nowUnlocked = [SELECT Data_Update_Locked__c FROM Contact WHERE Id = :unblocked.Id LIMIT 1];
        System.assertEquals(false, nowUnlocked.Data_Update_Locked__c);
    }

    @IsTest
    static void unlock_ScopedToFormAndBlockedByOtherFormsOpenTicket() {
        String U = uniq();
        // Église locked by its own open ticket: the Account form must neither see nor unlock it.
        Account e = createEglise('Eglise Scope ' + U);
        insert new Data_Update_Request__c(
            Target_Object_API_Name__c = 'Account', Target_Record_Id__c = e.Id,
            Update_Form_DeveloperName__c = 'SEMBEQ_Eglise_Update', Status__c = 'New', Subject__c = 'Eglise open ' + U
        );
        // Person account locked by an open ticket from another form sharing the lock field.
        Contact p = createTestContact('Partage' + U, 'Luc');
        p.put('Data_Update_Locked__c', true);
        update p;
        Data_Update_Request__c otherFormTicket = new Data_Update_Request__c(
            Target_Object_API_Name__c = 'Contact', Target_Record_Id__c = p.Id,
            Update_Form_DeveloperName__c = 'Some_Other_Form', Status__c = 'New', Subject__c = 'Other form ' + U
        );
        insert otherFormTicket;

        Test.startTest();
        DataUpdateWrapper.UnlockAllResult all = DataUpdateReviewController.unlockAllRecords(FORM_NAME);
        DataUpdateWrapper.UnlockResult outOfScope = DataUpdateReviewController.unlockRecord(e.Id, FORM_NAME);
        DataUpdateWrapper.UnlockResult crossForm = DataUpdateReviewController.unlockRecord(p.Id, FORM_NAME);
        DataUpdateWrapper.LockedRecordListResult listed = DataUpdateReviewController.getLockedRecords(FORM_NAME, 50, 0, 'Partage' + U);
        Test.stopTest();

        System.assert(all.success);
        System.assertEquals(true, [SELECT Data_Update_Locked__c FROM Contact WHERE Id = :p.Id].Data_Update_Locked__c,
            'An open ticket from any form keeps the record locked');
        System.assertEquals('OUT_OF_SCOPE', outOfScope.errorMessage);
        System.assertEquals('REQUEST_STILL_OPEN', crossForm.errorMessage);
        System.assertEquals(otherFormTicket.Id, crossForm.openRequestId);
        System.assertEquals(1, listed.records.size());
        System.assertEquals(true, listed.records[0].isBlockedByOpenRequest);
        System.assertEquals(String.valueOf(otherFormTicket.Id), listed.records[0].latestRequestId);
    }

    @IsTest
    static void getLockedRecords_ReturnsOnlyLockedAccountsWithLatestStatus() {
        String U = uniq();
        Contact locked = createTestContact('Bergeron' + U, 'Chantal');
        locked.put('Data_Update_Locked__c', true);
        locked.put('Data_Update_Locked_Date__c', Datetime.now());
        update locked;
        createReviewRequest(locked.Id, '{"Alternative_Email_1__c":"x@example.com"}');

        Contact notLocked = createTestContact('Gauthier' + U, 'Serge');

        Test.startTest();
        DataUpdateWrapper.LockedRecordListResult result = DataUpdateReviewController.getLockedRecords(FORM_NAME, 25, 0, null);
        Test.stopTest();

        System.assert(result.success);
        Set<Id> returnedIds = new Set<Id>();
        for (DataUpdateWrapper.LockedRecordSummary s : result.records) returnedIds.add(Id.valueOf(s.recordId));
        System.assert(returnedIds.contains(locked.Id), 'Locked account must appear in the locked list');
        System.assert(!returnedIds.contains(notLocked.Id), 'Non-locked account must not appear in the locked list');
    }

    @IsTest
    static void getLockedRecords_SearchTermFiltersByName() {
        String U = uniq();
        Contact a = createTestContact('UniqueLockMarker' + U, 'Test');
        a.put('Data_Update_Locked__c', true);
        a.put('Data_Update_Locked_Date__c', Datetime.now());
        update a;
        a = [SELECT Id, Name FROM Contact WHERE Id = :a.Id LIMIT 1];

        Test.startTest();
        DataUpdateWrapper.LockedRecordListResult result = DataUpdateReviewController.getLockedRecords(FORM_NAME, 25, 0, a.Name);
        Test.stopTest();

        System.assert(result.success);
        System.assertEquals(1, result.records.size());
        System.assertEquals(a.Id, Id.valueOf(result.records[0].recordId));
    }

    // ─── Helpers (permission-set user, Eglise, fake forms) ──────────────────

    // Production admins don't get FLS on the lock/Eglise fields from their profile — only
    // from the Data Update Center permission set — so FLS-sensitive paths run as a user
    // holding that permission set.
    private static User dataUpdateUser() {
        User usr;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            String U = uniq();
            usr = new User(
                ProfileId = UserInfo.getProfileId(),
                Username = 'duc' + U + '@example.com.test',
                Email = 'duc' + U + '@example.com',
                LastName = 'DataUpdate', Alias = 'duct',
                TimeZoneSidKey = 'America/Toronto', LocaleSidKey = 'fr_CA',
                EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
            );
            insert usr;
            insert new PermissionSetAssignment(
                AssigneeId = usr.Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Data_Update_Center_Access' LIMIT 1].Id
            );
        }
        return usr;
    }

    private static Account createEglise(String name) {
        Account a = new Account(
            Name = name,
            RecordTypeId = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND DeveloperName = 'Eglise' LIMIT 1].Id
        );
        return (Account) insertResilient(a);
    }

    private static Data_Update_Request__c createRequestFor(Id recordId, String formName, String proposedJson) {
        Data_Update_Request__c t = new Data_Update_Request__c(
            Target_Object_API_Name__c = recordId.getSObjectType().getDescribe().getName(),
            Target_Record_Id__c = recordId,
            Update_Form_DeveloperName__c = formName,
            Status__c = 'New',
            Subject__c = 'Review request ' + uniq(),
            Proposed_Values_JSON__c = proposedJson
        );
        insert t;
        return t;
    }

    // In-memory form without a lock field (the org only ships forms that have one).
    private static void useNoLockFakeForm() {
        DataUpdateFormConfigService.testFormMdt = (Data_Update_Form__mdt) JSON.deserialize(
            '{"DeveloperName":"Fake_NoLock_Form","MasterLabel":"Fake","Target_Object_API_Name__c":"Contact",'
            + '"Identity_Field_1_API_Name__c":"Name","Identity_Field_1_Comparison__c":"Exact",'
            + '"Subject_Template__c":"{RecordName}","Is_Active__c":true}',
            Data_Update_Form__mdt.class);
        DataUpdateFormConfigService.testFieldMdts = (List<Data_Update_Form_Field__mdt>) JSON.deserialize(
            '[{"Field_API_Name__c":"Phone","Label_FR__c":"T","Label_EN__c":"T","Display_Order__c":1,'
            + '"Input_Type__c":"Phone","History_Mode__c":"Replace","Is_Active__c":true}]',
            List<Data_Update_Form_Field__mdt>.class);
    }

    // Same, but with a lock field and no lock date field.
    private static void useLockNoDateFakeForm() {
        useNoLockFakeForm();
        DataUpdateFormConfigService.testFormMdt = (Data_Update_Form__mdt) JSON.deserialize(
            '{"DeveloperName":"Fake_Lock_Form","MasterLabel":"Fake","Target_Object_API_Name__c":"Contact",'
            + '"Identity_Field_1_API_Name__c":"Name","Identity_Field_1_Comparison__c":"Exact",'
            + '"Subject_Template__c":"{RecordName}","Is_Active__c":true,"Lock_Field_API_Name__c":"Data_Update_Locked__c"}',
            Data_Update_Form__mdt.class);
    }

    @IsTest
    static void getRequests_FormWithoutLockField_NeverShowsLocked() {
        String U = uniq();
        Contact c = createTestContact('SansVerrou' + U, 'Paul');
        Data_Update_Request__c t = createRequestFor(c.Id, 'Fake_NoLock_Form', '{"Phone":"5145550000"}');
        useNoLockFakeForm();
        DataUpdateWrapper.RequestListResult result = DataUpdateReviewController.getRequests('All', 'All', '', 50, 0);
        System.assert(result.success, result.errorMessage);
    }

    @IsTest
    static void getLockedRecords_FormWithBaseFilter_KeepsOnlyMatchingRecords() {
        String U = uniq();
        Contact inScope = createTestContact('Filtre' + U, 'Ana');
        Contact outScope = createTestContact('Autre' + U, 'Ana');
        for (Contact c : new List<Contact>{ inScope, outScope }) {
            c.put('Data_Update_Locked__c', true);
            c.put('Data_Update_Locked_Date__c', Datetime.now());
        }
        update new List<Contact>{ inScope, outScope };
        useNoLockFakeForm();
        DataUpdateFormConfigService.testFormMdt = (Data_Update_Form__mdt) JSON.deserialize(
            '{"DeveloperName":"Fake_Filter_Form","MasterLabel":"Fake","Target_Object_API_Name__c":"Contact",'
            + '"Identity_Field_1_API_Name__c":"Name","Identity_Field_1_Comparison__c":"Exact",'
            + '"Subject_Template__c":"{RecordName}","Is_Active__c":true,"Lock_Field_API_Name__c":"Data_Update_Locked__c",'
            + '"Lock_Date_Field_API_Name__c":"Data_Update_Locked_Date__c",'
            + '"Target_Base_Filter_Field__c":"LastName","Target_Base_Filter_Value__c":"Filtre' + U + '"}',
            Data_Update_Form__mdt.class);

        DataUpdateWrapper.LockedRecordListResult result = DataUpdateReviewController.getLockedRecords('Fake_Filter_Form', 25, 0, null);

        System.assert(result.success, result.errorMessage);
        Set<Id> ids = new Set<Id>();
        for (DataUpdateWrapper.LockedRecordSummary s : result.records) ids.add(Id.valueOf(s.recordId));
        System.assert(ids.contains(inScope.Id), 'Record matching the base filter must be listed');
        System.assert(!ids.contains(outScope.Id), 'Record outside the base filter must not be listed');
    }

    private static Id findLogId(Id requestId, String actionType) {
        return [SELECT Id FROM Data_Update_Log__c WHERE Request__c = :requestId AND Action_Type__c = :actionType
                ORDER BY CreatedDate DESC LIMIT 1].Id;
    }

    // ─── Rollback ───────────────────────────────────────────────────────────

    @IsTest
    static void rollbackChange_FullCycle_RestoresValueAndReopens() {
        String U = uniq();
        Contact a = createTestContact('Retour' + U, 'Anne');
        String originalEmail = getEmail(queryContactEmailOnly(a.Id));
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{
            'Alternative_Email_1__c' => 'rolled' + U + '@example.com'
        }));
        System.assert(DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Alternative_Email_1__c' }).success);
        Id applyLogId = findLogId(t.Id, 'APPLY_COMPLETED');
        // Same-transaction logs share a CreatedDate; push the apply back so the rollback log
        // deterministically sorts after it in getFieldTouchMap().
        Test.setCreatedDate(applyLogId, DateTime.now().addMinutes(-5));

        Test.startTest();
        DataUpdateWrapper.AuditLogResult audit = DataUpdateReviewController.getAuditLog(t.Id);
        DataUpdateWrapper.ApplyResult wrongField = DataUpdateReviewController.rollbackChange(applyLogId, 'MobilePhone');
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.rollbackChange(applyLogId, 'Alternative_Email_1__c');
        DataUpdateWrapper.ApplyResult again = DataUpdateReviewController.rollbackChange(applyLogId, 'Alternative_Email_1__c');
        DataUpdateWrapper.AuditLogResult auditAfter = DataUpdateReviewController.getAuditLog(t.Id);
        Test.stopTest();

        System.assert(audit.success);
        System.assert(audit.entries[0].fieldChanges[0].canRollback, 'The latest apply must be rollback-eligible');
        System.assertEquals('ROLLBACK_INVALID_STATE', wrongField.errorMessage);
        System.assert(result.success, 'Rollback should succeed: ' + result.errorMessage);
        System.assertEquals(1, result.updatedFieldCount);
        System.assertEquals(false, result.historyCleanupSkipped == true);
        System.assertEquals('ROLLBACK_INVALID_STATE', again.errorMessage, 'A field already rolled back cannot be rolled back twice');
        System.assert(auditAfter.success);

        System.assertEquals(originalEmail, getEmail(queryContactEmailOnly(a.Id)));
        Data_Update_Request__c reopened = [SELECT Status__c, Notes__c FROM Data_Update_Request__c WHERE Id = :t.Id];
        System.assertEquals('Reopened', reopened.Status__c);
        System.assert(reopened.Notes__c.contains('Rollback'));

        DataUpdateWrapper.ComparisonData cmp = DataUpdateReviewController.getComparisonData(t.Id);
        System.assert(cmp.fields[0].previouslyRolledBack);
    }

    // ─── EDA preferred email ────────────────────────────────────────────────

    private static Contact createPreferredEmailContact(String lastName, String email) {
        Contact c = createTestContact(lastName, 'Eda');
        c.put('hed__AlternateEmail__c', email);
        c.put('hed__Preferred_Email__c', 'Alternate Email');
        c.put('Email', email);
        update c;
        return c;
    }

    private static Contact queryEmails(Id recId) {
        return (Contact) Database.query('SELECT Id, Email, hed__AlternateEmail__c, Alternative_Email_1__c FROM Contact WHERE Id = :recId LIMIT 1');
    }

    @IsTest
    static void applyEmail_PreferredAlternate_WritesPreferredFieldAndRollsBack() {
        String U = uniq();
        String oldEmail = 'old' + U + '@example.com';
        String newEmail = 'new' + U + '@example.com';
        Contact c = createPreferredEmailContact('Courriel' + U, oldEmail);
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{ 'Email' => newEmail }));
        System.assertEquals('hed__AlternateEmail__c', DataUpdateReviewController.getComparisonData(t.Id).fields[0].savedInFieldApiName);

        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Email' });
        System.assert(applied.success, applied.errorMessage);
        Contact after = queryEmails(c.Id);
        System.assertEquals(newEmail, after.get('hed__AlternateEmail__c'), 'The new email goes to the preferred email field');
        System.assertEquals(newEmail, after.Email, 'EDA mirrors the preferred field into Email');
        Boolean sourceShown = false;
        for (DataUpdateWrapper.AuditLogEntry e : DataUpdateReviewController.getAuditLog(t.Id).entries) {
            for (DataUpdateWrapper.AuditFieldChange ch : e.fieldChanges) {
                if (ch.fieldApiName == 'hed__AlternateEmail__c') sourceShown = ch.sourceLabelEn != null;
            }
        }
        System.assert(sourceShown, 'Historique tells the value came from the Email question');

        Id applyLogId = findLogId(t.Id, 'APPLY_COMPLETED');
        Test.setCreatedDate(applyLogId, DateTime.now().addMinutes(-5));
        Test.startTest();
        DataUpdateWrapper.ApplyResult rolled = DataUpdateReviewController.rollbackChange(applyLogId, 'hed__AlternateEmail__c');
        Test.stopTest();
        System.assert(rolled.success, rolled.errorMessage);
        Contact restored = queryEmails(c.Id);
        System.assertEquals(oldEmail, restored.get('hed__AlternateEmail__c'));
        System.assertEquals(oldEmail, restored.Email);
    }

    private static Set<String> notAppliedReasons(Id requestId) {
        Set<String> reasons = new Set<String>();
        for (DataUpdateWrapper.AuditLogEntry e : DataUpdateReviewController.getAuditLog(requestId).entries) {
            if (e.notApplied == null) continue;
            for (DataUpdateWrapper.AuditNotApplied n : e.notApplied) reasons.add(n.reason);
        }
        return reasons;
    }

    @IsTest
    static void applyEmail_EmailAndPreferredBothAnswered_EmailWinsOtherNoted() {
        String U = uniq();
        Contact c = createPreferredEmailContact('Double' + U, 'old' + U + '@example.com');
        c.put('hed__Preferred_Email__c', 'Alternative Email 1');
        update c;
        String emailAnswer = 'main' + U + '@example.com';
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{
            'Email' => emailAnswer, 'Alternative_Email_1__c' => 'alt1' + U + '@example.com'
        }));

        DataUpdateWrapper.ComparisonData cmp = DataUpdateReviewController.getComparisonData(t.Id);
        for (DataUpdateWrapper.ComparisonField cf : cmp.fields) {
            System.assertEquals(true, cf.emailConflict, 'Both rows warn: only one main email ' + cf.fieldApiName);
        }

        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdates(t.Id,
            new List<String>{ 'Email', 'Alternative_Email_1__c' });

        System.assert(applied.success, applied.errorMessage);
        Contact after = queryEmails(c.Id);
        System.assertEquals(emailAnswer, after.get('Alternative_Email_1__c'), 'Email\'s answer takes the preferred field');
        System.assertEquals(emailAnswer, after.Email, 'and stays the main email');
        System.assert(notAppliedReasons(t.Id).contains('EMAIL_PREFERRED_CONFLICT'), 'The other answer is listed as not applied');
    }

    @IsTest
    static void applyEmail_SameAnswerAsPreferredField_AppliesOnce() {
        String U = uniq();
        Contact c = createPreferredEmailContact('Same' + U, 'old' + U + '@example.com');
        String answer = 'same' + U + '@example.com';
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{
            'Email' => answer, 'hed__AlternateEmail__c' => answer.toUpperCase()
        }));

        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdates(t.Id,
            new List<String>{ 'Email', 'hed__AlternateEmail__c' });

        System.assert(applied.success, applied.errorMessage);
        System.assertEquals(answer, queryEmails(c.Id).Email.toLowerCase());
    }

    @IsTest
    static void applyEmail_Blank_NeverClearsMainEmail() {
        String U = uniq();
        String oldEmail = 'keep' + U + '@example.com';
        Contact c = createPreferredEmailContact('Blank' + U, oldEmail);
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{ 'Email' => '' }));
        for (DataUpdateWrapper.ComparisonField cf : DataUpdateReviewController.getComparisonData(t.Id).unchangedFields) {
            System.assertEquals(null, cf.savedInFieldApiName, 'Nothing to explain for a blank Email');
        }

        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Email' });

        System.assert(applied.success, applied.errorMessage);
        System.assertEquals(oldEmail, queryEmails(c.Id).Email);
        System.assert(notAppliedReasons(t.Id).contains('EMAIL_EMPTY'));
    }

    @IsTest
    static void applyEmail_ContactWithoutEmail_SetsPreferenceAndRollbackClearsBoth() {
        String U = uniq();
        Contact c = (Contact) insertResilient(new Contact(LastName = 'Vide' + U, FirstName = 'Eda'));
        String newEmail = 'first' + U + '@example.com';
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{ 'Email' => newEmail }));

        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Email' });
        System.assert(applied.success, applied.errorMessage);
        Contact after = (Contact) Database.query('SELECT Email, hed__AlternateEmail__c, hed__Preferred_Email__c FROM Contact WHERE Id = \'' + c.Id + '\'');
        System.assertEquals(newEmail, after.get('hed__AlternateEmail__c'));
        System.assertEquals('Alternate Email', after.get('hed__Preferred_Email__c'));
        System.assertEquals(newEmail, after.Email);

        Id applyLogId = findLogId(t.Id, 'APPLY_COMPLETED');
        Test.setCreatedDate(applyLogId, DateTime.now().addMinutes(-5));
        Test.startTest();
        DataUpdateWrapper.ApplyResult rolled = DataUpdateReviewController.rollbackChange(applyLogId, 'hed__AlternateEmail__c');
        Test.stopTest();
        System.assert(rolled.success, rolled.errorMessage);
        Contact restored = (Contact) Database.query('SELECT Email, hed__AlternateEmail__c, hed__Preferred_Email__c FROM Contact WHERE Id = \'' + c.Id + '\'');
        System.assertEquals(null, restored.get('hed__AlternateEmail__c'));
        System.assertEquals(null, restored.get('hed__Preferred_Email__c'));
        System.assertEquals(null, restored.Email, 'Nothing left for EDA to copy back');
    }

    @IsTest
    static void applyEmail_StaffPicksEmailAsPlace_GoesToPreferredField() {
        String U = uniq();
        Contact c = createPreferredEmailContact('Place' + U, 'old' + U + '@example.com');
        String answer = 'picked' + U + '@example.com';
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{ 'Alternative_Email_1__c' => answer }));

        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applyCore(t.Id,
            new List<String>{ 'Alternative_Email_1__c' }, null, new Map<String, String>{ 'Alternative_Email_1__c' => 'Email' }, null);

        System.assert(applied.success, applied.errorMessage);
        Contact after = queryEmails(c.Id);
        System.assertEquals(answer, after.get('hed__AlternateEmail__c'));
        System.assertEquals(answer, after.Email);
    }

    @IsTest
    static void applyEmailField_ContactWithoutEmail_PointsPreferenceAtIt() {
        String U = uniq();
        Contact c = (Contact) insertResilient(new Contact(LastName = 'Seul' + U, FirstName = 'Eda'));
        String answer = 'alt1' + U + '@example.com';
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{ 'Alternative_Email_1__c' => answer }));

        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Alternative_Email_1__c' });

        System.assert(applied.success, applied.errorMessage);
        Contact after = (Contact) Database.query('SELECT Email, hed__Preferred_Email__c FROM Contact WHERE Id = \'' + c.Id + '\'');
        System.assertEquals('Alternative Email 1', after.get('hed__Preferred_Email__c'));
        System.assertEquals(answer, after.Email);
    }

    @IsTest
    static void rollbackEmail_OtherEmailStillFilled_PreferenceMovesToIt() {
        String U = uniq();
        Contact c = (Contact) insertResilient(new Contact(LastName = 'Deux' + U, FirstName = 'Eda'));
        String other = 'other' + U + '@example.com';
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{
            'Email' => 'main' + U + '@example.com', 'Alternative_Email_1__c' => other
        }));
        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdates(t.Id,
            new List<String>{ 'Email', 'Alternative_Email_1__c' });
        System.assert(applied.success, applied.errorMessage);

        Id applyLogId = findLogId(t.Id, 'APPLY_COMPLETED');
        Test.setCreatedDate(applyLogId, DateTime.now().addMinutes(-5));
        Test.startTest();
        DataUpdateWrapper.ApplyResult rolled = DataUpdateReviewController.rollbackChange(applyLogId, 'hed__AlternateEmail__c');
        Test.stopTest();

        System.assert(rolled.success, rolled.errorMessage);
        Contact after = (Contact) Database.query('SELECT Email, hed__AlternateEmail__c, hed__Preferred_Email__c FROM Contact WHERE Id = \'' + c.Id + '\'');
        System.assertEquals(null, after.get('hed__AlternateEmail__c'));
        System.assertEquals('Alternative Email 1', after.get('hed__Preferred_Email__c'), 'EDA refuses a blank preference while an email is left');
        System.assertEquals(other, after.Email);
    }

    @IsTest
    static void applyEmail_UnknownPreference_ToldBeforeAndOnApply() {
        String U = uniq();
        Contact c = createPreferredEmailContact('Inconnu' + U, 'old' + U + '@example.com');
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{ 'Email' => 'new' + U + '@example.com' }));
        DataUpdateReviewController.testPreference = 'Pigeon Email';

        System.assertEquals('Pigeon Email', DataUpdateReviewController.getComparisonData(t.Id).fields[0].emailPreferenceUnknown);
        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Email' });

        System.assertEquals(false, applied.success);
        System.assertEquals('EMAIL_PREFERENCE_UNKNOWN', applied.errorMessage);
        System.assertEquals('New', [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c, 'Not an error: the ticket is unchanged');
    }

    @IsTest
    static void emailTarget_ResolvesOnlyWhenItApplies() {
        Map<String, Schema.SObjectField> contactFields = Contact.SObjectType.getDescribe().fields.getMap();
        String U = uniq();
        Contact c = createPreferredEmailContact('Pref' + U, 'p' + U + '@example.com');
        Contact none = (Contact) insertResilient(new Contact(LastName = 'None' + U));

        System.assertEquals(false, DataUpdateReviewController.isPreferredEmailEnforcementDisabled(), 'No org default in tests: enforcement on');
        System.assertEquals('hed__AlternateEmail__c', DataUpdateReviewController.emailSavedIn('Contact', c.Id, contactFields));
        System.assertEquals('Alternate Email', DataUpdateReviewController.emailTarget('Contact', none.Id, contactFields).setPreference);
        System.assertEquals(null, DataUpdateReviewController.emailSavedIn('Account', c.Id,
            Account.SObjectType.getDescribe().fields.getMap()));
        DataUpdateReviewController.testEnforcementDisabled = true;
        System.assertEquals(null, DataUpdateReviewController.emailSavedIn('Contact', c.Id, contactFields));

        System.assertEquals(null, DataUpdateReviewController.emailFieldForPreference(null, contactFields));
        System.assertEquals('hed__WorkEmail__c', DataUpdateReviewController.emailFieldForPreference('Work Email', contactFields));
        System.assertEquals('Alternative_Email_1__c', DataUpdateReviewController.emailFieldForPreference('Alternative Email 1', contactFields));
        System.assertEquals(null, DataUpdateReviewController.emailFieldForPreference('Nope', contactFields));
        System.assertEquals('Work Email', DataUpdateReviewController.preferenceForField('hed__WorkEmail__c', contactFields));
        System.assertEquals(null, DataUpdateReviewController.preferenceForField('Email', contactFields));
        System.assertEquals(null, DataUpdateReviewController.preferenceForField('Email',
            Account.SObjectType.getDescribe().fields.getMap()));
    }

    @IsTest
    static void rollbackChanges_AllOrNothing() {
        String U = uniq();
        Contact a = createTestContact('Lot' + U, 'Luc');
        String originalEmail = getEmail(queryContactEmailOnly(a.Id));
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{
            'Alternative_Email_1__c' => 'batch' + U + '@example.com'
        }));
        System.assert(DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Alternative_Email_1__c' }).success);
        Id applyLogId = findLogId(t.Id, 'APPLY_COMPLETED');
        Test.setCreatedDate(applyLogId, DateTime.now().addMinutes(-5));
        String appliedStatus = [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c;

        Test.startTest();
        DataUpdateWrapper.ApplyResult empty = DataUpdateReviewController.rollbackChanges(applyLogId, new List<String>());
        // Second field is invalid → the first one must be undone too.
        DataUpdateWrapper.ApplyResult partial = DataUpdateReviewController.rollbackChanges(
            applyLogId, new List<String>{ 'Alternative_Email_1__c', 'MobilePhone' });
        String emailAfterPartial = getEmail(queryContactEmailOnly(a.Id));
        String statusAfterPartial = [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c;
        DataUpdateWrapper.ApplyResult ok = DataUpdateReviewController.rollbackChanges(
            applyLogId, new List<String>{ 'Alternative_Email_1__c' });
        Test.stopTest();

        System.assertEquals('ROLLBACK_INVALID_STATE', empty.errorMessage);
        System.assertEquals(false, partial.success);
        System.assertEquals('batch' + U + '@example.com', emailAfterPartial, 'Failed batch must restore nothing');
        System.assertEquals(appliedStatus, statusAfterPartial, 'Failed batch must not reopen the request');
        System.assert(ok.success, 'Batch rollback should succeed: ' + ok.errorMessage);
        System.assertEquals(1, ok.updatedFieldCount);
        System.assertEquals(originalEmail, getEmail(queryContactEmailOnly(a.Id)));

        DataUpdateWrapper.ComparisonData cmp = DataUpdateReviewController.getComparisonData(t.Id);
        System.assertEquals('Reopened', cmp.status);
    }

    @IsTest
    static void rollbackChange_RelocksRecord_AndFailureRollsEverythingBack() {
        String U = uniq();
        Contact a = createTestContact('Reverrou' + U, 'Anne');
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{
            'Alternative_Email_1__c' => 'relock' + U + '@example.com'
        }));
        System.assert(DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Alternative_Email_1__c' }).success);
        Id applyLogId = findLogId(t.Id, 'APPLY_COMPLETED');
        Test.setCreatedDate(applyLogId, DateTime.now().addMinutes(-5));
        update new Contact(Id = a.Id, Data_Update_Locked__c = false);
        User usr = dataUpdateUser();

        DataUpdateWrapper.ApplyResult failed;
        Contact afterFailure;
        String statusAfterFailure;
        DataUpdateWrapper.ApplyResult ok;
        Test.startTest();
        System.runAs(usr) {
            DataUpdateReviewController.TEST_FORCE_ROLLBACK_DML_ERROR = true;
            failed = DataUpdateReviewController.rollbackChange(applyLogId, 'Alternative_Email_1__c');
            afterFailure = (Contact) Database.query('SELECT Alternative_Email_1__c, Data_Update_Locked__c FROM Contact WHERE Id = \'' + a.Id + '\'');
            statusAfterFailure = [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c;
            DataUpdateReviewController.TEST_FORCE_ROLLBACK_DML_ERROR = false;
            ok = DataUpdateReviewController.rollbackChange(applyLogId, 'Alternative_Email_1__c');
        }
        Test.stopTest();

        System.assertEquals('GENERIC_ERROR', failed.errorMessage);
        System.assertEquals('relock' + U + '@example.com', afterFailure.get('Alternative_Email_1__c'), 'Failed rollback must leave the value untouched');
        System.assertEquals(false, afterFailure.get('Data_Update_Locked__c'));
        System.assertEquals('Applied', statusAfterFailure);

        System.assert(ok.success, 'Rollback should succeed: ' + ok.errorMessage);
        Contact relocked = [SELECT Data_Update_Locked__c, Data_Update_Locked_Date__c FROM Contact WHERE Id = :a.Id];
        System.assertEquals(true, relocked.Data_Update_Locked__c, 'Reopened ticket puts the record back under lock');
        System.assertNotEquals(null, relocked.Data_Update_Locked_Date__c);
    }

    @IsTest
    static void reopenRequest_DeletedForm_StillRelocksViaSharedLockField() {
        String U = uniq();
        Contact a = createTestContact('Orphelin' + U, 'Test');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"x@example.com"}');
        update new Data_Update_Request__c(Id = t.Id, Status__c = 'Applied', Closed_Reason__c = 'Applied',
            Update_Form_DeveloperName__c = 'Form_That_No_Longer_Exists_' + U);
        User usr = dataUpdateUser();

        Test.startTest();
        System.runAs(usr) {
            DataUpdateReviewController.reopenRequest(t.Id);
        }
        Test.stopTest();

        Contact relocked = [SELECT Data_Update_Locked__c, Data_Update_Locked_Date__c FROM Contact WHERE Id = :a.Id];
        System.assertEquals(true, relocked.Data_Update_Locked__c);
        System.assertNotEquals(null, relocked.Data_Update_Locked_Date__c);
    }

    @IsTest
    static void applySelectedUpdates_FailureAfterUpdate_LeavesRecordAndTicketUntouched() {
        String U = uniq();
        Contact a = createTestContact('Atomique' + U, 'Test');
        String originalEmail = 'orig' + U + '@example.com';
        update new Contact(Id = a.Id, Alternative_Email_1__c = originalEmail);
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{
            'Alternative_Email_1__c' => 'new' + U + '@example.com'
        }));

        Test.startTest();
        DataUpdateReviewController.TEST_FORCE_APPLY_DML_ERROR = true;
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Alternative_Email_1__c' });
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('GENERIC_ERROR', result.errorMessage);
        System.assertEquals(originalEmail, [SELECT Alternative_Email_1__c FROM Contact WHERE Id = :a.Id].Alternative_Email_1__c,
            'The record update must be rolled back with the rest');
        System.assertNotEquals('Applied', [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c);
    }

    @IsTest
    static void rollbackChange_UnknownObjectOrReadOnlyField_ReturnsGenericError() {
        String U = uniq();
        Contact a = createTestContact('Lecture' + U, 'Seule');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"x@example.com"}');
        Data_Update_Log__c badObject = new Data_Update_Log__c(
            Request__c = t.Id, Action_Type__c = 'APPLY_COMPLETED',
            Target_Object_API_Name__c = 'Nope_Not_An_Object__c', Target_Record_Id__c = String.valueOf(a.Id),
            Before_Snapshot_JSON__c = '{}', Field_Decisions_JSON__c = '{"Alternative_Email_1__c":{"selectedValue":"x"}}'
        );
        insert badObject;

        Data_Update_Request__c t2 = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"x@example.com"}');
        Data_Update_Log__c readOnly = new Data_Update_Log__c(
            Request__c = t2.Id, Action_Type__c = 'APPLY_COMPLETED',
            Target_Object_API_Name__c = 'Contact', Target_Record_Id__c = String.valueOf(a.Id),
            Before_Snapshot_JSON__c = '{}', Field_Decisions_JSON__c = '{"CreatedDate":"not-a-map"}'
        );
        insert readOnly;

        Test.startTest();
        DataUpdateWrapper.ApplyResult r1 = DataUpdateReviewController.rollbackChange(badObject.Id, 'Alternative_Email_1__c');
        DataUpdateWrapper.ApplyResult r2 = DataUpdateReviewController.rollbackChange(readOnly.Id, 'CreatedDate');
        DataUpdateWrapper.ApplyResult r3 = DataUpdateReviewController.rollbackChange(UserInfo.getUserId(), 'Alternative_Email_1__c');
        DataUpdateWrapper.AuditLogResult audit = DataUpdateReviewController.getAuditLog(t2.Id);
        DataUpdateWrapper.AuditLogResult noDiff = DataUpdateReviewController.getAuditLog(t.Id);
        Test.stopTest();

        System.assert(noDiff.success);
        System.assertEquals('', noDiff.entries[0].fieldChanges[0].beforeValue, 'No diff map → blank before value');
        System.assertEquals('x', noDiff.entries[0].fieldChanges[0].afterValue);

        System.assertEquals('GENERIC_ERROR', r1.errorMessage);
        System.assertEquals('GENERIC_ERROR', r2.errorMessage);
        System.assertEquals('GENERIC_ERROR', r3.errorMessage);
        System.assertEquals(false, audit.success, 'A non-map decision entry is a malformed log');
    }

    @IsTest
    static void rollbackChange_LogWithoutDecisions_IsInvalidState() {
        String U = uniq();
        Contact a = createTestContact('SansDecision' + U, 'Log');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"x@example.com"}');
        Data_Update_Log__c emptyLog = new Data_Update_Log__c(
            Request__c = t.Id, Action_Type__c = 'APPLY_COMPLETED',
            Target_Object_API_Name__c = 'Contact', Target_Record_Id__c = String.valueOf(a.Id),
            Before_Snapshot_JSON__c = '{}'
        );
        insert emptyLog;

        DataUpdateWrapper.ApplyResult r = DataUpdateReviewController.rollbackChange(emptyLog.Id, 'Alternative_Email_1__c');
        System.assertEquals(false, r.success);
        System.assertEquals('ROLLBACK_INVALID_STATE', r.errorMessage);
    }

    @IsTest
    static void rollbackChange_ForcedError_ReturnsGenericError() {
        DataUpdateReviewController.TEST_FORCE_ERROR = true;
        DataUpdateWrapper.ApplyResult r = DataUpdateReviewController.rollbackChange(UserInfo.getUserId(), 'Alternative_Email_1__c');
        DataUpdateWrapper.AuditLogResult audit = DataUpdateReviewController.getAuditLog(UserInfo.getUserId());
        DataUpdateWrapper.ReviewSummary summary = DataUpdateReviewController.getReviewSummary(UserInfo.getUserId());
        DataUpdateWrapper.ComparisonData cmp = DataUpdateReviewController.getComparisonData(UserInfo.getUserId());
        DataUpdateReviewController.TEST_FORCE_ERROR = false;
        System.assertEquals('GENERIC_ERROR', r.errorMessage);
        System.assertEquals('GENERIC_ERROR', audit.errorMessage);
        System.assertEquals('GENERIC_ERROR', summary.errorMessage);
        System.assertEquals('GENERIC_ERROR', cmp.errorMessage);
    }

    @IsTest
    static void deletedForm_FallbackConfig_ApplyAndRollbackFlagHistoryCleanup() {
        String U = uniq();
        Contact a = createTestContact('Supprime' + U, 'Form');
        Data_Update_Request__c t = createRequestFor(a.Id, 'Gone_Form_' + U, JSON.serialize(new Map<String, String>{
            'Alternative_Email_1__c' => 'fallback' + U + '@example.com',
            'Nope_Not_A_Field__c' => 'ignored'
        }));

        Test.startTest();
        DataUpdateWrapper.ComparisonData cmp = DataUpdateReviewController.getComparisonData(t.Id);
        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Alternative_Email_1__c' });
        DataUpdateWrapper.ApplyResult rolled = DataUpdateReviewController.rollbackChange(findLogId(t.Id, 'APPLY_COMPLETED'), 'Alternative_Email_1__c');
        Test.stopTest();

        System.assert(cmp.success);
        System.assert(cmp.formDeleted);
        System.assertEquals(1, cmp.fields.size(), 'Unknown keys are dropped, real fields are rebuilt from the ticket');
        System.assert(applied.success);
        System.assert(rolled.success, 'Rollback should succeed: ' + rolled.errorMessage);
        System.assert(rolled.historyCleanupSkipped, 'A deleted form lost its history mapping');
    }

    @IsTest
    static void buildFallbackConfig_ResolvesFromRecordIdOrThrows() {
        String U = uniq();
        Contact a = createTestContact('Repli' + U, 'Id');
        Data_Update_Request__c byId = new Data_Update_Request__c(Target_Record_Id__c = a.Id);
        Data_Update_Request__c none = new Data_Update_Request__c();

        DataUpdateFormConfigService.FormConfig cfg = DataUpdateReviewController.buildFallbackConfig(byId);
        System.assertEquals('Contact', cfg.targetObjectApiName);
        System.assertEquals('Name', cfg.recordNameFieldApiName);
        try {
            DataUpdateReviewController.buildFallbackConfig(none);
            System.assert(false, 'Expected RequestNotFoundException');
        } catch (DataUpdateReviewController.RequestNotFoundException e) {
            System.assert(e.getMessage().contains('Cannot resolve'));
        }

        // Malformed proposed JSON is ignored without touching the config.
        DataUpdateReviewController.addProposedFieldsMissingFromConfig(cfg,
            new Data_Update_Request__c(Proposed_Values_JSON__c = '{bad'));
        System.assert(cfg.fields.isEmpty());
    }

    // ─── Apply: savepoint rollback + historize (Eglise) ─────────────────────

    @IsTest
    static void applySelectedUpdates_InvalidValue_RollsBackAndMarksError() {
        String U = uniq();
        Contact a = createTestContact('Invalide' + U, 'Courriel');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"not an email"}');

        Test.startTest();
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Alternative_Email_1__c' });
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('Error', [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c);
    }

    // SEMBEQ has no Attendance_History__c / Baptism_History__c, and no Account field to Historize
    // from a real form: Task stands in as the history object (CallDurationInSeconds = value,
    // ActivityDate = date, WhatId/WhoId = lookup back to the record) in in-memory forms.
    // Account carries no lock field in SEMBEQ, so this form has none.
    private static void useHistorizeFakeForm() {
        DataUpdateFormConfigService.testFormMdt = (Data_Update_Form__mdt) JSON.deserialize(
            '{"DeveloperName":"Fake_Historize_Form","MasterLabel":"Fake","Target_Object_API_Name__c":"Account",'
            + '"Identity_Field_1_API_Name__c":"Name","Identity_Field_1_Comparison__c":"Exact",'
            + '"Subject_Template__c":"{RecordName}","Is_Active__c":true}',
            Data_Update_Form__mdt.class);
        DataUpdateFormConfigService.testFieldMdts = (List<Data_Update_Form_Field__mdt>) JSON.deserialize(
            '[{"Field_API_Name__c":"NumberOfEmployees","Label_FR__c":"Assistance","Label_EN__c":"Attendance",'
            + '"Display_Order__c":1,"Input_Type__c":"Number","History_Mode__c":"Historize","Is_Active__c":true,'
            + '"History_Target_Object_API_Name__c":"Task","History_Target_Value_Field_API_Name__c":"CallDurationInSeconds",'
            + '"History_Target_Date_Field_API_Name__c":"ActivityDate","History_Target_Account_Field_API_Name__c":"WhatId",'
            + '"History_Date_Source_Field_API_Name__c":"Excl_date__c"},'
            + '{"Field_API_Name__c":"Excl_date__c","Label_FR__c":"Date","Label_EN__c":"Date","Display_Order__c":2,'
            + '"Input_Type__c":"Date","History_Mode__c":"Replace","Is_Active__c":true}]',
            List<Data_Update_Form_Field__mdt>.class);
    }

    @IsTest
    static void eglise_ApplyHistorizesWithSubmittedDateThenRollbackKeepsUnlinkedRow() {
        User usr = dataUpdateUser();
        String U = uniq();
        Account e = createEglise('Eglise Test ' + U);
        Data_Update_Request__c t = createRequestFor(e.Id, 'Fake_Historize_Form', JSON.serialize(new Map<String, String>{
            'NumberOfEmployees' => '42',
            'Excl_date__c' => '2026-09-01'
        }));
        useHistorizeFakeForm();

        DataUpdateWrapper.ApplyResult applied;
        DataUpdateWrapper.ApplyResult rolled;
        Test.startTest();
        System.runAs(usr) {
            applied = DataUpdateReviewController.applySelectedUpdates(t.Id,
                new List<String>{ 'NumberOfEmployees', 'Excl_date__c' });
            rolled = DataUpdateReviewController.rollbackChange(findLogId(t.Id, 'APPLY_COMPLETED'), 'NumberOfEmployees');
        }
        Test.stopTest();

        System.assert(applied.success, 'Apply should succeed: ' + applied.errorMessage);
        System.assert(rolled.success, 'Rollback should succeed: ' + rolled.errorMessage);
        System.assertEquals(true, rolled.historyCleanupSkipped, 'No log lookup mapped → history cleanup is skipped');
        List<SObject> rows = Database.query('SELECT CallDurationInSeconds, ActivityDate FROM Task WHERE WhatId = \'' + e.Id + '\'');
        System.assertEquals(1, rows.size(), 'The apply wrote one history row');
        System.assertEquals(42, (Integer) rows[0].get('CallDurationInSeconds'));
        System.assertEquals(Date.newInstance(2026, 9, 1), rows[0].get('ActivityDate'), 'Row dated with the submitted date');
    }

    @IsTest
    static void getFormResponseChecklist_RealEgliseForm_ListsEglises() {
        User usr = dataUpdateUser();
        Account e = createEglise('Eglise Checklist ' + uniq());

        DataUpdateWrapper.ChecklistResult result;
        Test.startTest();
        System.runAs(usr) {
            result = DataUpdateReviewController.getFormResponseChecklist('SEMBEQ_Eglise_Update');
        }
        Test.stopTest();

        System.assert(result.success);
        Boolean found = false;
        for (DataUpdateWrapper.ChecklistItem item : result.items) {
            if (item.recordId == String.valueOf(e.Id)) found = true;
        }
        System.assert(found, 'The Eglise must be listed');
    }

    @IsTest
    static void getFormResponseChecklist_CountsOnlyThisFormAndPeriod() {
        User usr = dataUpdateUser();
        Account answered = createEglise('Eglise Answered ' + uniq());
        Account otherForm = createEglise('Eglise Other Form ' + uniq());
        createRequestFor(answered.Id, 'SEMBEQ_Eglise_Update', '{}');
        createRequestFor(otherForm.Id, 'Some_Other_Form', '{}');

        String today = String.valueOf(Date.today());
        String tomorrow = String.valueOf(Date.today().addDays(1));
        DataUpdateWrapper.ChecklistResult allTime;
        DataUpdateWrapper.ChecklistResult sinceToday;
        DataUpdateWrapper.ChecklistResult sinceTomorrow;
        DataUpdateWrapper.ChecklistResult badDate;
        Test.startTest();
        System.runAs(usr) {
            allTime = DataUpdateReviewController.getFormResponseChecklistSince('SEMBEQ_Eglise_Update', '');
            sinceToday = DataUpdateReviewController.getFormResponseChecklistSince('SEMBEQ_Eglise_Update', today);
            sinceTomorrow = DataUpdateReviewController.getFormResponseChecklistSince('SEMBEQ_Eglise_Update', tomorrow);
            badDate = DataUpdateReviewController.getFormResponseChecklistSince('SEMBEQ_Eglise_Update', 'not-a-date');
        }
        Test.stopTest();

        System.assert(allTime.success);
        System.assertEquals(true, checklistItem(allTime, answered.Id).responded);
        System.assertNotEquals(null, checklistItem(allTime, answered.Id).lastResponse);
        System.assertEquals(false, checklistItem(allTime, otherForm.Id).responded,
            'A request from another form must not count');
        System.assertEquals(true, checklistItem(sinceToday, answered.Id).responded);
        System.assertEquals(false, checklistItem(sinceTomorrow, answered.Id).responded,
            'A request before the period start must not count');
        System.assertEquals('GENERIC_ERROR', badDate.errorMessage);
    }

    private static DataUpdateWrapper.ChecklistItem checklistItem(DataUpdateWrapper.ChecklistResult r, Id recordId) {
        for (DataUpdateWrapper.ChecklistItem item : r.items) {
            if (item.recordId == String.valueOf(recordId)) return item;
        }
        System.assert(false, 'Record not listed: ' + recordId);
        return null;
    }

    @IsTest
    static void getFormResponseChecklist_UnknownForm_ReturnsGenericError() {
        DataUpdateWrapper.ChecklistResult result = DataUpdateReviewController.getFormResponseChecklist('DOES_NOT_EXIST');
        System.assertEquals('GENERIC_ERROR', result.errorMessage);
    }

    // ─── Forms without lock / without lock date ─────────────────────────────

    @IsTest
    static void noLockForm_LockMethodsAreNoOps() {
        useNoLockFakeForm();
        Test.startTest();
        DataUpdateWrapper.UnlockResult r1 = DataUpdateReviewController.unlockRecord(UserInfo.getUserId(), 'Fake_NoLock_Form');
        DataUpdateWrapper.UnlockAllResult r2 = DataUpdateReviewController.unlockAllRecords('Fake_NoLock_Form');
        DataUpdateWrapper.LockedRecordListResult r3 = DataUpdateReviewController.getLockedRecords('Fake_NoLock_Form', null, null, null);
        DataUpdateWrapper.ChecklistResult r4 = DataUpdateReviewController.getFormResponseChecklist('Fake_NoLock_Form');
        Test.stopTest();
        System.assert(r1.success);
        System.assert(r2.success);
        System.assert(r3.success);
        System.assert(r4.success, 'The checklist no longer depends on a lock field');
    }

    @IsTest
    static void lockWithoutDateField_LockedListHasNoDate() {
        User usr = dataUpdateUser();
        String U = uniq();
        Contact a = createTestContact('SansDate' + U, 'Lock');
        a.put('Data_Update_Locked__c', true);
        update a;
        useLockNoDateFakeForm();

        DataUpdateWrapper.LockedRecordListResult result;
        Test.startTest();
        System.runAs(usr) {
            result = DataUpdateReviewController.getLockedRecords('Fake_Lock_Form', 25, 0, null);
        }
        Test.stopTest();

        System.assert(result.success);
        System.assert(!result.records.isEmpty());
        System.assertEquals(null, result.records[0].lockedDate);
    }

    @IsTest
    static void lockMethods_UnknownForm_ReturnGenericError() {
        System.assertEquals('GENERIC_ERROR', DataUpdateReviewController.unlockRecord(UserInfo.getUserId(), 'DOES_NOT_EXIST').errorMessage);
        System.assertEquals('GENERIC_ERROR', DataUpdateReviewController.unlockAllRecords('DOES_NOT_EXIST').errorMessage);
        System.assertEquals('GENERIC_ERROR', DataUpdateReviewController.getLockedRecords('DOES_NOT_EXIST', 25, 0, null).errorMessage);
    }

    @IsTest
    static void unlockAllRecords_NothingLocked_ReturnsSuccess() {
        DataUpdateWrapper.UnlockAllResult result = DataUpdateReviewController.unlockAllRecords(FORM_NAME);
        System.assert(result.success);
        System.assertEquals(0, result.unlockedCount);
    }

    // ─── Correction: postal code ────────────────────────────────────────────

    @IsTest
    static void correctProposedValue_PostalCode_FormatsOrRejects() {
        String U = uniq();
        Contact a = createTestContact('Postal' + U, 'Code');
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{
            'MailingPostalCode' => 'H2X1Y4', 'MailingCountry' => 'Canada'
        }));

        Test.startTest();
        DataUpdateWrapper.CorrectionResult bad = DataUpdateReviewController.correctProposedValue(t.Id, 'MailingPostalCode', 'H2X');
        DataUpdateWrapper.CorrectionResult good = DataUpdateReviewController.correctProposedValue(t.Id, 'MailingPostalCode', 'h3a2b7');
        Test.stopTest();

        System.assertEquals('INVALID_POSTAL_CODE', bad.errorMessage);
        System.assert(good.success);
        System.assertEquals('H3A 2B7', good.newValue);
    }

    // ─── Inbox filters, counts, status transitions ──────────────────────────

    @IsTest
    static void getRequests_StatusFormAndDeletedFilters() {
        String U = uniq();
        Contact a = createTestContact('Filtre' + U, 'Test');
        Data_Update_Request__c live = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"x@example.com"}');
        Data_Update_Request__c orphan = createRequestFor(a.Id, 'Gone_Form_' + U, '{"Alternative_Email_1__c":"y@example.com"}');

        Test.startTest();
        DataUpdateWrapper.RequestListResult byStatus = DataUpdateReviewController.getRequests('New', FORM_NAME, null, null, null);
        DataUpdateWrapper.RequestListResult deleted = DataUpdateReviewController.getRequests('All', DataUpdateReviewController.DELETED_FORMS_FILTER, null, 10, 0);
        DataUpdateWrapper.RequestListResult broken = DataUpdateReviewController.getRequests(null, null, null, 10, 0);
        Boolean hasDeleted = DataUpdateReviewController.hasDeletedFormTickets();
        Map<String, Integer> all = DataUpdateReviewController.getStatusCounts('All');
        Map<String, Integer> byForm = DataUpdateReviewController.getStatusCounts(FORM_NAME);
        Map<String, Integer> deletedCounts = DataUpdateReviewController.getStatusCounts(DataUpdateReviewController.DELETED_FORMS_FILTER);
        Test.stopTest();

        System.assert(byStatus.success);
        System.assertEquals(1, byStatus.requests.size());
        System.assertEquals(live.Id, byStatus.requests[0].id);
        System.assertEquals(1, byStatus.requests[0].changedFieldCount);
        System.assertEquals(1, deleted.requests.size());
        System.assertEquals(orphan.Id, deleted.requests[0].id);
        System.assertEquals('GENERIC_ERROR', broken.errorMessage);
        System.assert(hasDeleted);
        System.assertEquals(2, all.get('Total'));
        System.assertEquals(2, all.get('Open'));
        System.assertEquals(1, byForm.get('New'));
        System.assertEquals(1, deletedCounts.get('Total'));
        System.assertEquals(0, DataUpdateReviewController.countProposedFields('{bad'));
        System.assertEquals(0, DataUpdateReviewController.countProposedFields(null));
    }

    @IsTest
    static void ignoreRequest_RequiresReasonThenCloses() {
        String U = uniq();
        Contact a = createTestContact('Ignore' + U, 'Test');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"x@example.com"}');

        Test.startTest();
        Boolean threw = false;
        try {
            DataUpdateReviewController.ignoreRequest(t.Id, '  ', null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        DataUpdateReviewController.ignoreRequest(t.Id, 'Duplicate', 'line1\nline2');
        Test.stopTest();

        System.assert(threw, 'A blank closed reason must be rejected');
        Data_Update_Request__c ignored = [SELECT Status__c, Final_Action__c, Closed_Reason__c, Notes__c FROM Data_Update_Request__c WHERE Id = :t.Id];
        System.assertEquals('Ignored', ignored.Status__c);
        System.assertEquals('Ignored', ignored.Final_Action__c);
        System.assertEquals('Duplicate', ignored.Closed_Reason__c);
        System.assert(ignored.Notes__c.contains('[HIST:Ignored|||Duplicate|||line1\\nline2'));
    }

    // ─── Pure helpers ───────────────────────────────────────────────────────

    @IsTest
    static void coerceHelpers_AllTypes() {
        System.assertEquals(null, DataUpdateReviewController.coerceValue(Schema.DisplayType.STRING, ''));
        System.assertEquals(Date.newInstance(2026, 1, 2), DataUpdateReviewController.coerceValue(Schema.DisplayType.DATE, '2026-01-02'));
        System.assertEquals(DateTime.valueOf('2026-01-02 03:04:05'), DataUpdateReviewController.coerceValue(Schema.DisplayType.DATETIME, '2026-01-02 03:04:05'));
        System.assertEquals(Decimal.valueOf('1.5'), DataUpdateReviewController.coerceValue(Schema.DisplayType.DOUBLE, '1.5'));
        System.assertEquals(3, DataUpdateReviewController.coerceValue(Schema.DisplayType.INTEGER, '3'));
        System.assertEquals(true, DataUpdateReviewController.coerceValue(Schema.DisplayType.BOOLEAN, 'true'));
        System.assertEquals('abc', DataUpdateReviewController.coerceValue(Schema.DisplayType.STRING, 'abc'));

        DateTime dt = DateTime.newInstance(2026, 5, 6, 7, 8, 9);
        Date d = Date.newInstance(2026, 5, 6);
        System.assertEquals(dt, DataUpdateReviewController.coerceDateValue(dt, Schema.DisplayType.DATETIME, Schema.DisplayType.DATETIME));
        System.assertEquals(dt.date(), DataUpdateReviewController.coerceDateValue(dt, Schema.DisplayType.DATETIME, Schema.DisplayType.DATE));
        System.assertEquals(d, DataUpdateReviewController.coerceDateValue(d, Schema.DisplayType.DATE, Schema.DisplayType.DATE));
        System.assertEquals(DateTime.newInstance(d, Time.newInstance(0, 0, 0, 0)),
            DataUpdateReviewController.coerceDateValue(d, Schema.DisplayType.DATE, Schema.DisplayType.DATETIME));

        System.assertEquals('Name = true', DataUpdateReviewController.buildBaseFilterClause('Name', 'TRUE'));
        System.assertEquals('RecordType.DeveloperName = \'Eglise\'', DataUpdateReviewController.buildBaseFilterClause('RecordType.DeveloperName', 'Eglise'));
        System.assertEquals(null, DataUpdateReviewController.buildBaseFilterClause(null, 'x'));
        System.assertEquals('RecordType.DeveloperName IN (\'Organisme\', \'Business_Organization\')',
            DataUpdateReviewController.buildBaseFilterClause('RecordType.DeveloperName', 'Organisme, Business_Organization,'));
        System.assertEquals(new List<String>(), DataUpdateFormConfigService.splitFilterValues(null));
        System.assertEquals(false, DataUpdateReviewController.isFieldAccessible('Nope_Not_An_Object__c', 'Name'));
    }

    @IsTest
    static void historyRowHelpers_NoDateSourceAndNoLogField() {
        String U = uniq();
        Account e = createEglise('Eglise Hist ' + U);
        DataUpdateFormConfigService.FormFieldConfig fc = new DataUpdateFormConfigService.FormFieldConfig();
        fc.fieldApiName = 'NumberOfEmployees';
        fc.historyMode = 'Historize';
        fc.historyTargetObjectApiName = 'Task';
        fc.historyTargetValueFieldApiName = 'CallDurationInSeconds';
        fc.historyTargetDateFieldApiName = 'ActivityDate';
        fc.historyTargetAccountFieldApiName = 'WhatId';

        SObject row = DataUpdateReviewController.buildDynamicHistoryRow(fc, e.Id, 12, new Account(Id = e.Id), null, null);
        System.assertEquals(Date.today(), row.get('ActivityDate'), 'No date source → today');
        System.assertEquals(e.Id, row.get('WhatId'));
        System.assert(DataUpdateReviewController.deleteHistoryRowsForRollback(fc, null), 'No log field → cleanup skipped');
    }

    // No SEMBEQ object has a lookup to Data_Update_Log__c, so form validation never lets a log
    // field through; the row builders and the cleanup are exercised directly, with Task.Subject
    // standing in for the log lookup (it stores the log id as text).
    @IsTest
    static void historyRowHelpers_WithLogField_StampAndCleanUpRows() {
        String U = uniq();
        Account e = createEglise('Eglise HistLog ' + U);
        Contact c = createTestContact('HistLog' + U, 'Test');
        Data_Update_Request__c t = createReviewRequest(c.Id, '{}');
        Data_Update_Log__c log = newApplyLog(t, '{}');
        insert log;

        DataUpdateFormConfigService.FormFieldConfig fc = new DataUpdateFormConfigService.FormFieldConfig();
        fc.fieldApiName = 'NumberOfEmployees';
        fc.historyMode = 'Historize';
        fc.historyTargetObjectApiName = 'Task';
        fc.historyTargetValueFieldApiName = 'CallDurationInSeconds';
        fc.historyTargetDateFieldApiName = 'ActivityDate';
        fc.historyTargetAccountFieldApiName = 'WhatId';
        fc.historyTargetLogFieldApiName = 'Subject';
        SObject historizeRow = DataUpdateReviewController.buildDynamicHistoryRow(fc, e.Id, 12, new Account(Id = e.Id), t.Id, log.Id);
        System.assertEquals(String.valueOf(log.Id), String.valueOf(historizeRow.get('Subject')));

        DataUpdateFormConfigService.FormFieldConfig ho = new DataUpdateFormConfigService.FormFieldConfig();
        ho.fieldApiName = HIST_ONLY_KEY;
        ho.historyMode = 'History_Only';
        ho.historyTargetObjectApiName = 'Task';
        ho.historyTargetValueFieldApiName = 'CallDurationInSeconds';
        ho.historyTargetDateFieldApiName = 'ActivityDate';
        ho.historyTargetAccountFieldApiName = 'WhoId';
        ho.historyTargetLogFieldApiName = 'Subject';
        SObject historyOnlyRow = DataUpdateReviewController.buildHistoryOnlyRow(ho, t, new Map<String, String>{ HIST_ONLY_KEY => '9' }, log.Id);
        System.assertEquals(String.valueOf(log.Id), String.valueOf(historyOnlyRow.get('Subject')));
        insert historyOnlyRow;

        DataUpdateFormConfigService.FormFieldConfig tc = new DataUpdateFormConfigService.FormFieldConfig();
        tc.fieldApiName = HT_KEY;
        tc.historyMode = 'History_Table';
        tc.historyTargetObjectApiName = 'Task';
        tc.historyTargetDateFieldApiName = 'ActivityDate';
        tc.historyTargetAccountFieldApiName = 'WhoId';
        tc.historyTargetLogFieldApiName = 'Subject';
        DataUpdateReviewController.planTableApply(tc, DataUpdateReviewController.parseTableValue(
            htValue(new List<List<String>>{ new List<String>{ '2026-08-09', '40' } })), new Set<Integer>{ 0 }, c.Id, log.Id);

        Test.startTest();
        Boolean skipped = DataUpdateReviewController.deleteHistoryRowsForRollback(ho, log.Id);
        Test.stopTest();

        System.assertEquals(false, skipped);
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhoId = :c.Id], 'Rows pointing to the log are deleted');
    }

    @IsTest
    static void historyRow_PairedDateNotApplied_UsesTicketDate() {
        String U = uniq();
        Account e = createEglise('Eglise Paired ' + U);
        DataUpdateFormConfigService.FormFieldConfig fc = new DataUpdateFormConfigService.FormFieldConfig();
        fc.fieldApiName = 'NumberOfEmployees';
        fc.historyMode = 'Historize';
        fc.historyTargetObjectApiName = 'Task';
        fc.historyTargetValueFieldApiName = 'CallDurationInSeconds';
        fc.historyTargetDateFieldApiName = 'ActivityDate';
        fc.historyTargetAccountFieldApiName = 'WhatId';
        fc.historyDateSourceFieldApiName = 'Excl_date__c';

        // grouped review: the date goes in with another ticket, so it is not on targetRecord
        Map<String, String> proposed = new Map<String, String>{ 'Excl_date__c' => '2026-04-05' };
        SObject row = DataUpdateReviewController.buildDynamicHistoryRow(fc, e.Id, 120, new Account(Id = e.Id), null, null, proposed);
        System.assertEquals(Date.newInstance(2026, 4, 5), row.get('ActivityDate'), 'Date this ticket sent, not today');

        // applied with this ticket: the record value wins
        Account withDate = new Account(Id = e.Id, Excl_date__c = Date.newInstance(2026, 3, 1));
        row = DataUpdateReviewController.buildDynamicHistoryRow(fc, e.Id, 120, withDate, null, null, proposed);
        System.assertEquals(Date.newInstance(2026, 3, 1), row.get('ActivityDate'));

        // malformed → today, as before
        row = DataUpdateReviewController.buildDynamicHistoryRow(fc, e.Id, 120, new Account(Id = e.Id), null, null,
            new Map<String, String>{ 'Excl_date__c' => 'not a date' });
        System.assertEquals(Date.today(), row.get('ActivityDate'));
    }

    @IsTest
    static void eglise_ComparisonData_HistorizeShowsLatestHistoryRow() {
        User usr = dataUpdateUser();
        Account e = createEglise('Eglise Preview ' + uniq());
        insert new Task(WhatId = e.Id, CallDurationInSeconds = 1410, ActivityDate = Date.newInstance(2025, 9, 14));
        Data_Update_Request__c t = createRequestFor(e.Id, 'Fake_Historize_Form', JSON.serialize(new Map<String, String>{
            'NumberOfEmployees' => '1500',
            'Excl_date__c' => '2026-09-10'
        }));
        useHistorizeFakeForm();

        DataUpdateWrapper.ComparisonData data;
        Test.startTest();
        System.runAs(usr) {
            data = DataUpdateReviewController.getComparisonData(t.Id);
        }
        Test.stopTest();

        System.assert(data.success, 'Comparison should load: ' + data.errorMessage);
        DataUpdateWrapper.ComparisonField att;
        for (DataUpdateWrapper.ComparisonField f : data.fields) {
            if (f.fieldApiName == 'NumberOfEmployees') att = f;
        }
        System.assertNotEquals(null, att, 'Attendance must be a changed field');
        System.assertEquals(true, att.isHistorize);
        System.assert(String.isNotBlank(att.historyObjectLabel));
        System.assertEquals('1410', att.historyLastValue);
        System.assertEquals('2025-09-14', att.historyLastDate);
        System.assertEquals('2026-09-10', att.historyDate, 'New row carries the submitted date');
    }

    @IsTest
    static void historizePreviewHelpers_FallbacksAndSkips() {
        DataUpdateFormConfigService.FormFieldConfig fc = new DataUpdateFormConfigService.FormFieldConfig();
        fc.fieldApiName = 'NumberOfEmployees';
        fc.historyMode = 'Historize';
        fc.historyTargetObjectApiName = 'Task';
        fc.historyTargetValueFieldApiName = 'CallDurationInSeconds';

        System.assertEquals(String.valueOf(Date.today()),
            DataUpdateReviewController.resolveHistorizePreviewDate(fc, new Map<String, String>()), 'No date source → today');
        fc.historyDateSourceFieldApiName = 'Excl_date__c';
        System.assertEquals(String.valueOf(Date.today()),
            DataUpdateReviewController.resolveHistorizePreviewDate(fc, new Map<String, String>()), 'Date not submitted → today');
        System.assertEquals('Nope_Not_An_Object__c', DataUpdateReviewController.historyObjectLabel('Nope_Not_An_Object__c'));

        Id fakeId = FAKE_RECORD_ID;
        // No account lookup mapped → skipped.
        System.assert(DataUpdateReviewController.queryLatestHistorizePoints(
            new List<DataUpdateFormConfigService.FormFieldConfig>{ fc }, fakeId).isEmpty());
        // Broken mapping → query fails → preview just shows no previous row.
        fc.historyTargetAccountFieldApiName = 'WhatId';
        fc.historyTargetValueFieldApiName = 'Nope_Not_A_Field__c';
        System.assert(DataUpdateReviewController.queryLatestHistorizePoints(
            new List<DataUpdateFormConfigService.FormFieldConfig>{ fc }, fakeId).isEmpty());
        // Unknown history object → skipped; null record id → empty.
        fc.historyTargetObjectApiName = 'Nope_Not_An_Object__c';
        System.assert(DataUpdateReviewController.queryLatestHistorizePoints(
            new List<DataUpdateFormConfigService.FormFieldConfig>{ fc }, fakeId).isEmpty());
        System.assert(DataUpdateReviewController.queryLatestHistorizePoints(
            new List<DataUpdateFormConfigService.FormFieldConfig>{ fc }, null).isEmpty());
    }

    // ─── History_Only: value only becomes a history row, nothing on the record ──

    private static final String HIST_ONLY_KEY = 'Task.CallDurationInSeconds';

    private static void useHistoryOnlyFakeForm() {
        DataUpdateFormConfigService.testFormMdt = (Data_Update_Form__mdt) JSON.deserialize(
            '{"DeveloperName":"Fake_HistOnly_Form","MasterLabel":"Fake","Target_Object_API_Name__c":"Contact",'
            + '"Identity_Field_1_API_Name__c":"Name","Identity_Field_1_Comparison__c":"Exact",'
            + '"Subject_Template__c":"{RecordName}","Is_Active__c":true,"Lock_Field_API_Name__c":"Data_Update_Locked__c",'
            + '"Lock_Date_Field_API_Name__c":"Data_Update_Locked_Date__c"}',
            Data_Update_Form__mdt.class);
        DataUpdateFormConfigService.testFieldMdts = (List<Data_Update_Form_Field__mdt>) JSON.deserialize(
            '[{"Field_API_Name__c":"' + HIST_ONLY_KEY + '","Label_FR__c":"Assistance","Label_EN__c":"Attendance",'
            + '"Display_Order__c":1,"Input_Type__c":"Number","History_Mode__c":"History_Only","Is_Active__c":true,'
            + '"History_Target_Object_API_Name__c":"Task","History_Target_Value_Field_API_Name__c":"CallDurationInSeconds",'
            + '"History_Target_Date_Field_API_Name__c":"ActivityDate","History_Target_Account_Field_API_Name__c":"WhoId"},'
            + '{"Field_API_Name__c":"Phone","Label_FR__c":"T","Label_EN__c":"T","Display_Order__c":2,'
            + '"Input_Type__c":"Phone","History_Mode__c":"Replace","Is_Active__c":true}]',
            List<Data_Update_Form_Field__mdt>.class);
    }

    private static SObject newAttendanceRow(Id contactId, Integer value, Date metricDate) {
        return new Task(WhoId = contactId, CallDurationInSeconds = value, ActivityDate = metricDate);
    }

    @IsTest
    static void historyOnly_CompareApplyAuditRollback() {
        User usr = dataUpdateUser();
        Contact e = createTestContact('HistOnly' + uniq(), 'Test');
        insert newAttendanceRow(e.Id, 30, Date.newInstance(2026, 8, 1));
        Data_Update_Request__c t = createRequestFor(e.Id, 'Fake_HistOnly_Form', JSON.serialize(new Map<String, String>{
            HIST_ONLY_KEY => '42',
            HIST_ONLY_KEY + '@date' => '2026-09-01'
        }));
        useHistoryOnlyFakeForm();

        DataUpdateWrapper.ReviewSummary summary;
        DataUpdateWrapper.ComparisonData comparison;
        DataUpdateWrapper.ApplyResult applied;
        DataUpdateWrapper.AuditLogResult audit;
        DataUpdateWrapper.ApplyResult rolled;
        Test.startTest();
        System.runAs(usr) {
            summary    = DataUpdateReviewController.getReviewSummary(t.Id);
            comparison = DataUpdateReviewController.getComparisonData(t.Id);
            applied    = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ HIST_ONLY_KEY });
            audit      = DataUpdateReviewController.getAuditLog(t.Id);
            rolled     = DataUpdateReviewController.rollbackChange(findLogId(t.Id, 'APPLY_COMPLETED'), HIST_ONLY_KEY);
        }
        Test.stopTest();

        System.assertEquals(1, summary.changedFieldCount, 'A history-only value always counts as a change');

        System.assert(comparison.success, comparison.errorMessage);
        DataUpdateWrapper.ComparisonField cf;
        for (DataUpdateWrapper.ComparisonField f : comparison.fields) {
            if (f.fieldApiName == HIST_ONLY_KEY) cf = f;
        }
        System.assertNotEquals(null, cf);
        System.assertEquals(true, cf.isHistoryOnly);
        System.assertEquals(true, cf.isDifferent);
        System.assertEquals('30', cf.currentValue);
        System.assertEquals('2026-08-01', cf.currentValueDate);
        System.assertEquals('2026-09-01', cf.historyDate);

        System.assert(applied.success, 'Apply should succeed: ' + applied.errorMessage);
        System.assertEquals(1, applied.updatedFieldCount);

        System.assert(audit.success, audit.errorMessage);
        Boolean sawDatedAfter = false;
        for (DataUpdateWrapper.AuditLogEntry entry : audit.entries) {
            for (DataUpdateWrapper.AuditFieldChange change : entry.fieldChanges) {
                if (change.fieldApiName == HIST_ONLY_KEY && change.afterValue != null
                    && change.afterValue.contains('(2026-09-01)')) sawDatedAfter = true;
            }
        }
        System.assert(sawDatedAfter, 'Audit must show the history date next to the applied value');

        System.assert(rolled.success, 'Rollback should succeed: ' + rolled.errorMessage);
        List<SObject> remaining = Database.query('SELECT CallDurationInSeconds FROM Task WHERE WhoId = \'' + e.Id + '\'');
        System.assertEquals(1, remaining.size(), 'Rollback removes only the row created by the apply');
        System.assertEquals(30, (Integer) remaining[0].get('CallDurationInSeconds'));
        System.assertEquals('Reopened', [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c);
    }

    @IsTest
    static void historyOnly_ApplyWritesRowWithSubmissionDate() {
        User usr = dataUpdateUser();
        Contact e = createTestContact('HistOnly2' + uniq(), 'Test');
        Data_Update_Request__c t = createRequestFor(e.Id, 'Fake_HistOnly_Form', JSON.serialize(new Map<String, String>{
            HIST_ONLY_KEY => '17'
        }));
        useHistoryOnlyFakeForm();

        DataUpdateWrapper.ApplyResult applied;
        Test.startTest();
        System.runAs(usr) {
            applied = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ HIST_ONLY_KEY });
        }
        Test.stopTest();

        System.assert(applied.success, 'Apply should succeed: ' + applied.errorMessage);
        List<SObject> rows = Database.query('SELECT CallDurationInSeconds, ActivityDate FROM Task WHERE WhoId = \'' + e.Id + '\'');
        System.assertEquals(1, rows.size());
        System.assertEquals(17, (Integer) rows[0].get('CallDurationInSeconds'));
        System.assertEquals(Date.today(), rows[0].get('ActivityDate'), 'No typed date → submission date');
        Data_Update_Log__c log = [SELECT Field_Decisions_JSON__c FROM Data_Update_Log__c
                                  WHERE Request__c = :t.Id AND Action_Type__c = 'APPLY_COMPLETED' LIMIT 1];
        System.assert(log.Field_Decisions_JSON__c.contains('historyRowId'), 'The log must remember which row was inserted');
    }

    @IsTest
    static void historyOnly_RollbackWithoutRowId_FallsBackToLogLookupOrSkips() {
        User usr = dataUpdateUser();
        Contact e = createTestContact('HistOnly3' + uniq(), 'Test');
        Data_Update_Request__c t = createRequestFor(e.Id, 'Fake_HistOnly_Form', JSON.serialize(new Map<String, String>{
            HIST_ONLY_KEY => '5'
        }));
        useHistoryOnlyFakeForm();

        DataUpdateWrapper.ApplyResult rolled;
        Test.startTest();
        System.runAs(usr) {
            DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ HIST_ONLY_KEY });
            Id logId = findLogId(t.Id, 'APPLY_COMPLETED');
            // Strip historyRowId so rollback has to fall back to the log lookup — none is mapped here.
            Data_Update_Log__c log = [SELECT Field_Decisions_JSON__c FROM Data_Update_Log__c WHERE Id = :logId];
            Map<String, Object> decisions = (Map<String, Object>) JSON.deserializeUntyped(log.Field_Decisions_JSON__c);
            ((Map<String, Object>) decisions.get(HIST_ONLY_KEY)).remove('historyRowId');
            update new Data_Update_Log__c(Id = logId, Field_Decisions_JSON__c = JSON.serialize(decisions));
            rolled = DataUpdateReviewController.rollbackChange(logId, HIST_ONLY_KEY);
        }
        Test.stopTest();

        System.assert(rolled.success, 'Rollback should succeed: ' + rolled.errorMessage);
        System.assertEquals(true, rolled.historyCleanupSkipped, 'Without row id or log lookup the row cannot be found');
        System.assertEquals(1, Database.countQuery('SELECT COUNT() FROM Task WHERE WhoId = \'' + e.Id + '\''));
    }

    @IsTest
    static void historyOnly_RollbackDmlError_RestoresEverything() {
        User usr = dataUpdateUser();
        Contact e = createTestContact('HistOnly4' + uniq(), 'Test');
        Data_Update_Request__c t = createRequestFor(e.Id, 'Fake_HistOnly_Form', JSON.serialize(new Map<String, String>{
            HIST_ONLY_KEY => '8'
        }));
        useHistoryOnlyFakeForm();

        DataUpdateWrapper.ApplyResult rolled;
        Test.startTest();
        System.runAs(usr) {
            DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ HIST_ONLY_KEY });
            DataUpdateReviewController.TEST_FORCE_ROLLBACK_DML_ERROR = true;
            rolled = DataUpdateReviewController.rollbackChange(findLogId(t.Id, 'APPLY_COMPLETED'), HIST_ONLY_KEY);
        }
        Test.stopTest();

        System.assertEquals(false, rolled.success);
        System.assertEquals(1, Database.countQuery('SELECT COUNT() FROM Task WHERE WhoId = \'' + e.Id + '\''),
            'A failed rollback must leave the history row in place');
    }

    @IsTest
    static void historyOnly_DateAndRowHelpers() {
        Contact e = createTestContact('HistOnly5' + uniq(), 'Test');
        Data_Update_Request__c t = createRequestFor(e.Id, 'Fake_HistOnly_Form', '{}');
        t = [SELECT Id, CreatedDate, Target_Record_Id__c FROM Data_Update_Request__c WHERE Id = :t.Id];
        DataUpdateFormConfigService.FormFieldConfig fc = new DataUpdateFormConfigService.FormFieldConfig();
        fc.fieldApiName = HIST_ONLY_KEY;
        fc.historyMode = 'History_Only';
        fc.historyTargetObjectApiName = 'Task';
        fc.historyTargetValueFieldApiName = 'CallDurationInSeconds';
        fc.historyTargetDateFieldApiName = 'ActivityDate';
        fc.historyTargetAccountFieldApiName = 'WhoId';

        String dateKey = HIST_ONLY_KEY + '@date';
        System.assertEquals(Date.newInstance(2026, 3, 4),
            DataUpdateReviewController.resolveHistoryDate(fc, new Map<String, String>{ dateKey => '2026-03-04' }, t));
        System.assertEquals(t.CreatedDate.date(),
            DataUpdateReviewController.resolveHistoryDate(fc, new Map<String, String>{ dateKey => 'not-a-date' }, t));
        System.assertEquals(Date.today(),
            DataUpdateReviewController.resolveHistoryDate(fc, new Map<String, String>(), new Data_Update_Request__c()));

        SObject row = DataUpdateReviewController.buildHistoryOnlyRow(fc, t, new Map<String, String>{ HIST_ONLY_KEY => '9' }, null);
        System.assertEquals(9, (Integer) row.get('CallDurationInSeconds'));
        System.assertEquals(e.Id, row.get('WhoId'));
        System.assertEquals(t.CreatedDate.date(), row.get('ActivityDate'));
    }

    // ─── Rediseño: encabezado, campos idénticos, candado y presencia ────────

    @IsTest
    static void getComparisonData_ReturnsHeaderAndUnchangedFields() {
        String U = uniq();
        Contact a = createTestContact('Gagnon' + U, 'Marc');
        a = queryContactEmailAndPhone(a.Id);
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{
            'Alternative_Email_1__c' => 'brandnew' + U + '@example.com',
            'MobilePhone' => getMobilePhone(a)
        }));
        t.Requested_Name__c = 'Marc Gagnon';
        t.Requested_Email__c = 'marc' + U + '@example.com';
        update t;

        Test.startTest();
        DataUpdateWrapper.ComparisonData data = DataUpdateReviewController.getComparisonData(t.Id);
        Test.stopTest();

        System.assert(data.success);
        System.assertEquals(1, data.fields.size(), 'Identical fields must stay out of the apply list');
        System.assertEquals(1, data.unchangedFields.size());
        System.assertEquals('MobilePhone', data.unchangedFields[0].fieldApiName);
        System.assertEquals(false, data.unchangedFields[0].isDifferent);
        System.assertEquals('Marc Gagnon', data.requestedName);
        System.assertEquals(t.Requested_Email__c, data.requestedEmail);
        System.assertNotEquals(null, data.requestNumber);
        System.assertNotEquals(null, data.createdDate);
    }

    @IsTest
    static void getRequests_ReportsLockAndOtherViewers() {
        String U = uniq();
        Contact locked = createTestContact('Roy' + U, 'Anne');
        locked.put('Data_Update_Locked__c', true);
        update locked;
        Contact open = createTestContact('Roy' + U, 'Paul');
        Data_Update_Request__c tLocked = createReviewRequest(locked.Id, '{"Alternative_Email_1__c":"a@example.com"}');
        Data_Update_Request__c tOpen = createReviewRequest(open.Id, '{"Alternative_Email_1__c":"b@example.com"}');
        // The search box matches the requester's name.
        update new List<Data_Update_Request__c>{
            new Data_Update_Request__c(Id = tLocked.Id, Requested_Name__c = 'Anne Roy' + U),
            new Data_Update_Request__c(Id = tOpen.Id, Requested_Name__c = 'Paul Roy' + U)
        };
        Id adminId = UserInfo.getUserId();
        insert new Data_Update_Presence__c(Key__c = String.valueOf(tLocked.Id) + adminId, Request__c = tLocked.Id,
                                           User__c = adminId, Last_Seen__c = Datetime.now());
        User usr = dataUpdateUser();

        DataUpdateWrapper.RequestListResult result;
        Test.startTest();
        System.runAs(usr) {
            result = DataUpdateReviewController.getRequests('All', 'All', 'Roy' + U, 50, 0);
        }
        Test.stopTest();

        System.assert(result.success);
        Map<String, DataUpdateWrapper.RequestSummary> byId = new Map<String, DataUpdateWrapper.RequestSummary>();
        for (DataUpdateWrapper.RequestSummary r : result.requests) byId.put(r.id, r);
        System.assertEquals(true, byId.get(tLocked.Id).isLocked);
        System.assertEquals(false, byId.get(tOpen.Id).isLocked);
        System.assertEquals(1, byId.get(tLocked.Id).viewers.size(), 'The admin is viewing the locked ticket');
        System.assert(byId.get(tOpen.Id).viewers.isEmpty());
    }

    @IsTest
    static void heartbeat_UpsertsOwnRowReturnsOthersAndLeaveDeletes() {
        String U = uniq();
        Contact a = createTestContact('Cote' + U, 'Julie');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"c@example.com"}');
        User usr = dataUpdateUser();
        Id adminId = UserInfo.getUserId();
        insert new Data_Update_Presence__c(Key__c = String.valueOf(t.Id) + adminId, Request__c = t.Id,
                                           User__c = adminId, Last_Seen__c = Datetime.now());
        // Stale row of the user's own (closed browser): cleaned up by the next heartbeat.
        insert new Data_Update_Presence__c(Key__c = 'stale' + U.left(30), Request__c = t.Id,
                                           User__c = usr.Id, Last_Seen__c = Datetime.now().addDays(-2));

        List<String> others;
        Test.startTest();
        System.runAs(usr) {
            others = DataUpdateReviewController.heartbeat(t.Id);
            DataUpdateReviewController.heartbeat(t.Id); // second beat updates the same row
        }
        Test.stopTest();

        System.assertEquals(1, others.size(), 'Only the admin, the user itself is excluded');
        String key = String.valueOf(t.Id) + String.valueOf(usr.Id);
        System.assertEquals(1, [SELECT COUNT() FROM Data_Update_Presence__c WHERE Key__c = :key]);
        System.assertEquals(0, [SELECT COUNT() FROM Data_Update_Presence__c WHERE User__c = :usr.Id
                                AND Last_Seen__c < :Datetime.now().addHours(-1)], 'Stale rows are cleaned up');

        System.runAs(usr) {
            DataUpdateReviewController.leaveRequest(t.Id);
        }
        System.assertEquals(0, [SELECT COUNT() FROM Data_Update_Presence__c WHERE Key__c = :key]);
    }

    @IsTest
    static void heartbeat_NullRequest_IsNoOp() {
        System.assert(DataUpdateReviewController.heartbeat(null).isEmpty());
        DataUpdateReviewController.leaveRequest(null);
        System.assertEquals(0, [SELECT COUNT() FROM Data_Update_Presence__c]);
    }

    // ─── History_Table: pasted lines → one history record each ──────────────

    private static final String HT_KEY = 'Task#table';

    private static void useHistoryTableFakeForm() {
        DataUpdateFormConfigService.testFormMdt = (Data_Update_Form__mdt) JSON.deserialize(
            '{"DeveloperName":"Fake_Table_Form","MasterLabel":"Fake","Target_Object_API_Name__c":"Contact",'
            + '"Identity_Field_1_API_Name__c":"Name","Identity_Field_1_Comparison__c":"Exact",'
            + '"Subject_Template__c":"{RecordName}","Is_Active__c":true,"Lock_Field_API_Name__c":"Data_Update_Locked__c",'
            + '"Lock_Date_Field_API_Name__c":"Data_Update_Locked_Date__c"}',
            Data_Update_Form__mdt.class);
        String columns = '[{"f":"ActivityDate","fr":"Date","en":"Date"},{"f":"CallDurationInSeconds","fr":"Personnes","en":"People"}]';
        DataUpdateFormConfigService.testFieldMdts = (List<Data_Update_Form_Field__mdt>) JSON.deserialize(
            '[{"Field_API_Name__c":"Phone","Label_FR__c":"T","Label_EN__c":"T","Display_Order__c":1,'
            + '"Input_Type__c":"Phone","History_Mode__c":"Replace","Is_Active__c":true},'
            + '{"Field_API_Name__c":"' + HT_KEY + '","Label_FR__c":"Assistance","Label_EN__c":"Attendance",'
            + '"Display_Order__c":2,"Input_Type__c":"Text","History_Mode__c":"History_Table","Is_Active__c":true,'
            + '"History_Target_Object_API_Name__c":"Task","History_Target_Date_Field_API_Name__c":"ActivityDate",'
            + '"History_Target_Account_Field_API_Name__c":"WhoId",'
            + '"History_Table_Columns__c":' + JSON.serialize(columns) + '}]',
            List<Data_Update_Form_Field__mdt>.class);
    }

    private static String htValue(List<List<String>> rows) {
        return JSON.serialize(new Map<String, Object>{
            'cols' => new List<String>{ 'ActivityDate', 'CallDurationInSeconds' },
            'rows' => rows
        });
    }

    @IsTest
    static void historyTable_CompareApplyOverwriteRollback() {
        User usr = dataUpdateUser();
        Contact e = createTestContact('Table' + uniq(), 'Test');
        insert newAttendanceRow(e.Id, 30, Date.newInstance(2026, 8, 2));
        Data_Update_Request__c t = createRequestFor(e.Id, 'Fake_Table_Form', JSON.serialize(new Map<String, String>{
            HT_KEY => htValue(new List<List<String>>{
                new List<String>{ '2026-08-02', '35' },
                new List<String>{ '2026-08-09', '40' },
                new List<String>{ '2026-08-16', '45' }
            })
        }));
        useHistoryTableFakeForm();

        DataUpdateWrapper.ReviewSummary summary;
        DataUpdateWrapper.ComparisonData comparison;
        DataUpdateWrapper.ApplyResult applied;
        DataUpdateWrapper.AuditLogResult audit;
        DataUpdateWrapper.ApplyResult rolled;
        Test.startTest();
        System.runAs(usr) {
            summary    = DataUpdateReviewController.getReviewSummary(t.Id);
            comparison = DataUpdateReviewController.getComparisonData(t.Id);
            // Line 0 has the same date as the existing row → kept = overwrite; line 2 excluded.
            applied    = DataUpdateReviewController.applySelectedUpdatesWithTables(t.Id, new List<String>(),
                JSON.serialize(new Map<String, Object>{ HT_KEY => new List<Integer>{ 0, 1 } }));
            audit      = DataUpdateReviewController.getAuditLog(t.Id);
        }
        Test.stopTest();

        System.assertEquals(3, summary.changedFieldCount, 'Each pasted line counts as one change');

        System.assert(comparison.success, comparison.errorMessage);
        System.assertEquals(1, comparison.tables.size());
        DataUpdateWrapper.ComparisonTable ct = comparison.tables[0];
        System.assertEquals(HT_KEY, ct.key);
        System.assertEquals(3, ct.rows.size());
        System.assertEquals(1, ct.duplicateCount);
        System.assertEquals(true, ct.rows[0].isDuplicate);
        System.assertEquals(false, ct.rows[1].isDuplicate);
        System.assertEquals('2026-08-02', ct.rows[0].existingCells[0]);

        System.assert(applied.success, 'Apply should succeed: ' + applied.errorMessage);
        Map<Date, Integer> byDate = attendanceByDate(e.Id);
        System.assertEquals(2, byDate.size(), 'One overwrite + one insert, the excluded line is not written');
        System.assertEquals(35, byDate.get(Date.newInstance(2026, 8, 2)));
        System.assertEquals(40, byDate.get(Date.newInstance(2026, 8, 9)));
        System.assert(audit.success, audit.errorMessage);

        System.runAs(usr) {
            rolled = DataUpdateReviewController.rollbackChange(findLogId(t.Id, 'APPLY_COMPLETED'), HT_KEY);
        }
        System.assert(rolled.success, 'Rollback should succeed: ' + rolled.errorMessage);
        byDate = attendanceByDate(e.Id);
        System.assertEquals(1, byDate.size(), 'Rollback deletes the inserted line');
        System.assertEquals(30, byDate.get(Date.newInstance(2026, 8, 2)), 'Rollback restores the overwritten value');
        System.assertEquals('Reopened', [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c);
    }

    @IsTest
    static void historyTable_NothingSelectedWritesNothing() {
        User usr = dataUpdateUser();
        Contact e = createTestContact('Table2' + uniq(), 'Test');
        Data_Update_Request__c t = createRequestFor(e.Id, 'Fake_Table_Form', JSON.serialize(new Map<String, String>{
            HT_KEY => htValue(new List<List<String>>{ new List<String>{ '2026-08-02', '35' } }),
            'Phone' => '514-555-0199'
        }));
        useHistoryTableFakeForm();
        DataUpdateWrapper.ApplyResult applied;
        Test.startTest();
        System.runAs(usr) {
            applied = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Phone' });
        }
        Test.stopTest();
        System.assert(applied.success, applied.errorMessage);
        System.assertEquals(0, attendanceByDate(e.Id).size());
    }

    private static Map<Date, Integer> attendanceByDate(Id accountId) {
        Map<Date, Integer> out = new Map<Date, Integer>();
        for (SObject row : Database.query('SELECT ActivityDate, CallDurationInSeconds FROM Task WHERE WhoId = \'' + accountId + '\'')) {
            out.put((Date) row.get('ActivityDate'), (Integer) row.get('CallDurationInSeconds'));
        }
        return out;
    }

    @IsTest
    static void historyTable_Helpers() {
        String value = htValue(new List<List<String>>{
            new List<String>{ '2026-08-02', '35' }, new List<String>{ '2026-08-09', '40' }
        });
        System.assertEquals(3, DataUpdateReviewController.countProposedFields(JSON.serialize(new Map<String, String>{
            HT_KEY => value, 'Phone' => '1'
        })));
        System.assertEquals(0, DataUpdateReviewController.countProposedFields('not json'));
        System.assertNotEquals(null, DataUpdateReviewController.parseTableValue(value));
        System.assertEquals(null, DataUpdateReviewController.parseTableValue('{"cols":[],"rows":[]}'));
        System.assertEquals(null, DataUpdateReviewController.parseTableValue('garbage'));
        System.assertEquals(null, DataUpdateReviewController.parseTableValue(null));

        Map<String, Set<Integer>> sel = DataUpdateReviewController.parseTableSelections('{"' + HT_KEY + '":[0,2],"x":"bad"}');
        System.assertEquals(new Set<Integer>{ 0, 2 }, sel.get(HT_KEY));
        System.assertEquals(0, sel.get('x').size());
        System.assertEquals(0, DataUpdateReviewController.parseTableSelections(null).size());

        System.assertEquals(false, DataUpdateReviewController.coerceTableValue(Schema.DisplayType.BOOLEAN, ''));
        System.assertEquals(null, DataUpdateReviewController.coerceTableValue(Schema.DisplayType.DOUBLE, ''));
        System.assertEquals(7, DataUpdateReviewController.coerceTableValue(Schema.DisplayType.INTEGER, '7.0'));
        System.assertEquals(Datetime.newInstanceGmt(2026, 8, 2, 12, 0, 0),
            DataUpdateReviewController.coerceTableValue(Schema.DisplayType.DATETIME, '2026-08-02'));
        System.assertEquals(Date.newInstance(2026, 8, 2), DataUpdateReviewController.coerceTableValue(Schema.DisplayType.DATE, '2026-08-02'));
    }

    // ─── Status guards (stale panel) / correction type checks ───────────────

    private static String transitionError(Id requestId, String action) {
        try {
            if (action == 'hold') DataUpdateReviewController.holdRequest(requestId, 'r');
            else if (action == 'resume') DataUpdateReviewController.resumeRequest(requestId);
            else if (action == 'ignore') DataUpdateReviewController.ignoreRequest(requestId, 'Duplicate', null);
            else DataUpdateReviewController.reopenRequest(requestId);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    @IsTest
    static void statusChanges_RefusedForTheWrongCurrentStatus() {
        String U = uniq();
        Contact a = createTestContact('Guard' + U, 'Test');
        Data_Update_Request__c applied = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"x@example.com"}');
        update new Data_Update_Request__c(
            Id = applied.Id, Status__c = 'Applied', Final_Action__c = 'Applied', Closed_Reason__c = 'Applied'
        );
        Data_Update_Request__c open = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"y@example.com"}');

        Test.startTest();
        for (String action : new List<String>{ 'hold', 'resume', 'ignore' }) {
            System.assertEquals('TICKET_ALREADY_CLOSED', transitionError(applied.Id, action), action);
        }
        System.assertEquals('TICKET_STILL_OPEN', transitionError(open.Id, 'reopen'));
        Test.stopTest();

        Data_Update_Request__c stillApplied = [SELECT Status__c, Final_Action__c FROM Data_Update_Request__c WHERE Id = :applied.Id];
        System.assertEquals('Applied', stillApplied.Status__c);
        System.assertEquals('Applied', stillApplied.Final_Action__c, 'audit trail is not rewritten');
        System.assertEquals('New', [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :open.Id].Status__c);
    }

    @IsTest
    static void correctProposedValue_Email_StoredLowercase() {
        String U = uniq();
        Contact a = createTestContact('LowMail' + U, 'Test');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"ok' + U + '@example.com"}');

        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(t.Id, 'Alternative_Email_1__c', 'New.Mail' + U + '@Example.CA');
        Test.stopTest();

        System.assert(result.success, result.errorMessage);
        System.assertEquals(('new.mail' + U + '@example.ca').toLowerCase(), result.newValue);
    }

    @IsTest
    static void correctProposedValue_InvalidEmail_RefusedBeforeApply() {
        String U = uniq();
        Contact a = createTestContact('BadMail' + U, 'Test');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"ok' + U + '@example.com"}');

        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(t.Id, 'Alternative_Email_1__c', 'not-an-email');
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('INVALID_EMAIL', result.errorMessage);
        System.assert([SELECT Proposed_Values_JSON__c FROM Data_Update_Request__c WHERE Id = :t.Id].Proposed_Values_JSON__c
            .contains('ok' + U + '@example.com'), 'the stored value is untouched');
        System.assertEquals(0, [SELECT COUNT() FROM Data_Update_Log__c WHERE Request__c = :t.Id AND Action_Type__c = 'CORRECTED']);
    }

    // ─── Coverage: date-less history previews, Datetime tables, rollback guards ──

    // User without Modify All Data, without Edit Tasks (so no delete on the Task history rows)
    // and without the Data Update Center permission set: delete DML on someone else's row fails for them.
    private static User lowPrivUser() {
        User usr;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE UserLicense.Name = 'Salesforce'
                         AND PermissionsModifyAllData = false AND PermissionsEditTask = false LIMIT 1];
            String U = uniq();
            usr = new User(
                ProfileId = p.Id,
                Username = 'dulow' + U + '@example.com.test',
                Email = 'dulow' + U + '@example.com',
                LastName = 'DataUpdateLow', Alias = 'dulo',
                TimeZoneSidKey = 'America/Toronto', LocaleSidKey = 'fr_CA',
                EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
            );
            insert usr;
        }
        return usr;
    }

    private static Data_Update_Log__c newApplyLog(Data_Update_Request__c t, String decisionsJson) {
        return new Data_Update_Log__c(
            Request__c = t.Id, Action_Type__c = 'APPLY_COMPLETED',
            Target_Object_API_Name__c = Id.valueOf(t.Target_Record_Id__c).getSObjectType().getDescribe().getName(),
            Target_Record_Id__c = t.Target_Record_Id__c,
            Before_Snapshot_JSON__c = '{}', Field_Decisions_JSON__c = decisionsJson
        );
    }

    @IsTest
    static void getComparisonData_HistoryFieldsWithoutDateField_ShowNoDate() {
        User usr = dataUpdateUser();
        Contact e = createTestContact('NoDate' + uniq(), 'Test');
        insert newAttendanceRow(e.Id, 12, Date.newInstance(2026, 8, 1));
        Data_Update_Request__c t = createRequestFor(e.Id, 'Fake_NoDate_Form', JSON.serialize(new Map<String, String>{
            HIST_ONLY_KEY => '42',
            'Phone' => '514-555-0142'
        }));
        DataUpdateFormConfigService.testFormMdt = (Data_Update_Form__mdt) JSON.deserialize(
            '{"DeveloperName":"Fake_NoDate_Form","MasterLabel":"Fake","Target_Object_API_Name__c":"Contact",'
            + '"Identity_Field_1_API_Name__c":"Name","Identity_Field_1_Comparison__c":"Exact",'
            + '"Subject_Template__c":"{RecordName}","Is_Active__c":true}',
            Data_Update_Form__mdt.class);
        DataUpdateFormConfigService.testFieldMdts = (List<Data_Update_Form_Field__mdt>) JSON.deserialize(
            '[{"Field_API_Name__c":"' + HIST_ONLY_KEY + '","Label_FR__c":"A","Label_EN__c":"A",'
            + '"Display_Order__c":1,"Input_Type__c":"Number","History_Mode__c":"History_Only","Is_Active__c":true,'
            + '"History_Target_Object_API_Name__c":"Task","History_Target_Value_Field_API_Name__c":"CallDurationInSeconds",'
            + '"History_Target_Account_Field_API_Name__c":"WhoId"},'
            + '{"Field_API_Name__c":"Phone","Label_FR__c":"T","Label_EN__c":"T","Display_Order__c":2,'
            + '"Input_Type__c":"Phone","History_Mode__c":"Historize","Is_Active__c":true,'
            + '"History_Target_Object_API_Name__c":"Task","History_Target_Value_Field_API_Name__c":"CallDurationInSeconds",'
            + '"History_Target_Account_Field_API_Name__c":"WhoId"}]',
            List<Data_Update_Form_Field__mdt>.class);

        DataUpdateWrapper.ComparisonData comparison;
        Test.startTest();
        System.runAs(usr) {
            comparison = DataUpdateReviewController.getComparisonData(t.Id);
        }
        Test.stopTest();

        System.assert(comparison.success, comparison.errorMessage);
        Map<String, DataUpdateWrapper.ComparisonField> byKey = new Map<String, DataUpdateWrapper.ComparisonField>();
        for (DataUpdateWrapper.ComparisonField f : comparison.fields) byKey.put(f.fieldApiName, f);
        System.assertEquals('', byKey.get(HIST_ONLY_KEY).historyDate, 'No date field mapped → no date shown');
        System.assertEquals('', byKey.get(HIST_ONLY_KEY).currentValueDate);
        System.assertEquals('12', byKey.get(HIST_ONLY_KEY).currentValue);
        System.assertEquals(true, byKey.get('Phone').isHistorize);
        System.assertEquals('', byKey.get('Phone').historyDate);
        System.assertEquals('12', byKey.get('Phone').historyLastValue);
        System.assertEquals('', byKey.get('Phone').historyLastDate);
    }

    @IsTest
    static void buildComparisonTable_DatetimeDateAndUnconfiguredColumns() {
        User usr = dataUpdateUser();
        Contact a = createTestContact('TableDt' + uniq(), 'Test');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{}');
        insert new List<Data_Update_Log__c>{
            new Data_Update_Log__c(Request__c = t.Id, Action_Type__c = 'CORRECTED', Target_Object_API_Name__c = 'Contact', Before_Snapshot_JSON__c = '{}',
                                   Target_Record_Id__c = a.Id, Performed_Date__c = Datetime.newInstanceGmt(2026, 8, 2, 12, 0, 0)),
            new Data_Update_Log__c(Request__c = t.Id, Action_Type__c = 'CORRECTED', Target_Object_API_Name__c = 'Contact', Before_Snapshot_JSON__c = '{}',
                                   Target_Record_Id__c = a.Id)
        };
        DataUpdateFormConfigService.FormFieldConfig tc = new DataUpdateFormConfigService.FormFieldConfig();
        tc.fieldApiName = 'Data_Update_Log__c#table';
        tc.historyMode = 'History_Table';
        tc.historyTargetObjectApiName = 'Data_Update_Log__c';
        tc.historyTargetDateFieldApiName = 'Performed_Date__c';
        tc.historyTargetAccountFieldApiName = 'Request__c';

        DataUpdateWrapper.ComparisonTable withDate;
        DataUpdateWrapper.ComparisonTable noDate;
        Test.startTest();
        System.runAs(usr) {
            // Columns aren't configured on tc, so each one is labelled from the schema (or kept raw).
            withDate = DataUpdateReviewController.buildComparisonTable(tc, DataUpdateReviewController.parseTableValue(
                '{"cols":["Performed_Date__c","Action_Type__c","Unknown_Col__c"],'
                + '"rows":[["2026-08-02","APPLY_COMPLETED","x"],["2026-08-03","CORRECTED","y"]]}'), t.Id);
            noDate = DataUpdateReviewController.buildComparisonTable(tc, DataUpdateReviewController.parseTableValue(
                '{"cols":["Action_Type__c"],"rows":[["CORRECTED"]]}'), t.Id);
        }
        Test.stopTest();

        System.assertEquals(3, withDate.columns.size());
        System.assertEquals(true, withDate.columns[0].isDate);
        System.assertEquals('Unknown_Col__c', withDate.columns[2].labelFr, 'An unknown column keeps its API name');
        System.assertEquals('Text', withDate.columns[2].kind);
        System.assertEquals(1, withDate.duplicateCount, 'A Datetime date matches its yyyy-MM-dd day');
        System.assertEquals(true, withDate.rows[0].isDuplicate);
        System.assertEquals(false, withDate.rows[1].isDuplicate);

        System.assertEquals(0, noDate.duplicateCount, 'Without a date column nothing can match');
        System.assertEquals('', noDate.rows[0].dateValue);
    }

    @IsTest
    static void historyTable_RollbackRestoresDatetimeAndFailsCleanly() {
        User usr = dataUpdateUser();
        Contact e = createTestContact('TableDt' + uniq(), 'Test');
        Data_Update_Request__c t = createRequestFor(e.Id, 'Fake_Table_Form', '{}');
        Data_Update_Request__c other = createRequestFor(e.Id, 'Fake_Table_Form', '{}');
        Data_Update_Log__c overwritten = new Data_Update_Log__c(
            Request__c = other.Id, Action_Type__c = 'CORRECTED', Target_Object_API_Name__c = 'Contact',
            Target_Record_Id__c = e.Id, Before_Snapshot_JSON__c = '{}', Performed_Date__c = Datetime.newInstanceGmt(2026, 9, 9, 9, 0, 0));
        insert overwritten;
        // A table whose history object has a DateTime date: the rollback restores it as a Datetime.
        Data_Update_Log__c applyLog = newApplyLog(t, JSON.serialize(new Map<String, Object>{
            HT_KEY => new Map<String, Object>{
                'historyObject'    => 'Data_Update_Log__c',
                'tableInserted'    => new List<Object>(),
                'tableOverwritten' => new List<Object>{ new Map<String, Object>{
                    'id'     => overwritten.Id,
                    'before' => new Map<String, Object>{ 'Performed_Date__c' => '2026-08-02 12:00:00', 'Gone__c' => 'x' }
                } },
                'diff' => new Map<String, Object>{ 'after' => '1 line' }
            }
        }));
        insert applyLog;
        useHistoryTableFakeForm();

        DataUpdateWrapper.ApplyResult failed;
        DataUpdateWrapper.ApplyResult rolled;
        Test.startTest();
        System.runAs(usr) {
            DataUpdateReviewController.TEST_FORCE_ROLLBACK_DML_ERROR = true;
            failed = DataUpdateReviewController.rollbackChange(applyLog.Id, HT_KEY);
            DataUpdateReviewController.TEST_FORCE_ROLLBACK_DML_ERROR = false;
            rolled = DataUpdateReviewController.rollbackChange(applyLog.Id, HT_KEY);
        }
        Test.stopTest();

        System.assertEquals(false, failed.success);
        System.assertEquals('GENERIC_ERROR', failed.errorMessage);
        System.assert(rolled.success, 'Rollback should succeed: ' + rolled.errorMessage);
        System.assertEquals(1, rolled.updatedFieldCount);
        System.assertEquals(Datetime.newInstanceGmt(2026, 8, 2, 12, 0, 0),
            [SELECT Performed_Date__c FROM Data_Update_Log__c WHERE Id = :overwritten.Id].Performed_Date__c);
        Contact relocked = (Contact) Database.query('SELECT Data_Update_Locked__c, Data_Update_Locked_Date__c FROM Contact WHERE Id = \'' + e.Id + '\'');
        System.assertEquals(true, relocked.get('Data_Update_Locked__c'));
        System.assertNotEquals(null, relocked.get('Data_Update_Locked_Date__c'), 'Rollback relocks with a date');
        System.assertEquals('Reopened', [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c);
    }

    @IsTest
    static void historyRollbacks_UnusableHistoryObject_ReturnGenericError() {
        User usr = dataUpdateUser();
        User low = lowPrivUser();
        Contact e = createTestContact('Guard' + uniq(), 'Test');
        Data_Update_Request__c tableReq = createRequestFor(e.Id, 'Fake_Table_Form', '{}');
        Data_Update_Request__c histReq = createRequestFor(e.Id, 'Fake_HistOnly_Form', '{}');
        Data_Update_Log__c tableLog = newApplyLog(tableReq, JSON.serialize(new Map<String, Object>{
            HT_KEY => new Map<String, Object>{ 'tableInserted' => new List<Object>() }
        }));
        Data_Update_Log__c histLog = newApplyLog(histReq, JSON.serialize(new Map<String, Object>{
            HIST_ONLY_KEY => new Map<String, Object>{ 'diff' => new Map<String, Object>{ 'after' => '5' } }
        }));
        insert new List<Data_Update_Log__c>{ tableLog, histLog };

        DataUpdateWrapper.ApplyResult noObject;
        DataUpdateWrapper.ApplyResult notDeletable;
        Test.startTest();
        useHistoryTableFakeForm();
        System.runAs(usr) {
            noObject = DataUpdateReviewController.rollbackChange(tableLog.Id, HT_KEY);
        }
        useHistoryOnlyFakeForm();
        System.runAs(low) {
            notDeletable = DataUpdateReviewController.rollbackChange(histLog.Id, HIST_ONLY_KEY);
        }
        Test.stopTest();

        System.assertEquals(false, noObject.success, 'A table decision without its history object cannot be undone');
        System.assertEquals('GENERIC_ERROR', noObject.errorMessage);
        System.assertEquals(false, notDeletable.success, 'A user who cannot delete history rows cannot roll back');
        System.assertEquals('GENERIC_ERROR', notDeletable.errorMessage);
    }

    @IsTest
    static void reopenRequest_RelockFails_StatusIsRolledBack() {
        User usr = dataUpdateUser();
        Contact a = createTestContact('Gone' + uniq(), 'Test');
        Data_Update_Request__c t = createRequestFor(a.Id, 'Fake_Lock_Form', '{"Phone":"1"}');
        update new Data_Update_Request__c(Id = t.Id, Status__c = 'Applied', Final_Action__c = 'Applied', Closed_Reason__c = 'Applied');
        delete a;
        useLockNoDateFakeForm();

        Exception caught;
        Test.startTest();
        System.runAs(usr) {
            try {
                DataUpdateReviewController.reopenRequest(t.Id);
            } catch (Exception ex) {
                caught = ex;
            }
        }
        Test.stopTest();

        System.assertNotEquals(null, caught, 'Relocking a deleted record must fail the reopen');
        System.assertEquals('Applied', [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c,
            'Status and lock succeed or fail together');
    }

    @IsTest
    static void presence_DeleteFailures_AreSwallowed() {
        User low = lowPrivUser();
        Contact a = createTestContact('Presence' + uniq(), 'Test');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"p@example.com"}');
        Data_Update_Request__c other = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"q@example.com"}');
        // Rows about the low user but owned by the admin: the low user can't delete them.
        Data_Update_Presence__c stale = new Data_Update_Presence__c(Key__c = 'stale' + uniq().left(30), Request__c = other.Id,
                                                                    User__c = low.Id, Last_Seen__c = Datetime.now().addDays(-2));
        Data_Update_Presence__c own = new Data_Update_Presence__c(Key__c = String.valueOf(other.Id) + String.valueOf(low.Id),
                                                                  Request__c = other.Id, User__c = low.Id, Last_Seen__c = Datetime.now());
        insert new List<Data_Update_Presence__c>{ stale, own };

        List<String> others;
        Test.startTest();
        System.runAs(low) {
            others = DataUpdateReviewController.heartbeat(t.Id);
            DataUpdateReviewController.leaveRequest(other.Id);
        }
        Test.stopTest();

        System.assert(others.isEmpty(), 'A presence failure never breaks the panel');
        System.assertEquals(2, [SELECT COUNT() FROM Data_Update_Presence__c WHERE Id IN :new List<Id>{ stale.Id, own.Id }],
            'Rows the user cannot delete stay in place');
    }

    @IsTest
    static void getRequests_BadTargetIdAndBadTableJson_AreSkipped() {
        String U = uniq();
        DataUpdateWrapper.RequestListResult result;
        Test.startTest();
        System.runAs(dataUpdateUser()) {
            insert new Data_Update_Request__c(
                Target_Object_API_Name__c = 'Contact',
                Target_Record_Id__c = 'not-an-id',
                Update_Form_DeveloperName__c = FORM_NAME,
                Status__c = 'New',
                Subject__c = 'BadTargetMarker' + U,
                Proposed_Values_JSON__c = '{"Alternative_Email_1__c":"x@example.com"}'
            );
            result = DataUpdateReviewController.getRequests('All', 'All', 'BadTargetMarker' + U, 50, 0);
        }
        Test.stopTest();

        System.assert(result.success, result.errorMessage);
        System.assertEquals(1, result.requests.size(), 'A ticket with an unreadable target still lists');
        System.assertEquals(0, DataUpdateReviewController.countTableRows('{not json'));
    }

    // ─── Historique: status events, not-applied note, unlockable count ─────

    @IsTest
    static void parseStatusEvents_LegacyAndNewFormats() {
        String notes = String.join(new List<String>{
            '[HIST:Ignored|||Other|||Line one\\nLine two|||2026-10-15 14:30:00|||Jane Staff]',
            '[HIST:Reopened||||||Rollback: 1 field(s) restored|||2026-10-14 10:00:00|||Jane Staff]',
            'free text that is not a history entry',
            '[HIST:On Hold|||only three parts]',
            '[HIST:In Review||||||not-a-date|||Jane Staff]',
            '[HIST:On Hold||||||Waiting|||2026-10-10]',
            '[HIST:New|||||||||2026-10-10]'
        }, '\n');

        Test.startTest();
        List<DataUpdateWrapper.AuditLogEntry> events = DataUpdateReviewController.parseStatusEvents(notes);
        Test.stopTest();

        System.assertEquals(3, events.size(), 'Rollback, malformed and bad-date lines are skipped');
        DataUpdateWrapper.AuditLogEntry ignored = events[0];
        System.assertEquals('STATUS', ignored.actionType);
        System.assertEquals('Ignored', ignored.statusValue);
        System.assertEquals('Other', ignored.statusReason);
        System.assertEquals('Line one\nLine two', ignored.statusNotes);
        System.assertEquals('Jane Staff', ignored.performedByName);
        System.assertEquals(false, ignored.dateOnly);
        System.assertEquals(Datetime.newInstanceGmt(2026, 10, 15, 14, 30, 0), ignored.performedDate);

        DataUpdateWrapper.AuditLogEntry hold = events[1];
        System.assertEquals('On Hold', hold.statusValue);
        System.assertEquals('', hold.performedByName, 'Old entries have no user');
        System.assertEquals(true, hold.dateOnly);
        System.assert(hold.performedDate > events[2].performedDate, 'Same-day legacy entries keep their chain order');
        System.assertEquals(0, DataUpdateReviewController.parseStatusEvents(null).size());
    }

    @IsTest
    static void getAuditLog_IncludesStatusEntriesNewestFirst() {
        String U = uniq();
        Contact a = createTestContact('Statut' + U, 'Test');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"Alternative_Email_1__c":"x@example.com"}');
        update new Data_Update_Request__c(Id = t.Id, Notes__c = '[HIST:On Hold||||||Old note|||2020-01-01]');
        DataUpdateReviewController.correctProposedValue(t.Id, 'Alternative_Email_1__c', 'y' + U + '@example.com');

        Test.startTest();
        DataUpdateWrapper.AuditLogResult res = DataUpdateReviewController.getAuditLog(t.Id);
        Test.stopTest();

        System.assert(res.success);
        DataUpdateWrapper.AuditLogEntry oldest = res.entries[res.entries.size() - 1];
        System.assertEquals('STATUS', oldest.actionType, 'Newest first: the 2020 status entry goes last');
        System.assertEquals('Old note', oldest.statusNotes);
        System.assertEquals('CORRECTED', res.entries[0].actionType);
    }

    private static List<DataUpdateWrapper.AuditNotApplied> appliedNotApplied(Id requestId) {
        DataUpdateWrapper.AuditLogResult res = DataUpdateReviewController.getAuditLog(requestId);
        for (DataUpdateWrapper.AuditLogEntry e : res.entries) {
            if (e.actionType == 'APPLY_COMPLETED') return e.notApplied;
        }
        return null;
    }

    @IsTest
    static void applySelectedUpdates_RecordsUncheckedValuesAsNotApplied() {
        String U = uniq();
        // Same mobile as Salesforce (5140000000) -> SAME_AS_SF; a different one -> UNCHECKED.
        Contact same = createTestContact('Pareil' + U, 'Anne');
        Data_Update_Request__c tSame = createReviewRequest(same.Id, JSON.serialize(new Map<String, String>{
            'Alternative_Email_1__c' => 'a' + U + '@example.com', 'MobilePhone' => '5140000000'
        }));
        Contact diff = createTestContact('Autre' + U, 'Paul');
        Data_Update_Request__c tDiff = createReviewRequest(diff.Id, JSON.serialize(new Map<String, String>{
            'Alternative_Email_1__c' => 'b' + U + '@example.com', 'MobilePhone' => '5147778888'
        }));
        Contact all = createTestContact('Tout' + U, 'Luc');
        Data_Update_Request__c tAll = createReviewRequest(all.Id, JSON.serialize(new Map<String, String>{
            'Alternative_Email_1__c' => 'c' + U + '@example.com'
        }));

        Test.startTest();
        System.assert(DataUpdateReviewController.applySelectedUpdates(tSame.Id, new List<String>{ 'Alternative_Email_1__c' }).success);
        System.assert(DataUpdateReviewController.applySelectedUpdates(tDiff.Id, new List<String>{ 'Alternative_Email_1__c' }).success);
        System.assert(DataUpdateReviewController.applySelectedUpdates(tAll.Id, new List<String>{ 'Alternative_Email_1__c' }).success);
        Test.stopTest();

        List<DataUpdateWrapper.AuditNotApplied> sameNotes = appliedNotApplied(tSame.Id);
        System.assertEquals(1, sameNotes.size());
        System.assertEquals('5140000000', sameNotes[0].value);
        System.assertEquals('SAME_AS_SF', sameNotes[0].reason);

        List<DataUpdateWrapper.AuditNotApplied> diffNotes = appliedNotApplied(tDiff.Id);
        System.assertEquals(1, diffNotes.size());
        System.assertEquals('UNCHECKED', diffNotes[0].reason);

        System.assertEquals(0, appliedNotApplied(tAll.Id).size(), 'Nothing left out = no note');
    }

    @IsTest
    static void getLockedRecords_UnlockableCountSkipsOpenTickets() {
        String U = uniq();
        Contact withTicket = createTestContact('Ouvert' + U, 'Chantal');
        Contact free = createTestContact('Libre' + U, 'Serge');
        for (Contact a : new List<Contact>{ withTicket, free }) {
            a.put('Data_Update_Locked__c', true);
            a.put('Data_Update_Locked_Date__c', Datetime.now());
        }
        update new List<Contact>{ withTicket, free };
        createReviewRequest(withTicket.Id, '{"Alternative_Email_1__c":"x@example.com"}');

        Test.startTest();
        DataUpdateWrapper.LockedRecordListResult result = DataUpdateReviewController.getLockedRecords(FORM_NAME, 25, 0, null);
        Test.stopTest();

        System.assert(result.success);
        System.assertEquals(2, result.totalCount);
        System.assertEquals(1, result.unlockableCount, 'A record with an open ticket cannot be unlocked');
    }

    // ─── "Save in" / "Preferred" (email and phone rows) ─────────────────────

    // In-memory Contact form with email, phone and text questions.
    private static void useSaveOptionsFakeForm() {
        DataUpdateFormConfigService.testFormMdt = (Data_Update_Form__mdt) JSON.deserialize(
            '{"DeveloperName":"Fake_Save_Form","MasterLabel":"Fake","Target_Object_API_Name__c":"Contact",'
            + '"Identity_Field_1_API_Name__c":"Name","Identity_Field_1_Comparison__c":"Exact",'
            + '"Subject_Template__c":"{RecordName}","Is_Active__c":true}',
            Data_Update_Form__mdt.class);
        DataUpdateFormConfigService.testFieldMdts = (List<Data_Update_Form_Field__mdt>) JSON.deserialize(
            '[{"Field_API_Name__c":"FirstName","Label_FR__c":"P","Label_EN__c":"F","Display_Order__c":1,'
            + '"Input_Type__c":"Text","History_Mode__c":"Replace","Is_Active__c":true},'
            + '{"Field_API_Name__c":"HomePhone","Label_FR__c":"T","Label_EN__c":"T","Display_Order__c":2,'
            + '"Input_Type__c":"Phone","History_Mode__c":"Replace","Is_Active__c":true},'
            + '{"Field_API_Name__c":"Email","Label_FR__c":"C","Label_EN__c":"E","Display_Order__c":3,'
            + '"Input_Type__c":"Email","History_Mode__c":"Replace","Is_Active__c":true},'
            + '{"Field_API_Name__c":"hed__WorkEmail__c","Label_FR__c":"CT","Label_EN__c":"WE","Display_Order__c":4,'
            + '"Input_Type__c":"Email","History_Mode__c":"Replace","Is_Active__c":true}]',
            List<Data_Update_Form_Field__mdt>.class);
    }

    private static Contact queryPhones(Id recId) {
        return (Contact) Database.query('SELECT Id, HomePhone, MobilePhone, OtherPhone, hed__PreferredPhone__c FROM Contact WHERE Id = :recId LIMIT 1');
    }

    @IsTest
    static void saveOptions_ComparisonOffersPlacesWithoutPhoneOrSavedEmail() {
        useSaveOptionsFakeForm();
        String U = uniq();
        Contact c = createPreferredEmailContact('Places' + U, 'p' + U + '@example.com');
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{
            'HomePhone' => '5145550101', 'Email' => 'n' + U + '@example.com', 'FirstName' => 'Autre' }));

        DataUpdateWrapper.ComparisonData cmp = DataUpdateReviewController.getComparisonData(t.Id);

        Map<String, String> kinds = new Map<String, String>();
        for (DataUpdateWrapper.ComparisonField cf : cmp.fields) kinds.put(cf.fieldApiName, cf.saveKind);
        System.assertEquals('PHONE', kinds.get('HomePhone'));
        System.assertEquals('EMAIL', kinds.get('Email'));
        System.assertEquals(null, kinds.get('FirstName'), 'Text rows never move');
        Map<String, DataUpdateWrapper.GroupSlotGroup> byKind = new Map<String, DataUpdateWrapper.GroupSlotGroup>();
        for (DataUpdateWrapper.GroupSlotGroup g : cmp.saveOptions) byKind.put(g.kind, g);
        System.assert(byKind.containsKey('PHONE') && byKind.containsKey('EMAIL'));
        Boolean hasPreference = false;
        for (DataUpdateWrapper.GroupSlot slot : byKind.get('PHONE').slots) {
            System.assertNotEquals('Phone', slot.apiName, 'EDA fills Phone itself');
            if (slot.apiName == 'HomePhone') hasPreference = slot.preference != null;
        }
        System.assert(hasPreference, 'Home Phone can be the preferred phone');
        for (DataUpdateWrapper.GroupSlot slot : byKind.get('EMAIL').slots) {
            System.assertNotEquals('Email', slot.apiName, 'Email is saved in the preferred email field');
        }
        System.assertEquals('hed__AlternateEmail__c', byKind.get('EMAIL').preferredField);
    }

    @IsTest
    static void saveOptions_BusinessAccount_NoPreferences() {
        Account a = createEglise('Places ' + uniq());
        List<DataUpdateWrapper.GroupSlotGroup> groups = DataUpdateReviewController.buildSaveOptions(a.Id,
            Account.SObjectType.getDescribe().fields.getMap(), null);
        for (DataUpdateWrapper.GroupSlotGroup g : groups) {
            System.assertEquals(null, g.preferredField);
            for (DataUpdateWrapper.GroupSlot slot : g.slots) System.assertEquals(null, slot.preference);
        }
    }

    @IsTest
    static void applyWithOptions_PhoneSavedInOtherField() {
        useSaveOptionsFakeForm();
        String U = uniq();
        Contact c = createTestContact('Autre' + U, 'Eda');
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{ 'HomePhone' => '5145550102' }));

        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdatesWithOptions(t.Id,
            new List<String>{ 'HomePhone' }, null, '{"overrides":{"HomePhone":"OtherPhone"},"preferred":null}');

        System.assert(applied.success, applied.errorMessage);
        Contact after = queryPhones(c.Id);
        System.assertEquals('5145550102', after.OtherPhone);
        System.assertEquals(null, after.HomePhone);
    }

    @IsTest
    static void applyWithOptions_PreferredPhone_SetAndRolledBack() {
        useSaveOptionsFakeForm();
        String U = uniq();
        Contact c = createTestContact('Pref' + U, 'Eda');
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{ 'HomePhone' => '5145550103' }));

        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdatesWithOptions(t.Id,
            new List<String>{ 'HomePhone' }, null, '{"preferred":{"PHONE":"HomePhone"}}');

        System.assert(applied.success, applied.errorMessage);
        System.assertEquals('Home Phone', queryPhones(c.Id).hed__PreferredPhone__c);
        Boolean shown = false;
        for (DataUpdateWrapper.AuditLogEntry e : DataUpdateReviewController.getAuditLog(t.Id).entries) {
            for (DataUpdateWrapper.AuditPreferredChange pc : e.preferredChanges) {
                if (pc.kind == 'PHONE' && pc.afterValue == 'Home Phone') shown = true;
            }
        }
        System.assert(shown, 'Historique shows the preferred phone change');

        Id applyLogId = findLogId(t.Id, 'APPLY_COMPLETED');
        Test.setCreatedDate(applyLogId, DateTime.now().addMinutes(-5));
        Test.startTest();
        DataUpdateWrapper.ApplyResult rolled = DataUpdateReviewController.rollbackChange(applyLogId, 'HomePhone');
        Test.stopTest();
        System.assert(rolled.success, rolled.errorMessage);
        Contact restored = queryPhones(c.Id);
        System.assertEquals(null, restored.HomePhone);
        System.assertNotEquals('Home Phone', restored.hed__PreferredPhone__c, 'The preference leaves the emptied field');
    }

    @IsTest
    static void applyWithOptions_PreferredEmail_OtherFieldBecomesMain() {
        useSaveOptionsFakeForm();
        String U = uniq();
        Contact c = createPreferredEmailContact('Main' + U, 'old' + U + '@example.com');
        String answer = 'work' + U + '@example.com';
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{ 'hed__WorkEmail__c' => answer }));

        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdatesWithOptions(t.Id,
            new List<String>{ 'hed__WorkEmail__c' }, null, '{"overrides":{},"preferred":{"EMAIL":"hed__WorkEmail__c"}}');

        System.assert(applied.success, applied.errorMessage);
        Contact after = (Contact) Database.query('SELECT Email, hed__Preferred_Email__c FROM Contact WHERE Id = \'' + c.Id + '\'');
        System.assertEquals('Work Email', after.get('hed__Preferred_Email__c'));
        System.assertEquals(answer, after.Email);
    }

    @IsTest
    static void applyWithOptions_InvalidChoices_Refused() {
        useSaveOptionsFakeForm();
        String U = uniq();
        Contact c = createTestContact('Refus' + U, 'Eda');
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{
            'FirstName' => 'Autre', 'HomePhone' => '5145550104' }));
        List<String> rows = new List<String>{ 'FirstName', 'HomePhone' };

        System.assertEquals('GENERIC_ERROR', DataUpdateReviewController.applySelectedUpdatesWithOptions(t.Id, rows, null, '{bad').errorMessage);
        System.assertEquals('INVALID_SAVE_CHOICE', DataUpdateReviewController.applySelectedUpdatesWithOptions(t.Id, rows, null,
            '{"overrides":{"FirstName":"LastName"}}').errorMessage, 'A text value never moves to another field');
        System.assertEquals('INVALID_SAVE_CHOICE', DataUpdateReviewController.applySelectedUpdatesWithOptions(t.Id, rows, null,
            '{"preferred":{"PHONE":"FirstName"}}').errorMessage, 'Only an email / phone field can be preferred');
        System.assertEquals('INVALID_SAVE_CHOICE', DataUpdateReviewController.applySelectedUpdatesWithOptions(t.Id, rows, null,
            '{"preferred":{"FAX":"HomePhone"}}').errorMessage);
        System.assertEquals('Eda', [SELECT FirstName FROM Contact WHERE Id = :c.Id].FirstName, 'Nothing applied');
        System.assertEquals('New', [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c,
            'A choice to fix never marks the ticket as Error');
        System.assertEquals(0, [SELECT COUNT() FROM Data_Update_Log__c WHERE Request__c = :t.Id AND Action_Type__c = 'APPLY_ERROR']);

        System.assert(DataUpdateReviewController.stringMap('x').isEmpty());
        System.assertEquals(new Map<String, String>{ 'a' => '1' },
            DataUpdateReviewController.stringMap(new Map<String, Object>{ 'a' => 1, 'b' => null }));
        DataUpdateWrapper.ApplyResult ok = DataUpdateReviewController.applySelectedUpdatesWithOptions(t.Id, rows, null, null);
        System.assert(ok.success, ok.errorMessage);
    }

    // Contact whose main email is the Work Email field.
    private static Contact createWorkEmailContact(String lastName, String email) {
        Contact c = createTestContact(lastName, 'Eda');
        c.put('hed__WorkEmail__c', email);
        c.put('hed__Preferred_Email__c', 'Work Email');
        c.put('Email', email);
        update c;
        return c;
    }

    private static Integer preferredChangeCount(Id requestId) {
        Integer n = 0;
        for (DataUpdateWrapper.AuditLogEntry e : DataUpdateReviewController.getAuditLog(requestId).entries) n += e.preferredChanges.size();
        return n;
    }

    @IsTest
    static void applyWithOptions_StarOnRowLeftOut_IgnoredNotError() {
        useSaveOptionsFakeForm();
        String U = uniq();
        Contact c = createWorkEmailContact('Conflit' + U, 'old' + U + '@example.com');
        String mainAnswer = 'main' + U + '@example.com';
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{
            'Email' => mainAnswer, 'hed__WorkEmail__c' => 'other' + U + '@example.com' }));

        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdatesWithOptions(t.Id,
            new List<String>{ 'Email', 'hed__WorkEmail__c' }, null, '{"preferred":{"EMAIL":"hed__WorkEmail__c"}}');

        System.assert(applied.success, applied.errorMessage);
        Contact after = (Contact) Database.query('SELECT hed__WorkEmail__c, hed__Preferred_Email__c FROM Contact WHERE Id = \'' + c.Id + '\'');
        System.assertEquals(mainAnswer, after.get('hed__WorkEmail__c'), 'Email wins the conflict');
        System.assertEquals('Work Email', after.get('hed__Preferred_Email__c'));
        System.assertEquals('Applied', [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c);
    }

    @IsTest
    static void applyWithOptions_StarOnEmail_SameValueAsPreferredField() {
        useSaveOptionsFakeForm();
        String U = uniq();
        Contact c = createWorkEmailContact('Pareil' + U, 'old' + U + '@example.com');
        String answer = 'same' + U + '@example.com';
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{
            'Email' => answer, 'hed__WorkEmail__c' => answer }));

        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdatesWithOptions(t.Id,
            new List<String>{ 'Email', 'hed__WorkEmail__c' }, null, '{"preferred":{"EMAIL":"Email"}}');

        System.assert(applied.success, applied.errorMessage);
        System.assertEquals(answer, [SELECT Email FROM Contact WHERE Id = :c.Id].Email);
    }

    @IsTest
    static void rollbackAll_PreferenceNeverLeftOnEmptyField() {
        useSaveOptionsFakeForm();
        String U = uniq();
        Contact c = (Contact) insertResilient(new Contact(LastName = 'Vide' + U, FirstName = 'Eda'));
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{
            'Email' => 'a' + U + '@example.com', 'hed__WorkEmail__c' => 'w' + U + '@example.com' }));
        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdatesWithOptions(t.Id,
            new List<String>{ 'Email', 'hed__WorkEmail__c' }, null, '{"preferred":{"EMAIL":"hed__WorkEmail__c"}}');
        System.assert(applied.success, applied.errorMessage);
        System.assertEquals('Work Email', Database.query('SELECT hed__Preferred_Email__c FROM Contact WHERE Id = \'' + c.Id + '\'')[0].get('hed__Preferred_Email__c'));

        Id applyLogId = findLogId(t.Id, 'APPLY_COMPLETED');
        Test.setCreatedDate(applyLogId, DateTime.now().addMinutes(-5));
        Test.startTest();
        DataUpdateWrapper.ApplyResult rolled = DataUpdateReviewController.rollbackChanges(applyLogId,
            new List<String>{ 'hed__WorkEmail__c', 'hed__AlternateEmail__c' });
        Test.stopTest();

        System.assert(rolled.success, rolled.errorMessage);
        SObject after = Database.query('SELECT hed__WorkEmail__c, hed__AlternateEmail__c, hed__Preferred_Email__c FROM Contact WHERE Id = \'' + c.Id + '\'');
        System.assertEquals(null, after.get('hed__WorkEmail__c'));
        System.assertEquals(null, after.get('hed__AlternateEmail__c'));
        System.assert(String.isBlank((String) after.get('hed__Preferred_Email__c')), 'No preference on an empty field');
        System.assert(preferredChangeCount(t.Id) >= 2, 'Historique shows the preference the rollback put back');
    }

    @IsTest
    static void rollback_PreferenceChangedSince_KeptAsIs() {
        useSaveOptionsFakeForm();
        String U = uniq();
        Contact c = createTestContact('Depuis' + U, 'Eda');
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{ 'HomePhone' => '5145550105' }));
        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdatesWithOptions(t.Id,
            new List<String>{ 'HomePhone' }, null, '{"preferred":{"PHONE":"HomePhone"}}');
        System.assert(applied.success, applied.errorMessage);
        Contact changed = new Contact(Id = c.Id);
        changed.put('hed__PreferredPhone__c', 'Mobile Phone');
        update changed;

        Id applyLogId = findLogId(t.Id, 'APPLY_COMPLETED');
        Test.setCreatedDate(applyLogId, DateTime.now().addMinutes(-5));
        Test.startTest();
        DataUpdateWrapper.ApplyResult rolled = DataUpdateReviewController.rollbackChange(applyLogId, 'HomePhone');
        Test.stopTest();

        System.assert(rolled.success, rolled.errorMessage);
        System.assertEquals('Mobile Phone', queryPhones(c.Id).hed__PreferredPhone__c, 'A preference staff changed since stays');
    }

    @IsTest
    static void applyWithOptions_ExcludedPlace_Refused() {
        useSaveOptionsFakeForm();
        String U = uniq();
        Contact c = createTestContact('Exclu' + U, 'Eda');
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{ 'HomePhone' => '5145550106' }));

        System.assertEquals(false, DataUpdateReviewController.applySelectedUpdatesWithOptions(t.Id,
            new List<String>{ 'HomePhone' }, null, '{"overrides":{"HomePhone":"AssistantPhone"}}').success);
        for (DataUpdateWrapper.GroupSlotGroup g : DataUpdateReviewController.getComparisonData(t.Id).saveOptions) {
            for (DataUpdateWrapper.GroupSlot slot : g.slots) System.assertNotEquals('AssistantPhone', slot.apiName);
        }
    }

    // ─── EDA preferred phone ────────────────────────────────────────────────

    private static void usePhoneFakeForm() {
        DataUpdateFormConfigService.testFormMdt = (Data_Update_Form__mdt) JSON.deserialize(
            '{"DeveloperName":"Fake_Phone_Form","MasterLabel":"Fake","Target_Object_API_Name__c":"Contact",'
            + '"Identity_Field_1_API_Name__c":"Name","Identity_Field_1_Comparison__c":"Exact",'
            + '"Subject_Template__c":"{RecordName}","Is_Active__c":true}',
            Data_Update_Form__mdt.class);
        DataUpdateFormConfigService.testFieldMdts = (List<Data_Update_Form_Field__mdt>) JSON.deserialize(
            '[{"Field_API_Name__c":"Phone","Label_FR__c":"Tel","Label_EN__c":"Phone","Display_Order__c":1,'
            + '"Input_Type__c":"Phone","History_Mode__c":"Replace","Is_Active__c":true},'
            + '{"Field_API_Name__c":"HomePhone","Label_FR__c":"Maison","Label_EN__c":"Home","Display_Order__c":2,'
            + '"Input_Type__c":"Phone","History_Mode__c":"Replace","Is_Active__c":true}]',
            List<Data_Update_Form_Field__mdt>.class);
    }

    private static Contact createHomePhoneContact(String lastName, String phone) {
        Contact c = new Contact(LastName = lastName, HomePhone = phone);
        c.put('hed__PreferredPhone__c', 'Home Phone');
        return (Contact) insertResilient(c);
    }

    @IsTest
    static void applyPhone_NoPreference_SavedInMobileWithPreferenceAndRolledBack() {
        usePhoneFakeForm();
        String U = uniq();
        Contact c = (Contact) insertResilient(new Contact(LastName = 'SansTel' + U));
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{ 'Phone' => '5145550111' }));

        DataUpdateWrapper.ComparisonData cmp = DataUpdateReviewController.getComparisonData(t.Id);
        System.assertEquals('MobilePhone', cmp.fields[0].savedInFieldApiName, 'No preferred phone: saved in Mobile Phone');
        for (DataUpdateWrapper.GroupSlotGroup g : cmp.saveOptions) {
            for (DataUpdateWrapper.GroupSlot slot : g.slots) System.assertNotEquals('Phone', slot.apiName, 'EDA fills Phone itself');
        }

        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Phone' });
        System.assert(applied.success, applied.errorMessage);
        Contact after = queryPhones(c.Id);
        System.assertEquals('5145550111', after.MobilePhone);
        System.assertEquals('Mobile Phone', after.get('hed__PreferredPhone__c'), 'The preference is set with the field');
        System.assertEquals(1, preferredChangeCount(t.Id), 'Historique shows the preference set');

        Id applyLogId = findLogId(t.Id, 'APPLY_COMPLETED');
        Test.setCreatedDate(applyLogId, DateTime.now().addMinutes(-5));
        Test.startTest();
        DataUpdateWrapper.ApplyResult rolled = DataUpdateReviewController.rollbackChange(applyLogId, 'MobilePhone');
        Test.stopTest();
        System.assert(rolled.success, rolled.errorMessage);
        Contact restored = queryPhones(c.Id);
        System.assertEquals(null, restored.MobilePhone);
        System.assertEquals(null, restored.get('hed__PreferredPhone__c'), 'Rollback clears the preference with the field');
    }

    @IsTest
    static void applyPhone_PreferredHome_WritesHomePhone() {
        usePhoneFakeForm();
        String U = uniq();
        Contact c = createHomePhoneContact('Maison' + U, '5145550100');
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{ 'Phone' => '5145550122' }));
        System.assertEquals('HomePhone', DataUpdateReviewController.getComparisonData(t.Id).fields[0].savedInFieldApiName);
        System.assertEquals('HomePhone', DataUpdateReviewController.phoneSavedIn('Contact', c.Id, Contact.SObjectType.getDescribe().fields.getMap()));

        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Phone' });
        System.assert(applied.success, applied.errorMessage);
        Contact after = queryPhones(c.Id);
        System.assertEquals('5145550122', after.HomePhone, 'The new phone goes to the preferred phone field');
        System.assertEquals('Home Phone', after.get('hed__PreferredPhone__c'), 'Preference unchanged');
    }

    @IsTest
    static void applyPhone_PhoneAndPreferredBothAnswered_PhoneWinsOtherNoted() {
        usePhoneFakeForm();
        String U = uniq();
        Contact c = createHomePhoneContact('DoubleTel' + U, '5145550100');
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{
            'Phone' => '5145550133', 'HomePhone' => '5145550144' }));
        for (DataUpdateWrapper.ComparisonField cf : DataUpdateReviewController.getComparisonData(t.Id).fields) {
            System.assertEquals(true, cf.emailConflict, 'Both rows warn: only one main phone ' + cf.fieldApiName);
        }

        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Phone', 'HomePhone' });
        System.assert(applied.success, applied.errorMessage);
        System.assertEquals('5145550133', queryPhones(c.Id).HomePhone, 'Phone\'s answer takes the preferred field');
        System.assert(notAppliedReasons(t.Id).contains('PHONE_PREFERRED_CONFLICT'));
    }

    @IsTest
    static void applyPhone_SameAnswerAsPreferredField_AppliesOnce() {
        usePhoneFakeForm();
        String U = uniq();
        Contact c = createHomePhoneContact('MemeTel' + U, '5145550100');
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{
            'Phone' => '(514) 555-0155', 'HomePhone' => '514-555-0155' }));
        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Phone', 'HomePhone' });
        System.assert(applied.success, applied.errorMessage);
        System.assertEquals('514-555-0155', queryPhones(c.Id).HomePhone);
        System.assert(notAppliedReasons(t.Id).isEmpty(), 'Same number: nothing left out');
    }

    @IsTest
    static void applyPhone_BlankPhone_NotApplied() {
        usePhoneFakeForm();
        String U = uniq();
        Contact c = createHomePhoneContact('VideTel' + U, '5145550100');
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{
            'Phone' => '', 'HomePhone' => '5145550166' }));
        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Phone', 'HomePhone' });
        System.assert(applied.success, applied.errorMessage);
        System.assertEquals('5145550166', queryPhones(c.Id).HomePhone);
        System.assert(notAppliedReasons(t.Id).contains('PHONE_EMPTY'));
    }

    @IsTest
    static void applyPhone_UnknownPreference_ToldAndTicketUnchanged() {
        usePhoneFakeForm();
        String U = uniq();
        Contact c = createHomePhoneContact('InconnuTel' + U, '5145550100');
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{ 'Phone' => '5145550177' }));
        DataUpdateReviewController.testPhonePreference = 'Pigeon Phone';

        System.assertEquals('Pigeon Phone', DataUpdateReviewController.getComparisonData(t.Id).fields[0].emailPreferenceUnknown);
        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'Phone' });
        System.assertEquals('PHONE_PREFERENCE_UNKNOWN', applied.errorMessage);
        System.assertEquals('New', [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c);
        System.assertEquals('5145550100', queryPhones(c.Id).HomePhone, 'Nothing applied');
    }

    @IsTest
    static void phoneTarget_ResolvesOnlyWhenItApplies() {
        Map<String, Schema.SObjectField> contactFields = Contact.SObjectType.getDescribe().fields.getMap();
        String U = uniq();
        Contact c = createHomePhoneContact('CibleTel' + U, '5145550100');
        System.assertEquals(false, DataUpdateReviewController.isPreferredPhoneEnforcementDisabled(), 'No org default in tests: enforcement on');
        System.assertEquals(null, DataUpdateReviewController.phoneSavedIn('Account', c.Id, Account.SObjectType.getDescribe().fields.getMap()));
        DataUpdateReviewController.testPhoneEnforcementDisabled = true;
        System.assertEquals(null, DataUpdateReviewController.phoneSavedIn('Contact', c.Id, contactFields));
        Boolean phoneOffered = false;
        for (DataUpdateWrapper.GroupSlotGroup g : DataUpdateReviewController.buildSaveOptions(c.Id, contactFields, null)) {
            for (DataUpdateWrapper.GroupSlot slot : g.slots) phoneOffered |= slot.apiName == 'Phone';
        }
        System.assert(phoneOffered, 'Enforcement off: Phone is a place like any other');
    }

    @IsTest
    static void applyWithOptions_PreferredWrongKind_InvalidChoiceNotError() {
        useSaveOptionsFakeForm();
        String U = uniq();
        Contact c = createTestContact('DeuxVal' + U, 'Eda');
        Data_Update_Request__c t = createReviewRequest(c.Id, JSON.serialize(new Map<String, String>{
            'HomePhone' => '5145550188', 'hed__WorkEmail__c' => 'w' + U + '@example.com' }));
        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdatesWithOptions(t.Id,
            new List<String>{ 'HomePhone' }, null, '{"overrides":{"HomePhone":"OtherPhone"},"preferred":{"EMAIL":"HomePhone"}}');
        System.assertEquals('INVALID_SAVE_CHOICE', applied.errorMessage);
        System.assertEquals('New', [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c);
    }
}
