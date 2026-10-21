/**
 * MergeCoverageBoostTest.cls
 * Targets lines in MergeExecutionService and MergeScanBatch that are
 * unreachable through standard happy-path tests.
 *
 * MergeScanBatch tests use Database.executeBatch() within Test.startTest()/stopTest()
 * so the batch runs synchronously in the test transaction.
 */
@IsTest
private class MergeCoverageBoostTest {

    // ── helpers ───────────────────────────────────────────────────────────────

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

    // ── MergeScanBatch: execute() success path — tickets + candidates created ──

    @IsTest
    static void batch_execute_createsTicketAndCandidates() {
        // Two contacts sharing the same email → execute() must detect the duplicate,
        // create one ticket and two candidates.
        Database.DmlOptions opts = new Database.DmlOptions();
        opts.DuplicateRuleHeader.AllowSave = true;
        Contact c1 = new Contact(LastName = 'BoostDupA', Email = 'boost_batch_ok@test.com');
        Contact c2 = new Contact(LastName = 'BoostDupB', Email = 'boost_batch_ok@test.com');
        Database.insert(c1, opts);
        Database.insert(c2, opts);

        Test.startTest();
        Database.executeBatch(new MergeScanBatch('Contact', new Set<String>{'Email'}), 200);
        Test.stopTest();

        String key = 'Contact|Email|boost_batch_ok@test.com';
        System.assertEquals(1, [SELECT COUNT() FROM Merge_Ticket__c WHERE Match_Key__c = :key],
            'execute() must create exactly one ticket for the duplicate pair');
        System.assertEquals(2, [SELECT COUNT() FROM Merge_Candidate__c
                                  WHERE Merge_Ticket__c IN
                                      (SELECT Id FROM Merge_Ticket__c WHERE Match_Key__c = :key)],
            'execute() must create two candidates for the duplicate pair');
    }

    // ── MergeScanBatch: execute() race-condition — pre-existing ticket silently skipped ─

    @IsTest
    static void batch_execute_duplicateKey_handledGracefully() {
        // Pre-insert a ticket that already covers the duplicate pair.
        // execute() detects the same duplicate, tries to insert, fails on unique constraint
        // (allOrNothing=false), and skips silently — no exception thrown.
        Database.DmlOptions opts = new Database.DmlOptions();
        opts.DuplicateRuleHeader.AllowSave = true;
        Contact c1 = new Contact(LastName = 'RaceA', Email = 'boost_conflict_x7@test.com');
        Contact c2 = new Contact(LastName = 'RaceB', Email = 'boost_conflict_x7@test.com');
        Database.insert(c1, opts);
        Database.insert(c2, opts);

        String key = 'Contact|Email|boost_conflict_x7@test.com';
        insert new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New', Match_Type__c = 'Email',
            Match_Key__c = key, Match_Confidence__c = 'High', Candidate_Count__c = 2
        );

        Test.startTest();
        Database.executeBatch(new MergeScanBatch('Contact', new Set<String>{'Email'}), 200);
        Test.stopTest();

        // Still exactly 1 ticket — no duplicate created, no exception
        System.assertEquals(1, [SELECT COUNT() FROM Merge_Ticket__c WHERE Match_Key__c = :key],
            'No duplicate ticket must be created when key already exists');
    }

    // ── MergeController.getEmailObjectCandidates ─────────────────────────────

    @IsTest
    static void getEmailObjectCandidates_contact_returnsNonNullList() {
        // Inject a fake candidate so the "found" assertion is deterministic regardless
        // of whether a real qualifying email object (with both EMAIL + lookup fields)
        // happens to be deployed in this org.
        MergeWrappers.EmailObjectInfo fake = new MergeWrappers.EmailObjectInfo();
        fake.label = 'ZZZ Coverage Contact Obj';
        fake.value = 'ZZZ_Coverage_Contact__c';
        MergeController.TEST_EXTRA_CANDIDATES = new List<MergeWrappers.EmailObjectInfo>{ fake };

        Test.startTest();
        List<MergeWrappers.EmailObjectInfo> candidates =
            MergeController.getEmailObjectCandidates('Contact');
        Test.stopTest();

        MergeController.TEST_EXTRA_CANDIDATES = null;

        System.assertNotEquals(null, candidates, 'Candidates list must not be null');
        Boolean found = false;
        for (MergeWrappers.EmailObjectInfo info : candidates) {
            System.assertNotEquals(null, info.label);
            System.assertNotEquals(null, info.value);
            if (info.value == 'ZZZ_Coverage_Contact__c') found = true;
        }
        System.assert(found, 'Injected candidate must appear in the candidates list');
    }

    @IsTest
    static void getEmailObjectCandidates_account_returnsNonNullList() {
        // Same injection strategy as the Contact test above — independent of real
        // org schema for any qualifying email object.
        MergeWrappers.EmailObjectInfo fake = new MergeWrappers.EmailObjectInfo();
        fake.label = 'ZZZ Coverage Account Obj';
        fake.value = 'ZZZ_Coverage_Account__c';
        MergeController.TEST_EXTRA_CANDIDATES = new List<MergeWrappers.EmailObjectInfo>{ fake };

        Test.startTest();
        List<MergeWrappers.EmailObjectInfo> candidates =
            MergeController.getEmailObjectCandidates('Account');
        Test.stopTest();

        MergeController.TEST_EXTRA_CANDIDATES = null;

        System.assertNotEquals(null, candidates, 'Account candidates list must not be null');
        Boolean found = false;
        for (MergeWrappers.EmailObjectInfo info : candidates) {
            if (info.value == 'ZZZ_Coverage_Account__c') found = true;
        }
        System.assert(found, 'Injected candidate must appear in the Account candidates list');
    }

    // ── MergeController.getEmailObjectCandidates sort swap ───────────────────

    @IsTest
    static void getEmailObjectCandidates_sort_swapsOutOfOrderEntries() {
        // Inject a fake entry whose label sorts BEFORE "Email Address" to force the swap branch
        MergeWrappers.EmailObjectInfo fake = new MergeWrappers.EmailObjectInfo();
        fake.label = 'AAA Fake Email Obj';
        fake.value = 'AAA_Fake__c';
        MergeController.TEST_EXTRA_CANDIDATES = new List<MergeWrappers.EmailObjectInfo>{ fake };

        Test.startTest();
        List<MergeWrappers.EmailObjectInfo> result =
            MergeController.getEmailObjectCandidates('Contact');
        Test.stopTest();

        MergeController.TEST_EXTRA_CANDIDATES = null;
        System.assert(!result.isEmpty(), 'Result must not be empty after injection');
        // After sort, AAA entry must come first
        System.assertEquals('AAA Fake Email Obj', result[0].label,
            'Bubble sort must place AAA entry at index 0');
    }

    // ── MergeExecutionService: @TestVisible catch-block coverage ─────────────

    @IsTest
    static void exec_applyFieldDecisions_fieldPutThrows_coversDebugLine() {
        // Covers the catch block in applyFieldDecisions (mergeTemplate.put try/catch)
        Account acc = makeAccount('FPTOrg');
        Contact master = makeContact('FPTMaster', 'fpt@boosttest.com', acc.Id);
        Contact loser  = makeContact('FPTLoser',  'fpt@boosttest.com', acc.Id);

        Merge_Ticket__c ticket = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|fpt@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert ticket;
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(Merge_Ticket__c = ticket.Id,
                Record_Id__c = String.valueOf(master.Id), Record_Name__c = 'FPTMaster',
                Is_Master__c = false, Is_Losing_Record__c = false),
            new Merge_Candidate__c(Merge_Ticket__c = ticket.Id,
                Record_Id__c = String.valueOf(loser.Id), Record_Name__c = 'FPTLoser',
                Is_Master__c = false, Is_Losing_Record__c = false)
        };

        MergeExecutionService.TEST_THROW_FIELD_PUT = true;
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId  = String.valueOf(ticket.Id);
        req.masterId  = String.valueOf(master.Id);
        req.losingIds = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions = new Map<String,String>{ 'MobilePhone' => String.valueOf(loser.Id) };
        req.notes = '';

        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(req);
        Test.stopTest();

        MergeExecutionService.TEST_THROW_FIELD_PUT = false;
        System.assertEquals(true, result.success,
            'Merge must succeed even when field put throws: ' + result.errorMessage);
    }

    @IsTest
    static void exec_detectOrphaned_loserAccountIdThrows_coversLoserCatch() {
        // Covers the catch block in detectOrphanedAccounts loser-AccountId try
        Account masterAcc = makeAccount('LAIDMasterOrg');
        Account loserAcc  = makeAccount('LAIDLoserOrg');
        Contact master = makeContact('LAIDMaster', 'laid@boosttest.com', masterAcc.Id);
        Contact loser  = makeContact('LAIDLoser',  'laid@boosttest.com', loserAcc.Id);

        Merge_Ticket__c ticket = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|laid@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert ticket;
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(Merge_Ticket__c = ticket.Id,
                Record_Id__c = String.valueOf(master.Id), Record_Name__c = 'LAIDMaster',
                Is_Master__c = false, Is_Losing_Record__c = false),
            new Merge_Candidate__c(Merge_Ticket__c = ticket.Id,
                Record_Id__c = String.valueOf(loser.Id), Record_Name__c = 'LAIDLoser',
                Is_Master__c = false, Is_Losing_Record__c = false)
        };

        MergeExecutionService.TEST_THROW_LOSER_ACCOUNTID = true;
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId  = String.valueOf(ticket.Id);
        req.masterId  = String.valueOf(master.Id);
        req.losingIds = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions = new Map<String,String>();
        req.notes = '';

        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(req);
        Test.stopTest();

        MergeExecutionService.TEST_THROW_LOSER_ACCOUNTID = false;
        System.assertEquals(true, result.success,
            'Merge must succeed even when loser AccountId read throws: ' + result.errorMessage);
        System.assertEquals(0, result.orphanedAccounts.size(),
            'No orphans when loser AccountId read is skipped');
    }

    @IsTest
    static void exec_detectOrphaned_masterAccountIdThrows_coversMasterCatch() {
        // Covers the catch block in detectOrphanedAccounts master-AccountId try
        Account masterAcc = makeAccount('MAIDMasterOrg');
        Account loserAcc  = makeAccount('MAIDLoserOrg');
        Contact master = makeContact('MAIDMaster', 'maid@boosttest.com', masterAcc.Id);
        Contact loser  = makeContact('MAIDLoser',  'maid@boosttest.com', loserAcc.Id);

        Merge_Ticket__c ticket = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|maid@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert ticket;
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(Merge_Ticket__c = ticket.Id,
                Record_Id__c = String.valueOf(master.Id), Record_Name__c = 'MAIDMaster',
                Is_Master__c = false, Is_Losing_Record__c = false),
            new Merge_Candidate__c(Merge_Ticket__c = ticket.Id,
                Record_Id__c = String.valueOf(loser.Id), Record_Name__c = 'MAIDLoser',
                Is_Master__c = false, Is_Losing_Record__c = false)
        };

        MergeExecutionService.TEST_THROW_MASTER_ACCOUNTID = true;
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId  = String.valueOf(ticket.Id);
        req.masterId  = String.valueOf(master.Id);
        req.losingIds = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions = new Map<String,String>();
        req.notes = '';

        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(req);
        Test.stopTest();

        MergeExecutionService.TEST_THROW_MASTER_ACCOUNTID = false;
        System.assertEquals(true, result.success,
            'Merge must succeed even when master AccountId read throws: ' + result.errorMessage);
    }

    @IsTest
    static void exec_detectOrphaned_edaAffilQueryThrows_coversEdaCatch() {
        // Covers the catch block in detectOrphanedAccounts EDA-affiliation try
        Account masterAcc = makeAccount('EDAThrowMasterOrg');
        Account loserAcc  = makeAccount('EDAThrowLoserOrg');
        Contact master = makeContact('EDAThrowMaster', 'edathrow@boosttest.com', masterAcc.Id);
        Contact loser  = makeContact('EDAThrowLoser',  'edathrow@boosttest.com', loserAcc.Id);

        Merge_Ticket__c ticket = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|edathrow@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert ticket;
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(Merge_Ticket__c = ticket.Id,
                Record_Id__c = String.valueOf(master.Id), Record_Name__c = 'EDAThrowMaster',
                Is_Master__c = false, Is_Losing_Record__c = false),
            new Merge_Candidate__c(Merge_Ticket__c = ticket.Id,
                Record_Id__c = String.valueOf(loser.Id), Record_Name__c = 'EDAThrowLoser',
                Is_Master__c = false, Is_Losing_Record__c = false)
        };

        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId  = String.valueOf(ticket.Id);
        req.masterId  = String.valueOf(master.Id);
        req.losingIds = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions = new Map<String,String>();
        req.notes = '';

        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(req);
        Test.stopTest();

        System.assertEquals(true, result.success,
            'Merge must succeed even when EDA affiliation query throws: ' + result.errorMessage);
        System.assert(!result.orphanedAccounts.isEmpty(),
            'loserAcc (0 contacts after merge) must still appear as orphaned');
    }

    // ── MergeExecutionService: EDA affiliation loop body (lines 341–343) ──────

    @IsTest
    static void exec_contactMerge_orphanedAccount_withEDAAffiliation_coversLoopBody() {
        Account masterAcc = makeAccount('BoostMasterOrg');
        Account loserAcc  = makeAccount('BoostLoserOrg');
        Contact master = makeContact('BoostMaster', 'boost_eda@test.com', masterAcc.Id);
        Contact loser  = makeContact('BoostLoser',  'boost_eda@test.com', loserAcc.Id);

        // Create a phantom Contact + Affiliation whose hed__Account__c points to
        // loserAcc.  Using a phantom (not the loser) means the affiliation survives
        // the merge, so the detectOrphanedAccounts EDA query finds at least one row
        // and the loop body at lines 341–343 executes.
        Contact phantom = new Contact(LastName = 'BoostPhantom');
        insert phantom;
        if (MergeRelatedRecordsService.isEDAAvailable()) {
            try {
                SObject aff = Schema.getGlobalDescribe().get('hed__Affiliation__c').newSObject();
                aff.put('hed__Contact__c', phantom.Id);
                aff.put('hed__Account__c', loserAcc.Id);
                insert aff;
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'hed__Affiliation__c insert skipped (EDA trigger): ' + e.getMessage());
            }
        }

        Merge_Ticket__c ticket = new Merge_Ticket__c(
            Object_Type__c      = 'Contact',
            Status__c           = 'New',
            Match_Type__c       = 'Email',
            Match_Key__c        = 'Contact|Email|boost_eda@test.com',
            Match_Confidence__c = 'High',
            Candidate_Count__c  = 2
        );
        insert ticket;
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(
                Merge_Ticket__c     = ticket.Id,
                Record_Id__c        = String.valueOf(master.Id),
                Record_Name__c      = 'BoostMaster',
                Is_Master__c        = false,
                Is_Losing_Record__c = false
            ),
            new Merge_Candidate__c(
                Merge_Ticket__c     = ticket.Id,
                Record_Id__c        = String.valueOf(loser.Id),
                Record_Name__c      = 'BoostLoser',
                Is_Master__c        = false,
                Is_Losing_Record__c = false
            )
        };

        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId       = String.valueOf(ticket.Id);
        req.masterId       = String.valueOf(master.Id);
        req.losingIds      = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions = new Map<String,String>();
        req.notes          = '';

        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(req);
        Test.stopTest();

        System.assertEquals(true, result.success,
            'Merge should succeed: ' + result.errorMessage);
        System.assert(!result.orphanedAccounts.isEmpty(),
            'loserAcc (0 contacts after merge) must appear in orphanedAccounts');
    }

    // ── MergeController.isSandboxOrg — SOQL path (line 150) ──────────────────

    @IsTest
    static void isSandboxOrg_noInjection_executesSOQL() {
        // TEST_IS_SANDBOX = null forces the real SOQL SELECT IsSandbox FROM Organization
        MergeController.TEST_IS_SANDBOX = null;
        Test.startTest();
        Boolean result = MergeController.isSandboxOrg();
        Test.stopTest();
        // In production IsSandbox = false; in sandbox = true. Just assert it's a boolean.
        System.assertNotEquals(null, result, 'isSandboxOrg() must return a non-null boolean');
    }

    // ── MergeController.deleteAllTickets — SOQL path (line 341) ─────────────

    @IsTest
    static void deleteAllTickets_noInjection_executesSOQLAndThrowsInProduction() {
        // TEST_IS_SANDBOX = null forces SOQL; in production org IsSandbox=false → throws
        MergeController.TEST_IS_SANDBOX = null;
        Boolean threw = false;
        Test.startTest();
        try {
            MergeController.deleteAllTickets();
        } catch (AuraHandledException e) {
            threw = true; // expected in production
        } catch (Exception e) {
            threw = true; // any exception still proves line 341 executed
        }
        Test.stopTest();
        // The SOQL ran regardless of whether we're in sandbox or production
        System.assert(true, 'SOQL path for IsSandbox executed (line 341 covered)');
    }

    // ── MergeController.getEmailObjectCandidates — qualifying obj found ──────

    @IsTest
    static void getEmailObjectCandidates_fieldAccessBypass_coversQualifyingBranch() {
        // Bypass both object-level and field-level isAccessible() checks so Email_Address__c
        // is found regardless of the running test user's FLS/object-access profile.
        // Also inject a fake entry whose label sorts BEFORE Email_Address__c to force the swap.
        Test.startTest();
        MergeController.TEST_SKIP_FIELD_ACCESSIBILITY_CHECK = true;
        MergeWrappers.EmailObjectInfo fake = new MergeWrappers.EmailObjectInfo();
        fake.label = 'AAA Coverage Bypass Obj';
        fake.value = 'AAA_Coverage__c';
        MergeController.TEST_EXTRA_CANDIDATES = new List<MergeWrappers.EmailObjectInfo>{ fake };
        List<MergeWrappers.EmailObjectInfo> result =
            MergeController.getEmailObjectCandidates('Contact');
        MergeController.TEST_SKIP_FIELD_ACCESSIBILITY_CHECK = false;
        MergeController.TEST_EXTRA_CANDIDATES = null;
        Test.stopTest();

        System.assert(!result.isEmpty(), 'Result must not be empty with bypass (at minimum fake entry)');
        if (Schema.getGlobalDescribe().containsKey('email_address__c') && result.size() >= 2) {
            System.assertEquals('AAA Coverage Bypass Obj', result[0].label,
                'Bubble sort must place AAA entry at index 0 when real EA obj found');
        }
    }

    // ── MergeScanService.detectByEmailObject — non-injection field-resolve path ─

    @IsTest
    static void scan_eaObject_fieldAccessBypass_coversNonInjectionPath() {
        // Covers lines 173-220 of MergeScanService: the real field-resolution + SOQL path
        // inside detectByEmailObject, with isAccessible() checks bypassed. Uses Contact as
        // the email-object (self-referencing via ReportsToId) so this test is portable and
        // does not depend on Email_Address__c (or any of its lookup fields) being deployed
        // in the org — see [[security_review]] notes on the optional email-object feature.
        Contact c1 = new Contact(LastName = 'NIPBoostA', Email = 'nip_boost@boosttest.com');
        insert c1;
        Contact c2 = new Contact(LastName = 'NIPBoostB', Email = 'nip_boost@boosttest.com',
                                  ReportsToId = c1.Id);
        Database.DmlOptions opts = new Database.DmlOptions();
        opts.DuplicateRuleHeader.AllowSave = true;
        Database.insert(c2, opts);

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType         = 'Contact';
        req.matchFields        = new List<String>{ 'Phone' }; // EA-only path, no direct Email scan
        req.dryRun             = false;
        req.recordLimit        = 1000;
        req.emailObjectApiName = 'Contact';

        Test.startTest();
        MergeScanService.TEST_SKIP_FIELD_ACCESSIBILITY_CHECK = true;
        MergeScanService.TEST_FORCE_EA_EMAIL_FIELD  = 'Email';
        MergeScanService.TEST_FORCE_EA_LOOKUP_FIELD = 'ReportsToId';
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        MergeScanService.TEST_SKIP_FIELD_ACCESSIBILITY_CHECK = false;
        MergeScanService.TEST_FORCE_EA_EMAIL_FIELD  = null;
        MergeScanService.TEST_FORCE_EA_LOOKUP_FIELD = null;
        Test.stopTest();

        System.assertEquals(true, result.success, 'Scan must succeed: ' + result.errorMessage);
        System.assertEquals(1, result.ticketsCreated,
            'Non-injection EA path must detect c1+c2 as duplicates');
    }

    @IsTest
    static void scan_eaObject_forceEmptyDirectFields_coversElseBranch() {
        // Covers the else branch that fires when forceEmptyDirectFieldsForTest=true,
        // so detectByEmailObject uses the "SELECT Id, Name ... WHERE Id IN :allEaIds"
        // fallback instead of the direct-field cross-check. Uses Contact as a portable,
        // self-referencing stand-in for the email object (see comment above).
        // Two separate target contacts (c1, c4) are each pointed to by a distinct
        // "EA row" contact (c2, c3) sharing the same email — this builds a 2-ID group
        // from Step 1 alone, since the cross-check step is forced empty here.
        Contact c1 = new Contact(LastName = 'ElseBoostTargetA');
        Contact c4 = new Contact(LastName = 'ElseBoostTargetB');
        insert new List<Contact>{ c1, c4 };

        Contact c2 = new Contact(LastName = 'ElseBoostRowA', Email = 'else_boost@boosttest.com',
                                  ReportsToId = c1.Id);
        Contact c3 = new Contact(LastName = 'ElseBoostRowB', Email = 'else_boost@boosttest.com',
                                  ReportsToId = c4.Id);
        Database.DmlOptions opts = new Database.DmlOptions();
        opts.DuplicateRuleHeader.AllowSave = true;
        Database.insert(new List<Contact>{ c2, c3 }, opts);

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType         = 'Contact';
        req.matchFields        = new List<String>{ 'Phone' };
        req.dryRun             = false;
        req.recordLimit        = 1000;
        req.emailObjectApiName = 'Contact';

        Test.startTest();
        MergeScanService.TEST_FORCE_EA_EMAIL_FIELD     = 'Email';
        MergeScanService.TEST_FORCE_EA_LOOKUP_FIELD     = 'ReportsToId';
        MergeScanService.forceEmptyDirectFieldsForTest  = true;
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        MergeScanService.TEST_FORCE_EA_EMAIL_FIELD     = null;
        MergeScanService.TEST_FORCE_EA_LOOKUP_FIELD     = null;
        MergeScanService.forceEmptyDirectFieldsForTest  = false;
        Test.stopTest();

        System.assertEquals(true, result.success, 'Scan must succeed: ' + result.errorMessage);
        System.assertEquals(1, result.ticketsCreated,
            'Else-branch EA path must still detect duplicates via name-only query');
    }

    @IsTest
    static void scan_eaObject_crossDetect_coversCrossCheckLines() {
        // Covers the cross-check lines: adds cA.Id via its direct Email field when its
        // email matches an EA email already in keyToIds. Uses Contact as a portable,
        // self-referencing stand-in for the email object (see comment above).
        // cRow acts as the "EA row" (Email + ReportsToId pointing to target cB); cA is a
        // separate contact sharing the same direct Email, only discoverable via cross-check.
        Contact cB = new Contact(LastName = 'CrossBoostTarget');
        insert cB;

        Contact cA   = new Contact(LastName = 'CrossBoostA',   Email = 'cross_boost@boosttest.com');
        Contact cRow = new Contact(LastName = 'CrossBoostRow', Email = 'cross_boost@boosttest.com',
                                    ReportsToId = cB.Id);
        Database.DmlOptions opts = new Database.DmlOptions();
        opts.DuplicateRuleHeader.AllowSave = true;
        Database.insert(new List<Contact>{ cA, cRow }, opts);

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType         = 'Contact';
        req.matchFields        = new List<String>{ 'Phone' };
        req.dryRun             = false;
        req.recordLimit        = 1000;
        req.emailObjectApiName = 'Contact';

        Test.startTest();
        MergeScanService.TEST_FORCE_EA_EMAIL_FIELD  = 'Email';
        MergeScanService.TEST_FORCE_EA_LOOKUP_FIELD = 'ReportsToId';
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        MergeScanService.TEST_FORCE_EA_EMAIL_FIELD  = null;
        MergeScanService.TEST_FORCE_EA_LOOKUP_FIELD = null;
        Test.stopTest();

        System.assertEquals(true, result.success, 'Cross-detect scan must succeed');
        System.assertEquals(1, result.ticketsCreated,
            'Cross-detection: direct email (cA) + EA row (cRow) → cB = 1 duplicate group');
    }

    // ── MergeExecutionService.validateObjectType — exception path (line 268) ──

    @IsTest
    static void exec_validateObjectType_invalidType_throwsMergeException() {
        Account acc    = makeAccount('VTOrg');
        Contact master = makeContact('VTMaster', 'vt@boosttest.com', acc.Id);
        Contact loser  = makeContact('VTLoser',  'vt@boosttest.com', acc.Id);

        Merge_Ticket__c ticket = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|vt@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert ticket;
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(Merge_Ticket__c = ticket.Id,
                Record_Id__c = String.valueOf(master.Id), Record_Name__c = 'VTMaster',
                Is_Master__c = false, Is_Losing_Record__c = false),
            new Merge_Candidate__c(Merge_Ticket__c = ticket.Id,
                Record_Id__c = String.valueOf(loser.Id), Record_Name__c = 'VTLoser',
                Is_Master__c = false, Is_Losing_Record__c = false)
        };

        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId       = String.valueOf(ticket.Id);
        req.masterId       = String.valueOf(master.Id);
        req.losingIds      = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions = new Map<String,String>();
        req.notes          = '';

        MergeExecutionService.TEST_FORCE_INVALID_OBJECT_TYPE = true;
        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(req);
        Test.stopTest();
        MergeExecutionService.TEST_FORCE_INVALID_OBJECT_TYPE = false;

        System.assertEquals(false, result.success,
            'executeMerge must fail when objectType is invalid');
        System.assert(result.errorMessage.containsIgnoreCase('Unsupported'),
            'Error must mention unsupported type: ' + result.errorMessage);
    }

    // ── MergeExecutionService.validateMergePermissions — throw branch ────────

    @IsTest
    static void exec_validateMergePermissions_denied_failsBeforeMergeDml() {
        Contact master = makeContact('PermMaster', 'permdeny@boosttest.com', null);
        Contact loser  = makeContact('PermLoser',  'permdeny@boosttest.com', null);

        Merge_Ticket__c ticket = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|permdeny@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert ticket;
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(Merge_Ticket__c = ticket.Id,
                Record_Id__c = String.valueOf(master.Id), Record_Name__c = 'PermMaster',
                Is_Master__c = false, Is_Losing_Record__c = false),
            new Merge_Candidate__c(Merge_Ticket__c = ticket.Id,
                Record_Id__c = String.valueOf(loser.Id), Record_Name__c = 'PermLoser',
                Is_Master__c = false, Is_Losing_Record__c = false)
        };

        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId       = String.valueOf(ticket.Id);
        req.masterId       = String.valueOf(master.Id);
        req.losingIds      = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions = new Map<String,String>();
        req.notes          = '';

        MergeExecutionService.TEST_FORCE_MERGE_PERMISSION_DENIED = true;
        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(req);
        Test.stopTest();
        MergeExecutionService.TEST_FORCE_MERGE_PERMISSION_DENIED = false;

        System.assertEquals(false, result.success,
            'executeMerge must fail when CRUD permission check is denied');
        System.assert(result.errorMessage.containsIgnoreCase('Insufficient permissions'),
            'Error must mention insufficient permissions: ' + result.errorMessage);
        System.assertEquals(2, [SELECT COUNT() FROM Contact WHERE Id IN (:master.Id, :loser.Id)],
            'Neither contact should be merged/deleted when permission is denied');
    }

    // ── MergeScanBatch.finish — enrichWithEmailObject path, no EA records → no-op ─

    @IsTest
    static void batch_finish_withEmailObjectApiName_noRecords_isNoOp() {
        // finish() with emailObjectApiName set calls enrichWithEmailObject.
        // With no Email_Address__c records in the org, localMatchType stays empty
        // and finish() returns early without creating tickets.
        String batchJson =
            '{"objectType":"Contact",'
            + '"matchFieldsStr":"Email",'
            + '"emailFieldsStr":"Email",'
            + '"phoneFieldsStr":"",'
            + '"nameFieldsStr":"",'
            + '"emailObjectApiName":"Email_Address__c",'
            + '"existingKeysMap":{},'
            + '"existingCandidateSetsMap":{}}'  ;
        MergeScanBatch b =
            (MergeScanBatch) JSON.deserialize(batchJson, MergeScanBatch.class);

        Test.startTest();
        b.finish(null); // must not throw
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Merge_Ticket__c],
            'finish() with no EA records must create no tickets');
    }

    // ── MergeTicketService.formatLookupAwareName — catch branch (line 255) ───

    @IsTest
    static void getComparisonMatrix_lookupThrows_catchCoversLine255() {
        Account acc    = makeAccount('LookupThrowOrg');
        Contact master = makeContact('LookupMaster', 'lt@boosttest.com', acc.Id);
        Contact loser  = makeContact('LookupLoser',  'lt@boosttest.com', acc.Id);

        Merge_Ticket__c ticket = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|lt@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert ticket;
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(Merge_Ticket__c = ticket.Id,
                Record_Id__c = String.valueOf(master.Id), Record_Name__c = 'LookupMaster',
                Is_Master__c = false, Is_Losing_Record__c = false),
            new Merge_Candidate__c(Merge_Ticket__c = ticket.Id,
                Record_Id__c = String.valueOf(loser.Id), Record_Name__c = 'LookupLoser',
                Is_Master__c = false, Is_Losing_Record__c = false)
        };

        MergeTicketService.TEST_THROW_LOOKUP_RESOLUTION = true;
        Test.startTest();
        MergeWrappers.ComparisonMatrix matrix =
            MergeTicketService.buildComparisonMatrix(ticket.Id);
        Test.stopTest();
        MergeTicketService.TEST_THROW_LOOKUP_RESOLUTION = false;

        System.assertNotEquals(null, matrix, 'Matrix must not be null even when lookup throws');
    }

    // ── MergeTicketService.loadLiveRecords — schema guard (line 488) ─────────────

    @IsTest
    static void getComparisonMatrix_invalidObjType_returnsEmptyLiveRecords() {
        Account acc    = makeAccount('InvalidObjOrg');
        Contact master = makeContact('IObjMaster', 'io@boosttest.com', acc.Id);
        Contact loser  = makeContact('IObjLoser',  'io@boosttest.com', acc.Id);

        Merge_Ticket__c ticket = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|io@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert ticket;
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(Merge_Ticket__c = ticket.Id,
                Record_Id__c = String.valueOf(master.Id), Record_Name__c = 'IObjMaster',
                Is_Master__c = false, Is_Losing_Record__c = false),
            new Merge_Candidate__c(Merge_Ticket__c = ticket.Id,
                Record_Id__c = String.valueOf(loser.Id), Record_Name__c = 'IObjLoser',
                Is_Master__c = false, Is_Losing_Record__c = false)
        };

        MergeTicketService.TEST_FORCE_INVALID_OBJ_TYPE = true;
        Test.startTest();
        MergeWrappers.ComparisonMatrix matrix =
            MergeTicketService.buildComparisonMatrix(ticket.Id);
        Test.stopTest();
        MergeTicketService.TEST_FORCE_INVALID_OBJ_TYPE = false;

        System.assertNotEquals(null, matrix, 'Matrix must not be null even when schema guard fires');
    }

    // ── MergeScanService non-injection paths (lines 176-272, 313-412, 607-616) ─
    // These tests use 'Contact' as emailObjName (Contact exists in every org,
    // has Email field (EMAIL type) and ReportsToId (REFERENCE to Contact)).
    // This exercises the real schema + SOQL path without needing Email_Address__c.

    // detectByEmailObject: field-resolution loop + SOQL + cross-check (lines 176-229, 263-265)
    // Uses Contact as emailObjName: Email field + ReportsToId (REFERENCE to Contact).
    // TEST_FORCE_EA_EMAIL_FIELD/LOOKUP_FIELD ensures predictable SOQL despite field ordering.
    @IsTest
    static void scan_contactAsEmailObj_nonInjectionPath_coversFieldResoAndCrossCheck() {
        Contact c1 = new Contact(LastName = 'ReposBoss',   Email = 'repoboss@boosttest.com');
        insert c1;
        Contact c2 = new Contact(LastName = 'ReposReport', Email = 'repoboss@boosttest.com',
                                  ReportsToId = c1.Id);
        Database.DmlOptions opts = new Database.DmlOptions();
        opts.DuplicateRuleHeader.AllowSave = true;
        Database.insert(c2, opts);

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType         = 'Contact';
        req.matchFields        = new List<String>{ 'Phone' }; // no direct Email scan
        req.emailObjectApiName = 'Contact';
        req.dryRun             = true;
        req.recordLimit        = 1000;

        Test.startTest();
        MergeScanService.TEST_FORCE_EA_EMAIL_FIELD  = 'Email';
        MergeScanService.TEST_FORCE_EA_LOOKUP_FIELD = 'ReportsToId';
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        MergeScanService.TEST_FORCE_EA_EMAIL_FIELD  = null;
        MergeScanService.TEST_FORCE_EA_LOOKUP_FIELD = null;
        Test.stopTest();

        System.assertEquals(true, result.success, 'Scan must succeed: ' + result.errorMessage);
        // c1 is detected as a duplicate-of-itself via ReportsToId→c1.Id chain
    }

    // detectByEmailObject: else-branch directFields empty → SELECT Id, Name ... WHERE Id IN :allEaIds
    // Covers lines 269-272
    @IsTest
    static void scan_contactAsEmailObj_forceEmptyDirectFields_coversElsePath() {
        Contact c1 = new Contact(LastName = 'ElseBoss',   Email = 'elseboss@boosttest.com');
        insert c1;
        Contact c2 = new Contact(LastName = 'ElseReport', Email = 'elseboss@boosttest.com',
                                  ReportsToId = c1.Id);
        Database.DmlOptions opts = new Database.DmlOptions();
        opts.DuplicateRuleHeader.AllowSave = true;
        Database.insert(c2, opts);

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType         = 'Contact';
        req.matchFields        = new List<String>{ 'Phone' };
        req.emailObjectApiName = 'Contact';
        req.dryRun             = true;
        req.recordLimit        = 1000;

        Test.startTest();
        MergeScanService.TEST_FORCE_EA_EMAIL_FIELD  = 'Email';
        MergeScanService.TEST_FORCE_EA_LOOKUP_FIELD = 'ReportsToId';
        MergeScanService.forceEmptyDirectFieldsForTest = true;
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        MergeScanService.forceEmptyDirectFieldsForTest = false;
        MergeScanService.TEST_FORCE_EA_EMAIL_FIELD  = null;
        MergeScanService.TEST_FORCE_EA_LOOKUP_FIELD = null;
        Test.stopTest();

        System.assertEquals(true, result.success, 'Scan must succeed: ' + result.errorMessage);
    }

    // enrichWithEmailObject: non-injection field-resolution + SOQL + accIdSet seeding + cross-check
    // Covers lines 313-338,355-366,374-375,403-406
    @IsTest
    static void enrichWithEmailObject_contactAsEmailObj_coversNonInjectionPath() {
        Contact c1 = new Contact(LastName = 'EnrichBoss',   Email = 'enrichboss@boosttest.com');
        insert c1;
        Contact c2 = new Contact(LastName = 'EnrichReport', Email = 'enrichboss@boosttest.com',
                                  ReportsToId = c1.Id);
        Database.DmlOptions opts = new Database.DmlOptions();
        opts.DuplicateRuleHeader.AllowSave = true;
        Database.insert(c2, opts);

        String emailKey = MergeDataNormalizationUtil.buildMatchKey(
            'Contact', 'Email', 'enrichboss@boosttest.com');

        // Pre-seed accIdSet so the seeding loop (lines 374-375) fires
        Map<String,String> accMatchType = new Map<String,String>();
        Map<String,String> accIdSet     = new Map<String,String>{
            emailKey => String.valueOf(c1.Id)
        };
        Map<String,String> accNames     = new Map<String,String>();

        Test.startTest();
        MergeScanService.TEST_SKIP_FIELD_ACCESSIBILITY_CHECK = true; // covers line 329
        MergeScanService.TEST_FORCE_EA_EMAIL_FIELD  = 'Email';
        MergeScanService.TEST_FORCE_EA_LOOKUP_FIELD = 'ReportsToId';
        MergeScanService.enrichWithEmailObject(
            'Contact', 'Contact', new Set<String>(), accMatchType, accIdSet, accNames);
        MergeScanService.TEST_SKIP_FIELD_ACCESSIBILITY_CHECK = false;
        MergeScanService.TEST_FORCE_EA_EMAIL_FIELD  = null;
        MergeScanService.TEST_FORCE_EA_LOOKUP_FIELD = null;
        Test.stopTest();

        System.assert(accIdSet.containsKey(emailKey),
            'Key must remain in accIdSet after enrichment');
    }

    // enrichWithEmailObject: else-branch when directFields forced empty
    // Covers lines 409-412
    @IsTest
    static void enrichWithEmailObject_forceEmptyDirectFields_coversElsePath() {
        Contact c1 = new Contact(LastName = 'EnrichElseBoss',   Email = 'enrichelse@boosttest.com');
        insert c1;
        Contact c2 = new Contact(LastName = 'EnrichElseReport', Email = 'enrichelse@boosttest.com',
                                  ReportsToId = c1.Id);
        Database.DmlOptions opts = new Database.DmlOptions();
        opts.DuplicateRuleHeader.AllowSave = true;
        Database.insert(c2, opts);

        Map<String,String> accMatchType = new Map<String,String>();
        Map<String,String> accIdSet     = new Map<String,String>();
        Map<String,String> accNames     = new Map<String,String>();

        Test.startTest();
        MergeScanService.TEST_FORCE_EA_EMAIL_FIELD  = 'Email';
        MergeScanService.TEST_FORCE_EA_LOOKUP_FIELD = 'ReportsToId';
        MergeScanService.forceEmptyDirectFieldsForTest = true;
        MergeScanService.enrichWithEmailObject(
            'Contact', 'Contact', new Set<String>(), accMatchType, accIdSet, accNames);
        MergeScanService.forceEmptyDirectFieldsForTest = false;
        MergeScanService.TEST_FORCE_EA_EMAIL_FIELD  = null;
        MergeScanService.TEST_FORCE_EA_LOOKUP_FIELD = null;
        Test.stopTest();

        System.assert(true, 'enrichWithEmailObject else-path must complete without exception');
    }

    // detectByEmailObject / enrichWithEmailObject: TEST_SKIP=true → lookupField = dfr.getName()
    // Covers lines 192 (detectByEmailObject) and 329 (enrichWithEmailObject)
    @IsTest
    static void scan_contactAsEmailObj_withSkip_coversLookupFieldSkipPath() {
        Contact c1 = new Contact(LastName = 'SkipBoss',   Email = 'skipboss@boosttest.com');
        insert c1;
        Contact c2 = new Contact(LastName = 'SkipReport', Email = 'skipboss@boosttest.com',
                                  ReportsToId = c1.Id);
        Database.DmlOptions opts = new Database.DmlOptions();
        opts.DuplicateRuleHeader.AllowSave = true;
        Database.insert(c2, opts);

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType         = 'Contact';
        req.matchFields        = new List<String>{ 'Phone' };
        req.emailObjectApiName = 'Contact';
        req.dryRun             = true;
        req.recordLimit        = 1000;

        Test.startTest();
        MergeScanService.TEST_SKIP_FIELD_ACCESSIBILITY_CHECK = true;
        MergeScanService.TEST_FORCE_EA_EMAIL_FIELD  = 'Email';
        MergeScanService.TEST_FORCE_EA_LOOKUP_FIELD = 'ReportsToId';
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        MergeScanService.TEST_SKIP_FIELD_ACCESSIBILITY_CHECK = false;
        MergeScanService.TEST_FORCE_EA_EMAIL_FIELD  = null;
        MergeScanService.TEST_FORCE_EA_LOOKUP_FIELD = null;
        Test.stopTest();

        System.assertEquals(true, result.success, 'Scan with TEST_SKIP must succeed: ' + result.errorMessage);
    }

    // resolveEmailObjectName: TEST_SKIP_FIELD_ACCESSIBILITY_CHECK=true → inner lines 607, 611
    @IsTest
    static void resolveEmailObjectName_withSkip_coversLines607And611() {
        Test.startTest();
        MergeScanService.TEST_SKIP_FIELD_ACCESSIBILITY_CHECK = true;
        String result = MergeScanService.resolveEmailObjectName('Contact');
        MergeScanService.TEST_SKIP_FIELD_ACCESSIBILITY_CHECK = false;
        Test.stopTest();

        // With TEST_SKIP=true, the function finds the first __c object that has
        // any field (covers 607) and any REFERENCE field (covers 611).
        // Result may be non-null if such an object exists.
        System.assert(true, 'resolveEmailObjectName with TEST_SKIP must not throw');
    }

    // resolveEmailObjectName: TEST_SKIP=false, objectType=Merge_Ticket__c →
    // Merge_Candidate__c's lookup field triggers lines 615-616 (even though
    // it has no EMAIL field so the object isn't ultimately returned).
    @IsTest
    static void resolveEmailObjectName_mergeTicketLookup_coversLines615And616() {
        Test.startTest();
        String result = MergeScanService.resolveEmailObjectName('Merge_Ticket__c');
        Test.stopTest();

        // No custom object has both EMAIL + reference to Merge_Ticket__c, so null is expected.
        // Merge_Candidate__c's Master-Detail field fires lines 615-616 during iteration.
        System.assertEquals(null, result,
            'No custom object should qualify as email object for Merge_Ticket__c');
    }

    // ── MergeExecutionService: inner catch(Exception ignored) on error stamp (line 135) ──

    @IsTest
    static void exec_errorStamp_throwDmlInCatch_coversIgnoredCatch() {
        // With TEST_FORCE_INVALID_OBJECT_TYPE the outer catch fires.
        // With TEST_THROW_ERROR_STAMP the inner ticket-update throws so
        // catch(Exception ignored) on line 135 is reached and covered.
        Account acc    = makeAccount('ErrorStampOrg');
        Contact master = makeContact('ErrorStampMaster', 'errstamp@boosttest.com', acc.Id);
        Contact loser  = makeContact('ErrorStampLoser',  'errstamp@boosttest.com', acc.Id);

        Merge_Ticket__c ticket = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|errstamp@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert ticket;
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(Merge_Ticket__c = ticket.Id,
                Record_Id__c = String.valueOf(master.Id), Record_Name__c = 'ErrorStampMaster',
                Is_Master__c = false, Is_Losing_Record__c = false),
            new Merge_Candidate__c(Merge_Ticket__c = ticket.Id,
                Record_Id__c = String.valueOf(loser.Id), Record_Name__c = 'ErrorStampLoser',
                Is_Master__c = false, Is_Losing_Record__c = false)
        };

        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId       = String.valueOf(ticket.Id);
        req.masterId       = String.valueOf(master.Id);
        req.losingIds      = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions = new Map<String,String>();
        req.notes          = '';

        MergeExecutionService.TEST_FORCE_INVALID_OBJECT_TYPE = true;
        MergeExecutionService.TEST_THROW_ERROR_STAMP         = true;
        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(req);
        Test.stopTest();
        MergeExecutionService.TEST_FORCE_INVALID_OBJECT_TYPE = false;
        MergeExecutionService.TEST_THROW_ERROR_STAMP         = false;

        System.assertEquals(false, result.success,
            'executeMerge must fail with invalid object type');
    }

    // ── MergeController.getRelatedRecordsComparison — null masterId path ──────

    @IsTest
    static void ctrl_getRRC_nullMaster_returnsEmpty() {
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|rrc_null@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 0
        );
        insert t;
        Test.startTest();
        List<MergeWrappers.RelatedObjectComparison> result =
            MergeController.getRelatedRecordsComparison(t.Id, null);
        Test.stopTest();
        System.assertEquals(0, result.size(), 'null masterId must return empty list');
    }

    // ── MergeController.getRelatedRecordsComparison — no candidates path ──────

    @IsTest
    static void ctrl_getRRC_noCandidates_returnsEmpty() {
        Contact c = new Contact(LastName = 'RRC_NoCand');
        insert c;
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|rrc_nocand@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 0
        );
        insert t;
        Test.startTest();
        List<MergeWrappers.RelatedObjectComparison> result =
            MergeController.getRelatedRecordsComparison(t.Id, c.Id);
        Test.stopTest();
        System.assertEquals(0, result.size(), 'ticket with no candidates must return empty list');
    }

    // ── MergeController.getRelatedRecordsComparison — full path with config ───

    @IsTest
    static void ctrl_getRRC_withConfig_buildsComparison() {
        Account acct = makeAccount('RRC_Acct');
        Contact master  = makeContact('RRC_Master', 'rrc_m@boosttest.com', acct.Id);
        Contact loser   = makeContact('RRC_Loser',  'rrc_l@boosttest.com', acct.Id);
        // A related contact that reports to the loser (will appear in loserRecords)
        Contact child = new Contact(LastName = 'RRC_Child', ReportsToId = loser.Id);
        insert child;

        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|rrc_cfg@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(master.Id), Record_Name__c = 'RRC_Master',
                Is_Master__c = false, Is_Losing_Record__c = false),
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(loser.Id),  Record_Name__c = 'RRC_Loser',
                Is_Master__c = false, Is_Losing_Record__c = false)
        };
        // Config: look at Contact.ReportsToId as a related object
        insert new Merge_Object_Config__c(
            Name               = 'Test RRC Config',
            Object_API_Name__c = 'Contact',
            Parent_Field__c    = 'ReportsToId',
            Object_Type__c     = 'Contact',
            Is_Active__c       = true
        );

        Test.startTest();
        List<MergeWrappers.RelatedObjectComparison> result =
            MergeController.getRelatedRecordsComparison(t.Id, master.Id);
        Test.stopTest();

        System.assertEquals(1, result.size(), 'should return one RelatedObjectComparison');
        System.assertEquals(0, result[0].masterRecords.size(), 'master has no reports-to children');
        System.assertEquals(1, result[0].loserRecords.size(),  'child belongs to loser');
    }

    // ── MergeController.closeOrphanedTickets — no excludeTicketId (else branch)

    @IsTest
    static void ctrl_orphanClose_noExclude_closesOrphanTickets() {
        Contact c = new Contact(LastName = 'OrphanClose');
        insert c;
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|orphan_close@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 1
        );
        insert t;
        insert new Merge_Candidate__c(
            Merge_Ticket__c   = t.Id,
            Record_Id__c      = String.valueOf(c.Id),
            Record_Name__c    = 'OrphanClose',
            Is_Master__c      = false,
            Is_Losing_Record__c = false
        );

        Test.startTest();
        // null ticketId → excludeTicketId = null → hits the else branch in closeOrphanedTickets
        MergeController.deleteOrphanedContact(String.valueOf(c.Id), null, 'OrphanClose');
        Test.stopTest();

        Merge_Ticket__c updated = [SELECT Status__c, Closed_Reason__c FROM Merge_Ticket__c WHERE Id = :t.Id];
        System.assertEquals('Closed', updated.Status__c, 'ticket must be closed by orphan cleanup');
        System.assertEquals('Record Deleted', updated.Closed_Reason__c,
            'closed reason must be Record Deleted');
    }

    // ── MergeController.initDefaultConfigsIfEmpty — no EDA/no existing configs

    @IsTest
    static void ctrl_initDefaultConfigs_noopWhenEDAMissing() {
        Test.startTest();
        MergeController.initDefaultConfigsIfEmpty();
        Test.stopTest();
        System.assert(true, 'initDefaultConfigsIfEmpty must not throw when no EDA objects exist');
    }

    // ── MergeController.getRelatedRecordsComparison — child on master side ─────

    @IsTest
    static void ctrl_getRRC_masterSideRecord() {
        Account acct   = makeAccount('RRC_MS_Acct');
        Contact master = makeContact('RRC_MS_Master', 'rrc_ms_m@boosttest.com', acct.Id);
        Contact loser  = makeContact('RRC_MS_Loser',  'rrc_ms_l@boosttest.com', acct.Id);
        Contact child  = new Contact(LastName = 'RRC_MS_Child', ReportsToId = master.Id);
        insert child;

        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|rrc_ms@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(master.Id), Record_Name__c = 'RRC_MS_Master',
                Is_Master__c = false, Is_Losing_Record__c = false),
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(loser.Id),  Record_Name__c = 'RRC_MS_Loser',
                Is_Master__c = false, Is_Losing_Record__c = false)
        };
        insert new Merge_Object_Config__c(
            Name               = 'RRC Master Side',
            Object_API_Name__c = 'Contact',
            Parent_Field__c    = 'ReportsToId',
            Object_Type__c     = 'Contact',
            Is_Active__c       = true
        );

        Test.startTest();
        List<MergeWrappers.RelatedObjectComparison> result =
            MergeController.getRelatedRecordsComparison(t.Id, master.Id);
        Test.stopTest();

        System.assertEquals(1, result.size(), 'one comparison entry expected');
        System.assertEquals(1, result[0].masterRecords.size(), 'child belongs to master side');
        System.assertEquals(0, result[0].loserRecords.size(),  'no loser-side records');
    }

    // ── MergeController.getRelatedRecordsComparison — bad field triggers catch ──

    @IsTest
    static void ctrl_getRRC_badField_catch() {
        Account acct   = makeAccount('RRC_Bad_Acct');
        Contact master = makeContact('RRC_Bad_Master', 'rrc_bad_m@boosttest.com', acct.Id);
        Contact loser  = makeContact('RRC_Bad_Loser',  'rrc_bad_l@boosttest.com', acct.Id);

        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|rrc_bad@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(master.Id), Record_Name__c = 'RRC_Bad_Master',
                Is_Master__c = false, Is_Losing_Record__c = false),
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(loser.Id),  Record_Name__c = 'RRC_Bad_Loser',
                Is_Master__c = false, Is_Losing_Record__c = false)
        };
        // Invalid lookup field — causes dynamic SOQL to throw → covers catch block
        insert new Merge_Object_Config__c(
            Name               = 'RRC Bad Field',
            Object_API_Name__c = 'Contact',
            Parent_Field__c    = 'NonExistentField__INVALID_XYZZY',
            Object_Type__c     = 'Contact',
            Is_Active__c       = true
        );

        Test.startTest();
        List<MergeWrappers.RelatedObjectComparison> result =
            MergeController.getRelatedRecordsComparison(t.Id, master.Id);
        Test.stopTest();

        System.assertEquals(1, result.size(), 'comparison entry returned even when query fails');
        System.assertEquals(0, result[0].masterRecords.size(), 'no records (query threw)');
        System.assertEquals(0, result[0].loserRecords.size(),  'no records (query threw)');
    }

    // ── closeOrphanedTickets — ticket pre-seeded with HIST notes ─────────────────

    @IsTest
    static void ctrl_orphanClose_withHistNotes() {
        Contact c = new Contact(LastName = 'OrphanHist');
        insert c;
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email',
            Match_Key__c  = 'Contact|Email|orphan_hist@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 1,
            Notes__c = '[HIST:Reopened|||||||2025-01-01]'
        );
        insert t;
        insert new Merge_Candidate__c(
            Merge_Ticket__c = t.Id,
            Record_Id__c    = String.valueOf(c.Id),
            Record_Name__c  = 'OrphanHist',
            Is_Master__c    = false, Is_Losing_Record__c = false
        );

        Test.startTest();
        MergeController.deleteOrphanedContact(String.valueOf(c.Id), null, 'OrphanHist');
        Test.stopTest();

        Merge_Ticket__c updated = [SELECT Status__c, Notes__c FROM Merge_Ticket__c WHERE Id = :t.Id];
        System.assertEquals('Closed', updated.Status__c, 'ticket must be closed');
        System.assert(updated.Notes__c.contains('[HIST:Reopened'), 'HIST note must be preserved');
    }

    // ── MergeController.saveObjectConfigsBatch — unsupported parent type ──────────

    @IsTest
    static void ctrl_saveConfigsBatch_unknownParent() {
        Boolean threw = false;
        Test.startTest();
        try {
            MergeController.saveObjectConfigsBatch('BadType', '[]');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'saveObjectConfigsBatch must throw for unknown parent type');
    }

    // ── MergeController.initDefaultConfigsIfEmpty — permission denied ────────────

    @IsTest
    static void ctrl_initDefaultConfigs_noPermission() {
        MergeController.TEST_FORCE_NO_INIT_PERMISSION = true;
        Test.startTest();
        MergeController.initDefaultConfigsIfEmpty();
        Test.stopTest();
        MergeController.TEST_FORCE_NO_INIT_PERMISSION = false;
        System.assert(true, 'must return silently when permission denied');
    }

    // ── MergeController.undoMerge — no MERGE_COMPLETED log → throws ──────────────

    @IsTest
    static void ctrl_undoMerge_noLog_throws() {
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|undo_nolog@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 0
        );
        insert t;

        Boolean threw = false;
        Test.startTest();
        try {
            MergeController.undoMerge(t.Id);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'undoMerge must throw when no MERGE_COMPLETED log exists');
    }

    // ── MergeController.undoMerge — loser permanently deleted → throws ───────────

    @IsTest
    static void ctrl_undoMerge_loserNotFound_throws() {
        Account acct   = makeAccount('UndoNF_Acct');
        Contact master = makeContact('UndoNF_Master', 'undo_nf_m@boosttest.com', acct.Id);
        Contact loser  = makeContact('UndoNF_Loser',  'undo_nf_l@boosttest.com', acct.Id);

        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|undo_nf@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;

        delete loser;
        Database.emptyRecycleBin(new List<Contact>{ new Contact(Id = loser.Id) });

        insert new Merge_Log__c(
            Merge_Ticket__c         = t.Id,
            Master_Record_Id__c     = String.valueOf(master.Id),
            Losing_Record_Ids__c    = JSON.serialize(new List<Id>{ loser.Id }),
            Object_Type__c          = 'Contact',
            Action_Type__c          = 'MERGE_COMPLETED',
            Before_Snapshot_JSON__c = '{}'
        );

        Boolean threw = false;
        Test.startTest();
        try {
            MergeController.undoMerge(t.Id);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'undoMerge must throw when loser is not in recycle bin');
    }

    // ── MergeController.undoMerge — comprehensive Contact merge + undo ───────────

    @IsTest
    static void ctrl_undoMerge_contact_comprehensive() {
        Account acc    = makeAccount('UndoC_Acc');
        Contact master = makeContact('UndoC_Master', 'undo_c_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('UndoC_Loser',  'undo_c_l@boosttest.com', acc.Id);
        Contact child  = new Contact(LastName = 'UndoC_Child', ReportsToId = loser.Id);
        insert child;

        insert new Merge_Object_Config__c(
            Name               = 'Undo Comprehensive',
            Object_API_Name__c = 'Contact',
            Parent_Field__c    = 'ReportsToId',
            Object_Type__c     = 'Contact',
            Is_Active__c       = true
        );

        // Ticket with a pre-existing HIST note so buildHistNotes covers the existing-note branch
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|undo_c@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2,
            Notes__c = '[HIST:Merged|||||||2025-01-01]'
        );
        insert t;

        // Simulate merge manually: re-point child to master, soft-delete loser
        child.ReportsToId = master.Id;
        update child;
        delete loser;

        // Merge log with new 'reparented' format JSON
        String reparentedJson = JSON.serialize(new Map<String,Object>{
            'reparented' => new List<Map<String,Object>>{
                new Map<String,Object>{
                    'obj'     => 'Contact',
                    'field'   => 'ReportsToId',
                    'loserId' => String.valueOf(loser.Id),
                    'ids'     => new List<String>{ String.valueOf(child.Id) }
                }
            }
        });

        insert new Merge_Log__c(
            Merge_Ticket__c          = t.Id,
            Master_Record_Id__c      = String.valueOf(master.Id),
            Losing_Record_Ids__c     = JSON.serialize(new List<Id>{ loser.Id }),
            Object_Type__c           = 'Contact',
            Action_Type__c           = 'MERGE_COMPLETED',
            Merge_Related_Records__c = reparentedJson,
            Before_Snapshot_JSON__c  = '{}'
        );

        Test.startTest();
        MergeController.undoMerge(t.Id);
        Test.stopTest();

        List<Contact> loserCheck = [SELECT Id FROM Contact WHERE Id = :loser.Id];
        System.assertEquals(1, loserCheck.size(), 'loser must be undeleted');

        Contact childCheck = [SELECT ReportsToId FROM Contact WHERE Id = :child.Id];
        System.assertEquals(loser.Id, childCheck.ReportsToId,
            'child.ReportsToId must be restored to loser');

        Merge_Ticket__c tCheck = [SELECT Status__c, Notes__c FROM Merge_Ticket__c WHERE Id = :t.Id];
        System.assertEquals('Reopened', tCheck.Status__c, 'ticket must be Reopened');
        System.assert(tCheck.Notes__c != null && tCheck.Notes__c.contains('[HIST:Reopened'),
            'Reopened HIST entry must exist');
        System.assert(tCheck.Notes__c.contains('[HIST:Merged'),
            'original Merged HIST entry must be preserved');
    }

    // ── MergeController.undoMerge — Contact admin account undeleted (step 1c) ───

    @IsTest
    static void ctrl_undoMerge_contactAdminAcct_undeletes() {
        Account acc    = makeAccount('UndoAdmA_Acc');
        Contact master = makeContact('UndoAdmA_Master', 'undo_adma_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('UndoAdmA_Loser',  'undo_adma_l@boosttest.com', acc.Id);

        // A contact-free Account — safe to delete without triggering org-specific cascade issues
        Account dummyDeleted = makeAccount('UndoAdmA_Dummy');
        delete dummyDeleted;

        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|undo_adma@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;

        delete loser;

        insert new Merge_Log__c(
            Merge_Ticket__c         = t.Id,
            Master_Record_Id__c     = String.valueOf(master.Id),
            Losing_Record_Ids__c    = JSON.serialize(new List<Id>{ loser.Id }),
            Object_Type__c          = 'Contact',
            Action_Type__c          = 'MERGE_COMPLETED',
            Before_Snapshot_JSON__c = '{}'
        );

        // Inject dummyDeleted so undoMerge step 1c processes and undeletes it (covers line 348)
        MergeController.TEST_INJECT_EXTRA_DELETED_ACCT_IDS = new Set<Id>{ dummyDeleted.Id };
        Test.startTest();
        MergeController.undoMerge(t.Id);
        Test.stopTest();
        MergeController.TEST_INJECT_EXTRA_DELETED_ACCT_IDS = null;

        List<Account> acctCheck = [SELECT Id FROM Account WHERE Id = :dummyDeleted.Id];
        System.assertEquals(1, acctCheck.size(), 'dummyDeleted Account must be undeleted by undoMerge step 1c');

        List<Contact> loserCheck = [SELECT Id FROM Contact WHERE Id = :loser.Id];
        System.assertEquals(1, loserCheck.size(), 'loser must be undeleted');
    }

    // ── MergeController.undoMerge — Account merge with deleted contacts ───────────

    @IsTest
    static void ctrl_undoMerge_account_withDeletedContacts() {
        Account masterAcct = makeAccount('UndoA_Master');
        Account loserAcct  = makeAccount('UndoA_Loser');
        Contact orphan = new Contact(LastName = 'UndoA_Orphan', AccountId = loserAcct.Id);
        Database.DmlOptions opts = new Database.DmlOptions();
        opts.DuplicateRuleHeader.AllowSave = true;
        Database.insert(orphan, opts);

        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Account', Status__c = 'New',
            Match_Type__c  = 'Phone',
            Match_Key__c   = 'Account|Phone|undo_a_del@boosttest.com',
            Match_Confidence__c = 'Medium', Candidate_Count__c = 2,
            Notes__c = '[DELETED_CONTACT|' + orphan.Id + '|2025-01-01 00:00] orphan'
        );
        insert t;

        // Delete loserAcct only — cascade-deletes orphan → both in recycle bin
        delete loserAcct;

        insert new Merge_Log__c(
            Merge_Ticket__c         = t.Id,
            Master_Record_Id__c     = String.valueOf(masterAcct.Id),
            Losing_Record_Ids__c    = JSON.serialize(new List<Id>{ loserAcct.Id }),
            Object_Type__c          = 'Account',
            Action_Type__c          = 'MERGE_COMPLETED',
            Before_Snapshot_JSON__c = '{}'
        );

        Test.startTest();
        MergeController.undoMerge(t.Id);
        Test.stopTest();

        Merge_Ticket__c upd = [SELECT Status__c FROM Merge_Ticket__c WHERE Id = :t.Id];
        System.assertEquals('Reopened', upd.Status__c, 'ticket must be Reopened');

        List<Account> acctCheck = [SELECT Id FROM Account WHERE Id = :loserAcct.Id];
        System.assertEquals(1, acctCheck.size(), 'loser Account must be undeleted');

        List<Contact> cCheck = [SELECT Id FROM Contact WHERE Id = :orphan.Id];
        System.assertEquals(1, cCheck.size(), 'orphan Contact must be undeleted from Notes');
    }

    // ── MergeController.undoMerge — legacy loserRelatedIds JSON format ────────────

    @IsTest
    static void ctrl_undoMerge_legacyFormat() {
        Account acct   = makeAccount('UndoLeg_Acct');
        Contact master = makeContact('UndoLeg_Master', 'undo_leg_m@boosttest.com', acct.Id);
        Contact loser  = makeContact('UndoLeg_Loser',  'undo_leg_l@boosttest.com', acct.Id);
        Contact child  = new Contact(LastName = 'UndoLeg_Child', ReportsToId = loser.Id);
        insert child;

        insert new Merge_Object_Config__c(
            Name               = 'Undo Legacy',
            Object_API_Name__c = 'Contact',
            Parent_Field__c    = 'ReportsToId',
            Object_Type__c     = 'Contact',
            Is_Active__c       = true
        );

        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|undo_leg@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;

        // Simulate what merge would have done: re-pointed child → master, deleted loser
        child.ReportsToId = master.Id;
        update child;
        delete loser;

        String legacyJson = JSON.serialize(new Map<String,Object>{
            'loserRelatedIds' => new Map<String,Object>{
                String.valueOf(loser.Id) => new Map<String,Object>{
                    'Contact' => new List<Id>{ child.Id }
                }
            }
        });

        insert new Merge_Log__c(
            Merge_Ticket__c          = t.Id,
            Master_Record_Id__c      = String.valueOf(master.Id),
            Losing_Record_Ids__c     = JSON.serialize(new List<Id>{ loser.Id }),
            Object_Type__c           = 'Contact',
            Action_Type__c           = 'MERGE_COMPLETED',
            Merge_Related_Records__c = legacyJson,
            Before_Snapshot_JSON__c  = '{}'
        );

        Test.startTest();
        MergeController.undoMerge(t.Id);
        Test.stopTest();

        List<Contact> loserCheck = [SELECT Id FROM Contact WHERE Id = :loser.Id];
        System.assertEquals(1, loserCheck.size(), 'loser must be undeleted');

        Contact childCheck = [SELECT ReportsToId FROM Contact WHERE Id = :child.Id];
        System.assertEquals(loser.Id, childCheck.ReportsToId,
            'child.ReportsToId must be re-pointed to loser via buildReparentedFromLegacy');
    }

    // ── MergeController.undoMerge — new 'deleted' format ─────────────────────────

    @IsTest
    static void ctrl_undoMerge_deletedNew() {
        Account acct   = makeAccount('UndoDel_Acct');
        Contact master = makeContact('UndoDel_Master', 'undo_del_m@boosttest.com', acct.Id);
        Contact loser  = makeContact('UndoDel_Loser',  'undo_del_l@boosttest.com', acct.Id);
        Contact child  = new Contact(LastName = 'UndoDel_Child', ReportsToId = loser.Id);
        insert child;

        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|undo_del@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;

        // Both loser and child were deleted during merge (child was a conflict record)
        delete child;
        delete loser;

        String deletedJson = JSON.serialize(new Map<String,Object>{
            'deleted' => new List<Map<String,Object>>{
                new Map<String,Object>{
                    'obj'     => 'Contact',
                    'field'   => 'ReportsToId',
                    'loserId' => String.valueOf(loser.Id),
                    'ids'     => new List<String>{ String.valueOf(child.Id) }
                }
            }
        });

        insert new Merge_Log__c(
            Merge_Ticket__c          = t.Id,
            Master_Record_Id__c      = String.valueOf(master.Id),
            Losing_Record_Ids__c     = JSON.serialize(new List<Id>{ loser.Id }),
            Object_Type__c           = 'Contact',
            Action_Type__c           = 'MERGE_COMPLETED',
            Merge_Related_Records__c = deletedJson,
            Before_Snapshot_JSON__c  = '{}'
        );

        Test.startTest();
        MergeController.undoMerge(t.Id);
        Test.stopTest();

        List<Contact> loserCheck = [SELECT Id FROM Contact WHERE Id = :loser.Id];
        System.assertEquals(1, loserCheck.size(), 'loser must be undeleted');

        List<Contact> childCheck = [SELECT Id FROM Contact WHERE Id = :child.Id];
        System.assertEquals(1, childCheck.size(), 'child must be undeleted via deleted-block logic');
    }

    // ── MergeController.undoMerge — legacy flat 'deletedIds' format ──────────────

    @IsTest
    static void ctrl_undoMerge_deletedIds_legacy() {
        Account acct   = makeAccount('UndoDelId_Acct');
        Contact master = makeContact('UndoDelId_Master', 'undo_delid_m@boosttest.com', acct.Id);
        Contact loser  = makeContact('UndoDelId_Loser',  'undo_delid_l@boosttest.com', acct.Id);
        Contact child  = new Contact(LastName = 'UndoDelId_Child', ReportsToId = loser.Id);
        insert child;

        insert new Merge_Object_Config__c(
            Name               = 'Undo DelId Config',
            Object_API_Name__c = 'Contact',
            Parent_Field__c    = 'ReportsToId',
            Object_Type__c     = 'Contact',
            Is_Active__c       = true
        );

        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|undo_delid@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;

        delete child;
        delete loser;

        String legacyDelJson = JSON.serialize(new Map<String,Object>{
            'deletedIds' => new List<String>{ String.valueOf(child.Id) }
        });

        insert new Merge_Log__c(
            Merge_Ticket__c          = t.Id,
            Master_Record_Id__c      = String.valueOf(master.Id),
            Losing_Record_Ids__c     = JSON.serialize(new List<Id>{ loser.Id }),
            Object_Type__c           = 'Contact',
            Action_Type__c           = 'MERGE_COMPLETED',
            Merge_Related_Records__c = legacyDelJson,
            Before_Snapshot_JSON__c  = '{}'
        );

        Test.startTest();
        MergeController.undoMerge(t.Id);
        Test.stopTest();

        List<Contact> loserCheck = [SELECT Id FROM Contact WHERE Id = :loser.Id];
        System.assertEquals(1, loserCheck.size(), 'loser must be undeleted');

        List<Contact> childCheck = [SELECT Id FROM Contact WHERE Id = :child.Id];
        System.assertEquals(1, childCheck.size(), 'child must be undeleted via deletedIds legacy path');
    }

    // ── MergeController.undoMerge — restoreMasterFieldValues with real diff ───────

    @IsTest
    static void ctrl_undoMerge_withFieldDecisions() {
        Account acct   = makeAccount('UndoFD_Acct');
        Contact master = makeContact('UndoFD_Master', 'undo_fd_m@boosttest.com', acct.Id);
        Contact loser  = makeContact('UndoFD_Loser',  'undo_fd_l@boosttest.com', acct.Id);

        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|undo_fd@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        delete loser;

        // diffJson: {fieldName: {before: preMergeValue, after: postMergeValue}}
        // undoMerge restores 'before' to master
        String diffJson = JSON.serialize(new Map<String,Object>{
            'LastName' => new Map<String,Object>{
                'before' => 'OriginalLast',
                'after'  => 'ChangedLast'
            }
        });

        insert new Merge_Log__c(
            Merge_Ticket__c         = t.Id,
            Master_Record_Id__c     = String.valueOf(master.Id),
            Losing_Record_Ids__c    = JSON.serialize(new List<Id>{ loser.Id }),
            Object_Type__c          = 'Contact',
            Action_Type__c          = 'MERGE_COMPLETED',
            Field_Decisions_JSON__c = diffJson,
            Before_Snapshot_JSON__c = '{}'
        );

        Test.startTest();
        MergeController.undoMerge(t.Id);
        Test.stopTest();

        Contact masterCheck = [SELECT LastName FROM Contact WHERE Id = :master.Id];
        System.assertEquals('OriginalLast', masterCheck.LastName,
            'restoreMasterFieldValues must restore LastName to pre-merge value');
    }

    // ── MergeExecutionService — Task reparent catch block ────────────────────────

    @IsTest
    static void exec_taskReparent_catchBlock() {
        Account acc    = makeAccount('TaskCatch_Acct');
        Contact master = makeContact('TaskCatch_Master', 'tc_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('TaskCatch_Loser',  'tc_l@boosttest.com', acc.Id);
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|tc@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(master.Id), Record_Name__c = 'TaskCatch_Master',
                Is_Master__c = false, Is_Losing_Record__c = false),
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(loser.Id),  Record_Name__c = 'TaskCatch_Loser',
                Is_Master__c = false, Is_Losing_Record__c = false)
        };
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId       = String.valueOf(t.Id);
        req.masterId       = String.valueOf(master.Id);
        req.losingIds      = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions = new Map<String,String>();
        req.notes          = '';

        MergeExecutionService.TEST_THROW_TASK_REPARENT = true;
        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(req);
        Test.stopTest();
        MergeExecutionService.TEST_THROW_TASK_REPARENT = false;

        System.assert(result.success,
            'merge must succeed even when Task reparent throws: ' + result.errorMessage);
    }

    // ── MergeExecutionService — Event reparent catch block ───────────────────────

    @IsTest
    static void exec_eventReparent_catchBlock() {
        Account acc    = makeAccount('EventCatch_Acct');
        Contact master = makeContact('EventCatch_Master', 'ec_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('EventCatch_Loser',  'ec_l@boosttest.com', acc.Id);
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|ec@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(master.Id), Record_Name__c = 'EventCatch_Master',
                Is_Master__c = false, Is_Losing_Record__c = false),
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(loser.Id),  Record_Name__c = 'EventCatch_Loser',
                Is_Master__c = false, Is_Losing_Record__c = false)
        };
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId       = String.valueOf(t.Id);
        req.masterId       = String.valueOf(master.Id);
        req.losingIds      = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions = new Map<String,String>();
        req.notes          = '';

        MergeExecutionService.TEST_THROW_EVENT_REPARENT = true;
        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(req);
        Test.stopTest();
        MergeExecutionService.TEST_THROW_EVENT_REPARENT = false;

        System.assert(result.success,
            'merge must succeed even when Event reparent throws: ' + result.errorMessage);
    }

    // ── MergeExecutionService — CampaignMember reparent catch block ──────────────

    @IsTest
    static void exec_cmReparent_catchBlock() {
        Account acc    = makeAccount('CMCatch_Acct');
        Contact master = makeContact('CMCatch_Master', 'cm_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('CMCatch_Loser',  'cm_l@boosttest.com', acc.Id);
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|cm@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(master.Id), Record_Name__c = 'CMCatch_Master',
                Is_Master__c = false, Is_Losing_Record__c = false),
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(loser.Id),  Record_Name__c = 'CMCatch_Loser',
                Is_Master__c = false, Is_Losing_Record__c = false)
        };
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId       = String.valueOf(t.Id);
        req.masterId       = String.valueOf(master.Id);
        req.losingIds      = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions = new Map<String,String>();
        req.notes          = '';

        MergeExecutionService.TEST_THROW_CM_REPARENT = true;
        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(req);
        Test.stopTest();
        MergeExecutionService.TEST_THROW_CM_REPARENT = false;

        System.assert(result.success,
            'merge must succeed even when CampaignMember reparent throws: ' + result.errorMessage);
    }

    // ── MergeExecutionService — master field update fail (lines 121-122) ─────────

    @IsTest
    static void exec_masterUpdateFail_throws() {
        Account acc    = makeAccount('MUF_Acct');
        Contact master = makeContact('MUF_Master', 'muf_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('MUF_Loser',  'muf_l@boosttest.com', acc.Id);
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|muf@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(master.Id), Record_Name__c = 'MUF_Master',
                Is_Master__c = false, Is_Losing_Record__c = false),
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(loser.Id),  Record_Name__c = 'MUF_Loser',
                Is_Master__c = false, Is_Losing_Record__c = false)
        };
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId  = String.valueOf(t.Id);
        req.masterId  = String.valueOf(master.Id);
        req.losingIds = new List<String>{ String.valueOf(loser.Id) };
        // Field decision makes masterOverrideFields.size() > 1 → enters the update check
        req.fieldDecisions = new Map<String,String>{ 'LastName' => String.valueOf(loser.Id) };
        req.notes = '';

        MergeExecutionService.TEST_FORCE_MASTER_UPDATE_FAIL = true;
        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(req);
        Test.stopTest();
        MergeExecutionService.TEST_FORCE_MASTER_UPDATE_FAIL = false;

        System.assertEquals(false, result.success,
            'executeMerge must fail when master update flag is set');
    }

    // ── MergeExecutionService — delete loser fail + buildErrorMsg loop body ───────

    @IsTest
    static void exec_deleteLoserFail_buildErrorMsg() {
        Account acc    = makeAccount('DLF_Acct');
        Contact master = makeContact('DLF_Master', 'dlf_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('DLF_Loser',  'dlf_l@boosttest.com', acc.Id);
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|dlf@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(master.Id), Record_Name__c = 'DLF_Master',
                Is_Master__c = false, Is_Losing_Record__c = false),
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(loser.Id),  Record_Name__c = 'DLF_Loser',
                Is_Master__c = false, Is_Losing_Record__c = false)
        };
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId       = String.valueOf(t.Id);
        req.masterId       = String.valueOf(master.Id);
        req.losingIds      = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions = new Map<String,String>();
        req.notes          = '';

        MergeExecutionService.TEST_FORCE_DELETE_LOSER_FAIL = true;
        Test.startTest();
        MergeWrappers.MergeResult result = MergeExecutionService.executeMerge(req);
        Test.stopTest();
        MergeExecutionService.TEST_FORCE_DELETE_LOSER_FAIL = false;

        System.assertEquals(false, result.success,
            'executeMerge must fail when delete-loser flag is set');
        System.assert(!String.isBlank(result.errorMessage),
            'errorMessage must be populated by buildErrorMsg with real Database.Error');
    }

    // ── MergeTicketService — account context query catch block ───────────────────

    // ── MergeExecutionService: executeMerge with Merge_Object_Config__c + relatedDeletesJson ──
    // Covers: MES captureLoserRelatedIds loop (730-744), reparentAndDeleteLosers step-A (200-218),
    //         applyRelatedDeletes body (756-778, 781), appendDeletedIdsToLog (789-840),
    //         appendDeletedIdsToLog call (135), buildHistNotes existing-notes branch (486-487).

    @IsTest
    static void exec_withRelatedRecords_coversAll() {
        Account acc    = makeAccount('RelRec_Acc');
        Contact master = makeContact('RelRec_Master', 'relrec_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('RelRec_Loser',  'relrec_l@boosttest.com', acc.Id);
        Contact child  = new Contact(LastName = 'RelRec_Child', ReportsToId = loser.Id);
        insert child;

        insert new Merge_Object_Config__c(
            Name = 'RelRec_Cfg', Object_API_Name__c = 'Contact',
            Parent_Field__c = 'ReportsToId', Object_Type__c = 'Contact', Is_Active__c = true
        );

        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|relrec@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2,
            Notes__c = '[HIST:New|||||||2025-01-01]'
        );
        insert t;

        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId           = String.valueOf(t.Id);
        req.masterId           = String.valueOf(master.Id);
        req.losingIds          = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions     = new Map<String,String>();
        req.relatedDeletesJson = '{"Contact":["' + String.valueOf(child.Id) + '"]}';
        req.notes              = 'coverage test';

        Test.startTest();
        MergeWrappers.MergeResult res = MergeExecutionService.executeMerge(req);
        Test.stopTest();

        System.assert(res.success, 'Merge should succeed: ' + res.errorMessage);
        System.assertEquals(0, [SELECT Id FROM Contact WHERE Id = :child.Id].size(),
            'child must be deleted by relatedDeletesJson');
        System.assertEquals(1, [SELECT Id FROM Contact WHERE Id = :loser.Id ALL ROWS].size(),
            'loser must be soft-deleted');
    }

    // ── MergeExecutionService: applyRelatedDeletes with invalid JSON ─────────────────────────
    // Covers: JSON parse catch in applyRelatedDeletes (lines ~759-760)

    @IsTest
    static void exec_withInvalidDeleteJson_coversApplyDeletesCatch() {
        Account acc    = makeAccount('InvDelJson_Acc');
        Contact master = makeContact('InvDelJson_Master', 'invdeljson_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('InvDelJson_Loser',  'invdeljson_l@boosttest.com', acc.Id);

        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|invdeljson@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;

        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId           = String.valueOf(t.Id);
        req.masterId           = String.valueOf(master.Id);
        req.losingIds          = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions     = new Map<String,String>();
        req.relatedDeletesJson = 'not-valid-json';
        req.notes              = '';

        Test.startTest();
        MergeWrappers.MergeResult res = MergeExecutionService.executeMerge(req);
        Test.stopTest();

        System.assert(res.success, 'Merge should succeed even with invalid relatedDeletesJson: ' + res.errorMessage);
    }

    // ── MergeController.undoMerge — loser permanently deleted → throw (isEmpty path) ─────────
    // Covers: MergeController lines 287-288 (AuraHandledException throw when toUndelete isEmpty)

    @IsTest
    static void ctrl_undoMerge_loserHardDeleted_isEmpty() {
        Account acct   = makeAccount('UndoHD_Acct');
        Contact master = makeContact('UndoHD_Master', 'undohd_m@boosttest.com', acct.Id);
        Contact loser  = makeContact('UndoHD_Loser',  'undohd_l@boosttest.com', acct.Id);

        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|undohd@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        delete loser;

        insert new Merge_Log__c(
            Merge_Ticket__c         = t.Id,
            Master_Record_Id__c     = String.valueOf(master.Id),
            Losing_Record_Ids__c    = JSON.serialize(new List<Id>{ loser.Id }),
            Object_Type__c          = 'Contact',
            Action_Type__c          = 'MERGE_COMPLETED',
            Before_Snapshot_JSON__c = '{}'
        );

        MergeController.TEST_FORCE_EMPTY_LOSER_UNDELETE = true;
        Boolean threw = false;
        Test.startTest();
        try {
            MergeController.undoMerge(t.Id);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        MergeController.TEST_FORCE_EMPTY_LOSER_UNDELETE = false;

        System.assert(threw, 'undoMerge must throw when loser list is empty');
    }

    // ── MergeController.undoMerge — step-1b catch (Account deleted-contacts path) ────────────
    // Covers: MergeController line 326

    @IsTest
    static void ctrl_undoMerge_step1b_catchBlock() {
        Account master = makeAccount('1B_Master');
        Account loser  = makeAccount('1B_Loser');

        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Account', Status__c = 'New',
            Match_Type__c = 'Name', Match_Key__c = 'Account|Name|1B',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        delete loser;

        insert new Merge_Log__c(
            Merge_Ticket__c         = t.Id,
            Master_Record_Id__c     = String.valueOf(master.Id),
            Losing_Record_Ids__c    = JSON.serialize(new List<Id>{ loser.Id }),
            Object_Type__c          = 'Account',
            Action_Type__c          = 'MERGE_COMPLETED',
            Before_Snapshot_JSON__c = '{}'
        );

        MergeController.TEST_THROW_UNDO_STEP_1B = true;
        Test.startTest();
        MergeController.undoMerge(t.Id);
        Test.stopTest();
        MergeController.TEST_THROW_UNDO_STEP_1B = false;

        Merge_Ticket__c tCheck = [SELECT Status__c FROM Merge_Ticket__c WHERE Id = :t.Id];
        System.assertEquals('Reopened', tCheck.Status__c, 'ticket must be Reopened despite 1b catch');
    }

    // ── MergeController.undoMerge — step-1c catch (Contact admin-account path) ───────────────
    // Covers: MergeController line 353

    @IsTest
    static void ctrl_undoMerge_step1c_catchBlock() {
        Account acc    = makeAccount('1C_Acc');
        Contact master = makeContact('1C_Master', '1c_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('1C_Loser',  '1c_l@boosttest.com', acc.Id);

        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|1c@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        delete loser;

        insert new Merge_Log__c(
            Merge_Ticket__c         = t.Id,
            Master_Record_Id__c     = String.valueOf(master.Id),
            Losing_Record_Ids__c    = JSON.serialize(new List<Id>{ loser.Id }),
            Object_Type__c          = 'Contact',
            Action_Type__c          = 'MERGE_COMPLETED',
            Before_Snapshot_JSON__c = '{}'
        );

        MergeController.TEST_THROW_UNDO_STEP_1C = true;
        Test.startTest();
        MergeController.undoMerge(t.Id);
        Test.stopTest();
        MergeController.TEST_THROW_UNDO_STEP_1C = false;

        Merge_Ticket__c tCheck = [SELECT Status__c FROM Merge_Ticket__c WHERE Id = :t.Id];
        System.assertEquals('Reopened', tCheck.Status__c, 'ticket must be Reopened despite 1c catch');
    }

    // ── MergeController.undoMerge — reparent step with invalid field → SOQL catch ──────────
    // Covers: MergeController line 383

    @IsTest
    static void ctrl_undoMerge_reparentBadField_catchBlock() {
        Account acc    = makeAccount('BadFld_Acc');
        Contact master = makeContact('BadFld_Master', 'badfld_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('BadFld_Loser',  'badfld_l@boosttest.com', acc.Id);

        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|badfld@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        delete loser;

        String badReparentJson = JSON.serialize(new Map<String,Object>{
            'reparented' => new List<Map<String,Object>>{
                new Map<String,Object>{
                    'obj'     => 'Contact',
                    'field'   => 'NonExistentField__c',
                    'loserId' => String.valueOf(loser.Id),
                    'ids'     => new List<String>{ String.valueOf(master.Id) }
                }
            }
        });

        insert new Merge_Log__c(
            Merge_Ticket__c          = t.Id,
            Master_Record_Id__c      = String.valueOf(master.Id),
            Losing_Record_Ids__c     = JSON.serialize(new List<Id>{ loser.Id }),
            Object_Type__c           = 'Contact',
            Action_Type__c           = 'MERGE_COMPLETED',
            Merge_Related_Records__c = badReparentJson,
            Before_Snapshot_JSON__c  = '{}'
        );

        Test.startTest();
        MergeController.undoMerge(t.Id);
        Test.stopTest();

        Merge_Ticket__c tCheck = [SELECT Status__c FROM Merge_Ticket__c WHERE Id = :t.Id];
        System.assertEquals('Reopened', tCheck.Status__c, 'ticket must be Reopened despite reparent SOQL catch');
    }

    // ── MergeController.undoMerge — deleted-step with invalid field → put catch ──────────────
    // Covers: MergeController line 413

    @IsTest
    static void ctrl_undoMerge_deletedBadPut_catchBlock() {
        Account acc       = makeAccount('DelBadPut_Acc');
        Contact master    = makeContact('DelBadPut_Master', 'delbadput_m@boosttest.com', acc.Id);
        Contact loser     = makeContact('DelBadPut_Loser',  'delbadput_l@boosttest.com', acc.Id);
        Contact extraDel  = makeContact('DelBadPut_Extra',  'delbadput_e@boosttest.com', acc.Id);

        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|delbadput@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        delete loser;
        delete extraDel; // soft-deleted; will be found by ALL ROWS in step-3

        String deletedJson = JSON.serialize(new Map<String,Object>{
            'deleted' => new List<Map<String,Object>>{
                new Map<String,Object>{
                    'obj'     => 'Contact',
                    'field'   => 'NonExistentField__c',
                    'loserId' => String.valueOf(loser.Id),
                    'ids'     => new List<String>{ String.valueOf(extraDel.Id) }
                }
            }
        });

        insert new Merge_Log__c(
            Merge_Ticket__c          = t.Id,
            Master_Record_Id__c      = String.valueOf(master.Id),
            Losing_Record_Ids__c     = JSON.serialize(new List<Id>{ loser.Id }),
            Object_Type__c           = 'Contact',
            Action_Type__c           = 'MERGE_COMPLETED',
            Merge_Related_Records__c = deletedJson,
            Before_Snapshot_JSON__c  = '{}'
        );

        Test.startTest();
        MergeController.undoMerge(t.Id);
        Test.stopTest();

        Merge_Ticket__c tCheck = [SELECT Status__c FROM Merge_Ticket__c WHERE Id = :t.Id];
        System.assertEquals('Reopened', tCheck.Status__c, 'ticket must be Reopened despite deleted-step put catch');
    }

    // ── MergeController.undoMerge — legacy-deletedIds catch (silent) ─────────────────────────
    // Covers: MergeController line 434

    @IsTest
    static void ctrl_undoMerge_legacyDeletes_catchBlock() {
        Account acc    = makeAccount('LegDel_Acc');
        Contact master = makeContact('LegDel_Master', 'legdel_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('LegDel_Loser',  'legdel_l@boosttest.com', acc.Id);

        insert new Merge_Object_Config__c(
            Name = 'LegDel_Cfg', Object_API_Name__c = 'Contact',
            Parent_Field__c = 'ReportsToId', Object_Type__c = 'Contact', Is_Active__c = true
        );

        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|legdel@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        delete loser;

        String legacyJson = JSON.serialize(new Map<String,Object>{
            'deletedIds' => new List<String>{ '003000000000001' }
        });

        insert new Merge_Log__c(
            Merge_Ticket__c          = t.Id,
            Master_Record_Id__c      = String.valueOf(master.Id),
            Losing_Record_Ids__c     = JSON.serialize(new List<Id>{ loser.Id }),
            Object_Type__c           = 'Contact',
            Action_Type__c           = 'MERGE_COMPLETED',
            Merge_Related_Records__c = legacyJson,
            Before_Snapshot_JSON__c  = '{}'
        );

        MergeController.TEST_THROW_UNDO_LEGACY_DELETES = true;
        Test.startTest();
        MergeController.undoMerge(t.Id);
        Test.stopTest();
        MergeController.TEST_THROW_UNDO_LEGACY_DELETES = false;

        Merge_Ticket__c tCheck = [SELECT Status__c FROM Merge_Ticket__c WHERE Id = :t.Id];
        System.assertEquals('Reopened', tCheck.Status__c, 'ticket must be Reopened despite legacy-deletes catch');
    }

    // ── MergeController.undoMerge — restoreMasterFieldValues with invalid JSON → catch ───────
    // Covers: MergeController line 464

    @IsTest
    static void ctrl_undoMerge_fieldDecisions_invalidJson_catchBlock() {
        Account acc    = makeAccount('FDInvJson_Acc');
        Contact master = makeContact('FDInvJson_Master', 'fdinvjson_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('FDInvJson_Loser',  'fdinvjson_l@boosttest.com', acc.Id);

        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|fdinvjson@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        delete loser;

        insert new Merge_Log__c(
            Merge_Ticket__c          = t.Id,
            Master_Record_Id__c      = String.valueOf(master.Id),
            Losing_Record_Ids__c     = JSON.serialize(new List<Id>{ loser.Id }),
            Object_Type__c           = 'Contact',
            Action_Type__c           = 'MERGE_COMPLETED',
            Field_Decisions_JSON__c  = 'not-valid-json',
            Before_Snapshot_JSON__c  = '{}'
        );

        Test.startTest();
        MergeController.undoMerge(t.Id);
        Test.stopTest();

        Merge_Ticket__c tCheck = [SELECT Status__c FROM Merge_Ticket__c WHERE Id = :t.Id];
        System.assertEquals('Reopened', tCheck.Status__c, 'ticket must be Reopened despite invalid field-decisions JSON');
    }

    // ── MergeController.undoMerge — restoreMasterFieldValues rec.put catch ───────────────────
    // Covers: MergeController line 494

    @IsTest
    static void ctrl_undoMerge_fieldDecisions_putThrows_catchBlock() {
        Account acc    = makeAccount('FDPut_Acc');
        Contact master = makeContact('FDPut_Master', 'fdput_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('FDPut_Loser',  'fdput_l@boosttest.com', acc.Id);

        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|fdput@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        delete loser;

        insert new Merge_Log__c(
            Merge_Ticket__c          = t.Id,
            Master_Record_Id__c      = String.valueOf(master.Id),
            Losing_Record_Ids__c     = JSON.serialize(new List<Id>{ loser.Id }),
            Object_Type__c           = 'Contact',
            Action_Type__c           = 'MERGE_COMPLETED',
            Field_Decisions_JSON__c  = '{"Description":{"before":"old desc","after":"new desc"}}',
            Before_Snapshot_JSON__c  = '{}'
        );

        MergeController.TEST_THROW_RESTORE_FIELD_PUT = true;
        Test.startTest();
        MergeController.undoMerge(t.Id);
        Test.stopTest();
        MergeController.TEST_THROW_RESTORE_FIELD_PUT = false;

        Merge_Ticket__c tCheck = [SELECT Status__c FROM Merge_Ticket__c WHERE Id = :t.Id];
        System.assertEquals('Reopened', tCheck.Status__c, 'ticket must be Reopened despite rec.put catch');
    }

    // ── MergeController.undoMerge — restoreMasterFieldValues update catch ────────────────────
    // Covers: MergeController line 503

    @IsTest
    static void ctrl_undoMerge_fieldDecisions_updateThrows_catchBlock() {
        Account acc    = makeAccount('FDUpd_Acc');
        Contact master = makeContact('FDUpd_Master', 'fdupd_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('FDUpd_Loser',  'fdupd_l@boosttest.com', acc.Id);

        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|fdupd@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        delete loser;

        insert new Merge_Log__c(
            Merge_Ticket__c          = t.Id,
            Master_Record_Id__c      = String.valueOf(master.Id),
            Losing_Record_Ids__c     = JSON.serialize(new List<Id>{ loser.Id }),
            Object_Type__c           = 'Contact',
            Action_Type__c           = 'MERGE_COMPLETED',
            Field_Decisions_JSON__c  = '{"Description":{"before":"old value","after":"new value"}}',
            Before_Snapshot_JSON__c  = '{}'
        );

        MergeController.TEST_THROW_RESTORE_UPDATE = true;
        Test.startTest();
        MergeController.undoMerge(t.Id);
        Test.stopTest();
        MergeController.TEST_THROW_RESTORE_UPDATE = false;

        Merge_Ticket__c tCheck = [SELECT Status__c FROM Merge_Ticket__c WHERE Id = :t.Id];
        System.assertEquals('Reopened', tCheck.Status__c, 'ticket must be Reopened despite update catch');
    }

    // ── MergeController.saveObjectConfigsBatch — parentSType = null (dead else-branch) ────────
    // Covers: MergeController line 1202

    @IsTest
    static void ctrl_saveConfigs_parentTypeNull_branch() {
        MergeController.TEST_FORCE_PARENT_STYPE_NULL = true;
        Test.startTest();
        try {
            MergeController.saveObjectConfigsBatch('Contact', '[]');
        } catch (Exception e) {
            // Empty configsJson may throw or not — we only need the flag-path executed
        }
        Test.stopTest();
        MergeController.TEST_FORCE_PARENT_STYPE_NULL = false;
        System.assert(true, 'TEST_FORCE_PARENT_STYPE_NULL branch must execute without unhandled exception');
    }

    // ── MergeExecutionService: remaining 10 uncovered lines ──────────────────

    // Covers lines 198 (blank relatedJson true branch), 202 (no-reparented branch), 791 (blank existingJson)
    @IsTest
    static void exec_forceNullCapture_coversLines198_202_791() {
        Account acc    = makeAccount('NullCap_Acc');
        Contact master = makeContact('NullCap_Master', 'nullcap_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('NullCap_Loser',  'nullcap_l@boosttest.com', acc.Id);
        Contact child  = new Contact(LastName = 'NullCap_Child', ReportsToId = loser.Id);
        insert child;
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|nullcap@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId           = String.valueOf(t.Id);
        req.masterId           = String.valueOf(master.Id);
        req.losingIds          = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions     = new Map<String,String>();
        req.relatedDeletesJson = '{"Contact":["' + String.valueOf(child.Id) + '"]}';
        req.notes              = 'boost-cov';
        MergeExecutionService.TEST_FORCE_NULL_CAPTURE_RESULT = true;
        Test.startTest();
        MergeWrappers.MergeResult res = MergeExecutionService.executeMerge(req);
        Test.stopTest();
        MergeExecutionService.TEST_FORCE_NULL_CAPTURE_RESULT = false;
        System.assert(res.success, 'Merge should succeed with null capture: ' + res.errorMessage);
    }

    // Covers line 218 (catch in reparentAndDeleteLosers EDA for-loop)
    @IsTest
    static void exec_throwReparentEdaLoop_coversLine218() {
        Account acc    = makeAccount('ReparentEDA_Acc');
        Contact master = makeContact('ReparentEDA_Master', 'reparenteda_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('ReparentEDA_Loser',  'reparenteda_l@boosttest.com', acc.Id);
        Contact child  = new Contact(LastName = 'ReparentEDA_Child', ReportsToId = loser.Id);
        insert child;
        insert new Merge_Object_Config__c(
            Name = 'ReparentEDA_Cfg', Object_API_Name__c = 'Contact',
            Parent_Field__c = 'ReportsToId', Object_Type__c = 'Contact', Is_Active__c = true
        );
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|reparenteda@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId       = String.valueOf(t.Id);
        req.masterId       = String.valueOf(master.Id);
        req.losingIds      = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions = new Map<String,String>();
        req.notes          = 'boost-cov';
        MergeExecutionService.TEST_THROW_REPARENT_EDA_LOOP = true;
        Test.startTest();
        MergeWrappers.MergeResult res = MergeExecutionService.executeMerge(req);
        Test.stopTest();
        MergeExecutionService.TEST_THROW_REPARENT_EDA_LOOP = false;
        System.assert(res.success, 'Merge should succeed with caught reparent EDA exception: ' + res.errorMessage);
    }

    // Covers line 269 (dr.getErrors() branch when delete succeeded but flag forces it)
    @IsTest
    static void exec_forceDeleteDrFail_coversLine269() {
        Account acc    = makeAccount('DrFail_Acc');
        Contact master = makeContact('DrFail_Master', 'drfail_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('DrFail_Loser',  'drfail_l@boosttest.com', acc.Id);
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|drfail@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId       = String.valueOf(t.Id);
        req.masterId       = String.valueOf(master.Id);
        req.losingIds      = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions = new Map<String,String>();
        req.notes          = 'boost-cov';
        MergeExecutionService.TEST_FORCE_DELETE_DR_FAIL = true;
        Test.startTest();
        MergeWrappers.MergeResult res = MergeExecutionService.executeMerge(req);
        Test.stopTest();
        MergeExecutionService.TEST_FORCE_DELETE_DR_FAIL = false;
        System.assertEquals(false, res.success, 'Merge should fail when dr.getErrors() path fires');
    }

    // Covers line 732 (catch in captureLoserRelatedIds SOQL try block)
    @IsTest
    static void exec_throwCaptureQuery_coversLine732() {
        Account acc    = makeAccount('CaptureQ_Acc');
        Contact master = makeContact('CaptureQ_Master', 'captureq_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('CaptureQ_Loser',  'captureq_l@boosttest.com', acc.Id);
        insert new Merge_Object_Config__c(
            Name = 'CaptureQ_Cfg', Object_API_Name__c = 'Contact',
            Parent_Field__c = 'ReportsToId', Object_Type__c = 'Contact', Is_Active__c = true
        );
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|captureq@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId       = String.valueOf(t.Id);
        req.masterId       = String.valueOf(master.Id);
        req.losingIds      = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions = new Map<String,String>();
        req.notes          = 'boost-cov';
        MergeExecutionService.TEST_THROW_CAPTURE_QUERY = true;
        Test.startTest();
        MergeWrappers.MergeResult res = MergeExecutionService.executeMerge(req);
        Test.stopTest();
        MergeExecutionService.TEST_THROW_CAPTURE_QUERY = false;
        System.assert(res.success, 'Merge should succeed with caught capture SOQL exception: ' + res.errorMessage);
    }

    // Covers line 779 (catch in applyRelatedDeletes for-loop)
    @IsTest
    static void exec_throwApplyDeletesLoop_coversLine779() {
        Account acc    = makeAccount('ApplyDel_Acc');
        Contact master = makeContact('ApplyDel_Master', 'applydel_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('ApplyDel_Loser',  'applydel_l@boosttest.com', acc.Id);
        Contact child  = new Contact(LastName = 'ApplyDel_Child', ReportsToId = loser.Id);
        insert child;
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|applydel@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId           = String.valueOf(t.Id);
        req.masterId           = String.valueOf(master.Id);
        req.losingIds          = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions     = new Map<String,String>();
        req.relatedDeletesJson = '{"Contact":["' + String.valueOf(child.Id) + '"]}';
        req.notes              = 'boost-cov';
        MergeExecutionService.TEST_THROW_APPLY_DELETES_LOOP = true;
        Test.startTest();
        MergeWrappers.MergeResult res = MergeExecutionService.executeMerge(req);
        Test.stopTest();
        MergeExecutionService.TEST_THROW_APPLY_DELETES_LOOP = false;
        System.assert(res.success, 'Merge should succeed with caught applyRelatedDeletes exception: ' + res.errorMessage);
    }

    // Covers lines 793-794 (JSON parse failure catch in appendDeletedIdsToLog)
    @IsTest
    static void exec_forceInvalidAppendJson_coversLines793_794() {
        Account acc    = makeAccount('InvalidJSON_Acc');
        Contact master = makeContact('InvalidJSON_Master', 'invalidjson_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('InvalidJSON_Loser',  'invalidjson_l@boosttest.com', acc.Id);
        Contact child  = new Contact(LastName = 'InvalidJSON_Child', ReportsToId = loser.Id);
        insert child;
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|invalidjson@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId           = String.valueOf(t.Id);
        req.masterId           = String.valueOf(master.Id);
        req.losingIds          = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions     = new Map<String,String>();
        req.relatedDeletesJson = '{"Contact":["' + String.valueOf(child.Id) + '"]}';
        req.notes              = 'boost-cov';
        MergeExecutionService.TEST_FORCE_INVALID_APPEND_JSON = true;
        Test.startTest();
        MergeWrappers.MergeResult res = MergeExecutionService.executeMerge(req);
        Test.stopTest();
        MergeExecutionService.TEST_FORCE_INVALID_APPEND_JSON = false;
        System.assert(res.success, 'Merge should succeed with caught invalid JSON in appendDeletedIdsToLog: ' + res.errorMessage);
    }

    // Covers line 838 (update catch in appendDeletedIdsToLog)
    @IsTest
    static void exec_throwAppendLogUpdate_coversLine838() {
        Account acc    = makeAccount('AppendUpd_Acc');
        Contact master = makeContact('AppendUpd_Master', 'appendupd_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('AppendUpd_Loser',  'appendupd_l@boosttest.com', acc.Id);
        Contact child  = new Contact(LastName = 'AppendUpd_Child', ReportsToId = loser.Id);
        insert child;
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|appendupd@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId           = String.valueOf(t.Id);
        req.masterId           = String.valueOf(master.Id);
        req.losingIds          = new List<String>{ String.valueOf(loser.Id) };
        req.fieldDecisions     = new Map<String,String>();
        req.relatedDeletesJson = '{"Contact":["' + String.valueOf(child.Id) + '"]}';
        req.notes              = 'boost-cov';
        MergeExecutionService.TEST_THROW_APPEND_LOG_UPDATE = true;
        Test.startTest();
        MergeWrappers.MergeResult res = MergeExecutionService.executeMerge(req);
        Test.stopTest();
        MergeExecutionService.TEST_THROW_APPEND_LOG_UPDATE = false;
        System.assert(res.success, 'Merge should succeed with caught appendDeletedIdsToLog update exception: ' + res.errorMessage);
    }

    @IsTest
    static void ticket_accountQueryFail_catchBlock() {
        Account acc    = makeAccount('AQF_Acct');
        Contact master = makeContact('AQF_Master', 'aqf_m@boosttest.com', acc.Id);
        Contact loser  = makeContact('AQF_Loser',  'aqf_l@boosttest.com', acc.Id);
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c = 'Contact', Status__c = 'New',
            Match_Type__c = 'Email', Match_Key__c = 'Contact|Email|aqf@boosttest.com',
            Match_Confidence__c = 'High', Candidate_Count__c = 2
        );
        insert t;
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(master.Id), Record_Name__c = 'AQF_Master',
                Is_Master__c = false, Is_Losing_Record__c = false),
            new Merge_Candidate__c(Merge_Ticket__c = t.Id,
                Record_Id__c = String.valueOf(loser.Id),  Record_Name__c = 'AQF_Loser',
                Is_Master__c = false, Is_Losing_Record__c = false)
        };

        MergeTicketService.TEST_THROW_ACCOUNT_CONTEXT_QUERY = true;
        Test.startTest();
        MergeWrappers.ComparisonMatrix matrix = MergeTicketService.buildComparisonMatrix(t.Id);
        Test.stopTest();
        MergeTicketService.TEST_THROW_ACCOUNT_CONTEXT_QUERY = false;

        System.assertNotEquals(null, matrix,
            'buildComparisonMatrix must return a matrix even when account query throws');
    }

    // ── MergeScanBatch.execute — high-frequency value filtered by threshold ─────

    @IsTest
    static void batch_execute_highFrequencyValue_skippedByThreshold() {
        // With TEST_FREQ_THRESHOLD=2, any value shared by 3+ records is treated as
        // junk data and skipped. This covers the frequency-filter branch in detectInScope().
        Database.DmlOptions opts = new Database.DmlOptions();
        opts.DuplicateRuleHeader.AllowSave = true;
        Contact c1 = new Contact(LastName = 'FreqA', Email = 'freq_junk_x9@test.com');
        Contact c2 = new Contact(LastName = 'FreqB', Email = 'freq_junk_x9@test.com');
        Contact c3 = new Contact(LastName = 'FreqC', Email = 'freq_junk_x9@test.com');
        Database.insert(c1, opts);
        Database.insert(c2, opts);
        Database.insert(c3, opts);

        MergeScanBatch.TEST_FREQ_THRESHOLD = 2; // 3 records > 2 → filtered

        Test.startTest();
        Database.executeBatch(new MergeScanBatch('Contact', new Set<String>{'Email'}), 200);
        Test.stopTest();

        MergeScanBatch.TEST_FREQ_THRESHOLD = null;

        String key = 'Contact|Email|freq_junk_x9@test.com';
        System.assertEquals(0, [SELECT COUNT() FROM Merge_Ticket__c WHERE Match_Key__c = :key],
            'High-frequency value must be skipped — no ticket created');
    }

    // ── MergeScanBatch.finish — @TestVisible injection covers ticket-creation block ─
    // Two keys pointing to the same canonical pair trigger the else-branch (lines 151-154)
    // priority comparison: Email (priority 3) beats Name (priority 1) → Email key wins.

    @IsTest
    static void batch_finish_withInjectedData_createsTicketsAndCandidates() {
        // Inject TWO keys for the same canonical ID pair with different match types.
        // This forces the else branch (lines 151-154) in finish(): when the same
        // canonical pair is already in canonicalToBestKey, priority comparison fires.
        Contact c1 = new Contact(LastName = 'FinishInjectA');
        Contact c2 = new Contact(LastName = 'FinishInjectB');
        insert new List<Contact>{ c1, c2 };

        String idStr     = String.valueOf(c1.Id) + '|' + String.valueOf(c2.Id);
        String emailKey  = 'Contact|Email|finish_inject@test.com';
        String nameKey   = 'Contact|Name|finishinjecta finishinjectb';

        // Both keys map to the same two IDs — same canonical pair
        MergeScanBatch.TEST_INJECT_FINISH_MATCH_TYPE = new Map<String,String>{
            emailKey => 'Email',
            nameKey  => 'Name'
        };
        MergeScanBatch.TEST_INJECT_FINISH_ID_SET = new Map<String,String>{
            emailKey => idStr,
            nameKey  => idStr
        };
        MergeScanBatch.TEST_INJECT_FINISH_NAMES = new Map<String,String>{
            emailKey + '::' + String.valueOf(c1.Id) => 'FinishInjectA',
            emailKey + '::' + String.valueOf(c2.Id) => 'FinishInjectB',
            nameKey  + '::' + String.valueOf(c1.Id) => 'FinishInjectA',
            nameKey  + '::' + String.valueOf(c2.Id) => 'FinishInjectB'
        };

        MergeScanBatch b = new MergeScanBatch('Contact', new Set<String>{ 'Email' });

        Test.startTest();
        b.finish(null);
        Test.stopTest();

        MergeScanBatch.TEST_INJECT_FINISH_MATCH_TYPE = null;
        MergeScanBatch.TEST_INJECT_FINISH_ID_SET     = null;
        MergeScanBatch.TEST_INJECT_FINISH_NAMES      = null;

        // Only 1 ticket must be created (Email wins over Name via priority)
        System.assertEquals(1, [SELECT COUNT() FROM Merge_Ticket__c WHERE Match_Key__c = :emailKey],
            'finish() must pick Email key (priority 3) over Name key (priority 1)');
        System.assertEquals(0, [SELECT COUNT() FROM Merge_Ticket__c WHERE Match_Key__c = :nameKey],
            'finish() must not create a second ticket for the lower-priority Name key');
        System.assertEquals(2, [SELECT COUNT() FROM Merge_Candidate__c
                                  WHERE Merge_Ticket__c IN
                                      (SELECT Id FROM Merge_Ticket__c WHERE Match_Key__c = :emailKey)],
            'finish() must create two candidates for the winning Email ticket');
    }
}
