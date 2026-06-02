import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getComparisonMatrix            from '@salesforce/apex/MergeController.getComparisonMatrix';
import executeMergeApex               from '@salesforce/apex/MergeController.executeMerge';
import dismissTicketApex              from '@salesforce/apex/MergeController.dismissTicket';
import deleteOrphanedAccountApex       from '@salesforce/apex/MergeController.deleteOrphanedAccount';
import restoreDeletedAccountApex       from '@salesforce/apex/MergeController.restoreDeletedAccount';
import getDeletedAccountsForTicketApex from '@salesforce/apex/MergeController.getDeletedAccountsForTicket';
import deleteOrphanedContactApex       from '@salesforce/apex/MergeController.deleteOrphanedContact';
import restoreDeletedContactApex       from '@salesforce/apex/MergeController.restoreDeletedContact';
import getDeletedContactsForTicketApex from '@salesforce/apex/MergeController.getDeletedContactsForTicket';

// Key fields shown on Step-1 candidate cards (label -> fieldApiName)
const KEY_FIELD_MAP = [
    { label: 'Courriel',   field: 'Email'       },
    { label: 'Téléphone',  field: 'Phone'        },
    { label: 'Mobile',     field: 'MobilePhone'  },
    { label: 'Compte',     field: 'AccountId'    },
    { label: 'ID Contact', field: 'ID_Contact__c'},
    { label: 'Propriét.',  field: 'OwnerId'      }
];

const CLOSED_REASON_OPTIONS = [
    { label: 'Faux positif — Même domicile',     value: 'False Positive - Same Household' },
    { label: 'Faux positif — Même organisation', value: 'False Positive - Same Organization' },
    { label: 'Faux positif — Tél. partagé',      value: 'False Positive - Shared Phone' },
    { label: 'Faux positif — Courriel partagé',  value: 'False Positive - Shared Email' },
    { label: 'Déjà résolu manuellement',          value: 'Already Resolved' },
    { label: 'Hors périmètre',                   value: 'Out of Scope' },
    { label: 'Autre (voir Notes)',               value: 'Other' }
];

export default class MergeWizard extends LightningElement {
    @api ticketId;

    // ── Wizard state ─────────────────────────────────────────────────────────
    @track currentStep       = 1;
    @track masterId          = null;
    @track selectedLoserIds  = [];   // explicitly selected losers (supports 3+ candidates)
    @track fieldDecisions    = {};   // { fieldApiName: sourceRecordId }
    @track mergeNotes        = '';
    @track isLoading         = false;
    @track isExecuting       = false;

    // ── Dismiss modal state ──────────────────────────────────────────────────
    @track showDismissModal = false;
    @track dismissReason    = null;
    @track dismissNotes     = '';
    @track dismissError     = null;
    @track isDismissing     = false;

    // ── Orphaned Account modal state ─────────────────────────────────────────
    @track showOrphanModal    = false;
    @track orphanedAccounts   = [];
    @track isDeletingAccount  = false;
    _pendingMergeComplete     = null;

    // ── Deleted accounts (for restore) ───────────────────────────────────────
    _wiredDeletedAccounts;
    @track deletedAccounts    = [];

    // ── Orphaned Contact modal state (Account merges) ─────────────────────────
    @track showOrphanContactModal = false;
    @track orphanedContacts       = [];
    @track isDeletingContact      = false;

    // ── Deleted contacts (for restore) ───────────────────────────────────────
    _wiredDeletedContacts;
    @track deletedContacts        = [];

    // ── Data ─────────────────────────────────────────────────────────────────
    @track _matrix  = null;
    @track _ticket  = null;

    closedReasonOptions = CLOSED_REASON_OPTIONS;

    // ── Wire: deleted accounts log ────────────────────────────────────────────
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

    // ── Wire: load comparison matrix on ticketId change ──────────────────────
    @wire(getComparisonMatrix, { ticketId: '$ticketId' })
    wiredMatrix({ error, data }) {
        this.isLoading = false;
        if (data) {
            this._matrix = data;
            this._initMasterFromEDA(data);
        } else if (error) {
            this._toast('Erreur chargement', error.body?.message, 'error');
        }
    }

    // ── Computed: ticket display ──────────────────────────────────────────────

    get ticket() { return this._ticket || {}; }

    get ticketTypeIcon() {
        return this._matrix?.objectType === 'Account'
            ? 'standard:account' : 'standard:contact';
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
        return `${t.Match_Type__c || ''} · ${t.Candidate_Count__c || 0} enregistrements`;
    }

    get confidenceClass() {
        const map = { High: 'slds-badge slds-badge_success', Medium: 'slds-badge badge-medium', Low: 'slds-badge' };
        return map[this._ticket?.Match_Confidence__c] || 'slds-badge';
    }

    // ── Computed: step visibility ─────────────────────────────────────────────

    get showStep1() { return this.currentStep === 1 && !this.isLoading; }
    get showStep2() { return this.currentStep === 2 && !this.isLoading; }
    get showStep3() { return this.currentStep === 3 && !this.isLoading; }

    get isLastStep()    { return this.currentStep === 3; }
    get isPrevDisabled(){ return this.currentStep === 1 || this.isExecuting; }
    get isNextDisabled(){
        if (this.isExecuting) return true;
        if (!this.masterId)   return true;
        // For 3+ candidates the user must explicitly select at least one loser
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
        if (s > 1)  return 'wiz-circle wiz-circle_done';
        if (s === 1) return 'wiz-circle wiz-circle_active';
        return 'wiz-circle wiz-circle_inactive';
    }
    get step2CircleClass() {
        const s = this.currentStep;
        if (s > 2)  return 'wiz-circle wiz-circle_done';
        if (s === 2) return 'wiz-circle wiz-circle_active';
        return 'wiz-circle wiz-circle_inactive';
    }
    get step3CircleClass() {
        return this.currentStep === 3
            ? 'wiz-circle wiz-circle_active' : 'wiz-circle wiz-circle_inactive';
    }
    get step1LabelClass() {
        const s = this.currentStep;
        if (s > 1)  return 'wiz-label wiz-label_done';
        if (s === 1) return 'wiz-label wiz-label_active';
        return 'wiz-label';
    }
    get step2LabelClass() {
        const s = this.currentStep;
        if (s > 2)  return 'wiz-label wiz-label_done';
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

    // ── Computed: comparison matrix passthrough ───────────────────────────────

    get comparisonMatrix() { return this._matrix; }
    get hasMatrix()        { return !!this._matrix; }

    // ── Computed: step-1 candidate cards ─────────────────────────────────────

    get candidateCards() {
        if (!this._matrix) return [];
        const total        = this._matrix.recordIds.length;
        const isMulti      = total > 2;
        const savedMaster  = this._matrix.savedMasterId;
        const missingIds   = this._matrix.missingRecordIds || [];
        const isMerged     = missingIds.length > 0;
        return this._matrix.recordIds.map((id, i) => {
            const eda            = this._matrix.edaCountsByRecordId?.[id] || {};
            const isMaster       = id === this.masterId;
            const isSelectedLoser = !isMaster && this.selectedLoserIds.includes(id);
            const showLoserToggle = isMulti && !isMaster;
            const isMergedLoser  = missingIds.includes(id);
            const isMergedMaster = isMerged && !!savedMaster && id === savedMaster;

            const keyFieldRows = KEY_FIELD_MAP
                .map(kf => {
                    const row = this._matrix.rows?.find(r => r.fieldApiName === kf.field);
                    const val = row?.valuesByRecordId?.[id];
                    return val ? { label: kf.label, val } : null;
                })
                .filter(Boolean)
                .slice(0, 5);

            let cardClass = 'slds-card candidate-card';
            if (isMaster)             cardClass += ' candidate-card_selected';
            else if (isSelectedLoser) cardClass += ' candidate-card_loser';

            // 3-column grid for exactly 3 records, 2-column otherwise
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
                loserPillLabel: isSelectedLoser ? '✓ Inclus' : '+ Fusionner',
                loserPillClass: isSelectedLoser
                    ? 'loser-pill loser-pill_selected' : 'loser-pill',
                edaCounts: eda,
                keyFieldRows,
                hasActiveEnrollmentWarning: eda.hasActiveEnrollments,
                cardClass,
                colClass,
                isMergedLoser,
                isMergedMaster,
                courseClass:  eda.activeCourseConnections > 0
                    ? 'slds-text-heading_small eda-count_active' : 'slds-text-heading_small',
                programClass: eda.activeProgramEnrollments > 0
                    ? 'slds-text-heading_small eda-count_active' : 'slds-text-heading_small'
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

    get hasExcludedRecords() { return this.excludedRecordNames.length > 0; }

    get hasCustomDecisions() {
        return this.customDecisionSummary.length > 0;
    }

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
        return losers.some(id => this._matrix.edaCountsByRecordId?.[id]?.hasActiveEnrollments);
    }

    // ── Navigation handlers ───────────────────────────────────────────────────

    goToStep1() { if (this.currentStep > 1) this.currentStep = 1; }
    goToStep2() { if (this.masterId) this.currentStep = 2; }

    goToNextStep() {
        if (this.currentStep < 3) this.currentStep += 1;
    }

    goToPrevStep() {
        if (this.currentStep > 1) this.currentStep -= 1;
    }

    // ── Step-1: master selection via card click ────────────────────────────────

    handleCardMasterSelect(event) {
        const newMasterId = event.currentTarget.dataset.id;
        this._setMaster(newMasterId);
    }

    // ── Step-1: loser toggle (3+ candidates only) ─────────────────────────────

    handleCardLoserToggle(event) {
        event.stopPropagation(); // don't trigger the master-select click on the card
        const recordId = event.currentTarget.dataset.id;
        if (this.selectedLoserIds.includes(recordId)) {
            this.selectedLoserIds = this.selectedLoserIds.filter(id => id !== recordId);
        } else {
            this.selectedLoserIds = [...this.selectedLoserIds, recordId];
        }
    }

    // ── Step-2: master change from matrix column radio ────────────────────────

    handleMasterChange(event) {
        this._setMaster(event.detail.masterId);
    }

    // ── Step-2: individual field decision ─────────────────────────────────────

    handleFieldDecisionChange(event) {
        const { fieldName, recordId } = event.detail;
        // Spread to trigger reactivity in child (fieldDecisions is @api in child)
        this.fieldDecisions = { ...this.fieldDecisions, [fieldName]: recordId };
    }

    // ── Step-3: notes ─────────────────────────────────────────────────────────

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

            // Only send overrides (where user chose a non-master source).
            // applyFieldDecisions already skips master-to-master entries, but
            // sending all __c fields bloats the payload and can break Apex deserialization.
            const fieldDecisions = {};
            for (const [field, sourceId] of Object.entries(this.fieldDecisions || {})) {
                if (String(sourceId) !== masterIdStr) {
                    fieldDecisions[field] = String(sourceId);
                }
            }

            const result = await executeMergeApex({
                ticketId:       ticketIdStr,
                masterId:       masterIdStr,
                losingIds,
                fieldDecisions,
                notes:          this.mergeNotes || ''
            });

            if (result.success) {
                const mergeDetail = {
                    logId: result.logId, mergedRecordId: result.mergedRecordId,
                    ticketId: this.ticketId
                };
                if (result.orphanedContacts && result.orphanedContacts.length > 0) {
                    this._pendingMergeComplete  = mergeDetail;
                    this.orphanedContacts        = result.orphanedContacts;
                    this.showOrphanContactModal  = true;
                } else if (result.orphanedAccounts && result.orphanedAccounts.length > 0) {
                    this._pendingMergeComplete = mergeDetail;
                    this.orphanedAccounts      = result.orphanedAccounts;
                    this.showOrphanModal       = true;
                } else {
                    this.dispatchEvent(new CustomEvent('mergecomplete', { detail: mergeDetail }));
                }
            } else {
                this._toast('Erreur fusion', result.errorMessage, 'error', 'sticky');
            }
        } catch (err) {
            this._toast('Erreur', err.body?.message || err.message, 'error');
        } finally {
            this.isExecuting = false;
        }
    }

    // ── Dismiss modal handlers ────────────────────────────────────────────────

    openDismissModal()  { this.showDismissModal = true; this.dismissError = null; }
    closeDismissModal() { this.showDismissModal = false; }

    handleDismissReasonChange(event) { this.dismissReason = event.detail.value; }
    handleDismissNotesChange(event)  { this.dismissNotes  = event.detail.value; }

    async confirmDismiss() {
        if (!this.dismissReason) {
            this.dismissError = 'Veuillez sélectionner une raison.';
            return;
        }
        this.isDismissing = true;
        this.dismissError = null;
        try {
            await dismissTicketApex({
                ticketId:     this.ticketId,
                closedReason: this.dismissReason,
                notes:        this.dismissNotes
            });
            this.showDismissModal = false;
            this.dispatchEvent(new CustomEvent('dismissed', { detail: { ticketId: this.ticketId } }));
        } catch (err) {
            this.dismissError = err.body?.message || err.message;
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
            await deleteOrphanedAccountApex({
                accountId,
                ticketId:    this.ticketId,
                accountName: accountName || ''
            });
            this.orphanedAccounts = this.orphanedAccounts.filter(
                a => a.accountId !== accountId
            );
            if (this._wiredDeletedAccounts) refreshApex(this._wiredDeletedAccounts);
            if (this.orphanedAccounts.length === 0) {
                this.closeOrphanModal();
            }
        } catch (err) {
            this._toast('Erreur suppression', err.body?.message || err.message, 'error');
        } finally {
            this.isDeletingAccount = false;
        }
    }

    async handleRestoreAccount(event) {
        const accountId = event.currentTarget.dataset.id;
        try {
            await restoreDeletedAccountApex({ accountId, ticketId: this.ticketId });
            if (this._wiredDeletedAccounts) refreshApex(this._wiredDeletedAccounts);
            this._toast('Compte restauré', 'Le compte a été restauré dans la corbeille.', 'success');
        } catch (err) {
            this._toast('Erreur restauration', err.body?.message || err.message, 'error');
        }
    }

    // ── Orphaned Contact handlers (Account merges) ────────────────────────────

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
            await deleteOrphanedContactApex({
                contactId,
                ticketId:    this.ticketId,
                contactName: contactName || ''
            });
            this.orphanedContacts = this.orphanedContacts.filter(c => c.contactId !== contactId);
            if (this._wiredDeletedContacts) refreshApex(this._wiredDeletedContacts);
            if (this.orphanedContacts.length === 0) this.closeOrphanContactModal();
        } catch (err) {
            this._toast('Erreur suppression', err.body?.message || err.message, 'error');
        } finally {
            this.isDeletingContact = false;
        }
    }

    async handleRestoreContact(event) {
        const contactId = event.currentTarget.dataset.id;
        try {
            await restoreDeletedContactApex({ contactId, ticketId: this.ticketId });
            if (this._wiredDeletedContacts) refreshApex(this._wiredDeletedContacts);
            this._toast('Contact restauré', 'Le contact a été restauré.', 'success');
        } catch (err) {
            this._toast('Erreur restauration', err.body?.message || err.message, 'error');
        }
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    /**
     * When master changes, reset all field decisions to point to the new master.
     * The user can then override individual rows in Step 2.
     */
    _setMaster(newMasterId) {
        this.masterId = newMasterId;

        const total = this._matrix?.recordIds?.length || 0;
        if (total <= 2) {
            // Two records: auto-set the other one as the loser
            this.selectedLoserIds = (this._matrix?.recordIds || [])
                .filter(id => id !== newMasterId);
        } else {
            // 3+ records: remove the new master from the loser set (can't be both)
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

    /**
     * Auto-select the master as the record with the most total EDA-related records.
     * Falls back to the first record if EDA is not available.
     */
    _initMasterFromEDA(matrix) {
        if (!matrix?.recordIds?.length) return;
        let bestId    = matrix.recordIds[0];
        let bestScore = -1;
        for (const id of matrix.recordIds) {
            const eda   = matrix.edaCountsByRecordId?.[id] || {};
            const score = (eda.totalRelatedRecords || 0) * 10
                        + (eda.activeCourseConnections || 0) * 5
                        + (eda.activeProgramEnrollments || 0) * 5;
            if (score > bestScore) { bestScore = score; bestId = id; }
        }
        this._setMaster(bestId);
    }

    _toast(title, message, variant, mode = 'dismissible') {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant, mode }));
    }
}
