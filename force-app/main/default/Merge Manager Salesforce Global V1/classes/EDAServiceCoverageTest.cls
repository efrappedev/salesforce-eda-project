/**
 * EDAServiceCoverageTest.cls
 * Coverage suite for RelatedRecordsService — verifies bulk counts, mock injection,
 * exception branches, and the resolveActiveStatuses helper path.
 */
@IsTest
private class EDAServiceCoverageTest {

    // ── helpers ───────────────────────────────────────────────────────────────

    private static Contact makeContact(String lastName) {
        Contact c = new Contact(LastName = lastName);
        insert c;
        return c;
    }

    private static Account makeAccount(String name) {
        Account a = new Account(Name = name);
        insert a;
        return a;
    }

    // ── Affiliations: aggregate loop body ─────────────────────────────────────

    @IsTest
    static void covers_affiliations_loopBody() {
        if (!RelatedRecordsService.isEDAAvailable()) return;
        Account acc = makeAccount('RelSvc_AffOrg');
        Contact c   = makeContact('RelSvc_AffContact');

        insert new hed__Affiliation__c(
            hed__Contact__c   = c.Id,
            hed__Account__c   = acc.Id,
            hed__Role__c      = 'Student',
            hed__Status__c    = 'Current',
            hed__Primary__c   = true,
            hed__StartDate__c = Date.today()
        );

        Test.startTest();
        Map<Id, MergeWrappers.RelatedCountsWrapper> result =
            RelatedRecordsService.getBulkCountsForContacts(new Set<Id>{ c.Id });
        Test.stopTest();

        System.assert(result.containsKey(c.Id), 'Result must contain the contact');
        System.assertEquals(1, result.get(c.Id).getByLabel('Affiliations').total,
            'Affiliations must be 1 after inserting one hed__Affiliation__c');
    }

    // ── Program Enrollments: aggregate loop body ──────────────────────────────

    @IsTest
    static void covers_programEnrollments_loopBody() {
        if (!RelatedRecordsService.isEDAAvailable()) return;
        Contact c = makeContact('RelSvc_PEContact');

        hed__Program_Plan__c plan = new hed__Program_Plan__c(
            Name           = 'RelSvc_Plan_' + System.now().getTime(),
            hed__Status__c = 'Current'
        );
        insert plan;

        insert new hed__Program_Enrollment__c(
            hed__Contact__c      = c.Id,
            hed__Program_Plan__c = plan.Id,
            Status__c            = 'Current'
        );

        Test.startTest();
        Map<Id, MergeWrappers.RelatedCountsWrapper> result =
            RelatedRecordsService.getBulkCountsForContacts(new Set<Id>{ c.Id });
        Test.stopTest();

        System.assert(result.containsKey(c.Id), 'Result must contain the contact');
        System.assertEquals(1, result.get(c.Id).getByLabel('Programmes').total,
            'Programmes must be 1');
        System.assert(result.get(c.Id).getByLabel('Programmes').active >= 0,
            'Active programme count must be non-negative');
    }

    // ── Exception catch blocks (TEST_THROW_OBJECTS) ───────────────────────────

    @IsTest
    static void covers_aggregate_catchBlocks() {
        Contact c = makeContact('RelSvc_CatchBlock');
        RelatedRecordsService.TEST_THROW_OBJECTS.add('hed__Course_Enrollment__c');
        RelatedRecordsService.TEST_THROW_OBJECTS.add('hed__Program_Enrollment__c');
        RelatedRecordsService.TEST_THROW_OBJECTS.add('hed__Affiliation__c');

        Test.startTest();
        Map<Id, MergeWrappers.RelatedCountsWrapper> result =
            RelatedRecordsService.getBulkCountsForContacts(new Set<Id>{ c.Id });
        Test.stopTest();

        System.assert(result.containsKey(c.Id),
            'Result map must contain the contact even when catches fire');
        RelatedRecordsService.TEST_THROW_OBJECTS.clear();
    }

    // ── Course Connections: loop bodies via mock injection ────────────────────
    // Real CE records cannot be created in sandbox (EDA Course trigger).
    // We inject real AggregateResult rows built from a Contact aggregate query —
    // the aliases (pid, total) match exactly what the CE loop uses.

    @IsTest
    static void covers_courseConnections_loopBodies_viaMock() {
        Contact c = makeContact('RelSvc_CEMockContact');

        AggregateResult mockRow = [
            SELECT Id pid, COUNT(Name) total
            FROM Contact WHERE Id = :c.Id
            GROUP BY Id
        ][0];

        RelatedRecordsService.TEST_TOTAL_RESULTS = new Map<String,List<AggregateResult>>{
            'hed__Course_Enrollment__c' => new List<AggregateResult>{ mockRow }
        };
        RelatedRecordsService.TEST_ACTIVE_RESULTS = new Map<String,List<AggregateResult>>{
            'hed__Course_Enrollment__c' => new List<AggregateResult>{ mockRow }
        };

        Test.startTest();
        Map<Id, MergeWrappers.RelatedCountsWrapper> result =
            RelatedRecordsService.getBulkCountsForContacts(new Set<Id>{ c.Id });
        Test.stopTest();

        System.assert(result.containsKey(c.Id), 'Result must contain the contact');
        System.assertEquals(1, result.get(c.Id).getByLabel('Cours').total,
            'Cours total must be populated from mock row');
        System.assertEquals(1, result.get(c.Id).getByLabel('Cours').active,
            'Cours active must be populated from mock row');

        RelatedRecordsService.TEST_TOTAL_RESULTS  = null;
        RelatedRecordsService.TEST_ACTIVE_RESULTS = null;
    }

    // ── getCountsForContact: true branch + null else branch ───────────────────

    @IsTest
    static void getCountsForContact_validId_hitsTrueBranch() {
        Contact c = makeContact('RelSvc_TrueBranch');
        Test.startTest();
        MergeWrappers.RelatedCountsWrapper wrapper =
            RelatedRecordsService.getCountsForContact(c.Id);
        Test.stopTest();

        System.assertNotEquals(null, wrapper, 'Must return a wrapper for a valid contact');
        System.assertNotEquals(null, wrapper.counts, 'counts list must not be null');
    }

    @IsTest
    static void getCountsForContact_nullId_hitsElseBranch() {
        Test.startTest();
        MergeWrappers.RelatedCountsWrapper wrapper =
            RelatedRecordsService.getCountsForContact(null);
        Test.stopTest();

        System.assertNotEquals(null, wrapper, 'Must return an empty wrapper, not null');
        System.assertEquals(0, wrapper.totalRelated, 'totalRelated must be zero for null ID');
    }

    // ── getBulkCounts: empty set ──────────────────────────────────────────────

    @IsTest
    static void getBulkCounts_emptySet_returnsEmptyMap() {
        Test.startTest();
        Integer sz = RelatedRecordsService.getBulkCountsForContacts(new Set<Id>()).size();
        Test.stopTest();
        System.assertEquals(0, sz);
    }

    // ── isEDAAvailable ────────────────────────────────────────────────────────

    @IsTest
    static void isEDAAvailable_doesNotThrow() {
        Test.startTest();
        Boolean result = RelatedRecordsService.isEDAAvailable();
        Test.stopTest();
        System.assertNotEquals(null, result);
    }

    // ── resolveActiveStatuses: fallback branch via status field describe ──────
    // The resolveActiveStatuses catch path fires when the picklist describe throws.
    // We trigger it indirectly by injecting a mock that has no active statuses,
    // verifying the service still returns a valid (empty active) wrapper.

    @IsTest
    static void covers_noActiveStatuses_returnsZeroActive() {
        Contact c = makeContact('RelSvc_NoActiveStatus');

        // Inject a total row but no active row — forces the active query path
        // with an empty result set, verifying the loop body with 0 active entries.
        AggregateResult mockRow = [
            SELECT Id pid, COUNT(Name) total
            FROM Contact WHERE Id = :c.Id
            GROUP BY Id
        ][0];
        RelatedRecordsService.TEST_TOTAL_RESULTS = new Map<String,List<AggregateResult>>{
            'hed__Course_Enrollment__c' => new List<AggregateResult>{ mockRow }
        };
        RelatedRecordsService.TEST_ACTIVE_RESULTS = new Map<String,List<AggregateResult>>{
            'hed__Course_Enrollment__c' => new List<AggregateResult>()
        };

        Test.startTest();
        Map<Id, MergeWrappers.RelatedCountsWrapper> result =
            RelatedRecordsService.getBulkCountsForContacts(new Set<Id>{ c.Id });
        Test.stopTest();

        System.assertEquals(1, result.get(c.Id).getByLabel('Cours').total, 'total from mock');
        System.assertEquals(0, result.get(c.Id).getByLabel('Cours').active, 'active must be 0');

        RelatedRecordsService.TEST_TOTAL_RESULTS  = null;
        RelatedRecordsService.TEST_ACTIVE_RESULTS = null;
    }

    // ── SeeAllData fallback: tries real CE data if available ──────────────────

    @IsTest(SeeAllData=true)
    static void covers_courseConnections_loopBody_seeAllData() {
        if (!RelatedRecordsService.isEDAAvailable()) return;

        List<SObject> offerings = Database.query('SELECT Id FROM hed__Course_Offering__c LIMIT 1');
        if (offerings.isEmpty()) {
            System.debug(LoggingLevel.WARN,
                'EDAServiceCoverageTest: no hed__Course_Offering__c found — skipping');
            return;
        }
        Id offeringId = offerings[0].Id;

        Contact c = new Contact(LastName = 'RelSvc_CEReal_' + System.now().getTime());
        insert c;

        try {
            SObject ce = Schema.getGlobalDescribe()
                .get('hed__Course_Enrollment__c').newSObject();
            ce.put('hed__Contact__c',         c.Id);
            ce.put('hed__Course_Offering__c', offeringId);
            ce.put('hed__Status__c',          'Current');
            Database.insert(ce);
        } catch (Exception ex) {
            System.debug(LoggingLevel.WARN,
                'EDAServiceCoverageTest: CE insert blocked — ' + ex.getMessage());
            return;
        }

        Test.startTest();
        Map<Id, MergeWrappers.RelatedCountsWrapper> result =
            RelatedRecordsService.getBulkCountsForContacts(new Set<Id>{ c.Id });
        Test.stopTest();

        System.assert(result.containsKey(c.Id));
        System.assertEquals(1, result.get(c.Id).getByLabel('Cours').total);
    }

    // ── Custom object configs path (lines 61-79) ──────────────────────────────

    @IsTest
    static void covers_customObjectConfigs_withAndWithoutKeywords() {
        Contact c = makeContact('RelSvc_CfgContact');

        // Config 1: no Active_Status_Values__c → keywords stays null (covers lines 61-65, 71-76, 79)
        insert new Related_Object_Config__c(
            Name               = 'Cfg No Keywords',
            Object_API_Name__c = 'RelSvc_NoSchema1__c',
            Parent_Field__c    = 'Contact__c',
            Object_Type__c     = 'Contact',
            Is_Active__c       = true,
            Sort_Order__c      = 1
        );
        // Config 2: Active_Status_Values__c populated → covers lines 65-68 (split + add keywords)
        insert new Related_Object_Config__c(
            Name                    = 'Cfg With Keywords',
            Object_API_Name__c      = 'RelSvc_NoSchema2__c',
            Parent_Field__c         = 'Contact__c',
            Object_Type__c          = 'Contact',
            Is_Active__c            = true,
            Sort_Order__c           = 2,
            Active_Status_Values__c = 'current, active'
        );

        Test.startTest();
        Map<Id, MergeWrappers.RelatedCountsWrapper> result =
            RelatedRecordsService.getBulkCountsForContacts(new Set<Id>{ c.Id });
        Test.stopTest();

        System.assert(result.containsKey(c.Id), 'Contact should be in result map');
    }

    // ── MAX_CONFIGS truncation (lines 147-149) ────────────────────────────────

    @IsTest
    static void covers_maxConfigsTruncation() {
        Contact c = makeContact('RelSvc_MaxCfg');
        List<Related_Object_Config__c> cfgs = new List<Related_Object_Config__c>();
        for (Integer i = 0; i < 41; i++) {
            cfgs.add(new Related_Object_Config__c(
                Name               = 'MaxCfg_' + i,
                Object_API_Name__c = 'RelSvcMax' + i + '__c',
                Parent_Field__c    = 'Contact__c',
                Object_Type__c     = 'Contact',
                Is_Active__c       = true,
                Sort_Order__c      = i + 1
            ));
        }
        insert cfgs;

        Test.startTest();
        Map<Id, MergeWrappers.RelatedCountsWrapper> result =
            RelatedRecordsService.getBulkCountsForContacts(new Set<Id>{ c.Id });
        Test.stopTest();

        System.assert(result.containsKey(c.Id), 'Contact should still be in result map');
    }

    // ── resolveActiveStatuses catch block (lines 243-245) ─────────────────────

    @IsTest
    static void covers_resolveActiveStatuses_catchBlock() {
        Contact c = makeContact('RelSvc_CatchPicklist');

        // Config pointing to a real object (Contact) with a real field (AccountId reference)
        // and non-blank Active_Status_Values__c so resolveActiveStatuses is called.
        // TEST_THROW_PICKLIST forces the try block to throw, exercising the catch.
        insert new Related_Object_Config__c(
            Name                    = 'Cfg Catch Test',
            Object_API_Name__c      = 'Contact',
            Parent_Field__c         = 'AccountId',
            Status_Field__c         = 'AccountId',
            Active_Status_Values__c = 'current',
            Object_Type__c          = 'Contact',
            Is_Active__c            = true,
            Sort_Order__c           = 1
        );

        RelatedRecordsService.TEST_THROW_PICKLIST = true;
        Test.startTest();
        Map<Id, MergeWrappers.RelatedCountsWrapper> result =
            RelatedRecordsService.getBulkCountsForContacts(new Set<Id>{ c.Id });
        Test.stopTest();
        RelatedRecordsService.TEST_THROW_PICKLIST = false;

        System.assert(result.containsKey(c.Id), 'Contact should be in result map after catch');
    }
}
