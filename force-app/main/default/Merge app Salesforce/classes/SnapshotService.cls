/**
 * SnapshotService.cls
 * Captures and serializes SObject state as immutable JSON snapshots for audit purposes.
 *
 * Key design decision: uses getPopulatedFieldsAsMap() instead of iterating the full
 * schema describe. This means we capture exactly what was queried — no risk of NullPointer
 * on unqueried fields, and the snapshot is automatically bounded by the caller's SOQL.
 *
 * Snapshot format: Map<fieldApiName, value> plus __meta_* keys for audit metadata.
 */
public without sharing class SnapshotService {

    // Field display types that must never appear in a snapshot (encrypted / binary)
    private static final Set<String> EXCLUDED_DISPLAY_TYPES = new Set<String>{
        'ENCRYPTEDSTRING', 'BASE64'
    };

    // System fields that add no audit value
    private static final Set<String> EXCLUDED_FIELD_NAMES = new Set<String>{
        'systemmodstamp', 'lastvieweddate', 'lastreferenceddate', 'jigsaw',
        'jigsawcontactid', 'cleanstatus'
    };

    // ─── Schema describe cache (once per transaction) ─────────────────────────

    private static final Map<String, Map<String,Schema.SObjectField>> DESCRIBE_CACHE =
        new Map<String, Map<String,Schema.SObjectField>>();

    // ─── Core snapshot capture ────────────────────────────────────────────────

    /**
     * Captures all queried (populated) fields from an SObject into a flat map.
     * The caller must ensure the record was queried with all desired fields.
     */
    public static Map<String,Object> captureSnapshot(SObject record) {
        if (record == null) return new Map<String,Object>();

        String objectType = String.valueOf(record.getSObjectType());
        Map<String,Schema.SObjectField> fieldDescMap = getDescribeMap(objectType);
        Map<String,Object> snapshot = new Map<String,Object>();

        for (String fieldName : record.getPopulatedFieldsAsMap().keySet()) {
            String lower = fieldName.toLowerCase();
            if (EXCLUDED_FIELD_NAMES.contains(lower)) continue;

            if (fieldDescMap.containsKey(lower)) {
                String displayType = String.valueOf(
                    fieldDescMap.get(lower).getDescribe().getType()
                );
                if (EXCLUDED_DISPLAY_TYPES.contains(displayType)) continue;
            }

            snapshot.put(fieldName, record.getPopulatedFieldsAsMap().get(fieldName));
        }

        snapshot.put('__meta_capturedAt',    String.valueOf(System.now()));
        snapshot.put('__meta_capturedBy',    UserInfo.getUserId());
        snapshot.put('__meta_objectType',    objectType);

        return snapshot;
    }

    public static String captureAndSerialize(SObject record) {
        return JSON.serialize(captureSnapshot(record));
    }

    // ─── Bulk capture ─────────────────────────────────────────────────────────

    /**
     * Returns Map<recordIdString, snapshotMap> for a list of records.
     * Zero extra SOQL — assumes records are already loaded.
     */
    public static Map<String,Map<String,Object>> captureSnapshotsBulk(List<SObject> records) {
        Map<String,Map<String,Object>> result = new Map<String,Map<String,Object>>();
        for (SObject rec : records) {
            result.put(String.valueOf(rec.Id), captureSnapshot(rec));
        }
        return result;
    }

    public static String serializeBulkSnapshots(List<SObject> records) {
        return JSON.serialize(captureSnapshotsBulk(records));
    }

    // ─── Diff ─────────────────────────────────────────────────────────────────

    /**
     * Returns only the fields that changed between two snapshots.
     * Structure: { fieldName: { before: X, after: Y } }
     * Skips __meta_* audit keys.
     */
    public static Map<String,Object> diffSnapshots(
        Map<String,Object> before,
        Map<String,Object> after
    ) {
        Map<String,Object> diff = new Map<String,Object>();
        Set<String> allKeys = new Set<String>();
        allKeys.addAll(before.keySet());
        allKeys.addAll(after.keySet());

        for (String key : allKeys) {
            if (key.startsWith('__meta_')) continue;
            Object bVal = before.get(key);
            Object aVal = after.get(key);
            if (String.valueOf(bVal) != String.valueOf(aVal)) {
                diff.put(key, new Map<String,Object>{ 'before' => bVal, 'after' => aVal });
            }
        }
        return diff;
    }

    // ─── Deserialization ──────────────────────────────────────────────────────

    public static Map<String,Object> deserialize(String jsonStr) {
        if (String.isBlank(jsonStr)) return new Map<String,Object>();
        return (Map<String,Object>) JSON.deserializeUntyped(jsonStr);
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    private static Map<String,Schema.SObjectField> getDescribeMap(String objectType) {
        if (!DESCRIBE_CACHE.containsKey(objectType)) {
            Schema.SObjectType sType = Schema.getGlobalDescribe().get(objectType);
            DESCRIBE_CACHE.put(
                objectType,
                sType != null
                    ? sType.getDescribe().fields.getMap()
                    : new Map<String,Schema.SObjectField>()
            );
        }
        return DESCRIBE_CACHE.get(objectType);
    }
}
