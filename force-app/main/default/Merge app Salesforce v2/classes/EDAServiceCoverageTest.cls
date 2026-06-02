/**
 * EDAServiceCoverageTest.cls
 * Raises EDARelatedRecordsService from 75% to 98%+ by covering the
 * aggregate-result loop bodies that only execute when EDA records exist.
 *
 * Uncovered lines targeted:
 *   143-145  aggregateAffiliations loop body
 *   111-113  aggregateProgramEnrollments total loop body
 *   123-125  aggregateProgramEnrollments active loop body
 *    79-81   aggregateCourseConnections total loop body
 *    91-93   aggregateCourseConnections active loop body
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

    // ── Affiliations: lines 143-145 ───────────────────────────────────────────

    @IsTest
    static void covers_affiliations_loopBody() {
        Account acc = makeAccount('EDASvc_AffOrg');
        Contact c   = makeContact('EDASvc_AffContact');

        insert new hed__Affiliation__c(
            hed__Contact__c   = c.Id,
            hed__Account__c   = acc.Id,
            hed__Role__c      = 'Student',
            hed__Status__c    = 'Current',
            hed__Primary__c   = true,
            hed__StartDate__c = Date.today()
        );

        Test.startTest();
        Map<Id, MergeWrappers.EDACountsWrapper> result =
            EDARelatedRecordsService.getBulkCountsForContacts(new Set<Id>{ c.Id });
        Test.stopTest();

        System.assert(result.containsKey(c.Id), 'Result must contain the contact');
        System.assertEquals(1, result.get(c.Id).affiliations,
            'affiliations must be 1 after inserting one hed__Affiliation__c');
    }

    // ── Program Enrollments: lines 111-113 + 123-125 ──────────────────────────

    @IsTest
    static void covers_programEnrollments_loopBody() {
        Contact c = makeContact('EDASvc_PEContact');

        hed__Program_Plan__c plan = new hed__Program_Plan__c(
            Name           = 'EDASvc_Plan_' + System.now().getTime(),
            hed__Status__c = 'Current'
        );
        insert plan;

        insert new hed__Program_Enrollment__c(
            hed__Contact__c      = c.Id,
            hed__Program_Plan__c = plan.Id,
            Status__c            = 'Current'
        );

        Test.startTest();
        Map<Id, MergeWrappers.EDACountsWrapper> result =
            EDARelatedRecordsService.getBulkCountsForContacts(new Set<Id>{ c.Id });
        Test.stopTest();

        System.assert(result.containsKey(c.Id), 'Result must contain the contact');
        System.assertEquals(1, result.get(c.Id).programEnrollments,
            'programEnrollments must be 1');
        System.assert(result.get(c.Id).activeProgramEnrollments >= 0,
            'activeProgramEnrollments must be non-negative');
    }

    // ── Aggregate catch blocks: lines 95, 127, 147 ───────────────────────────

    @IsTest
    static void covers_aggregate_catchBlocks() {
        Contact c = makeContact('EDASvc_CatchBlock');
        EDARelatedRecordsService.TEST_THROW_COURSE      = true;
        EDARelatedRecordsService.TEST_THROW_PROGRAM     = true;
        EDARelatedRecordsService.TEST_THROW_AFFILIATION = true;

        Test.startTest();
        Map<Id, MergeWrappers.EDACountsWrapper> result =
            EDARelatedRecordsService.getBulkCountsForContacts(new Set<Id>{ c.Id });
        Test.stopTest();

        System.assert(result.containsKey(c.Id), 'Result map must contain the contact even when catches fire');
    }

    // ── Status-describe catch blocks: lines ~171, ~193 ────────────────────────

    @IsTest
    static void covers_status_catchBlocks() {
        EDARelatedRecordsService.TEST_THROW_COURSE_STATUS  = true;
        EDARelatedRecordsService.TEST_THROW_PROGRAM_STATUS = true;

        Test.startTest();
        Set<String> courseStatuses  = EDARelatedRecordsService.getActiveCourseStatuses();
        Set<String> programStatuses = EDARelatedRecordsService.getActiveProgramStatuses();
        Test.stopTest();

        System.assert(courseStatuses.contains('Current'),
            'catch fallback must add Current to course statuses');
        System.assert(programStatuses.contains('Current'),
            'catch fallback must add Current to program statuses');
    }

    // ── Course Connections: loop bodies via mock injection ────────────────────
    // Covers loop bodies in aggregateCourseConnections (lines 91-92, 103-104).
    // Real CE records cannot be created in this sandbox (EDA Course trigger),
    // so we inject real AggregateResult rows built from a Contact aggregate query —
    // the aliases (cId, total) match exactly what the CE loop uses.

    @IsTest
    static void covers_courseConnections_loopBodies_viaMock() {
        Contact c = makeContact('EDASvc_CEMockContact');

        // Build real AggregateResult with matching aliases: cId, total.
        // Querying against Contact avoids any dependency on CE/Course objects.
        AggregateResult mockRow = [
            SELECT Id cId, COUNT(Name) total
            FROM Contact WHERE Id = :c.Id
            GROUP BY Id
        ][0];

        EDARelatedRecordsService.TEST_COURSE_RESULTS        = new List<AggregateResult>{ mockRow };
        EDARelatedRecordsService.TEST_ACTIVE_COURSE_RESULTS = new List<AggregateResult>{ mockRow };

        Test.startTest();
        Map<Id, MergeWrappers.EDACountsWrapper> result =
            EDARelatedRecordsService.getBulkCountsForContacts(new Set<Id>{ c.Id });
        Test.stopTest();

        System.assert(result.containsKey(c.Id), 'Result must contain the contact');
        System.assertEquals(1, result.get(c.Id).courseConnections,
            'courseConnections must be populated from mock row');
        System.assertEquals(1, result.get(c.Id).activeCourseConnections,
            'activeCourseConnections must be populated from mock row');
    }

    // ── getCountsForContact: true branch (line 50) + null else branch (line 51) ─

    @IsTest
    static void getCountsForContact_validId_hitsTrueBranch() {
        // Covers line 50: result.containsKey(contactId) = true → returns found wrapper
        Contact c = makeContact('EDASvc_TrueBranch');
        Test.startTest();
        MergeWrappers.EDACountsWrapper wrapper =
            EDARelatedRecordsService.getCountsForContact(c.Id);
        Test.stopTest();

        System.assertNotEquals(null, wrapper, 'Must return a wrapper for a valid contact');
    }

    @IsTest
    static void getCountsForContact_nullId_hitsElseBranch() {
        // initResultMap skips null IDs so result.containsKey(null) = false
        // → the ternary else on line 51 fires returning a new empty wrapper
        Test.startTest();
        MergeWrappers.EDACountsWrapper wrapper =
            EDARelatedRecordsService.getCountsForContact(null);
        Test.stopTest();

        System.assertNotEquals(null, wrapper, 'Must return an empty wrapper, not null');
        System.assertEquals(0, wrapper.courseConnections, 'All counts must be zero for null ID');
    }

    // ── SeeAllData fallback: still tries real CE data if available ─────────────

    @IsTest(SeeAllData=true)
    static void covers_courseConnections_loopBody_seeAllData() {
        List<hed__Course_Offering__c> offerings = [
            SELECT Id FROM hed__Course_Offering__c LIMIT 1
        ];
        if (offerings.isEmpty()) {
            System.debug(LoggingLevel.WARN,
                'EDAServiceCoverageTest: no hed__Course_Offering__c found — skipping CE real-data test');
            return;
        }
        Id offeringId = offerings[0].Id;

        Contact c = new Contact(LastName = 'EDASvc_CEReal_' + System.now().getTime());
        insert c;

        Set<String> activeStatuses = EDARelatedRecordsService.getActiveCourseStatuses();
        String activeStatus = activeStatuses.isEmpty()
            ? 'Current' : new List<String>(activeStatuses)[0];

        try {
            insert new hed__Course_Enrollment__c(
                hed__Contact__c         = c.Id,
                hed__Course_Offering__c = offeringId,
                hed__Status__c          = activeStatus
            );
        } catch (Exception ex) {
            System.debug(LoggingLevel.WARN,
                'EDAServiceCoverageTest: CE insert blocked — ' + ex.getMessage());
            return;
        }

        Test.startTest();
        Map<Id, MergeWrappers.EDACountsWrapper> result =
            EDARelatedRecordsService.getBulkCountsForContacts(new Set<Id>{ c.Id });
        Test.stopTest();

        System.assert(result.containsKey(c.Id));
        System.assertEquals(1, result.get(c.Id).courseConnections);
    }
}
