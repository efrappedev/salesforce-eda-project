import { LightningElement, api, track } from 'lwc';
import DucConfirmModal from 'c/ducConfirmModal';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getLabels, format } from 'c/dataUpdateI18n';
import {
    statusStyle, statusKey, toneStyle, statusLabel, ticketNumber, initials, formatDate, formatDateTime, isOpenStatus
} from 'c/dataUpdateUi';
import getComparisonDataApex from '@salesforce/apex/DataUpdateReviewController.getComparisonData';
import applySelectedUpdatesApex from '@salesforce/apex/DataUpdateReviewController.applySelectedUpdatesWithOptions';
import correctProposedValueApex from '@salesforce/apex/DataUpdateReviewController.correctProposedValue';
import { isPostalCodeField, countryFieldFor, formatPostalCode, isInvalidPostalCode } from 'c/dataUpdatePostalCode';
import getAuditLogApex from '@salesforce/apex/DataUpdateReviewController.getAuditLog';
import rollbackChangesApex from '@salesforce/apex/DataUpdateReviewController.rollbackChanges';
import unlockRecordApex from '@salesforce/apex/DataUpdateReviewController.unlockRecord';
import holdRequestApex from '@salesforce/apex/DataUpdateReviewController.holdRequest';
import resumeRequestApex from '@salesforce/apex/DataUpdateReviewController.resumeRequest';
import ignoreRequestApex from '@salesforce/apex/DataUpdateReviewController.ignoreRequest';
import reopenRequestApex from '@salesforce/apex/DataUpdateReviewController.reopenRequest';
import heartbeatApex from '@salesforce/apex/DataUpdateReviewController.heartbeat';
import leaveRequestApex from '@salesforce/apex/DataUpdateReviewController.leaveRequest';

const HEARTBEAT_MS = 30000;
const ALL_FIELDS = '*';

const ACTION_TONES = {
    APPLY_COMPLETED: { tone: 'applied', icon: 'check', key: 'rdActApplied' },
    APPLY_ERROR: { tone: 'error', icon: 'x', key: 'rdActError' },
    ROLLBACK_COMPLETED: { tone: 'reopen', icon: 'rewind', key: 'rdActRolledBack' },
    CORRECTED: { tone: 'review', icon: 'pen', key: 'rdActCorrected' }
};

const MODE_STATUS = { inReview: 'In Review', onHold: 'On Hold', ignore: 'Ignored' };
// Server-side value checks on a correction (DataUpdateFormConfigService.validateFieldValue).
const EDIT_ERROR_KEYS = {
    INVALID_DATE: 'editInvalidDate',
    INVALID_NUMBER: 'editInvalidNumber',
    INVALID_BOOLEAN: 'editInvalidBoolean',
    INVALID_EMAIL: 'editInvalidEmail',
    INVALID_PICKLIST: 'editInvalidPicklist',
    VALUE_TOO_LONG: 'editValueTooLong'
};
// Thrown when another staff member changed the ticket's status first.
const isStaleStatusError = (e) => {
    const msg = (e && e.body && e.body.message) || '';
    return msg === 'TICKET_ALREADY_CLOSED' || msg === 'TICKET_STILL_OPEN';
};

export default class RequestReviewPanel extends LightningElement {
    @api recordId;
    @api requestLabel = '';
    @api requestStatus = '';
    @api lang = 'fr';
    // Open tickets of the same record (only sent for staff with Data_Update_Multi_Ticket_Review).
    @api groupCount = 0;

    @track isLoading = true;
    @track isApplying = false;
    @track errorMessage = '';
    @track data = null;
    @track selected = {};
    // History tables: key → { rowIndex: true } for the lines staff keep. A kept same-date line
    // overwrites the existing record; the others create one record each.
    @track tableSel = {};
    // Email / phone rows: field picked in "Save in" (only when not its own), and the row marked
    // "Preferred" per kind ({EMAIL: fieldApiName, PHONE: fieldApiName}).
    @track places = {};
    @track preferredRow = {};
    openNote = null;
    @track auditEntries = [];
    @track isRollingBack = false;
    @track confirmingRollbackKey = null;
    @track subTab = 'update';
    @track isUnlocking = false;
    @track isReopening = false;
    @track showSame = false;
    @track viewers = [];

    // status popover
    @track isPopOpen = false;
    @track exceptionMode = null; // null | 'inReview' | 'onHold' | 'ignore'
    @track exceptionReason = '';
    @track closedReason = '';
    @track isSubmittingException = false;
    _focusNote = false;

    // inline correction
    @track editingFieldApiName = null;
    @track editDraftValue = '';
    @track isSavingEdit = false;
    _focusEdit = false;

    // ticket-level rollback ("Annuler les modifications")
    @track rbAsk = false;
    _rollbackAskToken = null;

    _active = false;
    _heartbeatTimer = null;
    _connected = false;

    connectedCallback() {
        this._connected = true;
        this._loadData();
        if (this._active) this._startPresence();
    }

    disconnectedCallback() {
        this._connected = false;
        this._stopPresence(true);
    }

    // Called from dataUpdateCenter when this request's status changes from outside this panel.
    @api
    refresh() {
        this._loadData();
    }

    @api
    get active() { return this._active; }
    set active(value) {
        const next = !!value;
        if (next === this._active) return;
        this._active = next;
        if (!this._connected) return;
        if (next) this._startPresence();
        else this._stopPresence(true);
    }

    // Opening the ticket from the list's rollback quick action asks right away.
    @api
    get rollbackAskToken() { return this._rollbackAskToken; }
    set rollbackAskToken(value) {
        if (value && value !== this._rollbackAskToken) {
            this.rbAsk = true;
            this.subTab = 'update';
        }
        this._rollbackAskToken = value;
    }

    get i18n() { return getLabels(this.lang); }

    // ── Presence ─────────────────────────────────────────────────────────────

    _startPresence() {
        this._stopPresence(false);
        this._presenceGen = (this._presenceGen || 0) + 1;
        this._beat();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._heartbeatTimer = setInterval(() => this._beat(), HEARTBEAT_MS);
    }

    _stopPresence(leave) {
        // A heartbeat already in flight must not repaint viewers after we stopped.
        this._presenceGen = (this._presenceGen || 0) + 1;
        if (this._heartbeatTimer) {
            clearInterval(this._heartbeatTimer);
            this._heartbeatTimer = null;
            if (leave && this.recordId) {
                leaveRequestApex({ requestId: this.recordId }).catch(() => {});
            }
        }
        this.viewers = [];
    }

    async _beat() {
        if (!this.recordId || document.hidden) return;
        const gen = this._presenceGen;
        try {
            const names = await heartbeatApex({ requestId: this.recordId });
            if (gen !== this._presenceGen) return;
            this.viewers = names || [];
        } catch (e) {
            // presence is best-effort — never surfaces errors
        }
    }

    get hasViewers() { return this.viewers.length > 0; }
    get viewerInitials() { return initials(this.viewers[0]); }
    get viewingText() {
        const fmt = this.viewers.length > 1 ? this.i18n.rdViewingManyFmt : this.i18n.rdViewingFmt;
        return format(fmt, this.viewers.join(', '));
    }

    // ── Header ───────────────────────────────────────────────────────────────

    get hasError() { return !!this.errorMessage; }
    get hasData() { return !!(this.data && this.data.success); }
    get isFormDeleted() { return !!(this.data && this.data.formDeleted); }
    get isRequestClosed() {
        if (this.data) return !!this.data.requestClosed;
        return !isOpenStatus(this.requestStatus);
    }
    get isLocked() { return !!(this.data && this.data.isLocked); }

    get showGroupBanner() { return this.hasData && !this.isRequestClosed && (this.groupCount || 0) > 1; }
    get groupBannerText() { return format(this.i18n.grpBannerFmt, this.groupCount); }
    get groupBannerBtn() { return format(this.i18n.grpReviewTogetherFmt, this.groupCount); }

    handleMultiTicketReview() {
        this.dispatchEvent(new CustomEvent('groupselect', {
            detail: { targetRecordId: this.data.recordId, name: this.data.recordName, count: this.groupCount }
        }));
    }
    get otherOpenNumber() { return (this.data && this.data.otherOpenRequestNumber) || ''; }
    get canUnlock() { return this.isLocked && this.isRequestClosed && !this.otherOpenNumber; }
    get unlockDisabled() { return this.isUnlocking || !this.canUnlock; }
    get unlockTitle() { return this.canUnlock ? '' : this.unlockHintText; }
    get showUnlockHint() { return this.isLocked && !this.canUnlock; }
    get unlockHintText() {
        return this.otherOpenNumber
            ? format(this.i18n.rdUnlockHintOtherFmt, this.otherOpenNumber)
            : this.i18n.rdUnlockHint;
    }

    get titleText() {
        return this.requestLabel || (this.data && (this.data.recordName || this.data.requestedName)) || '';
    }
    get formLabelDisplay() {
        const label = (this.data && this.data.formLabel) || '';
        if (!this.isFormDeleted) return label;
        return label ? `${label} (${this.i18n.formDeletedLabel})` : this.i18n.formDeletedLabel;
    }
    get tno() { return ticketNumber(this.data && this.data.requestNumber); }
    get hasTno() { return !!(this.data && this.data.requestNumber); }
    get submittedByText() {
        if (!this.data || !this.data.requestedName) return '';
        const email = this.data.requestedEmail ? ` · ${this.data.requestedEmail}` : '';
        return `${this.i18n.rdSubmittedBy} ${this.data.requestedName}${email}`;
    }
    get submittedDate() { return formatDateTime(this.data && this.data.createdDate, this.lang); }
    // The server status wins: the list row that opened this tab can be stale.
    get currentStatus() { return (this.data && this.data.status) || this.requestStatus; }
    get statusText() { return statusLabel(this.i18n, this.currentStatus); }
    get statusPillStyle() { return statusStyle(this.currentStatus); }

    // ── Sub tabs ─────────────────────────────────────────────────────────────

    get isUpdateTab() { return this.subTab === 'update'; }
    get isHistoryTab() { return this.subTab === 'history'; }
    get updateTabSelected() { return String(this.isUpdateTab); }
    get historyTabSelected() { return String(this.isHistoryTab); }
    get updateTabClass() { return 'duc-stab' + (this.isUpdateTab ? ' duc-stab_on' : ''); }
    get historyTabClass() { return 'duc-stab' + (this.isHistoryTab ? ' duc-stab_on' : ''); }
    get changedCount() { return this.hasData ? this.data.fields.length + this._tableRowCount : 0; }
    get _tables() { return (this.hasData && this.data.tables) || []; }
    get _tableRowCount() { return this._tables.reduce((n, t) => n + t.rows.length, 0); }
    get historyCount() { return this.auditEntries.length; }

    handleSubTab(event) {
        this.subTab = event.currentTarget.dataset.tab;
        this.confirmingRollbackKey = null;
    }

    // ── Changed fields ───────────────────────────────────────────────────────

    get hasFields() { return this.hasData && this.data.fields.length > 0; }
    get hasTables() { return this._tables.length > 0; }
    get showNoFields() { return this.hasData && !this.hasFields && !this.hasTables; }

    // ── History tables ───────────────────────────────────────────────────────

    _fmtCell(value, col) {
        if (value === null || value === undefined || value === '') return '—';
        if (col && col.kind === 'Checkbox') return value === 'true' ? '✓' : '✗';
        if (col && col.kind === 'Date') {
            const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(value);
            if (m) {
                return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]))
                    .toLocaleDateString(this.lang === 'en' ? 'en-CA' : 'fr-CA', { year: 'numeric', month: 'short', day: 'numeric' });
            }
        }
        if (col && col.kind === 'Picklist') {
            const o = (col.picklistOptions || []).find((x) => x.value === value);
            if (o) return o.label;
        }
        return value;
    }

    get tableViews() {
        return this._tables.map((t) => {
            const sel = this.tableSel[t.key] || {};
            const cols = t.columns || [];
            let kept = 0;
            const rows = t.rows.map((r) => {
                const checked = !!sel[r.index];
                if (checked) kept++;
                const dup = r.isDuplicate === true;
                const same = dup && JSON.stringify(r.cells) === JSON.stringify(r.existingCells || []);
                let action = this.i18n.rdTblCreate;
                let actionClass = 'duc-tchip duc-tchip_create';
                if (!checked) {
                    action = this.i18n.rdTblExclude;
                    actionClass = 'duc-tchip duc-tchip_off';
                } else if (dup) {
                    action = this.i18n.rdTblOverwrite;
                    actionClass = 'duc-tchip duc-tchip_over';
                }
                return {
                    key: t.key + ':' + r.index,
                    index: r.index,
                    checked,
                    isDuplicate: dup,
                    same,
                    rowClass: 'duc-trow' + (checked ? '' : ' duc-trow_off') + (dup ? ' duc-trow_dup' : ''),
                    cells: cols.map((c, j) => ({ key: 'c' + j, value: this._fmtCell(r.cells[j], c) })),
                    existing: dup ? cols.map((c, j) => ({ key: 'e' + j, value: this._fmtCell((r.existingCells || [])[j], c) })) : [],
                    action,
                    actionClass,
                    ariaLabel: format(this.i18n.rdTblLineFmt, r.index + 1)
                };
            });
            return {
                key: t.key,
                title: this._localizedLabel(t.titleFr, t.titleEn) || t.objectLabel,
                countText: format(this.i18n.rdTblSelectedFmt, kept, t.rows.length),
                hasDuplicates: t.duplicateCount > 0,
                dupText: format(this.i18n.rdTblDupFmt, t.duplicateCount),
                previouslyRolledBack: t.previouslyRolledBack === true,
                gridStyle: 'grid-template-columns: 28px repeat(' + cols.length + ', minmax(70px, 1fr)) 90px;',
                headers: cols.map((c, j) => ({ key: 'h' + j, label: this._localizedLabel(c.labelFr, c.labelEn) || c.apiName })),
                rows
            };
        });
    }

    handleTableRowToggle(event) {
        const { table, index } = event.currentTarget.dataset;
        const cur = { ...(this.tableSel[table] || {}), [index]: event.target.checked };
        this.tableSel = { ...this.tableSel, [table]: cur };
    }

    handleTableSelect(event) {
        if (this.selectionLocked) return;
        const { table, mode } = event.currentTarget.dataset;
        const t = this._tables.find((x) => x.key === table);
        if (!t) return;
        const next = {};
        t.rows.forEach((r) => {
            next[r.index] = mode === 'all' || (mode === 'new' && r.isDuplicate !== true);
        });
        this.tableSel = { ...this.tableSel, [table]: next };
    }

    _initialTableSel(result) {
        const out = {};
        (result.tables || []).forEach((t) => {
            const sel = {};
            // Same-date lines start excluded: overwriting an existing record is a deliberate choice.
            t.rows.forEach((r) => { sel[r.index] = !result.requestClosed && r.isDuplicate !== true; });
            out[t.key] = sel;
        });
        return out;
    }

    _tableSelections() {
        const out = {};
        Object.keys(this.tableSel).forEach((key) => {
            const sel = this.tableSel[key];
            const idx = Object.keys(sel).filter((i) => sel[i]).map(Number);
            if (idx.length) out[key] = idx;
        });
        return out;
    }

    get _selectedTableRows() {
        return Object.values(this._tableSelections()).reduce((n, list) => n + list.length, 0);
    }

    get correctedFields() {
        const set = new Set();
        this.auditEntries.forEach((e) => {
            if (e.actionType === 'CORRECTED') {
                (e.fieldChanges || []).forEach((c) => set.add(c.fieldApiName));
            }
        });
        return set;
    }

    get changeRows() {
        if (!this.hasData) return [];
        const corrected = this.correctedFields;
        const closed = this.isRequestClosed;
        const mains = { EMAIL: this._mainConflict('EMAIL'), PHONE: this._mainConflict('PHONE') };
        const clash = this._placeClash();
        return this.data.fields.map((f) => {
            const kind = f.saveKind === 'PHONE' ? 'PHONE' : 'EMAIL';
            const { mainRow, mainMoved, conflictRow } = mains[kind];
            const conflictGone = !conflictRow;
            const prefRow = this.preferredRow[kind] ? this.data.fields.find((x) => x.fieldApiName === this.preferredRow[kind]) : null;
            const txt = (name) => this._kindText(kind, name);
            const checked = !!this.selected[f.fieldApiName];
            const isEditing = this.editingFieldApiName === f.fieldApiName;
            const cur = this._withDate(f.currentValue, f.isHistoryOnly ? f.currentValueDate : null);
            const sub = this._withDate(f.submittedValue, f.isHistoryOnly ? f.historyDate : null);
            const historize = !!f.isHistorize;
            const hasLast = historize && !!(f.historyLastValue || f.historyLastDate);
            const label = this._localizedLabel(f.fieldLabelFr, f.fieldLabelEn);
            const save = this._saveControl(f, checked && !closed);
            let edaNote = '';
            let edaWarn = !!f.emailPreferenceUnknown;
            if (f.emailPreferenceUnknown) {
                edaNote = format(txt('PreferenceUnknownFmt'), f.emailPreferenceUnknown);
            } else if (clash.has(f.fieldApiName)) {
                edaNote = format(this.i18n.rdSamePlaceFmt, this._placeLabel(f));
                edaWarn = true;
            } else if (f === conflictRow) {
                // Same warning on both rows; this row's value is the one left out.
                edaNote = format(txt('ConflictFmt'), this._localizedLabel(mainRow.fieldLabelFr, mainRow.fieldLabelEn), label);
                edaWarn = true;
                save.prefDisabled = true;
            } else if (save.replacesNote) {
                edaNote = save.replacesNote;
                edaWarn = true;
            } else if (f.savedInFieldApiName && mainMoved) {
                edaNote = '';
                edaWarn = false;
            } else if (f.savedInFieldApiName && !conflictGone) {
                // Same warning on both rows: Email and the field it collides with.
                edaNote = format(txt('SavedInFmt'), this._localizedLabel(f.savedInLabelFr, f.savedInLabelEn)) + ' '
                    + format(txt('ConflictFmt'), label, this._localizedLabel(conflictRow.fieldLabelFr, conflictRow.fieldLabelEn));
                edaWarn = true;
            } else if (f.savedInFieldApiName && prefRow && prefRow !== f && this.selected[prefRow.fieldApiName]) {
                edaNote = format(txt('NotMainFmt'), this._localizedLabel(prefRow.fieldLabelFr, prefRow.fieldLabelEn));
                edaWarn = true;
            } else if (f.savedInFieldApiName) {
                edaNote = format(txt('SavedInFmt'), this._localizedLabel(f.savedInLabelFr, f.savedInLabelEn));
                edaWarn = false;
            } else if (f.emailConflict && !mainRow && checked) {
                // Email (Phone) itself unchanged: this field is the main one, so changing it changes Email too.
                edaNote = txt('AlsoChangesMain');
                edaWarn = true;
            }
            return {
                key: f.fieldApiName,
                fieldApiName: f.fieldApiName,
                label,
                rowClass: 'duc-chg' + (historize ? ' duc-chg_hist' : '') + (checked ? '' : ' duc-chg_off'),
                hasEdaNote: !!edaNote && !edaWarn,
                hasSaveLine: save.hasSaveCtl || (!!edaNote && edaWarn),
                edaNote,
                edaNoteClass: 'duc-eda' + (edaWarn ? ' duc-eda_warn' : ''),
                // Warnings fold into a small red "⚠ Check" button; the text opens on click.
                edaIsWarn: !!edaNote && edaWarn,
                edaOpen: edaWarn && this.openNote === f.fieldApiName,
                edaExpanded: String(edaWarn && this.openNote === f.fieldApiName),
                ...save,
                checked,
                isHistoryOnly: !!f.isHistoryOnly,
                previouslyRolledBack: !!f.previouslyRolledBack,
                isCorrected: corrected.has(f.fieldApiName),
                isHistorize: historize,
                curText: historize ? this.i18n.rdNewRecord : (cur || this.i18n.rdEmpty),
                curClass: historize ? 'duc-v duc-v_newrec' : 'duc-v duc-v_old' + (cur ? '' : ' duc-v_empty'),
                histObject: f.historyObjectLabel,
                histTrend: hasLast ? this._trendText(f.submittedValue, f.historyLastValue, f.historyLastDate) : '',
                histNewRowClass: 'duc-hl-row' + (checked ? '' : ' duc-hl-row_skip'),
                histNewDate: this._dateOnly(f.historyDate),
                histNewValue: f.submittedValue || this.i18n.rdEmpty,
                histNewTag: !checked ? this.i18n.rdHistNotAdded : (hasLast ? this.i18n.rdHistNew : this.i18n.rdHistNewFirst),
                histHasLast: hasLast,
                histLastDate: this._dateOnly(f.historyLastDate),
                histLastValue: f.historyLastValue || this.i18n.rdEmpty,
                subText: sub || this.i18n.rdEmpty,
                subClass: 'duc-v duc-v_new' + (sub ? '' : ' duc-v_empty'),
                isEditing,
                showPen: !closed,
                penDisabled: this.isApplying || (this.editingFieldApiName !== null && !isEditing)
            };
        });
    }

    // ── "Save in" / "Preferred" (email and phone rows) ───────────────────────

    _saveGroup(f) {
        const groups = (this.data && this.data.saveOptions) || [];
        return f.saveKind ? groups.find((g) => g.kind === f.saveKind) : null;
    }

    // Field the row's value is written in by default: its own, or for EDA's Email the preferred email field.
    _ownPlace(f) { return f.savedInFieldApiName || f.fieldApiName; }
    _placeOf(f) { return this.places[f.fieldApiName] || this._ownPlace(f); }

    _placeLabel(f) {
        const place = this._placeOf(f);
        const g = this._saveGroup(f);
        const slot = g && g.slots.find((s) => s.apiName === place);
        return slot ? slot.label : place;
    }

    // Email / phone wording of a note: rdEmail… or rdPhone….
    _kindText(kind, name) {
        return this.i18n[(kind === 'PHONE' ? 'rdPhone' : 'rdEmail') + name];
    }

    // EDA contact: Email (Phone) is saved in the preferred field of its kind (EDA copies it into
    // Email). The conflict row is another checked row landing in that same field with a different
    // value — Apex keeps Email's answer and leaves that row's out. Computed from the current
    // choices and values, so moving / unchecking a row or correcting a value updates it.
    _mainConflict(kind) {
        const mainRow = this.data.fields.find((x) => x.savedInFieldApiName && x.saveKind === kind);
        const mainMoved = !!mainRow && this._placeOf(mainRow) !== mainRow.savedInFieldApiName;
        const norm = kind === 'PHONE' ? (v) => (v || '').replace(/\D/g, '') : (v) => (v || '').trim().toLowerCase();
        const conflictRow = mainRow && !mainMoved && this.selected[mainRow.fieldApiName] && mainRow.submittedValue
            ? this.data.fields.find((x) => x !== mainRow && x.saveKind === kind && this.selected[x.fieldApiName]
                && this._placeOf(x) === mainRow.savedInFieldApiName && norm(x.submittedValue) !== norm(mainRow.submittedValue))
            : null;
        return { mainRow, mainMoved, conflictRow: conflictRow || null };
    }

    // Checked rows whose values would land in the same field (Email / Phone and their preferred
    // field excepted: Apex settles that pair). Apply stays blocked until staff picks another place.
    _placeClash() {
        const settled = new Set();
        ['EMAIL', 'PHONE'].forEach((kind) => {
            const { mainRow, mainMoved } = this._mainConflict(kind);
            if (mainRow && !mainMoved) settled.add(mainRow);
        });
        const byPlace = {};
        this.data.fields.forEach((f) => {
            if (!f.saveKind || !this.selected[f.fieldApiName] || settled.has(f)) return;
            const place = this._placeOf(f).toLowerCase();
            (byPlace[place] = byPlace[place] || []).push(f.fieldApiName);
        });
        const clash = new Set();
        Object.values(byPlace).forEach((rows) => { if (rows.length > 1) rows.forEach((r) => clash.add(r)); });
        return clash;
    }

    // Fields other checked rows of the panel already write in — never offered twice.
    _takenPlaces(f) {
        const taken = new Set();
        this.data.fields.forEach((o) => {
            if (o !== f && o.saveKind === f.saveKind && this.selected[o.fieldApiName]) taken.add(this._placeOf(o));
        });
        return taken;
    }

    _saveControl(f, active) {
        const g = this._saveGroup(f);
        const none = { hasSaveCtl: false, replacesNote: '' };
        if (!g || !active || !f.submittedValue) return none;
        const own = this._ownPlace(f);
        const place = this._placeOf(f);
        const taken = this._takenPlaces(f);
        const slotOf = (api) => g.slots.find((s) => s.apiName === api);
        const ownSlot = slotOf(own);
        const options = [{
            value: own,
            label: format(f.currentValue || (ownSlot && ownSlot.value) ? this.i18n.rdSaveReplaceFmt : this.i18n.rdSaveInFmt,
                this._localizedLabel(f.savedInFieldApiName ? f.savedInLabelFr : f.fieldLabelFr, f.savedInFieldApiName ? f.savedInLabelEn : f.fieldLabelEn)),
            selected: place === own
        }];
        g.slots.forEach((s) => {
            if (s.apiName === own || (taken.has(s.apiName) && s.apiName !== place)) return;
            options.push({
                value: s.apiName,
                label: format(s.value ? this.i18n.rdSaveOtherFullFmt : this.i18n.rdSaveOtherEmptyFmt, s.label),
                selected: s.apiName === place
            });
        });
        const placeSlot = slotOf(place);
        const canPrefer = g.slots.some((s) => s.preference);
        const isPreferredNow = !!g.preferredField && g.preferredField === place;
        const starred = isPreferredNow || this.preferredRow[f.saveKind] === f.fieldApiName;
        const preferable = !!(placeSlot && placeSlot.preference);
        let prefTitle = this.i18n.rdPreferredMakeTitle;
        if (isPreferredNow) prefTitle = this.i18n.rdPreferredAlreadyTitle;
        else if (!preferable) prefTitle = this.i18n.rdPreferredNotPossibleTitle;
        return {
            hasSaveCtl: options.length > 1 || canPrefer,
            hasPlaces: options.length > 1,
            placeOptions: options,
            placeClass: 'duc-save-dest' + (place !== own ? ' duc-save-dest_on' : ''),
            canPrefer,
            prefStar: starred ? '★' : '☆',
            prefPressed: String(starred),
            prefTitle,
            prefDisabled: isPreferredNow || !preferable || this.selectionLocked,
            prefClass: 'duc-pref' + (starred ? ' duc-pref_on' : '') + (isPreferredNow ? ' duc-pref_fixed' : ''),
            replacesNote: place !== own && placeSlot && placeSlot.value
                ? format(this.i18n.rdSaveReplacesFmt, placeSlot.value, placeSlot.label) : ''
        };
    }

    handleNoteToggle(event) {
        const field = event.currentTarget.dataset.field;
        this.openNote = this.openNote === field ? null : field;
    }

    handleNoteClose() { this.openNote = null; }

    handleNoteKeydown(event) {
        if (event.key === 'Escape') this.openNote = null;
    }

    handlePlaceChange(event) {
        const field = event.currentTarget.dataset.field;
        const row = this.data.fields.find((x) => x.fieldApiName === field);
        const value = event.target.value;
        const next = { ...this.places };
        if (value === this._ownPlace(row)) delete next[field];
        else next[field] = value;
        this.places = next;
        // The star follows the value: a place that can't be preferred drops it.
        const g = this._saveGroup(row);
        const slot = g && g.slots.find((s) => s.apiName === value);
        if (this.preferredRow[row.saveKind] === field && !(slot && slot.preference)) {
            this.preferredRow = { ...this.preferredRow, [row.saveKind]: null };
        }
    }

    handlePreferredClick(event) {
        const field = event.currentTarget.dataset.field;
        const row = this.data.fields.find((x) => x.fieldApiName === field);
        const kind = row.saveKind;
        this.preferredRow = { ...this.preferredRow, [kind]: this.preferredRow[kind] === field ? null : field };
    }

    // Apply payload: places different from the row's own, stars on rows still checked.
    _saveOptionsJson() {
        const overrides = {};
        Object.keys(this.places).forEach((k) => { if (this.selected[k]) overrides[k] = this.places[k]; });
        const preferred = {};
        Object.keys(this.preferredRow).forEach((kind) => {
            const field = this.preferredRow[kind];
            const row = field && this.data.fields.find((x) => x.fieldApiName === field);
            const g = row && this._saveGroup(row);
            if (!row || !this.selected[field] || (g && g.preferredField === this._placeOf(row))) return;
            // A row left out (Email / Phone conflict) never sets the preference.
            if (row === this._mainConflict(kind).conflictRow) return;
            preferred[kind] = field;
        });
        return JSON.stringify({ overrides, preferred });
    }

    // Normal fields first, then the historical ones under their own title (same row markup).
    get changeGroups() {
        const rows = this.changeRows;
        const plain = rows.filter((r) => !r.isHistorize);
        const hist = rows.filter((r) => r.isHistorize);
        const groups = [];
        if (plain.length) groups.push({ key: 'plain', title: this.i18n.rdChangedFields, rows: plain, showHead: true });
        if (hist.length) groups.push({ key: 'hist', title: this.i18n.rdHistorizedFields, rows: hist, showHead: false });
        return groups;
    }

    // 'YYYY-MM-DD' → localized date, parsed as a local date so it never shifts a day.
    _dateOnly(value) {
        const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(value || '');
        if (!m) return value || '';
        return formatDate(new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])), this.lang);
    }

    // "+90 vs Sep 14, 2025" when both values are numbers; blank otherwise.
    _trendText(newValue, lastValue, lastDate) {
        const a = Number(newValue);
        const b = Number(lastValue);
        if (newValue === '' || lastValue === '' || !Number.isFinite(a) || !Number.isFinite(b)) return '';
        const diff = a - b;
        const shown = Number.isInteger(diff) ? diff : Math.round(diff * 100) / 100;
        const when = lastDate ? ` vs ${this._dateOnly(lastDate)}` : '';
        return `${diff > 0 ? '+' : ''}${shown}${when}`;
    }

    get unchangedList() {
        const list = (this.data && this.data.unchangedFields) || [];
        return list.map((f) => ({
            key: f.fieldApiName,
            label: this._localizedLabel(f.fieldLabelFr, f.fieldLabelEn),
            value: f.currentValue || this.i18n.rdEmpty
        }));
    }
    get hasUnchanged() { return this.unchangedList.length > 0; }
    get sameToggleText() {
        const n = this.unchangedList.length;
        const fmt = n === 1 ? this.i18n.rdUnchangedOneFmt : this.i18n.rdUnchangedManyFmt;
        return `${format(fmt, n)} — ${this.showSame ? this.i18n.rdHide : this.i18n.rdShow}`;
    }
    get sameChevClass() { return 'duc-chev' + (this.showSame ? ' duc-chev_open' : ''); }

    get sameExpanded() { return String(this.showSame); }
    handleToggleSame() { this.showSame = !this.showSame; }

    _withDate(value, dateValue) {
        if (!value) return '';
        return dateValue ? `${value} (${dateValue})` : value;
    }

    _localizedLabel(fr, en) {
        return this.lang === 'en' ? (en || fr) : (fr || en);
    }

    // ── Selection ────────────────────────────────────────────────────────────

    get selectedCount() { return Object.values(this.selected).filter(Boolean).length + this._selectedTableRows; }
    get selectedText() { return format(this.i18n.rdSelectedFmt, this.selectedCount, this.changedCount); }
    get selectionLocked() { return this.isApplying || this.isRequestClosed || this.isEditingField; }
    get isEditingField() { return this.editingFieldApiName !== null; }

    handleFieldToggle(event) {
        const field = event.currentTarget.dataset.field;
        this.selected = { ...this.selected, [field]: event.target.checked };
    }

    handleSelectAll() { this._setAll(true); }
    handleSelectNone() { this._setAll(false); }

    _setAll(value) {
        if (this.selectionLocked || !this.hasData) return;
        const next = {};
        this.data.fields.forEach((f) => { next[f.fieldApiName] = value; });
        this.selected = next;
        const tables = {};
        this._tables.forEach((t) => {
            const sel = {};
            // "All" keeps same-date lines excluded; the table's own "All" link overwrites them.
            t.rows.forEach((r) => { sel[r.index] = value && r.isDuplicate !== true; });
            tables[t.key] = sel;
        });
        this.tableSel = tables;
    }

    // ── Apply ────────────────────────────────────────────────────────────────

    get showActions() { return this.hasData && !this.isRequestClosed && this.isUpdateTab; }
    get isApplyDisabled() {
        return this.isApplying || this.isRequestClosed || this.selectedCount === 0 || this.isEditingField
            || (this.hasData && this._placeClash().size > 0);
    }
    get applyLabel() {
        if (this.isApplying) return this.i18n.rdApplying;
        const n = this.selectedCount;
        if (n === 0) return this.i18n.rdApplyNothing;
        return format(n === 1 ? this.i18n.rdApplyOneFmt : this.i18n.rdApplyManyFmt, n);
    }

    async handleApply() {
        if (this.isApplyDisabled) return;
        const ok = await DucConfirmModal.open({
            size: 'small',
            label: this.i18n.rdApplyConfirmTitle,
            message: this.selectedCount === 1
                ? format(this.i18n.rdApplyConfirmOneFmt, this.titleText)
                : format(this.i18n.rdApplyConfirmFmt, this.selectedCount, this.titleText),
            okLabel: this.applyLabel,
            cancelLabel: this.i18n.btnCancel
        });
        if (!ok || this.isApplyDisabled) return;
        this.isApplying = true;
        try {
            const fieldsToApply = Object.keys(this.selected).filter((k) => this.selected[k]);
            const result = await applySelectedUpdatesApex({
                requestId: this.recordId,
                fieldsToApply,
                tableSelectionsJson: JSON.stringify(this._tableSelections()),
                optionsJson: this._saveOptionsJson()
            });
            if (result.success) {
                this._toast(
                    this.i18n.toastApplySuccessTitle,
                    format(this.i18n.toastApplySuccessMsgFmt, result.updatedFieldCount),
                    'success'
                );
                await this._loadData();
                this.dispatchEvent(new CustomEvent('applied', {
                    detail: { requestId: this.recordId, status: 'Applied' }
                }));
            } else {
                const msg = result.errorMessage === 'TICKET_ALREADY_CLOSED' ? this.i18n.toastTicketChangedMsg
                    : result.errorMessage === 'EMAIL_PREFERENCE_UNKNOWN' ? this.i18n.rdEmailPreferenceUnknownToast
                    : result.errorMessage === 'PHONE_PREFERENCE_UNKNOWN' ? this.i18n.rdPhonePreferenceUnknownToast
                    : this.i18n.reviewErrGeneric;
                // A choice to fix (place, preferred): the ticket is unchanged, keep the panel as staff left it.
                if (result.errorMessage === 'INVALID_SAVE_CHOICE') {
                    this._toast(this.i18n.toastApplyErrorTitle, this.i18n.rdInvalidSaveChoiceToast, 'warning');
                    return;
                }
                this._toast(this.i18n.toastApplyErrorTitle, msg, 'error');
                await this._reloadAfterFailure();
            }
        } catch (e) {
            this._toast(this.i18n.toastApplyErrorTitle, this.i18n.reviewErrGeneric, 'error');
            await this._reloadAfterFailure();
        } finally {
            this.isApplying = false;
        }
    }

    // A failed apply can still move the request server-side (e.g. to Error) — resync the
    // panel and let the list/tabs know so the pill doesn't keep showing the old status.
    async _reloadAfterFailure() {
        await this._loadData();
    }

    // ── Inline correction ────────────────────────────────────────────────────

    handleEditFieldClick(event) {
        if (this.isEditingField) return;
        const fieldApiName = event.currentTarget.dataset.field;
        const field = this.data.fields.find((f) => f.fieldApiName === fieldApiName);
        this.editingFieldApiName = fieldApiName;
        this.editDraftValue = (field && field.submittedValue) || '';
        this._focusEdit = true;
    }

    handleEditDraftChange(event) {
        let value = event.target.value;
        if (isPostalCodeField(this.editingFieldApiName)) {
            value = formatPostalCode(value, this._postalCountryFor(this.editingFieldApiName));
            if (event.target.value !== value) event.target.value = value;
        }
        this.editDraftValue = value;
    }

    handleEditKey(event) {
        if (event.key === 'Enter') {
            event.preventDefault();
            this.handleEditSave();
        } else if (event.key === 'Escape') {
            event.preventDefault();
            this.handleEditCancel();
        }
    }

    // Same address's country: the value proposed in this ticket, else the record's current one.
    // Apex re-applies the same rule on save, so this only drives the live formatting.
    _postalCountryFor(postalFieldApiName) {
        const countryField = countryFieldFor(postalFieldApiName);
        const all = [...((this.data && this.data.fields) || []), ...((this.data && this.data.unchangedFields) || [])];
        const f = all.find((x) => x.fieldApiName === countryField);
        return f ? (f.submittedValue || f.currentValue || '') : '';
    }

    handleEditCancel() {
        this.editingFieldApiName = null;
        this.editDraftValue = '';
    }

    async handleEditSave() {
        if (this.isSavingEdit) return;
        const fieldApiName = this.editingFieldApiName;
        const newValue = (this.editDraftValue || '').trim();
        if (!newValue) {
            this._toast(this.i18n.toastEditErrorTitle, this.i18n.editValueRequiredMsg, 'error');
            return;
        }
        if (isPostalCodeField(fieldApiName) && isInvalidPostalCode(newValue, this._postalCountryFor(fieldApiName))) {
            this._toast(this.i18n.toastEditErrorTitle, this.i18n.errInvalidPostalCode, 'error');
            return;
        }
        this.isSavingEdit = true;
        try {
            const result = await correctProposedValueApex({ requestId: this.recordId, fieldApiName, newValue });
            if (result.success) {
                const updatedFields = this.data.fields.map((f) => (
                    f.fieldApiName === fieldApiName
                        ? { ...f, submittedValue: result.newValue, isDifferent: true }
                        : f
                ));
                this.data = { ...this.data, fields: updatedFields };
                // A corrected value starts clean: its "Save in" and star are chosen again.
                const nextPlaces = { ...this.places };
                delete nextPlaces[fieldApiName];
                this.places = nextPlaces;
                const nextPref = { ...this.preferredRow };
                Object.keys(nextPref).forEach((k) => { if (nextPref[k] === fieldApiName) nextPref[k] = null; });
                this.preferredRow = nextPref;
                this.editingFieldApiName = null;
                this.editDraftValue = '';
                this._toast(this.i18n.toastEditSuccessTitle, '', 'success');
                await this._refreshAuditLog();
            } else if (result.errorMessage === 'INVALID_POSTAL_CODE') {
                this._toast(this.i18n.toastEditErrorTitle, this.i18n.errInvalidPostalCode, 'error');
            } else if (EDIT_ERROR_KEYS[result.errorMessage]) {
                this._toast(this.i18n.toastEditErrorTitle, this.i18n[EDIT_ERROR_KEYS[result.errorMessage]], 'error');
            } else if (result.errorMessage === 'TICKET_ALREADY_CLOSED') {
                this.editingFieldApiName = null;
                this._toast(this.i18n.toastEditErrorTitle, this.i18n.toastTicketChangedMsg, 'warning');
                await this._loadData();
            } else {
                this._toast(this.i18n.toastEditErrorTitle, this.i18n.reviewErrGeneric, 'error');
            }
        } catch (e) {
            this._toast(this.i18n.toastEditErrorTitle, this.i18n.reviewErrGeneric, 'error');
        } finally {
            this.isSavingEdit = false;
        }
    }

    renderedCallback() {
        if (this._focusEdit) {
            const input = this.template.querySelector('.duc-edit-input');
            if (input) {
                this._focusEdit = false;
                input.focus();
                input.select();
            }
        }
        if (this._focusNote) {
            const note = this.template.querySelector('.duc-pop-note');
            if (note) {
                this._focusNote = false;
                note.focus();
            }
        }
    }

    // ── Status popover (In Review / On Hold / Ignore) ────────────────────────

    get popModes() {
        const opt = (mode, tone, icon, title, desc) => ({
            mode, icon, title, desc,
            style: toneStyle(tone),
            pressed: String(this.exceptionMode === mode)
        });
        return [
            opt('inReview', 'review', 'eye', this.i18n.rdReview, this.i18n.rdReviewD),
            opt('onHold', 'hold', 'pause', this.i18n.rdHold, this.i18n.rdHoldD),
            opt('ignore', 'ignored', 'x', this.i18n.rdIgnore, this.i18n.rdIgnoreD)
        ].filter((m) => MODE_STATUS[m.mode] !== this.currentStatus); // don't offer the status it already has
    }
    get isIgnoreMode() { return this.exceptionMode === 'ignore'; }
    get hasMode() { return !!this.exceptionMode; }
    get reasonChips() {
        return [
            { label: this.i18n.closedReasonNoChanges, value: 'No Changes Needed' },
            { label: this.i18n.closedReasonDuplicate, value: 'Duplicate Request' },
            { label: this.i18n.closedReasonInvalid, value: 'Invalid Data Provided' },
            { label: this.i18n.closedReasonOther, value: 'Other' }
        ].map((r) => ({
            ...r,
            pressed: String(this.closedReason === r.value),
            cls: 'duc-reason' + (this.closedReason === r.value ? ' duc-reason_on' : '')
        }));
    }
    get isHoldMode() { return this.exceptionMode === 'onHold'; }
    // On Hold and Ignore both take a note; "Other" needs one, since the chip alone says nothing.
    get showNoteBox() { return this.isHoldMode || (this.isIgnoreMode && !!this.closedReason); }
    get isNoteRequired() { return this.isIgnoreMode && this.closedReason === 'Other'; }
    get notePlaceholder() {
        if (this.isHoldMode) return this.i18n.rdHoldNotePh;
        return this.isNoteRequired ? this.i18n.rdOtherNoteReq : this.i18n.rdReasonPh;
    }
    get isExceptionConfirmDisabled() {
        if (this.isSubmittingException || !this.exceptionMode) return true;
        if (this.isIgnoreMode && !this.closedReason) return true;
        return this.isNoteRequired && !(this.exceptionReason || '').trim();
    }
    get popChevClass() { return 'duc-chev' + (this.isPopOpen ? ' duc-chev_up' : ''); }
    get popExpanded() { return String(this.isPopOpen); }

    handleTogglePop() {
        if (this.isPopOpen) this._closePop();
        else {
            this.isPopOpen = true;
            this.exceptionMode = null;
            this.exceptionReason = '';
            this.closedReason = '';
        }
    }

    _closePop() {
        this.isPopOpen = false;
        this.exceptionMode = null;
        this.exceptionReason = '';
        this.closedReason = '';
    }

    handlePopCancel() { this._closePop(); }

    handlePopKey(event) {
        if (event.key === 'Escape') {
            event.preventDefault();
            this._closePop();
        }
    }

    // In Review is one click. On Hold asks for an optional note, and Ignore closes the ticket,
    // so it asks for a reason; both then wait for Confirm.
    handleModeChange(event) {
        if (this.isSubmittingException) return;
        this.exceptionMode = event.currentTarget.dataset.mode;
        this.closedReason = '';
        if (this.exceptionMode === 'inReview') this.confirmException();
        else if (this.isHoldMode) this._focusNote = true;
    }

    handleReasonPick(event) {
        if (this.isSubmittingException) return;
        this.closedReason = event.currentTarget.dataset.value;
        this._focusNote = true;
    }

    handleExceptionReasonChange(event) {
        this.exceptionReason = event.target.value;
    }

    async confirmException() {
        if (this.isExceptionConfirmDisabled) return;
        this.isSubmittingException = true;
        try {
            if (this.exceptionMode === 'inReview') {
                await resumeRequestApex({ requestId: this.recordId });
                this._toast(this.i18n.toastResumeSuccessTitle, '', 'success');
                this._notifyStatusChanged('In Review');
            } else if (this.exceptionMode === 'ignore') {
                await ignoreRequestApex({
                    requestId: this.recordId,
                    closedReason: this.closedReason,
                    notes: this.exceptionReason
                });
                this._toast(this.i18n.toastIgnoreSuccessTitle, '', 'success');
                this._notifyStatusChanged('Ignored');
            } else {
                await holdRequestApex({ requestId: this.recordId, reason: this.exceptionReason });
                this._toast(this.i18n.toastHoldSuccessTitle, '', 'success');
                this._notifyStatusChanged('On Hold');
            }
            this._closePop();
            await this._loadData();
        } catch (e) {
            if (isStaleStatusError(e)) {
                this._closePop();
                this._toast(this.i18n.toastActionErrorTitle, this.i18n.toastTicketChangedMsg, 'warning');
                await this._loadData();
            } else {
                this._toast(this.i18n.toastActionErrorTitle, '', 'error');
            }
        } finally {
            this.isSubmittingException = false;
        }
    }

    // ── Closed ticket: ticket-level rollback or reopen ───────────────────────

    // Newest APPLY_COMPLETED entry that still has rollback-eligible fields.
    get latestApplied() {
        return this.auditEntries.find((e) => e.actionType === 'APPLY_COMPLETED'
            && (e.fieldChanges || []).some((c) => c.canRollback)) || null;
    }
    get showClosedNotice() { return this.hasData && this.isRequestClosed; }
    get showRbNotice() { return this.showClosedNotice && !!this.latestApplied; }
    get showReopenNotice() { return this.showClosedNotice && !this.latestApplied; }
    get rbRows() {
        const entry = this.latestApplied;
        if (!entry) return [];
        return entry.fieldChanges.filter((c) => c.canRollback).map((c) => ({
            key: c.fieldApiName,
            label: this._localizedLabel(c.fieldLabelFr, c.fieldLabelEn),
            after: c.afterValue || this.i18n.rdEmpty,
            afterClass: 'duc-v duc-v_old' + (c.afterValue ? '' : ' duc-v_empty'),
            before: c.beforeValue || this.i18n.rdEmpty,
            beforeClass: 'duc-v duc-v_new' + (c.beforeValue ? '' : ' duc-v_empty')
        }));
    }
    get appliedNoteText() {
        const entry = this.latestApplied;
        if (!entry) return '';
        const n = entry.fieldChanges.filter((c) => c.canRollback).length;
        const fmt = n === 1 ? this.i18n.rdAppliedNoteOneFmt : this.i18n.rdAppliedNoteManyFmt;
        return format(fmt, n, formatDateTime(entry.performedDate, this.lang));
    }
    get rbNoticeClass() { return 'duc-notice duc-rb-notice' + (this.rbAsk ? ' duc-rb-notice_ask' : ''); }

    handleRbAsk() { this.rbAsk = true; }
    handleRbCancel() { this.rbAsk = false; }

    async handleRbConfirm() {
        const entry = this.latestApplied;
        if (!entry || this.isRollingBack) return;
        const fields = entry.fieldChanges.filter((c) => c.canRollback).map((c) => c.fieldApiName);
        await this._rollbackFields(entry.logId, fields);
        this.rbAsk = false;
    }

    async handleReopen() {
        if (this.isReopening) return;
        const confirmed = await DucConfirmModal.open({
            label: this.i18n.reopenConfirmTitle,
            message: this.i18n.reopenConfirmMsg,
            theme: 'warning',
            okLabel: this.i18n.confirmOk,
            cancelLabel: this.i18n.btnCancel
        });
        if (!confirmed) return;
        this.isReopening = true;
        try {
            await reopenRequestApex({ requestId: this.recordId });
            this._toast(this.i18n.toastReopenSuccessTitle, '', 'success');
            this._notifyStatusChanged('Reopened');
            await this._loadData();
        } catch (e) {
            if (isStaleStatusError(e)) {
                this._toast(this.i18n.toastActionErrorTitle, this.i18n.toastTicketChangedMsg, 'warning');
                await this._loadData();
            } else {
                this._toast(this.i18n.toastActionErrorTitle, '', 'error');
            }
        } finally {
            this.isReopening = false;
        }
    }

    // ── History timeline ─────────────────────────────────────────────────────

    get hasAuditEntries() { return this.auditEntries.length > 0; }

    // Status change from Notes__c (hold, resume, ignore, reopen) — no field rows, just reason/note.
    _statusTimelineItem(entry, i) {
        const tone = statusKey(entry.statusValue);
        const icon = { hold: 'pause', review: 'play', ignored: 'x', reopen: 'undo' }[tone] || 'clock';
        const reasonLabels = {
            'No Changes Needed': this.i18n.closedReasonNoChanges,
            'Duplicate Request': this.i18n.closedReasonDuplicate,
            'Invalid Data Provided': this.i18n.closedReasonInvalid,
            Other: this.i18n.closedReasonOther
        };
        const details = [];
        if (entry.statusReason) {
            details.push({ key: 'r', label: this.i18n.rdStatusReasonLbl, value: reasonLabels[entry.statusReason] || entry.statusReason });
        }
        if (entry.statusNotes) details.push({ key: 'n', label: this.i18n.rdStatusNoteLbl, value: entry.statusNotes });
        return {
            key: `st${i}`,
            dotStyle: toneStyle(tone),
            icon,
            who: entry.performedByName || '—',
            action: format(this.i18n.rdActStatusFmt, statusLabel(this.i18n, entry.statusValue)),
            when: entry.dateOnly ? this._dateOnly(String(entry.performedDate || '')) : formatDateTime(entry.performedDate, this.lang),
            tlClass: 'duc-tl',
            hasStatusDetails: details.length > 0,
            statusDetails: details,
            hasChanges: false,
            changes: [],
            hasGroup: false,
            hasNotApplied: false,
            showFieldRewind: false,
            showEntryRollback: false,
            isConfirmingEntry: false
        };
    }

    get timeline() {
        return this.auditEntries.map((entry, i) => {
            if (entry.actionType === 'STATUS') return this._statusTimelineItem(entry, i);
            const meta = ACTION_TONES[entry.actionType] || { tone: 'ignored', icon: 'clock', key: '' };
            const changes = (entry.fieldChanges || []).map((c) => {
                const confirmKey = `${entry.logId}::${c.fieldApiName}`;
                const own = this._localizedLabel(c.fieldLabelFr, c.fieldLabelEn);
                // Answered in another question and saved here (e.g. Email → preferred email).
                const source = this._localizedLabel(c.sourceLabelFr, c.sourceLabelEn);
                const label = source ? format(this.i18n.rdHistSavedInFmt, source, own) : own;
                return {
                    key: c.fieldApiName,
                    label,
                    rollbackAria: `${this.i18n.rdRollback} : ${label}`,
                    before: c.beforeValue || this.i18n.rdEmpty,
                    beforeClass: 'duc-v duc-v_old' + (c.beforeValue ? '' : ' duc-v_empty'),
                    after: c.afterValue || this.i18n.rdEmpty,
                    afterClass: 'duc-v duc-v_new' + (c.afterValue ? '' : ' duc-v_empty'),
                    canRollback: !!c.canRollback,
                    confirmKey,
                    isConfirming: this.confirmingRollbackKey === confirmKey
                };
            });
            const rollbackable = changes.filter((c) => c.canRollback);
            const entryKey = `${entry.logId}::${ALL_FIELDS}`;
            const isApply = entry.actionType === 'APPLY_COMPLETED';
            const others = entry.groupOthers || 0;
            const groupText = others > 0
                ? format(others === 1 ? this.i18n.grpHistGroupOneFmt : this.i18n.grpHistGroupFmt, others, entry.groupRecordName || '')
                : '';
            const notApplied = (entry.notApplied || []).map((n, i) => {
                let reason;
                if (n.reason === 'SAME_AS_SF') reason = this.i18n.grpReasonSameAsSf;
                else if (n.reason === 'OTHER_TICKET') reason = format(this.i18n.grpReasonOtherTicketFmt, n.ticket);
                else if (n.reason === 'MERGED') reason = format(this.i18n.grpReasonMergedFmt, n.ticket);
                else if (n.reason === 'EMAIL_PREFERRED_CONFLICT') reason = this.i18n.rdReasonEmailConflict;
                else if (n.reason === 'EMAIL_EMPTY') reason = this.i18n.rdReasonEmailEmpty;
                else if (n.reason === 'PHONE_PREFERRED_CONFLICT') reason = this.i18n.rdReasonPhoneConflict;
                else if (n.reason === 'PHONE_EMPTY') reason = this.i18n.rdReasonPhoneEmpty;
                else reason = this.i18n.grpReasonUnchecked;
                const value = /^\d{4}-\d{2}-\d{2}$/.test(n.value || '') ? this._dateOnly(n.value) : n.value;
                return { key: 'na' + i, label: this._localizedLabel(n.labelFr, n.labelEn), value, reason };
            });
            const preferredChanges = (entry.preferredChanges || []).map((p, i) => ({
                key: 'pc' + i,
                label: p.kind === 'PHONE' ? this.i18n.rdPreferredPhone : this.i18n.rdPreferredEmail,
                before: p.beforeValue || this.i18n.rdEmpty,
                beforeClass: 'duc-v duc-v_old' + (p.beforeValue ? '' : ' duc-v_empty'),
                after: p.afterValue || this.i18n.rdEmpty
            }));
            return {
                hasPreferredChanges: preferredChanges.length > 0,
                preferredChanges,
                hasGroup: !!groupText,
                groupText,
                hasNotApplied: notApplied.length > 0,
                notApplied,
                key: entry.logId,
                dotStyle: toneStyle(meta.tone),
                icon: meta.icon,
                who: entry.performedByName || '—',
                action: meta.key ? this.i18n[meta.key] : entry.actionType,
                when: formatDateTime(entry.performedDate, this.lang),
                tlClass: 'duc-tl' + (isApply && rollbackable.length === 0 ? ' duc-tl_rolled' : ''),
                hasChanges: changes.length > 0,
                changes,
                // a single-field entry only needs the entry-level button
                showFieldRewind: rollbackable.length > 1,
                showEntryRollback: rollbackable.length > 0 && this.confirmingRollbackKey !== entryKey,
                entryKey,
                isConfirmingEntry: this.confirmingRollbackKey === entryKey,
                rbConfirmText: rollbackable.length > 1 ? this.i18n.rdRbConfirmMany : this.i18n.rdRbConfirm
            };
        });
    }

    handleRollbackClick(event) {
        this.confirmingRollbackKey = event.currentTarget.dataset.key;
    }

    handleRollbackCancel() {
        this.confirmingRollbackKey = null;
    }

    async handleRollbackConfirm(event) {
        const key = event.currentTarget.dataset.key;
        const [logId, fieldApiName] = key.split('::');
        let fields = [fieldApiName];
        if (fieldApiName === ALL_FIELDS) {
            const entry = this.auditEntries.find((e) => e.logId === logId);
            fields = entry ? entry.fieldChanges.filter((c) => c.canRollback).map((c) => c.fieldApiName) : [];
        }
        await this._rollbackFields(logId, fields);
        this.confirmingRollbackKey = null;
    }

    // One server call, all-or-nothing: either every selected field is restored or none is.
    async _rollbackFields(logId, fields) {
        if (!fields.length || this.isRollingBack) return;
        this.isRollingBack = true;
        try {
            let result;
            try {
                result = await rollbackChangesApex({ logId, fieldApiNames: fields });
            } catch (e) {
                result = null;
            }
            if (result && result.success) {
                this._toast(this.i18n.toastRollbackSuccessTitle,
                    format(this.i18n.rdRollbackDoneFmt, result.updatedFieldCount || fields.length), 'success');
                if (result.historyCleanupSkipped) {
                    this._toast(this.i18n.toastRollbackHistoryOrphanedTitle, this.i18n.toastRollbackHistoryOrphanedMsg, 'warning');
                }
                await this._loadData();
                this.subTab = 'update';
                this.dispatchEvent(new CustomEvent('rollback', { detail: { requestId: this.recordId } }));
            } else {
                this._toast(this.i18n.toastRollbackErrorTitle, this.i18n.reviewErrGeneric, 'error');
            }
        } finally {
            this.isRollingBack = false;
            this.rbAsk = false;
        }
    }

    // ── Unlock ───────────────────────────────────────────────────────────────

    async handleUnlock() {
        if (this.unlockDisabled) return;
        const ok = await DucConfirmModal.open({
            size: 'small',
            label: this.i18n.rdUnlock,
            message: format(this.i18n.unlockOneConfirmFmt, this.titleText),
            okLabel: this.i18n.rdUnlock,
            cancelLabel: this.i18n.btnCancel
        });
        if (!ok || this.unlockDisabled) return;
        this.isUnlocking = true;
        try {
            const result = await unlockRecordApex({ recordId: this.data.recordId, formName: this.data.formDeveloperName });
            if (result.success) {
                this._toast(this.i18n.toastUnlockAccountSuccessTitle, '', 'success');
                await this._loadData();
                this._notifyStatusChanged(null);
            } else if (result.errorMessage === 'REQUEST_STILL_OPEN') {
                this._toast(this.i18n.toastUnlockBlockedTitle, this.i18n.unlockBlockedMsg, 'warning');
            } else {
                this._toast(this.i18n.toastActionErrorTitle, '', 'error');
            }
        } catch (e) {
            this._toast(this.i18n.toastActionErrorTitle, '', 'error');
        } finally {
            this.isUnlocking = false;
        }
    }

    // ── Data ─────────────────────────────────────────────────────────────────

    async _loadData() {
        this.isLoading = !this.data;
        this.errorMessage = '';
        this.editingFieldApiName = null;
        this.editDraftValue = '';
        try {
            const [result, auditResult] = await Promise.all([
                getComparisonDataApex({ requestId: this.recordId }),
                getAuditLogApex({ requestId: this.recordId })
            ]);
            this.data = result;
            if (result.success) {
                const initialSelected = {};
                // Open tickets start with every change selected; staff unticks what they skip.
                result.fields.forEach((f) => { initialSelected[f.fieldApiName] = !result.requestClosed; });
                this.selected = initialSelected;
                this.places = {};
                this.preferredRow = {};
                this.tableSel = this._initialTableSel(result);
                if (result.status && this.requestStatus && result.status !== this.requestStatus) {
                    this._notifyStatusChanged(result.status);
                }
            } else {
                this.errorMessage = this.i18n.reviewErrGeneric;
            }
            this.auditEntries = auditResult && auditResult.success ? auditResult.entries : [];
            // The "undo?" prompt only makes sense while there is something to roll back.
            if (!this.showRbNotice) this.rbAsk = false;
        } catch (e) {
            this.errorMessage = this.i18n.reviewErrGeneric;
        } finally {
            this.isLoading = false;
        }
    }

    async _refreshAuditLog() {
        try {
            const auditResult = await getAuditLogApex({ requestId: this.recordId });
            this.auditEntries = auditResult && auditResult.success ? auditResult.entries : [];
        } catch (e) {
            // History keeps showing its previous state — non-critical.
        }
    }

    _notifyStatusChanged(status) {
        this.dispatchEvent(new CustomEvent('requestchanged', {
            detail: { requestId: this.recordId, status }
        }));
    }

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
