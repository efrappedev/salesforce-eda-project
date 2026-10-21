// "Clean Field" reads each candidate record's own live value straight from
// Salesforce and strips/normalizes invisible or unwanted characters in
// place — see project_prodon_french_narrow_space_bug: pasting a value back
// at the tool to match against (the old Paste Update flow) never survives
// clipboard transport for invisible characters like U+202F, so this feature
// deliberately has no paste/match step at all.
public without sharing class BulkCleanFieldService {

    private static final Integer PREVIEW_SAMPLE_SIZE = 200;

    // Only field types that can actually carry stray whitespace/punctuation
    // — PICKLIST/BOOLEAN/DOUBLE/DATE/etc. (already offered by the broader
    // BulkEditService.getEditableFields()) are filtered out here.
    private static final Set<String> CLEANABLE_FIELD_TYPES = new Set<String>{ 'STRING', 'PHONE', 'EMAIL', 'URL' };

    public static List<BulkEditWrappers.FieldOption> getCleanableFields(String objectApiName) {
        List<BulkEditWrappers.FieldOption> options = new List<BulkEditWrappers.FieldOption>();
        for (BulkEditWrappers.FieldOption opt : BulkEditService.getEditableFields(objectApiName)) {
            if (CLEANABLE_FIELD_TYPES.contains(opt.dataType)) {
                options.add(opt);
            }
        }
        return options;
    }

    // Deterministic 5-step pipeline so each rule's effect is visible in
    // isolation and the combined result never depends on call order:
    //   1. Strip zero-width invisible characters outright (no visible width,
    //      so "replace with space" would be wrong).
    //   2. Replace visible-width exotic space variants — including U+202F,
    //      the confirmed French-locale culprit — with a regular space.
    //   3. Remove every comma-separated item in customCharsToStrip, each
    //      taken as a literal substring (not a regex, not a character set)
    //      — so a single character ("!") and a whole word/phrase ("(older)")
    //      work the same way: removed wherever that exact text appears.
    //   4. Collapse runs of 2+ regular spaces (may be newly created by
    //      steps 2/3) down to one.
    //   5. Trim leading/trailing spaces.
    public static String cleanValue(String raw, Boolean normalizeSpaces, Boolean collapseSpaces, Boolean trimEdges, String customCharsToStrip) {
        if (raw == null) {
            return null;
        }
        String cleaned = raw;

        if (normalizeSpaces == true) {
            cleaned = cleaned.replaceAll('[\\u200B\\u200C\\u200D\\uFEFF]', '');
            cleaned = cleaned.replaceAll('[\\u00A0\\u2000-\\u200A\\u202F\\u205F\\u3000\\t]', ' ');
        }

        // Not String.isNotBlank() — a user may legitimately want to strip a
        // plain space character (e.g. " " typed to remove regular spaces
        // after normalizeSpaces has already converted exotic ones to
        // regular spaces), and isBlank() treats a whitespace-only string as
        // blank, which would silently ignore exactly that input.
        if (customCharsToStrip != null && customCharsToStrip.length() > 0) {
            for (String rawItem : customCharsToStrip.split(',')) {
                String trimmedItem = rawItem.trim();
                // Same isBlank()-style pitfall as above, at the item level:
                // an item that is entirely whitespace (someone listed a
                // literal space as one of the comma-separated items) must
                // not collapse to '' via trim().
                String item = trimmedItem.length() > 0 ? trimmedItem : rawItem;
                if (item.length() > 0) {
                    // String.replace() is a literal substring replace in
                    // Apex, not regex — safe for arbitrary punctuation and
                    // words alike, and removes every occurrence in one call.
                    cleaned = cleaned.replace(item, '');
                }
            }
        }

        if (collapseSpaces == true) {
            cleaned = cleaned.replaceAll(' {2,}', ' ');
        }

        if (trimEdges == true) {
            cleaned = cleaned.trim();
        }

        return cleaned;
    }

    public static BulkEditWrappers.CleanPreviewResult previewCleanup(
        String objectApiName,
        String fieldApiName,
        String filterFieldApiName,
        String filterValue,
        Boolean filterIsBlankValue,
        Boolean normalizeSpaces,
        Boolean collapseSpaces,
        Boolean trimEdges,
        String customCharsToStrip
    ) {
        Schema.SObjectType sType = BulkEditService.resolveObjectType(objectApiName);
        Schema.DescribeFieldResult dfr = BulkEditService.resolveFieldDescribe(sType, fieldApiName);

        String whereClause = buildWhereForCandidates(sType, dfr, filterFieldApiName, filterValue, filterIsBlankValue);
        String fieldName = String.escapeSingleQuotes(dfr.getName());
        String objectName = String.escapeSingleQuotes(sType.getDescribe().getName());
        String displayFieldName = BulkPasteUpdateService.resolveDisplayFieldName(sType);
        Boolean includeDisplayField = String.isNotBlank(displayFieldName) && displayFieldName != fieldName;

        BulkEditWrappers.CleanPreviewResult result = new BulkEditWrappers.CleanPreviewResult();
        result.totalMatching = Database.countQuery('SELECT COUNT() FROM ' + objectName + ' WHERE ' + whereClause);

        String sampleQuery = 'SELECT Id, ' + fieldName + (includeDisplayField ? ', ' + displayFieldName : '') +
            ' FROM ' + objectName + ' WHERE ' + whereClause + ' LIMIT ' + PREVIEW_SAMPLE_SIZE;

        List<SObject> sample = Database.query(sampleQuery);
        result.sampleSize = sample.size();

        for (SObject record : sample) {
            Object rawVal = record.get(dfr.getName());
            String beforeValue = rawVal == null ? null : String.valueOf(rawVal);
            String afterValue = cleanValue(beforeValue, normalizeSpaces, collapseSpaces, trimEdges, customCharsToStrip);
            // Apex's != on String silently ignores zero-width/format
            // Unicode characters (e.g. U+200B) — see the same note in
            // BulkCleanFieldBatch.execute() — so == / != must not be used
            // here even as a fallback; .equals() alone is exact.
            Boolean unchanged = (beforeValue == null) ? (afterValue == null) : beforeValue.equals(afterValue);
            Boolean willChange = !unchanged;
            if (willChange) {
                result.sampleWouldChange++;
            }
            Object rawDisplay = includeDisplayField ? record.get(displayFieldName) : null;
            String display = includeDisplayField && rawDisplay != null ? String.valueOf(rawDisplay) : record.Id;
            result.rows.add(new BulkEditWrappers.CleanPreviewRow(record.Id, display, beforeValue, afterValue, willChange));
        }

        return result;
    }

    // Shared by previewCleanup() and BulkCleanFieldBatch.start(): candidate
    // scope is every populated value of the target field, optionally ANDed
    // with the same cross-filter criterion Bulk Edit already offers. Which
    // of those candidates actually change is decided per record by
    // cleanValue(), not by this WHERE clause.
    public static String buildWhereForCandidates(
        Schema.SObjectType sType,
        Schema.DescribeFieldResult dfr,
        String filterFieldApiName,
        String filterValue,
        Boolean filterIsBlankValue
    ) {
        String whereClause = buildNotBlankClause(dfr);
        if (String.isNotBlank(filterFieldApiName)) {
            Schema.DescribeFieldResult filterDfr = BulkEditService.resolveFilterFieldDescribe(sType, filterFieldApiName);
            whereClause += ' AND ' + BulkEditService.buildWhereClause(filterDfr, filterValue, filterIsBlankValue);
        }
        return whereClause;
    }

    private static String buildNotBlankClause(Schema.DescribeFieldResult dfr) {
        String fieldName = String.escapeSingleQuotes(dfr.getName());
        return '(' + fieldName + ' != null AND ' + fieldName + ' != \'\')';
    }
}
