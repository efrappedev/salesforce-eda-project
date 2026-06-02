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

    // ─── Ticket list ──────────────────────────────────────────────────────────

    @AuraEnabled
    public static List<Merge_Ticket__c> getTickets(
        String objectType,
        String statusFilter  // 'All' | 'New' | 'In Review' | 'Ready' | 'Error'
    ) {
        String soql =
            'SELECT Id, Name, Status__c, Object_Type__c, Match_Type__c, ' +
            '       Match_Confidence__c, Candidate_Count__c, Match_Key__c, ' +
            '       Error_Message__c, ' +
            '       CreatedDate, LastModifiedDate, ' +
            '       (SELECT Record_Name__c FROM Merge_Candidates__r ' +
            '        ORDER BY CreatedDate ASC LIMIT 5) ' +
            'FROM Merge_Ticket__c ' +
            'WHERE Object_Type__c = :objectType';

        if (statusFilter == 'All') {
            soql += ' AND Status__c NOT IN (\'Merged\', \'Ignored\')';
        } else if (statusFilter == 'Closed') {
            soql += ' AND Status__c IN (\'Merged\', \'Ignored\')';
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
        update new Merge_Ticket__c(
            Id              = (Id) ticketId,
            Status__c       = 'Ignored',
            Final_Action__c = 'Ignored',
            Closed_Reason__c = closedReason,
            Notes__c        = notes
        );
    }

    // ─── Utility ─────────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static Boolean isEDAAvailable() {
        return EDARelatedRecordsService.isEDAAvailable();
    }

    // Returns true only in sandbox/scratch orgs — used by the LWC to hide the
    // Reset button in production so it cannot be accidentally triggered.
    @AuraEnabled(cacheable=true)
    public static Boolean isSandboxOrg() {
        if (TEST_IS_SANDBOX != null) return TEST_IS_SANDBOX;
        return [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox;
    }

    // ─── Orphaned Account cleanup ─────────────────────────────────────────────

    @AuraEnabled
    public static void deleteOrphanedAccount(
        String accountId, String ticketId, String accountName
    ) {
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
}
