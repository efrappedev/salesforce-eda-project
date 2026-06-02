/**
 * MergeTicketService.cls
 * Builds the ComparisonMatrix used by the Merge Review wizard (Step 2).
 *
 * Responsibilities:
 *  - Load live SObject records for all candidates in a ticket.
 *  - Fetch EDA counts via EDARelatedRecordsService (bulk).
 *  - Assemble a ComparisonMatrix: one row per field, one column per candidate.
 *  - Flag EDA-related fields and conflict rows for the LWC to highlight.
 *
 * Key fields compared are defined in KEY_COMPARISON_FIELDS.
 * All fields are filtered through Schema.getGlobalDescribe() before querying.
 */
public without sharing class MergeTicketService {

    // Fields to always show in the comparison table, in display order
    private static final Map<String,List<String>> KEY_COMPARISON_FIELDS =
        new Map<String,List<String>>{
            'Contact' => new List<String>{
                'FirstName', 'LastName', 'Name',
                'Email',
                'hed__AlternateEmail__c', 'Alternative_Email_1__c',
                'Alternative_Email_2__c', 'Alternative_Email_3__c',
                'hed__UniversityEmail__c', 'hed__WorkEmail__c',
                'Phone', 'MobilePhone', 'HomePhone', 'OtherPhone',
                'hed__WorkPhone__c',
                'AccountId',
                'ID_Contact__c',
                'OwnerId',
                'MailingStreet', 'MailingCity', 'MailingState',
                'MailingPostalCode', 'MailingCountry',
                'Birthdate',
                'hed__Preferred_Email__c', 'hed__Preferred_Phone__c'
            },
            'Account' => new List<String>{
                'Name', 'Common_Name__c',
                'Phone', 'Fax',
                'hed__Credentialing_Email__c',
                'AccountNumber',
                'ID_Account__c', 'ID_Prodon__c',
                'Credentialing_Identifier__c',
                'hed__School_Code__c',
                'BillingStreet', 'BillingCity', 'BillingState',
                'BillingPostalCode', 'BillingCountry',
                'Type',
                'OwnerId'
            }
        };

    // Fields flagged with an EDA badge in the UI
    private static final Set<String> EDA_FIELD_NAMES = new Set<String>{
        'hed__AlternateEmail__c', 'hed__UniversityEmail__c', 'hed__WorkEmail__c',
        'hed__WorkPhone__c', 'hed__Preferred_Email__c', 'hed__Preferred_Phone__c',
        'hed__School_Code__c', 'hed__Credentialing_Email__c'
    };

    // ─── Public API ───────────────────────────────────────────────────────────

    public static MergeWrappers.ComparisonMatrix buildComparisonMatrix(Id ticketId) {
        Merge_Ticket__c ticket = [
            SELECT Id, Object_Type__c, Status__c, Selected_Master_Id__c
            FROM Merge_Ticket__c
            WHERE Id = :ticketId LIMIT 1
        ];

        List<Merge_Candidate__c> candidates = [
            SELECT Id, Record_Id__c, Record_Name__c,
                   Is_Master__c, Is_Losing_Record__c
            FROM Merge_Candidate__c
            WHERE Merge_Ticket__c = :ticketId
            ORDER BY Is_Master__c DESC, CreatedDate ASC
        ];

        Set<Id>   sfIds   = new Set<Id>();
        List<String> orderedIds = new List<String>();
        // Saved name at ticket-creation time — used as fallback for merged/deleted records
        Map<String,String> savedNames = new Map<String,String>();
        for (Merge_Candidate__c mc : candidates) {
            if (!String.isBlank(mc.Record_Id__c)) {
                Id sfId = (Id) mc.Record_Id__c;
                sfIds.add(sfId);
                String sfIdStr = String.valueOf(sfId);
                orderedIds.add(sfIdStr);
                if (!String.isBlank(mc.Record_Name__c)) {
                    savedNames.put(sfIdStr, mc.Record_Name__c);
                }
            }
        }

        // ── Load live field values ─────────────────────────────────────────────
        List<String>   queryFields  = buildFieldList(ticket.Object_Type__c);
        Map<Id,SObject> liveRecords = loadLiveRecords(ticket.Object_Type__c, sfIds, queryFields);

        // ── Load pre-merge snapshot for any candidates that no longer exist ────
        // Losing records are deleted by Salesforce after merge. Their field values
        // are preserved in Merge_Log__c.Before_Snapshot_JSON__c (inserted before
        // the merge DML). Use those snapshots to populate the comparison rows.
        Map<String,Map<String,Object>> deletedSnapshots = new Map<String,Map<String,Object>>();
        {
            Boolean anyMissing = false;
            for (Id sfId : sfIds) {
                if (!liveRecords.containsKey(sfId)) { anyMissing = true; break; }
            }
            if (anyMissing) {
                List<Merge_Log__c> logs = [
                    SELECT Before_Snapshot_JSON__c
                    FROM Merge_Log__c
                    WHERE Merge_Ticket__c = :ticketId
                    ORDER BY CreatedDate DESC
                    LIMIT 1
                ];
                if (!logs.isEmpty() && !String.isBlank(logs[0].Before_Snapshot_JSON__c)) {
                    Map<String,Object> raw = (Map<String,Object>)
                        JSON.deserializeUntyped(logs[0].Before_Snapshot_JSON__c);
                    for (String recIdStr : raw.keySet()) {
                        deletedSnapshots.put(recIdStr, (Map<String,Object>) raw.get(recIdStr));
                    }
                }
            }
        }

        // ── EDA counts (bulk, single set of aggregate queries) ────────────────
        Map<Id,MergeWrappers.EDACountsWrapper> edaCounts = ticket.Object_Type__c == 'Contact'
            ? EDARelatedRecordsService.getBulkCountsForContacts(sfIds)
            : new Map<Id,MergeWrappers.EDACountsWrapper>();

        // ── Assemble matrix ───────────────────────────────────────────────────
        MergeWrappers.ComparisonMatrix matrix = new MergeWrappers.ComparisonMatrix();
        matrix.objectType    = ticket.Object_Type__c;
        matrix.savedMasterId = ticket.Selected_Master_Id__c != null
            ? String.valueOf(ticket.Selected_Master_Id__c) : null;
        List<String> missingIds = new List<String>();
        for (Id sfId : sfIds) {
            if (!liveRecords.containsKey(sfId)) missingIds.add(String.valueOf(sfId));
        }
        matrix.missingRecordIds = missingIds;

        // ── Related contacts per Account (Account merges only) ────────────────
        if (ticket.Object_Type__c == 'Account') {
            matrix.relatedContactsByRecordId = loadRelatedContacts(sfIds);
            // Aggregate contact EDA counts up to the Account level so Step 1
            // candidate cards show meaningful Cours/Prog/Afil totals (same data
            // already loaded, zero extra SOQL).
            for (String accIdStr : matrix.relatedContactsByRecordId.keySet()) {
                MergeWrappers.EDACountsWrapper agg = new MergeWrappers.EDACountsWrapper();
                for (MergeWrappers.RelatedContactInfo rci :
                        matrix.relatedContactsByRecordId.get(accIdStr)) {
                    if (rci.edaCounts == null) continue;
                    agg.courseConnections        += rci.edaCounts.courseConnections;
                    agg.programEnrollments       += rci.edaCounts.programEnrollments;
                    agg.affiliations             += rci.edaCounts.affiliations;
                    agg.activeCourseConnections  += rci.edaCounts.activeCourseConnections;
                    agg.activeProgramEnrollments += rci.edaCounts.activeProgramEnrollments;
                }
                agg.computeDerived();
                edaCounts.put((Id) accIdStr, agg);
            }
        }

        Map<String,Schema.SObjectField> fieldDescMap =
            Schema.getGlobalDescribe().get(ticket.Object_Type__c)
                  ?.getDescribe()?.fields?.getMap();

        for (String sfIdStr : orderedIds) {
            Id sfId = (Id) sfIdStr;
            matrix.recordIds.add(sfIdStr);
            SObject rec = liveRecords.get(sfId);
            // Prefer live record name; fall back to pre-merge snapshot; then saved name; last = raw ID
            String displayName = rec != null ? (String) rec.get('Name') : null;
            if (String.isBlank(displayName) && deletedSnapshots.containsKey(sfIdStr)) {
                Object snapName = deletedSnapshots.get(sfIdStr).get('Name');
                if (snapName != null) displayName = String.valueOf(snapName);
            }
            if (String.isBlank(displayName)) displayName = savedNames.get(sfIdStr);
            if (String.isBlank(displayName)) displayName = sfIdStr;
            matrix.recordNames.add(displayName);

            if (edaCounts.containsKey(sfId)) {
                matrix.edaCountsByRecordId.put(sfIdStr, edaCounts.get(sfId));
            }
        }

        // Build one ComparisonRow per field
        for (String fieldName : queryFields) {
            if (fieldName == 'Id') continue;
            MergeWrappers.ComparisonRow row =
                buildRow(fieldName, orderedIds, liveRecords, deletedSnapshots, fieldDescMap);
            if (row != null) matrix.rows.add(row);
        }

        return matrix;
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    private static MergeWrappers.ComparisonRow buildRow(
        String fieldName,
        List<String> orderedIds,
        Map<Id,SObject> liveRecords,
        Map<String,Map<String,Object>> deletedSnapshots,
        Map<String,Schema.SObjectField> fieldDescMap
    ) {
        String lower = fieldName.toLowerCase();
        if (!fieldDescMap.containsKey(lower)) return null;

        Schema.DescribeFieldResult dfr = fieldDescMap.get(lower).getDescribe();
        MergeWrappers.ComparisonRow row = new MergeWrappers.ComparisonRow();
        row.fieldApiName     = fieldName;
        row.fieldLabel       = dfr.getLabel();
        row.fieldType        = String.valueOf(dfr.getType());
        row.isEdaField       = EDA_FIELD_NAMES.contains(fieldName);
        row.isUpdateable     = dfr.isUpdateable();
        row.selectedRecordId = orderedIds.isEmpty() ? null : orderedIds[0]; // default = first (master)

        String firstVal = null;
        for (String sfIdStr : orderedIds) {
            SObject rec = liveRecords.get((Id) sfIdStr);
            String displayVal = null;
            if (rec != null) {
                displayVal = formatLookupAwareName(rec, fieldName, dfr);
            } else if (deletedSnapshots.containsKey(sfIdStr)) {
                // Record was deleted (losing record after merge) — use pre-merge snapshot
                Object rawVal = deletedSnapshots.get(sfIdStr).get(fieldName);
                if (rawVal != null) displayVal = String.valueOf(rawVal);
            }
            if (displayVal != null) row.valuesByRecordId.put(sfIdStr, displayVal);
            if (firstVal == null) {
                firstVal = displayVal;
            } else if (firstVal != displayVal) {
                row.hasConflict = true;
            }
        }

        return row;
    }

    private static String formatLookupAwareName(
        SObject rec, String fieldName, Schema.DescribeFieldResult dfr
    ) {
        Object val = rec.get(fieldName);
        if (val == null) return null;
        if (dfr.getType() == Schema.DisplayType.DATE)     return ((Date)     val).format();
        if (dfr.getType() == Schema.DisplayType.DATETIME) return ((DateTime) val).format();

        // For any reference/lookup field, use the Schema relationship name to resolve Name
        if (dfr.getType() == Schema.DisplayType.REFERENCE) {
            String relName = dfr.getRelationshipName();
            if (!String.isBlank(relName)) {
                try {
                    SObject related = rec.getSObject(relName);
                    if (related != null) {
                        String name = (String) related.get('Name');
                        if (!String.isBlank(name)) return name;
                    }
                } catch (Exception e) { /* fall through to raw ID */ }
            }
        }
        return String.valueOf(val);
    }

    // Builds the ordered field list: priority fields first, then ALL remaining
    // custom (__c) fields from the org's schema — no manual maintenance needed.
    private static List<String> buildFieldList(String objectType) {
        Map<String,Schema.SObjectField> fieldMap =
            Schema.getGlobalDescribe().get(objectType)
                  ?.getDescribe()?.fields?.getMap();
        if (fieldMap == null) return new List<String>{ 'Id', 'Name' };

        // Step 1: priority fields in defined order
        Set<String>  includedLower = new Set<String>{ 'id', 'name' };
        List<String> result        = new List<String>{ 'Id', 'Name' };

        List<String> priority = KEY_COMPARISON_FIELDS.get(objectType);
        if (priority != null) {
            for (String f : priority) {
                String fl = f.toLowerCase();
                if (fieldMap.containsKey(fl) && !includedLower.contains(fl)) {
                    result.add(f);
                    includedLower.add(fl);
                }
            }
        }

        // Step 2: every remaining __c field not already included
        Set<Schema.DisplayType> skipTypes = new Set<Schema.DisplayType>{
            Schema.DisplayType.BASE64,
            Schema.DisplayType.ENCRYPTEDSTRING,
            Schema.DisplayType.ANYTYPE
        };
        Set<String> skipStdFields = new Set<String>{
            'isdeleted','masterrecordid','createdbyid','createddate',
            'lastmodifiedbyid','lastmodifieddate','systemmodstamp',
            'lastactivitydate','lastreferenceddate','lastvieweddate',
            'emailbounceddate','emailbouncedreason','isemailbounced',
            'photouri','individualid','jigsaw','jigsawcontactid'
        };

        List<String> extras = new List<String>();
        for (String lower : fieldMap.keySet()) {
            if (includedLower.contains(lower))   continue;
            if (skipStdFields.contains(lower))   continue;
            if (!lower.endsWith('__c'))          continue;
            Schema.DescribeFieldResult dfr = fieldMap.get(lower).getDescribe();
            if (skipTypes.contains(dfr.getType())) continue;
            if (!dfr.isAccessible())               continue;
            extras.add(dfr.getName());
        }
        extras.sort();
        result.addAll(extras);
        return result;
    }

    // Loads Contacts grouped by AccountId, with EDA counts, for Account merge comparison.
    private static Map<String,List<MergeWrappers.RelatedContactInfo>> loadRelatedContacts(
        Set<Id> accountIds
    ) {
        Map<String,List<MergeWrappers.RelatedContactInfo>> result =
            new Map<String,List<MergeWrappers.RelatedContactInfo>>();
        for (Id accId : accountIds) {
            result.put(String.valueOf(accId), new List<MergeWrappers.RelatedContactInfo>());
        }

        List<Contact> contacts = [
            SELECT Id, Name, AccountId, Email, Phone, MobilePhone
            FROM Contact
            WHERE AccountId IN :accountIds
            ORDER BY AccountId, Name
            LIMIT 300
        ];

        Set<Id> contactIds = new Set<Id>();
        for (Contact c : contacts) contactIds.add(c.Id);

        Map<Id,MergeWrappers.EDACountsWrapper> edaCounts =
            EDARelatedRecordsService.getBulkCountsForContacts(contactIds);

        for (Contact c : contacts) {
            String key = String.valueOf(c.AccountId);
            if (!result.containsKey(key)) continue;
            MergeWrappers.RelatedContactInfo info = new MergeWrappers.RelatedContactInfo();
            info.contactId   = String.valueOf(c.Id);
            info.contactName = c.Name;
            info.edaCounts   = edaCounts.containsKey(c.Id)
                ? edaCounts.get(c.Id) : new MergeWrappers.EDACountsWrapper();
            result.get(key).add(info);
        }
        return result;
    }

    private static Map<Id,SObject> loadLiveRecords(
        String objectType,
        Set<Id> ids,
        List<String> fields
    ) {
        Set<String> fieldSet = new Set<String>(fields);

        // For every REFERENCE field we're querying, add RelationshipName.Name
        // so formatLookupAwareName can show a human-readable value instead of a raw ID.
        Map<String,Schema.SObjectField> fieldMap =
            Schema.getGlobalDescribe().get(objectType)?.getDescribe()?.fields?.getMap();
        if (fieldMap != null) {
            Set<String> queryFieldsLower = new Set<String>();
            for (String f : fields) queryFieldsLower.add(f.toLowerCase());

            for (String fl : queryFieldsLower) {
                if (!fieldMap.containsKey(fl)) continue;
                Schema.DescribeFieldResult dfr = fieldMap.get(fl).getDescribe();
                if (dfr.getType() != Schema.DisplayType.REFERENCE) continue;
                if (!dfr.isAccessible()) continue;
                String relName = dfr.getRelationshipName();
                if (!String.isBlank(relName)) {
                    fieldSet.add(relName + '.Name');
                }
            }
        }

        String query = 'SELECT ' + String.join(new List<String>(fieldSet), ', ') +
                       ' FROM ' + objectType +
                       ' WHERE Id IN :ids';
        Map<Id,SObject> result = new Map<Id,SObject>();
        for (SObject rec : Database.query(query)) {
            result.put(rec.Id, rec);
        }
        return result;
    }
}
