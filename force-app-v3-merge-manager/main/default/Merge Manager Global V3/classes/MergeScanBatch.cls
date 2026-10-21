/**
 * MergeScanBatch.cls
 * Detects duplicates in chunks of 200 via per-chunk SOQL (no stateful accumulation).
 * Each execute() detects duplicates against the full org and creates tickets immediately.
 * This avoids the "Batchable instance is too big" governor limit for large orgs.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class MergeScanBatch
    implements Database.Batchable<SObject>, Database.Stateful {

    // ─── Config ───────────────────────────────────────────────────────────────
    private String objectType;
    private String matchFieldsStr;
    private String emailObjectApiName;

    // ─── Resolved in start() ─────────────────────────────────────────────────
    private String emailFieldsStr;
    private String phoneFieldsStr;
    private String nameFieldsStr;

    // ─── Existing tickets (loaded in start(), read-only in execute) ───────────
    // Stateful state is now MINIMAL: only existing-ticket keys, not per-record accumulators.
    private Map<String,String> existingKeysMap;           // matchKey → '1'
    private Map<String,String> existingCandidateSetsMap;  // canonical sorted IDs → '1'

    @TestVisible private MergeScanBatch() {}

    public MergeScanBatch(String objectType, Set<String> matchFieldSet) {
        this(objectType, matchFieldSet, null);
    }

    public MergeScanBatch(String objectType, Set<String> matchFieldSet, String emailObjectApiName) {
        this.objectType         = objectType;
        this.emailObjectApiName = emailObjectApiName;
        this.matchFieldsStr     = matchFieldSet == null ? ''
                                    : String.join(new List<String>(matchFieldSet), '|');
        this.existingKeysMap          = new Map<String,String>();
        this.existingCandidateSetsMap = new Map<String,String>();
    }

    // ─── start ───────────────────────────────────────────────────────────────

    public Database.QueryLocator start(Database.BatchableContext ctx) {
        if (String.isBlank(objectType)) {
            throw new BatchException('MergeScanBatch.start: objectType is blank.');
        }
        if (existingKeysMap        == null) existingKeysMap        = new Map<String,String>();
        if (existingCandidateSetsMap == null) existingCandidateSetsMap = new Map<String,String>();

        for (String k : MergeScanService.loadExistingKeys(objectType)) {
            existingKeysMap.put(k, '1');
        }
        for (String c : MergeScanService.loadExistingCandidateSets(objectType)) {
            existingCandidateSetsMap.put(c, '1');
        }

        Set<String> matchFieldSet = String.isBlank(matchFieldsStr)
            ? new Set<String>()
            : new Set<String>(matchFieldsStr.split('\\|'));

        List<String> emailFields = matchFieldSet.contains('Email')
            ? MergeScanService.resolveFields(objectType, 'Email') : new List<String>();
        List<String> phoneFields = matchFieldSet.contains('Phone')
            ? MergeScanService.resolveFields(objectType, 'Phone') : new List<String>();
        List<String> nameFields  = matchFieldSet.contains('Name')
            ? MergeScanService.resolveFields(objectType, 'Name')  : new List<String>();

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

    // ─── execute: per-chunk SOQL detection + immediate ticket creation ────────

    public void execute(Database.BatchableContext ctx, List<SObject> scope) {
        List<String> emailFields = String.isBlank(emailFieldsStr) ? new List<String>()
            : emailFieldsStr.split('\\|');
        List<String> phoneFields = String.isBlank(phoneFieldsStr) ? new List<String>()
            : phoneFieldsStr.split('\\|');
        List<String> nameFields  = String.isBlank(nameFieldsStr)  ? new List<String>()
            : nameFieldsStr.split('\\|');

        // Local (non-stateful) maps — reset each execute() call
        Map<String,String>  localMatchType = new Map<String,String>();
        Map<String,Set<Id>> localKeyToIds  = new Map<String,Set<Id>>();
        Map<Id,String>      localIdToName  = new Map<Id,String>();

        detectInScope(scope, emailFields, 'Email', localMatchType, localKeyToIds, localIdToName);
        detectInScope(scope, phoneFields, 'Phone', localMatchType, localKeyToIds, localIdToName);
        detectInScope(scope, nameFields,  'Name',  localMatchType, localKeyToIds, localIdToName);

        persistDuplicates(localMatchType, localKeyToIds, localIdToName);
    }

    // ─── Test injection flags ────────────────────────────────────────────────
    @TestVisible private static Map<String,String> TEST_INJECT_FINISH_MATCH_TYPE = null;
    @TestVisible private static Map<String,String> TEST_INJECT_FINISH_ID_SET     = null;
    @TestVisible private static Map<String,String> TEST_INJECT_FINISH_NAMES      = null;
    // Override the frequency threshold in tests (default 500 in production)
    @TestVisible private static Integer TEST_FREQ_THRESHOLD = null;

    private static final Integer DEFAULT_FREQ_THRESHOLD = 500;

    // ─── finish: email-object enrichment only (local maps, not stateful) ──────

    public void finish(Database.BatchableContext ctx) {
        Map<String,String> localMatchType = new Map<String,String>();
        Map<String,String> localIdSet     = new Map<String,String>();
        Map<String,String> localNames     = new Map<String,String>();

        if (TEST_INJECT_FINISH_MATCH_TYPE != null) {
            localMatchType.putAll(TEST_INJECT_FINISH_MATCH_TYPE);
            if (TEST_INJECT_FINISH_ID_SET  != null) localIdSet.putAll(TEST_INJECT_FINISH_ID_SET);
            if (TEST_INJECT_FINISH_NAMES   != null) localNames.putAll(TEST_INJECT_FINISH_NAMES);
        } else if (String.isNotBlank(emailObjectApiName)) {
            String emailObjToUse = emailObjectApiName == 'AUTO'
                ? MergeScanService.resolveEmailObjectName(objectType) : emailObjectApiName;
            if (String.isBlank(emailObjToUse)) return;
            Set<String> existingKeySet = existingKeysMap != null
                ? new Set<String>(existingKeysMap.keySet()) : new Set<String>();
            MergeScanService.enrichWithEmailObject(
                objectType, emailObjToUse, existingKeySet, localMatchType, localIdSet, localNames
            );
        } else {
            return;
        }

        if (localMatchType.isEmpty()) return;

        Map<String,Integer> matchPriority = new Map<String,Integer>{
            'Email' => 3, 'Phone' => 2, 'Name' => 1
        };
        Map<String,String> canonicalToBestKey = new Map<String,String>();

        for (String key : localMatchType.keySet()) {
            String idStr = localIdSet.get(key);
            if (String.isBlank(idStr)) continue;
            List<String> ids = idStr.split('\\|');
            if (ids.size() < 2) continue;
            ids.sort();
            String canonical = String.join(ids, '|');
            if (existingCandidateSetsMap != null && existingCandidateSetsMap.containsKey(canonical)) continue;
            if (!canonicalToBestKey.containsKey(canonical)) {
                canonicalToBestKey.put(canonical, key);
            } else {
                String curKey = canonicalToBestKey.get(canonical);
                Integer newP = matchPriority.get(localMatchType.get(key))        ?? 0;
                Integer curP = matchPriority.get(localMatchType.get(curKey)) ?? 0;
                if (newP > curP) canonicalToBestKey.put(canonical, key);
            }
        }
        if (canonicalToBestKey.isEmpty()) return;

        List<String>          ticketKeys = new List<String>(canonicalToBestKey.values());
        List<Merge_Ticket__c> tickets    = new List<Merge_Ticket__c>();
        for (String key : ticketKeys) {
            List<String> ids = localIdSet.get(key).split('\\|');
            tickets.add(new Merge_Ticket__c(
                Object_Type__c      = objectType,
                Match_Type__c       = localMatchType.get(key),
                Match_Key__c        = key,
                Match_Confidence__c = MergeDataNormalizationUtil.inferConfidence(localMatchType.get(key), 1),
                Status__c           = 'New',
                Candidate_Count__c  = ids.size()
            ));
        }
        List<Database.SaveResult> results = Database.insert(tickets, false);

        List<Merge_Candidate__c> candidates = new List<Merge_Candidate__c>();
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) continue;
            String key = ticketKeys[i];
            for (String candidateId : localIdSet.get(key).split('\\|')) {
                candidates.add(new Merge_Candidate__c(
                    Merge_Ticket__c     = results[i].getId(),
                    Record_Id__c        = candidateId,
                    Record_Name__c      = localNames.get(key + '::' + candidateId),
                    Is_Master__c        = false,
                    Is_Losing_Record__c = false
                ));
            }
        }
        if (!candidates.isEmpty()) insert candidates;
    }

    // ─── Private helpers ─────────────────────────────────────────────────────

    /**
     * For the 200-record scope, collect raw field values, then query ALL org records
     * sharing those values. Group results by normalized key — only confirmed duplicates
     * (≥2 records) enter the local maps. No stateful accumulation.
     */
    private void detectInScope(
        List<SObject>       scope,
        List<String>        fields,
        String              matchType,
        Map<String,String>  localMatchType,
        Map<String,Set<Id>> localKeyToIds,
        Map<Id,String>      localIdToName
    ) {
        if (fields.isEmpty()) return;

        Set<String> rawVals = new Set<String>();
        for (SObject rec : scope) {
            for (String f : fields) {
                String v = (String) rec.get(f);
                if (!String.isBlank(v)) rawVals.add(v);
            }
        }
        if (rawVals.isEmpty()) return;

        // Build SELECT with OR WHERE across all fields for this match type.
        // LIMIT 50000 is a hard safety cap: prevents "Too many query rows" even if
        // rawVals contains a value shared by tens of thousands of records.
        Set<String> selectFields = new Set<String>{ 'Id', 'Name' };
        selectFields.addAll(fields);
        List<String> whereClauses = new List<String>();
        for (String f : fields) {
            whereClauses.add(f + ' IN :rawVals');
        }
        String soql = 'SELECT ' + String.join(new List<String>(selectFields), ', ')
                    + ' FROM '  + objectType
                    + ' WHERE ' + String.join(whereClauses, ' OR ') // NOPMD
                    + ' LIMIT 50000';

        List<SObject> allMatches = Database.query(soql); // NOPMD

        // First pass: count how many records share each raw value.
        // Values above the threshold are junk data (call-center numbers, generic addresses,
        // placeholder emails) — treating them as duplicates would flood the ticket list.
        Integer freqThreshold = TEST_FREQ_THRESHOLD != null ? TEST_FREQ_THRESHOLD : DEFAULT_FREQ_THRESHOLD;
        Map<String,Integer> valFrequency = new Map<String,Integer>();
        for (SObject rec : allMatches) {
            for (String f : fields) {
                String raw = (String) rec.get(f);
                if (String.isBlank(raw)) continue;
                Integer cnt = valFrequency.get(raw);
                valFrequency.put(raw, cnt == null ? 1 : cnt + 1);
            }
        }

        // Second pass: build local maps, skipping high-frequency values.
        for (SObject rec : allMatches) {
            Id     recId   = rec.Id;
            String recName = (String) rec.get('Name');
            localIdToName.put(recId, recName != null ? recName : '');
            for (String f : fields) {
                String raw = (String) rec.get(f);
                if (String.isBlank(raw)) continue;
                if (valFrequency.get(raw) > freqThreshold) continue;
                String key = MergeDataNormalizationUtil.buildMatchKey(objectType, matchType, raw);
                if (String.isBlank(key) || existingKeysMap.containsKey(key)) continue;
                if (!localMatchType.containsKey(key)) {
                    localMatchType.put(key, matchType);
                    localKeyToIds.put(key, new Set<Id>());
                }
                localKeyToIds.get(key).add(recId);
            }
        }
    }

    /**
     * From the local maps built in detectInScope, deduplicate by canonical candidate set
     * and insert tickets + candidates. Uses allOrNothing=false so the unique Match_Key__c
     * constraint silently rejects races when the same pair is detected in multiple chunks.
     */
    private void persistDuplicates(
        Map<String,String>  localMatchType,
        Map<String,Set<Id>> localKeyToIds,
        Map<Id,String>      localIdToName
    ) {
        if (localMatchType.isEmpty()) return;

        Map<String,Integer> matchPriority = new Map<String,Integer>{
            'Email' => 3, 'Phone' => 2, 'Name' => 1
        };
        Map<String,String> canonicalToBestKey = new Map<String,String>();

        for (String key : localMatchType.keySet()) {
            Set<Id> idSet = localKeyToIds.get(key);
            if (idSet == null || idSet.size() < 2) continue;

            List<String> sortedIds = new List<String>();
            for (Id id : idSet) sortedIds.add(String.valueOf(id));
            sortedIds.sort();
            String canonical = String.join(sortedIds, '|');

            if (existingCandidateSetsMap != null && existingCandidateSetsMap.containsKey(canonical)) continue;

            if (!canonicalToBestKey.containsKey(canonical)) {
                canonicalToBestKey.put(canonical, key);
            } else {
                String curKey = canonicalToBestKey.get(canonical);
                Integer newP = matchPriority.get(localMatchType.get(key))        ?? 0;
                Integer curP = matchPriority.get(localMatchType.get(curKey)) ?? 0;
                if (newP > curP) canonicalToBestKey.put(canonical, key);
            }
        }
        if (canonicalToBestKey.isEmpty()) return;

        List<String>          ticketKeys = new List<String>(canonicalToBestKey.values());
        List<Merge_Ticket__c> tickets    = new List<Merge_Ticket__c>();
        for (String key : ticketKeys) {
            Set<Id> idSet = localKeyToIds.get(key);
            tickets.add(new Merge_Ticket__c(
                Object_Type__c      = objectType,
                Match_Type__c       = localMatchType.get(key),
                Match_Key__c        = key,
                Match_Confidence__c = MergeDataNormalizationUtil.inferConfidence(localMatchType.get(key), 1),
                Status__c           = 'New',
                Candidate_Count__c  = idSet.size()
            ));
        }

        List<Database.SaveResult> results = Database.insert(tickets, false);

        List<Merge_Candidate__c> candidates = new List<Merge_Candidate__c>();
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) continue;
            Set<Id> idSet = localKeyToIds.get(ticketKeys[i]);
            for (Id candidateId : idSet) {
                candidates.add(new Merge_Candidate__c(
                    Merge_Ticket__c     = results[i].getId(),
                    Record_Id__c        = String.valueOf(candidateId),
                    Record_Name__c      = localIdToName.get(candidateId),
                    Is_Master__c        = false,
                    Is_Losing_Record__c = false
                ));
            }
        }
        if (!candidates.isEmpty()) insert candidates;
    }

    public class BatchException extends Exception {}
}
