/**
 * DataUpdatePortalController.cls
 * Public Guest-facing controller for the external data-update portal.
 * Runs in system mode (no Guest FLS exists to rely on) — the only real control
 * is live re-validation of every CMDT-declared object/field against
 * Schema.describe() on every call (see DataUpdateFormConfigService). Field
 * names that reach dynamic SOQL always come from the validated catalog, never
 * from a raw client JSON key. proposedValuesJson is a single flat String
 * parameter (not a nested Apex type) to work around the Guest/LWR Aura bridge
 * deserialization bug confirmed on the original Account-only portal.
 *
 * Adapted from DataUpdatePortalController.cls: inserts Data_Update_Request__c
 * instead of Case (no RecordType/AccountId — those are Case-only concepts), and
 * immediately opens the audit trail via DataUpdateAuditService.createSubmitLog()
 * right after insert, capturing the target record's before-state.
 */
public without sharing class DataUpdatePortalController {

    @TestVisible private static Boolean TEST_FORCE_ERROR = false;
    // Fails the submit after the request is inserted, to prove the savepoint undoes it.
    @TestVisible private static Boolean TEST_FORCE_LOCK_ERROR = false;

    /** A pasted history table that doesn't pass server-side validation (the portal checks first). */
    public class TableValidationException extends Exception {}

    // Not final so a test can lower it: a real over-the-limit submit needs >128 KB of input.
    @TestVisible private static Integer PROPOSED_VALUES_MAX_LENGTH = 131072;

    @AuraEnabled(cacheable=true)
    public static String getRecaptchaSiteKey() {
        return DataUpdateReCaptchaService.getSiteKey();
    }

    @AuraEnabled
    public static DataUpdateWrapper.FormDefinition getFormDefinition(String formName) {
        DataUpdateWrapper.FormDefinition result = new DataUpdateWrapper.FormDefinition();
        try {
            if (TEST_FORCE_ERROR) throw new AuraHandledException('TEST_FORCE_ERROR');

            DataUpdateFormConfigService.FormConfig config = DataUpdateFormConfigService.getForm(formName);
            result.requiresIdentityField2 = String.isNotBlank(config.identityField2ApiName);
            result.identityField2ApiName  = config.identityField2ApiName;
            result.portalTexts            = config.portalTexts;
            for (DataUpdateFormConfigService.FormFieldConfig fc : config.fields) {
                DataUpdateWrapper.FieldDefinition fd = new DataUpdateWrapper.FieldDefinition();
                fd.fieldApiName   = fc.fieldApiName;
                fd.labelFr        = fc.labelFr;
                fd.labelEn        = fc.labelEn;
                fd.displayOrder   = fc.displayOrder;
                fd.sectionLabelFr = fc.sectionLabelFr;
                fd.sectionLabelEn = fc.sectionLabelEn;
                fd.inputType      = fc.inputType;
                fd.isRequired     = fc.isRequired;
                fd.helpFr         = fc.helpFr;
                fd.helpEn         = fc.helpEn;
                fd.sameRowAsPrevious = fc.sameRowAsPrevious;
                fd.isHistoryOnly  = DataUpdateFormConfigService.isHistoryOnly(fc);
                fd.historyDateKey = DataUpdateFormConfigService.historyDateKey(fc);
                fd.isReadOnly     = fc.isReadOnly == true;
                if ('Picklist'.equals(fc.inputType)) {
                    fd.picklistOptions = getPicklistOptions(fc, config.targetObjectApiName);
                }
                result.fields.add(fd);
            }
            for (DataUpdateFormConfigService.FormFieldConfig tc : config.tables) {
                DataUpdateWrapper.TableDefinition td = new DataUpdateWrapper.TableDefinition();
                td.key     = tc.fieldApiName;
                td.titleFr = tc.labelFr;
                td.titleEn = tc.labelEn;
                td.helpFr  = tc.helpFr;
                td.helpEn  = tc.helpEn;
                td.maxRows = DataUpdateFormConfigService.HISTORY_TABLE_MAX_ROWS;
                td.inputMode = tc.tableInputMode;
                td.columns = DataUpdateFormConfigService.describeTableColumns(tc);
                td.displayOrder   = tc.displayOrder;
                td.sectionLabelFr = tc.sectionLabelFr;
                td.sectionLabelEn = tc.sectionLabelEn;
                result.tables.add(td);
            }
            result.success = true;
        } catch (Exception e) {
            result.success      = false;
            result.errorMessage = 'GENERIC_ERROR';
        }
        return result;
    }

    @AuraEnabled
    public static DataUpdateWrapper.LookupResult lookupRecord(String formName, String identity1, String identity2, String recaptchaToken) {
        DataUpdateWrapper.LookupResult result = new DataUpdateWrapper.LookupResult();
        try {
            if (TEST_FORCE_ERROR) throw new AuraHandledException('TEST_FORCE_ERROR');

            if (!DataUpdateReCaptchaService.verifyToken(recaptchaToken)) {
                result.success      = false;
                result.errorMessage = 'INVALID_CAPTCHA';
                return result;
            }

            DataUpdateFormConfigService.FormConfig config = DataUpdateFormConfigService.getForm(formName);
            SObject record = findMatchingRecord(config, identity1, identity2);
            if (record == null) {
                result.success      = false;
                result.errorMessage = 'NOT_FOUND';
                return result;
            }

            Id recordId = (Id) record.get('Id');
            if (isLocked(config, record)) {
                result.success      = false;
                result.isLocked     = true;
                result.errorMessage = 'LOCKED';
                return result;
            }
            if (!config.allowDuplicateOpenRequests && hasOpenRequest(config, recordId)) {
                result.success        = false;
                result.alreadyPending = true;
                result.errorMessage   = 'ALREADY_PENDING';
                return result;
            }

            result.success     = true;
            result.recordId    = String.valueOf(recordId);
            result.recordName  = String.valueOf(record.get(config.recordNameFieldApiName));
            result.lookupPass  = DataUpdateReCaptchaService.generateLookupPass(formName, identity1, identity2);
            result.readOnlyValuesJson = buildReadOnlyValues(config, record);
        } catch (Exception e) {
            result.success      = false;
            result.errorMessage = 'GENERIC_ERROR';
        }
        return result;
    }

    @AuraEnabled
    public static DataUpdateWrapper.SubmitResult submitUpdate(String formName, String identity1, String identity2, String proposedValuesJson, String lookupPass) {
        DataUpdateWrapper.SubmitResult result = new DataUpdateWrapper.SubmitResult();
        try {
            if (TEST_FORCE_ERROR) throw new AuraHandledException('TEST_FORCE_ERROR');

            // Checked before any query runs: without this, submitUpdate() would
            // itself be a captcha-free identity-guessing oracle via its
            // NOT_FOUND vs. match behavior, even with lookupRecord() protected.
            if (!DataUpdateReCaptchaService.validateLookupPass(lookupPass, formName, identity1, identity2)) {
                result.success      = false;
                result.errorMessage = 'INVALID_CAPTCHA';
                return result;
            }

            DataUpdateFormConfigService.FormConfig config = DataUpdateFormConfigService.getForm(formName);
            SObject record = findMatchingRecord(config, identity1, identity2);
            if (record == null) {
                result.success      = false;
                result.errorMessage = 'NOT_FOUND';
                return result;
            }

            Id recordId = (Id) record.get('Id');
            // Row lock on the record: a double click or two open tabs now run one after the
            // other, and the second submit sees the first one's lock / open request instead of
            // creating a duplicate ticket.
            String lockQuery = 'SELECT Id'
                + (String.isNotBlank(config.lockFieldApiName) ? ', ' + config.lockFieldApiName : '')
                + ' FROM ' + config.targetObjectApiName + ' WHERE Id = :recordId FOR UPDATE';
            SObject lockedRecord = Database.queryWithBinds(
                lockQuery, new Map<String, Object>{ 'recordId' => recordId }, AccessLevel.SYSTEM_MODE)[0];
            if (isLocked(config, lockedRecord)) {
                result.success      = false;
                result.isLocked     = true;
                result.errorMessage = 'LOCKED';
                return result;
            }
            if (!config.allowDuplicateOpenRequests && hasOpenRequest(config, recordId)) {
                result.success        = false;
                result.alreadyPending = true;
                result.errorMessage   = 'ALREADY_PENDING';
                return result;
            }

            Map<String, String> proposedValues;
            try {
                proposedValues = buildProposedValues(proposedValuesJson, config);
            } catch (TableValidationException tableEx) {
                result.success      = false;
                result.errorMessage = 'INVALID_TABLE';
                return result;
            }
            // Server-side too: the portal formats while typing, but the stored value must not
            // depend on the client.
            DataUpdateFormConfigService.formatPostalCodes(proposedValues, record);
            String invalidPostalField = DataUpdateFormConfigService.findInvalidPostalCodeField(proposedValues, record);
            if (invalidPostalField != null) {
                result.success             = false;
                result.errorMessage        = 'INVALID_POSTAL_CODE';
                result.invalidFieldApiName = invalidPostalField;
                return result;
            }
            if (proposedValues.isEmpty()) {
                result.success      = false;
                result.errorMessage = 'NO_CHANGES';
                return result;
            }
            // Type / length check against the real field — a bad value is refused here instead
            // of putting the ticket in Error when staff applies it.
            String requestedEmail;
            String requestedPhone;
            for (DataUpdateFormConfigService.FormFieldConfig fc : config.fields) {
                if (!proposedValues.containsKey(fc.fieldApiName)) continue;
                Schema.DescribeFieldResult valueField = DataUpdateFormConfigService.describeValueField(fc, config.targetObjectApiName);
                // First email / phone sent fills the ticket's contact columns (list search, header).
                if (valueField != null && requestedEmail == null && valueField.getType() == Schema.DisplayType.EMAIL) {
                    requestedEmail = proposedValues.get(fc.fieldApiName);
                }
                if (valueField != null && requestedPhone == null && valueField.getType() == Schema.DisplayType.PHONE) {
                    requestedPhone = proposedValues.get(fc.fieldApiName);
                }
                proposedValues.put(fc.fieldApiName,
                    DataUpdateFormConfigService.normalizeEmail(valueField, proposedValues.get(fc.fieldApiName)));
                String invalidCode = DataUpdateFormConfigService.validateFieldValue(
                    valueField, proposedValues.get(fc.fieldApiName));
                if (invalidCode != null) {
                    result.success             = false;
                    result.errorMessage        = 'INVALID_VALUE';
                    result.invalidFieldApiName = fc.fieldApiName;
                    return result;
                }
            }

            String proposedJson = JSON.serialize(proposedValues);
            if (proposedJson.length() > PROPOSED_VALUES_MAX_LENGTH) {
                result.success      = false;
                result.errorMessage = 'INVALID_TABLE';
                return result;
            }

            Data_Update_Request__c t = new Data_Update_Request__c();
            t.Target_Object_API_Name__c    = config.targetObjectApiName;
            t.Target_Record_Id__c          = recordId;
            t.Update_Form_DeveloperName__c = config.developerName;
            t.Update_Form_Label__c         = config.label;
            t.Proposed_Values_JSON__c      = proposedJson;
            t.Subject__c                   = buildSubject(config, record);
            Object recordName              = record.get(config.recordNameFieldApiName);
            t.Requested_Name__c            = recordName == null ? null : String.valueOf(recordName).left(255);
            t.Requested_Email__c           = String.isBlank(requestedEmail) ? null : requestedEmail.left(255);
            t.Requested_Phone__c           = String.isBlank(requestedPhone) ? null : requestedPhone.left(40);
            t.Status__c                    = 'New';
            if (config.requestOwnerQueueId != null) t.OwnerId = config.requestOwnerQueueId;

            // All-or-nothing: if the lock update fails, the request and its log roll back too —
            // otherwise the visitor sees an error yet gets ALREADY_PENDING on retry.
            Savepoint sp = Database.setSavepoint();
            try {
                insert t;

                DataUpdateAuditService.createSubmitLog(t.Id, config.targetObjectApiName, recordId, record);

                if (TEST_FORCE_LOCK_ERROR) throw new DmlException('TEST_FORCE_LOCK_ERROR');
                if (String.isNotBlank(config.lockFieldApiName)) {
                    Schema.SObjectType targetType = DataUpdateFormConfigService.globalTypes().get(config.targetObjectApiName);
                    SObject lockUpdate = targetType.newSObject(recordId);
                    lockUpdate.put(config.lockFieldApiName, true);
                    if (String.isNotBlank(config.lockDateFieldApiName)) {
                        lockUpdate.put(config.lockDateFieldApiName, Datetime.now());
                    }
                    update lockUpdate;
                }
            } catch (Exception submitEx) {
                Database.rollback(sp);
                throw submitEx;
            }

            result.success  = true;
            result.requestId = t.Id;
        } catch (Exception e) {
            result.success      = false;
            result.errorMessage = 'GENERIC_ERROR';
        }
        return result;
    }

    // ─── Helpers privados ───────────────────────────────────────────────────

    @TestVisible private static SObject findMatchingRecord(DataUpdateFormConfigService.FormConfig config, String identity1, String identity2) {
        Set<String> queryFields = new Set<String>{'Id', config.recordNameFieldApiName, config.identityField1ApiName};
        if (String.isNotBlank(config.identityField2ApiName)) {
            queryFields.add(config.identityField2ApiName);
        }
        if (String.isNotBlank(config.lockFieldApiName)) {
            queryFields.add(config.lockFieldApiName);
        }
        for (DataUpdateFormConfigService.FormFieldConfig fc : config.fields) {
            // History_Only keys are virtual (HistoryObject.ValueField) — nothing to read on the record.
            if (DataUpdateFormConfigService.isHistoryOnly(fc)) continue;
            queryFields.add(fc.fieldApiName);
        }
        String fieldList = String.join(new List<String>(queryFields), ', ');

        Map<String, Object> binds = new Map<String, Object>();
        String whereClause = '';
        if (String.isNotBlank(config.targetBaseFilterField)) {
            if (config.targetBaseFilterIsBoolean) {
                String boolLiteral = 'true'.equalsIgnoreCase(config.targetBaseFilterValue) ? 'true' : 'false';
                whereClause = config.targetBaseFilterField + ' = ' + boolLiteral;
            } else {
                whereClause = config.targetBaseFilterField + ' IN :baseFilterValues';
                binds.put('baseFilterValues', DataUpdateFormConfigService.splitFilterValues(config.targetBaseFilterValue));
            }
        }

        Boolean identity1Exact = 'Exact'.equals(config.identityField1Comparison);
        if (identity1Exact) {
            String identityClause = config.identityField1ApiName + ' = :identity1Value';
            binds.put('identity1Value', identity1);
            whereClause = String.isBlank(whereClause) ? identityClause : whereClause + ' AND ' + identityClause;
        }

        String query = 'SELECT ' + fieldList + ' FROM ' + config.targetObjectApiName +
            (String.isNotBlank(whereClause) ? ' WHERE ' + whereClause : '') +
            ' LIMIT ' + (identity1Exact ? '1' : '200');

        List<SObject> results = Database.queryWithBinds(query, binds, AccessLevel.SYSTEM_MODE);

        for (SObject candidate : results) {
            if (!identity1Exact && !DataUpdateFormConfigService.matchesIdentity(candidate.get(config.identityField1ApiName), identity1, config.identityField1Comparison)) {
                continue;
            }
            if (String.isNotBlank(config.identityField2ApiName) &&
                !DataUpdateFormConfigService.matchesIdentity(candidate.get(config.identityField2ApiName), identity2, config.identityField2Comparison)) {
                continue;
            }
            return candidate;
        }
        return null;
    }

    private static Boolean hasOpenRequest(DataUpdateFormConfigService.FormConfig config, Id recordId) {
        List<Data_Update_Request__c> openRequests = [
            SELECT Id FROM Data_Update_Request__c
            WHERE Target_Object_API_Name__c = :config.targetObjectApiName
            AND Target_Record_Id__c = :recordId
            AND Update_Form_DeveloperName__c = :config.developerName
            AND Status__c NOT IN ('Applied', 'Ignored', 'Closed')
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return !openRequests.isEmpty();
    }

    private static Boolean isLocked(DataUpdateFormConfigService.FormConfig config, SObject record) {
        if (String.isBlank(config.lockFieldApiName)) return false;
        return record.get(config.lockFieldApiName) == true;
    }

    @TestVisible private static Map<String, String> buildProposedValues(String proposedValuesJson, DataUpdateFormConfigService.FormConfig config) {
        Map<String, String> proposed = new Map<String, String>();
        if (String.isBlank(proposedValuesJson)) return proposed;

        Map<String, Object> raw;
        try {
            raw = (Map<String, Object>) JSON.deserializeUntyped(proposedValuesJson);
        } catch (Exception e) {
            return proposed;
        }

        for (DataUpdateFormConfigService.FormFieldConfig fc : config.fields) {
            // "Only see" questions are shown, never changed by the visitor.
            if (fc.isReadOnly == true) continue;
            if (raw.containsKey(fc.fieldApiName)) {
                Object val = raw.get(fc.fieldApiName);
                String strVal = val == null ? '' : String.valueOf(val);
                // Picklist is the one input type where the client sends back an API value that
                // must match a real, currently-active option — everything else is free text and
                // has no such constraint to enforce server-side.
                if ('Picklist'.equals(fc.inputType) && String.isNotBlank(strVal)
                    && !isValidPicklistValue(fc, config.targetObjectApiName, strVal)) {
                    continue;
                }
                if (DataUpdateFormConfigService.isHistoryOnly(fc)) {
                    // A history row with no value means nothing — and its date only travels with a value.
                    if (String.isBlank(strVal)) continue;
                    String dateKey = DataUpdateFormConfigService.historyDateKey(fc);
                    String dateVal = dateKey != null && raw.get(dateKey) != null ? String.valueOf(raw.get(dateKey)).trim() : '';
                    if (isValidIsoDate(dateVal)) {
                        proposed.put(dateKey, dateVal);
                    }
                }
                proposed.put(fc.fieldApiName, strVal);
            }
        }
        for (DataUpdateFormConfigService.FormFieldConfig tc : config.tables) {
            if (!raw.containsKey(tc.fieldApiName)) continue;
            String tableJson = buildTableValue(tc, raw.get(tc.fieldApiName));
            if (tableJson != null) proposed.put(tc.fieldApiName, tableJson);
        }
        return proposed;
    }

    /**
     * Pasted history table → the compact value stored on the ticket:
     * {"cols":[api names],"rows":[[cell,...],...]} (dates yyyy-MM-dd, numbers with a dot).
     * The portal already normalized and checked every line; this re-checks everything
     * server-side (never trust the client) and rejects the whole submit on any bad line.
     * Fully blank lines are dropped; returns null when no line is left.
     */
    @TestVisible private static String buildTableValue(DataUpdateFormConfigService.FormFieldConfig tc, Object rawRows) {
        if (!(rawRows instanceof List<Object>)) throw new TableValidationException('Rows must be a list.');
        List<Object> rowList = (List<Object>) rawRows;
        List<DataUpdateWrapper.TableColumnDefinition> cols = DataUpdateFormConfigService.describeTableColumns(tc);

        List<String> apiNames = new List<String>();
        for (DataUpdateWrapper.TableColumnDefinition col : cols) apiNames.add(col.apiName);

        List<List<String>> rows = new List<List<String>>();
        Set<String> seenDates = new Set<String>();
        for (Object rawRow : rowList) {
            if (!(rawRow instanceof List<Object>)) throw new TableValidationException('Each row must be a list.');
            List<Object> cells = (List<Object>) rawRow;
            if (cells.size() > cols.size()) throw new TableValidationException('Too many cells.');
            List<String> clean = new List<String>();
            Boolean anyValue = false;
            for (Integer i = 0; i < cols.size(); i++) {
                String cell = i < cells.size() && cells[i] != null ? String.valueOf(cells[i]).trim() : '';
                if (String.isNotBlank(cell)) anyValue = true;
                clean.add(cell);
            }
            if (!anyValue) continue;
            for (Integer i = 0; i < cols.size(); i++) {
                DataUpdateWrapper.TableColumnDefinition col = cols[i];
                String cell = clean[i];
                if (String.isBlank(cell)) {
                    if (col.isRequired == true) throw new TableValidationException('Missing ' + col.apiName + '.');
                    continue;
                }
                if (!isValidTableCell(col, cell)) throw new TableValidationException('Invalid ' + col.apiName + '.');
                if (col.isDate == true && !seenDates.add(cell)) throw new TableValidationException('Duplicate date ' + cell + '.');
            }
            rows.add(clean);
        }
        if (rows.size() > DataUpdateFormConfigService.HISTORY_TABLE_MAX_ROWS) {
            throw new TableValidationException('Too many rows.');
        }
        if (rows.isEmpty()) return null;
        return JSON.serialize(new Map<String, Object>{ 'cols' => apiNames, 'rows' => rows });
    }

    @TestVisible private static Boolean isValidTableCell(DataUpdateWrapper.TableColumnDefinition col, String cell) {
        switch on col.kind {
            when 'Date' {
                return isValidIsoDate(cell);
            }
            when 'Number' {
                if (!Pattern.matches('-?\\d+(\\.\\d+)?', cell)) return false;
                return true;
            }
            when 'Checkbox' {
                return cell == 'true' || cell == 'false';
            }
            when 'Picklist' {
                for (DataUpdateWrapper.PicklistOption opt : col.picklistOptions) {
                    if (opt.value == cell) return true;
                }
                return false;
            }
            when else {
                return col.maxLength == null || col.maxLength == 0 || cell.length() <= col.maxLength;
            }
        }
    }

    // Record values of the read-only questions; History_Only ones have no value on the record.
    @TestVisible private static String buildReadOnlyValues(DataUpdateFormConfigService.FormConfig config, SObject record) {
        Map<String, String> values = new Map<String, String>();
        for (DataUpdateFormConfigService.FormFieldConfig fc : config.fields) {
            if (DataUpdateFormConfigService.isHistoryOnly(fc)) continue;
            // Editable checkboxes travel too: the form starts them in their real state, so a
            // visitor can UNcheck one (otherwise only "checked" could ever be sent).
            Boolean isEditableCheckbox = fc.isReadOnly != true && 'Checkbox'.equals(fc.inputType);
            if (fc.isReadOnly != true && !isEditableCheckbox) continue;
            Object val = record.get(fc.fieldApiName);
            if (val == null) continue;
            // A Date boxed as Object stringifies with a time part — cast so <input type=date> gets yyyy-MM-dd.
            if (val instanceof Date) values.put(fc.fieldApiName, String.valueOf((Date) val));
            else if (val instanceof Datetime) values.put(fc.fieldApiName, ((Datetime) val).format('yyyy-MM-dd'));
            else values.put(fc.fieldApiName, String.valueOf(val));
        }
        return JSON.serialize(values);
    }

    @TestVisible private static Boolean isValidIsoDate(String value) {
        if (String.isBlank(value) || !Pattern.matches('\\d{4}-\\d{2}-\\d{2}', value)) return false;
        try {
            Date.valueOf(value);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    private static List<DataUpdateWrapper.PicklistOption> getPicklistOptions(DataUpdateFormConfigService.FormFieldConfig fc, String targetObjectApiName) {
        List<DataUpdateWrapper.PicklistOption> options = new List<DataUpdateWrapper.PicklistOption>();
        Schema.DescribeFieldResult describe = DataUpdateFormConfigService.describeValueField(fc, targetObjectApiName);
        if (describe == null) return options;
        for (Schema.PicklistEntry entry : describe.getPicklistValues()) {
            if (!entry.isActive()) continue;
            DataUpdateWrapper.PicklistOption opt = new DataUpdateWrapper.PicklistOption();
            opt.label = entry.getLabel();
            opt.value = entry.getValue();
            options.add(opt);
        }
        return options;
    }

    private static Boolean isValidPicklistValue(DataUpdateFormConfigService.FormFieldConfig fc, String targetObjectApiName, String value) {
        for (DataUpdateWrapper.PicklistOption opt : getPicklistOptions(fc, targetObjectApiName)) {
            if (opt.value == value) return true;
        }
        return false;
    }

    private static String buildSubject(DataUpdateFormConfigService.FormConfig config, SObject record) {
        String template = String.isBlank(config.requestSubjectTemplate) ? '{RecordName}' : config.requestSubjectTemplate;
        Object nameVal = record.get(config.recordNameFieldApiName);
        String recordName = nameVal == null ? '' : String.valueOf(nameVal);
        return template.replace('{RecordName}', recordName);
    }
}
