public without sharing class BulkRecordTypeService {

    // Search is scoped to Account only (v1) — a different selection model
    // (explicit record IDs) than the value-match flow in BulkEditService,
    // so it's kept in its own service rather than generalized.
    private static final Schema.SObjectType ACCOUNT_TYPE = Account.sObjectType;

    // Field types safe for a LIKE '%term%' text search. Deliberately mirrors
    // BulkEditService's text-friendly subset, minus PICKLIST/BOOLEAN/numeric
    // types that don't make sense for free-text search.
    private static final Set<Schema.DisplayType> SEARCHABLE_FIELD_TYPES = new Set<Schema.DisplayType>{
        Schema.DisplayType.STRING,
        Schema.DisplayType.PICKLIST,
        Schema.DisplayType.PHONE,
        Schema.DisplayType.EMAIL,
        Schema.DisplayType.URL
    };

    @TestVisible private static Boolean TEST_FORCE_SERVICE_EXCEPTION = false;

    // Unlike BulkEditService (which resolves objects dynamically and checks
    // dsr.isAccessible() via resolveObjectType() for every object), this
    // service hardcodes Account, so that same object-level CRUD check has
    // to be asserted explicitly here rather than inherited for free.
    @TestVisible private static Boolean TEST_FORCE_ACCOUNT_NOT_ACCESSIBLE = false;

    private static void assertAccountAccessible() {
        if (TEST_FORCE_ACCOUNT_NOT_ACCESSIBLE || !ACCOUNT_TYPE.getDescribe().isAccessible()) {
            throw new BulkEditException('You do not have permission to view Account records.');
        }
    }

    public static List<BulkEditWrappers.RecordTypeOption> getRecordTypesForObject() {
        if (TEST_FORCE_SERVICE_EXCEPTION) {
            throw new BulkEditException('Forced error for test coverage.');
        }
        List<BulkEditWrappers.RecordTypeOption> options = new List<BulkEditWrappers.RecordTypeOption>();
        for (Schema.RecordTypeInfo info : ACCOUNT_TYPE.getDescribe().getRecordTypeInfos()) {
            if (!info.isActive() || info.isMaster()) {
                continue;
            }
            options.add(new BulkEditWrappers.RecordTypeOption(info.getRecordTypeId(), info.getName()));
        }
        options.sort(new RecordTypeOptionComparator());
        return options;
    }

    public static List<BulkEditWrappers.FieldOption> getSearchableFields() {
        if (TEST_FORCE_SERVICE_EXCEPTION) {
            throw new BulkEditException('Forced error for test coverage.');
        }
        assertAccountAccessible();
        List<BulkEditWrappers.FieldOption> options = new List<BulkEditWrappers.FieldOption>();
        Map<String, Schema.SObjectField> fieldMap = ACCOUNT_TYPE.getDescribe().fields.getMap();

        for (String fieldApiName : fieldMap.keySet()) {
            Schema.DescribeFieldResult dfr = fieldMap.get(fieldApiName).getDescribe();
            if (!SEARCHABLE_FIELD_TYPES.contains(dfr.getType())) {
                continue;
            }
            if (!dfr.isAccessible()) {
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

    // Re-validates searchFieldApiName against the same allowlist returned by
    // getSearchableFields() — the field name is concatenated directly into
    // the query (dynamic SOQL can't bind a field name), so a cached/stale
    // client value must never be trusted without this check.
    private static Schema.DescribeFieldResult resolveSearchFieldDescribe(String fieldApiName) {
        Map<String, Schema.SObjectField> fieldMap = ACCOUNT_TYPE.getDescribe().fields.getMap();
        Schema.SObjectField sField = fieldMap.get(fieldApiName);
        if (sField == null) {
            throw new BulkEditException('Unknown field: ' + fieldApiName);
        }
        Schema.DescribeFieldResult dfr = sField.getDescribe();
        if (!SEARCHABLE_FIELD_TYPES.contains(dfr.getType()) || !dfr.isAccessible()) {
            throw new BulkEditException('This field is not available for search.');
        }
        return dfr;
    }

    public static List<BulkEditWrappers.RecordSearchResult> searchRecords(Id recordTypeIdFilter, String searchFieldApiName, String searchTerm) {
        assertAccountAccessible();
        Boolean hasRecordTypeFilter = recordTypeIdFilter != null;
        Boolean hasTermFilter = String.isNotBlank(searchTerm) && String.isNotBlank(searchFieldApiName);

        if (!hasRecordTypeFilter && !hasTermFilter) {
            throw new BulkEditException('Please choose a Record Type filter and/or a search term.');
        }

        List<String> conditions = new List<String>();
        if (hasRecordTypeFilter) {
            conditions.add('RecordTypeId = :recordTypeIdFilter');
        }
        if (hasTermFilter) {
            Schema.DescribeFieldResult fieldDfr = resolveSearchFieldDescribe(searchFieldApiName);
            String fieldName = String.escapeSingleQuotes(fieldDfr.getName());
            String escapedTerm = String.escapeSingleQuotes(searchTerm);
            conditions.add(fieldName + ' LIKE \'%' + escapedTerm + '%\'');
        }

        String query = 'SELECT Id, Name, RecordTypeId, RecordType.Name FROM Account WHERE ' +
            String.join(conditions, ' AND ') + ' ORDER BY Name LIMIT 200';

        List<BulkEditWrappers.RecordSearchResult> results = new List<BulkEditWrappers.RecordSearchResult>();
        for (Account acc : (List<Account>) Database.query(query)) {
            results.add(new BulkEditWrappers.RecordSearchResult(
                acc.Id, acc.Name, acc.RecordTypeId, acc.RecordType != null ? acc.RecordType.Name : null
            ));
        }
        return results;
    }

    private class RecordTypeOptionComparator implements Comparator<BulkEditWrappers.RecordTypeOption> {
        public Integer compare(BulkEditWrappers.RecordTypeOption a, BulkEditWrappers.RecordTypeOption b) {
            return a.label.compareTo(b.label);
        }
    }

    private class FieldOptionComparator implements Comparator<BulkEditWrappers.FieldOption> {
        public Integer compare(BulkEditWrappers.FieldOption a, BulkEditWrappers.FieldOption b) {
            return a.label.compareTo(b.label);
        }
    }
}
