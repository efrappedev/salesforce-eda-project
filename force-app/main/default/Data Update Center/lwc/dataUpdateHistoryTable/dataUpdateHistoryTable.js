import { LightningElement, api, track } from 'lwc';
import { getLabels, format } from 'c/dataUpdateI18n';

// One History_Table of the public form (églises), in two modes over the same rows: 'entry'
// (one labelled box per column, a single line: it is sent with the form, no "Add" step) and
// 'table' (paste-from-Excel grid, for several lines). The form builder picks Fields, Excel or
// Both (the person chooses). Each line becomes one record of the related history object once
// staff approve it. Lines are validated here
// (the server validates again) and sent as arrays in column order: dates yyyy-MM-dd, numbers
// with a dot, checkboxes true/false, picklists by API value.

const SHOW = 8;
const BLANK = 3;
const NUM_DATE = /^(\d{1,2})[/.-](\d{1,2})[/.-](\d{2}|\d{4})$/;
const ISO_DATE = /^(\d{4})[/.-](\d{1,2})[/.-](\d{1,2})$/;
const NUMBER = /^-?\d+(\.\d+)?$/;
const MONTHS = {
    jan: 0, janv: 0, january: 0, janvier: 0, feb: 1, february: 1, fev: 1, 'fév': 1, 'févr': 1, 'février': 1, fevrier: 1,
    mar: 2, march: 2, mars: 2, apr: 3, april: 3, avr: 3, avril: 3, may: 4, mai: 4, jun: 5, june: 5, juin: 5,
    jul: 6, july: 6, juil: 6, juillet: 6, aug: 7, august: 7, aout: 7, 'août': 7, sep: 8, sept: 8, september: 8, septembre: 8,
    oct: 9, october: 9, octobre: 9, nov: 10, november: 10, novembre: 10, dec: 11, december: 11, 'déc': 11, 'décembre': 11, decembre: 11
};
const TRUE_WORDS = ['true', 'oui', 'yes', 'vrai', '1', 'x', 'o', 'y'];
const FALSE_WORDS = ['false', 'non', 'no', 'faux', '0', 'n'];

function fullYear(y) {
    const n = Number(y);
    if (n >= 100) return n;
    return n <= 40 ? 2000 + n : 1900 + n;
}

function makeDate(y, m, d) {
    const dt = new Date(y, m, d);
    return dt.getFullYear() === y && dt.getMonth() === m && dt.getDate() === d ? dt : null;
}

function parseTextDate(s) {
    const t = s.toLowerCase().replace(/[.,]/g, ' ').replace(/\s+/g, ' ').trim();
    let m = t.match(/^([a-zéûè]+) (\d{1,2}) (\d{4})$/);
    if (m && m[1] in MONTHS) return makeDate(Number(m[3]), MONTHS[m[1]], Number(m[2]));
    m = t.match(/^(\d{1,2}) ([a-zéûè]+) (\d{4})$/);
    if (m && m[2] in MONTHS) return makeDate(Number(m[3]), MONTHS[m[2]], Number(m[1]));
    return null;
}

function looksLikeDate(s) {
    const v = (s || '').trim();
    return NUM_DATE.test(v) || ISO_DATE.test(v) || !!parseTextDate(v);
}

// order: 'dmy' | 'mdy'. 15/12/2003 or 12-15-2003 can only be read one way, whatever the order.
function parseDate(s, order) {
    const v = (s || '').trim();
    if (!v) return null;
    let m = v.match(ISO_DATE);
    if (m) return makeDate(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
    m = v.match(NUM_DATE);
    if (m) {
        const a = Number(m[1]);
        const b = Number(m[2]);
        const y = fullYear(m[3]);
        if (a > 12) return makeDate(y, b - 1, a);
        if (b > 12) return makeDate(y, a - 1, b);
        return order === 'mdy' ? makeDate(y, a - 1, b) : makeDate(y, b - 1, a);
    }
    return parseTextDate(v);
}

// Which order fits the whole column? Ambiguous columns default to day/month (Québec), with a
// warning when month/day would put every date on the same weekday (weekly services).
function detectOrder(values) {
    const nums = values.map((v) => (v || '').trim().match(NUM_DATE)).filter(Boolean);
    if (!nums.length) return { order: 'dmy' };
    const read = (m, o) => {
        const a = Number(m[1]);
        const b = Number(m[2]);
        const y = fullYear(m[3]);
        return o === 'dmy' ? makeDate(y, b - 1, a) : makeDate(y, a - 1, b);
    };
    const dmy = nums.every((m) => read(m, 'dmy'));
    const mdy = nums.every((m) => read(m, 'mdy'));
    if (dmy && !mdy) return { order: 'dmy' };
    if (mdy && !dmy) return { order: 'mdy', other: true };
    const anyAmbiguous = nums.some((m) => Number(m[1]) <= 12 && Number(m[2]) <= 12 && m[1] !== m[2]);
    if (!anyAmbiguous || !dmy) return { order: 'dmy' };
    const score = (o) => {
        const counts = {};
        nums.forEach((m) => {
            const day = read(m, o).getDay();
            counts[day] = (counts[day] || 0) + 1;
        });
        return Math.max(...Object.values(counts)) / nums.length;
    };
    return { order: 'dmy', flip: score('mdy') > score('dmy') };
}

function pad(n) {
    return String(n).padStart(2, '0');
}

function toIso(dt) {
    return dt.getFullYear() + '-' + pad(dt.getMonth() + 1) + '-' + pad(dt.getDate());
}

function normalizeNumber(s) {
    let v = (s || '').replace(/[\s  ']/g, '');
    if (v.includes(',') && !v.includes('.')) {
        // "1,5" → 1.5 ; "1,300" (thousands) → 1300
        v = /^-?\d{1,3}(,\d{3})+$/.test(v) ? v.replace(/,/g, '') : v.replace(',', '.');
    } else {
        v = v.replace(/,/g, '');
    }
    return v;
}

export default class DataUpdateHistoryTable extends LightningElement {
    @api lang = 'fr';
    @api disabled = false;

    @track rows = [];
    mode = 'entry';
    entryTouched = false;
    choice = null;
    showHelp = false;
    _table;

    @api
    get table() {
        return this._table;
    }
    set table(value) {
        const first = !this._table;
        this._table = value;
        if (first && value) this.mode = this.inputMode === 'Excel' ? 'table' : 'entry';
    }

    // Fields | Excel | Both — anything else (older config) is the paste grid.
    get inputMode() {
        const m = this._table && this._table.inputMode;
        return m === 'Fields' || m === 'Both' ? m : 'Excel';
    }

    get showModes() {
        return this.inputMode === 'Both';
    }

    get i18n() {
        return getLabels(this.lang);
    }

    get columns() {
        return (this._table && this._table.columns) || [];
    }

    get maxRows() {
        return (this._table && this._table.maxRows) || 1000;
    }

    get dateIndex() {
        return this.columns.findIndex((c) => c.isDate);
    }

    get title() {
        if (!this._table) return '';
        return (this.lang === 'en' ? this._table.titleEn : this._table.titleFr) || this._table.titleFr || '';
    }

    get helpText() {
        if (!this._table) return '';
        return (this.lang === 'en' ? this._table.helpEn : this._table.helpFr) || '';
    }

    get hasHelp() {
        return !!this.helpText;
    }

    get helpExpanded() {
        return this.showHelp ? 'true' : 'false';
    }

    get howTo() {
        if (this.isEntry) return this.showModes ? this.i18n.htEntryHowToBoth : this.i18n.htEntryHowTo;
        return format(this.i18n.htHowToFmt, this.columns.map((c) => this._colLabel(c)).join(' · '));
    }

    _colLabel(c) {
        return (this.lang === 'en' ? c.labelEn : c.labelFr) || c.apiName;
    }

    // ── Validation ──────────────────────────────────────────────────────────

    get _detected() {
        const idx = this.dateIndex;
        return detectOrder(idx < 0 ? [] : this.rows.map((r) => r[idx]));
    }

    get order() {
        return this.choice || this._detected.order;
    }

    _isBlank(row) {
        return !row || row.every((v) => !(v || '').trim());
    }

    // { values (normalized cells, or null), error, date (Date|null) } for one line.
    _check(row) {
        const out = [];
        let error = '';
        let date = null;
        this.columns.forEach((c, i) => {
            const raw = (row[i] || '').trim();
            let val = '';
            if (!raw) {
                if (c.isRequired && !error) error = this.i18n.htErrRequired;
                out.push(c.kind === 'Checkbox' ? 'false' : '');
                return;
            }
            if (c.kind === 'Date') {
                const dt = parseDate(raw, this.order);
                if (!dt) error = error || this.i18n.htErrDate;
                else {
                    val = toIso(dt);
                    if (c.isDate) date = dt;
                }
            } else if (c.kind === 'Number') {
                val = normalizeNumber(raw);
                if (!NUMBER.test(val)) error = error || this.i18n.htErrNum;
            } else if (c.kind === 'Checkbox') {
                const w = raw.toLowerCase();
                if (TRUE_WORDS.includes(w)) val = 'true';
                else if (FALSE_WORDS.includes(w)) val = 'false';
                else error = error || this.i18n.htErrCheckbox;
            } else if (c.kind === 'Picklist') {
                const w = raw.toLowerCase();
                const hit = (c.picklistOptions || []).find((o) => o.value.toLowerCase() === w || (o.label || '').toLowerCase() === w);
                if (hit) val = hit.value;
                else error = error || this.i18n.htErrChoice;
            } else {
                val = raw;
                if (c.maxLength && val.length > c.maxLength) error = error || this.i18n.htErrTooLong;
            }
            out.push(val);
        });
        return { values: error ? null : out, error, date };
    }

    get _checked() {
        const seen = new Map();
        const checked = this.rows.map((r) => (this._isBlank(r) ? null : this._check(r)));
        checked.forEach((c, i) => {
            if (!c || !c.date) return;
            const k = toIso(c.date);
            if (seen.has(k)) {
                c.error = c.error || this.i18n.htErrDup;
                const first = checked[seen.get(k)];
                first.error = first.error || this.i18n.htErrDup;
            } else {
                seen.set(k, i);
            }
        });
        return checked;
    }

    _emit() {
        const checked = this._checked;
        const filled = checked.filter(Boolean);
        const errors = filled.filter((c) => c.error).length;
        const tooMany = filled.length > this.maxRows;
        this.dispatchEvent(new CustomEvent('tablechange', {
            detail: {
                key: this._table.key,
                lineCount: filled.length,
                errorCount: errors + (tooMany ? 1 : 0),
                values: errors || tooMany ? [] : filled.map((c) => c.values)
            }
        }));
    }

    // ── View ────────────────────────────────────────────────────────────────

    get headers() {
        const suffix = this.i18n.htDateSuffix;
        return this.columns.map((c, i) => ({
            key: 'h' + i,
            label: this._colLabel(c) + (c.kind === 'Date' ? suffix : ''),
            required: c.isRequired
        }));
    }

    get hasDate() {
        return this.dateIndex >= 0;
    }

    get gridStyle() {
        const cols = this.columns.map((c) => (c.kind === 'Date' ? 'minmax(7.5rem,1.2fr)' : 'minmax(5rem,1fr)'));
        if (this.hasDate) cols.push('minmax(8rem,1.3fr)');
        return 'grid-template-columns: 2.25rem ' + cols.join(' ') + ' 1.5rem;';
    }

    get viewRows() {
        const checked = this._checked;
        const errIdx = [];
        const okIdx = [];
        this.rows.forEach((r, i) => ((checked[i] && checked[i].error) ? errIdx : okIdx).push(i));
        const shown = [...errIdx, ...okIdx].slice(0, SHOW).sort((a, b) => a - b);
        const hidden = this.rows.length - shown.length;
        const lines = shown.map((i) => ({ i, row: this.rows[i], c: checked[i] }));
        const blanks = this.rows.length > SHOW ? 1 : BLANK;
        for (let b = 0; b < blanks; b++) lines.push({ i: this.rows.length + b, row: [], c: null });

        const locale = this.lang === 'en' ? 'en-CA' : 'fr-CA';
        const out = [];
        lines.forEach(({ i, row, c }, pos) => {
            const err = c ? c.error : '';
            out.push({
                key: 'r' + i,
                num: i + 1,
                className: 'duht-row' + (err ? ' duht-row_bad' : ''),
                error: err,
                flag: err ? '!' : '',
                read: c && c.date ? c.date.toLocaleDateString(locale, { year: 'numeric', month: 'long', day: 'numeric' }) : '',
                cells: this.columns.map((col, j) => ({
                    key: 'c' + j,
                    r: i,
                    c: j,
                    value: row[j] || '',
                    placeholder: col.kind === 'Date' ? this.i18n.htDatePlaceholder : '',
                    inputMode: col.kind === 'Number' ? 'decimal' : 'text',
                    ariaLabel: this._colLabel(col) + ' ' + (i + 1)
                })),
                isMore: false
            });
            if (hidden > 0 && pos === shown.length - 1) {
                out.push({ key: 'more', isMore: true, moreText: format(this.i18n.htMoreFmt, hidden.toLocaleString(locale)) });
            }
        });
        return out;
    }

    get filledCount() {
        return this.rows.filter((r) => !this._isBlank(r)).length;
    }

    get hasLines() {
        return this.filledCount > 0;
    }

    get linesText() {
        const locale = this.lang === 'en' ? 'en-CA' : 'fr-CA';
        return format(this.i18n.htLinesFmt, this.filledCount.toLocaleString(locale), this.maxRows.toLocaleString(locale));
    }

    get tooManyText() {
        if (this.filledCount <= this.maxRows) return '';
        const locale = this.lang === 'en' ? 'en-CA' : 'fr-CA';
        return format(this.i18n.htTooManyFmt, this.filledCount.toLocaleString(locale), this.maxRows.toLocaleString(locale));
    }

    get errorsText() {
        const errs = this._checked.filter((c) => c && c.error);
        if (!errs.length) return '';
        return format(this.i18n.htErrFixFmt, errs.length) + ' (' + [...new Set(errs.map((c) => c.error))].join(' · ') + ')';
    }

    get showFormatLine() {
        const idx = this.dateIndex;
        return idx >= 0 && this.rows.some((r) => NUM_DATE.test((r[idx] || '').trim()));
    }

    get formatLine() {
        const det = this._detected;
        const odd = !this.choice && (det.other || det.flip);
        return {
            warning: odd ? (det.other ? this.i18n.htOddMdy : this.i18n.htOddFlip) : '',
            order: this.order === 'mdy' ? this.i18n.htMdy : this.i18n.htDmy,
            auto: this.choice ? '' : ' · ' + this.i18n.htAuto,
            className: 'duht-fmt' + (odd ? ' duht-fmt_odd' : '')
        };
    }

    // ── Entry mode (one line at a time) ─────────────────────────────────────

    get isEntry() {
        return this.mode === 'entry';
    }

    get isTable() {
        return this.mode === 'table';
    }

    get entryTabClass() {
        return 'duht-mode' + (this.isEntry ? ' duht-mode_on' : '');
    }

    get tableTabClass() {
        return 'duht-mode' + (this.isTable ? ' duht-mode_on' : '');
    }

    get entryPressed() {
        return this.isEntry ? 'true' : 'false';
    }

    get tablePressed() {
        return this.isTable ? 'true' : 'false';
    }

    // An unticked checkbox alone is not a line.
    _hasValue(row) {
        return this.columns.some((col, j) => {
            const v = (row[j] || '').trim();
            return v && !(col.kind === 'Checkbox' && v === 'false');
        });
    }

    get _entryRow() {
        return this.rows[0] || [];
    }

    // Shown once the person leaves a box, so "required" doesn't flash while typing.
    get entryError() {
        if (!this.entryTouched) return '';
        const c = this._checked[0];
        return c ? c.error : '';
    }

    get showCount() {
        return this.isTable;
    }

    get showErrors() {
        return this.isTable && !!this.errorsText;
    }

    // Both: the table can hold several lines; the single-line boxes can't show them.
    get entryDisabled() {
        return this.disabled || this.filledCount > 1;
    }

    get draftFields() {
        const row = this._entryRow;
        return this.columns.map((col, j) => {
            const value = row[j] || '';
            return {
                key: 'd' + j,
                c: j,
                label: this._colLabel(col),
                required: col.isRequired || col.isDate,
                value,
                isDate: col.kind === 'Date',
                isCheckbox: col.kind === 'Checkbox',
                isPicklist: col.kind === 'Picklist',
                isText: col.kind !== 'Date' && col.kind !== 'Checkbox' && col.kind !== 'Picklist',
                checked: value === 'true',
                inputMode: col.kind === 'Number' ? 'decimal' : 'text',
                maxLength: col.maxLength || null,
                options: (col.picklistOptions || []).map((o) => ({
                    key: o.value,
                    value: o.value,
                    label: o.label || o.value,
                    selected: o.value === value
                }))
            };
        });
    }

    handleModeEntry() {
        if (this.filledCount > 1) return;
        this.mode = 'entry';
        this.rows = this.rows.filter((r) => !this._isBlank(r));
    }

    handleModeTable() {
        this.mode = 'table';
    }

    handleDraftInput(event) {
        const c = Number(event.target.dataset.c);
        const row = this.columns.map((col, j) => this._entryRow[j] || '');
        row[c] = event.target.type === 'checkbox' ? (event.target.checked ? 'true' : 'false') : event.target.value;
        this.rows = this._hasValue(row) ? [row] : [];
        this._emit();
    }

    handleDraftBlur() {
        this.entryTouched = true;
    }

    // Pasting several Excel rows into an entry box switches to the table with them.
    handleDraftPaste(event) {
        const text = (event.clipboardData || window.clipboardData).getData('text');
        if (!this.showModes || !/[\t\n]/.test(text.trim())) return;
        event.preventDefault();
        this.mode = 'table';
        this._pasteAt(text, 0, 0);
    }

    // ── Events ──────────────────────────────────────────────────────────────

    _setCell(r, c, value) {
        const rows = this.rows.map((x) => [...x]);
        while (rows.length <= r) rows.push([]);
        rows[r][c] = value;
        while (rows.length && this._isBlank(rows[rows.length - 1])) rows.pop();
        this.rows = rows;
        this._emit();
    }

    handleCellChange(event) {
        const { r, c } = event.target.dataset;
        this._setCell(Number(r), Number(c), event.target.value);
    }

    // Excel copies TSV: one line per row, tabs between cells. Pasting into a cell fills from
    // that cell rightwards and downwards; a single value without tab/newline pastes normally.
    handlePaste(event) {
        const text = (event.clipboardData || window.clipboardData).getData('text');
        if (!/[\t\n]/.test(text)) return;
        event.preventDefault();
        this._pasteAt(text, Math.min(Number(event.target.dataset.r), this.rows.length), Number(event.target.dataset.c));
    }

    _pasteAt(text, r0, c0) {
        const n = this.columns.length;
        const di = this.dateIndex;
        const parsed = text.replace(/\r/g, '').split('\n').filter((l) => l.trim()).map((line) => {
            const cells = line.split('\t').map((x) => x.trim());
            const row = new Array(n).fill('');
            cells.forEach((v, j) => {
                if (c0 + j < n) row[c0 + j] = v;
            });
            // Columns pasted in another order: put the date where the date column is.
            if (c0 === 0 && di >= 0 && !looksLikeDate(row[di])) {
                const j = row.findIndex((v, k) => k !== di && looksLikeDate(v));
                if (j >= 0) [row[di], row[j]] = [row[j], row[di]];
            }
            return row;
        });
        const rows = this.rows.map((x) => [...x]);
        parsed.forEach((p, k) => {
            const existing = rows[r0 + k] || [];
            rows[r0 + k] = p.map((v, j) => (j < c0 ? existing[j] || '' : v));
        });
        this.rows = rows;
        this.choice = null;
        this._emit();
    }

    handleClear() {
        this.rows = [];
        this.entryTouched = false;
        this.choice = null;
        this._emit();
    }

    handleSwapOrder() {
        this.choice = this.order === 'dmy' ? 'mdy' : 'dmy';
        this._emit();
    }

    handleToggleHelp() {
        this.showHelp = !this.showHelp;
    }
}
