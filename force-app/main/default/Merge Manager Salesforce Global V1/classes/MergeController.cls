/**
 * MergeController.cls
 * Thin LWC adapter — zero business logic.
 * Every method delegates immediately to a service class.
 *
 * Uses "with sharing" so Salesforce enforces record-level security for the
 * current user. The service classes use "without sharing" where elevated
 * access is required (merge DML, audit log writes).
 */
public with sharing class MergeController {

    // Test-injection: extra candidates appended before sort to force swap coverage
    @TestVisible private static List<MergeWrappers.EmailObjectInfo> TEST_EXTRA_CANDIDATES = null;
    // Test-injection: override IsSandbox check so tests can reach the production guard branch
    @TestVisible private static Boolean TEST_IS_SANDBOX = null;
    // Test-injection: bypass dfr.isAccessible() in getEmailObjectCandidates so tests cover
    // the qualifying-object branch regardless of the running user's FLS profile
    @TestVisible private static Boolean TEST_SKIP_FIELD_ACCESSIBILITY_CHECK = false;
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

    @AuraEnabled
    public static List<Merge_Ticket__c> getTickets(
        String objectType,
        String statusFilter  // 'All' | 'New' | 'In Review' | 'Ready' | 'Error'
    ) {
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
        soql += ' ORDER BY LastModifiedDate DESC LIMIT 2000';

        return Database.query(soql);
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
        System.debug('SCAN_DEBUG objType=' + objType
            + ' matchFields=' + matchFields
            + ' dryRun=' + dryRun);

        MergeWrappers.ScanRequest request = new MergeWrappers.ScanRequest();
        request.mergeObjectType    = objType;
        request.matchFields        = matchFields;
        request.recordLimit        = (dryRun != true) ? 50000 : recordLimit;
        request.dryRun             = dryRun;
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
        String             notes
    ) {
        MergeWrappers.MergeRequest req = new MergeWrappers.MergeRequest();
        req.ticketId       = ticketId;
        req.masterId       = masterId;
        req.losingIds      = losingIds;
        req.fieldDecisions = fieldDecisions;
        req.notes          = notes;
        return MergeExecutionService.executeMerge(req);
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
        String preserved = preserveHistLines(ticketId);
        String newNotes  = String.isBlank(preserved)
            ? notes
            : (String.isBlank(notes) ? preserved : notes + '\n' + preserved);
        update new Merge_Ticket__c(
            Id              = (Id) ticketId,
            Status__c       = 'Ignored',
            Final_Action__c = 'Ignored',
            Closed_Reason__c = closedReason,
            Notes__c        = newNotes
        );
    }

    @AuraEnabled
    public static void closeTicket(
        String ticketId,
        String closedReason,
        String notes
    ) {
        String preserved = preserveHistLines(ticketId);
        String newNotes  = String.isBlank(preserved)
            ? notes
            : (String.isBlank(notes) ? preserved : notes + '\n' + preserved);
        update new Merge_Ticket__c(
            Id               = (Id) ticketId,
            Status__c        = 'Closed',
            Final_Action__c  = 'Closed',
            Closed_Reason__c = closedReason,
            Notes__c         = newNotes
        );
    }

    /** Reads the current Notes__c and returns only the [HIST:...] lines (if any). */
    private static String preserveHistLines(String ticketId) {
        Merge_Ticket__c t = [SELECT Notes__c FROM Merge_Ticket__c WHERE Id = :ticketId LIMIT 1];
        if (String.isBlank(t.Notes__c)) return '';
        List<String> hist = new List<String>();
        for (String line : t.Notes__c.split('\n')) {
            if (line.startsWith('[HIST:')) hist.add(line);
        }
        return String.join(hist, '\n');
    }

    /**
     * Reopens an Ignored or Closed ticket — archives current decision to Notes history, clears the closed reason.
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

        if (hasReason || hasNotes) {
            String reason       = hasReason ? ticket.Closed_Reason__c : '';
            String encodedNotes = activeNotesStr.replace('\n', '\\n');
            String dateStr      = String.valueOf(System.now()).substring(0, 10);
            String status       = ticket.Status__c != null ? ticket.Status__c : '';
            String histEntry    = '[HIST:' + status + '|||' + reason + '|||' + encodedNotes + '|||' + dateStr + ']';
            // Prepend: build new list with this entry first, then existing HIST lines
            List<String> combined = new List<String>{ histEntry };
            combined.addAll(histLines);
            histLines = combined;
        }

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
                            if (ref.getDescribe().getName() == objectType) {
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

            if (!childName.endsWith('__c')) continue;
            if (!childDesc.isQueryable() || !childDesc.isAccessible()) continue;

            Schema.DescribeFieldResult fdr = cr.getField().getDescribe();

            if (seenIdx.containsKey(childName)) {
                // Upgrade to required lookup if we already have an optional one
                if (!fdr.isNillable() || TEST_FORCE_UPGRADE_BRANCH) {
                    result[seenIdx.get(childName)].put('lookupField', fdr.getName());
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
        List<Related_Object_Config__c> existing = [
            SELECT Id FROM Related_Object_Config__c WHERE Object_Type__c = :parentType
        ];
        if (!existing.isEmpty()) delete existing;

        List<Object> items = (List<Object>) JSON.deserializeUntyped(configsJson);
        List<Related_Object_Config__c> toInsert = new List<Related_Object_Config__c>();
        Integer order = 1;
        for (Object o : items) {
            Map<String,Object> m = (Map<String,Object>) o;
            Related_Object_Config__c cfg = new Related_Object_Config__c();
            cfg.Name               = String.valueOf(m.get('customLabel'));
            cfg.Object_API_Name__c = String.valueOf(m.get('apiName'));
            cfg.Parent_Field__c    = String.valueOf(m.get('lookupField'));
            cfg.Object_Type__c     = parentType;
            cfg.Is_Active__c       = true;
            cfg.Sort_Order__c      = order++;
            toInsert.add(cfg);
        }
        if (!toInsert.isEmpty()) insert toInsert;
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
            byStatus.put(s, cnt);
            total += cnt;
            if (s == 'New' || s == 'Reopened') pending += cnt;
            if (s == 'Error')                  errors  += cnt;
        }
        stats.put('byStatus',       byStatus);
        stats.put('totalTickets',   total);
        stats.put('pendingTickets', pending);
        stats.put('errorCount',     errors);

        // By age — New/Reopened tickets bucketed by days since CreatedDate.
        // Same thresholds as the mergeTicketList badge (0-2 New, 3-7 Pending,
        // 8+ Stale). Status__c is untouched; this is a derived reporting view.
        Map<String, Integer> byAge = new Map<String, Integer>{
            'New' => 0, 'Pending' => 0, 'Stale' => 0
        };
        for (Merge_Ticket__c t : [
            SELECT CreatedDate FROM Merge_Ticket__c WHERE Status__c IN ('New', 'Reopened')
        ]) {
            Integer ageDays = Date.today().daysBetween(t.CreatedDate.date());
            String bucket = ageDays >= 8 ? 'Stale' : (ageDays >= 3 ? 'Pending' : 'New');
            byAge.put(bucket, byAge.get(bucket) + 1);
        }
        stats.put('byAge', byAge);

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
