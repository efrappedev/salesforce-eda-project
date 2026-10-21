import { LightningElement, api, track } from 'lwc';
import { getLabels, format } from 'c/dataUpdateI18n';
import {
    statusLabel, statusKey, formatDate, DEFAULT_DASH_COLORS, loadDashColors, saveDashColors
} from 'c/dataUpdateUi';
import getStatusCountsApex from '@salesforce/apex/DataUpdateReviewController.getStatusCounts';
import getFormsApex from '@salesforce/apex/DataUpdateFormAdminController.getForms';
import hasDeletedFormTicketsApex from '@salesforce/apex/DataUpdateReviewController.hasDeletedFormTickets';
import getFormResponseChecklistSinceApex from '@salesforce/apex/DataUpdateReviewController.getFormResponseChecklistSince';

const EMPTY_COUNTS = {
    total: 0, open: 0, new: 0, inReview: 0, onHold: 0,
    applied: 0, ignored: 0, closed: 0, reopened: 0, error: 0
};

const DELETED_FORMS_FILTER = '__DELETED_FORMS__';
const EGLISE_FORM_NAME = 'AEBEQ_Eglise_Update';
const MAX_FORM_CHIPS = 5;

const pad2 = (n) => String(n).padStart(2, '0');
const toIsoDate = (d) => `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;

// Same day N months back, clamped to the target month's last day (May 31 − 3 → Feb 28, not Mar 3).
function monthsAgo(now, n) {
    const first = new Date(now.getFullYear(), now.getMonth() - n, 1);
    const lastDay = new Date(first.getFullYear(), first.getMonth() + 1, 0).getDate();
    return new Date(first.getFullYear(), first.getMonth(), Math.min(now.getDate(), lastDay));
}

// Start date (yyyy-MM-dd) of a response period; '' = since the beginning.
function periodStartIso(period, customDate, now = new Date()) {
    switch (period) {
        case 'thisMonth': return toIsoDate(new Date(now.getFullYear(), now.getMonth(), 1));
        case 'last3Months': return toIsoDate(monthsAgo(now, 3));
        case 'last12Months': return toIsoDate(monthsAgo(now, 12));
        case 'custom': return customDate || '';
        default: return '';
    }
}

export default class RequestDashboard extends LightningElement {
    @api lang = 'fr';
    // The list's current status filter, so the matching bar shows as selected.
    @api statusName = '';

    @track isLoading = true;
    @track counts = { ...EMPTY_COUNTS };
    @track forms = [];
    @track formFilter = 'All';
    @track checklistStats = { responded: 0, total: 0 };
    @track showChecklistModal = false;
    @track checklistPeriod = 'all';
    @track checklistCustomDate = '';
    @track checklistSelectedForm = EGLISE_FORM_NAME;
    @track dashColors = loadDashColors();
    @track showColorPanel = false;
    @track draftColors = {};
    _loadedOnce = false;

    // Follows the request list's form filter so the chips and the list never disagree.
    @api
    get formName() { return this.formFilter; }
    set formName(value) {
        const next = value || 'All';
        if (next === this.formFilter) return;
        this.formFilter = next;
        if (this._loadedOnce) this.load();
    }

    async connectedCallback() {
        await this.loadForms();
        await Promise.all([this.load(), this.loadChecklistStats()]);
    }

    get i18n() { return getLabels(this.lang); }

    get hasStatusData() { return this.counts.total > 0; }

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
    }

    // Only a few form chips fit in the header — the rest go into a "+N more" menu. The
    // selected form is always kept visible as a chip, even when it lives in the overflow.
    get _chipSplit() {
        // Deleted-forms label resolved here so it follows the language toggle.
        const forms = this.forms.map((f) => ({
            label: f.developerName === DELETED_FORMS_FILTER ? this.i18n.filterDeletedForms : f.label,
            value: f.developerName
        }));
        if (forms.length <= MAX_FORM_CHIPS + 1) return { visible: forms, overflow: [] };
        const visible = forms.slice(0, MAX_FORM_CHIPS);
        const overflow = forms.slice(MAX_FORM_CHIPS);
        const idx = overflow.findIndex((f) => f.value === this.formFilter);
        if (idx >= 0) visible.push(overflow.splice(idx, 1)[0]);
        return { visible, overflow };
    }

    get formChips() {
        return [{ label: this.i18n.rdAllForms, value: 'All' }, ...this._chipSplit.visible].map((c) => ({
            ...c,
            pressed: String(this.formFilter === c.value),
            cls: 'duc-chip' + (this.formFilter === c.value ? ' duc-chip_on' : '')
        }));
    }

    get hasMoreForms() { return this._chipSplit.overflow.length > 0; }
    get moreFormsLabel() { return format(this.i18n.rdMoreFormsFmt, this._chipSplit.overflow.length); }
    get moreFormOptions() { return this._chipSplit.overflow; }

    handleMoreForms(event) {
        const value = event.target.value;
        event.target.value = '';
        if (!value || value === this.formFilter) return;
        this.formFilter = value;
        this.load();
        this._syncListForm();
    }

    get hasFormFilter() { return this.forms.length > 1; }

    get tiles() {
        const tile = (key, value, label, tone, status) => ({
            key, value, label, status,
            style: tone === 'text' ? '--c:var(--duc-text)' : `--c:var(--duc-${tone})`
        });
        return [
            tile('total', this.counts.total, this.i18n.rdTotal, 'text', 'All'),
            tile('open', this.counts.open, this.i18n.rdKOpen, 'brand', 'Open'),
            tile('applied', this.counts.applied, this.i18n.rdKApplied, 'applied', 'Applied'),
            tile('error', this.counts.error, this.i18n.rdKErrors, 'error', 'Error')
        ];
    }

    get checklistPct() {
        const { responded, total } = this.checklistStats;
        const pct = total ? Math.round((responded / total) * 1000) / 10 : 0;
        return `width:${pct}%`;
    }

    get churchTileStyle() { return '--c:var(--duc-applied)'; }

    // The responses card only covers church forms; it ignores the dashboard form filter and
    // has its own form picker inside the modal (defaults to the église form).
    get churchForms() { return this.forms.filter((f) => f.isChurchForm); }

    get checklistFormOptions() {
        return this.churchForms.map((f) => ({ label: f.label, value: f.developerName }));
    }

    get _checklistForm() {
        const forms = this.churchForms;
        return forms.find((f) => f.developerName === this.checklistSelectedForm)
            || forms.find((f) => f.developerName === EGLISE_FORM_NAME)
            || forms[0]
            || null;
    }

    get showChecklistCard() { return !!this._checklistForm; }

    get checklistFormName() { return this._checklistForm ? this._checklistForm.developerName : ''; }

    get checklistFormLabel() { return this._checklistForm ? this._checklistForm.label : ''; }

    get checklistSinceIso() { return periodStartIso(this.checklistPeriod, this.checklistCustomDate); }

    get checklistPeriodLabel() {
        if (this.checklistPeriod === 'custom') {
            if (!this.checklistCustomDate) return this.i18n.periodAll;
            const [y, m, d] = this.checklistCustomDate.split('-').map(Number);
            return `${this.i18n.periodSinceShort} ${formatDate(new Date(y, m - 1, d), this.lang)}`;
        }
        const keys = { thisMonth: 'periodThisMonth', last3Months: 'periodLast3Months', last12Months: 'periodLast12Months' };
        return this.i18n[keys[this.checklistPeriod] || 'periodAll'];
    }

    get checklistCardSubtitle() { return `${this.checklistFormLabel} · ${this.checklistPeriodLabel}`; }

    get checklistValueLabel() {
        return `${this.checklistStats.responded}/${this.checklistStats.total}`;
    }

    get statusBars() {
        const rows = [
            ['new', 'New'], ['inReview', 'In Review'], ['onHold', 'On Hold'], ['reopened', 'Reopened'],
            ['applied', 'Applied'], ['ignored', 'Ignored'], ['closed', 'Closed'], ['error', 'Error']
        ].filter(([key]) => key !== 'closed' || this.counts.closed > 0);
        const max = Math.max(1, ...rows.map(([key]) => this.counts[key] || 0));
        return rows.map(([key, status]) => {
            const count = this.counts[key] || 0;
            return {
                key,
                status,
                count,
                label: statusLabel(this.i18n, status),
                cls: 'duc-barrow' + (this.statusName === status ? ' duc-barrow_on' : ''),
                pressed: this.statusName === status ? 'true' : 'false',
                style: `--sc:${this.dashColors[statusKey(status)]}`,
                width: `width:${Math.round((count / max) * 100)}%`
            };
        });
    }

    // ── Color panel (pencil next to refresh) — only the dashboard bars use these colors ──

    get colorPanelRows() {
        const rows = [
            ['new', 'New'], ['review', 'In Review'], ['hold', 'On Hold'], ['reopen', 'Reopened'],
            ['applied', 'Applied'], ['ignored', 'Ignored'], ['error', 'Error']
        ];
        return rows.map(([key, status]) => ({
            key,
            label: key === 'ignored'
                ? `${statusLabel(this.i18n, 'Ignored')} / ${statusLabel(this.i18n, 'Closed')}`
                : statusLabel(this.i18n, status),
            color: this.draftColors[key],
            swatchStyle: `background:${this.draftColors[key]}`
        }));
    }

    handleOpenColorPanel() {
        this.draftColors = { ...this.dashColors };
        this.showColorPanel = true;
    }

    handleCloseColorPanel() {
        this.showColorPanel = false;
    }

    handleColorInput(event) {
        this.draftColors = { ...this.draftColors, [event.target.dataset.key]: event.target.value };
    }

    handleColorReset() {
        this.draftColors = { ...DEFAULT_DASH_COLORS };
    }

    handleColorSave() {
        this.dashColors = { ...this.draftColors };
        saveDashColors(this.dashColors);
        this.showColorPanel = false;
    }

    handleColorPanelKey(event) {
        if (event.key === 'Escape') {
            event.stopPropagation();
            this.handleCloseColorPanel();
        }
    }

    handleColorBackdrop(event) {
        if (event.target === event.currentTarget) this.handleCloseColorPanel();
    }

    @api
    refresh() {
        this.load();
        this.loadChecklistStats();
    }

    async load() {
        // Spinner only on first load — later refreshes update the numbers in place.
        if (!this._loadedOnce) this.isLoading = true;
        // Fast chip clicks: only the newest response may paint the counts.
        const seq = (this._seq = (this._seq || 0) + 1);
        try {
            const raw = await getStatusCountsApex({ formDeveloperName: this.formFilter });
            if (seq !== this._seq) return;
            this.counts = {
                total: raw.Total || 0,
                open: raw.Open || 0,
                new: raw.New || 0,
                inReview: raw['In Review'] || 0,
                onHold: raw['On Hold'] || 0,
                applied: raw.Applied || 0,
                ignored: raw.Ignored || 0,
                closed: raw.Closed || 0,
                reopened: raw.Reopened || 0,
                error: raw.Error || 0
            };
        } catch (e) {
            if (seq === this._seq) this.counts = { ...EMPTY_COUNTS };
        } finally {
            if (seq === this._seq) {
                this._loadedOnce = true;
                this.isLoading = false;
            }
        }
    }

    async loadChecklistStats() {
        const formName = this.checklistFormName;
        if (!formName) return;
        const sinceIsoDate = this.checklistSinceIso;
        try {
            const result = await getFormResponseChecklistSinceApex({ formName, sinceIsoDate });
            if (formName !== this.checklistFormName || sinceIsoDate !== this.checklistSinceIso) return;
            const items = (result && result.items) || [];
            this.checklistStats = {
                responded: items.filter((i) => i.responded).length,
                total: items.length
            };
        } catch (e) {
            this.checklistStats = { responded: 0, total: 0 };
        }
    }

    handleRefresh() {
        this.load();
        this.loadChecklistStats();
    }

    handleFormChip(event) {
        const value = event.currentTarget.dataset.value;
        if (value === this.formFilter) return;
        this.formFilter = value;
        this.load();
        this._syncListForm();
    }

    // A form chip also filters the request list, so both sides always show the same form.
    _syncListForm() {
        this.dispatchEvent(new CustomEvent('statusfilter', { detail: { status: null, form: this.formFilter } }));
    }

    // Tiles and status rows filter the request list on the left.
    handleStatusClick(event) {
        this.dispatchEvent(new CustomEvent('statusfilter', {
            detail: { status: event.currentTarget.dataset.status, form: this.formFilter }
        }));
    }

    handleChecklistFormChange(event) {
        this.checklistSelectedForm = event.detail.formName;
        this.checklistStats = { responded: 0, total: 0 };
        this.loadChecklistStats();
    }

    handleChecklistPeriodChange(event) {
        const { period, customDate } = event.detail;
        this.checklistPeriod = period;
        this.checklistCustomDate = customDate || '';
        this.loadChecklistStats();
    }

    handleOpenChecklist() {
        this.showChecklistModal = true;
    }

    handleCloseChecklist() {
        this.showChecklistModal = false;
    }

    handleChurchKey(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleOpenChecklist();
        }
    }
}
