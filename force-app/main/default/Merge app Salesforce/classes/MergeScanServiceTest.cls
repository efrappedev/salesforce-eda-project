/**
 * MergeScanServiceTest.cls
 * Covers: MergeScanService (scan, dryRun, deduplication, helpers),
 *         MergeScanBatch (full batch lifecycle)
 * Target coverage: 100 %
 */
@IsTest
private class MergeScanServiceTest {

    // ─── Shared test-data helpers ─────────────────────────────────────────────

    private static Merge_Ticket__c makeTicket(String objectType, String matchKey) {
        Merge_Ticket__c t = new Merge_Ticket__c(
            Object_Type__c      = objectType,
            Status__c           = 'New',
            Match_Type__c       = 'Email',
            Match_Key__c        = matchKey,
            Match_Confidence__c = 'High',
            Candidate_Count__c  = 2
        );
        insert t;
        return t;
    }

    private static void attachCandidates(
        Id ticketId, Id id1, String name1, Id id2, String name2
    ) {
        insert new List<Merge_Candidate__c>{
            new Merge_Candidate__c(Merge_Ticket__c = ticketId,
                Record_Id__c = String.valueOf(id1), Record_Name__c = name1,
                Is_Master__c = false, Is_Losing_Record__c = false),
            new Merge_Candidate__c(Merge_Ticket__c = ticketId,
                Record_Id__c = String.valueOf(id2), Record_Name__c = name2,
                Is_Master__c = false, Is_Losing_Record__c = false)
        };
    }

    // ─── MergeScanService.scan ────────────────────────────────────────────────

    @IsTest
    static void scan_emailMatch_createsTicketAndCandidates() {
        Contact c1 = new Contact(LastName = 'DupA', Email = 'dup_email@scantest.com');
        Contact c2 = new Contact(LastName = 'DupB', Email = 'dup_email@scantest.com');
        insert new List<Contact>{ c1, c2 };

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType  = 'Contact';
        req.matchFields = new List<String>{ 'Email' };
        req.recordLimit = 1000;
        req.dryRun      = false;

        Test.startTest();
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(1, result.ticketsCreated);
        System.assertEquals(0, result.previews.size());

        List<Merge_Ticket__c> tickets = [
            SELECT Id FROM Merge_Ticket__c WHERE Object_Type__c = 'Contact'
        ];
        System.assertEquals(1, tickets.size());
        System.assertEquals(2, [SELECT COUNT() FROM Merge_Candidate__c
                                  WHERE Merge_Ticket__c = :tickets[0].Id]);
    }

    @IsTest
    static void scan_dryRun_returnsPreviews_noInsert() {
        Contact c1 = new Contact(LastName = 'DryA', Email = 'dryrun@scantest.com');
        Contact c2 = new Contact(LastName = 'DryB', Email = 'dryrun@scantest.com');
        insert new List<Contact>{ c1, c2 };

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType  = 'Contact';
        req.matchFields = new List<String>{ 'Email' };
        req.recordLimit = 1000;
        req.dryRun      = true;

        Test.startTest();
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        Test.stopTest();

        System.assertEquals(true,   result.success);
        System.assertEquals(0,      result.ticketsCreated);
        System.assertEquals(1,      result.previews.size());
        System.assertEquals('Email',result.previews[0].matchType);
        System.assertEquals(2,      result.previews[0].candidateCount);
        System.assertEquals(0,      [SELECT COUNT() FROM Merge_Ticket__c]);
    }

    @IsTest
    static void scan_phoneMatch_createsTicket() {
        Contact c1 = new Contact(LastName = 'PhoneA', Phone = '5148881234');
        Contact c2 = new Contact(LastName = 'PhoneB', Phone = '5148881234');
        insert new List<Contact>{ c1, c2 };

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType  = 'Contact';
        req.matchFields = new List<String>{ 'Phone' };
        req.recordLimit = 1000;
        req.dryRun      = false;

        Test.startTest();
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(1, result.ticketsCreated);
    }

    @IsTest
    static void scan_nameMatch_createsTicket() {
        Contact c1 = new Contact(LastName = 'Tremblay', FirstName = 'Jean');
        Contact c2 = new Contact(LastName = 'Tremblay', FirstName = 'Jean');
        insert new List<Contact>{ c1, c2 };

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType  = 'Contact';
        req.matchFields = new List<String>{ 'Name' };
        req.recordLimit = 1000;
        req.dryRun      = false;

        Test.startTest();
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(1, result.ticketsCreated);
    }

    @IsTest
    static void scan_accountPhoneMatch_createsTicket() {
        Account a1 = new Account(Name = 'Corp Alpha', Phone = '5140001111');
        Account a2 = new Account(Name = 'Corp Beta',  Phone = '5140001111');
        insert new List<Account>{ a1, a2 };

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType  = 'Account';
        req.matchFields = new List<String>{ 'Phone' };
        req.recordLimit = 1000;
        req.dryRun      = false;

        Test.startTest();
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(1, result.ticketsCreated);
    }

    @IsTest
    static void scan_existingMatchKey_doesNotCreateDuplicate() {
        Contact c1 = new Contact(LastName = 'ExA', Email = 'existing_key@scantest.com');
        Contact c2 = new Contact(LastName = 'ExB', Email = 'existing_key@scantest.com');
        insert new List<Contact>{ c1, c2 };

        String matchKey = DataNormalizationUtil.buildMatchKey(
            'Contact', 'Email', 'existing_key@scantest.com'
        );
        makeTicket('Contact', matchKey);

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType  = 'Contact';
        req.matchFields = new List<String>{ 'Email' };
        req.recordLimit = 1000;
        req.dryRun      = false;

        Test.startTest();
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(0, result.ticketsCreated);
        // Ticket count stays at 1 (only pre-existing)
        System.assertEquals(1, [SELECT COUNT() FROM Merge_Ticket__c]);
    }

    @IsTest
    static void scan_existingCandidateSet_countsAsSkipped() {
        // Two contacts matched by both phone AND email.
        // Existing ticket covers phone match with same candidates.
        // Scanning by email only: email key not in existingKeys, but candidate set is covered.
        String phone = '5149991234';
        String email = 'bothkeys@scantest.com';
        Contact c1 = new Contact(LastName = 'BKA', Email = email, Phone = phone);
        Contact c2 = new Contact(LastName = 'BKB', Email = email, Phone = phone);
        insert new List<Contact>{ c1, c2 };

        String phoneKey = DataNormalizationUtil.buildMatchKey('Contact', 'Phone', phone);
        Merge_Ticket__c t = makeTicket('Contact', phoneKey);
        attachCandidates(t.Id, c1.Id, 'BKA', c2.Id, 'BKB');

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType  = 'Contact';
        req.matchFields = new List<String>{ 'Email' };
        req.recordLimit = 1000;
        req.dryRun      = false;

        Test.startTest();
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(0, result.ticketsCreated);
        System.assert(result.skippedExistingTickets > 0,
            'Group should be counted as skipped (candidate set already covered)');
    }

    @IsTest
    static void scan_deduplicatesSamePairEmailAndPhone_oneTicket() {
        Contact c1 = new Contact(LastName = 'DedupeA',
            Email = 'dedupe@scantest.com', Phone = '5149990001');
        Contact c2 = new Contact(LastName = 'DedupeB',
            Email = 'dedupe@scantest.com', Phone = '5149990001');
        insert new List<Contact>{ c1, c2 };

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType  = 'Contact';
        req.matchFields = new List<String>{ 'Email', 'Phone' };
        req.recordLimit = 1000;
        req.dryRun      = false;

        Test.startTest();
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(1, result.ticketsCreated,
            'Email+Phone on the same pair should produce exactly 1 ticket');
    }

    @IsTest
    static void scan_nullMatchFields_defaultsToEmailPhone() {
        Contact solo = new Contact(LastName = 'Solo', Email = 'solo@scantest.com');
        insert solo;

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType  = 'Contact';
        req.matchFields = null;   // → defaults to Email + Phone
        req.dryRun      = false;

        Test.startTest();
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(0, result.ticketsCreated);
        System.assert(result.recordsAnalyzed >= 1, 'Should have analyzed at least 1 record');
    }

    @IsTest
    static void scan_nullObjectType_defaultsToContact() {
        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType  = null;
        req.matchFields = new List<String>{ 'Email' };
        req.dryRun      = false;

        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        System.assertEquals(true, result.success);
    }

    // ─── MergeScanService static helpers ─────────────────────────────────────

    @IsTest
    static void loadExistingKeys_empty_returnsEmptySet() {
        Set<String> keys = MergeScanService.loadExistingKeys('Contact');
        System.assertNotEquals(null, keys);
        System.assertEquals(0, keys.size());
    }

    @IsTest
    static void loadExistingKeys_withTicket_returnsKey() {
        String key = 'Contact|Email|load_keys@scantest.com';
        makeTicket('Contact', key);
        Set<String> keys = MergeScanService.loadExistingKeys('Contact');
        System.assertEquals(true, keys.contains(key));
    }

    @IsTest
    static void loadExistingCandidateSets_empty_returnsEmptySet() {
        Set<String> sets = MergeScanService.loadExistingCandidateSets('Contact');
        System.assertNotEquals(null, sets);
    }

    @IsTest
    static void loadExistingCandidateSets_withCandidates_returnsCanonical() {
        Contact c1 = new Contact(LastName = 'CandA');
        Contact c2 = new Contact(LastName = 'CandB');
        insert new List<Contact>{ c1, c2 };

        Merge_Ticket__c t = makeTicket('Contact', 'Contact|Email|cs_test@scantest.com');
        attachCandidates(t.Id, c1.Id, 'CandA', c2.Id, 'CandB');

        Set<String> sets = MergeScanService.loadExistingCandidateSets('Contact');
        System.assert(!sets.isEmpty(), 'Should have at least one canonical set');

        List<String> ids = new List<String>{
            String.valueOf(c1.Id), String.valueOf(c2.Id)
        };
        ids.sort();
        System.assertEquals(true, sets.contains(String.join(ids, '|')));
    }

    @IsTest
    static void resolveFields_email_includesEmailField() {
        List<String> fields = MergeScanService.resolveFields('Contact', 'Email');
        System.assertEquals(true, fields.contains('Email'));
    }

    @IsTest
    static void resolveFields_phone_includesPhoneField() {
        List<String> fields = MergeScanService.resolveFields('Contact', 'Phone');
        System.assertEquals(true, fields.contains('Phone'));
    }

    @IsTest
    static void resolveFields_name_includesNameField() {
        List<String> fields = MergeScanService.resolveFields('Contact', 'Name');
        System.assertEquals(true, fields.contains('Name'));
    }

    @IsTest
    static void resolveFields_invalidObjectType_returnsEmpty() {
        List<String> fields = MergeScanService.resolveFields('BadObject__x', 'Email');
        System.assertEquals(0, fields.size());
    }

    // ─── MergeScanBatch ───────────────────────────────────────────────────────

    @IsTest
    static void batch_emailMatch_createsTicketAndCandidates() {
        Contact c1 = new Contact(LastName = 'BatchA', Email = 'batch_scan@scantest.com');
        Contact c2 = new Contact(LastName = 'BatchB', Email = 'batch_scan@scantest.com');
        insert new List<Contact>{ c1, c2 };

        Test.startTest();
        Database.executeBatch(
            new MergeScanBatch('Contact', new Set<String>{ 'Email' }), 200
        );
        Test.stopTest();

        List<Merge_Ticket__c> tickets = [
            SELECT Id, Candidate_Count__c FROM Merge_Ticket__c
            WHERE Object_Type__c = 'Contact'
        ];
        System.assertEquals(1, tickets.size());
        System.assertEquals(2, tickets[0].Candidate_Count__c);
        System.assertEquals(2, [SELECT COUNT() FROM Merge_Candidate__c
                                  WHERE Merge_Ticket__c = :tickets[0].Id]);
    }

    @IsTest
    static void batch_noMatchFields_producesNoTickets() {
        Contact c = new Contact(LastName = 'NoMatchBatch', Email = 'nomatch@batch.com');
        insert c;

        Test.startTest();
        Database.executeBatch(
            new MergeScanBatch('Contact', new Set<String>()), 200
        );
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Merge_Ticket__c]);
    }

    @IsTest
    static void batch_phoneMatch_createsTicket() {
        Contact c1 = new Contact(LastName = 'BatPhoneA', Phone = '5140005555');
        Contact c2 = new Contact(LastName = 'BatPhoneB', Phone = '5140005555');
        insert new List<Contact>{ c1, c2 };

        Test.startTest();
        Database.executeBatch(
            new MergeScanBatch('Contact', new Set<String>{ 'Phone' }), 200
        );
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Merge_Ticket__c
                                  WHERE Object_Type__c = 'Contact']);
    }

    @IsTest
    static void batch_skipsDuplicateCandidateSet() {
        String phone = '5140006666';
        String email = 'batch_dedup@scantest.com';
        Contact c1 = new Contact(LastName = 'BDedA', Email = email, Phone = phone);
        Contact c2 = new Contact(LastName = 'BDedB', Email = email, Phone = phone);
        insert new List<Contact>{ c1, c2 };

        // Pre-create phone ticket covering {c1, c2}
        String phoneKey = DataNormalizationUtil.buildMatchKey('Contact', 'Phone', phone);
        Merge_Ticket__c t = makeTicket('Contact', phoneKey);
        attachCandidates(t.Id, c1.Id, 'BDedA', c2.Id, 'BDedB');

        Test.startTest();
        Database.executeBatch(
            new MergeScanBatch('Contact', new Set<String>{ 'Email' }), 200
        );
        Test.stopTest();

        // Still only 1 ticket
        System.assertEquals(1, [SELECT COUNT() FROM Merge_Ticket__c]);
    }

    @IsTest
    static void batch_accountScan_createsTicket() {
        Account a1 = new Account(Name = 'BatAccA', Phone = '5140007777');
        Account a2 = new Account(Name = 'BatAccB', Phone = '5140007777');
        insert new List<Account>{ a1, a2 };

        Test.startTest();
        Database.executeBatch(
            new MergeScanBatch('Account', new Set<String>{ 'Phone' }), 200
        );
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Merge_Ticket__c
                                  WHERE Object_Type__c = 'Account']);
    }

    @IsTest
    static void batch_noArgConstructor_isCallable() {
        // Exercises the @TestVisible no-arg constructor (required for Database.Stateful)
        MergeScanBatch b = new MergeScanBatch();
        System.assertNotEquals(null, b);
    }

    @IsTest
    static void batch_blankObjectType_throwsBatchException() {
        Boolean threw = false;
        Test.startTest();
        Database.executeBatch(
            new MergeScanBatch('', new Set<String>{ 'Email' }), 200
        );
        try {
            Test.stopTest();
        } catch (Exception e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Blank objectType should throw BatchException in start()');
    }

    @IsTest
    static void batch_nameScan_createsTicket() {
        // Covers the nameFieldsStr non-blank branch in execute()
        Contact c1 = new Contact(LastName = 'Tremblay', FirstName = 'Marie');
        Contact c2 = new Contact(LastName = 'Tremblay', FirstName = 'Marie');
        insert new List<Contact>{ c1, c2 };

        Test.startTest();
        Database.executeBatch(
            new MergeScanBatch('Contact', new Set<String>{ 'Name' }), 200
        );
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Merge_Ticket__c
                                  WHERE Object_Type__c = 'Contact'
                                    AND Match_Type__c = 'Name']);
    }

    @IsTest
    static void batch_sameCanonicalHigherPriority_emailBeatsPhone() {
        // Same pair matches by both Email and Phone → priority resolution picks Email
        // Covers the else branch in finish() (lines 146-149)
        Contact c1 = new Contact(LastName = 'PrioA', Email = 'prio@scantest.com', Phone = '5140008888');
        Contact c2 = new Contact(LastName = 'PrioB', Email = 'prio@scantest.com', Phone = '5140008888');
        insert new List<Contact>{ c1, c2 };

        Test.startTest();
        Database.executeBatch(
            new MergeScanBatch('Contact', new Set<String>{ 'Email', 'Phone' }), 200
        );
        Test.stopTest();

        List<Merge_Ticket__c> tickets = [
            SELECT Match_Type__c FROM Merge_Ticket__c WHERE Object_Type__c = 'Contact'
        ];
        System.assertEquals(1, tickets.size(), 'Same canonical pair should produce only 1 ticket');
        System.assertEquals('Email', tickets[0].Match_Type__c,
            'Email (priority 3) should beat Phone (priority 2)');
    }
}
