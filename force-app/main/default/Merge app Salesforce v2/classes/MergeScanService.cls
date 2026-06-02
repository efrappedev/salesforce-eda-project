/**
 * MergeScanService.cls
 * Detects duplicate records and generates Merge_Ticket__c + Merge_Candidate__c records.
 *
 * Field detection strategy:
 *  - Email fields: resolved dynamically via Schema.DisplayType.EMAIL — any Email-type
 *    field on Contact/Account is automatically included, no hardcoded catalog needed.
 *  - Phone fields: same pattern via Schema.DisplayType.PHONE.
 *  - Name fields: 'Name' (universal) + Common_Name__c if present in schema.
 *  - Email_Address__c child object: optional. If the object exists in the org, a
 *    supplemental detection phase finds Contact/Account pairs sharing an email stored
 *    there, cross-referencing direct email fields for full coverage. If the object does
 *    not exist, this phase is silently skipped — zero impact on existing orgs.
 */
public without sharing class MergeScanService {

    private static final Integer DEFAULT_SCAN_LIMIT = 5000;

    // Cached: avoids repeated Schema.getGlobalDescribe() calls across methods
    @TestVisible private static Boolean emailAddressObjectAvailable = null;
    // Forces resolveFields to return [] inside EA methods — used only in tests to
    // cover the else branch that fires when the object has no direct Email-type fields.
    @TestVisible private static Boolean forceEmptyDirectFieldsForTest = false;

    // Test-injection: bypass the email-object SOQL queries so EA code paths can be
    // covered in orgs where no qualifying email object is deployed. When non-null,
    // detectByEmailObject and enrichWithEmailObject skip Step 1's SOQL and use these
    // maps directly. Steps 2 and 3 (cross-check against real Contact/Account records)
    // still execute normally, covering those lines.
    //   TEST_EA_KEY_TO_IDS : matchKey → Set<Id> of parent record IDs sharing that email
    //   TEST_EA_KEY_TO_RAW : matchKey → raw email string (used for cross-check query)
    @TestVisible static Map<String,Set<Id>> TEST_EA_KEY_TO_IDS = null;
    @TestVisible static Map<String,String>  TEST_EA_KEY_TO_RAW = null;

    // Test-injection: forces resolveEmailObjectName() to return a specific value so
    // the "qualifying object found" return path is covered without a real email object.
    @TestVisible static String TEST_RESOLVE_EMAIL_OBJECT_NAME = null;
    // Test-injection: bypass dfr.isAccessible() in detectByEmailObject/enrichWithEmailObject
    // so tests cover field-resolution lines regardless of the running user's FLS profile.
    @TestVisible private static Boolean TEST_SKIP_FIELD_ACCESSIBILITY_CHECK = false;

    // Test-injection: force specific emailField/lookupField names after field-resolution loop.
    // Allows tests to run the real SOQL path with a predictable field, bypassing field-ordering
    // non-determinism from Schema.getGlobalDescribe() when using standard objects as email objects.
    @TestVisible private static String TEST_FORCE_EA_EMAIL_FIELD  = null;
    @TestVisible private static String TEST_FORCE_EA_LOOKUP_FIELD = null;

    // ─── Public API ───────────────────────────────────────────────────────────

    public static MergeWrappers.ScanResult scan(MergeWrappers.ScanRequest request) {
        MergeWrappers.ScanResult result = new MergeWrappers.ScanResult();
        try {
            // mergeObjectType is the primary field sent from LWC (objectType conflicts with Aura internals)
            String  rawObjType = String.isNotBlank(request.mergeObjectType)
                ? request.mergeObjectType : request.objectType;
            String  objType = String.isBlank(rawObjType) ? 'Contact' : rawObjType;
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
            // Email-object detection is independent of the Email criterion so the toggle
            // works for Account (which has no direct Email fields) just like Contact.
            if (String.isNotBlank(request.emailObjectApiName)) {
                String emailObjToUse = request.emailObjectApiName == 'AUTO'
                    ? resolveEmailObjectName(objType) : request.emailObjectApiName;
                if (String.isNotBlank(emailObjToUse)) {
                    detectByEmailObject(objType, emailObjToUse, lim, existingKeys, groups);
                }
            }
            if (mf.contains('Phone')) {
                detectByFields(objType, 'Phone', lim, existingKeys, groups);
            }
            if (mf.contains('Name')) {
                detectByFields(objType, 'Name', lim, existingKeys, groups);
            }

            Integer rawCount = groups.size();
            groups = deduplicateByCandidateSet(groups, existingCandidateSets);

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
        List<String> available = resolveFields(objectType, matchType);
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

        Map<String,Set<Id>>  keyToIds = new Map<String,Set<Id>>();
        Map<Id,String>       idToName = new Map<Id,String>();

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

    /**
     * Supplemental email-object detection phase.
     * Accepts any custom object name that has an EMAIL-type field and a REFERENCE
     * field pointing to objectType. Defaults to Email_Address__c behavior.
     * Silently no-ops if the object is not deployed in this org.
     */
    private static void detectByEmailObject(
        String objectType,
        String emailObjName,
        Integer lim,
        Set<String> existingKeys,
        Map<String,DuplicateGroup> groups
    ) {
        if (String.isBlank(emailObjName)) return;

        // When test injection data is provided, skip ALL schema discovery and SOQL.
        // Steps 2 and 3 (cross-check against real Contact/Account records) still execute.
        Boolean useInjection = TEST_EA_KEY_TO_IDS != null;

        if (!useInjection) {
            // Availability check — uses cached flag for Email_Address__c (supports test overrides)
            if (emailObjName == 'Email_Address__c') {
                if (!isEmailAddressObjectAvailable()) return;
            } else {
                if (!Schema.getGlobalDescribe().containsKey(emailObjName.toLowerCase())) return;
            }
        }

        Map<String,Schema.SObjectField> eaFieldMap = useInjection ? null
            : Schema.getGlobalDescribe().get(emailObjName.toLowerCase())?.getDescribe()?.fields?.getMap();
        if (!useInjection && eaFieldMap == null) return;

        // Dynamically resolve the first EMAIL-type field and lookup to objectType
        String emailField  = null;
        String lookupField = null;
        if (!useInjection) {
            for (Schema.SObjectField f : eaFieldMap.values()) {
                Schema.DescribeFieldResult dfr = f.getDescribe();
                if (emailField == null
                        && (dfr.getType() == Schema.DisplayType.EMAIL || TEST_SKIP_FIELD_ACCESSIBILITY_CHECK)
                        && (TEST_SKIP_FIELD_ACCESSIBILITY_CHECK || dfr.isAccessible())) {
                    emailField = dfr.getName();
                }
                if (lookupField == null && dfr.getType() == Schema.DisplayType.REFERENCE) {
                    if (TEST_SKIP_FIELD_ACCESSIBILITY_CHECK) {
                        lookupField = dfr.getName();
                    } else {
                        for (Schema.SObjectType ref : dfr.getReferenceTo()) {
                            if (ref.getDescribe().getName() == objectType) { lookupField = dfr.getName(); break; }
                        }
                    }
                }
                if (emailField != null && lookupField != null) break;
            }
            // Allow test override of field names for predictable SOQL when field ordering
            // is non-deterministic (e.g. using standard objects as email objects in tests).
            if (TEST_FORCE_EA_EMAIL_FIELD  != null) emailField  = TEST_FORCE_EA_EMAIL_FIELD;
            if (TEST_FORCE_EA_LOOKUP_FIELD != null) lookupField = TEST_FORCE_EA_LOOKUP_FIELD;
            if (emailField == null || lookupField == null) return;
        }

        // Step 1: collect key → IDs from email object
        Map<String,Set<Id>> keyToIds = new Map<String,Set<Id>>();
        Map<String,String>  keyToRaw = new Map<String,String>();

        if (useInjection) {
            // Test injection: bypass SOQL to cover EA code paths in orgs without email object
            for (String k : TEST_EA_KEY_TO_IDS.keySet()) {
                if (!existingKeys.contains(k)) {
                    keyToIds.put(k, new Set<Id>(TEST_EA_KEY_TO_IDS.get(k)));
                    if (TEST_EA_KEY_TO_RAW != null && TEST_EA_KEY_TO_RAW.containsKey(k))
                        keyToRaw.put(k, TEST_EA_KEY_TO_RAW.get(k));
                }
            }
        } else {
            String fEmail  = emailField;
            String fLookup = lookupField;
            for (SObject ea : Database.query(
                'SELECT ' + fEmail + ', ' + fLookup +
                ' FROM ' + emailObjName + ' WHERE ' + fLookup + ' != null AND ' + fEmail + ' != null'
            )) {
                String raw      = (String) ea.get(fEmail);
                Id     recordId = (Id)     ea.get(fLookup);
                String key      = DataNormalizationUtil.buildMatchKey(objectType, 'Email', raw);
                if (String.isBlank(key) || existingKeys.contains(key)) continue;
                if (!keyToIds.containsKey(key)) { keyToIds.put(key, new Set<Id>()); keyToRaw.put(key, raw); }
                keyToIds.get(key).add(recordId);
            }
        }
        if (keyToIds.isEmpty()) return;

        // Seed with IDs already found by direct-field detection (same email key)
        for (String key : keyToIds.keySet()) {
            if (groups.containsKey(key)) keyToIds.get(key).addAll(groups.get(key).candidateIds);
        }

        // Step 2: cross-check — find parent records whose direct fields match email object emails
        List<String> directFields = resolveFields(objectType, 'Email');
        if (forceEmptyDirectFieldsForTest) directFields = new List<String>();
        Set<Id> allEaIds = new Set<Id>();
        for (Set<Id> ids : keyToIds.values()) allEaIds.addAll(ids);

        Map<Id,String> nameMap = new Map<Id,String>();

        if (!directFields.isEmpty()) {
            Set<String> rawEmailSet = new Set<String>(keyToRaw.values());
            List<String> orClauses  = new List<String>();
            for (String f : directFields) orClauses.add(f + ' IN :rawEmailSet');

            String q = 'SELECT Id, Name, ' + String.join(directFields, ', ')
                     + ' FROM ' + objectType
                     + ' WHERE Id IN :allEaIds OR (' + String.join(orClauses, ' OR ') + ')'
                     + ' LIMIT ' + lim;

            for (SObject rec : Database.query(q)) {
                Id recId = rec.Id;
                nameMap.put(recId, (String) rec.get('Name'));
                for (String f : directFields) {
                    String raw = (String) rec.get(f);
                    if (String.isBlank(raw)) continue;
                    String key = DataNormalizationUtil.buildMatchKey(objectType, 'Email', raw);
                    if (!keyToIds.containsKey(key)) continue;
                    keyToIds.get(key).add(recId);
                }
            }
        } else {
            for (SObject rec : Database.query(
                'SELECT Id, Name FROM ' + objectType + ' WHERE Id IN :allEaIds'
            )) {
                nameMap.put(rec.Id, (String) rec.get('Name'));
            }
        }

        // Step 3: merge into groups map
        for (String key : keyToIds.keySet()) {
            Set<Id> ids = keyToIds.get(key);
            if (groups.containsKey(key)) ids.addAll(groups.get(key).candidateIds);
            if (ids.size() < 2) continue;
            if (!groups.containsKey(key)) groups.put(key, new DuplicateGroup(key, 'Email', objectType));
            groups.get(key).addCandidates(ids, nameMap);
        }
    }

    /**
     * Public version of the email-object detection phase used by MergeScanBatch.finish().
     * Accepts any qualifying custom object name (defaults to Email_Address__c).
     * Updates the stateful Map<String,String> accumulators in-place rather than returning
     * DuplicateGroup objects (to stay compatible with the Stateful serialization contract).
     */
    public static void enrichWithEmailObject(
        String objectType,
        String emailObjName,
        Set<String> existingKeys,
        Map<String,String> accMatchType,
        Map<String,String> accIdSet,
        Map<String,String> accNames
    ) {
        if (String.isBlank(emailObjName)) return;

        Boolean useInjection = TEST_EA_KEY_TO_IDS != null;

        if (!useInjection) {
            if (emailObjName == 'Email_Address__c') {
                if (!isEmailAddressObjectAvailable()) return;
            } else {
                if (!Schema.getGlobalDescribe().containsKey(emailObjName.toLowerCase())) return;
            }
        }

        Map<String,Schema.SObjectField> eaFieldMap = useInjection ? null
            : Schema.getGlobalDescribe().get(emailObjName.toLowerCase())?.getDescribe()?.fields?.getMap();
        if (!useInjection && eaFieldMap == null) return;

        // Dynamically resolve the first EMAIL-type field and lookup to objectType
        String emailField  = null;
        String lookupField = null;
        if (!useInjection) {
            for (Schema.SObjectField f : eaFieldMap.values()) {
                Schema.DescribeFieldResult dfr = f.getDescribe();
                if (emailField == null
                        && (dfr.getType() == Schema.DisplayType.EMAIL || TEST_SKIP_FIELD_ACCESSIBILITY_CHECK)
                        && (TEST_SKIP_FIELD_ACCESSIBILITY_CHECK || dfr.isAccessible())) {
                    emailField = dfr.getName();
                }
                if (lookupField == null && dfr.getType() == Schema.DisplayType.REFERENCE) {
                    if (TEST_SKIP_FIELD_ACCESSIBILITY_CHECK) {
                        lookupField = dfr.getName();
                    } else {
                        for (Schema.SObjectType ref : dfr.getReferenceTo()) {
                            if (ref.getDescribe().getName() == objectType) { lookupField = dfr.getName(); break; }
                        }
                    }
                }
                if (emailField != null && lookupField != null) break;
            }
            // Allow test override of field names for predictable SOQL when field ordering
            // is non-deterministic (e.g. using standard objects as email objects in tests).
            if (TEST_FORCE_EA_EMAIL_FIELD  != null) emailField  = TEST_FORCE_EA_EMAIL_FIELD;
            if (TEST_FORCE_EA_LOOKUP_FIELD != null) lookupField = TEST_FORCE_EA_LOOKUP_FIELD;
            if (emailField == null || lookupField == null) return;
        }

        // Step 1: collect key → IDs from email object
        Map<String,Set<Id>> keyToIds = new Map<String,Set<Id>>();
        Map<String,String>  keyToRaw = new Map<String,String>();

        if (useInjection) {
            // Test injection: bypass SOQL to cover EA code paths in orgs without email object
            for (String k : TEST_EA_KEY_TO_IDS.keySet()) {
                if (!existingKeys.contains(k)) {
                    keyToIds.put(k, new Set<Id>(TEST_EA_KEY_TO_IDS.get(k)));
                    if (TEST_EA_KEY_TO_RAW != null && TEST_EA_KEY_TO_RAW.containsKey(k))
                        keyToRaw.put(k, TEST_EA_KEY_TO_RAW.get(k));
                }
            }
        } else {
            String fEmail  = emailField;
            String fLookup = lookupField;
            for (SObject ea : Database.query(
                'SELECT ' + fEmail + ', ' + fLookup +
                ' FROM ' + emailObjName + ' WHERE ' + fLookup + ' != null AND ' + fEmail + ' != null'
            )) {
                String raw      = (String) ea.get(fEmail);
                Id     recordId = (Id)     ea.get(fLookup);
                String key      = DataNormalizationUtil.buildMatchKey(objectType, 'Email', raw);
                if (String.isBlank(key) || existingKeys.contains(key)) continue;
                if (!keyToIds.containsKey(key)) { keyToIds.put(key, new Set<Id>()); keyToRaw.put(key, raw); }
                keyToIds.get(key).add(recordId);
            }
        }
        if (keyToIds.isEmpty()) return;

        // Seed with IDs already accumulated by the batch
        for (String key : keyToIds.keySet()) {
            if (accIdSet.containsKey(key)) {
                for (String idStr : accIdSet.get(key).split('\\|')) {
                    if (String.isNotBlank(idStr)) keyToIds.get(key).add((Id) idStr);
                }
            }
        }

        // Step 2: cross-check direct email fields + fetch names in one query
        List<String> directFields = resolveFields(objectType, 'Email');
        if (forceEmptyDirectFieldsForTest) directFields = new List<String>();
        Set<Id>      allEaIds     = new Set<Id>();
        for (Set<Id> ids : keyToIds.values()) allEaIds.addAll(ids);

        Map<Id,String> nameMap = new Map<Id,String>();

        if (!directFields.isEmpty()) {
            Set<String> rawEmailSet = new Set<String>(keyToRaw.values());
            List<String> orClauses  = new List<String>();
            for (String f : directFields) orClauses.add(f + ' IN :rawEmailSet');

            String q = 'SELECT Id, Name, ' + String.join(directFields, ', ')
                     + ' FROM ' + objectType
                     + ' WHERE Id IN :allEaIds OR (' + String.join(orClauses, ' OR ') + ')';

            for (SObject rec : Database.query(q)) {
                Id recId = rec.Id;
                nameMap.put(recId, (String) rec.get('Name'));
                for (String f : directFields) {
                    String raw = (String) rec.get(f);
                    if (String.isBlank(raw)) continue;
                    String key = DataNormalizationUtil.buildMatchKey(objectType, 'Email', raw);
                    if (!keyToIds.containsKey(key)) continue;
                    keyToIds.get(key).add(recId);
                }
            }
        } else {
            for (SObject rec : Database.query(
                'SELECT Id, Name FROM ' + objectType + ' WHERE Id IN :allEaIds'
            )) {
                nameMap.put(rec.Id, (String) rec.get('Name'));
            }
        }

        // Step 3: update stateful accumulators
        for (String key : keyToIds.keySet()) {
            Set<Id> ids = keyToIds.get(key);
            if (ids.size() < 2) continue;

            if (!accMatchType.containsKey(key)) accMatchType.put(key, 'Email');

            List<String> idStrs = new List<String>();
            for (Id id : ids) idStrs.add(String.valueOf(id));
            accIdSet.put(key, String.join(idStrs, '|'));

            for (Id id : ids) {
                String nameKey = key + '::' + String.valueOf(id);
                if (!accNames.containsKey(nameKey)) {
                    accNames.put(nameKey, nameMap.containsKey(id) ? nameMap.get(id) : '');
                }
            }
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
                    Merge_Ticket__c     = insertedTickets[i].Id,
                    Record_Id__c        = String.valueOf(recId),
                    Record_Name__c      = grp.candidateNames.get(recId),
                    Is_Master__c        = false,
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
     * Resolves the field list for a given object + matchType using Schema introspection.
     * Email → all Schema.DisplayType.EMAIL fields
     * Phone → all Schema.DisplayType.PHONE fields
     * Name  → 'Name' (universal) + Common_Name__c if present
     * Any field that does not exist in the org's schema is automatically excluded.
     */
    public static List<String> resolveFields(String objectType, String matchType) {
        Map<String,Schema.SObjectField> fieldMap =
            Schema.getGlobalDescribe().get(objectType)?.getDescribe()?.fields?.getMap();
        if (fieldMap == null) return new List<String>();

        if (matchType == 'Name') {
            List<String> result = new List<String>();
            if (fieldMap.containsKey('name'))           result.add('Name');
            if (fieldMap.containsKey('common_name__c')) result.add('Common_Name__c');
            return result;
        }

        Schema.DisplayType targetType = matchType == 'Email'
            ? Schema.DisplayType.EMAIL
            : Schema.DisplayType.PHONE;

        List<String> result = new List<String>();
        for (Schema.SObjectField f : fieldMap.values()) {
            Schema.DescribeFieldResult dfr = f.getDescribe();
            // No FLS check — matches original filterAvailableFields behaviour.
            // SOQL in a without-sharing class already bypasses row-level security;
            // FLS enforcement is intentionally skipped so admin scans are never
            // silently degraded by profile-level field restrictions.
            if (dfr.getType() == targetType) {
                result.add(dfr.getName());
            }
        }
        return result;
    }

    // ─── Auto-discover qualifying email object ────────────────────────────────

    /**
     * Finds the first accessible, queryable custom object that has both an
     * EMAIL-type field and a REFERENCE field pointing to objectType.
     * Called when emailObjectApiName == 'AUTO' to support cross-org portability.
     * Returns the object's API name, or null if none qualifies.
     */
    public static String resolveEmailObjectName(String objectType) {
        if (TEST_RESOLVE_EMAIL_OBJECT_NAME != null) return TEST_RESOLVE_EMAIL_OBJECT_NAME;
        Map<String,Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
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

            if (hasEmailField && hasLookupToTarget) return objDesc.getName();
        }
        return null;
    }

    // ─── Email_Address__c availability (cached per transaction) ──────────────

    private static Boolean isEmailAddressObjectAvailable() {
        if (emailAddressObjectAvailable == null) {
            // Keys in getGlobalDescribe() are lowercase — must compare lowercase
            emailAddressObjectAvailable =
                Schema.getGlobalDescribe().containsKey('email_address__c');
        }
        return emailAddressObjectAvailable;
    }

    // ─── Deduplication ────────────────────────────────────────────────────────

    private static Map<String,DuplicateGroup> deduplicateByCandidateSet(
        Map<String,DuplicateGroup> groups,
        Set<String> existingCandidateSets
    ) {
        Map<String,Integer> priority = new Map<String,Integer>{
            'Email' => 3, 'Phone' => 2, 'Name' => 1
        };

        Map<String,DuplicateGroup> byCanonical = new Map<String,DuplicateGroup>();

        for (DuplicateGroup grp : groups.values()) {
            List<String> sortedIds = new List<String>();
            for (Id id : grp.candidateIds) sortedIds.add(String.valueOf(id));
            sortedIds.sort();
            String canonical = String.join(sortedIds, '|');

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

        Map<String,DuplicateGroup> result = new Map<String,DuplicateGroup>();
        for (DuplicateGroup grp : byCanonical.values()) {
            result.put(grp.matchKey, grp);
        }
        return result;
    }

    // ─── Inner accumulator ────────────────────────────────────────────────────

    private class DuplicateGroup {
        public String         matchKey;
        public String         matchType;
        public String         objectType;
        public Set<Id>        candidateIds;
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
