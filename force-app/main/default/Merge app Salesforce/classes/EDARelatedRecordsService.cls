/**
 * EDARelatedRecordsService.cls
 * Queries EDA-related record counts for Contact candidates.
 *
 * Bulk design: all queries use AggregateResult + GROUP BY, so the cost is
 * always O(EDA_OBJECTS) SOQL queries, not O(candidates).
 *
 * EDA objects covered (hed namespace, confirmed installed in this org):
 *   hed__Course_Enrollment__c  — Course Connections
 *   hed__Program_Enrollment__c — Program Enrollments
 *   hed__Affiliation__c        — Affiliations
 *
 * Status field names confirmed from DegreeAuditMatrixController:
 *   Course Enrollment: hed__Status__c
 *   Program Enrollment: Status__c  (picklist driven by org config)
 */
public without sharing class EDARelatedRecordsService {

    // Cached to avoid repeated Schema.getGlobalDescribe() calls
    private static Boolean edaAvailable;

    // Active statuses — derived at runtime from picklist describe so they stay
    // in sync with org configuration without a code deployment.
    private static Set<String> activeCourseStatuses;
    private static Set<String> activeProgramStatuses;

    @TestVisible private static Boolean TEST_THROW_COURSE         = false;
    @TestVisible private static Boolean TEST_THROW_PROGRAM        = false;
    @TestVisible private static Boolean TEST_THROW_AFFILIATION    = false;
    @TestVisible private static Boolean TEST_THROW_COURSE_STATUS  = false;
    @TestVisible private static Boolean TEST_THROW_PROGRAM_STATUS = false;

    // ─── Public API ───────────────────────────────────────────────────────────

    public static Boolean isEDAAvailable() {
        if (edaAvailable == null) {
            edaAvailable = Schema.getGlobalDescribe().containsKey('hed__Course_Enrollment__c');
        }
        return edaAvailable;
    }

    /** Single-record convenience wrapper; delegates to bulk method. */
    public static MergeWrappers.EDACountsWrapper getCountsForContact(Id contactId) {
        Map<Id,MergeWrappers.EDACountsWrapper> result =
            getBulkCountsForContacts(new Set<Id>{ contactId });
        return result.containsKey(contactId)
            ? result.get(contactId)
            : new MergeWrappers.EDACountsWrapper();
    }

    /**
     * Returns EDA counts for every contact in the set.
     * Executes at most 5 aggregate SOQL queries regardless of set size.
     */
    public static Map<Id,MergeWrappers.EDACountsWrapper> getBulkCountsForContacts(
        Set<Id> contactIds
    ) {
        Map<Id,MergeWrappers.EDACountsWrapper> result = initResultMap(contactIds);

        if (!isEDAAvailable() || contactIds.isEmpty()) return result;

        aggregateCourseConnections(contactIds, result);
        aggregateProgramEnrollments(contactIds, result);
        aggregateAffiliations(contactIds, result);

        for (MergeWrappers.EDACountsWrapper counts : result.values()) {
            counts.computeDerived();
        }

        return result;
    }

    // ─── Aggregate queries ────────────────────────────────────────────────────

    private static void aggregateCourseConnections(
        Set<Id> contactIds,
        Map<Id,MergeWrappers.EDACountsWrapper> result
    ) {
        try {
            if (TEST_THROW_COURSE) throw new IllegalArgumentException('test-induced');
            for (AggregateResult ar : [
                SELECT hed__Contact__c cId, COUNT(Id) total
                FROM hed__Course_Enrollment__c
                WHERE hed__Contact__c IN :contactIds
                GROUP BY hed__Contact__c
            ]) {
                Id cId = (Id) ar.get('cId');
                result.get(cId).courseConnections = (Integer) ar.get('total');
            }

            Set<String> activeStatuses = getActiveCourseStatuses();
            for (AggregateResult ar : [
                SELECT hed__Contact__c cId, COUNT(Id) total
                FROM hed__Course_Enrollment__c
                WHERE hed__Contact__c IN :contactIds
                  AND hed__Status__c IN :activeStatuses
                GROUP BY hed__Contact__c
            ]) {
                Id cId = (Id) ar.get('cId');
                result.get(cId).activeCourseConnections = (Integer) ar.get('total');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'EDARelatedRecordsService [Course]: ' + e.getMessage());
        }
    }

    private static void aggregateProgramEnrollments(
        Set<Id> contactIds,
        Map<Id,MergeWrappers.EDACountsWrapper> result
    ) {
        try {
            if (TEST_THROW_PROGRAM) throw new IllegalArgumentException('test-induced');
            for (AggregateResult ar : [
                SELECT hed__Contact__c cId, COUNT(Id) total
                FROM hed__Program_Enrollment__c
                WHERE hed__Contact__c IN :contactIds
                GROUP BY hed__Contact__c
            ]) {
                Id cId = (Id) ar.get('cId');
                result.get(cId).programEnrollments = (Integer) ar.get('total');
            }

            Set<String> activeStatuses = getActiveProgramStatuses();
            for (AggregateResult ar : [
                SELECT hed__Contact__c cId, COUNT(Id) total
                FROM hed__Program_Enrollment__c
                WHERE hed__Contact__c IN :contactIds
                  AND Status__c IN :activeStatuses
                GROUP BY hed__Contact__c
            ]) {
                Id cId = (Id) ar.get('cId');
                result.get(cId).activeProgramEnrollments = (Integer) ar.get('total');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'EDARelatedRecordsService [ProgramEnrollment]: ' + e.getMessage());
        }
    }

    private static void aggregateAffiliations(
        Set<Id> contactIds,
        Map<Id,MergeWrappers.EDACountsWrapper> result
    ) {
        try {
            if (TEST_THROW_AFFILIATION) throw new IllegalArgumentException('test-induced');
            for (AggregateResult ar : [
                SELECT hed__Contact__c cId, COUNT(Id) total
                FROM hed__Affiliation__c
                WHERE hed__Contact__c IN :contactIds
                GROUP BY hed__Contact__c
            ]) {
                Id cId = (Id) ar.get('cId');
                result.get(cId).affiliations = (Integer) ar.get('total');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'EDARelatedRecordsService [Affiliation]: ' + e.getMessage());
        }
    }

    // ─── Active-status helpers (picklist-driven, cached) ─────────────────────

    @TestVisible
    private static Set<String> getActiveCourseStatuses() {
        if (activeCourseStatuses == null) {
            activeCourseStatuses = new Set<String>();
            try {
                if (TEST_THROW_COURSE_STATUS) throw new IllegalArgumentException('test-induced');
                Schema.DescribeFieldResult dfr =
                    hed__Course_Enrollment__c.hed__Status__c.getDescribe();
                for (Schema.PicklistEntry e : dfr.getPicklistValues()) {
                    // "Current" and "Enrolled" are the standard active values
                    String v = e.getValue();
                    if (e.isActive() && (v.containsIgnoreCase('Current') ||
                                         v.containsIgnoreCase('Enrolled') ||
                                         v.containsIgnoreCase('Registered'))) {
                        activeCourseStatuses.add(v);
                    }
                }
            } catch (Exception e) {
                activeCourseStatuses.add('Current');
            }
        }
        return activeCourseStatuses;
    }

    @TestVisible
    private static Set<String> getActiveProgramStatuses() {
        if (activeProgramStatuses == null) {
            activeProgramStatuses = new Set<String>();
            try {
                if (TEST_THROW_PROGRAM_STATUS) throw new IllegalArgumentException('test-induced');
                Schema.DescribeFieldResult dfr =
                    hed__Program_Enrollment__c.Status__c.getDescribe();
                for (Schema.PicklistEntry e : dfr.getPicklistValues()) {
                    String v = e.getValue();
                    if (e.isActive() && (v.containsIgnoreCase('Current') ||
                                         v.containsIgnoreCase('Enrolled') ||
                                         v.containsIgnoreCase('Applicant'))) {
                        activeProgramStatuses.add(v);
                    }
                }
            } catch (Exception e) {
                activeProgramStatuses.add('Current');
            }
        }
        return activeProgramStatuses;
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    private static Map<Id,MergeWrappers.EDACountsWrapper> initResultMap(Set<Id> contactIds) {
        Map<Id,MergeWrappers.EDACountsWrapper> result =
            new Map<Id,MergeWrappers.EDACountsWrapper>();
        for (Id cId : contactIds) {
            result.put(cId, new MergeWrappers.EDACountsWrapper());
        }
        return result;
    }
}
