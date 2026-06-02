/**
 * MergeScanBatch.cls
 * Scans ALL records in chunks of 200, accumulates duplicate groups across
 * chunks using Database.Stateful, then creates Tickets + Candidates in finish().
 *
 * SERIALIZATION CONTRACT: Every instance variable MUST be a primitive (String,
 * Integer, Boolean) or Map<String,String>. Salesforce Database.Stateful does
 * not reliably round-trip Set<String> or List<String> across async chunk
 * boundaries — use pipe-delimited Strings stored in Map<String,String> instead.
 * Candidate IDs are stored as pipe-delimited strings; names as "matchKey::id".
 */
public without sharing class MergeScanBatch
    implements Database.Batchable<SObject>, Database.Stateful {

    // ─── Config — pipe-delimited strings (guaranteed serializable) ────────────
    private String objectType;
    private String matchFieldsStr;    // e.g. 'Email|Phone' or 'Name|Phone'
    private String emailObjectApiName; // null = skip email scan; 'AUTO' = auto-discover

    // ─── Resolved once in start(), stored as pipe-delimited strings ───────────
    private String emailFieldsStr;   // e.g. 'Email|hed__AlternateEmail__c'
    private String phoneFieldsStr;   // e.g. 'Phone|MobilePhone'
    private String nameFieldsStr;    // e.g. 'Name|Common_Name__c'

    // ─── Existing open-ticket keys: Map<matchKey, '1'> ────────────────────────
    private Map<String,String> existingKeysMap;
    private Map<String,String> existingCandidateSetsMap;

    // ─── Stateful accumulator: Map<String,String> only ────────────────────────
    //     accMatchType : matchKey → 'Email'|'Phone'|'Name'
    //     accIdSet     : matchKey → 'id1|id2|id3'  (pipe-delimited 18-char IDs)
    //     accNames     : 'matchKey::candidateId' → candidateName
    private Map<String,String> accMatchType;
    private Map<String,String> accIdSet;
    private Map<String,String> accNames;

    // ─── Required no-arg constructor for Database.Stateful deserialization ────
    @TestVisible private MergeScanBatch() {}

    // ─── Public constructors ─────────────────────────────────────────────────
    public MergeScanBatch(String objectType, Set<String> matchFieldSet) {
        this(objectType, matchFieldSet, null);
    }

    public MergeScanBatch(String objectType, Set<String> matchFieldSet, String emailObjectApiName) {
        this.objectType          = objectType;
        this.emailObjectApiName  = emailObjectApiName;
        this.matchFieldsStr      = matchFieldSet == null ? ''
                                     : String.join(new List<String>(matchFieldSet), '|');
        this.accMatchType    = new Map<String,String>();
        this.accIdSet        = new Map<String,String>();
        this.accNames        = new Map<String,String>();
        this.existingKeysMap           = new Map<String,String>();
        this.existingCandidateSetsMap  = new Map<String,String>();
    }

    // ─── start: build one QueryLocator for ALL records ────────────────────────

    public Database.QueryLocator start(Database.BatchableContext ctx) {
        if (String.isBlank(objectType)) {
            throw new BatchException('MergeScanBatch.start: objectType is blank.');
        }
        if (accMatchType           == null) accMatchType           = new Map<String,String>();
        if (accIdSet               == null) accIdSet               = new Map<String,String>();
        if (accNames               == null) accNames               = new Map<String,String>();
        if (existingKeysMap        == null) existingKeysMap        = new Map<String,String>();
        if (existingCandidateSetsMap == null) existingCandidateSetsMap = new Map<String,String>();

        // Rebuild existingKeys from the org's open tickets
        for (String k : MergeScanService.loadExistingKeys(objectType)) {
            existingKeysMap.put(k, '1');
        }
        for (String c : MergeScanService.loadExistingCandidateSets(objectType)) {
            existingCandidateSetsMap.put(c, '1');
        }

        // Parse the match-field selection from the stored pipe-delimited string
        Set<String> matchFieldSet = String.isBlank(matchFieldsStr)
            ? new Set<String>()
            : new Set<String>(matchFieldsStr.split('\\|'));

        // Resolve which API field names exist in this org for each match type
        List<String> emailFields = matchFieldSet.contains('Email')
            ? MergeScanService.resolveFields(objectType, 'Email') : new List<String>();
        List<String> phoneFields = matchFieldSet.contains('Phone')
            ? MergeScanService.resolveFields(objectType, 'Phone') : new List<String>();
        List<String> nameFields  = matchFieldSet.contains('Name')
            ? MergeScanService.resolveFields(objectType, 'Name')  : new List<String>();

        // Persist resolved field lists as pipe-delimited strings
        emailFieldsStr = String.join(emailFields, '|');
        phoneFieldsStr = String.join(phoneFields, '|');
        nameFieldsStr  = String.join(nameFields,  '|');

        Set<String> allFields = new Set<String>{ 'Id', 'Name' };
        allFields.addAll(emailFields);
        allFields.addAll(phoneFields);
        allFields.addAll(nameFields);

        String q = 'SELECT ' + String.join(new List<String>(allFields), ', ')
                 + ' FROM '  + objectType;
        return Database.getQueryLocator(q);
    }

    // ─── execute: normalize fields for each record and accumulate ─────────────

    public void execute(Database.BatchableContext ctx, List<SObject> scope) {
        // Reconstruct field lists from their serialized pipe-delimited strings
        List<String> emailFields = String.isBlank(emailFieldsStr) ? new List<String>()
            : emailFieldsStr.split('\\|');
        List<String> phoneFields = String.isBlank(phoneFieldsStr) ? new List<String>()
            : phoneFieldsStr.split('\\|');
        List<String> nameFields  = String.isBlank(nameFieldsStr)  ? new List<String>()
            : nameFieldsStr.split('\\|');

        for (SObject rec : scope) {
            Id     recId   = rec.Id;
            String recName = (String) rec.get('Name');
            for (String f : emailFields) { accum(rec, recId, recName, f, 'Email'); }
            for (String f : phoneFields) { accum(rec, recId, recName, f, 'Phone'); }
            for (String f : nameFields)  { accum(rec, recId, recName, f, 'Name');  }
        }
    }

    // ─── finish: deduplicate by candidate set, then persist as Tickets ──────────

    public void finish(Database.BatchableContext ctx) {
        // Supplement batch accumulator with Email_Address__c cross-object detection.
        // No-ops silently if Email_Address__c is not deployed in this org.
        // Email-object enrichment: controlled by emailObjectApiName, independent of matchFields.
        // This lets Account (which has no direct Email fields) use the toggle just like Contact.
        if (String.isNotBlank(emailObjectApiName)) {
            String emailObjToUse = emailObjectApiName == 'AUTO'
                ? MergeScanService.resolveEmailObjectName(objectType) : emailObjectApiName;
            if (String.isNotBlank(emailObjToUse)) {
                Set<String> existingKeySet = existingKeysMap != null
                    ? new Set<String>(existingKeysMap.keySet()) : new Set<String>();
                MergeScanService.enrichWithEmailObject(
                    objectType, emailObjToUse, existingKeySet, accMatchType, accIdSet, accNames
                );
            }
        }

        // Match type priority: Email beats Phone beats Name
        Map<String,Integer> matchPriority = new Map<String,Integer>{
            'Email' => 3, 'Phone' => 2, 'Name' => 1
        };

        // Step 1 — group accumulated match keys by their sorted candidate set.
        // Same contacts matched by both Email and Phone → only one ticket.
        Map<String,String> canonicalToBestKey = new Map<String,String>();

        for (String key : accMatchType.keySet()) {
            String idStr = accIdSet.get(key);
            if (String.isBlank(idStr)) continue;
            List<String> ids = idStr.split('\\|');
            if (ids.size() < 2) continue;

            ids.sort();
            String canonical = String.join(ids, '|');

            // Skip: a ticket (any status) already covers this candidate set
            if (existingCandidateSetsMap != null && existingCandidateSetsMap.containsKey(canonical)) continue;

            if (!canonicalToBestKey.containsKey(canonical)) {
                canonicalToBestKey.put(canonical, key);
            } else {
                String currentKey = canonicalToBestKey.get(canonical);
                Integer newP  = matchPriority.get(accMatchType.get(key))        ?? 0;
                Integer curP  = matchPriority.get(accMatchType.get(currentKey)) ?? 0;
                if (newP > curP) canonicalToBestKey.put(canonical, key);
            }
        }

        if (canonicalToBestKey.isEmpty()) return;

        // Step 2 — create one Ticket per unique candidate set
        List<String>          ticketKeys = new List<String>(canonicalToBestKey.values());
        List<Merge_Ticket__c> tickets    = new List<Merge_Ticket__c>();

        for (String key : ticketKeys) {
            String matchType = accMatchType.get(key);
            List<String> ids = accIdSet.get(key).split('\\|');
            tickets.add(new Merge_Ticket__c(
                Object_Type__c      = objectType,
                Match_Type__c       = matchType,
                Match_Key__c        = key,
                Match_Confidence__c = DataNormalizationUtil.inferConfidence(matchType, 1),
                Status__c           = 'New',
                Candidate_Count__c  = ids.size()
            ));
        }

        // allOrNothing=false: if a key already exists (unique constraint), skip that
        // ticket and still insert the rest rather than rolling back everything.
        List<Database.SaveResult> ticketResults = Database.insert(tickets, false);

        // Collect only the tickets that were actually inserted
        List<Merge_Ticket__c> insertedTickets = new List<Merge_Ticket__c>();
        List<String>          insertedKeys    = new List<String>();
        List<String>          insertErrors    = new List<String>();
        for (Integer i = 0; i < ticketResults.size(); i++) {
            if (ticketResults[i].isSuccess()) {
                insertedTickets.add(tickets[i]);
                insertedKeys.add(ticketKeys[i]);
            } else {
                for (Database.Error err : ticketResults[i].getErrors()) {
                    insertErrors.add(err.getMessage());
                }
            }
        }

        // Surface insert errors via batch job ExtendedStatus (visible in Apex Jobs)
        if (!insertErrors.isEmpty() && insertedTickets.isEmpty()) {
            throw new BatchException(
                'MergeScanBatch: failed to insert all ' + tickets.size()
                + ' tickets for ' + objectType + '. First error: ' + insertErrors[0]
            );
        }

        if (insertedTickets.isEmpty()) return;

        List<Merge_Candidate__c> candidates = new List<Merge_Candidate__c>();
        for (Integer i = 0; i < insertedTickets.size(); i++) {
            String key = insertedKeys.get(i);
            List<String> ids = accIdSet.get(key).split('\\|');
            for (String candidateId : ids) {
                candidates.add(new Merge_Candidate__c(
                    Merge_Ticket__c     = insertedTickets[i].Id,
                    Record_Id__c        = candidateId,
                    Record_Name__c      = accNames.get(key + '::' + candidateId),
                    Is_Master__c        = false,
                    Is_Losing_Record__c = false
                ));
            }
        }
        if (!candidates.isEmpty()) insert candidates;
    }

    // ─── Private: normalize one field value and add to accumulator ────────────

    private void accum(SObject rec, Id recId, String recName,
                       String field, String matchType) {
        String raw = (String) rec.get(field);
        if (String.isBlank(raw)) return;

        String key   = DataNormalizationUtil.buildMatchKey(objectType, matchType, raw);
        String idStr = String.valueOf(recId);

        if (String.isBlank(key) || existingKeysMap.containsKey(key)) return;

        if (!accMatchType.containsKey(key)) {
            accMatchType.put(key, matchType);
            accIdSet.put(key, idStr);
        } else {
            String existing = accIdSet.get(key);
            // Exact-ID dedup: split on '|' to avoid substring false-positives
            Set<String> seen = new Set<String>(existing.split('\\|'));
            if (!seen.contains(idStr)) {
                accIdSet.put(key, existing + '|' + idStr);
            }
        }
        accNames.put(key + '::' + idStr, recName != null ? recName : '');
    }

    public class BatchException extends Exception {}
}
