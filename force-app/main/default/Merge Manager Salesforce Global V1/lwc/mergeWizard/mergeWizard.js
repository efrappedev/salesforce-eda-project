import { LightningElement, api, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import { getLabels, format } from 'c/i18n';
import getComparisonMatrix            from '@salesforce/apex/MergeController.getComparisonMatrix';
import getLoserSnapshotApex           from '@salesforce/apex/MergeController.getLoserSnapshot';
import executeMergeApex               from '@salesforce/apex/MergeController.executeMerge';
import dismissTicketApex              from '@salesforce/apex/MergeController.dismissTicket';
import closeTicketApex                from '@salesforce/apex/MergeController.closeTicket';
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

    // ── Wizard state ─────────────────────────────────────────────────────────
    @track currentStep       = 1;
    @track masterId          = null;
    @track selectedLoserIds  = [];
    @track fieldDecisions    = {};
    @track mergeNotes        = '';
    @track isLoading         = false;
    @track isExecuting       = false;

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

    // ── Record view modal ────────────────────────────────────────────────────
    @track showRecordModal  = false;
    @track recordModalId    = null;
    @track recordModalName  = null;

    // ── Snapshot view modal ──────────────────────────────────────────────────
    @track showSnapshotModal  = false;
    @track snapshotLoading    = false;
    @track snapshotData       = null;

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

    get hasDeletedAccounts() { return this.deletedAccounts.length > 0; }

    @wire(getDeletedContactsForTicketApex, { ticketId: '$ticketId' })
    wiredDeletedContacts(result) {
        this._wiredDeletedContacts = result;
        if (result.data) this.deletedContacts = result.data;
    }

    get hasDeletedContacts() { return this.deletedContacts.length > 0; }

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
        return this._matrix?.objectType === 'Account'
            ? 'standard:account' : 'standard:contact';
    }

    get objectApiName() {
        return this._matrix?.objectType === 'Account' ? 'Account' : 'Contact';
    }

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

    get isIgnoredTicket() { return this._matrix?.ticketStatus === 'Ignored'; }
    get isClosedTicket()  { return this._matrix?.ticketStatus === 'Closed'; }
    get isMergedTicket()  { return this._matrix?.ticketStatus === 'Merged'; }

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
            .filter(l => !l.startsWith('[DELETED_') && !l.startsWith('[HIST:'));
        // Custom reason: first line is the reason label — skip it for notes
        const startIdx = raw === 'Other' && lines.length > 1 ? 1 : 0;
        return lines.slice(startIdx).join('\n').trim();
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
                const statusLabel = status === 'Ignored' ? t.tabToValidate
                    : status === 'Closed' ? t.closedBadge : status;
                return { id: `hist_${idx}`, statusLabel, reasonLabel, notes: notesDisplay, date };
            });
    }

    get visibleHistoryLogs() {
        const logs = this.ticketHistoryLogs;
        // > 2 logs: collapse all until user expands; ≤ 2 logs: always show
        if (logs.length > 2 && !this.showAllHistory) return [];
        return logs;
    }

    get hasHistory()         { return this.ticketHistoryLogs.length > 0; }
    get hasHiddenHistory()   { return this.ticketHistoryLogs.length > 2 && !this.showAllHistory; }
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

    handleViewRecord(event) {
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
            this.showRecordModal = true;
        }
    }

    closeRecordModal() {
        this.showRecordModal = false;
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

            const result = await executeMergeApex({
                ticketId: ticketIdStr,
                masterId: masterIdStr,
                losingIds,
                fieldDecisions,
                notes: this.mergeNotes || ''
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
            }
        } catch (err) {
            this._toast(this.i18n.error, err.body?.message || err.message, 'error');
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
