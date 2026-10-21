/**
 * DataUpdateWrapper.cls
 * DTOs for the Data Update Center (DataUpdatePortalController, DataUpdateReviewController).
 * Objects and fields are driven by Data_Update_Form__mdt / Data_Update_Form_Field__mdt, so these
 * wrappers carry variable-cardinality field data as a flat JSON string rather than fixed Apex
 * properties.
 *
 * Adapted from DataUpdateWrapper.cls (Case-based framework): caseId/caseClosed renamed to
 * requestId/requestClosed since the backing object is now Data_Update_Request__c. Labels are FR/EN. RequestSummary/RequestListResult are new — they back
 * the dataUpdateRequestList LWC, which has no equivalent in the Case-based framework.
 */
public without sharing class DataUpdateWrapper {

    // ─── Portal (public) ────────────────────────────────────────────────────

    public class PicklistOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
    }

    public class FieldDefinition {
        @AuraEnabled public String  fieldApiName;
        @AuraEnabled public String  labelFr;
        @AuraEnabled public String  labelEn;
        @AuraEnabled public Integer displayOrder;
        @AuraEnabled public String  sectionLabelFr;
        @AuraEnabled public String  sectionLabelEn;
        @AuraEnabled public String  inputType;
        @AuraEnabled public Boolean isRequired;
        // Optional per-question help set from the form builder; blank = the portal's default.
        @AuraEnabled public String  helpFr;
        @AuraEnabled public String  helpEn;
        // Pure layout hint: true when the public form should render this field on the same
        // visual row as the immediately preceding field in its section (see dataUpdateForm.js).
        @AuraEnabled public Boolean sameRowAsPrevious;
        // Only populated when inputType == 'Picklist' — active values live-described from
        // Schema at request time, never cached/duplicated in CMDT (see DataUpdatePortalController).
        @AuraEnabled public List<PicklistOption> picklistOptions;
        // History_Only fields: the value is written only as a new row on a related history
        // object. When that object has a date field, historyDateKey is the proposed-values key
        // under which the portal sends the (optional) date — blank = the submission date.
        @AuraEnabled public Boolean isHistoryOnly;
        @AuraEnabled public String  historyDateKey;
        // Shown on the public form but not editable ("Only see" in the form builder).
        @AuraEnabled public Boolean isReadOnly;

        public FieldDefinition() {
            picklistOptions = new List<PicklistOption>();
        }
    }

    // History_Table column, live-described from the history object's schema.
    public class TableColumnDefinition {
        @AuraEnabled public String  apiName;
        @AuraEnabled public String  labelFr;
        @AuraEnabled public String  labelEn;
        // Date | Number | Checkbox | Picklist | Text
        @AuraEnabled public String  kind;
        // The table's date column (1 line = 1 date) — always required.
        @AuraEnabled public Boolean isDate;
        @AuraEnabled public Boolean isRequired;
        @AuraEnabled public Integer maxLength;
        @AuraEnabled public List<PicklistOption> picklistOptions;

        public TableColumnDefinition() {
            picklistOptions = new List<PicklistOption>();
        }
    }

    // Paste-from-Excel history table on the public form (églises).
    public class TableDefinition {
        // Proposed-values key (HistoryObject#table) the rows travel under.
        @AuraEnabled public String  key;
        @AuraEnabled public String  titleFr;
        @AuraEnabled public String  titleEn;
        @AuraEnabled public String  helpFr;
        @AuraEnabled public String  helpEn;
        @AuraEnabled public Integer maxRows;
        // How people enter the lines: Fields (one box per column) | Excel (paste grid) | Both.
        @AuraEnabled public String  inputMode;
        @AuraEnabled public List<TableColumnDefinition> columns;
        // Its place on the form, like a question (sorted together with the fields).
        @AuraEnabled public Integer displayOrder;
        @AuraEnabled public String  sectionLabelFr;
        @AuraEnabled public String  sectionLabelEn;

        public TableDefinition() {
            columns = new List<TableColumnDefinition>();
        }
    }

    public class FormDefinition {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String  errorMessage;
        @AuraEnabled public Boolean requiresIdentityField2;
        // Drives which label/placeholder the portal shows for the second identity field —
        // different forms use different fields here (e.g. LastName vs. a church NEQ number),
        // so the client needs the API name to pick the right i18n copy (see dataUpdateI18n.js).
        @AuraEnabled public String  identityField2ApiName;
        @AuraEnabled public List<FieldDefinition> fields;
        @AuraEnabled public List<TableDefinition> tables;
        // Per-form overrides of the portal's standard screen texts (blank = standard i18n text).
        @AuraEnabled public PortalTexts portalTexts;

        public FormDefinition() {
            success = false;
            fields = new List<FieldDefinition>();
            tables = new List<TableDefinition>();
        }
    }

    // Optional per-form overrides of the public portal's standard texts, FR/EN. Every blank
    // value falls back to the standard dataUpdateI18n copy, so a form only stores what it changes.
    public class PortalTexts {
        @AuraEnabled public String lookupTitleFr;
        @AuraEnabled public String lookupTitleEn;
        @AuraEnabled public String lookupSubtitleFr;
        @AuraEnabled public String lookupSubtitleEn;
        @AuraEnabled public String idHelpFr;
        @AuraEnabled public String idHelpEn;
        @AuraEnabled public String formTitleFr;
        @AuraEnabled public String formTitleEn;
        @AuraEnabled public String formSubtitleFr;
        @AuraEnabled public String formSubtitleEn;
        // Text palette of the form builder (JSON, see Portal_Text_Styles__c).
        @AuraEnabled public String stylesJson;
        // Design blocks of the builder's Tools tab (JSON array, see Portal_Blocks__c).
        @AuraEnabled public String blocksJson;
        // Uniform font + colors of the whole form (JSON, see Portal_Appearance__c).
        @AuraEnabled public String appearanceJson;
        // Custom FR/EN texts of the portal messages (JSON, see Portal_Messages__c).
        @AuraEnabled public String messagesJson;
    }

    // Named appearance the builder can copy into any form (Data_Update_Appearance_Template__mdt).
    public class AppearanceTemplate {
        @AuraEnabled public String developerName;
        @AuraEnabled public String label;
        @AuraEnabled public String appearanceJson;
    }

    public class LookupResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public Boolean alreadyPending;
        @AuraEnabled public Boolean isLocked;
        @AuraEnabled public String  errorMessage;
        @AuraEnabled public String  recordId;
        @AuraEnabled public String  recordName;
        // Signed proof (DataUpdateReCaptchaService) that this identity pair already
        // cleared a captcha-gated lookup — passed back into submitUpdate() so the
        // visitor isn't asked to solve reCAPTCHA a second time on the form step.
        @AuraEnabled public String  lookupPass;
        // Current values of the "Only see" questions (JSON map field -> text), shown read-only
        // on the form step. Only those questions — the rest of the record is never sent back.
        @AuraEnabled public String  readOnlyValuesJson;

        public LookupResult() {
            success        = false;
            alreadyPending = false;
            isLocked       = false;
        }
    }

    public class SubmitResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public Boolean alreadyPending;
        @AuraEnabled public Boolean isLocked;
        @AuraEnabled public String  errorMessage;
        @AuraEnabled public String  requestId;
        // Set with errorMessage INVALID_POSTAL_CODE: the field to show the error under.
        @AuraEnabled public String  invalidFieldApiName;

        public SubmitResult() {
            success        = false;
            alreadyPending = false;
            isLocked       = false;
        }
    }

    // ─── Internal review ────────────────────────────────────────────────────

    public class ReviewSummary {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String  errorMessage;
        @AuraEnabled public Integer changedFieldCount;
        @AuraEnabled public Boolean requestClosed;

        public ReviewSummary() {
            success           = false;
            requestClosed      = false;
            changedFieldCount = 0;
        }
    }

    public class ComparisonField {
        @AuraEnabled public String  fieldApiName;
        @AuraEnabled public String  fieldLabelFr;
        @AuraEnabled public String  fieldLabelEn;
        @AuraEnabled public String  sectionLabelFr;
        @AuraEnabled public String  sectionLabelEn;
        @AuraEnabled public String  submittedValue;
        @AuraEnabled public String  currentValue;
        @AuraEnabled public Boolean isDifferent;
        @AuraEnabled public Boolean previouslyRolledBack;
        // History_Only: currentValue is the latest history row's value (currentValueDate its
        // date); historyDate is the date the new row will carry once applied.
        @AuraEnabled public Boolean isHistoryOnly;
        @AuraEnabled public String  currentValueDate;
        @AuraEnabled public String  historyDate;
        // Historize: the Account field is replaced AND a row is added to the history object.
        // The panel shows the history object's label, its latest row (as reference) and the
        // date the new row will carry; historyLast* are blank when the account has no rows yet.
        @AuraEnabled public Boolean isHistorize;
        @AuraEnabled public String  historyObjectLabel;
        @AuraEnabled public String  historyLastValue;
        @AuraEnabled public String  historyLastDate;
        // EDA contact: Email is saved in the preferred email field (EDA copies it into Email).
        @AuraEnabled public String  savedInFieldApiName;
        @AuraEnabled public String  savedInLabelFr;
        @AuraEnabled public String  savedInLabelEn;
        // Email and the preferred email field both bring a different new value: only one can be
        // the main email. Both checked → Email's value is kept, the other one is not applied.
        @AuraEnabled public Boolean emailConflict;
        @AuraEnabled public String emailPreferenceUnknown;
        // EMAIL / PHONE when the value can be saved in another field of that kind (saveOptions).
        @AuraEnabled public String saveKind;
    }

    // One pasted line of a History_Table. isDuplicate = the account already has a history row
    // on that date (existingCells = that row's values, same column order) — excluded by default,
    // staff may choose to overwrite it.
    public class ComparisonTableRow {
        @AuraEnabled public Integer      index;
        @AuraEnabled public List<String> cells;
        @AuraEnabled public String       dateValue;
        @AuraEnabled public Boolean      isDuplicate;
        @AuraEnabled public List<String> existingCells;

        public ComparisonTableRow() {
            cells = new List<String>();
            existingCells = new List<String>();
            isDuplicate = false;
        }
    }

    public class ComparisonTable {
        @AuraEnabled public String  key;
        @AuraEnabled public String  titleFr;
        @AuraEnabled public String  titleEn;
        @AuraEnabled public String  objectLabel;
        @AuraEnabled public Boolean previouslyRolledBack;
        @AuraEnabled public Integer duplicateCount;
        @AuraEnabled public List<TableColumnDefinition> columns;
        @AuraEnabled public List<ComparisonTableRow> rows;

        public ComparisonTable() {
            columns = new List<TableColumnDefinition>();
            rows = new List<ComparisonTableRow>();
            duplicateCount = 0;
            previouslyRolledBack = false;
        }
    }

    public class ComparisonData {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String  errorMessage;
        @AuraEnabled public String  requestId;
        @AuraEnabled public String  recordId;
        @AuraEnabled public String  recordName;
        @AuraEnabled public Boolean requestClosed;
        @AuraEnabled public Boolean isLocked;
        @AuraEnabled public String  formDeveloperName;
        @AuraEnabled public String  formLabel;
        // true when the source form no longer exists and the grid was rebuilt from the ticket
        @AuraEnabled public Boolean formDeleted;
        @AuraEnabled public List<ComparisonField> fields;
        // Ticket header (review panel redesign): number, submitter and submission date.
        @AuraEnabled public String   requestNumber;
        @AuraEnabled public String   requestedName;
        @AuraEnabled public String   requestedEmail;
        @AuraEnabled public Datetime createdDate;
        // Live Status__c from the server — the panel's pill must not trust a stale list row.
        @AuraEnabled public String   status;
        // Proposed fields whose value already matches Salesforce — shown collapsed as
        // "identical fields", never applied. Kept apart from `fields` on purpose.
        @AuraEnabled public List<ComparisonField> unchangedFields;
        // History_Table lines submitted with the ticket (paste-from-Excel history).
        @AuraEnabled public List<ComparisonTable> tables;
        // Number of another still-open ticket on the same record (closed ticket + locked record
        // only): the unlock stays blocked until that ticket is closed too.
        @AuraEnabled public String   otherOpenRequestNumber;
        // Email / phone fields of the record a value can be saved in instead ("Save in"), and the
        // EDA preference each one can take ("Preferred"). Empty when the record has none.
        @AuraEnabled public List<GroupSlotGroup> saveOptions;

        public ComparisonData() {
            tables       = new List<ComparisonTable>();
            success      = false;
            requestClosed = false;
            isLocked     = false;
            formDeleted  = false;
            fields       = new List<ComparisonField>();
            unchangedFields = new List<ComparisonField>();
            saveOptions  = new List<GroupSlotGroup>();
        }
    }

    public class ApplyResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String  errorMessage;
        @AuraEnabled public Integer updatedFieldCount;
        // true only on a rollback whose field had History_Mode__c = 'Historize' but no
        // History_Target_Log_Field_API_Name__c configured — the base field still rolled back,
        // but its history row could not be located to delete and is now orphaned.
        @AuraEnabled public Boolean historyCleanupSkipped;

        public ApplyResult() {
            success           = false;
            updatedFieldCount = 0;
        }
    }

    public class CorrectionResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String  errorMessage;
        @AuraEnabled public String  newValue;

        public CorrectionResult() {
            success = false;
        }
    }

    // ─── Bandeja de entrada (dataUpdateRequestList) ────────────────────────────────

    public class RequestSummary {
        @AuraEnabled public String   id;
        @AuraEnabled public String   requestNumber;
        @AuraEnabled public String   subject;
        @AuraEnabled public String   status;
        @AuraEnabled public String   closedReason;
        @AuraEnabled public String   requestedName;
        @AuraEnabled public String   updateFormDeveloperName;
        @AuraEnabled public String   formLabel;
        @AuraEnabled public Integer  changedFieldCount;
        @AuraEnabled public Datetime createdDate;
        // Target record currently locked (form has a lock field) — shows the lock icon in the list.
        @AuraEnabled public Boolean  isLocked;
        // Other users who have this ticket open right now (Data_Update_Presence__c heartbeat).
        @AuraEnabled public List<String> viewers;
        // Grouped list: the record the ticket is about, its name, and how many tickets are
        // still open on it (every form), plus history-table lines it carries.
        @AuraEnabled public String   targetRecordId;
        @AuraEnabled public String   targetName;
        @AuraEnabled public Integer  targetOpenCount;
        @AuraEnabled public Integer  tableRowCount;

        public RequestSummary() {
            isLocked = false;
            viewers  = new List<String>();
        }
    }

    public class RequestListResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String  errorMessage;
        @AuraEnabled public List<RequestSummary> requests;
        @AuraEnabled public Integer totalCount;

        public RequestListResult() {
            success    = false;
            requests    = new List<RequestSummary>();
            totalCount = 0;
        }
    }

    // ─── Cuentas bloqueadas (dataUpdateLockedList) ─────────────────────────

    public class LockedRecordSummary {
        @AuraEnabled public String   recordId;
        @AuraEnabled public String   recordName;
        @AuraEnabled public Datetime lockedDate;
        @AuraEnabled public String   latestRequestId;
        @AuraEnabled public String   latestRequestNumber;
        @AuraEnabled public String   latestRequestStatus;
        @AuraEnabled public Boolean  isBlockedByOpenRequest;

        public LockedRecordSummary() {
            isBlockedByOpenRequest = false;
        }
    }

    public class LockedRecordListResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String  errorMessage;
        @AuraEnabled public List<LockedRecordSummary> records;
        @AuraEnabled public Integer totalCount;
        // Locked records "Unlock all" can actually free (no open ticket) — not filled while searching.
        @AuraEnabled public Integer unlockableCount;

        public LockedRecordListResult() {
            success    = false;
            records    = new List<LockedRecordSummary>();
            totalCount = 0;
            unlockableCount = 0;
        }
    }

    // ─── Checklist de respuesta por formulario (dataUpdateResponseChecklist) ──

    public class ChecklistItem {
        @AuraEnabled public String  recordId;
        @AuraEnabled public String  recordName;
        @AuraEnabled public Boolean responded;
        @AuraEnabled public Datetime lastResponse;
    }

    public class ChecklistResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String  errorMessage;
        @AuraEnabled public List<ChecklistItem> items;

        public ChecklistResult() {
            success = false;
            items   = new List<ChecklistItem>();
        }
    }

    public class UnlockResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String  errorMessage;
        @AuraEnabled public String  openRequestId;
        @AuraEnabled public String  openRequestNumber;

        public UnlockResult() {
            success = false;
        }
    }

    public class UnlockAllResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String  errorMessage;
        @AuraEnabled public Integer unlockedCount;
        @AuraEnabled public Integer skippedCount;

        public UnlockAllResult() {
            success       = false;
            unlockedCount = 0;
            skippedCount  = 0;
        }
    }

    // ─── Audit history (Data_Update_Log__c) ────────────────────────────────

    public class AuditFieldChange {
        @AuraEnabled public String fieldApiName;
        @AuraEnabled public String fieldLabelFr;
        @AuraEnabled public String fieldLabelEn;
        @AuraEnabled public String  beforeValue;
        @AuraEnabled public String  afterValue;
        @AuraEnabled public Boolean canRollback;
        // Value answered in another question and saved in this field (e.g. Email → preferred email).
        @AuraEnabled public String  sourceLabelFr;
        @AuraEnabled public String  sourceLabelEn;
    }

    public class AuditLogEntry {
        @AuraEnabled public Id       logId;
        @AuraEnabled public String   actionType;
        @AuraEnabled public String   performedByName;
        @AuraEnabled public Datetime performedDate;
        @AuraEnabled public List<AuditFieldChange> fieldChanges;
        // Grouped review: how many other tickets of the same record were applied with this one.
        @AuraEnabled public Integer  groupOthers;
        @AuraEnabled public String   groupRecordName;
        // Grouped review: values of this ticket that were not applied, and why.
        @AuraEnabled public List<AuditNotApplied> notApplied;
        // EDA preference changed with this apply (Preferred Email / Phone): kind EMAIL/PHONE, before → after.
        @AuraEnabled public List<AuditPreferredChange> preferredChanges;
        // actionType = 'STATUS': a status change (hold, resume, ignore, reopen) read from Notes__c.
        @AuraEnabled public String   statusValue;
        @AuraEnabled public String   statusReason;
        @AuraEnabled public String   statusNotes;
        // Older status entries only stored the day — show the date without a time.
        @AuraEnabled public Boolean  dateOnly;

        public AuditLogEntry() {
            fieldChanges = new List<AuditFieldChange>();
            notApplied   = new List<AuditNotApplied>();
            preferredChanges = new List<AuditPreferredChange>();
        }
    }

    public class AuditPreferredChange {
        @AuraEnabled public String kind;
        @AuraEnabled public String beforeValue;
        @AuraEnabled public String afterValue;
    }

    // ─── Grouped review (DataUpdateMultiTicketReviewController) ─────────────────

    public class GroupTicket {
        @AuraEnabled public String   id;
        @AuraEnabled public String   requestNumber;
        @AuraEnabled public String   status;
        @AuraEnabled public String   formDeveloperName;
        @AuraEnabled public String   formLabel;
        @AuraEnabled public Datetime createdDate;
    }

    // One field of the record that a value can be saved in, with what it holds now.
    public class GroupSlot {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        // EDA contact: the hed__Preferred_Email__c / hed__PreferredPhone__c value naming this
        // field, null when it can't be the preferred one.
        @AuraEnabled public String preference;
    }

    // Fields of one kind (EMAIL / PHONE) — "Save to" choices for a value of that kind.
    public class GroupSlotGroup {
        @AuraEnabled public String kind;
        @AuraEnabled public List<GroupSlot> slots;
        // EDA contact: the field preferred now (null: none, or no EDA preference for this kind).
        @AuraEnabled public String preferredField;
        public GroupSlotGroup() { slots = new List<GroupSlot>(); }
    }

    public class GroupContext {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String  errorMessage;
        @AuraEnabled public String  targetRecordId;
        @AuraEnabled public String  recordName;
        // Open tickets on the record, newest first.
        @AuraEnabled public List<GroupTicket> tickets;
        @AuraEnabled public List<GroupSlotGroup> slotGroups;
        // EDA contact: the field Email is really saved in (Email itself is never offered as a place).
        @AuraEnabled public String  emailSavedIn;
        // Same for Phone (the preferred phone field).
        @AuraEnabled public String  phoneSavedIn;
        public GroupContext() {
            success    = false;
            tickets    = new List<GroupTicket>();
            slotGroups = new List<GroupSlotGroup>();
        }
    }

    // reason: SAME_AS_SF | OTHER_TICKET (ticket = the one whose value was used) | UNCHECKED | MERGED
    //         | EMAIL_PREFERRED_CONFLICT (Email's value took the preferred email field) | EMAIL_EMPTY
    public class AuditNotApplied {
        @AuraEnabled public String labelFr;
        @AuraEnabled public String labelEn;
        @AuraEnabled public String value;
        @AuraEnabled public String reason;
        @AuraEnabled public String ticket;
    }

    public class AuditLogResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String  errorMessage;
        @AuraEnabled public List<AuditLogEntry> entries;

        public AuditLogResult() {
            success = false;
            entries = new List<AuditLogEntry>();
        }
    }

    // ─── Catálogo de campos (dataUpdateFormBuilder) ────────────

    public class FormSummary {
        @AuraEnabled public String  developerName;
        @AuraEnabled public String  label;
        @AuraEnabled public String  targetObjectApiName;
        @AuraEnabled public Boolean hasLockField;
        // Real public URL of the site this form is published on, resolved server-side via
        // Network.getLoginUrl() — never guessed from window.location (Settings runs inside the
        // internal org, not the public site). Null if Network_Name__c doesn't match a live Network.
        @AuraEnabled public String  publicUrl;
        // True for the original/base form of its site — never deletable from Settings.
        @AuraEnabled public Boolean isCoreForm;
        // Site (Network.Name) the form is published on — the builder's "New form" defaults to it.
        @AuraEnabled public String  networkName;
        // True when the form targets église Accounts — drives the dashboard responses checklist.
        @AuraEnabled public Boolean isChurchForm;
        // Church form whose tickets can pile up per church (no lock) — grouped in the review list.
        @AuraEnabled public Boolean allowMultipleSubmissions;
    }

    // Inherited config from a site's core form, used to pre-fill the "create form" wizard's
    // Advanced options when the admin picks a Site — see DataUpdateFormAdminController.
    // getCoreFormConfigForNetwork().
    public class CoreFormConfig {
        @AuraEnabled public String targetObjectApiName;
        @AuraEnabled public String identityField1ApiName;
        @AuraEnabled public String identityField1Comparison;
        @AuraEnabled public String identityField2ApiName;
        @AuraEnabled public String identityField2Comparison;
        @AuraEnabled public String targetBaseFilterField;
        @AuraEnabled public String targetBaseFilterValue;
        @AuraEnabled public String ownerQueueDeveloperName;
        @AuraEnabled public String recordNameFieldApiName;
        @AuraEnabled public String lockFieldApiName;
        @AuraEnabled public String lockDateFieldApiName;
    }

    public class AdminFieldConfig {
        @AuraEnabled public String  developerName;
        @AuraEnabled public String  fieldApiName;
        @AuraEnabled public String  labelFr;
        @AuraEnabled public String  labelEn;
        @AuraEnabled public Integer displayOrder;
        @AuraEnabled public String  sectionLabelFr;
        @AuraEnabled public String  sectionLabelEn;
        @AuraEnabled public String  inputType;
        @AuraEnabled public Boolean isRequired;
        @AuraEnabled public Boolean isActive;
        @AuraEnabled public Boolean isValidInSchema;
        @AuraEnabled public String  historyMode;
        @AuraEnabled public String  historyTargetObjectApiName;
        @AuraEnabled public String  historyTargetValueFieldApiName;
        @AuraEnabled public String  historyTargetDateFieldApiName;
        @AuraEnabled public String  historyTargetAccountFieldApiName;
        @AuraEnabled public String  historyTargetLogFieldApiName;
        @AuraEnabled public String  historyDateSourceFieldApiName;
        @AuraEnabled public Boolean sameRowAsPrevious;
        @AuraEnabled public Boolean isHidden;
        @AuraEnabled public Boolean isReadOnly;
        @AuraEnabled public String  helpFr;
        @AuraEnabled public String  helpEn;
        // History_Table only: History_Table_Columns__c JSON ([{f,fr,en}], display order).
        @AuraEnabled public String  historyTableColumns;
        // History_Table only: Fields | Excel | Both (blank = Excel).
        @AuraEnabled public String  historyTableInputMode;
    }

    // Form-level data the visual form builder (dataUpdateFormBuilder) needs beyond the field catalog.
    public class BuilderFormInfo {
        @AuraEnabled public String developerName;
        @AuraEnabled public String label;
        @AuraEnabled public String targetObjectApiName;
        @AuraEnabled public String identityField2ApiName;
        @AuraEnabled public PortalTexts portalTexts;
        // Église forms get one paste-from-Excel history table per related history object.
        @AuraEnabled public Boolean isChurchForm;
        @AuraEnabled public Boolean allowMultipleSubmissions;
    }

    // A related object as a candidate History_Table for the form builder: the lookups/date
    // column the server will use, and the columns staff can check (lookups never offered).
    public class HistoryTableSchema {
        @AuraEnabled public String objectApiName;
        @AuraEnabled public String objectLabel;
        @AuraEnabled public String accountFieldApiName;
        @AuraEnabled public String logFieldApiName;
        @AuraEnabled public String dateFieldApiName;
        @AuraEnabled public List<SchemaFieldOption> columns;

        public HistoryTableSchema() {
            columns = new List<SchemaFieldOption>();
        }
    }

    public class AvailableFieldOption {
        @AuraEnabled public String apiName;
        @AuraEnabled public String schemaLabel;
        @AuraEnabled public String inferredInputType;
    }

    // ─── Schema-scan for history mapping (dataUpdateFormBuilder) ──────────

    public class SchemaObjectOption {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        // getRelatedObjects only: forms (DeveloperName) that already map a question/table to it.
        @AuraEnabled public List<String> usedByForms;
    }

    public class SchemaFieldOption {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        @AuraEnabled public String type;
        @AuraEnabled public List<String> referenceToApiNames;
        // Must be filled on insert (not nillable, no default) — locked-on in history tables.
        @AuraEnabled public Boolean isRequired;
        @AuraEnabled public Boolean isCreateable;

        public SchemaFieldOption() {
            referenceToApiNames = new List<String>();
        }
    }

    // Builder publish lock (one publish at a time in the org).
    public class PublishLockInfo {
        @AuraEnabled public Boolean active = false;
        @AuraEnabled public Boolean acquired = false;
        @AuraEnabled public Boolean mine = false;
        @AuraEnabled public String  phase;          // publishing | cooldown
        @AuraEnabled public String  what;
        @AuraEnabled public String  userName;
        @AuraEnabled public Integer elapsedSecs;
        @AuraEnabled public Integer remainingSecs;
    }

    public class DeployStatusResult {
        @AuraEnabled public String  jobId;
        @AuraEnabled public String  status;
        @AuraEnabled public Boolean done;
        @AuraEnabled public String  errorMessage;
        @AuraEnabled public String  formDeveloperName;

        public DeployStatusResult() {
            done = false;
        }
    }
}
