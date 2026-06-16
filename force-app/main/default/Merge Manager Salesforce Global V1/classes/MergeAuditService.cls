/**
 * MergeAuditService.cls
 * Creates and maintains immutable Merge_Log__c records for every merge action.
 *
 * Critical design contract — NO savepoints here, by design:
 *   The pre-merge log is inserted BEFORE the merge DML. If the merge throws,
 *   the log already exists with the full before-snapshot and can be updated
 *   with error details. Rolling back would destroy the audit trail.
 *
 * Calling sequence expected from MergeExecutionService:
 *   1. createPreMergeLog()    → insert log with before-snapshot, return log Id
 *   2. <execute merge DML>
 *   3a. recordMergeSuccess()  → update log with after-snapshot, set Action_Type = COMPLETED
 *   3b. recordMergeFailure()  → update log with error, set ticket Status = Error
 */
public without sharing class MergeAuditService {

    // ─── Pre-merge log ────────────────────────────────────────────────────────

    /**
     * Inserts a Merge_Log__c capturing the state of all candidates before the merge.
     * Must be called before any merge DML executes.
     */
    public static Merge_Log__c createPreMergeLog(
        Id               ticketId,
        String           objectType,
        Id               masterId,
        List<Id>         losingIds,
        List<SObject>    allCandidates,
        Map<String,String> fieldDecisions
    ) {
        // Bulk-capture snapshots: { recordIdString -> { fieldName -> value } }
        Map<String,Map<String,Object>> snapshots =
            SnapshotService.captureSnapshotsBulk(allCandidates);

        // ── Build human-readable fields ───────────────────────────────────────
        Set<Id> losingSet = new Set<Id>(losingIds);
        String   masterName    = '';
        List<String> losingNames   = new List<String>();
        List<String> summaryBlocks = new List<String>();

        // Key fields to include in the summary (shown when viewing the log)
        List<String> KEY_FIELDS = new List<String>{
            'Name','FirstName','LastName',
            'Email','MobilePhone','Phone',
            'AccountId','ID_Contact__c','ID_Prodon__c',
            'Birthdate','MailingStreet','MailingCity',
            'MailingState','MailingPostalCode','MailingCountry',
            'OwnerId','hed__AlternateEmail__c','hed__UniversityEmail__c'
        };

        for (SObject c : allCandidates) {
            String recId   = String.valueOf(c.Id);
            String recName = getFieldSafe(c, 'Name');
            if (recName == null) recName = recId;

            if (String.valueOf(masterId) == recId) {
                masterName = recName;
            } else if (losingSet.contains(c.Id)) {
                losingNames.add(recName);
                // Build the per-record block
                List<String> lines = new List<String>();
                lines.add('=== ' + recName + ' (' + recId + ') ===');
                for (String f : KEY_FIELDS) {
                    String v = getFieldSafe(c, f);
                    if (v != null) lines.add(f + ': ' + v);
                }
                summaryBlocks.add(String.join(lines, '\n'));
            }
        }

        Merge_Log__c log = new Merge_Log__c(
            Merge_Ticket__c           = ticketId,
            Object_Type__c            = objectType,
            Action_Type__c            = 'MERGE_PENDING',
            Master_Record_Id__c       = String.valueOf(masterId),
            Master_Record_Name__c     = abbreviateSafe(masterName, 255),
            Losing_Record_Ids__c      = JSON.serialize(losingIds),
            Losing_Record_Names__c    = abbreviateSafe(String.join(losingNames, '\n'), 2000),
            Losing_Records_Summary__c = String.join(summaryBlocks, '\n\n'),
            Before_Snapshot_JSON__c   = JSON.serialize(snapshots),
            Field_Decisions_JSON__c   = JSON.serialize(fieldDecisions),
            Performed_By__c           = UserInfo.getUserId(),
            Performed_Date__c         = System.now()
        );

        insert log;
        return log;
    }

    private static String getFieldSafe(SObject rec, String fieldName) {
        try {
            Object v = rec.get(fieldName);
            if (v == null) return null;
            String s = String.valueOf(v);
            return String.isBlank(s) ? null : s;
        } catch (Exception e) {
            return null;
        }
    }

    // ─── Post-merge updates ───────────────────────────────────────────────────

    /** Call after the merge DML succeeds. Re-queries master to capture final state. */
    public static void recordMergeSuccess(Id logId, SObject masterRecordAfter) {
        String afterJson   = SnapshotService.captureAndSerialize(masterRecordAfter);

        // Fetch the before snapshot to compute the diff
        Merge_Log__c existing = [
            SELECT Before_Snapshot_JSON__c FROM Merge_Log__c WHERE Id = :logId LIMIT 1
        ];
        Map<String,Object> before = SnapshotService.deserialize(existing.Before_Snapshot_JSON__c);
        // Before is a map of { recordId -> snapshotMap }; extract master's snapshot
        String masterId = (String) SnapshotService.deserialize(afterJson).get('Id');
        Map<String,Object> masterBefore = new Map<String,Object>();
        if (before.containsKey(masterId)) {
            masterBefore = (Map<String,Object>) before.get(masterId);
        }
        Map<String,Object> diff = SnapshotService.diffSnapshots(
            masterBefore,
            SnapshotService.deserialize(afterJson)
        );

        // Two separate updates: the validation rule blocks changing After_Snapshot_JSON__c
        // and Action_Type in the same DML when Action_Type ends up as MERGE_COMPLETED.
        // Fix: set snapshot/diff first (Action_Type still MERGE_PENDING), then seal it.
        update new Merge_Log__c(
            Id                      = logId,
            After_Snapshot_JSON__c  = afterJson,
            Field_Decisions_JSON__c = JSON.serialize(diff)
        );
        update new Merge_Log__c(
            Id             = logId,
            Action_Type__c = 'MERGE_COMPLETED'
        );
    }

    /**
     * Call when the merge throws. Updates log + ticket.
     * Uses allOrNone=false so one DML failure doesn't block the other.
     */
    public static void recordMergeFailure(Id logId, Id ticketId, String errorMessage) {
        List<SObject> toUpdate = new List<SObject>();

        if (logId != null) {
            toUpdate.add(new Merge_Log__c(
                Id             = logId,
                Action_Type__c = 'MERGE_ERROR'
            ));
        }

        if (ticketId != null) {
            toUpdate.add(new Merge_Ticket__c(
                Id              = ticketId,
                Status__c       = 'Error',
                Error_Message__c = abbreviateSafe(errorMessage, 32768)
            ));
        }

        if (!toUpdate.isEmpty()) {
            Database.update(toUpdate, false);
        }
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    private static String abbreviateSafe(String s, Integer maxLen) {
        if (String.isBlank(s)) return s;
        return s.length() <= maxLen ? s : s.substring(0, maxLen);
    }
}
