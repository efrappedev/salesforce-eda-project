import { LightningElement, api, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import { getRecordUi } from 'lightning/uiRecordApi';
import { getLabels, format } from 'c/i18n';
import getComparisonMatrix               from '@salesforce/apex/MergeController.getComparisonMatrix';
import getRelatedRecordsComparisonApex   from '@salesforce/apex/MergeController.getRelatedRecordsComparison';
import getLoserSnapshotApex              from '@salesforce/apex/MergeController.getLoserSnapshot';
import executeMergeApex                  from '@salesforce/apex/MergeController.executeMerge';
import undoMergeApex                     from '@salesforce/apex/MergeController.undoMerge';
import dismissTicketApex                 from '@salesforce/apex/MergeController.dismissTicket';
import closeTicketApex                   from '@salesforce/apex/MergeController.closeTicket';
import reopenTicketApex                  from '@salesforce/apex/MergeController.reopenTicket';
import deleteOrphanedAccountApex       from '@salesforce/apex/MergeController.deleteOrphanedAccount';
import restoreDeletedAccountApex       from '@salesforce/apex/MergeController.restoreDeletedAccount';
import getDeletedAccountsForTicketApex from '@salesforce/apex/MergeController.getDeletedAccountsForTicket';
import deleteOrphanedContactApex       from '@salesforce/apex/MergeController.deleteOrphanedContact';
import restoreDeletedContactApex       from '@salesforce/apex/MergeController.restoreDeletedContact';
import getDeletedContactsForTicketApex from '@salesforce/apex/MergeController.getDeletedContactsForTicket';

const CLOSED_REASON_KEY = {
    'False Positive - Same Household':    'reasonHouseholdLong',
    'False Positive - Same Organization': 'reasonOrganizationLong',
    'False Positive - Shared Phone':      'reasonSharedPhoneLong',
    'False Positive - Shared Email':      'reasonSharedEmailLong',
    'Already Resolved':                   'reasonResolvedLong',
    'Out of Scope':                       'reasonOutOfScopeLong',
    'Other':                              'reasonOtherLong'
};

// Maps the internal close-reason keys to valid Salesforce picklist API values
const CLOSE_REASON_TO_SF = {
    'same-household': 'False Positive - Same Household',
    'same-phone':     'False Positive - Shared Phone',
    'same-email':     'False Positive - Shared Email',
    'not-duplicate':  'Out of Scope',
    'already-merged': 'Already Resolved'
};

const MATCH_TYPE_KEY = {
    Email: 'matchEmail',
    Phone: 'matchPhone',
    Name:  'matchName',
    Mixed: 'matchMixed'
};

const KEY_FIELD_DEF = [
    { i18nKey: 'kfEmail',     field: 'Email'        },
    { i18nKey: 'kfPhone',     field: 'Phone'        },
    { i18nKey: 'kfMobile',    field: 'MobilePhone'  },
    { i18nKey: 'kfAccount',   field: 'AccountId'    },
    { i18nKey: 'kfContactId', field: 'ID_Contact__c'},
    { i18nKey: 'kfOwner',     field: 'OwnerId'      }
];

export default class MergeWizard extends NavigationMixin(LightningElement) {
    @api ticketId;
    @api lang = 'fr';
    @api objectType = 'Contact';

    // ── Wizard state ─────────────────────────────────────────────────────────
    @track currentStep       = 1;
    @track masterId          = null;
    @track selectedLoserIds  = [];
    @track fieldDecisions    = {};
    @track mergeNotes        = '';
    @track isLoading         = false;
    @track isExecuting       = false;
    @track isReopening       = false;

    // ── Dismiss modal ────────────────────────────────────────────────────────
    @track showDismissModal     = false;
    @track dismissMode          = null; // null | 'toValidate' | 'close'
    @track dismissReason        = null;
    @track dismissNotes         = '';
    @track dismissError         = null;
    @track isDismissing         = false;
    @track closeReason          = null;
    @track closeNotes           = '';
    @track newReasonInput         = '';
    @track customCloseReasons     = [];
    @track showAddReasonPopover   = false;
    @track showAllHistory         = false;

    // ── Orphaned Account modal ───────────────────────────────────────────────
    @track showOrphanModal    = false;
    @track orphanedAccounts   = [];
    @track isDeletingAccount  = false;
    _pendingMergeComplete     = null;

    // ── Deleted accounts (for restore) ───────────────────────────────────────
    _wiredDeletedAccounts;
    @track deletedAccounts    = [];

    // ── Orphaned Contact modal ────────────────────────────────────────────────
    @track showOrphanContactModal = false;
    @track orphanedContacts       = [];
    @track isDeletingContact      = false;

    // ── Cleaned-up orphaned tickets ──────────────────────────────────────────
    @track cleanedUpMessage = '';

    // ── Deleted contacts (for restore) ───────────────────────────────────────
    _wiredDeletedContacts;
    @track deletedContacts        = [];

    // ── Candidate record / snapshot modal ───────────────────────────────────
    @track recordModalId    = null;
    @track recordModalName  = null;

    get showCandidateModal() { return !!this.recordModalId; }

    // ── Snapshot view modal ──────────────────────────────────────────────────
    @track showSnapshotModal  = false;
    @track snapshotLoading    = false;
    @track snapshotData       = null;

    // ── Related records (Step 2) ─────────────────────────────────────────────
    _wiredRelated;
    @track _relatedComparisons = [];
    @track _relatedDeleteIds   = {};   // { recordId: true } for loser records to delete
    @track undoConfirmMode     = false;

    // ── Data ─────────────────────────────────────────────────────────────────
    @track _matrix  = null;
    @track _ticket  = null;

    // ── i18n ─────────────────────────────────────────────────────────────────
    get i18n() { return getLabels(this.lang); }

    get closedReasonOptions() {
        const t = this.i18n;
        return Object.entries(CLOSED_REASON_KEY).map(([value, key]) => ({
            label: t[key] || value,
            value
        }));
    }

    get dismissModeToValidate() { return this.dismissMode === 'toValidate'; }
    get dismissModeClose()      { return this.dismissMode === 'close'; }
    get hasDismissMode()        { return this.dismissMode !== null; }
    get choiceCardToValidateClass() {
        return 'exception-choice-card exception-choice-card_validate' +
            (this.dismissMode === 'toValidate' ? ' exception-choice-card_selected' : '');
    }
    get choiceCardCloseClass() {
        return 'exception-choice-card exception-choice-card_close' +
            (this.dismissMode === 'close' ? ' exception-choice-card_selected' : '');
    }
    get closeReasonOptions() {
        const t = this.i18n;
        const predefined = [
            { label: t.closeReasonSameHousehold,  value: 'same-household'  },
            { label: t.closeReasonSamePhone,       value: 'same-phone'      },
            { label: t.closeReasonSameEmail,       value: 'same-email'      },
            { label: t.closeReasonNotDuplicate,    value: 'not-duplicate'   },
            { label: t.closeReasonAlreadyMerged,   value: 'already-merged'  }
        ];
        const custom = this.customCloseReasons.map(r => ({ label: r, value: r }));
        return [...predefined, ...custom, { label: t.addNewReasonOption, value: '__add_new__' }];
    }

    // ── Wire: deleted accounts ────────────────────────────────────────────────
    @wire(getDeletedAccountsForTicketApex, { ticketId: '$ticketId' })
    wiredDeleted(result) {
        this._wiredDeletedAccounts = result;
        if (result.data) this.deletedAccounts = result.data;
    }

    get hasDeletedAccounts() { return this.isMergedTicket && this.deletedAccounts.length > 0; }

    @wire(getDeletedContactsForTicketApex, { ticketId: '$ticketId' })
    wiredDeletedContacts(result) {
        this._wiredDeletedContacts = result;
        if (result.data) this.deletedContacts = result.data;
    }

    get hasDeletedContacts() { return this.isMergedTicket && this.deletedContacts.length > 0; }

    // ── Wire: related records comparison ─────────────────────────────────────
    @track _allRelatedIds = null;   // all IDs for bulk getRecordUi preview
    @track _previewMap    = {};     // { id15 → [{label, value}] }

    @wire(getRelatedRecordsComparisonApex, { ticketId: '$ticketId', masterId: '$masterId' })
    wiredRelated(result) {
        this._wiredRelated = result;
        if (result.data) {
            this._relatedComparisons = result.data;
            this._relatedDeleteIds   = {};
            this._previewMap         = {}; // reset while previews reload
            // Collect all record IDs for bulk compact-layout preview
            const ids = new Set();
            for (const c of result.data) {
                [...(c.masterRecords||[]), ...(c.loserRecords||[])].forEach(r => {
                    if (r.recordId) ids.add(r.recordId);
                });
            }
            this._allRelatedIds = ids.size > 0 ? [...ids] : null;
        }
    }

    // Load compact layout data for ALL related records at once
    @wire(getRecordUi, {
        recordIds:   '$_allRelatedIds',
        layoutTypes: ['Full'],
        modes:       ['View']
    })
    wiredAllRelatedUi({ data }) {
        if (data) this._previewMap = this._buildPreviewMap(data);
    }

    _buildPreviewMap(data) {
        const map = {};
        try {
            const snap     = JSON.parse(JSON.stringify(data));
            const recs     = snap.records     || {};
            const objInfos = snap.objectInfos || {};
            const layouts  = snap.layouts     || {};

            const SKIP = new Set([
                'Id', 'Name', 'RecordTypeId', 'OwnerId', 'IsDeleted',
                'SystemModstamp', 'LastReferencedDate', 'LastViewedDate',
                'CreatedById', 'LastModifiedById', 'LastActivityDate',
                'CurrencyIsoCode', 'CreatedDate', 'LastModifiedDate',
                'CreatedBy', 'LastModifiedBy'
            ]);

            const stripHtml = (s) =>
                s.replace(/<br\s*\/?>/gi, ', ')
                 .replace(/<[^>]*>/g, '')
                 .replace(/,\s*,/g, ',')
                 .trim();

            const getRelName = (fields, relKey) => {
                const r = fields[relKey];
                if (!r) return null;
                return r.displayValue
                    || (typeof r.value === 'string' ? r.value : null)
                    || r.value?.fields?.Name?.value
                    || null;
            };

            // Field types that best identify a record (shown first)
            const PRIORITY_TYPES = new Set([
                'Reference', 'String', 'Picklist', 'MultiPicklist',
                'Email', 'Phone', 'Url', 'TextArea', 'LongTextArea'
            ]);

            // Extract field names in page layout order from Full layout sections
            const getLayoutOrder = (apiName, recFields) => {
                const objLayouts = layouts[apiName] || {};
                const rtKey = Object.keys(objLayouts)[0];
                const viewLayout = rtKey ? objLayouts[rtKey]?.Full?.View : null;
                if (!viewLayout?.sections || !Array.isArray(viewLayout.sections)) return null;
                const ordered = [];
                for (const section of viewLayout.sections) {
                    for (const row of (section.layoutRows || [])) {
                        for (const item of (row.layoutItems || [])) {
                            for (const comp of (item.layoutComponents || [])) {
                                const fn = comp.apiName;
                                if (comp.componentType === 'Field' && fn
                                    && !SKIP.has(fn) && recFields[fn]
                                    && !fn.endsWith('__r')) {
                                    ordered.push(fn);
                                }
                            }
                        }
                    }
                }
                return ordered.length > 0 ? ordered : null;
            };

            // Resolve a single field to its display value (or null if should skip)
            const resolveVal = (fname, fval, recFields, fieldMeta) => {
                if (fval.displayValue != null) return String(fval.displayValue);
                if (fval.value == null || fval.value === false) return null;
                if (typeof fval.value === 'boolean') return '✓';
                if (typeof fval.value === 'object') return null;
                if (fieldMeta.dataType === 'Reference') {
                    const relKey = fname.endsWith('__c')
                        ? fname.slice(0, -3) + '__r'
                        : fname.replace(/Id$/, '');
                    return getRelName(recFields, relKey) || null;
                }
                return String(fval.value);
            };

            const MAX_PREVIEW = 5;

            for (const [id, rec] of Object.entries(recs)) {
                const objFields = (objInfos[rec.apiName] || {}).fields || {};
                const recFields = rec.fields || {};
                const preview   = [];

                const orderedKeys = getLayoutOrder(rec.apiName, recFields)
                    || Object.keys(recFields).filter(f => !SKIP.has(f) && !f.endsWith('__r'));

                // Two-pass: priority types first, then numeric/date to fill remaining slots
                const secondary = [];
                for (const fname of orderedKeys) {
                    const fval = recFields[fname];
                    if (!fval || SKIP.has(fname) || fname.endsWith('__r')) continue;
                    const fieldMeta = objFields[fname] || {};
                    let val = resolveVal(fname, fval, recFields, fieldMeta);
                    if (!val) continue;
                    if (val.includes('<')) val = stripHtml(val);
                    if (!val) continue;
                    const entry = { label: fieldMeta.label || fname, value: val };
                    if (PRIORITY_TYPES.has(fieldMeta.dataType)) {
                        if (preview.length < MAX_PREVIEW) preview.push(entry);
                    } else {
                        secondary.push(entry);
                    }
                }
                // Fill remaining slots with secondary fields (dates, numbers)
                for (const entry of secondary) {
                    if (preview.length >= MAX_PREVIEW) break;
                    preview.push(entry);
                }

                map[id.substring(0, 15).toLowerCase()] = preview;
            }
        } catch(e) { /* ignore */ }
        return map;
    }

    get relatedCompGroups() {
        if (!this._relatedComparisons || !this._relatedComparisons.length) return [];
        const pm = this._previewMap;
        const pf = (id) => pm[id?.substring(0, 15)?.toLowerCase()] || [];
        return this._relatedComparisons
            .map(c => ({
                key:   c.apiName,
                label: c.label,
                masterRecords: c.masterRecords.map(r => {
                    const previewFields = pf(r.recordId);
                    return {
                        ...r,
                        objectApiName: c.apiName,
                        objectLabel:   c.label,
                        previewFields,
                        hasPreview: previewFields.length > 0
                    };
                }),
                loserRecords: c.loserRecords.map(r => {
                    const previewFields = pf(r.recordId);
                    return {
                        recordId:      r.recordId,
                        recordName:    r.recordName,
                        hasConflict:   r.hasConflict,
                        objectApiName: c.apiName,
                        objectLabel:   c.label,
                        deleteChecked: !!this._relatedDeleteIds[r.recordId],
                        rowClass: r.hasConflict
                            ? 'related-rec related-rec_conflict' : 'related-rec',
                        previewFields,
                        hasPreview: previewFields.length > 0
                    };
                }),
                hasConflicts: c.loserRecords.some(r => r.hasConflict)
            }));
    }

    // ── Record view modal ─────────────────────────────────────────────────────
    @track _viewRecordId      = null;
    @track _viewObjectApiName = null;
    @track _viewObjectLabel   = null;
    @track _viewRecordName    = null;
    @track _viewRecordUi      = null;
    @track _viewRecordUiError = null;

    get showRecordModal() { return !!this._viewRecordId; }

    get _viewRecordUrl() {
        return this._viewRecordId ? '/lightning/r/' + this._viewRecordId + '/view' : '#';
    }

    @wire(getRecordUi, {
        recordIds:   '$_viewRecordId',
        layoutTypes: ['Full'],
        modes:       ['View']
    })
    wiredViewRecordUi({ data, error }) {
        this._viewRecordUi      = data  || null;
        this._viewRecordUiError = error || null;
    }

    get viewRecordFields() {
        if (!this._viewRecordUi || !this._viewRecordId) return [];
        try {
            const snap = JSON.parse(JSON.stringify(this._viewRecordUi));
            const recs = snap.records;
            if (!recs) return [];
            const recData = Object.values(recs)[0];
            if (!recData?.fields) return [];
            const SKIP = new Set([
                'Id', 'Name', 'RecordTypeId', 'OwnerId', 'IsDeleted',
                'SystemModstamp', 'LastReferencedDate', 'LastViewedDate',
                'CreatedById', 'LastModifiedById', 'LastActivityDate',
                'CurrencyIsoCode', 'CreatedDate', 'LastModifiedDate',
                'CreatedBy', 'LastModifiedBy'
            ]);
            // Only include fields that actually have a displayable value
            const hasValue = (fval) => {
                if (!fval) return false;
                if (fval.displayValue != null) return true;
                if (fval.value == null) return false;
                if (typeof fval.value === 'boolean') return fval.value; // skip false checkboxes
                if (typeof fval.value === 'object') return false;
                return String(fval.value).trim() !== '';
            };
            // Extract fields in page layout order
            const objLayouts = (snap.layouts || {})[recData.apiName] || {};
            const rtKey = Object.keys(objLayouts)[0];
            const viewLayout = rtKey ? objLayouts[rtKey]?.Full?.View : null;
            if (viewLayout?.sections && Array.isArray(viewLayout.sections)) {
                const ordered = [];
                for (const section of viewLayout.sections) {
                    for (const row of (section.layoutRows || [])) {
                        for (const item of (row.layoutItems || [])) {
                            for (const comp of (item.layoutComponents || [])) {
                                const fn = comp.apiName;
                                if (comp.componentType === 'Field' && fn
                                    && !SKIP.has(fn)
                                    && !fn.endsWith('__r')
                                    && hasValue(recData.fields[fn])) {
                                    ordered.push(fn);
                                }
                            }
                        }
                    }
                }
                if (ordered.length > 0) return ordered;
            }
            // Fallback: all non-skipped fields with values
            return Object.keys(recData.fields).filter(
                f => !SKIP.has(f) && !f.endsWith('__r') && hasValue(recData.fields[f])
            );
        } catch(e) {
            return [];
        }
    }

    get hasViewRecordFields() { return this.viewRecordFields.length > 0; }
    get isViewRecordLoading() {
        return !!this._viewRecordId && !this._viewRecordUi && !this._viewRecordUiError;
    }
    get isViewRecordError() {
        return !!this._viewRecordId && !!this._viewRecordUiError;
    }
    get viewRecordErrorMsg() {
        const e = this._viewRecordUiError;
        return (e?.body?.message) || (e?.message) || String(e || '');
    }
    get isViewRecordEmpty() {
        return !!this._viewRecordUi && !this.hasViewRecordFields;
    }

    handleViewRecord(e) {
        this._viewRecordUi      = null; // reset so spinner shows while new record loads
        this._viewRecordId      = e.currentTarget.dataset.id;
        this._viewObjectApiName = e.currentTarget.dataset.obj;
        this._viewObjectLabel   = e.currentTarget.dataset.label;
        this._viewRecordName    = e.currentTarget.dataset.name;
    }

    handleCloseRecordModal() {
        this._viewRecordId      = null;
        this._viewObjectApiName = null;
        this._viewObjectLabel   = null;
        this._viewRecordName    = null;
        this._viewRecordUi      = null;
        this._viewRecordUiError = null;
    }

    get hasRelatedData() { return this.relatedCompGroups.length > 0; }

    // ── Wire: comparison matrix ───────────────────────────────────────────────
    _wiredMatrix;
    @wire(getComparisonMatrix, { ticketId: '$ticketId' })
    wiredMatrix(result) {
        this._wiredMatrix = result;
        this.isLoading = false;
        if (result.data) {
            this._matrix = result.data;
            this._initMasterFromEDA(result.data);
            this.showAllHistory = false;
        } else if (result.error) {
            this._toast(this.i18n.toastErrLoad, result.error.body?.message, 'error');
        }
    }

    @api refreshMatrix() {
        if (this._wiredMatrix) return refreshApex(this._wiredMatrix);
        return Promise.resolve();
    }

    // ── Computed: ticket display ──────────────────────────────────────────────

    get ticket() { return this._ticket || {}; }

    get ticketTypeIcon() {
        const type = this._matrix?.objectType || this.objectType;
        return type === 'Account' ? 'standard:account' : 'standard:contact';
    }

    get objectApiName() {
        return this._matrix?.objectType === 'Account' ? 'Account' : 'Contact';
    }

    get isAccountMerge() { return this._matrix?.objectType === 'Account'; }

    get ticketMatchValue() {
        const key = this._ticket?.Match_Key__c;
        if (!key) return this._ticket?.Name || '…';
        const parts = key.split('|');
        return parts.length >= 3 ? parts.slice(2).join('|') : key;
    }

    get ticketSubtitle() {
        const t = this._ticket;
        if (!t) return '';
        const typeKey = MATCH_TYPE_KEY[t.Match_Type__c];
        const typeLabel = typeKey ? this.i18n[typeKey] : (t.Match_Type__c || '');
        return `${typeLabel} · ${t.Candidate_Count__c || 0} ${this.i18n.records}`;
    }

    get confidenceClass() {
        const map = { High: 'slds-badge slds-badge_success', Medium: 'slds-badge badge-medium', Low: 'slds-badge' };
        return map[this._ticket?.Match_Confidence__c] || 'slds-badge';
    }

    // ── Computed: ignore reason banner ───────────────────────────────────────

    get isIgnoredTicket()     { return this._matrix?.ticketStatus === 'Ignored'; }
    get isClosedTicket()      { return this._matrix?.ticketStatus === 'Closed'; }
    get isMergedTicket()      { return this._matrix?.ticketStatus === 'Merged'; }
    get isErrorTicket()       { return this._matrix?.ticketStatus === 'Error'; }
    get isReopenedTicket()    { return this._matrix?.ticketStatus === 'Reopened'; }
    // Closed or Ignored → footer shows Reopen button instead of Back/Next
    get isReopenableTicket()  { return this.isClosedTicket || this.isIgnoredTicket; }
    // Active tickets (New/Pending/Stale/Reopened/Error) → normal Back/Next/Execute footer
    get isActiveTicket()      { return !this.isMergedTicket && !this.isReopenableTicket; }
    // Terminal = no Exception, no navigation (Merged + Closed + Ignored)
    get isTerminalTicket()    { return this.isMergedTicket || this.isClosedTicket || this.isIgnoredTicket; }
    get ticketErrorMessage()  { return this._matrix?.ticketErrorMessage || ''; }

    // Date of the most-recent Reopened HIST entry (for the Reopened banner)
    get reopenedDate() {
        if (!this.isReopenedTicket) return '';
        return this.ticketHistoryLogs[0]?.date || '';
    }

    // Footer button disabled states
    get isPrevDisabledFull()    { return this.isTerminalTicket || this.isPrevDisabled; }
    get isNextDisabledFull()    { return this.isTerminalTicket || this.isNextDisabled; }
    get isExecuteDisabledFull() { return this.isTerminalTicket || this.isExecuting; }

    // Step progress bar: greyed out for terminal tickets
    get wizStepperClass() {
        return 'wiz-stepper' + (this.isTerminalTicket ? ' wiz-stepper_muted' : '');
    }

    get mergeLogPerformedBy() { return this._matrix?.mergePerformedBy || ''; }

    get mergeLogDate() {
        const raw = this._matrix?.mergePerformedDate;
        if (!raw) return '';
        try {
            const locale = this.lang === 'fr' ? 'fr-CA' : this.lang === 'es' ? 'es' : 'en-CA';
            return new Date(raw).toLocaleString(locale);
        } catch(e) { return raw; }
    }

    get mergeLogMasterName()  { return this._matrix?.mergeMasterName  || ''; }
    get mergeLogLoserNames()  { return this._matrix?.mergeLoserNames  || ''; }

    get undoDaysLeft() {
        const raw = this._matrix?.mergePerformedDate;
        if (!raw) return 0;
        const daysPassed = Math.floor((Date.now() - new Date(raw).getTime()) / 86400000);
        return Math.max(0, 15 - daysPassed);
    }

    get canUndoMerge() { return this.isMergedTicket && this.undoDaysLeft > 0; }

    get undoDaysNote() {
        const t = this.i18n;
        const days = this.undoDaysLeft;
        if (days <= 0) return t.undoWindowExpired || 'Window expired (15 days)';
        return format(t.undoDaysRemaining || '{0} day(s) remaining', days);
    }

    get ignoreReasonLabel() {
        const raw = this._matrix?.ticketClosedReason;
        if (!raw) return '';
        if (raw === 'Other') {
            // Custom reason: first active line of notes holds the reason text
            const notes = this._matrix?.ticketNotes || '';
            const firstLine = notes.split('\n')
                .find(l => l.trim() && !l.startsWith('[DELETED_') && !l.startsWith('[HIST:'));
            return firstLine ? firstLine.trim() : (this.i18n.reasonOtherLong || 'Other');
        }
        const key = CLOSED_REASON_KEY[raw];
        return key ? this.i18n[key] : raw;
    }

    get ignoreNotes() {
        const notes = this._matrix?.ticketNotes;
        if (!notes) return '';
        const raw = this._matrix?.ticketClosedReason;
        const lines = notes.split('\n')
            .filter(l => !l.startsWith('[DELETED_') && !l.startsWith('[HIST:') && !l.startsWith('[CLOSED_ORPHAN|'));
        // Custom reason: first line is the reason label — skip it for notes
        const startIdx = raw === 'Other' && lines.length > 1 ? 1 : 0;
        return lines.slice(startIdx).join('\n').trim();
    }

    get orphanCloseInfo() {
        const notes = this._matrix?.ticketNotes;
        if (!notes) return null;
        const line = notes.split('\n').find(l => l.startsWith('[CLOSED_ORPHAN|'));
        if (!line) return null;
        const tagEnd = line.indexOf(']');
        if (tagEnd < 0) return null;
        const tagParts = line.slice(1, tagEnd).split('|'); // [CLOSED_ORPHAN, recordId, timestamp]
        const description = line.slice(tagEnd + 1).trim();
        return { description, date: tagParts[2] || '' };
    }

    get ticketHistoryLogs() {
        const notes = this._matrix?.ticketNotes;
        if (!notes) return [];
        const t = this.i18n;
        return notes.split('\n')
            .filter(l => l.startsWith('[HIST:'))
            .map((line, idx) => {
                const inner = line.slice(6, line.length - 1);
                const parts  = inner.split('|||');
                const status = parts[0] || '';
                const reason = parts[1] || '';
                const notesDecoded = (parts[2] || '').replace(/\\n/g, '\n');
                const date   = parts[3] || '';
                const reasonKey = CLOSED_REASON_KEY[reason];
                let reasonLabel = reasonKey ? t[reasonKey] : reason;
                let notesDisplay = notesDecoded;
                if (reason === 'Other') {
                    const noteLines = notesDecoded.split('\n');
                    reasonLabel  = noteLines[0] || reasonLabel;
                    notesDisplay = noteLines.slice(1).join('\n').trim();
                }
                const statusLabel = status === 'Ignored'  ? t.tabToValidate
                    : status === 'Closed'   ? t.closedBadge
                    : status === 'Reopened' ? (t.histReopened || 'Reopened')
                    : status === 'Merged'   ? (t.histMerged   || 'Merged')
                    : status === 'Error'    ? (t.histError     || 'Error')
                    : status;
                return { id: `hist_${idx}`, statusLabel, reasonLabel, notes: notesDisplay, date };
            });
    }

    // Index 0 = current state (already shown in the banner) → HISTORY shows only past entries
    get historyDisplayLogs() { return this.ticketHistoryLogs.slice(1); }

    get visibleHistoryLogs() {
        const logs = this.historyDisplayLogs;
        // > 2 past entries: collapse until user expands; ≤ 2: always show
        if (logs.length > 2 && !this.showAllHistory) return [];
        return logs;
    }

    get hasHistory()         { return this.historyDisplayLogs.length > 0; }
    get hasHiddenHistory()   { return this.historyDisplayLogs.length > 2 && !this.showAllHistory; }
    get logShowMoreLabel()   { return this.i18n.logShowMore || '(+) LOGS'; }
    get logShowLessLabel()   { return this.i18n.logShowLess || '(-) LOGS'; }
    get isReopenedWithHistory() {
        const s = this._matrix?.ticketStatus;
        return this.hasHistory && s !== 'Ignored' && s !== 'Closed';
    }

    get by() { return this.i18n.by; }

    // ── Computed: step visibility ─────────────────────────────────────────────

    get showStep1() { return this.currentStep === 1 && !this.isLoading; }
    get showStep2() { return this.currentStep === 2 && !this.isLoading; }
    get showStep3() { return this.currentStep === 3 && !this.isLoading; }

    get isLastStep()    { return this.currentStep === 3; }
    get isPrevDisabled(){ return this.currentStep === 1 || this.isExecuting; }
    get isNextDisabled(){
        if (this.isExecuting) return true;
        if (!this.masterId)   return true;
        if (this.hasMultipleCandidates && this.selectedLoserIds.length === 0) return true;
        return false;
    }

    get hasMultipleCandidates() {
        return (this._matrix?.recordIds?.length || 0) > 2;
    }

    get step1Done() { return this.currentStep > 1; }
    get step2Done() { return this.currentStep > 2; }
    get step1Disabled() { return false; }
    get step2Disabled() { return !this.masterId; }

    get step1CircleClass() {
        const s = this.currentStep;
        if (s > 1)   return 'wiz-circle wiz-circle_done';
        if (s === 1) return 'wiz-circle wiz-circle_active';
        return 'wiz-circle wiz-circle_inactive';
    }
    get step2CircleClass() {
        const s = this.currentStep;
        if (s > 2)   return 'wiz-circle wiz-circle_done';
        if (s === 2) return 'wiz-circle wiz-circle_active';
        return 'wiz-circle wiz-circle_inactive';
    }
    get step3CircleClass() {
        return this.currentStep === 3
            ? 'wiz-circle wiz-circle_active' : 'wiz-circle wiz-circle_inactive';
    }
    get step1LabelClass() {
        const s = this.currentStep;
        if (s > 1)   return 'wiz-label wiz-label_done';
        if (s === 1) return 'wiz-label wiz-label_active';
        return 'wiz-label';
    }
    get step2LabelClass() {
        const s = this.currentStep;
        if (s > 2)   return 'wiz-label wiz-label_done';
        if (s === 2) return 'wiz-label wiz-label_active';
        return 'wiz-label';
    }
    get step3LabelClass() {
        return this.currentStep === 3 ? 'wiz-label wiz-label_active' : 'wiz-label';
    }
    get connector1Class() {
        return this.currentStep > 1 ? 'wiz-connector wiz-connector_done' : 'wiz-connector';
    }
    get connector2Class() {
        return this.currentStep > 2 ? 'wiz-connector wiz-connector_done' : 'wiz-connector';
    }

    // ── Computed: matrix passthrough ─────────────────────────────────────────

    get comparisonMatrix() { return this._matrix; }
    get hasMatrix()        { return !!this._matrix; }

    // ── Computed: multi-candidate banner ─────────────────────────────────────

    get multiDetectedLabel() {
        return format(this.i18n.multiDetectedFmt, this.candidateCards.length);
    }

    // ── Computed: step-1 candidate cards ─────────────────────────────────────

    get candidateCards() {
        if (!this._matrix) return [];
        const total        = this._matrix.recordIds.length;
        const isMulti      = total > 2;
        const savedMaster  = this._matrix.savedMasterId;
        const missingIds   = this._matrix.missingRecordIds || [];
        const isMerged     = missingIds.length > 0;
        const t            = this.i18n;

        return this._matrix.recordIds.map((id, i) => {
            const rc             = this._matrix.relatedCountsByRecordId?.[id]
                                   || { counts: [], totalRelated: 0, hasActiveRecords: false };
            const isMaster       = id === this.masterId;
            const isSelectedLoser = !isMaster && this.selectedLoserIds.includes(id);
            const showLoserToggle = isMulti && !isMaster;
            const isMergedLoser  = missingIds.includes(id);
            const isMergedMaster = isMerged && !!savedMaster && id === savedMaster;

            const keyFieldRows = KEY_FIELD_DEF
                .map(kf => {
                    const row = this._matrix.rows?.find(r => r.fieldApiName === kf.field);
                    const val = row?.valuesByRecordId?.[id];
                    return val ? { label: t[kf.i18nKey] || kf.i18nKey, val } : null;
                })
                .filter(Boolean)
                .slice(0, 5);

            let cardClass = 'slds-card candidate-card';
            if (isMaster)             cardClass += ' candidate-card_selected';
            else if (isSelectedLoser) cardClass += ' candidate-card_loser';

            const colSize  = total === 3 ? 'slds-medium-size_1-of-3' : 'slds-medium-size_1-of-2';
            const colClass = `slds-col slds-size_1-of-1 ${colSize} slds-p-bottom_small`;

            return {
                recordId: id,
                recordName: this._matrix.recordNames[i],
                typeIcon: this._matrix.objectType === 'Account'
                    ? 'standard:account' : 'standard:contact',
                isMaster,
                isSelectedLoser,
                showLoserToggle,
                loserPillLabel: isSelectedLoser ? t.pillIncluded : t.pillMerge,
                loserPillClass: isSelectedLoser
                    ? 'loser-pill loser-pill_selected' : 'loser-pill',
                hasRelatedCounts: rc.counts && rc.counts.length > 0,
                relatedCounts: (rc.counts || []).map(c => ({
                    label:      c.label,
                    total:      c.total || 0,
                    active:     c.active || 0,
                    countClass: c.active > 0
                        ? 'slds-text-heading_small eda-count_active'
                        : 'slds-text-heading_small'
                })),
                keyFieldRows,
                hasActiveEnrollmentWarning: rc.hasActiveRecords,
                cardClass,
                colClass,
                isMergedLoser,
                isMergedMaster
            };
        });
    }

    // ── Computed: step-3 confirmation ─────────────────────────────────────────

    get masterRecordName() {
        if (!this._matrix || !this.masterId) return '';
        const idx = this._matrix.recordIds.indexOf(this.masterId);
        return idx >= 0 ? this._matrix.recordNames[idx] : this.masterId;
    }

    get losingRecordNames() {
        if (!this._matrix) return [];
        const losers = this.hasMultipleCandidates
            ? this.selectedLoserIds
            : this._matrix.recordIds.filter(id => id !== this.masterId);
        return losers.map(id => {
            const idx = this._matrix.recordIds.indexOf(id);
            return this._matrix.recordNames[idx] || id;
        });
    }

    get excludedRecordNames() {
        if (!this._matrix || !this.hasMultipleCandidates) return [];
        return this._matrix.recordIds
            .filter(id => id !== this.masterId && !this.selectedLoserIds.includes(id))
            .map(id => {
                const idx = this._matrix.recordIds.indexOf(id);
                return this._matrix.recordNames[idx] || id;
            });
    }

    get hasCleanedUpTickets() { return !!this.cleanedUpMessage; }
    get hasExcludedRecords()  { return this.excludedRecordNames.length > 0; }

    get hasCustomDecisions() { return this.customDecisionSummary.length > 0; }

    get customDecisionSummary() {
        if (!this._matrix) return [];
        const result = [];
        for (const [fieldName, sourceId] of Object.entries(this.fieldDecisions)) {
            if (sourceId === this.masterId) continue;
            const row = this._matrix.rows?.find(r => r.fieldApiName === fieldName);
            const idx = this._matrix.recordIds.indexOf(sourceId);
            if (row && idx >= 0) {
                result.push({
                    fieldLabel: row.fieldLabel,
                    sourceName: this._matrix.recordNames[idx]
                });
            }
        }
        return result;
    }

    get hasActiveLoserWarning() {
        if (!this._matrix) return false;
        const losers = this.hasMultipleCandidates
            ? this.selectedLoserIds
            : this._matrix.recordIds.filter(id => id !== this.masterId);
        return losers.some(id => this._matrix.relatedCountsByRecordId?.[id]?.hasActiveRecords);
    }

    // ── Computed: label proxies for HTML ─────────────────────────────────────

    get labelClosedReason()  { return this.i18n.labelClosedReason; }

    // ── Navigation handlers ───────────────────────────────────────────────────

    goToStep1() { if (this.currentStep > 1) this.currentStep = 1; }
    goToStep2() { if (this.masterId) this.currentStep = 2; }
    goToNextStep() { if (this.currentStep < 3) this.currentStep += 1; }
    goToPrevStep() { if (this.currentStep > 1) this.currentStep -= 1; }

    // ── Record / Snapshot view modal ─────────────────────────────────────────

    handleNameClick(event) {
        event.stopPropagation();
        const id = event.currentTarget.dataset.id;
        this[NavigationMixin.GenerateUrl]({
            type: 'standard__recordPage',
            attributes: { recordId: id, actionName: 'view' }
        }).then(url => window.open(url, '_blank'));
    }

    handleViewCandidateRecord(event) {
        event.stopPropagation();
        const id   = event.currentTarget.dataset.id;
        const name = event.currentTarget.dataset.name;
        const isMergedLoser = (this._matrix?.missingRecordIds || []).includes(id);
        if (isMergedLoser) {
            this.snapshotLoading   = true;
            this.snapshotData      = null;
            this.showSnapshotModal = true;
            getLoserSnapshotApex({ ticketId: this.ticketId, loserId: id })
                .then(data => {
                    this.snapshotData    = data;
                    this.snapshotLoading = false;
                })
                .catch(err => {
                    this.snapshotLoading   = false;
                    this.showSnapshotModal = false;
                    this._toast(this.i18n.error, err.body?.message || err.message, 'error');
                });
        } else {
            this.recordModalId   = id;
            this.recordModalName = name;
        }
    }

    closeRecordModal() {
        this.recordModalId   = null;
        this.recordModalName = null;
    }

    closeSnapshotModal() {
        this.showSnapshotModal = false;
        this.snapshotData      = null;
        this.snapshotLoading   = false;
    }

    get snapshotModalName() { return this.snapshotData?.recordName || '…'; }

    get snapshotModalCapturedAt() {
        const raw = this.snapshotData?.capturedAt;
        if (!raw) return '';
        try {
            const locale = this.lang === 'fr' ? 'fr-CA' : this.lang === 'es' ? 'es' : 'en-CA';
            return new Date(raw).toLocaleString(locale);
        } catch(e) { return raw; }
    }

    get snapshotModalFields() { return this.snapshotData?.fields || []; }
    get hasSnapshotFields()   { return this.snapshotModalFields.length > 0; }

    // ── Step-1: master/loser selection ────────────────────────────────────────

    handleCardMasterSelect(event) { this._setMaster(event.currentTarget.dataset.id); }

    handleCardLoserToggle(event) {
        event.stopPropagation();
        const recordId = event.currentTarget.dataset.id;
        if (this.selectedLoserIds.includes(recordId)) {
            this.selectedLoserIds = this.selectedLoserIds.filter(id => id !== recordId);
        } else {
            this.selectedLoserIds = [...this.selectedLoserIds, recordId];
        }
    }

    handleMasterChange(event)       { this._setMaster(event.detail.masterId); }
    handleFieldDecisionChange(event) {
        const { fieldName, recordId } = event.detail;
        this.fieldDecisions = { ...this.fieldDecisions, [fieldName]: recordId };
    }

    handleNotesChange(event) { this.mergeNotes = event.detail.value; }

    handleRelatedToggle(event) {
        const recordId = event.currentTarget.dataset.id;
        const checked  = event.target.checked;
        this._relatedDeleteIds = { ...this._relatedDeleteIds, [recordId]: checked };
    }

    // ── Execute merge ─────────────────────────────────────────────────────────

    async executeMerge() {
        if (!this.masterId) return;
        this.isExecuting = true;
        try {
            const masterIdStr = String(this.masterId);
            const ticketIdStr = String(this.ticketId);
            const losingIds = this.hasMultipleCandidates
                ? this.selectedLoserIds.map(id => String(id))
                : this._matrix.recordIds
                    .filter(id => String(id) !== masterIdStr)
                    .map(id => String(id));

            const fieldDecisions = {};
            for (const [field, sourceId] of Object.entries(this.fieldDecisions || {})) {
                if (String(sourceId) !== masterIdStr) {
                    fieldDecisions[field] = String(sourceId);
                }
            }

            // Build relatedDeletesJson from user's delete decisions on loser records
            const deletesByObj = {};
            for (const comp of (this._relatedComparisons || [])) {
                for (const rec of (comp.loserRecords || [])) {
                    if (this._relatedDeleteIds[rec.recordId]) {
                        if (!deletesByObj[comp.apiName]) deletesByObj[comp.apiName] = [];
                        deletesByObj[comp.apiName].push(rec.recordId);
                    }
                }
            }
            const relatedDeletesJson = Object.keys(deletesByObj).length > 0
                ? JSON.stringify(deletesByObj) : null;

            const result = await executeMergeApex({
                ticketId: ticketIdStr,
                masterId: masterIdStr,
                losingIds,
                fieldDecisions,
                notes:              this.mergeNotes || '',
                relatedDeletesJson: relatedDeletesJson
            });

            if (result.success) {
                const cleanedCount = result.cleanedUpTicketCount || 0;
                if (cleanedCount > 0) {
                    const t      = this.i18n;
                    const names  = this.losingRecordNames.join(', ') || '—';
                    const plural = this.losingRecordNames.length > 1;
                    const countWord = cleanedCount === 1
                        ? t.cleanedSingle
                        : format(t.cleanedPluralFmt, cleanedCount);
                    const verb = plural ? t.cleanedVerbPl : t.cleanedVerbSg;
                    const noun = plural ? t.cleanedNounPl : t.cleanedNounSg;
                    this.cleanedUpMessage = format(t.cleanedFmt, countWord, names, verb, noun);
                } else {
                    this.cleanedUpMessage = '';
                }
                // Refresh cache immediately so reopening this tab shows 'Merged' state with undo button.
                if (this._wiredMatrix) await refreshApex(this._wiredMatrix);

                const mergeDetail = {
                    logId: result.logId, mergedRecordId: result.mergedRecordId,
                    ticketId: this.ticketId
                };
                if (result.orphanedContacts && result.orphanedContacts.length > 0) {
                    this._pendingMergeComplete = mergeDetail;
                    this.orphanedContacts      = result.orphanedContacts;
                    this.showOrphanContactModal = true;
                } else if (result.orphanedAccounts && result.orphanedAccounts.length > 0) {
                    this._pendingMergeComplete = mergeDetail;
                    this.orphanedAccounts      = result.orphanedAccounts;
                    this.showOrphanModal       = true;
                } else {
                    this.dispatchEvent(new CustomEvent('mergecomplete', { detail: mergeDetail }));
                }
            } else {
                this._toast(this.i18n.toastErrFusion, result.errorMessage, 'error', 'sticky');
                // Refresh so the ticket shows 'Error' state + error message inline
                if (this._wiredMatrix) await refreshApex(this._wiredMatrix);
            }
        } catch (err) {
            this._toast(this.i18n.error, err.body?.message || err.message, 'error');
            if (this._wiredMatrix) await refreshApex(this._wiredMatrix);
        } finally {
            this.isExecuting = false;
        }
    }

    // ── Undo merge ────────────────────────────────────────────────────────────

    handleUndoConfirmShow() { this.undoConfirmMode = true; }
    handleUndoCancelConfirm() { this.undoConfirmMode = false; }

    async handleUndoMerge() {
        this.undoConfirmMode = false;
        this.isExecuting     = true;
        try {
            await undoMergeApex({ ticketId: this.ticketId });
            this._toast(this.i18n.toastUndoSuccess, this.i18n.toastUndoSuccessMsg, 'success');
            if (this._wiredMatrix) await refreshApex(this._wiredMatrix);
            if (this._wiredRelated) await refreshApex(this._wiredRelated);
            this._relatedDeleteIds = {};
            this.dispatchEvent(new CustomEvent('undocomplete', { detail: { ticketId: this.ticketId } }));
        } catch(err) {
            this._toast(this.i18n.toastUndoError, err.body?.message || err.message, 'error');
        } finally {
            this.isExecuting = false;
        }
    }

    // ── Dismiss modal ─────────────────────────────────────────────────────────

    openDismissModal() {
        this.showDismissModal   = true;
        this.dismissMode        = null;
        this.dismissReason      = null;
        this.dismissNotes       = '';
        this.closeReason        = null;
        this.closeNotes         = '';
        this.newReasonInput       = '';
        this.showAddReasonPopover = false;
        this.dismissError         = null;
        try {
            const stored = localStorage.getItem('mergeManager_customCloseReasons');
            this.customCloseReasons = stored ? JSON.parse(stored) : [];
        } catch(e) { this.customCloseReasons = []; }
    }

    closeDismissModal() { this.showDismissModal = false; }

    handleDismissModeChange(event) {
        this.dismissMode  = event.currentTarget.dataset.mode;
        this.dismissError = null;
    }

    handleDismissReasonChange(event) { this.dismissReason = event.detail.value; }
    handleDismissNotesChange(event)  { this.dismissNotes  = event.detail.value; }
    handleCloseReasonChange(event) {
        const val = event.detail.value;
        if (val === '__add_new__') {
            this.closeReason = null;
            this.newReasonInput = '';
            this.showAddReasonPopover = true;
        } else {
            this.closeReason = val;
        }
    }
    handleCloseNotesChange(event)  { this.closeNotes     = event.detail.value; }
    handleNewReasonInput(event)    { this.newReasonInput = event.target.value; }

    toggleHistory() { this.showAllHistory = !this.showAllHistory; }

    cancelAddReason() {
        this.showAddReasonPopover = false;
        this.newReasonInput = '';
    }

    confirmAddReason() {
        const reason = (this.newReasonInput || '').trim();
        if (!reason || this.customCloseReasons.includes(reason)) return;
        this.customCloseReasons = [...this.customCloseReasons, reason];
        this.closeReason = reason;
        this.newReasonInput = '';
        this.showAddReasonPopover = false;
        try {
            localStorage.setItem('mergeManager_customCloseReasons',
                JSON.stringify(this.customCloseReasons));
        } catch(e) { /* ignore */ }
    }

    async confirmDismiss() {
        const isToValidate = this.dismissMode === 'toValidate';
        const reason = isToValidate ? this.dismissReason : this.closeReason;
        if (!reason) {
            this.dismissError = this.i18n.dismissValidation;
            return;
        }
        this.isDismissing = true;
        this.dismissError = null;
        try {
            if (isToValidate) {
                await dismissTicketApex({
                    ticketId:     this.ticketId,
                    closedReason: this.dismissReason,
                    notes:        this.dismissNotes
                });
            } else {
                const sfReason = CLOSE_REASON_TO_SF[this.closeReason] || 'Other';
                const notes    = CLOSE_REASON_TO_SF[this.closeReason]
                    ? this.closeNotes
                    : [this.closeReason, this.closeNotes].filter(Boolean).join('\n');
                await closeTicketApex({
                    ticketId:     this.ticketId,
                    closedReason: sfReason,
                    notes:        notes
                });
            }
            this.showDismissModal = false;
            // Refresh the wire cache so the banner shows immediately and future opens
            // get fresh data — without this, cacheable=true returns stale 'New' status.
            if (this._wiredMatrix) await refreshApex(this._wiredMatrix);
            const newStatus = isToValidate ? 'Ignored' : 'Closed';
            this.dispatchEvent(new CustomEvent('dismissed', { detail: { ticketId: this.ticketId, status: newStatus } }));
        } catch (err) {
            const msg = err.body?.message || err.message || String(err);
            this.dismissError = msg;
            this.dispatchEvent(new ShowToastEvent({ title: this.i18n.error, message: msg, variant: 'error' }));
        } finally {
            this.isDismissing = false;
        }
    }

    // ── Reopen from inside the wizard (Closed / Ignored footer button) ───────

    async handleReopenFromWizard() {
        if (this.isReopening) return;
        this.isReopening = true;
        try {
            await reopenTicketApex({ ticketId: this.ticketId });
            if (this._wiredMatrix) await refreshApex(this._wiredMatrix);
            this.dispatchEvent(new CustomEvent('ticketreopened', {
                detail: { ticketId: this.ticketId }, bubbles: true, composed: true
            }));
            this.dispatchEvent(new ShowToastEvent({
                title: this.i18n.toastTicketReopened || 'Ticket reopened',
                variant: 'success'
            }));
        } catch (err) {
            const msg = err.body?.message || err.message || String(err);
            this.dispatchEvent(new ShowToastEvent({ title: this.i18n.error || 'Error', message: msg, variant: 'error' }));
        } finally {
            this.isReopening = false;
        }
    }

    // ── Orphaned Account handlers ─────────────────────────────────────────────

    closeOrphanModal() {
        this.showOrphanModal = false;
        if (this._pendingMergeComplete) {
            this.dispatchEvent(new CustomEvent('mergecomplete',
                { detail: this._pendingMergeComplete }));
            this._pendingMergeComplete = null;
        }
    }

    async handleDeleteOrphanedAccount(event) {
        const accountId   = event.currentTarget.dataset.id;
        const accountName = this.orphanedAccounts.find(a => a.accountId === accountId)?.accountName;
        this.isDeletingAccount = true;
        try {
            await deleteOrphanedAccountApex({ accountId, ticketId: this.ticketId, accountName: accountName || '' });
            this.orphanedAccounts = this.orphanedAccounts.filter(a => a.accountId !== accountId);
            if (this._wiredDeletedAccounts) refreshApex(this._wiredDeletedAccounts);
            if (this.orphanedAccounts.length === 0) this.closeOrphanModal();
        } catch (err) {
            this._toast(this.i18n.toastErrDelete, err.body?.message || err.message, 'error');
        } finally {
            this.isDeletingAccount = false;
        }
    }

    async handleRestoreAccount(event) {
        const accountId = event.currentTarget.dataset.id;
        try {
            await restoreDeletedAccountApex({ accountId, ticketId: this.ticketId });
            if (this._wiredDeletedAccounts) refreshApex(this._wiredDeletedAccounts);
            this._toast(this.i18n.toastAccountRestored, this.i18n.toastAccountRestoredMsg, 'success');
        } catch (err) {
            this._toast(this.i18n.toastErrRestore, err.body?.message || err.message, 'error');
        }
    }

    // ── Orphaned Contact handlers ─────────────────────────────────────────────

    closeOrphanContactModal() {
        this.showOrphanContactModal = false;
        if (this._pendingMergeComplete) {
            this.dispatchEvent(new CustomEvent('mergecomplete',
                { detail: this._pendingMergeComplete }));
            this._pendingMergeComplete = null;
        }
    }

    async handleDeleteOrphanedContact(event) {
        const contactId   = event.currentTarget.dataset.id;
        const contactName = this.orphanedContacts.find(c => c.contactId === contactId)?.contactName;
        this.isDeletingContact = true;
        try {
            await deleteOrphanedContactApex({ contactId, ticketId: this.ticketId, contactName: contactName || '' });
            this.orphanedContacts = this.orphanedContacts.filter(c => c.contactId !== contactId);
            if (this._wiredDeletedContacts) refreshApex(this._wiredDeletedContacts);
            if (this.orphanedContacts.length === 0) this.closeOrphanContactModal();
        } catch (err) {
            this._toast(this.i18n.toastErrDelete, err.body?.message || err.message, 'error');
        } finally {
            this.isDeletingContact = false;
        }
    }

    async handleRestoreContact(event) {
        const contactId = event.currentTarget.dataset.id;
        try {
            await restoreDeletedContactApex({ contactId, ticketId: this.ticketId });
            if (this._wiredDeletedContacts) refreshApex(this._wiredDeletedContacts);
            this._toast(this.i18n.toastContactRestored, this.i18n.toastContactRestoredMsg, 'success');
        } catch (err) {
            this._toast(this.i18n.toastErrRestore, err.body?.message || err.message, 'error');
        }
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    _setMaster(newMasterId) {
        this.masterId = newMasterId;
        const total = this._matrix?.recordIds?.length || 0;
        if (total <= 2) {
            this.selectedLoserIds = (this._matrix?.recordIds || [])
                .filter(id => id !== newMasterId);
        } else {
            this.selectedLoserIds = this.selectedLoserIds.filter(id => id !== newMasterId);
        }
        const reset = {};
        if (this._matrix?.rows) {
            for (const row of this._matrix.rows) {
                reset[row.fieldApiName] = newMasterId;
            }
        }
        this.fieldDecisions = reset;
    }

    _initMasterFromEDA(matrix) {
        if (!matrix?.recordIds?.length) return;
        let bestId    = matrix.recordIds[0];
        let bestScore = -1;
        for (const id of matrix.recordIds) {
            const rc     = matrix.relatedCountsByRecordId?.[id] || {};
            const active = (rc.counts || []).reduce((s, c) => s + (c.active || 0), 0);
            const score  = (rc.totalRelated || 0) * 10 + active * 5;
            if (score > bestScore) { bestScore = score; bestId = id; }
        }
        this._setMaster(bestId);
    }

    _toast(title, message, variant, mode = 'dismissible') {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant, mode }));
    }
}
