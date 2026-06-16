/**
 * RelatedRecordsService.cls
 * Auto-detects installed packages at runtime and queries related record counts.
 * Uses Schema.getGlobalDescribe() checks before running any dynamic SOQL —
 * the class compiles and deploys in any org, with or without EDA.
 */
public without sharing class RelatedRecordsService {

    @TestVisible private static Map<String,List<AggregateResult>> TEST_TOTAL_RESULTS  = null;
    @TestVisible private static Map<String,List<AggregateResult>> TEST_ACTIVE_RESULTS = null;
    @TestVisible private static Set<String>                       TEST_THROW_OBJECTS  =
        new Set<String>();
    @TestVisible private static Boolean TEST_THROW_PICKLIST = false;
    // Test-injection: forces getObjectConfigs to skip real Related_Object_Config__c
    // rows and use the hardcoded EDA fallback configs, so coverage of the fallback
    // path doesn't depend on whether the org has custom configs already set up.
    @TestVisible private static Boolean TEST_FORCE_EDA_FALLBACK_CONFIGS = false;

    // Schema.getGlobalDescribe() is platform-cached per transaction, but calling the
    // method repeatedly adds dispatch overhead. Cache it once here for clarity and
    // to make the query-limit math easier to reason about.
    private static Map<String,Schema.SObjectType> GD_CACHE;
    private static Map<String,Schema.SObjectType> gd() {
        if (GD_CACHE == null) GD_CACHE = Schema.getGlobalDescribe();
        return GD_CACHE;
    }

    // Each configured object fires up to 2 SOQL queries (total + active counts).
    // Cap at 40 configs → max 80 SOQL from this service; leaves headroom for all
    // other queries in the same transaction (MergeTicketService, MergeController…).
    private static final Integer MAX_CONFIGS = 40;

    // ─── Object configuration ──────────────────────────────────────────────────

    private class RelatedObjectConfig {
        String      objectApiName;
        String      parentField;
        String      statusField;
        Set<String> activeKeywords; // matched case-insensitively against picklist values
        String      displayLabel;

        RelatedObjectConfig(String obj, String parentFld, String statusFld,
                            Set<String> keywords, String label) {
            this.objectApiName  = obj;
            this.parentField    = parentFld;
            this.statusField    = statusFld;
            this.activeKeywords = keywords;
            this.displayLabel   = label;
        }
    }

    private static List<RelatedObjectConfig> getObjectConfigs(String parentType) {
        Map<String,Schema.SObjectType> gd = gd();
        List<RelatedObjectConfig> configs = new List<RelatedObjectConfig>();

        // Read user-configured objects first
        if (!TEST_FORCE_EDA_FALLBACK_CONFIGS && gd.containsKey('related_object_config__c')) {
            List<SObject> rows = Database.query(
                'SELECT Name, Object_API_Name__c, Parent_Field__c, ' +
                '       Status_Field__c, Active_Status_Values__c, Sort_Order__c ' +
                'FROM Related_Object_Config__c ' +
                'WHERE Object_Type__c = :parentType AND Is_Active__c = true ' +
                'ORDER BY Sort_Order__c NULLS LAST, Name ASC'
            );
            if (!rows.isEmpty()) {
                for (SObject row : rows) {
                    String statusFld  = (String) row.get('Status_Field__c');
                    String activeVals = (String) row.get('Active_Status_Values__c');
                    Set<String> keywords = null;
                    if (!String.isBlank(activeVals)) {
                        keywords = new Set<String>();
                        for (String v : activeVals.split(',')) {
                            keywords.add(v.trim().toLowerCase());
                        }
                    }
                    configs.add(new RelatedObjectConfig(
                        (String) row.get('Object_API_Name__c'),
                        (String) row.get('Parent_Field__c'),
                        String.isBlank(statusFld) ? null : statusFld,
                        keywords,
                        (String) row.get('Name')
                    ));
                }
                return configs;
            }
        }

        // Fallback: EDA auto-detection when no custom configs exist
        if (parentType == 'Contact') {
            if (gd.containsKey('hed__course_enrollment__c')) {
                configs.add(new RelatedObjectConfig(
                    'hed__Course_Enrollment__c', 'hed__Contact__c',
                    'hed__Status__c',
                    new Set<String>{'current','enrolled','registered'}, 'Cours'
                ));
            }
            if (gd.containsKey('hed__program_enrollment__c')) {
                configs.add(new RelatedObjectConfig(
                    'hed__Program_Enrollment__c', 'hed__Contact__c',
                    'Status__c',
                    new Set<String>{'current','enrolled','applicant'}, 'Programmes'
                ));
            }
            if (gd.containsKey('hed__affiliation__c')) {
                configs.add(new RelatedObjectConfig(
                    'hed__Affiliation__c', 'hed__Contact__c',
                    null, null, 'Affiliations'
                ));
            }
        }

        return configs;
    }

    // ─── Public API ────────────────────────────────────────────────────────────

    public static Boolean isEDAAvailable() {
        return gd().containsKey('hed__course_enrollment__c');
    }

    public static MergeWrappers.RelatedCountsWrapper getCountsForContact(Id contactId) {
        Map<Id,MergeWrappers.RelatedCountsWrapper> result =
            getBulkCountsForContacts(new Set<Id>{ contactId });
        return result.containsKey(contactId)
            ? result.get(contactId)
            : new MergeWrappers.RelatedCountsWrapper();
    }

    public static Map<Id,MergeWrappers.RelatedCountsWrapper> getBulkCountsForContacts(
        Set<Id> contactIds
    ) {
        return getBulkCounts(contactIds, 'Contact');
    }

    public static Map<Id,MergeWrappers.RelatedCountsWrapper> getBulkCounts(
        Set<Id> recordIds,
        String  parentType
    ) {
        Map<Id,MergeWrappers.RelatedCountsWrapper> result =
            new Map<Id,MergeWrappers.RelatedCountsWrapper>();
        for (Id rid : recordIds) {
            if (rid != null) result.put(rid, new MergeWrappers.RelatedCountsWrapper());
        }
        if (recordIds.isEmpty()) return result;

        List<RelatedObjectConfig> configs = getObjectConfigs(parentType);
        if (configs.isEmpty()) return result;
        if (configs.size() > MAX_CONFIGS) {
            System.debug(LoggingLevel.WARN,
                'RelatedRecordsService: ' + configs.size() + ' configs exceed MAX_CONFIGS=' +
                MAX_CONFIGS + '. Truncating to stay within SOQL governor limits.');
            List<RelatedObjectConfig> capped = new List<RelatedObjectConfig>();
            for (Integer i = 0; i < MAX_CONFIGS; i++) capped.add(configs[i]);
            configs = capped;
        }

        Map<String,Schema.SObjectType> gd = gd();

        for (RelatedObjectConfig cfg : configs) {
            if (!gd.containsKey(cfg.objectApiName.toLowerCase())) continue;

            Map<Id, MergeWrappers.RelatedCount> countByRecord =
                new Map<Id, MergeWrappers.RelatedCount>();
            for (Id rid : recordIds) {
                if (rid == null) continue;
                MergeWrappers.RelatedCount rc = new MergeWrappers.RelatedCount(cfg.displayLabel);
                result.get(rid).counts.add(rc);
                countByRecord.put(rid, rc);
            }

            try {
                if (TEST_THROW_OBJECTS.contains(cfg.objectApiName)) {
                    throw new IllegalArgumentException('test-induced');
                }

                String totalQ =
                    'SELECT ' + cfg.parentField + ' pid, COUNT(Id) total ' +
                    'FROM '   + cfg.objectApiName + ' ' +
                    'WHERE '  + cfg.parentField + ' IN :recordIds ' +
                    'GROUP BY ' + cfg.parentField;
                List<AggregateResult> totalRows =
                    (TEST_TOTAL_RESULTS != null && TEST_TOTAL_RESULTS.containsKey(cfg.objectApiName))
                    ? TEST_TOTAL_RESULTS.get(cfg.objectApiName)
                    : Database.query(totalQ);
                for (AggregateResult ar : totalRows) {
                    Id pid = (Id) ar.get('pid');
                    if (countByRecord.containsKey(pid)) {
                        countByRecord.get(pid).total = (Integer) ar.get('total');
                    }
                }

                if (cfg.statusField != null && cfg.activeKeywords != null) {
                    Schema.DescribeSObjectResult objDesc =
                        gd.get(cfg.objectApiName.toLowerCase()).getDescribe();
                    Map<String,Schema.SObjectField> fields = objDesc.fields.getMap();
                    if (fields.containsKey(cfg.statusField.toLowerCase())) {
                        Set<String> activeVals = resolveActiveStatuses(
                            fields.get(cfg.statusField.toLowerCase()).getDescribe(),
                            cfg.activeKeywords
                        );
                        if (!activeVals.isEmpty()) {
                            String activeQ =
                                'SELECT ' + cfg.parentField + ' pid, COUNT(Id) total ' +
                                'FROM '   + cfg.objectApiName + ' ' +
                                'WHERE '  + cfg.parentField + ' IN :recordIds ' +
                                'AND '    + cfg.statusField  + ' IN :activeVals ' +
                                'GROUP BY ' + cfg.parentField;
                            List<AggregateResult> activeRows =
                                (TEST_ACTIVE_RESULTS != null && TEST_ACTIVE_RESULTS.containsKey(cfg.objectApiName))
                                ? TEST_ACTIVE_RESULTS.get(cfg.objectApiName)
                                : Database.query(activeQ);
                            for (AggregateResult ar : activeRows) {
                                Id pid = (Id) ar.get('pid');
                                if (countByRecord.containsKey(pid)) {
                                    countByRecord.get(pid).active = (Integer) ar.get('total');
                                }
                            }
                        }
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'RelatedRecordsService [' + cfg.objectApiName + ']: ' + e.getMessage());
            }
        }

        for (MergeWrappers.RelatedCountsWrapper w : result.values()) {
            w.computeDerived();
        }
        return result;
    }

    // ─── Private helpers ───────────────────────────────────────────────────────

    private static Set<String> resolveActiveStatuses(
        Schema.DescribeFieldResult dfr,
        Set<String> keywords
    ) {
        Set<String> active = new Set<String>();
        try {
            if (TEST_THROW_PICKLIST) throw new IllegalArgumentException('test-induced');
            for (Schema.PicklistEntry e : dfr.getPicklistValues()) {
                if (!e.isActive()) continue;
                String v = e.getValue().toLowerCase();
                for (String kw : keywords) {
                    if (v.contains(kw)) { active.add(e.getValue()); break; }
                }
            }
        } catch (Exception ex) {
            if (!keywords.isEmpty()) {
                active.add(new List<String>(keywords)[0]);
            }
        }
        return active;
    }
}
