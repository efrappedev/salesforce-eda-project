import { LightningElement, api, track } from 'lwc';
import DucConfirmModal from 'c/ducConfirmModal';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getLabels, format } from 'c/dataUpdateI18n';
import {
    statusStyle, statusLabel, ticketNumber, initials, formatDate, toneStyle, isOpenStatus
} from 'c/dataUpdateUi';
import getRequestsApex from '@salesforce/apex/DataUpdateReviewController.getRequests';
import getFormsApex from '@salesforce/apex/DataUpdateFormAdminController.getForms';
import hasDeletedFormTicketsApex from '@salesforce/apex/DataUpdateReviewController.hasDeletedFormTickets';
import reopenRequestApex from '@salesforce/apex/DataUpdateReviewController.reopenRequest';
import holdRequestApex from '@salesforce/apex/DataUpdateReviewController.holdRequest';
import resumeRequestApex from '@salesforce/apex/DataUpdateReviewController.resumeRequest';
import getCanMultiTicketReviewApex from '@salesforce/apex/DataUpdateReviewController.getCanMultiTicketReview';

// Same page size as Zeffy Connect; SOQL OFFSET caps at 2000, so up to 5 pages (2,500 tickets) per filter.
const PAGE_SIZE = 500;
const ALL_FORMS = 'All';
const DELETED_FORMS_FILTER = '__DELETED_FORMS__';
const POLL_MS = 60000;
const SEARCH_DEBOUNCE_MS = 300;
// Order of the status filter (Open first, All last) — same as the approved mockup.
const STATUS_ORDER = ['New', 'In Review', 'On Hold', 'Reopened', 'Applied', 'Ignored', 'Error'];

export default class RequestInboxList extends LightningElement {
    @api lang = 'fr';
    @api selectedRequestId = null;

    @track isLoading = true;
    @track statusFilter = 'Open';
    @track formFilter = ALL_FORMS;
    @track forms = [];
    @track searchTerm = '';
    @track pageOffset = 0;
    @track totalCount = 0;
    @track holdModalRequestId = null;
    @track holdReason = '';
    @track isHolding = false;
    @track _editingPage = false;
    @track canGroup = false;
    @track expandedGroups = {};

    _rawRequests = [];
    pageSize = PAGE_SIZE;
    _pollId = null;
    _searchTimer = null;
    _focusHold = false;

    async connectedCallback() {
        try {
            this.canGroup = !!(await getCanMultiTicketReviewApex());
        } catch (e) {
            this.canGroup = false;
        }
        await this.loadForms();
        this.loadRequests();
        // Silent refresh so presence badges (other staff viewing) and new tickets show up.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._pollId = setInterval(() => {
            if (!document.hidden && !this.isLoading) this.loadRequests(true);
        }, POLL_MS);
    }

    disconnectedCallback() {
        if (this._pollId) clearInterval(this._pollId);
        if (this._searchTimer) clearTimeout(this._searchTimer);
    }

    renderedCallback() {
        if (this._focusHold) {
            const ta = this.template.querySelector('.duc-hold-note');
            if (ta) {
                ta.focus();
                this._focusHold = false;
            }
        }
    }

    get i18n() { return getLabels(this.lang); }

    async loadForms() {
        try {
            const realForms = (await getFormsApex()) || [];
            let hasDeletedFormTickets = false;
            try {
                hasDeletedFormTickets = await hasDeletedFormTicketsApex();
            } catch (e) {
                hasDeletedFormTickets = false;
            }
            this.forms = hasDeletedFormTickets
                ? [
                    ...realForms,
                    {
                        developerName: DELETED_FORMS_FILTER,
                        label: this.i18n.filterDeletedForms,
                        hasLockField: false,
                        isCoreForm: false
                    }
                ]
                : realForms;
        } catch (e) {
            this.forms = [];
        }
        this._notifyFormFilterChanged();
    }

    // ── Filters (native selects) ────────────────────────────────────────────

    get formOptions() {
        const opts = [{ value: ALL_FORMS, label: this.i18n.rdAllForms }];
        this.forms.forEach((f) => opts.push({
            value: f.developerName,
            // resolved here so the label follows the language toggle
            label: f.developerName === DELETED_FORMS_FILTER ? this.i18n.filterDeletedForms : f.label
        }));
        return opts.map((o) => ({ ...o, selected: o.value === this.formFilter }));
    }

    get statusOptions() {
        const opts = [{ value: 'Open', label: this.i18n.rdFilterOpen }];
        STATUS_ORDER.forEach((s) => opts.push({ value: s, label: statusLabel(this.i18n, s) }));
        opts.push({ value: 'All', label: this.i18n.rdFilterAll });
        return opts.map((o) => ({ ...o, selected: o.value === this.statusFilter }));
    }

    handleStatusFilterChange(event) {
        this.statusFilter = event.target.value;
        this.pageOffset = 0;
        this.loadRequests();
        this._notifyFormFilterChanged();
    }

    handleFormFilterChange(event) {
        const developerName = event.target.value;
        if (developerName === this.formFilter) return;
        this.formFilter = developerName;
        this.pageOffset = 0;
        this.loadRequests();
        this._notifyFormFilterChanged();
    }

    // Called by the dashboard (through the Center) when a tile / status bar is clicked.
    @api
    setFilters(status, form) {
        if (status) this.statusFilter = status;
        if (form) this.formFilter = form;
        // A dashboard drill-down must show every match, not just the ones the old search kept.
        this.searchTerm = '';
        this.pageOffset = 0;
        this.loadRequests();
        this._notifyFormFilterChanged();
    }

    _notifyFormFilterChanged() {
        this.dispatchEvent(new CustomEvent('formfilterchange', {
            detail: { formName: this.formFilter, status: this.statusFilter }
        }));
    }

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
        this.pageOffset = 0;
        if (this._searchTimer) clearTimeout(this._searchTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._searchTimer = setTimeout(() => this.loadRequests(), SEARCH_DEBOUNCE_MS);
    }

    get isSearching() { return !!(this.searchTerm || '').trim(); }
    get noSearchResultsText() {
        if (this.isStatusFiltered) {
            const opt = this.statusOptions.find((o) => o.value === this.statusFilter);
            return format(this.i18n.rdNoSearchResultsStatusFmt, opt ? opt.label : this.statusFilter, this.searchTerm.trim());
        }
        return format(this.i18n.rdNoSearchResultsFmt, this.searchTerm.trim());
    }
    get isStatusFiltered() { return this.statusFilter !== 'All'; }

    handleShowAllStatuses() {
        this.statusFilter = 'All';
        this.pageOffset = 0;
        this.loadRequests();
        this._notifyFormFilterChanged();
    }

    handleClearSearch() {
        this.searchTerm = '';
        this.pageOffset = 0;
        const input = this.template.querySelector('input[type="text"]');
        if (input) {
            input.value = '';
            input.focus();
        }
        this.loadRequests();
    }

    handleSearchKey(event) {
        if (event.key === 'Escape' && this.searchTerm) {
            event.target.value = '';
            this.searchTerm = '';
            this.pageOffset = 0;
            this.loadRequests();
        }
    }

    // ── Data ─────────────────────────────────────────────────────────────────

    async loadRequests(silent) {
        // Only the newest call may write results — an older, slower response is dropped.
        const seq = (this._seq = (this._seq || 0) + 1);
        if (!silent) this.isLoading = true;
        try {
            const result = await getRequestsApex({
                statusFilter: this.statusFilter,
                formFilter: this.formFilter,
                searchTerm: this.searchTerm,
                pageSize: this.pageSize,
                pageOffset: this.pageOffset
            });
            if (seq !== this._seq) return;
            if (result.success) {
                this._rawRequests = result.requests || [];
                this.totalCount = result.totalCount;
                // A new search/filter shows its results from the top (silent refreshes keep the place).
                if (!silent) {
                    const list = this.template.querySelector('.duc-list');
                    if (list) list.scrollTop = 0;
                }
            } else if (!silent) {
                this._toast(this.i18n.toastActionErrorTitle, this.i18n.reviewErrGeneric, 'error');
            }
        } catch (e) {
            if (seq === this._seq && !silent) this._toast(this.i18n.toastActionErrorTitle, this.i18n.reviewErrGeneric, 'error');
        } finally {
            if (seq === this._seq) this.isLoading = false;
        }
    }

    @api
    refresh() {
        this.loadRequests(true);
    }

    handleRefresh() {
        this.loadRequests();
    }

    get requests() {
        return this._rawRequests.map((t) => this._decorate(t));
    }

    // Grouping is on for staff with Data_Update_Multi_Ticket_Review: the open tickets of one record
    // become one card (placed where its newest ticket is). Everyone else sees the flat list.
    _groupable(t) {
        return this.canGroup && !!t.targetRecordId && isOpenStatus(t.status) && (t.targetOpenCount || 0) > 1;
    }

    get entries() {
        const i18n = this.i18n;
        const out = [];
        const byTarget = {};
        this.requests.forEach((r) => {
            if (!this._groupable(r)) {
                out.push({ key: r.id, isSingle: true, r });
                return;
            }
            let g = byTarget[r.targetRecordId];
            if (!g) {
                g = { key: 'grp:' + r.targetRecordId, isGroup: true, targetId: r.targetRecordId, items: [] };
                byTarget[r.targetRecordId] = g;
                out.push(g);
            }
            g.items.push(r);
        });
        // A filter can leave a single visible ticket of a record: show it as a plain ticket, not as a
        // group card whose "show N more" would expand to nothing.
        return out.map((e) => (e.isGroup && e.items.length === 1
            ? { key: e.items[0].id, isSingle: true, r: e.items[0] }
            : e)).map((e) => {
            if (!e.isGroup) return e;
            const latest = e.items[0];
            const count = Math.max(latest.targetOpenCount || 0, e.items.length);
            const name = latest.targetName || latest.name;
            const forms = [];
            const byForm = {};
            e.items.forEach((r) => {
                const fk = r.formLabelDisplay;
                if (!byForm[fk]) {
                    byForm[fk] = { key: e.key + '|' + fk, form: fk, tickets: [] };
                    forms.push(byForm[fk]);
                }
                byForm[fk].tickets.push(r);
            });
            const formsTxt = forms.length === 1 ? i18n.grpOneForm : format(i18n.grpFormsFmt, forms.length);
            const expanded = !!this.expandedGroups[e.targetId];
            const active = this.selectedRequestId === e.key;
            const anyOn = active || e.items.some((r) => r.id === this.selectedRequestId);
            return {
                ...e,
                name,
                count,
                latest,
                latestShowPill: true,
                // "Review together" opens every open ticket of the record, filtered or not — say so.
                chipText: format(i18n.grpTicketsFmt, count)
                    + (count > e.items.length ? ' (' + format(i18n.grpHiddenFmt, count - e.items.length) + ')' : '')
                    + ' · ' + formsTxt,
                expanded,
                collapsed: !expanded,
                expandedTxt: String(expanded),
                toggleText: expanded ? i18n.grpCollapse : format(i18n.grpShowMoreFmt, e.items.length - 1),
                reviewText: format(i18n.grpReviewTogetherFmt, count),
                cardClass: 'duc-item' + (anyOn ? ' duc-item_on' : ''),
                reviewClass: 'duc-gbtn' + (active ? ' duc-gbtn_on' : ''),
                sections: forms.map((f, i) => ({
                    ...f,
                    n: f.tickets.length,
                    secClass: 'duc-gsec' + (i > 0 ? ' duc-gsec_div' : ''),
                    tickets: f.tickets.map((r) => ({
                        ...r,
                        miniClass: 'duc-mini' + (r.id === this.selectedRequestId ? ' duc-mini_on' : ''),
                        showPill: true
                    }))
                }))
            };
        });
    }

    handleGroupToggle(event) {
        const id = event.currentTarget.dataset.target;
        this.expandedGroups = { ...this.expandedGroups, [id]: !this.expandedGroups[id] };
    }

    handleGroupKey(event) {
        if (event.target !== event.currentTarget) return;
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleMultiTicketReview(event);
        }
    }

    handleMultiTicketReview(event) {
        const { target, name, count } = event.currentTarget.dataset;
        this.dispatchEvent(new CustomEvent('groupselect', {
            detail: { targetRecordId: target, name, count: Number(count) }
        }));
    }

    get isEmpty() { return !this.isLoading && this._rawRequests.length === 0; }
    get showSpinner() { return this.isLoading && this._rawRequests.length === 0; }

    get countLabel() {
        return format(this.totalCount === 1 ? this.i18n.rdNReqOneFmt : this.i18n.rdNReqManyFmt, this.totalCount);
    }

    _decorate(t) {
        const i18n = this.i18n;
        const tno = ticketNumber(t.requestNumber);
        const name = t.subject || t.requestedName || t.requestNumber || '';
        const viewers = t.viewers || [];
        const count = t.changedFieldCount || 0;
        let quick;
        if (t.status === 'On Hold') {
            quick = { act: 'resume', icon: 'play', label: i18n.rdResume };
        } else if (t.status === 'Applied') {
            quick = { act: 'rollback', icon: 'rewind', label: i18n.rdRbList };
        } else if (t.status === 'Ignored' || t.status === 'Closed') {
            quick = { act: 'reopen', icon: 'undo', label: i18n.rdReopen };
        } else {
            quick = { act: 'hold', icon: 'pause', label: i18n.rdPutHold };
        }
        const viewingTip = viewers.length
            ? format(viewers.length > 1 ? i18n.rdViewingManyFmt : i18n.rdViewingFmt, viewers.join(', '))
            : '';
        return {
            ...t,
            name,
            initials: initials(name),
            itemClass: 'duc-item' + (t.id === this.selectedRequestId ? ' duc-item_on' : ''),
            ariaSelected: String(t.id === this.selectedRequestId),
            statusText: statusLabel(i18n, t.status),
            statusStyle: statusStyle(t.status),
            tnoZeros: tno.zeros,
            tnoDigits: tno.digits,
            tnoFull: tno.full,
            tnoTitle: '#' + tno.full,
            when: formatDate(t.createdDate, this.lang),
            changesText: format(count === 1 ? i18n.rdChangeOneFmt : i18n.rdChangesFmt, count).replace(/^·\s*/, '')
                + ((t.tableRowCount || 0) > 1 ? ' · ' + format(i18n.grpExcelRowsFmt, t.tableRowCount) : ''),
            formLabelDisplay: t.formLabel || i18n.formDeletedLabel,
            hasViewers: viewers.length > 0,
            peerInitials: viewers.length ? initials(viewers[0]) : '',
            peerMore: viewers.length > 1 ? '+' + (viewers.length - 1) : '',
            viewingTip,
            quickAct: quick.act,
            quickIcon: quick.icon,
            quickLabel: quick.label
        };
    }

    // ── Pagination ───────────────────────────────────────────────────────────

    get currentPage() { return Math.floor(this.pageOffset / this.pageSize) + 1; }
    get totalPages() { return Math.max(1, Math.ceil(this.totalCount / this.pageSize)); }
    get pageLabel() { return `${this.currentPage}/${this.totalPages}`; }
    get showPageNav() { return this.totalPages > 1; }
    get isPrevDisabled() { return this.isLoading || this.pageOffset <= 0; }
    get isNextDisabled() { return this.isLoading || (this.pageOffset + this.pageSize) >= this.totalCount; }

    handlePrevPage() {
        if (this.isPrevDisabled) return;
        this.pageOffset = Math.max(0, this.pageOffset - this.pageSize);
        this.loadRequests();
    }

    handleNextPage() {
        if (this.isNextDisabled) return;
        this.pageOffset += this.pageSize;
        this.loadRequests();
    }

    handlePageLabelClick() {
        this._editingPage = true;
        Promise.resolve().then(() => {
            const inp = this.template.querySelector('.duc-pager-input');
            if (inp) {
                inp.value = this.currentPage;
                inp.select();
                inp.focus();
            }
        });
    }

    handlePageLabelKey(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handlePageLabelClick();
        }
    }

    handlePageInputBlur() { this._editingPage = false; }

    handlePageInputKey(event) {
        if (event.key === 'Escape') {
            this._editingPage = false;
            return;
        }
        if (event.key !== 'Enter') return;
        const target = parseInt(event.target.value, 10);
        this._editingPage = false;
        if (isNaN(target) || target < 1 || target > this.totalPages) return;
        this.pageOffset = (target - 1) * this.pageSize;
        this.loadRequests();
    }

    // ── Selection ────────────────────────────────────────────────────────────

    handleRequestClick(event) {
        const { id, label, status } = event.currentTarget.dataset;
        this._select(id, label, status, false);
    }

    handleItemKey(event) {
        if (event.target !== event.currentTarget) return;
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            const { id, label, status } = event.currentTarget.dataset;
            this._select(id, label, status, false);
        }
    }

    _select(requestId, label, status, rollbackAsk) {
        const t = this._rawRequests.find((r) => r.id === requestId);
        // Lets the ticket tab offer "Review N together" when the record has other open tickets.
        const groupCount = t && this._groupable(t) ? t.targetOpenCount : 0;
        this.dispatchEvent(new CustomEvent('requestselect', {
            detail: { requestId, label, status, rollbackAsk, groupCount, number: t ? t.requestNumber : '' }
        }));
    }

    // ── Quick actions (without opening the ticket) ──────────────────────────

    handleQuick(event) {
        event.stopPropagation();
        const { id, act, label, status } = event.currentTarget.dataset;
        if (act === 'hold') {
            this.holdModalRequestId = id;
            this.holdReason = '';
            this._focusHold = true;
        } else if (act === 'resume') {
            this._resume(id);
        } else if (act === 'reopen') {
            this._reopen(id);
        } else if (act === 'rollback') {
            this._select(id, label, status, true);
        }
    }

    handleQuickKey(event) {
        // Keep Enter/Space on the icon from also selecting the card.
        if (event.key === 'Enter' || event.key === ' ') event.stopPropagation();
    }

    async _reopen(requestId) {
        // Reopening re-locks the account, so it's confirmed first.
        const confirmed = await DucConfirmModal.open({
            label: this.i18n.reopenConfirmTitle,
            message: this.i18n.reopenConfirmMsg,
            theme: 'warning',
            okLabel: this.i18n.confirmOk,
            cancelLabel: this.i18n.btnCancel
        });
        if (!confirmed) return;
        try {
            await reopenRequestApex({ requestId });
            this._toast(this.i18n.toastReopenSuccessTitle, '', 'success');
            this.loadRequests(true);
            this._notifyChanged(requestId, 'Reopened');
        } catch (e) {
            this._toast(this.i18n.toastActionErrorTitle, '', 'error');
        }
    }

    async _resume(requestId) {
        try {
            await resumeRequestApex({ requestId });
            this._toast(this.i18n.toastResumeSuccessTitle, '', 'success');
            this.loadRequests(true);
            this._notifyChanged(requestId, 'In Review');
        } catch (e) {
            this._toast(this.i18n.toastActionErrorTitle, '', 'error');
        }
    }

    // ── Hold mini-modal ──────────────────────────────────────────────────────

    get isHoldModalOpen() { return !!this.holdModalRequestId; }
    get holdTone() { return toneStyle('hold'); }

    get holdTicket() {
        const t = this._rawRequests.find((r) => r.id === this.holdModalRequestId);
        if (!t) return { name: '', tnoZeros: '', tnoDigits: '' };
        const tno = ticketNumber(t.requestNumber);
        return { name: t.subject || t.requestedName || '', tnoZeros: tno.zeros, tnoDigits: tno.digits };
    }

    handleHoldReasonChange(event) {
        this.holdReason = event.target.value;
    }

    handleHoldKey(event) {
        if (event.key === 'Escape') {
            event.preventDefault();
            this.handleCancelHold();
        } else if (event.key === 'Enter' && !event.shiftKey) {
            event.preventDefault();
            this.holdReason = event.target.value;
            this.handleConfirmHold();
        }
    }

    handleCancelHold() {
        this.holdModalRequestId = null;
        this.holdReason = '';
    }

    async handleConfirmHold() {
        if (this.isHolding) return;
        const requestId = this.holdModalRequestId;
        this.isHolding = true;
        try {
            await holdRequestApex({ requestId, reason: (this.holdReason || '').trim() });
            this._toast(this.i18n.toastHoldSuccessTitle, '', 'success');
            this.holdModalRequestId = null;
            this.holdReason = '';
            this.loadRequests(true);
            this._notifyChanged(requestId, 'On Hold');
        } catch (e) {
            this._toast(this.i18n.toastActionErrorTitle, '', 'error');
        } finally {
            this.isHolding = false;
        }
    }

    _notifyChanged(requestId, status) {
        this.dispatchEvent(new CustomEvent('requestchanged', { detail: { requestId, status } }));
    }

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
