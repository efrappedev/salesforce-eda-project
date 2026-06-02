/**
 * MergeScanServiceTest.cls
 * Covers: MergeScanService (scan, dryRun, deduplication, helpers, dynamic field
 *         resolution, Email_Address__c enrichment), MergeScanBatch (full batch lifecycle)
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

    @IsTest
    static void resolveFields_email_dynamic_allFieldsAreEmailType() {
        // Every field returned by dynamic Email resolution must have DisplayType.EMAIL
        List<String> emailFields = MergeScanService.resolveFields('Contact', 'Email');
        System.assert(!emailFields.isEmpty(), 'Must return at least one email field');
        Map<String,Schema.SObjectField> fm =
            Schema.getGlobalDescribe().get('Contact').getDescribe().fields.getMap();
        for (String f : emailFields) {
            Schema.DescribeFieldResult dfr = fm.get(f.toLowerCase()).getDescribe();
            System.assertEquals(Schema.DisplayType.EMAIL, dfr.getType(),
                'Dynamic email field must have DisplayType.EMAIL: ' + f);
        }
    }

    @IsTest
    static void resolveFields_phone_dynamic_allFieldsArePhoneType() {
        // Every field returned by dynamic Phone resolution must have DisplayType.PHONE
        List<String> phoneFields = MergeScanService.resolveFields('Contact', 'Phone');
        System.assert(!phoneFields.isEmpty(), 'Must return at least one phone field');
        Map<String,Schema.SObjectField> fm =
            Schema.getGlobalDescribe().get('Contact').getDescribe().fields.getMap();
        for (String f : phoneFields) {
            Schema.DescribeFieldResult dfr = fm.get(f.toLowerCase()).getDescribe();
            System.assertEquals(Schema.DisplayType.PHONE, dfr.getType(),
                'Dynamic phone field must have DisplayType.PHONE: ' + f);
        }
    }

    // ─── Email_Address__c — graceful no-op when object absent ────────────────

    @IsTest
    static void scan_emailAddress_gracefulWhenObjectAbsent() {
        // Covers detectByEmailObject early-return path when EA object unavailable
        // (emailObjectApiName must be set so the method is actually called)
        MergeScanService.emailAddressObjectAvailable = false;

        Contact c = new Contact(LastName = 'NoEA', Email = 'noea@scantest.com');
        insert c;

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType         = 'Contact';
        req.matchFields        = new List<String>{ 'Email' };
        req.dryRun             = false;
        req.emailObjectApiName = 'Email_Address__c';

        Test.startTest();
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        Test.stopTest();

        System.assertEquals(true, result.success, 'Scan must not throw when EA object is absent');
    }

    @IsTest
    static void enrichWithEmailAddressObject_noopWhenAbsent() {
        // Simulate absent object — stateful maps must remain untouched
        MergeScanService.emailAddressObjectAvailable = false;
        Map<String,String> accMatchType = new Map<String,String>();
        Map<String,String> accIdSet     = new Map<String,String>();
        Map<String,String> accNames     = new Map<String,String>();

        MergeScanService.enrichWithEmailObject(
            'Contact', 'Email_Address__c', new Set<String>(), accMatchType, accIdSet, accNames
        );

        System.assertEquals(0, accMatchType.size(), 'No changes when EA object absent');
    }

    // ─── Email_Address__c — detection when object is deployed ─────────────────

    @IsTest
    static void scan_emailAddress_detectsDuplicatesFromChildObject() {
        if (Schema.getGlobalDescribe().get('Email_Address__c') == null) {
            System.debug(LoggingLevel.WARN,
                'MergeScanServiceTest: Email_Address__c not deployed — skipping EA detection test');
            return;
        }

        Contact c1 = new Contact(LastName = 'EADupA');
        Contact c2 = new Contact(LastName = 'EADupB');
        insert new List<Contact>{ c1, c2 };

        SObject ea1 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea1.put('Contact__c', c1.Id);
        ea1.put('Email__c',   'shared_ea@scantest.com');
        SObject ea2 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea2.put('Contact__c', c2.Id);
        ea2.put('Email__c',   'shared_ea@scantest.com');
        insert new List<SObject>{ ea1, ea2 };

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType         = 'Contact';
        req.matchFields        = new List<String>{ 'Email' };
        req.dryRun             = false;
        req.recordLimit        = 1000;
        req.emailObjectApiName = 'Email_Address__c';

        Test.startTest();
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(1, result.ticketsCreated,
            'Should detect c1 and c2 as duplicates via Email_Address__c');
    }

    @IsTest
    static void scan_emailAddress_crossDetect_directFieldAndChildObject() {
        // Contact A has email in direct field; Contact B has same email only in EA.
        // They should be detected as duplicates via cross-detection.
        if (Schema.getGlobalDescribe().get('Email_Address__c') == null) {
            System.debug(LoggingLevel.WARN,
                'MergeScanServiceTest: Email_Address__c not deployed — skipping cross-detection test');
            return;
        }

        Contact cA = new Contact(LastName = 'CrossA', Email = 'cross_detect@scantest.com');
        Contact cB = new Contact(LastName = 'CrossB');
        insert new List<Contact>{ cA, cB };

        SObject ea = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea.put('Contact__c', cB.Id);
        ea.put('Email__c',   'cross_detect@scantest.com');
        insert ea;

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType         = 'Contact';
        req.matchFields        = new List<String>{ 'Email' };
        req.dryRun             = false;
        req.recordLimit        = 1000;
        req.emailObjectApiName = 'Email_Address__c';

        Test.startTest();
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(1, result.ticketsCreated,
            'Cross-detection: direct email (cA) + Email_Address__c (cB) = duplicate pair');
    }

    @IsTest
    static void batch_emailAddress_enrichesWhenObjectExists() {
        if (Schema.getGlobalDescribe().get('Email_Address__c') == null) {
            System.debug(LoggingLevel.WARN,
                'MergeScanServiceTest: Email_Address__c not deployed — skipping batch EA test');
            return;
        }

        Contact c1 = new Contact(LastName = 'BatchEA_A');
        Contact c2 = new Contact(LastName = 'BatchEA_B');
        insert new List<Contact>{ c1, c2 };

        SObject ea1 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea1.put('Contact__c', c1.Id);
        ea1.put('Email__c',   'batch_ea@scantest.com');
        SObject ea2 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea2.put('Contact__c', c2.Id);
        ea2.put('Email__c',   'batch_ea@scantest.com');
        insert new List<SObject>{ ea1, ea2 };

        Test.startTest();
        Database.executeBatch(
            new MergeScanBatch('Contact', new Set<String>{ 'Email' }, 'Email_Address__c'), 200
        );
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Merge_Ticket__c
                                  WHERE Object_Type__c = 'Contact'],
            'Batch should detect duplicates via Email_Address__c child object');
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

    // ─── Coverage boosters: scan() outer catch + countQuery catch ─────────────

    @IsTest
    static void scan_nullRequest_returnsErrorResult() {
        // Covers lines 61-63: outer try-catch in scan() fires on null request NPE
        MergeWrappers.ScanResult result = MergeScanService.scan(null);
        System.assertEquals(false,  result.success);
        System.assertNotEquals(null, result.errorMessage);
    }

    @IsTest
    static void scan_invalidObjectType_countQueryExceptionCaught() {
        // Covers line 33: inner countQuery catch fires when object does not exist
        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType  = 'NotARealObject__xyz';
        req.matchFields = new List<String>{ 'Email' };
        req.dryRun      = false;

        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        System.assertEquals(true, result.success,
            'Scan should succeed even when countQuery fails');
        System.assertEquals(0, result.recordsAnalyzed,
            'recordsAnalyzed must be 0 when countQuery throws');
    }

    // ─── Coverage boosters: EA with Account (else branch + lookupField ternary) ─

    @IsTest
    static void scan_account_emailAddress_detectsDuplicates() {
        // Covers: line 132 (Account branch of lookupField ternary in detectByEmailAddressObject)
        //         lines 191-197 (else branch — Account has no direct Email-type field)
        if (Schema.getGlobalDescribe().get('Email_Address__c') == null) {
            System.debug(LoggingLevel.WARN,
                'MergeScanServiceTest: Email_Address__c not deployed — skipping');
            return;
        }

        Account a1 = new Account(Name = 'EAAccA');
        Account a2 = new Account(Name = 'EAAccB');
        insert new List<Account>{ a1, a2 };

        SObject ea1 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea1.put('Account__c', a1.Id);
        ea1.put('Email__c',   'acc_ea@scantest.com');
        SObject ea2 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea2.put('Account__c', a2.Id);
        ea2.put('Email__c',   'acc_ea@scantest.com');
        insert new List<SObject>{ ea1, ea2 };

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType         = 'Account';
        req.matchFields        = new List<String>{ 'Email' };
        req.dryRun             = false;
        req.recordLimit        = 1000;
        req.emailObjectApiName = 'Email_Address__c';

        Test.startTest();
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(1, result.ticketsCreated,
            'Should detect Account duplicates via Email_Address__c');
    }

    @IsTest
    static void enrichWithEmailAddressObject_unknownObjectType_noops() {
        // Covers line 226: lookupField == null return in enrichWithEmailAddressObject
        Map<String,String> accMatchType = new Map<String,String>();
        Map<String,String> accIdSet     = new Map<String,String>();
        Map<String,String> accNames     = new Map<String,String>();

        MergeScanService.enrichWithEmailObject(
            'Lead', 'Email_Address__c', new Set<String>(), accMatchType, accIdSet, accNames
        );

        System.assertEquals(0, accMatchType.size(), 'Must no-op for non-Contact/Account types');
    }

    @IsTest
    static void enrichWithEmailAddressObject_seedsFromExistingAccIdSet() {
        // Covers lines 252-256: seed loop merges pre-existing batch IDs into keyToIds
        // Covers line 299 else branch: accMatchType already has the key → skip put
        if (Schema.getGlobalDescribe().get('Email_Address__c') == null) {
            System.debug(LoggingLevel.WARN,
                'MergeScanServiceTest: Email_Address__c not deployed — skipping');
            return;
        }

        Contact cA = new Contact(LastName = 'SeedEnrichA');
        Contact cB = new Contact(LastName = 'SeedEnrichB');
        insert new List<Contact>{ cA, cB };

        SObject ea = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea.put('Contact__c', cA.Id);
        ea.put('Email__c',   'seed_enrich@scantest.com');
        insert ea;

        String key = DataNormalizationUtil.buildMatchKey(
            'Contact', 'Email', 'seed_enrich@scantest.com'
        );
        Map<String,String> accMatchType = new Map<String,String>{ key => 'Email' };
        Map<String,String> accIdSet     = new Map<String,String>{ key => String.valueOf(cB.Id) };
        Map<String,String> accNames     = new Map<String,String>();

        Test.startTest();
        MergeScanService.enrichWithEmailObject(
            'Contact', 'Email_Address__c', new Set<String>(), accMatchType, accIdSet, accNames
        );
        Test.stopTest();

        System.assert(accIdSet.containsKey(key));
        Set<String> ids = new Set<String>(accIdSet.get(key).split('\\|'));
        System.assert(ids.contains(String.valueOf(cA.Id)), 'cA from EA must be in result');
        System.assert(ids.contains(String.valueOf(cB.Id)), 'cB from pre-existing batch data must be preserved');
    }

    @IsTest
    static void scan_emailAddress_seedsFromExistingDirectFieldGroup() {
        // Covers line 160: seed loop — detectByEmailAddressObject seeds from existing group
        // Covers line 202: Step 3 — groups.containsKey(key) when EA merges into existing group
        if (Schema.getGlobalDescribe().get('Email_Address__c') == null) {
            System.debug(LoggingLevel.WARN,
                'MergeScanServiceTest: Email_Address__c not deployed — skipping');
            return;
        }

        Contact cA = new Contact(LastName = 'SeedGrpA', Email = 'seed_grp@scantest.com');
        Contact cB = new Contact(LastName = 'SeedGrpB', Email = 'seed_grp@scantest.com');
        Contact cC = new Contact(LastName = 'SeedGrpC');
        insert new List<Contact>{ cA, cB, cC };

        SObject ea = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea.put('Contact__c', cC.Id);
        ea.put('Email__c',   'seed_grp@scantest.com');
        insert ea;

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType         = 'Contact';
        req.matchFields        = new List<String>{ 'Email' };
        req.dryRun             = true;
        req.recordLimit        = 1000;
        req.emailObjectApiName = 'Email_Address__c';

        Test.startTest();
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(1, result.previews.size(), 'A, B, C must collapse into one group');
        System.assertEquals(3, result.previews[0].candidateCount, 'Group must contain all 3 contacts');
    }

    @IsTest
    static void batch_account_emailAddress_enriches() {
        // Covers lines 286-291 (else branch in enrichWithEmailAddressObject — Account has no
        // direct Email-type fields so names are fetched in the else path)
        if (Schema.getGlobalDescribe().get('Email_Address__c') == null) {
            System.debug(LoggingLevel.WARN,
                'MergeScanServiceTest: Email_Address__c not deployed — skipping');
            return;
        }

        Account a1 = new Account(Name = 'BatchAccEA_A');
        Account a2 = new Account(Name = 'BatchAccEA_B');
        insert new List<Account>{ a1, a2 };

        SObject ea1 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea1.put('Account__c', a1.Id);
        ea1.put('Email__c',   'batch_acc_ea@scantest.com');
        SObject ea2 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea2.put('Account__c', a2.Id);
        ea2.put('Email__c',   'batch_acc_ea@scantest.com');
        insert new List<SObject>{ ea1, ea2 };

        Test.startTest();
        Database.executeBatch(
            new MergeScanBatch('Account', new Set<String>{ 'Email' }, 'Email_Address__c'), 200
        );
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Merge_Ticket__c
                                  WHERE Object_Type__c = 'Account'],
            'Batch must detect Account duplicates via EA (else branch — no direct email fields)');
    }

    @IsTest
    static void scan_leadObjectType_emailAddressLookupNullReturn() {
        // Covers line 134: lookupField == null return in detectByEmailAddressObject
        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType  = 'Lead';
        req.matchFields = new List<String>{ 'Email' };
        req.dryRun      = false;
        req.recordLimit = 100;

        Test.startTest();
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        Test.stopTest();

        System.assertEquals(true, result.success,
            'Scan must not throw for Lead — lookupField is null and detectByEmailAddressObject returns early');
    }

    // ─── Coverage boosters: else branches (no direct Email-type fields) ─────────

    @IsTest
    static void scan_forcedEmptyDirectFields_elseNameQueryCoversLines192to195() {
        // Covers lines 192-195: else branch in detectByEmailAddressObject fires when
        // forceEmptyDirectFieldsForTest=true bypasses the direct-field query path,
        // exercising the simpler "SELECT Id, Name … WHERE Id IN :allEaIds" fallback.
        if (Schema.getGlobalDescribe().get('Email_Address__c') == null) {
            System.debug(LoggingLevel.WARN,
                'MergeScanServiceTest: Email_Address__c not deployed — skipping else-branch test');
            return;
        }

        MergeScanService.forceEmptyDirectFieldsForTest = true;

        Account a1 = new Account(Name = 'ElseAccA');
        Account a2 = new Account(Name = 'ElseAccB');
        insert new List<Account>{ a1, a2 };

        SObject ea1 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea1.put('Account__c', a1.Id);
        ea1.put('Email__c',   'else_branch_acc@scantest.com');
        SObject ea2 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea2.put('Account__c', a2.Id);
        ea2.put('Email__c',   'else_branch_acc@scantest.com');
        insert new List<SObject>{ ea1, ea2 };

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType         = 'Account';
        req.matchFields        = new List<String>{ 'Email' };
        req.dryRun             = false;
        req.recordLimit        = 1000;
        req.emailObjectApiName = 'Email_Address__c';

        Test.startTest();
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(1, result.ticketsCreated,
            'Else branch must still detect Account duplicates via EA name-only query');
    }

    @IsTest
    static void enrich_forcedEmptyDirectFields_elseNameQueryCoversLines286to291() {
        // Covers lines 286-291: else branch in enrichWithEmailAddressObject fires when
        // forceEmptyDirectFieldsForTest=true, exercising the name-only fallback query.
        if (Schema.getGlobalDescribe().get('Email_Address__c') == null) {
            System.debug(LoggingLevel.WARN,
                'MergeScanServiceTest: Email_Address__c not deployed — skipping else-branch enrich test');
            return;
        }

        MergeScanService.forceEmptyDirectFieldsForTest = true;

        Contact cA = new Contact(LastName = 'ElseEnrichA');
        Contact cB = new Contact(LastName = 'ElseEnrichB');
        insert new List<Contact>{ cA, cB };

        SObject ea1 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea1.put('Contact__c', cA.Id);
        ea1.put('Email__c',   'else_enrich@scantest.com');
        SObject ea2 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea2.put('Contact__c', cB.Id);
        ea2.put('Email__c',   'else_enrich@scantest.com');
        insert new List<SObject>{ ea1, ea2 };

        Map<String,String> accMatchType = new Map<String,String>();
        Map<String,String> accIdSet     = new Map<String,String>();
        Map<String,String> accNames     = new Map<String,String>();

        Test.startTest();
        MergeScanService.enrichWithEmailObject(
            'Contact', 'Email_Address__c', new Set<String>(), accMatchType, accIdSet, accNames
        );
        Test.stopTest();

        String key = DataNormalizationUtil.buildMatchKey('Contact', 'Email', 'else_enrich@scantest.com');
        System.assert(accIdSet.containsKey(key), 'Else branch must populate accIdSet');
        Set<String> ids = new Set<String>(accIdSet.get(key).split('\\|'));
        System.assert(ids.contains(String.valueOf(cA.Id)), 'cA must be in result');
        System.assert(ids.contains(String.valueOf(cB.Id)), 'cB must be in result');
    }

    // ─── Custom emailObjectApiName: non-existent object returns early ────────────

    @IsTest
    static void scan_nonExistentEmailObject_gracefullySkips() {
        // Covers MergeScanService line ~140: early return when custom emailObjName
        // does not exist in globalDescribe (detectByEmailObject guard)
        Contact c1 = new Contact(LastName = 'FakeObjA', Email = 'fakeobj@scantest.com');
        Contact c2 = new Contact(LastName = 'FakeObjB', Email = 'fakeobj@scantest.com');
        insert new List<Contact>{ c1, c2 };

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType         = 'Contact';
        req.matchFields        = new List<String>{ 'Email' };
        req.recordLimit        = 1000;
        req.dryRun             = false;
        req.emailObjectApiName = 'Totally_Fake_Email_Obj__c';

        Test.startTest();
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        Test.stopTest();

        System.assertEquals(true, result.success,
            'Scan must succeed even when emailObjectApiName refers to non-existent object');
        System.assertEquals(1, result.ticketsCreated,
            'Direct-field duplicate still detected despite missing custom email object');
    }

    @IsTest
    static void enrichWithEmailObject_nonExistentObject_noops() {
        // Covers MergeScanService line ~254: early return in enrichWithEmailObject
        // when the custom emailObjName is not in globalDescribe
        Map<String,String> accMatchType = new Map<String,String>();
        Map<String,String> accIdSet     = new Map<String,String>();
        Map<String,String> accNames     = new Map<String,String>();

        MergeScanService.enrichWithEmailObject(
            'Contact', 'Totally_Fake_Email_Obj__c',
            new Set<String>(), accMatchType, accIdSet, accNames
        );

        System.assertEquals(0, accMatchType.size(),
            'enrichWithEmailObject must no-op when object does not exist in org');
    }

    // ─── Account email detection via toggle (no Email button in modal) ──────────

    @IsTest
    static void scan_account_emailToggleOn_detectsViaEmailObject() {
        // Account has no Email button in the modal; the toggle (AUTO) is the only
        // way to detect email-based Account duplicates.
        if (Schema.getGlobalDescribe().get('Email_Address__c') == null) {
            System.debug(LoggingLevel.WARN,
                'MergeScanServiceTest: Email_Address__c not deployed — skipping Account toggle test');
            return;
        }
        Account a1 = new Account(Name = 'AccToggleOn_A');
        Account a2 = new Account(Name = 'AccToggleOn_B');
        insert new List<Account>{ a1, a2 };

        SObject ea1 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea1.put('Account__c', a1.Id);
        ea1.put('Email__c',   'acctoggle_on@scantest.com');
        SObject ea2 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea2.put('Account__c', a2.Id);
        ea2.put('Email__c',   'acctoggle_on@scantest.com');
        insert new List<SObject>{ ea1, ea2 };

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType         = 'Account';
        req.matchFields        = new List<String>{ 'Phone', 'Name' }; // Email button hidden
        req.dryRun             = false;
        req.recordLimit        = 1000;
        req.emailObjectApiName = 'AUTO'; // toggle ON

        Test.startTest();
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(1, result.ticketsCreated,
            'Account scan with toggle ON must detect email duplicates via auto-discovered email object');
    }

    @IsTest
    static void scan_account_emailToggleOff_skipsEmailObject() {
        // Toggle OFF for Account means no email-object detection — same as Contact toggle OFF.
        if (Schema.getGlobalDescribe().get('Email_Address__c') == null) {
            System.debug(LoggingLevel.WARN,
                'MergeScanServiceTest: Email_Address__c not deployed — skipping Account toggle-off test');
            return;
        }
        Account a1 = new Account(Name = 'AccToggleOff_A');
        Account a2 = new Account(Name = 'AccToggleOff_B');
        insert new List<Account>{ a1, a2 };

        SObject ea1 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea1.put('Account__c', a1.Id);
        ea1.put('Email__c',   'acctoggle_off@scantest.com');
        SObject ea2 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea2.put('Account__c', a2.Id);
        ea2.put('Email__c',   'acctoggle_off@scantest.com');
        insert new List<SObject>{ ea1, ea2 };

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType         = 'Account';
        req.matchFields        = new List<String>{ 'Phone', 'Name' };
        req.dryRun             = false;
        req.recordLimit        = 1000;
        req.emailObjectApiName = null; // toggle OFF — must skip email object

        Test.startTest();
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(0, result.ticketsCreated,
            'Account scan with toggle OFF must skip email-object detection');
    }

    @IsTest
    static void batch_account_emailToggleOn_detectsViaEmailObject() {
        if (Schema.getGlobalDescribe().get('Email_Address__c') == null) {
            System.debug(LoggingLevel.WARN,
                'MergeScanServiceTest: Email_Address__c not deployed — skipping batch Account toggle test');
            return;
        }
        Account a1 = new Account(Name = 'BatchAccToggleOn_A');
        Account a2 = new Account(Name = 'BatchAccToggleOn_B');
        insert new List<Account>{ a1, a2 };

        SObject ea1 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea1.put('Account__c', a1.Id);
        ea1.put('Email__c',   'batch_acctoggle_on@scantest.com');
        SObject ea2 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea2.put('Account__c', a2.Id);
        ea2.put('Email__c',   'batch_acctoggle_on@scantest.com');
        insert new List<SObject>{ ea1, ea2 };

        Test.startTest();
        Database.executeBatch(
            new MergeScanBatch('Account', new Set<String>{ 'Phone', 'Name' }, 'AUTO'), 200
        );
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Merge_Ticket__c
                                  WHERE Object_Type__c = 'Account'],
            'Batch Account with toggle ON must detect email duplicates via email object');
    }

    // ─── AUTO email-object discovery ─────────────────────────────────────────

    @IsTest
    static void resolveEmailObjectName_contactType_returnsNonNullWhenEmailObjectDeployed() {
        if (Schema.getGlobalDescribe().get('Email_Address__c') == null) {
            System.debug(LoggingLevel.WARN,
                'MergeScanServiceTest: Email_Address__c not deployed — skipping resolveEmailObjectName test');
            return;
        }
        String resolved = MergeScanService.resolveEmailObjectName('Contact');
        System.assertNotEquals(null, resolved,
            'resolveEmailObjectName should find at least one qualifying email object for Contact');
    }

    @IsTest
    static void resolveEmailObjectName_leadType_returnsNull() {
        // Lead has no custom email-address object with a Lead lookup → returns null
        String resolved = MergeScanService.resolveEmailObjectName('Lead');
        System.assertEquals(null, resolved,
            'resolveEmailObjectName should return null when no qualifying email object exists for Lead');
    }

    @IsTest
    static void scan_autoEmailObject_detectsDuplicates() {
        if (Schema.getGlobalDescribe().get('Email_Address__c') == null) {
            System.debug(LoggingLevel.WARN,
                'MergeScanServiceTest: Email_Address__c not deployed — skipping AUTO scan test');
            return;
        }
        Contact c1 = new Contact(LastName = 'AutoEA_A');
        Contact c2 = new Contact(LastName = 'AutoEA_B');
        insert new List<Contact>{ c1, c2 };

        SObject ea1 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea1.put('Contact__c', c1.Id);
        ea1.put('Email__c',   'auto_ea@scantest.com');
        SObject ea2 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea2.put('Contact__c', c2.Id);
        ea2.put('Email__c',   'auto_ea@scantest.com');
        insert new List<SObject>{ ea1, ea2 };

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType         = 'Contact';
        req.matchFields        = new List<String>{ 'Email' };
        req.dryRun             = false;
        req.recordLimit        = 1000;
        req.emailObjectApiName = 'AUTO';

        Test.startTest();
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(1, result.ticketsCreated,
            'AUTO mode should auto-discover the email object and detect duplicates');
    }

    // ─── Mock-injection tests: cover EA code paths without the real email object ──
    // These tests work in ANY org regardless of whether Email_Address__c is deployed.
    // They inject mock key→ID maps directly into MergeScanService, bypassing the SOQL
    // query that would normally read from the email object. Steps 2 and 3 (cross-check
    // against real Contact/Account records) still run and cover those lines.

    @IsTest
    static void detectByEmailObject_mockInjection_createsTicket() {
        // Covers detectByEmailObject body (lines after "if emailField == null return")
        // without requiring Email_Address__c to be deployed.
        Contact c1 = new Contact(LastName = 'MockEA_A');  // no direct email field
        Contact c2 = new Contact(LastName = 'MockEA_B');
        insert new List<Contact>{ c1, c2 };

        String rawEmail = 'mock_ea_inject@scantest.com';
        String key = DataNormalizationUtil.buildMatchKey('Contact', 'Email', rawEmail);

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType         = 'Contact';
        req.matchFields        = new List<String>{ 'Email' };
        req.dryRun             = false;
        req.recordLimit        = 1000;
        req.emailObjectApiName = 'Email_Address__c';

        Test.startTest();
        // Injection must be set inside startTest so static state is visible in this
        // governor-limit context (package-private statics can be reset across startTest).
        MergeScanService.TEST_EA_KEY_TO_IDS = new Map<String,Set<Id>>{ key => new Set<Id>{ c1.Id, c2.Id } };
        MergeScanService.TEST_EA_KEY_TO_RAW = new Map<String,String>{ key => rawEmail };
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        MergeScanService.TEST_EA_KEY_TO_IDS = null;
        MergeScanService.TEST_EA_KEY_TO_RAW = null;
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(1, result.ticketsCreated,
            'Mock injection must detect c1+c2 as duplicates via injected EA data');
    }

    @IsTest
    static void enrichWithEmailObject_mockInjection_populatesAccumulators() {
        // Covers enrichWithEmailObject body (lines after "if emailField == null return")
        // without requiring Email_Address__c to be deployed.
        Contact cA = new Contact(LastName = 'EnrichMock_A');
        Contact cB = new Contact(LastName = 'EnrichMock_B');
        insert new List<Contact>{ cA, cB };

        String rawEmail = 'enrich_mock@scantest.com';
        String key = DataNormalizationUtil.buildMatchKey('Contact', 'Email', rawEmail);

        Map<String,String> accMatchType = new Map<String,String>();
        Map<String,String> accIdSet     = new Map<String,String>();
        Map<String,String> accNames     = new Map<String,String>();

        Test.startTest();
        // Injection must be set inside startTest so static state is visible in this
        // governor-limit context (package-private statics can be reset across startTest).
        MergeScanService.TEST_EA_KEY_TO_IDS = new Map<String,Set<Id>>{ key => new Set<Id>{ cA.Id, cB.Id } };
        MergeScanService.TEST_EA_KEY_TO_RAW = new Map<String,String>{ key => rawEmail };
        MergeScanService.enrichWithEmailObject(
            'Contact', 'Email_Address__c', new Set<String>(), accMatchType, accIdSet, accNames
        );
        MergeScanService.TEST_EA_KEY_TO_IDS = null;
        MergeScanService.TEST_EA_KEY_TO_RAW = null;
        Test.stopTest();

        System.assert(accIdSet.containsKey(key),
            'enrichWithEmailObject must populate accIdSet with the injected key');
        Set<String> ids = new Set<String>(accIdSet.get(key).split('\\|'));
        System.assert(ids.contains(String.valueOf(cA.Id)), 'cA must be in accumulator');
        System.assert(ids.contains(String.valueOf(cB.Id)), 'cB must be in accumulator');
    }

    @IsTest
    static void resolveEmailObjectName_testInjection_returnsInjectedName() {
        // Covers the "qualifying object found" return path in resolveEmailObjectName
        // without requiring a real qualifying email object in the org.
        MergeScanService.TEST_RESOLVE_EMAIL_OBJECT_NAME = 'Email_Address__c';
        String result = MergeScanService.resolveEmailObjectName('Contact');
        MergeScanService.TEST_RESOLVE_EMAIL_OBJECT_NAME = null;
        System.assertEquals('Email_Address__c', result,
            'TEST_RESOLVE_EMAIL_OBJECT_NAME injection must return the injected value');
    }

    @IsTest
    static void scan_autoMode_mockInjection_usesResolvedObject() {
        // Covers the AUTO → resolveEmailObjectName → detectByEmailObject path
        // via both TEST_RESOLVE_EMAIL_OBJECT_NAME and TEST_EA_KEY_TO_IDS injection.
        Contact c1 = new Contact(LastName = 'AutoMock_A');
        Contact c2 = new Contact(LastName = 'AutoMock_B');
        insert new List<Contact>{ c1, c2 };

        String rawEmail = 'auto_mock@scantest.com';
        String key = DataNormalizationUtil.buildMatchKey('Contact', 'Email', rawEmail);

        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType         = 'Contact';
        req.matchFields        = new List<String>{ 'Email' };
        req.dryRun             = false;
        req.recordLimit        = 1000;
        req.emailObjectApiName = 'AUTO';

        Test.startTest();
        // Injection must be set inside startTest so static state is visible in this
        // governor-limit context (package-private statics can be reset across startTest).
        MergeScanService.TEST_RESOLVE_EMAIL_OBJECT_NAME = 'Email_Address__c';
        MergeScanService.TEST_EA_KEY_TO_IDS = new Map<String,Set<Id>>{ key => new Set<Id>{ c1.Id, c2.Id } };
        MergeScanService.TEST_EA_KEY_TO_RAW = new Map<String,String>{ key => rawEmail };
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        MergeScanService.TEST_RESOLVE_EMAIL_OBJECT_NAME = null;
        MergeScanService.TEST_EA_KEY_TO_IDS = null;
        MergeScanService.TEST_EA_KEY_TO_RAW = null;
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(1, result.ticketsCreated,
            'AUTO mode with injected resolver + EA data must detect duplicate pair');
    }

    @IsTest
    static void scan_autoEmailObject_noQualifyingObject_gracefullySkips() {
        // Lead has no qualifying email object → AUTO resolves to null → scan succeeds
        MergeWrappers.ScanRequest req = new MergeWrappers.ScanRequest();
        req.objectType         = 'Lead';
        req.matchFields        = new List<String>{ 'Email' };
        req.dryRun             = false;
        req.recordLimit        = 100;
        req.emailObjectApiName = 'AUTO';

        Test.startTest();
        MergeWrappers.ScanResult result = MergeScanService.scan(req);
        Test.stopTest();

        System.assertEquals(true, result.success,
            'AUTO with no qualifying object for Lead must succeed gracefully');
    }

    @IsTest
    static void batch_autoEmailObject_enriches() {
        if (Schema.getGlobalDescribe().get('Email_Address__c') == null) {
            System.debug(LoggingLevel.WARN,
                'MergeScanServiceTest: Email_Address__c not deployed — skipping batch AUTO test');
            return;
        }
        Contact c1 = new Contact(LastName = 'BatchAutoEA_A');
        Contact c2 = new Contact(LastName = 'BatchAutoEA_B');
        insert new List<Contact>{ c1, c2 };

        SObject ea1 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea1.put('Contact__c', c1.Id);
        ea1.put('Email__c',   'batch_auto_ea@scantest.com');
        SObject ea2 = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea2.put('Contact__c', c2.Id);
        ea2.put('Email__c',   'batch_auto_ea@scantest.com');
        insert new List<SObject>{ ea1, ea2 };

        Test.startTest();
        Database.executeBatch(
            new MergeScanBatch('Contact', new Set<String>{ 'Email' }, 'AUTO'), 200
        );
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Merge_Ticket__c
                                  WHERE Object_Type__c = 'Contact'],
            'Batch with AUTO should auto-discover Email_Address__c and detect duplicates');
    }

    @IsTest
    static void batch_autoEmailObject_noQualifyingObject_gracefullySkips() {
        // Lead + AUTO → resolveEmailObjectName('Lead') = null → enrichWithEmailObject skipped.
        // No Lead records inserted so no tickets are attempted (Lead is not in the
        // Object_Type__c restricted picklist — this test only exercises the null-resolution path).
        Test.startTest();
        Database.executeBatch(
            new MergeScanBatch('Lead', new Set<String>{ 'Email' }, 'AUTO'), 200
        );
        Test.stopTest();

        System.assert(true,
            'Batch with AUTO and no qualifying email object for Lead must not throw');
    }

    @IsTest
    static void batch_crossDetect_contactDirectEmailAndEA_coversLine281() {
        // Covers line 281: buildMatchKey inside the direct-fields loop of
        // enrichWithEmailAddressObject — fires when a Contact with a non-blank direct
        // Email field is returned by the cross-check query.
        // Setup: cA has EA only; cB has direct Email only (no paired dup via direct scan).
        // In finish(), EA finds cA; cross-check query also returns cB (by email match).
        if (Schema.getGlobalDescribe().get('Email_Address__c') == null) {
            System.debug(LoggingLevel.WARN,
                'MergeScanServiceTest: Email_Address__c not deployed — skipping line-281 test');
            return;
        }

        Contact cA = new Contact(LastName = 'CrossEnrichA');
        Contact cB = new Contact(LastName = 'CrossEnrichB', Email = 'cross_enrich@scantest.com');
        insert new List<Contact>{ cA, cB };

        SObject ea = Schema.getGlobalDescribe().get('Email_Address__c').newSObject();
        ea.put('Contact__c', cA.Id);
        ea.put('Email__c',   'cross_enrich@scantest.com');
        insert ea;

        Test.startTest();
        Database.executeBatch(
            new MergeScanBatch('Contact', new Set<String>{ 'Email' }, 'Email_Address__c'), 200
        );
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Merge_Ticket__c
                                  WHERE Object_Type__c = 'Contact'],
            'Cross-detect: EA-only contact (cA) + direct-email contact (cB) = 1 ticket via line 281 path');
    }
}
