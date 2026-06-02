import { LightningElement, api, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getTickets from '@salesforce/apex/MergeController.getTickets';

// ── Badge class maps ──────────────────────────────────────────────────────────

const CONFIDENCE_CLASS = {
    High:   'slds-badge ticket-badge ticket-badge_high',
    Medium: 'slds-badge ticket-badge ticket-badge_medium',
    Low:    'slds-badge ticket-badge ticket-badge_low'
};
const STATUS_CLASS = {
    'New':       'slds-badge ticket-badge ticket-badge_new',
    'In Review': 'slds-badge ticket-badge ticket-badge_review',
    'Ready':     'slds-badge ticket-badge ticket-badge_ready',
    'Merged':    'slds-badge ticket-badge ticket-badge_merged',
    'Ignored':   'slds-badge ticket-badge ticket-badge_ignored',
    'Error':     'slds-badge ticket-badge ticket-badge_error'
};
const MATCH_TYPE_LABEL = {
    Email: 'Courriel', Phone: 'Téléphone', Name: 'Nom', Mixed: 'Mixte'
};

export default class MergeTicketList extends LightningElement {
    @api selectedTicketId;

    @track objectTypeFilter = 'Contact';
    @track statusFilter     = 'All';
    @track searchTerm       = '';
    @track isLoading        = false;
    @track errorMessage     = null;

    _wiredResult; // Stored for refreshApex

    objectTypeOptions = [
        { label: 'Contact', value: 'Contact' },
        { label: 'Account', value: 'Account' }
    ];

    statusOptions = [
        { label: 'Tous (sauf fermés)', value: 'All' },
        { label: 'Nouveaux',           value: 'New' },
        { label: 'En révision',        value: 'In Review' },
        { label: 'Prêts',              value: 'Ready' },
        { label: 'Erreurs',            value: 'Error' },
        { label: 'Fusionnés',          value: 'Merged' },
        { label: 'Ignorés',            value: 'Ignored' }
    ];

    @wire(getTickets, {
        objectType:   '$objectTypeFilter',
        statusFilter: '$statusFilter'
    })
    wiredTickets(result) {
        this._wiredResult = result;
        this.isLoading    = false;
        if (result.error) {
            this.errorMessage = result.error.body?.message || 'Erreur de chargement';
        } else {
            this.errorMessage = null;
        }
    }

    // ── Computed getters ──────────────────────────────────────────────────────

    get enrichedTickets() {
        const data = this._wiredResult?.data;
        if (!data) return [];
        const term = (this.searchTerm || '').toLowerCase().trim();
        return data
            .map(t => {
                // Apex @AuraEnabled subquery returns QueryResult {records:[]} not a plain array
                const raw = t.Merge_Candidates__r;
                const candidates = !raw ? []
                    : Array.isArray(raw) ? raw
                    : (raw.records || []);
                const candidateNames = candidates
                    .map(c => c.Record_Name__c)
                    .filter(Boolean);
                return {
                    ...t,
                    matchValue:       this._extractMatchValue(t.Match_Key__c) || t.Name,
                    typeIcon:         t.Object_Type__c === 'Account' ? 'standard:account' : 'standard:contact',
                    matchTypeLabel:   MATCH_TYPE_LABEL[t.Match_Type__c] || t.Match_Type__c,
                    confidenceClass:  CONFIDENCE_CLASS[t.Match_Confidence__c] || 'slds-badge ticket-badge',
                    statusClass:      STATUS_CLASS[t.Status__c] || 'slds-badge ticket-badge',
                    rowClass:         this._rowClass(t.Id),
                    relativeDate:     this._relativeDate(t.LastModifiedDate),
                    candidateNames,
                    candidateLabel:        candidateNames.join(' · '),
                    candidateNamesItems:   candidateNames.map((n, i) => ({ id: `cn_${i}_${n}`, name: n }))
                };
            })
            .filter(t => {
                if (!term) return true;
                return t.matchValue.toLowerCase().includes(term)
                    || t.candidateLabel.toLowerCase().includes(term);
            });
    }

    get countLabel() {
        const filtered = this.enrichedTickets.length;
        const total    = this._wiredResult?.data?.length ?? 0;
        const suffix   = filtered !== 1 ? 's' : '';
        return this.searchTerm
            ? `${filtered} / ${total} cas trouvé${suffix}`
            : `${total} cas trouvé${suffix}`;
    }

    get isEmpty() {
        return !this.isLoading && !this.errorMessage && this.enrichedTickets.length === 0;
    }

    get hasError() { return !!this.errorMessage; }

    // ── Event handlers ────────────────────────────────────────────────────────

    handleObjectTypeChange(event) { this.objectTypeFilter = event.detail.value; }
    handleStatusChange(event)     { this.statusFilter     = event.detail.value; }
    handleSearchChange(event)     { this.searchTerm       = event.target.value; }

    handleTicketClick(event) {
        const ticketId    = event.currentTarget.dataset.id;
        const ticketLabel = event.currentTarget.dataset.label;
        const matchType   = event.currentTarget.dataset.matchtype;
        this.dispatchEvent(new CustomEvent('ticketselect', {
            detail: { ticketId, ticketLabel, matchType }
        }));
    }

    handleRefresh() {
        if (this._wiredResult) refreshApex(this._wiredResult);
    }

    @api
    refresh(objectType) {
        if (objectType && typeof objectType === 'string' && objectType !== this.objectTypeFilter) {
            this.objectTypeFilter = objectType;
        }
        if (this._wiredResult) refreshApex(this._wiredResult);
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    _extractMatchValue(matchKey) {
        // Format: "Contact|Email|john@example.com" → "john@example.com"
        if (!matchKey) return null;
        const parts = matchKey.split('|');
        return parts.length >= 3 ? parts.slice(2).join('|') : matchKey;
    }

    _rowClass(id) {
        const base = 'ticket-list__item slds-is-relative';
        return id === this.selectedTicketId
            ? `${base} ticket-list__item_selected`
            : base;
    }

    _relativeDate(iso) {
        if (!iso) return '';
        const ms = Date.now() - new Date(iso).getTime();
        const m  = Math.floor(ms / 60000);
        if (m < 60)   return `il y a ${m} min`;
        const h = Math.floor(m / 60);
        if (h < 24)   return `il y a ${h} h`;
        return `il y a ${Math.floor(h / 24)} j`;
    }
}
