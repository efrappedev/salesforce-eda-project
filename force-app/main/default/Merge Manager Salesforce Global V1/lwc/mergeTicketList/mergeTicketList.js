import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getLabels } from 'c/i18n';
import getTickets       from '@salesforce/apex/MergeController.getTickets';
import reopenTicketApex from '@salesforce/apex/MergeController.reopenTicket';

const CLOSED_REASON_KEY = {
    'False Positive - Same Household':    'reasonHousehold',
    'False Positive - Same Organization': 'reasonOrganization',
    'False Positive - Shared Phone':      'reasonSharedPhone',
    'False Positive - Shared Email':      'reasonSharedEmail',
    'Already Resolved':                   'reasonResolved',
    'Out of Scope':                       'reasonOutOfScope',
    'Other':                              'reasonOther'
};

const MATCH_TYPE_KEY = {
    Email: 'matchEmail',
    Phone: 'matchPhone',
    Name:  'matchName',
    Mixed: 'matchMixed'
};

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
    'Closed':    'slds-badge ticket-badge ticket-badge_closed',
    'Reopened':  'slds-badge ticket-badge ticket-badge_reopened',
    'Error':     'slds-badge ticket-badge ticket-badge_error'
};

// Tags always render in English regardless of UI language
const STATUS_BADGE_LABEL = {
    'New':       'New',
    'In Review': 'In Review',
    'Ready':     'Ready',
    'Merged':    'Merged',
    'Ignored':   'To Validate',
    'Closed':    'Closed',
    'Reopened':  'Reopened',
    'Error':     'Error'
};

export default class MergeTicketList extends LightningElement {
    @api selectedTicketId;
    @api lang = 'fr';

    @track objectTypeFilter      = 'Contact';
    @track statusFilter          = 'All';
    @track closedReasonFilter    = null;
    @track searchTerm            = '';
    @track isLoading             = false;
    @track isReopening           = false;
    @track errorMessage          = null;
    @track _tickets              = [];

    get i18n() { return getLabels(this.lang); }

    get objectTypeOptions() {
        const t = this.i18n;
        return [
            { label: t.objectTypeContact, value: 'Contact' },
            { label: t.objectTypeAccount, value: 'Account' }
        ];
    }

    get statusOptions() {
        const t = this.i18n;
        return [
            { label: t.statusAll,      value: 'All'      },
            { label: t.statusNew,      value: 'New'      },
            { label: t.statusReopened, value: 'Reopened' },
            { label: t.statusErrors,   value: 'Error'    },
            { label: t.statusIgnored,  value: 'Ignored'  },
            { label: t.statusMerged,   value: 'Merged'   },
            { label: t.statusClosed,   value: 'Closed'   }
        ];
    }

    connectedCallback() {
        this._loadTickets();
    }

    async _loadTickets() {
        this.isLoading = true;
        try {
            this._tickets = await getTickets({
                objectType:   this.objectTypeFilter,
                statusFilter: this.statusFilter
            });
            this.errorMessage = null;
        } catch (err) {
            this.errorMessage = err.body?.message || this.i18n.errLoading;
            this._tickets = [];
        } finally {
            this.isLoading = false;
        }
    }

    // ── Computed getters ──────────────────────────────────────────────────────

    get enrichedTickets() {
        const data = this._tickets;
        if (!data || !data.length) return [];
        const term = (this.searchTerm || '').toLowerCase().trim();
        const t    = this.i18n;
        return data
            .map(ticket => {
                const raw = ticket.Merge_Candidates__r;
                const candidates = !raw ? []
                    : Array.isArray(raw) ? raw
                    : (raw.records || []);
                const candidateNames = candidates
                    .map(c => c.Record_Name__c)
                    .filter(Boolean);
                const matchTypeKey = MATCH_TYPE_KEY[ticket.Match_Type__c];
                const closedReasonKey = CLOSED_REASON_KEY[ticket.Closed_Reason__c];
                return {
                    ...ticket,
                    matchValue:       this._extractMatchValue(ticket.Match_Key__c) || ticket.Name,
                    typeIcon:         ticket.Object_Type__c === 'Account' ? 'standard:account' : 'standard:contact',
                    matchTypeLabel:   matchTypeKey ? t[matchTypeKey] : (ticket.Match_Type__c || ''),
                    confidenceClass:  CONFIDENCE_CLASS[ticket.Match_Confidence__c] || 'slds-badge ticket-badge',
                    statusClass:      STATUS_CLASS[ticket.Status__c] || 'slds-badge ticket-badge',
                    statusBadgeLabel: STATUS_BADGE_LABEL[ticket.Status__c] || ticket.Status__c,
                    errorTooltip:     ticket.Status__c === 'Error' && ticket.Error_Message__c ? ticket.Error_Message__c : null,
                    closedReasonLabel: ticket.Closed_Reason__c
                        ? (closedReasonKey ? t[closedReasonKey] : ticket.Closed_Reason__c)
                        : null,
                    closedNotes:      ticket.Notes__c || null,
                    canReopen:        ticket.Status__c === 'Ignored' || ticket.Status__c === 'Closed',
                    rowClass:         this._rowClass(ticket.Id),
                    relativeDate:     this._relativeDate(ticket.LastModifiedDate, t),
                    candidateNames,
                    candidateLabel:       candidateNames.join(' · '),
                    candidateNamesItems:  candidateNames.map((n, i) => ({ id: `cn_${i}_${n}`, name: n }))
                };
            })
            .filter(ticket => {
                if (this.closedReasonFilter && ticket.Closed_Reason__c !== this.closedReasonFilter) return false;
                if (!term) return true;
                return ticket.matchValue.toLowerCase().includes(term)
                    || ticket.candidateLabel.toLowerCase().includes(term);
            });
    }

    get showClosedReasonFilter() {
        return this.statusFilter === 'Closed' || this.statusFilter === 'Ignored';
    }

    get closedReasonFilterOptions() {
        const t = this.i18n;
        return Object.entries(CLOSED_REASON_KEY).map(([value, key]) => ({
            label: t[key] || value,
            value
        }));
    }

    get countLabel() {
        const filtered = this.enrichedTickets.length;
        const total    = this._tickets?.length ?? 0;
        const suffix   = this.i18n.casFound;
        return this.searchTerm
            ? `${filtered} / ${total} ${suffix}`
            : `${total} ${suffix}`;
    }

    get isEmpty() {
        return !this.isLoading && !this.errorMessage && this.enrichedTickets.length === 0;
    }

    get hasError() { return !!this.errorMessage; }

    // ── Event handlers ────────────────────────────────────────────────────────

    handleObjectTypeChange(event) {
        this.objectTypeFilter = event.detail.value;
        this._loadTickets();
    }

    handleStatusChange(event) {
        this.statusFilter       = event.detail.value;
        this.closedReasonFilter = null;
        this._loadTickets();
    }

    handleClosedReasonFilterChange(event) {
        this.closedReasonFilter = event.detail.value || null;
    }

    handleSearchChange(event) { this.searchTerm = event.target.value; }

    handleTicketClick(event) {
        const ticketId    = event.currentTarget.dataset.id;
        const ticketLabel = event.currentTarget.dataset.label;
        const matchType   = event.currentTarget.dataset.matchtype;
        this.dispatchEvent(new CustomEvent('ticketselect', {
            detail: { ticketId, ticketLabel, matchType }
        }));
    }

    @api get currentObjectType() { return this.objectTypeFilter; }

    handleRefresh() { this._loadTickets(); }

    @api
    refresh(objectType) {
        if (objectType && typeof objectType === 'string') {
            this.objectTypeFilter = objectType;
        }
        this._loadTickets();
    }

    async handleReopenTicket(event) {
        event.stopPropagation();
        const ticketId = event.currentTarget.dataset.id;
        this.isReopening = true;
        const t = this.i18n;
        try {
            await reopenTicketApex({ ticketId });
            this._loadTickets();
            this.dispatchEvent(new CustomEvent('ticketreopened', { detail: { ticketId }, bubbles: true, composed: true }));
            this.dispatchEvent(new ShowToastEvent({
                title:   t.toastTicketReopened,
                message: t.toastTicketNewState,
                variant: 'success'
            }));
        } catch (err) {
            this.dispatchEvent(new ShowToastEvent({
                title:   t.error,
                message: err.body?.message || err.message,
                variant: 'error'
            }));
        } finally {
            this.isReopening = false;
        }
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    _extractMatchValue(matchKey) {
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

    _relativeDate(iso, t) {
        if (!iso) return '';
        const ms = Date.now() - new Date(iso).getTime();
        const m  = Math.floor(ms / 60000);
        if (m < 60)   return t.agoMin.replace('{0}', m);
        const h = Math.floor(m / 60);
        if (h < 24)   return t.agoHour.replace('{0}', h);
        return t.agoDay.replace('{0}', Math.floor(h / 24));
    }
}
