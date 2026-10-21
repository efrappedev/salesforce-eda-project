/**
 * MergeExecutionService.cls
 * Executes the native Salesforce merge DML with a full audit trail.
 *
 * Execution sequence (see executeMerge):
 *   1.  Validate inputs.
 *   2.  Derive object type from ticket.
 *   3.  Load all candidate records with the comparison field set.
 *   4.  Insert pre-merge audit log  ← BEFORE any merge DML (critical).
 *   5.  Apply field decisions to the master SObject in memory.
 *   6.  Reparent EDA-specific + standard SF related records to master,
 *       then Database.delete() losers (no MasterRecordId → undelete works in undoMerge).
 *   7.  Re-query master for after-snapshot.
 *   8.  Update log (success) and ticket (Merged).
 *   On any exception: update log + ticket with error details; NO rollback so
 *   the pre-merge snapshot persists.
 *
 * Database.delete() (not Database.merge()) is used so the loser is soft-deleted
 * WITHOUT MasterRecordId, enabling Database.undelete in undoMerge().
 */
// CRUD/FLS: without sharing required for merge DML across record ownership boundaries.
// Access restricted to authorized admins via Merge_Manager_Access permission set.
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class MergeExecutionService {

    // Test-injection flags — always false in production; set by test classes to cover catch blocks
    @TestVisible private static Boolean TEST_THROW_FIELD_PUT           = false;
    @TestVisible private static Boolean TEST_THROW_LOSER_ACCOUNTID     = false;
    @TestVisible private static Boolean TEST_THROW_MASTER_ACCOUNTID    = false;
    // Forces validateObjectType to throw so the MergeException branch is covered in tests
    @TestVisible private static Boolean TEST_FORCE_INVALID_OBJECT_TYPE = false;
    // Forces the inner ticket-update to throw so catch(Exception ignored) on that line is covered
    @TestVisible private static Boolean TEST_THROW_ERROR_STAMP         = false;
    // Forces validateMergePermissions to deny, covering the throw branch (no test user lacks CRUD by default)
    @TestVisible private static Boolean TEST_FORCE_MERGE_PERMISSION_DENIED = false;
    // Forces catch blocks in Task/Event/CampaignMember reparenting
    @TestVisible private static Boolean TEST_THROW_TASK_REPARENT   = false;
    @TestVisible private static Boolean TEST_THROW_EVENT_REPARENT  = false;
    @TestVisible private static Boolean TEST_THROW_CM_REPARENT     = false;
    // Forces master-field update failure (covers lines 113-114 + buildErrorMsg)
    @TestVisible private static Boolean TEST_FORCE_MASTER_UPDATE_FAIL = false;
    // Forces loser-delete failure (covers line 256 + buildErrorMsg loop body via dummy DML)
    @TestVisible private static Boolean TEST_FORCE_DELETE_LOSER_FAIL  = false;
    // Forces captureLoserRelatedIds to return null (covers lines 198, 202, and 791)
    @TestVisible private static Boolean TEST_FORCE_NULL_CAPTURE_RESULT  = false;
    // Forces throw inside captureLoserRelatedIds SOQL try block (covers line 732)
    @TestVisible private static Boolean TEST_THROW_CAPTURE_QUERY        = false;
    // Forces throw inside reparentAndDeleteLosers EDA for-loop try block (covers line 218)
    @TestVisible private static Boolean TEST_THROW_REPARENT_EDA_LOOP    = false;
    // Forces the dr.getErrors() branch when delete technically succeeded (covers line 269)
    @TestVisible private static Boolean TEST_FORCE_DELETE_DR_FAIL       = false;
    // Forces throw inside applyRelatedDeletes for-loop try block (covers line 779)
    @TestVisible private static Boolean TEST_THROW_APPLY_DELETES_LOOP   = false;
    // Forces invalid existingJson in appendDeletedIdsToLog (covers lines 793-794)
    @TestVisible private static Boolean TEST_FORCE_INVALID_APPEND_JSON  = false;
    // Forces update to throw in appendDeletedIdsToLog (covers line 838)
    @TestVisible private static Boolean TEST_THROW_APPEND_LOG_UPDATE    = false;
    // Overrides the dynamic SOQL budget in captureLoserRelatedIds (for test coverage of cap path)
    @TestVisible private static Integer TEST_SOQL_CAP_OVERRIDE          = null;
    // Forces the real-SOQL-budget break path in captureLoserRelatedIds (covers break on budget ≤25)
    @TestVisible private static Boolean TEST_FORCE_SOQL_BUDGET_HIT      = false;

    // ─── Public API ───────────────────────────────────────────────────────────

    public static MergeWrappers.MergeResult executeMerge(MergeWrappers.MergeRequest request) {
        MergeWrappers.MergeResult result = new MergeWrappers.MergeResult();
        Id auditLogId;

        try {
            // ── 1. Validate ───────────────────────────────────────────────────
            validateRequest(request);

            Id            ticketId             = (Id) request.ticketId;
            Id            masterId             = (Id) request.masterId;
            List<Id>      losingIds            = toIdList(request.losingIds);
            List<Contact> losingAccountContacts = new List<Contact>();

            // ── 2. Derive object type from ticket ─────────────────────────────
            String objectType = TEST_FORCE_INVALID_OBJECT_TYPE ? '__Invalid__' : getObjectType(ticketId);
            validateObjectType(objectType);
            validateMergePermissions(objectType);

            // ── 3. Load all candidates with comparison fields ─────────────────
            Set<Id> allIds = new Set<Id>{ masterId };
            allIds.addAll(losingIds);
            List<SObject>  candidates   = loadCandidates(objectType, allIds);
            Map<Id,SObject> candidateMap = indexById(candidates);

            if (!candidateMap.containsKey(masterId)) {
                throw new MergeException('Master record not found: ' + masterId);
            }

            // ── 3b. Pre-capture contacts on losing Accounts before merge re-parents them ──
            if (objectType == 'Account') {
                losingAccountContacts = [
                    SELECT Id, Name, Email, Phone
                    FROM Contact
                    WHERE AccountId IN :losingIds
                ];
            }

            // ── 3c. Capture related record IDs for each loser (for undo snapshot) ──
            String relatedRecordsJson = captureLoserRelatedIds(losingIds, objectType);

            // ── 4. Pre-merge audit log (inserted BEFORE merge DML) ────────────
            Merge_Log__c auditLog = MergeAuditService.createPreMergeLog(
                ticketId, objectType, masterId, losingIds,
                candidates, request.fieldDecisions, relatedRecordsJson
            );
            auditLogId = auditLog.Id;

            // ── 5. Build field overrides for master ───────────────────────────
            Map<String,Schema.SObjectField> fieldMap =
                Schema.getGlobalDescribe().get(objectType)?.getDescribe()?.fields?.getMap();
            SObject masterOverride = Schema.getGlobalDescribe()
                .get(objectType).newSObject(masterId);
            applyFieldDecisions(masterOverride, candidateMap, request.fieldDecisions, fieldMap);
            applyEmailRescues(masterOverride, candidateMap, request.emailRescues, fieldMap);

            // ── 6. Reparent related records to master, then soft-delete losers ─
            // NOTE: losers are deleted BEFORE applying field decisions (step 5c below).
            // This is intentional: unique fields (like ID_Prodon_contact__c) cannot be
            // written to the master while the loser still holds the same value. Deleting
            // the loser first frees the unique constraint. The loser's field values are
            // already captured in candidateMap (in-memory) so applyFieldDecisions works.
            reparentAndDeleteLosers(losingIds, objectType, masterId, relatedRecordsJson);

            // ── 5c. Apply field decisions to master via explicit UPDATE ───────
            Map<String,Object> masterOverrideFields = masterOverride.getPopulatedFieldsAsMap();
            if (masterOverrideFields.size() > 1) {
                List<Database.SaveResult> srs = Database.update(
                    new List<SObject>{ masterOverride }, false
                );
                if (!srs.isEmpty() && (!srs[0].isSuccess() || TEST_FORCE_MASTER_UPDATE_FAIL)) {
                    throw new MergeException('Master field update failed: '
                        + buildErrorMsg(srs[0].getErrors()));
                }
            }

            // ── 6b. Apply user's related-record delete decisions ──────────────
            List<Id> deletedRelatedIds = applyRelatedDeletes(request.relatedDeletesJson);

            // ── 7. Re-query master for after-snapshot ─────────────────────────
            SObject masterAfter = reloadRecord(objectType, masterId);

            // ── 8. Finalize audit log and ticket ──────────────────────────────
            MergeAuditService.recordMergeSuccess(auditLogId, masterAfter);
            if (!deletedRelatedIds.isEmpty()) {
                appendDeletedIdsToLog(auditLogId, relatedRecordsJson, deletedRelatedIds);
            }
            closeTicket(ticketId, masterId, request.notes);

            result.success        = true;
            result.logId          = String.valueOf(auditLogId);
            result.mergedRecordId = String.valueOf(masterId);

            // ── 9. Detect orphaned Accounts (Contact merges only) ─────────────
            if (objectType == 'Contact') {
                result.orphanedAccounts = detectOrphanedAccounts(
                    losingIds, masterId, candidateMap
                );
            }

            // ── 10. Detect orphaned Contacts (Account merges only) ────────────
            if (objectType == 'Account' && !losingAccountContacts.isEmpty()) {
                result.orphanedContacts = buildOrphanedContactInfo(losingAccountContacts);
            }

            // ── 11. Delete other tickets whose candidates reference the losing records ──
            // After a successful merge the losing records no longer exist in Salesforce.
            // Any other ticket that listed one of those records as a candidate is now
            // unresolvable — delete them to keep the ticket list clean.
            result.cleanedUpTicketCount = cleanupOrphanedTickets(ticketId, losingIds);

        } catch (Exception e) {
            String errorMsg = e.getMessage() + '\n\nStack:\n' + e.getStackTraceString();
            MergeAuditService.recordMergeFailure(
                auditLogId, (Id) request.ticketId, errorMsg
            );
            // Also stamp the error on the ticket so it's visible without opening the Log
            try {
                if (TEST_THROW_ERROR_STAMP) throw new DmlException('test-induced');
                Merge_Ticket__c errTkt = [SELECT Notes__c FROM Merge_Ticket__c WHERE Id = :(Id)request.ticketId LIMIT 1];
                String errNotes = buildHistNotes(errTkt.Notes__c, 'Error', e.getMessage().left(200), null);
                update new Merge_Ticket__c(
                    Id               = (Id) request.ticketId,
                    Status__c        = 'Error',
                    Error_Message__c = e.getMessage().left(32000),
                    Notes__c         = errNotes
                );
            } catch (Exception ignored) {}
            result.success      = false;
            result.errorMessage = e.getMessage();
        }

        return result;
    }

    // ─── Merge execution ──────────────────────────────────────────────────────

    // Reparents EDA-specific and standard SF related records from losers to master,
    // then soft-deletes the losers WITHOUT MasterRecordId so Database.undelete works
    // in undoMerge().
    private static void reparentAndDeleteLosers(
        List<Id> losingIds, String objectType, Id masterId, String relatedJson
    ) {
        Set<Id> losingIdSet = new Set<Id>(losingIds);
        Map<String,Schema.SObjectType> gd = Schema.getGlobalDescribe();

        // ── A: Reparent EDA-specific objects (snapshot captured pre-merge) ───
        Map<String,Object> relatedMap = String.isBlank(relatedJson)
            ? new Map<String,Object>()
            : (Map<String,Object>) JSON.deserializeUntyped(relatedJson);
        List<Object> reparentedEntries = relatedMap.containsKey('reparented')
            ? (List<Object>) relatedMap.get('reparented')
            : new List<Object>();
        for (Object rawEntry : reparentedEntries) {
            Map<String,Object> entry = (Map<String,Object>) rawEntry;
            String objApiName  = (String) entry.get('obj');
            String lookupField = (String) entry.get('field');
            List<Object> rawIds = (List<Object>) entry.get('ids');
            if (rawIds == null || rawIds.isEmpty()) continue;
            if (!gd.containsKey(objApiName.toLowerCase())) continue;
            Set<Id> recIdSet = new Set<Id>();
            for (Object o : rawIds) recIdSet.add((Id) String.valueOf(o));
            try {
                if (TEST_THROW_REPARENT_EDA_LOOP) throw new System.QueryException('test-reparent-eda');
                Schema.SObjectType sot = gd.get(objApiName.toLowerCase());
                List<SObject> recs = new List<SObject>();
                for (Id recId : recIdSet) {
                    SObject r = sot.newSObject(recId);
                    r.put(lookupField, masterId);
                    recs.add(r);
                }
                if (!recs.isEmpty()) Database.update(recs, false);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'reparentAndDeleteLosers EDA [' + objApiName + ']: ' + e.getMessage());
            }
        }

        // ── B: Reparent standard SF activity / membership records ─────────────
        if (objectType == 'Contact') {
            try {
                if (TEST_THROW_TASK_REPARENT) throw new System.QueryException('test-task');
                List<Task> tasks = [SELECT Id FROM Task WHERE WhoId IN :losingIdSet];
                for (Task t : tasks) t.WhoId = masterId;
                if (!tasks.isEmpty()) Database.update(tasks, false);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'reparentAndDeleteLosers Task: ' + e.getMessage());
            }
            try {
                if (TEST_THROW_EVENT_REPARENT) throw new System.QueryException('test-event');
                List<Event> events = [SELECT Id FROM Event WHERE WhoId IN :losingIdSet];
                for (Event ev : events) ev.WhoId = masterId;
                if (!events.isEmpty()) Database.update(events, false);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'reparentAndDeleteLosers Event: ' + e.getMessage());
            }
            try {
                if (TEST_THROW_CM_REPARENT) throw new System.QueryException('test-cm');
                List<CampaignMember> cms = [
                    SELECT Id FROM CampaignMember WHERE ContactId IN :losingIdSet
                ];
                for (CampaignMember cm : cms) cm.ContactId = (Id) String.valueOf(masterId);
                if (!cms.isEmpty()) Database.update(cms, false);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'reparentAndDeleteLosers CampaignMember: ' + e.getMessage());
            }
        }

        // ── C: Soft-delete losers (MasterRecordId stays null → undelete works) ─
        List<SObject> losers = Database.query(
            'SELECT Id FROM ' + String.escapeSingleQuotes(objectType) + ' WHERE Id IN :losingIdSet'
        );
        if (losers.size() < losingIdSet.size()) {
            throw new MergeException(
                'Loser record(s) not found — may already be deleted or inaccessible.'
            );
        }
        List<Database.DeleteResult> drs = Database.delete(losers, false);
        for (Database.DeleteResult dr : drs) {
            if (!dr.isSuccess() || TEST_FORCE_DELETE_LOSER_FAIL || TEST_FORCE_DELETE_DR_FAIL) {
                List<Database.Error> errs = (TEST_FORCE_DELETE_LOSER_FAIL && dr.isSuccess())
                    ? Database.insert(new Contact(), false).getErrors()
                    : dr.getErrors();
                throw new MergeException(buildErrorMsg(errs));
            }
        }
    }

    /**
     * Iterates the fieldDecisions map and copies the chosen value from the
     * source candidate into the master SObject (in memory only — no DML yet).
     * Salesforce will persist these values when Database.merge() executes.
     */
    private static void applyFieldDecisions(
        SObject mergeTemplate,
        Map<Id,SObject> candidateMap,
        Map<String,String> fieldDecisions,
        Map<String,Schema.SObjectField> fieldMap
    ) {
        if (fieldDecisions == null || fieldDecisions.isEmpty()) return;

        for (String fieldName : fieldDecisions.keySet()) {
            String sourceIdStr = fieldDecisions.get(fieldName);
            if (String.isBlank(sourceIdStr)) continue;

            Id sourceId = (Id) sourceIdStr;
            if (sourceId == mergeTemplate.Id) continue;

            // EDA preference fields are handled by fixEdaPreferenceFields with language remapping.
            // Excluding them here prevents the merge template from carrying a stale English value.
            String fl = fieldName.toLowerCase();
            if (fl == 'hed__preferredphone__c' || fl == 'hed__preferred_email__c') continue;

            // Skip fields that Salesforce won't allow to be updated
            if (fieldMap != null) {
                if (!fieldMap.containsKey(fl)) continue;
                if (!fieldMap.get(fl).getDescribe().isUpdateable()) continue;
            }

            SObject source = candidateMap.get(sourceId);
            if (source == null) continue;

            try {
                if (TEST_THROW_FIELD_PUT) throw new SObjectException('test-induced');
                mergeTemplate.put(fieldName, source.get(fieldName));
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'MergeExecution: skip field ' + fieldName + ': ' + e.getMessage());
            }
        }
    }

    // ─── SOQL helpers ─────────────────────────────────────────────────────────

    private static List<SObject> loadCandidates(String objectType, Set<Id> ids) {
        List<String> fields = getComparisonFields(objectType);
        String q = 'SELECT ' + String.join(fields, ', ') +
                   ' FROM ' + String.escapeSingleQuotes(objectType) + ' WHERE Id IN :ids';
        return Database.query(q); // NOPMD — objectType escaped; fields validated via Schema.getGlobalDescribe()
    }

    private static SObject reloadRecord(String objectType, Id recordId) {
        List<String> fields = getComparisonFields(objectType);
        String q = 'SELECT ' + String.join(fields, ', ') +
                   ' FROM ' + String.escapeSingleQuotes(objectType) + ' WHERE Id = :recordId LIMIT 1';
        List<SObject> rows = Database.query(q); // NOPMD — objectType escaped; fields validated via Schema.getGlobalDescribe()
        return rows.isEmpty() ? null : rows[0];
    }

    // Reuse MergeTicketService's field logic to stay consistent
    private static Map<String,List<String>> QUERY_FIELDS_CACHE =
        new Map<String,List<String>>();

    private static List<String> getComparisonFields(String objectType) {
        if (QUERY_FIELDS_CACHE.containsKey(objectType)) {
            return QUERY_FIELDS_CACHE.get(objectType);
        }

        Map<String,Schema.SObjectField> fieldMap =
            Schema.getGlobalDescribe().get(objectType)
                  ?.getDescribe()?.fields?.getMap();

        Set<String> fields = new Set<String>{ 'Id', 'Name' };
        if (fieldMap != null) {
            for (String f : fieldMap.keySet()) {
                Schema.DescribeFieldResult dfr = fieldMap.get(f).getDescribe();
                // Include accessible, non-calculated, non-compound fields
                if (dfr.isAccessible() && !dfr.isCalculated() &&
                    dfr.getType() != Schema.DisplayType.ADDRESS &&
                    dfr.getType() != Schema.DisplayType.LOCATION) {
                    fields.add(dfr.getName());
                }
            }
        }

        List<String> result = new List<String>(fields);
        QUERY_FIELDS_CACHE.put(objectType, result);
        return result;
    }

    // ─── Ticket / log helpers ─────────────────────────────────────────────────

    private static String getObjectType(Id ticketId) {
        return [
            SELECT Object_Type__c FROM Merge_Ticket__c WHERE Id = :ticketId LIMIT 1
        ].Object_Type__c;
    }

    private static void closeTicket(Id ticketId, Id masterId, String notes) {
        Merge_Ticket__c current = [SELECT Notes__c FROM Merge_Ticket__c WHERE Id = :ticketId LIMIT 1];
        String newNotes = buildHistNotes(current.Notes__c, 'Merged', null, notes);
        update new Merge_Ticket__c(
            Id                    = ticketId,
            Status__c             = 'Merged',
            Selected_Master_Id__c = String.valueOf(masterId),
            Final_Action__c       = 'Merged',
            Notes__c              = newNotes
        );
    }

    private static String buildHistNotes(String existingNotes, String histStatus, String reason, String activeNotes) {
        List<String> histLines = new List<String>();
        if (!String.isBlank(existingNotes)) {
            for (String line : existingNotes.split('\n')) {
                if (line.startsWith('[HIST:')) histLines.add(line);
            }
        }
        String encNotes   = String.isBlank(activeNotes) ? '' : activeNotes.replace('\n', '\\n');
        String safeReason = reason != null ? reason : '';
        String dateStr    = String.valueOf(System.now()).substring(0, 10);
        String histEntry  = '[HIST:' + histStatus + '|||' + safeReason + '|||' + encNotes + '|||' + dateStr + ']';
        List<String> combined = new List<String>{ histEntry };
        combined.addAll(histLines);
        String histStr = String.join(combined, '\n');
        return String.isBlank(activeNotes) ? histStr : activeNotes + '\n' + histStr;
    }

    // ─── Validation ───────────────────────────────────────────────────────────

    private static final Set<String> ALLOWED_OBJECT_TYPES =
        new Set<String>{ 'Contact', 'Account' };

    private static void validateRequest(MergeWrappers.MergeRequest request) {
        if (String.isBlank(request.ticketId)) {
            throw new MergeException('ticketId is required.');
        }
        if (String.isBlank(request.masterId)) {
            throw new MergeException('masterId is required.');
        }
        if (request.losingIds == null || request.losingIds.isEmpty()) {
            throw new MergeException('At least one losingId is required.');
        }
        if (request.losingIds.contains(request.masterId)) {
            throw new MergeException('masterId cannot also appear in losingIds.');
        }
    }

    // Called after objectType is derived from the ticket — guards against
    // unexpected values before it reaches the dynamic SOQL FROM clause.
    private static void validateObjectType(String objectType) {
        if (!ALLOWED_OBJECT_TYPES.contains(objectType)) {
            throw new MergeException('Unsupported object type: ' + objectType);
        }
    }

    // Database.merge() runs in system mode and does not enforce the running
    // user's CRUD permissions on its own — Apex DML bypasses FLS/CRUD by default.
    // A merge both updates the master and deletes the losers, so both
    // permissions must be explicitly checked before the merge DML executes.
    private static void validateMergePermissions(String objectType) {
        Schema.DescribeSObjectResult describe =
            Schema.getGlobalDescribe().get(objectType).getDescribe();
        if (TEST_FORCE_MERGE_PERMISSION_DENIED || !describe.isUpdateable() || !describe.isDeletable()) {
            throw new MergeException(
                'Insufficient permissions to merge ' + objectType + ' records.'
            );
        }
    }

    // ─── Misc helpers ─────────────────────────────────────────────────────────

    private static List<Id> toIdList(List<String> strings) {
        List<Id> ids = new List<Id>();
        for (String s : strings) {
            if (!String.isBlank(s)) ids.add((Id) s);
        }
        return ids;
    }

    private static Map<Id,SObject> indexById(List<SObject> records) {
        Map<Id,SObject> m = new Map<Id,SObject>();
        for (SObject r : records) m.put(r.Id, r);
        return m;
    }

    @TestVisible private static String buildErrorMsg(List<Database.Error> errors) {
        List<String> parts = new List<String>();
        for (Database.Error err : errors) {
            parts.add(err.getStatusCode() + ': ' + err.getMessage());
        }
        return String.join(parts, ' | ');
    }

    // ─── Orphaned Account detection ───────────────────────────────────────────

    private static List<MergeWrappers.OrphanedAccountInfo> detectOrphanedAccounts(
        List<Id>         losingIds,
        Id               masterId,
        Map<Id,SObject>  candidateMap
    ) {
        // Collect AccountIds from losing contacts (pre-merge snapshot still in map)
        Set<Id> losingAccountIds = new Set<Id>();
        for (Id losingId : losingIds) {
            SObject rec = candidateMap.get(losingId);
            if (rec == null) continue;
            try {
                if (TEST_THROW_LOSER_ACCOUNTID) throw new SObjectException('test-induced');
                Id accId = (Id) rec.get('AccountId');
                if (accId != null) losingAccountIds.add(accId);
            } catch (Exception e) { /* field not accessible */ }
        }

        if (losingAccountIds.isEmpty()) return new List<MergeWrappers.OrphanedAccountInfo>();

        // Exclude master's own Account (not orphaned)
        SObject masterRec = candidateMap.get(masterId);
        if (masterRec != null) {
            try {
                if (TEST_THROW_MASTER_ACCOUNTID) throw new SObjectException('test-induced');
                Id masterAccId = (Id) masterRec.get('AccountId');
                if (masterAccId != null) losingAccountIds.remove(masterAccId);
            } catch (Exception e) { /* ignore */ }
        }

        if (losingAccountIds.isEmpty()) return new List<MergeWrappers.OrphanedAccountInfo>();

        // Count contacts still linked to each candidate account AFTER merge
        Map<Id,Integer> contactCountByAcc = new Map<Id,Integer>();
        for (Id accId : losingAccountIds) contactCountByAcc.put(accId, 0);

        for (AggregateResult ar : [
            SELECT AccountId accId, COUNT(Id) cnt
            FROM Contact
            WHERE AccountId IN :losingAccountIds
            GROUP BY AccountId
        ]) {
            contactCountByAcc.put((Id) ar.get('accId'), (Integer) ar.get('cnt'));
        }

        // Only keep accounts with 0 contacts remaining → truly orphaned
        Set<Id> orphanedIds = new Set<Id>();
        for (Id accId : losingAccountIds) {
            if (contactCountByAcc.get(accId) == 0) orphanedIds.add(accId);
        }

        if (orphanedIds.isEmpty()) return new List<MergeWrappers.OrphanedAccountInfo>();

        Map<Id,Integer> affiliationCounts = new Map<Id,Integer>();
        for (Id accId : orphanedIds) affiliationCounts.put(accId, 0);

        List<MergeWrappers.OrphanedAccountInfo> result =
            new List<MergeWrappers.OrphanedAccountInfo>();

        for (Account acc : [SELECT Id, Name FROM Account WHERE Id IN :orphanedIds]) {
            MergeWrappers.OrphanedAccountInfo info = new MergeWrappers.OrphanedAccountInfo();
            info.accountId        = String.valueOf(acc.Id);
            info.accountName      = acc.Name;
            info.affiliationCount = affiliationCounts.get(acc.Id) ?? 0;
            info.isSafeToDelete   = (info.affiliationCount == 0);
            result.add(info);
        }

        return result;
    }

    private static List<MergeWrappers.OrphanedContactInfo> buildOrphanedContactInfo(
        List<Contact> contacts
    ) {
        List<MergeWrappers.OrphanedContactInfo> infos = new List<MergeWrappers.OrphanedContactInfo>();
        for (Contact c : contacts) {
            MergeWrappers.OrphanedContactInfo info = new MergeWrappers.OrphanedContactInfo();
            info.contactId   = String.valueOf(c.Id);
            info.contactName = c.Name;
            info.email       = c.Email;
            info.phone       = c.Phone;
            infos.add(info);
        }
        return infos;
    }

    // ─── Orphaned-ticket cleanup ──────────────────────────────────────────────

    // After a successful merge the losing record IDs are deleted from Salesforce.
    // This removes every other ticket (not the one just merged) that still lists
    // any of those record IDs as a candidate — they can never be resolved.
    // Record_Id__c is Text(18) so we bind a Set<String>, not Set<Id>.
    private static Integer cleanupOrphanedTickets(Id currentTicketId, List<Id> losingIds) {
        if (losingIds == null || losingIds.isEmpty()) return 0;

        Set<String> losingIdStrings = new Set<String>();
        for (Id lid : losingIds) losingIdStrings.add(String.valueOf(lid));

        Set<Id> ticketsToDelete = new Set<Id>();
        for (Merge_Candidate__c c : [
            SELECT Merge_Ticket__c
            FROM Merge_Candidate__c
            WHERE Record_Id__c IN :losingIdStrings
              AND Merge_Ticket__c != :currentTicketId
        ]) {
            ticketsToDelete.add(c.Merge_Ticket__c);
        }

        if (ticketsToDelete.isEmpty()) return 0;

        List<Merge_Ticket__c> toDelete = [
            SELECT Id FROM Merge_Ticket__c WHERE Id IN :ticketsToDelete
        ];
        delete toDelete;
        return toDelete.size();
    }

    // ─── Related records snapshot / delete helpers ────────────────────────────

    private static String captureLoserRelatedIds(List<Id> losingIds, String objectType) {
        List<Map<String,String>> configs = RelatedRecordsService.getConfigsForComparison(objectType);
        if (configs.isEmpty()) return null;
        if (TEST_FORCE_NULL_CAPTURE_RESULT) return null;

        Map<String,Schema.SObjectType> gd = Schema.getGlobalDescribe();
        Set<Id> losingIdSet = new Set<Id>(losingIds);

        // Flat list: [{obj, field, loserId, ids}] — one entry per (object, loser) pair.
        // Storing the lookup field here lets undoMerge re-parent without re-querying configs.
        List<Map<String,Object>> reparented = new List<Map<String,Object>>();

        Integer configsProcessed = 0;
        for (Map<String,String> cfg : configs) {
            configsProcessed++;
            // Dynamic SOQL budget: re-checked before each query to account for real consumption.
            // Reserve 25 for post-capture fixed queries (measured baseline ~6-9; buffer for flows/triggers).
            if (TEST_SOQL_CAP_OVERRIDE != null && configsProcessed > TEST_SOQL_CAP_OVERRIDE) break;
            if (TEST_SOQL_CAP_OVERRIDE == null && (TEST_FORCE_SOQL_BUDGET_HIT || (Limits.getLimitQueries() - Limits.getQueries()) <= 25)) {
                System.debug(LoggingLevel.WARN,
                    'captureLoserRelatedIds: SOQL budget ≤25 remaining, stopped at '
                    + configsProcessed + '/' + configs.size() + ' configs.');
                break;
            }
            String apiName     = cfg.get('apiName');
            String lookupField = cfg.get('lookupField');
            if (!gd.containsKey(apiName.toLowerCase())) continue;

            Map<String, List<String>> byLoser = new Map<String, List<String>>();
            try {
                if (TEST_THROW_CAPTURE_QUERY) throw new System.QueryException('test-capture-query');
                List<SObject> recs = Database.query(
                    'SELECT Id, ' + String.escapeSingleQuotes(lookupField) + ' FROM ' + String.escapeSingleQuotes(apiName) +
                    ' WHERE ' + String.escapeSingleQuotes(lookupField) + ' IN :losingIdSet'
                );
                for (SObject r : recs) {
                    String ownerId = String.valueOf(r.get(lookupField));
                    if (!byLoser.containsKey(ownerId)) byLoser.put(ownerId, new List<String>());
                    byLoser.get(ownerId).add(String.valueOf(r.Id));
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'captureLoserRelatedIds [' + apiName + ']: ' + e.getMessage());
            }

            for (String loserId : byLoser.keySet()) {
                reparented.add(new Map<String,Object>{
                    'obj'     => apiName,
                    'field'   => lookupField,
                    'loserId' => loserId,
                    'ids'     => byLoser.get(loserId)
                });
            }
        }

        return JSON.serialize(new Map<String, Object>{ 'reparented' => reparented });
    }

    private static List<Id> applyRelatedDeletes(String relatedDeletesJson) {
        List<Id> deletedIds = new List<Id>();
        if (String.isBlank(relatedDeletesJson)) return deletedIds;

        Map<String,Object> deleteMap;
        try {
            deleteMap = (Map<String,Object>) JSON.deserializeUntyped(relatedDeletesJson);
        } catch (Exception e) {
            return deletedIds;
        }

        Map<String,Schema.SObjectType> gd = Schema.getGlobalDescribe();
        for (String objApiName : deleteMap.keySet()) {
            if (!gd.containsKey(objApiName.toLowerCase())) continue;
            List<Object> rawIds = (List<Object>) deleteMap.get(objApiName);
            if (rawIds == null || rawIds.isEmpty()) continue;

            Set<Id> recIdSet = new Set<Id>();
            for (Object o : rawIds) recIdSet.add((Id) String.valueOf(o));
            try {
                if (TEST_THROW_APPLY_DELETES_LOOP) throw new System.QueryException('test-apply-deletes');
                List<SObject> recs = Database.query(
                    'SELECT Id FROM ' + String.escapeSingleQuotes(objApiName) + ' WHERE Id IN :recIdSet'
                );
                if (!recs.isEmpty()) {
                    List<Database.DeleteResult> drs = Database.delete(recs, false);
                    for (Integer i = 0; i < drs.size(); i++) {
                        if (drs[i].isSuccess()) deletedIds.add(recs[i].Id);
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'applyRelatedDeletes [' + objApiName + ']: ' + e.getMessage());
            }
        }
        return deletedIds;
    }

    private static void appendDeletedIdsToLog(Id logId, String existingJson, List<Id> deletedIds) {
        if (TEST_FORCE_INVALID_APPEND_JSON) existingJson = 'not-valid-json';
        Map<String,Object> parsed;
        try {
            parsed = String.isBlank(existingJson)
                ? new Map<String,Object>()
                : (Map<String,Object>) JSON.deserializeUntyped(existingJson);
        } catch (Exception e) {
            parsed = new Map<String,Object>();
        }

        // Build reverse-lookup from reparented entries so we know which
        // object/field/loser each deleted record originally belonged to.
        Map<String, Map<String,String>> idToMeta = new Map<String, Map<String,String>>();
        if (parsed.containsKey('reparented')) {
            for (Object rawEntry : (List<Object>) parsed.get('reparented')) {
                Map<String,Object> entry = (Map<String,Object>) rawEntry;
                String obj     = (String) entry.get('obj');
                String field   = (String) entry.get('field');
                String loserId = (String) entry.get('loserId');
                for (Object rawId : (List<Object>) entry.get('ids')) {
                    idToMeta.put(String.valueOf(rawId), new Map<String,String>{
                        'obj' => obj, 'field' => field, 'loserId' => loserId
                    });
                }
            }
        }

        // Group deleted records by (obj, loserId) for clean undo iteration.
        Map<String, Map<String,Object>> groups = new Map<String, Map<String,Object>>();
        for (Id deletedId : deletedIds) {
            String key  = String.valueOf(deletedId);
            Map<String,String> meta = idToMeta.get(key);
            if (meta == null) continue;
            String groupKey = meta.get('obj') + '|' + meta.get('loserId');
            if (!groups.containsKey(groupKey)) {
                groups.put(groupKey, new Map<String,Object>{
                    'obj'     => meta.get('obj'),
                    'field'   => meta.get('field'),
                    'loserId' => meta.get('loserId'),
                    'ids'     => new List<String>()
                });
            }
            ((List<String>) groups.get(groupKey).get('ids')).add(key);
        }
        parsed.put('deleted', groups.values());

        if (!Schema.SObjectType.Merge_Log__c.fields.getMap().containsKey('merge_related_records__c')) return;
        try {
            if (TEST_THROW_APPEND_LOG_UPDATE) throw new System.DmlException('test-append-update');
            Merge_Log__c upd = new Merge_Log__c(Id = logId);
            upd.put('Merge_Related_Records__c', JSON.serialize(parsed));
            update upd;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'appendDeletedIdsToLog: ' + e.getMessage());
        }
    }

    // ─── Email rescue ─────────────────────────────────────────────────────────

    // Copies a loser's email value into a different (empty) email field on the master.
    // This runs in memory before the master UPDATE DML, so the rescue value travels
    // with the regular field-override update at step 5c.
    private static void applyEmailRescues(
        SObject                              masterOverride,
        Map<Id,SObject>                      candidateMap,
        List<MergeWrappers.EmailRescueDecision> rescues,
        Map<String,Schema.SObjectField>      fieldMap
    ) {
        if (rescues == null || rescues.isEmpty()) return;
        for (MergeWrappers.EmailRescueDecision r : rescues) {
            if (String.isBlank(r.sourceRecordId) || String.isBlank(r.sourceField)
                || String.isBlank(r.targetField)) continue;
            Id srcId;
            try { srcId = (Id) r.sourceRecordId; } catch (Exception e) { continue; }
            SObject source = candidateMap.get(srcId);
            if (source == null) continue;
            String tfl = r.targetField.toLowerCase();
            if (fieldMap != null && fieldMap.containsKey(tfl)
                && !fieldMap.get(tfl).getDescribe().isUpdateable()) continue;
            try {
                masterOverride.put(r.targetField, source.get(r.sourceField));
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'applyEmailRescues [' + r.targetField + ']: ' + e.getMessage());
            }
        }
    }

    // ─── Custom exception ─────────────────────────────────────────────────────

    public class MergeException extends Exception {}
}
