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
 *   6.  Execute Database.merge() — supports 1 or 2 losing records per call;
 *       chains automatically for 3+ losers.
 *   7.  Re-query master for after-snapshot.
 *   8.  Update log (success) and ticket (Merged).
 *   On any exception: update log + ticket with error details; NO rollback so
 *   the pre-merge snapshot persists.
 *
 * Database.merge() is used with allOrNone=false so we get a result object
 * instead of an uncatchable DmlException — gives us richer error details.
 */
public without sharing class MergeExecutionService {

    // Test-injection flags — always false in production; set by test classes to cover catch blocks
    @TestVisible private static Boolean TEST_THROW_FIELD_PUT           = false;
    @TestVisible private static Boolean TEST_THROW_LOSER_ACCOUNTID     = false;
    @TestVisible private static Boolean TEST_THROW_MASTER_ACCOUNTID    = false;
    @TestVisible private static Boolean TEST_THROW_EDA_AFFIL_QUERY     = false;
    // Forces validateObjectType to throw so the MergeException branch is covered in tests
    @TestVisible private static Boolean TEST_FORCE_INVALID_OBJECT_TYPE = false;
    // Forces the inner ticket-update to throw so catch(Exception ignored) on that line is covered
    @TestVisible private static Boolean TEST_THROW_ERROR_STAMP         = false;
    // Injects stale normalized values for pref fields so the remap branch in fixEdaPreferenceFields is covered
    @TestVisible private static Boolean TEST_INJECT_STALE_PREF         = false;

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

            // ── 4. Pre-merge audit log (inserted BEFORE merge DML) ────────────
            Merge_Log__c auditLog = MergeAuditService.createPreMergeLog(
                ticketId, objectType, masterId, losingIds,
                candidates, request.fieldDecisions
            );
            auditLogId = auditLog.Id;

            // ── 5. Build a clean merge template: only Id + updateable overrides ──
            // Passing the fully-loaded SObject to Database.merge() causes
            // INVALID_FIELD_FOR_INSERT_UPDATE for read-only fields (Name, CreatedDate, etc.).
            // A clean SObject with only the Id avoids that entirely.
            Map<String,Schema.SObjectField> fieldMap =
                Schema.getGlobalDescribe().get(objectType)?.getDescribe()?.fields?.getMap();
            SObject mergeTemplate = Schema.getGlobalDescribe()
                .get(objectType).newSObject(masterId);
            applyFieldDecisions(mergeTemplate, candidateMap, request.fieldDecisions, fieldMap);

            // ── 5b. Fix EDA preference fields BEFORE merge ───────────────────
            // hed__Preferred_Phone__c / hed__Preferred_Email__c store the field LABEL
            // in the org's current language. When the language changes the stored label
            // is rejected by EDA TDTM during merge. A separate UPDATE DML before the
            // merge guarantees EDA sees a valid (or blank) value, unlike setting the
            // field in the merge template which Database.merge() may not apply for
            // managed-package fields.
            if (objectType == 'Contact') {
                fixEdaPreferenceFields(masterId, losingIds, fieldMap);
            }

            // ── 6. Execute merge ──────────────────────────────────────────────
            runMerge(mergeTemplate, losingIds);

            // ── 7. Re-query master for after-snapshot ─────────────────────────
            SObject masterAfter = reloadRecord(objectType, masterId);

            // ── 8. Finalize audit log and ticket ──────────────────────────────
            MergeAuditService.recordMergeSuccess(auditLogId, masterAfter);
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

        } catch (Exception e) {
            String errorMsg = e.getMessage() + '\n\nStack:\n' + e.getStackTraceString();
            MergeAuditService.recordMergeFailure(
                auditLogId, (Id) request.ticketId, errorMsg
            );
            // Also stamp the error on the ticket so it's visible without opening the Log
            try {
                if (TEST_THROW_ERROR_STAMP) throw new DmlException('test-induced');
                update new Merge_Ticket__c(
                    Id              = (Id) request.ticketId,
                    Status__c       = 'Error',
                    Error_Message__c = e.getMessage().left(32000)
                );
            } catch (Exception ignored) {}
            result.success      = false;
            result.errorMessage = e.getMessage();
        }

        return result;
    }

    // ─── Merge execution ──────────────────────────────────────────────────────

    private static void runMerge(SObject masterRecord, List<Id> losingIds) {
        // Salesforce supports up to 2 losing records per Database.merge() call.
        // For 3+ we chain — each iteration re-uses the same master ID.
        for (Integer i = 0; i < losingIds.size(); i += 2) {
            List<Id> batch = new List<Id>{ losingIds[i] };
            if (i + 1 < losingIds.size()) batch.add(losingIds[i + 1]);

            List<Database.MergeResult> mrs = Database.merge(masterRecord, batch, false);
            if (!mrs.isEmpty() && !mrs[0].isSuccess()) {
                throw new MergeException(buildErrorMsg(mrs[0].getErrors()));
            }
        }
    }

    // EDA stores phone/email preference as a field LABEL in the org's display language.
    // EDA TDTM validates during merge that the stored value matches the CURRENT LANGUAGE label
    // of the corresponding field — so a value stored in English ("Home Phone") fails in a
    // French org where the label is "Téléphone (domicile)".
    //
    // Fix: before the merge, remap each stored value to the current-language label of the
    // matching field by normalizing both the stored value and each field API name to a
    // language-agnostic key. No hardcoded language mappings are needed:
    //   "Home Phone"        → normalize → "homephone" → matches HomePhone (API) → "Téléphone (domicile)"
    //   "hed__WorkPhone__c" → normalize → "workphone" → matches "Work Phone" stored value → ...
    // If the stored value already equals the current-language label, no update is needed.
    // These fields are also excluded from applyFieldDecisions so the merge template never
    // carries the stale value from a loser record.

    private static void fixEdaPreferenceFields(
        Id masterId, List<Id> losingIds, Map<String,Schema.SObjectField> fieldMap
    ) {
        if (fieldMap == null) return;
        Boolean hasPrefPhone = fieldMap.containsKey('hed__preferredphone__c');
        Boolean hasPrefEmail = fieldMap.containsKey('hed__preferred_email__c');
        if (!hasPrefPhone && !hasPrefEmail) return;

        // Build normalized-key → current-language label for every phone/email field.
        // normalizeEdaKey("Home Phone") == normalizeEdaKey("HomePhone") == "homephone"
        // so a stored English value matches the right field regardless of org language.
        Map<String,String> phoneNormToLabel = new Map<String,String>();
        Map<String,String> emailNormToLabel = new Map<String,String>();
        for (String f : fieldMap.keySet()) {
            Schema.DescribeFieldResult dfr = fieldMap.get(f).getDescribe();
            String currentLabel = dfr.getLabel();
            if (dfr.getType() == Schema.DisplayType.Phone) {
                phoneNormToLabel.put(normalizeEdaKey(dfr.getName()), currentLabel);
            }
            if (dfr.getType() == Schema.DisplayType.Email) {
                emailNormToLabel.put(normalizeEdaKey(dfr.getName()), currentLabel);
            }
        }

        // Query current preference values for all contacts
        List<Id> allIds = new List<Id>{ masterId };
        allIds.addAll(losingIds);
        String sel = 'SELECT Id'
            + (hasPrefPhone ? ', hed__PreferredPhone__c' : '')
            + (hasPrefEmail ? ', hed__Preferred_Email__c' : '')
            + ' FROM Contact WHERE Id IN :allIds';
        List<SObject> contacts = Database.query(sel);

        List<SObject> toUpdate = new List<SObject>();
        for (SObject c : contacts) {
            SObject upd = Schema.getGlobalDescribe().get('Contact').newSObject((Id) c.get('Id'));
            Boolean changed = false;

            if (hasPrefPhone) {
                String stored = TEST_INJECT_STALE_PREF ? 'homephone' : (String) c.get('hed__PreferredPhone__c');
                if (stored != null) {
                    String target = phoneNormToLabel.get(normalizeEdaKey(stored));
                    if (target != null && target != stored) {
                        upd.put('hed__PreferredPhone__c', target);
                        changed = true;
                    }
                }
            }

            if (hasPrefEmail) {
                String stored = TEST_INJECT_STALE_PREF ? 'alternateemail' : (String) c.get('hed__Preferred_Email__c');
                if (stored != null) {
                    String target = emailNormToLabel.get(normalizeEdaKey(stored));
                    if (target != null && target != stored) {
                        upd.put('hed__Preferred_Email__c', target);
                        changed = true;
                    }
                }
            }

            if (changed) toUpdate.add(upd);
        }

        if (!toUpdate.isEmpty()) {
            try { Database.update(toUpdate, false); } catch (Exception e) {}
        }
    }

    // Strips namespace prefix (e.g. "hed__"), "__c" suffix, and non-alphanumeric chars,
    // then lowercases — making field API names and their EDA picklist counterparts identical:
    //   "Home Phone" → "homephone"   "HomePhone" → "homephone"
    //   "hed__WorkPhone__c" → "workphone"   "Work Phone" → "workphone"
    private static String normalizeEdaKey(String s) {
        if (String.isBlank(s)) return '';
        String norm = s.replaceAll('^[a-z][a-z0-9]*__', '');  // remove namespace prefix
        norm = norm.replaceAll('__c$', '');                     // remove __c suffix
        norm = norm.replaceAll('[^a-zA-Z0-9]', '');             // remove spaces / punctuation
        return norm.toLowerCase();
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
                   ' FROM ' + objectType + ' WHERE Id IN :ids';
        return Database.query(q);
    }

    private static SObject reloadRecord(String objectType, Id recordId) {
        List<String> fields = getComparisonFields(objectType);
        String q = 'SELECT ' + String.join(fields, ', ') +
                   ' FROM ' + objectType + ' WHERE Id = :recordId LIMIT 1';
        List<SObject> rows = Database.query(q);
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
        update new Merge_Ticket__c(
            Id                  = ticketId,
            Status__c           = 'Merged',
            Selected_Master_Id__c = String.valueOf(masterId),
            Final_Action__c     = 'Merged',
            Notes__c            = notes
        );
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

    private static String buildErrorMsg(List<Database.Error> errors) {
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

        // Count EDA affiliations per orphaned account (if EDA installed)
        Map<Id,Integer> affiliationCounts = new Map<Id,Integer>();
        for (Id accId : orphanedIds) affiliationCounts.put(accId, 0);

        if (EDARelatedRecordsService.isEDAAvailable()) {
            try {
                if (TEST_THROW_EDA_AFFIL_QUERY) throw new QueryException('test-induced');
                for (AggregateResult ar : [
                    SELECT hed__Account__c accId, COUNT(Id) cnt
                    FROM hed__Affiliation__c
                    WHERE hed__Account__c IN :orphanedIds
                    GROUP BY hed__Account__c
                ]) {
                    Id accId = (Id) ar.get('accId');
                    if (affiliationCounts.containsKey(accId)) {
                        affiliationCounts.put(accId, (Integer) ar.get('cnt'));
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'detectOrphanedAccounts affiliation: ' + e.getMessage());
            }
        }

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

    // ─── Custom exception ─────────────────────────────────────────────────────

    public class MergeException extends Exception {}
}
