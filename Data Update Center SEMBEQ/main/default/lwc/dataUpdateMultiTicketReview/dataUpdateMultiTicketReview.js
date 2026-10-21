import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import DucConfirmModal from 'c/ducConfirmModal';
import { getLabels, format } from 'c/dataUpdateI18n';
import { statusStyle, statusLabel, ticketNumber, formatDate } from 'c/dataUpdateUi';
import getGroupContextApex from '@salesforce/apex/DataUpdateMultiTicketReviewController.getGroupContext';
import applyGroupTicketApex from '@salesforce/apex/DataUpdateMultiTicketReviewController.applyGroupTicket';
import getComparisonDataApex from '@salesforce/apex/DataUpdateReviewController.getComparisonData';
import correctProposedValueApex from '@salesforce/apex/DataUpdateReviewController.correctProposedValue';
import ignoreRequestApex from '@salesforce/apex/DataUpdateReviewController.ignoreRequest';
import getAuditLogApex from '@salesforce/apex/DataUpdateReviewController.getAuditLog';

// Same server-side value checks as the single-ticket panel (correctProposedValue).
const EDIT_ERROR_KEYS = {
    INVALID_DATE: 'editInvalidDate',
    INVALID_NUMBER: 'editInvalidNumber',
    INVALID_BOOLEAN: 'editInvalidBoolean',
    INVALID_EMAIL: 'editInvalidEmail',
    INVALID_PICKLIST: 'editInvalidPicklist',
    VALUE_TOO_LONG: 'editValueTooLong'
};

const norm = (x) => String(x == null ? '' : x).trim().toLowerCase();

// Two table cells hold the same value ("118" vs "118.0", "4 820" vs "4820").
const sameCell = (a, b) => {
    const x = String(a == null ? '' : a).trim();
    const y = String(b == null ? '' : b).trim();
    if (x === y) return true;
    if (x === '' || y === '') return false;
    const nx = Number(x.replace(/\s/g, '').replace(',', '.'));
    const ny = Number(y.replace(/\s/g, '').replace(',', '.'));
    return !isNaN(nx) && !isNaN(ny) && nx === ny;
};

/**
 * Grouped review: every open ticket of one record on one screen (staff with the
 * Data_Update_Multi_Ticket_Review permission). Account values sent in several tickets are merged,
 * each value picks where it is saved ("Save to"), history rows are kept per ticket, and
 * Apply runs ticket by ticket so each one keeps its own log and rollback.
 */
export default class DataUpdateMultiTicketReview extends LightningElement {
    @api targetRecordId;
    @api lang = 'fr';

    @track isLoading = true;
    @track errorText = '';
    @track tickets = [];
    @track slotGroups = [];
    emailSavedIn = '';
    phoneSavedIn = '';
    @track recordName = '';

    // decisions
    @track tog = {};
    @track picks = {};
    @track edits = {};
    @track ho = {};
    @track hopen = {};
    @track editingId = null;
    @track draft = '';
    @track isSavingEdit = false;

    // apply / ignore
    @track isWorking = false;
    @track progressText = '';
    @track closedTickets = [];
    @track isIgnoreOpen = false;
    @track ignoreReason = '';
    @track ignoreNote = '';

    _focusEdit = false;

    connectedCallback() {
        this._load();
    }

    renderedCallback() {
        if (this._focusEdit) {
            const inp = this.template.querySelector('.grp-vin');
            if (inp) {
                inp.focus();
                this._focusEdit = false;
            }
        }
    }

    // Another tab changed a ticket: reload, keeping the choices not applied yet.
    @api
    refresh() {
        if (!this.isWorking) this._load(true);
    }

    get i18n() { return getLabels(this.lang); }

    _label(fr, en) {
        return this.lang === 'en' ? (en || fr || '') : (fr || en || '');
    }

    // ── Load ─────────────────────────────────────────────────────────────────

    async _load(keepChoices) {
        this.isLoading = true;
        this.errorText = '';
        try {
            const ctx = await getGroupContextApex({ targetRecordId: this.targetRecordId });
            if (!ctx || !ctx.success) {
                this.errorText = this.i18n.reviewErrGeneric;
                return;
            }
            this.recordName = ctx.recordName || '';
            this.slotGroups = ctx.slotGroups || [];
            this.emailSavedIn = ctx.emailSavedIn || '';
            this.phoneSavedIn = ctx.phoneSavedIn || '';
            const datas = await Promise.all((ctx.tickets || []).map((t) =>
                getComparisonDataApex({ requestId: t.id }).catch(() => null)));
            // Fields already corrected by staff on each ticket → "Value corrected" badge, like the single panel.
            const audits = await Promise.all((ctx.tickets || []).map((t) =>
                getAuditLogApex({ requestId: t.id }).catch(() => null)));
            this.tickets = (ctx.tickets || []).map((t, i) => {
                const tno = ticketNumber(t.requestNumber);
                const corrected = new Set();
                ((audits[i] && audits[i].success && audits[i].entries) || []).forEach((e) => {
                    if (e.actionType === 'CORRECTED') (e.fieldChanges || []).forEach((fc) => corrected.add(fc.fieldApiName));
                });
                return { ...t, no: tno.full, zeros: tno.zeros, digits: tno.digits, data: datas[i], corrected };
            }).filter((t) => t.data && t.data.success);
            if (!keepChoices) {
                this.tog = {};
                this.picks = {};
                this.ho = {};
            }
            // corrections are saved on the ticket itself — the reload already carries them
            this.edits = {};
            this.editingId = null;
        } catch (e) {
            const msg = (e && e.body && e.body.message) || '';
            this.errorText = msg === 'NO_PERMISSION' ? this.i18n.grpNoPermission : this.i18n.reviewErrGeneric;
        } finally {
            this.isLoading = false;
        }
    }

    get hasError() { return !!this.errorText; }
    get hasTickets() { return !this.isLoading && !this.errorText && this.tickets.length > 0; }
    get isDone() { return !this.isLoading && !this.errorText && this.tickets.length === 0; }
    get hasClosedTickets() { return this.closedTickets.length > 0; }

    get headerSub() {
        const n = this.tickets.length;
        const forms = new Set(this.tickets.map((t) => t.formDeveloperName || t.formLabel));
        const formsTxt = forms.size === 1 ? this.i18n.grpOneForm : format(this.i18n.grpFormsFmt, forms.size);
        const parts = [format(this.i18n.grpTicketsFmt, n), formsTxt];
        if (n) {
            const first = formatDate(this.tickets[n - 1].createdDate, this.lang);
            const last = formatDate(this.tickets[0].createdDate, this.lang);
            parts.push(first === last ? last : first + ' – ' + last);
        }
        return parts.join(' · ');
    }

    // ── Account fields ───────────────────────────────────────────────────────

    // "Save to" places for a field: the field itself first, then the other fields of its kind.
    // EDA contact: Email (Phone) is saved in the preferred field of its kind, so its places are that field's.
    _slotsFor(apiName) {
        const savedIn = norm(apiName) === 'email' ? this.emailSavedIn : norm(apiName) === 'phone' ? this.phoneSavedIn : '';
        const isMain = !!savedIn;
        const lower = isMain ? norm(savedIn) : norm(apiName);
        for (const g of this.slotGroups) {
            // Email / Phone have one place only: another field would leave the main one unchanged.
            if (isMain) {
                const own = (g.slots || []).find((s) => norm(s.apiName) === lower);
                if (own) return [own];
                continue;
            }
            const own = (g.slots || []).find((s) => norm(s.apiName) === lower);
            if (own) return [own, ...g.slots.filter((s) => s !== own)];
        }
        return null;
    }

    get _fieldModel() {
        const i18n = this.i18n;
        const byField = new Map();
        const groups = [];
        this.tickets.forEach((t) => {
            const add = (f, unchanged) => {
                if (f.submittedValue == null || f.submittedValue === '') return;
                let g = byField.get(f.fieldApiName);
                if (!g) {
                    g = { api: f.fieldApiName, label: this._label(f.fieldLabelFr, f.fieldLabelEn),
                        labelFr: f.fieldLabelFr, labelEn: f.fieldLabelEn, values: [] };
                    byField.set(f.fieldApiName, g);
                    groups.push(g);
                }
                g.values.push({ t, orig: f.submittedValue, current: f.currentValue, unchanged });
            };
            (t.data.fields || []).forEach((f) => add(f, false));
            (t.data.unchangedFields || []).forEach((f) => add(f, true));
        });

        const rows = [];
        const used = {};
        groups.forEach((g) => {
            const slots = this._slotsFor(g.api);
            // The same value sent in several tickets → one row (newest ticket owns it).
            const vals = [];
            const byVal = {};
            g.values.forEach((v) => {
                const k = norm(v.orig);
                if (byVal[k]) {
                    byVal[k].members.push(v.t);
                    return;
                }
                byVal[k] = { owner: v, members: [v.t], id: g.api + '|' + v.t.id };
                vals.push(byVal[k]);
            });
            // pass 1: value already on the record → locked, its place is taken
            vals.forEach((v) => {
                v.edited = this.edits[v.id] !== undefined && this.edits[v.id] !== v.owner.orig;
                v.val = v.edited ? this.edits[v.id] : v.owner.orig;
                if (slots) {
                    const home = slots.find((s) => norm(s.value) !== '' && norm(s.value) === norm(v.val));
                    v.same = !!home;
                    if (home) {
                        v.key = home.apiName;
                        used[norm(home.apiName)] = true;
                    }
                } else {
                    v.same = v.edited ? norm(v.val) === norm(v.owner.current) : v.owner.unchanged;
                    if (v.same) v.key = g.api;
                }
            });
            // pass 2: the rest → picked place, else the field itself if free, else first empty free place
            let firstLive = true;
            const liveUsed = {};
            vals.forEach((v) => {
                if (v.same) {
                    v.on = false;
                    return;
                }
                if (slots) {
                    let key = this.picks[v.id];
                    if (!key) {
                        const free = slots.find((s) => !s.value && !used[norm(s.apiName)]);
                        key = !used[norm(slots[0].apiName)] ? slots[0].apiName : (free || slots[0]).apiName;
                    }
                    // no free place left: a newer value already goes there, so this one starts
                    // unchecked instead of opening as a conflict staff must undo
                    const taken = !this.picks[v.id] && !!liveUsed[norm(key)];
                    used[norm(key)] = true;
                    liveUsed[norm(key)] = true;
                    v.key = key;
                    v.on = this.tog[v.id] !== undefined ? this.tog[v.id] : !taken;
                } else {
                    v.key = g.api;
                    // one place only: the newest value starts checked
                    v.on = this.tog[v.id] !== undefined ? this.tog[v.id] : firstLive;
                }
                firstLive = false;
            });
            vals.forEach((v, i) => rows.push({ g, slots, v, first: i === 0 }));
        });

        // A value already on the record is "Same" only while nothing else is saved over it. When a
        // checked value goes to its place, it is replaced: the row unlocks (unchecked — the newer
        // value wins) so staff can see it and, to keep it, check it and pick another place.
        // Repeated because a kept value moved to another place can in turn replace another one.
        for (let changed = true; changed;) {
            changed = false;
            const takenBy = {};
            rows.forEach(({ v }) => {
                if (v.on && !v.same && !takenBy[norm(v.key)]) takenBy[norm(v.key)] = v;
            });
            rows.forEach(({ v }) => {
                if (!v.same || !takenBy[norm(v.key)]) return;
                v.same = false;
                v.replacedBy = takenBy[norm(v.key)];
                v.home = v.key;
                if (this.picks[v.id]) v.key = this.picks[v.id];
                v.on = this.tog[v.id] !== undefined ? this.tog[v.id] : false;
                changed = true;
            });
        }

        const onByKey = {};
        rows.forEach(({ v }) => {
            if (v.on) onByKey[norm(v.key)] = (onByKey[norm(v.key)] || 0) + 1;
        });

        let hasClash = false;
        const out = rows.map(({ g, slots, v, first }) => {
            const slot = slots ? slots.find((s) => norm(s.apiName) === norm(v.key)) : null;
            const placeLabel = slot ? slot.label : g.label;
            const placeValue = slot ? slot.value : v.owner.current;
            const clash = v.on && onByKey[norm(v.key)] > 1;
            if (clash) hasClash = true;
            let note = '';
            let noteClass = 'grp-ow';
            let isNew = false;
            let oldValue = '';
            const atHome = !!v.replacedBy && norm(v.key) === norm(v.home);
            if (v.same) {
                note = slots ? format(i18n.grpAlreadyInFmt, placeLabel) : '';
                noteClass += ' grp-ow_same';
            } else if (clash) {
                note = i18n.grpClash;
                noteClass += ' grp-ow_bad';
            } else if (atHome) {
                // still where it is today: the newer value takes this place
                note = format(slots && slots.length > 1 ? i18n.grpReplacedByFmt : i18n.grpReplacedByOneFmt,
                    v.replacedBy.val, v.replacedBy.owner.t.no);
            } else if (!placeValue) {
                isNew = true;
            } else {
                // same look as the single-ticket panel: the value being replaced, struck through
                oldValue = placeValue;
            }
            const isCorrected = !v.same && (v.edited || (v.owner.t.corrected && v.owner.t.corrected.has(g.api)));
            const editing = this.editingId === v.id;
            const vtag = v.same || v.replacedBy ? i18n.grpAlreadyOnAccount : (v.edited ? i18n.grpNotOnAccount : '');
            return {
                id: v.id,
                api: g.api,
                labelFr: g.labelFr,
                labelEn: g.labelEn,
                ownerId: v.owner.t.id,
                ownerNo: v.owner.t.no,
                orig: v.owner.orig,
                key: v.key,
                members: v.members,
                label: g.label,
                // the same field again: label repeated, lighter, so the row never looks empty
                labelClass: 'grp-flabel' + (first ? '' : ' grp-flabel_rep'),
                cbLabel: `${i18n.grpColApply} — ${g.label} : ${v.val} (#${v.owner.t.no})`,
                value: v.val,
                checked: !!v.on,
                same: v.same,
                rowClass: 'grp-fr' + (v.on ? '' : ' grp-off') + (first ? ' grp-first' : ''),
                editing,
                notEditing: !editing,
                edited: v.edited,
                isCorrected,
                hasOld: !!oldValue,
                oldValue,
                valueClass: v.same ? 'grp-newv grp-newv_same' : 'duc-v duc-v_new grp-vpill',
                hasVtag: !!vtag,
                vtag,
                vtagClass: 'grp-vtag ' + (v.same || v.replacedBy ? 'grp-vtag_on' : 'grp-vtag_not'),
                replacedNo: v.replacedBy ? v.replacedBy.owner.t.no : '',
                replacedAtHome: atHome,
                showSel: !!slots && !v.same && slots.length > 1,
                showText: !slots || v.same || slots.length === 1,
                slotText: placeLabel,
                slotOptions: slots ? slots.map((s) => ({
                    key: s.apiName,
                    selected: norm(s.apiName) === norm(v.key),
                    text: s.label + ' — ' + (s.value || i18n.grpSlotEmpty)
                })) : [],
                isNew,
                showSameTag: v.same,
                hasNote: !!note,
                note,
                noteClass,
                ticketText: '#' + v.members.map((t) => t.no).join(' · #'),
                multiTk: v.members.length > 1,
                tkNote: format(i18n.grpSentInFmt, v.members.length)
            };
        });
        const live = out.filter((r) => !r.same);
        const n = out.filter((r) => r.checked).length;
        return { rows: out, n, live: live.length, hasClash };
    }

    get fieldRows() { return this._fieldModel.rows; }
    get hasFields() { return this.fieldRows.length > 0; }
    get fieldSelText() {
        const m = this._fieldModel;
        return format(this.i18n.grpSelectedFmt, m.n + '/' + m.live);
    }

    handleFieldToggle(event) {
        const id = event.currentTarget.dataset.id;
        this.tog = { ...this.tog, [id]: event.target.checked };
    }

    handleFieldsAll(event) {
        const val = event.currentTarget.dataset.val === 'all';
        const t = { ...this.tog };
        // "All" leaves a value about to be replaced unchecked — checked where it is, it would clash
        // with the newer value; to keep it, staff checks it and picks another place.
        this._fieldModel.rows.filter((r) => !r.same && !(val && r.replacedAtHome))
            .forEach((r) => { t[r.id] = val; });
        this.tog = t;
    }

    handleSlotPick(event) {
        const id = event.currentTarget.dataset.id;
        this.picks = { ...this.picks, [id]: event.target.value };
    }

    handleEditStart(event) {
        if (this.editingId || this.isWorking) return;
        const id = event.currentTarget.dataset.id;
        const row = this.fieldRows.find((r) => r.id === id);
        if (!row) return;
        this.editingId = id;
        this.draft = row.value || '';
        this._focusEdit = true;
    }

    handleDraftChange(event) {
        this.draft = event.target.value;
    }

    handleEditKey(event) {
        if (event.key === 'Enter') {
            event.preventDefault();
            this.handleEditSave();
        } else if (event.key === 'Escape') {
            event.preventDefault();
            this.editingId = null;
        }
    }

    async handleEditSave() {
        const row = this.fieldRows.find((r) => r.id === this.editingId);
        if (!row) {
            this.editingId = null;
            return;
        }
        const newValue = (this.draft || '').trim();
        if (!newValue) {
            this._toast(this.i18n.toastEditErrorTitle, this.i18n.editValueRequiredMsg, 'error');
            return;
        }
        if (newValue === row.value) {
            this.editingId = null;
            return;
        }
        if (await this._correct(row, newValue)) this.editingId = null;
    }

    async handleEditRevert(event) {
        const row = this.fieldRows.find((r) => r.id === event.currentTarget.dataset.id);
        if (!row) return;
        if (await this._correct(row, row.orig)) {
            this.editingId = null;
            const t = { ...this.tog };
            delete t[row.id];
            this.tog = t;
        }
    }

    // The value is corrected on the ticket that owns the row (the newest one that sent it).
    async _correct(row, newValue) {
        if (this.isSavingEdit) return false;
        this.isSavingEdit = true;
        try {
            const result = await correctProposedValueApex({
                requestId: row.ownerId, fieldApiName: row.api, newValue
            });
            if (result.success) {
                const ed = { ...this.edits };
                if (result.newValue === row.orig) delete ed[row.id];
                else ed[row.id] = result.newValue;
                this.edits = ed;
                return true;
            }
            const key = EDIT_ERROR_KEYS[result.errorMessage];
            let msg = key ? this.i18n[key] : this.i18n.reviewErrGeneric;
            if (result.errorMessage === 'INVALID_POSTAL_CODE') msg = this.i18n.errInvalidPostalCode;
            if (result.errorMessage === 'TICKET_ALREADY_CLOSED') msg = this.i18n.toastTicketChangedMsg;
            this._toast(this.i18n.toastEditErrorTitle, msg, 'error');
        } catch (e) {
            this._toast(this.i18n.toastEditErrorTitle, this.i18n.reviewErrGeneric, 'error');
        } finally {
            this.isSavingEdit = false;
        }
        return false;
    }

    // ── History tables ───────────────────────────────────────────────────────

    _fmtDay(d) {
        if (!/^\d{4}-\d{2}-\d{2}$/.test(d || '')) return d || '';
        return new Date(d + 'T12:00:00').toLocaleDateString(this.lang === 'en' ? 'en-CA' : 'fr-CA', {
            year: 'numeric', month: 'short', day: 'numeric'
        });
    }

    get _histModel() {
        const i18n = this.i18n;
        const ho = this.ho;
        const tabMap = new Map();
        const tabs = [];
        this.tickets.forEach((t) => (t.data.tables || []).forEach((tb) => {
            let g = tabMap.get(tb.key);
            if (!g) {
                g = { key: tb.key, title: this._label(tb.titleFr, tb.titleEn), titleFr: tb.titleFr,
                    titleEn: tb.titleEn, columns: tb.columns || [], entries: [] };
                tabMap.set(tb.key, g);
                tabs.push(g);
            }
            g.entries.push({ t, rows: tb.rows || [] });
        }));

        const meta = {};
        let nOn = 0;
        let nAll = 0;
        const tabOut = tabs.map((g) => {
            const dateIdx = g.columns.findIndex((c) => c.isDate);
            const valOf = (cells) => (cells || []).filter((c, i) => i !== dateIdx).join(' · ');
            const dateOf = (t, r) => r.dateValue || (dateIdx >= 0 ? (r.cells || [])[dateIdx] : '') || ('#' + t.id + ':' + r.index);
            const sameAsSf = (r) => r.isDuplicate === true
                && (r.cells || []).every((c, i) => i === dateIdx || sameCell(c, (r.existingCells || [])[i]));
            const keyOf = (t, r) => g.key + '|' + t.id + '|' + r.index;
            // who sent each date, newest ticket first
            const byDate = {};
            g.entries.forEach(({ t, rows }) => rows.forEach((r) => {
                const d = dateOf(t, r);
                (byDate[d] = byDate[d] || []).push({ t, r, key: keyOf(t, r), same: sameAsSf(r), v: valOf(r.cells) });
            }));
            const isOn = (e, d) => {
                if (e.same) return false;
                if (e.key in ho) return ho[e.key];
                if (e.r.isDuplicate) return false;
                return byDate[d][0].t.id === e.t.id;
            };
            const tabKeys = [];
            let tOn = 0;
            let tAll = 0;
            const tickets = g.entries.map(({ t, rows }) => {
                let kOn = 0;
                let inSf = 0;
                let diffSf = 0;
                let also = 0;
                const alsoNos = new Set();
                const keys = [];
                const sorted = rows.slice().sort((a, b) => String(dateOf(t, b)).localeCompare(String(dateOf(t, a))));
                const rowOut = sorted.map((r) => {
                    const d = dateOf(t, r);
                    const e = byDate[d].find((x) => x.t.id === t.id && x.r.index === r.index);
                    const checked = isOn(e, d);
                    // a date already in Salesforce (here or in the other ticket) is locked — no choice to make
                    const others = e.same ? [] : byDate[d].filter((x) => x !== e && !x.same);
                    const clash = checked && others.some((o) => isOn(o, d));
                    let note = '';
                    let noteCls = '';
                    if (e.same) {
                        note = i18n.grpInSf;
                        inSf++;
                    } else if (r.isDuplicate) {
                        note = format(i18n.grpSfHasFmt, valOf(r.existingCells));
                        noteCls = 'grp-hn_warn';
                        diffSf++;
                    }
                    if (others.length) {
                        also++;
                        others.forEach((x) => alsoNos.add('#' + x.t.no));
                        const o = others[0];
                        if (clash) {
                            note = format(i18n.grpTwoValuesFmt, o.t.no, o.v);
                            noteCls = 'grp-hn_bad';
                        } else if (checked) {
                            note = format(i18n.grpUsingFmt, o.t.no, o.v);
                            noteCls = 'grp-hn_warn';
                        } else if (!e.same && !note) {
                            note = format(i18n.grpUseInsteadFmt, o.t.no, o.v);
                            noteCls = 'grp-hn_warn';
                        }
                    }
                    meta[e.key] = { others: others.map((o) => o.key), same: e.same, date: d, tab: g.key, ticketId: t.id };
                    if (!e.same) {
                        keys.push(e.key);
                        tabKeys.push(e.key);
                    }
                    if (checked) kOn++;
                    return {
                        key: e.key,
                        index: r.index,
                        dateIso: d,
                        date: this._fmtDay(d),
                        value: valOf(r.cells),
                        cbLabel: `${i18n.grpColApply} — ${g.title} ${this._fmtDay(d)} : ${valOf(r.cells)} (#${t.no})`,
                        checked,
                        locked: e.same,
                        clash,
                        otherChecked: others.find((o) => isOn(o, d)),
                        rowClass: checked ? 'grp-hr' : 'grp-hr grp-off',
                        hasNote: !!note,
                        note,
                        noteClass: 'grp-hn ' + noteCls
                    };
                });
                tOn += kOn;
                tAll += rows.length;
                const chips = [];
                if (inSf) chips.push({ key: 'sf', txt: format(inSf === 1 ? i18n.grpChipInSfFmt : i18n.grpChipInSfManyFmt, inSf), cls: 'grp-chip2' });
                if (diffSf) chips.push({ key: 'df', txt: format(i18n.grpChipDiffFmt, diffSf), cls: 'grp-chip2 grp-chip2_warn' });
                if (also) chips.push({ key: 'al', txt: format(also === 1 ? i18n.grpChipAlsoFmt : i18n.grpChipAlsoManyFmt, also, [...alsoNos].join(', ')), cls: 'grp-chip2 grp-chip2_warn' });
                const openKey = g.key + '|' + t.id;
                const open = !!this.hopen[openKey];
                const last = rowOut.length - 1;
                return {
                    key: openKey,
                    ticketId: t.id,
                    no: t.no,
                    one: rows.length === 1,
                    many: rows.length > 1,
                    r0: rowOut[0] || {},
                    rows: rowOut,
                    n: rows.length,
                    pastedText: format(i18n.grpPastedFmt, rows.length),
                    range: last >= 0 ? rowOut[last].date + ' → ' + rowOut[0].date : '',
                    chips,
                    sel: kOn + '/' + rows.length,
                    keys,
                    open,
                    openTxt: String(open),
                    chev: open ? '▾' : '▸',
                    headClass: 'grp-tkh' + (rows.length === 1 && rowOut[0] && !rowOut[0].checked ? ' grp-off' : '')
                };
            });
            nOn += tOn;
            nAll += tAll;
            return {
                key: g.key,
                title: g.title,
                titleFr: g.titleFr,
                titleEn: g.titleEn,
                tickets,
                keys: tabKeys,
                sel: format(i18n.grpSelectedFmt, tOn + '/' + tAll)
            };
        });
        return { tabs: tabOut, meta, n: nOn, total: nAll };
    }

    get histTabs() { return this._histModel.tabs; }
    get hasHist() { return this.histTabs.length > 0; }
    get histSelText() {
        const m = this._histModel;
        return format(this.i18n.grpSelectedFmt, m.n + '/' + m.total);
    }

    handleRowToggle(event) {
        const key = event.currentTarget.dataset.key;
        const checked = event.target.checked;
        const m = this._histModel.meta[key];
        const o = { ...this.ho, [key]: checked };
        // Checking one value for a date unchecks the same date in the other tickets.
        if (checked && m) m.others.forEach((k) => { o[k] = false; });
        this.ho = o;
    }

    handleTicketOpen(event) {
        const key = event.currentTarget.dataset.key;
        this.hopen = { ...this.hopen, [key]: !this.hopen[key] };
    }

    // All / None at ticket, table or whole-section level. "All" never checks two values of
    // the same date: inside the chosen scope the newest ticket wins, outside it is unchecked.
    handleRowsAll(event) {
        const { scope, key, val } = event.currentTarget.dataset;
        const on = val === 'all';
        const model = this._histModel;
        let keys = [];
        model.tabs.forEach((tb) => {
            if (scope === 'all') keys = keys.concat(tb.keys);
            else if (scope === 'tab' && tb.key === key) keys = keys.concat(tb.keys);
            else if (scope === 'tk') tb.tickets.forEach((k) => { if (k.key === key) keys = keys.concat(k.keys); });
        });
        const o = { ...this.ho };
        if (!on) {
            keys.forEach((k) => { o[k] = false; });
        } else {
            const taken = {};
            // tickets are newest first, so the first key seen for a date wins
            keys.forEach((k) => {
                const m = model.meta[k];
                const dk = m.tab + '|' + m.date;
                if (taken[dk]) {
                    o[k] = false;
                    return;
                }
                taken[dk] = true;
                o[k] = true;
                m.others.forEach((x) => { o[x] = false; });
            });
        }
        this.ho = o;
    }

    // ── Plan / summary ───────────────────────────────────────────────────────

    _plans() {
        const fm = this._fieldModel;
        const hm = this._histModel;
        const plans = {};
        this.tickets.forEach((t) => {
            plans[t.id] = { fields: [], overrides: {}, tables: {}, notApplied: [], count: 0 };
        });
        const na = (t, labelFr, labelEn, value, reason, ticket) => {
            plans[t.id].notApplied.push({ labelFr, labelEn, value, reason, ticket: ticket || '' });
        };
        fm.rows.forEach((r) => {
            if (r.same) {
                r.members.forEach((t) => na(t, r.labelFr, r.labelEn, r.value, 'SAME_AS_SF'));
            } else if (r.checked) {
                const p = plans[r.ownerId];
                p.fields.push(r.api);
                if (norm(r.key) !== norm(r.api)) p.overrides[r.api] = r.key;
                p.count++;
                r.members.filter((t) => t.id !== r.ownerId)
                    .forEach((t) => na(t, r.labelFr, r.labelEn, r.value, 'MERGED', r.ownerNo));
            } else if (r.replacedNo) {
                r.members.forEach((t) => na(t, r.labelFr, r.labelEn, r.value, 'OTHER_TICKET', r.replacedNo));
            } else {
                r.members.forEach((t) => na(t, r.labelFr, r.labelEn, r.value, 'UNCHECKED'));
            }
        });
        hm.tabs.forEach((tb) => tb.tickets.forEach((k) => {
            const t = this.tickets.find((x) => x.id === k.ticketId);
            k.rows.forEach((r) => {
                const value = r.dateIso + ' → ' + r.value;
                if (r.checked) {
                    (plans[t.id].tables[tb.key] = plans[t.id].tables[tb.key] || []).push(r.index);
                    plans[t.id].count++;
                } else if (r.locked) {
                    na(t, tb.titleFr, tb.titleEn, value, 'SAME_AS_SF');
                } else if (r.otherChecked) {
                    na(t, tb.titleFr, tb.titleEn, value, 'OTHER_TICKET', r.otherChecked.t.no);
                } else {
                    na(t, tb.titleFr, tb.titleEn, value, 'UNCHECKED');
                }
            });
        }));
        return plans;
    }

    get _emptyTickets() {
        const plans = this._plans();
        return this.tickets.filter((t) => plans[t.id].count === 0);
    }

    get hasEmpty() { return this._emptyTickets.length > 0; }
    get emptyText() {
        const list = this._emptyTickets.map((t) => '#' + t.no).join(', ');
        return format(this._emptyTickets.length === 1 ? this.i18n.grpEmptyOneFmt : this.i18n.grpEmptyManyFmt, list);
    }

    get sumFields() {
        const n = this._fieldModel.rows.filter((r) => r.checked && !r.same).length;
        return format(n === 1 ? this.i18n.grpFieldOneFmt : this.i18n.grpFieldManyFmt, n);
    }
    get sumRows() {
        const n = this._histModel.n;
        return format(n === 1 ? this.i18n.grpRowOneFmt : this.i18n.grpRowManyFmt, n);
    }
    get sumTickets() {
        const n = this.tickets.length;
        return format(n === 1 ? this.i18n.grpTicketOneFmt : this.i18n.grpTicketManyFmt, n);
    }

    get hasClash() {
        if (this._fieldModel.hasClash) return true;
        return this.histTabs.some((tb) => tb.tickets.some((k) => k.rows.some((r) => r.clash)));
    }

    get isApplyDisabled() { return this.isWorking || this.hasClash || !!this.editingId || this.isSavingEdit; }
    get isIgnoreDisabled() { return this.isWorking || !!this.editingId; }
    get applyLabel() { return this.isWorking && this.progressText ? this.progressText : this.i18n.grpApply; }

    // ── Apply / Ignore ───────────────────────────────────────────────────────

    // Tickets a ticket's "not applied" notes point to ("applied with #N", "the value from #N was
    // used"): those must be applied first, so a ticket is never closed saying its value went in
    // with a ticket that then failed and stayed open.
    _applyOrder(plans) {
        const byNo = {};
        this.tickets.forEach((t) => { byNo[t.no] = t.id; });
        const deps = {};
        this.tickets.forEach((t) => {
            deps[t.id] = new Set(plans[t.id].notApplied
                .filter((x) => x.ticket && byNo[x.ticket] && byNo[x.ticket] !== t.id)
                .map((x) => byNo[x.ticket]));
        });
        // oldest first otherwise, so the history of the record reads in the order the tickets came in
        const left = this.tickets.slice().reverse();
        const order = [];
        const placed = new Set();
        while (left.length) {
            let i = left.findIndex((t) => [...deps[t.id]].every((d) => placed.has(d)));
            if (i < 0) i = 0; // tickets pointing at each other: oldest first
            const t = left.splice(i, 1)[0];
            order.push(t);
            placed.add(t.id);
        }
        return { order, deps };
    }

    async handleApply() {
        if (this.isApplyDisabled) return;
        const plans = this._plans();
        const { order, deps } = this._applyOrder(plans);
        // Several tickets and the account change at once: ask before, like the one-ticket panel.
        const ok = await DucConfirmModal.open({
            size: 'small',
            label: this.i18n.rdApplyConfirmTitle,
            message: format(this.i18n.grpApplyConfirmFmt, order.length, order.map((t) => '#' + t.no).join(', '), this.recordName),
            okLabel: this.i18n.grpApply,
            cancelLabel: this.i18n.btnCancel
        });
        if (!ok) return;
        const others = order.length - 1;
        this.isWorking = true;
        const done = [];
        const skipped = [];
        let failed = null;
        try {
            for (let i = 0; i < order.length; i++) {
                const t = order[i];
                this.progressText = format(this.i18n.grpApplyingFmt, i + 1, order.length);
                const p = plans[t.id];
                let result = null;
                try {
                    result = await applyGroupTicketApex({
                        requestId: t.id,
                        planJson: JSON.stringify({
                            fields: p.fields, overrides: p.overrides, tables: p.tables,
                            notApplied: p.notApplied, groupOthers: others, recordName: this.recordName
                        })
                    });
                } catch (e) {
                    result = null;
                }
                if (result && result.success) {
                    done.push({ ...t, status: 'Applied' });
                    continue;
                }
                // Closed meanwhile by someone else: skip it, unless a ticket still to apply relies on it.
                const reliedOn = order.slice(i + 1).some((x) => deps[x.id].has(t.id));
                if (result && result.errorMessage === 'TICKET_ALREADY_CLOSED' && !reliedOn) {
                    skipped.push(t);
                    continue;
                }
                failed = { t, open: order.slice(i) };
                break;
            }
        } finally {
            if (skipped.length) {
                this._toast(format(this.i18n.grpSkippedClosedFmt, skipped.map((t) => '#' + t.no).join(', ')), '', 'warning');
            }
            if (failed) {
                this._toast(this.i18n.toastApplyErrorTitle,
                    format(this.i18n.grpApplyFailFmt, failed.t.no, failed.open.map((t) => '#' + t.no).join(', ')), 'error');
            }
            await this._finish(done, 'Applied');
        }
    }

    get ignoreReasons() {
        const opts = [
            { label: this.i18n.closedReasonNoChanges, value: 'No Changes Needed' },
            { label: this.i18n.closedReasonDuplicate, value: 'Duplicate Request' },
            { label: this.i18n.closedReasonInvalid, value: 'Invalid Data Provided' },
            { label: this.i18n.closedReasonOther, value: 'Other' }
        ];
        return opts.map((r) => ({
            ...r,
            pressed: String(this.ignoreReason === r.value),
            cls: 'grp-reason' + (this.ignoreReason === r.value ? ' grp-reason_on' : '')
        }));
    }

    get ignoreTitle() { return format(this.i18n.grpIgnoreQFmt, this.tickets.length); }
    get isIgnoreConfirmDisabled() { return this.isWorking || !this.ignoreReason; }
    get ignoreConfirmLabel() { return this.isWorking && this.progressText ? this.progressText : this.i18n.grpIgnoreAll; }

    handleIgnoreOpen() {
        if (this.isIgnoreDisabled) return;
        this.isIgnoreOpen = true;
        this.ignoreReason = '';
        this.ignoreNote = '';
    }

    handleIgnoreCancel() {
        if (!this.isWorking) this.isIgnoreOpen = false;
    }

    handleIgnoreReason(event) {
        this.ignoreReason = event.currentTarget.dataset.value;
    }

    handleIgnoreNote(event) {
        this.ignoreNote = event.target.value;
    }

    async handleIgnoreConfirm() {
        if (this.isIgnoreConfirmDisabled) return;
        const order = this.tickets.slice().reverse();
        this.isWorking = true;
        const done = [];
        try {
            for (let i = 0; i < order.length; i++) {
                const t = order[i];
                this.progressText = format(this.i18n.grpIgnoringFmt, i + 1, order.length);
                try {
                    await ignoreRequestApex({ requestId: t.id, closedReason: this.ignoreReason, notes: this.ignoreNote });
                } catch (e) {
                    this._toast(this.i18n.toastActionErrorTitle,
                        format(this.i18n.grpApplyFailFmt, t.no, order.slice(i).map((x) => '#' + x.no).join(', ')), 'error');
                    break;
                }
                done.push({ ...t, status: 'Ignored' });
            }
        } finally {
            this.isIgnoreOpen = false;
            await this._finish(done, 'Ignored');
        }
    }

    async _finish(done) {
        this.isWorking = false;
        this.progressText = '';
        if (done.length) {
            this._toast(format(this.i18n.grpClosedToastFmt, done.length), '', 'success');
            this.closedTickets = done.map((t) => ({
                id: t.id,
                no: t.no,
                formLabel: t.formLabel || '',
                status: t.status,
                statusText: statusLabel(this.i18n, t.status),
                statusStyle: statusStyle(t.status)
            }));
        }
        await this._load();
        if (done.length) {
            this.dispatchEvent(new CustomEvent('groupapplied', {
                detail: { targetRecordId: this.targetRecordId, requestIds: done.map((t) => t.id), remaining: this.tickets.length }
            }));
        }
    }

    handleOpenTicket(event) {
        const { id, label, status } = event.currentTarget.dataset;
        this.dispatchEvent(new CustomEvent('requestselect', {
            detail: { requestId: id, label: label || this.recordName, status, rollbackAsk: false, number: event.currentTarget.dataset.no }
        }));
    }

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
