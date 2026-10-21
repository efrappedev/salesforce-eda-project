/**
 * DucFormConfigStore.cls
 * Single read/write point for the Data Update Center form configuration.
 *
 * The configuration lives in two layers:
 *   1. Custom Metadata (Data_Update_Form__mdt, Data_Update_Form_Field__mdt,
 *      Data_Update_Appearance_Template__mdt) — the base, shipped with deploys.
 *   2. DUC_Form_Config__c rows — what the Form Builder publishes. One row per metadata record
 *      (Config_Key__c = its fullName), holding the published values as JSON.
 *
 * Reads merge row values over the metadata record field by field — the same semantics a
 * metadata deploy has (values left out keep their previous value) — and a row flagged
 * Is_Deleted__c hides the record entirely. The merged records are rebuilt as in-memory
 * __mdt sObjects, so every caller keeps working with the same types it always did.
 *
 * Why: publishing used to go through Metadata.Operations.enqueueDeployment, which needs
 * metadata rights on the running user. Plain DML on an app object only needs the app's own
 * permission sets (Data_Update_Center_Form_Admin).
 *
 * without sharing: the public portal (guest user) and every staff member must see the same
 * configuration regardless of who published it. Who may WRITE is gated by the callers
 * (DataUpdateFormAdminController.requireManageForms / Data_Update_Delete_Forms).
 */
public without sharing class DucFormConfigStore {

    public class StoreException extends Exception {}

    public static final String FORM_TYPE     = 'Data_Update_Form__mdt';
    public static final String FIELD_TYPE    = 'Data_Update_Form_Field__mdt';
    public static final String TEMPLATE_TYPE = 'Data_Update_Appearance_Template__mdt';
    @TestVisible private static final Integer VALUES_MAX_LENGTH = 131072;

    // Tests can't insert Custom Metadata: they hand in the base layer here instead.
    @TestVisible private static Map<String, List<SObject>> baseForTest;
    // Unless a test sets baseForTest, tests run against a fixed copy of the forms (static resource
    // DucTestFormFixtures), never the org's own: production ships minimal base forms and staff
    // change them at will, so the org's forms can't be what the tests depend on.
    @TestVisible private static Boolean useOrgMetadataForTest = false;
    @TestVisible private static final String TEST_FIXTURES_RESOURCE = 'DucTestFormFixtures';

    // Per-transaction caches (cleared on every write).
    private static Map<String, List<SObject>> baseCache = new Map<String, List<SObject>>();
    private static Map<String, List<DUC_Form_Config__c>> rowCache = new Map<String, List<DUC_Form_Config__c>>();
    private static Map<String, Map<String, Map<String, Object>>> mergedCache = new Map<String, Map<String, Map<String, Object>>>();

    // ─── Read ────────────────────────────────────────────────────────────

    /** Every live form (active or not), sorted by label. */
    public static List<Data_Update_Form__mdt> forms() {
        List<Data_Update_Form__mdt> result = (List<Data_Update_Form__mdt>) JSON.deserialize(
            JSON.serialize(merged(FORM_TYPE).values()), List<Data_Update_Form__mdt>.class);
        result.sort(new FormLabelComparator());
        return result;
    }

    /** One live form, or null. */
    public static Data_Update_Form__mdt form(String developerName) {
        if (String.isBlank(developerName)) return null;
        Map<String, Object> m = merged(FORM_TYPE).get(developerName.toLowerCase());
        return m == null ? null : (Data_Update_Form__mdt) JSON.deserialize(JSON.serialize(m), Data_Update_Form__mdt.class);
    }

    /** The live question/table records of a form, by Display_Order__c (blank last). */
    public static List<Data_Update_Form_Field__mdt> fields(String formDeveloperName) {
        List<Map<String, Object>> picked = new List<Map<String, Object>>();
        for (Map<String, Object> m : merged(FIELD_TYPE).values()) {
            String formName = formOf(m);
            if (formName != null && formDeveloperName != null && formName.equalsIgnoreCase(formDeveloperName)) picked.add(m);
        }
        List<Data_Update_Form_Field__mdt> result = (List<Data_Update_Form_Field__mdt>) JSON.deserialize(
            JSON.serialize(picked), List<Data_Update_Form_Field__mdt>.class);
        result.sort(new DisplayOrderComparator());
        return result;
    }

    /** Every live appearance template (active or not), sorted by label. */
    public static List<Data_Update_Appearance_Template__mdt> appearanceTemplates() {
        List<Data_Update_Appearance_Template__mdt> result = (List<Data_Update_Appearance_Template__mdt>) JSON.deserialize(
            JSON.serialize(merged(TEMPLATE_TYPE).values()), List<Data_Update_Appearance_Template__mdt>.class);
        result.sort(new TemplateLabelComparator());
        return result;
    }

    /**
     * Every DeveloperName ever used for this type, lower-cased — deleted ones included, so a new
     * record never revives the leftovers (old values, old questions) of a deleted one.
     */
    public static Set<String> usedDeveloperNames(String metadataType) {
        Set<String> names = new Set<String>();
        for (SObject rec : baseRecords(metadataType)) {
            names.add(((String) rec.get('DeveloperName')).toLowerCase());
        }
        for (DUC_Form_Config__c row : rows(metadataType)) {
            if (String.isNotBlank(row.Developer_Name__c)) names.add(row.Developer_Name__c.toLowerCase());
        }
        return names;
    }

    // ─── Write ───────────────────────────────────────────────────────────

    /** Publishes metadata-shaped records: each one's values are merged into its row (created if new). */
    public static void save(List<Metadata.CustomMetadata> records) {
        if (records == null || records.isEmpty()) return;
        Map<String, DUC_Form_Config__c> byKey = existingRows(records);
        Map<String, DUC_Form_Config__c> toSave = new Map<String, DUC_Form_Config__c>();
        for (Metadata.CustomMetadata cmd : records) {
            String key = cmd.fullName;
            String metadataType = key.substringBefore('.');
            String developerName = key.substringAfter('.');
            if (String.isBlank(metadataType) || String.isBlank(developerName)) {
                throw new StoreException('Invalid record name: ' + key);
            }
            DUC_Form_Config__c row = toSave.containsKey(key.toLowerCase()) ? toSave.get(key.toLowerCase()) : byKey.get(key.toLowerCase());
            if (row == null) {
                row = new DUC_Form_Config__c(Config_Key__c = key, Metadata_Type__c = metadataType, Developer_Name__c = developerName);
            }
            // A damaged row is rewritten from what is being published now.
            Map<String, Object> values = parseValues(row.Values_JSON__c);
            if (values == null) values = new Map<String, Object>();
            for (Metadata.CustomMetadataValue v : cmd.values) {
                values.put(v.field, v.value);
            }
            String valuesJson = JSON.serialize(values);
            if (valuesJson.length() > VALUES_MAX_LENGTH) {
                throw new StoreException('This form is too large to save (' + developerName + '). Remove some text or blocks and try again.');
            }
            row.Values_JSON__c = valuesJson;
            if (String.isNotBlank(cmd.label)) row.Label__c = cmd.label;
            row.Name = (String.isNotBlank(row.Label__c) ? row.Label__c : developerName).left(80);
            row.Is_Deleted__c = false;
            row.Form_Developer_Name__c = metadataType == FORM_TYPE ? developerName
                : metadataType == FIELD_TYPE ? fieldFormName(values, row, developerName) : null;
            toSave.put(key.toLowerCase(), row);
        }
        assertFormsNotDeleted(toSave.values());
        upsert toSave.values() Config_Key__c;
        clearCaches();
    }

    // A builder left open on a form someone else deleted must not bring it back half-built:
    // names of deleted forms are never reused, so publishing into one is always a stale builder.
    private static void assertFormsNotDeleted(List<DUC_Form_Config__c> toSave) {
        Set<String> formNames = new Set<String>();
        for (DUC_Form_Config__c row : toSave) {
            if (String.isNotBlank(row.Form_Developer_Name__c)) formNames.add(row.Form_Developer_Name__c);
        }
        if (formNames.isEmpty()) return;
        for (DUC_Form_Config__c deleted : [
            SELECT Developer_Name__c FROM DUC_Form_Config__c
            WHERE Metadata_Type__c = :FORM_TYPE AND Is_Deleted__c = true AND Developer_Name__c IN :formNames
            LIMIT 1
        ]) {
            throw new StoreException('This form was deleted (' + deleted.Developer_Name__c
                + '). Close the builder and reload the page.');
        }
    }

    /** Deletes a form and all its questions/tables (hidden everywhere, rows kept for the record). */
    public static void deleteForm(String formDeveloperName) {
        List<Metadata.CustomMetadata> names = new List<Metadata.CustomMetadata>();
        for (Data_Update_Form_Field__mdt fm : fields(formDeveloperName)) {
            names.add(named(FIELD_TYPE + '.' + fm.DeveloperName));
        }
        names.add(named(FORM_TYPE + '.' + formDeveloperName));
        Map<String, DUC_Form_Config__c> byKey = existingRows(names);
        List<DUC_Form_Config__c> toSave = new List<DUC_Form_Config__c>();
        for (Metadata.CustomMetadata cmd : names) {
            DUC_Form_Config__c row = byKey.get(cmd.fullName.toLowerCase());
            if (row == null) {
                row = new DUC_Form_Config__c(
                    Config_Key__c = cmd.fullName,
                    Metadata_Type__c = cmd.fullName.substringBefore('.'),
                    Developer_Name__c = cmd.fullName.substringAfter('.'),
                    Name = cmd.fullName.substringAfter('.').left(80)
                );
            }
            row.Form_Developer_Name__c = formDeveloperName;
            row.Is_Deleted__c = true;
            toSave.add(row);
        }
        upsert toSave Config_Key__c;
        clearCaches();
    }

    @TestVisible private static void clearCaches() {
        baseCache.clear();
        rowCache.clear();
        mergedCache.clear();
    }

    // ─── Merge ───────────────────────────────────────────────────────────

    // Lower-cased DeveloperName => record as an untyped map (JSON shape of the __mdt sObject).
    private static Map<String, Map<String, Object>> merged(String metadataType) {
        if (mergedCache.containsKey(metadataType)) return mergedCache.get(metadataType);
        Map<String, Map<String, Object>> byName = new Map<String, Map<String, Object>>();
        for (SObject rec : baseRecords(metadataType)) {
            Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(rec));
            byName.put(((String) m.get('DeveloperName')).toLowerCase(), m);
        }
        for (DUC_Form_Config__c row : rows(metadataType)) {
            // A damaged row (no name, unreadable values) is skipped: it must never take down every
            // form, the portal and the builder with it. The base record (if any) stays as it was.
            if (String.isBlank(row.Developer_Name__c)) continue;
            String name = row.Developer_Name__c.toLowerCase();
            if (row.Is_Deleted__c == true) {
                byName.remove(name);
                continue;
            }
            Map<String, Object> m = byName.get(name);
            if (m == null) {
                m = new Map<String, Object>{
                    'attributes' => new Map<String, Object>{ 'type' => metadataType },
                    'DeveloperName' => row.Developer_Name__c
                };
            }
            Map<String, Object> values = parseValues(row.Values_JSON__c);
            if (values == null) {
                System.debug(LoggingLevel.ERROR, 'DucFormConfigStore: skipped unreadable row ' + row.Developer_Name__c);
                continue;
            }
            if (String.isNotBlank(row.Label__c)) m.put('MasterLabel', row.Label__c);
            for (String field : values.keySet()) {
                if (field == 'Form__c') {
                    // A metadata relationship is published by name; the sObject carries it as Form__r.
                    m.remove('Form__c');
                    m.put('Form__r', new Map<String, Object>{
                        'attributes' => new Map<String, Object>{ 'type' => FORM_TYPE },
                        'DeveloperName' => values.get(field)
                    });
                } else {
                    m.put(field, values.get(field));
                }
            }
            byName.put(name, m);
        }
        mergedCache.put(metadataType, byName);
        return byName;
    }

    private static String formOf(Map<String, Object> fieldRecord) {
        Object rel = fieldRecord.get('Form__r');
        return rel instanceof Map<String, Object> ? (String) ((Map<String, Object>) rel).get('DeveloperName') : null;
    }

    // Form of a question row: from the values being saved, else the row's, else the metadata record's.
    private static String fieldFormName(Map<String, Object> values, DUC_Form_Config__c row, String developerName) {
        if (values.get('Form__c') instanceof String) return (String) values.get('Form__c');
        if (String.isNotBlank(row.Form_Developer_Name__c)) return row.Form_Developer_Name__c;
        Map<String, Object> m = merged(FIELD_TYPE).get(developerName.toLowerCase());
        return m == null ? null : formOf(m);
    }

    // Values of a row, or null when the JSON is unreadable (callers decide how to recover).
    private static Map<String, Object> parseValues(String valuesJson) {
        if (String.isBlank(valuesJson)) return new Map<String, Object>();
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(valuesJson);
        } catch (JSONException e) {
            return null;
        }
        return parsed instanceof Map<String, Object> ? (Map<String, Object>) parsed : null;
    }

    private static Metadata.CustomMetadata named(String fullName) {
        Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
        cmd.fullName = fullName;
        return cmd;
    }

    private static Map<String, DUC_Form_Config__c> existingRows(List<Metadata.CustomMetadata> records) {
        Set<String> keys = new Set<String>();
        for (Metadata.CustomMetadata cmd : records) keys.add(cmd.fullName);
        Map<String, DUC_Form_Config__c> byKey = new Map<String, DUC_Form_Config__c>();
        for (DUC_Form_Config__c row : [
            SELECT Id, Config_Key__c, Metadata_Type__c, Developer_Name__c, Form_Developer_Name__c,
                   Label__c, Values_JSON__c, Is_Deleted__c
            FROM DUC_Form_Config__c
            WHERE Config_Key__c IN :keys
        ]) {
            byKey.put(row.Config_Key__c.toLowerCase(), row);
        }
        return byKey;
    }

    // ─── Layers ──────────────────────────────────────────────────────────

    private static List<DUC_Form_Config__c> rows(String metadataType) {
        if (!rowCache.containsKey(metadataType)) {
            rowCache.put(metadataType, [
                SELECT Developer_Name__c, Form_Developer_Name__c, Label__c, Values_JSON__c, Is_Deleted__c
                FROM DUC_Form_Config__c
                WHERE Metadata_Type__c = :metadataType
                ORDER BY CreatedDate ASC
            ]);
        }
        return rowCache.get(metadataType);
    }

    private static List<SObject> baseRecords(String metadataType) {
        if (baseForTest == null && Test.isRunningTest() && !useOrgMetadataForTest) {
            baseForTest = testFixtures();
        }
        if (baseForTest != null) {
            return baseForTest.containsKey(metadataType) ? baseForTest.get(metadataType) : new List<SObject>();
        }
        if (!baseCache.containsKey(metadataType)) {
            List<SObject> records;
            if (metadataType == FORM_TYPE) {
                records = [
                    SELECT DeveloperName, MasterLabel, Target_Object_API_Name__c, Target_Base_Filter_Field__c,
                           Target_Base_Filter_Value__c, Identity_Field_1_API_Name__c, Identity_Field_1_Comparison__c,
                           Identity_Field_2_API_Name__c, Identity_Field_2_Comparison__c,
                           Owner_Queue_DeveloperName__c, Subject_Template__c, Record_Name_Field_API_Name__c,
                           Allow_Duplicate_Open_Requests__c, Is_Active__c, Is_Core_Form__c, Network_Name__c,
                           Lock_Field_API_Name__c, Lock_Date_Field_API_Name__c,
                           Portal_Lookup_Title_FR__c, Portal_Lookup_Title_EN__c,
                           Portal_Lookup_Subtitle_FR__c, Portal_Lookup_Subtitle_EN__c,
                           Portal_Id_Help_FR__c, Portal_Id_Help_EN__c,
                           Portal_Form_Title_FR__c, Portal_Form_Title_EN__c,
                           Portal_Form_Subtitle_FR__c, Portal_Form_Subtitle_EN__c, Portal_Text_Styles__c,
                           Portal_Blocks__c, Portal_Appearance__c, Portal_Messages__c
                    FROM Data_Update_Form__mdt
                ];
            } else if (metadataType == FIELD_TYPE) {
                records = [
                    SELECT DeveloperName, MasterLabel, Form__r.DeveloperName, Field_API_Name__c,
                           Label_FR__c, Label_EN__c, Display_Order__c, Section_Label_FR__c, Section_Label_EN__c,
                           Input_Type__c, Is_Required__c, Is_Active__c, History_Mode__c,
                           History_Target_Object_API_Name__c, History_Target_Value_Field_API_Name__c,
                           History_Target_Date_Field_API_Name__c, History_Target_Account_Field_API_Name__c,
                           History_Target_Log_Field_API_Name__c, History_Date_Source_Field_API_Name__c,
                           Same_Row_As_Previous__c, Help_FR__c, Help_EN__c, Is_Hidden__c, Is_Read_Only__c,
                           History_Table_Columns__c, History_Table_Input_Mode__c
                    FROM Data_Update_Form_Field__mdt
                ];
            } else if (metadataType == TEMPLATE_TYPE) {
                records = [
                    SELECT DeveloperName, MasterLabel, Appearance__c, Is_Active__c
                    FROM Data_Update_Appearance_Template__mdt
                ];
            } else {
                throw new StoreException('Unknown configuration type: ' + metadataType);
            }
            baseCache.put(metadataType, records);
        }
        return baseCache.get(metadataType);
    }

    // { metadata type => [records] } as the JSON shape of the __mdt sObjects.
    private static Map<String, List<SObject>> testFixtures() {
        String body = [SELECT Body FROM StaticResource WHERE Name = :TEST_FIXTURES_RESOURCE LIMIT 1].Body.toString();
        Map<String, Object> byType = (Map<String, Object>) JSON.deserializeUntyped(body);
        return new Map<String, List<SObject>>{
            FORM_TYPE => (List<SObject>) JSON.deserialize(JSON.serialize(byType.get(FORM_TYPE)), List<Data_Update_Form__mdt>.class),
            FIELD_TYPE => (List<SObject>) JSON.deserialize(JSON.serialize(byType.get(FIELD_TYPE)), List<Data_Update_Form_Field__mdt>.class),
            TEMPLATE_TYPE => (List<SObject>) JSON.deserialize(JSON.serialize(byType.get(TEMPLATE_TYPE)), List<Data_Update_Appearance_Template__mdt>.class)
        };
    }

    // ─── Sorting ─────────────────────────────────────────────────────────

    private static Integer compareLabels(String a, String b) {
        return (a == null ? '' : a).compareTo(b == null ? '' : b);
    }

    private class FormLabelComparator implements Comparator<Data_Update_Form__mdt> {
        public Integer compare(Data_Update_Form__mdt a, Data_Update_Form__mdt b) {
            return compareLabels(a.MasterLabel, b.MasterLabel);
        }
    }

    private class TemplateLabelComparator implements Comparator<Data_Update_Appearance_Template__mdt> {
        public Integer compare(Data_Update_Appearance_Template__mdt a, Data_Update_Appearance_Template__mdt b) {
            return compareLabels(a.MasterLabel, b.MasterLabel);
        }
    }

    private class DisplayOrderComparator implements Comparator<Data_Update_Form_Field__mdt> {
        public Integer compare(Data_Update_Form_Field__mdt a, Data_Update_Form_Field__mdt b) {
            if (a.Display_Order__c == b.Display_Order__c) return a.DeveloperName.compareTo(b.DeveloperName);
            if (a.Display_Order__c == null) return 1;
            if (b.Display_Order__c == null) return -1;
            return a.Display_Order__c < b.Display_Order__c ? -1 : 1;
        }
    }
}
