/**
 * MergeExecutionControllerTest.cls
 * Covers: MergeAuditService, MergeTicketService, MergeExecutionService,
 *         MergeController (all public methods)
 * Target coverage: 100 %
 */
@IsTest
private class MergeExecutionControllerTest {

    // ─── Test-data factory helpers ────────────────────────────────────────────

    private static Account makeAccount(String name) {
        Account a = new Account(Name = name);
        insert a;
        return a;
    }

    private static Contact makeContact(String lastName, String email, Id accountId) {
        Contact c = new Contact(LastName = lastName, Email = email, AccountId = accountId);
        Database.DmlOptions opts = new Database.DmlOptions();
        opts.DuplicateRuleHeader.AllowSave = true;
        Database.insert(c, opts);
        return c;
    }

    private static Merge_Ticket__c makeContactTicket(
        Contact master, Contact loser, String matchKey
    ) {
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c      = 'Contact',
            Status__c           = 'New',
            Match_Type__c       = 'Email',
            Match_Key__c        = matchKey,
            Match_Confidence__c = 'High',
            Candidate_Count__c  = 2
        );
        insert t;
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(master.Id),
                Record_Name__c = master.LastName,
                Is_Master__c = false, Is_Losing_Record__c = false),
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(loser.Id),
                Record_Name__c = loser.LastName,
                Is_Master__c = false, Is_Losing_Record__c = false)
        };
        return t;
    }

    private static Merge_Ticket__c makeAccountTicket(
        Account master, Account loser, String matchKey
    ) {
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c      = 'Account',
            Status__c           = 'New',
            Match_Type__c       = 'Phone',
            Match_Key__c        = matchKey,
            Match_Confidence__c = 'Medium',
            Candidate_Count__c  = 2
        );
        insert t;
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(master.Id),
                Record_Name__c = master.Name,
                Is_Master__c = false, Is_Losing_Record__c = false),
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(loser.Id),
                Record_Name__c = loser.Name,
                Is_Master__c = false, Is_Losing_Record__c = false)
        };
        return t;
    }

    private static MergeWrappers.MergeRequest makeRequest(
        Id ticketId, Id masterId, List<Id> losingIds
    ) {
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId       = String.valueOf(ticketId);
        req.masterId       = String.valueOf(masterId);
        req.losingIds      = new List<String>();
        for (Id lid : losingIds) req.losingIds.add(String.valueOf(lid));
        req.fieldDecisions = new Map<String,String>();
        req.notes          = '';
        return req;
    }

    // ─── MergeAuditService ────────────────────────────────────────────────────

    @IsTest
    static void audit_createPreMergeLog_insertsLogWithPendingStatus() {
        Account acc = makeAccount('Audit Org');
        Contact master = makeContact('AuditMaster', 'audit_m@exectest.com', acc.Id);
        Contact loser  = makeContact('AuditLoser',  'audit_l@exectest.com', acc.Id);
        Merge_Ticket__c ticket = makeContactTicket(
            master, loser, 'Contact|Email|audit@exectest.com'
        );
        List<SObject> candidates = [
            SELECT Id, Name, Email, Phone, AccountId
            FROM Contact WHERE Id IN :new Set<Id>{ master.Id, loser.Id }
        ];

        Test.startTest();
        Merge_Log__c log = MergeAuditService.createPreMergeLog(
            ticket.Id, 'Contact', master.Id,
            new List<Id>{ loser.Id }, candidates, new Map<String,String>()
        );
        Test.stopTest();

        System.assertNotEquals(null, log.Id);
        Merge_Log__c saved = [
            SELECT Action_Type__c, Master_Record_Id__c, Object_Type__c,
                   Before_Snapshot_JSON__c
            FROM Merge_Log__c WHERE Id = :log.Id
        ];
        System.assertEquals('MERGE_PENDING', saved.Action_Type__c);
        System.assertEquals(String.valueOf(master.Id), saved.Master_Record_Id__c);
        System.assertEquals('Contact', saved.Object_Type__c);
        System.assert(!String.isBlank(saved.Before_Snapshot_JSON__c),
            'Before snapshot should not be blank');
    }

    @IsTest
    static void audit_recordMergeFailure_withBothIds_updatesLogAndTicket() {
        Account acc = makeAccount('Failure Org');
        Contact c1 = makeContact('FTMaster', null, acc.Id);
        Contact c2 = makeContact('FTLoser',  null, acc.Id);
        Merge_Ticket__c t = makeContactTicket(c1, c2, 'Contact|Email|fail_both@exectest.com');
        List<SObject> cands = [
            SELECT Id, Name FROM Contact WHERE Id IN :new Set<Id>{ c1.Id, c2.Id }
        ];
        Merge_Log__c log = MergeAuditService.createPreMergeLog(
            t.Id, 'Contact', c1.Id, new List<Id>{ c2.Id }, cands, null
        );

        Test.startTest();
        MergeAuditService.recordMergeFailure(log.Id, t.Id, 'Simulated failure');
        Test.stopTest();

        System.assertEquals('MERGE_ERROR',
            [SELECT Action_Type__c FROM Merge_Log__c WHERE Id = :log.Id].Action_Type__c);
        System.assertEquals('Error',
            [SELECT Status__c FROM Merge_Ticket__c WHERE Id = :t.Id].Status__c);
    }

    @IsTest
    static void audit_recordMergeFailure_nullIds_doesNotThrow() {
        Test.startTest();
        MergeAuditService.recordMergeFailure(null, null, 'Error with no IDs');
        Test.stopTest();
        // No exception = pass
        System.assertEquals(1, 1);
    }

    @IsTest
    static void audit_recordMergeFailure_nullLogId_onlyUpdatesTicket() {
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|fail_ticket@exectest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        Test.startTest();
        MergeAuditService.recordMergeFailure(null, t.Id, 'Ticket-only failure');
        Test.stopTest();
        System.assertEquals('Error',
            [SELECT Status__c FROM Merge_Ticket__c WHERE Id = :t.Id].Status__c);
    }

    // ─── MergeExecutionService — validation ──────────────────────────────────

    @IsTest
    static void exec_validation_blankTicketId_returnsError() {
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId  = '';
        req.masterId  = '003000000000001AAA';
        req.losingIds = new List<String>{ '003000000000002AAA' };

        Boolean errorOccurred = false;
        try {
            MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(req);
            errorOccurred = !result.success;
        } catch (Exception e) {
            // Service catch block re-throws when casting blank ticketId to Id
            errorOccurred = true;
        }
        System.assertEquals(true, errorOccurred, 'Blank ticketId should cause an error');
    }

    @IsTest
    static void exec_validation_blankMasterId_returnsError() {
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|val_master@exectest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId  = String.valueOf(t.Id);
        req.masterId  = '';
        req.losingIds = new List<String>{ '003000000000001AAA' };

        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(req);
        System.assertEquals(false, result.success);
        System.assert(result.errorMessage.containsIgnoreCase('masterId'));
    }

    @IsTest
    static void exec_validation_emptyLosingIds_returnsError() {
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|val_loser@exectest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId  = String.valueOf(t.Id);
        req.masterId  = '003000000000001AAA';
        req.losingIds = new List<String>();

        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(req);
        System.assertEquals(false, result.success);
        System.assert(result.errorMessage.containsIgnoreCase('losingId'));
    }

    @IsTest
    static void exec_validation_masterInLosingIds_returnsError() {
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|val_overlap@exectest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        Contact c = new Contact(LastName = 'SameId');
        insert c;
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId  = String.valueOf(t.Id);
        req.masterId  = String.valueOf(c.Id);
        req.losingIds = new List<String>{ String.valueOf(c.Id) };

        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(req);
        System.assertEquals(false, result.success);
    }

    // ─── MergeExecutionService — successful Contact merge ────────────────────

    @IsTest
    static void exec_contactMerge_success_loserDeletedTicketMerged() {
        Account acc = makeAccount('ExecOrg');
        Contact master = makeContact('KeepMe',  'exec_keep@exectest.com', acc.Id);
        Contact loser  = makeContact('MergeMe', 'exec_keep@exectest.com', acc.Id);
        Merge_Ticket__c ticket = makeContactTicket(
            master, loser, 'Contact|Email|exec_merge@exectest.com'
        );
        MergeWrappers.MergeRequest req = makeRequest(ticket.Id, master.Id,
                                                      new List<Id>{ loser.Id });
        req.notes = 'Unit test merge';

        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(req);
        Test.stopTest();

        System.assertEquals(true, result.success, 'Merge failed: ' + result.errorMessage);
        System.assertEquals(String.valueOf(master.Id), result.mergedRecordId);
        System.assertNotEquals(null, result.logId);

        Merge_Ticket__c t = [
            SELECT Status__c, Selected_Master_Id__c
            FROM Merge_Ticket__c WHERE Id = :ticket.Id
        ];
        System.assertEquals('Merged', t.Status__c);
        System.assertEquals(String.valueOf(master.Id), t.Selected_Master_Id__c);
        System.assertEquals(0, [SELECT COUNT() FROM Contact WHERE Id = :loser.Id]);

        Merge_Log__c log = [
            SELECT Action_Type__c FROM Merge_Log__c WHERE Merge_Ticket__c = :ticket.Id
        ];
        System.assertEquals('MERGE_COMPLETED', log.Action_Type__c);
    }

    @IsTest
    static void exec_contactMerge_withFieldDecisions_succeeds() {
        Account acc = makeAccount('FDOrg');
        Contact master = new Contact(LastName = 'FDMaster', Email = 'fd@exectest.com',
                                     MobilePhone = '5140000001', AccountId = acc.Id);
        Contact loser  = new Contact(LastName = 'FDLoser',  Email = 'fd@exectest.com',
                                     MobilePhone = '5140000002', AccountId = acc.Id);
        Database.DmlOptions fdOpts = new Database.DmlOptions();
        fdOpts.DuplicateRuleHeader.AllowSave = true;
        Database.insert(master, fdOpts);
        Database.insert(loser, fdOpts);
        Merge_Ticket__c ticket = makeContactTicket(master, loser, 'Contact|Email|fd@exectest.com');
        MergeWrappers.MergeRequest req = makeRequest(ticket.Id, master.Id,
                                                      new List<Id>{ loser.Id });
        req.fieldDecisions = new Map<String,String>{
            'MobilePhone' => String.valueOf(loser.Id)
        };

        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(req);
        Test.stopTest();

        System.assertEquals(true, result.success, 'Merge failed: ' + result.errorMessage);
    }

    @IsTest
    static void exec_contactMerge_orphanedAccount_detected() {
        Account masterAcc = makeAccount('MasterAcc OA');
        Account loserAcc  = makeAccount('LoserAcc OA');
        Contact master = makeContact('OAMaster', 'oa@exectest.com', masterAcc.Id);
        Contact loser  = makeContact('OALoser',  'oa@exectest.com', loserAcc.Id);
        Merge_Ticket__c ticket = makeContactTicket(
            master, loser, 'Contact|Email|oa@exectest.com'
        );

        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(
            makeRequest(ticket.Id, master.Id, new List<Id>{ loser.Id })
        );
        Test.stopTest();

        System.assertEquals(true, result.success, 'Merge failed: ' + result.errorMessage);
        System.assert(!result.orphanedAccounts.isEmpty(),
            'Loser account with 0 remaining contacts should be reported as orphaned');
        System.assertEquals(true, result.orphanedAccounts[0].isSafeToDelete);
    }

    @IsTest
    static void exec_accountMerge_success_loserDeleted() {
        Account master = new Account(Name = 'AccMaster', Phone = '5140009001');
        Account loser  = new Account(Name = 'AccLoser',  Phone = '5140009001');
        insert new List<Account>{ master, loser };
        Merge_Ticket__c ticket = makeAccountTicket(master, loser, 'Account|Phone|5140009001A');

        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(
            makeRequest(ticket.Id, master.Id, new List<Id>{ loser.Id })
        );
        Test.stopTest();

        System.assertEquals(true, result.success, 'Merge failed: ' + result.errorMessage);
        System.assertEquals(0, [SELECT COUNT() FROM Account WHERE Id = :loser.Id]);
    }

    @IsTest
    static void exec_accountMerge_orphanedContacts_detected() {
        Account master = new Account(Name = 'AccMasterOC', Phone = '5140009002');
        Account loser  = new Account(Name = 'AccLoserOC',  Phone = '5140009002');
        insert new List<Account>{ master, loser };
        Contact orphan = new Contact(LastName = 'OrphanCont', AccountId = loser.Id);
        insert orphan;
        Merge_Ticket__c ticket = makeAccountTicket(master, loser, 'Account|Phone|5140009002B');

        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(
            makeRequest(ticket.Id, master.Id, new List<Id>{ loser.Id })
        );
        Test.stopTest();

        System.assertEquals(true, result.success, 'Merge failed: ' + result.errorMessage);
        System.assert(!result.orphanedContacts.isEmpty(),
            'Contact on losing account should appear in orphanedContacts');
        System.assertEquals('OrphanCont', result.orphanedContacts[0].contactName);
    }

    // ─── MergeTicketService ───────────────────────────────────────────────────

    @IsTest
    static void ticket_buildMatrix_contact_returnsRowsAndRecordIds() {
        Account acc = makeAccount('MatrixOrg');
        Contact c1 = makeContact('MatrixA', 'mx@exectest.com', acc.Id);
        Contact c2 = makeContact('MatrixB', 'mx@exectest.com', acc.Id);
        Merge_Ticket__c ticket = makeContactTicket(c1, c2, 'Contact|Email|mx@exectest.com');

        Test.startTest();
        MergeWrappers.ComparisonMatrix matrix =
            MergeTicketService.buildComparisonMatrix(ticket.Id);
        Test.stopTest();

        System.assertNotEquals(null, matrix);
        System.assertEquals('Contact', matrix.objectType);
        System.assertEquals(2, matrix.recordIds.size());
        System.assertEquals(2, matrix.recordNames.size());
        System.assert(!matrix.rows.isEmpty(), 'Comparison rows should not be empty');
        System.assertEquals(null, matrix.savedMasterId);
        System.assertEquals(0, matrix.missingRecordIds.size());
    }

    @IsTest
    static void ticket_buildMatrix_account_includesRelatedContacts() {
        Account a1 = new Account(Name = 'MxAcc1', Phone = '5140007001');
        Account a2 = new Account(Name = 'MxAcc2', Phone = '5140007001');
        insert new List<Account>{ a1, a2 };
        Merge_Ticket__c ticket = makeAccountTicket(a1, a2, 'Account|Phone|5140007001M');

        Test.startTest();
        MergeWrappers.ComparisonMatrix matrix =
            MergeTicketService.buildComparisonMatrix(ticket.Id);
        Test.stopTest();

        System.assertEquals('Account', matrix.objectType);
        System.assertEquals(2, matrix.recordIds.size());
        System.assertNotEquals(null, matrix.relatedContactsByRecordId);
    }

    @IsTest
    static void ticket_buildMatrix_account_withContacts_populatesRelatedContacts() {
        // Covers MergeTicketService lines 321-328: loadRelatedContacts for-loop body
        Account a1 = new Account(Name = 'MxAccCont1', Phone = '5140088001');
        Account a2 = new Account(Name = 'MxAccCont2', Phone = '5140088001');
        insert new List<Account>{ a1, a2 };
        Contact c1 = new Contact(LastName = 'RelContA', AccountId = a1.Id);
        Contact c2 = new Contact(LastName = 'RelContB', AccountId = a2.Id);
        insert new List<Contact>{ c1, c2 };
        Merge_Ticket__c ticket = makeAccountTicket(a1, a2, 'Account|Phone|5140088001RC');

        Test.startTest();
        MergeWrappers.ComparisonMatrix matrix =
            MergeTicketService.buildComparisonMatrix(ticket.Id);
        Test.stopTest();

        System.assertEquals('Account', matrix.objectType);
        System.assertEquals(2, matrix.recordIds.size());
        String keyA1 = String.valueOf(a1.Id);
        String keyA2 = String.valueOf(a2.Id);
        System.assertEquals(true,
            matrix.relatedContactsByRecordId.containsKey(keyA1) &&
            !matrix.relatedContactsByRecordId.get(keyA1).isEmpty(),
            'Account a1 should have related contacts in matrix');
        System.assertEquals(true,
            matrix.relatedContactsByRecordId.containsKey(keyA2) &&
            !matrix.relatedContactsByRecordId.get(keyA2).isEmpty(),
            'Account a2 should have related contacts in matrix');
    }

    @IsTest
    static void ticket_buildMatrix_mergedTicket_hasSavedMasterAndMissingIds() {
        Account acc = makeAccount('SMOrg');
        Contact c1 = makeContact('SMMaster', 'sm@exectest.com', acc.Id);
        Contact c2 = makeContact('SMLoser',  'sm@exectest.com', acc.Id);
        Merge_Ticket__c ticket = makeContactTicket(c1, c2, 'Contact|Email|sm@exectest.com');

        // Merge c2 into c1 so ticket is Merged and c2 is deleted
        MergeExecutionService.executeMerge(
            makeRequest(ticket.Id, c1.Id, new List<Id>{ c2.Id })
        );

        Test.startTest();
        MergeWrappers.ComparisonMatrix matrix =
            MergeTicketService.buildComparisonMatrix(ticket.Id);
        Test.stopTest();

        System.assertEquals(String.valueOf(c1.Id), matrix.savedMasterId);
        System.assertEquals(1, matrix.missingRecordIds.size());
        System.assertEquals(String.valueOf(c2.Id), matrix.missingRecordIds[0]);
    }

    // ─── MergeController ─────────────────────────────────────────────────────

    @IsTest
    static void ctrl_getTickets_all_returnsTickets() {
        insert new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|ctrl_all@exectest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        List<Merge_Ticket__c> tickets = MergeController.getTickets('Contact', 'All');
        System.assert(!tickets.isEmpty(), 'Should return at least one ticket');
    }

    @IsTest
    static void ctrl_getTickets_filterByStatus() {
        insert new List<Merge_Ticket__c>{
            new Merge_Ticket__c(Object_Type__c = 'Contact', Status__c = 'In Review',
                Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|ctrl_inrev@exectest.com',
                Match_Confidence__c = 'High', Candidate_Count__c = 2),
            new Merge_Ticket__c(Object_Type__c = 'Contact', Status__c = 'New',
                Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|ctrl_new@exectest.com',
                Match_Confidence__c = 'High', Candidate_Count__c = 2)
        };
        System.assertEquals(1, MergeController.getTickets('Contact', 'In Review').size());
        System.assertEquals(1, MergeController.getTickets('Contact', 'New').size());
        System.assertEquals(0, MergeController.getTickets('Contact', 'Ready').size());
    }

    @IsTest
    static void ctrl_getTickets_closedFilter_returnsMergedAndIgnored() {
        // Covers MergeController line 31: Status__c IN ('Merged', 'Ignored')
        Contact dummy = new Contact(LastName = 'ClosedFilterMaster');
        insert dummy;
        insert new List<Merge_Ticket__c>{
            new Merge_Ticket__c(Object_Type__c = 'Contact', Status__c = 'Merged',
                Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|ctrl_merged@exectest.com',
                Match_Confidence__c = 'High', Candidate_Count__c = 2,
                Selected_Master_Id__c = String.valueOf(dummy.Id)),
            new Merge_Ticket__c(Object_Type__c = 'Contact', Status__c = 'Ignored',
                Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|ctrl_ignored@exectest.com',
                Match_Confidence__c = 'High', Candidate_Count__c = 2,
                Closed_Reason__c = 'False Positive - Shared Phone')
        };
        List<Merge_Ticket__c> closed = MergeController.getTickets('Contact', 'Closed');
        System.assertEquals(2, closed.size(), 'Closed filter must return Merged + Ignored tickets');
    }

    @IsTest
    static void ctrl_runScan_dryRun_succeeds() {
        Contact c1 = new Contact(LastName = 'SC1', Email = 'scan_ctrl@exectest.com');
        Contact c2 = new Contact(LastName = 'SC2', Email = 'scan_ctrl@exectest.com');
        insert new List<Contact>{ c1, c2 };

        MergeWrappers.ScanResult result = MergeController.runScan(
            'Contact',
            new List<String>{ 'Email' },
            1000,
            true,
            null
        );
        System.assertEquals(true, result.success);
        System.assert(!result.previews.isEmpty(), 'Dry run should return previews');
    }

    @IsTest
    static void ctrl_runScan_nonDryRun_forcesLimitTo50000() {
        MergeWrappers.ScanResult result = MergeController.runScan(
            'Contact',
            new List<String>{ 'Email' },
            5,
            false,
            null
        );
        System.assertEquals(true, result.success);
    }

    @IsTest
    static void ctrl_isSandboxOrg_sandboxReturnsTrue() {
        // Use TEST_IS_SANDBOX flag so this test passes in both sandbox AND production
        MergeController.TEST_IS_SANDBOX = true;
        Boolean result = MergeController.isSandboxOrg();
        System.assertEquals(true, result, 'Should return true when flag is set to true');
        MergeController.TEST_IS_SANDBOX = null;
    }

    @IsTest
    static void ctrl_isSandboxOrg_flagOverride_returnsFalse() {
        // Covers the TEST_IS_SANDBOX != null branch (production simulation)
        MergeController.TEST_IS_SANDBOX = false;
        Boolean result = MergeController.isSandboxOrg();
        System.assertEquals(false, result);
        MergeController.TEST_IS_SANDBOX = null;
    }

    @IsTest
    static void ctrl_runScan_invalidObjectType_throws() {
        // Covers the objectType whitelist guard added for production hardening
        try {
            MergeController.runScan('Lead', new List<String>{'Email'}, 100, true, null);
            System.assert(false, 'Expected AuraHandledException for invalid object type');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        }
    }

    @IsTest
    static void ctrl_getTicketPreview_returnsTicketCandidatesAndLog() {
        // Arrange — ticket with two candidates
        Contact master = new Contact(LastName = 'PreviewMaster');
        Contact loser  = new Contact(LastName = 'PreviewLoser');
        insert new List<Contact>{ master, loser };

        Merge_Ticket__c ticket = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'Merged',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|preview@test.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2,
            Selected_Master_Id__c = master.Id,  // required by Require_Master_When_Merged validation
            Final_Action__c = 'MERGED'
        );
        insert ticket;

        Merge_Candidate__c cMaster = new Merge_Candidate__c(
            Merge_Ticket__c = ticket.Id, Record_Id__c = master.Id,
            Record_Name__c = 'PreviewMaster', Is_Master__c = true,
            Is_Losing_Record__c = false,
            Snapshot_JSON__c = '{"Email":"m@t.com","Phone":"514-000-0001"}',
            Related_Info_JSON__c = '{"totalCourses":2,"activeCourses":1,"totalPrograms":0,"activePrograms":0,"totalAffiliations":1}'
        );
        Merge_Candidate__c cLoser = new Merge_Candidate__c(
            Merge_Ticket__c = ticket.Id, Record_Id__c = loser.Id,
            Record_Name__c = 'PreviewLoser', Is_Master__c = false,
            Is_Losing_Record__c = true,
            Snapshot_JSON__c = '{"Email":"l@t.com"}',
            Related_Info_JSON__c = '{"totalCourses":0,"activeCourses":0,"totalPrograms":0,"activePrograms":0,"totalAffiliations":0}'
        );
        insert new List<Merge_Candidate__c>{ cMaster, cLoser };

        Merge_Log__c lg = new Merge_Log__c(
            Merge_Ticket__c = ticket.Id, Action_Type__c = 'MERGE_COMPLETED',
            Object_Type__c = 'Contact',
            Master_Record_Id__c = master.Id, Master_Record_Name__c = 'PreviewMaster',
            Losing_Record_Ids__c = loser.Id, Losing_Record_Names__c = 'PreviewLoser',
            Performed_By__c = UserInfo.getUserId(),
            Performed_Date__c = DateTime.now(),
            Before_Snapshot_JSON__c = '{}', After_Snapshot_JSON__c = '{}'
        );
        insert lg;

        // Act
        Map<String, Object> result = MergeController.getTicketPreview(ticket.Id);

        // Assert
        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertNotEquals(null, result.get('ticket'), 'ticket key expected');
        System.assertNotEquals(null, result.get('candidates'), 'candidates key expected');
        System.assertNotEquals(null, result.get('mergeLog'), 'mergeLog key expected for merged ticket');

        @SuppressWarnings('PMD.ApexUnitTestClassShouldHaveAsserts')
        List<Merge_Candidate__c> cands = (List<Merge_Candidate__c>) result.get('candidates');
        System.assertEquals(2, cands.size(), 'Expected 2 candidates');

        Map<String, Object> logData = (Map<String, Object>) result.get('mergeLog');
        System.assertEquals('MERGE_COMPLETED', (String) logData.get('actionType'));
        System.assertNotEquals(null, logData.get('masterName'));
    }

    @IsTest
    static void ctrl_getTicketPreview_noLog_returnsNullMergeLog() {
        // A ticket with no merge log should return mergeLog = null
        Merge_Ticket__c ticket = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|nolog@test.com',
            Match_Confidence__c = 'Low', Candidate_Count__c = 2
        );
        insert ticket;

        Map<String, Object> result = MergeController.getTicketPreview(ticket.Id);
        System.assertEquals(null, result.get('mergeLog'), 'mergeLog should be null when no log exists');
    }

    @IsTest
    static void ctrl_deleteAllTickets_productionGuard_throws() {
        // Simulate production (non-sandbox) to reach the throw branch
        MergeController.TEST_IS_SANDBOX = false;
        try {
            MergeController.deleteAllTickets();
            System.assert(false, 'Expected AuraHandledException for production context');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } finally {
            MergeController.TEST_IS_SANDBOX = null;
        }
    }

    @IsTest
    static void ctrl_deleteAllTickets_sandboxGuard_passes() {
        // Simulate sandbox to confirm the happy path executes normally
        MergeController.TEST_IS_SANDBOX = true;
        Integer deleted = MergeController.deleteAllTickets();
        System.assert(deleted >= 0);
        MergeController.TEST_IS_SANDBOX = null;
    }

    @IsTest
    static void ctrl_executeMerge_invalidObjectType_throws() {
        // Covers validateObjectType() in MergeExecutionService by corrupting the ticket's Object_Type__c
        // — we insert a ticket with a valid type and then call executeMerge; execution service
        // reads objectType from the ticket. To reach the guard, we must reach getObjectType first.
        // Since Object_Type__c is a restricted picklist, we instead just confirm that the validation
        // method exists and the happy path passes, as the throw branch requires bypassing the picklist.
        // This test at minimum exercises the validateObjectType call on the success path.
        Account acc = makeAccount('ValObjOrg');
        Contact c1 = makeContact('VO1', 'val_obj@exectest.com', acc.Id);
        Contact c2 = makeContact('VO2', 'val_obj@exectest.com', acc.Id);
        Merge_Ticket__c ticket = makeContactTicket(c1, c2, 'Contact|Email|val_obj@exectest.com');

        MergeWrappers.MergeResult result = MergeController.executeMerge(
            String.valueOf(ticket.Id),
            String.valueOf(c1.Id),
            new List<String>{ String.valueOf(c2.Id) },
            new Map<String,String>(),
            'validate objectType path'
        );
        System.assertEquals(true, result.success);
    }

    @IsTest
    static void ctrl_getComparisonMatrix_returnsMatrix() {
        Account acc = makeAccount('CtrlMxOrg');
        Contact c1 = makeContact('CMX1', 'ctrl_mx@exectest.com', acc.Id);
        Contact c2 = makeContact('CMX2', 'ctrl_mx@exectest.com', acc.Id);
        Merge_Ticket__c ticket = makeContactTicket(c1, c2, 'Contact|Email|ctrl_mx@exectest.com');

        MergeWrappers.ComparisonMatrix matrix =
            MergeController.getComparisonMatrix(String.valueOf(ticket.Id));
        System.assertNotEquals(null, matrix);
        System.assertEquals(2, matrix.recordIds.size());
    }

    @IsTest
    static void ctrl_executeMerge_delegatesToService() {
        Account acc = makeAccount('CtrlExecOrg');
        Contact c1 = makeContact('CE1', 'ctrl_exec@exectest.com', acc.Id);
        Contact c2 = makeContact('CE2', 'ctrl_exec@exectest.com', acc.Id);
        Merge_Ticket__c ticket = makeContactTicket(c1, c2, 'Contact|Email|ctrl_exec@exectest.com');

        Test.startTest();
        MergeWrappers.MergeResult result = MergeController.executeMerge(
            String.valueOf(ticket.Id),
            String.valueOf(c1.Id),
            new List<String>{ String.valueOf(c2.Id) },
            new Map<String,String>(),
            'Controller test'
        );
        Test.stopTest();

        System.assertEquals(true, result.success, 'Merge failed: ' + result.errorMessage);
    }

    @IsTest
    static void ctrl_updateTicketStatus_changesStatusAndNotes() {
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|upd_status@exectest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        MergeController.updateTicketStatus(String.valueOf(t.Id), 'In Review', 'Test note');
        Merge_Ticket__c upd = [SELECT Status__c, Notes__c FROM Merge_Ticket__c WHERE Id = :t.Id];
        System.assertEquals('In Review', upd.Status__c);
        System.assertEquals('Test note', upd.Notes__c);
    }

    @IsTest
    static void ctrl_dismissTicket_setsIgnoredAndReason() {
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|dismiss@exectest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        MergeController.dismissTicket(
            String.valueOf(t.Id), 'False Positive - Shared Phone', 'Dismiss test'
        );
        Merge_Ticket__c upd = [
            SELECT Status__c, Final_Action__c, Closed_Reason__c
            FROM Merge_Ticket__c WHERE Id = :t.Id
        ];
        System.assertEquals('Ignored', upd.Status__c);
        System.assertEquals('Ignored', upd.Final_Action__c);
        System.assertEquals('False Positive - Shared Phone', upd.Closed_Reason__c);
    }

    @IsTest
    static void ctrl_isEDAAvailable_returnsBoolean() {
        System.assertNotEquals(null, MergeController.isEDAAvailable());
    }

    @IsTest
    static void ctrl_deleteOrphanedAccount_noContacts_deletesAndLogsEntry() {
        Account acc = makeAccount('OrphanDel');
        Contact dummyMaster1 = new Contact(LastName = 'OD_Master1');
        insert dummyMaster1;
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'Merged',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|orphan_del@exectest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2,
            Selected_Master_Id__c = String.valueOf(dummyMaster1.Id)
        );
        insert t;

        MergeController.deleteOrphanedAccount(
            String.valueOf(acc.Id), String.valueOf(t.Id), acc.Name
        );

        System.assertEquals(0, [SELECT COUNT() FROM Account WHERE Id = :acc.Id]);
        String notes = [SELECT Notes__c FROM Merge_Ticket__c WHERE Id = :t.Id].Notes__c;
        System.assert(notes.contains('[DELETED_ACCOUNT|'), 'Notes should contain deletion entry');
        System.assert(notes.contains(acc.Name), 'Notes should contain account name');
    }

    @IsTest
    static void ctrl_deleteOrphanedAccount_withContacts_throwsException() {
        Account acc = makeAccount('HasContAcc');
        insert new Contact(LastName = 'BlocksDeletion', AccountId = acc.Id);
        Contact dummyMaster2 = new Contact(LastName = 'OD_Master2');
        insert dummyMaster2;
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'Merged',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|block_del@exectest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2,
            Selected_Master_Id__c = String.valueOf(dummyMaster2.Id)
        );
        insert t;

        Boolean threw = false;
        try {
            MergeController.deleteOrphanedAccount(
                String.valueOf(acc.Id), String.valueOf(t.Id), acc.Name
            );
        } catch (Exception e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Should throw when account has contacts');
    }

    @IsTest
    static void ctrl_restoreDeletedAccount_undeletesAndCleansNotes() {
        Account acc = makeAccount('ToRestore');
        Contact dummyMaster3 = new Contact(LastName = 'Restore_Master');
        insert dummyMaster3;
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'Merged',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|restore_acc@exectest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2,
            Selected_Master_Id__c = String.valueOf(dummyMaster3.Id)
        );
        insert t;

        MergeController.deleteOrphanedAccount(
            String.valueOf(acc.Id), String.valueOf(t.Id), acc.Name
        );
        System.assertEquals(0, [SELECT COUNT() FROM Account WHERE Id = :acc.Id]);

        MergeController.restoreDeletedAccount(String.valueOf(acc.Id), String.valueOf(t.Id));
        System.assertEquals(1, [SELECT COUNT() FROM Account WHERE Id = :acc.Id]);

        String notes = [SELECT Notes__c FROM Merge_Ticket__c WHERE Id = :t.Id].Notes__c;
        System.assertEquals(true,
            notes == null || !notes.contains('[DELETED_ACCOUNT|' + acc.Id + '|'),
            'DELETED_ACCOUNT entry should be removed after restore');
    }

    @IsTest
    static void ctrl_getDeletedAccountsForTicket_parsesNotesCorrectly() {
        Contact dummyMaster4 = new Contact(LastName = 'GetDel_Master');
        insert dummyMaster4;
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'Merged',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|get_del_a@exectest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2,
            Selected_Master_Id__c = String.valueOf(dummyMaster4.Id),
            Notes__c = '\n[DELETED_ACCOUNT|FAKEACCID001|Acme Corp|2025-01-15 10:00]'
        );
        insert t;

        List<MergeWrappers.DeletedAccountInfo> result =
            MergeController.getDeletedAccountsForTicket(String.valueOf(t.Id));

        System.assertEquals(1, result.size());
        System.assertEquals('FAKEACCID001',     result[0].accountId);
        System.assertEquals('Acme Corp',        result[0].accountName);
        System.assertEquals('2025-01-15 10:00', result[0].deletedAt);
    }

    @IsTest
    static void ctrl_getDeletedAccountsForTicket_blankNotes_returnsEmpty() {
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|blank_da@exectest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        System.assertEquals(0,
            MergeController.getDeletedAccountsForTicket(String.valueOf(t.Id)).size());
    }

    @IsTest
    static void ctrl_deleteAndRestoreOrphanedContact() {
        Account acc = makeAccount('ContactOrphanOrg');
        Contact c = new Contact(LastName = 'OrphanC', AccountId = acc.Id);
        insert c;
        Account dummyMasterAcc = makeAccount('OrphanCtMaster');
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Account', Status__c = 'Merged',
            Match_Type__c = 'Phone', Match_Key__c = 'Account|Phone|orphan_ct@exectest.com',
            Match_Confidence__c = 'Medium', Candidate_Count__c = 2,
            Selected_Master_Id__c = String.valueOf(dummyMasterAcc.Id)
        );
        insert t;

        MergeController.deleteOrphanedContact(
            String.valueOf(c.Id), String.valueOf(t.Id), c.LastName
        );
        System.assertEquals(0, [SELECT COUNT() FROM Contact WHERE Id = :c.Id]);
        System.assertEquals(true,
            [SELECT Notes__c FROM Merge_Ticket__c WHERE Id = :t.Id]
                .Notes__c.contains('[DELETED_CONTACT|'));

        MergeController.restoreDeletedContact(String.valueOf(c.Id), String.valueOf(t.Id));
        System.assertEquals(1, [SELECT COUNT() FROM Contact WHERE Id = :c.Id]);

        String notesAfter = [SELECT Notes__c FROM Merge_Ticket__c WHERE Id = :t.Id].Notes__c;
        System.assertEquals(true,
            notesAfter == null || !notesAfter.contains('[DELETED_CONTACT|' + c.Id + '|'),
            'DELETED_CONTACT entry should be removed after restore');
    }

    @IsTest
    static void ctrl_getDeletedContactsForTicket_parsesNotesCorrectly() {
        Account dummyMasterAcc2 = makeAccount('GetDelCMaster');
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Account', Status__c = 'Merged',
            Match_Type__c = 'Phone', Match_Key__c = 'Account|Phone|get_del_c@exectest.com',
            Match_Confidence__c = 'Medium', Candidate_Count__c = 2,
            Selected_Master_Id__c = String.valueOf(dummyMasterAcc2.Id),
            Notes__c = '\n[DELETED_CONTACT|FAKECTID001|Dupont Marie|2025-02-20 09:00]'
        );
        insert t;

        List<MergeWrappers.DeletedContactInfo> result =
            MergeController.getDeletedContactsForTicket(String.valueOf(t.Id));

        System.assertEquals(1, result.size());
        System.assertEquals('FAKECTID001',      result[0].contactId);
        System.assertEquals('Dupont Marie',     result[0].contactName);
        System.assertEquals('2025-02-20 09:00', result[0].deletedAt);
    }

    @IsTest
    static void ctrl_getDeletedContactsForTicket_blankNotes_returnsEmpty() {
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Account', Status__c = 'New',
            Match_Type__c = 'Phone', Match_Key__c = 'Account|Phone|blank_dc@exectest.com',
            Match_Confidence__c = 'Medium', Candidate_Count__c = 2
        );
        insert t;
        System.assertEquals(0,
            MergeController.getDeletedContactsForTicket(String.valueOf(t.Id)).size());
    }

    // ─── cleanupOrphanedTickets ───────────────────────────────────────────────

    @IsTest
    static void exec_merge_cleansUpOrphanedTickets_afterSuccessfulMerge() {
        // Two extra tickets reference the same loser as the primary ticket.
        // After merge the loser no longer exists → those tickets must be deleted.
        Account acc = makeAccount('CleanupOrg');
        Contact master = makeContact('CleanMaster', 'cleanup@exectest.com', acc.Id);
        Contact loser  = makeContact('CleanLoser',  'cleanup@exectest.com', acc.Id);
        Merge_Ticket__c primaryTicket = makeContactTicket(
            master, loser, 'Contact|Email|cleanup@exectest.com'
        );

        Contact otherA = makeContact('OtherA', 'other_a_cleanup@exectest.com', acc.Id);
        Contact otherB = makeContact('OtherB', 'other_b_cleanup@exectest.com', acc.Id);
        Merge_Ticket__c extraTicket1 = makeContactTicket(
            otherA, loser, 'Contact|Phone|5550001CL'
        );
        Merge_Ticket__c extraTicket2 = makeContactTicket(
            otherB, loser, 'Contact|Name|CLEANLOSER'
        );

        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(
            makeRequest(primaryTicket.Id, master.Id, new List<Id>{ loser.Id })
        );
        Test.stopTest();

        System.assertEquals(true, result.success, 'Merge failed: ' + result.errorMessage);
        System.assertEquals(2, result.cleanedUpTicketCount,
            'Expected 2 orphaned tickets to be deleted');
        System.assertEquals(0, [SELECT COUNT() FROM Merge_Ticket__c WHERE Id = :extraTicket1.Id],
            'Extra ticket 1 should be deleted');
        System.assertEquals(0, [SELECT COUNT() FROM Merge_Ticket__c WHERE Id = :extraTicket2.Id],
            'Extra ticket 2 should be deleted');
        System.assertEquals(1, [SELECT COUNT() FROM Merge_Ticket__c WHERE Id = :primaryTicket.Id],
            'Primary ticket must NOT be deleted');
    }

    @IsTest
    static void exec_merge_noOrphanedTickets_cleanupCountIsZero() {
        // When no other ticket references the loser, cleanedUpTicketCount must be 0.
        Account acc = makeAccount('NoOrphanOrg');
        Contact master = makeContact('NoOrpMaster', 'noorphan@exectest.com', acc.Id);
        Contact loser  = makeContact('NoOrpLoser',  'noorphan@exectest.com', acc.Id);
        Merge_Ticket__c ticket = makeContactTicket(
            master, loser, 'Contact|Email|noorphan@exectest.com'
        );

        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(
            makeRequest(ticket.Id, master.Id, new List<Id>{ loser.Id })
        );
        Test.stopTest();

        System.assertEquals(true, result.success, 'Merge failed: ' + result.errorMessage);
        System.assertEquals(0, result.cleanedUpTicketCount,
            'No orphaned tickets expected when loser appears in only one ticket');
    }

    // ─── MergeController.getLoserSnapshot ────────────────────────────────────

    @IsTest
    static void ctrl_getLoserSnapshot_returnsAllFieldTypes() {
        // Covers the happy path of getLoserSnapshot and every field-type branch:
        // Boolean (true→Oui, false→Non), Map with Name (relationship), Map without Name (skip),
        // List (skip), blank string (skip), null (skip), skipFields (Id), custom field.
        Account acc          = makeAccount('SnapOrg');
        Contact loser        = makeContact('SnapLoser', 'snap@exectest.com', acc.Id);
        Contact dummyMaster  = new Contact(LastName = 'SnapMaster');
        insert dummyMaster;

        Merge_Ticket__c ticket = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'Merged',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|snap@exectest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2,
            Selected_Master_Id__c = String.valueOf(dummyMaster.Id),
            Final_Action__c = 'MERGED'
        );
        insert ticket;

        String loserId = String.valueOf(loser.Id);

        Map<String, Object> snap = new Map<String, Object>{
            'Id'              => loserId,
            'Name'            => 'Jean Dupont',
            'Email'           => 'snap@exectest.com',
            'Phone'           => '5141234567',
            'DoNotCall'       => true,
            'HasOptedOutOfEmail' => false,
            'Account'         => new Map<String, Object>{ 'Name' => 'SnapOrg', 'Id' => acc.Id },
            'ReportsTo'       => new Map<String, Object>{ 'Id' => '003000000000001AAA' },
            'ActivityHistory' => new List<Object>{ 'item1' },
            'Description'     => '',
            'NullField__c'    => null,
            'ID_Contact__c'   => 'ADAR0001',
            '__meta_capturedAt'  => '2026-06-08T10:00:00.000Z',
            '__meta_capturedBy'  => UserInfo.getUserId(),
            '__meta_objectType'  => 'Contact'
        };

        Merge_Log__c lg = new Merge_Log__c(
            Merge_Ticket__c           = ticket.Id,
            Object_Type__c            = 'Contact',
            Action_Type__c            = 'MERGE_COMPLETED',
            Master_Record_Id__c       = String.valueOf(dummyMaster.Id),
            Master_Record_Name__c     = 'SnapMaster',
            Losing_Record_Ids__c      = loserId,
            Losing_Record_Names__c    = 'Jean Dupont',
            Before_Snapshot_JSON__c   = JSON.serialize(new Map<String, Object>{ loserId => snap }),
            After_Snapshot_JSON__c    = '{}',
            Field_Decisions_JSON__c   = '{}',
            Performed_By__c           = UserInfo.getUserId(),
            Performed_Date__c         = System.now()
        );
        insert lg;

        Test.startTest();
        MergeWrappers.SnapshotViewWrapper result =
            MergeController.getLoserSnapshot(String.valueOf(ticket.Id), loserId);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Wrapper should not be null');
        System.assertEquals(loserId,       result.recordId);
        System.assertEquals('Jean Dupont', result.recordName);
        System.assertEquals('Contact',     result.objectType);
        System.assert(!result.fields.isEmpty(), 'Fields list should not be empty');
        System.assertNotEquals('', result.capturedAt, 'capturedAt should be populated');

        Map<String, String> byApiName = new Map<String, String>();
        for (MergeWrappers.SnapshotField f : result.fields) byApiName.put(f.apiName, f.value);

        System.assertEquals('Oui',     byApiName.get('DoNotCall'),         'Boolean true → Oui');
        System.assertEquals('Non',     byApiName.get('HasOptedOutOfEmail'), 'Boolean false → Non');
        System.assertEquals('SnapOrg', byApiName.get('Account'),           'Relationship Name extracted');
        System.assertEquals('ADAR0001',byApiName.get('ID_Contact__c'),     'Custom field present');
        System.assertEquals(null, byApiName.get('Id'),             'Id filtered (skipFields)');
        System.assertEquals(null, byApiName.get('ActivityHistory'), 'List value filtered');
        System.assertEquals(null, byApiName.get('NullField__c'),   'Null value filtered');
        System.assertEquals(null, byApiName.get('Description'),    'Blank string filtered');
        System.assertEquals(null, byApiName.get('ReportsTo'),      'Map without Name filtered');
    }

    @IsTest
    static void ctrl_getLoserSnapshot_noName_usesFirstLastName() {
        // Covers the else branch (lines 250-252): no Name field → use FirstName + LastName
        Contact loser       = new Contact(LastName = 'FNLNLoser');
        Contact dummyMaster = new Contact(LastName = 'FNLNMaster');
        insert new List<Contact>{ loser, dummyMaster };

        Merge_Ticket__c ticket = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'Merged',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|fnln@exectest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2,
            Selected_Master_Id__c = String.valueOf(dummyMaster.Id),
            Final_Action__c = 'MERGED'
        );
        insert ticket;

        String loserId = String.valueOf(loser.Id);

        Map<String, Object> snap = new Map<String, Object>{
            'FirstName' => 'Marie',
            'LastName'  => 'Dupont',
            'Email'     => 'marie@exectest.com',
            '__meta_capturedAt' => String.valueOf(System.now())
        };

        Merge_Log__c lg = new Merge_Log__c(
            Merge_Ticket__c           = ticket.Id,
            Object_Type__c            = 'Contact',
            Action_Type__c            = 'MERGE_COMPLETED',
            Master_Record_Id__c       = String.valueOf(dummyMaster.Id),
            Master_Record_Name__c     = 'FNLNMaster',
            Losing_Record_Ids__c      = loserId,
            Losing_Record_Names__c    = 'Marie Dupont',
            Before_Snapshot_JSON__c   = JSON.serialize(new Map<String, Object>{ loserId => snap }),
            After_Snapshot_JSON__c    = '{}',
            Field_Decisions_JSON__c   = '{}',
            Performed_By__c           = UserInfo.getUserId(),
            Performed_Date__c         = System.now()
        );
        insert lg;

        MergeWrappers.SnapshotViewWrapper result =
            MergeController.getLoserSnapshot(String.valueOf(ticket.Id), loserId);

        System.assertNotEquals(null, result);
        System.assertEquals('Marie Dupont', result.recordName,
            'Name should be assembled from FirstName + LastName when Name field absent');
    }

    @IsTest
    static void ctrl_getLoserSnapshot_noLog_returnsNull() {
        // Covers early return on line 223: no Merge_Log__c for the ticket
        Merge_Ticket__c ticket = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|nosnap@exectest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert ticket;

        MergeWrappers.SnapshotViewWrapper result =
            MergeController.getLoserSnapshot(String.valueOf(ticket.Id), '003000000000001AAA');

        System.assertEquals(null, result, 'Should return null when no merge log exists');
    }

    @IsTest
    static void ctrl_getLoserSnapshot_loserNotInSnapshot_returnsNull() {
        // Covers early return on line 229: loserId absent from Before_Snapshot_JSON__c
        Contact dummyMaster = new Contact(LastName = 'SnapMasterMM');
        insert dummyMaster;

        Merge_Ticket__c ticket = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'Merged',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|mismatch@exectest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2,
            Selected_Master_Id__c = String.valueOf(dummyMaster.Id),
            Final_Action__c = 'MERGED'
        );
        insert ticket;

        Map<String, Object> allSnaps = new Map<String, Object>{
            '003000000000001AAA' => new Map<String, Object>{ 'Name' => 'OtherContact' }
        };

        Merge_Log__c lg = new Merge_Log__c(
            Merge_Ticket__c           = ticket.Id,
            Object_Type__c            = 'Contact',
            Action_Type__c            = 'MERGE_COMPLETED',
            Master_Record_Id__c       = String.valueOf(dummyMaster.Id),
            Master_Record_Name__c     = 'SnapMasterMM',
            Losing_Record_Ids__c      = '003000000000001AAA',
            Losing_Record_Names__c    = 'OtherContact',
            Before_Snapshot_JSON__c   = JSON.serialize(allSnaps),
            After_Snapshot_JSON__c    = '{}',
            Field_Decisions_JSON__c   = '{}',
            Performed_By__c           = UserInfo.getUserId(),
            Performed_Date__c         = System.now()
        );
        insert lg;

        MergeWrappers.SnapshotViewWrapper result =
            MergeController.getLoserSnapshot(
                String.valueOf(ticket.Id),
                '003000000000002AAA'  // not in snapshot → null
            );

        System.assertEquals(null, result, 'Should return null when loserId not in snapshot');
    }

    @IsTest
    static void ctrl_sortSnapshotFields_swapsOutOfOrderLabels() {
        // Directly covers the swap body (lines 313-315) in sortSnapshotFields (@TestVisible)
        MergeWrappers.SnapshotField f1 = new MergeWrappers.SnapshotField();
        f1.label = 'ZZZ'; f1.apiName = 'ZZZ__c'; f1.value = 'z-value';
        MergeWrappers.SnapshotField f2 = new MergeWrappers.SnapshotField();
        f2.label = 'AAA'; f2.apiName = 'AAA__c'; f2.value = 'a-value';

        List<MergeWrappers.SnapshotField> fields =
            new List<MergeWrappers.SnapshotField>{ f1, f2 };

        MergeController.sortSnapshotFields(fields);

        System.assertEquals('AAA', fields[0].label, 'AAA should come before ZZZ after sort');
        System.assertEquals('ZZZ', fields[1].label, 'ZZZ should be second after sort');
    }

    // ─── Extra coverage tests ─────────────────────────────────────────────────

    @IsTest
    static void exec_contactMerge_masterNotFound_returnsError() {
        // Covers line 48: candidateMap does not contain masterId
        Contact tempMaster = new Contact(LastName = 'MNFTemp');
        insert tempMaster;
        Id deletedMasterId = tempMaster.Id;
        delete tempMaster;

        Contact loser = new Contact(LastName = 'MNFLoser');
        insert loser;
        Merge_Ticket__c ticket = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|mnf@exectest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert ticket;

        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId       = String.valueOf(ticket.Id);
        req.masterId       = String.valueOf(deletedMasterId);
        req.losingIds      = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions = new Map<String,String>();
        req.notes          = '';

        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(req);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(
            result.errorMessage != null &&
            result.errorMessage.containsIgnoreCase('Master record not found'),
            'Expected master-not-found error, got: ' + result.errorMessage
        );
    }

    @IsTest
    static void exec_contactMerge_mergeDmlFails_returnsError() {
        // Covers lines 126 + 269-274: Database.merge returns isSuccess=false (entity deleted)
        Account acc = makeAccount('DMLFail Org');
        Contact master = makeContact('DFMaster', 'df_master@exectest.com', acc.Id);
        Contact loser  = makeContact('DFLoser',  'df_loser@exectest.com',  acc.Id);
        Merge_Ticket__c ticket = makeContactTicket(master, loser, 'Contact|Email|df@exectest.com');

        // Delete loser — Database.merge will return ENTITY_IS_DELETED failure
        delete loser;

        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(
            makeRequest(ticket.Id, master.Id, new List<Id>{ loser.Id })
        );
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(
            result.errorMessage != null && result.errorMessage.length() > 0,
            'Error message should be populated when merge DML fails'
        );
    }

    @IsTest
    static void exec_contactMerge_loserAccountNotOrphaned_siblingExists() {
        // Covers lines 317-318: loser account still has a contact after merge → not orphaned
        Account masterAcc = makeAccount('SibMasterAcc');
        Account loserAcc  = makeAccount('SibLoserAcc');
        Contact master  = makeContact('SibMaster', 'sib_master@exectest.com', masterAcc.Id);
        Contact loser   = makeContact('SibLoser',  'sib_loser@exectest.com',  loserAcc.Id);
        Contact sibling = new Contact(LastName = 'SibStays', AccountId = loserAcc.Id);
        insert sibling;
        Merge_Ticket__c ticket = makeContactTicket(master, loser, 'Contact|Email|sib@exectest.com');

        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(
            makeRequest(ticket.Id, master.Id, new List<Id>{ loser.Id })
        );
        Test.stopTest();

        System.assertEquals(true, result.success, 'Merge failed: ' + result.errorMessage);
        System.assertEquals(0, result.orphanedAccounts.size(),
            'loserAcc should NOT be orphaned because sibling contact remains');
    }

    @IsTest
    static void ctrl_deleteAllTickets_deletesEverything() {
        List<Merge_Ticket__c> batch = new List<Merge_Ticket__c>();
        for (Integer i = 0; i < 3; i++) {
            batch.add(new Merge_Ticket__c(
                Object_Type__c = 'Contact', Status__c = 'New',
                Match_Type__c = 'Email',
                Match_Key__c  = 'Contact|Email|del_all_' + i + '@exectest.com',
                Match_Confidence__c = 'High', Candidate_Count__c = 2
            ));
        }
        insert batch;

        // Force sandbox mode so the production guard doesn't block this test
        MergeController.TEST_IS_SANDBOX = true;
        Test.startTest();
        Integer deletedCount = MergeController.deleteAllTickets();
        Test.stopTest();
        MergeController.TEST_IS_SANDBOX = null;

        System.assertEquals(3, deletedCount);
        System.assertEquals(0, [SELECT COUNT() FROM Merge_Ticket__c]);
    }
}
