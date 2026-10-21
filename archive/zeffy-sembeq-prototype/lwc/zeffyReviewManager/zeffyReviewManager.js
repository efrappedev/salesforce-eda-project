import { LightningElement, track } from 'lwc';
import getTickets     from '@salesforce/apex/ZeffyDonationService.getTickets';
import resolveCreate  from '@salesforce/apex/ZeffyDonationService.resolveCreateNew';
import resolveLink    from '@salesforce/apex/ZeffyDonationService.resolveLinkExisting';
import skipTicket     from '@salesforce/apex/ZeffyDonationService.skipTicket';

const FMT_CAD = new Intl.NumberFormat('fr-CA', { style: 'currency', currency: 'CAD' });
const FMT_DATE = new Intl.DateTimeFormat('fr-CA', { year: 'numeric', month: 'short', day: 'numeric' });

function fmtAmt(val) { return val != null ? FMT_CAD.format(val) : '—'; }
function fmtDate(s) {
    if (!s) return '—';
    try { return FMT_DATE.format(new Date(s)); } catch (e) { return s; }
}
function badgeClass(status) {
    const m = {
        'Pending Review': 'zrm-badge zrm-badge--pending',
        'Error':          'zrm-badge zrm-badge--error',
        'Skipped':        'zrm-badge zrm-badge--skipped',
    };
    return m[status] || 'zrm-badge zrm-badge--resolved';
}
function enrichTicket(t) {
    return {
        ...t,
        _fullName:      [t.First_Name__c, t.Last_Name__c].filter(Boolean).join(' ') || t.Email__c || t.Name,
        _amountStr:     fmtAmt(t.Amount__c),
        _eligibleStr:   fmtAmt(t.Eligible_Amount__c),
        _netStr:        fmtAmt(t.Net_Amount__c),
        _dateStr:       fmtDate(t.Gift_Date__c),
        _addressStr:    [t.Address__c, t.City__c, t.Province__c, t.Postal_Code__c, t.Country__c].filter(Boolean).join(', '),
        _badgeClass:    badgeClass(t.Status__c),
        _recurringLabel: t.Is_Recurring__c ? 'Sí' : 'No',
        _rowClass:      'zrm-row' + (t.Status__c === 'Pending Review' ? ' zrm-row--pending' : ''),
    };
}

const DONOR_LABELS = {
    individual: '👤 Persona individual',
    eglise:     '⛪ Iglesia',
    org:        '🏢 Organización',
};

export default class ZeffyReviewManager extends LightningElement {
    @track tickets           = [];
    @track selectedTicket    = null;
    @track statusFilter      = 'Pending Review';
    @track isLoading         = false;

    // action flow state
    @track showMainButtons    = true;
    @track showDonorTypeSelect = false;
    @track showNotesInput      = false;
    @track showSearch          = false;

    @track donorType          = 'individual';
    @track resolutionNotes    = '';
    @track selectedRecordId   = null;
    @track isResolving        = false;
    @track actionError        = '';

    connectedCallback() { this.loadTickets(); }

    // ── getters ──────────────────────────────────────────────────────
    get isPending()  { return this.selectedTicket && this.selectedTicket.Status__c === 'Pending Review'; }
    get isResolved() { return this.selectedTicket && this.selectedTicket.Status__c !== 'Pending Review'; }
    get isLinkDisabled()     { return !this.selectedRecordId; }
    get confirmCreateLabel() { return this.isResolving ? 'Procesando…' : 'Confirmar — crear registro'; }
    get donorTypeLabel()     { return DONOR_LABELS[this.donorType] || ''; }
    get filterLabel() {
        return this.statusFilter === 'All' ? '' : ` con estado "${this.statusFilter}"`;
    }

    // ── data ─────────────────────────────────────────────────────────
    loadTickets() {
        this.isLoading = true;
        const filter = this.statusFilter === 'All' ? null : this.statusFilter;
        getTickets({ statusFilter: filter })
            .then(raw => {
                this.tickets   = (raw || []).map(enrichTicket);
                this.isLoading = false;
                if (this.selectedTicket) {
                    const updated = this.tickets.find(t => t.Id === this.selectedTicket.Id);
                    this.selectedTicket = updated || null;
                }
            })
            .catch(err => { this.isLoading = false; console.error(err); });
    }

    // ── list ─────────────────────────────────────────────────────────
    handleFilterChange(evt) {
        this.statusFilter   = evt.target.value;
        this.selectedTicket = null;
        this.resetActionState();
        this.loadTickets();
    }

    handleSelectTicket(evt) {
        const id = evt.currentTarget.dataset.id;
        this.selectedTicket = this.tickets.find(t => t.Id === id) || null;
        this.resetActionState();
    }

    // ── Create-new flow (2 steps) ─────────────────────────────────────
    handleCreateNew() {
        this.showMainButtons     = false;
        this.showDonorTypeSelect = true;
        this.showNotesInput      = false;
        this.showSearch          = false;
        this.donorType           = 'individual';
        this.actionError         = '';
    }

    handleDonorTypeChange(evt) { this.donorType = evt.target.value; }

    handleConfirmDonorType() {
        this.showDonorTypeSelect = false;
        this.showNotesInput      = true;
    }

    handleBackToDonorType() {
        this.showNotesInput      = false;
        this.showDonorTypeSelect = true;
    }

    handleConfirmCreate() {
        if (!this.selectedTicket) return;
        this.isResolving = true;
        this.actionError = '';
        resolveCreate({
            ticketId:     this.selectedTicket.Id,
            donorType:    this.donorType,
            notes:        this.resolutionNotes
        })
        .then(() => { this.isResolving = false; this.resetActionState(); this.loadTickets(); })
        .catch(err => {
            this.isResolving = false;
            this.actionError = (err.body && err.body.message) ? err.body.message : String(err);
        });
    }

    // ── Link-existing flow ────────────────────────────────────────────
    handleShowSearch() {
        this.showMainButtons   = false;
        this.showSearch        = true;
        this.selectedRecordId  = null;
        this.actionError       = '';
    }

    handleCancelSearch() { this.resetActionState(); }

    handleRecordPick(evt) { this.selectedRecordId = evt.detail.recordId || null; }

    handleConfirmLink() {
        if (!this.selectedTicket || !this.selectedRecordId) return;
        this.isResolving = true;
        this.actionError = '';
        resolveLink({
            ticketId:  this.selectedTicket.Id,
            contactId: this.selectedRecordId,
            notes:     this.resolutionNotes
        })
        .then(() => { this.isResolving = false; this.resetActionState(); this.loadTickets(); })
        .catch(err => {
            this.isResolving = false;
            this.actionError = (err.body && err.body.message) ? err.body.message : String(err);
        });
    }

    // ── Skip ──────────────────────────────────────────────────────────
    handleSkip() {
        if (!this.selectedTicket) return;
        skipTicket({ ticketId: this.selectedTicket.Id, reason: 'Omitido manualmente por el staff' })
            .then(() => this.loadTickets())
            .catch(err => { this.actionError = (err.body && err.body.message) ? err.body.message : String(err); });
    }

    // ── Misc ──────────────────────────────────────────────────────────
    handleNotesInput(evt)   { this.resolutionNotes = evt.target.value; }
    handleCancelAction()    { this.resetActionState(); }

    resetActionState() {
        this.showMainButtons     = true;
        this.showDonorTypeSelect = false;
        this.showNotesInput      = false;
        this.showSearch          = false;
        this.donorType           = 'individual';
        this.selectedRecordId    = null;
        this.resolutionNotes     = '';
        this.isResolving         = false;
        this.actionError         = '';
    }
}
