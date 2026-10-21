import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import DucConfirmModal from 'c/ducConfirmModal';
import { getLabels, format } from 'c/dataUpdateI18n';
import { statusStyle, statusLabel, formatDate } from 'c/dataUpdateUi';
import getLockedRecordsApex from '@salesforce/apex/DataUpdateReviewController.getLockedRecords';
import unlockRecordApex from '@salesforce/apex/DataUpdateReviewController.unlockRecord';
import unlockAllRecordsApex from '@salesforce/apex/DataUpdateReviewController.unlockAllRecords';
import getFormsApex from '@salesforce/apex/DataUpdateFormAdminController.getForms';

const PAGE_SIZE = 25;
const SEARCH_DEBOUNCE_MS = 300;
// Same fallback form used by dataUpdateForm.js's portal — the lock feature is currently
// only configured for this form.
const DEFAULT_FORM_DEVELOPER_NAME = 'AEBEQ_Account_Update';
// Pseudo-filter of the request list — never a real (lockable) form.
const DELETED_FORMS_FILTER = '__DELETED_FORMS__';

export default class DataUpdateLockedList extends LightningElement {
    @api lang = 'fr';

    _formName = DEFAULT_FORM_DEVELOPER_NAME;
    _requestedForm;
    _formNameInitialized = false;

    // The sibling request list now defaults to 'All' and can pick forms without a lock field —
    // only follow the parent when it names a form that actually supports locking.
    @api
    get formName() { return this._formName; }
    set formName(value) {
        this._requestedForm = value;
        if (!this._isLockForm(value)) return;
        const changed = value !== this._formName;
        this._formName = value;
        if (changed && this._formNameInitialized) {
            this.pageOffset = 0;
            this.loadLockedRecords();
        }
    }

    @track isLoading = true;
    @track searchTerm = '';
    @track pageOffset = 0;
    @track totalCount = 0;
    @track unlockableCount = 0;
    @track selectedIds = new Set();
    @track isUnlocking = false;
    @track lockForms = [];
    @track editingPage = false;

    _rawRecords = [];
    _loadedOnce = false;
    _searchTimer;
    pageSize = PAGE_SIZE;

    async connectedCallback() {
        // Resolve the lock forms first so the first query already targets a valid form.
        await this._loadForms();
        this._formNameInitialized = true;
        this.loadLockedRecords();
    }

    disconnectedCallback() {
        clearTimeout(this._searchTimer);
    }

    renderedCallback() {
        const cb = this.template.querySelector('.duc-lk-all');
        if (cb) cb.indeterminate = this.hasAnySelected && !this.allSelectableSelected;
        if (this.editingPage) {
            const inp = this.template.querySelector('.duc-pager-input');
            if (inp && this.template.activeElement !== inp) {
                inp.value = this.currentPage;
                inp.select();
                inp.focus();
            }
        }
    }

    @api
    refresh() {
        this.loadLockedRecords();
    }

    get i18n() { return getLabels(this.lang); }

    _isLockForm(name) {
        if (!name || name === 'All' || name === DELETED_FORMS_FILTER) return false;
        // Before getForms() answers, trust the parent; afterwards only accept lock forms.
        return !this.lockForms.length || this.lockForms.some((f) => f.developerName === name);
    }

    async _loadForms() {
        try {
            const forms = (await getFormsApex()) || [];
            this.lockForms = forms.filter((f) => f.hasLockField);
            // Follow the form the parent asked for if it turned out to be lockable.
            if (this._requestedForm && this.lockForms.some((f) => f.developerName === this._requestedForm)) {
                this._formName = this._requestedForm;
            }
            if (this.lockForms.length && !this.lockForms.some((f) => f.developerName === this._formName)) {
                this._formName = this.lockForms[0].developerName;
                this.pageOffset = 0;
            }
        } catch (e) {
            this.lockForms = [];
        }
    }

    // ── form picker ──────────────────────────────────────────────
    get showFormSelect() { return this.lockForms.length > 1; }

    get formOptions() {
        return this.lockForms.map((f) => ({
            value: f.developerName,
            label: f.label,
            selected: f.developerName === this._formName
        }));
    }

    get currentFormLabel() {
        const f = this.lockForms.find((x) => x.developerName === this._formName);
        return f ? f.label : this._formName;
    }

    handleFormSelect(event) {
        const next = event.target.value;
        if (!next || next === this._formName) return;
        this._formName = next;
        this.pageOffset = 0;
        this.loadLockedRecords();
    }

    // ── rows ─────────────────────────────────────────────────────
    get records() {
        const formLabel = this.currentFormLabel;
        return this._rawRecords.map((r) => {
            const blocked = !!r.isBlockedByOpenRequest;
            return {
                ...r,
                formLabel,
                since: formatDate(r.lockedDate, this.lang),
                hasTicket: !!r.latestRequestId,
                pillStyle: statusStyle(r.latestRequestStatus),
                statusText: statusLabel(this.i18n, r.latestRequestStatus),
                blocked,
                checked: this.selectedIds.has(r.recordId),
                rowClass: blocked ? 'duc-lk-row duc-lk-row_blocked' : 'duc-lk-row'
            };
        });
    }

    get hasRecords() { return this._rawRecords.length > 0; }
    get showSpinner() { return this.isLoading && !this._loadedOnce; }
    get isEmpty() { return this._loadedOnce && !this.hasRecords; }
    get emptyText() { return this.i18n.rdNoLocked; }

    get selectableIds() {
        return this._rawRecords.filter((r) => !r.isBlockedByOpenRequest).map((r) => r.recordId);
    }
    get selectedCount() { return this.selectedIds.size; }
    get hasAnySelected() { return this.selectedCount > 0; }
    get allSelectableSelected() {
        const ids = this.selectableIds;
        return ids.length > 0 && ids.every((id) => this.selectedIds.has(id));
    }
    get isSelectAllDisabled() { return this.isLoading || this.selectableIds.length === 0; }

    get unlockSelectedLabel() {
        return this.selectedCount ? format(this.i18n.rdUnlockNFmt, this.selectedCount) : this.i18n.rdUnlock;
    }
    get isUnlockSelectedDisabled() { return this.isLoading || this.isUnlocking || !this.hasAnySelected; }
    // "Unlock all" ignores the search box (it unlocks the whole form), so it is disabled while a
    // search is active — otherwise it would look like it only affects the filtered rows.
    get isUnlockAllDisabled() {
        return this.isLoading || this.isUnlocking || this.unlockableCount === 0 || !!(this.searchTerm || '').trim();
    }
    // Only accounts without an open ticket can be freed — the button counts those, not every lock.
    get unlockAllLabel() { return `${this.i18n.rdUnlockAll} (${this.unlockableCount})`; }
    get countText() { return `${this.totalCount} ${this.totalCount === 1 ? this.i18n.lockedAccountsOne : this.i18n.lockedAccountsTab}`; }

    // ── paging ───────────────────────────────────────────────────
    get currentPage() { return Math.floor(this.pageOffset / this.pageSize) + 1; }
    get totalPages() { return Math.max(1, Math.ceil(this.totalCount / this.pageSize)); }
    get pageLabel() { return `${this.currentPage}/${this.totalPages}`; }
    get showPageNav() { return this.totalPages > 1; }
    get isPrevDisabled() { return this.isLoading || this.pageOffset <= 0; }
    get isNextDisabled() { return this.isLoading || (this.pageOffset + this.pageSize) >= this.totalCount; }

    async loadLockedRecords() {
        // Only the newest call may write results — an older, slower response is dropped.
        const seq = (this._seq = (this._seq || 0) + 1);
        this.isLoading = true;
        this.selectedIds = new Set();
        try {
            const result = await getLockedRecordsApex({
                formName: this._formName,
                pageSize: this.pageSize,
                pageOffset: this.pageOffset,
                searchTerm: this.searchTerm
            });
            if (seq !== this._seq) return;
            if (result.success) {
                this._rawRecords = result.records || [];
                this.totalCount = result.totalCount || 0;
                // Not computed while searching (Unlock all is disabled then) — keep the last value.
                if (!(this.searchTerm || '').trim()) this.unlockableCount = result.unlockableCount || 0;
            } else {
                this._toast(this.i18n.toastActionErrorTitle, this.i18n.reviewErrGeneric, 'error');
            }
        } catch (e) {
            if (seq === this._seq) this._toast(this.i18n.toastActionErrorTitle, this.i18n.reviewErrGeneric, 'error');
        } finally {
            if (seq === this._seq) {
                this.isLoading = false;
                this._loadedOnce = true;
            }
        }
    }

    handleRefresh() {
        this.loadLockedRecords();
    }

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
        clearTimeout(this._searchTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._searchTimer = setTimeout(() => {
            this.pageOffset = 0;
            this.loadLockedRecords();
        }, SEARCH_DEBOUNCE_MS);
    }

    handleSearchKey(event) {
        if (event.key === 'Escape' && this.searchTerm) {
            event.target.value = '';
            this.handleSearchChange(event);
        }
    }

    handlePrevPage() {
        if (this.isPrevDisabled) return;
        this.pageOffset = Math.max(0, this.pageOffset - this.pageSize);
        this.loadLockedRecords();
    }

    handleNextPage() {
        if (this.isNextDisabled) return;
        this.pageOffset += this.pageSize;
        this.loadLockedRecords();
    }

    handlePageLabelClick() { this.editingPage = true; }
    handlePageLabelKey(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.editingPage = true;
        }
    }
    handlePageInputBlur() { this.editingPage = false; }

    handlePageInputKey(event) {
        if (event.key === 'Escape') { this.editingPage = false; return; }
        if (event.key !== 'Enter') return;
        const target = parseInt(event.target.value, 10);
        this.editingPage = false;
        if (isNaN(target) || target < 1 || target > this.totalPages) return;
        this.pageOffset = (target - 1) * this.pageSize;
        this.loadLockedRecords();
    }

    // ── selection ────────────────────────────────────────────────
    handleToggleSelectAll(event) {
        const next = new Set(this.selectedIds);
        this.selectableIds.forEach((id) => (event.target.checked ? next.add(id) : next.delete(id)));
        this.selectedIds = next;
    }

    handleRowCheckboxChange(event) {
        const id = event.currentTarget.dataset.id;
        const next = new Set(this.selectedIds);
        if (event.target.checked) next.add(id); else next.delete(id);
        this.selectedIds = next;
    }

    // ── unlock ───────────────────────────────────────────────────
    async handleUnlockSelected() {
        if (this.isUnlockSelectedDisabled) return;
        const ids = Array.from(this.selectedIds);
        this.isUnlocking = true;
        try {
            const results = await Promise.all(ids.map((recordId) =>
                unlockRecordApex({ recordId, formName: this._formName })
                    .then((r) => ({ ...r, recordId }))
                    .catch(() => ({ success: false, errorMessage: 'GENERIC_ERROR', recordId }))
            ));
            const unlockedCount = results.filter((r) => r.success).length;
            // Only an open ticket counts as "skipped" — any other failure is reported as an error.
            const skippedCount = results.filter((r) => !r.success && r.errorMessage === 'REQUEST_STILL_OPEN').length;
            const failedCount = results.length - unlockedCount - skippedCount;
            let message;
            if (failedCount > 0) {
                message = format(this.i18n.toastUnlockSelectedMixedMsgFmt, unlockedCount, skippedCount, failedCount);
            } else if (skippedCount > 0) {
                message = format(this.i18n.toastUnlockAllResultMsgFmt, unlockedCount, skippedCount);
            } else {
                message = format(this.i18n.toastUnlockAllSuccessMsgFmt, unlockedCount);
            }
            const variant = failedCount > 0 ? 'error' : (skippedCount > 0 ? 'warning' : 'success');
            this._toast(variant === 'success' ? this.i18n.toastUnlockSuccessTitle : this.i18n.toastUnlockPartialTitle, message, variant);
            this.loadLockedRecords();
            if (unlockedCount > 0) this._notifyLocksChanged();
        } finally {
            this.isUnlocking = false;
        }
    }

    async handleUnlockAll() {
        if (this.isUnlockAllDisabled) return;
        const ok = await DucConfirmModal.open({
            label: `${this.i18n.rdUnlockAll} — ${this.currentFormLabel} (${this.unlockableCount})`,
            message: this.i18n.unlockAllConfirmMsg,
            theme: 'warning',
            okLabel: this.i18n.confirmOk,
            cancelLabel: this.i18n.btnCancel
        });
        if (!ok) return;
        this.isUnlocking = true;
        try {
            const result = await unlockAllRecordsApex({ formName: this._formName });
            if (!result.success) {
                this._toast(this.i18n.toastActionErrorTitle, '', 'error');
                return;
            }
            const partial = result.skippedCount > 0;
            const message = partial
                ? format(this.i18n.toastUnlockAllResultMsgFmt, result.unlockedCount, result.skippedCount)
                : format(this.i18n.toastUnlockAllSuccessMsgFmt, result.unlockedCount);
            this._toast(partial ? this.i18n.toastUnlockPartialTitle : this.i18n.toastUnlockSuccessTitle, message, partial ? 'warning' : 'success');
            this.pageOffset = 0;
            this.loadLockedRecords();
            if (result.unlockedCount > 0) this._notifyLocksChanged();
        } catch (e) {
            this._toast(this.i18n.toastActionErrorTitle, '', 'error');
        } finally {
            this.isUnlocking = false;
        }
    }

    handleViewTicket(event) {
        const { requestId, requestName, requestNumber, requestStatus } = event.currentTarget.dataset;
        if (!requestId) return;
        // Same tab label as the request list (a person's name, not a ticket number).
        this.dispatchEvent(new CustomEvent('requestselect', {
            detail: { requestId, label: requestName || requestNumber, status: requestStatus, number: requestNumber }
        }));
    }

    // Lets the Center refresh open ticket panels / the request list (lock icon, status).
    _notifyLocksChanged() {
        this.dispatchEvent(new CustomEvent('lockschanged'));
    }

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
