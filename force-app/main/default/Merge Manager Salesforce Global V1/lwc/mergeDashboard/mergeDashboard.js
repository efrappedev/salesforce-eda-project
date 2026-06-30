import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { getLabels } from 'c/i18n';
import getDashboardStats from '@salesforce/apex/MergeController.getDashboardStats';

const LS_KEY        = 'mergeManager_dashboard_v1';
const DEFAULT_TYPES = { status: 'bar', objType: 'donut', trendPeriod: 'month' };
const COLORS        = ['#0176d3','#2e844a','#fe9339','#ba0517','#706e6b','#9050e9','#0b827c'];
const STATUS_ORDER  = ['New','Reopened','Error','Merged','Closed','Ignored'];
const OBJ_COLORS    = { Contact: '#0176d3', Account: '#9050e9' };
const AGE_ORDER      = ['New', 'Pending', 'Stale'];
const AGE_COLORS     = { New: '#0176d3', Pending: '#9a5000', Stale: '#ba0517' };

export default class MergeDashboard extends LightningElement {
    @api lang = 'fr';

    @wire(getDashboardStats)
    _stats;

    @track _chartTypes  = { ...DEFAULT_TYPES };
    @track _trendOffset = 0;

    connectedCallback() {
        try {
            const saved = JSON.parse(localStorage.getItem(LS_KEY) || '{}');
            this._chartTypes = { ...DEFAULT_TYPES, ...saved };
        } catch (_) { /* ignore malformed storage */ }
    }

    get i18n() { return getLabels(this.lang); }

    get _monthsShort() {
        const locale = this.lang === 'fr' ? 'fr-CA' : this.lang === 'es' ? 'es' : 'en-US';
        return Array.from({ length: 12 }, (_, i) =>
            new Intl.DateTimeFormat(locale, { month: 'short' }).format(new Date(2000, i, 1))
        );
    }

    // ── Loading ───────────────────────────────────────────────────────────────

    get isLoading() {
        return !this._stats || (!this._stats.data && !this._stats.error);
    }

    // ── KPI values ────────────────────────────────────────────────────────────

    get totalTickets()    { return this._stats?.data?.totalTickets    ?? 0; }
    get pendingTickets()  { return this._stats?.data?.pendingTickets   ?? 0; }
    get mergedThisMonth() { return this._stats?.data?.mergedThisMonth  ?? 0; }
    get errorCount()      { return this._stats?.data?.errorCount       ?? 0; }

    // ── Chart type flags ──────────────────────────────────────────────────────

    get isBarStatus()    { return this._chartTypes.status !== 'donut'; }
    get isDonutStatus()  { return this._chartTypes.status === 'donut'; }
    get isDonutObjType() { return this._chartTypes.objType !== 'bar'; }
    get isBarObjType()   { return this._chartTypes.objType === 'bar'; }

    get trendPeriod()    { return this._chartTypes.trendPeriod || 'month'; }
    get isTrendWeek()    { return this.trendPeriod === 'week' || this.trendPeriod === 'day'; }
    get isTrendMonth()   { return this.trendPeriod === 'month'; }
    get isTrendYear()    { return this.trendPeriod === 'year'; }

    get statusBarClass()    { return `dash-toggle-btn${this.isBarStatus    ? ' dash-toggle-btn--active' : ''}`; }
    get statusDonutClass()  { return `dash-toggle-btn${this.isDonutStatus  ? ' dash-toggle-btn--active' : ''}`; }
    get objTypeDonutClass() { return `dash-toggle-btn${this.isDonutObjType ? ' dash-toggle-btn--active' : ''}`; }
    get objTypeBarClass()   { return `dash-toggle-btn${this.isBarObjType   ? ' dash-toggle-btn--active' : ''}`; }
    get trendWeekClass()    { return `dash-toggle-btn${this.isTrendWeek    ? ' dash-toggle-btn--active' : ''}`; }
    get trendMonthClass()   { return `dash-toggle-btn${this.isTrendMonth   ? ' dash-toggle-btn--active' : ''}`; }
    get trendYearClass()    { return `dash-toggle-btn${this.isTrendYear    ? ' dash-toggle-btn--active' : ''}`; }

    get trendWindowLabel() {
        const today  = new Date();
        const offset = this._trendOffset;
        if (this.isTrendWeek) {
            const endDay   = new Date(today);
            endDay.setDate(today.getDate() - offset * 7);
            const startDay = new Date(endDay);
            startDay.setDate(endDay.getDate() - 6);
            return `${this._monthsShort[startDay.getMonth()]} ${startDay.getDate()} – ${this._monthsShort[endDay.getMonth()]} ${endDay.getDate()}`;
        }
        if (this.isTrendMonth) {
            const d = new Date(today.getFullYear(), today.getMonth() - offset, 1);
            return `${this._monthsShort[d.getMonth()]} ${d.getFullYear()}`;
        }
        return `${today.getFullYear() - offset}`;
    }
    get navPrevDisabled() {
        const MAX = { week: 11, month: 2, year: 2 };
        return this._trendOffset >= (MAX[this.trendPeriod] || 11);
    }
    get navNextDisabled() { return this._trendOffset <= 0; }

    // ── Status ────────────────────────────────────────────────────────────────

    get _statusRaw() {
        const map = this._stats?.data?.byStatus || {};
        const t   = this.i18n;
        const LABELS = {
            New:      t.statusNew      || 'New',
            Reopened: t.statusReopened || 'Reopened',
            Error:    t.statusErrors   || 'Error',
            Merged:   t.statusMerged   || 'Merged',
            Closed:   t.statusClosed   || 'Closed',
            Ignored:  t.statusIgnored  || 'Ignored'
        };
        return STATUS_ORDER
            .filter(k => map[k] > 0)
            .map(k => ({ key: k, label: LABELS[k] || k, value: map[k] }));
    }

    get hasStatusData() { return this._statusRaw.length > 0; }

    get statusData() {
        const raw = this._statusRaw;
        const max = Math.max(...raw.map(r => r.value), 1);
        return raw.map((row, i) => ({
            ...row,
            barStyle: `width:${Math.round(row.value / max * 100)}%;background:${COLORS[i % COLORS.length]}`,
            dotStyle: `background:${COLORS[i % COLORS.length]}`
        }));
    }

    get statusDonutStyle() {
        const total = this.totalTickets;
        if (!total) return 'background:#e0e0e0';
        const raw = this._statusRaw;
        let deg = 0;
        const segs = raw.map((row, i) => {
            const span = row.value / total * 360;
            const c    = COLORS[i % COLORS.length];
            const from = deg;
            deg += span;
            return `${c} ${from}deg ${deg}deg`;
        });
        return `background:conic-gradient(${segs.join(',')})`;
    }

    // ── Match type ────────────────────────────────────────────────────────────

    get _matchTypeRaw() {
        const map = this._stats?.data?.byMatchType || {};
        const t   = this.i18n;
        const LABELS = { Email: t.matchEmail || 'Email', Phone: t.matchPhone || 'Phone', Name: 'Name' };
        return Object.keys(map)
            .filter(k => map[k] > 0)
            .sort()
            .map(k => ({ key: k, label: LABELS[k] || k, value: map[k] }));
    }

    get hasMatchTypeData() { return this._matchTypeRaw.length > 0; }

    get matchTypeData() {
        const raw = this._matchTypeRaw;
        const max = Math.max(...raw.map(r => r.value), 1);
        return raw.map((row, i) => ({
            ...row,
            barStyle: `width:${Math.round(row.value / max * 100)}%;background:${COLORS[i % COLORS.length]}`
        }));
    }

    // ── Age (New/Reopened tickets bucketed by days since CreatedDate) ─────────

    get _ageRaw() {
        const map = this._stats?.data?.byAge || {};
        const t   = this.i18n;
        const LABELS = {
            New:     t.statusNew || 'New',
            Pending: t.statusPending || 'Pending',
            Stale:   t.statusStale || 'Stale'
        };
        return AGE_ORDER
            .filter(k => map[k] > 0)
            .map(k => ({ key: k, label: LABELS[k] || k, value: map[k], color: AGE_COLORS[k] }));
    }

    get hasAgeData() { return this._ageRaw.length > 0; }

    get ageData() {
        const raw = this._ageRaw;
        const max = Math.max(...raw.map(r => r.value), 1);
        return raw.map(row => ({
            ...row,
            barStyle: `width:${Math.round(row.value / max * 100)}%;background:${row.color}`
        }));
    }

    // ── Object type ───────────────────────────────────────────────────────────

    get _objTypeRaw() {
        const map = this._stats?.data?.byObjectType || {};
        const t   = this.i18n;
        const LABELS = {
            Contact: t.objectTypeContact || 'Contact',
            Account: t.objectTypeAccount || 'Account'
        };
        return Object.keys(map)
            .filter(k => map[k] > 0)
            .sort()
            .map(k => ({ key: k, label: LABELS[k] || k, value: map[k] }));
    }

    get hasObjTypeData() { return this._objTypeRaw.length > 0; }

    get objTypeData() {
        const raw = this._objTypeRaw;
        const max = Math.max(...raw.map(r => r.value), 1);
        return raw.map(row => ({
            ...row,
            barStyle: `width:${Math.round(row.value / max * 100)}%;background:${OBJ_COLORS[row.key] || COLORS[0]}`,
            dotStyle: `background:${OBJ_COLORS[row.key] || COLORS[0]}`
        }));
    }

    get objTypeDonutStyle() {
        const total = this._objTypeRaw.reduce((s, r) => s + r.value, 0);
        if (!total) return 'background:#e0e0e0';
        let deg = 0;
        const segs = this._objTypeRaw.map(row => {
            const span = row.value / total * 360;
            const c    = OBJ_COLORS[row.key] || COLORS[0];
            const from = deg;
            deg += span;
            return `${c} ${from}deg ${deg}deg`;
        });
        return `background:conic-gradient(${segs.join(',')})`;
    }

    // ── Closed reasons ────────────────────────────────────────────────────────

    _shortReason(raw) {
        return raw.replace(/^False\s+Positive\s*[-–]\s*/i, '').trim();
    }

    _translateReason(raw) {
        const short = this._shortReason(raw);
        const t = this.i18n;
        const map = {
            // EN values
            'same household':            t.reasonHousehold,
            'same home':                 t.reasonHousehold,
            'same organization':         t.reasonOrganization,
            'shared phone':              t.reasonSharedPhone,
            'shared email':              t.reasonSharedEmail,
            'already resolved':          t.reasonResolved,
            'already resolved manually': t.reasonResolved,
            'already merged manually':   t.reasonResolved,
            'out of scope':              t.reasonOutOfScope,
            'other':                     t.reasonOther,
            'other (see notes)':         t.reasonOther,
            'not a duplicate':           t.reasonOther,
            // FR values
            'même domicile':             t.reasonHousehold,
            'même ménage':               t.reasonHousehold,
            'même organisation':         t.reasonOrganization,
            'tél. partagé':              t.reasonSharedPhone,
            'courriel partagé':          t.reasonSharedEmail,
            'déjà résolu':               t.reasonResolved,
            'déjà résolu manuellement':  t.reasonResolved,
            'hors périmètre':            t.reasonOutOfScope,
            'autre':                     t.reasonOther,
            'autre (voir notes)':        t.reasonOther,
            // ES values
            'mismo domicilio':           t.reasonHousehold,
            'misma organización':        t.reasonOrganization,
            'tel. compartido':           t.reasonSharedPhone,
            'correo compartido':         t.reasonSharedEmail,
            'ya resuelto':               t.reasonResolved,
            'ya resuelto manualmente':   t.reasonResolved,
            'fuera de alcance':          t.reasonOutOfScope,
            'otro':                      t.reasonOther,
            'otro (ver notas)':          t.reasonOther,
        };
        return map[short.toLowerCase()] || short;
    }

    get _closedReasonRaw() {
        const map = this._stats?.data?.byClosedReason || {};
        return Object.keys(map)
            .filter(k => map[k] > 0)
            .sort((a, b) => map[b] - map[a])
            .map(k => ({ key: k, label: this._translateReason(k), value: map[k] }));
    }

    get hasClosedReasonData() { return this._closedReasonRaw.length > 0; }

    get closedReasonData() {
        const raw = this._closedReasonRaw;
        const max = Math.max(...raw.map(r => r.value), 1);
        return raw.map((row, i) => ({
            ...row,
            barStyle: `width:${Math.round(row.value / max * 100)}%;background:${COLORS[i % COLORS.length]}`
        }));
    }

    // ── Trend (week / month / year) — navigable, grouped bars ────────────────

    _dayRawMap(raw) {
        const m = {};
        (raw || []).forEach(e => {
            const k = `${e.year}-${e.month}-${e.day}`;
            if (!m[k]) m[k] = { contact: 0, account: 0 };
            if (e.objType === 'Contact')      m[k].contact += e.count;
            else if (e.objType === 'Account') m[k].account += e.count;
        });
        return m;
    }

    _buildGroupedBars(slots, maxPx = 80) {
        const maxCount = Math.max(...slots.flatMap(s => [s.contact, s.account]), 1);
        return slots.map(s => {
            const cH = Math.round(s.contact / maxCount * maxPx);
            const aH = Math.round(s.account / maxCount * maxPx);
            return {
                key:              s.key,
                label:            s.label,
                contactCount:     s.contact,
                accountCount:     s.account,
                showContactCount: s.contact > 0,
                showAccountCount: s.account > 0,
                contactBarStyle:  `height:${Math.max(cH, s.contact > 0 ? 2 : 0)}px;background:#0176d3;border-radius:2px 2px 0 0`,
                accountBarStyle:  `height:${Math.max(aH, s.account > 0 ? 2 : 0)}px;background:#9050e9;border-radius:2px 2px 0 0`
            };
        });
    }

    get trendData() {
        const period = this.trendPeriod;
        const offset = this._trendOffset;
        const today  = new Date();

        // ── Week: 7 day-bars, navigate by week ──────────────────────────────
        if (period === 'week' || period === 'day') {
            const rawMap = this._dayRawMap(this._stats?.data?.mergedByDay);
            const endDay = new Date(today);
            endDay.setDate(today.getDate() - offset * 7);
            const slots = [];
            for (let i = 6; i >= 0; i--) {
                const d  = new Date(endDay);
                d.setDate(endDay.getDate() - i);
                const k  = `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
                const e  = rawMap[k] || { contact: 0, account: 0 };
                slots.push({ key: k, label: `${this._monthsShort[d.getMonth()]} ${d.getDate()}`, ...e });
            }
            return this._buildGroupedBars(slots);
        }

        // ── Month: 4-5 week-bucket bars, navigate by month ──────────────────
        if (period === 'month') {
            const rawMap  = this._dayRawMap(this._stats?.data?.mergedByDay);
            const tgtDate = new Date(today.getFullYear(), today.getMonth() - offset, 1);
            const yr      = tgtDate.getFullYear();
            const mo      = tgtDate.getMonth() + 1;
            const dim     = new Date(yr, tgtDate.getMonth() + 1, 0).getDate();
            const BUCKETS = [{ s: 1, e: 7 }, { s: 8, e: 14 }, { s: 15, e: 21 }, { s: 22, e: 28 }];
            if (dim > 28) BUCKETS.push({ s: 29, e: dim });
            const slots = BUCKETS.map(b => {
                const agg = { contact: 0, account: 0 };
                for (let d = b.s; d <= b.e; d++) {
                    const de = rawMap[`${yr}-${mo}-${d}`] || { contact: 0, account: 0 };
                    agg.contact += de.contact;
                    agg.account += de.account;
                }
                return { key: `${yr}-${mo}-w${b.s}`, label: b.s >= 29 ? `${b.s}+` : `${b.s}-${b.e}`, ...agg };
            });
            return this._buildGroupedBars(slots);
        }

        // ── Year: 12 monthly bars for target year, navigate by year ─────────
        const rawMonth = this._stats?.data?.mergedByMonth || [];
        const rawMap   = {};
        rawMonth.forEach(e => {
            const k = `${e.year}-${e.month}`;
            if (!rawMap[k]) rawMap[k] = { contact: 0, account: 0 };
            if (e.objType === 'Contact')      rawMap[k].contact += e.count;
            else if (e.objType === 'Account') rawMap[k].account += e.count;
        });
        const tgtYear = today.getFullYear() - offset;
        const slots   = [];
        for (let m = 1; m <= 12; m++) {
            const e = rawMap[`${tgtYear}-${m}`] || { contact: 0, account: 0 };
            slots.push({ key: `${tgtYear}-${m}`, label: this._monthsShort[m - 1], ...e });
        }
        return this._buildGroupedBars(slots);
    }

    // ── Actions ───────────────────────────────────────────────────────────────

    handleRefresh() {
        if (this._stats) refreshApex(this._stats);
    }

    handleReset() {
        this._chartTypes = { ...DEFAULT_TYPES };
        localStorage.removeItem(LS_KEY);
    }

    handleChartTypeToggle(event) {
        const key  = event.currentTarget.dataset.key;
        const type = event.currentTarget.dataset.type;
        if (key === 'trendPeriod') this._trendOffset = 0;
        this._chartTypes = { ...this._chartTypes, [key]: type };
        localStorage.setItem(LS_KEY, JSON.stringify(this._chartTypes));
    }

    handleTrendPrev() {
        const MAX = { week: 11, month: 2, year: 2 };
        this._trendOffset = Math.min(this._trendOffset + 1, MAX[this.trendPeriod] || 11);
    }

    handleTrendNext() {
        this._trendOffset = Math.max(0, this._trendOffset - 1);
    }
}
