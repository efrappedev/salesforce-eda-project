@IsTest(SeeAllData=false)
private class DataUpdateMultiTicketReviewTest {

    private static final String FORM_NAME = 'SEMBEQ_Contact_Update';

    private static String uniq() {
        return String.valueOf(DateTime.now().getTime()) + String.valueOf(Crypto.getRandomInteger());
    }

    private static Contact createPerson(String lastName) {
        Contact a = new Contact(LastName = lastName, FirstName = 'Lucie');
        a.put('Email', 'current' + uniq() + '@example.com');
        Database.DMLOptions dmo = new Database.DMLOptions();
        dmo.DuplicateRuleHeader.allowSave = true;
        dmo.DuplicateRuleHeader.runAsCurrentUser = true;
        Database.SaveResult sr = Database.insert(new List<SObject>{ a }, dmo)[0];
        System.assert(sr.isSuccess(), 'Insert failed');
        a.Id = sr.getId();
        return a;
    }

    private static Data_Update_Request__c createRequest(Id accountId, String proposedJson) {
        return createRequest(accountId, proposedJson, FORM_NAME);
    }

    private static Data_Update_Request__c createRequest(Id accountId, String proposedJson, String formName) {
        // Grouping only applies to "multiple submissions" forms — flag the test form as one.
        DataUpdateReviewController.multiSubmissionFormsForTest = new Set<String>{ FORM_NAME };
        Data_Update_Request__c t = new Data_Update_Request__c(
            Target_Object_API_Name__c = 'Contact',
            Target_Record_Id__c = accountId,
            Update_Form_DeveloperName__c = formName,
            Status__c = 'New',
            Subject__c = 'Group request ' + uniq(),
            Proposed_Values_JSON__c = proposedJson
        );
        insert t;
        return t;
    }

    @IsTest
    static void getGroupContext_ListsOpenTicketsAndSlots() {
        DataUpdateMultiTicketReviewController.bypassPermissionForTest = true;
        Contact a = createPerson('Grp' + uniq());
        createRequest(a.Id, JSON.serialize(new Map<String, String>{ 'Email' => 'a' + uniq() + '@example.com' }));
        createRequest(a.Id, JSON.serialize(new Map<String, String>{ 'Email' => 'b' + uniq() + '@example.com' }));

        Test.startTest();
        DataUpdateWrapper.GroupContext ctx = DataUpdateMultiTicketReviewController.getGroupContext(a.Id);
        Test.stopTest();

        System.assert(ctx.success, ctx.errorMessage);
        System.assertEquals(2, ctx.tickets.size());
        Boolean hasEmails = false;
        for (DataUpdateWrapper.GroupSlotGroup g : ctx.slotGroups) {
            if (g.kind == 'EMAIL' && !g.slots.isEmpty()) hasEmails = true;
        }
        System.assert(hasEmails, 'Contact has email fields to save to');

        DataUpdateWrapper.GroupContext bad = DataUpdateMultiTicketReviewController.getGroupContext('not-an-id');
        System.assertEquals(false, bad.success);
    }

    @IsTest
    static void getGroupContext_NeedsPermission() {
        Exception caught;
        try {
            DataUpdateMultiTicketReviewController.getGroupContext(UserInfo.getUserId());
        } catch (Exception e) {
            caught = e;
        }
        System.assertEquals(DataUpdateReviewController.getCanMultiTicketReview() == false, caught != null);
    }

    @IsTest
    static void applyGroupTicket_RedirectsLogsNotesAndRollsBack() {
        DataUpdateMultiTicketReviewController.bypassPermissionForTest = true;
        Contact a = createPerson('Grp' + uniq());
        String newEmail = 'new' + uniq() + '@example.com';
        Data_Update_Request__c t = createRequest(a.Id, JSON.serialize(new Map<String, String>{ 'Email' => newEmail }));

        // Pick another email field of the record to save the value in.
        DataUpdateWrapper.GroupContext ctx = DataUpdateMultiTicketReviewController.getGroupContext(a.Id);
        String other;
        for (DataUpdateWrapper.GroupSlotGroup g : ctx.slotGroups) {
            if (g.kind != 'EMAIL') continue;
            for (DataUpdateWrapper.GroupSlot s : g.slots) {
                if (s.apiName != 'Email' && String.isBlank(s.value)) other = s.apiName;
            }
        }
        System.assertNotEquals(null, other, 'Needs a free email field');

        Map<String, Object> plan = new Map<String, Object>{
            'fields'      => new List<String>{ 'Email' },
            'overrides'   => new Map<String, String>{ 'Email' => other },
            'tables'      => new Map<String, Object>(),
            'groupOthers' => 2,
            'recordName'  => 'Test church',
            'notApplied'  => new List<Object>{ new Map<String, Object>{
                'labelFr' => 'Téléphone', 'labelEn' => 'Phone', 'value' => '514', 'reason' => 'SAME_AS_SF', 'ticket' => '' } }
        };

        Test.startTest();
        DataUpdateWrapper.ApplyResult res = DataUpdateMultiTicketReviewController.applyGroupTicket(t.Id, JSON.serialize(plan));
        System.assert(res.success, res.errorMessage);
        Id recId = a.Id;
        SObject after = Database.query('SELECT ' + other + ' FROM Contact WHERE Id = :recId');
        System.assertEquals(newEmail, after.get(other), 'Saved in the chosen field');

        DataUpdateWrapper.AuditLogResult audit = DataUpdateReviewController.getAuditLog(t.Id);
        System.assert(audit.success);
        DataUpdateWrapper.AuditLogEntry entry = audit.entries[0];
        System.assertEquals(2, entry.groupOthers);
        System.assertEquals('Test church', entry.groupRecordName);
        System.assertEquals(1, entry.notApplied.size());
        System.assertEquals(1, entry.fieldChanges.size(), 'Notes are not fields');
        System.assertEquals(other, entry.fieldChanges[0].fieldApiName);
        System.assert(entry.fieldChanges[0].canRollback);

        DataUpdateWrapper.ApplyResult note = DataUpdateReviewController.rollbackChange(entry.logId, '__group');
        System.assertEquals(false, note.success, 'A note is never rolled back');
        DataUpdateWrapper.ApplyResult rb = DataUpdateReviewController.rollbackChange(entry.logId, other);
        Test.stopTest();

        System.assert(rb.success, rb.errorMessage);
        SObject restored = Database.query('SELECT ' + other + ' FROM Contact WHERE Id = :recId');
        System.assertEquals(null, restored.get(other), 'Back to empty');
    }

    @IsTest
    static void applyGroupTicket_EmptyPlanClosesAndBadPlans() {
        DataUpdateMultiTicketReviewController.bypassPermissionForTest = true;
        Contact a = createPerson('Grp' + uniq());
        Data_Update_Request__c t = createRequest(a.Id, JSON.serialize(new Map<String, String>{ 'Email' => 'x' + uniq() + '@example.com' }));
        Data_Update_Request__c t2 = createRequest(a.Id, JSON.serialize(new Map<String, String>{ 'Email' => 'y' + uniq() + '@example.com' }));

        Test.startTest();
        DataUpdateWrapper.ApplyResult broken = DataUpdateMultiTicketReviewController.applyGroupTicket(t.Id, '{not json');
        System.assertEquals(false, broken.success);

        // A place of another kind is refused.
        DataUpdateWrapper.ApplyResult wrongKind = DataUpdateMultiTicketReviewController.applyGroupTicket(t2.Id, JSON.serialize(new Map<String, Object>{
            'fields' => new List<String>{ 'Email' }, 'overrides' => new Map<String, String>{ 'Email' => 'Phone' } }));
        System.assertEquals(false, wrongKind.success);

        DataUpdateWrapper.ApplyResult empty = DataUpdateMultiTicketReviewController.applyGroupTicket(t.Id, '');
        Test.stopTest();

        System.assert(empty.success, empty.errorMessage);
        System.assertEquals('Applied', [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c);
    }

    @IsTest
    static void getRequests_CarriesGroupData() {
        Contact a = createPerson('Grp' + uniq());
        createRequest(a.Id, JSON.serialize(new Map<String, Object>{
            'Email' => 'g' + uniq() + '@example.com',
            'Task#table' => '{"cols":["ActivityDate","CallDurationInSeconds"],"rows":[["2026-01-04","80"],["2026-01-11","82"]]}'
        }));
        createRequest(a.Id, JSON.serialize(new Map<String, String>{ 'Email' => 'h' + uniq() + '@example.com' }));

        Test.startTest();
        DataUpdateWrapper.RequestListResult res = DataUpdateReviewController.getRequests('Open', 'All', '', 50, 0);
        Test.stopTest();

        System.assert(res.success);
        Integer rows = 0;
        for (DataUpdateWrapper.RequestSummary s : res.requests) {
            if (s.targetRecordId != String.valueOf(a.Id)) continue;
            System.assertEquals(2, s.targetOpenCount);
            System.assertNotEquals(null, s.targetName);
            rows += s.tableRowCount;
        }
        System.assertEquals(2, rows, 'Two history lines');
    }

    @IsTest
    static void grouping_OnlyMultipleSubmissionForms() {
        DataUpdateMultiTicketReviewController.bypassPermissionForTest = true;
        Contact a = createPerson('Grp' + uniq());
        createRequest(a.Id, JSON.serialize(new Map<String, String>{ 'Email' => 'm' + uniq() + '@example.com' }));
        createRequest(a.Id, JSON.serialize(new Map<String, String>{ 'Email' => 'o' + uniq() + '@example.com' }), 'Single_Submission_Form');

        Test.startTest();
        DataUpdateWrapper.GroupContext ctx = DataUpdateMultiTicketReviewController.getGroupContext(a.Id);
        DataUpdateWrapper.RequestListResult res = DataUpdateReviewController.getRequests('Open', 'All', '', 50, 0);
        Test.stopTest();

        System.assertEquals(1, ctx.tickets.size(), 'Only the multiple-submissions ticket is grouped');
        for (DataUpdateWrapper.RequestSummary s : res.requests) {
            if (s.targetRecordId != String.valueOf(a.Id)) continue;
            Integer expected = s.updateFormDeveloperName == FORM_NAME ? 1 : 0;
            System.assertEquals(expected, s.targetOpenCount, 'Other forms never group');
        }
    }

    @IsTest
    static void getMultiSubmissionForms_ReadsCmdt() {
        DataUpdateReviewController.multiSubmissionFormsForTest = null;
        System.assertNotEquals(null, DataUpdateReviewController.getMultiSubmissionForms());
    }

    @IsTest
    static void applyGroupTicket_TwoValuesForOneField_Refused() {
        DataUpdateMultiTicketReviewController.bypassPermissionForTest = true;
        Contact a = createPerson('Grp' + uniq());
        Data_Update_Request__c t = createRequest(a.Id, JSON.serialize(new Map<String, String>{
            'HomePhone' => '514-555-0101', 'MobilePhone' => '514-555-0102' }));

        Test.startTest();
        // Both phones sent to the same other field.
        DataUpdateWrapper.ApplyResult sameDest = DataUpdateMultiTicketReviewController.applyGroupTicket(t.Id, JSON.serialize(new Map<String, Object>{
            'fields' => new List<String>{ 'HomePhone', 'MobilePhone' },
            'overrides' => new Map<String, String>{ 'HomePhone' => 'OtherPhone', 'MobilePhone' => 'OtherPhone' } }));
        // One phone sent into a field that also gets its own value.
        DataUpdateWrapper.ApplyResult ownField = DataUpdateMultiTicketReviewController.applyGroupTicket(t.Id, JSON.serialize(new Map<String, Object>{
            'fields' => new List<String>{ 'HomePhone', 'MobilePhone' },
            'overrides' => new Map<String, String>{ 'MobilePhone' => 'HomePhone' } }));
        Test.stopTest();

        System.assertEquals(false, sameDest.success);
        System.assertEquals(false, ownField.success);
        System.assertNotEquals('Applied', [SELECT Status__c FROM Data_Update_Request__c WHERE Id = :t.Id].Status__c, 'Nothing applied');
    }
}
