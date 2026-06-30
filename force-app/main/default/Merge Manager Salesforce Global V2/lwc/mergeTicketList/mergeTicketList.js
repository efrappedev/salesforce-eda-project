import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getLabels } from 'c/i18n';
import getTickets       from '@salesforce/apex/MergeController.getTickets';
import getTicketCount   from '@salesforce/apex/MergeController.getTicketCount';
import resolveSearchIds from '@salesforce/apex/MergeController.resolveSearchIds';
import reopenTicketApex from '@salesforce/apex/MergeController.reopenTicket';

const CLOSED_REASON_KEY = {
    'False Positive - Same Household':    'reasonHousehold',
    'False Positive - Same Organization': 'reasonOrganization',
    'False Positive - Shared Phone':      'reasonSharedPhone',
    'False Positive - Shared Email':      'reasonSharedEmail',
    'Already Resolved':                   'reasonResolved',
    'Out of Scope':                       'reasonOutOfScope',
    'Other':                              'reasonOther',
    'Record Deleted':                     'reasonDeleted'
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

const STATUS_BADGE_KEY = {
    'New':       'statusNew',
    'In Review': 'statusInReview',
    'Ready':     'statusReady',
    'Merged':    'statusMerged',
    'Ignored':   'statusIgnored',
    'Closed':    'statusClosed',
    'Reopened':  'statusReopened',
    'Error':     'statusErrors'
};

const PAGE_SIZE = 2000;

// "New"/"Reopened" tickets get reclassified into Pending/Stale the longer
// they sit untouched. Status__c itself never changes — display-only.
const NEW_TICKET_AGE_DAYS = { PENDING: 3, STALE: 8 };

export default class MergeTicketList extends LightningElement {
    @api selectedTicketId;

    @track _lang                 = 'fr';
    @track _labels               = { ...getLabels('fr') };
    @track objectTypeFilter      = 'Contact';
    @track statusFilter          = 'All';
    @track closedReasonFilter    = null;
    @track searchTerm            = '';
    @track isLoading             = false;
    @track isReopening           = false;
    @track errorMessage          = null;
    @track _tickets              = [];
    @track _totalCount           = 0;
    // Keyset pagination: _cursors[i] = cursor to load page i; null = first page (no cursor)
    @track _cursors              = [null];
    @track _currentPageIdx       = 0;

    _searchTimer                 = null;
    _editingPage                 = false;
    _lastCandidateIds            = null;

    @api
    get lang() { return this._lang; }
    set lang(v) {
        if (v && v !== this._lang) {
            this._lang   = v;
            this._labels = { ...getLabels(v) };
        }
    }

    get i18n() { return this._labels; }

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
        const cursor = this._cursors[this._currentPageIdx] ?? null;
        try {
            // Candidate name search runs in its own transaction (own 50k governor limit).
            // Must resolve first so both getTickets and getTicketCount receive the same IDs.
            const candidateTicketIds = this.searchTerm
                ? await resolveSearchIds({ searchTerm: this.searchTerm })
                : null;
            this._lastCandidateIds = candidateTicketIds;

            const params = {
                objectType:         this.objectTypeFilter,
                statusFilter:       this.statusFilter,
                searchTerm:         this.searchTerm || null,
                candidateTicketIds: candidateTicketIds,
                cursorTimestamp:    cursor ? cursor.ts : null,
                cursorId:           cursor ? cursor.id : null
            };
            const [tickets, count] = await Promise.all([
                getTickets(params),
                getTicketCount({
                    objectType:         params.objectType,
                    statusFilter:       params.statusFilter,
                    searchTerm:         params.searchTerm,
                    candidateTicketIds: params.candidateTicketIds
                })
            ]);
            this._tickets    = tickets;
            this._totalCount = count ?? 0;
            // Keyset: store cursor for the next page when we got a full page (search or not)
            if (tickets.length === PAGE_SIZE
                    && this._currentPageIdx + 1 >= this._cursors.length) {
                const last = tickets[tickets.length - 1];
                const newCursors = [...this._cursors];
                newCursors.push({ ts: new Date(last.LastModifiedDate).getTime(), id: last.Id });
                this._cursors = newCursors;
            }
            this.errorMessage = null;
        } catch (err) {
            this.errorMessage = err.body?.message || this.i18n.errLoading;
            this._tickets    = [];
            this._totalCount = 0;
        } finally {
            this.isLoading = false;
        }
    }

    _resetPagination() {
        this._currentPageIdx = 0;
        this._cursors = [null];
    }

    // ── Computed getters ──────────────────────────────────────────────────────

    get enrichedTickets() {
        const data = this._tickets;
        if (!data || !data.length) return [];
        const t = this.i18n;
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
                const aging = this._agingBadge(ticket.Status__c, ticket.CreatedDate, t);
                const statusKey = STATUS_BADGE_KEY[ticket.Status__c];
                return {
                    ...ticket,
                    matchValue:       this._extractMatchValue(ticket.Match_Key__c) || ticket.Name,
                    typeIcon:         ticket.Object_Type__c === 'Account' ? 'standard:account' : 'standard:contact',
                    matchTypeLabel:   matchTypeKey ? t[matchTypeKey] : (ticket.Match_Type__c || ''),
                    confidenceClass:  CONFIDENCE_CLASS[ticket.Match_Confidence__c] || 'slds-badge ticket-badge',
                    statusClass:      aging ? aging.statusClass : (STATUS_CLASS[ticket.Status__c] || 'slds-badge ticket-badge'),
                    statusBadgeLabel: aging ? aging.statusLabel : (statusKey ? t[statusKey] : ticket.Status__c),
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
                // closedReason is client-side (fast dropdown); text search is server-side
                if (this.closedReasonFilter && ticket.Closed_Reason__c !== this.closedReasonFilter) return false;
                return true;
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
        const loaded = this._tickets?.length ?? 0;
        const total  = this._totalCount > 0 ? this._totalCount : loaded;
        const base   = `${total.toLocaleString()} ${this.i18n.casFound}`;
        if (loaded > 0 && loaded < total) {
            return `${base} ${this.i18n.casShowing.replace('{0}', loaded.toLocaleString())}`;
        }
        return base;
    }

    get _totalPages() {
        return Math.max(1, Math.ceil((this._totalCount || 1) / PAGE_SIZE));
    }

    get pageLabel() {
        return `${this._currentPageIdx + 1}/${this._totalPages}`;
    }

    get showPageNav() {
        return this._totalPages > 1;
    }

    get isPrevDisabled() {
        return this._currentPageIdx === 0;
    }

    get isNextDisabled() {
        return this._tickets.length < PAGE_SIZE
            || this._currentPageIdx + 1 >= this._cursors.length;
    }

    get isEmpty() {
        return !this.isLoading && !this.errorMessage && this.enrichedTickets.length === 0;
    }

    get hasError() { return !!this.errorMessage; }

    // ── Event handlers ────────────────────────────────────────────────────────

    handleObjectTypeChange(event) {
        this.objectTypeFilter = event.detail.value;
        this._resetPagination();
        this._loadTickets();
    }

    handleStatusChange(event) {
        this.statusFilter       = event.detail.value;
        this.closedReasonFilter = null;
        this._resetPagination();
        this._loadTickets();
    }

    handleClosedReasonFilterChange(event) {
        this.closedReasonFilter = event.detail.value || null;
    }

    get hasSearch() { return !!this.searchTerm; }

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
        if (this._searchTimer) clearTimeout(this._searchTimer);
        this._searchTimer = setTimeout(() => {
            this._resetPagination();
            this._loadTickets();
        }, 400);
    }

    handleClearSearch() {
        this.searchTerm = '';
        const input = this.template.querySelector('.ticket-list__search-input');
        if (input) input.value = '';
        if (this._searchTimer) clearTimeout(this._searchTimer);
        this._resetPagination();
        this._loadTickets();
    }

    handlePrevPage() {
        if (!this.isPrevDisabled) {
            this._currentPageIdx--;
            this._loadTickets();
        }
    }

    handleNextPage() {
        if (!this.isNextDisabled) {
            this._currentPageIdx++;
            this._loadTickets();
        }
    }

    handlePageLabelClick() {
        this._editingPage = true;
        Promise.resolve().then(() => {
            const inp = this.template.querySelector('.page-nav-input');
            if (inp) {
                inp.value = this._currentPageIdx + 1;
                inp.select();
                inp.focus();
            }
        });
    }

    handlePageInputBlur() {
        this._editingPage = false;
    }

    async handlePageInputKey(event) {
        if (event.key === 'Escape') {
            this._editingPage = false;
            return;
        }
        if (event.key !== 'Enter') return;
        const target = parseInt(event.target.value, 10);
        this._editingPage = false;
        if (isNaN(target) || target < 1 || target > this._totalPages) return;
        if (target - 1 !== this._currentPageIdx) {
            await this._jumpToPage(target - 1);
        }
    }

    async _jumpToPage(targetIdx) {
        this.isLoading = true;
        // Silently prefetch cursors for intermediate pages not yet visited
        while (this._cursors.length <= targetIdx) {
            const cursorIdx = this._cursors.length - 1;
            const cursor    = this._cursors[cursorIdx];
            try {
                // eslint-disable-next-line no-await-in-loop
                const intermediate = await getTickets({
                    objectType:         this.objectTypeFilter,
                    statusFilter:       this.statusFilter,
                    searchTerm:         this.searchTerm || null,
                    candidateTicketIds: this._lastCandidateIds,
                    cursorTimestamp:    cursor ? cursor.ts : null,
                    cursorId:           cursor ? cursor.id : null
                });
                if (intermediate.length === PAGE_SIZE) {
                    const last = intermediate[intermediate.length - 1];
                    const next = [...this._cursors];
                    next.push({ ts: new Date(last.LastModifiedDate).getTime(), id: last.Id });
                    this._cursors = next;
                } else {
                    break; // reached actual last page
                }
            } catch (err) {
                this.isLoading = false;
                return;
            }
        }
        this._currentPageIdx = Math.min(targetIdx, this._cursors.length - 1);
        this._loadTickets();
    }

    handleTicketClick(event) {
        const ticketId    = event.currentTarget.dataset.id;
        const ticketLabel = event.currentTarget.dataset.label;
        const matchType   = event.currentTarget.dataset.matchtype;
        const objectType  = event.currentTarget.dataset.objecttype;
        this.dispatchEvent(new CustomEvent('ticketselect', {
            detail: { ticketId, ticketLabel, matchType, objectType }
        }));
    }

    @api get currentObjectType() { return this.objectTypeFilter; }

    handleRefresh() {
        this._resetPagination();
        this._loadTickets();
    }

    @api
    refresh(objectType) {
        if (objectType && typeof objectType === 'string') {
            this.objectTypeFilter = objectType;
        }
        this._resetPagination();
        this._loadTickets();
    }

    async handleReopenTicket(event) {
        event.stopPropagation();
        const ticketId = event.currentTarget.dataset.id;
        this.isReopening = true;
        const t = this.i18n;
        try {
            await reopenTicketApex({ ticketId });
            this._resetPagination();
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

    _agingBadge(status, createdDate, t) {
        if (status !== 'New' || !createdDate) return null;
        const days = Math.floor((Date.now() - new Date(createdDate).getTime()) / 86400000);
        if (days >= NEW_TICKET_AGE_DAYS.STALE) {
            return { statusClass: 'slds-badge ticket-badge ticket-badge_stale', statusLabel: t.statusStale };
        }
        if (days >= NEW_TICKET_AGE_DAYS.PENDING) {
            return { statusClass: 'slds-badge ticket-badge ticket-badge_pending', statusLabel: t.statusPending };
        }
        return null;
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
