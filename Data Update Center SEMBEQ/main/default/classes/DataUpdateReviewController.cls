/**
 * DataUpdateReviewController.cls
 * Internal (authenticated, with sharing) controller for reviewing and applying
 * Data_Update_Request__c requests created by DataUpdatePortalController.
 * Unlike the public portal, real FLS applies here: a catalog field the
 * logged-in user can't access/update is silently excluded, never applied
 * "because it's internal."
 *
 * Adapted from DataUpdateReviewController.cls (Case-based framework), plus new
 * inbox/workflow methods modeled on MergeController.cls's request-status surface
 * (getRequests/getRequestCount/reopenRequest), simplified because Data_Update_Request__c
 * has no candidates to compare and no legacy HIST-less data to backfill — Notes__c
 * here is purely a [HIST:...] chain, newest entry first, from the record's creation.
 */
public with sharing class DataUpdateReviewController {

    @TestVisible private static Boolean TEST_FORCE_ERROR = false;
    // Fails a rollback after the record update, to prove the savepoint undoes it.
    @TestVisible private static Boolean TEST_FORCE_ROLLBACK_DML_ERROR = false;
    @TestVisible private static Boolean TEST_FORCE_APPLY_DML_ERROR = false;

    /** Sentinel value for formFilter meaning "tickets whose source form was hard-deleted". */
    public static final String DELETED_FORMS_FILTER = '__DELETED_FORMS__';

    public class RequestNotFoundException extends Exception {}

    /** Custom permission (PS "Data Update Center – Multi-Ticket Review") that turns on grouped review. */
    public static final String MULTI_TICKET_REVIEW_PERMISSION = 'Data_Update_Multi_Ticket_Review';

    /** True when the user may review a record's tickets together (list grouped by record). */
    @AuraEnabled(cacheable=true)
    public static Boolean getCanMultiTicketReview() {
        return FeatureManagement.checkPermission(MULTI_TICKET_REVIEW_PERMISSION);
    }

    // Tests can't insert CMDT rows — they name the "multiple submissions" forms here instead.
    @TestVisible private static Set<String> multiSubmissionFormsForTest;

    /**
     * Forms with "Multiple submissions" on (Allow_Duplicate_Open_Requests__c, e.g. Église Update).
     * Only their tickets are grouped for multi-ticket review: a record with several open tickets of
     * other forms (a person with 2 forgotten tickets) keeps one ticket per review.
     */
    public static Set<String> getMultiSubmissionForms() {
        if (Test.isRunningTest() && multiSubmissionFormsForTest != null) return multiSubmissionFormsForTest;
        Set<String> names = new Set<String>();
        for (Data_Update_Form__mdt f : DucFormConfigStore.forms()) {
            if (f.Allow_Duplicate_Open_Requests__c == true) names.add(f.DeveloperName);
        }
        return names;
    }

    /** Tracks, per field API name, the most recent log entry that touched it (apply or rollback). */
    private class FieldTouch {
        String actionType;
        Id     logId;
    }

    /** Latest row of a History_Only field's history object for one target record. */
    @TestVisible private class HistoryPoint {
        String value;
        String dateValue;
    }

    /** The most recent Data_Update_Request__c associated with a locked target record. */
    private class LatestRequestInfo {
        Id     requestId;
        String requestNumber;
        String status;
    }

    // ─── Review de un request ────────────────────────────────────────────────

    @AuraEnabled
    public static DataUpdateWrapper.ReviewSummary getReviewSummary(Id requestId) {
        DataUpdateWrapper.ReviewSummary result = new DataUpdateWrapper.ReviewSummary();
        try {
            if (TEST_FORCE_ERROR) throw new AuraHandledException('TEST_FORCE_ERROR');

            Data_Update_Request__c t = queryRequest(requestId);
            DataUpdateFormConfigService.FormConfig config = resolveRequestConfig(t);
            Map<String, String> proposed = parseProposedValues(t.Proposed_Values_JSON__c, config);
            List<DataUpdateFormConfigService.FormFieldConfig> accessibleFields = getAccessibleFields(config, false);
            SObject targetRecord = queryCurrentValues(config, t.Target_Record_Id__c, accessibleFields);

            Integer changedCount = 0;
            if (targetRecord != null) {
                for (DataUpdateFormConfigService.FormFieldConfig fc : accessibleFields) {
                    if (!proposed.containsKey(fc.fieldApiName)) continue;
                    // Every History_Only value is a new data point, even if equal to the last one.
                    if (DataUpdateFormConfigService.isHistoryOnly(fc)) {
                        changedCount++;
                        continue;
                    }
                    if (!valueToString(targetRecord.get(fc.fieldApiName)).equals(proposed.get(fc.fieldApiName))) {
                        changedCount++;
                    }
                }
                // Each pasted history line is one change.
                for (DataUpdateFormConfigService.FormFieldConfig tc : getAccessibleTables(config, false)) {
                    TableValue tv = parseTableValue(proposed.get(tc.fieldApiName));
                    if (tv != null) changedCount += tv.rows.size();
                }
            }

            result.success           = true;
            result.changedFieldCount = changedCount;
            result.requestClosed      = isTerminal(t.Status__c);
        } catch (Exception e) {
            result.success      = false;
            result.errorMessage = 'GENERIC_ERROR';
        }
        return result;
    }

    @AuraEnabled
    public static DataUpdateWrapper.ComparisonData getComparisonData(Id requestId) {
        DataUpdateWrapper.ComparisonData result = new DataUpdateWrapper.ComparisonData();
        try {
            if (TEST_FORCE_ERROR) throw new AuraHandledException('TEST_FORCE_ERROR');

            Data_Update_Request__c t = queryRequest(requestId);
            result.formDeveloperName = t.Update_Form_DeveloperName__c;
            result.formLabel         = t.Update_Form_Label__c;

            DataUpdateFormConfigService.FormConfig config = resolveRequestConfig(t);
            Map<String, String> proposed = parseProposedValues(t.Proposed_Values_JSON__c, config);
            List<DataUpdateFormConfigService.FormFieldConfig> accessibleFields = getAccessibleFields(config, false);
            SObject targetRecord = queryCurrentValues(config, t.Target_Record_Id__c, accessibleFields);
            if (targetRecord == null) {
                result.success      = false;
                result.errorMessage = 'RECORD_NOT_FOUND';
                return result;
            }

            Map<String, FieldTouch> fieldTouches = getFieldTouchMap(requestId);
            Map<String, HistoryPoint> latestHistory = queryLatestHistoryPoints(accessibleFields, t.Target_Record_Id__c);
            Map<String, HistoryPoint> latestHistorize = queryLatestHistorizePoints(accessibleFields, t.Target_Record_Id__c);

            for (DataUpdateFormConfigService.FormFieldConfig fc : accessibleFields) {
                if (!proposed.containsKey(fc.fieldApiName)) continue;

                Boolean historyOnly = DataUpdateFormConfigService.isHistoryOnly(fc);
                HistoryPoint latest = latestHistory.get(fc.fieldApiName);
                String currentVal  = historyOnly
                    ? (latest != null ? latest.value : '')
                    : valueToString(targetRecord.get(fc.fieldApiName));
                String proposedVal = proposed.get(fc.fieldApiName);
                // A History_Only value is always a new row to add, even if equal to the last one.
                Boolean isDifferent = historyOnly || !currentVal.equals(proposedVal);
                if (!isDifferent) {
                    DataUpdateWrapper.ComparisonField same = new DataUpdateWrapper.ComparisonField();
                    same.fieldApiName   = fc.fieldApiName;
                    same.fieldLabelFr   = fc.labelFr;
                    same.fieldLabelEn   = fc.labelEn;
                    same.sectionLabelFr = fc.sectionLabelFr;
                    same.sectionLabelEn = fc.sectionLabelEn;
                    same.submittedValue = proposedVal;
                    same.currentValue   = currentVal;
                    same.isDifferent    = false;
                    result.unchangedFields.add(same);
                    continue;
                }

                FieldTouch touch = fieldTouches.get(fc.fieldApiName);

                DataUpdateWrapper.ComparisonField cf = new DataUpdateWrapper.ComparisonField();
                cf.fieldApiName          = fc.fieldApiName;
                cf.fieldLabelFr          = fc.labelFr;
                cf.fieldLabelEn          = fc.labelEn;
                cf.sectionLabelFr        = fc.sectionLabelFr;
                cf.sectionLabelEn        = fc.sectionLabelEn;
                cf.submittedValue        = proposedVal;
                cf.currentValue          = currentVal;
                cf.isDifferent           = isDifferent;
                cf.previouslyRolledBack  = touch != null && touch.actionType == 'ROLLBACK_COMPLETED';
                cf.isHistoryOnly         = historyOnly;
                if (historyOnly) {
                    cf.currentValueDate = latest != null ? latest.dateValue : '';
                    cf.historyDate      = String.isNotBlank(fc.historyTargetDateFieldApiName)
                        ? String.valueOf(resolveHistoryDate(fc, proposed, t))
                        : '';
                }
                if (fc.historyMode == 'Historize') {
                    HistoryPoint last = latestHistorize.get(fc.fieldApiName);
                    cf.isHistorize        = true;
                    cf.historyObjectLabel = historyObjectLabel(fc.historyTargetObjectApiName);
                    cf.historyLastValue   = last != null ? last.value : '';
                    cf.historyLastDate    = last != null ? last.dateValue : '';
                    cf.historyDate        = String.isNotBlank(fc.historyTargetDateFieldApiName)
                        ? resolveHistorizePreviewDate(fc, proposed)
                        : '';
                }
                result.fields.add(cf);
            }

            markMainTargets(result, config, t.Target_Record_Id__c);
            setSaveOptions(result, config, t.Target_Record_Id__c);

            for (DataUpdateFormConfigService.FormFieldConfig tc : getAccessibleTables(config, false)) {
                TableValue tv = parseTableValue(proposed.get(tc.fieldApiName));
                if (tv == null) continue;
                DataUpdateWrapper.ComparisonTable ct = buildComparisonTable(tc, tv, t.Target_Record_Id__c);
                FieldTouch touch = fieldTouches.get(tc.fieldApiName);
                ct.previouslyRolledBack = touch != null && touch.actionType == 'ROLLBACK_COMPLETED';
                result.tables.add(ct);
            }

            result.success      = true;
            result.requestId     = t.Id;
            result.recordId     = t.Target_Record_Id__c;
            result.recordName   = valueToString(targetRecord.get(config.recordNameFieldApiName));
            result.requestClosed = isTerminal(t.Status__c);
            result.formDeleted   = config.isFallback == true;
            result.requestNumber  = t.Name;
            result.requestedName  = t.Requested_Name__c;
            result.requestedEmail = t.Requested_Email__c;
            result.createdDate    = t.CreatedDate;
            result.status         = t.Status__c;
            result.isLocked      = String.isNotBlank(config.lockFieldApiName)
                && isFieldAccessible(config.targetObjectApiName, config.lockFieldApiName)
                && targetRecord.get(config.lockFieldApiName) == true;
            // A closed ticket can't unlock while another ticket on the same record is still
            // open (unlockRecord would refuse with REQUEST_STILL_OPEN) — tell the panel up front.
            if (result.isLocked && result.requestClosed) {
                Id targetId = toIdOrNull(t.Target_Record_Id__c);
                LatestRequestInfo other = getOpenRequestInfo(config, new Set<Id>{ targetId }).get(targetId);
                result.otherOpenRequestNumber = other != null ? other.requestNumber : null;
            }
        } catch (Exception e) {
            result.success      = false;
            result.errorMessage = 'GENERIC_ERROR';
        }
        return result;
    }

    @AuraEnabled
    public static DataUpdateWrapper.ApplyResult applySelectedUpdates(Id requestId, List<String> fieldsToApply) {
        return applySelectedUpdatesWithTables(requestId, fieldsToApply, null);
    }

    /**
     * Same as applySelectedUpdates, plus the History_Table lines staff kept:
     * tableSelectionsJson = {"HistoryObject#table":[line index, ...]}. A kept line whose date
     * already has a history row for this record OVERWRITES that row (staff chose "Overwrite" in
     * the panel); any other kept line is inserted as a new row. A table missing from the map
     * applies nothing.
     */
    @AuraEnabled
    public static DataUpdateWrapper.ApplyResult applySelectedUpdatesWithTables(Id requestId, List<String> fieldsToApply, String tableSelectionsJson) {
        return applyCore(requestId, fieldsToApply, tableSelectionsJson, null, null);
    }

    /**
     * Same as applySelectedUpdatesWithTables, plus the "Save in" / "Preferred" choices staff made
     * on email and phone rows: optionsJson =
     * {"overrides":{"FormField":"OtherField"}, "preferred":{"EMAIL":"FormField","PHONE":"FormField"}}.
     */
    @AuraEnabled
    public static DataUpdateWrapper.ApplyResult applySelectedUpdatesWithOptions(Id requestId, List<String> fieldsToApply,
            String tableSelectionsJson, String optionsJson) {
        Map<String, Object> options;
        try {
            options = String.isBlank(optionsJson) ? new Map<String, Object>()
                : (Map<String, Object>) JSON.deserializeUntyped(optionsJson);
        } catch (Exception e) {
            DataUpdateWrapper.ApplyResult bad = new DataUpdateWrapper.ApplyResult();
            bad.success      = false;
            bad.errorMessage = 'GENERIC_ERROR';
            return bad;
        }
        return applyCore(requestId, fieldsToApply, tableSelectionsJson,
            stringMap(options.get('overrides')), null, stringMap(options.get('preferred')));
    }

    /** {key: value} of a JSON object, null values dropped; empty when it isn't an object. */
    public static Map<String, String> stringMap(Object raw) {
        Map<String, String> out = new Map<String, String>();
        if (raw instanceof Map<String, Object>) {
            Map<String, Object> m = (Map<String, Object>) raw;
            for (String k : m.keySet()) {
                if (m.get(k) != null) out.put(k, String.valueOf(m.get(k)));
            }
        }
        return out;
    }

    /**
     * Shared apply. Used as-is by the one-ticket review, and by the grouped review
     * (DataUpdateMultiTicketReviewController) with two extras:
     *  - targetOverrides {formField: otherField}: staff chose to save the value in another field
     *    of the same kind (e.g. a phone into Work_Phone__c because Phone is taken). The
     *    redirected field gets its own decision with an explicit before/after (it isn't in the
     *    submit snapshot), so its rollback restores the right value.
     *  - notes: extra decision keys starting with "__" (group context, lines not applied) — shown
     *    in the History tab, never a field.
     * An apply with nothing selected is allowed: the ticket closes as Applied with nothing changed.
     */
    public static DataUpdateWrapper.ApplyResult applyCore(Id requestId, List<String> fieldsToApply, String tableSelectionsJson,
            Map<String, String> targetOverrides, Map<String, Object> notes) {
        return applyCore(requestId, fieldsToApply, tableSelectionsJson, targetOverrides, notes, null);
    }

    /**
     * preferred {EMAIL|PHONE: form field}: staff marked that row "Preferred" — on an EDA contact the
     * field its value is saved in becomes hed__Preferred_Email__c / hed__PreferredPhone__c (noted
     * with the value before, so a rollback of that field restores the preference too).
     */
    public static DataUpdateWrapper.ApplyResult applyCore(Id requestId, List<String> fieldsToApply, String tableSelectionsJson,
            Map<String, String> targetOverrides, Map<String, Object> notes, Map<String, String> preferred) {
        DataUpdateWrapper.ApplyResult result = new DataUpdateWrapper.ApplyResult();
        Id logId;
        try {
            if (TEST_FORCE_ERROR) throw new AuraHandledException('TEST_FORCE_ERROR');

            // Row lock first: two staff applying the same ticket at once run one after the
            // other, and the second one then sees Applied and stops here.
            List<Data_Update_Request__c> rowLock = [SELECT Id FROM Data_Update_Request__c WHERE Id = :requestId FOR UPDATE];
            Data_Update_Request__c t = queryRequest(requestId);
            if (isTerminal(t.Status__c)) {
                result.success      = false;
                result.errorMessage = 'TICKET_ALREADY_CLOSED';
                return result;
            }

            DataUpdateFormConfigService.FormConfig config = resolveRequestConfig(t);
            Map<String, String> proposed = parseProposedValues(t.Proposed_Values_JSON__c, config);
            List<DataUpdateFormConfigService.FormFieldConfig> accessibleFields = getAccessibleFields(config, true);

            Schema.SObjectType targetType = DataUpdateFormConfigService.globalTypes().get(config.targetObjectApiName);
            Map<String, Schema.SObjectField> fieldMap = targetType.getDescribe().fields.getMap();
            Set<String> selected = fieldsToApply == null ? new Set<String>() : new Set<String>(fieldsToApply);
            // One-ticket apply: remember what staff left unchecked, listed under the entry in Historique.
            if (notes == null) notes = buildNotAppliedNotes(t, config, proposed, accessibleFields, selected);

            logId = getOrCreatePendingLogId(t, config);

            SObject targetRecord = targetType.newSObject(t.Target_Record_Id__c);
            Map<String, Object> selectedFieldValues = new Map<String, Object>();
            List<SObject> historyRows = new List<SObject>();
            Integer updatedCount = 0;

            // Pass 1: put every selected value onto targetRecord first, so a paired
            // History_Date_Source_Field_API_Name__c value (e.g. a visitor-submitted date on a
            // sibling field) is guaranteed present before any history row is built in pass 2,
            // regardless of Display_Order__c iteration order.
            Integer targetFieldCount = 0;
            List<DataUpdateFormConfigService.FormFieldConfig> historyOnlyFields = new List<DataUpdateFormConfigService.FormFieldConfig>();
            Map<String, Object> redirectedValues = new Map<String, Object>();
            Map<String, String> redirectedFrom = new Map<String, String>();
            // Form field → the field its value is really written in (after "Save in" / EDA redirects).
            Map<String, String> placedIn = new Map<String, String>();
            // EDA contact: Email's / Phone's answer is saved in the preferred field of its kind (see mainTargets).
            Map<String, EmailTarget> mainTo = mainTargets(config.targetObjectApiName, t.Target_Record_Id__c, fieldMap);
            Map<String, DataUpdateFormConfigService.FormFieldConfig> ownPlaced = new Map<String, DataUpdateFormConfigService.FormFieldConfig>();
            for (DataUpdateFormConfigService.FormFieldConfig fc : accessibleFields) {
                if (selected.contains(fc.fieldApiName) && proposed.containsKey(fc.fieldApiName)) {
                    ownPlaced.put(placeOf(targetOverrides, fc.fieldApiName).toLowerCase(), fc);
                }
            }
            // Email (Phone) and its preferred field both answered: only one can be the main one. Same
            // value → the field's own answer covers Email; otherwise Email's answer wins (staff
            // unchecks Email to keep the other one) and the field's own answer is listed as not applied.
            Map<String, DataUpdateFormConfigService.FormFieldConfig> mainFcByKind = new Map<String, DataUpdateFormConfigService.FormFieldConfig>();
            Map<String, DataUpdateFormConfigService.FormFieldConfig> destFcByKind = new Map<String, DataUpdateFormConfigService.FormFieldConfig>();
            Set<String> skipped = new Set<String>();
            for (String kind : mainTo.keySet()) {
                DataUpdateFormConfigService.FormFieldConfig mainFc = ownPlaced.get(MAIN_FIELD_BY_KIND.get(kind).toLowerCase());
                if (mainFc == null || mainFc.historyMode == 'Historize') continue;
                String dest = mainTo.get(kind).field;
                DataUpdateFormConfigService.FormFieldConfig destFc = dest != null ? ownPlaced.get(dest.toLowerCase()) : null;
                mainFcByKind.put(kind, mainFc);
                if (destFc != null) destFcByKind.put(kind, destFc);
                if (String.isBlank(proposed.get(mainFc.fieldApiName))) {
                    // A blank Email is ignored by EDA, and blanking the preferred field is refused.
                    skipped.add(mainFc.fieldApiName);
                    notes = addNotApplied(notes, mainFc, proposed.get(mainFc.fieldApiName), kind + '_EMPTY');
                } else if (destFc != null && sameValue(kind, proposed.get(mainFc.fieldApiName), proposed.get(destFc.fieldApiName))) {
                    skipped.add(mainFc.fieldApiName);
                } else if (destFc != null) {
                    skipped.add(destFc.fieldApiName);
                    notes = addNotApplied(notes, destFc, proposed.get(destFc.fieldApiName), kind + '_PREFERRED_CONFLICT');
                }
            }
            for (DataUpdateFormConfigService.FormFieldConfig fc : accessibleFields) {
                if (!selected.contains(fc.fieldApiName)) continue;
                if (!proposed.containsKey(fc.fieldApiName) || skipped.contains(fc.fieldApiName)) continue;

                if (DataUpdateFormConfigService.isHistoryOnly(fc)) {
                    historyOnlyFields.add(fc);
                    updatedCount++;
                    continue;
                }

                Schema.SObjectField field = fieldMap.get(fc.fieldApiName.toLowerCase());
                if (field == null) continue;

                Schema.DisplayType fieldType = field.getDescribe().getType();
                String redirect = targetOverrides != null ? targetOverrides.get(fc.fieldApiName) : null;
                // EDA reverts a direct Email / Phone write: Email (the form's field, or the place staff
                // picked) goes to the preferred field of its kind, which EDA copies into Email.
                for (String kind : mainTo.keySet()) {
                    if (fc.historyMode == 'Historize' || !placeOf(targetOverrides, fc.fieldApiName).equalsIgnoreCase(MAIN_FIELD_BY_KIND.get(kind))) continue;
                    if (mainTo.get(kind).field == null) throw new EmailPreferenceException(PREFERENCE_UNKNOWN_BY_KIND.get(kind));
                    redirect = mainTo.get(kind).field;
                }
                if (String.isNotBlank(redirect) && !redirect.equalsIgnoreCase(fc.fieldApiName)) {
                    Schema.SObjectField dest = fieldMap.get(redirect.toLowerCase());
                    // Only email / phone values move to another field (the panels offer nothing else).
                    if (fc.historyMode == 'Historize' || dest == null || kindOf(fieldType) == null
                            || !dest.getDescribe().isUpdateable()
                            || EXCLUDED_SLOTS.contains(redirect.toLowerCase())
                            || dest.getDescribe().getType() != fieldType) {
                        throw new SaveChoiceException('Invalid place for ' + fc.fieldApiName + ': ' + redirect);
                    }
                    String destName = dest.getDescribe().getName();
                    if (redirectedValues.containsKey(destName)) {
                        throw new SaveChoiceException('Two values for the same field: ' + destName);
                    }
                    Object redirectedValue = coerceValue(fieldType, proposed.get(fc.fieldApiName));
                    targetRecord.put(destName, redirectedValue);
                    redirectedValues.put(destName, redirectedValue);
                    redirectedFrom.put(destName, fc.fieldApiName);
                    placedIn.put(fc.fieldApiName, destName);
                    updatedCount++;
                    targetFieldCount++;
                    continue;
                }
                Object coerced = coerceValue(fieldType, proposed.get(fc.fieldApiName));
                targetRecord.put(fc.fieldApiName, coerced);
                selectedFieldValues.put(fc.fieldApiName, coerced);
                placedIn.put(fc.fieldApiName, field.getDescribe().getName());
                updatedCount++;
                targetFieldCount++;
            }

            for (String destName : redirectedValues.keySet()) {
                for (String own : selectedFieldValues.keySet()) {
                    if (own.equalsIgnoreCase(destName)) {
                        throw new SaveChoiceException('Two values for the same field: ' + destName);
                    }
                }
            }
            // Preferred chosen by staff: the field the row's value lands in becomes the preferred one.
            Map<String, Object> preferenceNotes = new Map<String, Object>();
            if (preferred != null) {
                Id recId = t.Target_Record_Id__c;
                for (String kind : preferred.keySet()) {
                    String prefField = PREFERENCE_FIELD_BY_KIND.get(kind);
                    String dest = placedIn.get(preferred.get(kind));
                    if (dest == null && skipped.contains(preferred.get(kind))) {
                        // Email skipped because the preferred field answers the same value: that
                        // field holds it. Any other skipped row isn't written — its star is moot.
                        DataUpdateFormConfigService.FormFieldConfig mainFc = mainFcByKind.get(kind);
                        if (mainFc == null || mainFc.fieldApiName != preferred.get(kind) || !destFcByKind.containsKey(kind)) continue;
                        dest = placedIn.get(destFcByKind.get(kind).fieldApiName);
                    }
                    String value = prefField != null && dest != null && config.targetObjectApiName == 'Contact'
                            && fieldMap.containsKey(prefField.toLowerCase())
                            && fieldMap.get(prefField.toLowerCase()).getDescribe().isUpdateable()
                        ? preferenceByField(fieldMap, kind).get(dest) : null;
                    if (value == null) throw new SaveChoiceException('Invalid preferred ' + kind + ': ' + preferred.get(kind));
                    String before = (String) Database.query('SELECT ' + prefField + ' FROM Contact WHERE Id = :recId LIMIT 1')[0].get(prefField);
                    targetRecord.put(prefField, value);
                    if (before != value) {
                        preferenceNotes.put(PREFERENCE_NOTE_BY_KIND.get(kind), new Map<String, Object>{ 'field' => dest, 'before' => before, 'after' => value });
                    }
                }
            }
            // Contact without any email (phone): the preference is set with the field, as EDA would
            // do — noted so a rollback clears both (EDA refuses a preference pointing at a blank field).
            for (String kind : mainTo.keySet()) {
                EmailTarget target = mainTo.get(kind);
                if (target.setPreference == null || (preferred != null && preferred.containsKey(kind))) continue;
                Map<String, String> prefByField = preferenceByField(fieldMap, kind);
                String filled = targetRecord.get(target.field) != null ? target.field : null;
                for (String field : prefByField.keySet()) {
                    if (filled == null && targetRecord.get(field) != null) filled = field;
                }
                String preference = filled != null ? prefByField.get(filled) : null;
                if (preference != null) {
                    targetRecord.put(PREFERENCE_FIELD_BY_KIND.get(kind), preference);
                    preferenceNotes.put(PREFERENCE_NOTE_BY_KIND.get(kind), new Map<String, Object>{ 'field' => filled, 'before' => null, 'after' => preference });
                }
            }
            // Values the redirected fields hold now — their "before" for the log and rollback.
            Map<String, Object> redirectedBefore = new Map<String, Object>();
            if (!redirectedValues.isEmpty()) {
                Id recId = t.Target_Record_Id__c;
                SObject current = Database.query('SELECT ' + String.join(new List<String>(redirectedValues.keySet()), ', ')
                    + ' FROM ' + config.targetObjectApiName + ' WHERE Id = :recId LIMIT 1');
                for (String destName : redirectedValues.keySet()) {
                    redirectedBefore.put(destName, current.get(destName));
                }
            }

            // Pass 2: build history rows now that targetRecord carries every selected value.
            for (DataUpdateFormConfigService.FormFieldConfig fc : accessibleFields) {
                if (!selectedFieldValues.containsKey(fc.fieldApiName)) continue;
                if (fc.historyMode == 'Historize') {
                    historyRows.add(buildDynamicHistoryRow(fc, t.Target_Record_Id__c, selectedFieldValues.get(fc.fieldApiName), targetRecord, requestId, logId, proposed));
                }
            }

            // History tables: kept lines → new rows, or overwrites of same-date rows.
            Map<String, Set<Integer>> tableSelections = parseTableSelections(tableSelectionsJson);
            List<TablePlan> tablePlans = new List<TablePlan>();
            for (DataUpdateFormConfigService.FormFieldConfig tc : getAccessibleTables(config, true)) {
                Set<Integer> keep = tableSelections.get(tc.fieldApiName);
                if (keep == null || keep.isEmpty()) continue;
                TableValue tv = parseTableValue(proposed.get(tc.fieldApiName));
                if (tv == null) continue;
                TablePlan plan = planTableApply(tc, tv, keep, t.Target_Record_Id__c, logId);
                if (plan.inserts.isEmpty() && plan.updates.isEmpty()) continue;
                tablePlans.add(plan);
                updatedCount += plan.inserts.size() + plan.updates.size();
            }

            // History_Only: the value only becomes a new row on the history object.
            Map<String, HistoryPoint> latestHistory = queryLatestHistoryPoints(historyOnlyFields, t.Target_Record_Id__c);
            Map<String, SObject> historyOnlyRows = new Map<String, SObject>();
            for (DataUpdateFormConfigService.FormFieldConfig fc : historyOnlyFields) {
                historyOnlyRows.put(fc.fieldApiName, buildHistoryOnlyRow(fc, t, proposed, logId));
            }

            // All-or-nothing: the record update, history rows, apply log and the Applied status
            // commit together — otherwise a failure after the update would leave the record
            // changed with the ticket still open, and a re-apply would duplicate history rows.
            Savepoint sp = Database.setSavepoint();
            try {
                if (targetFieldCount > 0) {
                    update targetRecord;
                }
                if (TEST_FORCE_APPLY_DML_ERROR) throw new DmlException('TEST_FORCE_APPLY_DML_ERROR');
                if (!historyRows.isEmpty()) {
                    insert historyRows;
                }
                if (!historyOnlyRows.isEmpty()) {
                    insert historyOnlyRows.values();
                }

                Map<String, Object> historyOnlyDecisions = new Map<String, Object>();
                for (TablePlan plan : tablePlans) {
                    if (!plan.inserts.isEmpty()) insert plan.inserts;
                    if (!plan.updates.isEmpty()) update plan.updates;
                    historyOnlyDecisions.put(plan.key, plan.toDecision());
                }
                for (DataUpdateFormConfigService.FormFieldConfig fc : historyOnlyFields) {
                    SObject row = historyOnlyRows.get(fc.fieldApiName);
                    HistoryPoint latest = latestHistory.get(fc.fieldApiName);
                    String newValue = valueToString(row.get(fc.historyTargetValueFieldApiName));
                    historyOnlyDecisions.put(fc.fieldApiName, new Map<String, Object>{
                        'selectedValue' => newValue,
                        'diff'          => new Map<String, Object>{
                            'before' => latest != null ? latest.value : '',
                            'after'  => newValue
                        },
                        'historyRowId'  => row.Id,
                        'historyDate'   => String.isNotBlank(fc.historyTargetDateFieldApiName)
                            ? valueToString(row.get(fc.historyTargetDateFieldApiName)) : ''
                    });
                }

                for (String destName : redirectedValues.keySet()) {
                    historyOnlyDecisions.put(destName, new Map<String, Object>{
                        'selectedValue'      => redirectedValues.get(destName),
                        'diff'               => new Map<String, Object>{
                            'before' => redirectedBefore.get(destName),
                            'after'  => redirectedValues.get(destName)
                        },
                        'beforeFromDecision' => true,
                        'sourceField'        => redirectedFrom.get(destName)
                    });
                }
                historyOnlyDecisions.putAll(preferenceNotes);
                if (notes != null) {
                    for (String key : notes.keySet()) {
                        if (key.startsWith(NOTE_KEY_PREFIX)) historyOnlyDecisions.put(key, notes.get(key));
                    }
                }

                SObject targetRecordAfter = queryCurrentValues(config, t.Target_Record_Id__c, config.fields);
                DataUpdateAuditService.recordApplySuccess(logId, targetRecordAfter, selectedFieldValues, historyOnlyDecisions);

                update new Data_Update_Request__c(
                    Id               = requestId,
                    Status__c        = 'Applied',
                    Final_Action__c  = 'Applied',
                    Closed_Reason__c = 'Applied'
                );
            } catch (Exception applyEx) {
                Database.rollback(sp);
                throw applyEx;
            }

            result.success           = true;
            result.updatedFieldCount = updatedCount;
        } catch (EmailPreferenceException e) {
            // A choice to fix in the panel, not a failure: the ticket stays as it was.
            result.success      = false;
            result.errorMessage = e.getMessage();
        } catch (SaveChoiceException e) {
            result.success      = false;
            result.errorMessage = INVALID_SAVE_CHOICE;
        } catch (Exception e) {
            DataUpdateAuditService.recordApplyError(logId, requestId, e.getMessage());
            result.success      = false;
            result.errorMessage = 'GENERIC_ERROR';
        }
        return result;
    }

    /**
     * Lets staff correct a single proposed value (e.g. a typo the contact made on the
     * public form) directly in Proposed_Values_JSON__c, before the request is applied —
     * applySelectedUpdates() reads from that same JSON, so this is the actual value that
     * ends up on the real record once staff hits Apply. Records a CORRECTED
     * Data_Update_Log__c (same Field_Decisions_JSON__c shape as a rollback) so the change
     * is visible in the review panel's History tab.
     */
    @AuraEnabled
    public static DataUpdateWrapper.CorrectionResult correctProposedValue(Id requestId, String fieldApiName, String newValue) {
        DataUpdateWrapper.CorrectionResult result = new DataUpdateWrapper.CorrectionResult();
        try {
            if (TEST_FORCE_ERROR) throw new AuraHandledException('TEST_FORCE_ERROR');

            Data_Update_Request__c t = queryRequest(requestId);
            if (isTerminal(t.Status__c)) {
                result.success      = false;
                result.errorMessage = 'TICKET_ALREADY_CLOSED';
                return result;
            }

            DataUpdateFormConfigService.FormConfig config = resolveRequestConfig(t);
            List<DataUpdateFormConfigService.FormFieldConfig> accessibleFields = getAccessibleFields(config, true);
            DataUpdateFormConfigService.FormFieldConfig editedField;
            for (DataUpdateFormConfigService.FormFieldConfig fc : accessibleFields) {
                if (fc.fieldApiName == fieldApiName) {
                    editedField = fc;
                    break;
                }
            }
            if (editedField == null) {
                result.success      = false;
                result.errorMessage = 'FIELD_NOT_EDITABLE';
                return result;
            }

            String trimmed = newValue == null ? '' : newValue.trim();
            if (String.isBlank(trimmed)) {
                result.success      = false;
                result.errorMessage = 'VALUE_REQUIRED';
                return result;
            }

            Map<String, Object> raw = String.isBlank(t.Proposed_Values_JSON__c)
                ? new Map<String, Object>()
                : (Map<String, Object>) JSON.deserializeUntyped(t.Proposed_Values_JSON__c);
            String oldValue = raw.containsKey(fieldApiName) ? valueToString(raw.get(fieldApiName)) : '';

            if (DataUpdateFormConfigService.isPostalCodeField(fieldApiName)) {
                SObject currentRecord = queryCurrentValues(config, t.Target_Record_Id__c, accessibleFields);
                String country = DataUpdateFormConfigService.resolvePostalCountry(fieldApiName, raw, currentRecord);
                trimmed = DataUpdateFormConfigService.formatPostalCode(trimmed, country);
                if (DataUpdateFormConfigService.isInvalidPostalCode(trimmed, country)) {
                    result.success      = false;
                    result.errorMessage = 'INVALID_POSTAL_CODE';
                    return result;
                }
            }

            // Refused now rather than at Apply, where a bad value would put the ticket in Error.
            Schema.DescribeFieldResult editedDescribe = DataUpdateFormConfigService.describeValueField(editedField, config.targetObjectApiName);
            trimmed = DataUpdateFormConfigService.normalizeEmail(editedDescribe, trimmed);
            String invalidCode = DataUpdateFormConfigService.validateFieldValue(editedDescribe, trimmed);
            if (invalidCode != null) {
                result.success      = false;
                result.errorMessage = invalidCode;
                return result;
            }

            result.success  = true;
            result.newValue = trimmed;
            if (oldValue.equals(trimmed)) {
                return result;
            }

            raw.put(fieldApiName, trimmed);
            update new Data_Update_Request__c(
                Id                       = requestId,
                Proposed_Values_JSON__c = JSON.serialize(raw)
            );

            SObject targetSnapshot = queryCurrentValues(config, t.Target_Record_Id__c, accessibleFields);
            DataUpdateAuditService.recordCorrection(
                requestId, config.targetObjectApiName, t.Target_Record_Id__c, targetSnapshot,
                fieldApiName, oldValue, trimmed
            );
        } catch (Exception e) {
            result.success      = false;
            result.errorMessage = 'GENERIC_ERROR';
        }
        return result;
    }

    // ─── Audit history ──────────────────────────────────────────────────────

    /**
     * Returns the completed/errored Data_Update_Log__c entries for a request, newest
     * first, decoded from Field_Decisions_JSON__c (written by DataUpdateAuditService.
     * recordApplySuccess) into per-field before/after values with localized labels.
     */
    @AuraEnabled
    public static DataUpdateWrapper.AuditLogResult getAuditLog(Id requestId) {
        DataUpdateWrapper.AuditLogResult result = new DataUpdateWrapper.AuditLogResult();
        try {
            if (TEST_FORCE_ERROR) throw new AuraHandledException('TEST_FORCE_ERROR');

            Data_Update_Request__c t = queryRequest(requestId);
            DataUpdateFormConfigService.FormConfig config = resolveRequestConfig(t);
            Map<String, DataUpdateFormConfigService.FormFieldConfig> fieldByApi = new Map<String, DataUpdateFormConfigService.FormFieldConfig>();
            for (DataUpdateFormConfigService.FormFieldConfig fc : config.fields) {
                fieldByApi.put(fc.fieldApiName, fc);
            }
            for (DataUpdateFormConfigService.FormFieldConfig tc : config.tables) {
                fieldByApi.put(tc.fieldApiName, tc);
            }

            Map<String, FieldTouch> fieldTouches = getFieldTouchMap(requestId);
            Schema.SObjectType auditTargetType = String.isBlank(config.targetObjectApiName)
                ? null : DataUpdateFormConfigService.globalTypes().get(config.targetObjectApiName);
            Map<String, Schema.SObjectField> auditFieldMap = auditTargetType != null
                ? auditTargetType.getDescribe().fields.getMap() : new Map<String, Schema.SObjectField>();

            for (Data_Update_Log__c log : [
                SELECT Id, Action_Type__c, Performed_By__r.Name, Performed_Date__c, Field_Decisions_JSON__c
                FROM Data_Update_Log__c
                WHERE Request__c = :requestId AND Action_Type__c IN ('APPLY_COMPLETED', 'APPLY_ERROR', 'ROLLBACK_COMPLETED', 'CORRECTED')
                ORDER BY Performed_Date__c DESC
            ]) {
                DataUpdateWrapper.AuditLogEntry entry = new DataUpdateWrapper.AuditLogEntry();
                entry.logId           = log.Id;
                entry.actionType      = log.Action_Type__c;
                entry.performedByName = log.Performed_By__r != null ? log.Performed_By__r.Name : '';
                entry.performedDate   = log.Performed_Date__c;

                if (String.isNotBlank(log.Field_Decisions_JSON__c)) {
                    Map<String, Object> decisions = (Map<String, Object>) JSON.deserializeUntyped(log.Field_Decisions_JSON__c);
                    readNotes(entry, decisions);
                    for (String fieldApiName : decisions.keySet()) {
                        if (fieldApiName.startsWith(NOTE_KEY_PREFIX)) continue;
                        Map<String, Object> decision = (Map<String, Object>) decisions.get(fieldApiName);
                        Map<String, Object> diff = decision.get('diff') instanceof Map<String, Object>
                            ? (Map<String, Object>) decision.get('diff')
                            : null;

                        DataUpdateWrapper.AuditFieldChange change = new DataUpdateWrapper.AuditFieldChange();
                        change.fieldApiName = fieldApiName;
                        DataUpdateFormConfigService.FormFieldConfig fc = fieldByApi.get(fieldApiName);
                        // A value saved in another field (grouped review) — show that field's own label.
                        Schema.SObjectField schemaField = fc == null ? auditFieldMap.get(fieldApiName.toLowerCase()) : null;
                        String schemaLabel = schemaField != null ? schemaField.getDescribe().getLabel() : fieldApiName;
                        change.fieldLabelFr = fc != null ? fc.labelFr : schemaLabel;
                        change.fieldLabelEn = fc != null ? fc.labelEn : schemaLabel;
                        // Answered in another question and saved here (Email → preferred email, "Save to").
                        DataUpdateFormConfigService.FormFieldConfig sourceFc = fieldByApi.get(valueToString(decision.get('sourceField')));
                        change.sourceLabelFr = sourceFc != null ? sourceFc.labelFr : null;
                        change.sourceLabelEn = sourceFc != null ? sourceFc.labelEn : null;
                        change.beforeValue   = diff != null ? valueToString(diff.get('before')) : '';
                        change.afterValue    = diff != null ? valueToString(diff.get('after')) : valueToString(decision.get('selectedValue'));
                        String historyDate   = valueToString(decision.get('historyDate'));
                        if (String.isNotBlank(historyDate) && String.isNotBlank(change.afterValue)) {
                            change.afterValue += ' (' + historyDate.left(10) + ')';
                        }

                        // A field row is only rollback-eligible if THIS entry is still the
                        // latest thing to have touched that field — otherwise a later apply
                        // or an earlier rollback has already superseded it.
                        FieldTouch touch = fieldTouches.get(fieldApiName);
                        change.canRollback = log.Action_Type__c == 'APPLY_COMPLETED'
                            && touch != null && touch.logId == log.Id;

                        entry.fieldChanges.add(change);
                    }
                }
                result.entries.add(entry);
            }
            Data_Update_Request__c withNotes = [SELECT Notes__c FROM Data_Update_Request__c WHERE Id = :requestId LIMIT 1];
            result.entries.addAll(parseStatusEvents(withNotes.Notes__c));
            result.entries.sort(new AuditEntryNewestFirst());
            result.success = true;
        } catch (Exception e) {
            result.success      = false;
            result.errorMessage = 'GENERIC_ERROR';
        }
        return result;
    }

    /**
     * Status changes made by staff (hold, resume, ignore, reopen) as Historique entries, read
     * from the [HIST:status|||reason|||notes|||date(|||user)] chain in Notes__c. Rollback
     * reopenings are skipped: their ROLLBACK_COMPLETED log already shows them.
     */
    @TestVisible private static List<DataUpdateWrapper.AuditLogEntry> parseStatusEvents(String notes) {
        List<DataUpdateWrapper.AuditLogEntry> events = new List<DataUpdateWrapper.AuditLogEntry>();
        if (String.isBlank(notes)) return events;
        Integer seq = 0;
        for (String line : notes.split('\n')) {
            line = line.trim();
            if (!line.startsWith('[HIST:') || !line.endsWith(']')) continue;
            List<String> parts = line.substring(6, line.length() - 1).split('\\|\\|\\|', -1);
            if (parts.size() < 4) continue;
            String entryNotes = parts[2].replace('\\n', '\n');
            if (entryNotes.startsWith('Rollback:')) continue;
            // 4 parts = old format (day only); 5 parts = date-time (GMT) + who.
            Boolean legacy = parts.size() == 4;
            String stamp = legacy ? parts[3] : parts[parts.size() - 2];
            DataUpdateWrapper.AuditLogEntry entry = new DataUpdateWrapper.AuditLogEntry();
            entry.logId           = null;
            entry.actionType      = 'STATUS';
            entry.statusValue     = parts[0];
            entry.statusReason    = parts[1];
            entry.statusNotes     = entryNotes;
            entry.performedByName = legacy ? '' : parts[parts.size() - 1];
            entry.dateOnly        = stamp.length() <= 10;
            try {
                entry.performedDate = Datetime.valueOfGmt(entry.dateOnly ? stamp.left(10) + ' 12:00:00' : stamp);
            } catch (Exception e) {
                continue;
            }
            // Day-only entries sit at noon GMT; same-day ones keep their chain order (newest first).
            entry.performedDate = entry.performedDate.addSeconds(entry.dateOnly ? -seq : 0);
            seq++;
            events.add(entry);
        }
        return events;
    }

    private class AuditEntryNewestFirst implements Comparator<DataUpdateWrapper.AuditLogEntry> {
        public Integer compare(DataUpdateWrapper.AuditLogEntry a, DataUpdateWrapper.AuditLogEntry b) {
            Datetime da = a.performedDate, db = b.performedDate;
            if (da == db) return 0;
            if (da == null) return 1;
            if (db == null) return -1;
            return da > db ? -1 : 1;
        }
    }

    /**
     * Reverts ONE field changed by a specific APPLY_COMPLETED log entry back to its
     * Before_Snapshot_JSON__c value (captured right before that apply ran). Scoped to a
     * single field — not the whole entry — because one "Apply selected" action can bundle
     * several fields together, and staff may need to undo just one of them (e.g. two
     * different people each responsible for a different field). Records a new
     * ROLLBACK_COMPLETED log for the reversal itself, and reopens the request so it
     * re-enters the normal review workflow.
     */
    @AuraEnabled
    public static DataUpdateWrapper.ApplyResult rollbackChange(Id logId, String fieldApiName) {
        DataUpdateWrapper.ApplyResult result = new DataUpdateWrapper.ApplyResult();
        try {
            if (TEST_FORCE_ERROR) throw new AuraHandledException('TEST_FORCE_ERROR');

            Data_Update_Log__c log = [
                SELECT Id, Request__c, Action_Type__c, Target_Object_API_Name__c, Target_Record_Id__c,
                       Before_Snapshot_JSON__c, Field_Decisions_JSON__c
                FROM Data_Update_Log__c
                WHERE Id = :logId
                LIMIT 1
            ];
            Map<String, Object> decisions = String.isNotBlank(log.Field_Decisions_JSON__c)
                ? (Map<String, Object>) JSON.deserializeUntyped(log.Field_Decisions_JSON__c)
                : new Map<String, Object>();
            if (log.Action_Type__c != 'APPLY_COMPLETED' || !decisions.containsKey(fieldApiName)
                    || fieldApiName.startsWith(NOTE_KEY_PREFIX)) {
                result.success      = false;
                result.errorMessage = 'ROLLBACK_INVALID_STATE';
                return result;
            }

            // Defensive: this log must still be the latest entry to have touched this field —
            // otherwise it was already rolled back, or re-applied with a newer value since.
            Map<String, FieldTouch> fieldTouches = getFieldTouchMap(log.Request__c);
            FieldTouch touch = fieldTouches.get(fieldApiName);
            if (touch == null || touch.logId != logId) {
                result.success      = false;
                result.errorMessage = 'ROLLBACK_INVALID_STATE';
                return result;
            }

            Data_Update_Request__c t = queryRequest(log.Request__c);
            DataUpdateFormConfigService.FormConfig config = resolveRequestConfig(t);

            if (DataUpdateFormConfigService.isHistoryTableKey(fieldApiName)) {
                return rollbackHistoryTable(log, t, config, fieldApiName,
                    (Map<String, Object>) decisions.get(fieldApiName));
            }

            DataUpdateFormConfigService.FormFieldConfig rolledBackFieldConfig;
            for (DataUpdateFormConfigService.FormFieldConfig fc : config.fields) {
                if (fc.fieldApiName == fieldApiName) {
                    rolledBackFieldConfig = fc;
                    break;
                }
            }

            if (DataUpdateFormConfigService.isHistoryOnly(rolledBackFieldConfig)) {
                return rollbackHistoryOnly(log, t, config, rolledBackFieldConfig,
                    (Map<String, Object>) decisions.get(fieldApiName));
            }

            Map<String, Object> before = DataUpdateSnapshotService.deserialize(log.Before_Snapshot_JSON__c);

            Schema.SObjectType targetType = DataUpdateFormConfigService.globalTypes().get(log.Target_Object_API_Name__c);
            if (targetType == null) {
                result.success      = false;
                result.errorMessage = 'GENERIC_ERROR';
                return result;
            }
            Map<String, Schema.SObjectField> fieldMap = targetType.getDescribe().fields.getMap();
            Schema.SObjectField field = fieldMap.get(fieldApiName.toLowerCase());
            if (field == null || !field.getDescribe().isUpdateable()) {
                result.success      = false;
                result.errorMessage = 'GENERIC_ERROR';
                return result;
            }

            SObject targetRecordBefore = queryCurrentValues(config, log.Target_Record_Id__c, config.fields);

            SObject targetRecord = targetType.newSObject(log.Target_Record_Id__c);
            Object rawBefore = before.get(fieldApiName);
            // Saved in another field than the form's (grouped review): the submit snapshot never
            // held it, the apply recorded its own before value.
            Map<String, Object> ownDecision = (Map<String, Object>) decisions.get(fieldApiName);
            Map<String, Object> redirectedDiff = ownDecision != null && ownDecision.get('beforeFromDecision') == true
                    && ownDecision.get('diff') instanceof Map<String, Object>
                ? (Map<String, Object>) ownDecision.get('diff') : null;
            if (redirectedDiff != null) rawBefore = redirectedDiff.get('before');
            Object coerced = coerceValue(field.getDescribe().getType(), rawBefore == null ? null : String.valueOf(rawBefore));
            targetRecord.put(fieldApiName, coerced);
            Map<String, Object> restoredFieldValues = new Map<String, Object>{ fieldApiName => coerced };
            // The preference was set with this field (staff's "Preferred", or a contact without
            // email): restore both together. Field emptied with no preference before → another
            // field of the kind that still holds a value (EDA refuses a blank preference then).
            // Restored only if nobody changed it since, and never left on the field this empties.
            Map<String, Object> preferenceRestored = rollbackPreferences(log.Target_Object_API_Name__c,
                log.Target_Record_Id__c, fieldApiName, coerced, fieldMap, decisions);
            for (String kind : preferenceRestored.keySet()) {
                targetRecord.put(PREFERENCE_FIELD_BY_KIND.get(kind),
                    ((Map<String, Object>) preferenceRestored.get(kind)).get('after'));
            }

            // The rollback reopens the ticket, so the record goes back under lock — same state
            // as a fresh submission (open ticket = locked), keeping the Locked List consistent.
            if (String.isNotBlank(config.lockFieldApiName) && isFieldUpdateable(fieldMap, config.lockFieldApiName)) {
                targetRecord.put(config.lockFieldApiName, true);
                if (String.isNotBlank(config.lockDateFieldApiName) && isFieldUpdateable(fieldMap, config.lockDateFieldApiName)) {
                    targetRecord.put(config.lockDateFieldApiName, Datetime.now());
                }
            }

            // All-or-nothing: restored value, history cleanup, rollback log and Reopened status.
            Savepoint sp = Database.setSavepoint();
            try {
                update targetRecord;
                if (TEST_FORCE_ROLLBACK_DML_ERROR) throw new DmlException('TEST_FORCE_ROLLBACK_DML_ERROR');

                if (rolledBackFieldConfig != null && rolledBackFieldConfig.historyMode == 'Historize') {
                    result.historyCleanupSkipped = deleteHistoryRowsForRollback(rolledBackFieldConfig, logId);
                } else if (config.isFallback == true) {
                    // The history mapping died with the form — staff must check history rows by hand.
                    result.historyCleanupSkipped = true;
                }

                SObject targetRecordAfter = queryCurrentValues(config, log.Target_Record_Id__c, config.fields);
                Map<String, Object> rollbackExtra = new Map<String, Object>();
                if (redirectedDiff != null) {
                    rollbackExtra.put(fieldApiName, new Map<String, Object>{
                        'selectedValue' => coerced,
                        'diff'          => new Map<String, Object>{ 'before' => redirectedDiff.get('after'), 'after' => coerced }
                    });
                }
                // Historique shows the preference the rollback put back.
                for (String kind : preferenceRestored.keySet()) {
                    rollbackExtra.put(PREFERENCE_NOTE_BY_KIND.get(kind), preferenceRestored.get(kind));
                }
                DataUpdateAuditService.recordRollback(
                    log.Request__c, log.Target_Object_API_Name__c, log.Target_Record_Id__c,
                    targetRecordBefore, targetRecordAfter, restoredFieldValues, rollbackExtra
                );

                Data_Update_Request__c requestForHist = [SELECT Notes__c FROM Data_Update_Request__c WHERE Id = :t.Id LIMIT 1];
                update new Data_Update_Request__c(
                    Id               = t.Id,
                    Status__c        = 'Reopened',
                    Final_Action__c  = null,
                    Closed_Reason__c = null,
                    Notes__c         = prependHist(
                        requestForHist.Notes__c,
                        buildHistEntry('Reopened', '', 'Rollback: ' + restoredFieldValues.size() + ' field(s) restored')
                    )
                );
            } catch (Exception rollbackEx) {
                Database.rollback(sp);
                throw rollbackEx;
            }

            result.success           = true;
            result.updatedFieldCount = restoredFieldValues.size();
        } catch (Exception e) {
            result.success      = false;
            result.errorMessage = 'GENERIC_ERROR';
        }
        return result;
    }

    /**
     * All-or-nothing rollback of several fields from the same APPLY_COMPLETED log: each field
     * goes through rollbackChange (same validations, logs and relock), but under one outer
     * savepoint — if any field fails, every field already restored in this call is undone too.
     */
    @AuraEnabled
    public static DataUpdateWrapper.ApplyResult rollbackChanges(Id logId, List<String> fieldApiNames) {
        DataUpdateWrapper.ApplyResult result = new DataUpdateWrapper.ApplyResult();
        if (fieldApiNames == null || fieldApiNames.isEmpty()) {
            result.success      = false;
            result.errorMessage = 'ROLLBACK_INVALID_STATE';
            return result;
        }
        Savepoint sp = Database.setSavepoint();
        Integer restored = 0;
        Boolean cleanupSkipped = false;
        for (String fieldApiName : fieldApiNames) {
            DataUpdateWrapper.ApplyResult one = rollbackChange(logId, fieldApiName);
            if (one.success != true) {
                Database.rollback(sp);
                return one;
            }
            restored += one.updatedFieldCount == null ? 0 : one.updatedFieldCount;
            cleanupSkipped = cleanupSkipped || one.historyCleanupSkipped == true;
        }
        result.success               = true;
        result.updatedFieldCount     = restored;
        result.historyCleanupSkipped = cleanupSkipped;
        return result;
    }

    /**
     * Rollback of a History_Only field: nothing changed on the target record, so the reversal
     * is deleting the history row that apply inserted (Id kept in the log's decision, so no
     * Log lookup is needed on the history object), then relock + reopen like any rollback.
     */
    private static DataUpdateWrapper.ApplyResult rollbackHistoryOnly(
        Data_Update_Log__c log, Data_Update_Request__c t, DataUpdateFormConfigService.FormConfig config,
        DataUpdateFormConfigService.FormFieldConfig fc, Map<String, Object> decision
    ) {
        DataUpdateWrapper.ApplyResult result = new DataUpdateWrapper.ApplyResult();
        Schema.SObjectType histType = DataUpdateFormConfigService.globalTypes().get(fc.historyTargetObjectApiName);
        if (histType == null || !histType.getDescribe().isDeletable()) {
            result.success      = false;
            result.errorMessage = 'GENERIC_ERROR';
            return result;
        }

        String rowId = decision != null ? valueToString(decision.get('historyRowId')) : '';
        Map<String, Object> diff = decision != null && decision.get('diff') instanceof Map<String, Object>
            ? (Map<String, Object>) decision.get('diff') : new Map<String, Object>();
        String appliedValue = valueToString(diff.get('after'));

        Schema.SObjectType targetType = DataUpdateFormConfigService.globalTypes().get(config.targetObjectApiName);
        Map<String, Schema.SObjectField> fieldMap = targetType.getDescribe().fields.getMap();
        SObject lockUpdate = targetType.newSObject(log.Target_Record_Id__c);
        Boolean hasLockUpdate = false;
        if (String.isNotBlank(config.lockFieldApiName) && isFieldUpdateable(fieldMap, config.lockFieldApiName)) {
            lockUpdate.put(config.lockFieldApiName, true);
            hasLockUpdate = true;
            if (String.isNotBlank(config.lockDateFieldApiName) && isFieldUpdateable(fieldMap, config.lockDateFieldApiName)) {
                lockUpdate.put(config.lockDateFieldApiName, Datetime.now());
            }
        }

        SObject targetRecordBefore = queryCurrentValues(config, log.Target_Record_Id__c, config.fields);

        Savepoint sp = Database.setSavepoint();
        try {
            if (String.isNotBlank(rowId)) {
                Id historyRowId = Id.valueOf(rowId);
                List<SObject> rows = Database.query(
                    'SELECT Id FROM ' + fc.historyTargetObjectApiName + ' WHERE Id = :historyRowId LIMIT 1'
                );
                if (!rows.isEmpty()) {
                    delete rows;
                }
            } else {
                result.historyCleanupSkipped = deleteHistoryRowsForRollback(fc, log.Id);
            }
            if (hasLockUpdate) {
                update lockUpdate;
            }
            if (TEST_FORCE_ROLLBACK_DML_ERROR) throw new DmlException('TEST_FORCE_ROLLBACK_DML_ERROR');

            SObject targetRecordAfter = queryCurrentValues(config, log.Target_Record_Id__c, config.fields);
            DataUpdateAuditService.recordRollback(
                log.Request__c, log.Target_Object_API_Name__c, log.Target_Record_Id__c,
                targetRecordBefore, targetRecordAfter, new Map<String, Object>(),
                new Map<String, Object>{
                    fc.fieldApiName => new Map<String, Object>{
                        'selectedValue' => null,
                        'diff'          => new Map<String, Object>{ 'before' => appliedValue, 'after' => '' }
                    }
                }
            );

            Data_Update_Request__c requestForHist = [SELECT Notes__c FROM Data_Update_Request__c WHERE Id = :t.Id LIMIT 1];
            update new Data_Update_Request__c(
                Id               = t.Id,
                Status__c        = 'Reopened',
                Final_Action__c  = null,
                Closed_Reason__c = null,
                Notes__c         = prependHist(
                    requestForHist.Notes__c,
                    buildHistEntry('Reopened', '', 'Rollback: 1 history row removed')
                )
            );
        } catch (Exception rollbackEx) {
            Database.rollback(sp);
            throw rollbackEx;
        }

        result.success           = true;
        result.updatedFieldCount = 1;
        return result;
    }

    // ─── Bandeja de entrada ─────────────────────────────────────────────────

    @AuraEnabled
    public static DataUpdateWrapper.RequestListResult getRequests(
        String  statusFilter,
        String  formFilter,
        String  searchTerm,
        Integer pageSize,
        Integer pageOffset
    ) {
        DataUpdateWrapper.RequestListResult result = new DataUpdateWrapper.RequestListResult();
        try {
            Integer lim = (pageSize == null || pageSize <= 0) ? 50 : pageSize;
            Integer off = (pageOffset == null || pageOffset < 0) ? 0 : pageOffset;

            String statusFilterEsc = String.escapeSingleQuotes(statusFilter);
            String formFilterEsc   = String.escapeSingleQuotes(formFilter);
            Set<String> liveDeveloperNames = formFilterEsc == DELETED_FORMS_FILTER
                ? getLiveFormDeveloperNames() : null;
            String soql =
                'SELECT Id, Name, Subject__c, Status__c, Closed_Reason__c, Requested_Name__c, Requested_Email__c, ' +
                '       Update_Form_DeveloperName__c, Update_Form_Label__c, Proposed_Values_JSON__c, CreatedDate, ' +
                '       Target_Record_Id__c ' +
                'FROM Data_Update_Request__c WHERE Id != null';
            if (statusFilterEsc == 'Open') {
                soql += ' AND Status__c NOT IN (\'Applied\', \'Ignored\', \'Closed\')';
            } else if (!String.isBlank(statusFilterEsc) && statusFilterEsc != 'All') {
                soql += ' AND Status__c = :statusFilterEsc';
            }
            if (formFilterEsc == DELETED_FORMS_FILTER) {
                soql += ' AND Update_Form_DeveloperName__c NOT IN :liveDeveloperNames';
            } else if (!String.isBlank(formFilterEsc) && formFilterEsc != 'All') {
                soql += ' AND Update_Form_DeveloperName__c = :formFilterEsc';
            }
            // A search reads a wide page and keeps the real matches here (see searchLikePattern),
            // so the paging is done on the matches, not in SOQL.
            Boolean searching = String.isNotBlank(searchTerm);
            if (searching) {
                String likePattern = searchLikePattern(searchTerm); // NOPMD — used as SOQL bind variable
                soql += ' AND (' + REQUEST_SEARCH_WHERE + ')';
            }
            Integer qLim = searching ? SEARCH_SCAN_LIMIT : lim;
            Integer qOff = searching ? 0 : off;
            soql += ' ORDER BY CreatedDate DESC LIMIT :qLim OFFSET :qOff';

            List<Data_Update_Request__c> rows = Database.query(soql); // NOPMD
            Integer searchTotal = 0;
            if (searching) {
                List<Data_Update_Request__c> matches = filterRequestMatches(rows, searchTerm);
                searchTotal = matches.size();
                rows = new List<Data_Update_Request__c>();
                for (Integer i = off; i < Math.min(off + lim, matches.size()); i++) {
                    rows.add(matches[i]);
                }
            }
            Set<Id> lockedTargets = getLockedTargetIds(rows);
            Map<Id, List<String>> viewersByRequest = getViewersByRequest(new Map<Id, Data_Update_Request__c>(rows).keySet());
            Set<String> multiForms = getMultiSubmissionForms();
            Map<String, Integer> openByTarget = getOpenCountByTarget(rows, multiForms);
            Map<String, String> targetNames = getTargetNames(rows);
            for (Data_Update_Request__c t : rows) {
                DataUpdateWrapper.RequestSummary ts = new DataUpdateWrapper.RequestSummary();
                ts.id                     = t.Id;
                ts.requestNumber          = t.Name;
                ts.subject                = t.Subject__c;
                ts.status                 = t.Status__c;
                ts.closedReason           = t.Closed_Reason__c;
                ts.requestedName          = t.Requested_Name__c;
                ts.updateFormDeveloperName = t.Update_Form_DeveloperName__c;
                ts.formLabel              = t.Update_Form_Label__c;
                ts.changedFieldCount      = countProposedFields(t.Proposed_Values_JSON__c);
                ts.createdDate            = t.CreatedDate;
                ts.isLocked               = lockedTargets.contains(toIdOrNull(t.Target_Record_Id__c));
                ts.targetRecordId         = t.Target_Record_Id__c;
                ts.targetName             = targetNames.get(t.Target_Record_Id__c);
                ts.targetOpenCount        = multiForms.contains(t.Update_Form_DeveloperName__c) && openByTarget.containsKey(t.Target_Record_Id__c)
                    ? openByTarget.get(t.Target_Record_Id__c) : 0;
                ts.tableRowCount          = countTableRows(t.Proposed_Values_JSON__c);
                if (viewersByRequest.containsKey(t.Id)) ts.viewers = viewersByRequest.get(t.Id);
                result.requests.add(ts);
            }
            result.totalCount = searching ? searchTotal : getRequestCount(statusFilter, formFilter, searchTerm);
            result.success    = true;
        } catch (Exception e) {
            result.success      = false;
            result.errorMessage = 'GENERIC_ERROR';
        }
        return result;
    }

    // Open tickets per record, counting only "multiple submissions" forms (see getMultiSubmissionForms).
    private static Map<String, Integer> getOpenCountByTarget(List<Data_Update_Request__c> rows, Set<String> multiForms) {
        Set<String> targets = new Set<String>();
        for (Data_Update_Request__c t : rows) {
            if (String.isNotBlank(t.Target_Record_Id__c)) targets.add(t.Target_Record_Id__c);
        }
        Map<String, Integer> counts = new Map<String, Integer>();
        if (targets.isEmpty() || multiForms.isEmpty()) return counts;
        for (AggregateResult ar : [
            SELECT Target_Record_Id__c target, COUNT(Id) n
            FROM Data_Update_Request__c
            WHERE Target_Record_Id__c IN :targets AND Status__c NOT IN ('Applied', 'Ignored', 'Closed')
              AND Update_Form_DeveloperName__c IN :multiForms
            GROUP BY Target_Record_Id__c
        ]) {
            counts.put((String) ar.get('target'), (Integer) ar.get('n'));
        }
        return counts;
    }

    // Target ids are free text on the ticket: one unreadable value must never break the whole list.
    private static Id toIdOrNull(String value) {
        if (String.isBlank(value)) return null;
        try {
            return Id.valueOf(value);
        } catch (Exception e) {
            return null;
        }
    }

    // Display name of each target record (Name field), one query per object type.
    private static Map<String, String> getTargetNames(List<Data_Update_Request__c> rows) {
        Map<Schema.SObjectType, Set<Id>> idsByType = new Map<Schema.SObjectType, Set<Id>>();
        for (Data_Update_Request__c t : rows) {
            if (String.isBlank(t.Target_Record_Id__c)) continue;
            Id recId = toIdOrNull(t.Target_Record_Id__c);
            if (recId == null) continue;
            Schema.SObjectType sot = recId.getSObjectType();
            if (!idsByType.containsKey(sot)) idsByType.put(sot, new Set<Id>());
            idsByType.get(sot).add(recId);
        }
        Map<String, String> names = new Map<String, String>();
        for (Schema.SObjectType sot : idsByType.keySet()) {
            Schema.DescribeSObjectResult d = sot.getDescribe();
            Schema.SObjectField nameField = d.fields.getMap().get('name');
            if (!d.isAccessible() || nameField == null || !nameField.getDescribe().isAccessible()) continue;
            Set<Id> ids = idsByType.get(sot);
            for (SObject rec : Database.query('SELECT Id, Name FROM ' + d.getName() + ' WHERE Id IN :ids')) { // NOPMD
                String name = (String) rec.get('Name');
                names.put(rec.Id, name);
                names.put(String.valueOf(rec.Id).left(15), name);
            }
        }
        // Target ids are stored as 18 chars, but keep 15-char ones working too.
        Map<String, String> byStored = new Map<String, String>();
        for (Data_Update_Request__c t : rows) {
            if (String.isBlank(t.Target_Record_Id__c)) continue;
            String name = names.get(t.Target_Record_Id__c);
            if (name == null) name = names.get(t.Target_Record_Id__c.left(15));
            if (name != null) byStored.put(t.Target_Record_Id__c, name);
        }
        return byStored;
    }

    // Lines pasted/typed into history tables — "N rows from Excel" in the list.
    @TestVisible private static Integer countTableRows(String proposedValuesJson) {
        if (String.isBlank(proposedValuesJson)) return 0;
        try {
            Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(proposedValuesJson);
            Integer count = 0;
            for (String key : raw.keySet()) {
                if (!DataUpdateFormConfigService.isHistoryTableKey(key)) continue;
                TableValue tv = parseTableValue(valueToString(raw.get(key)));
                count += tv != null ? tv.rows.size() : 0;
            }
            return count;
        } catch (Exception e) {
            return 0;
        }
    }

    /**
     * Target records (of the given tickets) whose form lock field is currently true. One query
     * per distinct form; forms without a lock field, deleted forms, or a lock field the user
     * can't read are skipped (the ticket simply shows no lock icon).
     */
    private static Set<Id> getLockedTargetIds(List<Data_Update_Request__c> rows) {
        Map<String, Set<Id>> targetsByForm = new Map<String, Set<Id>>();
        for (Data_Update_Request__c t : rows) {
            Id targetId = toIdOrNull(t.Target_Record_Id__c);
            if (String.isBlank(t.Update_Form_DeveloperName__c) || targetId == null) continue;
            if (!targetsByForm.containsKey(t.Update_Form_DeveloperName__c)) {
                targetsByForm.put(t.Update_Form_DeveloperName__c, new Set<Id>());
            }
            targetsByForm.get(t.Update_Form_DeveloperName__c).add(targetId);
        }
        Set<Id> locked = new Set<Id>();
        for (String formName : targetsByForm.keySet()) {
            try {
                DataUpdateFormConfigService.FormConfig config = DataUpdateFormConfigService.getFormBasic(formName);
                if (String.isBlank(config.lockFieldApiName)
                        || !isFieldAccessible(config.targetObjectApiName, config.lockFieldApiName)) {
                    continue;
                }
                Set<Id> ids = targetsByForm.get(formName);
                String q = 'SELECT Id FROM ' + String.escapeSingleQuotes(config.targetObjectApiName) +
                           ' WHERE Id IN :ids AND ' + String.escapeSingleQuotes(config.lockFieldApiName) + ' = true';
                for (SObject rec : Database.query(q)) { // NOPMD — object/field names come from CMDT config
                    locked.add(rec.Id);
                }
            } catch (Exception e) {
                // Deleted/inactive form or bad config: no lock icon for its tickets.
            }
        }
        return locked;
    }

    // ─── Presencia ("X consulte aussi ce ticket") ─────────────────────────────

    /** A presence row counts as "viewing now" if its heartbeat is newer than this. */
    private static final Integer PRESENCE_WINDOW_SECONDS = 90;

    /** Names of OTHER users with a fresh heartbeat on each of the given tickets. */
    private static Map<Id, List<String>> getViewersByRequest(Set<Id> requestIds) {
        Map<Id, List<String>> result = new Map<Id, List<String>>();
        if (requestIds == null || requestIds.isEmpty()) return result;
        Datetime since = Datetime.now().addSeconds(-PRESENCE_WINDOW_SECONDS);
        Id me = UserInfo.getUserId();
        for (Data_Update_Presence__c p : [
            SELECT Request__c, User__r.Name
            FROM Data_Update_Presence__c
            WHERE Request__c IN :requestIds AND Last_Seen__c >= :since AND User__c != :me
            ORDER BY User__r.Name
        ]) {
            if (!result.containsKey(p.Request__c)) result.put(p.Request__c, new List<String>());
            result.get(p.Request__c).add(p.User__r.Name);
        }
        return result;
    }

    /**
     * Called every ~30 s by an open review tab: records that the current user is looking at
     * this ticket and returns the other users looking at it right now.
     */
    @AuraEnabled
    public static List<String> heartbeat(Id requestId) {
        List<String> others = new List<String>();
        if (requestId == null) return others;
        try {
            Id me = UserInfo.getUserId();
            Data_Update_Presence__c row = new Data_Update_Presence__c(
                Key__c       = String.valueOf(requestId) + String.valueOf(me),
                Request__c   = requestId,
                User__c      = me,
                Last_Seen__c = Datetime.now()
            );
            upsert row Key__c;
            // Housekeeping: drop this user's stale rows on other tickets (closed tabs that never
            // sent leaveRequest, e.g. the browser was closed).
            Datetime stale = Datetime.now().addHours(-12);
            delete [SELECT Id FROM Data_Update_Presence__c WHERE User__c = :me AND Last_Seen__c < :stale LIMIT 200];

            Map<Id, List<String>> viewers = getViewersByRequest(new Set<Id>{ requestId });
            if (viewers.containsKey(requestId)) others = viewers.get(requestId);
        } catch (Exception e) {
            // Presence is a convenience only — never break the review panel over it.
        }
        return others;
    }

    /** The current user closed the ticket tab: drop their presence row right away. */
    @AuraEnabled
    public static void leaveRequest(Id requestId) {
        if (requestId == null) return;
        try {
            String key = String.valueOf(requestId) + String.valueOf(UserInfo.getUserId());
            delete [SELECT Id FROM Data_Update_Presence__c WHERE Key__c = :key];
        } catch (Exception e) {
            // See heartbeat — presence never surfaces errors.
        }
    }

    @AuraEnabled
    public static Integer getRequestCount(String statusFilter, String formFilter, String searchTerm) {
        String statusFilterEsc = String.escapeSingleQuotes(statusFilter);
        String formFilterEsc   = String.escapeSingleQuotes(formFilter);
        Set<String> liveDeveloperNames = formFilterEsc == DELETED_FORMS_FILTER
            ? getLiveFormDeveloperNames() : null;
        Boolean searching = String.isNotBlank(searchTerm);
        String soql = (searching
            ? 'SELECT Id, Name, Subject__c, Requested_Name__c, Requested_Email__c'
            : 'SELECT COUNT()') + ' FROM Data_Update_Request__c WHERE Id != null';
        if (statusFilterEsc == 'Open') {
            soql += ' AND Status__c NOT IN (\'Applied\', \'Ignored\', \'Closed\')';
        } else if (!String.isBlank(statusFilterEsc) && statusFilterEsc != 'All') {
            soql += ' AND Status__c = :statusFilterEsc';
        }
        if (formFilterEsc == DELETED_FORMS_FILTER) {
            soql += ' AND Update_Form_DeveloperName__c NOT IN :liveDeveloperNames';
        } else if (!String.isBlank(formFilterEsc) && formFilterEsc != 'All') {
            soql += ' AND Update_Form_DeveloperName__c = :formFilterEsc';
        }
        if (searching) {
            String likePattern = searchLikePattern(searchTerm); // NOPMD — used as SOQL bind variable
            Integer qLim = SEARCH_SCAN_LIMIT;
            soql += ' AND (' + REQUEST_SEARCH_WHERE + ') LIMIT :qLim';
            List<Data_Update_Request__c> rows = Database.query(soql); // NOPMD
            return filterRequestMatches(rows, searchTerm).size();
        }
        return Database.countQuery(soql); // NOPMD
    }

    // ─── Search (case- and accent-insensitive) ─────────────────────────────────
    // SOQL LIKE ignores case but not accents: "lacharite" would never find "Lacharité". Every
    // letter that can carry an accent becomes a one-character wildcard in the LIKE, and the rows
    // are then re-checked here with accents folded. Quotes are safe (bind variable); % and _
    // typed by the user are escaped so they stay literal.

    @TestVisible
    private static Integer SEARCH_SCAN_LIMIT = 2000;

    private static final String REQUEST_SEARCH_WHERE =
        'Subject__c LIKE :likePattern OR Requested_Name__c LIKE :likePattern OR ' +
        'Requested_Email__c LIKE :likePattern OR Name LIKE :likePattern';

    private static final Set<String> ACCENTABLE_LETTERS = new Set<String>{ 'a', 'c', 'e', 'i', 'n', 'o', 'u', 'y' };

    private static final Map<String, String> ACCENT_FOLD = new Map<String, String>{
        'à' => 'a', 'á' => 'a', 'â' => 'a', 'ã' => 'a', 'ä' => 'a', 'å' => 'a',
        'ç' => 'c',
        'è' => 'e', 'é' => 'e', 'ê' => 'e', 'ë' => 'e',
        'ì' => 'i', 'í' => 'i', 'î' => 'i', 'ï' => 'i',
        'ñ' => 'n',
        'ò' => 'o', 'ó' => 'o', 'ô' => 'o', 'õ' => 'o', 'ö' => 'o',
        'ù' => 'u', 'ú' => 'u', 'û' => 'u', 'ü' => 'u',
        'ý' => 'y', 'ÿ' => 'y'
    };

    @TestVisible
    private static String foldAccents(String value) {
        if (value == null) return '';
        String lower = value.toLowerCase();
        if (lower.isAsciiPrintable()) return lower;
        List<String> out = new List<String>();
        for (Integer i = 0; i < lower.length(); i++) {
            String c = lower.substring(i, i + 1);
            String folded = ACCENT_FOLD.get(c);
            out.add(folded != null ? folded : c);
        }
        return String.join(out, '');
    }

    @TestVisible
    private static String searchLikePattern(String term) {
        String t = term.trim();
        List<String> out = new List<String>{ '%' };
        for (Integer i = 0; i < t.length(); i++) {
            String c = t.substring(i, i + 1);
            if (c.equals('%') || c.equals('_') || c.equals('\\')) {
                out.add('\\' + c);
            } else if (ACCENTABLE_LETTERS.contains(foldAccents(c))) {
                out.add('_');
            } else {
                out.add(c);
            }
        }
        out.add('%');
        return String.join(out, '');
    }

    @TestVisible
    private static Boolean matchesSearch(String needle, List<String> values) {
        for (String v : values) {
            if (v != null && foldAccents(v).contains(needle)) return true;
        }
        return false;
    }

    private static List<Data_Update_Request__c> filterRequestMatches(List<Data_Update_Request__c> rows, String term) {
        String needle = foldAccents(term.trim());
        List<Data_Update_Request__c> out = new List<Data_Update_Request__c>();
        for (Data_Update_Request__c r : rows) {
            if (matchesSearch(needle, new List<String>{ r.Name, r.Subject__c, r.Requested_Name__c, r.Requested_Email__c })) {
                out.add(r);
            }
        }
        return out;
    }

    /**
     * Detecta si existen tickets cuya forma de origen (Data_Update_Form__mdt) ya fue eliminada
     * permanentemente, para que el LWC decida si agrega la opción sintética "Tickets from
     * Deleted Forms" al picklist de filtro por formulario.
     */
    @AuraEnabled(cacheable=false)
    public static Boolean hasDeletedFormTickets() {
        Set<String> liveDeveloperNames = getLiveFormDeveloperNames();
        return [
            SELECT COUNT()
            FROM Data_Update_Request__c
            WHERE Update_Form_DeveloperName__c NOT IN :liveDeveloperNames
        ] > 0;
    }

    private static Set<String> getLiveFormDeveloperNames() {
        Set<String> names = new Set<String>();
        for (Data_Update_Form__mdt m : DucFormConfigStore.forms()) {
            names.add(m.DeveloperName);
        }
        return names;
    }

    // ─── Dashboard (KPIs de la bandeja) ────────────────────────────────────

    @AuraEnabled
    public static Map<String, Integer> getStatusCounts(String formDeveloperName) {
        Map<String, Integer> counts = new Map<String, Integer>{
            'Total' => 0, 'Open' => 0, 'New' => 0, 'In Review' => 0,
            'On Hold' => 0, 'Applied' => 0, 'Ignored' => 0, 'Closed' => 0,
            'Reopened' => 0, 'Error' => 0
        };
        Set<String> liveDeveloperNames = formDeveloperName == DELETED_FORMS_FILTER
            ? getLiveFormDeveloperNames() : null;

        String soql = 'SELECT Status__c st, COUNT(Id) cnt FROM Data_Update_Request__c';
        if (formDeveloperName == DELETED_FORMS_FILTER) {
            soql += ' WHERE Update_Form_DeveloperName__c NOT IN :liveDeveloperNames';
        } else if (String.isNotBlank(formDeveloperName) && formDeveloperName != 'All') {
            soql += ' WHERE Update_Form_DeveloperName__c = :formDeveloperName';
        }
        soql += ' GROUP BY Status__c';

        for (AggregateResult ar : Database.query(soql)) {
            String status = (String) ar.get('st');
            Integer cnt   = (Integer) ar.get('cnt');
            counts.put(status, cnt);
            counts.put('Total', counts.get('Total') + cnt);
            if (status != 'Applied' && status != 'Ignored' && status != 'Closed') {
                counts.put('Open', counts.get('Open') + cnt);
            }
        }
        return counts;
    }

    // ─── Estado del request (reopen / hold / resume) ────────────────────────

    @AuraEnabled
    public static void reopenRequest(Id requestId) {
        Data_Update_Request__c request = lockForTransition(requestId, true);
        // An open ticket means a locked record (same rule as a fresh submission and as
        // rollbackChange), so reopening re-locks it — status and lock succeed or fail together.
        Savepoint sp = Database.setSavepoint();
        try {
            update new Data_Update_Request__c(
                Id               = requestId,
                Status__c        = 'Reopened',
                Final_Action__c  = null,
                Closed_Reason__c = null,
                Notes__c         = prependHist(request.Notes__c, buildHistEntry('Reopened', '', ''))
            );
            relockRequestRecord(queryRequest(requestId));
        } catch (Exception e) {
            Database.rollback(sp);
            throw e;
        }
    }

    /**
     * Re-reads the ticket under a row lock and refuses a status change that doesn't fit its
     * CURRENT status: the panel hides these actions on a closed ticket, but a second staff
     * member with a stale panel could still put an Applied ticket On Hold or mark it Ignored.
     * Reopen is only for closed tickets; hold / resume / ignore only for open ones.
     */
    @TestVisible private static Data_Update_Request__c lockForTransition(Id requestId, Boolean mustBeClosed) {
        Data_Update_Request__c request = [
            SELECT Status__c, Notes__c FROM Data_Update_Request__c WHERE Id = :requestId LIMIT 1 FOR UPDATE
        ];
        if (isTerminal(request.Status__c) != mustBeClosed) {
            String code = mustBeClosed ? 'TICKET_STILL_OPEN' : 'TICKET_ALREADY_CLOSED';
            AuraHandledException e = new AuraHandledException(code);
            e.setMessage(code);
            throw e;
        }
        return request;
    }

    private static void relockRequestRecord(Data_Update_Request__c t) {
        if (String.isBlank(t.Target_Record_Id__c)) return;
        DataUpdateFormConfigService.FormConfig config = resolveRequestConfig(t);
        if (config == null || String.isBlank(config.lockFieldApiName)) return;
        Schema.SObjectType targetType = DataUpdateFormConfigService.globalTypes().get(config.targetObjectApiName);
        if (targetType == null) return;
        Map<String, Schema.SObjectField> fieldMap = targetType.getDescribe().fields.getMap();
        if (!isFieldUpdateable(fieldMap, config.lockFieldApiName)) return;
        SObject record = targetType.newSObject(t.Target_Record_Id__c);
        record.put(config.lockFieldApiName, true);
        if (String.isNotBlank(config.lockDateFieldApiName) && isFieldUpdateable(fieldMap, config.lockDateFieldApiName)) {
            record.put(config.lockDateFieldApiName, Datetime.now());
        }
        update record;
    }

    @AuraEnabled
    public static void holdRequest(Id requestId, String reason) {
        Data_Update_Request__c request = lockForTransition(requestId, false);
        update new Data_Update_Request__c(
            Id        = requestId,
            Status__c = 'On Hold',
            Notes__c  = prependHist(request.Notes__c, buildHistEntry('On Hold', '', reason))
        );
    }

    @AuraEnabled
    public static void resumeRequest(Id requestId) {
        Data_Update_Request__c request = lockForTransition(requestId, false);
        update new Data_Update_Request__c(
            Id        = requestId,
            Status__c = 'In Review',
            Notes__c  = prependHist(request.Notes__c, buildHistEntry('In Review', '', ''))
        );
    }

    /**
     * Closes a request without applying any field — e.g. a ticket with nothing to compare,
     * a duplicate, or invalid data. Sets a terminal status (Ignored) so the account's lock
     * (if any) becomes eligible for unlockRecord() right after this call.
     */
    @AuraEnabled
    public static void ignoreRequest(Id requestId, String closedReason, String notes) {
        if (String.isBlank(closedReason)) {
            throw new AuraHandledException('CLOSED_REASON_REQUIRED');
        }
        Data_Update_Request__c request = lockForTransition(requestId, false);
        update new Data_Update_Request__c(
            Id               = requestId,
            Status__c        = 'Ignored',
            Final_Action__c  = 'Ignored',
            Closed_Reason__c = closedReason,
            Notes__c         = prependHist(request.Notes__c, buildHistEntry('Ignored', closedReason, notes))
        );
    }

    // ─── Cuentas bloqueadas (candado) ───────────────────────────────────────

    /**
     * Unlocking is deliberately refused while the record's latest Data_Update_Request__c is
     * still open — the ticket must be closed (Applied/Ignored/Closed) first. Otherwise
     * staff could unlock a record whose original request is still mid-review, letting the
     * contact submit a second, conflicting request before the first one is resolved.
     */
    @AuraEnabled
    public static DataUpdateWrapper.UnlockResult unlockRecord(Id recordId, String formName) {
        DataUpdateWrapper.UnlockResult result = new DataUpdateWrapper.UnlockResult();
        try {
            DataUpdateFormConfigService.FormConfig config = DataUpdateFormConfigService.getForm(formName);
            if (String.isBlank(config.lockFieldApiName)) {
                result.success = true;
                return result;
            }

            // The record must belong to this form's scope (base filter) — a form can't unlock
            // records that only another form manages.
            String scopeQuery = 'SELECT Id FROM ' + config.targetObjectApiName + ' WHERE Id = :recordId';
            String scopeClause = buildBaseFilterClause(config.targetBaseFilterField, config.targetBaseFilterValue);
            if (String.isNotBlank(scopeClause)) scopeQuery += ' AND ' + scopeClause;
            if (Database.query(scopeQuery).isEmpty()) { // NOPMD
                result.success      = false;
                result.errorMessage = 'OUT_OF_SCOPE';
                return result;
            }

            // Any open ticket on this record blocks the unlock, whichever form it came from —
            // forms on the same object share one lock field.
            LatestRequestInfo latest = getOpenRequestInfo(config, new Set<Id>{recordId}).get(recordId);
            if (latest != null) {
                result.success            = false;
                result.errorMessage       = 'REQUEST_STILL_OPEN';
                result.openRequestId      = String.valueOf(latest.requestId);
                result.openRequestNumber  = latest.requestNumber;
                return result;
            }

            Schema.SObjectType targetType = DataUpdateFormConfigService.globalTypes().get(config.targetObjectApiName);
            SObject record = targetType.newSObject(recordId);
            record.put(config.lockFieldApiName, false);
            if (String.isNotBlank(config.lockDateFieldApiName)) {
                record.put(config.lockDateFieldApiName, null);
            }
            update record;
            result.success = true;
        } catch (Exception e) {
            result.success      = false;
            result.errorMessage = 'GENERIC_ERROR';
        }
        return result;
    }

    /** Same scope and open-request guard as unlockRecord, applied per-record — records with a still-open ticket are skipped, not just excluded silently. */
    @AuraEnabled
    public static DataUpdateWrapper.UnlockAllResult unlockAllRecords(String formName) {
        DataUpdateWrapper.UnlockAllResult result = new DataUpdateWrapper.UnlockAllResult();
        try {
            DataUpdateFormConfigService.FormConfig config = DataUpdateFormConfigService.getForm(formName);
            if (String.isBlank(config.lockFieldApiName)) {
                result.success = true;
                return result;
            }

            // Scoped by the form's base filter, like the Locked List — otherwise "Unlock all" on
            // the Account form would also unlock Églises (same lock field, different form).
            String query = 'SELECT Id FROM ' + config.targetObjectApiName +
                ' WHERE ' + config.lockFieldApiName + ' = true';
            String baseFilterClause = buildBaseFilterClause(config.targetBaseFilterField, config.targetBaseFilterValue);
            if (String.isNotBlank(baseFilterClause)) query += ' AND ' + baseFilterClause;
            query += ' LIMIT 9000';
            List<SObject> lockedRecords = Database.query(query); // NOPMD
            if (lockedRecords.isEmpty()) {
                result.success = true;
                return result;
            }

            Map<Id, LatestRequestInfo> openByRecordId = getOpenRequestInfo(config, new Map<Id, SObject>(lockedRecords).keySet());

            List<SObject> toUnlock = new List<SObject>();
            for (SObject record : lockedRecords) {
                Id recId = (Id) record.get('Id');
                if (openByRecordId.containsKey(recId)) {
                    result.skippedCount++;
                    continue;
                }
                record.put(config.lockFieldApiName, false);
                if (String.isNotBlank(config.lockDateFieldApiName)) {
                    record.put(config.lockDateFieldApiName, null);
                }
                toUnlock.add(record);
            }
            if (!toUnlock.isEmpty()) {
                update toUnlock;
            }
            result.unlockedCount = toUnlock.size();
            result.success       = true;
        } catch (Exception e) {
            result.success      = false;
            result.errorMessage = 'GENERIC_ERROR';
        }
        return result;
    }

    @AuraEnabled
    public static DataUpdateWrapper.LockedRecordListResult getLockedRecords(
        String  formName,
        Integer pageSize,
        Integer pageOffset,
        String  searchTerm
    ) {
        DataUpdateWrapper.LockedRecordListResult result = new DataUpdateWrapper.LockedRecordListResult();
        try {
            DataUpdateFormConfigService.FormConfig config = DataUpdateFormConfigService.getForm(formName);
            if (String.isBlank(config.lockFieldApiName)) {
                result.success = true;
                return result;
            }

            Integer lim = (pageSize == null || pageSize <= 0) ? 25 : pageSize;
            Integer off = (pageOffset == null || pageOffset < 0) ? 0 : pageOffset;

            Set<String> queryFields = new Set<String>{'Id', config.recordNameFieldApiName, config.lockFieldApiName};
            if (String.isNotBlank(config.lockDateFieldApiName)) {
                queryFields.add(config.lockDateFieldApiName);
            }
            String fieldList = String.join(new List<String>(queryFields), ', ');

            String whereClause = config.lockFieldApiName + ' = true';
            String baseFilterClause = buildBaseFilterClause(config.targetBaseFilterField, config.targetBaseFilterValue);
            if (String.isNotBlank(baseFilterClause)) {
                whereClause += ' AND ' + baseFilterClause;
            }
            Boolean searching = String.isNotBlank(searchTerm);
            if (searching) {
                String likePattern = searchLikePattern(searchTerm); // NOPMD — used as SOQL bind variable
                whereClause += ' AND ' + config.recordNameFieldApiName + ' LIKE :likePattern';
            }
            String orderBy = String.isNotBlank(config.lockDateFieldApiName) ? config.lockDateFieldApiName + ' DESC' : 'Id DESC';

            List<SObject> lockedRecords;
            if (searching) {
                // Same accent-insensitive re-check as the ticket search; paging on the matches.
                Integer qLim = SEARCH_SCAN_LIMIT;
                String query = 'SELECT ' + fieldList + ' FROM ' + config.targetObjectApiName +
                    ' WHERE ' + whereClause + ' ORDER BY ' + orderBy + ' LIMIT :qLim';
                String needle = foldAccents(searchTerm.trim());
                List<SObject> matches = new List<SObject>();
                for (SObject rec : Database.query(query)) { // NOPMD
                    if (matchesSearch(needle, new List<String>{ valueToString(rec.get(config.recordNameFieldApiName)) })) {
                        matches.add(rec);
                    }
                }
                result.totalCount = matches.size();
                lockedRecords = new List<SObject>();
                for (Integer i = off; i < Math.min(off + lim, matches.size()); i++) {
                    lockedRecords.add(matches[i]);
                }
            } else {
                String countQuery = 'SELECT COUNT() FROM ' + config.targetObjectApiName + ' WHERE ' + whereClause;
                result.totalCount = Database.countQuery(countQuery); // NOPMD

                // Same 9000-row scope as unlockAllRecords: records with an open ticket are skipped there.
                String allQuery = 'SELECT Id FROM ' + config.targetObjectApiName + ' WHERE ' + whereClause + ' LIMIT 9000';
                Set<Id> allLockedIds = new Map<Id, SObject>(Database.query(allQuery)).keySet(); // NOPMD
                result.unlockableCount = allLockedIds.size() - getOpenRequestInfo(config, allLockedIds).size();

                String query = 'SELECT ' + fieldList + ' FROM ' + config.targetObjectApiName +
                    ' WHERE ' + whereClause + ' ORDER BY ' + orderBy + ' LIMIT :lim OFFSET :off';
                lockedRecords = Database.query(query); // NOPMD
            }

            Set<Id> lockedIds = new Map<Id, SObject>(lockedRecords).keySet();
            Map<Id, LatestRequestInfo> latestByRecordId = getLatestRequestInfo(config, lockedIds);
            Map<Id, LatestRequestInfo> openByRecordId = getOpenRequestInfo(config, lockedIds);

            for (SObject record : lockedRecords) {
                Id recId = (Id) record.get('Id');
                // An open ticket (from any form) is what actually blocks the unlock, so show it first.
                LatestRequestInfo latest = openByRecordId.containsKey(recId) ? openByRecordId.get(recId) : latestByRecordId.get(recId);
                DataUpdateWrapper.LockedRecordSummary summary = new DataUpdateWrapper.LockedRecordSummary();
                summary.recordId   = String.valueOf(recId);
                summary.recordName = valueToString(record.get(config.recordNameFieldApiName));
                summary.lockedDate = String.isNotBlank(config.lockDateFieldApiName)
                    ? (Datetime) record.get(config.lockDateFieldApiName)
                    : null;
                if (latest != null) {
                    summary.latestRequestId       = String.valueOf(latest.requestId);
                    summary.latestRequestNumber   = latest.requestNumber;
                    summary.latestRequestStatus   = latest.status;
                    summary.isBlockedByOpenRequest = !isTerminal(latest.status);
                }
                result.records.add(summary);
            }
            result.success = true;
        } catch (Exception e) {
            result.success      = false;
            result.errorMessage = 'GENERIC_ERROR';
        }
        return result;
    }

    /**
     * Full-list checklist for a form's base-filtered records (e.g. every Account with
     * RecordType = Eglise) showing whether each one has submitted THIS form. "Responded" is
     * based on the form's own requests (not the lock field, which is shared by every form on
     * the same object), so a new form starts at 0 even if records answered an older one.
     * Returns EVERY record in scope so an unresponded record is visible too.
     */
    @AuraEnabled
    public static DataUpdateWrapper.ChecklistResult getFormResponseChecklist(String formName) {
        return getFormResponseChecklistSince(formName, null);
    }

    /**
     * Same as getFormResponseChecklist, counting only requests created on/after sinceIsoDate
     * (yyyy-MM-dd, user's time zone) — e.g. "this month" for a recurring campaign.
     * Blank = since the beginning.
     */
    @AuraEnabled
    public static DataUpdateWrapper.ChecklistResult getFormResponseChecklistSince(String formName, String sinceIsoDate) {
        DataUpdateWrapper.ChecklistResult result = new DataUpdateWrapper.ChecklistResult();
        try {
            DataUpdateFormConfigService.FormConfig config = DataUpdateFormConfigService.getFormBasic(formName);
            Datetime since = String.isBlank(sinceIsoDate)
                ? null
                : Datetime.newInstance(Date.valueOf(sinceIsoDate), Time.newInstance(0, 0, 0, 0));

            String fieldList = String.join(new List<String>(new Set<String>{ 'Id', config.recordNameFieldApiName }), ', ');
            String baseFilterClause = buildBaseFilterClause(config.targetBaseFilterField, config.targetBaseFilterValue);
            String whereClause = String.isNotBlank(baseFilterClause) ? ' WHERE ' + baseFilterClause : '';

            String query = 'SELECT ' + fieldList + ' FROM ' + config.targetObjectApiName +
                whereClause + ' ORDER BY ' + config.recordNameFieldApiName + ' ASC LIMIT 2000';
            List<SObject> records = Database.query(query); // NOPMD

            Set<String> recordIds = new Set<String>();
            for (SObject record : records) recordIds.add(String.valueOf(record.get('Id')));
            Map<String, Datetime> lastResponseById = getLastResponseByRecord(config, recordIds, since);

            for (SObject record : records) {
                DataUpdateWrapper.ChecklistItem item = new DataUpdateWrapper.ChecklistItem();
                item.recordId     = String.valueOf(record.get('Id'));
                item.recordName   = valueToString(record.get(config.recordNameFieldApiName));
                item.lastResponse = lastResponseById.get(item.recordId);
                item.responded    = item.lastResponse != null;
                result.items.add(item);
            }
            result.success = true;
        } catch (Exception e) {
            result.success      = false;
            result.errorMessage = 'GENERIC_ERROR';
        }
        return result;
    }

    // Latest submission of this form per record (any status: a request staff ignored was
    // still an answer from the record).
    private static Map<String, Datetime> getLastResponseByRecord(DataUpdateFormConfigService.FormConfig config,
            Set<String> recordIds, Datetime since) {
        Map<String, Datetime> lastById = new Map<String, Datetime>();
        if (recordIds.isEmpty()) return lastById;
        String query = 'SELECT Target_Record_Id__c, CreatedDate FROM Data_Update_Request__c'
            + ' WHERE Update_Form_DeveloperName__c = \'' + String.escapeSingleQuotes(config.developerName) + '\''
            + ' AND Target_Record_Id__c IN :recordIds'
            + (since != null ? ' AND CreatedDate >= :since' : '')
            + ' ORDER BY CreatedDate DESC';
        for (Data_Update_Request__c t : Database.query(query)) { // NOPMD
            if (!lastById.containsKey(t.Target_Record_Id__c)) {
                lastById.put(t.Target_Record_Id__c, t.CreatedDate);
            }
        }
        return lastById;
    }

    private static Map<Id, LatestRequestInfo> getLatestRequestInfo(DataUpdateFormConfigService.FormConfig config, Set<Id> recordIds) {
        Map<Id, LatestRequestInfo> latestByRecordId = new Map<Id, LatestRequestInfo>();
        if (recordIds.isEmpty()) return latestByRecordId;
        for (Data_Update_Request__c t : [
            SELECT Id, Name, Target_Record_Id__c, Status__c
            FROM Data_Update_Request__c
            WHERE Target_Object_API_Name__c = :config.targetObjectApiName
            AND Target_Record_Id__c IN :recordIds
            AND Update_Form_DeveloperName__c = :config.developerName
            ORDER BY CreatedDate DESC
        ]) {
            if (!latestByRecordId.containsKey(t.Target_Record_Id__c)) {
                LatestRequestInfo info = new LatestRequestInfo();
                info.requestId     = t.Id;
                info.requestNumber = t.Name;
                info.status        = t.Status__c;
                latestByRecordId.put(t.Target_Record_Id__c, info);
            }
        }
        return latestByRecordId;
    }

    /**
     * Latest still-open request per record from ANY form on the same target object. Forms on
     * one object share the lock field, so an open ticket from another form must still block
     * the unlock (getLatestRequestInfo is scoped to one form and would miss it).
     */
    private static Map<Id, LatestRequestInfo> getOpenRequestInfo(DataUpdateFormConfigService.FormConfig config, Set<Id> recordIds) {
        Map<Id, LatestRequestInfo> openByRecordId = new Map<Id, LatestRequestInfo>();
        if (recordIds.isEmpty()) return openByRecordId;
        for (Data_Update_Request__c t : [
            SELECT Id, Name, Target_Record_Id__c, Status__c
            FROM Data_Update_Request__c
            WHERE Target_Object_API_Name__c = :config.targetObjectApiName
            AND Target_Record_Id__c IN :recordIds
            AND Status__c NOT IN ('Applied', 'Ignored', 'Closed')
            ORDER BY CreatedDate DESC
        ]) {
            if (!openByRecordId.containsKey(t.Target_Record_Id__c)) {
                LatestRequestInfo info = new LatestRequestInfo();
                info.requestId     = t.Id;
                info.requestNumber = t.Name;
                info.status        = t.Status__c;
                openByRecordId.put(t.Target_Record_Id__c, info);
            }
        }
        return openByRecordId;
    }

    // ─── EDA preferred email ────────────────────────────────────────────────
    // With EDA's preferred-email enforcement on, Contact.Email is a copy of the email field named
    // by hed__Preferred_Email__c: a direct Email change is reverted on save, and a preference
    // pointing at a blank field is refused. So Email's answer is saved in the preferred field; on
    // a contact without any email, in hed__AlternateEmail__c with the preference set too (what EDA
    // does itself) — noted in the log so a rollback clears both together. All queried
    // dynamically: the class still runs in an org without EDA (then Email is written as-is).
    @TestVisible private static final String EMAIL_FIELD = 'Email';
    @TestVisible private static final String PREFERRED_EMAIL_FIELD = 'hed__Preferred_Email__c';
    private static final String DEFAULT_EMAIL_FIELD = 'hed__AlternateEmail__c';
    private static final String DEFAULT_EMAIL_PREFERENCE = 'Alternate Email';
    // Decision note {field, before, after}: the preference set with that field on apply.
    @TestVisible private static final String PREFERRED_NOTE_KEY = '__preferredEmail';
    // Same for the phone: EDA fills Phone from hed__PreferredPhone__c.
    private static final String PHONE_FIELD = 'Phone';
    @TestVisible private static final String PREFERRED_PHONE_FIELD = 'hed__PreferredPhone__c';
    @TestVisible private static final String PREFERRED_PHONE_NOTE_KEY = '__preferredPhone';
    private static final String DEFAULT_PHONE_FIELD = 'MobilePhone';
    private static final String DEFAULT_PHONE_PREFERENCE = 'Mobile Phone';
    private static final Map<String, String> MAIN_FIELD_BY_KIND = new Map<String, String>{
        'EMAIL' => EMAIL_FIELD, 'PHONE' => PHONE_FIELD };
    private static final Map<String, String> PREFERENCE_FIELD_BY_KIND = new Map<String, String>{
        'EMAIL' => PREFERRED_EMAIL_FIELD, 'PHONE' => PREFERRED_PHONE_FIELD };
    private static final Map<String, String> PREFERENCE_NOTE_BY_KIND = new Map<String, String>{
        'EMAIL' => PREFERRED_NOTE_KEY, 'PHONE' => PREFERRED_PHONE_NOTE_KEY };
    // Fields never offered as a "Save in" place even if they are of the right kind.
    private static final Set<String> EXCLUDED_SLOTS = new Set<String>{ 'fax', 'assistantphone', 'personassistantphone' };
    @TestVisible private static Boolean testEnforcementDisabled;
    @TestVisible private static String testPreference;
    @TestVisible private static Boolean testPhoneEnforcementDisabled;
    @TestVisible private static String testPhonePreference;

    /** field: where Email is saved (null if the preference names no known field); setPreference: value to write in hed__Preferred_Email__c, null when already set. */
    @TestVisible private class EmailTarget {
        String field;
        @TestVisible String setPreference;
        String preference;
    }

    /** Null when EDA doesn't manage Email on this record (not a Contact, no EDA, enforcement off). */
    @TestVisible private static EmailTarget emailTarget(String objectApiName, Id recordId, Map<String, Schema.SObjectField> fieldMap) {
        if (objectApiName != 'Contact' || !fieldMap.containsKey(PREFERRED_EMAIL_FIELD.toLowerCase())) return null;
        if (isPreferredEmailEnforcementDisabled()) return null;
        List<SObject> rows = Database.query('SELECT ' + PREFERRED_EMAIL_FIELD + ' FROM Contact WHERE Id = :recordId LIMIT 1');
        EmailTarget target = new EmailTarget();
        target.preference = testPreference != null ? testPreference : rows.isEmpty() ? null : (String) rows[0].get(PREFERRED_EMAIL_FIELD);
        target.field = String.isBlank(target.preference) ? DEFAULT_EMAIL_FIELD : emailFieldForPreference(target.preference, fieldMap);
        target.setPreference = String.isBlank(target.preference) ? DEFAULT_EMAIL_PREFERENCE : null;
        return target;
    }

    /** Same for Phone: saved in the field hed__PreferredPhone__c names; none set → MobilePhone, preference set too. */
    @TestVisible private static EmailTarget phoneTarget(String objectApiName, Id recordId, Map<String, Schema.SObjectField> fieldMap) {
        if (objectApiName != 'Contact' || !fieldMap.containsKey(PREFERRED_PHONE_FIELD.toLowerCase()) || isPreferredPhoneEnforcementDisabled()) return null;
        List<SObject> rows = Database.query('SELECT ' + PREFERRED_PHONE_FIELD + ' FROM Contact WHERE Id = :recordId LIMIT 1');
        EmailTarget target = new EmailTarget();
        target.preference = testPhonePreference != null ? testPhonePreference : rows.isEmpty() ? null : (String) rows[0].get(PREFERRED_PHONE_FIELD);
        Map<String, String> prefByField = preferenceByField(fieldMap, 'PHONE');
        for (String field : prefByField.keySet()) {
            if (prefByField.get(field) == target.preference) target.field = field;
        }
        if (String.isBlank(target.preference)) target.field = DEFAULT_PHONE_FIELD;
        target.setPreference = String.isBlank(target.preference) ? DEFAULT_PHONE_PREFERENCE : null;
        return target;
    }

    /** Kind (EMAIL / PHONE) → where EDA wants that main field's answer saved on this record. */
    private static Map<String, EmailTarget> mainTargets(String objectApiName, Id recordId, Map<String, Schema.SObjectField> fieldMap) {
        Map<String, EmailTarget> out = new Map<String, EmailTarget>();
        EmailTarget email = emailTarget(objectApiName, recordId, fieldMap);
        EmailTarget phone = phoneTarget(objectApiName, recordId, fieldMap);
        if (email != null) out.put('EMAIL', email);
        if (phone != null) out.put('PHONE', phone);
        return out;
    }

    @TestVisible private static final String EMAIL_PREFERENCE_UNKNOWN = 'EMAIL_PREFERENCE_UNKNOWN';
    @TestVisible private static final String PHONE_PREFERENCE_UNKNOWN = 'PHONE_PREFERENCE_UNKNOWN';
    private static final Map<String, String> PREFERENCE_UNKNOWN_BY_KIND = new Map<String, String>{
        'EMAIL' => EMAIL_PREFERENCE_UNKNOWN, 'PHONE' => PHONE_PREFERENCE_UNKNOWN };
    /** The message is the code returned to the panel (EMAIL_ / PHONE_PREFERENCE_UNKNOWN). */
    private class EmailPreferenceException extends Exception {}
    // "Save in" / preferred choices the record can't take: told to staff, the ticket is left as it was.
    @TestVisible private static final String INVALID_SAVE_CHOICE = 'INVALID_SAVE_CHOICE';
    private class SaveChoiceException extends Exception {}

    /** Email field API name → the hed__Preferred_Email__c value naming it (active values only). */
    private static Map<String, String> preferenceByField(Map<String, Schema.SObjectField> fieldMap) {
        return preferenceByField(fieldMap, 'EMAIL');
    }

    /** Same for a kind (EMAIL / PHONE): field API name → the preference picklist value naming it. */
    private static Map<String, String> preferenceByField(Map<String, Schema.SObjectField> fieldMap, String kind) {
        Map<String, String> out = new Map<String, String>();
        Schema.SObjectField pref = fieldMap.get(PREFERENCE_FIELD_BY_KIND.get(kind).toLowerCase());
        if (pref == null) return out;
        // Email / Phone are what EDA fills from the preference — never a preference themselves.
        Map<String, String> fieldByKey = new Map<String, String>();
        for (Schema.SObjectField f : fieldMap.values()) {
            Schema.DescribeFieldResult d = f.getDescribe();
            if (kindOf(d.getType()) != kind || !d.isUpdateable() || d.getName() == EMAIL_FIELD || d.getName() == PHONE_FIELD) continue;
            if (!fieldByKey.containsKey(emailKey(d.getName()))) fieldByKey.put(emailKey(d.getName()), d.getName());
        }
        for (Schema.PicklistEntry e : pref.getDescribe().getPicklistValues()) {
            String field = e.isActive() ? fieldByKey.get(emailKey(e.getValue())) : null;
            if (field != null && !out.containsKey(field)) out.put(field, e.getValue());
        }
        return out;
    }

    private static String kindOf(Schema.DisplayType type) {
        return type == Schema.DisplayType.EMAIL ? 'EMAIL' : type == Schema.DisplayType.PHONE ? 'PHONE' : null;
    }

    /**
     * Email and phone fields of the record a value can be saved in ("Save in"), with what each
     * holds now; on an EDA contact also the preference each can take and the one preferred now.
     * Left out: Email when EDA saves it elsewhere (emailSavedIn), Phone on an EDA contact (EDA
     * fills it from the preferred phone and reverts a direct write), fax-like fields, and
     * person-account fields on a business account.
     */
    public static List<DataUpdateWrapper.GroupSlotGroup> buildSaveOptions(Id recId, Map<String, Schema.SObjectField> fieldMap, String emailSavedIn) {
        String objectApiName = recId.getSObjectType().getDescribe().getName();
        Boolean isContact = objectApiName == 'Contact';
        // Short-circuits in orgs without Person Accounts (SEMBEQ): the probe only runs when the field exists.
        Boolean isPerson = fieldMap.containsKey('ispersonaccount') && Database.query('SELECT IsPersonAccount FROM ' + objectApiName + ' WHERE Id = :recId LIMIT 1')[0].get('IsPersonAccount') == true;
        Map<String, DataUpdateWrapper.GroupSlotGroup> groups = new Map<String, DataUpdateWrapper.GroupSlotGroup>();
        Set<String> queryFields = new Set<String>{ 'Id' };
        for (String key : fieldMap.keySet()) {
            Schema.DescribeFieldResult f = fieldMap.get(key).getDescribe();
            String kind = kindOf(f.getType());
            if (kind == null || !f.isUpdateable() || !f.isAccessible() || EXCLUDED_SLOTS.contains(key)) continue;
            if ((emailSavedIn != null && key == 'email')
                    || (isContact && key == 'phone' && fieldMap.containsKey(PREFERRED_PHONE_FIELD.toLowerCase()) && !isPreferredPhoneEnforcementDisabled())) continue;
            // Person-account fields (PersonEmail, PersonMobilePhone...) only on person accounts.
            if (!isPerson && key.startsWith('person') && !f.isCustom()) continue;
            if (!groups.containsKey(kind)) {
                DataUpdateWrapper.GroupSlotGroup g = new DataUpdateWrapper.GroupSlotGroup();
                g.kind = kind;
                groups.put(kind, g);
            }
            DataUpdateWrapper.GroupSlot slot = new DataUpdateWrapper.GroupSlot();
            slot.apiName = f.getName();
            slot.label   = f.getLabel();
            groups.get(kind).slots.add(slot);
            queryFields.add(f.getName());
        }
        Map<String, Map<String, String>> prefByKind = new Map<String, Map<String, String>>();
        for (String kind : groups.keySet()) {
            Schema.SObjectField pref = isContact ? fieldMap.get(PREFERENCE_FIELD_BY_KIND.get(kind).toLowerCase()) : null;
            if (pref == null || !pref.getDescribe().isUpdateable()) continue;
            prefByKind.put(kind, preferenceByField(fieldMap, kind));
            queryFields.add(pref.getDescribe().getName());
        }
        SObject rec = Database.query('SELECT ' + String.join(new List<String>(queryFields), ', ')
            + ' FROM ' + objectApiName + ' WHERE Id = :recId LIMIT 1');
        for (DataUpdateWrapper.GroupSlotGroup g : groups.values()) {
            Map<String, String> prefs = prefByKind.get(g.kind);
            String current = prefs != null ? (String) rec.get(PREFERENCE_FIELD_BY_KIND.get(g.kind)) : null;
            for (DataUpdateWrapper.GroupSlot slot : g.slots) {
                Object v = rec.get(slot.apiName);
                slot.value      = v == null ? '' : String.valueOf(v);
                slot.preference = prefs != null ? prefs.get(slot.apiName) : null;
                if (current != null && current == slot.preference) g.preferredField = slot.apiName;
            }
        }
        return groups.values();
    }

    /** One-ticket panel: which rows can go to another field (saveKind) and the places offered. */
    private static void setSaveOptions(DataUpdateWrapper.ComparisonData result, DataUpdateFormConfigService.FormConfig config, Id recordId) {
        Map<String, Schema.SObjectField> fieldMap = DataUpdateFormConfigService.globalTypes().get(config.targetObjectApiName).getDescribe().fields.getMap();
        Boolean hasKind = false;
        for (DataUpdateWrapper.ComparisonField cf : result.fields) {
            Schema.SObjectField f = fieldMap.get(cf.fieldApiName.toLowerCase());
            cf.saveKind = f == null || cf.isHistoryOnly == true || cf.isHistorize == true ? null : kindOf(f.getDescribe().getType());
            if (cf.saveKind != null) hasKind = true;
        }
        if (hasKind) result.saveOptions = buildSaveOptions(recordId, fieldMap, emailSavedIn(config.targetObjectApiName, recordId, fieldMap));
    }

    /** The hed__Preferred_Email__c value naming this email field, or null (not an email field EDA knows). */
    @TestVisible private static String preferenceForField(String fieldApiName, Map<String, Schema.SObjectField> fieldMap) {
        for (String field : preferenceByField(fieldMap).keySet()) {
            if (field.equalsIgnoreCase(fieldApiName)) return preferenceByField(fieldMap).get(field);
        }
        return null;
    }

    /**
     * Preference changes a field rollback makes, by kind: {field, before, after}. The apply's own
     * preference goes back to what it was, unless staff changed it since; a preference left on
     * the field this rollback empties moves to another field that still holds a value.
     */
    private static Map<String, Object> rollbackPreferences(String objectApiName, Id recordId, String fieldApiName,
            Object restoredValue, Map<String, Schema.SObjectField> fieldMap, Map<String, Object> decisions) {
        Map<String, Object> out = new Map<String, Object>();
        Schema.SObjectField rolled = fieldMap.get(fieldApiName.toLowerCase());
        String rolledKind = rolled == null ? null : kindOf(rolled.getDescribe().getType());
        if (objectApiName != 'Contact' || rolledKind == null) return out;
        String prefField = PREFERENCE_FIELD_BY_KIND.get(rolledKind);
        Schema.SObjectField pref = fieldMap.get(prefField.toLowerCase());
        if (pref == null || !pref.getDescribe().isUpdateable()) return out;
        String current = (String) Database.query('SELECT ' + prefField + ' FROM Contact WHERE Id = :recordId LIMIT 1')[0].get(prefField);
        String restore = current;
        Map<String, Object> note = decisions.get(PREFERENCE_NOTE_BY_KIND.get(rolledKind)) instanceof Map<String, Object>
            ? (Map<String, Object>) decisions.get(PREFERENCE_NOTE_BY_KIND.get(rolledKind)) : new Map<String, Object>();
        if (fieldApiName.equalsIgnoreCase(valueToString(note.get('field'))) && current == valueToString(note.get('after'))) {
            restore = valueToString(note.get('before'));
        }
        if (restoredValue == null) {
            String restoreField = null;
            Map<String, String> prefByField = preferenceByField(fieldMap, rolledKind);
            for (String name : prefByField.keySet()) {
                if (prefByField.get(name) == restore) restoreField = name;
            }
            Boolean ownChange = fieldApiName.equalsIgnoreCase(valueToString(note.get('field')));
            if ((String.isBlank(restore) && ownChange) || fieldApiName.equalsIgnoreCase(restoreField)) {
                restore = preferenceForFilledField(recordId, fieldApiName, fieldMap, rolledKind);
            }
        }
        if (restore != current) {
            out.put(rolledKind, new Map<String, Object>{ 'field' => fieldApiName, 'before' => current, 'after' => restore });
        }
        return out;
    }

    /** Preference for another field of the kind that still holds a value (EDA refuses a blank preference then). */
    private static String preferenceForFilledField(Id recordId, String clearedField, Map<String, Schema.SObjectField> fieldMap, String kind) {
        Map<String, String> prefByField = preferenceByField(fieldMap, kind);
        for (String name : new List<String>(prefByField.keySet())) {
            if (name.equalsIgnoreCase(clearedField)) prefByField.remove(name);
        }
        if (prefByField.isEmpty()) return null;
        SObject row = Database.query('SELECT ' + String.join(new List<String>(prefByField.keySet()), ', ')
            + ' FROM Contact WHERE Id = :recordId LIMIT 1');
        for (String name : prefByField.keySet()) {
            if (row.get(name) != null) return prefByField.get(name);
        }
        return null;
    }

    /** The field Email is really saved in on this record, or null when Email is written as-is. */
    public static String emailSavedIn(String objectApiName, Id recordId, Map<String, Schema.SObjectField> fieldMap) {
        EmailTarget target = emailTarget(objectApiName, recordId, fieldMap);
        return target != null ? target.field : null;
    }

    /** The field Phone is really saved in on this record, or null when Phone is written as-is. */
    public static String phoneSavedIn(String objectApiName, Id recordId, Map<String, Schema.SObjectField> fieldMap) {
        EmailTarget target = phoneTarget(objectApiName, recordId, fieldMap);
        return target != null ? target.field : null;
    }

    // Matched on API names, never on labels (translated per user language):
    // "Alternate Email" ↔ hed__AlternateEmail__c, "Alternative Email 1" ↔ Alternative_Email_1__c.
    @TestVisible private static String emailFieldForPreference(String preferred, Map<String, Schema.SObjectField> fieldMap) {
        if (String.isBlank(preferred)) return null;
        String key = emailKey(preferred);
        for (Schema.SObjectField f : fieldMap.values()) {
            Schema.DescribeFieldResult d = f.getDescribe();
            if (d.getType() != Schema.DisplayType.EMAIL || !d.isUpdateable() || d.getName() == EMAIL_FIELD) continue;
            if (emailKey(d.getName()) == key) return d.getName();
        }
        return null;
    }

    private static String emailKey(String value) {
        return value.removeStartIgnoreCase('hed__').removeEndIgnoreCase('__c').replaceAll('[^A-Za-z0-9]', '').toLowerCase();
    }

    private static Boolean sameEmail(String a, String b) {
        return (a == null ? '' : a).trim().equalsIgnoreCase((b == null ? '' : b).trim());
    }

    /** Same email (case / spaces ignored) or same phone (digits only). */
    private static Boolean sameValue(String kind, String a, String b) {
        if (kind == 'EMAIL') return sameEmail(a, b);
        return (a == null ? '' : a).replaceAll('[^0-9]', '') == (b == null ? '' : b).replaceAll('[^0-9]', '');
    }

    // Org default of EDA's hierarchy setting; no row (or no EDA) → enforcement treated as on.
    @TestVisible private static Boolean isPreferredEmailEnforcementDisabled() {
        if (testEnforcementDisabled != null) return testEnforcementDisabled;
        if (DataUpdateFormConfigService.globalTypes().get('hed__Hierarchy_Settings__c') == null) return false;
        Id orgId = UserInfo.getOrganizationId();
        List<SObject> rows = Database.query('SELECT hed__Disable_Preferred_Email_Enforcement__c FROM hed__Hierarchy_Settings__c'
            + ' WHERE SetupOwnerId = :orgId LIMIT 1');
        return !rows.isEmpty() && rows[0].get('hed__Disable_Preferred_Email_Enforcement__c') == true;
    }

    // Same for the phone (hed__Disable_Preferred_Phone_Enforcement__c).
    @TestVisible private static Boolean isPreferredPhoneEnforcementDisabled() {
        if (testPhoneEnforcementDisabled != null) return testPhoneEnforcementDisabled;
        if (DataUpdateFormConfigService.globalTypes().get('hed__Hierarchy_Settings__c') == null) return false;
        Id orgId = UserInfo.getOrganizationId();
        List<SObject> rows = Database.query('SELECT hed__Disable_Preferred_Phone_Enforcement__c FROM hed__Hierarchy_Settings__c'
            + ' WHERE SetupOwnerId = :orgId LIMIT 1');
        return !rows.isEmpty() && rows[0].get('hed__Disable_Preferred_Phone_Enforcement__c') == true;
    }

    /**
     * EDA contact: tells the panel where Email (Phone) is saved, and flags the preferred field's row
     * when applying it would change the main email (phone) differently from Email's own answer.
     */
    private static void markMainTargets(DataUpdateWrapper.ComparisonData result, DataUpdateFormConfigService.FormConfig config, Id recordId) {
        Map<String, Schema.SObjectField> fieldMap = DataUpdateFormConfigService.globalTypes().get(config.targetObjectApiName).getDescribe().fields.getMap();
        List<DataUpdateWrapper.ComparisonField> all = new List<DataUpdateWrapper.ComparisonField>(result.fields);
        all.addAll(result.unchangedFields);
        for (String kind : MAIN_FIELD_BY_KIND.keySet()) {
            DataUpdateWrapper.ComparisonField mainCf;
            for (DataUpdateWrapper.ComparisonField cf : all) {
                if (cf.fieldApiName.equalsIgnoreCase(MAIN_FIELD_BY_KIND.get(kind)) && cf.isHistorize != true) mainCf = cf;
            }
            // A blank Email is never applied — nothing to explain.
            if (mainCf == null || String.isBlank(mainCf.submittedValue)) continue;
            EmailTarget target = kind == 'EMAIL' ? emailTarget(config.targetObjectApiName, recordId, fieldMap)
                : phoneTarget(config.targetObjectApiName, recordId, fieldMap);
            if (target == null) continue;
            if (target.field == null) {
                mainCf.emailPreferenceUnknown = target.preference;
                continue;
            }
            String dest = target.field;
            mainCf.savedInFieldApiName = dest;
            mainCf.savedInLabelFr = mainCf.savedInLabelEn = fieldMap.get(dest.toLowerCase()).getDescribe().getLabel();
            for (DataUpdateFormConfigService.FormFieldConfig fc : config.fields) {
                if (fc.fieldApiName.equalsIgnoreCase(dest)) {
                    mainCf.savedInLabelFr = fc.labelFr;
                    mainCf.savedInLabelEn = fc.labelEn;
                }
            }
            for (DataUpdateWrapper.ComparisonField cf : result.fields) {
                if (cf.fieldApiName.equalsIgnoreCase(dest) && !sameValue(kind, cf.submittedValue, mainCf.submittedValue)) {
                    cf.emailConflict = true;
                    mainCf.emailConflict = mainCf.isDifferent;
                }
            }
        }
    }

    /** Adds a value to the "__notApplied" note (created when missing). */
    private static Map<String, Object> addNotApplied(Map<String, Object> notes, DataUpdateFormConfigService.FormFieldConfig fc, String value, String reason) {
        Map<String, Object> out = notes != null ? notes : new Map<String, Object>();
        List<Object> items = out.get('__notApplied') instanceof List<Object> ? (List<Object>) out.get('__notApplied') : new List<Object>();
        items.add(new Map<String, Object>{ 'labelFr' => fc.labelFr, 'labelEn' => fc.labelEn, 'value' => valueToString(value), 'reason' => reason });
        out.put('__notApplied', items);
        return out;
    }

    private static String placeOf(Map<String, String> overrides, String field) {
        String picked = overrides != null ? overrides.get(field) : null;
        return String.isBlank(picked) ? field : picked;
    }

    /**
     * Builds a "field = value" fragment for a form's Target_Base_Filter_Field__c/Value__c
     * (e.g. IsPersonAccount = true, or RecordType.DeveloperName = 'Eglise'). The stored value
     * is always a String, but the target field can be Boolean — quoting a Boolean literal
     * breaks the query (MALFORMED_QUERY), so 'true'/'false' are emitted unquoted.
     */
    @TestVisible private static String buildBaseFilterClause(String field, String value) {
        if (String.isBlank(field) || String.isBlank(value)) return null;
        if (value.equalsIgnoreCase('true') || value.equalsIgnoreCase('false')) {
            return field + ' = ' + value.toLowerCase();
        }
        List<String> values = DataUpdateFormConfigService.splitFilterValues(value);
        if (values.size() == 1) {
            return field + ' = \'' + String.escapeSingleQuotes(values[0]) + '\'';
        }
        List<String> quoted = new List<String>();
        for (String v : values) quoted.add('\'' + String.escapeSingleQuotes(v) + '\'');
        return field + ' IN (' + String.join(quoted, ', ') + ')';
    }

    private static Boolean isFieldUpdateable(Map<String, Schema.SObjectField> fieldMap, String fieldApiName) {
        Schema.SObjectField field = fieldMap.get(fieldApiName.toLowerCase());
        return field != null && field.getDescribe().isUpdateable();
    }

    @TestVisible private static Boolean isFieldAccessible(String objectApiName, String fieldApiName) {
        Schema.SObjectType targetType = DataUpdateFormConfigService.globalTypes().get(objectApiName);
        if (targetType == null) return false;
        Schema.SObjectField field = targetType.getDescribe().fields.getMap().get(fieldApiName.toLowerCase());
        return field != null && field.getDescribe().isAccessible();
    }

    private static String buildHistEntry(String status, String reason, String notes) {
        String encNotes   = String.isBlank(notes) ? '' : notes.replace('\n', '\\n');
        String safeReason = reason != null ? reason : '';
        // Date-time in GMT + who did it, so the Historique can show and order the change.
        String stamp      = System.now().formatGmt('yyyy-MM-dd HH:mm:ss');
        String who        = UserInfo.getName().replace('|', ' ').replace(']', ' ');
        return '[HIST:' + status + '|||' + safeReason + '|||' + encNotes + '|||' + stamp + '|||' + who + ']';
    }

    private static String prependHist(String existingNotes, String histEntry) {
        String existing = existingNotes == null ? '' : existingNotes;
        return String.isBlank(existing) ? histEntry : histEntry + '\n' + existing;
    }

    // ─── Helpers privados ───────────────────────────────────────────────────

    /**
     * For each field ever touched by an APPLY_COMPLETED or ROLLBACK_COMPLETED log on this
     * request, returns which of those log entries is the latest to have touched it (walking
     * logs oldest-first so the last write in the loop wins). Used to scope rollback to
     * exactly one field at a time: a field's apply entry can only still be rolled back if no
     * later entry (a newer apply, or an earlier rollback) has already superseded it.
     */
    private static Map<String, FieldTouch> getFieldTouchMap(Id requestId) {
        Map<String, FieldTouch> touches = new Map<String, FieldTouch>();
        for (Data_Update_Log__c log : [
            SELECT Id, Action_Type__c, Field_Decisions_JSON__c
            FROM Data_Update_Log__c
            WHERE Request__c = :requestId AND Action_Type__c IN ('APPLY_COMPLETED', 'ROLLBACK_COMPLETED')
            ORDER BY CreatedDate ASC
        ]) {
            if (String.isBlank(log.Field_Decisions_JSON__c)) continue;
            Map<String, Object> decisions = (Map<String, Object>) JSON.deserializeUntyped(log.Field_Decisions_JSON__c);
            for (String fieldApiName : decisions.keySet()) {
                if (fieldApiName.startsWith(NOTE_KEY_PREFIX)) continue;
                FieldTouch touch = new FieldTouch();
                touch.actionType = log.Action_Type__c;
                touch.logId      = log.Id;
                touches.put(fieldApiName, touch);
            }
        }
        return touches;
    }

    // Decision keys that are notes, not fields: "__group" {count, recordName} and
    // "__notApplied" [{labelFr, labelEn, value, reason, ticket}] written by the grouped review.
    @TestVisible private static final String NOTE_KEY_PREFIX = '__';

    /**
     * "__notApplied" note for a one-ticket apply: each submitted value staff didn't check, with
     * SAME_AS_SF when it already matched Salesforce, otherwise UNCHECKED. Null when all were applied.
     */
    @TestVisible private static Map<String, Object> buildNotAppliedNotes(Data_Update_Request__c t,
            DataUpdateFormConfigService.FormConfig config, Map<String, String> proposed,
            List<DataUpdateFormConfigService.FormFieldConfig> fields, Set<String> selected) {
        List<DataUpdateFormConfigService.FormFieldConfig> left = new List<DataUpdateFormConfigService.FormFieldConfig>();
        for (DataUpdateFormConfigService.FormFieldConfig fc : fields) {
            if (proposed.containsKey(fc.fieldApiName) && !selected.contains(fc.fieldApiName)) left.add(fc);
        }
        if (left.isEmpty()) return null;
        SObject current = queryCurrentValues(config, t.Target_Record_Id__c, left);
        List<Object> notApplied = new List<Object>();
        for (DataUpdateFormConfigService.FormFieldConfig fc : left) {
            String value = valueToString(proposed.get(fc.fieldApiName));
            String now = current != null && !DataUpdateFormConfigService.isHistoryOnly(fc)
                ? valueToString(current.get(fc.fieldApiName)) : null;
            Boolean same = now != null && now.trim().equalsIgnoreCase(value.trim());
            notApplied.add(new Map<String, Object>{
                'labelFr' => fc.labelFr,
                'labelEn' => fc.labelEn,
                'value'   => value,
                'reason'  => same ? 'SAME_AS_SF' : 'UNCHECKED'
            });
        }
        return new Map<String, Object>{ '__notApplied' => notApplied };
    }

    private static void readNotes(DataUpdateWrapper.AuditLogEntry entry, Map<String, Object> decisions) {
        if (decisions.get('__group') instanceof Map<String, Object>) {
            Map<String, Object> g = (Map<String, Object>) decisions.get('__group');
            entry.groupOthers     = g.get('count') instanceof Integer ? (Integer) g.get('count') : null;
            entry.groupRecordName = valueToString(g.get('recordName'));
        }
        if (decisions.get('__notApplied') instanceof List<Object>) {
            for (Object o : (List<Object>) decisions.get('__notApplied')) {
                if (!(o instanceof Map<String, Object>)) continue;
                Map<String, Object> m = (Map<String, Object>) o;
                DataUpdateWrapper.AuditNotApplied n = new DataUpdateWrapper.AuditNotApplied();
                n.labelFr = valueToString(m.get('labelFr'));
                n.labelEn = valueToString(m.get('labelEn'));
                n.value   = valueToString(m.get('value'));
                n.reason  = valueToString(m.get('reason'));
                n.ticket  = valueToString(m.get('ticket'));
                entry.notApplied.add(n);
            }
        }
        for (String kind : PREFERENCE_NOTE_BY_KIND.keySet()) {
            if (!(decisions.get(PREFERENCE_NOTE_BY_KIND.get(kind)) instanceof Map<String, Object>)) continue;
            Map<String, Object> m = (Map<String, Object>) decisions.get(PREFERENCE_NOTE_BY_KIND.get(kind));
            DataUpdateWrapper.AuditPreferredChange c = new DataUpdateWrapper.AuditPreferredChange();
            c.kind        = kind;
            c.beforeValue = valueToString(m.get('before'));
            c.afterValue  = valueToString(m.get('after'));
            entry.preferredChanges.add(c);
        }
    }

    private static Boolean isTerminal(String status) {
        return status == 'Applied' || status == 'Ignored' || status == 'Closed';
    }

    @TestVisible private static Integer countProposedFields(String proposedValuesJson) {
        if (String.isBlank(proposedValuesJson)) return 0;
        try {
            Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(proposedValuesJson);
            // Each pasted history line counts as one change, like any other field.
            Integer count = 0;
            for (String key : raw.keySet()) {
                if (DataUpdateFormConfigService.isHistoryTableKey(key)) {
                    TableValue tv = parseTableValue(valueToString(raw.get(key)));
                    count += tv != null ? tv.rows.size() : 0;
                } else {
                    count++;
                }
            }
            return count;
        } catch (Exception e) {
            return 0;
        }
    }

    private static Data_Update_Request__c queryRequest(Id requestId) {
        List<Data_Update_Request__c> requests = [
            SELECT Id, Name, Status__c, Target_Object_API_Name__c, Target_Record_Id__c, CreatedDate,
                   Update_Form_DeveloperName__c, Update_Form_Label__c, Proposed_Values_JSON__c,
                   Requested_Name__c, Requested_Email__c
            FROM Data_Update_Request__c
            WHERE Id = :requestId
            LIMIT 1
        ];
        if (requests.isEmpty()) {
            throw new RequestNotFoundException('Request not found: ' + requestId);
        }
        return requests[0];
    }

    /**
     * A ticket keeps showing every field it arrived with, whatever happened to its form after:
     * - form or catalog field deactivated → real config, inactive fields included;
     * - catalog field deleted → added back from the ticket's own proposed values;
     * - form deleted → whole config rebuilt from the ticket (target object + proposed keys),
     *   without sections or history mapping, since those only lived in the deleted metadata.
     * Fields added from the ticket use Salesforce labels and are never historized.
     */
    private static DataUpdateFormConfigService.FormConfig resolveRequestConfig(Data_Update_Request__c t) {
        DataUpdateFormConfigService.FormConfig config;
        try {
            config = DataUpdateFormConfigService.getFormForReview(t.Update_Form_DeveloperName__c);
        } catch (DataUpdateFormConfigService.FormNotFoundException e) {
            config = buildFallbackConfig(t);
        }
        addProposedFieldsMissingFromConfig(config, t);
        return config;
    }

    @TestVisible private static DataUpdateFormConfigService.FormConfig buildFallbackConfig(Data_Update_Request__c t) {
        Schema.SObjectType targetType = String.isNotBlank(t.Target_Object_API_Name__c)
            ? DataUpdateFormConfigService.globalTypes().get(t.Target_Object_API_Name__c)
            : null;
        if (targetType == null && String.isNotBlank(t.Target_Record_Id__c)) {
            targetType = Id.valueOf(t.Target_Record_Id__c).getSObjectType();
        }
        if (targetType == null) {
            throw new RequestNotFoundException('Cannot resolve target object for request ' + t.Id);
        }
        Schema.DescribeSObjectResult objectDescribe = targetType.getDescribe();

        DataUpdateFormConfigService.FormConfig config = new DataUpdateFormConfigService.FormConfig();
        config.developerName          = t.Update_Form_DeveloperName__c;
        config.label                  = t.Update_Form_Label__c;
        config.targetObjectApiName    = objectDescribe.getName();
        config.recordNameFieldApiName = objectDescribe.fields.getMap().containsKey('name') ? 'Name' : 'Id';
        config.fields                 = new List<DataUpdateFormConfigService.FormFieldConfig>();
        config.isFallback             = true;
        // Forms on the same object share one lock field, so the form being gone doesn't mean
        // the record isn't locked — keep apply/reopen consistent with the live forms.
        Map<String, Schema.SObjectField> fallbackFields = objectDescribe.fields.getMap();
        if (fallbackFields.containsKey('data_update_locked__c')) {
            config.lockFieldApiName = 'Data_Update_Locked__c';
            if (fallbackFields.containsKey('data_update_locked_date__c')) {
                config.lockDateFieldApiName = 'Data_Update_Locked_Date__c';
            }
        }
        return config;
    }

    @TestVisible private static void addProposedFieldsMissingFromConfig(DataUpdateFormConfigService.FormConfig config, Data_Update_Request__c t) {
        if (String.isBlank(t.Proposed_Values_JSON__c)) return;
        Map<String, Object> raw;
        try {
            raw = (Map<String, Object>) JSON.deserializeUntyped(t.Proposed_Values_JSON__c);
        } catch (Exception e) {
            return;
        }

        Integer nextOrder = 0;
        Set<String> knownFields = new Set<String>();
        for (DataUpdateFormConfigService.FormFieldConfig fc : config.fields) {
            knownFields.add(fc.fieldApiName.toLowerCase());
            if (fc.displayOrder != null && fc.displayOrder >= nextOrder) {
                nextOrder = fc.displayOrder + 1;
            }
        }

        Map<String, Schema.SObjectField> fieldMap =
            DataUpdateFormConfigService.globalTypes().get(config.targetObjectApiName).getDescribe().fields.getMap();

        // Keys keep their original casing: parseProposedValues() matches them case-sensitively.
        List<String> keys = new List<String>(raw.keySet());
        keys.sort();
        for (String key : keys) {
            if (knownFields.contains(key.toLowerCase())) continue;
            Schema.SObjectField field = fieldMap.get(key.toLowerCase());
            if (field == null) continue;
            String label = field.getDescribe().getLabel();
            DataUpdateFormConfigService.FormFieldConfig fc = new DataUpdateFormConfigService.FormFieldConfig();
            fc.fieldApiName = key;
            fc.labelFr      = label;
            fc.labelEn      = label;
            fc.displayOrder = nextOrder++;
            fc.historyMode  = 'Replace';
            config.fields.add(fc);
        }
    }

    /**
     * Reuses the log opened at submit time (Action_Type__c = SUBMIT_PENDING) so the
     * before-snapshot reflects the record's state when the requester submitted it.
     * If the request was already Applied once and later Reopened, that log is sealed
     * (APPLY_COMPLETED) — a fresh one is opened here so the new apply gets its own
     * accurate before-state instead of reusing a stale/immutable snapshot.
     */
    private static Id getOrCreatePendingLogId(Data_Update_Request__c request, DataUpdateFormConfigService.FormConfig config) {
        List<Data_Update_Log__c> logs = [
            SELECT Id FROM Data_Update_Log__c
            WHERE Request__c = :request.Id AND Action_Type__c = 'SUBMIT_PENDING'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!logs.isEmpty()) return logs[0].Id;

        SObject currentState = queryCurrentValues(config, request.Target_Record_Id__c, config.fields);
        Data_Update_Log__c newLog = DataUpdateAuditService.createSubmitLog(
            request.Id, config.targetObjectApiName, request.Target_Record_Id__c, currentState
        );
        return newLog.Id;
    }

    private static List<DataUpdateFormConfigService.FormFieldConfig> getAccessibleFields(DataUpdateFormConfigService.FormConfig config, Boolean requireUpdateable) {
        List<DataUpdateFormConfigService.FormFieldConfig> accessible = new List<DataUpdateFormConfigService.FormFieldConfig>();
        Schema.SObjectType targetType = DataUpdateFormConfigService.globalTypes().get(config.targetObjectApiName);
        Map<String, Schema.SObjectField> fieldMap = targetType.getDescribe().fields.getMap();
        for (DataUpdateFormConfigService.FormFieldConfig fc : config.fields) {
            if (DataUpdateFormConfigService.isHistoryOnly(fc)) {
                // Applying a History_Only field inserts a row, so it needs create (not update) access.
                Schema.DescribeFieldResult valueDescribe = DataUpdateFormConfigService.describeValueField(fc, config.targetObjectApiName);
                if (valueDescribe != null && (requireUpdateable ? valueDescribe.isCreateable() : valueDescribe.isAccessible())) {
                    accessible.add(fc);
                }
                continue;
            }
            Schema.SObjectField field = fieldMap.get(fc.fieldApiName.toLowerCase());
            if (field == null) continue;
            Schema.DescribeFieldResult describe = field.getDescribe();
            if (requireUpdateable ? describe.isUpdateable() : describe.isAccessible()) {
                accessible.add(fc);
            }
        }
        return accessible;
    }

    private static SObject queryCurrentValues(DataUpdateFormConfigService.FormConfig config, Id recordId, List<DataUpdateFormConfigService.FormFieldConfig> fields) {
        if (recordId == null) return null;
        Set<String> queryFields = new Set<String>{'Id', config.recordNameFieldApiName};
        for (DataUpdateFormConfigService.FormFieldConfig fc : fields) {
            if (DataUpdateFormConfigService.isHistoryOnly(fc)) continue;
            queryFields.add(fc.fieldApiName);
        }
        if (String.isNotBlank(config.lockFieldApiName) && isFieldAccessible(config.targetObjectApiName, config.lockFieldApiName)) {
            queryFields.add(config.lockFieldApiName);
        }
        String fieldList = String.join(new List<String>(queryFields), ', ');
        String query = 'SELECT ' + fieldList + ' FROM ' + config.targetObjectApiName + ' WHERE Id = :recordId LIMIT 1';
        List<SObject> results = Database.query(query);
        return results.isEmpty() ? null : results[0];
    }

    private static Map<String, String> parseProposedValues(String proposedValuesJson, DataUpdateFormConfigService.FormConfig config) {
        Map<String, String> proposed = new Map<String, String>();
        if (String.isBlank(proposedValuesJson)) return proposed;

        Map<String, Object> raw;
        try {
            raw = (Map<String, Object>) JSON.deserializeUntyped(proposedValuesJson);
        } catch (Exception e) {
            return proposed;
        }

        for (DataUpdateFormConfigService.FormFieldConfig fc : config.fields) {
            if (raw.containsKey(fc.fieldApiName)) {
                Object val = raw.get(fc.fieldApiName);
                proposed.put(fc.fieldApiName, val == null ? '' : String.valueOf(val));
            }
            String dateKey = DataUpdateFormConfigService.historyDateKey(fc);
            if (dateKey != null && raw.get(dateKey) != null) {
                proposed.put(dateKey, String.valueOf(raw.get(dateKey)));
            }
        }
        if (config.tables != null) {
            for (DataUpdateFormConfigService.FormFieldConfig tc : config.tables) {
                if (raw.get(tc.fieldApiName) != null) {
                    proposed.put(tc.fieldApiName, String.valueOf(raw.get(tc.fieldApiName)));
                }
            }
        }
        return proposed;
    }

    // ─── History tables (paste-from-Excel history, églises) ─────────────────

    /** Stored table value: column API names + pasted lines (see DataUpdatePortalController.buildTableValue). */
    @TestVisible private class TableValue {
        List<String> cols = new List<String>();
        List<List<String>> rows = new List<List<String>>();
    }

    @TestVisible private static TableValue parseTableValue(String tableJson) {
        if (String.isBlank(tableJson)) return null;
        try {
            Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(tableJson);
            TableValue tv = new TableValue();
            for (Object c : (List<Object>) raw.get('cols')) tv.cols.add(valueToString(c));
            for (Object r : (List<Object>) raw.get('rows')) {
                List<String> cells = new List<String>();
                for (Object c : (List<Object>) r) cells.add(valueToString(c));
                tv.rows.add(cells);
            }
            return tv.rows.isEmpty() ? null : tv;
        } catch (Exception e) {
            return null;
        }
    }

    @TestVisible private static Map<String, Set<Integer>> parseTableSelections(String tableSelectionsJson) {
        Map<String, Set<Integer>> result = new Map<String, Set<Integer>>();
        if (String.isBlank(tableSelectionsJson)) return result;
        Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(tableSelectionsJson);
        for (String key : raw.keySet()) {
            Set<Integer> idx = new Set<Integer>();
            if (raw.get(key) instanceof List<Object>) {
                for (Object o : (List<Object>) raw.get(key)) {
                    if (o != null) idx.add(Integer.valueOf(String.valueOf(o)));
                }
            }
            result.put(key, idx);
        }
        return result;
    }

    /** Tables the user can see (or, for apply, create AND edit rows of — overwrites are updates). */
    private static List<DataUpdateFormConfigService.FormFieldConfig> getAccessibleTables(DataUpdateFormConfigService.FormConfig config, Boolean forApply) {
        List<DataUpdateFormConfigService.FormFieldConfig> result = new List<DataUpdateFormConfigService.FormFieldConfig>();
        if (config.tables == null) return result;
        for (DataUpdateFormConfigService.FormFieldConfig tc : config.tables) {
            Schema.SObjectType histType = DataUpdateFormConfigService.globalTypes().get(tc.historyTargetObjectApiName);
            if (histType == null) continue;
            Schema.DescribeSObjectResult d = histType.getDescribe();
            if (forApply ? (d.isCreateable() && d.isUpdateable()) : d.isAccessible()) result.add(tc);
        }
        return result;
    }

    /** Existing history rows of this record, by date (yyyy-MM-dd), for the given dates. */
    private static Map<String, SObject> queryRowsByDate(DataUpdateFormConfigService.FormFieldConfig tc, List<String> cols, Set<String> dates, Id recordId) {
        Map<String, SObject> byDate = new Map<String, SObject>();
        if (recordId == null || dates.isEmpty()) return byDate;
        Schema.SObjectType histType = DataUpdateFormConfigService.globalTypes().get(tc.historyTargetObjectApiName);
        Map<String, Schema.SObjectField> histFieldMap = histType.getDescribe().fields.getMap();
        Schema.DescribeFieldResult dateDescribe = histFieldMap.get(tc.historyTargetDateFieldApiName.toLowerCase()).getDescribe();
        Set<String> queryFields = new Set<String>{ 'Id', tc.historyTargetDateFieldApiName };
        for (String col : cols) {
            Schema.SObjectField f = histFieldMap.get(col.toLowerCase());
            if (f != null && f.getDescribe().isAccessible()) queryFields.add(f.getDescribe().getName());
        }
        // Names below are CMDT-configured and validated against Schema.describe(); only the
        // date values are bound.
        String soql = 'SELECT ' + String.join(new List<String>(queryFields), ', ') +
            ' FROM ' + tc.historyTargetObjectApiName +
            ' WHERE ' + tc.historyTargetAccountFieldApiName + ' = :recordId ORDER BY CreatedDate ASC';
        Boolean isDatetime = dateDescribe.getType() == Schema.DisplayType.DATETIME;
        if (!isDatetime) {
            Set<Date> dateValues = new Set<Date>();
            for (String d : dates) dateValues.add(Date.valueOf(d));
            soql = soql.replace(' ORDER BY', ' AND ' + tc.historyTargetDateFieldApiName + ' IN :dateValues ORDER BY');
            for (SObject row : Database.queryWithBinds(soql, new Map<String, Object>{ 'recordId' => recordId, 'dateValues' => dateValues }, AccessLevel.USER_MODE)) {
                Object v = row.get(tc.historyTargetDateFieldApiName);
                if (v != null && !byDate.containsKey(String.valueOf((Date) v))) byDate.put(String.valueOf((Date) v), row);
            }
            return byDate;
        }
        for (SObject row : Database.queryWithBinds(soql, new Map<String, Object>{ 'recordId' => recordId }, AccessLevel.USER_MODE)) {
            Object v = row.get(tc.historyTargetDateFieldApiName);
            if (v == null) continue;
            String key = ((Datetime) v).formatGmt('yyyy-MM-dd');
            if (dates.contains(key) && !byDate.containsKey(key)) byDate.put(key, row);
        }
        return byDate;
    }

    private static Integer dateColumnIndex(DataUpdateFormConfigService.FormFieldConfig tc, TableValue tv) {
        for (Integer i = 0; i < tv.cols.size(); i++) {
            if (tv.cols[i].equalsIgnoreCase(tc.historyTargetDateFieldApiName)) return i;
        }
        return -1;
    }

    private static Set<String> collectDates(TableValue tv, Integer dateIdx) {
        Set<String> dates = new Set<String>();
        if (dateIdx < 0) return dates;
        for (List<String> row : tv.rows) {
            if (dateIdx < row.size() && String.isNotBlank(row[dateIdx])) dates.add(row[dateIdx]);
        }
        return dates;
    }

    @TestVisible private static DataUpdateWrapper.ComparisonTable buildComparisonTable(DataUpdateFormConfigService.FormFieldConfig tc, TableValue tv, Id recordId) {
        DataUpdateWrapper.ComparisonTable ct = new DataUpdateWrapper.ComparisonTable();
        ct.key         = tc.fieldApiName;
        ct.titleFr     = tc.labelFr;
        ct.titleEn     = tc.labelEn;
        ct.objectLabel = historyObjectLabel(tc.historyTargetObjectApiName);

        // Columns as the ticket stored them (the config may have changed since), labelled
        // with the builder's headers when the column is still configured.
        Map<String, DataUpdateWrapper.TableColumnDefinition> configured = new Map<String, DataUpdateWrapper.TableColumnDefinition>();
        for (DataUpdateWrapper.TableColumnDefinition def : DataUpdateFormConfigService.describeTableColumns(tc)) {
            configured.put(def.apiName.toLowerCase(), def);
        }
        Map<String, Schema.SObjectField> histFieldMap = DataUpdateFormConfigService.globalTypes().get(tc.historyTargetObjectApiName).getDescribe().fields.getMap();
        for (String col : tv.cols) {
            DataUpdateWrapper.TableColumnDefinition def = configured.get(col.toLowerCase());
            if (def == null) {
                def = new DataUpdateWrapper.TableColumnDefinition();
                Schema.SObjectField f = histFieldMap.get(col.toLowerCase());
                def.apiName = col;
                def.labelFr = f != null ? f.getDescribe().getLabel() : col;
                def.labelEn = def.labelFr;
                def.kind    = f != null ? DataUpdateFormConfigService.tableColumnKind(f.getDescribe().getType()) : 'Text';
                def.isDate  = col.equalsIgnoreCase(tc.historyTargetDateFieldApiName);
            }
            ct.columns.add(def);
        }

        Integer dateIdx = dateColumnIndex(tc, tv);
        Map<String, SObject> existing = queryRowsByDate(tc, tv.cols, collectDates(tv, dateIdx), recordId);
        for (Integer i = 0; i < tv.rows.size(); i++) {
            DataUpdateWrapper.ComparisonTableRow row = new DataUpdateWrapper.ComparisonTableRow();
            row.index     = i;
            row.cells     = tv.rows[i];
            row.dateValue = dateIdx >= 0 && dateIdx < tv.rows[i].size() ? tv.rows[i][dateIdx] : '';
            SObject match = existing.get(row.dateValue);
            if (match != null) {
                row.isDuplicate = true;
                ct.duplicateCount++;
                for (String col : tv.cols) {
                    Object v;
                    try { v = match.get(col); } catch (Exception e) { v = null; }
                    row.existingCells.add(v instanceof Date ? String.valueOf((Date) v) : valueToString(v));
                }
            }
            ct.rows.add(row);
        }
        return ct;
    }

    /** What applying one table does: rows to insert, rows to overwrite (+ their before values). */
    @TestVisible private class TablePlan {
        String key;
        String objectApiName;
        List<SObject> inserts = new List<SObject>();
        List<SObject> updates = new List<SObject>();
        List<Map<String, Object>> overwritten = new List<Map<String, Object>>();

        Map<String, Object> toDecision() {
            List<String> insertedIds = new List<String>();
            for (SObject row : inserts) insertedIds.add(row.Id);
            String summary = '+' + inserts.size() + (updates.isEmpty() ? '' : ' · ↻ ' + updates.size());
            return new Map<String, Object>{
                'selectedValue'    => summary,
                'diff'             => new Map<String, Object>{ 'before' => '', 'after' => summary },
                'historyObject'    => objectApiName,
                'tableInserted'    => insertedIds,
                'tableOverwritten' => overwritten
            };
        }
    }

    @TestVisible private static Object coerceTableValue(Schema.DisplayType fieldType, String rawValue) {
        if (String.isBlank(rawValue)) return fieldType == Schema.DisplayType.BOOLEAN ? (Object) false : null;
        if (fieldType == Schema.DisplayType.DATETIME && rawValue.length() == 10) {
            return Datetime.newInstanceGmt(Date.valueOf(rawValue), Time.newInstance(12, 0, 0, 0));
        }
        if (fieldType == Schema.DisplayType.INTEGER) return Decimal.valueOf(rawValue).intValue();
        return coerceValue(fieldType, rawValue);
    }

    @TestVisible private static TablePlan planTableApply(DataUpdateFormConfigService.FormFieldConfig tc, TableValue tv, Set<Integer> keep, Id recordId, Id logId) {
        TablePlan plan = new TablePlan();
        plan.key           = tc.fieldApiName;
        plan.objectApiName = tc.historyTargetObjectApiName;
        Schema.SObjectType histType = DataUpdateFormConfigService.globalTypes().get(tc.historyTargetObjectApiName);
        Map<String, Schema.SObjectField> histFieldMap = histType.getDescribe().fields.getMap();

        // Only columns that still exist and that the user may write.
        List<Integer> writableIdx = new List<Integer>();
        List<Schema.DescribeFieldResult> describes = new List<Schema.DescribeFieldResult>();
        for (Integer i = 0; i < tv.cols.size(); i++) {
            Schema.SObjectField f = histFieldMap.get(tv.cols[i].toLowerCase());
            describes.add(f != null ? f.getDescribe() : null);
            if (f != null && f.getDescribe().isCreateable()) writableIdx.add(i);
        }

        Integer dateIdx = dateColumnIndex(tc, tv);
        Map<String, SObject> existing = queryRowsByDate(tc, tv.cols, collectDates(tv, dateIdx), recordId);
        for (Integer r = 0; r < tv.rows.size(); r++) {
            if (!keep.contains(r)) continue;
            List<String> cells = tv.rows[r];
            String dateValue = dateIdx >= 0 && dateIdx < cells.size() ? cells[dateIdx] : '';
            SObject match = existing.get(dateValue);
            SObject row = match != null ? histType.newSObject(match.Id) : histType.newSObject();
            Map<String, Object> before = new Map<String, Object>();
            for (Integer i : writableIdx) {
                Schema.DescribeFieldResult d = describes[i];
                if (match != null && !d.isUpdateable()) continue;
                if (match != null) {
                    Object old;
                    try { old = match.get(d.getName()); } catch (Exception e) { old = null; }
                    before.put(d.getName(), old instanceof Date ? String.valueOf((Date) old) : (old instanceof Datetime ? ((Datetime) old).formatGmt('yyyy-MM-dd HH:mm:ss') : valueToString(old)));
                }
                row.put(d.getName(), coerceTableValue(d.getType(), i < cells.size() ? cells[i] : ''));
            }
            if (match != null) {
                plan.updates.add(row);
                plan.overwritten.add(new Map<String, Object>{ 'id' => match.Id, 'before' => before });
            } else {
                row.put(tc.historyTargetAccountFieldApiName, recordId);
                if (String.isNotBlank(tc.historyTargetLogFieldApiName)) {
                    row.put(tc.historyTargetLogFieldApiName, logId);
                }
                plan.inserts.add(row);
            }
        }
        return plan;
    }

    /**
     * Rollback of a history table: deletes the rows its apply inserted and puts back the
     * values of the rows it overwrote — everything is read from the log's own decision, so it
     * works even if the table was removed from the form since. Relock + reopen like any rollback.
     */
    private static DataUpdateWrapper.ApplyResult rollbackHistoryTable(
        Data_Update_Log__c log, Data_Update_Request__c t, DataUpdateFormConfigService.FormConfig config,
        String key, Map<String, Object> decision
    ) {
        DataUpdateWrapper.ApplyResult result = new DataUpdateWrapper.ApplyResult();
        String objectApiName = decision != null ? valueToString(decision.get('historyObject')) : '';
        Schema.SObjectType histType = String.isBlank(objectApiName) ? null : DataUpdateFormConfigService.globalTypes().get(objectApiName);
        if (histType == null || !histType.getDescribe().isDeletable() || !histType.getDescribe().isUpdateable()) {
            result.success      = false;
            result.errorMessage = 'GENERIC_ERROR';
            return result;
        }
        Map<String, Schema.SObjectField> histFieldMap = histType.getDescribe().fields.getMap();

        Set<Id> insertedIds = new Set<Id>();
        if (decision.get('tableInserted') instanceof List<Object>) {
            for (Object o : (List<Object>) decision.get('tableInserted')) {
                if (o != null) insertedIds.add(Id.valueOf(String.valueOf(o)));
            }
        }
        List<SObject> restores = new List<SObject>();
        if (decision.get('tableOverwritten') instanceof List<Object>) {
            for (Object o : (List<Object>) decision.get('tableOverwritten')) {
                Map<String, Object> entry = (Map<String, Object>) o;
                SObject row = histType.newSObject(Id.valueOf(String.valueOf(entry.get('id'))));
                Map<String, Object> before = (Map<String, Object>) entry.get('before');
                for (String fieldName : before.keySet()) {
                    Schema.SObjectField f = histFieldMap.get(fieldName.toLowerCase());
                    if (f == null || !f.getDescribe().isUpdateable()) continue;
                    String raw = valueToString(before.get(fieldName));
                    Schema.DisplayType type = f.getDescribe().getType();
                    row.put(fieldName, type == Schema.DisplayType.DATETIME && String.isNotBlank(raw)
                        ? (Object) Datetime.valueOfGmt(raw)
                        : coerceTableValue(type, raw));
                }
                restores.add(row);
            }
        }

        Schema.SObjectType targetType = DataUpdateFormConfigService.globalTypes().get(config.targetObjectApiName);
        Map<String, Schema.SObjectField> fieldMap = targetType.getDescribe().fields.getMap();
        SObject lockUpdate = targetType.newSObject(log.Target_Record_Id__c);
        Boolean hasLockUpdate = false;
        if (String.isNotBlank(config.lockFieldApiName) && isFieldUpdateable(fieldMap, config.lockFieldApiName)) {
            lockUpdate.put(config.lockFieldApiName, true);
            hasLockUpdate = true;
            if (String.isNotBlank(config.lockDateFieldApiName) && isFieldUpdateable(fieldMap, config.lockDateFieldApiName)) {
                lockUpdate.put(config.lockDateFieldApiName, Datetime.now());
            }
        }

        SObject targetRecordBefore = queryCurrentValues(config, log.Target_Record_Id__c, config.fields);
        String appliedSummary = decision.get('diff') instanceof Map<String, Object>
            ? valueToString(((Map<String, Object>) decision.get('diff')).get('after')) : '';

        Savepoint sp = Database.setSavepoint();
        try {
            if (!insertedIds.isEmpty()) {
                List<SObject> rows = Database.query('SELECT Id FROM ' + objectApiName + ' WHERE Id IN :insertedIds');
                if (!rows.isEmpty()) delete rows;
            }
            if (!restores.isEmpty()) update restores;
            if (hasLockUpdate) update lockUpdate;
            if (TEST_FORCE_ROLLBACK_DML_ERROR) throw new DmlException('TEST_FORCE_ROLLBACK_DML_ERROR');

            SObject targetRecordAfter = queryCurrentValues(config, log.Target_Record_Id__c, config.fields);
            DataUpdateAuditService.recordRollback(
                log.Request__c, log.Target_Object_API_Name__c, log.Target_Record_Id__c,
                targetRecordBefore, targetRecordAfter, new Map<String, Object>(),
                new Map<String, Object>{
                    key => new Map<String, Object>{
                        'selectedValue' => null,
                        'diff'          => new Map<String, Object>{ 'before' => appliedSummary, 'after' => '' }
                    }
                }
            );

            Data_Update_Request__c requestForHist = [SELECT Notes__c FROM Data_Update_Request__c WHERE Id = :t.Id LIMIT 1];
            update new Data_Update_Request__c(
                Id               = t.Id,
                Status__c        = 'Reopened',
                Final_Action__c  = null,
                Closed_Reason__c = null,
                Notes__c         = prependHist(
                    requestForHist.Notes__c,
                    buildHistEntry('Reopened', '', 'Rollback: ' + insertedIds.size() + ' history row(s) removed, ' + restores.size() + ' restored')
                )
            );
        } catch (Exception rollbackEx) {
            Database.rollback(sp);
            throw rollbackEx;
        }

        result.success           = true;
        result.updatedFieldCount = insertedIds.size() + restores.size();
        return result;
    }

    /**
     * Latest row (by date field, then creation) of each History_Only field's history object for
     * this target record — what the review panel shows as the "current" value. Mapping names
     * are CMDT-configured and validated against Schema.describe(), so the dynamic SOQL is safe.
     */
    private static Map<String, HistoryPoint> queryLatestHistoryPoints(List<DataUpdateFormConfigService.FormFieldConfig> fields, Id recordId) {
        Map<String, HistoryPoint> points = new Map<String, HistoryPoint>();
        if (recordId == null) return points;
        for (DataUpdateFormConfigService.FormFieldConfig fc : fields) {
            if (!DataUpdateFormConfigService.isHistoryOnly(fc)) continue;
            Boolean hasDate = String.isNotBlank(fc.historyTargetDateFieldApiName);
            String query = 'SELECT ' + fc.historyTargetValueFieldApiName + (hasDate ? ', ' + fc.historyTargetDateFieldApiName : '') +
                ' FROM ' + fc.historyTargetObjectApiName +
                ' WHERE ' + fc.historyTargetAccountFieldApiName + ' = :recordId' +
                ' ORDER BY ' + (hasDate ? fc.historyTargetDateFieldApiName + ' DESC NULLS LAST, ' : '') + 'CreatedDate DESC LIMIT 1';
            List<SObject> rows = Database.query(query);
            if (rows.isEmpty()) continue;
            HistoryPoint point = new HistoryPoint();
            point.value     = valueToString(rows[0].get(fc.historyTargetValueFieldApiName));
            point.dateValue = hasDate ? valueToString(rows[0].get(fc.historyTargetDateFieldApiName)).left(10) : '';
            points.put(fc.fieldApiName, point);
        }
        return points;
    }

    /**
     * Latest row of each Historize field's history object for this target record — shown in the
     * review panel as a reference under the new row. Read-only preview: a history object the
     * reviewer can't read, or a mapping without an account lookup, just shows no previous row
     * instead of failing the whole ticket. Mapping names are CMDT-configured and validated
     * against Schema.describe(), so the dynamic SOQL is safe.
     */
    @TestVisible private static Map<String, HistoryPoint> queryLatestHistorizePoints(List<DataUpdateFormConfigService.FormFieldConfig> fields, Id recordId) {
        Map<String, HistoryPoint> points = new Map<String, HistoryPoint>();
        if (recordId == null) return points;
        for (DataUpdateFormConfigService.FormFieldConfig fc : fields) {
            if (fc.historyMode != 'Historize') continue;
            if (String.isBlank(fc.historyTargetObjectApiName) || String.isBlank(fc.historyTargetValueFieldApiName)
                    || String.isBlank(fc.historyTargetAccountFieldApiName)) continue;
            try {
                Schema.SObjectType histType = DataUpdateFormConfigService.globalTypes().get(fc.historyTargetObjectApiName);
                if (histType == null || !histType.getDescribe().isAccessible()) continue;
                Boolean hasDate = String.isNotBlank(fc.historyTargetDateFieldApiName);
                String query = 'SELECT ' + fc.historyTargetValueFieldApiName + (hasDate ? ', ' + fc.historyTargetDateFieldApiName : '') +
                    ' FROM ' + fc.historyTargetObjectApiName +
                    ' WHERE ' + fc.historyTargetAccountFieldApiName + ' = :recordId' +
                    ' ORDER BY ' + (hasDate ? fc.historyTargetDateFieldApiName + ' DESC NULLS LAST, ' : '') + 'CreatedDate DESC LIMIT 1';
                List<SObject> rows = Database.query(query);
                if (rows.isEmpty()) continue;
                HistoryPoint point = new HistoryPoint();
                point.value     = valueToString(rows[0].get(fc.historyTargetValueFieldApiName));
                point.dateValue = hasDate ? valueToString(rows[0].get(fc.historyTargetDateFieldApiName)).left(10) : '';
                points.put(fc.fieldApiName, point);
            } catch (Exception e) {
                // Preview only — no previous row shown.
            }
        }
        return points;
    }

    @TestVisible private static String historyObjectLabel(String objectApiName) {
        Schema.SObjectType histType = String.isBlank(objectApiName) ? null : DataUpdateFormConfigService.globalTypes().get(objectApiName);
        return histType != null ? histType.getDescribe().getLabel() : objectApiName;
    }

    /**
     * Date the new Historize row will carry, mirroring buildDynamicHistoryRow(): the submitted
     * value of the paired date field when the form sent one, else today.
     */
    @TestVisible private static String resolveHistorizePreviewDate(DataUpdateFormConfigService.FormFieldConfig fc, Map<String, String> proposed) {
        if (String.isNotBlank(fc.historyDateSourceFieldApiName)) {
            String typed = proposed.get(fc.historyDateSourceFieldApiName);
            if (String.isNotBlank(typed)) return typed.trim().left(10);
        }
        return String.valueOf(Date.today());
    }

    /** Date a History_Only row gets: the date the visitor typed, else the day the form was submitted. */
    @TestVisible private static Date resolveHistoryDate(DataUpdateFormConfigService.FormFieldConfig fc, Map<String, String> proposed, Data_Update_Request__c t) {
        String dateKey = DataUpdateFormConfigService.historyDateKey(fc);
        String typed = dateKey != null ? proposed.get(dateKey) : null;
        if (String.isNotBlank(typed)) {
            try {
                return Date.valueOf(typed.trim());
            } catch (Exception e) {
                // Malformed — fall back to the submission date.
            }
        }
        return t.CreatedDate != null ? t.CreatedDate.date() : Date.today();
    }

    @TestVisible private static SObject buildHistoryOnlyRow(
        DataUpdateFormConfigService.FormFieldConfig fc, Data_Update_Request__c t, Map<String, String> proposed, Id logId
    ) {
        Schema.SObjectType histType = DataUpdateFormConfigService.globalTypes().get(fc.historyTargetObjectApiName);
        Map<String, Schema.SObjectField> histFieldMap = histType.getDescribe().fields.getMap();
        SObject row = histType.newSObject();

        Schema.SObjectField valueField = histFieldMap.get(fc.historyTargetValueFieldApiName.toLowerCase());
        row.put(fc.historyTargetValueFieldApiName,
            coerceValue(valueField.getDescribe().getType(), proposed.get(fc.fieldApiName)));

        if (String.isNotBlank(fc.historyTargetDateFieldApiName)) {
            Schema.DisplayType destType = histFieldMap.get(fc.historyTargetDateFieldApiName.toLowerCase()).getDescribe().getType();
            Date rowDate = resolveHistoryDate(fc, proposed, t);
            row.put(fc.historyTargetDateFieldApiName,
                coerceDateValue(rowDate, Schema.DisplayType.DATE, destType));
        }
        row.put(fc.historyTargetAccountFieldApiName, t.Target_Record_Id__c);
        if (String.isNotBlank(fc.historyTargetLogFieldApiName)) {
            row.put(fc.historyTargetLogFieldApiName, logId);
        }
        return row;
    }

    /**
     * Builds one dynamic history row for a field applied with History_Mode__c = 'Historize'.
     * The target object/fields are whatever the admin mapped in Settings — already
     * fail-closed validated against Schema.describe() by
     * DataUpdateFormConfigService.validateHistoryMapping() when the form was loaded, so no
     * defensive null-checks are needed here.
     */
    @TestVisible private static SObject buildDynamicHistoryRow(
        DataUpdateFormConfigService.FormFieldConfig fc, Id targetRecordId, Object coercedValue, SObject targetRecord, Id requestId, Id logId
    ) {
        return buildDynamicHistoryRow(fc, targetRecordId, coercedValue, targetRecord, requestId, logId, null);
    }

    // proposed: this ticket's submitted values. When the paired date field is not applied with
    // this ticket (grouped review: the same date applied by another ticket, or unchecked), the
    // row still gets the date the visitor sent with this value — same as the preview shows.
    @TestVisible private static SObject buildDynamicHistoryRow(
        DataUpdateFormConfigService.FormFieldConfig fc, Id targetRecordId, Object coercedValue, SObject targetRecord, Id requestId, Id logId,
        Map<String, String> proposed
    ) {
        Schema.SObjectType histType = DataUpdateFormConfigService.globalTypes().get(fc.historyTargetObjectApiName);
        Map<String, Schema.SObjectField> histFieldMap = histType.getDescribe().fields.getMap();
        SObject row = histType.newSObject();

        Schema.SObjectField valueField = histFieldMap.get(fc.historyTargetValueFieldApiName.toLowerCase());
        row.put(fc.historyTargetValueFieldApiName,
            coerceValue(valueField.getDescribe().getType(), valueToString(coercedValue)));

        if (String.isNotBlank(fc.historyTargetDateFieldApiName)) {
            Schema.SObjectField dateField = histFieldMap.get(fc.historyTargetDateFieldApiName.toLowerCase());
            Schema.DisplayType destType = dateField.getDescribe().getType();

            // Prefer the visitor-submitted date on a paired sibling field (e.g.
            // Eglise_Attendance_Date__c) over auto-generating today's date — targetRecord was
            // constructed via newSObject(id), so .get() safely returns null for any field never
            // .put() onto it (unlike a SOQL-queried SObject, which would throw), rather than
            // requiring the paired field to have been part of this apply.
            Object dateSourceValue = null;
            Schema.DisplayType dateSourceType = null;
            if (String.isNotBlank(fc.historyDateSourceFieldApiName)) {
                Schema.SObjectField sourceField = targetRecord.getSObjectType().getDescribe().fields.getMap()
                    .get(fc.historyDateSourceFieldApiName.toLowerCase());
                dateSourceType = sourceField.getDescribe().getType();
                dateSourceValue = targetRecord.get(fc.historyDateSourceFieldApiName);
                String typed = proposed != null ? proposed.get(fc.historyDateSourceFieldApiName) : null;
                if (dateSourceValue == null && String.isNotBlank(typed)) {
                    try {
                        dateSourceValue = coerceValue(dateSourceType, typed);
                    } catch (Exception e) {
                        dateSourceValue = null; // malformed → today, as before
                    }
                }
            }

            row.put(fc.historyTargetDateFieldApiName,
                dateSourceValue != null
                    ? coerceDateValue(dateSourceValue, dateSourceType, destType)
                    : (destType == Schema.DisplayType.DATETIME ? (Object) DateTime.now() : (Object) Date.today()));
        }
        if (String.isNotBlank(fc.historyTargetAccountFieldApiName)) {
            row.put(fc.historyTargetAccountFieldApiName, targetRecordId);
        }
        if (String.isNotBlank(fc.historyTargetLogFieldApiName)) {
            row.put(fc.historyTargetLogFieldApiName, logId);
        }
        return row;
    }

    // Converts a source Date/DateTime value to whichever shape the destination history field
    // expects. Branches on the source field's own Schema.DisplayType rather than `instanceof` —
    // SObject.get(String) on a Date field returns a value that satisfies BOTH
    // `instanceof DateTime` and `instanceof Date` in Apex, so an instanceof-first check on
    // DateTime wrongly takes the DateTime branch and calls .date() (a local-timezone
    // conversion), silently shifting the date back a day in any UTC-negative org. Casting
    // straight to the type the schema says it is avoids that entirely.
    @TestVisible private static Object coerceDateValue(Object sourceValue, Schema.DisplayType sourceType, Schema.DisplayType destType) {
        if (sourceType == Schema.DisplayType.DATETIME) {
            DateTime dtVal = (DateTime) sourceValue;
            return destType == Schema.DisplayType.DATETIME ? (Object) dtVal : (Object) dtVal.date();
        }
        Date dVal = (Date) sourceValue;
        return destType == Schema.DisplayType.DATETIME ? (Object) DateTime.newInstance(dVal, Time.newInstance(0, 0, 0, 0)) : (Object) dVal;
    }

    // Returns true when history row cleanup was SKIPPED (no Log lookup configured on the
    // target object, so there's no reliable way to find which row to delete) — surfaced to
    // the UI via ApplyResult.historyCleanupSkipped so staff know the base field rolled back
    // but its history row is now orphaned. No SOQL injection risk: both interpolated values
    // are CMDT-configured API names already validated against Schema.describe() in
    // DataUpdateFormConfigService.validateHistoryMapping().
    @TestVisible private static Boolean deleteHistoryRowsForRollback(DataUpdateFormConfigService.FormFieldConfig fc, Id logId) {
        if (String.isBlank(fc.historyTargetLogFieldApiName)) {
            return true;
        }
        List<SObject> rows = Database.query(
            'SELECT Id FROM ' + fc.historyTargetObjectApiName +
            ' WHERE ' + fc.historyTargetLogFieldApiName + ' = :logId LIMIT 200'
        );
        if (!rows.isEmpty()) {
            delete rows;
        }
        return false;
    }

    @TestVisible private static Object coerceValue(Schema.DisplayType fieldType, String rawValue) {
        if (String.isBlank(rawValue)) return null;
        switch on fieldType {
            when DATE {
                return Date.valueOf(rawValue);
            }
            when DATETIME {
                return DateTime.valueOf(rawValue);
            }
            when DOUBLE, CURRENCY, PERCENT {
                return Decimal.valueOf(rawValue);
            }
            when INTEGER {
                return Integer.valueOf(rawValue);
            }
            when BOOLEAN {
                return Boolean.valueOf(rawValue);
            }
            when else {
                return rawValue;
            }
        }
    }

    private static String valueToString(Object val) {
        return val == null ? '' : String.valueOf(val);
    }
}
