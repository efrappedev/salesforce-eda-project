/**
 * DataUpdateAuditService.cls
 * Creates and maintains immutable Data_Update_Log__c records for every request action.
 * Modeled on MergeAuditService.cls, simplified for a single target record per request
 * (Data_Update_Request__c has no "candidates" to compare — unlike Merge_Request__c).
 *
 * Critical design contract — NO savepoints here, by design:
 *   The submit log is inserted BEFORE any field is ever changed on the target record.
 *   If the later apply throws, the log already exists with the full before-snapshot and
 *   can be updated with error details. Rolling back would destroy the audit trail.
 *
 * Calling sequence expected from DataUpdatePortalController / DataUpdateReviewController:
 *   1. createSubmitLog()      → insert log with before-snapshot, return log Id
 *   2. <execute apply DML>
 *   3a. recordApplySuccess()  → update log with after-snapshot + diff, Action_Type = APPLY_COMPLETED
 *   3b. recordApplyError()    → update log with error, set request Status = Error
 */
// CRUD/FLS: without sharing required to write audit logs regardless of ownership.
// Access restricted via Data_Update_Center_Access permission set.
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class DataUpdateAuditService {

    private static final String REQUEST_KEY_PREFIX = Data_Update_Request__c.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).getKeyPrefix();

    // ─── Submit log ───────────────────────────────────────────────────────────

    /**
     * Inserts a Data_Update_Log__c capturing the state of the target record at the
     * moment the request was submitted, before any field is ever changed.
     */
    public static Data_Update_Log__c createSubmitLog(
        Id     requestId,
        String objectType,
        Id     targetRecordId,
        SObject targetRecordBeforeState
    ) {
        Data_Update_Log__c log = new Data_Update_Log__c(
            Request__c                 = requestId,
            Action_Type__c            = 'SUBMIT_PENDING',
            Target_Object_API_Name__c = objectType,
            Target_Record_Id__c       = String.valueOf(targetRecordId),
            Before_Snapshot_JSON__c   = DataUpdateSnapshotService.captureAndSerialize(targetRecordBeforeState),
            Performed_By__c           = UserInfo.getUserId(),
            Performed_Date__c         = System.now()
        );
        insert log;
        return log;
    }

    // ─── Post-apply updates ───────────────────────────────────────────────────

    /**
     * Call after the apply DML succeeds. Re-queries the target record to capture final
     * state and computes the diff against the before-snapshot taken at submit time.
     *
     * selectedFieldValues: the field→value pairs the reviewer chose to apply (from
     * Proposed_Values_JSON__c), recorded alongside the actual before/after diff so the
     * log shows both "what was chosen" and "what actually changed".
     */
    public static void recordApplySuccess(
        Id     logId,
        SObject targetRecordAfter,
        Map<String,Object> selectedFieldValues
    ) {
        recordApplySuccess(logId, targetRecordAfter, selectedFieldValues, null);
    }

    /**
     * Same as above, plus ready-made decisions for keys that never live on the target record
     * (History_Only fields: their before/after can't come from a record snapshot, so the
     * caller builds them — value, date and the inserted history row's Id for rollback).
     */
    public static void recordApplySuccess(
        Id     logId,
        SObject targetRecordAfter,
        Map<String,Object> selectedFieldValues,
        Map<String,Object> extraDecisions
    ) {
        String afterJson = DataUpdateSnapshotService.captureAndSerialize(targetRecordAfter);

        Data_Update_Log__c existing = [
            SELECT Before_Snapshot_JSON__c FROM Data_Update_Log__c WHERE Id = :logId LIMIT 1
        ];
        Map<String,Object> before = DataUpdateSnapshotService.deserialize(existing.Before_Snapshot_JSON__c);
        Map<String,Object> diff   = DataUpdateSnapshotService.diffSnapshots(
            before,
            DataUpdateSnapshotService.deserialize(afterJson)
        );

        Map<String,Object> decisions = new Map<String,Object>();
        for (String fieldName : selectedFieldValues.keySet()) {
            decisions.put(fieldName, new Map<String,Object>{
                'selectedValue' => selectedFieldValues.get(fieldName),
                'diff'          => diff.get(fieldName)
            });
        }
        if (extraDecisions != null) {
            decisions.putAll(extraDecisions);
        }

        // Two separate updates: the validation rule blocks changing After_Snapshot_JSON__c
        // and Action_Type in the same DML once Action_Type ends up as APPLY_COMPLETED.
        // Fix: set snapshot/diff first (Action_Type still SUBMIT_PENDING), then seal it.
        // Performed_By__c/Performed_Date__c are overwritten here too: at insert time they held
        // the submitting guest user (same for every public submission, so no info is lost), but
        // for an APPLY_COMPLETED log they need to mean "who applied this", i.e. the staff member
        // running this transaction — that's what the audit trail UI displays.
        update new Data_Update_Log__c(
            Id                      = logId,
            After_Snapshot_JSON__c  = afterJson,
            Field_Decisions_JSON__c = JSON.serialize(decisions),
            Performed_By__c         = UserInfo.getUserId(),
            Performed_Date__c       = System.now()
        );
        update new Data_Update_Log__c(
            Id             = logId,
            Action_Type__c = 'APPLY_COMPLETED'
        );
    }

    /**
     * Call when the apply throws. Updates log + request.
     * Uses allOrNone=false so one DML failure doesn't block the other.
     */
    public static void recordApplyError(Id logId, Id requestId, String errorMessage) {
        List<SObject> toUpdate = new List<SObject>();

        if (logId != null) {
            toUpdate.add(new Data_Update_Log__c(
                Id                = logId,
                Action_Type__c    = 'APPLY_ERROR',
                Performed_By__c   = UserInfo.getUserId(),
                Performed_Date__c = System.now()
            ));
        }

        // requestId can carry a foreign-object prefix when the caller never resolved a real
        // Data_Update_Request__c (e.g. a not-found path) — constructing the SObject with a
        // mismatched Id throws System.TypeException, so guard on the key prefix first.
        if (requestId != null && String.valueOf(requestId).startsWith(REQUEST_KEY_PREFIX)) {
            toUpdate.add(new Data_Update_Request__c(
                Id               = requestId,
                Status__c        = 'Error',
                Error_Message__c = abbreviateSafe(errorMessage, 32768)
            ));
        }

        if (!toUpdate.isEmpty()) {
            Database.update(toUpdate, false);
        }
    }

    // ─── Rollback ─────────────────────────────────────────────────────────────

    /**
     * Inserts a new, already-complete Data_Update_Log__c for a rollback action.
     * Unlike recordApplySuccess(), this is a single insert: Prevent_Manual_Edit_
     * After_Completion only fires on update (NOT(ISNEW())), so there's no sealing
     * dance needed — the row is born immutable with Action_Type__c already set.
     */
    public static void recordRollback(
        Id     requestId,
        String objectType,
        Id     targetRecordId,
        SObject targetRecordBefore,
        SObject targetRecordAfter,
        Map<String,Object> restoredFieldValues
    ) {
        recordRollback(requestId, objectType, targetRecordId, targetRecordBefore, targetRecordAfter, restoredFieldValues, null);
    }

    /** Same as above, plus ready-made decisions for History_Only keys (see recordApplySuccess). */
    public static void recordRollback(
        Id     requestId,
        String objectType,
        Id     targetRecordId,
        SObject targetRecordBefore,
        SObject targetRecordAfter,
        Map<String,Object> restoredFieldValues,
        Map<String,Object> extraDecisions
    ) {
        String beforeJson = DataUpdateSnapshotService.captureAndSerialize(targetRecordBefore);
        String afterJson  = DataUpdateSnapshotService.captureAndSerialize(targetRecordAfter);
        Map<String,Object> diff = DataUpdateSnapshotService.diffSnapshots(
            DataUpdateSnapshotService.deserialize(beforeJson),
            DataUpdateSnapshotService.deserialize(afterJson)
        );

        Map<String,Object> decisions = new Map<String,Object>();
        for (String fieldName : restoredFieldValues.keySet()) {
            decisions.put(fieldName, new Map<String,Object>{
                'selectedValue' => restoredFieldValues.get(fieldName),
                'diff'          => diff.get(fieldName)
            });
        }
        if (extraDecisions != null) {
            decisions.putAll(extraDecisions);
        }

        insert new Data_Update_Log__c(
            Request__c                 = requestId,
            Action_Type__c            = 'ROLLBACK_COMPLETED',
            Target_Object_API_Name__c = objectType,
            Target_Record_Id__c       = String.valueOf(targetRecordId),
            Before_Snapshot_JSON__c   = beforeJson,
            After_Snapshot_JSON__c    = afterJson,
            Field_Decisions_JSON__c   = JSON.serialize(decisions),
            Performed_By__c           = UserInfo.getUserId(),
            Performed_Date__c         = System.now()
        );
    }

    // ─── Correction (staff edits a proposed value before applying) ────────────

    /**
     * Inserts a Data_Update_Log__c documenting that staff edited a proposed value in
     * Proposed_Values_JSON__c before it was ever applied — e.g. fixing a typo the contact
     * made on the public form. Unlike recordApplySuccess/recordRollback, the real target
     * record is never touched here, so there's no natural before/after state to snapshot;
     * Before_Snapshot_JSON__c and After_Snapshot_JSON__c are both set to the same current-
     * record snapshot purely to satisfy the Require_Before_Snapshot validation rule and the
     * required Target_Object_API_Name__c/Target_Record_Id__c fields. The actual old/new
     * values live in Field_Decisions_JSON__c, same shape as recordRollback(), so the History
     * tab renders it with zero changes to getAuditLog()'s decoding logic.
     */
    public static void recordCorrection(
        Id     requestId,
        String objectType,
        Id     targetRecordId,
        SObject targetRecordSnapshot,
        String fieldApiName,
        String oldValue,
        String newValue
    ) {
        String snapshotJson = DataUpdateSnapshotService.captureAndSerialize(targetRecordSnapshot);

        Map<String,Object> decisions = new Map<String,Object>{
            fieldApiName => new Map<String,Object>{
                'selectedValue' => newValue,
                'diff'          => new Map<String,Object>{ 'before' => oldValue, 'after' => newValue }
            }
        };

        insert new Data_Update_Log__c(
            Request__c                 = requestId,
            Action_Type__c            = 'CORRECTED',
            Target_Object_API_Name__c = objectType,
            Target_Record_Id__c       = String.valueOf(targetRecordId),
            Before_Snapshot_JSON__c   = snapshotJson,
            After_Snapshot_JSON__c    = snapshotJson,
            Field_Decisions_JSON__c   = JSON.serialize(decisions),
            Performed_By__c           = UserInfo.getUserId(),
            Performed_Date__c         = System.now()
        );
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    private static String abbreviateSafe(String s, Integer maxLen) {
        if (String.isBlank(s)) return s;
        return s.length() <= maxLen ? s : s.substring(0, maxLen);
    }
}
