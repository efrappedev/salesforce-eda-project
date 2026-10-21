import { LightningElement, api, track } from 'lwc';
import { getLabels, format } from 'c/dataUpdateI18n';
import { formatDate } from 'c/dataUpdateUi';
import getFormResponseChecklistSinceApex from '@salesforce/apex/DataUpdateReviewController.getFormResponseChecklistSince';

const PICK_DATE = '__pick__';

export default class DataUpdateResponseChecklist extends LightningElement {
    @api lang = 'fr';
    @api formOptions = [];

    // Church form chosen in the modal; changing it reloads the list.
    @api
    get formName() { return this._formName; }
    set formName(value) {
        const changed = (value || '') !== this._formName;
        this._formName = value || '';
        if (changed && this._connected) this.loadChecklist();
    }
    _formName = '';
    @api formLabel = '';
    @api period = 'all';
    @api customDate = '';

    // Period start chosen on the dashboard; changing it reloads the list.
    @api
    get sinceIso() { return this._sinceIso; }
    set sinceIso(value) {
        const changed = (value || '') !== this._sinceIso;
        this._sinceIso = value || '';
        if (changed && this._connected) this.loadChecklist();
    }
    _sinceIso = '';
    _connected = false;

    @track isLoading = true;
    @track searchTerm = '';
    @track statusFilter = 'All';
    _items = [];

    connectedCallback() {
        this._connected = true;
        this.loadChecklist();
    }

    renderedCallback() {
        if (this.showDatePicker && !this._dateFocused) {
            const d = this.template.querySelector('.duc-cl-date-input');
            if (d) { d.focus(); this._dateFocused = true; }
        }
        if (!this.showDatePicker) this._dateFocused = false;
        if (this._focused) return;
        const close = this.template.querySelector('.duc-cl-x');
        if (close) { close.focus(); this._focused = true; }
    }

    get i18n() { return getLabels(this.lang); }

    async loadChecklist() {
        this.isLoading = true;
        // Only the newest call may write results or end the spinner.
        const seq = (this._seq = (this._seq || 0) + 1);
        try {
            const result = await getFormResponseChecklistSinceApex({
                formName: this._formName, sinceIsoDate: this._sinceIso
            });
            if (seq !== this._seq) return;
            this._items = (result && result.items) || [];
        } catch (e) {
            if (seq === this._seq) this._items = [];
        } finally {
            if (seq === this._seq) this.isLoading = false;
        }
    }

    get hasFormChoice() { return (this.formOptions || []).length > 1; }

    handleFormChange(event) {
        this.dispatchEvent(new CustomEvent('formchange', { detail: { formName: event.target.value } }));
    }

    get formSelectOptions() {
        return (this.formOptions || []).map((o) => ({ ...o, selected: o.value === this._formName }));
    }

    // "Since a date" isn't picked inline (it would push the toolbar around): choosing
    // PICK_DATE opens a small date dialog, and the chosen date then shows as its own option.
    get periodOptions() {
        const opts = [
            { label: this.i18n.periodAll, value: 'all' },
            { label: this.i18n.periodThisMonth, value: 'thisMonth' },
            { label: this.i18n.periodLast3Months, value: 'last3Months' },
            { label: this.i18n.periodLast12Months, value: 'last12Months' }
        ];
        if (this.period === 'custom' && this.customDate) {
            opts.push({ label: this.customDateLabel, value: 'custom' });
        }
        opts.push({ label: this.i18n.periodPickDate, value: PICK_DATE });
        return opts.map((o) => ({ ...o, selected: o.value === this.period }));
    }

    get customDateLabel() {
        const [y, m, d] = (this.customDate || '').split('-').map(Number);
        if (!y) return '';
        return `${this.i18n.periodSinceDate} ${formatDate(new Date(y, m - 1, d), this.lang)}`;
    }

    get periodLabel() {
        if (this.period === 'custom') return this.customDateLabel;
        const p = this.periodOptions.find((o) => o.value === this.period);
        return p ? p.label : '';
    }

    get subtitle() {
        return [this.formLabel, this.periodLabel].filter(Boolean).join(' · ');
    }

    @track showDatePicker = false;
    @track draftDate = '';

    handlePeriodChange(event) {
        const period = event.target.value;
        if (period === PICK_DATE) {
            event.target.value = this.period;
            const now = new Date();
            const today = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
            this.draftDate = this.customDate || today;
            this.showDatePicker = true;
            return;
        }
        this.dispatchEvent(new CustomEvent('periodchange', { detail: { period, customDate: '' } }));
    }

    handleDraftDate(event) { this.draftDate = event.target.value || ''; }
    get isDateApplyDisabled() { return !this.draftDate; }

    handleDateCancel() {
        this.showDatePicker = false;
    }

    handleDateApply() {
        if (!this.draftDate) return;
        this.showDatePicker = false;
        this.dispatchEvent(new CustomEvent('periodchange', {
            detail: { period: 'custom', customDate: this.draftDate }
        }));
    }

    handleDateKey(event) {
        if (event.key === 'Enter') this.handleDateApply();
    }

    get statusSegments() {
        const total = this.totalCount;
        const yes = this.respondedCount;
        return [
            { value: 'All', label: this.i18n.filterAll, count: total },
            { value: 'Responded', label: this.i18n.checklistRespondedLabel, count: yes },
            { value: 'NotResponded', label: this.i18n.checklistNotRespondedLabel, count: total - yes }
        ].map((o) => ({
            ...o,
            pressed: String(o.value === this.statusFilter),
            cls: 'duc-cl-seg' + (o.value === this.statusFilter ? ' duc-cl-seg_on' : '')
        }));
    }

    get filteredItems() {
        const term = this.searchTerm.trim().toLowerCase();
        let items = term
            ? this._items.filter((it) => (it.recordName || '').toLowerCase().includes(term))
            : this._items;
        if (this.statusFilter === 'Responded') {
            items = items.filter((it) => it.responded);
        } else if (this.statusFilter === 'NotResponded') {
            items = items.filter((it) => !it.responded);
        }
        return items.map((it) => ({
            recordId: it.recordId,
            recordName: it.recordName,
            responded: it.responded,
            dateText: it.lastResponse ? formatDate(it.lastResponse, this.lang) : '',
            rowClass: it.responded ? 'duc-cl-row duc-cl-row_yes' : 'duc-cl-row',
            iconName: it.responded ? 'check' : 'x',
            statusAlt: it.responded ? this.i18n.checklistRespondedLabel : this.i18n.checklistNotRespondedLabel
        }));
    }

    get hasItems() { return this.filteredItems.length > 0; }
    get isEmpty() { return !this.isLoading && this.filteredItems.length === 0; }

    get totalCount() { return this._items.length; }
    get respondedCount() { return this._items.filter((it) => it.responded).length; }

    get pctStyle() {
        const pct = this.totalCount ? Math.round((this.respondedCount / this.totalCount) * 100) : 0;
        return `width:${pct}%`;
    }

    get summaryText() {
        return format(this.i18n.checklistSummaryFmt, this.respondedCount, this.totalCount);
    }

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
    }

    handleStatusSegment(event) {
        this.statusFilter = event.currentTarget.dataset.value;
    }

    handleKeydown(event) {
        if (event.key === 'Escape') {
            event.stopPropagation();
            if (this.showDatePicker) this.handleDateCancel();
            else this.handleClose();
        }
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }
}
