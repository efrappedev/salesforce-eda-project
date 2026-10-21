/**
 * DataUpdateFormConfigService.cls
 * Single point of contact with the form configuration (Data_Update_Form__mdt /
 * Data_Update_Form_Field__mdt, as published — read through DucFormConfigStore).
 * CMDT is never trusted on its own: every object/field name it declares is
 * re-validated live against Schema.describe() on every call to getForm(), and
 * the whole transaction aborts (fail closed) if anything doesn't resolve —
 * a typo in a CMDT record must never cause a silent partial write.
 *
 * Adapted from DataUpdateFormConfigService.cls (Case-based framework): reads the
 * renamed Owner_Queue_DeveloperName__c / Subject_Template__c CMDT
 * fields instead of the old Case_* ones, drops RecordType resolution entirely
 * (Data_Update_Request__c has no per-form RecordType — Update_Form_DeveloperName__c
 * already identifies the form). The UI is French/English only; the legacy Label_ES__c /
 * Section_Label_ES__c CMDT columns are no longer read.
 */
public inherited sharing class DataUpdateFormConfigService {

    // Schema.getGlobalDescribe() costs ~27 ms of CPU per call in AEBEQ (2,300+ objects), and
    // apply/review call it per field — describe once per transaction and reuse the same map.
    private static Map<String, Schema.SObjectType> globalTypesCache;
    public static Map<String, Schema.SObjectType> globalTypes() {
        if (globalTypesCache == null) globalTypesCache = Schema.getGlobalDescribe();
        return globalTypesCache;
    }

    public class FormNotFoundException extends Exception {}
    public class FormValidationException extends Exception {}

    public class FormConfig {
        public String  developerName;
        public String  label;
        public String  targetObjectApiName;
        public String  targetBaseFilterField;
        public String  targetBaseFilterValue;
        public Boolean targetBaseFilterIsBoolean;
        public String  identityField1ApiName;
        public String  identityField1Comparison;
        public String  identityField2ApiName;
        public String  identityField2Comparison;
        public Id      requestOwnerQueueId;
        public String  requestSubjectTemplate;
        public String  recordNameFieldApiName;
        public Boolean allowDuplicateOpenRequests;
        public String  lockFieldApiName;
        public String  lockDateFieldApiName;
        public List<FormFieldConfig> fields;
        /** History_Table records (paste-from-Excel history tables) — kept apart from `fields`. */
        public List<FormFieldConfig> tables;
        /** Per-form overrides of the portal's standard texts (blank values = standard copy). */
        public DataUpdateWrapper.PortalTexts portalTexts;
        /** True when synthesized from a ticket because its source form no longer exists. */
        public Boolean isFallback;
    }

    public class FormFieldConfig {
        public String  fieldApiName;
        public String  labelFr;
        public String  labelEn;
        public Integer displayOrder;
        public String  sectionLabelFr;
        public String  sectionLabelEn;
        public String  inputType;
        public Boolean isRequired;
        public String  helpFr;
        public String  helpEn;
        public String  historyMode;
        public String  historyTargetObjectApiName;
        public String  historyTargetValueFieldApiName;
        public String  historyTargetDateFieldApiName;
        public String  historyTargetAccountFieldApiName;
        public String  historyTargetLogFieldApiName;
        public String  historyDateSourceFieldApiName;
        public Boolean sameRowAsPrevious;
        public Boolean isReadOnly;
        public Boolean isHidden;
        /** History_Table only: checked columns, in display order. */
        public List<TableColumn> tableColumns;
        /** History_Table only: Fields | Excel | Both — blank = Excel (published before the option). */
        public String tableInputMode;
    }

    /** One checked column of a History_Table (History_Table_Columns__c JSON shape). */
    public class TableColumn {
        public String f;
        public String fr;
        public String en;
    }

    public static FormConfig getForm(String formDeveloperName) {
        return loadForm(formDeveloperName, false);
    }

    /**
     * Review-side lookup: also resolves deactivated forms and deactivated catalog fields, so a
     * ticket keeps showing everything it arrived with, with its real labels and history mapping.
     * Never cached and never used by the public portal.
     */
    public static FormConfig getFormForReview(String formDeveloperName) {
        return loadForm(formDeveloperName, true);
    }

    // Test seams: CMDT records can't be inserted from a test, so tests hand in in-memory
    // records here (built via JSON.deserialize) to reach config shapes the org doesn't ship.
    @TestVisible private static Data_Update_Form__mdt testFormMdt;
    @TestVisible private static List<Data_Update_Form_Field__mdt> testFieldMdts;

    private static FormConfig loadForm(String formDeveloperName, Boolean includeInactive) {
        if (String.isBlank(formDeveloperName)) {
            throw new FormNotFoundException('Form not found: ' + formDeveloperName);
        }

        // Review mode never touches the cache: the cached config is the public (active-only) view.
        String cacheKey = 'form_' + formDeveloperName;
        if (!includeInactive) {
            FormConfig cached = getCachedForm(cacheKey);
            if (cached != null) return cached;
        }

        List<Data_Update_Form__mdt> forms = testFormMdt != null ? new List<Data_Update_Form__mdt>{ testFormMdt } : storeForm(formDeveloperName);
        if (forms.isEmpty() || (!includeInactive && forms[0].Is_Active__c != true)) {
            throw new FormNotFoundException('Form not found: ' + formDeveloperName);
        }
        Data_Update_Form__mdt formMdt = forms[0];

        List<Data_Update_Form_Field__mdt> fieldMdts = testFieldMdts != null ? testFieldMdts : DucFormConfigStore.fields(formDeveloperName);
        List<Data_Update_Form_Field__mdt> activeFieldMdts = new List<Data_Update_Form_Field__mdt>();
        List<Data_Update_Form_Field__mdt> inactiveFieldMdts = new List<Data_Update_Form_Field__mdt>();
        List<Data_Update_Form_Field__mdt> tableMdts = new List<Data_Update_Form_Field__mdt>();
        // Hidden questions stay in the builder layout but are off the public form: treated
        // like inactive ones here (review mode still shows them on tickets that have a value).
        for (Data_Update_Form_Field__mdt fm : fieldMdts) {
            if (fm.History_Mode__c == HISTORY_TABLE) {
                tableMdts.add(fm);
                continue;
            }
            if (fm.Is_Active__c == true && fm.Is_Hidden__c != true) {
                activeFieldMdts.add(fm);
            } else {
                inactiveFieldMdts.add(fm);
            }
        }
        Boolean hasPublicTable = false;
        for (Data_Update_Form_Field__mdt fm : tableMdts) {
            if (fm.Is_Active__c == true && fm.Is_Hidden__c != true) hasPublicTable = true;
        }
        if (activeFieldMdts.isEmpty() && !hasPublicTable && !includeInactive) {
            throw new FormValidationException('Form has no active fields: ' + formDeveloperName);
        }

        FormConfig config = new FormConfig();
        config.developerName              = formMdt.DeveloperName;
        config.label                      = formMdt.MasterLabel;
        config.targetObjectApiName        = formMdt.Target_Object_API_Name__c;
        config.targetBaseFilterField      = formMdt.Target_Base_Filter_Field__c;
        config.targetBaseFilterValue      = formMdt.Target_Base_Filter_Value__c;
        config.identityField1ApiName      = formMdt.Identity_Field_1_API_Name__c;
        config.identityField1Comparison   = formMdt.Identity_Field_1_Comparison__c;
        config.identityField2ApiName      = formMdt.Identity_Field_2_API_Name__c;
        config.identityField2Comparison   = formMdt.Identity_Field_2_Comparison__c;
        config.requestSubjectTemplate      = formMdt.Subject_Template__c;
        config.recordNameFieldApiName     = String.isBlank(formMdt.Record_Name_Field_API_Name__c) ? 'Name' : formMdt.Record_Name_Field_API_Name__c;
        config.allowDuplicateOpenRequests = formMdt.Allow_Duplicate_Open_Requests__c == true;
        // "Multiple submissions" forms never lock the record: the lock fields are ignored (kept
        // untouched on the CMDT so turning the switch off brings locking back as it was).
        config.lockFieldApiName           = config.allowDuplicateOpenRequests ? null : formMdt.Lock_Field_API_Name__c;
        config.lockDateFieldApiName       = config.allowDuplicateOpenRequests ? null : formMdt.Lock_Date_Field_API_Name__c;
        config.portalTexts                = toPortalTexts(formMdt);

        config.fields = new List<FormFieldConfig>();
        for (Data_Update_Form_Field__mdt fm : activeFieldMdts) {
            config.fields.add(toFieldConfig(fm));
        }

        validateAgainstSchema(config);

        // History tables: the public form gets the active, shown ones (fail closed like any
        // question); review mode also keeps hidden/deactivated ones — a ticket keeps showing
        // what it arrived with — and drops any whose mapping no longer holds.
        config.tables = new List<FormFieldConfig>();
        for (Data_Update_Form_Field__mdt fm : tableMdts) {
            Boolean isPublic = fm.Is_Active__c == true && fm.Is_Hidden__c != true;
            if (!isPublic && !includeInactive) continue;
            FormFieldConfig tc = toFieldConfig(fm);
            if (isPublic && !includeInactive) {
                validateHistoryTable(tc, config.targetObjectApiName);
                config.tables.add(tc);
                continue;
            }
            try {
                validateHistoryTable(tc, config.targetObjectApiName);
                config.tables.add(tc);
            } catch (FormValidationException e) {
                continue;
            }
        }

        // Review mode: a ticket keeps showing fields that were deactivated after it arrived.
        // Each one is validated on its own and dropped if its config no longer holds, so a
        // stale catalog row can never break the whole ticket.
        if (includeInactive && !inactiveFieldMdts.isEmpty()) {
            Map<String, Schema.SObjectField> fieldMap =
                globalTypes().get(config.targetObjectApiName).getDescribe().fields.getMap();
            for (Data_Update_Form_Field__mdt fm : inactiveFieldMdts) {
                FormFieldConfig fc = toFieldConfig(fm);
                try {
                    validateField(fc, fieldMap, config.targetObjectApiName);
                    config.fields.add(fc);
                } catch (FormValidationException e) {
                    continue;
                }
            }
        }

        config.requestOwnerQueueId = resolveQueueId(formMdt.Owner_Queue_DeveloperName__c);

        // Only the strict (active-only) config is cached — the portal reads this same key.
        if (!includeInactive) {
            putCachedForm(cacheKey, config);
        }

        return config;
    }

    private static FormFieldConfig toFieldConfig(Data_Update_Form_Field__mdt fm) {
        FormFieldConfig fc = new FormFieldConfig();
        fc.fieldApiName    = fm.Field_API_Name__c;
        fc.labelFr         = fm.Label_FR__c;
        fc.labelEn         = fm.Label_EN__c;
        fc.displayOrder    = fm.Display_Order__c != null ? Integer.valueOf(fm.Display_Order__c) : 0;
        fc.sectionLabelFr  = fm.Section_Label_FR__c;
        fc.sectionLabelEn  = fm.Section_Label_EN__c;
        fc.inputType       = fm.Input_Type__c;
        fc.isRequired      = fm.Is_Required__c == true;
        fc.helpFr          = fm.Help_FR__c;
        fc.helpEn          = fm.Help_EN__c;
        fc.historyMode     = String.isBlank(fm.History_Mode__c) ? 'Replace' : fm.History_Mode__c;
        fc.historyTargetObjectApiName      = fm.History_Target_Object_API_Name__c;
        fc.historyTargetValueFieldApiName  = fm.History_Target_Value_Field_API_Name__c;
        fc.historyTargetDateFieldApiName   = fm.History_Target_Date_Field_API_Name__c;
        fc.historyTargetAccountFieldApiName = fm.History_Target_Account_Field_API_Name__c;
        fc.historyTargetLogFieldApiName    = fm.History_Target_Log_Field_API_Name__c;
        fc.historyDateSourceFieldApiName   = fm.History_Date_Source_Field_API_Name__c;
        fc.sameRowAsPrevious              = fm.Same_Row_As_Previous__c == true;
        fc.isReadOnly                     = fm.Is_Read_Only__c == true;
        fc.isHidden                       = fm.Is_Hidden__c == true;
        if (fc.historyMode == HISTORY_TABLE) {
            fc.tableColumns = parseTableColumns(fm.History_Table_Columns__c);
            fc.tableInputMode = String.isBlank(fm.History_Table_Input_Mode__c) ? 'Excel' : fm.History_Table_Input_Mode__c;
        }
        return fc;
    }

    public static DataUpdateWrapper.PortalTexts toPortalTexts(Data_Update_Form__mdt formMdt) {
        DataUpdateWrapper.PortalTexts t = new DataUpdateWrapper.PortalTexts();
        t.lookupTitleFr    = formMdt.Portal_Lookup_Title_FR__c;
        t.lookupTitleEn    = formMdt.Portal_Lookup_Title_EN__c;
        t.lookupSubtitleFr = formMdt.Portal_Lookup_Subtitle_FR__c;
        t.lookupSubtitleEn = formMdt.Portal_Lookup_Subtitle_EN__c;
        t.idHelpFr         = formMdt.Portal_Id_Help_FR__c;
        t.idHelpEn         = formMdt.Portal_Id_Help_EN__c;
        t.formTitleFr      = formMdt.Portal_Form_Title_FR__c;
        t.formTitleEn      = formMdt.Portal_Form_Title_EN__c;
        t.formSubtitleFr   = formMdt.Portal_Form_Subtitle_FR__c;
        t.formSubtitleEn   = formMdt.Portal_Form_Subtitle_EN__c;
        t.stylesJson       = formMdt.Portal_Text_Styles__c;
        t.blocksJson       = formMdt.Portal_Blocks__c;
        t.appearanceJson   = formMdt.Portal_Appearance__c;
        t.messagesJson     = formMdt.Portal_Messages__c;
        return t;
    }

    /**
     * Lightweight form lookup for callers that only need object/filter/lock config — not the
     * field catalog. Unlike getForm(), doesn't require the form to have any active
     * Data_Update_Form_Field__mdt records, so it works for a form still mid-setup (e.g. a new
     * form whose fields haven't been added to the catalog yet) — used by the response checklist.
     */
    public static FormConfig getFormBasic(String formDeveloperName) {
        if (String.isBlank(formDeveloperName)) {
            throw new FormNotFoundException('Form not found: ' + formDeveloperName);
        }

        List<Data_Update_Form__mdt> forms = testFormMdt != null ? new List<Data_Update_Form__mdt>{ testFormMdt } : storeForm(formDeveloperName);
        if (forms.isEmpty() || forms[0].Is_Active__c != true) {
            throw new FormNotFoundException('Form not found: ' + formDeveloperName);
        }
        Data_Update_Form__mdt formMdt = forms[0];

        FormConfig config = new FormConfig();
        config.developerName          = formMdt.DeveloperName;
        config.targetObjectApiName    = formMdt.Target_Object_API_Name__c;
        config.targetBaseFilterField  = formMdt.Target_Base_Filter_Field__c;
        config.targetBaseFilterValue  = formMdt.Target_Base_Filter_Value__c;
        config.recordNameFieldApiName = String.isBlank(formMdt.Record_Name_Field_API_Name__c) ? 'Name' : formMdt.Record_Name_Field_API_Name__c;
        config.allowDuplicateOpenRequests = formMdt.Allow_Duplicate_Open_Requests__c == true;
        config.lockFieldApiName       = config.allowDuplicateOpenRequests ? null : formMdt.Lock_Field_API_Name__c;
        config.lockDateFieldApiName   = config.allowDuplicateOpenRequests ? null : formMdt.Lock_Date_Field_API_Name__c;
        config.fields                 = new List<FormFieldConfig>();
        config.tables                 = new List<FormFieldConfig>();
        return config;
    }

    // The form as published (Custom Metadata + Form Builder publishes, see DucFormConfigStore).
    private static List<Data_Update_Form__mdt> storeForm(String formDeveloperName) {
        Data_Update_Form__mdt form = DucFormConfigStore.form(formDeveloperName);
        return form == null ? new List<Data_Update_Form__mdt>() : new List<Data_Update_Form__mdt>{ form };
    }

    // ─── Cache (Platform Cache — Org partition, fail-open) ─────────────────
    //
    // Absorbs bursts of near-simultaneous public page loads (e.g. a mass email to ~2000
    // people all clicking within minutes of each other) without re-running Schema.describe()
    // and re-querying both __mdt objects on every single load. If this org has no Platform
    // Cache capacity allocated (see DataUpdateFormCache.cachePartition-meta.xml — deployed
    // with allocatedCapacity 0 so the deploy itself never depends on this org owning paid
    // cache), every Cache.Org call below throws and is swallowed: behavior falls back exactly
    // to the pre-cache code path, it just isn't sped up. Invalidated explicitly by
    // DataUpdateFormAdminController.checkDeployStatus() right after a Settings-screen catalog
    // change (add/toggle/reorder) succeeds, instead of waiting out the TTL.
    private static final String CACHE_PARTITION = 'local.DataUpdateFormCache';
    private static final Integer CACHE_TTL_SECS = 300;

    private static FormConfig getCachedForm(String cacheKey) {
        FormConfig cached = null;
        try {
            cached = (FormConfig) JSON.deserialize((String) Cache.Org.getPartition(CACHE_PARTITION).get(cacheKey), FormConfig.class);
        } catch (Exception e) {
            // Cache miss (null → deserialize throws), partition not provisioned, no capacity
            // allocated, or org cache unavailable — fail open, caller re-queries normally.
        }
        return cached;
    }

    private static void putCachedForm(String cacheKey, FormConfig config) {
        try {
            Cache.Org.getPartition(CACHE_PARTITION).put(cacheKey, JSON.serialize(config), CACHE_TTL_SECS, Cache.Visibility.NAMESPACE, false);
        } catch (Exception e) {
            // See getCachedForm — caching is a pure optimization, never required for correctness.
        }
    }

    public static void clearCache(String formDeveloperName) {
        if (String.isBlank(formDeveloperName)) return;
        try {
            Cache.Org.getPartition(CACHE_PARTITION).remove('form_' + formDeveloperName);
        } catch (Exception e) {
            // See getCachedForm.
        }
    }

    // ─── Schema validation (fail closed) ───────────────────────────────────

    @TestVisible private static void validateAgainstSchema(FormConfig config) {
        Schema.SObjectType targetType = globalTypes().get(config.targetObjectApiName);
        if (targetType == null) {
            throw new FormValidationException('Unknown object: ' + config.targetObjectApiName);
        }
        Map<String, Schema.SObjectField> fieldMap = targetType.getDescribe().fields.getMap();

        assertFieldExists(fieldMap, config.identityField1ApiName, config.targetObjectApiName);
        if (String.isNotBlank(config.identityField2ApiName)) {
            assertFieldExists(fieldMap, config.identityField2ApiName, config.targetObjectApiName);
        }
        assertFieldExists(fieldMap, config.recordNameFieldApiName, config.targetObjectApiName);

        if (String.isNotBlank(config.targetBaseFilterField)) {
            Schema.DisplayType filterFieldType = assertFilterFieldExists(fieldMap, config.targetBaseFilterField, config.targetObjectApiName);
            config.targetBaseFilterIsBoolean = filterFieldType == Schema.DisplayType.BOOLEAN;
        } else {
            config.targetBaseFilterIsBoolean = false;
        }

        for (FormFieldConfig fc : config.fields) {
            validateField(fc, fieldMap, config.targetObjectApiName);
        }

        if (String.isNotBlank(config.lockFieldApiName)) {
            assertFieldExists(fieldMap, config.lockFieldApiName, config.targetObjectApiName);
        }
        if (String.isNotBlank(config.lockDateFieldApiName)) {
            assertFieldExists(fieldMap, config.lockDateFieldApiName, config.targetObjectApiName);
        }
    }

    @TestVisible private static void validateField(FormFieldConfig fc, Map<String, Schema.SObjectField> fieldMap, String objectApiName) {
        if (isHistoryOnly(fc)) {
            validateHistoryOnly(fc, objectApiName);
            return;
        }
        assertFieldExists(fieldMap, fc.fieldApiName, objectApiName);
        if (fc.historyMode == 'Historize') {
            validateHistoryMapping(fc, objectApiName);
            if (String.isNotBlank(fc.historyDateSourceFieldApiName)) {
                Schema.SObjectField dateSourceField = assertFieldExists(fieldMap, fc.historyDateSourceFieldApiName, objectApiName);
                Schema.DisplayType dateSourceType = dateSourceField.getDescribe().getType();
                if (dateSourceType != Schema.DisplayType.DATE && dateSourceType != Schema.DisplayType.DATETIME) {
                    throw new FormValidationException('History date source field ' + fc.historyDateSourceFieldApiName + ' on ' + objectApiName + ' must be a Date or DateTime field.');
                }
            }
        }
    }

    private static Schema.SObjectField assertFieldExists(Map<String, Schema.SObjectField> fieldMap, String fieldApiName, String objectApiName) {
        Schema.SObjectField field = String.isBlank(fieldApiName) ? null : fieldMap.get(fieldApiName.toLowerCase());
        if (field == null) {
            throw new FormValidationException('Unknown field ' + fieldApiName + ' on ' + objectApiName);
        }
        return field;
    }

    // No fallback object: History_Mode__c = 'Historize' requires a fully valid mapping to a
    // real, admin-created object — enforced here (fail closed) rather than as a declarative
    // CMDT-required flag, same style as every other schema check in this class.
    @TestVisible private static void validateHistoryMapping(FormFieldConfig fc, String sourceObjectApiName) {
        if (String.isBlank(fc.historyTargetObjectApiName) || String.isBlank(fc.historyTargetValueFieldApiName)) {
            throw new FormValidationException('Field ' + fc.fieldApiName + ' is set to ' + fc.historyMode + ' but has no history target object/value field configured.');
        }
        Schema.SObjectType histType = globalTypes().get(fc.historyTargetObjectApiName);
        if (histType == null) {
            throw new FormValidationException('Unknown history target object: ' + fc.historyTargetObjectApiName);
        }
        Map<String, Schema.SObjectField> histFieldMap = histType.getDescribe().fields.getMap();

        // Type-shape check only — no isCreateable()/isAccessible() here. getForm() runs in every
        // caller's context, including the public portal's Guest User, who never needs (and isn't
        // granted) CRUD on the history object; only the internal staff applying a ticket actually
        // inserts into it, and that DML-time FLS is enforced separately (Data_Update_Center_Access).
        Schema.SObjectField valueField = assertFieldExists(histFieldMap, fc.historyTargetValueFieldApiName, fc.historyTargetObjectApiName);
        Schema.DisplayType valueType = valueField.getDescribe().getType();
        if (valueType == Schema.DisplayType.REFERENCE
            || valueType == Schema.DisplayType.MULTIPICKLIST
            || valueType == Schema.DisplayType.ADDRESS) {
            throw new FormValidationException('History value field ' + fc.historyTargetValueFieldApiName + ' on ' + fc.historyTargetObjectApiName + ' is not a valid target field.');
        }

        if (String.isNotBlank(fc.historyTargetDateFieldApiName)) {
            Schema.SObjectField dateField = assertFieldExists(histFieldMap, fc.historyTargetDateFieldApiName, fc.historyTargetObjectApiName);
            Schema.DisplayType dateType = dateField.getDescribe().getType();
            if (dateType != Schema.DisplayType.DATE && dateType != Schema.DisplayType.DATETIME) {
                throw new FormValidationException('History date field ' + fc.historyTargetDateFieldApiName + ' on ' + fc.historyTargetObjectApiName + ' must be a Date or DateTime field.');
            }
        }

        if (String.isNotBlank(fc.historyTargetAccountFieldApiName)) {
            assertReferenceFieldTo(histFieldMap, fc.historyTargetAccountFieldApiName, fc.historyTargetObjectApiName, sourceObjectApiName);
        }

        if (String.isNotBlank(fc.historyTargetLogFieldApiName)) {
            assertReferenceFieldTo(histFieldMap, fc.historyTargetLogFieldApiName, fc.historyTargetObjectApiName, 'Data_Update_Log__c');
        }
    }

    // History_Only: nothing is written on the target record — the field's key is the virtual
    // "HistoryObject.ValueField" and the value only ever becomes a new history row, so the
    // lookup back to the target record is mandatory (otherwise the row would be orphaned).
    @TestVisible private static void validateHistoryOnly(FormFieldConfig fc, String sourceObjectApiName) {
        validateHistoryMapping(fc, sourceObjectApiName);
        if (String.isBlank(fc.historyTargetAccountFieldApiName)) {
            throw new FormValidationException('Field ' + fc.fieldApiName + ' is set to History_Only but has no lookup to ' + sourceObjectApiName + ' configured.');
        }
        String expectedKey = buildHistoryOnlyKey(fc.historyTargetObjectApiName, fc.historyTargetValueFieldApiName);
        if (!expectedKey.equalsIgnoreCase(fc.fieldApiName)) {
            throw new FormValidationException('Field ' + fc.fieldApiName + ' is set to History_Only but its key does not match ' + expectedKey + '.');
        }
    }

    // ─── History_Only helpers ───────────────────────────────────────────────

    public static final String HISTORY_ONLY = 'History_Only';
    public static final String HISTORY_DATE_SUFFIX = '@date';

    public static Boolean isHistoryOnly(FormFieldConfig fc) {
        return fc != null && fc.historyMode == HISTORY_ONLY;
    }

    public static String buildHistoryOnlyKey(String historyObjectApiName, String valueFieldApiName) {
        return historyObjectApiName + '.' + valueFieldApiName;
    }

    /** Proposed-values key carrying a History_Only field's optional date, or null if no date field is mapped. */
    public static String historyDateKey(FormFieldConfig fc) {
        return isHistoryOnly(fc) && String.isNotBlank(fc.historyTargetDateFieldApiName)
            ? fc.fieldApiName + HISTORY_DATE_SUFFIX
            : null;
    }

    /**
     * Describe of the field a form field's value actually lands in: the history object's value
     * field for History_Only, otherwise the target object's own field. Null when it doesn't resolve.
     */
    public static Schema.DescribeFieldResult describeValueField(FormFieldConfig fc, String targetObjectApiName) {
        String objectApiName = isHistoryOnly(fc) ? fc.historyTargetObjectApiName : targetObjectApiName;
        String fieldApiName  = isHistoryOnly(fc) ? fc.historyTargetValueFieldApiName : fc.fieldApiName;
        if (String.isBlank(objectApiName) || String.isBlank(fieldApiName)) return null;
        Schema.SObjectType objType = globalTypes().get(objectApiName);
        if (objType == null) return null;
        Schema.SObjectField field = objType.getDescribe().fields.getMap().get(fieldApiName.toLowerCase());
        return field == null ? null : field.getDescribe();
    }

    /**
     * Checks a proposed value against the real field it will be written to, so a bad value is
     * refused when it is typed (portal submit, staff correction) instead of failing at Apply and
     * leaving the ticket in Error. Returns an error code, or null when the value is fine (blank
     * values and unknown fields are left to the caller).
     */
    public static String validateFieldValue(Schema.DescribeFieldResult d, String value) {
        if (d == null || String.isBlank(value)) return null;
        switch on d.getType() {
            when DATE {
                if (!Pattern.matches('\\d{4}-\\d{2}-\\d{2}', value)) return 'INVALID_DATE';
                try { Date.valueOf(value); } catch (Exception e) { return 'INVALID_DATE'; }
            }
            when DATETIME {
                try { Datetime.valueOf(value); } catch (Exception e) { return 'INVALID_DATE'; }
            }
            when DOUBLE, CURRENCY, PERCENT {
                try { Decimal.valueOf(value); } catch (Exception e) { return 'INVALID_NUMBER'; }
            }
            when INTEGER {
                try { Integer.valueOf(value); } catch (Exception e) { return 'INVALID_NUMBER'; }
            }
            when BOOLEAN {
                if (!value.equalsIgnoreCase('true') && !value.equalsIgnoreCase('false')) return 'INVALID_BOOLEAN';
            }
            when EMAIL {
                if (!Pattern.matches('[^\\s@]+@[^\\s@]+\\.[^\\s@]+', value)) return 'INVALID_EMAIL';
            }
            when PICKLIST {
                if (d.isRestrictedPicklist()) {
                    Boolean found = false;
                    for (Schema.PicklistEntry pe : d.getPicklistValues()) {
                        if (pe.isActive() && value.equals(pe.getValue())) { found = true; break; }
                    }
                    if (!found) return 'INVALID_PICKLIST';
                }
            }
        }
        Integer maxLength = d.getLength();
        if (maxLength != null && maxLength > 0 && value.length() > maxLength) return 'VALUE_TOO_LONG';
        return null;
    }

    // ─── History_Table helpers ──────────────────────────────────────────────
    //
    // A History_Table is a paste-from-Excel grid on the public form (églises): each pasted line
    // becomes one row of the mapped history object, linked to the target record. Its key is the
    // virtual "HistoryObject#table"; the date column (1 line = 1 date) is mandatory and is what
    // the review panel uses to flag lines whose date already has a row (duplicates).

    public static final String HISTORY_TABLE = 'History_Table';
    public static final String HISTORY_TABLE_SUFFIX = '#table';
    public static final Integer HISTORY_TABLE_MAX_ROWS = 1000;

    public static Boolean isHistoryTable(FormFieldConfig fc) {
        return fc != null && fc.historyMode == HISTORY_TABLE;
    }

    public static Boolean isHistoryTableKey(String key) {
        return key != null && key.endsWith(HISTORY_TABLE_SUFFIX);
    }

    public static String buildHistoryTableKey(String historyObjectApiName) {
        return historyObjectApiName + HISTORY_TABLE_SUFFIX;
    }

    public static List<TableColumn> parseTableColumns(String columnsJson) {
        if (String.isBlank(columnsJson)) return new List<TableColumn>();
        try {
            List<TableColumn> cols = (List<TableColumn>) JSON.deserialize(columnsJson, List<TableColumn>.class);
            return cols == null ? new List<TableColumn>() : cols;
        } catch (Exception e) {
            return new List<TableColumn>();
        }
    }

    /** Required in Salesforce = must be filled on insert and has no default (checkboxes never are). */
    public static Boolean isRequiredOnCreate(Schema.DescribeFieldResult d) {
        return !d.isNillable() && d.isCreateable() && !d.isDefaultedOnCreate()
            && d.getType() != Schema.DisplayType.BOOLEAN;
    }

    /** Column types a history table can hold — lookups, multi-selects and compound fields never. */
    public static Boolean isTableColumnType(Schema.DisplayType t) {
        return t == Schema.DisplayType.STRING || t == Schema.DisplayType.TEXTAREA
            || t == Schema.DisplayType.DOUBLE || t == Schema.DisplayType.INTEGER
            || t == Schema.DisplayType.LONG || t == Schema.DisplayType.CURRENCY
            || t == Schema.DisplayType.PERCENT || t == Schema.DisplayType.DATE
            || t == Schema.DisplayType.DATETIME || t == Schema.DisplayType.BOOLEAN
            || t == Schema.DisplayType.PICKLIST || t == Schema.DisplayType.EMAIL
            || t == Schema.DisplayType.PHONE || t == Schema.DisplayType.URL;
    }

    /** Portal/review input kind of a column: Date, Number, Checkbox, Picklist or Text. */
    public static String tableColumnKind(Schema.DisplayType t) {
        if (t == Schema.DisplayType.DATE || t == Schema.DisplayType.DATETIME) return 'Date';
        if (t == Schema.DisplayType.DOUBLE || t == Schema.DisplayType.INTEGER || t == Schema.DisplayType.LONG
            || t == Schema.DisplayType.CURRENCY || t == Schema.DisplayType.PERCENT) return 'Number';
        if (t == Schema.DisplayType.BOOLEAN) return 'Checkbox';
        if (t == Schema.DisplayType.PICKLIST) return 'Picklist';
        return 'Text';
    }

    /**
     * Live description of a table's checked columns (type, required, picklist values). Columns
     * that no longer resolve are dropped — validateHistoryTable() already failed the form if a
     * required one is gone.
     */
    public static List<DataUpdateWrapper.TableColumnDefinition> describeTableColumns(FormFieldConfig fc) {
        List<DataUpdateWrapper.TableColumnDefinition> result = new List<DataUpdateWrapper.TableColumnDefinition>();
        Schema.SObjectType histType = globalTypes().get(fc.historyTargetObjectApiName);
        if (histType == null || fc.tableColumns == null) return result;
        Map<String, Schema.SObjectField> histFieldMap = histType.getDescribe().fields.getMap();
        for (TableColumn col : fc.tableColumns) {
            Schema.SObjectField field = String.isBlank(col.f) ? null : histFieldMap.get(col.f.toLowerCase());
            if (field == null) continue;
            Schema.DescribeFieldResult d = field.getDescribe();
            DataUpdateWrapper.TableColumnDefinition def = new DataUpdateWrapper.TableColumnDefinition();
            def.apiName    = d.getName();
            def.labelFr    = String.isNotBlank(col.fr) ? col.fr : d.getLabel();
            def.labelEn    = String.isNotBlank(col.en) ? col.en : d.getLabel();
            def.kind       = tableColumnKind(d.getType());
            def.isDate     = d.getName().equalsIgnoreCase(fc.historyTargetDateFieldApiName);
            def.isRequired = def.isDate || isRequiredOnCreate(d);
            def.maxLength  = def.kind == 'Text' ? d.getLength() : null;
            if (def.kind == 'Picklist') {
                for (Schema.PicklistEntry entry : d.getPicklistValues()) {
                    if (!entry.isActive()) continue;
                    DataUpdateWrapper.PicklistOption opt = new DataUpdateWrapper.PicklistOption();
                    opt.label = entry.getLabel();
                    opt.value = entry.getValue();
                    def.picklistOptions.add(opt);
                }
            }
            result.add(def);
        }
        return result;
    }

    // History_Table: lookup back to the target record mandatory (rows would be orphaned
    // otherwise), a Date/DateTime date column that is one of the checked columns, every
    // checked column a real, plain field, and every field Salesforce requires checked.
    public static void validateHistoryTable(FormFieldConfig fc, String sourceObjectApiName) {
        if (String.isBlank(fc.historyTargetObjectApiName)) {
            throw new FormValidationException('History table ' + fc.fieldApiName + ' has no history object configured.');
        }
        Schema.SObjectType histType = globalTypes().get(fc.historyTargetObjectApiName);
        if (histType == null) {
            throw new FormValidationException('Unknown history target object: ' + fc.historyTargetObjectApiName);
        }
        if (!buildHistoryTableKey(fc.historyTargetObjectApiName).equalsIgnoreCase(fc.fieldApiName)) {
            throw new FormValidationException('History table ' + fc.fieldApiName + ' key does not match its object.');
        }
        Map<String, Schema.SObjectField> histFieldMap = histType.getDescribe().fields.getMap();
        if (String.isBlank(fc.historyTargetAccountFieldApiName)) {
            throw new FormValidationException('History table ' + fc.fieldApiName + ' has no lookup to ' + sourceObjectApiName + ' configured.');
        }
        assertReferenceFieldTo(histFieldMap, fc.historyTargetAccountFieldApiName, fc.historyTargetObjectApiName, sourceObjectApiName);
        if (String.isNotBlank(fc.historyTargetLogFieldApiName)) {
            assertReferenceFieldTo(histFieldMap, fc.historyTargetLogFieldApiName, fc.historyTargetObjectApiName, 'Data_Update_Log__c');
        }
        Schema.SObjectField dateField = assertFieldExists(histFieldMap, fc.historyTargetDateFieldApiName, fc.historyTargetObjectApiName);
        Schema.DisplayType dateType = dateField.getDescribe().getType();
        if (dateType != Schema.DisplayType.DATE && dateType != Schema.DisplayType.DATETIME) {
            throw new FormValidationException('History table date field ' + fc.historyTargetDateFieldApiName + ' must be a Date or DateTime field.');
        }
        if (fc.tableColumns == null || fc.tableColumns.isEmpty()) {
            throw new FormValidationException('History table ' + fc.fieldApiName + ' has no columns.');
        }
        Set<String> checked = new Set<String>();
        for (TableColumn col : fc.tableColumns) {
            Schema.SObjectField field = assertFieldExists(histFieldMap, col.f, fc.historyTargetObjectApiName);
            if (!isTableColumnType(field.getDescribe().getType())) {
                throw new FormValidationException('Column ' + col.f + ' of ' + fc.fieldApiName + ' cannot be a table column.');
            }
            checked.add(col.f.toLowerCase());
        }
        if (!checked.contains(fc.historyTargetDateFieldApiName.toLowerCase())) {
            throw new FormValidationException('History table ' + fc.fieldApiName + ' must include its date column.');
        }
        String accountKey = fc.historyTargetAccountFieldApiName.toLowerCase();
        String logKey = String.isBlank(fc.historyTargetLogFieldApiName) ? '' : fc.historyTargetLogFieldApiName.toLowerCase();
        for (String key : histFieldMap.keySet()) {
            if (key == accountKey || key == logKey || checked.contains(key)) continue;
            Schema.DescribeFieldResult d = histFieldMap.get(key).getDescribe();
            if (isRequiredOnCreate(d)) {
                throw new FormValidationException('History table ' + fc.fieldApiName + ' must include required field ' + d.getName() + '.');
            }
        }
    }

    @TestVisible private static void assertReferenceFieldTo(Map<String, Schema.SObjectField> fieldMap, String fieldApiName, String objectApiName, String expectedReferenceTo) {
        Schema.SObjectField field = assertFieldExists(fieldMap, fieldApiName, objectApiName);
        Schema.DescribeFieldResult dfr = field.getDescribe();
        if (dfr.getType() != Schema.DisplayType.REFERENCE) {
            throw new FormValidationException('Field ' + fieldApiName + ' on ' + objectApiName + ' must be a lookup/reference field.');
        }
        Boolean pointsToExpected = false;
        for (Schema.SObjectType refType : dfr.getReferenceTo()) {
            if (refType.getDescribe().getName().equalsIgnoreCase(expectedReferenceTo)) {
                pointsToExpected = true;
                break;
            }
        }
        if (!pointsToExpected) {
            throw new FormValidationException('Field ' + fieldApiName + ' on ' + objectApiName + ' must reference ' + expectedReferenceTo + '.');
        }
    }

    // A base filter value may list several values separated by commas (e.g. SEMBEQ's
    // "Organisme, Business_Organization" record types), matched with IN. Blank parts are dropped.
    public static List<String> splitFilterValues(String value) {
        List<String> result = new List<String>();
        if (String.isBlank(value)) return result;
        for (String part : value.split(',')) {
            if (String.isNotBlank(part)) result.add(part.trim());
        }
        return result;
    }

    // targetBaseFilterField is interpolated straight into dynamic SOQL (see
    // DataUpdatePortalController/DataUpdateReviewController), which supports a one-hop
    // relationship path like "RecordType.DeveloperName" (used by the église form's base
    // filter) — assertFieldExists alone rejects that because Schema describe's fields map
    // only has literal field names, not relationship names. Validate hop-by-hop instead so a
    // real relationship path still passes fail-closed schema validation.
    public static Schema.DisplayType assertFilterFieldExists(Map<String, Schema.SObjectField> fieldMap, String fieldPath, String objectApiName) {
        if (String.isBlank(fieldPath)) {
            throw new FormValidationException('Unknown field ' + fieldPath + ' on ' + objectApiName);
        }
        List<String> parts = fieldPath.split('\\.');
        if (parts.size() == 1) {
            return assertFieldExists(fieldMap, fieldPath, objectApiName).getDescribe().getType();
        }
        if (parts.size() > 2) {
            throw new FormValidationException('Unsupported relationship depth in filter field ' + fieldPath + ' on ' + objectApiName);
        }

        Schema.SObjectField relField = findFieldByRelationshipName(fieldMap, parts[0]);
        List<Schema.SObjectType> refTypes = relField == null ? new List<Schema.SObjectType>() : relField.getDescribe().getReferenceTo();
        if (refTypes.isEmpty()) {
            throw new FormValidationException('Unknown field ' + fieldPath + ' on ' + objectApiName);
        }
        Schema.DescribeSObjectResult relatedDescribe = refTypes[0].getDescribe();
        Map<String, Schema.SObjectField> relatedFieldMap = relatedDescribe.fields.getMap();
        Schema.SObjectField leafField = relatedFieldMap.get(parts[1].toLowerCase());
        if (leafField == null) {
            throw new FormValidationException('Unknown field ' + fieldPath + ' on ' + relatedDescribe.getName());
        }
        return leafField.getDescribe().getType();
    }

    private static Schema.SObjectField findFieldByRelationshipName(Map<String, Schema.SObjectField> fieldMap, String relationshipName) {
        for (Schema.SObjectField f : fieldMap.values()) {
            Schema.DescribeFieldResult dfr = f.getDescribe();
            if (dfr.getRelationshipName() != null && dfr.getRelationshipName().equalsIgnoreCase(relationshipName)) {
                return f;
            }
        }
        return null;
    }

    // ─── Queue ───────────────────────────────────────────────────────────

    private static Map<String, Id> queueCache = new Map<String, Id>();
    private static Id resolveQueueId(String developerName) {
        if (String.isBlank(developerName)) return null;
        if (!queueCache.containsKey(developerName)) {
            List<Group> queues = [
                SELECT Id FROM Group
                WHERE Type = 'Queue' AND DeveloperName = :developerName
                LIMIT 1
            ];
            queueCache.put(developerName, queues.isEmpty() ? null : queues[0].Id);
        }
        return queueCache.get(developerName);
    }

    // ─── Identity comparison ────────────────────────────────────────────────

    // Acentos plegados solo para comparar identidad — el valor almacenado en
    // el registro objetivo nunca se modifica.
    private static final Map<String, String> ACCENT_MAP = new Map<String, String>{
        'À' => 'A', 'Á' => 'A', 'Â' => 'A', 'Ã' => 'A', 'Ä' => 'A', 'Å' => 'A',
        'È' => 'E', 'É' => 'E', 'Ê' => 'E', 'Ë' => 'E',
        'Ì' => 'I', 'Í' => 'I', 'Î' => 'I', 'Ï' => 'I',
        'Ò' => 'O', 'Ó' => 'O', 'Ô' => 'O', 'Õ' => 'O', 'Ö' => 'O', 'Ø' => 'O',
        'Ù' => 'U', 'Ú' => 'U', 'Û' => 'U', 'Ü' => 'U',
        'Ñ' => 'N', 'Ç' => 'C', 'Ý' => 'Y', 'Ÿ' => 'Y'
    };

    public static String normalizeText(String value) {
        if (String.isBlank(value)) return '';
        String result = value.trim().toUpperCase();
        for (String accented : ACCENT_MAP.keySet()) {
            result = result.replace(accented, ACCENT_MAP.get(accented));
        }
        while (result.contains('  ')) {
            result = result.replace('  ', ' ');
        }
        return result.trim();
    }

    // ─── Canadian postal codes ─────────────────────────────────────────────
    // Canadian codes are stored "A1A 1A1"; every other country's code is kept as typed.
    // Mirrors the portal's live formatting in the dataUpdatePostalCode LWC module — keep in sync.

    private static final Set<String> CANADA_COUNTRY_VALUES = new Set<String>{ 'CA', 'CAN', 'CANADA' };
    private static final Pattern CANADIAN_POSTAL_SHAPE = Pattern.compile('^[A-Z][0-9][A-Z][0-9][A-Z][0-9]$');
    // A started-but-broken Canadian code (A1B, A1B2, A1B2C, A1B2C33...). Other countries' codes
    // (UK W1A 1AA, Irish D02 AF30, numeric codes) don't fit it, so they're never flagged.
    private static final Pattern CANADIAN_POSTAL_ATTEMPT = Pattern.compile('^[A-Z][0-9][A-Z]([0-9]([A-Z][0-9]*)?)?$');

    public static Boolean isPostalCodeField(String fieldApiName) {
        return String.isNotBlank(fieldApiName) && fieldApiName.toLowerCase().endsWith('postalcode');
    }

    /**
     * The country deciding a postal field's format: the matching "...Country" field of the same
     * address (PersonMailingPostalCode → PersonMailingCountry), taken from the proposed values
     * first, then from the record's current value.
     */
    public static String resolvePostalCountry(String postalFieldApiName, Map<String, Object> proposed, SObject currentRecord) {
        String countryField = postalFieldApiName.left(postalFieldApiName.length() - 'PostalCode'.length()) + 'Country';
        if (proposed != null) {
            for (String key : proposed.keySet()) {
                if (key.equalsIgnoreCase(countryField) && proposed.get(key) != null
                        && String.isNotBlank(String.valueOf(proposed.get(key)))) {
                    return String.valueOf(proposed.get(key));
                }
            }
        }
        if (currentRecord != null) {
            try {
                Object current = currentRecord.get(countryField);
                return current == null ? null : String.valueOf(current);
            } catch (SObjectException e) {
                return null; // no such field, or not queried
            }
        }
        return null;
    }

    /**
     * Known Canadian country → "A1A 1A1" (letters upper-cased; extra characters are kept so
     * isInvalidPostalCode() can flag them instead of silently cutting what the person typed).
     * Known other country → unchanged. No country → formatted only when the value already has
     * the Canadian letter/digit shape, which no other country's postal code uses.
     */
    public static String formatPostalCode(String value, String country) {
        if (String.isBlank(value)) return value;
        Boolean countryKnown = String.isNotBlank(country);
        if (countryKnown && !CANADA_COUNTRY_VALUES.contains(normalizeText(country))) return value;

        String compact = value.replaceAll('[^A-Za-z0-9]', '').toUpperCase();
        if (!countryKnown) {
            return CANADIAN_POSTAL_SHAPE.matcher(compact).matches()
                ? compact.left(3) + ' ' + compact.right(3)
                : value;
        }
        return compact.length() > 3 ? compact.left(3) + ' ' + compact.substring(3) : compact;
    }

    /**
     * True when a Canadian postal code is malformed: country known as Canada and the value isn't
     * exactly A1A1A1, or no country and the value is a broken Canadian-shaped attempt.
     */
    public static Boolean isInvalidPostalCode(String value, String country) {
        if (String.isBlank(value)) return false;
        Boolean countryKnown = String.isNotBlank(country);
        if (countryKnown && !CANADA_COUNTRY_VALUES.contains(normalizeText(country))) return false;

        String compact = value.replaceAll('[^A-Za-z0-9]', '').toUpperCase();
        if (CANADIAN_POSTAL_SHAPE.matcher(compact).matches()) return false;
        return countryKnown || CANADIAN_POSTAL_ATTEMPT.matcher(compact).matches();
    }

    /** First postal field in proposed holding a malformed Canadian code, or null. */
    public static String findInvalidPostalCodeField(Map<String, String> proposed, SObject currentRecord) {
        Map<String, Object> asObjects = new Map<String, Object>();
        for (String key : proposed.keySet()) {
            asObjects.put(key, proposed.get(key));
        }
        for (String key : proposed.keySet()) {
            if (isPostalCodeField(key)
                    && isInvalidPostalCode(proposed.get(key), resolvePostalCountry(key, asObjects, currentRecord))) {
                return key;
            }
        }
        return null;
    }

    public static void formatPostalCodes(Map<String, String> proposed, SObject currentRecord) {
        Map<String, Object> asObjects = new Map<String, Object>();
        for (String key : proposed.keySet()) {
            asObjects.put(key, proposed.get(key));
        }
        for (String key : new List<String>(proposed.keySet())) {
            if (!isPostalCodeField(key)) continue;
            proposed.put(key, formatPostalCode(proposed.get(key), resolvePostalCountry(key, asObjects, currentRecord)));
        }
    }

    /** Emails are stored lowercase, whatever the visitor or staff typed ("Info@Church.CA" → "info@church.ca"). */
    public static String normalizeEmail(Schema.DescribeFieldResult d, String value) {
        if (d == null || value == null || d.getType() != Schema.DisplayType.EMAIL) return value;
        return value.trim().toLowerCase();
    }

    public static Boolean matchesIdentity(Object recordValue, String inputValue, String comparisonType) {
        String recordStr = recordValue == null ? '' : String.valueOf(recordValue);
        String inputStr  = inputValue == null ? '' : inputValue.trim();
        if ('Normalized_Text'.equals(comparisonType)) {
            return normalizeText(recordStr) == normalizeText(inputStr);
        }
        return recordStr == inputStr;
    }
}
