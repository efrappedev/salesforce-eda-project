/**
 * MergeScanService.cls
 * Detects duplicate records and generates Merge_Ticket__c + Merge_Candidate__c records.
 *
 * Design:
 *  - Uses Schema.getGlobalDescribe() to skip fields not present in the org (safe for
 *    orgs where some EDA email/phone fields are not deployed).
 *  - Groups by normalized match key using DataNormalizationUtil.
 *  - Reads existing open ticket keys upfront to avoid creating duplicates.
 *  - Inner class DuplicateGroup is the accumulator before we hit the DB.
 */
public without sharing class MergeScanService {

    private static final Integer DEFAULT_SCAN_LIMIT = 5000;

    // ─── Field catalogs by object type ───────────────────────────────────────

    private static final Map<String,List<String>> EMAIL_FIELDS =
        new Map<String,List<String>>{
            'Contact' => new List<String>{
                'Email',
                'hed__AlternateEmail__c',
                'Alternative_Email_1__c',
                'Alternative_Email_2__c',
                'Alternative_Email_3__c',
                'hed__UniversityEmail__c',
                'hed__WorkEmail__c'
            },
            'Account' => new List<String>{ 'hed__Credentialing_Email__c' }
        };

    private static final Map<String,List<String>> PHONE_FIELDS =
        new Map<String,List<String>>{
            'Contact' => new List<String>{
                'Phone', 'MobilePhone', 'HomePhone', 'OtherPhone',
                'Fax', 'AssistantPhone', 'hed__WorkPhone__c'
            },
            'Account' => new List<String>{ 'Phone', 'Fax' }
        };

    private static final Map<String,List<String>> NAME_FIELDS =
        new Map<String,List<String>>{
            'Contact' => new List<String>{ 'Name' },
            'Account' => new List<String>{ 'Name', 'Common_Name__c' }
        };

    // ─── Public API ───────────────────────────────────────────────────────────

    public static MergeWrappers.ScanResult scan(MergeWrappers.ScanRequest request) {
        MergeWrappers.ScanResult result = new MergeWrappers.ScanResult();
        try {
            String  objType = String.isBlank(request.objectType) ? 'Contact' : request.objectType;
            Integer lim     = request.recordLimit != null ? request.recordLimit : DEFAULT_SCAN_LIMIT;
            List<String> mf = (request.matchFields != null && !request.matchFields.isEmpty())
                ? request.matchFields : new List<String>{ 'Email', 'Phone' };
            try {
                result.recordsAnalyzed = Database.countQuery('SELECT COUNT() FROM ' + objType);
            } catch (Exception ce) { result.recordsAnalyzed = 0; }
            Set<String> existingKeys          = loadExistingKeys(objType);
            Set<String> existingCandidateSets = loadExistingCandidateSets(objType);
            Map<String,DuplicateGroup> groups = new Map<String,DuplicateGroup>();

            if (mf.contains('Email')) {
                detectByFields(objType, 'Email', lim, existingKeys, groups);
            }
            if (mf.contains('Phone')) {
                detectByFields(objType, 'Phone', lim, existingKeys, groups);
            }
            if (mf.contains('Name')) {
                detectByFields(objType, 'Name', lim, existingKeys, groups);
            }

            // Count groups found before cross-match-type deduplication
            Integer rawCount = groups.size();

            // Collapse groups that cover the same candidate set (Email+Phone match
            // on the same pair → one ticket, not two).
            groups = deduplicateByCandidateSet(groups, existingCandidateSets);

            // duplicateGroupsFound = total found (including those skipped by key)
            // skippedExistingTickets = groups filtered because contacts already have a ticket
            result.duplicateGroupsFound   = rawCount;
            result.skippedExistingTickets = rawCount - groups.size();

            if (request.dryRun == true) {
                result.previews = buildPreviews(groups);
            } else if (!groups.isEmpty()) {
                result.ticketsCreated = persistTickets(groups, objType);
            }

        } catch (Exception e) {
            result.success       = false;
            result.errorMessage  = e.getMessage() + '\n' + e.getStackTraceString();
        }
        return result;
    }

    // ─── Detection ────────────────────────────────────────────────────────────

    private static void detectByFields(
        String objectType,
        String matchType,
        Integer lim,
        Set<String> existingKeys,
        Map<String,DuplicateGroup> groups
    ) {
        Map<String,List<String>> catalog = matchType == 'Email' ? EMAIL_FIELDS
                                         : matchType == 'Phone' ? PHONE_FIELDS
                                         : NAME_FIELDS;

        List<String> available = filterAvailableFields(
            objectType, catalog.get(objectType)
        );
        if (available.isEmpty()) return;

        Set<String> baseFieldsLower = new Set<String>{'id', 'name'};
        List<String> extraFields = new List<String>();
        for (String f : available) {
            if (!baseFieldsLower.contains(f.toLowerCase())) extraFields.add(f);
        }
        String query = 'SELECT Id, Name'
            + (extraFields.isEmpty() ? '' : ', ' + String.join(extraFields, ', '))
            + ' FROM ' + objectType + ' LIMIT ' + lim;

        List<SObject> records = Database.query(query);

        Map<String,Set<Id>>  keyToIds  = new Map<String,Set<Id>>();
        Map<Id,String>       idToName  = new Map<Id,String>();

        for (SObject rec : records) {
            idToName.put(rec.Id, (String) rec.get('Name'));

            for (String field : available) {
                String raw = (String) rec.get(field);
                if (String.isBlank(raw)) continue;
                String key = DataNormalizationUtil.buildMatchKey(objectType, matchType, raw);
                if (String.isBlank(key) || existingKeys.contains(key)) continue;

                if (!keyToIds.containsKey(key)) keyToIds.put(key, new Set<Id>());
                keyToIds.get(key).add(rec.Id);
            }
        }

        for (String key : keyToIds.keySet()) {
            Set<Id> ids = keyToIds.get(key);
            if (ids.size() < 2) continue;
            if (!groups.containsKey(key)) {
                groups.put(key, new DuplicateGroup(key, matchType, objectType));
            }
            groups.get(key).addCandidates(ids, idToName);
        }
    }

    // ─── Persistence ──────────────────────────────────────────────────────────

    private static Integer persistTickets(
        Map<String,DuplicateGroup> groups,
        String objectType
    ) {
        List<DuplicateGroup> orderedGroups = groups.values();
        List<Merge_Ticket__c> tickets      = new List<Merge_Ticket__c>();

        for (DuplicateGroup grp : orderedGroups) {
            tickets.add(new Merge_Ticket__c(
                Object_Type__c      = objectType,
                Match_Type__c       = grp.matchType,
                Match_Key__c        = grp.matchKey,
                Match_Confidence__c = DataNormalizationUtil.inferConfidence(grp.matchType, 1),
                Status__c           = 'New',
                Candidate_Count__c  = grp.candidateIds.size()
            ));
        }

        // allOrNothing=false: skip any ticket that hits the unique Match_Key__c
        // constraint (e.g. from a concurrent scan) rather than rolling everything back.
        List<Database.SaveResult> ticketResults = Database.insert(tickets, false);

        List<Merge_Ticket__c> insertedTickets = new List<Merge_Ticket__c>();
        List<DuplicateGroup>  insertedGroups  = new List<DuplicateGroup>();
        for (Integer i = 0; i < ticketResults.size(); i++) {
            if (ticketResults[i].isSuccess()) {
                insertedTickets.add(tickets[i]);
                insertedGroups.add(orderedGroups[i]);
            }
        }
        if (insertedTickets.isEmpty()) return 0;

        List<Merge_Candidate__c> candidates = new List<Merge_Candidate__c>();
        for (Integer i = 0; i < insertedTickets.size(); i++) {
            DuplicateGroup grp = insertedGroups[i];
            for (Id recId : grp.candidateIds) {
                candidates.add(new Merge_Candidate__c(
                    Merge_Ticket__c    = insertedTickets[i].Id,
                    Record_Id__c       = String.valueOf(recId),
                    Record_Name__c     = grp.candidateNames.get(recId),
                    Is_Master__c       = false,
                    Is_Losing_Record__c = false
                ));
            }
        }
        if (!candidates.isEmpty()) insert candidates;

        return insertedTickets.size();
    }

    // ─── Dry-run preview ──────────────────────────────────────────────────────

    private static List<MergeWrappers.TicketPreview> buildPreviews(
        Map<String,DuplicateGroup> groups
    ) {
        List<MergeWrappers.TicketPreview> previews = new List<MergeWrappers.TicketPreview>();
        for (DuplicateGroup grp : groups.values()) {
            MergeWrappers.TicketPreview p = new MergeWrappers.TicketPreview();
            p.matchKey       = grp.matchKey;
            p.matchType      = grp.matchType;
            p.confidence     = DataNormalizationUtil.inferConfidence(grp.matchType, 1);
            p.candidateCount = grp.candidateIds.size();
            previews.add(p);
        }
        return previews;
    }

    // ─── Helpers (public so MergeScanBatch can call them) ────────────────────

    public static Set<String> loadExistingKeys(String objectType) {
        Set<String> keys = new Set<String>();
        for (Merge_Ticket__c t : [
            SELECT Match_Key__c FROM Merge_Ticket__c
            WHERE Object_Type__c = :objectType
              AND Match_Key__c != null
        ]) {
            keys.add(t.Match_Key__c);
        }
        return keys;
    }

    /**
     * Returns a Set of canonical candidate-set keys for every ticket (all statuses).
     * Each key is the sorted, pipe-joined 18-char IDs of the ticket's candidates.
     * Used to prevent creating a duplicate ticket when the same pair was already
     * detected — even if that prior ticket was later Merged or Ignored.
     * Without this, re-scanning would hit the unique constraint on Match_Key__c.
     */
    public static Set<String> loadExistingCandidateSets(String objectType) {
        Set<Id> allTicketIds = new Set<Id>();
        for (Merge_Ticket__c t : [
            SELECT Id FROM Merge_Ticket__c
            WHERE Object_Type__c = :objectType
        ]) allTicketIds.add(t.Id);

        if (allTicketIds.isEmpty()) return new Set<String>();

        Map<Id,List<String>> ticketToIds = new Map<Id,List<String>>();
        for (Merge_Candidate__c mc : [
            SELECT Merge_Ticket__c, Record_Id__c
            FROM Merge_Candidate__c
            WHERE Merge_Ticket__c IN :allTicketIds
              AND Record_Id__c != null
        ]) {
            if (!ticketToIds.containsKey(mc.Merge_Ticket__c)) {
                ticketToIds.put(mc.Merge_Ticket__c, new List<String>());
            }
            ticketToIds.get(mc.Merge_Ticket__c).add(mc.Record_Id__c);
        }

        Set<String> canonicals = new Set<String>();
        for (List<String> ids : ticketToIds.values()) {
            ids.sort();
            canonicals.add(String.join(ids, '|'));
        }
        return canonicals;
    }

    /**
     * Collapses groups that cover identical candidate sets into a single group.
     * Priority: Email (3) > Phone (2) > Name (1) — the highest-confidence match
     * type wins and becomes the ticket's match type.
     * Also skips groups whose candidate set already has an open ticket.
     */
    private static Map<String,DuplicateGroup> deduplicateByCandidateSet(
        Map<String,DuplicateGroup> groups,
        Set<String> existingCandidateSets
    ) {
        Map<String,Integer> priority = new Map<String,Integer>{
            'Email' => 3, 'Phone' => 2, 'Name' => 1
        };

        // canonical key → best DuplicateGroup seen so far for that candidate set
        Map<String,DuplicateGroup> byCanonical = new Map<String,DuplicateGroup>();

        for (DuplicateGroup grp : groups.values()) {
            List<String> sortedIds = new List<String>();
            for (Id id : grp.candidateIds) sortedIds.add(String.valueOf(id));
            sortedIds.sort();
            String canonical = String.join(sortedIds, '|');

            // Skip: an existing open ticket already covers these contacts
            if (existingCandidateSets.contains(canonical)) continue;

            if (!byCanonical.containsKey(canonical)) {
                byCanonical.put(canonical, grp);
            } else {
                DuplicateGroup current = byCanonical.get(canonical);
                Integer newP  = priority.get(grp.matchType)     ?? 0;
                Integer curP  = priority.get(current.matchType) ?? 0;
                if (newP > curP) byCanonical.put(canonical, grp);
            }
        }

        // Rebuild keyed by matchKey (required by the rest of the pipeline)
        Map<String,DuplicateGroup> result = new Map<String,DuplicateGroup>();
        for (DuplicateGroup grp : byCanonical.values()) {
            result.put(grp.matchKey, grp);
        }
        return result;
    }

    // Returns the available fields for a given object + matchType combination.
    public static List<String> resolveFields(String objectType, String matchType) {
        Map<String,List<String>> catalog = matchType == 'Email' ? EMAIL_FIELDS
                                         : matchType == 'Phone' ? PHONE_FIELDS
                                         : NAME_FIELDS;
        return filterAvailableFields(objectType, catalog.get(objectType));
    }

    private static List<String> filterAvailableFields(
        String objectType,
        List<String> candidates
    ) {
        if (candidates == null) return new List<String>();
        Map<String,Schema.SObjectField> fieldMap =
            Schema.getGlobalDescribe().get(objectType)
                  ?.getDescribe()?.fields?.getMap();
        if (fieldMap == null) return new List<String>();

        List<String> available = new List<String>();
        for (String f : candidates) {
            if (fieldMap.containsKey(f.toLowerCase())) available.add(f);
        }
        return available;
    }

    // ─── Inner accumulator ────────────────────────────────────────────────────

    private class DuplicateGroup {
        public String        matchKey;
        public String        matchType;
        public String        objectType;
        public Set<Id>       candidateIds;
        public Map<Id,String> candidateNames;

        public DuplicateGroup(String key, String type, String objType) {
            matchKey       = key;
            matchType      = type;
            objectType     = objType;
            candidateIds   = new Set<Id>();
            candidateNames = new Map<Id,String>();
        }

        public void addCandidates(Set<Id> ids, Map<Id,String> names) {
            candidateIds.addAll(ids);
            for (Id id : ids) {
                if (names.containsKey(id)) candidateNames.put(id, names.get(id));
            }
        }
    }
}
