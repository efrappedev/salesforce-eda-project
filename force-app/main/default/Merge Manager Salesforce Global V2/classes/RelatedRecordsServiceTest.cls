/**
 * RelatedRecordsServiceTest.cls
 * Coverage suite for RelatedRecordsService — verifies bulk counts, mock injection,
 * exception branches, and the resolveActiveStatuses helper path.
 */
@IsTest
private class RelatedRecordsServiceTest {

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

        SObject aff = Schema.getGlobalDescribe().get('hed__Affiliation__c').newSObject();
        aff.put('hed__Contact__c',   c.Id);
        aff.put('hed__Account__c',   acc.Id);
        aff.put('hed__Role__c',      'Student');
        aff.put('hed__Status__c',    'Current');
        aff.put('hed__Primary__c',   true);
        aff.put('hed__StartDate__c', Date.today());
        insert aff;

        Test.startTest();
        Map<Id, MergeWrappers.RelatedCountsWrapper> result =
            RelatedRecordsService.getBulkCountsForContacts(new Set<Id>{ c.Id });
        Test.stopTest();

        System.assert(result.containsKey(c.Id), 'Result must contain the contact');
        System.assertEquals(1, result.get(c.Id).getByLabel('Affiliations').total,
            'Affiliations must be 1 after inserting one affiliation');
    }

    // ── Program Enrollments: aggregate loop body ──────────────────────────────

    @IsTest
    static void covers_programEnrollments_loopBody() {
        if (!RelatedRecordsService.isEDAAvailable()) return;
        Contact c = makeContact('RelSvc_PEContact');

        SObject plan = Schema.getGlobalDescribe().get('hed__Program_Plan__c').newSObject();
        plan.put('Name',           'RelSvc_Plan_' + System.now().getTime());
        plan.put('hed__Status__c', 'Current');
        insert plan;

        SObject pe = Schema.getGlobalDescribe().get('hed__Program_Enrollment__c').newSObject();
        pe.put('hed__Contact__c',      c.Id);
        pe.put('hed__Program_Plan__c', plan.Id);
        pe.put('Status__c',            'Current');
        insert pe;

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

        insert new Related_Object_Config__c(
            Name               = 'Test Catch Case',
            Object_API_Name__c = 'Case',
            Parent_Field__c    = 'ContactId',
            Object_Type__c     = 'Contact',
            Is_Active__c       = true,
            Sort_Order__c      = 1
        );

        RelatedRecordsService.TEST_THROW_OBJECTS.add('Case');

        Test.startTest();
        Map<Id, MergeWrappers.RelatedCountsWrapper> result =
            RelatedRecordsService.getBulkCountsForContacts(new Set<Id>{ c.Id });
        Test.stopTest();

        System.assert(result.containsKey(c.Id),
            'Result map must contain the contact even when catches fire');
        RelatedRecordsService.TEST_THROW_OBJECTS.clear();
    }

    // ── Course Connections: loop bodies via mock injection ────────────────────
    // Real course enrollment records may be blocked by triggers in some orgs.
    // We inject real AggregateResult rows built from a Contact aggregate query —
    // the aliases (pid, total) match exactly what the CE loop uses.

    @IsTest
    static void covers_courseConnections_loopBodies_viaMock() {
        Contact c = makeContact('RelSvc_CEMockContact');

        // Use Case.ContactId — a standard relationship available in every Salesforce org.
        // Active_Status_Values__c = 'new' matches Case.Status 'New', so active query fires.
        insert new Related_Object_Config__c(
            Name                    = 'Test Cases',
            Object_API_Name__c      = 'Case',
            Parent_Field__c         = 'ContactId',
            Status_Field__c         = 'Status',
            Active_Status_Values__c = 'new',
            Object_Type__c          = 'Contact',
            Is_Active__c            = true,
            Sort_Order__c           = 1
        );

        AggregateResult mockRow = [
            SELECT Id pid, COUNT(Name) total
            FROM Contact WHERE Id = :c.Id
            GROUP BY Id
        ][0];

        RelatedRecordsService.TEST_TOTAL_RESULTS = new Map<String,List<AggregateResult>>{
            'Case' => new List<AggregateResult>{ mockRow }
        };
        RelatedRecordsService.TEST_ACTIVE_RESULTS = new Map<String,List<AggregateResult>>{
            'Case' => new List<AggregateResult>{ mockRow }
        };

        Test.startTest();
        Map<Id, MergeWrappers.RelatedCountsWrapper> result =
            RelatedRecordsService.getBulkCountsForContacts(new Set<Id>{ c.Id });
        Test.stopTest();

        System.assert(result.containsKey(c.Id), 'Result must contain the contact');
        System.assertEquals(1, result.get(c.Id).getByLabel('Test Cases').total,
            'total must be populated from mock row');
        System.assertEquals(1, result.get(c.Id).getByLabel('Test Cases').active,
            'active must be populated from mock row');

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

    // ── isRelatedDataAvailable ────────────────────────────────────────────────

    @IsTest
    static void isEDAAvailable_doesNotThrow() {
        Test.startTest();
        Boolean result = RelatedRecordsService.isEDAAvailable();
        Test.stopTest();
        System.assertNotEquals(null, result);
    }

    // ── resolveActiveStatuses: fallback branch via status field describe ──────

    @IsTest
    static void covers_noActiveStatuses_returnsZeroActive() {
        Contact c = makeContact('RelSvc_NoActiveStatus');

        // NOMATCH_9XZ won't match any Case.Status value → resolveActiveStatuses returns
        // empty set → active query never runs → active stays 0.
        insert new Related_Object_Config__c(
            Name                    = 'Test Cases No Active',
            Object_API_Name__c      = 'Case',
            Parent_Field__c         = 'ContactId',
            Status_Field__c         = 'Status',
            Active_Status_Values__c = 'NOMATCH_9XZ',
            Object_Type__c          = 'Contact',
            Is_Active__c            = true,
            Sort_Order__c           = 1
        );

        AggregateResult mockRow = [
            SELECT Id pid, COUNT(Name) total
            FROM Contact WHERE Id = :c.Id
            GROUP BY Id
        ][0];
        RelatedRecordsService.TEST_TOTAL_RESULTS = new Map<String,List<AggregateResult>>{
            'Case' => new List<AggregateResult>{ mockRow }
        };
        RelatedRecordsService.TEST_ACTIVE_RESULTS = new Map<String,List<AggregateResult>>{
            'Case' => new List<AggregateResult>()
        };

        Test.startTest();
        Map<Id, MergeWrappers.RelatedCountsWrapper> result =
            RelatedRecordsService.getBulkCountsForContacts(new Set<Id>{ c.Id });
        Test.stopTest();

        System.assertEquals(1, result.get(c.Id).getByLabel('Test Cases No Active').total, 'total from mock');
        System.assertEquals(0, result.get(c.Id).getByLabel('Test Cases No Active').active, 'active must be 0');

        RelatedRecordsService.TEST_TOTAL_RESULTS  = null;
        RelatedRecordsService.TEST_ACTIVE_RESULTS = null;
    }

    // ── Custom object configs path ────────────────────────────────────────────

    @IsTest
    static void covers_customObjectConfigs_withAndWithoutKeywords() {
        Contact c = makeContact('RelSvc_CfgContact');

        insert new Related_Object_Config__c(
            Name               = 'Cfg No Keywords',
            Object_API_Name__c = 'RelSvc_NoSchema1__c',
            Parent_Field__c    = 'Contact__c',
            Object_Type__c     = 'Contact',
            Is_Active__c       = true,
            Sort_Order__c      = 1
        );
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

    // ── MAX_CONFIGS truncation ────────────────────────────────────────────────

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

    // ── Account type: EDA fallback (Affiliations via hed__Account__c) ────────

    @IsTest
    static void getBulkCounts_accountType_returnsMappedAccount() {
        Account acc = makeAccount('RelSvc_AccType');

        Test.startTest();
        Map<Id, MergeWrappers.RelatedCountsWrapper> result =
            RelatedRecordsService.getBulkCounts(new Set<Id>{ acc.Id }, 'Account');
        Test.stopTest();

        System.assert(result.containsKey(acc.Id), 'Account should be in result map');
    }

    // ── resolveActiveStatuses catch block ─────────────────────────────────────

    @IsTest
    static void covers_resolveActiveStatuses_catchBlock() {
        Contact c = makeContact('RelSvc_CatchPicklist');

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
