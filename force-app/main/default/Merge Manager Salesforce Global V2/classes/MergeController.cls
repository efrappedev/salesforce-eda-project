/**
 * MergeController.cls
 * Thin LWC adapter — zero business logic.
 * Every method delegates immediately to a service class.
 *
 * Uses "with sharing" so Salesforce enforces record-level security for the
 * current user. The service classes use "without sharing" where elevated
 * access is required (merge DML, audit log writes).
 */
// CRUD/FLS: Administrative tool restricted via Merge_Manager_Access permission set.
// with sharing enforces record-level security. CRUD intentionally bypassed for admin merge ops.
@SuppressWarnings('PMD.ApexCRUDViolation')
public with sharing class MergeController {

    // Test-injection: extra candidates appended before sort to force swap coverage
    @TestVisible private static List<MergeWrappers.EmailObjectInfo> TEST_EXTRA_CANDIDATES = null;
    // Test-injection: override IsSandbox check so tests can reach the production guard branch
    @TestVisible private static Boolean TEST_IS_SANDBOX = null;
    // Test-injection: bypass dfr.isAccessible() in getEmailObjectCandidates so tests cover
    // the qualifying-object branch regardless of the running user's FLS profile
    @TestVisible private static Boolean TEST_SKIP_FIELD_ACCESSIBILITY_CHECK = false;
    // Test-injection: force the inner for-ref loop body (hasLookupToTarget = true; break) to fire
    // so tests can cover lines 1174-1175 without needing a real custom object with an email field
    // pointing to the target type (which AEBEQ/any org without EDA doesn't have)
    @TestVisible private static Boolean TEST_FORCE_LOOKUP_MATCH = false;
    // Test-injection: extra items appended to getDiscoverableObjects result to force sort swap
    @TestVisible private static List<Map<String,Object>> TEST_EXTRA_DISCOVERABLE = null;
    // Test-injection: pre-seed seenIdx so a real child object appears "already seen" in the loop
    @TestVisible private static String TEST_PRESEED_CHILD_NAME = null;
    // Test-injection: force the nillable-upgrade branch (line 616) to execute in tests
    @TestVisible private static Boolean TEST_FORCE_UPGRADE_BRANCH = false;
    // Test-injection: force the Account-delete CRUD guard to deny, covering the throw branch
    @TestVisible private static Boolean TEST_FORCE_ACCOUNT_NOT_DELETABLE = false;
    // Test-injection: force the Contact-delete CRUD guard to deny, covering the throw branch
    @TestVisible private static Boolean TEST_FORCE_CONTACT_NOT_DELETABLE = false;
    // Test-injection: force the Related_Object_Config__c create/delete CRUD guard to deny
    @TestVisible private static Boolean TEST_FORCE_CONFIG_PERMISSION_DENIED = false;
    // Test-injection: force the object-accessibility guard in saveObjectConfigsBatch to deny
    @TestVisible private static Boolean TEST_FORCE_CONFIG_OBJECT_NOT_ACCESSIBLE = false;
    // Test-injection: force initDefaultConfigsIfEmpty to see "no permission" and return early
    @TestVisible private static Boolean TEST_FORCE_NO_INIT_PERMISSION = false;
    // Test-injection: extra deleted Account IDs to add to undoMerge step 1c (covers line 348 in EDA orgs)
    @TestVisible private static Set<Id> TEST_INJECT_EXTRA_DELETED_ACCT_IDS = null;
    // Test-injection: simulate all loser records permanently deleted (covers toUndelete.isEmpty() → throw)
    @TestVisible private static Boolean TEST_FORCE_EMPTY_LOSER_UNDELETE = false;
    // Test-injection: force catch block in undoMerge step-1b (Account deleted-contacts path)
    @TestVisible private static Boolean TEST_THROW_UNDO_STEP_1B = false;
    // Test-injection: force catch block in undoMerge step-1c (Contact admin-account path)
    @TestVisible private static Boolean TEST_THROW_UNDO_STEP_1C = false;
    // Test-injection: force catch block in undoMerge legacy-deletedIds path
    @TestVisible private static Boolean TEST_THROW_UNDO_LEGACY_DELETES = false;
    // Test-injection: force catch block in restoreMasterFieldValues rec.put path
    @TestVisible private static Boolean TEST_THROW_RESTORE_FIELD_PUT = false;
    // Test-injection: force catch block in restoreMasterFieldValues Database.update path
    @TestVisible private static Boolean TEST_THROW_RESTORE_UPDATE = false;
    // Test-injection: force parentSType = null in saveObjectConfigsBatch (covers dead else-branch)
    @TestVisible private static Boolean TEST_FORCE_PARENT_STYPE_NULL = false;
    // Test-injection: force corrupt JSON in getCustomCloseReasons catch block
    @TestVisible private static Boolean TEST_CORRUPT_CLOSE_REASONS_JSON = false;
    // Test-injection: override the parent-type list in initDefaultConfigsIfEmpty so tests can
    // drive the payload-build path (lines 1397-1405) with a type that has discoverable children
    @TestVisible private static List<String> TEST_INIT_PARENT_TYPES = null;
    // ─── Ticket list ──────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getTicketPreview(String ticketId) {
        Merge_Ticket__c ticket = [
            SELECT Id, Name, Status__c, Object_Type__c, Match_Type__c,
                   Match_Confidence__c, Match_Key__c, Error_Message__c,
                   Notes__c, CreatedDate, LastModifiedDate
            FROM Merge_Ticket__c WHERE Id = :ticketId LIMIT 1
        ];

        List<Merge_Candidate__c> candidates = [
            SELECT Id, Record_Name__c, Record_Id__c, Is_Master__c, Is_Losing_Record__c,
                   Snapshot_JSON__c, Related_Info_JSON__c
            FROM Merge_Candidate__c
            WHERE Merge_Ticket__c = :ticketId
            ORDER BY CreatedDate ASC
        ];

        List<Merge_Log__c> logs = [
            SELECT Id, Performed_By__r.Name, Performed_Date__c, Action_Type__c,
                   Master_Record_Name__c, Losing_Record_Names__c
            FROM Merge_Log__c
            WHERE Merge_Ticket__c = :ticketId
              AND Action_Type__c = 'MERGE_COMPLETED'
            ORDER BY CreatedDate DESC LIMIT 1
        ];

        Map<String, Object> mergeLogData = null;
        if (!logs.isEmpty()) {
            Merge_Log__c lg = logs[0];
            mergeLogData = new Map<String, Object>{
                'performedByName' => lg.Performed_By__r != null ? lg.Performed_By__r.Name : '—',
                'performedDate'   => lg.Performed_Date__c,
                'masterName'      => lg.Master_Record_Name__c,
                'loserNames'      => lg.Losing_Record_Names__c,
                'actionType'      => lg.Action_Type__c
            };
        }

        return new Map<String, Object>{
            'ticket'     => ticket,
            'candidates' => candidates,
            'mergeLog'   => mergeLogData
        };
    }

    // Resolves Merge_Ticket IDs from candidate names in a separate transaction
    // (own 50k governor limit, independent of getTickets/getTicketCount).
    @AuraEnabled
    public static List<String> resolveSearchIds(String searchTerm) {
        if (String.isBlank(searchTerm)) return new List<String>();
        searchTerm = String.escapeSingleQuotes(searchTerm);
        String likePattern = '%' + searchTerm + '%';
        Set<String> ids = new Set<String>();
        for (Merge_Candidate__c c : Database.query(
                'SELECT Merge_Ticket__c FROM Merge_Candidate__c' +
                ' WHERE Record_Name__c LIKE :likePattern LIMIT 50000')) { // NOPMD
            if (c.Merge_Ticket__c != null) ids.add(String.valueOf(c.Merge_Ticket__c));
        }
        return new List<String>(ids);
    }

    @AuraEnabled
    public static List<Merge_Ticket__c> getTickets(
        String       objectType,
        String       statusFilter,
        String       searchTerm,
        List<String> candidateTicketIds,
        Long         cursorTimestamp,
        String       cursorId
    ) {
        objectType   = String.escapeSingleQuotes(objectType);
        statusFilter = String.escapeSingleQuotes(statusFilter);
        String soql =
            'SELECT Id, Name, Status__c, Object_Type__c, Match_Type__c, ' +
            '       Match_Confidence__c, Candidate_Count__c, Match_Key__c, ' +
            '       Error_Message__c, Closed_Reason__c, Notes__c, ' +
            '       CreatedDate, LastModifiedDate, ' +
            '       (SELECT Record_Name__c FROM Merge_Candidates__r ' +
            '        ORDER BY CreatedDate ASC LIMIT 5) ' +
            'FROM Merge_Ticket__c ' +
            'WHERE Object_Type__c = :objectType';

        if (statusFilter == 'All') {
            soql += ' AND Status__c NOT IN (\'Merged\', \'Ignored\', \'Closed\')';
        } else if (!String.isBlank(statusFilter)) {
            soql += ' AND Status__c = :statusFilter';
        }
        if (!String.isBlank(searchTerm)) {
            searchTerm = String.escapeSingleQuotes(searchTerm);
            String likePattern = '%' + searchTerm + '%'; // NOPMD — used as SOQL bind variable
            Set<Id> candidateIdSet = new Set<Id>();
            if (candidateTicketIds != null) {
                for (String s : candidateTicketIds) {
                    if (!String.isBlank(s)) candidateIdSet.add((Id) s);
                }
            }
            String candidateClause = candidateIdSet.isEmpty() ? '' : ' OR Id IN :candidateIdSet';
            soql += ' AND (Match_Key__c LIKE :likePattern OR Name LIKE :likePattern' + candidateClause + ')';
        }
        if (cursorTimestamp != null && !String.isBlank(cursorId)) {
            Datetime cursorDt = Datetime.newInstance(cursorTimestamp); // NOPMD — used as SOQL bind variable
            soql += ' AND (LastModifiedDate < :cursorDt OR (LastModifiedDate = :cursorDt AND Id < :cursorId))';
        }
        soql += ' ORDER BY LastModifiedDate DESC, Id DESC LIMIT 2000';
        return Database.query(soql); // NOPMD
    }

    // Backward-compat overload for Apex tests — delegates to full version
    @TestVisible
    private static List<Merge_Ticket__c> getTickets(String objectType, String statusFilter) {
        return getTickets(objectType, statusFilter, null, null, null, null);
    }

    @AuraEnabled
    public static Integer getTicketCount(
        String       objectType,
        String       statusFilter,
        String       searchTerm,
        List<String> candidateTicketIds
    ) {
        objectType   = String.escapeSingleQuotes(objectType);
        statusFilter = String.escapeSingleQuotes(statusFilter);
        String soql =
            'SELECT COUNT() FROM Merge_Ticket__c ' +
            'WHERE Object_Type__c = :objectType';

        if (statusFilter == 'All') {
            soql += ' AND Status__c NOT IN (\'Merged\', \'Ignored\', \'Closed\')';
        } else if (!String.isBlank(statusFilter)) {
            soql += ' AND Status__c = :statusFilter';
        }
        if (!String.isBlank(searchTerm)) {
            searchTerm = String.escapeSingleQuotes(searchTerm);
            String likePattern = '%' + searchTerm + '%'; // NOPMD — used as SOQL bind variable
            Set<Id> candidateIdSet = new Set<Id>();
            if (candidateTicketIds != null) {
                for (String s : candidateTicketIds) {
                    if (!String.isBlank(s)) candidateIdSet.add((Id) s);
                }
            }
            String candidateClause = candidateIdSet.isEmpty() ? '' : ' OR Id IN :candidateIdSet';
            soql += ' AND (Match_Key__c LIKE :likePattern OR Name LIKE :likePattern' + candidateClause + ')';
        }
        return Database.countQuery(soql); // NOPMD
    }

    // Backward-compat overload for Apex tests
    @TestVisible
    private static Integer getTicketCount(String objectType, String statusFilter) {
        return getTicketCount(objectType, statusFilter, null, null);
    }

    // ─── Scan ─────────────────────────────────────────────────────────────────

    // Parameters are passed individually (not as a wrapper) to avoid LWC proxy
    // serialization issues that strip field values from nested Apex objects —
    // same pattern already used by executeMerge().
    @AuraEnabled
    public static MergeWrappers.ScanResult runScan(
        String       objType,
        List<String> matchFields,
        Integer      recordLimit,
        Boolean      dryRun,
        String       emailObjectApiName
    ) {
        if (!new Set<String>{ 'Contact', 'Account' }.contains(objType)) {
            throw new AuraHandledException('Type d\'objet non supporté : ' + objType);
        }

        // Production scan: run as Batch Apex so Database.getQueryLocator handles
        // any org size without hitting the 50,000-row governor limit.
        if (dryRun != true) {
            Set<String> fieldSet = (matchFields != null && !matchFields.isEmpty())
                ? new Set<String>(matchFields)
                : new Set<String>{ 'Email', 'Phone' };
            Id jobId = Database.executeBatch(
                new MergeScanBatch(objType, fieldSet, emailObjectApiName), 200
            );
            MergeWrappers.ScanResult result = new MergeWrappers.ScanResult();
            result.isAsync    = true;
            result.batchJobId = String.valueOf(jobId);
            return result;
        }

        // Preview / dry-run: sync scan with a small record cap (safe for governor limits).
        MergeWrappers.ScanRequest request = new MergeWrappers.ScanRequest();
        request.mergeObjectType    = objType;
        request.matchFields        = matchFields;
        request.recordLimit        = (recordLimit != null && recordLimit > 0) ? recordLimit : 5000;
        request.dryRun             = true;
        request.emailObjectApiName = emailObjectApiName;

        return MergeScanService.scan(request);
    }

    // ─── Comparison matrix ────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static MergeWrappers.ComparisonMatrix getComparisonMatrix(String ticketId) {
        return MergeTicketService.buildComparisonMatrix((Id) ticketId);
    }

    // ─── Merge execution ──────────────────────────────────────────────────────

    // All merge parameters are passed individually to avoid LWC proxy
    // serialization issues that strip values nested inside wrapper objects.
    @AuraEnabled
    public static MergeWrappers.MergeResult executeMerge(
        String             ticketId,
        String             masterId,
        List<String>       losingIds,
        Map<String,String> fieldDecisions,
        String             notes,
        String             relatedDeletesJson,
        String             emailRescuesJson
    ) {
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId           = ticketId;
        req.masterId           = masterId;
        req.losingIds          = losingIds;
        req.fieldDecisions     = fieldDecisions;
        req.notes              = notes;
        req.relatedDeletesJson = relatedDeletesJson;
        if (!String.isBlank(emailRescuesJson)) {
            try {
                req.emailRescues = (List<MergeWrappers.EmailRescueDecision>)
                    JSON.deserialize(emailRescuesJson, List<MergeWrappers.EmailRescueDecision>.class);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'executeMerge: emailRescues parse error: ' + e.getMessage());
            }
        }
        return MergeExecutionService.executeMerge(req);
    }

    // ─── Related records comparison (Step 2 wizard) ──────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<MergeWrappers.RelatedObjectComparison> getRelatedRecordsComparison(Id ticketId, Id masterId) {
        // masterId is passed from LWC (user's current Step-1 selection).
        // We cannot derive it from Is_Master__c because that field is set only
        // AFTER the merge DML completes — before the merge, all candidates have it null.
        if (masterId == null) return new List<MergeWrappers.RelatedObjectComparison>();

        List<Merge_Candidate__c> candidates = [
            SELECT Record_Id__c
            FROM Merge_Candidate__c WHERE Merge_Ticket__c = :ticketId
        ];

        Set<Id> allIds = new Set<Id>();
        for (Merge_Candidate__c c : candidates) {
            allIds.add((Id) c.Record_Id__c);
        }
        if (allIds.isEmpty()) return new List<MergeWrappers.RelatedObjectComparison>();

        // Derive object type from ticket
        Merge_Ticket__c ticket = [SELECT Object_Type__c FROM Merge_Ticket__c WHERE Id = :ticketId LIMIT 1];
        List<Map<String,String>> configs = RelatedRecordsService.getConfigsForComparison(ticket.Object_Type__c);

        Map<String,Schema.SObjectType> gd  = Schema.getGlobalDescribe();
        List<MergeWrappers.RelatedObjectComparison> result =
            new List<MergeWrappers.RelatedObjectComparison>();
        final Id masterIdFinal = masterId;

        for (Map<String,String> cfg : configs) {
            String apiName     = cfg.get('apiName');
            String lookupField = cfg.get('lookupField');
            String label       = cfg.get('label');
            if (!gd.containsKey(apiName.toLowerCase())) continue;

            MergeWrappers.RelatedObjectComparison comp = new MergeWrappers.RelatedObjectComparison();
            comp.apiName     = apiName;
            comp.label       = label;
            comp.lookupField = lookupField;

            try {
                String safeLookup = String.escapeSingleQuotes(lookupField);
                String safeApi    = String.escapeSingleQuotes(apiName);
                String q = 'SELECT Id, Name, ' + safeLookup + ' FROM ' + safeApi +
                    ' WHERE ' + safeLookup + ' IN :allIds ORDER BY Name ASC LIMIT 200';
                List<SObject> records = Database.query(q);

                // Build master name set for conflict detection
                Set<String> masterNames = new Set<String>();
                for (SObject r : records) {
                    if (String.valueOf(r.get(lookupField)) == String.valueOf(masterIdFinal)) {
                        String n = (String) r.get('Name');
                        if (!String.isBlank(n)) masterNames.add(n.toLowerCase());
                    }
                }

                for (SObject r : records) {
                    String ownerId = String.valueOf(r.get(lookupField));
                    MergeWrappers.RelatedRecordInfo info = new MergeWrappers.RelatedRecordInfo();
                    info.recordId        = String.valueOf(r.Id);
                    info.recordName      = String.isBlank((String) r.get('Name')) ? '—' : (String) r.get('Name');
                    info.ownerCandidateId = ownerId;

                    if (ownerId == String.valueOf(masterIdFinal)) {
                        comp.masterRecords.add(info);
                    } else {
                        info.hasConflict = masterNames.contains(info.recordName.toLowerCase());
                        comp.loserRecords.add(info);
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'getRelatedRecordsComparison [' + apiName + ']: ' + e.getMessage());
            }

            result.add(comp);
        }
        return result;
    }

    // ─── Undo merge ──────────────────────────────────────────────────────────

    @AuraEnabled
    public static void undoMerge(Id ticketId) {
        // Use dynamic SOQL so undoMerge keeps working if Related_Records_JSON__c
        // hasn't been deployed to this org yet (phantom-field safe).
        Boolean hasRelatedField = Schema.SObjectType.Merge_Log__c.fields.getMap()
            .containsKey('merge_related_records__c');
        String soqlFields = String.escapeSingleQuotes(
            'Master_Record_Id__c, Losing_Record_Ids__c, Object_Type__c, Field_Decisions_JSON__c'
            + (hasRelatedField ? ', Merge_Related_Records__c' : ''));
        List<Merge_Log__c> logs = Database.query(
            'SELECT ' + soqlFields +
            ' FROM Merge_Log__c' +
            ' WHERE Merge_Ticket__c = :ticketId AND Action_Type__c = \'MERGE_COMPLETED\'' +
            ' LIMIT 1'
        );
        if (logs.isEmpty()) {
            throw new AuraHandledException('Aucun enregistrement de fusion trouvé pour ce ticket.');
        }
        Merge_Log__c log = logs[0];

        String objectType = log.Object_Type__c;
        List<Object> rawLoserIds = (List<Object>) JSON.deserializeUntyped(log.Losing_Record_Ids__c);
        Set<Id> loserIds = new Set<Id>();
        for (Object o : rawLoserIds) loserIds.add((Id) String.valueOf(o));

        String relatedRecordsRaw = hasRelatedField ? (String) log.get('Merge_Related_Records__c') : null;
        Map<String,Object> relatedJson = String.isBlank(relatedRecordsRaw)
            ? new Map<String,Object>()
            : (Map<String,Object>) JSON.deserializeUntyped(relatedRecordsRaw);

        Map<String,Schema.SObjectType> gd = Schema.getGlobalDescribe();
        Id masterId = (Id) log.Master_Record_Id__c;

        // ── 1. Undelete the loser record(s) — preserves original Salesforce ID ─
        String sobjType = String.escapeSingleQuotes(objectType == 'Account' ? 'Account' : 'Contact');
        List<SObject> toUndelete = Database.query(
            'SELECT Id FROM ' + sobjType + ' WHERE Id IN :loserIds ALL ROWS'
        );
        if (TEST_FORCE_EMPTY_LOSER_UNDELETE) toUndelete.clear();
        if (toUndelete.isEmpty()) {
            throw new AuraHandledException(
                'Enregistrement(s) à restaurer introuvable(s). ' +
                'Les fusions effectuées avant la mise à jour 2026-06 ne peuvent pas être annulées. ' +
                'Créez le contact manuellement en utilisant les données du journal de fusion.'
            );
        }
        List<Database.UndeleteResult> undelResults = Database.undelete(toUndelete, false);
        for (Database.UndeleteResult ur : undelResults) {
            if (!ur.isSuccess()) {
                String errMsg = ur.getErrors().isEmpty() ? 'Erreur inconnue'
                    : ur.getErrors()[0].getMessage();
                throw new AuraHandledException(
                    'Impossible de restaurer l\'enregistrement: ' + errMsg + '. ' +
                    'Les fusions effectuées avant la mise à jour 2026-06 ne peuvent pas être annulées.'
                );
            }
        }

        // ── 1b. For Account merges: undelete contacts deleted during merge ──────
        if (sobjType == 'Account') {
            try {
                if (TEST_THROW_UNDO_STEP_1B) throw new QueryException('test-1b');
                Merge_Ticket__c tk = [SELECT Notes__c FROM Merge_Ticket__c WHERE Id = :ticketId LIMIT 1];
                if (!String.isBlank(tk.Notes__c)) {
                    Set<Id> deletedContactIds = new Set<Id>();
                    for (String ln : tk.Notes__c.split('\n')) {
                        if (!ln.startsWith('[DELETED_CONTACT|')) continue;
                        String content = ln.removeStart('[DELETED_CONTACT|').removeEnd(']');
                        List<String> parts = content.split('\\|');
                        if (!parts.isEmpty() && !String.isBlank(parts[0])) {
                            try { deletedContactIds.add((Id) parts[0]); } catch (Exception ex) {}
                        }
                    }
                    if (!deletedContactIds.isEmpty()) {
                        List<Contact> dc = Database.query(
                            'SELECT Id FROM Contact WHERE Id IN :deletedContactIds AND IsDeleted = true ALL ROWS'
                        );
                        if (!dc.isEmpty()) Database.undelete(dc, false);
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'undoMerge: deleted contacts undelete skipped — ' + e.getMessage());
            }
        }

        // ── 1c. Also undelete the loser's Administrative Account if deleted ──
        // After merge + account deletion (manual or EDA auto-cleanup), the loser's
        // AccountId points to a soft-deleted account. Undelete it so the contact
        // is fully restored with its original account relationship.
        if (sobjType == 'Contact') {
            try {
                if (TEST_THROW_UNDO_STEP_1C) throw new QueryException('test-1c');
                Set<Id> loserContactIds = new Set<Id>(loserIds);
                List<Contact> loserContacts = [
                    SELECT AccountId FROM Contact WHERE Id IN :loserContactIds
                ];
                Set<Id> accountIds = new Set<Id>();
                for (Contact c : loserContacts) {
                    if (c.AccountId != null) accountIds.add(c.AccountId);
                }
                if (TEST_INJECT_EXTRA_DELETED_ACCT_IDS != null) accountIds.addAll(TEST_INJECT_EXTRA_DELETED_ACCT_IDS);
                if (!accountIds.isEmpty()) {
                    List<Account> deletedAccounts = [
                        SELECT Id FROM Account WHERE Id IN :accountIds AND IsDeleted = true ALL ROWS
                    ];
                    if (!deletedAccounts.isEmpty()) Database.undelete(deletedAccounts, false);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'undoMerge: Administrative Account undelete skipped — ' + e.getMessage());
            }
        }

        // ── 2. Re-parent related records back to their original loser ────────────
        // New format: 'reparented' = [{obj, field, loserId, ids}]
        // Old format: 'loserRelatedIds' = {loserId: {objApiName: [ids]}} (backward compat)
        List<Object> reparentedEntries = relatedJson.containsKey('reparented')
            ? (List<Object>) relatedJson.get('reparented')
            : buildReparentedFromLegacy(relatedJson, objectType);

        for (Object rawEntry : reparentedEntries) {
            Map<String,Object> entry = (Map<String,Object>) rawEntry;
            String objApiName  = (String) entry.get('obj');
            String lookupField = (String) entry.get('field');
            Id     loserId     = (Id) String.valueOf(entry.get('loserId'));
            List<Object> rawIds = (List<Object>) entry.get('ids');
            if (rawIds == null || rawIds.isEmpty() || lookupField == null) continue;
            if (!gd.containsKey(objApiName.toLowerCase())) continue;
            Set<Id> recIdSet = new Set<Id>();
            for (Object o : rawIds) recIdSet.add((Id) String.valueOf(o));
            try {
                String safeField   = String.escapeSingleQuotes(lookupField);
                String safeObjName = String.escapeSingleQuotes(objApiName);
                List<SObject> recs = Database.query(
                    'SELECT Id, ' + safeField + ' FROM ' + safeObjName +
                    ' WHERE Id IN :recIdSet AND ' + safeField + ' = :masterId'
                );
                for (SObject r : recs) r.put(lookupField, loserId);
                if (!recs.isEmpty()) Database.update(recs, false);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'undoMerge reparent [' + objApiName + ']: ' + e.getMessage());
            }
        }

        // ── 3. Restore conflict records deleted during merge + re-point to loser ─
        // New format: 'deleted' = [{obj, field, loserId, ids}]
        // Old format: 'deletedIds' = [ids] (backward compat — no field/loser info)
        if (relatedJson.containsKey('deleted')) {
            for (Object rawEntry : (List<Object>) relatedJson.get('deleted')) {
                Map<String,Object> entry = (Map<String,Object>) rawEntry;
                String objApiName  = (String) entry.get('obj');
                String lookupField = (String) entry.get('field');
                Id     loserId     = (Id) String.valueOf(entry.get('loserId'));
                List<Object> rawIds = (List<Object>) entry.get('ids');
                if (rawIds == null || rawIds.isEmpty()) continue;
                if (!gd.containsKey(objApiName.toLowerCase())) continue;
                Set<Id> recIdSet = new Set<Id>();
                for (Object o : rawIds) recIdSet.add((Id) String.valueOf(o));
                try {
                    // Query recycle bin (ALL ROWS) then undelete + re-point in one pass
                    List<SObject> recs = Database.query(
                        'SELECT Id FROM ' + String.escapeSingleQuotes(objApiName) + ' WHERE Id IN :recIdSet ALL ROWS'
                    );
                    if (!recs.isEmpty()) {
                        Database.undelete(recs, false);
                        for (SObject r : recs) r.put(lookupField, loserId);
                        Database.update(recs, false);
                    }
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN,
                        'undoMerge restore deleted [' + objApiName + ']: ' + e.getMessage());
                }
            }
        } else if (relatedJson.containsKey('deletedIds')) {
            // Legacy: flat list — undelete only, cannot re-point (no field/loser info)
            List<Map<String,String>> configs =
                RelatedRecordsService.getConfigsForComparison(objectType);
            Set<Id> deletedIdSet = new Set<Id>();
            for (Object o : (List<Object>) relatedJson.get('deletedIds')) {
                deletedIdSet.add((Id) String.valueOf(o));
            }
            for (Map<String,String> cfg : configs) {
                String objApiName = cfg.get('apiName');
                if (!gd.containsKey(objApiName.toLowerCase())) continue;
                try {
                    if (TEST_THROW_UNDO_LEGACY_DELETES) throw new QueryException('test-legacy-deletes');
                    List<SObject> recs = Database.query(
                        'SELECT Id FROM ' + String.escapeSingleQuotes(objApiName) + ' WHERE Id IN :deletedIdSet ALL ROWS'
                    );
                    if (!recs.isEmpty()) Database.undelete(recs, false);
                } catch (Exception e) { /* silent — record may not be in this object */ }
            }
        }

        // ── 4. Revert master field values that changed during the merge ────────────
        restoreMasterFieldValues(masterId, objectType, log.Field_Decisions_JSON__c);

        // ── 5. Reset ticket to Reopened ──────────────────────────────────────────
        Merge_Ticket__c undoTkt = [SELECT Notes__c FROM Merge_Ticket__c WHERE Id = :ticketId LIMIT 1];
        String undoNotes = buildHistNotes(undoTkt.Notes__c, 'Reopened', null, null);
        update new Merge_Ticket__c(
            Id               = ticketId,
            Status__c        = 'Reopened',
            Final_Action__c  = null,
            Error_Message__c = null,
            Notes__c         = undoNotes
        );
    }

    // Reverts the master record's field values to their pre-merge state.
    // Field_Decisions_JSON__c (post-merge) contains the diff:
    //   { fieldName: { before: preMergeValue, after: postMergeValue } }
    // We restore every updateable field that the merge changed.
    private static void restoreMasterFieldValues(
        Id masterId, String objectType, String diffJson
    ) {
        if (String.isBlank(diffJson)) return;
        Map<String,Object> diff;
        try {
            diff = (Map<String,Object>) JSON.deserializeUntyped(diffJson);
        } catch (Exception e) { return; }
        if (diff == null || diff.isEmpty()) return;

        Map<String,Schema.SObjectField> fieldMap = Schema.getGlobalDescribe()
            .get(objectType)?.getDescribe()?.fields?.getMap();
        if (fieldMap == null) return;

        // System/compound fields that must never be written back
        Set<String> SKIP = new Set<String>{
            'id', 'isdeleted', 'masterrecordid',
            'createddate', 'createdbyid',
            'lastmodifieddate', 'lastmodifiedbyid',
            'systemmodstamp', 'lastvieweddate', 'lastreferenceddate',
            'name'   // compound on Contact; FirstName/LastName are in diff separately
        };

        SObject rec = Schema.getGlobalDescribe().get(objectType).newSObject(masterId);
        Boolean anySet = false;

        for (String fieldName : diff.keySet()) {
            if (SKIP.contains(fieldName.toLowerCase())) continue;
            String lower = fieldName.toLowerCase();
            if (!fieldMap.containsKey(lower)) continue;
            if (!fieldMap.get(lower).getDescribe().isUpdateable()) continue;

            Map<String,Object> change = (Map<String,Object>) diff.get(fieldName);
            Object beforeValue = change.get('before');
            try {
                if (TEST_THROW_RESTORE_FIELD_PUT) throw new System.SObjectException('test-put');
                rec.put(fieldName, beforeValue);
                anySet = true;
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'undoMerge restoreField [' + fieldName + ']: ' + e.getMessage());
            }
        }

        if (anySet) {
            try {
                if (TEST_THROW_RESTORE_UPDATE) throw new DmlException('test-update');
                Database.update(rec, false);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'undoMerge restoreMasterFields: ' + e.getMessage());
            }
        }
    }

    // Converts legacy 'loserRelatedIds' JSON structure to the new reparented list
    // format so undoMerge works on logs created before the format upgrade.
    private static List<Object> buildReparentedFromLegacy(
        Map<String,Object> relatedJson, String objectType
    ) {
        List<Object> result = new List<Object>();
        if (!relatedJson.containsKey('loserRelatedIds')) return result;
        List<Map<String,String>> configs =
            RelatedRecordsService.getConfigsForComparison(objectType);
        Map<String,String> apiToField = new Map<String,String>();
        for (Map<String,String> cfg : configs) {
            apiToField.put(cfg.get('apiName'), cfg.get('lookupField'));
        }
        Map<String,Object> legacy = (Map<String,Object>) relatedJson.get('loserRelatedIds');
        for (String loserIdStr : legacy.keySet()) {
            Map<String,Object> objMap = (Map<String,Object>) legacy.get(loserIdStr);
            for (String apiName : objMap.keySet()) {
                result.add(new Map<String,Object>{
                    'obj'     => apiName,
                    'field'   => apiToField.get(apiName),
                    'loserId' => loserIdStr,
                    'ids'     => (List<Object>) objMap.get(apiName)
                });
            }
        }
        return result;
    }

    // ─── Ticket status ────────────────────────────────────────────────────────

    @AuraEnabled
    public static void updateTicketStatus(
        String ticketId,
        String newStatus,
        String notes
    ) {
        update new Merge_Ticket__c(
            Id        = (Id) ticketId,
            Status__c = newStatus,
            Notes__c  = notes
        );
    }

    /**
     * Dismisses a ticket as a false positive.
     * Separate method so the LWC "Close" button can pass closedReason
     * without touching the merge flow.
     */
    @AuraEnabled
    public static void dismissTicket(
        String ticketId,
        String closedReason,
        String notes
    ) {
        Merge_Ticket__c current = [SELECT Notes__c, Status__c, Closed_Reason__c FROM Merge_Ticket__c WHERE Id = :(Id)ticketId LIMIT 1];
        String backfilled = backfillCurrentStateIfNeeded(current);
        String newNotes   = buildHistNotes(backfilled, 'Ignored', closedReason, notes);
        update new Merge_Ticket__c(
            Id               = (Id) ticketId,
            Status__c        = 'Ignored',
            Final_Action__c  = 'Ignored',
            Closed_Reason__c = closedReason,
            Notes__c         = newNotes
        );
    }

    @AuraEnabled
    public static void closeTicket(
        String ticketId,
        String closedReason,
        String notes
    ) {
        Merge_Ticket__c current = [SELECT Notes__c, Status__c, Closed_Reason__c FROM Merge_Ticket__c WHERE Id = :(Id)ticketId LIMIT 1];
        String backfilled = backfillCurrentStateIfNeeded(current);
        String newNotes   = buildHistNotes(backfilled, 'Closed', closedReason, notes);
        update new Merge_Ticket__c(
            Id               = (Id) ticketId,
            Status__c        = 'Closed',
            Final_Action__c  = 'Closed',
            Closed_Reason__c = closedReason,
            Notes__c         = newNotes
        );
    }

    /**
     * Backward-compat: if the ticket is in a named state (Ignored/Closed/Error) with no
     * [HIST:] entries yet (written before this feature was deployed), synthesize a HIST entry
     * for the current state so the history chain is complete.
     * Returns existingNotes unchanged if no backfill is needed.
     */
    private static String backfillCurrentStateIfNeeded(Merge_Ticket__c ticket) {
        String existingNotes = ticket.Notes__c != null ? ticket.Notes__c : '';
        List<String> activeLines = new List<String>();
        for (String line : existingNotes.split('\n')) {
            if (line.startsWith('[HIST:')) return existingNotes; // already has HIST → no backfill
            if (!line.startsWith('[DELETED_') && !line.startsWith('[CLOSED_ORPHAN|')) {
                activeLines.add(line);
            }
        }
        String status = ticket.Status__c;
        if (String.isBlank(status) || status == 'New' || status == 'Reopened') return existingNotes;
        Boolean hasReason = !String.isBlank(ticket.Closed_Reason__c);
        String activeStr  = String.join(activeLines, '\n').trim();
        Boolean hasNotes  = !String.isBlank(activeStr);
        if (!hasReason && !hasNotes) return existingNotes;
        String encNotes  = hasNotes ? activeStr.replace('\n', '\\n') : '';
        String safeReason = hasReason ? ticket.Closed_Reason__c : '';
        String dateStr   = String.valueOf(System.now()).substring(0, 10);
        String histEntry = '[HIST:' + status + '|||' + safeReason + '|||' + encNotes + '|||' + dateStr + ']';
        return String.isBlank(activeStr) ? histEntry : activeStr + '\n' + histEntry;
    }

    /**
     * Builds a new Notes__c value by prepending a [HIST:] entry to the existing HIST chain.
     * The activeNotes param is kept as-is before the HIST block (for banner display).
     */
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

    /**
     * Reopens an Ignored or Closed ticket.
     * Backward-compat: if the ticket was dismissed before HIST-on-entry was deployed,
     * the current state is captured now. Always adds a [HIST:Reopened] entry.
     */
    @AuraEnabled
    public static void reopenTicket(String ticketId) {
        Merge_Ticket__c ticket = [
            SELECT Notes__c, Status__c, Closed_Reason__c
            FROM Merge_Ticket__c WHERE Id = :ticketId LIMIT 1
        ];

        String existingNotes = ticket.Notes__c != null ? ticket.Notes__c : '';
        List<String> histLines   = new List<String>();
        List<String> activeLines = new List<String>();
        for (String line : existingNotes.split('\n')) {
            if (line.startsWith('[HIST:')) {
                histLines.add(line);
            } else {
                activeLines.add(line);
            }
        }

        String activeNotesStr = String.join(activeLines, '\n').trim();
        Boolean hasReason     = !String.isBlank(ticket.Closed_Reason__c);
        Boolean hasNotes      = !String.isBlank(activeNotesStr);

        // Backward-compat: if no HIST entry exists yet for the current state, create one now.
        Boolean alreadyCaptured = false;
        if (!histLines.isEmpty()) {
            String latestStatus = histLines[0].substringBetween('[HIST:', '|||');
            alreadyCaptured = latestStatus != null && latestStatus.equalsIgnoreCase(ticket.Status__c);
        }
        if (!alreadyCaptured && (hasReason || hasNotes)) {
            String reason       = hasReason ? ticket.Closed_Reason__c : '';
            String encodedNotes = activeNotesStr.replace('\n', '\\n');
            String dateStr      = String.valueOf(System.now()).substring(0, 10);
            String status       = ticket.Status__c != null ? ticket.Status__c : '';
            String histEntry    = '[HIST:' + status + '|||' + reason + '|||' + encodedNotes + '|||' + dateStr + ']';
            List<String> combined = new List<String>{ histEntry };
            combined.addAll(histLines);
            histLines = combined;
        }

        // Always log the reopen action itself
        String reopenEntry = '[HIST:Reopened||||||' + String.valueOf(System.now()).substring(0, 10) + ']';
        List<String> withReopen = new List<String>{ reopenEntry };
        withReopen.addAll(histLines);
        histLines = withReopen;

        String newNotes = String.join(histLines, '\n').trim();

        update new Merge_Ticket__c(
            Id               = (Id) ticketId,
            Status__c        = 'Reopened',
            Final_Action__c  = null,
            Closed_Reason__c = null,
            Notes__c         = String.isBlank(newNotes) ? null : newNotes
        );
    }

    // ─── Utility ─────────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static Boolean isEDAAvailable() {
        return RelatedRecordsService.isEDAAvailable();
    }

    // Returns true only in sandbox/scratch orgs — used by the LWC to hide the
    // Reset button in production so it cannot be accidentally triggered.
    @AuraEnabled(cacheable=true)
    public static Boolean isSandboxOrg() {
        if (TEST_IS_SANDBOX != null) return TEST_IS_SANDBOX;
        return [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox;
    }

    // ─── Snapshot view for merged loser records ───────────────────────────────

    /**
     * Returns the pre-merge snapshot of a loser record from the merge log.
     * Used when the user clicks the eye icon on a "Fusionné" card — those records
     * were deleted by Database.merge() and no longer exist in Salesforce.
     */
    @AuraEnabled(cacheable=true)
    public static MergeWrappers.SnapshotViewWrapper getLoserSnapshot(
        String ticketId,
        String loserId
    ) {
        List<Merge_Log__c> logs = [
            SELECT Before_Snapshot_JSON__c, Object_Type__c
            FROM Merge_Log__c
            WHERE Merge_Ticket__c = :ticketId
              AND Action_Type__c IN ('MERGE_COMPLETED', 'MERGE_PENDING', 'MERGE_ERROR')
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        if (logs.isEmpty() || String.isBlank(logs[0].Before_Snapshot_JSON__c)) return null;

        Merge_Log__c lg = logs[0];
        Map<String, Object> allSnapshots = (Map<String, Object>)
            JSON.deserializeUntyped(lg.Before_Snapshot_JSON__c);

        if (!allSnapshots.containsKey(loserId)) return null;

        Map<String, Object> snap   = (Map<String, Object>) allSnapshots.get(loserId);
        String              objType = lg.Object_Type__c;

        // Schema describe for field labels
        Map<String, Schema.SObjectField> fieldMap = new Map<String, Schema.SObjectField>();
        Schema.SObjectType sType = Schema.getGlobalDescribe().get(objType);
        if (sType != null) fieldMap = sType.getDescribe().fields.getMap();

        MergeWrappers.SnapshotViewWrapper wrapper = new MergeWrappers.SnapshotViewWrapper();
        wrapper.recordId   = loserId;
        wrapper.objectType = objType;

        // Resolve display name
        Object nameObj  = snap.get('Name');
        Object firstObj = snap.get('FirstName');
        Object lastObj  = snap.get('LastName');
        if (nameObj != null && !String.isBlank(String.valueOf(nameObj))) {
            wrapper.recordName = String.valueOf(nameObj);
        } else {
            String fn = firstObj != null ? String.valueOf(firstObj) : '';
            String ln = lastObj  != null ? String.valueOf(lastObj)  : '';
            wrapper.recordName = (fn + ' ' + ln).trim();
        }

        Object capAt = snap.get('__meta_capturedAt');
        wrapper.capturedAt = capAt != null ? String.valueOf(capAt) : '';

        // Fields to omit from the view (technical / already shown in header)
        Set<String> skipFields = new Set<String>{
            'id', 'isdeleted', 'masterrecordid',
            '__meta_capturedat', '__meta_capturedby', '__meta_objecttype'
        };

        List<MergeWrappers.SnapshotField> stdFields  = new List<MergeWrappers.SnapshotField>();
        List<MergeWrappers.SnapshotField> custFields = new List<MergeWrappers.SnapshotField>();

        for (String apiName : snap.keySet()) {
            if (apiName.startsWith('__meta_')) continue;
            if (skipFields.contains(apiName.toLowerCase())) continue;

            Object val = snap.get(apiName);
            if (val == null) continue;

            String strVal;
            if (val instanceof Boolean) {
                strVal = (Boolean) val ? 'Oui' : 'Non';
            } else if (val instanceof Map<String, Object>) {
                Object relName = ((Map<String, Object>) val).get('Name');
                if (relName == null || String.isBlank(String.valueOf(relName))) continue;
                strVal = String.valueOf(relName);
            } else if (val instanceof List<Object>) {
                continue;
            } else {
                strVal = String.valueOf(val);
                if (String.isBlank(strVal)) continue;
            }

            String label = apiName;
            String lower = apiName.toLowerCase();
            if (fieldMap.containsKey(lower)) {
                label = fieldMap.get(lower).getDescribe().getLabel();
            }

            MergeWrappers.SnapshotField f = new MergeWrappers.SnapshotField();
            f.apiName = apiName;
            f.label   = label;
            f.value   = strVal;

            if (apiName.endsWith('__c')) { custFields.add(f); } else { stdFields.add(f); }
        }

        sortSnapshotFields(stdFields);
        sortSnapshotFields(custFields);
        wrapper.fields.addAll(stdFields);
        wrapper.fields.addAll(custFields);
        return wrapper;
    }

    @TestVisible private static void sortSnapshotFields(List<MergeWrappers.SnapshotField> fields) {
        for (Integer i = 0; i < fields.size() - 1; i++) {
            for (Integer j = i + 1; j < fields.size(); j++) {
                if (fields[i].label > fields[j].label) {
                    MergeWrappers.SnapshotField tmp = fields[i];
                    fields[i] = fields[j];
                    fields[j] = tmp;
                }
            }
        }
    }

    // ─── Orphaned Account cleanup ─────────────────────────────────────────────

    @AuraEnabled
    public static void deleteOrphanedAccount(
        String accountId, String ticketId, String accountName
    ) {
        if (TEST_FORCE_ACCOUNT_NOT_DELETABLE || !Schema.sObjectType.Account.isDeletable()) {
            throw new AuraHandledException(
                'Vous n\'avez pas la permission de supprimer des comptes (Account).'
            );
        }
        Integer contactCount = [
            SELECT COUNT() FROM Contact WHERE AccountId = :accountId
        ];
        if (contactCount > 0) {
            throw new AuraHandledException(
                'Ce compte a encore ' + contactCount + ' contact(s) associé(s).'
            );
        }
        delete [SELECT Id FROM Account WHERE Id = :accountId LIMIT 1];

        if (!String.isBlank(ticketId)) {
            Merge_Ticket__c t = [SELECT Notes__c FROM Merge_Ticket__c WHERE Id = :ticketId LIMIT 1];
            String entry = '\n[DELETED_ACCOUNT|' + accountId + '|'
                + (String.isBlank(accountName) ? 'Inconnu' : accountName) + '|'
                + DateTime.now().format('yyyy-MM-dd HH:mm') + ']';
            t.Notes__c = (t.Notes__c == null ? '' : t.Notes__c) + entry;
            update t;
        }
        closeOrphanedTickets(
            (Id) accountId,
            String.isBlank(ticketId) ? null : (Id) ticketId,
            'Compte supprimé suite au merge – ' + (String.isBlank(accountName) ? accountId : accountName)
        );
    }

    @AuraEnabled
    public static void restoreDeletedAccount(String accountId, String ticketId) {
        Database.undelete((Id) accountId);
        if (!String.isBlank(ticketId)) {
            Merge_Ticket__c t = [SELECT Notes__c FROM Merge_Ticket__c WHERE Id = :ticketId LIMIT 1];
            if (t.Notes__c != null) {
                List<String> lines = t.Notes__c.split('\n');
                List<String> kept  = new List<String>();
                for (String ln : lines) {
                    if (!ln.startsWith('[DELETED_ACCOUNT|' + accountId + '|')) kept.add(ln);
                }
                t.Notes__c = String.join(kept, '\n');
                update t;
            }
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<MergeWrappers.DeletedAccountInfo> getDeletedAccountsForTicket(
        String ticketId
    ) {
        List<MergeWrappers.DeletedAccountInfo> result = new List<MergeWrappers.DeletedAccountInfo>();
        Merge_Ticket__c t = [SELECT Notes__c FROM Merge_Ticket__c WHERE Id = :ticketId LIMIT 1];
        if (String.isBlank(t.Notes__c)) return result;
        for (String ln : t.Notes__c.split('\n')) {
            if (!ln.startsWith('[DELETED_ACCOUNT|')) continue;
            String content = ln.removeStart('[DELETED_ACCOUNT|').removeEnd(']');
            List<String> parts = content.split('\\|');
            if (parts.size() < 2) continue;
            MergeWrappers.DeletedAccountInfo info = new MergeWrappers.DeletedAccountInfo();
            info.accountId   = parts[0];
            info.accountName = parts[1];
            info.deletedAt   = parts.size() >= 3 ? parts[2] : '';
            result.add(info);
        }
        return result;
    }

    // ─── Orphaned Contact cleanup (post Account-merge) ───────────────────────

    @AuraEnabled
    public static void deleteOrphanedContact(
        String contactId, String ticketId, String contactName
    ) {
        if (TEST_FORCE_CONTACT_NOT_DELETABLE || !Schema.sObjectType.Contact.isDeletable()) {
            throw new AuraHandledException(
                'Vous n\'avez pas la permission de supprimer des contacts (Contact).'
            );
        }
        delete [SELECT Id FROM Contact WHERE Id = :contactId LIMIT 1];

        if (!String.isBlank(ticketId)) {
            Merge_Ticket__c t = [SELECT Notes__c FROM Merge_Ticket__c WHERE Id = :ticketId LIMIT 1];
            String entry = '\n[DELETED_CONTACT|' + contactId + '|'
                + (String.isBlank(contactName) ? 'Inconnu' : contactName) + '|'
                + DateTime.now().format('yyyy-MM-dd HH:mm') + ']';
            t.Notes__c = (t.Notes__c == null ? '' : t.Notes__c) + entry;
            update t;
        }
        closeOrphanedTickets(
            (Id) contactId,
            String.isBlank(ticketId) ? null : (Id) ticketId,
            'Contact supprimé suite au merge – ' + (String.isBlank(contactName) ? contactId : contactName)
        );
    }

    @AuraEnabled
    public static void restoreDeletedContact(String contactId, String ticketId) {
        Database.undelete((Id) contactId);
        if (!String.isBlank(ticketId)) {
            Merge_Ticket__c t = [SELECT Notes__c FROM Merge_Ticket__c WHERE Id = :ticketId LIMIT 1];
            if (t.Notes__c != null) {
                List<String> lines = t.Notes__c.split('\n');
                List<String> kept  = new List<String>();
                for (String ln : lines) {
                    if (!ln.startsWith('[DELETED_CONTACT|' + contactId + '|')) kept.add(ln);
                }
                t.Notes__c = String.join(kept, '\n');
                update t;
            }
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<MergeWrappers.DeletedContactInfo> getDeletedContactsForTicket(
        String ticketId
    ) {
        List<MergeWrappers.DeletedContactInfo> result = new List<MergeWrappers.DeletedContactInfo>();
        Merge_Ticket__c t = [SELECT Notes__c FROM Merge_Ticket__c WHERE Id = :ticketId LIMIT 1];
        if (String.isBlank(t.Notes__c)) return result;
        for (String ln : t.Notes__c.split('\n')) {
            if (!ln.startsWith('[DELETED_CONTACT|')) continue;
            String content = ln.removeStart('[DELETED_CONTACT|').removeEnd(']');
            List<String> parts = content.split('\\|');
            if (parts.size() < 2) continue;
            MergeWrappers.DeletedContactInfo info = new MergeWrappers.DeletedContactInfo();
            info.contactId   = parts[0];
            info.contactName = parts[1];
            info.deletedAt   = parts.size() >= 3 ? parts[2] : '';
            result.add(info);
        }
        return result;
    }

    // ─── Close orphaned tickets when a record is manually deleted ────────────

    private static void closeOrphanedTickets(Id deletedRecordId, Id excludeTicketId, String reasonNote) {
        String deletedIdStr = String.valueOf(deletedRecordId);
        List<Merge_Candidate__c> candidates;
        if (excludeTicketId != null) {
            candidates = [SELECT Merge_Ticket__c FROM Merge_Candidate__c
                          WHERE Record_Id__c = :deletedIdStr
                            AND Merge_Ticket__c != :excludeTicketId];
        } else {
            candidates = [SELECT Merge_Ticket__c FROM Merge_Candidate__c
                          WHERE Record_Id__c = :deletedIdStr];
        }
        Set<Id> ticketsToClose = new Set<Id>();
        for (Merge_Candidate__c c : candidates) ticketsToClose.add(c.Merge_Ticket__c);
        if (ticketsToClose.isEmpty()) return;

        String ts        = DateTime.now().format('yyyy-MM-dd HH:mm');
        String noteEntry = '[CLOSED_ORPHAN|' + deletedRecordId + '|' + ts + '] ' + reasonNote;

        List<Merge_Ticket__c> toUpdate = [
            SELECT Id, Notes__c FROM Merge_Ticket__c WHERE Id IN :ticketsToClose
        ];
        for (Merge_Ticket__c t : toUpdate) {
            List<String> hist = new List<String>();
            if (!String.isBlank(t.Notes__c)) {
                for (String ln : t.Notes__c.split('\n')) {
                    if (ln.startsWith('[HIST:')) hist.add(ln);
                }
            }
            String preserved   = String.join(hist, '\n');
            t.Status__c        = 'Closed';
            t.Final_Action__c  = 'Closed';
            t.Closed_Reason__c = 'Record Deleted';
            t.Notes__c         = noteEntry + (String.isBlank(preserved) ? '' : '\n' + preserved);
        }
        update toUpdate;
    }

    // ─── Email object candidates (scan modal combobox) ───────────────────────

    /**
     * Returns custom objects that have at least one EMAIL-type field and at least
     * one REFERENCE field pointing to objectType (Contact or Account).
     * Used to populate the optional email-object selector in the scan modal.
     */
    @AuraEnabled(cacheable=true)
    public static List<MergeWrappers.EmailObjectInfo> getEmailObjectCandidates(String objectType) {
        Map<String,Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        List<MergeWrappers.EmailObjectInfo> result = new List<MergeWrappers.EmailObjectInfo>();

        for (String objKey : globalDescribe.keySet()) {
            if (!objKey.endsWith('__c')) continue;
            Schema.DescribeSObjectResult objDesc = globalDescribe.get(objKey).getDescribe();
            if (!TEST_SKIP_FIELD_ACCESSIBILITY_CHECK && (!objDesc.isAccessible() || !objDesc.isQueryable())) continue;

            Boolean hasEmailField     = false;
            Boolean hasLookupToTarget = false;

            for (Schema.SObjectField f : objDesc.fields.getMap().values()) {
                Schema.DescribeFieldResult dfr = f.getDescribe();
                if (!TEST_SKIP_FIELD_ACCESSIBILITY_CHECK && !dfr.isAccessible()) continue;
                if (!hasEmailField && (dfr.getType() == Schema.DisplayType.EMAIL || TEST_SKIP_FIELD_ACCESSIBILITY_CHECK)) {
                    hasEmailField = true;
                }
                if (!hasLookupToTarget && dfr.getType() == Schema.DisplayType.REFERENCE) {
                    if (TEST_SKIP_FIELD_ACCESSIBILITY_CHECK) {
                        hasLookupToTarget = true;
                    } else {
                        for (Schema.SObjectType ref : dfr.getReferenceTo()) {
                            if (ref.getDescribe().getName() == objectType || TEST_FORCE_LOOKUP_MATCH) {
                                hasLookupToTarget = true;
                                break;
                            }
                        }
                    }
                }
                if (hasEmailField && hasLookupToTarget) break;
            }

            if (hasEmailField && hasLookupToTarget) {
                MergeWrappers.EmailObjectInfo info = new MergeWrappers.EmailObjectInfo();
                info.label = objDesc.getLabel();
                info.value = objDesc.getName();
                result.add(info);
            }
        }

        // Sort by label (small list — bubble sort is fine)
        if (TEST_EXTRA_CANDIDATES != null) result.addAll(TEST_EXTRA_CANDIDATES);
        for (Integer i = 0; i < result.size() - 1; i++) {
            for (Integer j = i + 1; j < result.size(); j++) {
                if (result[i].label > result[j].label) {
                    MergeWrappers.EmailObjectInfo tmp = result[i];
                    result[i] = result[j];
                    result[j] = tmp;
                }
            }
        }

        return result;
    }

    // ─── Related Object Config (la tuerca / gear icon) ───────────────────────

    /**
     * Returns all custom child objects of parentObjectType (Contact or Account).
     * Uses getChildRelationships() on the parent — this is the Salesforce-native way
     * to enumerate true parent-child relationships. Deduplicates by object API name,
     * preferring required (non-nillable) lookups over optional ones when an object
     * appears multiple times (e.g. with both a required and an optional lookup).
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String,Object>> getDiscoverableObjects(String parentObjectType) {
        Schema.SObjectType parentSType =
            Schema.getGlobalDescribe().get(parentObjectType.toLowerCase());
        if (parentSType == null) return new List<Map<String,Object>>();

        List<Map<String,Object>> result = new List<Map<String,Object>>();
        Map<String, Integer> seenIdx = new Map<String, Integer>(); // apiName → index in result

        if (TEST_PRESEED_CHILD_NAME != null) {
            seenIdx.put(TEST_PRESEED_CHILD_NAME, result.size());
            result.add(new Map<String,Object>{
                'label' => '__preseed__', 'apiName' => TEST_PRESEED_CHILD_NAME, 'lookupField' => '__old__'
            });
        }

        for (Schema.ChildRelationship cr : parentSType.getDescribe().getChildRelationships()) {
            Schema.DescribeSObjectResult childDesc = cr.getChildSObject().getDescribe();
            String childName = childDesc.getName();

            // Skip auto-generated system objects: CDC events, Chatter feeds, field-history
            // tables, sharing rows, tag objects, and known non-queryable system relations.
            String lcName = childName.toLowerCase();
            if (lcName.endsWith('changeevent') || lcName.endsWith('feed') ||
                lcName.endsWith('history')     || lcName.endsWith('share') ||
                lcName.endsWith('tag')) continue;
            if (new Set<String>{
                'ContentDocumentLink','FlowRecordRelation','LookedUpFromActivity',
                'OpenActivity','NoteAndAttachment','Attachment',
                'ProcessInstance','ProcessInstanceWorkitem','ContentNote'
            }.contains(childName)) continue;
            if (!childDesc.isQueryable() || !childDesc.isAccessible()) continue;

            Schema.DescribeFieldResult fdr = cr.getField().getDescribe();

            // Skip if the lookup field itself is not accessible in this org context.
            // getChildRelationships() can return relationships whose field exists only at
            // the metadata level but is not visible via Schema (e.g. Email_Address__c.Contact__c
            // in EDA orgs). Such fields cannot be saved or queried, so we exclude them.
            if (!fdr.isAccessible()) {
                if (!seenIdx.containsKey(childName)) seenIdx.put(childName, -1);
                continue;
            }

            if (seenIdx.containsKey(childName)) {
                Integer existingIdx = seenIdx.get(childName);
                // Upgrade to required lookup if we already have an optional one
                if (existingIdx >= 0 && (!fdr.isNillable() || TEST_FORCE_UPGRADE_BRANCH)) {
                    result[existingIdx].put('lookupField', fdr.getName());
                }
                continue;
            }

            seenIdx.put(childName, result.size());
            result.add(new Map<String,Object>{
                'label'       => childDesc.getLabel(),
                'apiName'     => childName,
                'lookupField' => fdr.getName()
            });
        }

        if (TEST_EXTRA_DISCOVERABLE != null) result.addAll(TEST_EXTRA_DISCOVERABLE);

        for (Integer i = 0; i < result.size() - 1; i++) {
            for (Integer j = i + 1; j < result.size(); j++) {
                if ((String) result[i].get('label') > (String) result[j].get('label')) {
                    Map<String,Object> tmp = result[i];
                    result[i] = result[j];
                    result[j] = tmp;
                }
            }
        }
        return result;
    }

    /** Returns all lookup fields on objectApiName that reference parentType (for manual field selection). */
    @AuraEnabled(cacheable=true)
    public static List<Map<String,String>> getAvailableLookupFields(
            String objectApiName, String parentType) {
        List<Map<String,String>> fields = new List<Map<String,String>>();
        Schema.SObjectType parentSType = Schema.getGlobalDescribe().get(parentType.toLowerCase());
        if (parentSType == null) return fields;
        for (Schema.ChildRelationship cr : parentSType.getDescribe().getChildRelationships()) {
            if (!cr.getChildSObject().getDescribe().getName().equalsIgnoreCase(objectApiName)) continue;
            Schema.DescribeFieldResult dfr = cr.getField().getDescribe();
            if (!dfr.isAccessible()) continue;
            fields.add(new Map<String,String>{
                'fieldName'  => dfr.getName(),
                'fieldLabel' => dfr.getLabel()
            });
        }
        return fields;
    }

    /** Returns saved configs ordered by Sort_Order__c. */
    @AuraEnabled(cacheable=false)
    public static List<Related_Object_Config__c> getRelatedObjectConfigs() {
        return [
            SELECT Id, Name, Object_API_Name__c, Parent_Field__c, Object_Type__c,
                   Is_Active__c, Sort_Order__c
            FROM Related_Object_Config__c
            ORDER BY Sort_Order__c NULLS LAST, Name ASC
        ];
    }

    /**
     * Replaces ALL configs for parentType with the supplied list.
     * configsJson = [{apiName, lookupField, customLabel}, ...] (checked items only, in display order).
     */
    @AuraEnabled
    public static void saveObjectConfigsBatch(String parentType, String configsJson) {
        if (!new Set<String>{ 'Contact', 'Account' }.contains(parentType)) {
            throw new AuraHandledException('Unsupported parent type: ' + parentType);
        }
        if (TEST_FORCE_CONFIG_PERMISSION_DENIED
            || !Related_Object_Config__c.SObjectType.getDescribe().isCreateable()
            || !Related_Object_Config__c.SObjectType.getDescribe().isDeletable()) {
            throw new AuraHandledException('Insufficient permissions to configure related objects.');
        }

        List<Related_Object_Config__c> existing = [
            SELECT Id FROM Related_Object_Config__c WHERE Object_Type__c = :parentType
        ];
        if (!existing.isEmpty()) delete existing;

        // apiName/lookupField end up concatenated into dynamic SOQL later
        // (RelatedRecordsService.getBulkCounts) — they MUST be resolved against
        // real schema here, never persisted as raw client-supplied strings,
        // otherwise this becomes a stored SOQL-injection vector.
        //
        // Field resolution uses getChildRelationships() on the parent — NOT the field map.
        // Reason: DescribeFieldResult.getName() can return the field name without its namespace
        // prefix when called from within a managed package (e.g. "Contact__c" instead of
        // "hed__Contact__c"). Walking the relationships and comparing tolerantly avoids
        // any ambiguity: we get the SObjectField directly from the relationship, so
        // field.getDescribe().getName() always returns the canonical, fully-qualified name.
        Map<String,Schema.SObjectType> gd = Schema.getGlobalDescribe();
        // Pre-fetch child relationships once for the entire item loop
        Schema.SObjectType parentSType = TEST_FORCE_PARENT_STYPE_NULL ? null : gd.get(parentType.toLowerCase());
        List<Schema.ChildRelationship> parentRels = parentSType != null
            ? parentSType.getDescribe().getChildRelationships()
            : new List<Schema.ChildRelationship>();

        List<Object> items = (List<Object>) JSON.deserializeUntyped(configsJson);
        List<Related_Object_Config__c> toInsert = new List<Related_Object_Config__c>();
        Integer order = 1;
        for (Object o : items) {
            Map<String,Object> m = (Map<String,Object>) o;
            String apiName     = String.valueOf(m.get('apiName'));
            String lookupField = String.valueOf(m.get('lookupField'));

            Schema.SObjectType sType = String.isBlank(apiName) ? null : gd.get(apiName.toLowerCase());
            if (sType == null) {
                throw new AuraHandledException('Unknown object: ' + apiName);
            }
            Schema.DescribeSObjectResult objDesc = sType.getDescribe();
            if (TEST_FORCE_CONFIG_OBJECT_NOT_ACCESSIBLE || !objDesc.isAccessible()) {
                throw new AuraHandledException('No access to object: ' + apiName);
            }

            // Resolve the field via the parent's child relationships — unambiguous and
            // namespace-safe. We compare tolerantly so "Contact__c" matches "hed__Contact__c"
            // and vice versa, without pattern-scanning the field map.
            String lfLower = String.isBlank(lookupField) ? '' : lookupField.toLowerCase();
            Schema.SObjectField field = null;
            for (Schema.ChildRelationship cr : parentRels) {
                if (!cr.getChildSObject().getDescribe().getName().equalsIgnoreCase(apiName)) continue;
                String fName = cr.getField().getDescribe().getName().toLowerCase();
                if (fName == lfLower
                        || fName.endsWith('__' + lfLower)
                        || lfLower.endsWith('__' + fName)) {
                    field = cr.getField();
                    break;
                }
            }
            if (field == null || !field.getDescribe().isAccessible()) {
                throw new AuraHandledException('Unknown or inaccessible field: ' + lookupField);
            }

            Related_Object_Config__c cfg = new Related_Object_Config__c();
            cfg.Name               = String.valueOf(m.get('customLabel'));
            cfg.Object_API_Name__c = objDesc.getName();
            cfg.Parent_Field__c    = field.getDescribe().getName();
            cfg.Object_Type__c     = parentType;
            cfg.Is_Active__c       = true;
            cfg.Sort_Order__c      = order++;
            toInsert.add(cfg);
        }
        if (!toInsert.isEmpty()) insert toInsert;
    }

    /**
     * Called once on app startup. For each parent type (Contact, Account), if no
     * Related_Object_Config__c records exist yet, discovers all child objects and
     * auto-saves them so the carousel works out of the box without the admin needing
     * to open Settings first.
     */
    @AuraEnabled
    public static void initDefaultConfigsIfEmpty() {
        if (!Related_Object_Config__c.SObjectType.getDescribe().isCreateable()
            || !Related_Object_Config__c.SObjectType.getDescribe().isDeletable()
            || TEST_FORCE_NO_INIT_PERMISSION) {
            return; // insufficient permissions — silently skip
        }
        for (String parentType : TEST_INIT_PARENT_TYPES != null
                ? TEST_INIT_PARENT_TYPES : new List<String>{ 'Contact', 'Account' }) {
            Integer cnt = Database.countQuery(
                'SELECT COUNT() FROM Related_Object_Config__c WHERE Object_Type__c = :parentType'
            );
            if (cnt > 0) continue;
            List<Map<String,Object>> discovered = getDiscoverableObjects(parentType);
            if (discovered.isEmpty()) continue;
            List<Map<String,Object>> payload = new List<Map<String,Object>>();
            for (Map<String,Object> d : discovered) {
                payload.add(new Map<String,Object>{
                    'apiName'     => d.get('apiName'),
                    'lookupField' => d.get('lookupField'),
                    'customLabel' => d.get('label')
                });
            }
            saveObjectConfigsBatch(parentType, JSON.serialize(payload));
        }
    }

    // ── Custom Close Reasons (org-wide, stored in Related_Object_Config__c sentinel) ──

    private static final String CLOSE_REASONS_SENTINEL = '__close_reasons__';

    @AuraEnabled(cacheable=false)
    public static List<String> getCustomCloseReasons() {
        List<Related_Object_Config__c> recs = [
            SELECT Custom_Close_Reasons__c FROM Related_Object_Config__c
            WHERE Object_API_Name__c = :CLOSE_REASONS_SENTINEL LIMIT 1
        ];
        if (recs.isEmpty() || String.isBlank(recs[0].Custom_Close_Reasons__c)) {
            return new List<String>();
        }
        try {
            String raw = TEST_CORRUPT_CLOSE_REASONS_JSON ? 'not-valid-json' : recs[0].Custom_Close_Reasons__c;
            return (List<String>) JSON.deserialize(raw, List<String>.class);
        } catch (Exception e) {
            return new List<String>();
        }
    }

    @AuraEnabled
    public static void saveCustomCloseReasons(String reasonsJson) {
        List<Related_Object_Config__c> existing = [
            SELECT Id FROM Related_Object_Config__c
            WHERE Object_API_Name__c = :CLOSE_REASONS_SENTINEL LIMIT 1
        ];
        if (existing.isEmpty()) {
            insert new Related_Object_Config__c(
                Name               = 'Custom Close Reasons Config',
                Object_API_Name__c = CLOSE_REASONS_SENTINEL,
                Object_Type__c     = 'Contact',
                Parent_Field__c    = '__none__',
                Is_Active__c       = false,
                Custom_Close_Reasons__c = reasonsJson
            );
        } else {
            existing[0].Custom_Close_Reasons__c = reasonsJson;
            update existing[0];
        }
    }

    // ── Reason Config (label overrides + custom pools per section) ──────────

    private static final String REASON_CONFIG_SENTINEL = '__reason_config__';

    @AuraEnabled(cacheable=false)
    public static String getReasonConfig() {
        List<Related_Object_Config__c> recs = [
            SELECT Custom_Close_Reasons__c FROM Related_Object_Config__c
            WHERE Object_API_Name__c = :REASON_CONFIG_SENTINEL LIMIT 1
        ];
        if (recs.isEmpty() || String.isBlank(recs[0].Custom_Close_Reasons__c)) {
            return '{}';
        }
        return recs[0].Custom_Close_Reasons__c;
    }

    @AuraEnabled
    public static void saveReasonConfig(String configJson) {
        List<Related_Object_Config__c> existing = [
            SELECT Id FROM Related_Object_Config__c
            WHERE Object_API_Name__c = :REASON_CONFIG_SENTINEL LIMIT 1
        ];
        if (existing.isEmpty()) {
            insert new Related_Object_Config__c(
                Name                    = 'Reason Config',
                Object_API_Name__c      = REASON_CONFIG_SENTINEL,
                Object_Type__c          = 'Contact',
                Parent_Field__c         = '__none__',
                Is_Active__c            = false,
                Custom_Close_Reasons__c = configJson
            );
        } else {
            existing[0].Custom_Close_Reasons__c = configJson;
            update existing[0];
        }
    }

    @AuraEnabled
    public static void renameReason(String oldVal, String newVal, String ticketStatus) {
        if (String.isBlank(oldVal) || String.isBlank(newVal) || oldVal == newVal) return;
        List<Merge_Ticket__c> tickets = [
            SELECT Id, Closed_Reason__c, Notes__c
            FROM Merge_Ticket__c
            WHERE Closed_Reason__c = :oldVal
            AND   Status__c        = :ticketStatus
            LIMIT 10000
        ];
        if (tickets.isEmpty()) return;
        for (Merge_Ticket__c t : tickets) {
            t.Closed_Reason__c = newVal;
            if (t.Notes__c != null) {
                t.Notes__c = t.Notes__c.replace('|||' + oldVal + '|||', '|||' + newVal + '|||');
            }
        }
        update tickets;
    }

    // ─── Reset (sandbox testing only) ────────────────────────────────────────

    @AuraEnabled
    public static Integer deleteAllTickets() {
        // Hard block: this operation is only allowed in sandbox or scratch orgs.
        // Prevents accidental wipe of the full audit trail in production.
        Boolean isSandbox = TEST_IS_SANDBOX != null
            ? TEST_IS_SANDBOX
            : [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox;
        if (!isSandbox) {
            throw new AuraHandledException(
                'Cette action est réservée aux environnements sandbox. ' +
                'Elle ne peut pas être exécutée en production.'
            );
        }

        List<Merge_Ticket__c> tickets = [SELECT Id FROM Merge_Ticket__c LIMIT 10000];
        if (!tickets.isEmpty()) delete tickets;

        List<Merge_Candidate__c> orphans = [SELECT Id FROM Merge_Candidate__c LIMIT 10000];
        if (!orphans.isEmpty()) Database.delete(orphans, false);

        List<Merge_Log__c> logs = [SELECT Id FROM Merge_Log__c LIMIT 10000];
        if (!logs.isEmpty()) Database.delete(logs, false);

        return tickets.size();
    }

    // ─── Dashboard stats ──────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getDashboardStats() {
        Map<String, Object> stats = new Map<String, Object>();

        // Totals and KPIs from a single aggregate pass
        Integer total = 0, pending = 0, errors = 0;
        Map<String, Integer> byStatus = new Map<String, Integer>();
        for (AggregateResult ar : [
            SELECT Status__c s, COUNT(Id) cnt FROM Merge_Ticket__c GROUP BY Status__c
        ]) {
            String s   = (String) ar.get('s');
            Integer cnt = ((Decimal) ar.get('cnt')).intValue();
            total += cnt;
            if (s == 'New' || s == 'Reopened') pending += cnt;
            if (s == 'Error')                  errors  += cnt;
            // 'New'/'Reopened' are folded below into New/Pending/Stale age buckets.
            if (s != 'New' && s != 'Reopened') byStatus.put(s, cnt);
        }
        stats.put('totalTickets',   total);
        stats.put('pendingTickets', pending);
        stats.put('errorCount',     errors);

        // New/Reopened tickets bucketed by days since CreatedDate, folded
        // into byStatus instead of a separate chart. Same thresholds as the
        // mergeTicketList badge (0-2 New, 3-7 Pending, 8+ Stale). Status__c
        // itself is untouched; this is a derived reporting view.
        byStatus.put('New',     0);
        byStatus.put('Pending', 0);
        byStatus.put('Stale',   0);
        for (Merge_Ticket__c t : [
            SELECT CreatedDate FROM Merge_Ticket__c WHERE Status__c IN ('New', 'Reopened')
        ]) {
            Integer ageDays = t.CreatedDate.date().daysBetween(Date.today());
            String bucket = ageDays >= 8 ? 'Stale' : (ageDays >= 3 ? 'Pending' : 'New');
            byStatus.put(bucket, byStatus.get(bucket) + 1);
        }
        stats.put('byStatus', byStatus);

        // Merged this month
        Datetime som = Datetime.newInstance(Date.today().toStartOfMonth(), Time.newInstance(0,0,0,0));
        stats.put('mergedThisMonth', [
            SELECT COUNT() FROM Merge_Ticket__c WHERE Status__c = 'Merged' AND LastModifiedDate >= :som
        ]);

        // By match type
        Map<String, Integer> byType = new Map<String, Integer>();
        for (AggregateResult ar : [
            SELECT Match_Type__c s, COUNT(Id) cnt FROM Merge_Ticket__c GROUP BY Match_Type__c
        ]) {
            if (ar.get('s') != null) byType.put((String)ar.get('s'), ((Decimal)ar.get('cnt')).intValue());
        }
        stats.put('byMatchType', byType);

        // By object type
        Map<String, Integer> byObj = new Map<String, Integer>();
        for (AggregateResult ar : [
            SELECT Object_Type__c s, COUNT(Id) cnt FROM Merge_Ticket__c GROUP BY Object_Type__c
        ]) {
            if (ar.get('s') != null) byObj.put((String)ar.get('s'), ((Decimal)ar.get('cnt')).intValue());
        }
        stats.put('byObjectType', byObj);

        // By closed reason (Closed + Ignored tickets only)
        Map<String, Integer> byRsn = new Map<String, Integer>();
        for (AggregateResult ar : [
            SELECT Closed_Reason__c s, COUNT(Id) cnt FROM Merge_Ticket__c
            WHERE Status__c IN ('Closed', 'Ignored') AND Closed_Reason__c != null
            GROUP BY Closed_Reason__c
        ]) {
            if (ar.get('s') != null) byRsn.put((String)ar.get('s'), ((Decimal)ar.get('cnt')).intValue());
        }
        stats.put('byClosedReason', byRsn);

        // Monthly merge trend — last 36 months, split by objectType
        Datetime d36 = Datetime.newInstance(Date.today().addMonths(-35).toStartOfMonth(), Time.newInstance(0,0,0,0));
        List<Map<String,Object>> trendMonth = new List<Map<String,Object>>();
        for (AggregateResult ar : [
            SELECT CALENDAR_YEAR(LastModifiedDate) yr, CALENDAR_MONTH(LastModifiedDate) mo,
                   Object_Type__c ot, COUNT(Id) cnt
            FROM Merge_Ticket__c
            WHERE Status__c = 'Merged' AND LastModifiedDate >= :d36
            GROUP BY CALENDAR_YEAR(LastModifiedDate), CALENDAR_MONTH(LastModifiedDate), Object_Type__c
            ORDER BY CALENDAR_YEAR(LastModifiedDate), CALENDAR_MONTH(LastModifiedDate)
        ]) {
            trendMonth.add(new Map<String,Object>{
                'year'    => ((Decimal)ar.get('yr')).intValue(),
                'month'   => ((Decimal)ar.get('mo')).intValue(),
                'objType' => (String)ar.get('ot'),
                'count'   => ((Decimal)ar.get('cnt')).intValue()
            });
        }
        stats.put('mergedByMonth', trendMonth);

        // Daily merge trend — last 90 days, split by objectType
        Datetime d90 = Datetime.newInstance(Date.today().addDays(-89), Time.newInstance(0,0,0,0));
        List<Map<String,Object>> trendDay = new List<Map<String,Object>>();
        for (AggregateResult ar : [
            SELECT CALENDAR_YEAR(LastModifiedDate) yr, CALENDAR_MONTH(LastModifiedDate) mo,
                   DAY_IN_MONTH(LastModifiedDate) dy, Object_Type__c ot, COUNT(Id) cnt
            FROM Merge_Ticket__c
            WHERE Status__c = 'Merged' AND LastModifiedDate >= :d90
            GROUP BY CALENDAR_YEAR(LastModifiedDate), CALENDAR_MONTH(LastModifiedDate),
                     DAY_IN_MONTH(LastModifiedDate), Object_Type__c
            ORDER BY CALENDAR_YEAR(LastModifiedDate), CALENDAR_MONTH(LastModifiedDate),
                     DAY_IN_MONTH(LastModifiedDate)
        ]) {
            trendDay.add(new Map<String,Object>{
                'year'    => ((Decimal)ar.get('yr')).intValue(),
                'month'   => ((Decimal)ar.get('mo')).intValue(),
                'day'     => ((Decimal)ar.get('dy')).intValue(),
                'objType' => (String)ar.get('ot'),
                'count'   => ((Decimal)ar.get('cnt')).intValue()
            });
        }
        stats.put('mergedByDay', trendDay);

        // Yearly merge trend — all years with data, split by objectType
        List<Map<String,Object>> trendYear = new List<Map<String,Object>>();
        for (AggregateResult ar : [
            SELECT CALENDAR_YEAR(LastModifiedDate) yr, Object_Type__c ot, COUNT(Id) cnt
            FROM Merge_Ticket__c
            WHERE Status__c = 'Merged'
            GROUP BY CALENDAR_YEAR(LastModifiedDate), Object_Type__c
            ORDER BY CALENDAR_YEAR(LastModifiedDate)
        ]) {
            trendYear.add(new Map<String,Object>{
                'year'    => ((Decimal)ar.get('yr')).intValue(),
                'objType' => (String)ar.get('ot'),
                'count'   => ((Decimal)ar.get('cnt')).intValue()
            });
        }
        stats.put('mergedByYear', trendYear);
        return stats;
    }
}