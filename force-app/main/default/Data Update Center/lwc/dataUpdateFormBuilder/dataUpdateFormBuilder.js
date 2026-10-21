import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import DucConfirmModal from 'c/ducConfirmModal';
import { getLabels, format, getIdentity2Labels } from 'c/dataUpdateI18n';
import { TEXT_COLORS, HIGHLIGHTS, parseStyles, serializeStyles, buildRuns, blockStyle, styleAt } from 'c/dataUpdateTextStyle';
import {
    PAGE_TYPES, CONTENT_TYPES, TEXT_TYPES, IMAGE_TYPES, LOGIN_ANCHORS, MESSAGE_SCREENS, TEXT_MAX_LENGTH,
    parseBlocks, serializeBlocks, cleanBlock, placeBlocks, sectionAnchor, questionAnchor, videoEmbedUrl, newBlockId,
    BLOCK_RECOMMENDED
} from 'c/dataUpdateBlocks';
import {
    FONTS, DEFAULTS as APPEARANCE_DEFAULTS, COLOR_KEYS, parseAppearance, serializeAppearance, appearanceStyle,
    fontStack, cleanHex, contrastOnWhite, MIN_CONTRAST
} from 'c/dataUpdateAppearance';

import getForms from '@salesforce/apex/DataUpdateFormAdminController.getForms';
import getFormFields from '@salesforce/apex/DataUpdateFormAdminController.getFormFields';
import getAvailableFields from '@salesforce/apex/DataUpdateFormAdminController.getAvailableFields';
import getRelatedObjects from '@salesforce/apex/DataUpdateFormAdminController.getRelatedObjects';
import getObjectFields from '@salesforce/apex/DataUpdateFormAdminController.getObjectFields';
import getBuilderForm from '@salesforce/apex/DataUpdateFormAdminController.getBuilderForm';
import enqueuePublishBuilder from '@salesforce/apex/DataUpdateFormAdminController.enqueuePublishBuilder';
import checkDeployStatus from '@salesforce/apex/DataUpdateFormAdminController.checkDeployStatus';
import publishBlockImage from '@salesforce/apex/DataUpdateFormAdminController.publishBlockImage';
import getHistoryTableSchemas from '@salesforce/apex/DataUpdateFormAdminController.getHistoryTableSchemas';
import getNetworkOptions from '@salesforce/apex/DataUpdateFormAdminController.getNetworkOptions';
import getCoreFormConfigForNetwork from '@salesforce/apex/DataUpdateFormAdminController.getCoreFormConfigForNetwork';
import enqueueCreateForm from '@salesforce/apex/DataUpdateFormAdminController.enqueueCreateForm';
import getTargetObjectOptions from '@salesforce/apex/DataUpdateFormAdminController.getTargetObjectOptions';
import deleteFormApex from '@salesforce/apex/DataUpdateFormAdminController.deleteForm';
import getCanDeleteForms from '@salesforce/apex/DataUpdateFormAdminController.getCanDeleteForms';
import setCoreFormApex from '@salesforce/apex/DataUpdateFormAdminController.setCoreForm';
import getAppearanceTemplates from '@salesforce/apex/DataUpdateFormAdminController.getAppearanceTemplates';
import enqueueSaveAppearanceTemplate from '@salesforce/apex/DataUpdateFormAdminController.enqueueSaveAppearanceTemplate';
import enqueueDeleteAppearanceTemplate from '@salesforce/apex/DataUpdateFormAdminController.enqueueDeleteAppearanceTemplate';
import getPublishLock from '@salesforce/apex/DataUpdateFormAdminController.getPublishLock';
import acquirePublishLock from '@salesforce/apex/DataUpdateFormAdminController.acquirePublishLock';
import releasePublishLock from '@salesforce/apex/DataUpdateFormAdminController.releasePublishLock';

// Visual form builder: palette | live preview of the public portal | properties.
// The whole form is edited as a client-side draft and published in ONE metadata deploy
// (DataUpdateFormAdminController.enqueuePublishBuilder), so the public form never shows a
// half-applied state. Mappings of existing related-object questions stay in Settings.

const POLL_INTERVAL_MS = 2000;
// 3 min: metadata deploys can be slow on a busy org; past this the deploy keeps running.
const POLL_MAX_ATTEMPTS = 90;
// Publish lock (one publish at a time in the org): how often an open builder re-checks it.
const LOCK_POLL_IDLE_MS = 30000;
const LOCK_POLL_BUSY_MS = 10000;
// Same wait as the server's LOCK_COOLDOWN_SECS; only sizes the draining bar.
const LOCK_COOLDOWN_SECS = 20;
// The VF delete page answers in a few seconds; past this, check the form list by hand.
const HISTORY_ONLY = 'History_Only';
// Églises only: one paste-from-Excel table per related history object (DataUpdateHistoryTable).
const HISTORY_TABLE = 'History_Table';
const COLUMN_TYPE_LABELS = {
    DATE: 'Date', DATETIME: 'Date', DOUBLE: 'Number', INTEGER: 'Number', LONG: 'Number', CURRENCY: 'Number',
    PERCENT: 'Number', BOOLEAN: 'Checkbox', PICKLIST: 'Picklist', STRING: 'Text', TEXTAREA: 'Text',
    EMAIL: 'Text', PHONE: 'Text', URL: 'Text'
};
const LOG_OBJECT = 'Data_Update_Log__c';
const INPUT_TYPES = ['Text', 'Email', 'Phone', 'Number', 'Date', 'Checkbox', 'Picklist'];
const EXCLUDED_VALUE_TYPES = ['REFERENCE', 'MULTIPICKLIST', 'ADDRESS', 'ID'];
const DATE_TYPES = ['DATE', 'DATETIME'];
// Field types that make sense for each "Avancé" picker (identity = typed by the person; filter = exact match).
const IDENTITY_TYPES = ['STRING', 'EMAIL', 'PHONE', 'ID', 'INTEGER', 'DOUBLE'];
const NAME_TYPES = ['STRING', 'EMAIL', 'PHONE'];
const FILTER_TYPES = ['STRING', 'PICKLIST', 'BOOLEAN', 'ID', 'REFERENCE', 'INTEGER', 'DOUBLE'];
const NEW_SECTION_TITLES = { fr: 'Nouvelle section', en: 'New section' };

// Customisable portal texts: [draft key, i18n default key, properties-pane name key, screen]
const TEXT_DEFS = [
    { key: 'lookupTitle', nameKey: 'builderTextLookupTitle', screen: 'access' },
    { key: 'lookupSubtitle', nameKey: 'builderTextLookupSubtitle', screen: 'access' },
    { key: 'idHelp', nameKey: 'builderTextIdHelp', screen: 'access' },
    { key: 'formTitle', nameKey: 'builderTextFormTitle', screen: 'questions' },
    { key: 'formSubtitle', nameKey: 'builderTextFormSubtitle', screen: 'questions' },
    // Portal messages travel together in Portal_Messages__c (messagesJson).
    { key: 'lockedTitle', nameKey: 'builderMsgLockedTitle', screen: 'messages', msg: true },
    { key: 'lockedMessage', nameKey: 'builderMsgLockedMessage', screen: 'messages', msg: true, long: true },
    { key: 'pendingTitle', nameKey: 'builderMsgPendingTitle', screen: 'messages', msg: true },
    { key: 'pendingMessage', nameKey: 'builderMsgPendingMessage', screen: 'messages', msg: true, long: true },
    { key: 'confirmTitle', nameKey: 'builderMsgConfirmTitle', screen: 'messages', msg: true },
    { key: 'confirmMessage', nameKey: 'builderMsgConfirmMessage', screen: 'messages', msg: true, long: true },
    { key: 'errNoChanges', nameKey: 'builderMsgErrNoChanges', screen: 'messages', msg: true, long: true, noStyle: true }
];
const TEXT_KEYS = TEXT_DEFS.map((d) => d.key);
const MESSAGE_MAX_LENGTH = 1000;
// Message screens with blocks (lanes): their fixed title and message, in display order.
const MESSAGE_LANES = Object.keys(MESSAGE_SCREENS);

function parseMessages(json) {
    try {
        const m = json ? JSON.parse(json) : {};
        return m && typeof m === 'object' && !Array.isArray(m) ? m : {};
    } catch (e) {
        return {};
    }
}
const COLOR_LABEL_KEYS = {
    default: 'builderColorDefault', black: 'builderColorBlack', gray: 'builderColorGray', blue: 'builderColorBlue',
    green: 'builderColorGreen', orange: 'builderColorOrange', red: 'builderColorRed', burgundy: 'builderColorBurgundy',
    purple: 'builderColorPurple'
};
const HIGHLIGHT_LABEL_KEYS = {
    none: 'builderHlNone', yellow: 'builderHlYellow', green: 'builderHlGreen', blue: 'builderHlBlue', pink: 'builderHlPink'
};
const HISTORY_VALUE_FIELD = 'value__c';

// Design blocks (Tools tab). The Login screen and the form header are "lanes": their fixed
// items in order, with blocks in between. Blocks of the questions screen live in the sections.
const BLOCK_LABEL_KEYS = {
    banner: 'builderBlockBanner', logo: 'builderBlockLogo', spacer: 'builderBlockSpacer', title: 'builderBlockTitle',
    text: 'builderBlockText', image: 'builderBlockImage', video: 'builderBlockVideo', divider: 'builderBlockDivider'
};
const BLOCK_HINT_KEYS = {
    banner: 'builderBannerHint', logo: 'builderLogoHint', spacer: 'builderSpacerHint', image: 'builderImageHint',
    video: 'builderVideoHint', divider: 'builderDividerHint'
};
const BLOCK_ICONS = {
    banner: 'utility:image', logo: 'utility:company', spacer: 'utility:height', title: 'utility:title',
    text: 'utility:text', image: 'utility:image', video: 'utility:video', divider: 'utility:dash'
};
const LOGIN_FIXED = ['lookupTitle', 'lookupSubtitle', 'idField', 'button'];
const HEAD_FIXED = ['formTitle', 'formSubtitle'];
// With nothing selected, these go to the top of the screen instead of the end.
const TOP_TYPES = ['banner', 'logo'];
const IMAGE_ACCEPT = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg'];
// Same limit as DataUpdateFormAdminController.BLOCKS_MAX_LENGTH (Portal_Blocks__c).
const BLOCKS_MAX_LENGTH = 32000;

let uid = 0;
const newId = (prefix) => `${prefix}${++uid}`;
const clean = (v) => (v || '').trim();

// Word ranges (marks) follow an edit of their text: positions after the edited part shift,
// positions inside it collapse onto its edges.
function shiftMarks(marks, before, after) {
    if (!marks || !marks.length || before === after) return marks;
    let p = 0;
    while (p < before.length && p < after.length && before[p] === after[p]) p++;
    let sfx = 0;
    while (sfx < before.length - p && sfx < after.length - p
        && before[before.length - 1 - sfx] === after[after.length - 1 - sfx]) sfx++;
    const oldEnd = before.length - sfx;
    const newEnd = after.length - sfx;
    const delta = after.length - before.length;
    const map = (x, isEnd) => {
        if (x <= p) return x;
        if (x >= oldEnd) return x + delta;
        return isEnd ? newEnd : p;
    };
    return marks
        .map((m) => ({ ...m, start: map(m.start, false), end: map(m.end, true) }))
        .filter((m) => m.end > m.start);
}

function inputTypeForSchemaType(type) {
    switch (type) {
        case 'DOUBLE':
        case 'INTEGER':
        case 'LONG':
        case 'CURRENCY':
        case 'PERCENT':
            return 'Number';
        case 'DATE':
        case 'DATETIME':
            return 'Date';
        case 'BOOLEAN':
            return 'Checkbox';
        case 'EMAIL':
            return 'Email';
        case 'PHONE':
            return 'Phone';
        case 'PICKLIST':
            return 'Picklist';
        default:
            return 'Text';
    }
}

export default class DataUpdateFormBuilder extends LightningElement {
    @api lang = 'fr';
    @api initialFormDeveloperName = '';

    @track forms = [];
    @track draft = { texts: {}, styles: {}, sections: [] };
    @track catalog = [];
    @track availableFields = [];
    @track relatedObjects = [];
    @track objectFieldsByObject = {};

    formDeveloperName = '';
    info = null;
    publishedSnapshot = null;
    isLoading = true;
    isPublishing = false;
    loadError = '';
    screen = 'questions';
    msgLane = 'locked';
    previewLang = 'fr';
    search = '';
    paletteTab = 'fields';
    leftTab = 'questions';
    selQ = null;
    selB = null;
    isUploading = false;
    // Real size of the selected block's uploaded picture: { url, w, h }.
    imageDims = null;
    selS = null;
    // Selected history table (draft.tables[].id). Shown only while nothing else is selected.
    selT = null;
    tableSchemas = [];
    selText = null;
    textRange = null;
    // Appearance panel (uniform font + colors of the whole form) in the properties pane.
    appearanceOpen = false;
    appearanceTemplates = [];
    templatePick = '';
    templateName = '';
    isSavingTemplate = false;
    incompleteIds = new Set();
    // Another publish in progress (or just finished): { active, mine, phase, what, userName, … }.
    publishLock = null;
    urlCopied = false;
    _lockReceivedAt = 0;
    lockTick = 0;
    _drag = null;
    dropTarget = null;

    connectedCallback() {
        this.previewLang = this.lang === 'en' ? 'en' : 'fr';
        this._init();
        this._refreshLock();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._lockTimer = setInterval(() => this._lockSecond(), 1000);
    }

    disconnectedCallback() {
        if (this._lockTimer) clearInterval(this._lockTimer);
        clearTimeout(this._copiedTimer);
    }

    // ── Publish lock ─────────────────────────────────────────────────────────
    // Every builder write is a metadata deploy; the server lets only one run at a time in the
    // org (DataUpdateFormAdminController "Publish lock"). Others see who is publishing, the
    // Publish button waits, and it frees itself once Salesforce confirms the deploy is done.

    async _refreshLock() {
        try {
            this._setLock(await getPublishLock());
        } catch (e) {
            // Not fatal: the server still refuses a second publish.
        }
    }

    _setLock(lock) {
        this.publishLock = lock && lock.active ? lock : null;
        this._lockReceivedAt = Date.now();
        this._lockCheckedAt = Date.now();
    }

    _lockSecond() {
        const lock = this.publishLock;
        const since = Date.now() - (this._lockCheckedAt || 0);
        if (lock) {
            this.lockTick++;
            const ended = lock.phase === 'cooldown' && this._lockSecs(lock.remainingSecs, -1) <= 0;
            if (ended || since >= LOCK_POLL_BUSY_MS) this._refreshLock();
        } else if (since >= LOCK_POLL_IDLE_MS && !document.hidden) {
            this._refreshLock();
        }
    }

    // Seconds from the server, moved on locally (dir 1 = elapsed, -1 = remaining).
    _lockSecs(base, dir) {
        const moved = Math.floor((Date.now() - this._lockReceivedAt) / 1000);
        return Math.max((base || 0) + dir * moved, 0);
    }

    _clock(secs) {
        return Math.floor(secs / 60) + ':' + String(secs % 60).padStart(2, '0');
    }

    get lockBlocked() {
        return !!this.publishLock && !this.isPublishing;
    }

    get lockCooldown() {
        return !!this.publishLock && this.publishLock.phase === 'cooldown';
    }

    // Strip under the bar: my publish running, someone else's, or the short wait after one.
    get lockStrip() {
        const lock = this.publishLock;
        if (!lock) return null;
        // eslint-disable-next-line no-unused-expressions
        this.lockTick; // re-render every second
        const what = lock.what || '—';
        if (lock.phase === 'cooldown') {
            const left = this._lockSecs(lock.remainingSecs, -1);
            return {
                isCooldown: true,
                className: 'dub-lockstrip dub-lockstrip--cool',
                text: format(this.i18n.builderLockCooldown, this._clock(left)),
                drainStyle: 'width:' + Math.min(100, Math.round((left / LOCK_COOLDOWN_SECS) * 100)) + '%'
            };
        }
        const since = this._clock(this._lockSecs(lock.elapsedSecs, 1));
        if (lock.mine) {
            return { isMine: true, className: 'dub-lockstrip dub-lockstrip--mine', text: format(this.i18n.builderLockBusyMine, what, since) };
        }
        return {
            className: 'dub-lockstrip dub-lockstrip--busy',
            text: format(this.i18n.builderLockBusy, what, lock.userName || this.i18n.builderLockSomeone, since)
        };
    }

    // Takes the lock, then queues the deploy. Lock busy → the banner shows who has it.
    async _enqueueLocked(what, enqueue) {
        const lock = await acquirePublishLock({ what });
        this._setLock(lock);
        if (!lock.acquired) throw new Error(this.i18n.builderLockToast);
        try {
            return await enqueue();
        } catch (e) {
            try {
                await releasePublishLock();
            } catch (x) {
                // Expires on its own.
            }
            this._refreshLock();
            throw e;
        }
    }

    // The FR/EN switch drives the whole builder (panels, buttons, messages), not only the preview.
    get i18n() {
        return getLabels(this.previewLang);
    }

    get pv() {
        return getLabels(this.previewLang);
    }

    _autoHelp(inputType, lang) {
        const l = getLabels(lang);
        return inputType === 'Phone' ? l.phoneHelp : inputType === 'Email' ? l.emailHelp : '';
    }

    // ── Loading ──────────────────────────────────────────────────────────────

    async _init() {
        try {
            this.forms = (await getForms()) || [];
            this._loadTemplates();
            this._loadCanDeleteForms();
            const first = this.forms.find((f) => f.developerName === this.initialFormDeveloperName) || this.forms[0];
            if (first) await this._loadForm(first.developerName);
            else this.isLoading = false;
        } catch (e) {
            this.loadError = this._msg(e);
            this.isLoading = false;
        }
    }

    async _loadForm(developerName) {
        this.isLoading = true;
        this.loadError = '';
        this.formDeveloperName = developerName;
        this.selQ = null;
        this.selB = null;
        this.selS = null;
        this.selT = null;
        this.selText = null;
        this.appearanceOpen = false;
        this.textRange = null;
        this.incompleteIds = new Set();
        try {
            const [info, catalog, available] = await Promise.all([
                getBuilderForm({ formDeveloperName: developerName }),
                getFormFields({ formDeveloperName: developerName }),
                getAvailableFields({ formDeveloperName: developerName })
            ]);
            this.info = info;
            this.catalog = catalog || [];
            this.availableFields = available || [];
            this.relatedObjects = info.targetObjectApiName
                ? (await getRelatedObjects({ parentObjectApiName: info.targetObjectApiName })) || []
                : [];
            this.tableSchemas = info.isChurchForm && info.targetObjectApiName
                ? (await getHistoryTableSchemas({ parentObjectApiName: info.targetObjectApiName })) || []
                : [];
            this.draft = this._draftFromServer(info, this.catalog);
            this.publishedSnapshot = this._snapshot(this.draft);
        } catch (e) {
            this.loadError = this._msg(e);
        } finally {
            this.isLoading = false;
        }
    }

    _draftFromServer(info, catalog) {
        const t = info.portalTexts || {};
        const texts = {};
        const messages = parseMessages(t.messagesJson);
        TEXT_DEFS.forEach((d) => {
            const m = d.msg ? messages[d.key] || {} : null;
            texts[d.key] = m
                ? { fr: m.fr || '', en: m.en || '' }
                : { fr: t[d.key + 'Fr'] || '', en: t[d.key + 'En'] || '' };
        });
        // History tables sit among the questions, in their section and order; a table taken off
        // the form (hidden) waits in the palette.
        const tables = this._tablesFromServer(catalog);
        const tableByObject = new Map(tables.map((tb) => [tb.objectApiName.toLowerCase(), tb]));
        const placedTables = new Set();
        const sections = [];
        catalog
            .filter((c) => c.isActive && !(c.historyMode === HISTORY_TABLE && c.isHidden))
            .forEach((c) => {
                let item;
                if (c.historyMode === HISTORY_TABLE) {
                    item = c.fieldApiName ? tableByObject.get(c.fieldApiName.split('#')[0].toLowerCase()) : null;
                    if (!item || placedTables.has(item)) return;
                    placedTables.add(item);
                } else {
                    item = this._questionFromCatalog(c);
                }
                const fr = c.sectionLabelFr || '';
                const en = c.sectionLabelEn || '';
                let s = sections[sections.length - 1];
                if (!s || s.titles.fr !== fr || s.titles.en !== en) {
                    s = { id: newId('s'), titles: { fr, en }, questions: [] };
                    sections.push(s);
                }
                s.questions.push(item);
            });
        if (!sections.length) sections.push({ id: newId('s'), titles: { ...NEW_SECTION_TITLES }, questions: [] });
        // A table never published waits in the palette until it is added: opening a form never
        // starts with pending changes.
        const styles = parseStyles(t.stylesJson, TEXT_KEYS);
        const blocks = parseBlocks(t.blocksJson);
        const toItem = (b) => {
            if (TEXT_TYPES.includes(b.type)) {
                texts['b:' + b.id] = { fr: b.fr || '', en: b.en || '' };
                if (b.st) styles['b:' + b.id] = JSON.parse(JSON.stringify(b.st));
            }
            return this._newBlockItem(b.type, b);
        };
        // Each anchor's blocks are taken once (two sections may share the same titles).
        const taker = (placed) => (a) => {
            const list = placed.get(a) || [];
            placed.delete(a);
            return list.map(toItem);
        };

        const loginTake = taker(placeBlocks(blocks.filter((b) => b.screen === 'login'), LOGIN_ANCHORS, false));
        const login = loginTake('@start');
        LOGIN_FIXED.forEach((f) => login.push({ fixed: f, id: 'f:' + f }, ...loginTake('@' + f)));

        const anchors = ['@formStart', '@formTitle', '@formSubtitle'];
        sections.forEach((s) => {
            anchors.push(sectionAnchor(s.titles.fr, s.titles.en));
            s.questions.forEach((q) => {
                const key = this._itemKey(q);
                if (key) anchors.push(questionAnchor(key));
            });
        });
        const formTake = taker(placeBlocks(blocks.filter((b) => b.screen === 'form'), anchors, false));
        const head = formTake('@formStart');
        HEAD_FIXED.forEach((f) => head.push({ fixed: f, id: 'f:' + f }, ...formTake('@' + f)));
        sections.forEach((s) => {
            const items = formTake(sectionAnchor(s.titles.fr, s.titles.en));
            s.questions.forEach((q) => {
                const key = this._itemKey(q);
                items.push(q, ...(key ? formTake(questionAnchor(key)) : []));
            });
            s.questions = items;
        });
        const msgLanes = {};
        MESSAGE_LANES.forEach((screen) => {
            const anchors = MESSAGE_SCREENS[screen];
            const take = taker(placeBlocks(blocks.filter((b) => b.screen === screen), anchors, false));
            const lane = take('@start');
            anchors.slice(1).forEach((a) => lane.push({ fixed: a.slice(1), id: 'f:' + a.slice(1) }, ...take(a)));
            msgLanes[screen] = lane;
        });
        const appearance = parseAppearance(t.appearanceJson);
        const multi = info.allowMultipleSubmissions === true;
        return { texts, styles, sections, login, head, msgLanes, tables, appearance, multi };
    }

    // Every related history object of the église form gets its table: published ones come from
    // their catalog record, the others start as a new draft (all columns, shown to churches).
    _tablesFromServer(catalog) {
        const records = {};
        catalog
            .filter((c) => c.historyMode === HISTORY_TABLE && c.fieldApiName)
            .forEach((c) => {
                records[c.fieldApiName.split('#')[0].toLowerCase()] = c;
            });
        return this.tableSchemas.map((sc) => {
            const c = records[sc.objectApiName.toLowerCase()];
            const published = !!(c && c.isActive);
            let saved = [];
            if (published) {
                try {
                    saved = JSON.parse(c.historyTableColumns || '[]') || [];
                } catch (e) {
                    saved = [];
                }
            }
            const savedBy = {};
            saved.forEach((x, i) => {
                if (x && x.f) savedBy[x.f.toLowerCase()] = { ...x, pos: i };
            });
            const columns = (sc.columns || []).map((f) => {
                const sv = savedBy[f.apiName.toLowerCase()];
                const locked = f.isRequired === true;
                return {
                    f: f.apiName,
                    label: f.label || f.apiName,
                    type: f.type,
                    fr: sv ? sv.fr || '' : f.label || '',
                    en: sv ? sv.en || '' : f.label || '',
                    on: locked || !published || !!sv,
                    locked,
                    isDate: f.apiName === sc.dateFieldApiName,
                    pos: sv ? sv.pos : 1000,
                    editing: false
                };
            });
            // Checked columns first, in their saved order; the date column leads a new table.
            columns.sort((a, b) => (b.on - a.on) || (a.pos - b.pos) || (b.isDate - a.isDate));
            return {
                id: newId('t'),
                kind: 'table',
                developerName: c ? c.developerName : null,
                objectApiName: sc.objectApiName,
                objectLabel: sc.objectLabel || sc.objectApiName,
                published,
                titles: { fr: published ? c.labelFr || '' : sc.objectLabel || '', en: published ? c.labelEn || '' : sc.objectLabel || '' },
                help: { fr: published ? c.helpFr || '' : '', en: published ? c.helpEn || '' : '' },
                isHidden: published ? c.isHidden === true : false,
                // Tables published before the option keep the paste grid; new ones start as fields.
                inputMode: published ? c.historyTableInputMode || 'Excel' : 'Fields',
                columns
            };
        });
    }

    _newBlockItem(type, b = {}) {
        return {
            kind: 'block',
            id: newId('b'),
            bid: b.id || newBlockId(),
            type,
            url: b.url || '',
            altFr: b.altFr || '',
            altEn: b.altEn || '',
            size: b.size || 'M',
            align: b.align || 'center'
        };
    }

    _questionFromCatalog(c) {
        const related = c.historyMode === HISTORY_ONLY;
        return {
            id: newId('q'),
            developerName: c.developerName,
            key: c.fieldApiName,
            kind: related ? 'related' : 'field',
            labels: { fr: c.labelFr || '', en: c.labelEn || '' },
            help: { fr: c.helpFr || '', en: c.helpEn || '' },
            inputType: c.inputType || 'Text',
            isRequired: c.isRequired === true,
            sameRowAsPrevious: c.sameRowAsPrevious === true,
            isHidden: c.isHidden === true,
            isReadOnly: c.isReadOnly === true && c.isHidden !== true,
            historyMode: c.historyMode || 'Replace',
            target: {
                object: c.historyTargetObjectApiName || '',
                value: c.historyTargetValueFieldApiName || '',
                date: c.historyTargetDateFieldApiName || '',
                account: c.historyTargetAccountFieldApiName || '',
                log: c.historyTargetLogFieldApiName || '',
                dateSource: c.historyDateSourceFieldApiName || ''
            }
        };
    }

    // ── Draft <-> payload ────────────────────────────────────────────────────

    _flatQuestions(draft = this.draft) {
        const out = [];
        draft.sections.forEach((s) => s.questions.forEach((q) => {
            if (q.kind !== 'block' && q.kind !== 'table') out.push({ q, s });
        }));
        return out;
    }

    // Blocks in display order with their anchors: "after" is the previous item in the builder,
    // "afterVisible" the previous item the respondent actually sees (hidden questions and
    // all-hidden sections never reach the portal).
    _blockList(draft = this.draft) {
        const out = [];
        const emit = (it, screen, after, afterVisible, section) => {
            const key = 'b:' + it.bid;
            const tx = draft.texts[key] || {};
            out.push({
                id: it.bid, type: it.type, screen, after, afterVisible, section,
                fr: clean(tx.fr), en: clean(tx.en), st: draft.styles[key],
                url: clean(it.url), altFr: clean(it.altFr), altEn: clean(it.altEn), size: it.size, align: it.align
            });
        };
        let prev = '@start';
        draft.login.forEach((it) => {
            if (it.fixed) prev = '@' + it.fixed;
            else {
                emit(it, 'login', prev);
                prev = 'b:' + it.bid;
            }
        });
        MESSAGE_LANES.forEach((screen) => {
            prev = '@start';
            draft.msgLanes[screen].forEach((it) => {
                if (it.fixed) prev = '@' + it.fixed;
                else {
                    emit(it, screen, prev);
                    prev = 'b:' + it.bid;
                }
            });
        });
        prev = '@formStart';
        draft.head.forEach((it) => {
            if (it.fixed) prev = '@' + it.fixed;
            else {
                emit(it, 'form', prev);
                prev = 'b:' + it.bid;
            }
        });
        let visible = prev;
        draft.sections.forEach((s) => {
            const qs = s.questions.filter((x) => x.kind !== 'block');
            const anchor = sectionAnchor(clean(s.titles.fr), clean(s.titles.en));
            if (qs.length) prev = anchor;
            if (qs.some((q) => !q.isHidden)) visible = anchor;
            s.questions.forEach((it) => {
                if (it.kind === 'block') {
                    emit(it, 'form', prev, visible, qs.length ? anchor : undefined);
                    prev = 'b:' + it.bid;
                    visible = prev;
                    return;
                }
                const a = questionAnchor(this._itemKey(it));
                if (a) {
                    prev = a;
                    if (!it.isHidden) visible = a;
                }
            });
        });
        return out;
    }

    // Anchor key of a section item: a history table travels under Object#table, like the server.
    _itemKey(it) {
        return it.kind === 'table' ? it.objectApiName + '#table' : this._questionKey(it);
    }

    // Questions and tables in form order (0-based), with their section — publish positions.
    _placements(draft = this.draft) {
        const out = new Map();
        let n = 0;
        draft.sections.forEach((s) => s.questions.forEach((it) => {
            if (it.kind !== 'block') out.set(it.id, { n: n++, s });
        }));
        return out;
    }

    // A new related question gets its key on publish (Object.ValueField, same rule as the
    // server's buildHistoryOnlyKey): anchor a block below it on that key already.
    _questionKey(q) {
        if (q.key) return q.key;
        return q.kind === 'related' && q.target.object && q.target.value ? q.target.object + '.' + q.target.value : '';
    }

    _payload(draft = this.draft) {
        const portalTexts = {};
        const messages = {};
        TEXT_DEFS.forEach((d) => {
            const fr = clean(draft.texts[d.key].fr);
            const en = clean(draft.texts[d.key].en);
            if (!d.msg) {
                portalTexts[d.key + 'Fr'] = fr;
                portalTexts[d.key + 'En'] = en;
            } else if (fr || en) {
                messages[d.key] = { ...(fr ? { fr } : {}), ...(en ? { en } : {}) };
            }
        });
        portalTexts.messagesJson = Object.keys(messages).length ? JSON.stringify(messages) : null;
        portalTexts.stylesJson = serializeStyles(draft.styles, TEXT_KEYS);
        portalTexts.blocksJson = serializeBlocks(this._blockList(draft));
        portalTexts.appearanceJson = serializeAppearance(draft.appearance);
        const places = this._placements(draft);
        const questions = this._flatQuestions(draft).map(({ q, s }) => {
            const related = q.kind === 'related';
            const historize = !related && q.historyMode === 'Historize';
            const mapped = related || historize;
            return {
                developerName: q.developerName || null,
                fieldApiName: related ? null : q.key,
                labelFr: clean(q.labels.fr),
                labelEn: clean(q.labels.en),
                helpFr: clean(q.help.fr),
                helpEn: clean(q.help.en),
                sectionLabelFr: clean(s.titles.fr),
                sectionLabelEn: clean(s.titles.en),
                inputType: q.inputType,
                isRequired: q.isRequired,
                sameRowAsPrevious: q.sameRowAsPrevious,
                isHidden: q.isHidden === true,
                isReadOnly: q.isHidden !== true && q.isReadOnly === true,
                historyMode: q.historyMode,
                historyTargetObjectApiName: mapped ? q.target.object : null,
                historyTargetValueFieldApiName: mapped ? q.target.value : null,
                historyTargetDateFieldApiName: mapped ? q.target.date : null,
                historyTargetAccountFieldApiName: mapped ? q.target.account : null,
                historyTargetLogFieldApiName: mapped ? q.target.log : null,
                historyDateSourceFieldApiName: historize ? q.target.dateSource || null : null,
                position: places.get(q.id).n
            };
        });
        // A table off the form is kept hidden (its settings stay for when it comes back).
        // A table never published and not on the form is left out (nothing to save for it).
        const tables = (draft.tables || []).filter((t) => t.published || t.developerName || places.has(t.id)).map((t) => {
            const place = places.get(t.id);
            return {
                developerName: t.developerName || null,
                objectApiName: t.objectApiName,
                titleFr: clean(t.titles.fr),
                titleEn: clean(t.titles.en),
                helpFr: clean(t.help.fr),
                helpEn: clean(t.help.en),
                inputMode: t.inputMode || 'Excel',
                isHidden: !place,
                sectionLabelFr: place ? clean(place.s.titles.fr) : '',
                sectionLabelEn: place ? clean(place.s.titles.en) : '',
                position: place ? place.n : null,
                columns: t.columns.filter((col) => col.on).map((col) => ({ f: col.f, fr: clean(col.fr) || col.label, en: clean(col.en) || col.label }))
            };
        });
        return { portalTexts, questions, tables, allowMultipleSubmissions: this.info && this.info.isChurchForm ? draft.multi === true : null };
    }

    _identity(pq, fallback) {
        if (pq.developerName) return pq.developerName;
        if (pq.fieldApiName) return 'f:' + pq.fieldApiName.toLowerCase();
        return 'n:' + fallback;
    }

    _snapshot(draft) {
        const p = this._payload(draft);
        const tables = {};
        p.tables.forEach((pt) => {
            tables[pt.objectApiName] = JSON.stringify(pt);
        });
        const flat = this._flatQuestions(draft);
        const questions = {};
        p.questions.forEach((pq, i) => {
            questions[this._identity(pq, flat[i].q.id)] = JSON.stringify({ ...pq, pos: i });
        });
        const blocks = {};
        this._blockList(draft).forEach((b) => {
            blocks[b.id] = JSON.stringify(cleanBlock(b));
        });
        // Each message counts as one change, like the other screen texts.
        const texts = { ...p.portalTexts };
        TEXT_DEFS.filter((d) => d.msg).forEach((d) => {
            texts[d.key + 'Fr'] = clean(draft.texts[d.key].fr);
            texts[d.key + 'En'] = clean(draft.texts[d.key].en);
        });
        return { texts, questions, blocks, tables, multi: p.allowMultipleSubmissions };
    }

    get changeCount() {
        if (!this.publishedSnapshot) return 0;
        const cur = this._snapshot(this.draft);
        const pub = this.publishedSnapshot;
        let n = 0;
        Object.keys(cur.questions).forEach((k) => {
            if (cur.questions[k] !== pub.questions[k]) n++;
        });
        Object.keys(pub.questions).forEach((k) => {
            if (!(k in cur.questions)) n++;
        });
        TEXT_DEFS.forEach((d) => {
            if (cur.texts[d.key + 'Fr'] !== pub.texts[d.key + 'Fr'] || cur.texts[d.key + 'En'] !== pub.texts[d.key + 'En']) n++;
        });
        if (cur.texts.stylesJson !== pub.texts.stylesJson) n++;
        if (cur.texts.appearanceJson !== pub.texts.appearanceJson) n++;
        Object.keys(cur.blocks).forEach((k) => {
            if (cur.blocks[k] !== pub.blocks[k]) n++;
        });
        Object.keys(pub.blocks).forEach((k) => {
            if (!(k in cur.blocks)) n++;
        });
        Object.keys(cur.tables).forEach((k) => {
            if (cur.tables[k] !== pub.tables[k]) n++;
        });
        if (cur.multi !== pub.multi) n++;
        return n;
    }

    get publishedKeys() {
        return new Set(Object.keys((this.publishedSnapshot || { questions: {} }).questions));
    }

    // ── Top bar ──────────────────────────────────────────────────────────────

    @track multiTip = false;

    get showMultiSwitch() {
        return !!(this.info && this.info.isChurchForm && this.draft);
    }

    get multiClass() {
        return this.draft && this.draft.multi ? 'dub-sw dub-sw--on' : 'dub-sw';
    }

    get multiChecked() {
        return String(!!(this.draft && this.draft.multi));
    }

    get multiTipClass() {
        return this.multiTip ? 'dub-helpq dub-helpq--on' : 'dub-helpq';
    }

    handleMultiToggle() {
        if (this.isPublishing) return;
        this.draft = { ...this.draft, multi: !this.draft.multi };
    }

    handleMultiTip() {
        this.multiTip = !this.multiTip;
    }


    get formOptions() {
        return this.forms.map((f) => ({
            value: f.developerName,
            label: f.label,
            selected: f.developerName === this.formDeveloperName
        }));
    }

    get publicUrl() {
        const f = this.forms.find((x) => x.developerName === this.formDeveloperName);
        return f ? f.publicUrl || '' : '';
    }

    get currentFormLabel() {
        return this.currentForm ? this.currentForm.label : '';
    }

    get isMainForm() {
        return !!this.currentForm && this.currentForm.isCoreForm;
    }

    // The link without "https://"; a long sandbox host loses its first part (…sandbox.my.site.com/…).
    get publicUrlShort() {
        const m = /^https?:\/\/([^/]+)(.*)$/.exec(this.publicUrl);
        if (!m) return this.publicUrl;
        const host = m[1].split('.');
        return (host.length > 4 ? '…' + host.slice(1).join('.') : m[1]) + m[2];
    }

    get copyBtnClass() {
        return 'dub-ib' + (this.urlCopied ? ' dub-ib--on' : '');
    }

    // Red trash next to the link icons: only with delete permission, never on the site's main form.
    get showDeleteFormButton() {
        return this.canDeleteForms && !!this.currentForm && !this.currentForm.isCoreForm;
    }

    get unsavedText() {
        const n = this.changeCount;
        return n === 1 ? this.i18n.builderUnsaved1 : format(this.i18n.builderUnsavedN, n);
    }

    // The pill says the state (how many changes); the button only says the action.
    get publishLabel() {
        if (!this.isPublishing && this.changeCount && this.lockCooldown) {
            return format(this.i18n.builderPublishIn, this._clock(this._lockSecs(this.publishLock.remainingSecs, -1)));
        }
        return this.i18n.builderPublish;
    }

    get publishShowsLock() {
        return this.changeCount > 0 && this.lockBlocked && !this.lockCooldown;
    }

    get noChanges() {
        return this.changeCount === 0 || this.isPublishing || this.isLoading || this.lockBlocked;
    }

    get showBody() {
        return !this.isLoading && !this.loadError && !!this.info;
    }

    // ── New form ─────────────────────────────────────────────────────────────
    // Simple: a name + which main (core) form to copy — object, identity fields, filter, lock and
    // queue all come from it. Advanced: the same name, but the site, object and fields are picked
    // by hand, for a form that can't start from a main form.

    @track newForm = null;

    get showNewForm() {
        return !!this.newForm;
    }

    // One button per site's main (core) form: "Account Updates", "Église Update". The new form copies it.
    get newFormBases() {
        if (!this.newForm) return [];
        return this.newForm.sites
            .map((s) => ({ site: s.apiName, core: this.forms.find((f) => f.isCoreForm && f.networkName === s.apiName) }))
            .filter((o) => o.core)
            .map((o) => ({
                value: o.site,
                label: format(this.i18n.builderNewFormCoreLabel, o.core.label),
                pressed: String(o.site === this.newForm.site)
            }));
    }

    get newFormNoCore() {
        const n = this.newForm;
        return !!(n && !n.advanced && n.site && !n.loadingCore && !n.core);
    }

    get newFormCantCreate() {
        const n = this.newForm;
        if (!n || n.creating || !n.name.trim()) return true;
        if (n.advanced) {
            const a = n.adv;
            return !a.site || !a.object || !a.identity1 || n.loadingFields;
        }
        return n.loadingCore || !n.site || !n.core;
    }

    get newFormAdvancedLabel() {
        return this.newForm && this.newForm.advanced ? this.i18n.builderNewFormSimple : this.i18n.builderNewFormAdvanced;
    }

    _advOptions(list, selected, withNone) {
        const opts = list.map((o) => ({ value: o.value, label: o.label, selected: o.value === selected }));
        return withNone ? [{ value: '', label: this.i18n.fieldOptionNone, selected: !selected }, ...opts] : opts;
    }

    _advFields(filter) {
        return ((this.newForm && this.newForm.fields) || [])
            .filter(filter)
            .map((f) => ({ value: f.apiName, label: `${f.label} (${f.apiName})` }));
    }

    // Native <select>s: their options carry `selected`, so a re-render keeps each pick.
    get advSiteOptions() {
        const n = this.newForm;
        return this._advOptions((n.sites || []).map((s) => ({ value: s.apiName, label: s.label || s.apiName })), n.adv.site, true);
    }

    get advObjectOptions() {
        const n = this.newForm;
        return this._advOptions((n.objects || []).map((o) => ({ value: o.apiName, label: `${o.label} (${o.apiName})` })), n.adv.object, true);
    }

    get newFormClass() {
        return this.newForm && this.newForm.advanced ? 'dub-newform dub-newform--wide' : 'dub-newform';
    }

    get advHasObject() {
        return !!(this.newForm && this.newForm.adv.object && !this.newForm.loadingFields);
    }

    get advIdentity1Options() {
        return this._advOptions(this._advFields((f) => IDENTITY_TYPES.includes(f.type)), this.newForm.adv.identity1, true);
    }

    get advIdentity2Options() {
        return this._advOptions(this._advFields((f) => IDENTITY_TYPES.includes(f.type)), this.newForm.adv.identity2, true);
    }

    get advRecordNameOptions() {
        return this._advOptions(this._advFields((f) => NAME_TYPES.includes(f.type)), this.newForm.adv.recordName, false);
    }

    get advFilterOptions() {
        return this._advOptions(this._advFields((f) => FILTER_TYPES.includes(f.type)), this.newForm.adv.filterField, true);
    }

    get advLockOptions() {
        return this._advOptions(this._advFields((f) => f.type === 'BOOLEAN'), this.newForm.adv.lockField, true);
    }

    get advLockDateOptions() {
        return this._advOptions(this._advFields((f) => DATE_TYPES.includes(f.type)), this.newForm.adv.lockDateField, true);
    }

    _comparisonOptions(selected) {
        return [
            { value: 'Exact', label: this.i18n.comparisonExact },
            { value: 'Normalized_Text', label: this.i18n.comparisonNormalizedText }
        ].map((o) => ({ ...o, selected: o.value === selected }));
    }

    get advComparison1Options() {
        return this._comparisonOptions(this.newForm.adv.comparison1);
    }

    get advComparison2Options() {
        return this._comparisonOptions(this.newForm.adv.comparison2);
    }

    get advHasIdentity2() {
        return !!this.newForm.adv.identity2;
    }

    async handleNewForm() {
        if (this.changeCount > 0 && !(await this._confirmDiscard())) return;
        const current = this.forms.find((f) => f.developerName === this.formDeveloperName);
        this.newForm = {
            name: '', site: '', sites: [], core: null, loadingCore: true, creating: false, error: '',
            advanced: false, objects: null, fields: [], loadingFields: false, multi: false, multiTip: false,
            adv: {
                site: '', object: '', identity1: '', comparison1: 'Exact', identity2: '', comparison2: 'Normalized_Text',
                recordName: 'Name', filterField: '', filterValue: '', lockField: '', lockDateField: '', queue: ''
            }
        };
        try {
            const sites = (await getNetworkOptions()) || [];
            const names = sites.map((s) => s.apiName);
            const site = current && names.includes(current.networkName) ? current.networkName : names[0] || '';
            this.newForm = { ...this.newForm, sites, adv: { ...this.newForm.adv, site } };
            await this._pickNewFormSite(site);
        } catch (e) {
            this.newForm = { ...this.newForm, loadingCore: false, error: this._msg(e) };
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        Promise.resolve().then(() => {
            const input = this.template.querySelector('.dub-newform input');
            if (input) input.focus();
        });
    }

    async _pickNewFormSite(site) {
        this.newForm = { ...this.newForm, site, core: null, loadingCore: !!site, error: '' };
        if (!site) return;
        try {
            const core = await getCoreFormConfigForNetwork({ networkName: site });
            if (this.newForm && this.newForm.site === site) this.newForm = { ...this.newForm, core: core || null, loadingCore: false };
        } catch (e) {
            if (this.newForm) this.newForm = { ...this.newForm, loadingCore: false, error: this._msg(e) };
        }
    }

    handleNewFormSite(event) {
        this._pickNewFormSite(event.currentTarget.dataset.value);
    }

    handleNewFormName(event) {
        this.newForm = { ...this.newForm, name: event.target.value, error: '' };
    }

    async handleToggleNewFormAdvanced() {
        const advanced = !this.newForm.advanced;
        this.newForm = { ...this.newForm, advanced, error: '' };
        if (advanced && !this.newForm.objects) {
            try {
                const objects = (await getTargetObjectOptions()) || [];
                if (this.newForm) this.newForm = { ...this.newForm, objects };
            } catch (e) {
                if (this.newForm) this.newForm = { ...this.newForm, objects: [], error: this._msg(e) };
            }
        }
    }

    handleAdvInput(event) {
        const key = event.target.dataset.key;
        this.newForm = { ...this.newForm, adv: { ...this.newForm.adv, [key]: event.target.value }, error: '' };
    }

    // A new object means new fields: the field picks are cleared, then its fields load.
    async handleAdvObject(event) {
        const object = event.target.value;
        this.newForm = {
            ...this.newForm,
            fields: [],
            loadingFields: !!object,
            error: '',
            adv: {
                ...this.newForm.adv, object, identity1: '', identity2: '', recordName: 'Name',
                filterField: '', filterValue: '', lockField: '', lockDateField: ''
            }
        };
        if (!object) return;
        try {
            const fields = (await getObjectFields({ objectApiName: object })) || [];
            if (this.newForm && this.newForm.adv.object === object) this.newForm = { ...this.newForm, fields, loadingFields: false };
        } catch (e) {
            if (this.newForm) this.newForm = { ...this.newForm, loadingFields: false, error: this._msg(e) };
        }
    }

    handleNewFormKey(event) {
        if (event.key === 'Enter' && event.target.tagName === 'INPUT' && !this.newFormCantCreate) this.handleCreateNewForm();
        if (event.key === 'Escape') {
            event.stopPropagation();
            this.handleCancelNewForm();
        }
    }

    handleCancelNewForm() {
        if (this.newForm && this.newForm.creating) return;
        this.newForm = null;
    }

    // "Multiple submissions" only applies to église forms (Account + record type Eglise).
    get newFormShowMulti() {
        const n = this.newForm;
        if (!n) return false;
        const c = n.advanced
            ? { o: n.adv.object, f: n.adv.filterField, v: (n.adv.filterValue || '').trim() }
            : n.core ? { o: n.core.targetObjectApiName, f: n.core.targetBaseFilterField, v: n.core.targetBaseFilterValue } : {};
        return c.o === 'Account' && c.f === 'RecordType.DeveloperName' && c.v === 'Eglise';
    }

    get newFormMultiClass() {
        return this.newForm && this.newForm.multi ? 'dub-sw dub-sw--on' : 'dub-sw';
    }

    get newFormMultiChecked() {
        return String(!!(this.newForm && this.newForm.multi));
    }

    get newFormMultiTipClass() {
        return this.newForm && this.newForm.multiTip ? 'dub-helpq dub-helpq--on' : 'dub-helpq';
    }

    handleNewFormMulti() {
        if (this.newForm.creating) return;
        this.newForm = { ...this.newForm, multi: !this.newForm.multi };
    }

    handleNewFormMultiTip() {
        this.newForm = { ...this.newForm, multiTip: !this.newForm.multiTip };
    }

    _newFormParams(name) {
        const n = this.newForm;
        if (n.advanced) {
            const a = n.adv;
            return {
                targetObjectApiName: a.object,
                identityField1ApiName: a.identity1,
                identityField1Comparison: a.comparison1,
                identityField2ApiName: a.identity2,
                identityField2Comparison: a.comparison2,
                targetBaseFilterField: a.filterField,
                targetBaseFilterValue: a.filterField ? a.filterValue.trim() : '',
                ownerQueueDeveloperName: a.queue.trim(),
                recordNameFieldApiName: a.recordName || 'Name',
                lockFieldApiName: a.lockField,
                lockDateFieldApiName: a.lockDateField,
                networkName: a.site,
                allowMultipleSubmissions: this.newFormShowMulti && n.multi === true,
                subjectTemplate: '{RecordName}',
                label: name
            };
        }
        const c = n.core;
        return {
            targetObjectApiName: c.targetObjectApiName,
            identityField1ApiName: c.identityField1ApiName,
            identityField1Comparison: c.identityField1Comparison,
            identityField2ApiName: c.identityField2ApiName,
            identityField2Comparison: c.identityField2Comparison,
            targetBaseFilterField: c.targetBaseFilterField,
            targetBaseFilterValue: c.targetBaseFilterValue,
            ownerQueueDeveloperName: c.ownerQueueDeveloperName,
            recordNameFieldApiName: c.recordNameFieldApiName,
            lockFieldApiName: c.lockFieldApiName,
            lockDateFieldApiName: c.lockDateFieldApiName,
            networkName: n.site,
            allowMultipleSubmissions: this.newFormShowMulti && n.multi === true,
            subjectTemplate: '{RecordName}',
            label: name
        };
    }

    async handleCreateNewForm() {
        if (this.newFormCantCreate) return;
        const name = this.newForm.name.trim();
        const params = this._newFormParams(name);
        this.newForm = { ...this.newForm, creating: true, error: '' };
        try {
            const jobId = await this._enqueueLocked(name, () => enqueueCreateForm(params));
            const result = await this._pollDeploy(jobId);
            this._refreshLock();
            this.forms = (await getForms()) || [];
            this.newForm = null;
            this._toast(format(this.i18n.builderNewFormCreated, name), '', 'success');
            const devName = result && result.formDeveloperName;
            if (devName && this.forms.some((f) => f.developerName === devName)) await this._loadForm(devName);
        } catch (e) {
            if (this.newForm) this.newForm = { ...this.newForm, creating: false, error: this._msg(e) };
        }
    }

    // ── Delete form ──────────────────────────────────────────────────────────
    // The form and all its questions, never a main form. One server call: the form is flagged
    // deleted in the app's own config records (no Metadata API, no hidden page).

    canDeleteForms = false;
    @track deleteForm = null;

    get currentForm() {
        return this.forms.find((f) => f.developerName === this.formDeveloperName) || null;
    }

    get showDeleteForm() {
        return !!this.deleteForm;
    }

    async _loadCanDeleteForms() {
        try {
            this.canDeleteForms = (await getCanDeleteForms()) === true;
        } catch (e) {
            this.canDeleteForms = false;
        }
    }

    // Shield next to the trash: same delete permission, since it decides what can be deleted.
    get showMainToggle() {
        return this.canDeleteForms && !!this.currentForm;
    }

    get mainToggleClass() {
        return 'dub-ib' + (this.isMainForm ? ' dub-ib--on' : '');
    }

    get mainToggleTitle() {
        return this.isMainForm ? this.i18n.builderMainOn : this.i18n.builderMainOff;
    }

    async handleMainToggle() {
        const f = this.currentForm;
        if (!f || this.isPublishing || this.isSavingMain) return;
        const makeMain = !f.isCoreForm;
        const previous = makeMain
            ? this.forms.find((o) => o.isCoreForm && o.networkName === f.networkName && o.developerName !== f.developerName)
            : null;
        if (previous && !(await DucConfirmModal.open({
            message: format(this.i18n.builderMainReplaceConfirm, previous.label),
            headerless: true,
            label: this.i18n.builderMainOff,
            okLabel: this.i18n.builderMainOk,
            cancelLabel: this.i18n.btnCancel
        }))) return;
        this.isSavingMain = true;
        try {
            await setCoreFormApex({ formDeveloperName: f.developerName, isCore: makeMain });
            this.forms = (await getForms()) || [];
            this._toast(format(makeMain ? this.i18n.builderMainSetDone : this.i18n.builderMainUnsetDone, f.label), '', 'success');
        } catch (e) {
            this._toast(this._msg(e), '', 'error');
        } finally {
            this.isSavingMain = false;
        }
    }

    isSavingMain = false;

    handleDeleteForm() {
        const f = this.currentForm;
        if (!f || f.isCoreForm || this.isPublishing) return;
        this.deleteForm = { developerName: f.developerName, label: f.label, url: f.publicUrl || '', networkName: f.networkName, deleting: false, error: '' };
    }

    handleCancelDeleteForm() {
        if (this.deleteForm && this.deleteForm.deleting) return;
        this.deleteForm = null;
    }

    handleDeleteFormKey(event) {
        if (event.key === 'Escape') {
            event.stopPropagation();
            this.handleCancelDeleteForm();
        }
    }

    async handleConfirmDeleteForm() {
        const d = this.deleteForm;
        if (!d || d.deleting) return;
        this.deleteForm = { ...d, deleting: true, error: '' };
        try {
            await deleteFormApex({ formDeveloperName: d.developerName });
        } catch (e) {
            this._finishDelete(false, this._msg(e));
            return;
        }
        this._finishDelete(true);
    }

    async _finishDelete(success, message) {
        const d = this.deleteForm;
        if (!success) {
            if (d) this.deleteForm = { ...d, deleting: false, error: message || this.i18n.toastFormDeleteErrorTitle };
            return;
        }
        this.deleteForm = null;
        this._toast(format(this.i18n.builderDeleted, d ? d.label : ''), '', 'success');
        try {
            this.forms = (await getForms()) || [];
            // Back to the main form of the same site, else the first form.
            const next = this.forms.find((f) => f.isCoreForm && d && f.networkName === d.networkName) || this.forms[0];
            if (next) await this._loadForm(next.developerName);
        } catch (e) {
            this.loadError = this._msg(e);
        }
    }

    async handleFormSelect(event) {
        const next = event.target.value;
        if (next === this.formDeveloperName) return;
        if (this.changeCount > 0 && !(await this._confirmDiscard())) {
            event.target.value = this.formDeveloperName;
            return;
        }
        await this._loadForm(next);
    }

    async handleCopyUrl() {
        try {
            await navigator.clipboard.writeText(this.publicUrl);
            this.urlCopied = true;
            clearTimeout(this._copiedTimer);
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this._copiedTimer = setTimeout(() => {
                this.urlCopied = false;
            }, 2000);
        } catch (e) {
            this._toast(this.publicUrl, '', 'info');
        }
    }

    async handleDiscard() {
        if (!(await this._confirmDiscard())) return;
        this.draft = this._draftFromServer(this.info, this.catalog);
        this.publishedSnapshot = this._snapshot(this.draft);
        this.selQ = null;
        this.selS = null;
        this.selT = null;
        this.selB = null;
        this.selText = null;
        this.appearanceOpen = false;
        this.incompleteIds = new Set();
        this._toast(this.i18n.builderDiscardedToast, '', 'info');
    }

    async handleClose() {
        if (this.changeCount > 0 && !this.isPublishing && !(await this._confirmDiscard())) return;
        this.dispatchEvent(new CustomEvent('close'));
    }

    async _confirmDiscard() {
        return DucConfirmModal.open({
            message: this.i18n.builderLeaveConfirm,
            headerless: true,
            label: this.i18n.builderDiscard,
            okLabel: this.i18n.builderDiscard,
            cancelLabel: this.i18n.btnCancel
        });
    }

    async handlePublish() {
        const problem = this._validateDraft();
        if (problem) {
            this._toast(this.i18n.builderErrorTitle, problem, 'error');
            return;
        }
        const count = this.changeCount;
        this.isPublishing = true;
        try {
            const what = (this.forms.find((f) => f.developerName === this.formDeveloperName) || {}).label || this.formDeveloperName;
            const jobId = await this._enqueueLocked(what, () => enqueuePublishBuilder({
                formDeveloperName: this.formDeveloperName,
                draftJson: JSON.stringify(this._payload())
            }));
            await this._pollDeploy(jobId);
            this._refreshLock();
            this._toast(format(this.i18n.builderPublishedToast, count), '', 'success');
            await this._loadForm(this.formDeveloperName);
        } catch (e) {
            this._toast(this.i18n.builderErrorTitle, this._msg(e), 'error');
        } finally {
            this.isPublishing = false;
            this._refreshLock();
        }
    }

    _validateDraft() {
        const incomplete = new Set();
        let message = '';
        this._flatQuestions().forEach(({ q }) => {
            if (!clean(q.labels.fr) || !clean(q.labels.en)) {
                incomplete.add(q.id);
                message = message || this.i18n.builderMissingLabel;
            }
            if (q.kind === 'related' && !q.developerName && (!q.target.value || !q.target.account)) {
                incomplete.add(q.id);
                message = message || format(this.i18n.builderMissingMapping, clean(q.labels[this.previewLang]) || q.target.object);
            }
            if (this._historyIncomplete(q)) {
                incomplete.add(q.id);
                message = message || format(this.i18n.builderMissingHistory, clean(q.labels[this.previewLang]) || q.key);
            }
        });
        this._allBlocks().forEach(({ item }) => {
            if (this._blockIncomplete(item)) {
                incomplete.add(item.id);
                message = message || format(this.i18n.builderBlockMissing, this.i18n[BLOCK_LABEL_KEYS[item.type]]);
            }
        });
        // Sections are told apart by their FR|EN titles (block anchors, reload): two sections with
        // the same pair would merge, and a section without questions isn't saved.
        const seenTitles = new Set();
        this.draft.sections.forEach((sec) => {
            const hasQuestions = sec.questions.some((x) => x.kind !== 'block');
            if (!hasQuestions) {
                if (sec.questions.length) message = message || this.i18n.builderBlocksOnlySection;
                return;
            }
            const pair = sectionAnchor(clean(sec.titles.fr), clean(sec.titles.en));
            if (seenTitles.has(pair)) {
                message = message || format(this.i18n.builderDuplicateSection,
                    this._sectionName(sec));
            }
            seenTitles.add(pair);
        });
        (this.draft.tables || []).forEach((t) => {
            if (!clean(t.titles.fr) || !clean(t.titles.en)) {
                incomplete.add(t.id);
                message = message || format(this.i18n.builderTableMissingTitle, t.objectLabel);
            }
        });
        if (!message && serializeBlocks(this._blockList()).length > BLOCKS_MAX_LENGTH) message = this.i18n.builderBlocksTooLong;
        this.incompleteIds = incomplete;
        if (!message && !this._flatQuestions().some(({ q }) => !q.isHidden && !q.isReadOnly) && !this._placedTableIds().size) {
            message = this.i18n.builderAllReadOnly;
        }
        return message;
    }

    _blockIncomplete(b) {
        if (TEXT_TYPES.includes(b.type)) {
            const tx = this.draft.texts['b:' + b.bid] || {};
            return !clean(tx.fr) || !clean(tx.en);
        }
        if (IMAGE_TYPES.includes(b.type)) {
            // A logo or picture tells something: screen readers need its description. A banner is decoration.
            return !b.url || (b.type !== 'banner' && (!clean(b.altFr) || !clean(b.altEn)));
        }
        if (b.type === 'video') return !videoEmbedUrl(b.url);
        return false;
    }

    _historyIncomplete(q) {
        return q.kind === 'field' && q.historyMode === 'Historize'
            && (!q.target.object || !q.target.value || !q.target.account);
    }

    _pollDeploy(jobId) {
        return new Promise((resolve, reject) => {
            let attempts = 0;
            const tick = async () => {
                attempts++;
                try {
                    const result = await checkDeployStatus({ jobId });
                    if (result.done) {
                        if (result.status === 'Succeeded') resolve(result);
                        else reject(new Error(result.errorMessage || this.i18n.deployFailedGeneric));
                        return;
                    }
                    if (attempts >= POLL_MAX_ATTEMPTS) {
                        reject(new Error(this.i18n.deployStillRunning));
                        return;
                    }
                    // eslint-disable-next-line @lwc/lwc/no-async-operation
                    setTimeout(tick, POLL_INTERVAL_MS);
                } catch (e) {
                    reject(e);
                }
            };
            tick();
        });
    }

    // ── Palette ──────────────────────────────────────────────────────────────

    get usedKeys() {
        const used = new Set();
        this._flatQuestions().forEach(({ q }) => {
            if (q.key) used.add(q.key.toLowerCase());
        });
        return used;
    }

    _matches(...texts) {
        const term = clean(this.search).toLowerCase();
        return !term || texts.some((t) => (t || '').toLowerCase().includes(term));
    }

    _chip(item) {
        const used = item.isTable ? item.used : !item.isObject && this.usedKeys.has(item.key.toLowerCase());
        return {
            ...item,
            used,
            draggable: used ? 'false' : 'true',
            className: 'dub-chip' + (item.related ? ' dub-chip--related' : '') + (item.isTable ? ' dub-chip--table' : used ? ' dub-chip--used' : ''),
            subClass: item.mono ? 'dub-mono' : '',
            addLabel: format(this.i18n.builderAddTo, item.name)
        };
    }

    get fieldChips() {
        const L = this.previewLang;
        const seen = new Set();
        const chips = [];
        this.catalog
            .filter((c) => c.historyMode !== HISTORY_ONLY && c.historyMode !== HISTORY_TABLE)
            .forEach((c) => {
                seen.add(c.fieldApiName.toLowerCase());
                const name = (L === 'en' ? c.labelEn : c.labelFr) || c.fieldApiName;
                if (this._matches(name, c.labelFr, c.labelEn, c.fieldApiName)) {
                    chips.push(this._chip({ id: 'c:' + c.developerName, key: c.fieldApiName, name, sub: c.fieldApiName, mono: true }));
                }
            });
        this.availableFields.forEach((f) => {
            if (seen.has(f.apiName.toLowerCase())) return;
            if (this._matches(f.schemaLabel, f.apiName)) {
                chips.push(this._chip({ id: 'a:' + f.apiName, key: f.apiName, name: f.schemaLabel || f.apiName, sub: f.apiName, mono: true }));
            }
        });
        return chips;
    }

    get relatedChips() {
        const L = this.previewLang;
        const chips = [];
        this.catalog
            .filter((c) => c.historyMode === HISTORY_ONLY)
            .forEach((c) => {
                const name = (L === 'en' ? c.labelEn : c.labelFr) || c.fieldApiName;
                const objLabel = this._objectLabel(c.historyTargetObjectApiName);
                if (this._matches(name, c.labelFr, c.labelEn, objLabel)) {
                    chips.push(this._chip({
                        id: 'c:' + c.developerName, key: c.fieldApiName, name,
                        sub: format(this.i18n.builderNewRecordIn, objLabel), related: true
                    }));
                }
            });
        // A history object of the église form is offered as its Excel-style table, never as a
        // one-value question.
        const tableObjects = new Set();
        const placed = this._placedTableIds();
        (this.draft.tables || []).forEach((t) => {
            tableObjects.add(t.objectApiName.toLowerCase());
            const title = this._tableTitle(t);
            if (this._matches(title, t.objectLabel, t.objectApiName)) {
                chips.push(this._chip({
                    id: 't:' + t.id, key: 't:' + t.id, isTable: true, related: true, used: placed.has(t.id),
                    name: format(this.i18n.builderTableChip, title), sub: this.i18n.builderTableChipSub
                }));
            }
        });
        // Objects only another form uses (e.g. église attendance in the person form, both on
        // Account) go last, saying which form uses them.
        const others = [];
        this.relatedObjects.forEach((o) => {
            if (tableObjects.has(o.apiName.toLowerCase())) return;
            if (!this._matches(o.label, o.apiName)) return;
            const users = o.usedByForms || [];
            const otherOnly = users.length > 0 && !users.includes(this.formDeveloperName);
            const chip = this._chip({
                id: 'o:' + o.apiName, key: 'o:' + o.apiName, isObject: true, related: true,
                name: format(this.i18n.builderNewRelatedQuestion, o.label),
                sub: otherOnly
                    ? format(this.i18n.builderUsedByFmt, users.map((d) => this._formLabel(d)).join(', '))
                    : format(this.i18n.builderNewRecordIn, o.label)
            });
            if (otherOnly) {
                chip.className += ' dub-chip--other';
                others.push(chip);
            } else {
                chips.push(chip);
            }
        });
        return [...chips, ...others];
    }

    get hasFieldChips() {
        return this.fieldChips.length > 0;
    }

    get hasRelatedChips() {
        return this.relatedChips.length > 0;
    }

    _formLabel(developerName) {
        const f = (this.forms || []).find((x) => x.developerName === developerName);
        return f ? f.label : developerName;
    }

    _objectLabel(apiName) {
        const o = this.relatedObjects.find((x) => x.apiName === apiName);
        return o ? o.label : apiName || '';
    }

    handleSearch(event) {
        this.search = event.target.value;
    }

    // Palette tabs: record fields vs related objects, so the related list is one click away
    get isFieldsTab() {
        return this.paletteTab === 'fields';
    }

    get isRelatedTab() {
        return this.paletteTab === 'related';
    }

    get tabFieldsSelected() {
        return String(this.isFieldsTab);
    }

    get tabRelatedSelected() {
        return String(this.isRelatedTab);
    }

    get tabFieldsCount() {
        return this.fieldChips.length;
    }

    get tabRelatedCount() {
        return this.relatedChips.length;
    }

    handlePaletteTab(event) {
        this.paletteTab = event.currentTarget.dataset.value;
    }

    // Left pane: questions (fields + related objects) | tools (design blocks)
    get isQuestionsTab() {
        return this.leftTab === 'questions';
    }

    get leftTabQuestionsSelected() {
        return String(this.leftTab === 'questions');
    }

    get leftTabToolsSelected() {
        return String(this.leftTab === 'tools');
    }

    get leftPaneTitle() {
        return this.isQuestionsTab ? this.i18n.builderPalette : this.i18n.builderTabTools;
    }

    handleLeftTab(event) {
        this.leftTab = event.currentTarget.dataset.value;
        // Questions only go on the questions screen.
        if (this.leftTab === 'questions' && !this.isQuestionsScreen) this._showScreen('questions');
    }

    get toolGroups() {
        const tile = (type) => ({
            type,
            label: this.i18n[BLOCK_LABEL_KEYS[type]],
            icon: BLOCK_ICONS[type],
            hint: BLOCK_HINT_KEYS[type] ? this.i18n[BLOCK_HINT_KEYS[type]] : this.i18n[BLOCK_LABEL_KEYS[type]]
        });
        return [
            { key: 'page', label: this.i18n.builderToolsPage, tools: PAGE_TYPES.map(tile) },
            { key: 'content', label: this.i18n.builderToolsContent, tools: CONTENT_TYPES.map(tile) }
        ];
    }

    handleToolAdd(event) {
        const type = event.currentTarget.dataset.type;
        const item = this._newBlockItem(type);
        if (TEXT_TYPES.includes(type)) this.draft.texts['b:' + item.bid] = { fr: '', en: '' };
        const [list, index] = this._insertPoint(type);
        list.splice(index, 0, item);
        this._selectBlock(item);
        this._touch();
    }

    // Right after the selected item; otherwise banner/logo at the top, the rest at the end.
    _insertPoint(type) {
        const top = TOP_TYPES.includes(type);
        if (this.isMessagesScreen) {
            const lane = this.draft.msgLanes[this.msgLane];
            const sel = this._laneSelection(lane);
            if (sel > -1) return [lane, sel + 1];
            return [lane, top ? 0 : lane.length];
        }
        if (this.isAccessScreen) {
            const lane = this.draft.login;
            const sel = this._laneSelection(lane);
            if (sel > -1) return [lane, sel + 1];
            return [lane, top ? 0 : lane.findIndex((x) => x.fixed === 'button')];
        }
        const head = this.draft.head;
        const hs = this._laneSelection(head);
        if (hs > -1) return [head, hs + 1];
        const hit = this._findQ(this.selB || this.selQ);
        if (hit) return [hit.s.questions, hit.i + 1];
        if (top) return [head, 0];
        const secs = this.draft.sections;
        const s = secs.find((x) => x.id === this.selS) || secs[secs.length - 1];
        return [s.questions, s.questions.length];
    }

    _laneSelection(lane) {
        const fixed = this.selText === 'idHelp' ? 'idField' : this.selText;
        return lane.findIndex((x) => (this.selB && x.id === this.selB) || (!this.selB && x.fixed && x.fixed === fixed));
    }

    _selectBlock(item) {
        if (this.isMessagesScreen) this._setMsgLane(item.id);
        this.selB = item.id;
        this.selText = TEXT_TYPES.includes(item.type) ? 'b:' + item.bid : null;
        this.appearanceOpen = false;
        this.textRange = null;
        this.selQ = null;
        this.selS = null;
        this.selT = null;
    }

    // { list, i, item, where: 'login'|'head'|'message'|'section', s }
    _findB(id) {
        if (!id) return null;
        const lanes = [['login', this.draft.login], ['head', this.draft.head],
            ...MESSAGE_LANES.map((m) => ['message', this.draft.msgLanes[m]])];
        for (const [where, list] of lanes) {
            const i = list.findIndex((x) => x.id === id);
            if (i > -1) return { list, i, item: list[i], where };
        }
        const hit = this._findQ(id);
        return hit && hit.q.kind === 'block' ? { list: hit.s.questions, i: hit.i, item: hit.q, where: 'section', s: hit.s } : null;
    }

    _allBlocks() {
        const out = [];
        [this.draft.login, this.draft.head, ...MESSAGE_LANES.map((m) => this.draft.msgLanes[m]),
            ...this.draft.sections.map((s) => s.questions)].forEach((list) => {
            list.forEach((item) => {
                if (item.kind === 'block') out.push({ item });
            });
        });
        return out;
    }

    handleBlockClick(event) {
        event.stopPropagation();
        const hit = this._findB(event.currentTarget.dataset.b);
        if (hit) this._selectBlock(hit.item);
    }

    // Enter / Space select a focused block, like a click (keys typed in its tool buttons pass).
    handleBlockKey(event) {
        if (event.target !== event.currentTarget || (event.key !== 'Enter' && event.key !== ' ')) return;
        event.preventDefault();
        this.handleBlockClick(event);
    }

    handleBlockMove(event) {
        event.stopPropagation();
        const hit = this._findB(event.currentTarget.dataset.b);
        if (!hit) return;
        const dir = Number(event.currentTarget.dataset.dir);
        const secs = this.draft.sections;
        if (hit.where === 'section') {
            // From the top of the first section, a block goes up into the form header.
            if (dir < 0 && hit.i === 0 && secs.indexOf(hit.s) === 0) {
                hit.list.splice(hit.i, 1);
                this.draft.head.push(hit.item);
                this._touch();
            } else {
                this._moveItem(hit.item.id, dir);
            }
            return;
        }
        const j = hit.i + dir;
        if (hit.where === 'head' && j >= hit.list.length) {
            hit.list.splice(hit.i, 1);
            secs[0].questions.unshift(hit.item);
        } else if (j >= 0 && j < hit.list.length) {
            hit.list.splice(hit.i, 1);
            hit.list.splice(j, 0, hit.item);
        }
        this._touch();
    }

    handleBlockDuplicate(event) {
        event.stopPropagation();
        const hit = this._findB(event.currentTarget.dataset.b);
        if (!hit) return;
        const copy = { ...hit.item, id: newId('b'), bid: newBlockId() };
        const from = 'b:' + hit.item.bid;
        const to = 'b:' + copy.bid;
        if (this.draft.texts[from]) this.draft.texts[to] = { ...this.draft.texts[from] };
        if (this.draft.styles[from]) this.draft.styles[to] = JSON.parse(JSON.stringify(this.draft.styles[from]));
        hit.list.splice(hit.i + 1, 0, copy);
        this._selectBlock(copy);
        this._touch();
    }

    handleBlockRemove(event) {
        event.stopPropagation();
        const hit = this._findB(event.currentTarget.dataset.b);
        if (!hit) return;
        hit.list.splice(hit.i, 1);
        delete this.draft.texts['b:' + hit.item.bid];
        delete this.draft.styles['b:' + hit.item.bid];
        this.incompleteIds.delete(hit.item.id);
        if (this.selB === hit.item.id) {
            this.selB = null;
            this.selText = null;
            this.appearanceOpen = false;
            this.textRange = null;
        }
        this._touch();
    }

    handleKeydown(event) {
        if (event.key === 'Escape') {
            event.stopPropagation();
            this.handleClose();
        }
    }

    handleChipAdd(event) {
        this._addFromChip(event.currentTarget.dataset.chip);
    }

    // Palette "−" of a table on the form: takes it off, like the canvas ×.
    handleChipRemove(event) {
        this._removeTable(event.currentTarget.dataset.chip.slice(2));
    }

    handleChipDragStart(event) {
        this._drag = { type: 'add', chip: event.currentTarget.dataset.chip };
        event.dataTransfer.effectAllowed = 'copy';
        event.dataTransfer.setData('text/plain', this._drag.chip);
    }

    _addFromChip(chipId, sectionId, index) {
        if (chipId.startsWith('t:')) {
            this._showTable(chipId.slice(2), sectionId, index);
            return;
        }
        const q = this._newQuestionForChip(chipId);
        if (!q) return;
        if (q.key && this.usedKeys.has(q.key.toLowerCase())) return;
        const secs = this.draft.sections;
        let s = secs.find((x) => x.id === sectionId) || secs.find((x) => x.id === this.selS) || secs[secs.length - 1];
        if (!s) {
            s = { id: newId('s'), titles: this._newSectionTitles(), questions: [] };
            secs.push(s);
        }
        s.questions.splice(index === undefined ? s.questions.length : index, 0, q);
        this.selQ = q.id;
        this.selS = s.id;
        this.selB = null;
        this.selText = null;
        this.appearanceOpen = false;
        this.screen = 'questions';
        this._touch();
        if (q.kind === 'related' && !q.developerName) this._loadObjectFields(q);
        this._revealQuestion(q.id);
    }

    // The new question can land in a section below the fold: bring it into view once drawn.
    _revealQuestion(id) {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            const el = this.template.querySelector(`[data-q="${id}"]`);
            if (el && el.scrollIntoView) el.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
        });
    }

    _newQuestionForChip(chipId) {
        const [kind, ...rest] = chipId.split(':');
        const ref = rest.join(':');
        if (kind === 'c') {
            const c = this.catalog.find((x) => x.developerName === ref);
            // A question put back from the palette is always visible and editable again.
            return c ? { ...this._questionFromCatalog(c), isHidden: false, isReadOnly: false } : null;
        }
        if (kind === 'a') {
            const f = this.availableFields.find((x) => x.apiName === ref);
            if (!f) return null;
            return {
                id: newId('q'), developerName: null, key: f.apiName, kind: 'field',
                labels: { fr: f.schemaLabel || f.apiName, en: f.schemaLabel || f.apiName },
                help: { fr: '', en: '' },
                inputType: INPUT_TYPES.includes(f.inferredInputType) ? f.inferredInputType : 'Text',
                isRequired: false, sameRowAsPrevious: false, isHidden: false, isReadOnly: false, historyMode: 'Replace',
                target: { object: '', value: '', date: '', account: '', log: '', dateSource: '' }
            };
        }
        if (kind === 'o') {
            const o = this.relatedObjects.find((x) => x.apiName === ref);
            if (!o) return null;
            return {
                id: newId('q'), developerName: null, key: '', kind: 'related',
                labels: { fr: o.label, en: o.label }, help: { fr: '', en: '' },
                inputType: 'Number', isRequired: false, sameRowAsPrevious: false, isHidden: false, isReadOnly: false,
                historyMode: HISTORY_ONLY,
                target: { object: o.apiName, value: '', date: '', account: '', log: '', dateSource: '' }
            };
        }
        return null;
    }

    // autoPick=false only loads the field lists (a published mapping is never changed by a click).
    async _loadObjectFields(q, autoPick = true) {
        const obj = q.target.object;
        if (!this.objectFieldsByObject[obj]) {
            try {
                const fields = (await getObjectFields({ objectApiName: obj })) || [];
                this.objectFieldsByObject = { ...this.objectFieldsByObject, [obj]: fields };
            } catch (e) {
                this._toast(this.i18n.builderErrorTitle, this._msg(e), 'error');
                return;
            }
        }
        if (!autoPick) {
            this._touch();
            return;
        }
        // Pre-select the lookups an admin would almost always pick (same rule as Settings).
        const refs = this.objectFieldsByObject[obj].filter((f) => f.type === 'REFERENCE');
        const pick = (target) => {
            const match = refs.filter((f) => (f.referenceToApiNames || []).includes(target));
            return match.length === 1 ? match[0].apiName : '';
        };
        if (!q.target.account) q.target.account = pick(this.info.targetObjectApiName);
        if (!q.target.log) q.target.log = pick(LOG_OBJECT);
        if (q.kind === 'field' && q.historyMode === 'Historize') {
            const fields = this.objectFieldsByObject[obj];
            if (!q.target.value) {
                const v = fields.find((f) => f.apiName.toLowerCase() === HISTORY_VALUE_FIELD);
                if (v) q.target.value = v.apiName;
            }
            if (!q.target.date) {
                const dates = fields.filter((f) => DATE_TYPES.includes(f.type));
                if (dates.length === 1) q.target.date = dates[0].apiName;
            }
        }
        this._touch();
    }

    // ── Preview (canvas) ─────────────────────────────────────────────────────

    get isAccessScreen() {
        return this.screen === 'access';
    }

    get segScreenAccess() {
        return String(this.screen === 'access');
    }
    get segScreenQuestions() {
        return String(this.screen === 'questions');
    }
    get segScreenMessages() {
        return String(this.screen === 'messages');
    }
    get isQuestionsScreen() {
        return this.screen === 'questions';
    }
    get isMessagesScreen() {
        return this.screen === 'messages';
    }

    // Message card (locked / pending / confirm) that new tools go into.
    _setMsgLane(itemId) {
        const screen = MESSAGE_LANES.find((m) => this.draft.msgLanes[m].some((x) => x.id === itemId));
        if (screen) this.msgLane = screen;
    }

    handleMsgCard(event) {
        this.msgLane = event.currentTarget.dataset.lane;
    }
    get segFr() {
        return String(this.previewLang === 'fr');
    }
    get segEn() {
        return String(this.previewLang === 'en');
    }

    handleScreen(event) {
        this._showScreen(event.currentTarget.dataset.value);
        // Only tools can be added to the Login and Messages screens.
        if (!this.isQuestionsScreen) this.leftTab = 'tools';
    }

    _showScreen(screen) {
        this.screen = screen;
        this.selText = null;
        this.appearanceOpen = false;
        this.selB = null;
        this.textRange = null;
        if (this.screen !== 'questions') {
            this.selQ = null;
            this.selS = null;
            this.selT = null;
        }
    }

    _blockView(item) {
        const key = 'b:' + item.bid;
        const tx = this.draft.texts[key] || {};
        const incomplete = this.incompleteIds.has(item.id);
        return {
            id: item.id,
            isBlock: true,
            block: {
                type: item.type, fr: tx.fr || '', en: tx.en || '', st: this.draft.styles[key],
                url: item.url, altFr: item.altFr, altEn: item.altEn, size: item.size, align: item.align
            },
            label: this.i18n[BLOCK_LABEL_KEYS[item.type]],
            incomplete,
            incompleteTag: this.i18n.builderIncompleteTag,
            className: 'dub-blk' + (this.selB === item.id ? ' dub-is-selected' : '') + (incomplete ? ' dub-is-incomplete' : '')
                + (this._drag && this._drag.type === 'move' && this._drag.id === item.id ? ' dub-is-dragging' : '')
        };
    }

    _laneView(lane) {
        return lane.map((it, i) => {
            // A subtitle right under its title stays tight, as on the portal.
            const tight = (it.fixed === 'lookupSubtitle' || it.fixed === 'formSubtitle') && i > 0 && !!lane[i - 1].fixed;
            const view = it.fixed ? { id: it.id, isBlock: false, ['is_' + it.fixed]: true } : this._blockView(it);
            return { ...view, itemClass: 'dub-lane-item' + (tight ? ' dub-lane-item--tight' : '') };
        });
    }

    get loginItems() {
        return this._laneView(this.draft.login);
    }

    get headItems() {
        return this._laneView(this.draft.head);
    }

    get messageCards() {
        const nameKeys = { locked: 'builderMsgCardLocked', pending: 'builderMsgCardPending', confirm: 'builderMsgCardConfirm' };
        return MESSAGE_LANES.map((screen) => ({
            screen,
            name: this.i18n[nameKeys[screen]],
            className: 'dub-msg-card' + (this.msgLane === screen ? ' dub-is-active' : ''),
            items: this._laneView(this.draft.msgLanes[screen]).map((it) => {
                if (it.isBlock) return it;
                const fixed = it.id.slice(2);
                return { ...it, isMsgTitle: fixed.endsWith('Title'), text: this._text(fixed) };
            })
        }));
    }

    handlePreviewLang(event) {
        this.previewLang = event.currentTarget.dataset.value;
    }

    _text(key) {
        const custom = clean(this.draft.texts[key] && this.draft.texts[key][this.previewLang]);
        const entry = this.draft.styles[key];
        const value = custom || this.pv[key];
        return {
            key,
            value,
            runs: buildRuns(value, entry, this.previewLang, !!custom),
            blockStyle: blockStyle(entry),
            className: 'dub-acc-edit' + (this.selText === key ? ' dub-is-selected' : '') + (custom ? ' is-custom' : ''),
            customTag: this.i18n.builderCustomTag,
            isCustom: !!custom
        };
    }

    get textLookupTitle() {
        return this._text('lookupTitle');
    }
    get textLookupSubtitle() {
        return this._text('lookupSubtitle');
    }
    get textIdHelp() {
        return this._text('idHelp');
    }
    get textFormTitle() {
        return this._text('formTitle');
    }
    get textFormSubtitle() {
        return this._text('formSubtitle');
    }
    get textErrNoChanges() {
        return this._text('errNoChanges');
    }

    get hasIdentity2() {
        return !!(this.info && this.info.identityField2ApiName);
    }

    get identity2() {
        return getIdentity2Labels(this.previewLang, this.info ? this.info.identityField2ApiName : '');
    }

    handleTextSelect(event) {
        if (this.selText !== event.currentTarget.dataset.text) this.textRange = null;
        this.selText = event.currentTarget.dataset.text;
        if (this.isMessagesScreen) this._setMsgLane('f:' + this.selText);
        this.appearanceOpen = false;
        this.selB = null;
        this.selQ = null;
        this.selS = null;
        this.selT = null;
    }

    handleTextKey(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleTextSelect(event);
        }
    }

    get previewSections() {
        const L = this.previewLang;
        const pv = this.pv;
        const published = this.publishedKeys;
        const flat = this._flatQuestions();
        const payload = this._payload().questions;
        const identities = new Map(flat.map(({ q }, i) => [q.id, this._identity(payload[i], q.id)]));
        return this.draft.sections.map((s) => {
            const title = clean(s.titles[L]);
            const questions = s.questions.map((q, i) => {
                const drop = this.dropTarget && this.dropTarget.sectionId === s.id;
                const dropBefore = drop && this.dropTarget.index === i;
                const dropAfter = drop && this.dropTarget.index === i + 1 && i === s.questions.length - 1;
                if (q.kind === 'block') return { ...this._blockView(q), dropBefore, dropAfter };
                if (q.kind === 'table') return { ...this._tableView(q), dropBefore, dropAfter };
                const paired = q.sameRowAsPrevious && i > 0 && s.questions[i - 1].kind !== 'block' && s.questions[i - 1].kind !== 'table';
                const isNew = !published.has(identities.get(q.id));
                const incomplete = this.incompleteIds.has(q.id)
                    || (q.kind === 'related' && !q.developerName && (!q.target.value || !q.target.account))
                    || this._historyIncomplete(q);
                const help = clean(q.help[L]) || (q.inputType === 'Phone' ? pv.phoneHelp : q.inputType === 'Email' ? pv.emailHelp : '');
                const historize = q.kind === 'field' && q.historyMode === 'Historize';
                return {
                    id: q.id,
                    isBlock: false,
                    label: clean(q.labels[L]) || '…',
                    help,
                    hasHelp: !!help,
                    isRequired: q.isRequired,
                    isCheckbox: q.inputType === 'Checkbox',
                    isPicklist: q.inputType === 'Picklist',
                    isPlain: q.inputType !== 'Checkbox' && q.inputType !== 'Picklist',
                    htmlType: { Email: 'email', Phone: 'tel', Date: 'date', Number: 'number' }[q.inputType] || 'text',
                    selectPlaceholder: pv.selectPlaceholder,
                    isRelated: q.kind === 'related',
                    hasDate: q.kind === 'related' && !!q.target.date,
                    dateLabel: pv.historyDateLabel,
                    dateHelp: pv.historyDateHelp,
                    tag: q.kind === 'related' ? '↳ ' + this._objectLabel(q.target.object) : q.key,
                    tagClass: q.kind === 'related' ? 'dub-tag dub-tag--related' : 'dub-tag dub-tag--field dub-mono',
                    sameRow: paired,
                    className: 'dub-q'
                        + (this.selQ === q.id ? ' dub-is-selected' : '')
                        + (paired ? ' dub-q--paired' : '')
                        + (q.isHidden ? ' dub-is-hidden' : '')
                        + (q.isReadOnly && !q.isHidden ? ' dub-is-readonly' : '')
                        + (this._drag && this._drag.type === 'move' && this._drag.id === q.id ? ' dub-is-dragging' : ''),
                    isNew,
                    incomplete,
                    dropBefore,
                    dropAfter,
                    newTag: this.i18n.builderNewTag,
                    incompleteTag: this.i18n.builderIncompleteTag,
                    isHidden: q.isHidden === true,
                    isReadOnly: q.isReadOnly === true && q.isHidden !== true,
                    readOnlyTag: this.i18n.builderReadOnlyTag,
                    isHistorize: historize && !!q.target.object,
                    historyTag: format(this.i18n.builderHistoryTag, this._objectLabel(q.target.object)),
                    hiddenPressed: String(q.isHidden === true),
                    hiddenTag: this.i18n.builderHiddenTag,
                    toggleHiddenTitle: q.isHidden ? this.i18n.builderShow : this.i18n.builderHide,
                    toggleHiddenIcon: q.isHidden ? 'utility:preview' : 'utility:hide'
                };
            });
            return {
                id: s.id,
                title: title || this._sectionName(s),
                titleClass: 'dub-section__title' + (title ? '' : ' dub-section__title--empty'),
                className: 'dub-section' + (this.selS === s.id && !this.selQ && !this.selB ? ' dub-is-selected' : ''),
                questions,
                isEmpty: questions.length === 0,
                emptyClass: 'dub-empty-drop' + (this.dropTarget && this.dropTarget.sectionId === s.id ? ' dub-is-over' : '')
            };
        });
    }

    // Question rows are selectable from the keyboard too (Enter / Space), like the blocks.
    handleQuestionKey(event) {
        if (event.target !== event.currentTarget || (event.key !== 'Enter' && event.key !== ' ')) return;
        event.preventDefault();
        this.handleQuestionClick(event);
    }

    handleQuestionClick(event) {
        const id = event.currentTarget.dataset.q;
        const hit = this._findQ(id);
        if (!hit) return;
        this.selQ = id;
        this.selS = hit.s.id;
        this.selB = null;
        this.selText = null;
        this.appearanceOpen = false;
        this.textRange = null;
        if (hit.q.kind === 'related' && !hit.q.developerName) this._loadObjectFields(hit.q);
        else if (hit.q.kind === 'field' && hit.q.target.object) this._loadObjectFields(hit.q, false);
    }

    handleSectionSelect(event) {
        event.stopPropagation();
        this.selS = event.currentTarget.dataset.section;
        this.selQ = null;
        this.selB = null;
        this.selText = null;
        this.appearanceOpen = false;
    }

    handleMove(event) {
        event.stopPropagation();
        this._moveItem(event.currentTarget.dataset.q, Number(event.currentTarget.dataset.dir));
    }

    _moveItem(id, dir) {
        const hit = this._findQ(id);
        if (!hit) return;
        const secs = this.draft.sections;
        const si = secs.indexOf(hit.s);
        const j = hit.i + dir;
        // Arrows cross section borders: past the edge, the question goes to the next/previous section.
        if (j >= 0 && j < hit.s.questions.length) this._moveQuestion(hit.q.id, hit.s.id, dir > 0 ? j + 1 : j);
        else if (dir < 0 && si > 0) this._moveQuestion(hit.q.id, secs[si - 1].id, secs[si - 1].questions.length);
        else if (dir > 0 && si < secs.length - 1) this._moveQuestion(hit.q.id, secs[si + 1].id, 0);
    }

    handleRemoveQuestion(event) {
        event.stopPropagation();
        const hit = this._findQ(event.currentTarget.dataset.q);
        if (!hit) return;
        hit.s.questions.splice(hit.i, 1);
        if (this.selQ === hit.q.id) this.selQ = null;
        this._touch();
    }

    handleRemoveSection(event) {
        event.stopPropagation();
        const secs = this.draft.sections;
        const i = secs.findIndex((s) => s.id === event.currentTarget.dataset.section);
        if (i < 0) return;
        if (secs.length < 2) {
            this._toast(this.i18n.builderOnlySection, '', 'warning');
            return;
        }
        if (secs[i].questions.length) {
            const target = secs[i === 0 ? 1 : i - 1];
            if (i === 0) target.questions.unshift(...secs[i].questions);
            else target.questions.push(...secs[i].questions);
            this._toast(format(this.i18n.builderSectionMoved, this._sectionName(target)), '', 'info');
        }
        secs.splice(i, 1);
        if (this.selS === event.currentTarget.dataset.section) this.selS = null;
        this._touch();
    }

    // Sections are told apart by their FR|EN titles, so each new one gets a free pair
    // ("Nouvelle section 2"…) instead of a copy that would block Publish as a duplicate.
    _newSectionTitles() {
        const taken = new Set(this.draft.sections.map((x) => sectionAnchor(clean(x.titles.fr), clean(x.titles.en))));
        for (let n = 1; n < 1000; n++) {
            const sfx = n === 1 ? '' : ' ' + n;
            const titles = { fr: NEW_SECTION_TITLES.fr + sfx, en: NEW_SECTION_TITLES.en + sfx };
            if (!taken.has(sectionAnchor(titles.fr, titles.en))) return titles;
        }
        return { ...NEW_SECTION_TITLES };
    }

    // Shown name of a section; untitled ones are numbered so two never look the same.
    _sectionName(s) {
        const title = clean(s.titles[this.previewLang]);
        if (title) return title;
        const untitled = this.draft.sections.filter((x) => !clean(x.titles[this.previewLang]));
        return untitled.length > 1
            ? this.i18n.builderUntitledSection + ' ' + (untitled.indexOf(s) + 1)
            : this.i18n.builderUntitledSection;
    }

    handleAddSection() {
        const s = { id: newId('s'), titles: this._newSectionTitles(), questions: [] };
        this.draft.sections.push(s);
        this.selS = s.id;
        this.selQ = null;
        this.selB = null;
        this.selText = null;
        this.appearanceOpen = false;
        this._touch();
    }

    _findQ(id) {
        for (const s of this.draft.sections) {
            const i = s.questions.findIndex((q) => q.id === id);
            if (i > -1) return { s, i, q: s.questions[i] };
        }
        return null;
    }

    _moveQuestion(id, toSectionId, toIndex) {
        const hit = this._findQ(id);
        const dest = this.draft.sections.find((x) => x.id === toSectionId);
        if (!hit || !dest) return;
        hit.s.questions.splice(hit.i, 1);
        let idx = toIndex;
        if (dest === hit.s && idx > hit.i) idx--;
        dest.questions.splice(Math.max(0, Math.min(idx, dest.questions.length)), 0, hit.q);
        this._touch();
    }

    // ── Drag & drop ──────────────────────────────────────────────────────────

    handleQuestionDragStart(event) {
        this._drag = { type: 'move', id: event.currentTarget.dataset.q };
        event.dataTransfer.effectAllowed = 'move';
        event.dataTransfer.setData('text/plain', this._drag.id);
        this._touch();
    }

    handleQuestionDragOver(event) {
        if (!this._drag) return;
        event.preventDefault();
        const hit = this._findQ(event.currentTarget.dataset.q);
        if (!hit) return;
        const rect = event.currentTarget.getBoundingClientRect();
        const after = event.clientY > rect.top + rect.height / 2;
        const index = hit.i + (after ? 1 : 0);
        if (!this.dropTarget || this.dropTarget.sectionId !== hit.s.id || this.dropTarget.index !== index) {
            this.dropTarget = { sectionId: hit.s.id, index };
        }
    }

    handleEmptyDragOver(event) {
        if (!this._drag) return;
        event.preventDefault();
        const sectionId = event.currentTarget.dataset.section;
        if (!this.dropTarget || this.dropTarget.sectionId !== sectionId) {
            this.dropTarget = { sectionId, index: 0 };
        }
    }

    handleDrop(event) {
        event.preventDefault();
        const drag = this._drag;
        const target = this.dropTarget;
        this._endDrag();
        if (!drag || !target) return;
        if (drag.type === 'add') this._addFromChip(drag.chip, target.sectionId, target.index);
        else this._moveQuestion(drag.id, target.sectionId, target.index);
    }

    handleDragEnd() {
        this._endDrag();
    }

    _endDrag() {
        this._drag = null;
        this.dropTarget = null;
        this._touch();
    }

    // ── Properties pane ──────────────────────────────────────────────────────

    get propsTitle() {
        if (this.appearanceOpen) return this.i18n.builderAppearance;
        if (this.activeTable) return this.i18n.builderTable;
        const blk = this._findB(this.selB);
        if (blk) return this.i18n[BLOCK_LABEL_KEYS[blk.item.type]];
        if (this.selText) return this._screenTitle();
        if (this.selQ) return this.i18n.builderQuestion;
        if (this.selS) return this.i18n.builderSection;
        return this._screenTitle();
    }

    _screenTitle() {
        if (this.isAccessScreen) return this.i18n.builderAccessScreen;
        if (this.isMessagesScreen) return this.i18n.builderMessagesScreen;
        return this.i18n.builderProperties;
    }

    get showMessagesHint() {
        return !this.appearanceOpen && !this.selText && !this.selB && this.isMessagesScreen;
    }

    get showTextProps() {
        return !this.appearanceOpen && !!this.selText;
    }

    get showQuestionProps() {
        return !this.appearanceOpen && !this.selText && !this.selB && !!this.selectedQuestion;
    }

    get showSectionProps() {
        return !this.appearanceOpen && !this.selText && !this.selQ && !this.selB && !!this.selectedSection;
    }

    get showBlockProps() {
        return !this.appearanceOpen && !this.selText && !!this.selectedBlock;
    }

    get showAccessHint() {
        return !this.appearanceOpen && !this.selText && !this.selB && this.isAccessScreen;
    }

    get showEmptyHint() {
        return !this.appearanceOpen && !this.selText && !this.selB && this.isQuestionsScreen && !this.selectedQuestion
            && !this.selectedSection && !this.activeTable;
    }

    // ── Appearance (uniform font + colors of the whole form) ────────────────

    get appearance() {
        return this.draft.appearance || { ...APPEARANCE_DEFAULTS };
    }

    // CSS variables of the preview paper: same as the portal's container.
    get paperStyle() {
        return appearanceStyle(this.appearance);
    }

    get appearanceBtnPressed() {
        return this.appearanceOpen ? 'true' : 'false';
    }

    get appearanceIsDefault() {
        return serializeAppearance(this.appearance) === '';
    }

    get appearanceStatus() {
        return this.appearanceIsDefault ? this.i18n.builderAppearanceIsDefault : this.i18n.builderAppearanceCustom;
    }

    get fontOptions() {
        const cur = this.appearance.font;
        return FONTS.map((f) => ({ ...f, selected: f.key === cur, style: 'font-family: ' + f.stack }));
    }

    get fontSample() {
        return 'font-family: ' + fontStack(this.appearance.font);
    }

    get appearanceColors() {
        const labels = {
            question: this.i18n.builderAppearanceQuestion,
            section: this.i18n.builderAppearanceSection,
            accent: this.i18n.builderAppearanceAccent
        };
        return COLOR_KEYS.map((key) => {
            const value = this.appearance[key];
            const ratio = contrastOnWhite(value);
            return {
                key,
                label: labels[key],
                value,
                hexLabel: labels[key] + ' — ' + this.i18n.builderAppearanceHex,
                lowContrast: ratio < MIN_CONTRAST,
                warning: format(this.i18n.builderAppearanceLowContrast, ratio.toFixed(1))
            };
        });
    }

    get templateOptions() {
        return this.appearanceTemplates.map((t) => ({ ...t, selected: t.developerName === this.templatePick }));
    }

    get hasTemplates() {
        return this.appearanceTemplates.length > 0;
    }

    get templateActionDisabled() {
        return !this.templatePick || this.isSavingTemplate;
    }

    get templateDeleteDisabled() {
        return this.templateActionDisabled || this.lockBlocked;
    }

    get newFormDisabled() {
        return this.isPublishing || this.lockBlocked;
    }

    get templateSaveDisabled() {
        return !clean(this.templateName) || this.isSavingTemplate || this.lockBlocked;
    }

    get templateSaveLabel() {
        return this.isSavingTemplate ? this.i18n.builderTemplateSaving : this.i18n.builderTemplateSave;
    }

    handleToggleAppearance() {
        this.appearanceOpen = !this.appearanceOpen;
    }

    _setAppearance(next) {
        this.draft.appearance = { ...this.appearance, ...next };
        this._touch();
    }

    handleAppearanceFont(event) {
        this._setAppearance({ font: event.target.value });
    }

    // The color picker always gives a valid #rrggbb.
    handleAppearanceColor(event) {
        this._setAppearance({ [event.target.dataset.key]: event.target.value.toLowerCase() });
    }

    handleAppearanceHex(event) {
        const hex = cleanHex(event.target.value);
        if (!hex) {
            event.target.value = this.appearance[event.target.dataset.key];
            this._toast(this.i18n.builderAppearanceBadHex, '', 'warning');
            return;
        }
        this._setAppearance({ [event.target.dataset.key]: hex });
    }

    handleAppearanceReset() {
        this.draft.appearance = { ...APPEARANCE_DEFAULTS };
        this._touch();
    }

    async _loadTemplates() {
        try {
            this.appearanceTemplates = (await getAppearanceTemplates()) || [];
        } catch (e) {
            this.appearanceTemplates = [];
        }
        if (!this.appearanceTemplates.some((t) => t.developerName === this.templatePick)) this.templatePick = '';
    }

    handleTemplatePick(event) {
        this.templatePick = event.target.value;
    }

    // A copy: the form keeps these values even if the template changes or is deleted later.
    handleTemplateApply() {
        const t = this.appearanceTemplates.find((x) => x.developerName === this.templatePick);
        if (!t) return;
        this.draft.appearance = parseAppearance(t.appearanceJson);
        this._touch();
        this._toast(format(this.i18n.builderTemplateApplied, t.label), '', 'success');
    }

    async handleTemplateDelete() {
        const t = this.appearanceTemplates.find((x) => x.developerName === this.templatePick);
        if (!t) return;
        const ok = await DucConfirmModal.open({
            message: format(this.i18n.builderTemplateDeleteConfirm, t.label),
            headerless: true,
            label: this.i18n.builderTemplateDelete,
            okLabel: this.i18n.builderTemplateDelete,
            cancelLabel: this.i18n.btnCancel
        });
        if (!ok) return;
        this.isSavingTemplate = true;
        try {
            await this._pollDeploy(await this._enqueueLocked(t.label,
                () => enqueueDeleteAppearanceTemplate({ developerName: t.developerName })));
            this._refreshLock();
            this.templatePick = '';
            await this._loadTemplates();
            this._toast(this.i18n.builderTemplateDeleted, '', 'success');
        } catch (e) {
            this._toast(this.i18n.builderErrorTitle, this._msg(e), 'error');
        } finally {
            this.isSavingTemplate = false;
        }
    }

    handleTemplateName(event) {
        this.templateName = event.target.value;
    }

    async handleTemplateSave() {
        const name = clean(this.templateName);
        if (!name) return;
        if (this.appearanceIsDefault) {
            this._toast(this.i18n.builderTemplateDefaultNoSave, '', 'warning');
            return;
        }
        const existing = this.appearanceTemplates.find((t) => (t.label || '').toLowerCase() === name.toLowerCase());
        if (existing && !(await DucConfirmModal.open({
            message: format(this.i18n.builderTemplateOverwrite, existing.label),
            headerless: true,
            label: this.i18n.builderTemplateSave,
            okLabel: this.i18n.builderTemplateSave,
            cancelLabel: this.i18n.btnCancel
        }))) return;
        this.isSavingTemplate = true;
        try {
            await this._pollDeploy(await this._enqueueLocked(name, () => enqueueSaveAppearanceTemplate({
                label: name,
                appearanceJson: serializeAppearance(this.appearance)
            })));
            this._refreshLock();
            this.templateName = '';
            await this._loadTemplates();
            const saved = this.appearanceTemplates.find((t) => (t.label || '').toLowerCase() === name.toLowerCase());
            if (saved) this.templatePick = saved.developerName;
            this._toast(format(this.i18n.builderTemplateSaved, name), '', 'success');
        } catch (e) {
            this._toast(this.i18n.builderErrorTitle, this._msg(e), 'error');
        } finally {
            this.isSavingTemplate = false;
        }
    }

    // ── History tables (églises) ─────────────────────────────────────────────

    get activeTable() {
        if (!this.selT || this.selQ || this.selS || this.selB || this.selText || this.isAccessScreen) return null;
        return (this.draft.tables || []).find((t) => t.id === this.selT) || null;
    }

    get showTableProps() {
        return !this.appearanceOpen && !!this.activeTable;
    }

    _tableTitle(t) {
        return clean(t.titles[this.previewLang]) || t.objectLabel;
    }

    _colHeader(col) {
        const L = this.previewLang;
        const name = clean(col[L]) || col.label;
        return col.isDate ? name + (L === 'en' ? ' (dd/mm/yyyy)' : ' (jj/mm/aaaa)') : name;
    }

    // A table on the canvas: dragged, moved and removed like a question.
    _tableView(t) {
        const pub = (this.publishedSnapshot && this.publishedSnapshot.tables) || {};
        const cols = t.columns.filter((col) => col.on);
        const help = clean(t.help[this.previewLang]);
        return {
            id: t.id,
            isTable: true,
            isBlock: false,
            title: this._tableTitle(t),
            hasHelp: !!help,
            help,
            isHidden: t.isHidden,
            isNew: !(t.objectApiName in pub),
            incomplete: this.incompleteIds.has(t.id),
            headers: cols.map((col) => ({ key: col.f, label: this._colHeader(col) })),
            gridStyle: 'grid-template-columns: repeat(' + Math.max(cols.length, 1) + ', minmax(0, 1fr));',
            blanks: (t.inputMode === 'Fields' ? [1] : [1, 2]).map((n) => ({ key: 'r' + n, cells: cols.map((col) => ({ key: col.f })) })),
            // "Field by field" (and Both, which opens that way) looks like questions: label + box.
            isFieldsPreview: t.inputMode === 'Fields' || t.inputMode === 'Both',
            fields: cols.map((col) => ({
                key: col.f,
                label: clean(col[this.previewLang]) || col.label,
                htmlType: col.isDate ? 'date' : 'text',
                isCheckbox: col.type === 'BOOLEAN',
                isPicklist: col.type === 'PICKLIST'
            })),
            footer: format(this.i18n.builderTableFooter, t.objectLabel) + ' · ' + this._inputModeLabel(t.inputMode),
            className: 'dub-htable' + (this.activeTable && this.activeTable.id === t.id ? ' dub-is-selected' : '')
                + (this._drag && this._drag.type === 'move' && this._drag.id === t.id ? ' dub-is-dragging' : '')
        };
    }

    get selectedTable() {
        const t = this.activeTable;
        if (!t) return null;
        const last = t.columns.length - 1;
        return {
            titleFr: t.titles.fr,
            titleEn: t.titles.en,
            helpFr: t.help.fr,
            helpEn: t.help.en,
            shown: !t.isHidden,
            objectApiName: t.objectApiName,
            savedIn: format(this.i18n.builderTableSavedIn, t.objectLabel),
            inputModeOptions: ['Fields', 'Excel', 'Both'].map((value) => ({
                value,
                label: this._inputModeLabel(value),
                pressed: String((t.inputMode || 'Excel') === value)
            })),
            inputModeHint: this.i18n['builderTableMode' + (t.inputMode || 'Excel') + 'Hint'],
            columns: t.columns.map((col, i) => ({
                f: col.f,
                name: clean(col[this.previewLang]) || col.label,
                on: col.on,
                locked: col.locked,
                editing: col.editing,
                fr: col.fr,
                en: col.en,
                typeLabel: COLUMN_TYPE_LABELS[col.type] || col.type,
                isFirst: i === 0,
                isLast: i === last,
                className: 'dub-tcol' + (col.on ? '' : ' dub-tcol--off'),
                editPressed: String(col.editing === true),
                lockTitle: this.i18n.builderTableColLocked
            }))
        };
    }

    handleTableKey(event) {
        if (event.target !== event.currentTarget || (event.key !== 'Enter' && event.key !== ' ')) return;
        event.preventDefault();
        this.handleTableClick(event);
    }

    handleTableClick(event) {
        event.stopPropagation();
        this.selQ = null;
        this.selS = null;
        this.selT = event.currentTarget.dataset.t;
        this.selB = null;
        this.selText = null;
        this.appearanceOpen = false;
        this.textRange = null;
    }

    _placedTableIds() {
        const ids = new Set();
        this.draft.sections.forEach((s) => s.questions.forEach((it) => {
            if (it.kind === 'table') ids.add(it.id);
        }));
        return ids;
    }

    // Palette "+" or drop of a table: put it on the form (where dropped, else in the selected or
    // last section) and select it; one already on the form is just selected.
    _showTable(tableId, sectionId, index) {
        const t = (this.draft.tables || []).find((x) => x.id === tableId);
        if (!t) return;
        if (!this._findQ(t.id)) {
            const secs = this.draft.sections;
            let s = secs.find((x) => x.id === sectionId) || secs.find((x) => x.id === this.selS) || secs[secs.length - 1];
            if (!s) {
                s = { id: newId('s'), titles: this._newSectionTitles(), questions: [] };
                secs.push(s);
            }
            s.questions.splice(index === undefined ? s.questions.length : index, 0, t);
        }
        t.isHidden = false;
        this.selQ = null;
        this.selS = null;
        this.selT = t.id;
        this.selB = null;
        this.selText = null;
        this.appearanceOpen = false;
        this.textRange = null;
        this.screen = 'questions';
        this._touch();
    }

    handleTableRemove(event) {
        event.stopPropagation();
        this._removeTable(event.currentTarget.dataset.t);
    }

    _removeTable(tableId) {
        const hit = this._findQ(tableId);
        if (!hit) return;
        hit.s.questions.splice(hit.i, 1);
        hit.q.isHidden = true;
        if (this.selT === hit.q.id) this.selT = null;
        this._touch();
    }

    _inputModeLabel(mode) {
        return this.i18n['builderTableMode' + (mode || 'Excel')];
    }

    handleTableInputMode(event) {
        const t = this.activeTable;
        if (!t) return;
        t.inputMode = event.currentTarget.dataset.value;
        this._touch();
    }

    handleTableInput(event) {
        const t = this.activeTable;
        if (!t) return;
        const { prop, lang } = event.target.dataset;
        if (prop === 'title') t.titles[lang] = event.target.value;
        else if (prop === 'help') t.help[lang] = event.target.value;
    }

    _tableCol(event) {
        const t = this.activeTable;
        if (!t) return {};
        const f = event.currentTarget.dataset.f;
        const i = t.columns.findIndex((col) => col.f === f);
        return { t, i, col: t.columns[i] };
    }

    handleTableColToggle(event) {
        const { col } = this._tableCol(event);
        if (col && !col.locked) col.on = event.target.checked;
    }

    handleTableColEdit(event) {
        const { col } = this._tableCol(event);
        if (col) col.editing = !col.editing;
    }

    handleTableColLabel(event) {
        const { col } = this._tableCol(event);
        if (col) col[event.target.dataset.lang] = event.target.value;
    }

    handleTableColMove(event) {
        const { t, i } = this._tableCol(event);
        if (!t) return;
        const j = i + Number(event.currentTarget.dataset.dir);
        if (j < 0 || j >= t.columns.length) return;
        const cols = [...t.columns];
        [cols[i], cols[j]] = [cols[j], cols[i]];
        t.columns = cols;
    }

    get selectedText() {
        if (this.selText && this.selText.startsWith('b:')) {
            const blk = this._findB(this.selB);
            const cur = this.draft.texts[this.selText] || { fr: '', en: '' };
            return {
                name: blk ? this.i18n[BLOCK_LABEL_KEYS[blk.item.type]] : '',
                fr: cur.fr,
                en: cur.en,
                placeholderFr: '',
                placeholderEn: '',
                isBlock: true,
                maxLength: TEXT_MAX_LENGTH,
                rows: blk && blk.item.type === 'text' ? 5 : 2
            };
        }
        const def = TEXT_DEFS.find((d) => d.key === this.selText);
        if (!def) return null;
        const fr = getLabels('fr');
        const en = getLabels('en');
        const cur = this.draft.texts[def.key];
        return {
            name: this.i18n[def.nameKey],
            fr: cur.fr,
            en: cur.en,
            placeholderFr: fr[def.key],
            placeholderEn: en[def.key],
            isBlock: false,
            noStyle: !!def.noStyle,
            maxLength: def.long ? MESSAGE_MAX_LENGTH : 255,
            rows: def.long ? 4 : 2
        };
    }

    get selectedBlock() {
        const blk = this._findB(this.selB);
        if (!blk || TEXT_TYPES.includes(blk.item.type)) return null;
        const b = blk.item;
        const t = b.type;
        return {
            hint: BLOCK_HINT_KEYS[t] ? this.i18n[BLOCK_HINT_KEYS[t]] : '',
            isImage: IMAGE_TYPES.includes(t),
            hasImage: !!b.url,
            imageUrl: b.url,
            uploadLabel: b.url ? this.i18n.builderReplaceImage : this.i18n.builderUploadImage,
            altFr: b.altFr,
            altEn: b.altEn,
            showSize: t !== 'divider' && t !== 'video',
            sizes: ['S', 'M', 'L'].map((v) => ({ value: v, label: this.i18n['builderStyleSize' + v], pressed: String(b.size === v) })),
            showAlign: t === 'image' || t === 'logo',
            alignLeftPressed: String(b.align === 'left'),
            alignCenterPressed: String(b.align !== 'left'),
            isVideo: t === 'video',
            videoUrl: b.url,
            videoInvalid: !!clean(b.url) && !videoEmbedUrl(b.url),
            ...this._blockSizeAdvice(b)
        };
    }

    // Recommended upload size for the block's type and size, plus the uploaded picture's real
    // size (read when its preview loads) and a warning when it's too small to stay sharp.
    _blockSizeAdvice(b) {
        const L = this.i18n;
        const sizeLabel = L['builderStyleSize' + (b.size || 'M')];
        if (b.type === 'video') return { reco: L.builderRecoVideo };
        const r = BLOCK_RECOMMENDED[b.type] && BLOCK_RECOMMENDED[b.type][b.size || 'M'];
        if (!r) return {};
        const reco = b.type === 'banner' ? format(L.builderRecoBanner, r.w, r.h, sizeLabel)
            : b.type === 'logo' ? format(L.builderRecoLogo, r.h, sizeLabel)
                : format(L.builderRecoImage, r.w, sizeLabel);
        const dims = this.imageDims && this.imageDims.url === b.url ? this.imageDims : null;
        // 80 % of the recommendation still looks fine; below that it gets blurry.
        const tooSmall = !!dims && ((r.w && dims.w < r.w * 0.8) || (r.h && dims.h < r.h * 0.8));
        return {
            reco,
            recoWeight: L.builderRecoWeight,
            actualSize: dims ? format(L.builderImageActual, dims.w, dims.h) : '',
            tooSmall,
            tooSmallText: L.builderImageTooSmall
        };
    }

    handleImageLoad(event) {
        const img = event.currentTarget;
        this.imageDims = { url: img.getAttribute('src'), w: img.naturalWidth, h: img.naturalHeight };
    }

    get imageAccept() {
        return IMAGE_ACCEPT;
    }

    get blockUploadDisabled() {
        return this.isUploading;
    }

    handleBlockInput(event) {
        const blk = this._findB(this.selB);
        if (!blk) return;
        blk.item[event.target.dataset.prop] = event.target.value;
        this.incompleteIds.delete(blk.item.id);
        this._touch();
    }

    handleBlockSize(event) {
        const blk = this._findB(this.selB);
        if (!blk) return;
        blk.item.size = event.currentTarget.dataset.value;
        this._touch();
    }

    handleBlockAlign(event) {
        const blk = this._findB(this.selB);
        if (!blk) return;
        blk.item.align = event.currentTarget.dataset.value;
        this._touch();
    }

    handleImageRemove() {
        const blk = this._findB(this.selB);
        if (!blk) return;
        blk.item.url = '';
        this._touch();
    }

    // The uploaded file gets a public link (ContentDistribution) so the portal's guests can see it.
    async handleImageUploaded(event) {
        const blk = this._findB(this.selB);
        const files = (event.detail && event.detail.files) || [];
        if (!blk || !files.length) return;
        this.isUploading = true;
        try {
            blk.item.url = await publishBlockImage({ contentDocumentId: files[0].documentId });
            this.incompleteIds.delete(blk.item.id);
        } catch (e) {
            this._toast(this.i18n.builderErrorTitle, format(this.i18n.builderImageError, this._msg(e)), 'error');
        } finally {
            this.isUploading = false;
            this._touch();
        }
    }

    handleTextInput(event) {
        const lang = event.target.dataset.lang;
        const before = this.draft.texts[this.selText][lang] || '';
        const after = event.target.value;
        this.draft.texts[this.selText][lang] = after;
        if (this.selB) this.incompleteIds.delete(this.selB);
        const entry = this.draft.styles[this.selText];
        if (entry && entry.marks && entry.marks[lang]) entry.marks[lang] = shiftMarks(entry.marks[lang], before, after);
        this.textRange = null;
        this._touch();
    }

    handleTextReset() {
        this.draft.texts[this.selText] = { fr: '', en: '' };
        delete this.draft.styles[this.selText];
        this.textRange = null;
        this._touch();
    }

    // Remembers the words selected in a text box: the palette then styles only them.
    handleTextSelection(event) {
        const el = event.target;
        const start = el.selectionStart;
        const end = el.selectionEnd;
        const next = start < end ? { key: this.selText, lang: el.dataset.lang, start, end } : null;
        const cur = this.textRange;
        if (!next && !cur) return;
        if (next && cur && cur.key === next.key && cur.lang === next.lang && cur.start === next.start && cur.end === next.end) return;
        this.textRange = next;
    }

    get _range() {
        const r = this.textRange;
        if (!r || r.key !== this.selText) return null;
        const text = this.draft.texts[r.key][r.lang] || '';
        return r.end <= text.length ? r : null;
    }

    _styleEntry() {
        const key = this.selText;
        if (!this.draft.styles[key]) this.draft.styles[key] = {};
        const e = this.draft.styles[key];
        if (!e.style) e.style = {};
        if (!e.marks) e.marks = { fr: [], en: [] };
        if (!e.marks.fr) e.marks.fr = [];
        if (!e.marks.en) e.marks.en = [];
        return e;
    }

    // Current look under the selection (or of the whole text): drives the pressed buttons.
    get _currentStyle() {
        const entry = this.draft.styles[this.selText];
        const r = this._range;
        if (r) return styleAt(entry, r.lang, r.start);
        return (entry && entry.style) || {};
    }

    _applyStyle(patch) {
        const e = this._styleEntry();
        const r = this._range;
        if (r) e.marks[r.lang].push({ start: r.start, end: r.end, s: patch });
        else Object.assign(e.style, patch);
        this._touch();
    }

    // Palette buttons keep the focus (and the visible selection) in the text box.
    preventBlur(event) {
        event.preventDefault();
    }

    handleStyleToggle(event) {
        const prop = event.currentTarget.dataset.prop;
        this._applyStyle({ [prop]: this._currentStyle[prop] !== true });
    }

    handleStyleColor(event) {
        const v = event.currentTarget.dataset.value || null;
        this._applyStyle({ color: v });
    }

    handleStyleHighlight(event) {
        const v = event.currentTarget.dataset.value || null;
        this._applyStyle({ bg: v });
    }

    handleStyleSize(event) {
        this._styleEntry().style.size = event.currentTarget.dataset.value;
        this._touch();
    }

    handleStyleAlign(event) {
        this._styleEntry().style.align = event.currentTarget.dataset.value;
        this._touch();
    }

    handleStyleClear() {
        const r = this._range;
        if (r) {
            this._styleEntry().marks[r.lang].push({
                start: r.start, end: r.end, s: { b: false, i: false, u: false, color: null, bg: null }
            });
        } else {
            delete this.draft.styles[this.selText];
        }
        this._touch();
    }

    get textPalette() {
        if (!this.selText) return null;
        const cur = this._currentStyle;
        const block = (this.draft.styles[this.selText] && this.draft.styles[this.selText].style) || {};
        const r = this._range;
        const size = block.size || 'M';
        const align = block.align || 'left';
        const sw = (v, sel, base) => base + (sel ? ' dub-is-on' : '');
        return {
            boldPressed: String(cur.b === true),
            italicPressed: String(cur.i === true),
            underlinePressed: String(cur.u === true),
            tip: r
                ? format(this.i18n.builderStyleTipRange, this.draft.texts[r.key][r.lang].slice(r.start, r.end))
                : this.i18n.builderStyleTipAll,
            tipClass: 'dub-hint' + (r ? ' dub-hint--range' : ''),
            colors: TEXT_COLORS.map((c) => ({
                key: c.key,
                value: c.value || '',
                label: this.i18n[COLOR_LABEL_KEYS[c.key]],
                className: sw(c.value, (cur.color || null) === c.value, 'dub-swatch' + (c.value ? '' : ' dub-swatch--default')),
                style: c.value ? `background: ${c.value}` : ''
            })),
            highlights: HIGHLIGHTS.map((c) => ({
                key: c.key,
                value: c.value || '',
                label: this.i18n[HIGHLIGHT_LABEL_KEYS[c.key]],
                className: sw(c.value, (cur.bg || null) === c.value, 'dub-swatch' + (c.value ? '' : ' dub-swatch--none')),
                style: c.value ? `background: ${c.value}` : ''
            })),
            sizes: ['S', 'M', 'L'].map((v) => ({
                value: v,
                label: this.i18n['builderStyleSize' + v],
                pressed: String(size === v)
            })),
            alignLeftPressed: String(align === 'left'),
            alignCenterPressed: String(align === 'center')
        };
    }

    get selectedQuestion() {
        const hit = this.selQ ? this._findQ(this.selQ) : null;
        if (!hit) return null;
        const { q, s } = hit;
        const isNewRelated = q.kind === 'related' && !q.developerName;
        const fields = isNewRelated ? this.objectFieldsByObject[q.target.object] || [] : [];
        const none = { value: '', label: this.i18n.builderNone };
        const opts = (list, current) => list.map((f) => ({ value: f.apiName, label: `${f.label} (${f.apiName})`, selected: f.apiName === current }));
        const objLabel = this._objectLabel(q.target.object);
        const isField = q.kind === 'field';
        const keepHistory = isField && q.historyMode === 'Historize';
        const histFields = keepHistory && q.target.object ? this.objectFieldsByObject[q.target.object] || [] : [];
        const visibility = q.isHidden ? 'hidden' : q.isReadOnly ? 'ro' : 'edit';
        const visHint = { edit: 'builderVisEditHint', ro: 'builderVisReadOnlyHint', hidden: 'builderVisHiddenHint' }[visibility];
        const dateQuestions = this._flatQuestions()
            .filter(({ q: o }) => o.kind === 'field' && o.id !== q.id && o.inputType === 'Date' && o.key)
            .map(({ q: o }) => ({ key: o.key, label: clean(o.labels[this.previewLang]) || o.key }));
        const sourceQ = dateQuestions.find((d) => d.key === q.target.dateSource);
        const histMissing = keepHistory && (!q.target.value || !q.target.account);
        return {
            id: q.id,
            labelFr: q.labels.fr,
            labelEn: q.labels.en,
            helpFr: q.help.fr,
            helpEn: q.help.en,
            // Phone/Email get an automatic hint on the portal when Aide is blank — show it as the placeholder.
            helpPlaceholderFr: this._autoHelp(q.inputType, 'fr'),
            helpPlaceholderEn: this._autoHelp(q.inputType, 'en'),
            isRequired: q.isRequired,
            sameRowAsPrevious: q.sameRowAsPrevious,
            isHidden: q.isHidden === true,
            visibilityOptions: [
                { value: 'edit', label: this.i18n.builderVisEdit },
                { value: 'ro', label: this.i18n.builderVisReadOnly },
                { value: 'hidden', label: this.i18n.builderVisHidden }
            ].map((o) => ({ ...o, pressed: String(o.value === visibility) })),
            visibilityHint: this.i18n[visHint],
            showRequired: visibility === 'edit',
            canSameRow: s.questions.indexOf(q) > 0 && s.questions[s.questions.indexOf(q) - 1].kind !== 'block',
            typeOptions: INPUT_TYPES.map((t) => ({ value: t, label: this.i18n['builderType' + t], selected: t === q.inputType })),
            sectionOptions: this.draft.sections.map((x) => ({
                value: x.id,
                label: this._sectionName(x),
                selected: x.id === s.id
            })),
            isField,
            isRelated: q.kind === 'related',
            fieldApi: q.key,
            fieldHint: this.i18n.builderSavedFieldHint,
            keepHistory,
            historyObjectOptions: [
                { value: '', label: this.i18n.builderPickObject, selected: !q.target.object },
                ...this.relatedObjects.map((o) => ({ value: o.apiName, label: o.label, selected: o.apiName === q.target.object }))
            ],
            hasHistoryObject: keepHistory && !!q.target.object,
            rowDateOptions: [
                { value: '', label: this.i18n.builderRowDateApproved, selected: !q.target.dateSource },
                ...dateQuestions.map((d) => ({
                    value: d.key,
                    label: format(this.i18n.builderRowDateAnswer, d.label),
                    selected: d.key === q.target.dateSource
                }))
            ],
            historyExplain: keepHistory && q.target.object
                ? format(this.i18n.builderExplainHistorize, objLabel,
                    sourceQ ? format(this.i18n.builderExplainDateAnswer, sourceQ.label) : this.i18n.builderExplainDateApproved)
                : this.i18n.builderExplainReplace,
            showHistoryMapping: histMissing && histFields.length > 0,
            histValueOptions: [none, ...opts(histFields.filter((f) => !EXCLUDED_VALUE_TYPES.includes(f.type)), q.target.value)],
            histDateOptions: [none, ...opts(histFields.filter((f) => DATE_TYPES.includes(f.type)), q.target.date)],
            histAccountOptions: [none, ...opts(
                histFields.filter((f) => f.type === 'REFERENCE' && (f.referenceToApiNames || []).includes(this.info.targetObjectApiName)),
                q.target.account)],
            objLabel,
            hasDate: !!q.target.date,
            isNewRelated,
            showMappingNote: q.kind === 'related' && !!q.developerName,
            valueOptions: [none, ...opts(fields.filter((f) => !EXCLUDED_VALUE_TYPES.includes(f.type)), q.target.value)],
            dateOptions: [none, ...opts(fields.filter((f) => DATE_TYPES.includes(f.type)), q.target.date)],
            accountOptions: [none, ...opts(
                fields.filter((f) => f.type === 'REFERENCE' && (f.referenceToApiNames || []).includes(this.info.targetObjectApiName)),
                q.target.account)],
            logOptions: [none, ...opts(
                fields.filter((f) => f.type === 'REFERENCE' && (f.referenceToApiNames || []).includes(LOG_OBJECT)),
                q.target.log)]
        };
    }

    handleToggleHidden(event) {
        event.stopPropagation();
        const hit = this._findQ(event.currentTarget.dataset.q);
        if (!hit) return;
        hit.q.isHidden = !hit.q.isHidden;
        this._touch();
    }

    handleQuestionInput(event) {
        const hit = this._findQ(this.selQ);
        if (!hit) return;
        const { q } = hit;
        const { prop, lang } = event.target.dataset;
        if (prop === 'label') q.labels[lang] = event.target.value;
        else if (prop === 'help') q.help[lang] = event.target.value;
        else if (prop === 'type') q.inputType = event.target.value;
        else if (prop === 'required') q.isRequired = event.target.checked;
        else if (prop === 'sameRow') q.sameRowAsPrevious = event.target.checked;
        else if (prop === 'section') {
            const dest = this.draft.sections.find((x) => x.id === event.target.value);
            if (dest && dest !== hit.s) {
                this._moveQuestion(q.id, dest.id, dest.questions.length);
                this.selS = dest.id;
            }
            return;
        }
        if (this.incompleteIds.has(q.id)) this.incompleteIds.delete(q.id);
        this._touch();
    }

    handleTargetInput(event) {
        const hit = this._findQ(this.selQ);
        if (!hit) return;
        const { q } = hit;
        const part = event.target.dataset.part;
        q.target[part] = event.target.value;
        if (part === 'value' && q.kind === 'related') {
            q.key = q.target.value ? `${q.target.object}.${q.target.value}` : '';
            const f = (this.objectFieldsByObject[q.target.object] || []).find((x) => x.apiName === q.target.value);
            if (f) q.inputType = inputTypeForSchemaType(f.type);
        }
        this._touch();
    }

    handleVisibility(event) {
        const hit = this._findQ(this.selQ);
        if (!hit) return;
        const v = event.currentTarget.dataset.value;
        hit.q.isHidden = v === 'hidden';
        hit.q.isReadOnly = v === 'ro';
        this._touch();
    }

    handleKeepHistory(event) {
        const hit = this._findQ(this.selQ);
        if (!hit || hit.q.kind !== 'field') return;
        const { q } = hit;
        q.historyMode = event.target.checked ? 'Historize' : 'Replace';
        if (q.historyMode === 'Historize' && !q.target.object && this.relatedObjects.length === 1) {
            q.target.object = this.relatedObjects[0].apiName;
        }
        if (q.historyMode === 'Historize' && q.target.object) this._loadObjectFields(q);
        if (this.incompleteIds.has(q.id)) this.incompleteIds.delete(q.id);
        this._touch();
    }

    handleHistoryObject(event) {
        const hit = this._findQ(this.selQ);
        if (!hit) return;
        const { q } = hit;
        q.target = { object: event.target.value, value: '', date: '', account: '', log: '', dateSource: q.target.dateSource };
        if (q.target.object) this._loadObjectFields(q);
        this._touch();
    }

    handleRowDate(event) {
        const hit = this._findQ(this.selQ);
        if (!hit) return;
        hit.q.target.dateSource = event.target.value;
        this._touch();
    }

    get selectedSection() {
        const s = this.draft.sections.find((x) => x.id === this.selS);
        if (!s) return null;
        return {
            id: s.id,
            titleFr: s.titles.fr,
            titleEn: s.titles.en,
            countText: format(this.i18n.builderSectionCount, s.questions.filter((q) => q.kind !== 'block').length)
        };
    }

    handleSectionInput(event) {
        const s = this.draft.sections.find((x) => x.id === this.selS);
        if (!s) return;
        s.titles[event.target.dataset.lang] = event.target.value;
        this._touch();
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    // The draft is mutated in place; reassigning it makes every getter re-render.
    _touch() {
        this.draft = { ...this.draft };
    }

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    _msg(e) {
        if (!e) return '';
        if (e.body && e.body.message) return e.body.message;
        return e.message || String(e);
    }
}
