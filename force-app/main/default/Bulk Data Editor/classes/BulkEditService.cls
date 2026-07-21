public without sharing class BulkEditService {

    // ---------------------------------------------------------------
    // Caches (governor-limit friendly — describe calls are expensive)
    // ---------------------------------------------------------------
    private static Map<String, Schema.SObjectType> GD_CACHE;

    // Test-only hooks to deterministically exercise defense-in-depth branches
    // that can't be reliably reached through real schema/permission setups
    // (e.g. no field in this org is both an allowed type and excluded-by-name,
    // and an admin test-running user is accessible to virtually everything).
    // Always false in production code paths; each test resets it in a finally.
    @TestVisible private static Boolean TEST_FORCE_SERVICE_EXCEPTION = false;
    @TestVisible private static Boolean TEST_FORCE_OBJECT_NOT_EDITABLE = false;
    @TestVisible private static Boolean TEST_FORCE_FIELD_CALCULATED = false;
    @TestVisible private static Boolean TEST_FORCE_BYPASS_FIELD_CHECKS = false;
    @TestVisible private static Boolean TEST_FORCE_FILTER_FIELD_NOT_ACCESSIBLE = false;

    // Field types safe for GROUP BY aggregation and reliable string<->typed
    // round-tripping. Deliberately excludes: DATETIME (timezone complexity),
    // MULTIPICKLIST, ENCRYPTEDSTRING, TEXTAREA (long text/rich text),
    // REFERENCE (mass re-parenting out of scope for v1), BASE64, ID, ANYTYPE.
    private static final Set<Schema.DisplayType> ALLOWED_FIELD_TYPES = new Set<Schema.DisplayType>{
        Schema.DisplayType.STRING,
        Schema.DisplayType.PICKLIST,
        Schema.DisplayType.BOOLEAN,
        Schema.DisplayType.DOUBLE,
        Schema.DisplayType.INTEGER,
        Schema.DisplayType.CURRENCY,
        Schema.DisplayType.PERCENT,
        Schema.DisplayType.PHONE,
        Schema.DisplayType.EMAIL,
        Schema.DisplayType.URL,
        Schema.DisplayType.DATE
    };

    // Standard/audit fields never offered for mass-edit even when the
    // underlying type would otherwise qualify.
    private static final Set<String> EXCLUDED_FIELD_NAMES = new Set<String>{
        'ID', 'OWNERID', 'CREATEDBYID', 'CREATEDDATE', 'LASTMODIFIEDBYID',
        'LASTMODIFIEDDATE', 'SYSTEMMODSTAMP', 'ISDELETED', 'MASTERRECORDID'
    };

    // Platform-sensitive objects always excluded from auto-discovery,
    // regardless of the running user's object permissions.
    private static final Set<String> OBJECT_BLACKLIST = new Set<String>{
        'USER', 'PROFILE', 'PERMISSIONSET', 'PERMISSIONSETASSIGNMENT',
        'PERMISSIONSETGROUP', 'PERMISSIONSETLICENSE', 'USERROLE', 'GROUP',
        'GROUPMEMBER', 'QUEUESOBJECT', 'NETWORKMEMBERGROUP',
        'ORGANIZATION', 'SETUPENTITYACCESS', 'OBJECTPERMISSIONS',
        'FIELDPERMISSIONS', 'LOGINHISTORY', 'LOGINIP', 'ASYNCAPEXJOB',
        'CRONTRIGGER', 'CRONJOBDETAIL', 'AUTHPROVIDER', 'CONNECTEDAPPLICATION',
        'SAMLSSOCONFIG', 'CERTIFICATE', 'APEXCLASS', 'APEXTRIGGER',
        'APEXPAGE', 'APEXCOMPONENT', 'APEXLOG', 'STATICRESOURCE',
        'CUSTOMPERMISSION', 'SESSION', 'AUTHSESSION', 'PACKAGELICENSE',
        'USERLOGIN', 'USERPREFERENCE', 'BULK_EDIT_LOG__C', 'BULK_EDIT_SNAPSHOT__C'
    };

    // Object name suffixes/patterns excluded from auto-discovery (change
    // events, feeds, history, share tables, custom metadata, etc.).
    private static final List<String> EXCLUDED_NAME_SUFFIXES = new List<String>{
        '__SHARE', '__HISTORY', '__FEED', '__CHANGEEVENT', '__MDT',
        '__E', '__X', '__TAG', 'CHANGEEVENT', 'SHARE', 'HISTORY', 'FEED'
    };

    private static Map<String, Schema.SObjectType> gd() {
        if (GD_CACHE == null) {
            GD_CACHE = Schema.getGlobalDescribe();
        }
        return GD_CACHE;
    }

    private static Boolean isBlacklisted(String apiName) {
        String upper = apiName.toUpperCase();
        if (OBJECT_BLACKLIST.contains(upper)) {
            return true;
        }
        for (String suffix : EXCLUDED_NAME_SUFFIXES) {
            if (upper.endsWith(suffix)) {
                return true;
            }
        }
        return false;
    }

    // ---------------------------------------------------------------
    // Object / field discovery
    // ---------------------------------------------------------------

    public static List<BulkEditWrappers.ObjectOption> getEditableObjects() {
        if (TEST_FORCE_SERVICE_EXCEPTION) {
            throw new BulkEditException('Forced error for test coverage.');
        }
        List<BulkEditWrappers.ObjectOption> options = new List<BulkEditWrappers.ObjectOption>();

        for (String apiName : gd().keySet()) {
            if (isBlacklisted(apiName)) {
                continue;
            }
            Schema.SObjectType sType = gd().get(apiName);
            Schema.DescribeSObjectResult dsr = sType.getDescribe();

            if (!dsr.isAccessible() || !dsr.isUpdateable() || !dsr.isQueryable()) {
                continue;
            }
            if (dsr.isCustomSetting()) {
                continue;
            }

            options.add(new BulkEditWrappers.ObjectOption(dsr.getName(), dsr.getLabel()));
        }

        options.sort(new ObjectOptionComparator());
        return options;
    }

    public static Schema.SObjectType resolveObjectType(String objectApiName) {
        if (String.isBlank(objectApiName)) {
            throw new BulkEditException('Object API name is required.');
        }
        if (isBlacklisted(objectApiName)) {
            throw new BulkEditException('This object is not available for mass editing.');
        }
        Schema.SObjectType sType = gd().get(objectApiName);
        if (sType == null) {
            throw new BulkEditException('Unknown object: ' + objectApiName);
        }
        Schema.DescribeSObjectResult dsr = sType.getDescribe();
        if (TEST_FORCE_OBJECT_NOT_EDITABLE || !dsr.isAccessible() || !dsr.isUpdateable() || !dsr.isQueryable()) {
            throw new BulkEditException('You do not have permission to edit this object.');
        }
        return sType;
    }

    public static List<BulkEditWrappers.FieldOption> getEditableFields(String objectApiName) {
        Schema.SObjectType sType = resolveObjectType(objectApiName);
        List<BulkEditWrappers.FieldOption> options = new List<BulkEditWrappers.FieldOption>();

        Map<String, Schema.SObjectField> fieldMap = sType.getDescribe().fields.getMap();
        for (String fieldApiName : fieldMap.keySet()) {
            if (EXCLUDED_FIELD_NAMES.contains(fieldApiName.toUpperCase())) {
                continue;
            }
            Schema.DescribeFieldResult dfr = fieldMap.get(fieldApiName).getDescribe();

            if (!ALLOWED_FIELD_TYPES.contains(dfr.getType())) {
                continue;
            }
            if (!dfr.isAccessible() || !dfr.isUpdateable()) {
                continue;
            }
            if (TEST_FORCE_FIELD_CALCULATED || dfr.isCalculated() || dfr.isAutoNumber()) {
                continue;
            }
            // Component fields of compound types (e.g. the Latitude/Longitude
            // halves of a Geolocation field) describe as a plain allowed type
            // but SOQL rejects them in GROUP BY — isGroupable() is the
            // authoritative signal, so exclude them before they ever reach
            // the field picker instead of failing at query time.
            if (!dfr.isGroupable()) {
                continue;
            }

            options.add(new BulkEditWrappers.FieldOption(
                dfr.getName(),
                dfr.getLabel(),
                String.valueOf(dfr.getType())
            ));
        }

        options.sort(new FieldOptionComparator());
        return options;
    }

    // Field list for the optional "cross-filter" criterion (e.g. only rows
    // where Mailing State = Quebec). Unlike getEditableFields(), this only
    // requires read access — a filter field is queried, never written to —
    // and excludes the field already selected as the mass-edit target since
    // filtering a field by itself is redundant with the main value picker.
    public static List<BulkEditWrappers.FieldOption> getFilterableFields(String objectApiName, String excludeFieldApiName) {
        Schema.SObjectType sType = resolveObjectType(objectApiName);
        List<BulkEditWrappers.FieldOption> options = new List<BulkEditWrappers.FieldOption>();

        Map<String, Schema.SObjectField> fieldMap = sType.getDescribe().fields.getMap();
        for (String fieldApiName : fieldMap.keySet()) {
            if (EXCLUDED_FIELD_NAMES.contains(fieldApiName.toUpperCase())) {
                continue;
            }
            if (String.isNotBlank(excludeFieldApiName) && fieldApiName.equalsIgnoreCase(excludeFieldApiName)) {
                continue;
            }
            Schema.DescribeFieldResult dfr = fieldMap.get(fieldApiName).getDescribe();

            if (!ALLOWED_FIELD_TYPES.contains(dfr.getType())) {
                continue;
            }
            if (!dfr.isAccessible()) {
                continue;
            }
            if (TEST_FORCE_FIELD_CALCULATED || dfr.isCalculated()) {
                continue;
            }
            if (!dfr.isGroupable()) {
                continue;
            }

            options.add(new BulkEditWrappers.FieldOption(
                dfr.getName(),
                dfr.getLabel(),
                String.valueOf(dfr.getType())
            ));
        }

        options.sort(new FieldOptionComparator());
        return options;
    }

    public static Schema.DescribeFieldResult resolveFieldDescribe(Schema.SObjectType sType, String fieldApiName) {
        if (String.isBlank(fieldApiName)) {
            throw new BulkEditException('Field API name is required.');
        }
        Map<String, Schema.SObjectField> fieldMap = sType.getDescribe().fields.getMap();
        Schema.SObjectField sField = fieldMap.get(fieldApiName);
        if (sField == null) {
            throw new BulkEditException('Unknown field: ' + fieldApiName);
        }
        Schema.DescribeFieldResult dfr = sField.getDescribe();
        // RecordTypeId (REFERENCE) is narrowly allowed here — not because
        // general reference/lookup mass re-parenting is in scope (it isn't,
        // see ALLOWED_FIELD_TYPES above), but so BulkEditUndoBatch can
        // resolve it during undo of a Record Type change job created by
        // BulkRecordTypeController/BulkRecordTypeChangeBatch. It's still
        // never offered by getEditableFields()'s type filter, so it can't
        // be picked from the normal value-edit wizard.
        Boolean isRecordTypeReference = dfr.getType() == Schema.DisplayType.REFERENCE && dfr.getName() == 'RecordTypeId';
        if (!TEST_FORCE_BYPASS_FIELD_CHECKS && !ALLOWED_FIELD_TYPES.contains(dfr.getType()) && !isRecordTypeReference) {
            throw new BulkEditException('This field type is not supported for mass editing.');
        }
        if (!TEST_FORCE_BYPASS_FIELD_CHECKS && (!dfr.isAccessible() || !dfr.isUpdateable())) {
            throw new BulkEditException('You do not have permission to edit this field.');
        }
        if (EXCLUDED_FIELD_NAMES.contains(fieldApiName.toUpperCase())) {
            throw new BulkEditException('This field is not available for mass editing.');
        }
        return dfr;
    }

    // Counterpart to resolveFieldDescribe() for the optional filter field —
    // only requires read access since a filter field is queried, never
    // written to, so it deliberately skips the isUpdateable() check that
    // would wrongly exclude read-only-to-this-user fields from filtering.
    public static Schema.DescribeFieldResult resolveFilterFieldDescribe(Schema.SObjectType sType, String fieldApiName) {
        if (String.isBlank(fieldApiName)) {
            throw new BulkEditException('Filter field API name is required.');
        }
        Map<String, Schema.SObjectField> fieldMap = sType.getDescribe().fields.getMap();
        Schema.SObjectField sField = fieldMap.get(fieldApiName);
        if (sField == null) {
            throw new BulkEditException('Unknown filter field: ' + fieldApiName);
        }
        Schema.DescribeFieldResult dfr = sField.getDescribe();
        if (!ALLOWED_FIELD_TYPES.contains(dfr.getType())) {
            throw new BulkEditException('This field type is not supported for filtering.');
        }
        if (TEST_FORCE_FILTER_FIELD_NOT_ACCESSIBLE || !dfr.isAccessible()) {
            throw new BulkEditException('You do not have permission to view this filter field.');
        }
        if (EXCLUDED_FIELD_NAMES.contains(fieldApiName.toUpperCase())) {
            throw new BulkEditException('This field is not available for filtering.');
        }
        return dfr;
    }

    // ---------------------------------------------------------------
    // Value distribution (GROUP BY aggregate — 2,000 grouped-row limit)
    // ---------------------------------------------------------------

    public static BulkEditWrappers.ValueDistributionResult getValueDistribution(
        String objectApiName,
        String fieldApiName,
        String filterFieldApiName,
        String filterValue,
        Boolean filterIsBlankValue
    ) {
        Schema.SObjectType sType = resolveObjectType(objectApiName);
        Schema.DescribeFieldResult dfr = resolveFieldDescribe(sType, fieldApiName);
        // Defense in depth: getEditableFields() already excludes non-groupable
        // fields (e.g. Currency, or the Latitude/Longitude halves of a
        // Geolocation) so the picker never offers them, but a stale cached
        // field list on the client could still send one here — GROUP BY
        // would otherwise fail with an uncatchable platform fault.
        if (!dfr.isGroupable()) {
            throw new BulkEditException('This field cannot be grouped by value and does not support the value picker. Please choose a different field.');
        }

        String filterClause = null;
        if (String.isNotBlank(filterFieldApiName)) {
            Schema.DescribeFieldResult filterDfr = resolveFilterFieldDescribe(sType, filterFieldApiName);
            filterClause = buildWhereClause(filterDfr, filterValue, filterIsBlankValue);
        }

        return runValueDistributionQuery(sType, dfr, filterClause);
    }

    // Distribution for the filter field itself (e.g. showing "Quebec (120),
    // Ontario (45), (Blank) (10)..." so the user can pick a precise filter
    // value) — no filter-on-filter, so no WHERE clause here.
    public static BulkEditWrappers.ValueDistributionResult getFilterFieldValueDistribution(String objectApiName, String fieldApiName) {
        Schema.SObjectType sType = resolveObjectType(objectApiName);
        Schema.DescribeFieldResult dfr = resolveFilterFieldDescribe(sType, fieldApiName);
        if (!dfr.isGroupable()) {
            throw new BulkEditException('This field cannot be grouped by value and does not support the filter value picker. Please choose a different field.');
        }
        return runValueDistributionQuery(sType, dfr, null);
    }

    private static BulkEditWrappers.ValueDistributionResult runValueDistributionQuery(
        Schema.SObjectType sType,
        Schema.DescribeFieldResult dfr,
        String whereClause
    ) {
        BulkEditWrappers.ValueDistributionResult result = new BulkEditWrappers.ValueDistributionResult();
        result.fieldDataType = String.valueOf(dfr.getType());
        result.isPicklist = (dfr.getType() == Schema.DisplayType.PICKLIST);

        String fieldName = String.escapeSingleQuotes(dfr.getName());
        String objectName = String.escapeSingleQuotes(sType.getDescribe().getName());

        String query = 'SELECT ' + fieldName + ', COUNT(Id) recCount FROM ' + objectName +
            (String.isNotBlank(whereClause) ? ' WHERE ' + whereClause : '') +
            ' GROUP BY ' + fieldName + ' ORDER BY COUNT(Id) DESC LIMIT 2000';

        List<AggregateResult> rows = Database.query(query);

        Integer total = 0;
        for (AggregateResult ar : rows) {
            Object rawObj = ar.get(dfr.getName());
            Integer cnt = (Integer) ar.get('recCount');
            total += cnt;

            Boolean isBlank = (rawObj == null);
            String rawValue = isBlank ? null : String.valueOf(rawObj);
            String displayValue = isBlank ? '(Blank)' : rawValue;

            result.buckets.add(new BulkEditWrappers.ValueBucket(rawValue, displayValue, isBlank, cnt));
        }

        result.totalRecords = total;
        result.truncated = (rows.size() >= 2000);
        return result;
    }

    public static List<String> getPicklistValues(String objectApiName, String fieldApiName) {
        Schema.SObjectType sType = resolveObjectType(objectApiName);
        Schema.DescribeFieldResult dfr = resolveFieldDescribe(sType, fieldApiName);

        List<String> values = new List<String>();
        if (dfr.getType() != Schema.DisplayType.PICKLIST) {
            return values;
        }
        for (Schema.PicklistEntry entry : dfr.getPicklistValues()) {
            if (entry.isActive()) {
                values.add(entry.getValue());
            }
        }
        return values;
    }

    // ---------------------------------------------------------------
    // Preview / WHERE clause construction
    // ---------------------------------------------------------------

    public static Integer previewCount(String objectApiName, String fieldApiName, String oldValue, Boolean isBlankValue) {
        Schema.SObjectType sType = resolveObjectType(objectApiName);
        Schema.DescribeFieldResult dfr = resolveFieldDescribe(sType, fieldApiName);

        String whereClause = buildWhereClause(dfr, oldValue, isBlankValue);
        String objectName = String.escapeSingleQuotes(sType.getDescribe().getName());
        String query = 'SELECT COUNT() FROM ' + objectName + ' WHERE ' + whereClause;

        return Database.countQuery(query);
    }

    public static String buildWhereClause(Schema.DescribeFieldResult dfr, String rawValue, Boolean isBlankValue) {
        String fieldName = String.escapeSingleQuotes(dfr.getName());

        if (isBlankValue == true) {
            if (dfr.getType() == Schema.DisplayType.STRING ||
                dfr.getType() == Schema.DisplayType.PICKLIST ||
                dfr.getType() == Schema.DisplayType.PHONE ||
                dfr.getType() == Schema.DisplayType.EMAIL ||
                dfr.getType() == Schema.DisplayType.URL) {
                return '(' + fieldName + ' = null OR ' + fieldName + ' = \'\')';
            }
            return fieldName + ' = null';
        }

        String literal = toSoqlLiteral(dfr.getType(), rawValue);
        return fieldName + ' = ' + literal;
    }

    private static String toSoqlLiteral(Schema.DisplayType dt, String rawValue) {
        if (rawValue == null) {
            return 'null';
        }
        try {
            switch on dt {
                when BOOLEAN {
                    return String.valueOf(Boolean.valueOf(rawValue));
                }
                when DOUBLE, INTEGER, CURRENCY, PERCENT {
                    return String.valueOf(Decimal.valueOf(rawValue));
                }
                when DATE {
                    return String.valueOf(Date.valueOf(rawValue));
                }
                when else {
                    return '\'' + String.escapeSingleQuotes(rawValue) + '\'';
                }
            }
        } catch (Exception ex) {
            throw new BulkEditException('Invalid value "' + rawValue + '" for this field type.');
        }
    }

    public static Object toApexValue(Schema.DisplayType dt, String rawValue, Boolean isBlankValue) {
        if (isBlankValue == true || rawValue == null) {
            return null;
        }
        try {
            switch on dt {
                when BOOLEAN {
                    return Boolean.valueOf(rawValue);
                }
                when DOUBLE, INTEGER, CURRENCY, PERCENT {
                    return Decimal.valueOf(rawValue);
                }
                when DATE {
                    return Date.valueOf(rawValue);
                }
                when else {
                    return rawValue;
                }
            }
        } catch (Exception ex) {
            throw new BulkEditException('Invalid value "' + rawValue + '" for this field type.');
        }
    }

    // ---------------------------------------------------------------
    // Comparators
    // ---------------------------------------------------------------

    private class ObjectOptionComparator implements Comparator<BulkEditWrappers.ObjectOption> {
        public Integer compare(BulkEditWrappers.ObjectOption a, BulkEditWrappers.ObjectOption b) {
            return a.label.compareTo(b.label);
        }
    }

    private class FieldOptionComparator implements Comparator<BulkEditWrappers.FieldOption> {
        public Integer compare(BulkEditWrappers.FieldOption a, BulkEditWrappers.FieldOption b) {
            return a.label.compareTo(b.label);
        }
    }
}
