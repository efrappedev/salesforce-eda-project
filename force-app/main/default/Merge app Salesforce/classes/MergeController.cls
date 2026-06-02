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

    // ─── Ticket list ──────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<Merge_Ticket__c> getTickets(
        String objectType,
        String statusFilter  // 'All' | 'New' | 'In Review' | 'Ready' | 'Error'
    ) {
        String soql =
            'SELECT Id, Name, Status__c, Object_Type__c, Match_Type__c, ' +
            '       Match_Confidence__c, Candidate_Count__c, Match_Key__c, ' +
            '       CreatedDate, LastModifiedDate, ' +
            '       (SELECT Record_Name__c FROM Merge_Candidates__r ' +
            '        ORDER BY CreatedDate ASC LIMIT 5) ' +
            'FROM Merge_Ticket__c ' +
            'WHERE Object_Type__c = :objectType';

        if (!String.isBlank(statusFilter) && statusFilter != 'All') {
            soql += ' AND Status__c = :statusFilter';
        }
        soql += ' ORDER BY LastModifiedDate DESC LIMIT 2000';

        return Database.query(soql);
    }

    // ─── Scan ─────────────────────────────────────────────────────────────────

    @AuraEnabled
    public static MergeWrappers.ScanResult runScan(MergeWrappers.ScanRequest request) {
        // For real (non-dry) scans, override the limit to cover all records.
        // Database.Stateful batch accumulation is unreliable for large Maps;
        // synchronous scan handles up to 50 000 rows — sufficient for this org.
        if (request.dryRun != true) {
            request.recordLimit = 50000;
        }
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

    // ─── Reset (sandbox testing only) ────────────────────────────────────────

    @AuraEnabled
    public static Integer deleteAllTickets() {
        List<Merge_Ticket__c> tickets = [SELECT Id FROM Merge_Ticket__c LIMIT 10000];
        if (!tickets.isEmpty()) delete tickets;

        List<Merge_Candidate__c> orphans = [SELECT Id FROM Merge_Candidate__c LIMIT 10000];
        if (!orphans.isEmpty()) Database.delete(orphans, false);

        List<Merge_Log__c> logs = [SELECT Id FROM Merge_Log__c LIMIT 10000];
        if (!logs.isEmpty()) Database.delete(logs, false);

        return tickets.size();
    }
}
