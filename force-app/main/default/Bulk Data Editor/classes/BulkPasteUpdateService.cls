// Selection model: paste a list of external-id-style values (or raw
// Salesforce Ids) for a chosen search field, resolve each to at most one
// record, then update a target field — either the same value for every
// matched record, or a distinct value per row. See BulkEditService for the
// shared object/field discovery and type-conversion helpers this reuses.
public without sharing class BulkPasteUpdateService {

    // Not a real governor-limit ceiling (Database.Batchable chunking handles
    // thousands of rows fine) — just a sane upper bound against paste
    // mistakes (e.g. an entire spreadsheet pasted by accident).
    private static final Integer MAX_SEARCH_VALUES = 5000;

    @TestVisible private static Boolean TEST_FORCE_SERVICE_EXCEPTION = false;

    public static List<BulkEditWrappers.FieldOption> getSearchableFields(String objectApiName) {
        if (TEST_FORCE_SERVICE_EXCEPTION) {
            throw new BulkEditException('Forced error for test coverage.');
        }
        List<BulkEditWrappers.FieldOption> options = new List<BulkEditWrappers.FieldOption>();
        options.add(new BulkEditWrappers.FieldOption('Id', 'Record ID (Salesforce)', 'ID'));
        options.addAll(BulkEditService.getFilterableFields(objectApiName, null));
        return options;
    }

    public static List<BulkEditWrappers.MatchResult> matchRecords(String objectApiName, String searchFieldApiName, List<String> searchValues, String targetFieldApiName) {
        if (searchValues == null || searchValues.isEmpty()) {
            throw new BulkEditException('Please paste at least one value to search for.');
        }
        if (searchValues.size() > MAX_SEARCH_VALUES) {
            throw new BulkEditException('Too many values pasted (maximum ' + MAX_SEARCH_VALUES + ').');
        }
        if (String.isBlank(searchFieldApiName)) {
            throw new BulkEditException('Please choose a field to search by.');
        }

        Schema.SObjectType sType = BulkEditService.resolveObjectType(objectApiName);
        String objectName = String.escapeSingleQuotes(sType.getDescribe().getName());
        String displayFieldName = resolveDisplayFieldName(sType);
        // Optional: when the LWC already knows which field it's about to
        // overwrite (step 4 of the wizard), it also asks for that field's
        // *current* value here — same query, no extra round trip — so step 5
        // (Review matches) can show Old value next to New value. Left null
        // when the caller doesn't pass one (e.g. future callers that only
        // need to resolve records, not preview a field change).
        Schema.DescribeFieldResult targetDfr = String.isNotBlank(targetFieldApiName)
            ? BulkEditService.resolveFieldDescribe(sType, targetFieldApiName)
            : null;

        // Dedup pasted values while preserving first-seen order, so a
        // duplicate pasted line resolves to the same match row rather than
        // querying/returning it twice.
        List<String> distinctValues = new List<String>();
        Set<String> seen = new Set<String>();
        for (String raw : searchValues) {
            String trimmed = raw == null ? '' : raw.trim();
            if (String.isBlank(trimmed) || seen.contains(trimmed)) {
                continue;
            }
            seen.add(trimmed);
            distinctValues.add(trimmed);
        }
        if (distinctValues.isEmpty()) {
            throw new BulkEditException('Please paste at least one value to search for.');
        }

        Map<String, List<BulkEditWrappers.MatchResult>> resultsByValue = new Map<String, List<BulkEditWrappers.MatchResult>>();
        for (String v : distinctValues) {
            resultsByValue.put(v, new List<BulkEditWrappers.MatchResult>());
        }

        if (searchFieldApiName == 'Id') {
            runIdSearch(objectName, displayFieldName, targetDfr, distinctValues, resultsByValue);
        } else {
            Schema.DescribeFieldResult searchDfr = BulkEditService.resolveFilterFieldDescribe(sType, searchFieldApiName);
            runFieldSearch(objectName, searchDfr, displayFieldName, targetDfr, distinctValues, resultsByValue);
        }

        return classifyResults(distinctValues, resultsByValue);
    }

    // Builds a SELECT field list with no duplicates (case-insensitive),
    // dropping blank entries — used so Id/display-field/target-field/
    // search-field can each be requested independently without risking
    // "duplicate field" query errors when two of them turn out to be the
    // same field (e.g. updating the object's own Name field).
    private static String buildSelectClause(List<String> fieldNames) {
        Set<String> seenLower = new Set<String>();
        List<String> ordered = new List<String>();
        for (String f : fieldNames) {
            if (String.isNotBlank(f) && !seenLower.contains(f.toLowerCase())) {
                seenLower.add(f.toLowerCase());
                ordered.add(f);
            }
        }
        return String.join(ordered, ', ');
    }

    private static void runIdSearch(
        String objectName,
        String displayFieldName,
        Schema.DescribeFieldResult targetDfr,
        List<String> distinctValues,
        Map<String, List<BulkEditWrappers.MatchResult>> resultsByValue
    ) {
        Set<Id> idSet = new Set<Id>();
        Map<Id, String> idToRawValue = new Map<Id, String>();
        for (String v : distinctValues) {
            try {
                Id recId = (Id) v;
                idSet.add(recId);
                idToRawValue.put(recId, v);
            } catch (Exception ex) {
                // Not a valid Id for any object — left unmatched, surfaced as NotFound.
            }
        }
        if (idSet.isEmpty()) {
            return;
        }

        String targetFieldName = targetDfr != null ? targetDfr.getName() : null;
        String query = 'SELECT ' + buildSelectClause(new List<String>{ 'Id', displayFieldName, targetFieldName }) +
            ' FROM ' + objectName + ' WHERE Id IN :idSet';
        for (SObject record : Database.query(query)) {
            // idToRawValue is built 1:1 from idSet just above, and this query
            // filters WHERE Id IN :idSet, so every record returned here is
            // guaranteed to have a matching entry — no null-guard needed.
            String rawValue = idToRawValue.get(record.Id);
            String display = String.isNotBlank(displayFieldName) ? String.valueOf(record.get(displayFieldName)) : record.Id;
            String currentValue = targetFieldName != null ? String.valueOf(record.get(targetFieldName)) : null;
            resultsByValue.get(rawValue).add(new BulkEditWrappers.MatchResult(rawValue, record.Id, display, 'Matched', currentValue));
        }
    }

    private static void runFieldSearch(
        String objectName,
        Schema.DescribeFieldResult searchDfr,
        String displayFieldName,
        Schema.DescribeFieldResult targetDfr,
        List<String> distinctValues,
        Map<String, List<BulkEditWrappers.MatchResult>> resultsByValue
    ) {
        String searchFieldName = String.escapeSingleQuotes(searchDfr.getName());
        // IN-list bind variables require the bind collection's Apex type to
        // match the field's SOQL type (e.g. a numeric field rejects a bound
        // List<String>), so each pasted value is converted to a properly
        // typed/escaped SOQL literal here instead of relying on a bind
        // variable. Values that fail conversion (e.g. non-numeric text
        // pasted against a Number field) are simply omitted from the IN
        // list — they naturally end up classified as NotFound below.
        String inClause = buildInClauseLiteral(searchDfr.getType(), distinctValues);
        if (inClause == null) {
            return;
        }

        Boolean includeDisplayField = String.isNotBlank(displayFieldName) && displayFieldName != searchFieldName;
        String targetFieldName = targetDfr != null ? targetDfr.getName() : null;
        String query = 'SELECT ' + buildSelectClause(new List<String>{ 'Id', searchFieldName, displayFieldName, targetFieldName }) +
            ' FROM ' + objectName + ' WHERE ' + searchFieldName + ' IN ' + inClause;

        for (SObject record : Database.query(query)) {
            Object rawFieldValue = record.get(searchDfr.getName());
            String rawValue = normalizeFieldValue(searchDfr.getType(), rawFieldValue);
            // SOQL text comparisons are case-insensitive, but resultsByValue
            // is keyed by the exact-case pasted string — a case-mismatched
            // pasted value (e.g. 'pu-0' vs a stored 'PU-0') can match here at
            // the query level yet still miss this Map lookup, ending up
            // NotFound below rather than Matched.
            if (!resultsByValue.containsKey(rawValue)) {
                continue;
            }
            String display = includeDisplayField ? String.valueOf(record.get(displayFieldName)) : (String.isNotBlank(displayFieldName) ? rawValue : record.Id);
            String currentValue = targetFieldName != null ? String.valueOf(record.get(targetFieldName)) : null;
            resultsByValue.get(rawValue).add(new BulkEditWrappers.MatchResult(rawValue, record.Id, display, 'Matched', currentValue));
        }
    }

    // SObject.get() boxes a Date field's value as an Object whose generic
    // String.valueOf() renders "yyyy-MM-dd HH:mm:ss" (matching the internal
    // Datetime-at-midnight representation) instead of the plain "yyyy-MM-dd"
    // that toSearchLiteral()/Date.valueOf() produce for the pasted search
    // value — so a same-day match would otherwise never line up as equal
    // strings. Cast explicitly for DATE to keep both sides in the same format.
    // The only caller queries WHERE searchFieldName IN <non-null literals>,
    // so record.get(searchDfr.getName()) is guaranteed non-null here.
    private static String normalizeFieldValue(Schema.DisplayType dt, Object rawFieldValue) {
        if (dt == Schema.DisplayType.DATE) {
            return String.valueOf((Date) rawFieldValue);
        }
        return String.valueOf(rawFieldValue);
    }

    private static List<BulkEditWrappers.MatchResult> classifyResults(
        List<String> distinctValues,
        Map<String, List<BulkEditWrappers.MatchResult>> resultsByValue
    ) {
        List<BulkEditWrappers.MatchResult> finalResults = new List<BulkEditWrappers.MatchResult>();
        for (String v : distinctValues) {
            List<BulkEditWrappers.MatchResult> matches = resultsByValue.get(v);
            if (matches.isEmpty()) {
                finalResults.add(new BulkEditWrappers.MatchResult(v, null, null, 'NotFound', null));
            } else if (matches.size() == 1) {
                finalResults.add(matches[0]);
            } else {
                for (BulkEditWrappers.MatchResult m : matches) {
                    finalResults.add(new BulkEditWrappers.MatchResult(m.searchValue, m.recordId, m.recordDisplay, 'Duplicate', m.currentValue));
                }
            }
        }
        return finalResults;
    }

    // Every custom object requires a Name field, and most standard objects
    // (Account, Contact via compound Name, etc.) expose one too — used purely
    // to give the user a human-readable label for each matched row. Falls
    // back to the record Id itself (handled by callers) when absent or not
    // accessible to the running user.
    public static String resolveDisplayFieldName(Schema.SObjectType sType) {
        Map<String, Schema.SObjectField> fieldMap = sType.getDescribe().fields.getMap();
        Schema.SObjectField nameField = fieldMap.get('Name');
        if (nameField != null && nameField.getDescribe().isAccessible()) {
            return 'Name';
        }
        return null;
    }

    private static String buildInClauseLiteral(Schema.DisplayType dt, List<String> values) {
        List<String> literals = new List<String>();
        for (String v : values) {
            String literal = toSearchLiteral(dt, v);
            if (literal != null) {
                literals.add(literal);
            }
        }
        if (literals.isEmpty()) {
            return null;
        }
        return '(' + String.join(literals, ',') + ')';
    }

    // The only caller (buildInClauseLiteral, fed by distinctValues) has
    // already filtered out blank pasted lines in matchRecords(), so
    // rawValue is never blank here.
    private static String toSearchLiteral(Schema.DisplayType dt, String rawValue) {
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
            return null;
        }
    }
}
