@IsTest(SeeAllData=false)
private class DataUpdateReviewControllerTest {

    private static final String FORM_NAME = 'AEBEQ_Account_Update';
    private static final String FAKE_RECORD_ID = '001000000000000AAA';

    private static String uniq() {
        return String.valueOf(DateTime.now().getTime()) + String.valueOf(Crypto.getRandomInteger());
    }

    private static void applyDupBypass(Database.DMLOptions dmo) {
        dmo.DuplicateRuleHeader.allowSave = true;
        dmo.DuplicateRuleHeader.runAsCurrentUser = true;
    }

    private static Account insertResilient(Account a) {
        Database.DMLOptions dmo = new Database.DMLOptions();
        applyDupBypass(dmo);
        Database.SaveResult sr = Database.insert(new List<SObject>{ a }, dmo)[0];
        System.assert(sr.isSuccess(), 'Insert failed: ' +
            (sr.getErrors().isEmpty() ? 'unknown' : sr.getErrors()[0].getMessage()));
        a.Id = sr.getId();
        return a;
    }

    private static Id personAccountRtId() {
        RecordType rt = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND DeveloperName = 'PersonAccount' LIMIT 1];
        return rt.Id;
    }

    private static Account createTestPersonAccount(String lastName, String firstName) {
        Account a = new Account(RecordTypeId = personAccountRtId());
        a.put('LastName', lastName);
        a.put('FirstName', firstName);
        a.put('PersonEmail', 'current' + uniq() + '@example.com');
        a.put('PersonMobilePhone', '5140000000');
        return insertResilient(a);
    }

    private static String getPersonEmail(SObject rec) {
        return (String) rec.get('PersonEmail');
    }

    private static String getPersonMobilePhone(SObject rec) {
        return (String) rec.get('PersonMobilePhone');
    }

    private static Account queryAccountEmailAndPhone(Id accId) {
        return (Account) Database.query('SELECT Id, PersonEmail, PersonMobilePhone FROM Account WHERE Id = :accId LIMIT 1');
    }

    private static Account queryAccountEmailOnly(Id accId) {
        return (Account) Database.query('SELECT Id, PersonEmail FROM Account WHERE Id = :accId LIMIT 1');
    }

    private static Data_Update_Request__c createReviewRequest(Id accountId, String proposedJson) {
        Data_Update_Request__c t = new Data_Update_Request__c(
            Target_Object_API_Name__c = 'Account',
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
        Account a = createTestPersonAccount('Martin' + U, 'Lucie');
        a = queryAccountEmailAndPhone(a.Id);
        String proposedJson = JSON.serialize(new Map<String, String>{
            'PersonEmail' => 'brandnew' + U + '@example.com',
            'PersonMobilePhone' => getPersonMobilePhone(a)
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
        Account a = createTestPersonAccount('Martin' + U, 'Lucie');
        a = queryAccountEmailAndPhone(a.Id);
        String proposedJson = JSON.serialize(new Map<String, String>{
            'PersonEmail' => 'brandnew' + U + '@example.com',
            'PersonMobilePhone' => getPersonMobilePhone(a)
        });
        Data_Update_Request__c t = createReviewRequest(a.Id, proposedJson);

        Test.startTest();
        DataUpdateWrapper.ComparisonData data = DataUpdateReviewController.getComparisonData(t.Id);
        Test.stopTest();

        System.assert(data.success);
        System.assertEquals(a.Id, Id.valueOf(data.recordId));
        System.assertEquals(false, data.requestClosed);
        System.assertEquals(1, data.fields.size(), 'Only the differing field must be listed');
        System.assertEquals('PersonEmail', data.fields[0].fieldApiName);
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
            Target_Object_API_Name__c = 'Account',
            Target_Record_Id__c = FAKE_RECORD_ID,
            Update_Form_DeveloperName__c = FORM_NAME,
            Status__c = 'New',
            Subject__c = 'No target record',
            Proposed_Values_JSON__c = '{"PersonEmail":"x@example.com"}'
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
        Account a = createTestPersonAccount('Vachon' + U, 'Renee');
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
        Account a = createTestPersonAccount('Poirier' + U, 'Chantal');
        a = queryAccountEmailAndPhone(a.Id);
        String originalPhone = getPersonMobilePhone(a);
        String newEmail = 'updated' + U + '@example.com';
        String newPhone = '5141234567';
        String proposedJson = JSON.serialize(new Map<String, String>{
            'PersonEmail' => newEmail,
            'PersonMobilePhone' => newPhone
        });
        Data_Update_Request__c t = createReviewRequest(a.Id, proposedJson);

        Test.startTest();
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'PersonEmail' });
        Test.stopTest();

        System.assert(result.success);
        System.assertEquals(1, result.updatedFieldCount);

        Account updated = queryAccountEmailAndPhone(a.Id);
        System.assertEquals(newEmail, getPersonEmail(updated));
        System.assertEquals(originalPhone, getPersonMobilePhone(updated), 'Unselected field must remain unchanged');

        Data_Update_Request__c closed = [SELECT Status__c, Final_Action__c, Closed_Reason__c FROM Data_Update_Request__c WHERE Id = :t.Id LIMIT 1];
        System.assertEquals('Applied', closed.Status__c, 'Request must be Applied after apply');
        System.assertEquals('Applied', closed.Final_Action__c);
        System.assertEquals('Applied', closed.Closed_Reason__c);
    }

    @IsTest
    static void applySelectedUpdates_FullApply_AllFieldsChange() {
        String U = uniq();
        Account a = createTestPersonAccount('Bouchard' + U, 'Remi');
        String newEmail = 'full' + U + '@example.com';
        String newPhone = '5149998888';
        String proposedJson = JSON.serialize(new Map<String, String>{
            'PersonEmail' => newEmail,
            'PersonMobilePhone' => newPhone
        });
        Data_Update_Request__c t = createReviewRequest(a.Id, proposedJson);

        Test.startTest();
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.applySelectedUpdates(
            t.Id, new List<String>{ 'PersonEmail', 'PersonMobilePhone' }
        );
        Test.stopTest();

        System.assert(result.success);
        System.assertEquals(2, result.updatedFieldCount);

        Account updated = queryAccountEmailAndPhone(a.Id);
        System.assertEquals(newEmail, getPersonEmail(updated));
        System.assertEquals(newPhone, getPersonMobilePhone(updated));
    }

    @IsTest
    static void applySelectedUpdates_NoFieldsSelected_ClosesRequestWithoutAccountUpdate() {
        String U = uniq();
        Account a = createTestPersonAccount('Girard' + U, 'Nadia');
        a = queryAccountEmailOnly(a.Id);
        String originalEmail = getPersonEmail(a);
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'PersonEmail' => 'ignored@example.com' }));

        Test.startTest();
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.applySelectedUpdates(t.Id, null);
        Test.stopTest();

        System.assert(result.success);
        System.assertEquals(0, result.updatedFieldCount);

        Account unchanged = queryAccountEmailOnly(a.Id);
        System.assertEquals(originalEmail, getPersonEmail(unchanged));

        Data_Update_Request__c closed = [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id LIMIT 1];
        System.assertEquals('Applied', closed.Status__c);
    }

    @IsTest
    static void applySelectedUpdates_IgnoresFieldNotInCatalogOrNotProposed() {
        String U = uniq();
        Account a = createTestPersonAccount('Charest' + U, 'Olivier');
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'PersonEmail' => 'x@example.com' }));

        Test.startTest();
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.applySelectedUpdates(
            t.Id, new List<String>{ 'Name', 'PersonHomePhone' }
        );
        Test.stopTest();

        System.assert(result.success);
        System.assertEquals(0, result.updatedFieldCount);
    }

    @IsTest
    static void applySelectedUpdates_RequestNotFound_ReturnsGenericError() {
        Test.startTest();
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.applySelectedUpdates(UserInfo.getUserId(), new List<String>{ 'PersonEmail' });
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('GENERIC_ERROR', result.errorMessage);
    }

    @IsTest
    static void applySelectedUpdates_AlreadyClosedRequest_ReturnsError() {
        String U = uniq();
        Account a = createTestPersonAccount('Fournier' + U, 'Sophie');
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'PersonEmail' => 'x@example.com' }));
        update new Data_Update_Request__c(Id = t.Id, Status__c = 'Closed', Closed_Reason__c = 'Applied');

        Test.startTest();
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'PersonEmail' });
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('TICKET_ALREADY_CLOSED', result.errorMessage);
    }

    @IsTest
    static void applySelectedUpdates_ForcedError_ReturnsGenericError() {
        String U = uniq();
        Account a = createTestPersonAccount('Simoneau' + U, 'David');
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'PersonEmail' => 'x@example.com' }));

        DataUpdateReviewController.TEST_FORCE_ERROR = true;
        Test.startTest();
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'PersonEmail' });
        Test.stopTest();
        DataUpdateReviewController.TEST_FORCE_ERROR = false;

        System.assertEquals(false, result.success);
        System.assertEquals('GENERIC_ERROR', result.errorMessage);
    }

    // ─── Audit log integration (new — no Case-based precedent) ─────────────

    @IsTest
    static void applySelectedUpdates_Success_CreatesCompletedLogWithSnapshots() {
        String U = uniq();
        Account a = createTestPersonAccount('Ouellet' + U, 'Marc');
        String newEmail = 'audited' + U + '@example.com';
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'PersonEmail' => newEmail }));

        Test.startTest();
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'PersonEmail' });
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
        Account a = createTestPersonAccount('Tremblay' + U, 'Julie');
        String firstEmail = 'first' + U + '@example.com';
        String secondPhone = '5145551111';
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{
            'PersonEmail'       => firstEmail,
            'PersonMobilePhone' => secondPhone
        }));

        Test.startTest();
        DataUpdateWrapper.ApplyResult first = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'PersonEmail' });
        DataUpdateReviewController.reopenRequest(t.Id);
        DataUpdateWrapper.ApplyResult second = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'PersonMobilePhone' });
        Test.stopTest();

        System.assert(first.success);
        System.assert(second.success);

        List<Data_Update_Log__c> logs = [
            SELECT Action_Type__c FROM Data_Update_Log__c WHERE Request__c = :t.Id ORDER BY CreatedDate ASC
        ];
        System.assertEquals(2, logs.size(), 'Reopen after Applied must create a fresh log, not reuse the sealed one');
        System.assertEquals('APPLY_COMPLETED', logs[0].Action_Type__c);
        System.assertEquals('APPLY_COMPLETED', logs[1].Action_Type__c);

        Account updated = queryAccountEmailAndPhone(a.Id);
        System.assertEquals(firstEmail, getPersonEmail(updated));
        System.assertEquals(secondPhone, getPersonMobilePhone(updated));
    }

    // ─── correctProposedValue ───────────────────────────────────────────────

    @IsTest
    static void correctProposedValue_Success_UpdatesJsonAndCreatesCorrectedLog() {
        String U = uniq();
        Account a = createTestPersonAccount('Corrige' + U, 'Yvon');
        String typoEmail = 'tpyo' + U + '@example.com';
        String fixedEmail = 'fixed' + U + '@example.com';
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'PersonEmail' => typoEmail }));

        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(t.Id, 'PersonEmail', '  ' + fixedEmail + '  ');
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
        Account a = createTestPersonAccount('Corrige2' + U, 'Diane');
        String newPhone = '5145550000';
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'PersonEmail' => 'x' + U + '@example.com' }));

        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(t.Id, 'PersonMobilePhone', newPhone);
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
        Account a = createTestPersonAccount('Corrige9' + U, 'Simone');
        String newEmail = 'brandnew9' + U + '@example.com';
        Data_Update_Request__c t = createReviewRequest(a.Id, null);

        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(t.Id, 'PersonEmail', newEmail);
        Test.stopTest();

        System.assert(result.success);
        Data_Update_Request__c updated = [SELECT Proposed_Values_JSON__c FROM Data_Update_Request__c WHERE Id = :t.Id LIMIT 1];
        System.assert(updated.Proposed_Values_JSON__c.contains(newEmail));
    }

    @IsTest
    static void correctProposedValue_UnchangedValue_NoOpAndNoLog() {
        String U = uniq();
        Account a = createTestPersonAccount('Corrige3' + U, 'Marcel');
        String email = 'same' + U + '@example.com';
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'PersonEmail' => email }));

        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(t.Id, 'PersonEmail', email);
        Test.stopTest();

        System.assert(result.success);
        List<Data_Update_Log__c> logs = [SELECT Id FROM Data_Update_Log__c WHERE Request__c = :t.Id AND Action_Type__c = 'CORRECTED'];
        System.assert(logs.isEmpty(), 'Saving the same value must not create a CORRECTED log entry');
    }

    @IsTest
    static void correctProposedValue_BlankValue_ReturnsValueRequired() {
        String U = uniq();
        Account a = createTestPersonAccount('Corrige4' + U, 'Helene');
        String originalEmail = 'orig' + U + '@example.com';
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'PersonEmail' => originalEmail }));

        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(t.Id, 'PersonEmail', '   ');
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('VALUE_REQUIRED', result.errorMessage);
        Data_Update_Request__c unchanged = [SELECT Proposed_Values_JSON__c FROM Data_Update_Request__c WHERE Id = :t.Id LIMIT 1];
        System.assert(unchanged.Proposed_Values_JSON__c.contains(originalEmail));
    }

    @IsTest
    static void correctProposedValue_TerminalRequest_ReturnsAlreadyClosed() {
        String U = uniq();
        Account a = createTestPersonAccount('Corrige5' + U, 'Gilles');
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'PersonEmail' => 'x' + U + '@example.com' }));
        update new Data_Update_Request__c(Id = t.Id, Status__c = 'Closed', Closed_Reason__c = 'Applied');

        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(t.Id, 'PersonEmail', 'new' + U + '@example.com');
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('TICKET_ALREADY_CLOSED', result.errorMessage);
    }

    @IsTest
    static void correctProposedValue_FieldNotInFormConfig_ReturnsFieldNotEditable() {
        String U = uniq();
        Account a = createTestPersonAccount('Corrige6' + U, 'Pauline');
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'PersonEmail' => 'x' + U + '@example.com' }));

        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(t.Id, 'Name', 'Some New Name');
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('FIELD_NOT_EDITABLE', result.errorMessage);
    }

    @IsTest
    static void correctProposedValue_RequestNotFound_ReturnsGenericError() {
        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(UserInfo.getUserId(), 'PersonEmail', 'x@example.com');
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('GENERIC_ERROR', result.errorMessage);
    }

    @IsTest
    static void correctProposedValue_ForcedError_ReturnsGenericError() {
        String U = uniq();
        Account a = createTestPersonAccount('Corrige7' + U, 'Andre');
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'PersonEmail' => 'x' + U + '@example.com' }));

        DataUpdateReviewController.TEST_FORCE_ERROR = true;
        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(t.Id, 'PersonEmail', 'new' + U + '@example.com');
        Test.stopTest();
        DataUpdateReviewController.TEST_FORCE_ERROR = false;

        System.assertEquals(false, result.success);
        System.assertEquals('GENERIC_ERROR', result.errorMessage);
    }

    @IsTest
    static void getAuditLog_IncludesCorrectedEntry() {
        String U = uniq();
        Account a = createTestPersonAccount('Corrige8' + U, 'Francine');
        String typoEmail = 'tpyo8' + U + '@example.com';
        String fixedEmail = 'fixed8' + U + '@example.com';
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'PersonEmail' => typoEmail }));
        DataUpdateReviewController.correctProposedValue(t.Id, 'PersonEmail', fixedEmail);

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
        System.assertEquals('PersonEmail', correctedEntry.fieldChanges[0].fieldApiName);
        System.assertEquals(typoEmail, correctedEntry.fieldChanges[0].beforeValue);
        System.assertEquals(fixedEmail, correctedEntry.fieldChanges[0].afterValue);
        System.assertEquals(false, correctedEntry.fieldChanges[0].canRollback, 'A CORRECTED entry never touched the real record, so it cannot be rolled back');
    }

    // ─── Bandeja de entrada ─────────────────────────────────────────────────

    @IsTest
    static void getRequests_OpenFilter_ExcludesClosedRequests() {
        String U = uniq();
        Account a = createTestPersonAccount('Bandeja' + U, 'Test');
        Data_Update_Request__c openRequest = createReviewRequest(a.Id, '{"PersonEmail":"x@example.com"}');
        Data_Update_Request__c closedRequest = createReviewRequest(a.Id, '{"PersonEmail":"y@example.com"}');
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
        Account a = createTestPersonAccount('BusquedaTest' + U, 'Search');
        Data_Update_Request__c t = new Data_Update_Request__c(
            Target_Object_API_Name__c = 'Account',
            Target_Record_Id__c = a.Id,
            Update_Form_DeveloperName__c = FORM_NAME,
            Status__c = 'New',
            Subject__c = 'UniqueSubjectMarker' + U,
            Proposed_Values_JSON__c = '{"PersonEmail":"x@example.com"}'
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
        Account a = createTestPersonAccount('Conteo' + U, 'Test');
        createReviewRequest(a.Id, '{"PersonEmail":"x@example.com"}');

        Test.startTest();
        Integer count = DataUpdateReviewController.getRequestCount('Open', 'All', '');
        Test.stopTest();

        System.assert(count >= 1);
    }

    // ─── search: accents, apostrophe, email, literal wildcards ────────────────

    @IsTest
    static void search_IgnoresAccentsMatchesEmailAndApostrophe() {
        String U = uniq();
        Account a = createTestPersonAccount('Lacharite' + U, 'Test');
        Data_Update_Request__c t1 = createReviewRequest(a.Id, '{"PersonEmail":"x@example.com"}');
        Data_Update_Request__c t2 = createReviewRequest(a.Id, '{"PersonEmail":"y@example.com"}');
        Data_Update_Request__c t3 = createReviewRequest(a.Id, '{"PersonEmail":"z@example.com"}');
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
        Account a = createTestPersonAccount('Pagina' + U, 'Test');
        List<Data_Update_Request__c> updates = new List<Data_Update_Request__c>();
        for (Integer i = 0; i < 3; i++) {
            Data_Update_Request__c t = createReviewRequest(a.Id, '{"PersonEmail":"p' + i + '@example.com"}');
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
        Account a = createTestPersonAccount('Reopen' + U, 'Test');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"PersonEmail":"x@example.com"}');
        update new Data_Update_Request__c(
            Id = t.Id, Status__c = 'Applied', Final_Action__c = 'Applied', Closed_Reason__c = 'Applied'
        );

        update new Account(Id = a.Id, Data_Update_Locked__c = false);
        User usr = dataUpdateUser();

        Test.startTest();
        System.runAs(usr) {
            DataUpdateReviewController.reopenRequest(t.Id);
        }
        Test.stopTest();

        System.assertEquals(true, [SELECT Data_Update_Locked__c FROM Account WHERE Id = :a.Id].Data_Update_Locked__c,
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
        Account a = createTestPersonAccount('Hold' + U, 'Test');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"PersonEmail":"x@example.com"}');

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
        Account a = createTestPersonAccount('Resume' + U, 'Test');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"PersonEmail":"x@example.com"}');
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
        Account a = createTestPersonAccount('Lavoie' + U, 'Isabelle');
        a.put('Data_Update_Locked__c', true);
        a.put('Data_Update_Locked_Date__c', Datetime.now());
        update a;
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"PersonEmail":"x@example.com"}');
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
        Account a = createTestPersonAccount('Gagnon' + U, 'Marc');
        a.put('Data_Update_Locked__c', true);
        a.put('Data_Update_Locked_Date__c', Datetime.now());
        update a;
        Data_Update_Request__c closedT = createReviewRequest(a.Id, '{"PersonEmail":"x@example.com"}');
        closedT.Status__c = 'Applied';
        closedT.Closed_Reason__c = 'Applied';
        update closedT;
        Data_Update_Request__c openT = createReviewRequest(a.Id, '{"PersonEmail":"y@example.com"}');
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
        Account a = createTestPersonAccount('Desrosiers' + U, 'Alain');
        a.put('Data_Update_Locked__c', true);
        a.put('Data_Update_Locked_Date__c', Datetime.now());
        update a;

        Test.startTest();
        DataUpdateWrapper.UnlockResult result = DataUpdateReviewController.unlockRecord(a.Id, FORM_NAME);
        Test.stopTest();

        System.assert(result.success);
        Account unlocked = [SELECT Data_Update_Locked__c, Data_Update_Locked_Date__c FROM Account WHERE Id = :a.Id LIMIT 1];
        System.assertEquals(false, unlocked.Data_Update_Locked__c);
        System.assertEquals(null, unlocked.Data_Update_Locked_Date__c);
    }

    @IsTest
    static void unlockRecord_BlockedWhileLatestRequestStillOpen() {
        String U = uniq();
        Account a = createTestPersonAccount('Charron' + U, 'Melanie');
        a.put('Data_Update_Locked__c', true);
        a.put('Data_Update_Locked_Date__c', Datetime.now());
        update a;
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"PersonEmail":"x@example.com"}');

        Test.startTest();
        DataUpdateWrapper.UnlockResult result = DataUpdateReviewController.unlockRecord(a.Id, FORM_NAME);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('REQUEST_STILL_OPEN', result.errorMessage);
        System.assertEquals(t.Id, result.openRequestId);
        Account stillLocked = [SELECT Data_Update_Locked__c FROM Account WHERE Id = :a.Id LIMIT 1];
        System.assertEquals(true, stillLocked.Data_Update_Locked__c);
    }

    @IsTest
    static void unlockAllRecords_ClearsAllLockedAccountsAndReturnsCount() {
        String U = uniq();
        Account a1 = createTestPersonAccount('Pelletier' + U, 'Robert');
        Account a2 = createTestPersonAccount('Pelletier' + U, 'Nathalie');
        a1.put('Data_Update_Locked__c', true);
        a1.put('Data_Update_Locked_Date__c', Datetime.now());
        a2.put('Data_Update_Locked__c', true);
        a2.put('Data_Update_Locked_Date__c', Datetime.now());
        update new List<Account>{ a1, a2 };

        Test.startTest();
        DataUpdateWrapper.UnlockAllResult result = DataUpdateReviewController.unlockAllRecords(FORM_NAME);
        Test.stopTest();

        System.assert(result.success);
        System.assert(result.unlockedCount >= 2);
        List<Account> stillLocked = [SELECT Id FROM Account WHERE Id IN :new List<Id>{ a1.Id, a2.Id } AND Data_Update_Locked__c = true];
        System.assert(stillLocked.isEmpty(), 'unlockAllRecords must clear the lock on every currently-locked account');
    }

    @IsTest
    static void unlockAllRecords_SkipsAccountsWithStillOpenRequest() {
        String U = uniq();
        Account blocked = createTestPersonAccount('Fontaine' + U, 'Yves');
        blocked.put('Data_Update_Locked__c', true);
        blocked.put('Data_Update_Locked_Date__c', Datetime.now());
        update blocked;
        createReviewRequest(blocked.Id, '{"PersonEmail":"x@example.com"}');

        Account unblocked = createTestPersonAccount('Fontaine' + U, 'Sylvie');
        unblocked.put('Data_Update_Locked__c', true);
        unblocked.put('Data_Update_Locked_Date__c', Datetime.now());
        update unblocked;

        Test.startTest();
        DataUpdateWrapper.UnlockAllResult result = DataUpdateReviewController.unlockAllRecords(FORM_NAME);
        Test.stopTest();

        System.assert(result.success);
        System.assert(result.skippedCount >= 1);
        Account stillBlocked = [SELECT Data_Update_Locked__c FROM Account WHERE Id = :blocked.Id LIMIT 1];
        System.assertEquals(true, stillBlocked.Data_Update_Locked__c);
        Account nowUnlocked = [SELECT Data_Update_Locked__c FROM Account WHERE Id = :unblocked.Id LIMIT 1];
        System.assertEquals(false, nowUnlocked.Data_Update_Locked__c);
    }

    @IsTest
    static void unlock_ScopedToFormAndBlockedByOtherFormsOpenTicket() {
        String U = uniq();
        // Église locked by its own open ticket: the Account form must neither see nor unlock it.
        Account e = createEglise('Eglise Scope ' + U);
        e.put('Data_Update_Locked__c', true);
        update e;
        insert new Data_Update_Request__c(
            Target_Object_API_Name__c = 'Account', Target_Record_Id__c = e.Id,
            Update_Form_DeveloperName__c = 'AEBEQ_Eglise_Update', Status__c = 'New', Subject__c = 'Eglise open ' + U
        );
        // Person account locked by an open ticket from another form sharing the lock field.
        Account p = createTestPersonAccount('Partage' + U, 'Luc');
        p.put('Data_Update_Locked__c', true);
        update p;
        Data_Update_Request__c otherFormTicket = new Data_Update_Request__c(
            Target_Object_API_Name__c = 'Account', Target_Record_Id__c = p.Id,
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
        System.assertEquals(true, [SELECT Data_Update_Locked__c FROM Account WHERE Id = :e.Id].Data_Update_Locked__c,
            'Unlock all on the Account form must not touch Églises');
        System.assertEquals(true, [SELECT Data_Update_Locked__c FROM Account WHERE Id = :p.Id].Data_Update_Locked__c,
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
        Account locked = createTestPersonAccount('Bergeron' + U, 'Chantal');
        locked.put('Data_Update_Locked__c', true);
        locked.put('Data_Update_Locked_Date__c', Datetime.now());
        update locked;
        createReviewRequest(locked.Id, '{"PersonEmail":"x@example.com"}');

        Account notLocked = createTestPersonAccount('Gauthier' + U, 'Serge');

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
        Account a = createTestPersonAccount('UniqueLockMarker' + U, 'Test');
        a.put('Data_Update_Locked__c', true);
        a.put('Data_Update_Locked_Date__c', Datetime.now());
        update a;
        a = [SELECT Id, Name FROM Account WHERE Id = :a.Id LIMIT 1];

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
        return insertResilient(a);
    }

    private static Data_Update_Request__c createRequestFor(Id recordId, String formName, String proposedJson) {
        Data_Update_Request__c t = new Data_Update_Request__c(
            Target_Object_API_Name__c = 'Account',
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
            '{"DeveloperName":"Fake_NoLock_Form","MasterLabel":"Fake","Target_Object_API_Name__c":"Account",'
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
            '{"DeveloperName":"Fake_Lock_Form","MasterLabel":"Fake","Target_Object_API_Name__c":"Account",'
            + '"Identity_Field_1_API_Name__c":"Name","Identity_Field_1_Comparison__c":"Exact",'
            + '"Subject_Template__c":"{RecordName}","Is_Active__c":true,"Lock_Field_API_Name__c":"Data_Update_Locked__c"}',
            Data_Update_Form__mdt.class);
    }

    private static Id findLogId(Id requestId, String actionType) {
        return [SELECT Id FROM Data_Update_Log__c WHERE Request__c = :requestId AND Action_Type__c = :actionType
                ORDER BY CreatedDate DESC LIMIT 1].Id;
    }

    // ─── Rollback ───────────────────────────────────────────────────────────

    @IsTest
    static void rollbackChange_FullCycle_RestoresValueAndReopens() {
        String U = uniq();
        Account a = createTestPersonAccount('Retour' + U, 'Anne');
        String originalEmail = getPersonEmail(queryAccountEmailOnly(a.Id));
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{
            'PersonEmail' => 'rolled' + U + '@example.com'
        }));
        System.assert(DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'PersonEmail' }).success);
        Id applyLogId = findLogId(t.Id, 'APPLY_COMPLETED');
        // Same-transaction logs share a CreatedDate; push the apply back so the rollback log
        // deterministically sorts after it in getFieldTouchMap().
        Test.setCreatedDate(applyLogId, DateTime.now().addMinutes(-5));

        Test.startTest();
        DataUpdateWrapper.AuditLogResult audit = DataUpdateReviewController.getAuditLog(t.Id);
        DataUpdateWrapper.ApplyResult wrongField = DataUpdateReviewController.rollbackChange(applyLogId, 'PersonMobilePhone');
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.rollbackChange(applyLogId, 'PersonEmail');
        DataUpdateWrapper.ApplyResult again = DataUpdateReviewController.rollbackChange(applyLogId, 'PersonEmail');
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

        System.assertEquals(originalEmail, getPersonEmail(queryAccountEmailOnly(a.Id)));
        Data_Update_Request__c reopened = [SELECT Status__c, Notes__c FROM Data_Update_Request__c WHERE Id = :t.Id];
        System.assertEquals('Reopened', reopened.Status__c);
        System.assert(reopened.Notes__c.contains('Rollback'));

        DataUpdateWrapper.ComparisonData cmp = DataUpdateReviewController.getComparisonData(t.Id);
        System.assert(cmp.fields[0].previouslyRolledBack);
    }

    @IsTest
    static void rollbackChanges_AllOrNothing() {
        String U = uniq();
        Account a = createTestPersonAccount('Lot' + U, 'Luc');
        String originalEmail = getPersonEmail(queryAccountEmailOnly(a.Id));
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{
            'PersonEmail' => 'batch' + U + '@example.com'
        }));
        System.assert(DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'PersonEmail' }).success);
        Id applyLogId = findLogId(t.Id, 'APPLY_COMPLETED');
        Test.setCreatedDate(applyLogId, DateTime.now().addMinutes(-5));
        String appliedStatus = [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c;

        Test.startTest();
        DataUpdateWrapper.ApplyResult empty = DataUpdateReviewController.rollbackChanges(applyLogId, new List<String>());
        // Second field is invalid → the first one must be undone too.
        DataUpdateWrapper.ApplyResult partial = DataUpdateReviewController.rollbackChanges(
            applyLogId, new List<String>{ 'PersonEmail', 'PersonMobilePhone' });
        String emailAfterPartial = getPersonEmail(queryAccountEmailOnly(a.Id));
        String statusAfterPartial = [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c;
        DataUpdateWrapper.ApplyResult ok = DataUpdateReviewController.rollbackChanges(
            applyLogId, new List<String>{ 'PersonEmail' });
        Test.stopTest();

        System.assertEquals('ROLLBACK_INVALID_STATE', empty.errorMessage);
        System.assertEquals(false, partial.success);
        System.assertEquals('batch' + U + '@example.com', emailAfterPartial, 'Failed batch must restore nothing');
        System.assertEquals(appliedStatus, statusAfterPartial, 'Failed batch must not reopen the request');
        System.assert(ok.success, 'Batch rollback should succeed: ' + ok.errorMessage);
        System.assertEquals(1, ok.updatedFieldCount);
        System.assertEquals(originalEmail, getPersonEmail(queryAccountEmailOnly(a.Id)));

        DataUpdateWrapper.ComparisonData cmp = DataUpdateReviewController.getComparisonData(t.Id);
        System.assertEquals('Reopened', cmp.status);
    }

    @IsTest
    static void rollbackChange_RelocksRecord_AndFailureRollsEverythingBack() {
        String U = uniq();
        Account a = createTestPersonAccount('Reverrou' + U, 'Anne');
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{
            'PersonEmail' => 'relock' + U + '@example.com'
        }));
        System.assert(DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'PersonEmail' }).success);
        Id applyLogId = findLogId(t.Id, 'APPLY_COMPLETED');
        Test.setCreatedDate(applyLogId, DateTime.now().addMinutes(-5));
        update new Account(Id = a.Id, Data_Update_Locked__c = false);
        User usr = dataUpdateUser();

        DataUpdateWrapper.ApplyResult failed;
        Account afterFailure;
        String statusAfterFailure;
        DataUpdateWrapper.ApplyResult ok;
        Test.startTest();
        System.runAs(usr) {
            DataUpdateReviewController.TEST_FORCE_ROLLBACK_DML_ERROR = true;
            failed = DataUpdateReviewController.rollbackChange(applyLogId, 'PersonEmail');
            afterFailure = (Account) Database.query('SELECT PersonEmail, Data_Update_Locked__c FROM Account WHERE Id = \'' + a.Id + '\'');
            statusAfterFailure = [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c;
            DataUpdateReviewController.TEST_FORCE_ROLLBACK_DML_ERROR = false;
            ok = DataUpdateReviewController.rollbackChange(applyLogId, 'PersonEmail');
        }
        Test.stopTest();

        System.assertEquals('GENERIC_ERROR', failed.errorMessage);
        System.assertEquals('relock' + U + '@example.com', afterFailure.get('PersonEmail'), 'Failed rollback must leave the value untouched');
        System.assertEquals(false, afterFailure.get('Data_Update_Locked__c'));
        System.assertEquals('Applied', statusAfterFailure);

        System.assert(ok.success, 'Rollback should succeed: ' + ok.errorMessage);
        Account relocked = [SELECT Data_Update_Locked__c, Data_Update_Locked_Date__c FROM Account WHERE Id = :a.Id];
        System.assertEquals(true, relocked.Data_Update_Locked__c, 'Reopened ticket puts the record back under lock');
        System.assertNotEquals(null, relocked.Data_Update_Locked_Date__c);
    }

    @IsTest
    static void reopenRequest_DeletedForm_StillRelocksViaSharedLockField() {
        String U = uniq();
        Account a = createTestPersonAccount('Orphelin' + U, 'Test');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"PersonEmail":"x@example.com"}');
        update new Data_Update_Request__c(Id = t.Id, Status__c = 'Applied', Closed_Reason__c = 'Applied',
            Update_Form_DeveloperName__c = 'Form_That_No_Longer_Exists_' + U);
        User usr = dataUpdateUser();

        Test.startTest();
        System.runAs(usr) {
            DataUpdateReviewController.reopenRequest(t.Id);
        }
        Test.stopTest();

        Account relocked = [SELECT Data_Update_Locked__c, Data_Update_Locked_Date__c FROM Account WHERE Id = :a.Id];
        System.assertEquals(true, relocked.Data_Update_Locked__c);
        System.assertNotEquals(null, relocked.Data_Update_Locked_Date__c);
    }

    @IsTest
    static void applySelectedUpdates_FailureAfterUpdate_LeavesRecordAndTicketUntouched() {
        String U = uniq();
        Account a = createTestPersonAccount('Atomique' + U, 'Test');
        String originalEmail = 'orig' + U + '@example.com';
        update new Account(Id = a.Id, PersonEmail = originalEmail);
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{
            'PersonEmail' => 'new' + U + '@example.com'
        }));

        Test.startTest();
        DataUpdateReviewController.TEST_FORCE_APPLY_DML_ERROR = true;
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'PersonEmail' });
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('GENERIC_ERROR', result.errorMessage);
        System.assertEquals(originalEmail, [SELECT PersonEmail FROM Account WHERE Id = :a.Id].PersonEmail,
            'The record update must be rolled back with the rest');
        System.assertNotEquals('Applied', [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c);
    }

    @IsTest
    static void rollbackChange_UnknownObjectOrReadOnlyField_ReturnsGenericError() {
        String U = uniq();
        Account a = createTestPersonAccount('Lecture' + U, 'Seule');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"PersonEmail":"x@example.com"}');
        Data_Update_Log__c badObject = new Data_Update_Log__c(
            Request__c = t.Id, Action_Type__c = 'APPLY_COMPLETED',
            Target_Object_API_Name__c = 'Nope_Not_An_Object__c', Target_Record_Id__c = String.valueOf(a.Id),
            Before_Snapshot_JSON__c = '{}', Field_Decisions_JSON__c = '{"PersonEmail":{"selectedValue":"x"}}'
        );
        insert badObject;

        Data_Update_Request__c t2 = createReviewRequest(a.Id, '{"PersonEmail":"x@example.com"}');
        Data_Update_Log__c readOnly = new Data_Update_Log__c(
            Request__c = t2.Id, Action_Type__c = 'APPLY_COMPLETED',
            Target_Object_API_Name__c = 'Account', Target_Record_Id__c = String.valueOf(a.Id),
            Before_Snapshot_JSON__c = '{}', Field_Decisions_JSON__c = '{"CreatedDate":"not-a-map"}'
        );
        insert readOnly;

        Test.startTest();
        DataUpdateWrapper.ApplyResult r1 = DataUpdateReviewController.rollbackChange(badObject.Id, 'PersonEmail');
        DataUpdateWrapper.ApplyResult r2 = DataUpdateReviewController.rollbackChange(readOnly.Id, 'CreatedDate');
        DataUpdateWrapper.ApplyResult r3 = DataUpdateReviewController.rollbackChange(UserInfo.getUserId(), 'PersonEmail');
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
        Account a = createTestPersonAccount('SansDecision' + U, 'Log');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"PersonEmail":"x@example.com"}');
        Data_Update_Log__c emptyLog = new Data_Update_Log__c(
            Request__c = t.Id, Action_Type__c = 'APPLY_COMPLETED',
            Target_Object_API_Name__c = 'Account', Target_Record_Id__c = String.valueOf(a.Id),
            Before_Snapshot_JSON__c = '{}'
        );
        insert emptyLog;

        DataUpdateWrapper.ApplyResult r = DataUpdateReviewController.rollbackChange(emptyLog.Id, 'PersonEmail');
        System.assertEquals(false, r.success);
        System.assertEquals('ROLLBACK_INVALID_STATE', r.errorMessage);
    }

    @IsTest
    static void rollbackChange_ForcedError_ReturnsGenericError() {
        DataUpdateReviewController.TEST_FORCE_ERROR = true;
        DataUpdateWrapper.ApplyResult r = DataUpdateReviewController.rollbackChange(UserInfo.getUserId(), 'PersonEmail');
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
        Account a = createTestPersonAccount('Supprime' + U, 'Form');
        Data_Update_Request__c t = createRequestFor(a.Id, 'Gone_Form_' + U, JSON.serialize(new Map<String, String>{
            'PersonEmail' => 'fallback' + U + '@example.com',
            'Nope_Not_A_Field__c' => 'ignored'
        }));

        Test.startTest();
        DataUpdateWrapper.ComparisonData cmp = DataUpdateReviewController.getComparisonData(t.Id);
        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'PersonEmail' });
        DataUpdateWrapper.ApplyResult rolled = DataUpdateReviewController.rollbackChange(findLogId(t.Id, 'APPLY_COMPLETED'), 'PersonEmail');
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
        Account a = createTestPersonAccount('Repli' + U, 'Id');
        Data_Update_Request__c byId = new Data_Update_Request__c(Target_Record_Id__c = a.Id);
        Data_Update_Request__c none = new Data_Update_Request__c();

        DataUpdateFormConfigService.FormConfig cfg = DataUpdateReviewController.buildFallbackConfig(byId);
        System.assertEquals('Account', cfg.targetObjectApiName);
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
        Account a = createTestPersonAccount('Invalide' + U, 'Courriel');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"PersonEmail":"not an email"}');

        Test.startTest();
        DataUpdateWrapper.ApplyResult result = DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ 'PersonEmail' });
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('Error', [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c);
    }

    @IsTest
    static void eglise_ApplyHistorizesWithSubmittedDateThenRollbackDeletesRow() {
        User usr = dataUpdateUser();
        String U = uniq();
        Account e = createEglise('Eglise Test ' + U);
        Data_Update_Request__c t = createRequestFor(e.Id, 'AEBEQ_Eglise_Update', JSON.serialize(new Map<String, String>{
            'Eglise_Attendance__c' => '42',
            'Eglise_Attendance_Date__c' => '2026-09-01'
        }));

        DataUpdateWrapper.ApplyResult applied;
        DataUpdateWrapper.ApplyResult rolled;
        Test.startTest();
        System.runAs(usr) {
            applied = DataUpdateReviewController.applySelectedUpdates(t.Id,
                new List<String>{ 'Eglise_Attendance__c', 'Eglise_Attendance_Date__c' });
            rolled = DataUpdateReviewController.rollbackChange(findLogId(t.Id, 'APPLY_COMPLETED'), 'Eglise_Attendance__c');
        }
        Test.stopTest();

        System.assert(applied.success, 'Apply should succeed: ' + applied.errorMessage);
        System.assert(rolled.success, 'Rollback should succeed: ' + rolled.errorMessage);
        System.assertEquals(false, rolled.historyCleanupSkipped == true);
        System.assertEquals(0, Database.countQuery('SELECT COUNT() FROM Attendance_History__c WHERE Account__c = \'' + e.Id + '\''),
            'Rollback must delete the history row created by that apply');
    }

    @IsTest
    static void getFormResponseChecklist_RealEgliseForm_ListsEglises() {
        User usr = dataUpdateUser();
        Account e = createEglise('Eglise Checklist ' + uniq());

        DataUpdateWrapper.ChecklistResult result;
        Test.startTest();
        System.runAs(usr) {
            result = DataUpdateReviewController.getFormResponseChecklist('AEBEQ_Eglise_Update');
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
        createRequestFor(answered.Id, 'AEBEQ_Eglise_Update', '{}');
        createRequestFor(otherForm.Id, 'Some_Other_Form', '{}');

        String today = String.valueOf(Date.today());
        String tomorrow = String.valueOf(Date.today().addDays(1));
        DataUpdateWrapper.ChecklistResult allTime;
        DataUpdateWrapper.ChecklistResult sinceToday;
        DataUpdateWrapper.ChecklistResult sinceTomorrow;
        DataUpdateWrapper.ChecklistResult badDate;
        Test.startTest();
        System.runAs(usr) {
            allTime = DataUpdateReviewController.getFormResponseChecklistSince('AEBEQ_Eglise_Update', '');
            sinceToday = DataUpdateReviewController.getFormResponseChecklistSince('AEBEQ_Eglise_Update', today);
            sinceTomorrow = DataUpdateReviewController.getFormResponseChecklistSince('AEBEQ_Eglise_Update', tomorrow);
            badDate = DataUpdateReviewController.getFormResponseChecklistSince('AEBEQ_Eglise_Update', 'not-a-date');
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
        Account a = createTestPersonAccount('SansDate' + U, 'Lock');
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
        Account a = createTestPersonAccount('Postal' + U, 'Code');
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{
            'PersonMailingPostalCode' => 'H2X1Y4', 'PersonMailingCountry' => 'Canada'
        }));

        Test.startTest();
        DataUpdateWrapper.CorrectionResult bad = DataUpdateReviewController.correctProposedValue(t.Id, 'PersonMailingPostalCode', 'H2X');
        DataUpdateWrapper.CorrectionResult good = DataUpdateReviewController.correctProposedValue(t.Id, 'PersonMailingPostalCode', 'h3a2b7');
        Test.stopTest();

        System.assertEquals('INVALID_POSTAL_CODE', bad.errorMessage);
        System.assert(good.success);
        System.assertEquals('H3A 2B7', good.newValue);
    }

    // ─── Inbox filters, counts, status transitions ──────────────────────────

    @IsTest
    static void getRequests_StatusFormAndDeletedFilters() {
        String U = uniq();
        Account a = createTestPersonAccount('Filtre' + U, 'Test');
        Data_Update_Request__c live = createReviewRequest(a.Id, '{"PersonEmail":"x@example.com"}');
        Data_Update_Request__c orphan = createRequestFor(a.Id, 'Gone_Form_' + U, '{"PersonEmail":"y@example.com"}');

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
        Account a = createTestPersonAccount('Ignore' + U, 'Test');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"PersonEmail":"x@example.com"}');

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
        fc.fieldApiName = 'Eglise_Attendance__c';
        fc.historyMode = 'Historize';
        fc.historyTargetObjectApiName = 'Attendance_History__c';
        fc.historyTargetValueFieldApiName = 'Value__c';
        fc.historyTargetDateFieldApiName = 'Metric_Date__c';
        fc.historyTargetAccountFieldApiName = 'Account__c';

        SObject row = DataUpdateReviewController.buildDynamicHistoryRow(fc, e.Id, 12, new Account(Id = e.Id), null, null);
        System.assertEquals(Date.today(), row.get('Metric_Date__c'), 'No date source → today');
        System.assertEquals(e.Id, row.get('Account__c'));
        System.assert(DataUpdateReviewController.deleteHistoryRowsForRollback(fc, null), 'No log field → cleanup skipped');
    }

    @IsTest
    static void historyRow_PairedDateNotApplied_UsesTicketDate() {
        String U = uniq();
        Account e = createEglise('Eglise Paired ' + U);
        DataUpdateFormConfigService.FormFieldConfig fc = new DataUpdateFormConfigService.FormFieldConfig();
        fc.fieldApiName = 'Eglise_Attendance__c';
        fc.historyMode = 'Historize';
        fc.historyTargetObjectApiName = 'Attendance_History__c';
        fc.historyTargetValueFieldApiName = 'Value__c';
        fc.historyTargetDateFieldApiName = 'Metric_Date__c';
        fc.historyTargetAccountFieldApiName = 'Account__c';
        fc.historyDateSourceFieldApiName = 'Eglise_Attendance_Date__c';

        // grouped review: the date goes in with another ticket, so it is not on targetRecord
        Map<String, String> proposed = new Map<String, String>{ 'Eglise_Attendance_Date__c' => '2026-04-05' };
        SObject row = DataUpdateReviewController.buildDynamicHistoryRow(fc, e.Id, 120, new Account(Id = e.Id), null, null, proposed);
        System.assertEquals(Date.newInstance(2026, 4, 5), row.get('Metric_Date__c'), 'Date this ticket sent, not today');

        // applied with this ticket: the record value wins
        Account withDate = new Account(Id = e.Id, Eglise_Attendance_Date__c = Date.newInstance(2026, 3, 1));
        row = DataUpdateReviewController.buildDynamicHistoryRow(fc, e.Id, 120, withDate, null, null, proposed);
        System.assertEquals(Date.newInstance(2026, 3, 1), row.get('Metric_Date__c'));

        // malformed → today, as before
        row = DataUpdateReviewController.buildDynamicHistoryRow(fc, e.Id, 120, new Account(Id = e.Id), null, null,
            new Map<String, String>{ 'Eglise_Attendance_Date__c' => 'not a date' });
        System.assertEquals(Date.today(), row.get('Metric_Date__c'));
    }

    @IsTest
    static void eglise_ComparisonData_HistorizeShowsLatestHistoryRow() {
        User usr = dataUpdateUser();
        Account e = createEglise('Eglise Preview ' + uniq());
        SObject hist = Schema.getGlobalDescribe().get('Attendance_History__c').newSObject();
        hist.put('Account__c', e.Id);
        hist.put('Value__c', 1410);
        hist.put('Metric_Date__c', Date.newInstance(2025, 9, 14));
        insert hist;
        Data_Update_Request__c t = createRequestFor(e.Id, 'AEBEQ_Eglise_Update', JSON.serialize(new Map<String, String>{
            'Eglise_Attendance__c' => '1500',
            'Eglise_Attendance_Date__c' => '2026-09-10'
        }));

        DataUpdateWrapper.ComparisonData data;
        Test.startTest();
        System.runAs(usr) {
            data = DataUpdateReviewController.getComparisonData(t.Id);
        }
        Test.stopTest();

        System.assert(data.success, 'Comparison should load: ' + data.errorMessage);
        DataUpdateWrapper.ComparisonField att;
        for (DataUpdateWrapper.ComparisonField f : data.fields) {
            if (f.fieldApiName == 'Eglise_Attendance__c') att = f;
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
        fc.fieldApiName = 'Eglise_Attendance__c';
        fc.historyMode = 'Historize';
        fc.historyTargetObjectApiName = 'Attendance_History__c';
        fc.historyTargetValueFieldApiName = 'Value__c';

        System.assertEquals(String.valueOf(Date.today()),
            DataUpdateReviewController.resolveHistorizePreviewDate(fc, new Map<String, String>()), 'No date source → today');
        fc.historyDateSourceFieldApiName = 'Eglise_Attendance_Date__c';
        System.assertEquals(String.valueOf(Date.today()),
            DataUpdateReviewController.resolveHistorizePreviewDate(fc, new Map<String, String>()), 'Date not submitted → today');
        System.assertEquals('Nope_Not_An_Object__c', DataUpdateReviewController.historyObjectLabel('Nope_Not_An_Object__c'));

        Id fakeId = FAKE_RECORD_ID;
        // No account lookup mapped → skipped.
        System.assert(DataUpdateReviewController.queryLatestHistorizePoints(
            new List<DataUpdateFormConfigService.FormFieldConfig>{ fc }, fakeId).isEmpty());
        // Broken mapping → query fails → preview just shows no previous row.
        fc.historyTargetAccountFieldApiName = 'Account__c';
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

    private static final String HIST_ONLY_KEY = 'Attendance_History__c.Value__c';

    private static void useHistoryOnlyFakeForm() {
        DataUpdateFormConfigService.testFormMdt = (Data_Update_Form__mdt) JSON.deserialize(
            '{"DeveloperName":"Fake_HistOnly_Form","MasterLabel":"Fake","Target_Object_API_Name__c":"Account",'
            + '"Identity_Field_1_API_Name__c":"Name","Identity_Field_1_Comparison__c":"Exact",'
            + '"Subject_Template__c":"{RecordName}","Is_Active__c":true,"Lock_Field_API_Name__c":"Data_Update_Locked__c",'
            + '"Lock_Date_Field_API_Name__c":"Data_Update_Locked_Date__c"}',
            Data_Update_Form__mdt.class);
        DataUpdateFormConfigService.testFieldMdts = (List<Data_Update_Form_Field__mdt>) JSON.deserialize(
            '[{"Field_API_Name__c":"' + HIST_ONLY_KEY + '","Label_FR__c":"Assistance","Label_EN__c":"Attendance",'
            + '"Display_Order__c":1,"Input_Type__c":"Number","History_Mode__c":"History_Only","Is_Active__c":true,'
            + '"History_Target_Object_API_Name__c":"Attendance_History__c","History_Target_Value_Field_API_Name__c":"Value__c",'
            + '"History_Target_Date_Field_API_Name__c":"Metric_Date__c","History_Target_Account_Field_API_Name__c":"Account__c",'
            + '"History_Target_Log_Field_API_Name__c":"Log__c"},'
            + '{"Field_API_Name__c":"Phone","Label_FR__c":"T","Label_EN__c":"T","Display_Order__c":2,'
            + '"Input_Type__c":"Phone","History_Mode__c":"Replace","Is_Active__c":true}]',
            List<Data_Update_Form_Field__mdt>.class);
    }

    private static SObject newAttendanceRow(Id accountId, Decimal value, Date metricDate) {
        SObject row = Schema.getGlobalDescribe().get('Attendance_History__c').newSObject();
        row.put('Account__c', accountId);
        row.put('Value__c', value);
        row.put('Metric_Date__c', metricDate);
        return row;
    }

    @IsTest
    static void historyOnly_CompareApplyAuditRollback() {
        User usr = dataUpdateUser();
        Account e = createEglise('Eglise HistOnly ' + uniq());
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
        List<SObject> remaining = Database.query('SELECT Value__c FROM Attendance_History__c WHERE Account__c = \'' + e.Id + '\'');
        System.assertEquals(1, remaining.size(), 'Rollback removes only the row created by the apply');
        System.assertEquals(30, (Decimal) remaining[0].get('Value__c'));
        System.assertEquals('Reopened', [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c);
    }

    @IsTest
    static void historyOnly_ApplyWritesRowWithSubmissionDate() {
        User usr = dataUpdateUser();
        Account e = createEglise('Eglise HistOnly2 ' + uniq());
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
        List<SObject> rows = Database.query('SELECT Value__c, Metric_Date__c, Log__c FROM Attendance_History__c WHERE Account__c = \'' + e.Id + '\'');
        System.assertEquals(1, rows.size());
        System.assertEquals(17, (Decimal) rows[0].get('Value__c'));
        System.assertEquals(Date.today(), rows[0].get('Metric_Date__c'), 'No typed date → submission date');
        System.assertNotEquals(null, rows[0].get('Log__c'));
        Data_Update_Log__c log = [SELECT Field_Decisions_JSON__c FROM Data_Update_Log__c
                                  WHERE Request__c = :t.Id AND Action_Type__c = 'APPLY_COMPLETED' LIMIT 1];
        System.assert(log.Field_Decisions_JSON__c.contains('historyRowId'), 'The log must remember which row was inserted');
    }

    @IsTest
    static void historyOnly_RollbackWithoutRowId_FallsBackToLogLookup() {
        User usr = dataUpdateUser();
        Account e = createEglise('Eglise HistOnly3 ' + uniq());
        Data_Update_Request__c t = createRequestFor(e.Id, 'Fake_HistOnly_Form', JSON.serialize(new Map<String, String>{
            HIST_ONLY_KEY => '5'
        }));
        useHistoryOnlyFakeForm();

        DataUpdateWrapper.ApplyResult rolled;
        Test.startTest();
        System.runAs(usr) {
            DataUpdateReviewController.applySelectedUpdates(t.Id, new List<String>{ HIST_ONLY_KEY });
            Id logId = findLogId(t.Id, 'APPLY_COMPLETED');
            // Strip historyRowId so rollback has to find the row through its Log__c lookup.
            Data_Update_Log__c log = [SELECT Field_Decisions_JSON__c FROM Data_Update_Log__c WHERE Id = :logId];
            Map<String, Object> decisions = (Map<String, Object>) JSON.deserializeUntyped(log.Field_Decisions_JSON__c);
            ((Map<String, Object>) decisions.get(HIST_ONLY_KEY)).remove('historyRowId');
            update new Data_Update_Log__c(Id = logId, Field_Decisions_JSON__c = JSON.serialize(decisions));
            rolled = DataUpdateReviewController.rollbackChange(logId, HIST_ONLY_KEY);
        }
        Test.stopTest();

        System.assert(rolled.success, 'Rollback should succeed: ' + rolled.errorMessage);
        System.assertEquals(0, Database.countQuery('SELECT COUNT() FROM Attendance_History__c WHERE Account__c = \'' + e.Id + '\''));
    }

    @IsTest
    static void historyOnly_RollbackDmlError_RestoresEverything() {
        User usr = dataUpdateUser();
        Account e = createEglise('Eglise HistOnly4 ' + uniq());
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
        System.assertEquals(1, Database.countQuery('SELECT COUNT() FROM Attendance_History__c WHERE Account__c = \'' + e.Id + '\''),
            'A failed rollback must leave the history row in place');
    }

    @IsTest
    static void historyOnly_DateAndRowHelpers() {
        Account e = createEglise('Eglise HistOnly5 ' + uniq());
        Data_Update_Request__c t = createRequestFor(e.Id, 'Fake_HistOnly_Form', '{}');
        t = [SELECT Id, CreatedDate, Target_Record_Id__c FROM Data_Update_Request__c WHERE Id = :t.Id];
        DataUpdateFormConfigService.FormFieldConfig fc = new DataUpdateFormConfigService.FormFieldConfig();
        fc.fieldApiName = HIST_ONLY_KEY;
        fc.historyMode = 'History_Only';
        fc.historyTargetObjectApiName = 'Attendance_History__c';
        fc.historyTargetValueFieldApiName = 'Value__c';
        fc.historyTargetDateFieldApiName = 'Metric_Date__c';
        fc.historyTargetAccountFieldApiName = 'Account__c';

        String dateKey = HIST_ONLY_KEY + '@date';
        System.assertEquals(Date.newInstance(2026, 3, 4),
            DataUpdateReviewController.resolveHistoryDate(fc, new Map<String, String>{ dateKey => '2026-03-04' }, t));
        System.assertEquals(t.CreatedDate.date(),
            DataUpdateReviewController.resolveHistoryDate(fc, new Map<String, String>{ dateKey => 'not-a-date' }, t));
        System.assertEquals(Date.today(),
            DataUpdateReviewController.resolveHistoryDate(fc, new Map<String, String>(), new Data_Update_Request__c()));

        SObject row = DataUpdateReviewController.buildHistoryOnlyRow(fc, t, new Map<String, String>{ HIST_ONLY_KEY => '9' }, null);
        System.assertEquals(9, (Decimal) row.get('Value__c'));
        System.assertEquals(e.Id, row.get('Account__c'));
        System.assertEquals(t.CreatedDate.date(), row.get('Metric_Date__c'));
    }

    // ─── Rediseño: encabezado, campos idénticos, candado y presencia ────────

    @IsTest
    static void getComparisonData_ReturnsHeaderAndUnchangedFields() {
        String U = uniq();
        Account a = createTestPersonAccount('Gagnon' + U, 'Marc');
        a = queryAccountEmailAndPhone(a.Id);
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{
            'PersonEmail' => 'brandnew' + U + '@example.com',
            'PersonMobilePhone' => getPersonMobilePhone(a)
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
        System.assertEquals('PersonMobilePhone', data.unchangedFields[0].fieldApiName);
        System.assertEquals(false, data.unchangedFields[0].isDifferent);
        System.assertEquals('Marc Gagnon', data.requestedName);
        System.assertEquals(t.Requested_Email__c, data.requestedEmail);
        System.assertNotEquals(null, data.requestNumber);
        System.assertNotEquals(null, data.createdDate);
    }

    @IsTest
    static void getRequests_ReportsLockAndOtherViewers() {
        String U = uniq();
        Account locked = createTestPersonAccount('Roy' + U, 'Anne');
        locked.put('Data_Update_Locked__c', true);
        update locked;
        Account open = createTestPersonAccount('Roy' + U, 'Paul');
        Data_Update_Request__c tLocked = createReviewRequest(locked.Id, '{"PersonEmail":"a@example.com"}');
        Data_Update_Request__c tOpen = createReviewRequest(open.Id, '{"PersonEmail":"b@example.com"}');
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
        Account a = createTestPersonAccount('Cote' + U, 'Julie');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"PersonEmail":"c@example.com"}');
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

    private static final String HT_KEY = 'Attendance_History__c#table';

    private static void useHistoryTableFakeForm() {
        DataUpdateFormConfigService.testFormMdt = (Data_Update_Form__mdt) JSON.deserialize(
            '{"DeveloperName":"Fake_Table_Form","MasterLabel":"Fake","Target_Object_API_Name__c":"Account",'
            + '"Identity_Field_1_API_Name__c":"Name","Identity_Field_1_Comparison__c":"Exact",'
            + '"Subject_Template__c":"{RecordName}","Is_Active__c":true,"Lock_Field_API_Name__c":"Data_Update_Locked__c",'
            + '"Lock_Date_Field_API_Name__c":"Data_Update_Locked_Date__c"}',
            Data_Update_Form__mdt.class);
        String columns = '[{"f":"Metric_Date__c","fr":"Date","en":"Date"},{"f":"Value__c","fr":"Personnes","en":"People"}]';
        DataUpdateFormConfigService.testFieldMdts = (List<Data_Update_Form_Field__mdt>) JSON.deserialize(
            '[{"Field_API_Name__c":"Phone","Label_FR__c":"T","Label_EN__c":"T","Display_Order__c":1,'
            + '"Input_Type__c":"Phone","History_Mode__c":"Replace","Is_Active__c":true},'
            + '{"Field_API_Name__c":"' + HT_KEY + '","Label_FR__c":"Assistance","Label_EN__c":"Attendance",'
            + '"Display_Order__c":2,"Input_Type__c":"Text","History_Mode__c":"History_Table","Is_Active__c":true,'
            + '"History_Target_Object_API_Name__c":"Attendance_History__c","History_Target_Date_Field_API_Name__c":"Metric_Date__c",'
            + '"History_Target_Account_Field_API_Name__c":"Account__c","History_Target_Log_Field_API_Name__c":"Log__c",'
            + '"History_Table_Columns__c":' + JSON.serialize(columns) + '}]',
            List<Data_Update_Form_Field__mdt>.class);
    }

    private static String htValue(List<List<String>> rows) {
        return JSON.serialize(new Map<String, Object>{
            'cols' => new List<String>{ 'Metric_Date__c', 'Value__c' },
            'rows' => rows
        });
    }

    @IsTest
    static void historyTable_CompareApplyOverwriteRollback() {
        User usr = dataUpdateUser();
        Account e = createEglise('Eglise Table ' + uniq());
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
        Map<Date, Decimal> byDate = attendanceByDate(e.Id);
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
        Account e = createEglise('Eglise Table2 ' + uniq());
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

    private static Map<Date, Decimal> attendanceByDate(Id accountId) {
        Map<Date, Decimal> out = new Map<Date, Decimal>();
        for (SObject row : Database.query('SELECT Metric_Date__c, Value__c FROM Attendance_History__c WHERE Account__c = \'' + accountId + '\'')) {
            out.put((Date) row.get('Metric_Date__c'), (Decimal) row.get('Value__c'));
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
        Account a = createTestPersonAccount('Guard' + U, 'Test');
        Data_Update_Request__c applied = createReviewRequest(a.Id, '{"PersonEmail":"x@example.com"}');
        update new Data_Update_Request__c(
            Id = applied.Id, Status__c = 'Applied', Final_Action__c = 'Applied', Closed_Reason__c = 'Applied'
        );
        Data_Update_Request__c open = createReviewRequest(a.Id, '{"PersonEmail":"y@example.com"}');

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
        Account a = createTestPersonAccount('LowMail' + U, 'Test');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"PersonEmail":"ok' + U + '@example.com"}');

        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(t.Id, 'PersonEmail', 'New.Mail' + U + '@Example.CA');
        Test.stopTest();

        System.assert(result.success, result.errorMessage);
        System.assertEquals(('new.mail' + U + '@example.ca').toLowerCase(), result.newValue);
    }

    @IsTest
    static void correctProposedValue_InvalidEmail_RefusedBeforeApply() {
        String U = uniq();
        Account a = createTestPersonAccount('BadMail' + U, 'Test');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"PersonEmail":"ok' + U + '@example.com"}');

        Test.startTest();
        DataUpdateWrapper.CorrectionResult result = DataUpdateReviewController.correctProposedValue(t.Id, 'PersonEmail', 'not-an-email');
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals('INVALID_EMAIL', result.errorMessage);
        System.assert([SELECT Proposed_Values_JSON__c FROM Data_Update_Request__c WHERE Id = :t.Id].Proposed_Values_JSON__c
            .contains('ok' + U + '@example.com'), 'the stored value is untouched');
        System.assertEquals(0, [SELECT COUNT() FROM Data_Update_Log__c WHERE Request__c = :t.Id AND Action_Type__c = 'CORRECTED']);
    }

    // ─── Coverage: date-less history previews, Datetime tables, rollback guards ──

    // User without Modify All Data, without delete on the history objects and without the
    // Data Update Center permission set: delete DML on someone else's row fails for them.
    private static User lowPrivUser() {
        Set<Id> canDeleteHistory = new Set<Id>();
        for (ObjectPermissions op : [SELECT Parent.ProfileId FROM ObjectPermissions
                                     WHERE SobjectType = 'Attendance_History__c' AND PermissionsDelete = true
                                     AND Parent.IsOwnedByProfile = true]) {
            canDeleteHistory.add(op.Parent.ProfileId);
        }
        User usr;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE UserLicense.Name = 'Salesforce'
                         AND PermissionsModifyAllData = false AND Id NOT IN :canDeleteHistory LIMIT 1];
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
            Target_Object_API_Name__c = 'Account', Target_Record_Id__c = t.Target_Record_Id__c,
            Before_Snapshot_JSON__c = '{}', Field_Decisions_JSON__c = decisionsJson
        );
    }

    @IsTest
    static void getComparisonData_HistoryFieldsWithoutDateField_ShowNoDate() {
        User usr = dataUpdateUser();
        Account e = createEglise('Eglise NoDate ' + uniq());
        insert newAttendanceRow(e.Id, 12, Date.newInstance(2026, 8, 1));
        Data_Update_Request__c t = createRequestFor(e.Id, 'Fake_NoDate_Form', JSON.serialize(new Map<String, String>{
            HIST_ONLY_KEY => '42',
            'Phone' => '514-555-0142'
        }));
        DataUpdateFormConfigService.testFormMdt = (Data_Update_Form__mdt) JSON.deserialize(
            '{"DeveloperName":"Fake_NoDate_Form","MasterLabel":"Fake","Target_Object_API_Name__c":"Account",'
            + '"Identity_Field_1_API_Name__c":"Name","Identity_Field_1_Comparison__c":"Exact",'
            + '"Subject_Template__c":"{RecordName}","Is_Active__c":true}',
            Data_Update_Form__mdt.class);
        DataUpdateFormConfigService.testFieldMdts = (List<Data_Update_Form_Field__mdt>) JSON.deserialize(
            '[{"Field_API_Name__c":"' + HIST_ONLY_KEY + '","Label_FR__c":"A","Label_EN__c":"A",'
            + '"Display_Order__c":1,"Input_Type__c":"Number","History_Mode__c":"History_Only","Is_Active__c":true,'
            + '"History_Target_Object_API_Name__c":"Attendance_History__c","History_Target_Value_Field_API_Name__c":"Value__c",'
            + '"History_Target_Account_Field_API_Name__c":"Account__c"},'
            + '{"Field_API_Name__c":"Phone","Label_FR__c":"T","Label_EN__c":"T","Display_Order__c":2,'
            + '"Input_Type__c":"Phone","History_Mode__c":"Historize","Is_Active__c":true,'
            + '"History_Target_Object_API_Name__c":"Attendance_History__c","History_Target_Value_Field_API_Name__c":"Value__c",'
            + '"History_Target_Account_Field_API_Name__c":"Account__c"}]',
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
        Account a = createTestPersonAccount('TableDt' + uniq(), 'Test');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{}');
        insert new List<Data_Update_Log__c>{
            new Data_Update_Log__c(Request__c = t.Id, Action_Type__c = 'CORRECTED', Target_Object_API_Name__c = 'Account', Before_Snapshot_JSON__c = '{}',
                                   Target_Record_Id__c = a.Id, Performed_Date__c = Datetime.newInstanceGmt(2026, 8, 2, 12, 0, 0)),
            new Data_Update_Log__c(Request__c = t.Id, Action_Type__c = 'CORRECTED', Target_Object_API_Name__c = 'Account', Before_Snapshot_JSON__c = '{}',
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
        Account e = createEglise('Eglise TableDt ' + uniq());
        Data_Update_Request__c t = createRequestFor(e.Id, 'Fake_Table_Form', '{}');
        Data_Update_Request__c other = createRequestFor(e.Id, 'Fake_Table_Form', '{}');
        Data_Update_Log__c overwritten = new Data_Update_Log__c(
            Request__c = other.Id, Action_Type__c = 'CORRECTED', Target_Object_API_Name__c = 'Account',
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
        Account relocked = (Account) Database.query('SELECT Data_Update_Locked__c, Data_Update_Locked_Date__c FROM Account WHERE Id = \'' + e.Id + '\'');
        System.assertEquals(true, relocked.get('Data_Update_Locked__c'));
        System.assertNotEquals(null, relocked.get('Data_Update_Locked_Date__c'), 'Rollback relocks with a date');
        System.assertEquals('Reopened', [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c);
    }

    @IsTest
    static void historyRollbacks_UnusableHistoryObject_ReturnGenericError() {
        User usr = dataUpdateUser();
        User low = lowPrivUser();
        Account e = createEglise('Eglise Guard ' + uniq());
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
        Account a = createTestPersonAccount('Gone' + uniq(), 'Test');
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
        Account a = createTestPersonAccount('Presence' + uniq(), 'Test');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"PersonEmail":"p@example.com"}');
        Data_Update_Request__c other = createReviewRequest(a.Id, '{"PersonEmail":"q@example.com"}');
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
                Target_Object_API_Name__c = 'Account',
                Target_Record_Id__c = 'not-an-id',
                Update_Form_DeveloperName__c = FORM_NAME,
                Status__c = 'New',
                Subject__c = 'BadTargetMarker' + U,
                Proposed_Values_JSON__c = '{"PersonEmail":"x@example.com"}'
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
        Account a = createTestPersonAccount('Statut' + U, 'Test');
        Data_Update_Request__c t = createReviewRequest(a.Id, '{"PersonEmail":"x@example.com"}');
        update new Data_Update_Request__c(Id = t.Id, Notes__c = '[HIST:On Hold||||||Old note|||2020-01-01]');
        DataUpdateReviewController.correctProposedValue(t.Id, 'PersonEmail', 'y' + U + '@example.com');

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
        Account same = createTestPersonAccount('Pareil' + U, 'Anne');
        Data_Update_Request__c tSame = createReviewRequest(same.Id, JSON.serialize(new Map<String, String>{
            'PersonEmail' => 'a' + U + '@example.com', 'PersonMobilePhone' => '5140000000'
        }));
        Account diff = createTestPersonAccount('Autre' + U, 'Paul');
        Data_Update_Request__c tDiff = createReviewRequest(diff.Id, JSON.serialize(new Map<String, String>{
            'PersonEmail' => 'b' + U + '@example.com', 'PersonMobilePhone' => '5147778888'
        }));
        Account all = createTestPersonAccount('Tout' + U, 'Luc');
        Data_Update_Request__c tAll = createReviewRequest(all.Id, JSON.serialize(new Map<String, String>{
            'PersonEmail' => 'c' + U + '@example.com'
        }));

        Test.startTest();
        System.assert(DataUpdateReviewController.applySelectedUpdates(tSame.Id, new List<String>{ 'PersonEmail' }).success);
        System.assert(DataUpdateReviewController.applySelectedUpdates(tDiff.Id, new List<String>{ 'PersonEmail' }).success);
        System.assert(DataUpdateReviewController.applySelectedUpdates(tAll.Id, new List<String>{ 'PersonEmail' }).success);
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
        Account withTicket = createTestPersonAccount('Ouvert' + U, 'Chantal');
        Account free = createTestPersonAccount('Libre' + U, 'Serge');
        for (Account a : new List<Account>{ withTicket, free }) {
            a.put('Data_Update_Locked__c', true);
            a.put('Data_Update_Locked_Date__c', Datetime.now());
        }
        update new List<Account>{ withTicket, free };
        createReviewRequest(withTicket.Id, '{"PersonEmail":"x@example.com"}');

        Test.startTest();
        DataUpdateWrapper.LockedRecordListResult result = DataUpdateReviewController.getLockedRecords(FORM_NAME, 25, 0, null);
        Test.stopTest();

        System.assert(result.success);
        System.assertEquals(2, result.totalCount);
        System.assertEquals(1, result.unlockableCount, 'A record with an open ticket cannot be unlocked');
    }

    // ─── "Save in" (email and phone rows) ───────────────────────────────────

    // In-memory person account form with a text, a phone and an email question.
    private static void useSaveOptionsFakeForm() {
        DataUpdateFormConfigService.testFormMdt = (Data_Update_Form__mdt) JSON.deserialize(
            '{"DeveloperName":"Fake_Save_Form","MasterLabel":"Fake","Target_Object_API_Name__c":"Account",'
            + '"Identity_Field_1_API_Name__c":"Name","Identity_Field_1_Comparison__c":"Exact",'
            + '"Subject_Template__c":"{RecordName}","Is_Active__c":true}',
            Data_Update_Form__mdt.class);
        DataUpdateFormConfigService.testFieldMdts = (List<Data_Update_Form_Field__mdt>) JSON.deserialize(
            '[{"Field_API_Name__c":"FirstName","Label_FR__c":"P","Label_EN__c":"F","Display_Order__c":1,'
            + '"Input_Type__c":"Text","History_Mode__c":"Replace","Is_Active__c":true},'
            + '{"Field_API_Name__c":"PersonMobilePhone","Label_FR__c":"T","Label_EN__c":"T","Display_Order__c":2,'
            + '"Input_Type__c":"Phone","History_Mode__c":"Replace","Is_Active__c":true},'
            + '{"Field_API_Name__c":"PersonEmail","Label_FR__c":"C","Label_EN__c":"E","Display_Order__c":3,'
            + '"Input_Type__c":"Email","History_Mode__c":"Replace","Is_Active__c":true}]',
            List<Data_Update_Form_Field__mdt>.class);
    }

    @IsTest
    static void saveOptions_ComparisonOffersEmailAndPhonePlaces() {
        useSaveOptionsFakeForm();
        String U = uniq();
        Account a = createTestPersonAccount('Places' + U, 'Lea');
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{
            'PersonMobilePhone' => '5145550101', 'PersonEmail' => 'n' + U + '@example.com', 'FirstName' => 'Autre' }));

        DataUpdateWrapper.ComparisonData cmp = DataUpdateReviewController.getComparisonData(t.Id);

        Map<String, String> kinds = new Map<String, String>();
        for (DataUpdateWrapper.ComparisonField cf : cmp.fields) kinds.put(cf.fieldApiName, cf.saveKind);
        System.assertEquals('PHONE', kinds.get('PersonMobilePhone'));
        System.assertEquals('EMAIL', kinds.get('PersonEmail'));
        System.assertEquals(null, kinds.get('FirstName'), 'Text rows never move');
        Map<String, DataUpdateWrapper.GroupSlotGroup> byKind = new Map<String, DataUpdateWrapper.GroupSlotGroup>();
        for (DataUpdateWrapper.GroupSlotGroup g : cmp.saveOptions) byKind.put(g.kind, g);
        System.assert(byKind.containsKey('PHONE') && byKind.containsKey('EMAIL'));
        Boolean hasMobile = false;
        for (DataUpdateWrapper.GroupSlot slot : byKind.get('PHONE').slots) {
            System.assertNotEquals('Fax', slot.apiName);
            System.assertEquals(null, slot.preference, 'AEBEQ has no preferred phone');
            if (slot.apiName == 'PersonMobilePhone') hasMobile = slot.value == '5140000000';
        }
        System.assert(hasMobile, 'Each place shows what it holds now');
    }

    @IsTest
    static void saveOptions_BusinessAccount_NoPersonFields() {
        Account a = createEglise('Places ' + uniq());
        List<DataUpdateWrapper.GroupSlotGroup> groups = DataUpdateReviewController.buildSaveOptions(a.Id,
            Account.SObjectType.getDescribe().fields.getMap());
        for (DataUpdateWrapper.GroupSlotGroup g : groups) {
            for (DataUpdateWrapper.GroupSlot slot : g.slots) {
                System.assert(!slot.apiName.startsWith('Person'), slot.apiName);
            }
        }
    }

    @IsTest
    static void applyWithOptions_PhoneSavedInOtherField() {
        useSaveOptionsFakeForm();
        String U = uniq();
        Account a = createTestPersonAccount('Autre' + U, 'Lea');
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{ 'PersonMobilePhone' => '5145550102' }));

        DataUpdateWrapper.ApplyResult applied = DataUpdateReviewController.applySelectedUpdatesWithOptions(t.Id,
            new List<String>{ 'PersonMobilePhone' }, null, '{"overrides":{"PersonMobilePhone":"PersonHomePhone"}}');

        System.assert(applied.success, applied.errorMessage);
        Account after = (Account) Database.query('SELECT PersonMobilePhone, PersonHomePhone FROM Account WHERE Id = \'' + a.Id + '\'');
        System.assertEquals('5145550102', after.get('PersonHomePhone'));
        System.assertEquals('5140000000', after.get('PersonMobilePhone'), 'The mobile phone is not overwritten');
    }

    @IsTest
    static void applyWithOptions_InvalidChoices_Refused() {
        useSaveOptionsFakeForm();
        String U = uniq();
        Account a = createTestPersonAccount('Refus' + U, 'Lea');
        Data_Update_Request__c t = createReviewRequest(a.Id, JSON.serialize(new Map<String, String>{
            'FirstName' => 'Autre', 'PersonMobilePhone' => '5145550104' }));
        List<String> rows = new List<String>{ 'FirstName', 'PersonMobilePhone' };

        System.assertEquals('GENERIC_ERROR', DataUpdateReviewController.applySelectedUpdatesWithOptions(t.Id, rows, null, '{bad').errorMessage);
        System.assertEquals('INVALID_SAVE_CHOICE', DataUpdateReviewController.applySelectedUpdatesWithOptions(t.Id, rows, null,
            '{"overrides":{"FirstName":"LastName"}}').errorMessage, 'A text value never moves to another field');
        System.assertEquals('Lea', (String) Database.query('SELECT FirstName FROM Account WHERE Id = \'' + a.Id + '\'')[0].get('FirstName'), 'Nothing applied');
        System.assertEquals('New', [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c,
            'A choice to fix never marks the ticket as Error');
        System.assertEquals(0, [SELECT COUNT() FROM Data_Update_Log__c WHERE Request__c = :t.Id AND Action_Type__c = 'APPLY_ERROR']);

        System.assert(DataUpdateReviewController.stringMap('x').isEmpty());
        System.assertEquals(new Map<String, String>{ 'a' => '1' },
            DataUpdateReviewController.stringMap(new Map<String, Object>{ 'a' => 1, 'b' => null }));
        DataUpdateWrapper.ApplyResult ok = DataUpdateReviewController.applySelectedUpdatesWithOptions(t.Id, rows, null, null);
        System.assert(ok.success, ok.errorMessage);
    }
}
