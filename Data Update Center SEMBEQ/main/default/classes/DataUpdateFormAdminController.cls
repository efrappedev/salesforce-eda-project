/**
 * DataUpdateFormAdminController.cls
 * Backs the dataUpdateFormBuilder LWC (Form Builder, staff-only). Lets staff build each form's
 * questions from ALREADY-EXISTING fields into Data_Update_Form_Field__mdt — picked from
 * Schema.describe() so the API name is never hand-typed — and create or delete
 * Data_Update_Form__mdt records (public forms) pointing at fields the admin already created in Setup. This tool never creates new SCHEMA (no custom
 * fields, no objects) — only new CMDT records pointing at existing fields.
 *
 * Publishing writes DUC_Form_Config__c rows through DucFormConfigStore, which layers them over
 * the Custom Metadata records — plain DML, so staff only need the app's permission sets, never
 * metadata rights. Writes are still built as Metadata.CustomMetadata records (full record, never
 * a partial diff) and merged field by field, exactly like a metadata deploy.
 *
 * Publishing is synchronous: deploy() saves, writes a Succeeded Data_Update_Form_Deploy_Job__c
 * row under the returned job id and frees the publish lock. The LWC keeps polling
 * checkDeployStatus() as before; it just finds the job done on the first check.
 */
public with sharing class DataUpdateFormAdminController {

    public class AdminException extends Exception {}

    private static final String FORM_MDT       = 'Data_Update_Form__mdt';
    private static final String FIELD_MDT      = 'Data_Update_Form_Field__mdt';
    private static final String CHURCH_FILTER_FIELD = 'RecordType.DeveloperName';
    private static final String CHURCH_RECORD_TYPE  = 'Eglise';
    private static final Integer DISPLAY_ORDER_STEP = 10;
    private static final String HISTORY_ONLY = DataUpdateFormConfigService.HISTORY_ONLY;
    private static final String HISTORY_TABLE = DataUpdateFormConfigService.HISTORY_TABLE;

    // Test seams: production orgs running the tests may have no Live Experience Cloud site to
    // validate networkName against. skipEnqueueForTest is no longer read (publishing is plain DML
    // now) and only kept so existing tests compile.
    @TestVisible private static Boolean skipEnqueueForTest = false;
    @TestVisible private static Boolean bypassNetworkCheckForTest = false;
    // Lets tests use a form that doesn't exist in the org's CMDT (non-core form to delete,
    // form pointing at an unknown object).
    @TestVisible private static Data_Update_Form__mdt testFormMdt;
    // Same idea for the form's field records (History Only / History Table records the org's
    // forms don't ship). Built via JSON.deserialize, with Form__r.DeveloperName set.
    @TestVisible private static List<Data_Update_Form_Field__mdt> testFieldMdts;
    // Test orgs may have no Live site and no resolvable site URL; tests set these instead.
    @TestVisible private static String liveNetworkStatus = 'Live';
    @TestVisible private static Boolean useTestLoginUrl = false;
    @TestVisible private static String testLoginUrl;
    @TestVisible private static Boolean TEST_FORCE_ERROR = false;
    @TestVisible private static Boolean TEST_FORCE_SAVE_ERROR = false;

    // System fields never offered in the "add field" wizard — no reasonable free-text
    // equivalent, or already exposed some other way.
    private static final Set<String> EXCLUDED_FIELD_NAMES = new Set<String>{
        'id', 'isdeleted', 'masterrecordid', 'systemmodstamp', 'createdbyid', 'createddate',
        'lastmodifiedbyid', 'lastmodifieddate', 'lastactivitydate', 'lastvieweddate',
        'lastreferenceddate', 'ownerid', 'recordtypeid', 'photourl',
        // Internal/integration fields nobody should put on a public form.
        'jigsaw', 'jigsawcompanyid', 'billinggeocodeaccuracy', 'shippinggeocodeaccuracy',
        'iscustomerportal', 'ispartner', 'data_update_locked__c', 'data_update_locked_date__c'
    };

    // ─── Form-admin gate ─────────────────────────────────────────────────
    //
    // Building/creating/deleting forms is for the people who know what they're doing (staff lead,
    // IT) — not for every user with Data_Update_Center_Access, who only works the request inbox.
    // Granted by the Data_Update_Center_Form_Admin permission set (custom permission
    // Data_Update_Manage_Forms). Enforced here, server-side, on every builder endpoint; hiding the
    // builder button in dataUpdateCenter is UX only. getForms() stays open: the daily inbox,
    // dashboard and locked list use it for their form filter.
    public static final String MANAGE_FORMS_PERMISSION = 'Data_Update_Manage_Forms';

    // Tests run as users without the permission set by default; the gate's own test turns this on.
    @TestVisible private static Boolean enforceManageFormsForTest = false;

    @TestVisible private static void requireManageForms() {
        if (Test.isRunningTest() && !enforceManageFormsForTest) {
            return;
        }
        if (!FeatureManagement.checkPermission(MANAGE_FORMS_PERMISSION)) {
            AuraHandledException e = new AuraHandledException('');
            e.setMessage('You do not have permission to manage Data Update Center forms.');
            throw e;
        }
    }

    // ─── Publish lock ────────────────────────────────────────────────────
    //
    // One builder publish (any form, any user) at a time in the org, so two people publishing the
    // same form never silently overwrite each other. The lock is one shared
    // Data_Update_Form_Deploy_Job__c row (Job_Id__c = PUBLISH_LOCK_ID): taken by
    // acquirePublishLock(), checked and freed by deploy() once the publish is saved. A lock whose
    // holder never publishes expires on its own. (LOCK_RELEASED + cooldown are left from the old
    // async metadata deploys: only DataUpdateFormAdminDeployCallback still sets it.)
    // Holder = LastModifiedBy, start = LastModifiedDate (no extra fields needed).
    public static final String PUBLISH_LOCK_ID = 'publish-lock';
    public static final String LOCK_PUBLISHING = 'Publishing';
    public static final String LOCK_RELEASED = 'Released';
    public static final String LOCK_FREE = 'Free';
    @TestVisible private static final Integer LOCK_MAX_SECS = 300;
    @TestVisible private static final Integer LOCK_COOLDOWN_SECS = 20;
    // Existing tests publish without taking the lock; the lock's own tests turn this on.
    @TestVisible private static Boolean enforcePublishLockForTest = false;
    // Lets tests move the clock (expiry, end of cooldown).
    @TestVisible private static Datetime lockNow;
    // Simulates two admins creating the lock row at the same instant (the unique Job_Id__c collision).
    @TestVisible private static Boolean failLockUpsertForTest = false;

    @AuraEnabled(cacheable=false)
    public static DataUpdateWrapper.PublishLockInfo getPublishLock() {
        requireManageForms();
        return lockInfo(lockRow(false));
    }

    // what = what is being published, as the other builders' banner shows it (form label…).
    @AuraEnabled
    public static DataUpdateWrapper.PublishLockInfo acquirePublishLock(String what) {
        requireManageForms();
        Data_Update_Form_Deploy_Job__c row = lockRow(true);
        DataUpdateWrapper.PublishLockInfo current = lockInfo(row);
        if (current.active) return current;
        if (row == null) row = new Data_Update_Form_Deploy_Job__c(Job_Id__c = PUBLISH_LOCK_ID);
        row.Status__c = LOCK_PUBLISHING;
        row.Form_Developer_Name__c = String.isBlank(what) ? null : what.left(100);
        try {
            if (failLockUpsertForTest) throw new DmlException('TEST_LOCK_COLLISION');
            upsert row;
        } catch (DmlException e) {
            // Someone else created the row at the same instant (unique Job_Id__c): theirs wins.
            return lockInfo(lockRow(false));
        }
        DataUpdateWrapper.PublishLockInfo mine = lockInfo(lockRow(false));
        mine.acquired = true;
        return mine;
    }

    // The publish could not even be queued: give the lock back right away, no cooldown.
    @AuraEnabled
    public static void releasePublishLock() {
        requireManageForms();
        Data_Update_Form_Deploy_Job__c row = lockRow(true);
        if (row != null && row.Status__c == LOCK_PUBLISHING && row.LastModifiedById == UserInfo.getUserId()) {
            row.Status__c = LOCK_FREE;
            update row;
        }
    }

    // From DataUpdateFormAdminDeployCallback. stamp = the lock's LastModifiedDate when this
    // deploy was queued: a late callback never frees a newer lock taken after an expiry.
    public static void releasePublishLockAfterDeploy(Datetime stamp) {
        if (stamp == null) return;
        Data_Update_Form_Deploy_Job__c row = lockRow(true);
        if (row != null && row.Status__c == LOCK_PUBLISHING && row.LastModifiedDate.getTime() == stamp.getTime()) {
            row.Status__c = LOCK_RELEASED;
            update row;
        }
    }

    private static Data_Update_Form_Deploy_Job__c lockRow(Boolean forUpdate) {
        List<Data_Update_Form_Deploy_Job__c> rows = forUpdate
            ? [SELECT Id, Status__c, Form_Developer_Name__c, LastModifiedDate, LastModifiedById, LastModifiedBy.Name
               FROM Data_Update_Form_Deploy_Job__c WHERE Job_Id__c = :PUBLISH_LOCK_ID LIMIT 1 FOR UPDATE]
            : [SELECT Id, Status__c, Form_Developer_Name__c, LastModifiedDate, LastModifiedById, LastModifiedBy.Name
               FROM Data_Update_Form_Deploy_Job__c WHERE Job_Id__c = :PUBLISH_LOCK_ID LIMIT 1];
        return rows.isEmpty() ? null : rows[0];
    }

    private static DataUpdateWrapper.PublishLockInfo lockInfo(Data_Update_Form_Deploy_Job__c row) {
        DataUpdateWrapper.PublishLockInfo info = new DataUpdateWrapper.PublishLockInfo();
        if (row == null || row.LastModifiedDate == null) return info;
        Datetime now = lockNow != null ? lockNow : Datetime.now();
        Integer age = (Integer) ((now.getTime() - row.LastModifiedDate.getTime()) / 1000);
        if (row.Status__c == LOCK_PUBLISHING && age < LOCK_MAX_SECS) {
            info.phase = 'publishing';
            info.elapsedSecs = Math.max(age, 0);
            info.remainingSecs = LOCK_MAX_SECS - info.elapsedSecs;
        } else if (row.Status__c == LOCK_RELEASED && age < LOCK_COOLDOWN_SECS) {
            info.phase = 'cooldown';
            info.remainingSecs = LOCK_COOLDOWN_SECS - Math.max(age, 0);
        } else {
            return info;
        }
        info.active = true;
        info.what = row.Form_Developer_Name__c;
        info.userName = row.LastModifiedBy != null ? row.LastModifiedBy.Name : null;
        info.mine = row.LastModifiedById == UserInfo.getUserId();
        return info;
    }

    // deploy() only runs for the person holding a live lock.
    private static Data_Update_Form_Deploy_Job__c requirePublishLock() {
        if (Test.isRunningTest() && !enforcePublishLockForTest) return null;
        Data_Update_Form_Deploy_Job__c row = lockRow(false);
        DataUpdateWrapper.PublishLockInfo info = lockInfo(row);
        if (!info.active || info.phase != 'publishing' || !info.mine) {
            throw new AdminException('Another publish is in progress. Please wait a moment and try again.');
        }
        return row;
    }

    // Lets dataUpdateCenter show the Form Builder button only to form admins (UX only).
    @AuraEnabled(cacheable=true)
    public static Boolean getCanManageForms() {
        return FeatureManagement.checkPermission(MANAGE_FORMS_PERMISSION);
    }

    // ─── Read ────────────────────────────────────────────────────────────

    // Network (Experience Cloud sites) only exists once Digital Experiences is enabled, so it is
    // queried dynamically: the app still compiles and runs (with no sites) in an org without it.
    // Tests stand in rows with Id + Name (any SObject) since Network may not exist in the org.
    @TestVisible private static List<SObject> testNetworks;

    @TestVisible
    private static List<SObject> queryNetworks(String soql, Map<String, Object> binds) {
        if (testNetworks != null) return testNetworks;
        Boolean hasNetwork = Type.forName('Schema.Network') != null;
        return hasNetwork ? Database.queryWithBinds(soql, binds, AccessLevel.SYSTEM_MODE) : new List<SObject>();
    }

    @AuraEnabled(cacheable=false)
    public static List<DataUpdateWrapper.FormSummary> getForms() {
        Map<String, Id> networkIdByName = new Map<String, Id>();
        for (SObject n : queryNetworks('SELECT Id, Name FROM Network', new Map<String, Object>())) {
            networkIdByName.put((String) n.get('Name'), n.Id);
        }

        List<DataUpdateWrapper.FormSummary> result = new List<DataUpdateWrapper.FormSummary>();
        for (Data_Update_Form__mdt f : DucFormConfigStore.forms()) {
            if (f.Is_Active__c != true) continue;
            DataUpdateWrapper.FormSummary s = new DataUpdateWrapper.FormSummary();
            s.developerName       = f.DeveloperName;
            s.label                = f.MasterLabel;
            s.targetObjectApiName = f.Target_Object_API_Name__c;
            s.hasLockField         = String.isNotBlank(f.Lock_Field_API_Name__c);
            s.isCoreForm           = f.Is_Core_Form__c == true;
            s.networkName          = f.Network_Name__c;
            s.isChurchForm         = isChurchForm(f);
            s.allowMultipleSubmissions = f.Allow_Duplicate_Open_Requests__c == true;
            s.publicUrl            = buildPublicUrl(networkIdByName.get(f.Network_Name__c), f.DeveloperName, s.isCoreForm);
            result.add(s);
        }
        return result;
    }

    // A church form targets Account records of the église record type — the only forms the
    // dashboard's responses checklist covers.
    private static Boolean isChurchForm(Data_Update_Form__mdt f) {
        return f.Target_Object_API_Name__c == 'Account'
            && f.Target_Base_Filter_Field__c == CHURCH_FILTER_FIELD
            && f.Target_Base_Filter_Value__c == CHURCH_RECORD_TYPE;
    }

    // Real public URL for a form, resolved from the Experience Cloud site it belongs to.
    // Network.getLoginUrl() correctly resolves sandbox vs. production domain and the site's real
    // path prefix (e.g. /majcompte/ vs. /majeglise/) regardless of the context this Apex runs in —
    // unlike window.location.origin on the client, which resolves to the internal Lightning
    // domain when the Form Builder is opened from inside the org, not the public site.
    //
    // Core forms are pinned directly to their site's Home page via the dataUpdateForm component's
    // formNameOverride property (set in Experience Builder), which is evaluated before the "?form="
    // URL param is even read — so the bare site URL already loads the core form, and appending
    // "?form=" is misleading (looks like a special link when it's just the site root). Only
    // non-core (child) forms, which share that same pinned page, actually need "?form=" to be
    // reachable at all.
    @TestVisible private static String buildPublicUrl(Id networkId, String formDeveloperName, Boolean isCoreForm) {
        if (networkId == null || String.isBlank(formDeveloperName)) {
            return null;
        }
        String loginUrl = useTestLoginUrl ? testLoginUrl : Network.getLoginUrl(networkId);
        if (String.isBlank(loginUrl)) {
            return null;
        }
        String baseUrl = loginUrl.endsWithIgnoreCase('/login')
            ? loginUrl.substring(0, loginUrl.length() - '/login'.length())
            : loginUrl;
        if (isCoreForm == true) {
            return baseUrl + '/';
        }
        return baseUrl + '/?form=' + EncodingUtil.urlEncode(formDeveloperName, 'UTF-8');
    }

    // Site picker for the "create form" wizard — every public form must belong to one live
    // Experience Cloud site (Network_Name__c), used later to resolve its real public URL.
    @AuraEnabled(cacheable=false)
    public static List<DataUpdateWrapper.SchemaObjectOption> getNetworkOptions() {
        requireManageForms();
        List<DataUpdateWrapper.SchemaObjectOption> result = new List<DataUpdateWrapper.SchemaObjectOption>();
        for (SObject n : queryNetworks('SELECT Name FROM Network WHERE Status = :status ORDER BY Name ASC',
                new Map<String, Object>{ 'status' => liveNetworkStatus })) {
            DataUpdateWrapper.SchemaObjectOption opt = new DataUpdateWrapper.SchemaObjectOption();
            opt.apiName = (String) n.get('Name');
            opt.label   = opt.apiName;
            result.add(opt);
        }
        return result;
    }

    // Powers the "create form" wizard's inheritance shortcut: every site (Network_Name__c) has
    // exactly one core form, and a new child (anexo) form for that same site almost always wants
    // the same identity/base-filter/lock/owner-queue/record-name config — the discriminator that
    // actually varies per form is the Site, not the target object (both AEBEQ core forms target
    // Account, differentiated only by Network_Name__c + Target_Base_Filter_Field/Value__c). The
    // wizard pre-fills these from here and hides them behind "Advanced options"; the admin can
    // still override any of them before submitting. Returns null if the site has no core form yet.
    @AuraEnabled(cacheable=false)
    public static DataUpdateWrapper.CoreFormConfig getCoreFormConfigForNetwork(String networkName) {
        requireManageForms();
        if (String.isBlank(networkName)) {
            throw new AdminException('networkName is required.');
        }
        List<Data_Update_Form__mdt> forms = new List<Data_Update_Form__mdt>();
        for (Data_Update_Form__mdt candidate : DucFormConfigStore.forms()) {
            if (candidate.Network_Name__c == networkName && candidate.Is_Core_Form__c == true
                    && candidate.Is_Active__c == true && forms.isEmpty()) {
                forms.add(candidate);
            }
        }
        if (forms.isEmpty()) {
            return null;
        }
        Data_Update_Form__mdt f = forms[0];
        DataUpdateWrapper.CoreFormConfig c = new DataUpdateWrapper.CoreFormConfig();
        c.targetObjectApiName     = f.Target_Object_API_Name__c;
        c.identityField1ApiName   = f.Identity_Field_1_API_Name__c;
        c.identityField1Comparison = f.Identity_Field_1_Comparison__c;
        c.identityField2ApiName   = f.Identity_Field_2_API_Name__c;
        c.identityField2Comparison = f.Identity_Field_2_Comparison__c;
        c.targetBaseFilterField   = f.Target_Base_Filter_Field__c;
        c.targetBaseFilterValue   = f.Target_Base_Filter_Value__c;
        c.ownerQueueDeveloperName = f.Owner_Queue_DeveloperName__c;
        c.recordNameFieldApiName  = f.Record_Name_Field_API_Name__c;
        c.lockFieldApiName        = f.Lock_Field_API_Name__c;
        c.lockDateFieldApiName    = f.Lock_Date_Field_API_Name__c;
        return c;
    }

    @AuraEnabled(cacheable=false)
    public static List<DataUpdateWrapper.AdminFieldConfig> getFormFields(String formDeveloperName) {
        requireManageForms();
        if (String.isBlank(formDeveloperName)) {
            throw new AdminException('formDeveloperName is required.');
        }
        Data_Update_Form__mdt form = getFormOrThrow(formDeveloperName);
        Map<String, Schema.SObjectField> fieldMap = describeFieldMap(form.Target_Object_API_Name__c);

        List<DataUpdateWrapper.AdminFieldConfig> result = new List<DataUpdateWrapper.AdminFieldConfig>();
        for (Data_Update_Form_Field__mdt fm : getFieldRecords(formDeveloperName)) {
            DataUpdateWrapper.AdminFieldConfig c = new DataUpdateWrapper.AdminFieldConfig();
            c.developerName    = fm.DeveloperName;
            c.fieldApiName     = fm.Field_API_Name__c;
            c.labelFr          = fm.Label_FR__c;
            c.labelEn          = fm.Label_EN__c;
            c.displayOrder     = fm.Display_Order__c != null ? Integer.valueOf(fm.Display_Order__c) : 0;
            c.sectionLabelFr   = fm.Section_Label_FR__c;
            c.sectionLabelEn   = fm.Section_Label_EN__c;
            c.inputType        = fm.Input_Type__c;
            c.isRequired       = fm.Is_Required__c == true;
            c.isActive         = fm.Is_Active__c == true;
            c.historyMode      = String.isBlank(fm.History_Mode__c) ? 'Replace' : fm.History_Mode__c;
            c.isValidInSchema  = c.historyMode == HISTORY_ONLY
                ? isValidHistoryOnlyMapping(fm, form.Target_Object_API_Name__c)
                : c.historyMode == HISTORY_TABLE
                    ? isValidHistoryTableMapping(fm, form.Target_Object_API_Name__c)
                    : String.isNotBlank(fm.Field_API_Name__c) && fieldMap.containsKey(fm.Field_API_Name__c.toLowerCase());
            c.historyTableColumns             = fm.History_Table_Columns__c;
            c.historyTableInputMode           = fm.History_Table_Input_Mode__c;
            c.historyTargetObjectApiName      = fm.History_Target_Object_API_Name__c;
            c.historyTargetValueFieldApiName  = fm.History_Target_Value_Field_API_Name__c;
            c.historyTargetDateFieldApiName   = fm.History_Target_Date_Field_API_Name__c;
            c.historyTargetAccountFieldApiName = fm.History_Target_Account_Field_API_Name__c;
            c.historyTargetLogFieldApiName    = fm.History_Target_Log_Field_API_Name__c;
            c.historyDateSourceFieldApiName   = fm.History_Date_Source_Field_API_Name__c;
            c.sameRowAsPrevious               = fm.Same_Row_As_Previous__c == true;
            c.helpFr                          = fm.Help_FR__c;
            c.helpEn                          = fm.Help_EN__c;
            c.isHidden                        = fm.Is_Hidden__c == true;
            c.isReadOnly                      = fm.Is_Read_Only__c == true;
            result.add(c);
        }
        return result;
    }

    @AuraEnabled(cacheable=false)
    public static List<DataUpdateWrapper.AvailableFieldOption> getAvailableFields(String formDeveloperName) {
        requireManageForms();
        if (String.isBlank(formDeveloperName)) {
            throw new AdminException('formDeveloperName is required.');
        }
        Data_Update_Form__mdt form = getFormOrThrow(formDeveloperName);
        Schema.SObjectType targetType = DataUpdateFormConfigService.globalTypes().get(form.Target_Object_API_Name__c);
        if (targetType == null) {
            throw new AdminException('Unknown object: ' + form.Target_Object_API_Name__c);
        }

        Set<String> alreadyCataloged = new Set<String>();
        for (Data_Update_Form_Field__mdt fm : getFieldRecords(formDeveloperName)) {
            if (String.isNotBlank(fm.Field_API_Name__c)) {
                alreadyCataloged.add(fm.Field_API_Name__c.toLowerCase());
            }
        }

        // The form's own lock fields are never offered (the portal must not let people unlock themselves).
        if (String.isNotBlank(form.Lock_Field_API_Name__c)) alreadyCataloged.add(form.Lock_Field_API_Name__c.toLowerCase());
        if (String.isNotBlank(form.Lock_Date_Field_API_Name__c)) alreadyCataloged.add(form.Lock_Date_Field_API_Name__c.toLowerCase());
        Boolean businessAccountsOnly = form.Target_Object_API_Name__c == 'Account' && isBusinessAccountScope(form);

        List<DataUpdateWrapper.AvailableFieldOption> result = new List<DataUpdateWrapper.AvailableFieldOption>();
        for (Schema.SObjectField sf : targetType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult d = sf.getDescribe();
            String apiName = d.getName();
            if (alreadyCataloged.contains(apiName.toLowerCase())) continue;
            if (EXCLUDED_FIELD_NAMES.contains(apiName.toLowerCase())) continue;
            if (businessAccountsOnly && isPersonAccountOnlyField(apiName)) continue;
            if (!d.isAccessible() || !d.isUpdateable()) continue;

            Schema.DisplayType dt = d.getType();
            if (dt == Schema.DisplayType.MULTIPICKLIST
                || dt == Schema.DisplayType.REFERENCE || dt == Schema.DisplayType.ADDRESS) continue;

            DataUpdateWrapper.AvailableFieldOption opt = new DataUpdateWrapper.AvailableFieldOption();
            opt.apiName            = apiName;
            opt.schemaLabel        = d.getLabel();
            opt.inferredInputType  = inferInputType(dt);
            result.add(opt);
        }
        result.sort(new AvailableFieldOptionComparator());
        return result;
    }

    /** True when the form's base filter limits it to business accounts (e.g. Église = RecordType Eglise). */
    @TestVisible private static Boolean isBusinessAccountScope(Data_Update_Form__mdt form) {
        String field = form.Target_Base_Filter_Field__c;
        String value = form.Target_Base_Filter_Value__c;
        if (String.isBlank(field) || String.isBlank(value)) return false;
        if (field.equalsIgnoreCase('IsPersonAccount')) return value.equalsIgnoreCase('false');
        if (field.equalsIgnoreCase('RecordType.DeveloperName')) {
            List<String> values = DataUpdateFormConfigService.splitFilterValues(value);
            // RecordType.IsPersonType only exists in orgs with Person Accounts (AEBEQ, not SEMBEQ),
            // so it's queried dynamically; without it every Account record type is a business one.
            Boolean hasPersonType = Schema.SObjectType.RecordType.fields.getMap().containsKey('ispersontype');
            List<RecordType> rts = Database.query('SELECT ' + (hasPersonType ? 'IsPersonType' : 'Id')
                + ' FROM RecordType WHERE SobjectType = \'Account\' AND DeveloperName IN :values');
            Boolean allBusiness = !rts.isEmpty();
            for (RecordType rt : rts) {
                allBusiness = allBusiness && !(hasPersonType && rt.get('IsPersonType') == true);
            }
            return allBusiness;
        }
        return false;
    }

    /** Person Account fields surfaced on Account (PersonEmail, FirstName, custom __pc…) — empty on a business account. */
    @TestVisible private static Boolean isPersonAccountOnlyField(String apiName) {
        String lower = apiName.toLowerCase();
        return lower.startsWith('person') || lower.endsWith('__pc')
            || new Set<String>{ 'firstname', 'lastname', 'middlename', 'suffix', 'salutation' }.contains(lower);
    }

    private class AvailableFieldOptionComparator implements Comparator<DataUpdateWrapper.AvailableFieldOption> {
        public Integer compare(DataUpdateWrapper.AvailableFieldOption a, DataUpdateWrapper.AvailableFieldOption b) {
            return String.valueOf(a.schemaLabel).compareTo(String.valueOf(b.schemaLabel));
        }
    }

    @TestVisible private static String inferInputType(Schema.DisplayType dt) {
        if (dt == Schema.DisplayType.EMAIL) return 'Email';
        if (dt == Schema.DisplayType.PHONE) return 'Phone';
        if (dt == Schema.DisplayType.DOUBLE || dt == Schema.DisplayType.INTEGER
            || dt == Schema.DisplayType.CURRENCY || dt == Schema.DisplayType.PERCENT
            || dt == Schema.DisplayType.LONG) return 'Number';
        if (dt == Schema.DisplayType.DATE || dt == Schema.DisplayType.DATETIME) return 'Date';
        if (dt == Schema.DisplayType.BOOLEAN) return 'Checkbox';
        if (dt == Schema.DisplayType.PICKLIST) return 'Picklist';
        return 'Text';
    }

    // Picker for "related object" questions: only custom objects with a lookup to the form's
    // target object (e.g. Account), so admins don't scroll through every object in the org.
    // System objects (this app's own, Zeffy Connect's) are excluded — never answer destinations.
    private static final List<String> RELATED_OBJECT_EXCLUDED_PREFIXES = new List<String>{ 'Data_Update_', 'Zeffy_', 'DMC_', 'Dmc_' };

    @AuraEnabled(cacheable=false)
    public static List<DataUpdateWrapper.SchemaObjectOption> getRelatedObjects(String parentObjectApiName) {
        requireManageForms();
        if (String.isBlank(parentObjectApiName)) {
            throw new AdminException('parentObjectApiName is required.');
        }
        Schema.SObjectType parentType = DataUpdateFormConfigService.globalTypes().get(parentObjectApiName);
        if (parentType == null) {
            throw new AdminException('Unknown object: ' + parentObjectApiName);
        }
        Map<String, DataUpdateWrapper.SchemaObjectOption> byName = new Map<String, DataUpdateWrapper.SchemaObjectOption>();
        for (Schema.ChildRelationship rel : parentType.getDescribe().getChildRelationships()) {
            Schema.DescribeSObjectResult d = rel.getChildSObject().getDescribe();
            String apiName = d.getName();
            if (!apiName.endsWith('__c') || isExcludedRelatedObject(apiName)) continue;
            if (byName.containsKey(apiName)) continue;
            if (d.isCustomSetting()) continue;
            if (!d.isAccessible() || !d.isCreateable()) continue;

            DataUpdateWrapper.SchemaObjectOption opt = new DataUpdateWrapper.SchemaObjectOption();
            opt.apiName = apiName;
            opt.label   = d.getLabel();
            byName.put(apiName, opt);
        }
        // Which forms already use each object, so the builder can tell church objects apart in
        // a person form (both target Account).
        for (Data_Update_Form__mdt f : DucFormConfigStore.forms()) {
            for (Data_Update_Form_Field__mdt fm : DucFormConfigStore.fields(f.DeveloperName)) {
                DataUpdateWrapper.SchemaObjectOption opt = String.isBlank(fm.History_Target_Object_API_Name__c)
                    ? null : byName.get(fm.History_Target_Object_API_Name__c);
                if (opt == null) continue;
                if (opt.usedByForms == null) opt.usedByForms = new List<String>();
                if (!opt.usedByForms.contains(f.DeveloperName)) opt.usedByForms.add(f.DeveloperName);
            }
        }
        List<DataUpdateWrapper.SchemaObjectOption> result = byName.values();
        result.sort(new SchemaObjectOptionComparator());
        return result;
    }

    /**
     * Every related object that can be a History_Table on the form (églises): a custom child of
     * the target object with a Date/DateTime column. The lookups and the date column are
     * auto-detected here (and again, server-side, on publish) — staff only pick columns, and
     * lookups are never offered as columns (Account/Log are filled automatically).
     */
    @AuraEnabled(cacheable=false)
    public static List<DataUpdateWrapper.HistoryTableSchema> getHistoryTableSchemas(String parentObjectApiName) {
        requireManageForms();
        List<DataUpdateWrapper.HistoryTableSchema> result = new List<DataUpdateWrapper.HistoryTableSchema>();
        for (DataUpdateWrapper.SchemaObjectOption obj : getRelatedObjects(parentObjectApiName)) {
            DataUpdateWrapper.HistoryTableSchema hts = detectHistoryTableSchema(obj.apiName, parentObjectApiName);
            if (hts != null) result.add(hts);
        }
        return result;
    }

    /** Null when the object can't hold a history table (no lookup back, or no date column). */
    // Tests repoint it: no SEMBEQ object has a lookup to Data_Update_Log__c.
    @TestVisible private static String logObjectApiName = 'Data_Update_Log__c';

    @TestVisible private static DataUpdateWrapper.HistoryTableSchema detectHistoryTableSchema(String objectApiName, String parentObjectApiName) {
        Schema.SObjectType objType = DataUpdateFormConfigService.globalTypes().get(objectApiName);
        if (objType == null) return null;
        Schema.DescribeSObjectResult od = objType.getDescribe();
        DataUpdateWrapper.HistoryTableSchema hts = new DataUpdateWrapper.HistoryTableSchema();
        hts.objectApiName = od.getName();
        hts.objectLabel   = od.getLabel();

        List<Schema.DescribeFieldResult> fields = new List<Schema.DescribeFieldResult>();
        for (Schema.SObjectField sf : od.fields.getMap().values()) fields.add(sf.getDescribe());

        for (Schema.DescribeFieldResult d : fields) {
            if (d.getType() != Schema.DisplayType.REFERENCE || !d.isCreateable()) continue;
            for (Schema.SObjectType ref : d.getReferenceTo()) {
                String refName = ref.getDescribe().getName();
                if (refName.equalsIgnoreCase(parentObjectApiName)
                        && (hts.accountFieldApiName == null || d.getName() == 'Account__c')) {
                    hts.accountFieldApiName = d.getName();
                }
                if (refName == logObjectApiName && hts.logFieldApiName == null) {
                    hts.logFieldApiName = d.getName();
                }
            }
        }
        if (hts.accountFieldApiName == null) return null;

        for (Schema.DescribeFieldResult d : fields) {
            Schema.DisplayType t = d.getType();
            if (!d.isCreateable() || !(t == Schema.DisplayType.DATE || t == Schema.DisplayType.DATETIME)) continue;
            if (d.getName() == 'Metric_Date__c' || hts.dateFieldApiName == null) {
                if (hts.dateFieldApiName != 'Metric_Date__c') hts.dateFieldApiName = d.getName();
            }
        }
        if (hts.dateFieldApiName == null) return null;

        for (Schema.DescribeFieldResult d : fields) {
            if (!d.isCreateable() || !d.isAccessible()) continue;
            if (!DataUpdateFormConfigService.isTableColumnType(d.getType())) continue;
            DataUpdateWrapper.SchemaFieldOption opt = new DataUpdateWrapper.SchemaFieldOption();
            opt.apiName      = d.getName();
            opt.label        = d.getLabel();
            opt.type         = String.valueOf(d.getType());
            opt.isRequired   = d.getName() == hts.dateFieldApiName || DataUpdateFormConfigService.isRequiredOnCreate(d);
            opt.isCreateable = true;
            hts.columns.add(opt);
        }
        hts.columns.sort(new SchemaFieldOptionComparator());
        return hts;
    }

    private static Boolean isValidHistoryTableMapping(Data_Update_Form_Field__mdt fm, String targetObjectApiName) {
        try {
            DataUpdateFormConfigService.validateHistoryTable(toTableConfig(fm.Field_API_Name__c,
                fm.History_Target_Object_API_Name__c, fm.History_Target_Account_Field_API_Name__c,
                fm.History_Target_Log_Field_API_Name__c, fm.History_Target_Date_Field_API_Name__c,
                DataUpdateFormConfigService.parseTableColumns(fm.History_Table_Columns__c)), targetObjectApiName);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    private static DataUpdateFormConfigService.FormFieldConfig toTableConfig(String key, String objectApiName,
            String accountField, String logField, String dateField, List<DataUpdateFormConfigService.TableColumn> cols) {
        DataUpdateFormConfigService.FormFieldConfig fc = new DataUpdateFormConfigService.FormFieldConfig();
        fc.fieldApiName                     = key;
        fc.historyMode                      = HISTORY_TABLE;
        fc.historyTargetObjectApiName       = objectApiName;
        fc.historyTargetAccountFieldApiName = accountField;
        fc.historyTargetLogFieldApiName     = logField;
        fc.historyTargetDateFieldApiName    = dateField;
        fc.tableColumns                     = cols;
        return fc;
    }

    private static Boolean isExcludedRelatedObject(String apiName) {
        for (String prefix : RELATED_OBJECT_EXCLUDED_PREFIXES) {
            if (apiName.startsWith(prefix)) return true;
        }
        return false;
    }

    // Target-object picker for the "create form" wizard. Deliberately separate from
    // getCustomObjects() (which only lists __c objects, for the history-mapping picker) since
    // forms commonly target standard objects like Account — changing getCustomObjects() would
    // change that other picker's behavior.
    @AuraEnabled(cacheable=false)
    public static List<DataUpdateWrapper.SchemaObjectOption> getTargetObjectOptions() {
        requireManageForms();
        List<DataUpdateWrapper.SchemaObjectOption> result = new List<DataUpdateWrapper.SchemaObjectOption>();
        Map<String, Schema.SObjectType> allTypes = DataUpdateFormConfigService.globalTypes();
        for (String name : allTypes.keySet()) {
            // System objects (sharing, history, feeds, events, metadata…) are never a form target;
            // skipping them by name first also avoids describing ~800 objects.
            if (isSystemObjectName(name)) continue;
            Schema.DescribeSObjectResult d = allTypes.get(name).getDescribe(SObjectDescribeOptions.DEFERRED);
            if (d.isCustomSetting()) continue;
            if (!d.isAccessible() || !d.isUpdateable() || !d.isQueryable()) continue;

            DataUpdateWrapper.SchemaObjectOption opt = new DataUpdateWrapper.SchemaObjectOption();
            opt.apiName = d.getName();
            opt.label   = d.getLabel();
            result.add(opt);
        }
        result.sort(new SchemaObjectOptionComparator());
        return result;
    }

    private static final List<String> SYSTEM_OBJECT_SUFFIXES = new List<String>{
        'share', 'history', 'feed', 'changeevent', 'tag', '__mdt', '__e', '__x', '__b', '__kav', '__ka', '__votestat',
        '__viewstat', '__datacategoryselection', 'eventrelayfeedback'
    };

    // Lower-case API name of an object that is plumbing, not business data. Our own history
    // objects (Attendance_History__c…) end in "__c", so the "history" suffix never hides them.
    @TestVisible private static Boolean isSystemObjectName(String lowerName) {
        for (String suffix : SYSTEM_OBJECT_SUFFIXES) {
            if (lowerName.endsWith(suffix)) return true;
        }
        return false;
    }

    @AuraEnabled(cacheable=false)
    public static List<DataUpdateWrapper.SchemaFieldOption> getObjectFields(String objectApiName) {
        requireManageForms();
        if (String.isBlank(objectApiName)) {
            throw new AdminException('objectApiName is required.');
        }
        Map<String, Schema.SObjectField> fieldMap = describeFieldMap(objectApiName);

        List<DataUpdateWrapper.SchemaFieldOption> result = new List<DataUpdateWrapper.SchemaFieldOption>();
        for (Schema.SObjectField sf : fieldMap.values()) {
            Schema.DescribeFieldResult d = sf.getDescribe();
            if (!d.isAccessible()) continue;

            DataUpdateWrapper.SchemaFieldOption opt = new DataUpdateWrapper.SchemaFieldOption();
            opt.apiName = d.getName();
            opt.label   = d.getLabel();
            opt.type    = String.valueOf(d.getType());
            opt.isRequired   = DataUpdateFormConfigService.isRequiredOnCreate(d);
            opt.isCreateable = d.isCreateable();
            for (Schema.SObjectType refType : d.getReferenceTo()) {
                opt.referenceToApiNames.add(refType.getDescribe().getName());
            }
            result.add(opt);
        }
        result.sort(new SchemaFieldOptionComparator());
        return result;
    }

    private class SchemaObjectOptionComparator implements Comparator<DataUpdateWrapper.SchemaObjectOption> {
        public Integer compare(DataUpdateWrapper.SchemaObjectOption a, DataUpdateWrapper.SchemaObjectOption b) {
            return String.valueOf(a.label).compareTo(String.valueOf(b.label));
        }
    }

    private class SchemaFieldOptionComparator implements Comparator<DataUpdateWrapper.SchemaFieldOption> {
        public Integer compare(DataUpdateWrapper.SchemaFieldOption a, DataUpdateWrapper.SchemaFieldOption b) {
            return String.valueOf(a.label).compareTo(String.valueOf(b.label));
        }
    }

    // ─── Write (DucFormConfigStore) ─────────────────────────────────────

    @AuraEnabled
    public static String enqueueCreateForm(String label, String targetObjectApiName,
            String identityField1ApiName, String identityField1Comparison,
            String identityField2ApiName, String identityField2Comparison,
            String subjectTemplate, String targetBaseFilterField, String targetBaseFilterValue,
            String ownerQueueDeveloperName, String recordNameFieldApiName,
            String lockFieldApiName, String lockDateFieldApiName, String networkName,
            Boolean allowMultipleSubmissions) {
        requireManageForms();

        if (String.isBlank(label)) {
            throw new AdminException('Label is required.');
        }
        if (String.isBlank(targetObjectApiName)) {
            throw new AdminException('Target object is required.');
        }
        if (String.isBlank(identityField1ApiName)) {
            throw new AdminException('Identity field 1 is required.');
        }
        if (String.isBlank(subjectTemplate)) {
            throw new AdminException('Subject template is required.');
        }
        if (String.isBlank(networkName)) {
            throw new AdminException('Site (Network) is required.');
        }
        if (!bypassNetworkCheckForTest && queryNetworks('SELECT Id FROM Network WHERE Name = :name AND Status = \'Live\' LIMIT 1',
                new Map<String, Object>{ 'name' => networkName }).isEmpty()) {
            throw new AdminException('Unknown or non-live site: ' + networkName);
        }

        Map<String, Schema.SObjectField> fieldMap = describeFieldMap(targetObjectApiName);
        assertFieldExists(fieldMap, identityField1ApiName, 'Identity field 1');
        if (String.isNotBlank(identityField2ApiName)) {
            assertFieldExists(fieldMap, identityField2ApiName, 'Identity field 2');
        }
        if (String.isNotBlank(lockFieldApiName)) {
            assertFieldExists(fieldMap, lockFieldApiName, 'Lock field');
        }
        if (String.isNotBlank(lockDateFieldApiName)) {
            assertFieldExists(fieldMap, lockDateFieldApiName, 'Lock date field');
        }
        if (String.isNotBlank(recordNameFieldApiName)) {
            assertFieldExists(fieldMap, recordNameFieldApiName, 'Record name field');
        }
        if (String.isNotBlank(targetBaseFilterField)) {
            // Same hop-by-hop check the runtime config uses, so a relationship path like the
            // église core form's RecordType.DeveloperName is accepted, not just literal fields.
            try {
                DataUpdateFormConfigService.assertFilterFieldExists(fieldMap, targetBaseFilterField, targetObjectApiName);
            } catch (DataUpdateFormConfigService.FormValidationException e) {
                throw new AdminException('Base filter field ' + targetBaseFilterField + ' does not exist on the target object.');
            }
        }

        String developerName = buildUniqueFormDeveloperName(label);

        Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
        cmd.fullName = FORM_MDT + '.' + developerName;
        cmd.label = truncateLabel(label);

        addValue(cmd, 'Target_Object_API_Name__c', targetObjectApiName);
        addValue(cmd, 'Identity_Field_1_API_Name__c', identityField1ApiName);
        addValue(cmd, 'Identity_Field_1_Comparison__c', String.isNotBlank(identityField1Comparison) ? identityField1Comparison : 'Exact');
        if (String.isNotBlank(identityField2ApiName)) {
            addValue(cmd, 'Identity_Field_2_API_Name__c', identityField2ApiName);
            addValue(cmd, 'Identity_Field_2_Comparison__c', String.isNotBlank(identityField2Comparison) ? identityField2Comparison : 'Normalized_Text');
        }
        addValue(cmd, 'Subject_Template__c', subjectTemplate);
        if (String.isNotBlank(targetBaseFilterField)) {
            addValue(cmd, 'Target_Base_Filter_Field__c', targetBaseFilterField);
        }
        if (String.isNotBlank(targetBaseFilterValue)) {
            addValue(cmd, 'Target_Base_Filter_Value__c', targetBaseFilterValue);
        }
        if (String.isNotBlank(ownerQueueDeveloperName)) {
            addValue(cmd, 'Owner_Queue_DeveloperName__c', ownerQueueDeveloperName);
        }
        addValue(cmd, 'Record_Name_Field_API_Name__c', String.isNotBlank(recordNameFieldApiName) ? recordNameFieldApiName : 'Name');
        if (String.isNotBlank(lockFieldApiName)) {
            addValue(cmd, 'Lock_Field_API_Name__c', lockFieldApiName);
        }
        if (String.isNotBlank(lockDateFieldApiName)) {
            addValue(cmd, 'Lock_Date_Field_API_Name__c', lockDateFieldApiName);
        }
        addValue(cmd, 'Is_Active__c', true);
        // "Multiple submissions" only exists for church forms (tickets grouped by church).
        Boolean multi = allowMultipleSubmissions == true
            && targetObjectApiName == 'Account'
            && targetBaseFilterField == CHURCH_FILTER_FIELD
            && targetBaseFilterValue == CHURCH_RECORD_TYPE;
        addValue(cmd, 'Allow_Duplicate_Open_Requests__c', multi);
        addValue(cmd, 'Network_Name__c', networkName);
        addValue(cmd, 'Is_Core_Form__c', false);

        return deploy(new List<Metadata.CustomMetadata>{ cmd }, developerName);
    }

    // Deleting a form flags the form and all its questions as deleted in DUC_Form_Config__c
    // (DucFormConfigStore): it disappears from the portal, the builder and every picker at once,
    // with plain DML — no Metadata API, no session ID, no metadata rights. Gated behind the
    // Data_Update_Delete_Forms custom permission (Data_Update_Center_Delete_Access). Main (core)
    // forms and forms with open tickets can't be deleted.
    public static final String DELETE_REQUESTED = 'Delete Requested';

    /**
     * Step 1 of a form delete, called by the Form Builder when the admin confirms in its modal: issues a
     * random one-time token (a Delete Requested job row owned by this user). The hidden
     * DataUpdateFormDelete page only deletes when it gets a matching, fresh, unused token — so a
     * link to /apex/DataUpdateFormDelete opened from an email or another site deletes nothing.
     */
    @AuraEnabled
    public static String requestFormDelete(String formDeveloperName) {
        requireManageForms();
        if (!FeatureManagement.checkPermission('Data_Update_Delete_Forms')) {
            throw new AuraHandledException('You do not have permission to delete forms.');
        }
        if (String.isBlank(formDeveloperName)) {
            throw new AuraHandledException('formDeveloperName is required.');
        }
        String token = 'del-' + EncodingUtil.convertToHex(Crypto.generateAesKey(128));
        insert new Data_Update_Form_Deploy_Job__c(
            Job_Id__c = token,
            Status__c = DELETE_REQUESTED,
            Form_Developer_Name__c = formDeveloperName.left(100)
        );
        return token;
    }

    /** Deletes a form right away (Form Builder "Delete" button). */
    @AuraEnabled
    public static void deleteForm(String formDeveloperName) {
        requireManageForms();
        deleteFormRecords(formDeveloperName);
    }

    // Kept for the old DataUpdateFormDelete page (two-step token flow); same delete.
    public static void deleteFormPermanently(String formDeveloperName, String sessionId) {
        deleteFormRecords(formDeveloperName);
    }

    private static void deleteFormRecords(String formDeveloperName) {
        if (!FeatureManagement.checkPermission('Data_Update_Delete_Forms')) {
            throw new AdminException('You do not have permission to delete forms.');
        }
        if (String.isBlank(formDeveloperName)) {
            throw new AdminException('formDeveloperName is required.');
        }
        Data_Update_Form__mdt form = testFormMdt != null ? testFormMdt : DucFormConfigStore.form(formDeveloperName);
        if (form == null) {
            throw new AdminException('Form not found: ' + formDeveloperName);
        }
        if (form.Is_Core_Form__c == true) {
            throw new AdminException('This is a core form and cannot be deleted.');
        }

        Integer openTicketCount = [
            SELECT COUNT()
            FROM Data_Update_Request__c
            WHERE Update_Form_DeveloperName__c = :formDeveloperName
            AND Status__c NOT IN ('Applied', 'Ignored', 'Closed')
        ];
        if (openTicketCount > 0) {
            throw new AdminException('Cannot delete: ' + openTicketCount
                + ' open ticket(s) still reference this form. Close or resolve them first.');
        }
        // Never delete under someone else's publish (it could be this very form).
        DataUpdateWrapper.PublishLockInfo lockState = lockInfo(lockRow(true));
        if (lockState.active && lockState.phase == 'publishing' && !lockState.mine) {
            throw new AdminException('Another publish is in progress. Please wait a moment and try again.');
        }

        try {
            DucFormConfigStore.deleteForm(form.DeveloperName);
        } catch (Exception e) {
            throw new AdminException('Could not delete form: ' + e.getMessage());
        } finally {
            DataUpdateFormConfigService.clearCache(form.DeveloperName);
        }
    }

    /**
     * Marks or unmarks a form as its site's main (core) form — the one that can't be deleted and
     * whose link has no ?form=. One main form per site: turning one on turns the site's previous
     * main form off. Same gate as deleting, since it decides what can be deleted.
     */
    @AuraEnabled
    public static void setCoreForm(String formDeveloperName, Boolean isCore) {
        requireManageForms();
        if (!FeatureManagement.checkPermission('Data_Update_Delete_Forms')) {
            throw new AdminException('You do not have permission to change the main form.');
        }
        Data_Update_Form__mdt form = DucFormConfigStore.form(formDeveloperName);
        if (form == null) {
            throw new AdminException('Form not found: ' + formDeveloperName);
        }
        List<Metadata.CustomMetadata> records = new List<Metadata.CustomMetadata>{
            coreFlagRecord(form.DeveloperName, isCore == true)
        };
        if (isCore == true) {
            for (Data_Update_Form__mdt other : DucFormConfigStore.forms()) {
                if (other.DeveloperName != form.DeveloperName && other.Is_Core_Form__c == true
                        && other.Network_Name__c == form.Network_Name__c) {
                    records.add(coreFlagRecord(other.DeveloperName, false));
                }
            }
        }
        DucFormConfigStore.save(records);
        for (Metadata.CustomMetadata cmd : records) {
            DataUpdateFormConfigService.clearCache(cmd.fullName.substringAfter('.'));
        }
    }

    private static Metadata.CustomMetadata coreFlagRecord(String developerName, Boolean isCore) {
        Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
        cmd.fullName = DucFormConfigStore.FORM_TYPE + '.' + developerName;
        addValue(cmd, 'Is_Core_Form__c', isCore);
        return cmd;
    }

    // Lets the LWC hide/disable the Delete button for users who lack Data_Update_Delete_Forms —
    // the real enforcement is server-side in deleteFormPermanently(); this is UX only.
    @AuraEnabled(cacheable=true)
    public static Boolean getCanDeleteForms() {
        return FeatureManagement.checkPermission('Data_Update_Delete_Forms');
    }

    // ─── Visual form builder (dataUpdateFormBuilder) ────────────────────
    //
    // The builder edits a whole draft of the form client-side (order, sections, texts, help,
    // added/removed questions, portal screen texts) and publishes it in ONE metadata deploy, so
    // the public form never shows a half-applied state. Removing a question only deactivates its
    // record (tickets that arrived with it keep showing it in review); adding a question that was
    // removed before reactivates that same record instead of creating a duplicate.

    public class BuilderQuestion {
        public String  developerName;
        public String  fieldApiName;
        public String  labelFr;
        public String  labelEn;
        public String  helpFr;
        public String  helpEn;
        public String  sectionLabelFr;
        public String  sectionLabelEn;
        public String  inputType;
        public Boolean isRequired;
        public Boolean sameRowAsPrevious;
        public Boolean isHidden;
        public Boolean isReadOnly;
        public String  historyMode;
        public String  historyTargetObjectApiName;
        public String  historyTargetValueFieldApiName;
        public String  historyTargetDateFieldApiName;
        public String  historyTargetAccountFieldApiName;
        public String  historyTargetLogFieldApiName;
        public String  historyDateSourceFieldApiName;
        // Place among the form's questions and tables (0-based); null keeps the list order.
        public Integer position;
    }

    /** One History_Table of the draft (églises): object, FR/EN title + optional help, checked columns. */
    public class BuilderTable {
        public String  developerName;
        public String  objectApiName;
        public String  titleFr;
        public String  titleEn;
        public String  helpFr;
        public String  helpEn;
        public Boolean isHidden;
        public List<DataUpdateFormConfigService.TableColumn> columns;
        // How people enter the lines on the public form: Fields | Excel | Both (else Excel).
        public String  inputMode;
        // Where it sits on the form, like a question: its section and place (0-based).
        public String  sectionLabelFr;
        public String  sectionLabelEn;
        public Integer position;
    }

    public class BuilderDraft {
        public DataUpdateWrapper.PortalTexts portalTexts;
        public List<BuilderQuestion> questions;
        public List<BuilderTable> tables;
        // "Multiple submissions" switch (church forms only); null = leave as published.
        public Boolean allowMultipleSubmissions;
    }

    private static final Set<String> BUILDER_INPUT_TYPES = new Set<String>{
        'Text', 'Email', 'Phone', 'Number', 'Date', 'Checkbox', 'Picklist'
    };
    private static final Set<String> TABLE_INPUT_MODES = new Set<String>{ 'Fields', 'Excel', 'Both' };
    private static final Integer LABEL_MAX_LENGTH = 120;
    private static final Integer LONG_TEXT_MAX_LENGTH = 255;

    @AuraEnabled(cacheable=false)
    public static DataUpdateWrapper.BuilderFormInfo getBuilderForm(String formDeveloperName) {
        requireManageForms();
        if (String.isBlank(formDeveloperName)) {
            throw new AdminException('formDeveloperName is required.');
        }
        Data_Update_Form__mdt form = getFullFormOrThrow(formDeveloperName);
        DataUpdateWrapper.BuilderFormInfo info = new DataUpdateWrapper.BuilderFormInfo();
        info.developerName         = form.DeveloperName;
        info.label                 = form.MasterLabel;
        info.targetObjectApiName   = form.Target_Object_API_Name__c;
        info.identityField2ApiName = form.Identity_Field_2_API_Name__c;
        info.portalTexts           = DataUpdateFormConfigService.toPortalTexts(form);
        info.isChurchForm          = isChurchForm(form);
        info.allowMultipleSubmissions = form.Allow_Duplicate_Open_Requests__c == true;
        return info;
    }

    @AuraEnabled
    public static String enqueuePublishBuilder(String formDeveloperName, String draftJson) {
        requireManageForms();
        if (String.isBlank(formDeveloperName) || String.isBlank(draftJson)) {
            throw new AdminException('formDeveloperName and draftJson are required.');
        }
        BuilderDraft draft;
        try {
            draft = (BuilderDraft) JSON.deserialize(draftJson, BuilderDraft.class);
        } catch (Exception e) {
            throw new AdminException('Invalid builder draft: ' + e.getMessage());
        }
        if (draft == null) {
            throw new AdminException('The form needs at least one question.');
        }
        if (draft.questions == null) draft.questions = new List<BuilderQuestion>();
        // A church form may hold only history tables: a shown table counts as something to fill.
        Boolean anyVisible = false;
        if (draft.tables != null) {
            for (BuilderTable bt : draft.tables) {
                if (bt != null && bt.isHidden != true) anyVisible = true;
            }
        }
        if (draft.questions.isEmpty() && !anyVisible) {
            throw new AdminException('The form needs at least one question.');
        }
        for (BuilderQuestion q : draft.questions) {
            if (q != null && q.isHidden != true && q.isReadOnly != true) anyVisible = true;
        }
        if (!anyVisible) {
            throw new AdminException('At least one question must stay editable on the form.');
        }

        Data_Update_Form__mdt form = getFullFormOrThrow(formDeveloperName);
        Map<String, Schema.SObjectField> fieldMap = describeFieldMap(form.Target_Object_API_Name__c);

        Map<String, Data_Update_Form_Field__mdt> byDevName = new Map<String, Data_Update_Form_Field__mdt>();
        Map<String, Data_Update_Form_Field__mdt> byKey = new Map<String, Data_Update_Form_Field__mdt>();
        for (Data_Update_Form_Field__mdt fm : getFieldRecords(formDeveloperName)) {
            byDevName.put(fm.DeveloperName, fm);
            if (String.isNotBlank(fm.Field_API_Name__c)) byKey.put(fm.Field_API_Name__c.toLowerCase(), fm);
        }
        Set<String> takenDevNames = DucFormConfigStore.usedDeveloperNames(FIELD_MDT);

        List<Metadata.CustomMetadata> batch = new List<Metadata.CustomMetadata>();
        Set<String> keptDevNames = new Set<String>();
        Set<String> seenKeys = new Set<String>();
        Integer order = DISPLAY_ORDER_STEP;
        for (BuilderQuestion q : draft.questions) {
            validateBuilderQuestionText(q);
            Data_Update_Form_Field__mdt fm = null;
            if (String.isNotBlank(q.developerName)) {
                fm = byDevName.get(q.developerName);
                if (fm == null) {
                    throw new AdminException('Field record not found in this form: ' + q.developerName);
                }
            }
            String key = fm != null ? fm.Field_API_Name__c : resolveNewQuestionKey(q, form, fieldMap);
            if (fm == null) fm = byKey.get(key.toLowerCase());
            if (!seenKeys.add(key.toLowerCase())) {
                throw new AdminException('This question appears twice in the form: ' + key);
            }

            Metadata.CustomMetadata cmd;
            Boolean changed;
            if (fm != null) {
                keptDevNames.add(fm.DeveloperName);
                cmd = fullRecordToMetadata(fm);
                changed = applyBuilderValues(cmd, q, orderFor(q.position, order));
                changed |= applyBuilderHistory(cmd, q, fm.History_Mode__c, form);
            } else {
                String rawField = key.replace('.', '_').removeEnd('__c').replace('__c_', '_');
                String devName = appendUniqueSuffix(sanitizeDeveloperName(formDeveloperName + '_' + rawField), takenDevNames);
                takenDevNames.add(devName.toLowerCase());
                Boolean historyOnly = q.historyMode == HISTORY_ONLY;
                Boolean historize = q.historyMode == 'Historize';
                if (historize) validateBuilderHistorize(q, form);
                Boolean mapped = historyOnly || historize;
                cmd = new Metadata.CustomMetadata();
                cmd.fullName = FIELD_MDT + '.' + devName;
                cmd.label = truncateLabel(formDeveloperName + ' - ' + key);
                addValue(cmd, 'Form__c', formDeveloperName);
                addValue(cmd, 'Field_API_Name__c', key);
                addValue(cmd, 'History_Mode__c', historyOnly ? HISTORY_ONLY : (historize ? 'Historize' : 'Replace'));
                addValue(cmd, 'History_Target_Object_API_Name__c', mapped ? q.historyTargetObjectApiName : null);
                addValue(cmd, 'History_Target_Value_Field_API_Name__c', mapped ? q.historyTargetValueFieldApiName : null);
                addValue(cmd, 'History_Target_Date_Field_API_Name__c', mapped ? blankToNull(q.historyTargetDateFieldApiName) : null);
                addValue(cmd, 'History_Target_Account_Field_API_Name__c', mapped ? q.historyTargetAccountFieldApiName : null);
                addValue(cmd, 'History_Target_Log_Field_API_Name__c', mapped ? blankToNull(q.historyTargetLogFieldApiName) : null);
                addValue(cmd, 'History_Date_Source_Field_API_Name__c', historize ? blankToNull(q.historyDateSourceFieldApiName) : null);
                applyBuilderValues(cmd, q, orderFor(q.position, order));
                changed = true;
            }
            if (changed) batch.add(cmd);
            order += DISPLAY_ORDER_STEP;
        }

        // History tables (church forms only) — placed among the questions by their position.
        if (draft.tables != null && !draft.tables.isEmpty()) {
            if (!isChurchForm(form)) {
                throw new AdminException('History tables are only available on church forms.');
            }
            for (BuilderTable bt : draft.tables) {
                Metadata.CustomMetadata cmd = buildTableMetadata(bt, form, byDevName, byKey, takenDevNames, seenKeys,
                    bt == null ? order : orderFor(bt.position, order));
                keptDevNames.add(cmd.fullName.substringAfter('.'));
                batch.add(cmd);
                order += DISPLAY_ORDER_STEP;
            }
        }

        // Questions left out of the draft are deactivated, never deleted (see section header).
        for (Data_Update_Form_Field__mdt fm : byDevName.values()) {
            if (keptDevNames.contains(fm.DeveloperName) || fm.Is_Active__c != true) continue;
            Metadata.CustomMetadata cmd = fullRecordToMetadata(fm);
            setValue(cmd, 'Is_Active__c', false);
            setValue(cmd, 'Is_Hidden__c', false);
            batch.add(cmd);
        }

        if (draft.allowMultipleSubmissions == true && !isChurchForm(form)) {
            throw new AdminException('Multiple submissions are only available on church forms.');
        }
        Metadata.CustomMetadata formCmd = buildPortalTextsMetadata(form, draft.portalTexts, draft.allowMultipleSubmissions);
        if (formCmd != null) batch.add(formCmd);

        if (batch.isEmpty()) {
            throw new AdminException('No changes to publish.');
        }
        return deploy(batch, formDeveloperName);
    }

    // Builder positions are 0-based places on the form; without one the running order is kept.
    @TestVisible private static Integer orderFor(Integer position, Integer fallback) {
        return position != null && position >= 0 ? (position + 1) * DISPLAY_ORDER_STEP : fallback;
    }

    private static Metadata.CustomMetadata buildTableMetadata(
        BuilderTable bt, Data_Update_Form__mdt form,
        Map<String, Data_Update_Form_Field__mdt> byDevName, Map<String, Data_Update_Form_Field__mdt> byKey,
        Set<String> takenDevNames, Set<String> seenKeys, Integer order
    ) {
        if (bt == null || String.isBlank(bt.objectApiName)) {
            throw new AdminException('Every history table needs its object.');
        }
        if (String.isBlank(bt.titleFr) || String.isBlank(bt.titleEn)) {
            throw new AdminException('Every history table needs its title in French and English.');
        }
        assertMaxLength(bt.titleFr, LABEL_MAX_LENGTH, 'Table title (FR)');
        assertMaxLength(bt.titleEn, LABEL_MAX_LENGTH, 'Table title (EN)');
        assertMaxLength(bt.helpFr, LONG_TEXT_MAX_LENGTH, 'Table help (FR)');
        assertMaxLength(bt.helpEn, LONG_TEXT_MAX_LENGTH, 'Table help (EN)');

        // Lookups + date column are never trusted from the client — detected again here.
        DataUpdateWrapper.HistoryTableSchema hts = detectHistoryTableSchema(bt.objectApiName, form.Target_Object_API_Name__c);
        if (hts == null) {
            throw new AdminException(bt.objectApiName + ' cannot be used as a history table (needs a lookup to '
                + form.Target_Object_API_Name__c + ' and a date field).');
        }
        String key = DataUpdateFormConfigService.buildHistoryTableKey(hts.objectApiName);
        if (!seenKeys.add(key.toLowerCase())) {
            throw new AdminException('This history table appears twice in the form: ' + hts.objectLabel);
        }
        List<DataUpdateFormConfigService.TableColumn> cols = new List<DataUpdateFormConfigService.TableColumn>();
        for (DataUpdateFormConfigService.TableColumn c : bt.columns == null ? new List<DataUpdateFormConfigService.TableColumn>() : bt.columns) {
            if (c == null || String.isBlank(c.f)) continue;
            assertMaxLength(c.fr, LABEL_MAX_LENGTH, 'Column header (FR) of ' + c.f);
            assertMaxLength(c.en, LABEL_MAX_LENGTH, 'Column header (EN) of ' + c.f);
            DataUpdateFormConfigService.TableColumn clean = new DataUpdateFormConfigService.TableColumn();
            clean.f  = c.f;
            clean.fr = String.isBlank(c.fr) ? null : c.fr.trim();
            clean.en = String.isBlank(c.en) ? null : c.en.trim();
            cols.add(clean);
        }
        try {
            DataUpdateFormConfigService.validateHistoryTable(toTableConfig(key, hts.objectApiName,
                hts.accountFieldApiName, hts.logFieldApiName, hts.dateFieldApiName, cols),
                form.Target_Object_API_Name__c);
        } catch (DataUpdateFormConfigService.FormValidationException e) {
            throw new AdminException(e.getMessage());
        }

        Data_Update_Form_Field__mdt fm = String.isNotBlank(bt.developerName) ? byDevName.get(bt.developerName) : null;
        if (fm == null) fm = byKey.get(key.toLowerCase());
        Metadata.CustomMetadata cmd;
        if (fm != null) {
            cmd = fullRecordToMetadata(fm);
        } else {
            String devName = appendUniqueSuffix(
                sanitizeDeveloperName(form.DeveloperName + '_' + hts.objectApiName.removeEnd('__c') + '_Table'), takenDevNames);
            takenDevNames.add(devName.toLowerCase());
            cmd = new Metadata.CustomMetadata();
            cmd.fullName = FIELD_MDT + '.' + devName;
            cmd.label = truncateLabel(form.DeveloperName + ' - ' + key);
            addValue(cmd, 'Form__c', form.DeveloperName);
        }
        setValue(cmd, 'Field_API_Name__c', key);
        setValue(cmd, 'Label_FR__c', bt.titleFr.trim());
        setValue(cmd, 'Label_EN__c', bt.titleEn.trim());
        setValue(cmd, 'Help_FR__c', String.isBlank(bt.helpFr) ? null : bt.helpFr.trim());
        setValue(cmd, 'Help_EN__c', String.isBlank(bt.helpEn) ? null : bt.helpEn.trim());
        setValue(cmd, 'Display_Order__c', order);
        setValue(cmd, 'Section_Label_FR__c', bt.isHidden == true ? null : blankToNull(bt.sectionLabelFr));
        setValue(cmd, 'Section_Label_EN__c', bt.isHidden == true ? null : blankToNull(bt.sectionLabelEn));
        setValue(cmd, 'Input_Type__c', 'Text');
        setValue(cmd, 'Is_Required__c', false);
        setValue(cmd, 'Is_Active__c', true);
        setValue(cmd, 'Is_Hidden__c', bt.isHidden == true);
        setValue(cmd, 'Is_Read_Only__c', false);
        setValue(cmd, 'Same_Row_As_Previous__c', false);
        setValue(cmd, 'History_Mode__c', HISTORY_TABLE);
        setValue(cmd, 'History_Target_Object_API_Name__c', hts.objectApiName);
        setValue(cmd, 'History_Target_Value_Field_API_Name__c', null);
        setValue(cmd, 'History_Target_Date_Field_API_Name__c', hts.dateFieldApiName);
        setValue(cmd, 'History_Target_Account_Field_API_Name__c', hts.accountFieldApiName);
        setValue(cmd, 'History_Target_Log_Field_API_Name__c', hts.logFieldApiName);
        setValue(cmd, 'History_Date_Source_Field_API_Name__c', null);
        setValue(cmd, 'History_Table_Columns__c', JSON.serialize(cols, true));
        setValue(cmd, 'History_Table_Input_Mode__c', TABLE_INPUT_MODES.contains(bt.inputMode) ? bt.inputMode : 'Excel');
        return cmd;
    }

    private static void validateBuilderQuestionText(BuilderQuestion q) {
        if (q == null || String.isBlank(q.labelFr) || String.isBlank(q.labelEn)) {
            throw new AdminException('Every question needs its text in French and English.');
        }
        String name = q.labelFr.trim();
        assertMaxLength(q.labelFr, LABEL_MAX_LENGTH, 'Question text (FR) of "' + name + '"');
        assertMaxLength(q.labelEn, LABEL_MAX_LENGTH, 'Question text (EN) of "' + name + '"');
        assertMaxLength(q.sectionLabelFr, LABEL_MAX_LENGTH, 'Section title (FR) of "' + name + '"');
        assertMaxLength(q.sectionLabelEn, LABEL_MAX_LENGTH, 'Section title (EN) of "' + name + '"');
        assertMaxLength(q.helpFr, LONG_TEXT_MAX_LENGTH, 'Help (FR) of "' + name + '"');
        assertMaxLength(q.helpEn, LONG_TEXT_MAX_LENGTH, 'Help (EN) of "' + name + '"');
        if (String.isNotBlank(q.inputType) && !BUILDER_INPUT_TYPES.contains(q.inputType)) {
            throw new AdminException('Unknown question type: ' + q.inputType);
        }
    }

    private static void assertMaxLength(String value, Integer maxLength, String what) {
        if (value != null && value.trim().length() > maxLength) {
            throw new AdminException(what + ' is too long (max ' + maxLength + ' characters).');
        }
    }

    // Key of a question that has no catalog record yet: the target field's API name, or for a
    // related-object (History_Only) question the HistoryObject.ValueField key of its mapping.
    private static String resolveNewQuestionKey(BuilderQuestion q, Data_Update_Form__mdt form, Map<String, Schema.SObjectField> fieldMap) {
        if (q.historyMode == HISTORY_ONLY) {
            String key = DataUpdateFormConfigService.buildHistoryOnlyKey(q.historyTargetObjectApiName, q.historyTargetValueFieldApiName);
            if (key.length() > 80) {
                throw new AdminException('History object + value field names are too long (max 80 characters together).');
            }
            validateHistoryOnlyInput(q.historyTargetObjectApiName, q.historyTargetValueFieldApiName,
                blankToNull(q.historyTargetDateFieldApiName), q.historyTargetAccountFieldApiName,
                blankToNull(q.historyTargetLogFieldApiName), form.Target_Object_API_Name__c);
            return key;
        }
        if (String.isNotBlank(q.historyMode) && q.historyMode != 'Replace' && q.historyMode != 'Historize') {
            throw new AdminException('Unknown history mode for a new question: ' + q.historyMode);
        }
        if (String.isBlank(q.fieldApiName)) {
            throw new AdminException('A new question has no field.');
        }
        assertFieldExists(fieldMap, q.fieldApiName, 'Field');
        if (q.fieldApiName.equalsIgnoreCase(form.Lock_Field_API_Name__c)
            || q.fieldApiName.equalsIgnoreCase(form.Lock_Date_Field_API_Name__c)) {
            throw new AdminException('The lock fields cannot be put on the public form.');
        }
        return fieldMap.get(q.fieldApiName.toLowerCase()).getDescribe().getName();
    }

    // Writes the builder-editable values onto a record and reports whether any of them changed.
    // History mode/targets are handled apart, in applyBuilderHistory().
    private static Boolean applyBuilderValues(Metadata.CustomMetadata cmd, BuilderQuestion q, Integer order) {
        Boolean changed = false;
        changed |= setIfChanged(cmd, 'Label_FR__c', q.labelFr.trim());
        changed |= setIfChanged(cmd, 'Label_EN__c', q.labelEn.trim());
        changed |= setIfChanged(cmd, 'Help_FR__c', blankToNull(q.helpFr));
        changed |= setIfChanged(cmd, 'Help_EN__c', blankToNull(q.helpEn));
        changed |= setIfChanged(cmd, 'Section_Label_FR__c', blankToNull(q.sectionLabelFr));
        changed |= setIfChanged(cmd, 'Section_Label_EN__c', blankToNull(q.sectionLabelEn));
        changed |= setIfChanged(cmd, 'Input_Type__c', String.isBlank(q.inputType) ? 'Text' : q.inputType);
        changed |= setIfChanged(cmd, 'Is_Required__c', q.isRequired == true);
        changed |= setIfChanged(cmd, 'Same_Row_As_Previous__c', q.sameRowAsPrevious == true);
        changed |= setIfChanged(cmd, 'Is_Hidden__c', q.isHidden == true);
        changed |= setIfChanged(cmd, 'Is_Read_Only__c', q.isHidden != true && q.isReadOnly == true);
        changed |= setIfChanged(cmd, 'Is_Active__c', true);
        changed |= setIfChanged(cmd, 'Display_Order__c', order);
        return changed;
    }

    // "Keep history" on an account-field question: Replace <-> Historize, with its mapping.
    // History_Only questions keep their mapping (their key IS the mapping), and a question can't
    // switch in or out of History_Only — same rule as enqueueUpdateHistoryMapping().
    private static Boolean applyBuilderHistory(Metadata.CustomMetadata cmd, BuilderQuestion q, String currentMode, Data_Update_Form__mdt form) {
        Boolean wasHistoryOnly = currentMode == HISTORY_ONLY;
        if (q.historyMode == null) return false;
        if (wasHistoryOnly != (q.historyMode == HISTORY_ONLY)) {
            throw new AdminException('A question cannot be switched into or out of History Only — add a new question instead.');
        }
        if (wasHistoryOnly) return false;
        Boolean historize = q.historyMode == 'Historize';
        if (!historize && q.historyMode != 'Replace') {
            throw new AdminException('Unknown history mode: ' + q.historyMode);
        }
        if (historize) validateBuilderHistorize(q, form);
        Boolean changed = false;
        changed |= setIfChanged(cmd, 'History_Mode__c', historize ? 'Historize' : 'Replace');
        changed |= setIfChanged(cmd, 'History_Target_Object_API_Name__c', historize ? q.historyTargetObjectApiName : null);
        changed |= setIfChanged(cmd, 'History_Target_Value_Field_API_Name__c', historize ? q.historyTargetValueFieldApiName : null);
        changed |= setIfChanged(cmd, 'History_Target_Date_Field_API_Name__c', historize ? blankToNull(q.historyTargetDateFieldApiName) : null);
        changed |= setIfChanged(cmd, 'History_Target_Account_Field_API_Name__c', historize ? q.historyTargetAccountFieldApiName : null);
        changed |= setIfChanged(cmd, 'History_Target_Log_Field_API_Name__c', historize ? blankToNull(q.historyTargetLogFieldApiName) : null);
        changed |= setIfChanged(cmd, 'History_Date_Source_Field_API_Name__c', historize ? blankToNull(q.historyDateSourceFieldApiName) : null);
        return changed;
    }

    private static void validateBuilderHistorize(BuilderQuestion q, Data_Update_Form__mdt form) {
        validateHistoryMappingInput(q.historyTargetObjectApiName, q.historyTargetValueFieldApiName,
            blankToNull(q.historyTargetDateFieldApiName), q.historyTargetAccountFieldApiName,
            blankToNull(q.historyTargetLogFieldApiName), blankToNull(q.historyDateSourceFieldApiName),
            form.Target_Object_API_Name__c);
    }

    @TestVisible private static Boolean setIfChanged(Metadata.CustomMetadata cmd, String field, Object value) {
        Object current = null;
        Boolean found = false;
        for (Metadata.CustomMetadataValue v : cmd.values) {
            if (v.field == field) {
                current = v.value;
                found = true;
                break;
            }
        }
        setValue(cmd, field, value);
        if (!found) return true;
        // Compared as text so Decimal 10.0 read from the record equals Integer 10 from the draft;
        // .equals() rather than == (case-insensitive) so a capitalisation fix counts as a change.
        String before = current == null ? null : String.valueOf(current);
        String after = value == null ? null : String.valueOf(value);
        if (current instanceof Decimal) before = String.valueOf(((Decimal) current).intValue());
        if (before == null || after == null) return before != after;
        return !before.equals(after);
    }

    private static final List<String> PORTAL_TEXT_FIELDS = new List<String>{
        'Portal_Lookup_Title_FR__c', 'Portal_Lookup_Title_EN__c',
        'Portal_Lookup_Subtitle_FR__c', 'Portal_Lookup_Subtitle_EN__c',
        'Portal_Id_Help_FR__c', 'Portal_Id_Help_EN__c',
        'Portal_Form_Title_FR__c', 'Portal_Form_Title_EN__c',
        'Portal_Form_Subtitle_FR__c', 'Portal_Form_Subtitle_EN__c'
    };

    // Full rewrite of the form record (every field re-supplied, see class header) carrying the
    // new portal texts — or null when none of them changed, so the form record isn't redeployed.
    // allowMulti (null = unchanged) also rewrites the record when it differs from the published flag.
    private static Metadata.CustomMetadata buildPortalTextsMetadata(Data_Update_Form__mdt form, DataUpdateWrapper.PortalTexts t, Boolean allowMulti) {
        Boolean currentMulti = form.Allow_Duplicate_Open_Requests__c == true;
        Boolean multi = allowMulti == null ? currentMulti : allowMulti;
        if (t == null) {
            if (multi == currentMulti) return null;
            t = DataUpdateFormConfigService.toPortalTexts(form);
        }
        Map<String, String> desired = new Map<String, String>{
            'Portal_Lookup_Title_FR__c'    => t.lookupTitleFr,    'Portal_Lookup_Title_EN__c'    => t.lookupTitleEn,
            'Portal_Lookup_Subtitle_FR__c' => t.lookupSubtitleFr, 'Portal_Lookup_Subtitle_EN__c' => t.lookupSubtitleEn,
            'Portal_Id_Help_FR__c'         => t.idHelpFr,         'Portal_Id_Help_EN__c'         => t.idHelpEn,
            'Portal_Form_Title_FR__c'      => t.formTitleFr,      'Portal_Form_Title_EN__c'      => t.formTitleEn,
            'Portal_Form_Subtitle_FR__c'   => t.formSubtitleFr,   'Portal_Form_Subtitle_EN__c'   => t.formSubtitleEn
        };
        Boolean changed = false;
        for (String field : PORTAL_TEXT_FIELDS) {
            String value = blankToNull(desired.get(field));
            assertMaxLength(value, LONG_TEXT_MAX_LENGTH, 'Screen text ' + field);
            String current = blankToNull((String) form.get(field));
            if (current == null ? value != null : !current.equals(value)) changed = true;
        }
        String styles = normalizeTextStyles(t.stylesJson);
        String currentStyles = blankToNull(form.Portal_Text_Styles__c);
        if (currentStyles == null ? styles != null : !currentStyles.equals(styles)) changed = true;
        String blocks = normalizeBlocks(t.blocksJson);
        String currentBlocks = blankToNull(form.Portal_Blocks__c);
        if (currentBlocks == null ? blocks != null : !currentBlocks.equals(blocks)) changed = true;
        String appearance = normalizeAppearance(t.appearanceJson);
        String currentAppearance = blankToNull(form.Portal_Appearance__c);
        if (currentAppearance == null ? appearance != null : !currentAppearance.equals(appearance)) changed = true;
        String messages = normalizeMessages(t.messagesJson);
        String currentMessages = blankToNull(form.Portal_Messages__c);
        if (currentMessages == null ? messages != null : !currentMessages.equals(messages)) changed = true;
        if (multi != currentMulti) changed = true;
        if (!changed) return null;

        Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
        cmd.fullName = FORM_MDT + '.' + form.DeveloperName;
        cmd.label = String.isNotBlank(form.MasterLabel) ? form.MasterLabel : truncateLabel(form.DeveloperName);
        for (String field : new List<String>{
            'Target_Object_API_Name__c', 'Target_Base_Filter_Field__c', 'Target_Base_Filter_Value__c',
            'Identity_Field_1_API_Name__c', 'Identity_Field_1_Comparison__c',
            'Identity_Field_2_API_Name__c', 'Identity_Field_2_Comparison__c',
            'Owner_Queue_DeveloperName__c', 'Subject_Template__c', 'Record_Name_Field_API_Name__c',
            'Lock_Field_API_Name__c', 'Lock_Date_Field_API_Name__c', 'Network_Name__c'
        }) {
            addValue(cmd, field, form.get(field));
        }
        addValue(cmd, 'Allow_Duplicate_Open_Requests__c', multi);
        addValue(cmd, 'Is_Active__c', form.Is_Active__c == true);
        addValue(cmd, 'Is_Core_Form__c', form.Is_Core_Form__c == true);
        for (String field : PORTAL_TEXT_FIELDS) {
            addValue(cmd, field, blankToNull(desired.get(field)));
        }
        addValue(cmd, 'Portal_Text_Styles__c', styles);
        addValue(cmd, 'Portal_Blocks__c', blocks);
        addValue(cmd, 'Portal_Appearance__c', appearance);
        addValue(cmd, 'Portal_Messages__c', messages);
        return cmd;
    }

    // Must match MESSAGE keys of lwc/dataUpdateFormBuilder (TEXT_DEFS, screen 'messages').
    @TestVisible private static final List<String> PORTAL_MESSAGE_KEYS = new List<String>{
        'lockedTitle', 'lockedMessage', 'pendingTitle', 'pendingMessage', 'confirmTitle', 'confirmMessage', 'errNoChanges'
    };
    private static final Integer MESSAGE_MAX_LENGTH = 1000;

    // Custom portal messages as canonical JSON (fixed key order, trimmed, blanks dropped) so the
    // redeploy check compares like with like; null when every message keeps its standard text.
    // Plain text only: the portal renders it as text, never HTML.
    @TestVisible private static String normalizeMessages(String messagesJson) {
        String value = blankToNull(messagesJson);
        if (value == null) return null;
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(value);
        } catch (Exception e) {
            throw new AdminException('Invalid portal messages.');
        }
        if (!(parsed instanceof Map<String, Object>)) {
            throw new AdminException('Invalid portal messages.');
        }
        Map<String, Object> input = (Map<String, Object>) parsed;
        Map<String, Object> out = new Map<String, Object>();
        List<String> order = new List<String>();
        for (String key : PORTAL_MESSAGE_KEYS) {
            Object raw = input.get(key);
            if (!(raw instanceof Map<String, Object>)) continue;
            Map<String, Object> langs = (Map<String, Object>) raw;
            Map<String, Object> entry = new Map<String, Object>();
            for (String lang : new List<String>{ 'fr', 'en' }) {
                Object v = langs.get(lang);
                String text = v instanceof String ? blankToNull((String) v) : null;
                if (text == null) continue;
                assertMaxLength(text, MESSAGE_MAX_LENGTH, 'Message ' + key);
                entry.put(lang, text);
            }
            if (!entry.isEmpty()) {
                out.put(key, entry);
                order.add(key);
            }
        }
        if (out.isEmpty()) return null;
        // JSON.serialize of a Map has no guaranteed key order: build it by hand in a fixed order.
        List<String> parts = new List<String>();
        for (String key : order) {
            Map<String, Object> entry = (Map<String, Object>) out.get(key);
            List<String> langParts = new List<String>();
            for (String lang : new List<String>{ 'fr', 'en' }) {
                if (entry.containsKey(lang)) langParts.add(JSON.serialize(lang) + ':' + JSON.serialize(entry.get(lang)));
            }
            parts.add(JSON.serialize(key) + ':{' + String.join(langParts, ',') + '}');
        }
        return '{' + String.join(parts, ',') + '}';
    }

    // Must match FONTS in lwc/dataUpdateAppearance — the portal maps each key to a fixed system
    // font stack, so nothing but these keys (and #rrggbb colors) ever reaches its inline style.
    @TestVisible private static final Set<String> APPEARANCE_FONTS = new Set<String>{
        'standard', 'modern', 'verdana', 'trebuchet', 'georgia', 'palatino'
    };
    private static final List<String> APPEARANCE_COLOR_KEYS = new List<String>{ 'question', 'section', 'accent' };

    // Uniform look of one form (font + 3 colors), as canonical JSON in a fixed key order so the
    // builder's change detection and the redeploy check above compare like with like. Unknown
    // keys are dropped; null when nothing is set (= the standard look).
    @TestVisible private static String normalizeAppearance(String appearanceJson) {
        String value = blankToNull(appearanceJson);
        if (value == null) return null;
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(value);
        } catch (Exception e) {
            throw new AdminException('Invalid appearance.');
        }
        if (!(parsed instanceof Map<String, Object>)) {
            throw new AdminException('Invalid appearance.');
        }
        Map<String, Object> raw = (Map<String, Object>) parsed;
        Map<String, String> clean = new Map<String, String>();
        Object font = raw.get('font');
        if (font != null && String.isNotBlank(String.valueOf(font))) {
            String key = String.valueOf(font).trim().toLowerCase();
            if (!APPEARANCE_FONTS.contains(key)) throw new AdminException('Invalid appearance font: ' + font);
            if (key != 'standard') clean.put('font', key);
        }
        for (String colorKey : APPEARANCE_COLOR_KEYS) {
            Object color = raw.get(colorKey);
            if (color == null || String.isBlank(String.valueOf(color))) continue;
            String hex = String.valueOf(color).trim().toLowerCase();
            if (!Pattern.matches('^#[0-9a-f]{6}$', hex)) {
                throw new AdminException('Invalid appearance color for ' + colorKey + ': ' + color);
            }
            clean.put(colorKey, hex);
        }
        if (clean.isEmpty()) return null;
        List<String> parts = new List<String>();
        for (String key : new List<String>{ 'font', 'question', 'section', 'accent' }) {
            if (clean.containsKey(key)) parts.add(JSON.serialize(key) + ':' + JSON.serialize(clean.get(key)));
        }
        return '{' + String.join(parts, ',') + '}';
    }

    private static final Integer TEXT_STYLES_MAX_LENGTH = 32000;

    // The palette's JSON must at least be a JSON object; it's only ever rendered as inline styles
    // picked from fixed values on the portal (dataUpdateTextStyle), never as raw HTML.
    @TestVisible private static String normalizeTextStyles(String stylesJson) {
        String value = blankToNull(stylesJson);
        if (value == null) return null;
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(value);
        } catch (Exception e) {
            throw new AdminException('Invalid screen text styles.');
        }
        if (!(parsed instanceof Map<String, Object>)) {
            throw new AdminException('Invalid screen text styles.');
        }
        if (((Map<String, Object>) parsed).isEmpty()) return null;
        assertMaxLength(value, TEXT_STYLES_MAX_LENGTH, 'Screen text styles');
        return value;
    }

    private static final Integer BLOCKS_MAX_LENGTH = 32000;
    private static final Integer BLOCKS_MAX_COUNT = 80;
    private static final Set<String> BLOCK_TYPES = new Set<String>{
        'title', 'text', 'image', 'banner', 'logo', 'video', 'divider', 'spacer'
    };
    // Images must be Salesforce Files (public ContentDistribution links) and videos YouTube/Vimeo
    // (the sites' CSP Trusted Sites DataUpdate_Video_YouTube / DataUpdate_Video_Vimeo allow those frames).
    private static final List<String> BLOCK_URL_HOST_SUFFIXES = new List<String>{
        'force.com', 'salesforce.com', 'youtube.com', 'youtu.be', 'vimeo.com'
    };

    // The Tools tab's blocks must be a JSON array of objects with a known type; any URL must be
    // https on an allowed host. The portal renders them as text/<img>/<iframe>, never raw HTML.
    @TestVisible private static String normalizeBlocks(String blocksJson) {
        String value = blankToNull(blocksJson);
        if (value == null) return null;
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(value);
        } catch (Exception e) {
            throw new AdminException('Invalid design blocks.');
        }
        if (!(parsed instanceof List<Object>)) {
            throw new AdminException('Invalid design blocks.');
        }
        List<Object> blocks = (List<Object>) parsed;
        if (blocks.isEmpty()) return null;
        if (blocks.size() > BLOCKS_MAX_COUNT) {
            throw new AdminException('Too many design blocks (max ' + BLOCKS_MAX_COUNT + ').');
        }
        for (Object o : blocks) {
            if (!(o instanceof Map<String, Object>)) {
                throw new AdminException('Invalid design blocks.');
            }
            Map<String, Object> b = (Map<String, Object>) o;
            Object type = b.get('type');
            if (!(type instanceof String) || !BLOCK_TYPES.contains((String) type)) {
                throw new AdminException('Unknown design block type: ' + type);
            }
            Object url = b.get('url');
            if (url != null && !isAllowedBlockUrl(String.valueOf(url))) {
                throw new AdminException('This image or video address is not allowed: ' + url);
            }
        }
        assertMaxLength(value, BLOCKS_MAX_LENGTH, 'Design blocks');
        return value;
    }

    @TestVisible private static Boolean isAllowedBlockUrl(String url) {
        if (String.isBlank(url)) return true;
        if (!url.startsWithIgnoreCase('https://')) return false;
        // Browsers read "https://evil.com\.force.com" as evil.com while Url() sees *.force.com.
        if (url.contains('\\') || url.contains('@') || url.containsWhitespace()) return false;
        String host;
        try {
            host = new Url(url).getHost().toLowerCase();
        } catch (Exception e) {
            return false;
        }
        for (String suffix : BLOCK_URL_HOST_SUFFIXES) {
            String bare = suffix.removeStart('.');
            if (host == bare || host.endsWith('.' + bare)) return true;
        }
        return false;
    }

    // Only a file the user has just uploaded from the builder can be made public — never any other
    // image they can see (e.g. an ID photo attached to an account).
    @TestVisible private static Integer blockImageUploadWindowMinutes = 60;

    // Image blocks: the builder uploads a Salesforce File, then this makes a public link to it
    // (ContentDistribution) the guest portal can show. Returns the direct download URL.
    @AuraEnabled
    public static String publishBlockImage(String contentDocumentId) {
        requireManageForms();
        if (String.isBlank(contentDocumentId)) {
            throw new AdminException('contentDocumentId is required.');
        }
        List<ContentVersion> versions = [
            SELECT Id, Title, FileType, CreatedById, CreatedDate
            FROM ContentVersion
            WHERE ContentDocumentId = :contentDocumentId AND IsLatest = true
            WITH USER_MODE
            LIMIT 1
        ];
        if (versions.isEmpty()) {
            throw new AdminException('File not found.');
        }
        ContentVersion cv = versions[0];
        if (!IMAGE_FILE_TYPES.contains(String.valueOf(cv.FileType).toUpperCase())) {
            throw new AdminException('Only images (PNG, JPG, GIF, WEBP, SVG) can be used.');
        }
        if (cv.CreatedById != UserInfo.getUserId()
                || cv.CreatedDate < System.now().addMinutes(-blockImageUploadWindowMinutes)) {
            throw new AdminException('Only an image you have just uploaded can be used.');
        }
        // Re-uploading the same file reuses its public link instead of piling up new ones.
        List<ContentDistribution> existing = [
            SELECT ContentDownloadUrl FROM ContentDistribution
            WHERE ContentVersionId = :cv.Id
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (!existing.isEmpty() && String.isNotBlank(existing[0].ContentDownloadUrl)) return existing[0].ContentDownloadUrl;
        ContentDistribution cd = new ContentDistribution(
            Name = String.isNotBlank(cv.Title) ? cv.Title.left(100) : 'Portal image',
            ContentVersionId = cv.Id,
            PreferencesAllowViewInBrowser = true,
            // Pinned to this version: a later upload on the same file never changes the portal.
            PreferencesLinkLatestVersion = false,
            PreferencesNotifyOnVisit = false,
            PreferencesPasswordRequired = false,
            PreferencesAllowOriginalDownload = true
        );
        // System mode: the staff member needs no "Create Public Links" permission. Safe because the
        // file was read in user mode above and must be an image this same user has just uploaded.
        // The link is still created as (and owned by) that user.
        Database.insert(cd, AccessLevel.SYSTEM_MODE);
        return [SELECT ContentDownloadUrl FROM ContentDistribution WHERE Id = :cd.Id].ContentDownloadUrl;
    }

    private static final Set<String> IMAGE_FILE_TYPES = new Set<String>{
        'PNG', 'JPG', 'JPEG', 'GIF', 'WEBP', 'SVG', 'BMP'
    };

    private static Data_Update_Form__mdt getFullFormOrThrow(String formDeveloperName) {
        if (testFormMdt != null) {
            return testFormMdt;
        }
        return getFormOrThrow(formDeveloperName);
    }

    private static String blankToNull(String value) {
        return String.isBlank(value) ? null : value.trim();
    }

    // Pure read of the tracking row DataUpdateFormAdminDeployCallback writes when Salesforce
    // actually finishes the async deploy — see class header, there is no direct status-check
    // API for this deploy path. Status stays 'Pending' (done=false) until the callback fires.
    @AuraEnabled(cacheable=false)
    public static DataUpdateWrapper.DeployStatusResult checkDeployStatus(String jobId) {
        requireManageForms();
        DataUpdateWrapper.DeployStatusResult r = new DataUpdateWrapper.DeployStatusResult();
        r.jobId = jobId;
        try {
            if (TEST_FORCE_ERROR) throw new AdminException('TEST_FORCE_ERROR');
            List<Data_Update_Form_Deploy_Job__c> jobs = [
                SELECT Status__c, Error_Message__c, Form_Developer_Name__c
                FROM Data_Update_Form_Deploy_Job__c
                WHERE Job_Id__c = :jobId
                LIMIT 1
            ];
            if (jobs.isEmpty()) {
                r.status = 'Pending';
                r.done = false;
            } else {
                r.status = jobs[0].Status__c;
                r.errorMessage = jobs[0].Error_Message__c;
                r.formDeveloperName = jobs[0].Form_Developer_Name__c;
                r.done = (r.status == 'Succeeded' || r.status == 'Failed' || r.status == 'Canceled');
            }
        } catch (Exception e) {
            r.status = 'Unknown';
            r.done = false;
            r.errorMessage = e.getMessage();
        }
        return r;
    }

    // ─── Appearance templates ────────────────────────────────────────────
    // A template is only a named copy of a form's appearance: applying it copies the values into
    // the form being edited, so changing or deleting the template later never touches any form.

    private static final String APPEARANCE_TEMPLATE_MDT = 'Data_Update_Appearance_Template__mdt';
    // Tests can't insert CMDT records: they inject in-memory ones here instead.
    @TestVisible private static List<Data_Update_Appearance_Template__mdt> testAppearanceTemplates;

    private static List<Data_Update_Appearance_Template__mdt> allAppearanceTemplates() {
        if (testAppearanceTemplates != null) return testAppearanceTemplates;
        return DucFormConfigStore.appearanceTemplates();
    }

    @AuraEnabled(cacheable=false)
    public static List<DataUpdateWrapper.AppearanceTemplate> getAppearanceTemplates() {
        requireManageForms();
        List<DataUpdateWrapper.AppearanceTemplate> result = new List<DataUpdateWrapper.AppearanceTemplate>();
        for (Data_Update_Appearance_Template__mdt t : allAppearanceTemplates()) {
            if (t.Is_Active__c != true) continue;
            DataUpdateWrapper.AppearanceTemplate w = new DataUpdateWrapper.AppearanceTemplate();
            w.developerName = t.DeveloperName;
            w.label = t.MasterLabel;
            w.appearanceJson = t.Appearance__c;
            result.add(w);
        }
        return result;
    }

    // Saving under a name that already exists (any case, even a deleted one) overwrites it.
    @AuraEnabled
    public static String enqueueSaveAppearanceTemplate(String label, String appearanceJson) {
        requireManageForms();
        String name = blankToNull(label);
        if (name == null) throw new AdminException('Template name is required.');
        if (name.length() > 40) throw new AdminException('Template name must be 40 characters or less.');
        String appearance = normalizeAppearance(appearanceJson);
        if (appearance == null) throw new AdminException('This appearance is the standard one; nothing to save.');

        String developerName;
        Set<String> taken = new Set<String>();
        for (Data_Update_Appearance_Template__mdt t : allAppearanceTemplates()) {
            taken.add(t.DeveloperName.toLowerCase());
            if (t.MasterLabel != null && t.MasterLabel.equalsIgnoreCase(name)) developerName = t.DeveloperName;
        }
        if (developerName == null) developerName = appendUniqueSuffix(sanitizeDeveloperName(name), taken);
        return deploy(new List<Metadata.CustomMetadata>{ appearanceTemplateMetadata(developerName, name, appearance, true) }, null);
    }

    // CMDT records can't be deleted from Apex, so a deleted template is only switched off.
    @AuraEnabled
    public static String enqueueDeleteAppearanceTemplate(String developerName) {
        requireManageForms();
        Data_Update_Appearance_Template__mdt t;
        for (Data_Update_Appearance_Template__mdt candidate : allAppearanceTemplates()) {
            if (candidate.DeveloperName == developerName) t = candidate;
        }
        if (t == null) throw new AdminException('Template not found: ' + developerName);
        return deploy(new List<Metadata.CustomMetadata>{
            appearanceTemplateMetadata(t.DeveloperName, t.MasterLabel, t.Appearance__c, false)
        }, null);
    }

    private static Metadata.CustomMetadata appearanceTemplateMetadata(String developerName, String label, String appearance, Boolean active) {
        Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
        cmd.fullName = APPEARANCE_TEMPLATE_MDT + '.' + developerName;
        cmd.label = truncateLabel(label);
        addValue(cmd, 'Appearance__c', appearance);
        addValue(cmd, 'Is_Active__c', active);
        return cmd;
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    // Publishes the records (DucFormConfigStore) and returns a job id the LWC polls with
    // checkDeployStatus(). The job row is written Succeeded right away and the publish lock is
    // freed (no cooldown: the change is already live once this returns).
    private static String deploy(List<Metadata.CustomMetadata> records, String formDeveloperName) {
        Data_Update_Form_Deploy_Job__c lock = requirePublishLock();
        try {
            if (TEST_FORCE_SAVE_ERROR) throw new DmlException('TEST_FORCE_SAVE_ERROR');
            DucFormConfigStore.save(records);
        } catch (Exception e) {
            throw new AdminException('Could not save the form: ' + e.getMessage());
        }
        String correlationId = generateCorrelationId();
        insert new Data_Update_Form_Deploy_Job__c(
            Job_Id__c = correlationId,
            Status__c = 'Succeeded',
            Form_Developer_Name__c = String.isBlank(formDeveloperName) ? null : formDeveloperName.left(100)
        );
        if (lock != null) {
            lock.Status__c = LOCK_FREE;
            update lock;
        }
        if (String.isNotBlank(formDeveloperName)) DataUpdateFormConfigService.clearCache(formDeveloperName);
        return correlationId;
    }

    private static String generateCorrelationId() {
        return EncodingUtil.convertToHex(Crypto.generateAesKey(128));
    }

    private static Metadata.CustomMetadata fullRecordToMetadata(Data_Update_Form_Field__mdt fm) {
        Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
        cmd.fullName = FIELD_MDT + '.' + fm.DeveloperName;
        cmd.label = String.isNotBlank(fm.MasterLabel) ? fm.MasterLabel : truncateLabel(fm.DeveloperName);
        addValue(cmd, 'Form__c', fm.Form__r != null ? fm.Form__r.DeveloperName : null);
        addValue(cmd, 'Field_API_Name__c', fm.Field_API_Name__c);
        addValue(cmd, 'Label_FR__c', fm.Label_FR__c);
        addValue(cmd, 'Label_EN__c', fm.Label_EN__c);
        addValue(cmd, 'Display_Order__c', fm.Display_Order__c != null ? Integer.valueOf(fm.Display_Order__c) : 0);
        addValue(cmd, 'Section_Label_FR__c', fm.Section_Label_FR__c);
        addValue(cmd, 'Section_Label_EN__c', fm.Section_Label_EN__c);
        addValue(cmd, 'Input_Type__c', fm.Input_Type__c);
        addValue(cmd, 'Is_Required__c', fm.Is_Required__c == true);
        addValue(cmd, 'Is_Active__c', fm.Is_Active__c == true);
        addValue(cmd, 'History_Mode__c', String.isBlank(fm.History_Mode__c) ? 'Replace' : fm.History_Mode__c);
        addValue(cmd, 'History_Target_Object_API_Name__c', fm.History_Target_Object_API_Name__c);
        addValue(cmd, 'History_Target_Value_Field_API_Name__c', fm.History_Target_Value_Field_API_Name__c);
        addValue(cmd, 'History_Target_Date_Field_API_Name__c', fm.History_Target_Date_Field_API_Name__c);
        addValue(cmd, 'History_Target_Account_Field_API_Name__c', fm.History_Target_Account_Field_API_Name__c);
        addValue(cmd, 'History_Target_Log_Field_API_Name__c', fm.History_Target_Log_Field_API_Name__c);
        addValue(cmd, 'History_Date_Source_Field_API_Name__c', fm.History_Date_Source_Field_API_Name__c);
        addValue(cmd, 'Same_Row_As_Previous__c', fm.Same_Row_As_Previous__c == true);
        addValue(cmd, 'Help_FR__c', fm.Help_FR__c);
        addValue(cmd, 'Help_EN__c', fm.Help_EN__c);
        addValue(cmd, 'Is_Hidden__c', fm.Is_Hidden__c == true);
        addValue(cmd, 'Is_Read_Only__c', fm.Is_Read_Only__c == true);
        addValue(cmd, 'History_Table_Columns__c', fm.History_Table_Columns__c);
        addValue(cmd, 'History_Table_Input_Mode__c', fm.History_Table_Input_Mode__c);
        return cmd;
    }

    private static void addValue(Metadata.CustomMetadata cmd, String field, Object value) {
        Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
        v.field = field;
        v.value = value;
        cmd.values.add(v);
    }

    // Used when re-setting a single value on a record already fully built by fullRecordToMetadata —
    // replaces the entry rather than adding a duplicate <values> block for the same field.
    @TestVisible private static void setValue(Metadata.CustomMetadata cmd, String field, Object value) {
        for (Metadata.CustomMetadataValue v : cmd.values) {
            if (v.field == field) {
                v.value = value;
                return;
            }
        }
        addValue(cmd, field, value);
    }

    @TestVisible private static String truncateLabel(String label) {
        if (label == null) return '';
        return label.length() > 40 ? label.substring(0, 40) : label;
    }

    private static Data_Update_Form__mdt getFormOrThrow(String formDeveloperName) {
        if (testFormMdt != null) {
            return testFormMdt;
        }
        Data_Update_Form__mdt form = DucFormConfigStore.form(formDeveloperName);
        if (form == null) {
            throw new AdminException('Form not found: ' + formDeveloperName);
        }
        return form;
    }

    private static List<Data_Update_Form_Field__mdt> getFieldRecords(String formDeveloperName) {
        if (testFieldMdts != null) return testFieldMdts;
        return DucFormConfigStore.fields(formDeveloperName);
    }

    private static Map<String, Schema.SObjectField> describeFieldMap(String objectApiName) {
        Schema.SObjectType targetType = DataUpdateFormConfigService.globalTypes().get(objectApiName);
        if (targetType == null) {
            throw new AdminException('Unknown object: ' + objectApiName);
        }
        return targetType.getDescribe().fields.getMap();
    }

    private static void assertFieldExists(Map<String, Schema.SObjectField> fieldMap, String apiName, String label) {
        if (!fieldMap.containsKey(apiName.toLowerCase())) {
            throw new AdminException(label + ' ' + apiName + ' does not exist on the target object.');
        }
    }

    // Fail-fast mirror of DataUpdateFormConfigService.validateHistoryMapping() — same rules,
    // duplicated here (rather than shared) because this one throws AdminException on raw
    // strings before anything is deployed, while the other validates an already-loaded
    // FormFieldConfig on every getForm() call. Both must agree: this lets the Form Builder reject a
    // bad mapping immediately instead of only on the next form load.
    @TestVisible private static void validateHistoryMappingInput(String historyTargetObjectApiName, String historyTargetValueFieldApiName,
            String historyTargetDateFieldApiName, String historyTargetAccountFieldApiName,
            String historyTargetLogFieldApiName, String historyDateSourceFieldApiName, String sourceObjectApiName) {

        if (String.isBlank(historyTargetObjectApiName) || String.isBlank(historyTargetValueFieldApiName)) {
            throw new AdminException('History Mode needs a history target object and value field.');
        }
        Map<String, Schema.SObjectField> histFieldMap = describeFieldMap(historyTargetObjectApiName);

        Schema.SObjectField valueField = histFieldMap.get(historyTargetValueFieldApiName.toLowerCase());
        if (valueField == null) {
            throw new AdminException('Unknown history value field ' + historyTargetValueFieldApiName + ' on ' + historyTargetObjectApiName);
        }
        Schema.DisplayType valueType = valueField.getDescribe().getType();
        if (!valueField.getDescribe().isCreateable()
            || valueType == Schema.DisplayType.REFERENCE
            || valueType == Schema.DisplayType.MULTIPICKLIST
            || valueType == Schema.DisplayType.ADDRESS) {
            throw new AdminException('History value field ' + historyTargetValueFieldApiName + ' on ' + historyTargetObjectApiName + ' is not a valid target field.');
        }

        if (String.isNotBlank(historyTargetDateFieldApiName)) {
            Schema.SObjectField dateField = histFieldMap.get(historyTargetDateFieldApiName.toLowerCase());
            if (dateField == null) {
                throw new AdminException('Unknown history date field ' + historyTargetDateFieldApiName + ' on ' + historyTargetObjectApiName);
            }
            Schema.DisplayType dateType = dateField.getDescribe().getType();
            if (dateType != Schema.DisplayType.DATE && dateType != Schema.DisplayType.DATETIME) {
                throw new AdminException('History date field ' + historyTargetDateFieldApiName + ' on ' + historyTargetObjectApiName + ' must be a Date or DateTime field.');
            }
        }

        if (String.isNotBlank(historyTargetAccountFieldApiName)) {
            assertReferenceFieldTo(histFieldMap, historyTargetAccountFieldApiName, historyTargetObjectApiName, sourceObjectApiName);
        }
        if (String.isNotBlank(historyTargetLogFieldApiName)) {
            assertReferenceFieldTo(histFieldMap, historyTargetLogFieldApiName, historyTargetObjectApiName, 'Data_Update_Log__c');
        }

        if (String.isNotBlank(historyDateSourceFieldApiName)) {
            Map<String, Schema.SObjectField> sourceFieldMap = describeFieldMap(sourceObjectApiName);
            Schema.SObjectField dateSourceField = sourceFieldMap.get(historyDateSourceFieldApiName.toLowerCase());
            if (dateSourceField == null) {
                throw new AdminException('Unknown history date source field ' + historyDateSourceFieldApiName + ' on ' + sourceObjectApiName);
            }
            Schema.DisplayType dateSourceType = dateSourceField.getDescribe().getType();
            if (dateSourceType != Schema.DisplayType.DATE && dateSourceType != Schema.DisplayType.DATETIME) {
                throw new AdminException('History date source field ' + historyDateSourceFieldApiName + ' on ' + sourceObjectApiName + ' must be a Date or DateTime field.');
            }
        }
    }

    // History_Only = the same mapping rules as Historize, plus a mandatory lookup back to the
    // form's target object (mirror of DataUpdateFormConfigService.validateHistoryOnly()).
    @TestVisible private static void validateHistoryOnlyInput(String historyTargetObjectApiName, String historyTargetValueFieldApiName,
            String historyTargetDateFieldApiName, String historyTargetAccountFieldApiName,
            String historyTargetLogFieldApiName, String sourceObjectApiName) {
        validateHistoryMappingInput(historyTargetObjectApiName, historyTargetValueFieldApiName,
            historyTargetDateFieldApiName, historyTargetAccountFieldApiName, historyTargetLogFieldApiName,
            null, sourceObjectApiName);
        if (String.isBlank(historyTargetAccountFieldApiName)) {
            throw new AdminException('History Only needs the lookup from the history object to ' + sourceObjectApiName + '.');
        }
    }

    @TestVisible private static Boolean isValidHistoryOnlyMapping(Data_Update_Form_Field__mdt fm, String sourceObjectApiName) {
        try {
            validateHistoryOnlyInput(fm.History_Target_Object_API_Name__c, fm.History_Target_Value_Field_API_Name__c,
                fm.History_Target_Date_Field_API_Name__c, fm.History_Target_Account_Field_API_Name__c,
                fm.History_Target_Log_Field_API_Name__c, sourceObjectApiName);
            return DataUpdateFormConfigService.buildHistoryOnlyKey(fm.History_Target_Object_API_Name__c, fm.History_Target_Value_Field_API_Name__c)
                .equalsIgnoreCase(fm.Field_API_Name__c);
        } catch (Exception e) {
            return false;
        }
    }

    @TestVisible private static void assertReferenceFieldTo(Map<String, Schema.SObjectField> fieldMap, String fieldApiName, String objectApiName, String expectedReferenceTo) {
        Schema.SObjectField field = String.isBlank(fieldApiName) ? null : fieldMap.get(fieldApiName.toLowerCase());
        if (field == null) {
            throw new AdminException('Unknown field ' + fieldApiName + ' on ' + objectApiName);
        }
        Schema.DescribeFieldResult dfr = field.getDescribe();
        if (dfr.getType() != Schema.DisplayType.REFERENCE) {
            throw new AdminException('Field ' + fieldApiName + ' on ' + objectApiName + ' must be a lookup/reference field.');
        }
        Boolean pointsToExpected = false;
        for (Schema.SObjectType refType : dfr.getReferenceTo()) {
            if (refType.getDescribe().getName().equalsIgnoreCase(expectedReferenceTo)) {
                pointsToExpected = true;
                break;
            }
        }
        if (!pointsToExpected) {
            throw new AdminException('Field ' + fieldApiName + ' on ' + objectApiName + ' must reference ' + expectedReferenceTo + '.');
        }
    }

    @TestVisible private static String buildUniqueFormDeveloperName(String rawLabel) {
        String base = sanitizeDeveloperName(rawLabel);

        return appendUniqueSuffix(base, DucFormConfigStore.usedDeveloperNames(FORM_MDT));
    }

    private static final Map<String, String> ACCENT_MAP = new Map<String, String>{
        'àáâãäå' => 'a', 'ÀÁÂÃÄÅ' => 'A', 'èéêë' => 'e', 'ÈÉÊË' => 'E', 'ìíîï' => 'i', 'ÌÍÎÏ' => 'I',
        'òóôõö' => 'o', 'ÒÓÔÕÖ' => 'O', 'ùúûü' => 'u', 'ÙÚÛÜ' => 'U', 'ç' => 'c', 'Ç' => 'C',
        'ñ' => 'n', 'Ñ' => 'N', 'ÿý' => 'y', 'Ý' => 'Y', 'œ' => 'oe', 'Œ' => 'OE', 'æ' => 'ae', 'Æ' => 'AE'
    };

    // Turns any label into a valid DeveloperName base (shared by both builders). Accents are
    // folded first so French labels keep their letters ("Église 2027" -> "Eglise_2027"), and
    // the F_ prefix is added BEFORE collapsing "__" — the other order produced "F__glise_2027",
    // which the Metadata API rejects.
    @TestVisible private static String sanitizeDeveloperName(String raw) {
        String folded = raw == null ? '' : raw;
        for (String accents : ACCENT_MAP.keySet()) {
            for (Integer i = 0; i < accents.length(); i++) {
                folded = folded.replace(accents.substring(i, i + 1), ACCENT_MAP.get(accents));
            }
        }
        String base = folded.replaceAll('[^A-Za-z0-9_]', '_');
        if (!Pattern.matches('^[A-Za-z].*', base)) {
            base = 'F_' + base;
        }
        while (base.contains('__')) {
            base = base.replace('__', '_');
        }
        if (base.length() > 40) {
            base = base.substring(0, 40);
        }
        return trimTrailingUnderscores(base);
    }

    private static String trimTrailingUnderscores(String value) {
        String result = value;
        while (result.endsWith('_')) {
            result = result.substring(0, result.length() - 1);
        }
        return result;
    }

    // Shared by both DeveloperName builders: base as-is if free, otherwise base_2, base_3...
    // with base cut short so the result still fits in 40 chars. existing is lower-cased.
    @TestVisible private static String appendUniqueSuffix(String base, Set<String> existing) {
        if (!existing.contains(base.toLowerCase())) {
            return base;
        }
        Integer suffix = 2;
        String candidate;
        do {
            String suffixStr = '_' + suffix;
            // Trim after cutting, or "..._" + "_2" would form an invalid "__".
            String truncatedBase = base.length() + suffixStr.length() > 40
                ? trimTrailingUnderscores(base.substring(0, 40 - suffixStr.length()))
                : base;
            candidate = truncatedBase + suffixStr;
            suffix++;
        } while (existing.contains(candidate.toLowerCase()));
        return candidate;
    }
}
