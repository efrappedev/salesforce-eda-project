import { LightningElement, api, track, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import { getLabels, getIdentity2Labels, format } from 'c/dataUpdateI18n';
import { parseStyles, buildRuns, blockStyle } from 'c/dataUpdateTextStyle';
import { parseBlocks, placeBlocks, sectionAnchor, questionAnchor, LOGIN_ANCHORS, MESSAGE_SCREENS } from 'c/dataUpdateBlocks';
import { parseAppearance, appearanceStyle } from 'c/dataUpdateAppearance';
import {
    isPostalCodeField, countryFieldFor, isCountryField, postalFieldFor, formatPostalCode, isInvalidPostalCode
} from 'c/dataUpdatePostalCode';
import getFormDefinitionApex from '@salesforce/apex/DataUpdatePortalController.getFormDefinition';
import lookupRecordApex from '@salesforce/apex/DataUpdatePortalController.lookupRecord';
import submitUpdateApex from '@salesforce/apex/DataUpdatePortalController.submitUpdate';
import getRecaptchaSiteKeyApex from '@salesforce/apex/DataUpdatePortalController.getRecaptchaSiteKey';
import RECAPTCHA_FRAME_RESOURCE from '@salesforce/resourceUrl/DataUpdateRecaptchaFrame';

const LANG_KEY = 'dataUpdatePortal_lang';
const EMAIL_REGEX = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
// Digits with the usual separators; 7 to 15 digits (local number up to international).
const PHONE_CHARS_REGEX = /^\+?[\d\s().-]+$/;
// Browser autofill hints for well-known fields, so visitors can fill their details in one tap.
const AUTOCOMPLETE = [
    [/(^|_)firstname$/i, 'given-name'], [/(^|_)lastname$/i, 'family-name'],
    [/street$/i, 'street-address'], [/city$/i, 'address-level2'], [/state(code)?$/i, 'address-level1'],
    [/postalcode$/i, 'postal-code'], [/country(code)?$/i, 'country-name'],
    [/mobilephone$/i, 'tel'], [/homephone$/i, 'tel'], [/birthdate$/i, 'bday']
];
function autocompleteFor(apiName, inputType) {
    const name = String(apiName || '').replace(/__c$/i, '');
    const hit = AUTOCOMPLETE.find(([re]) => re.test(name));
    if (hit) return hit[1];
    if (inputType === 'Email') return 'email';
    if (inputType === 'Phone') return 'tel';
    return 'off';
}

const TEXT_KEYS = ['lookupTitle', 'lookupSubtitle', 'idHelp', 'formTitle', 'formSubtitle'];
// Message texts customised in the builder's Messages screen (Portal_Messages__c).
const MESSAGE_KEYS = ['lockedTitle', 'lockedMessage', 'pendingTitle', 'pendingMessage', 'confirmTitle', 'confirmMessage'];
// Fallback used when the page is opened without a "?form=" query param
// (e.g. the site's plain Home URL). Override per-link with "?form=<DeveloperName>".
const DEFAULT_FORM_DEVELOPER_NAME = 'AEBEQ_Account_Update';

export default class RequestUpdateForm extends LightningElement {
    // Set in Experience Builder to pin this page to one form, bypassing the "?form=" URL
    // query param — lets a form get its own dedicated page (e.g. a separate "/eglise-update"
    // page) instead of sharing the Account Update page's URL with a query param appended.
    @api formNameOverride = '';

    @track lang = 'fr';
    @track step = 'loading'; // loading | configError | lookup | pending | locked | form | confirmation
    @track isBusy = false;
    @track lookupErrorMessage = '';
    @track submitErrorMessage = '';
    @track fieldErrors = {};

    @track identity1 = '';
    @track identity2 = '';
    @track formValues = {};
    @track readOnlyValues = {};
    @track recaptchaSiteKey = '';
    @track recaptchaToken = '';
    @track recaptchaChallengeShown = false;

    formDeveloperName = '';
    fieldDefs = [];
    // History tables (églises): one paste grid per related history object.
    tables = [];
    // key → { values, lineCount, errorCount } reported by each c-data-update-history-table.
    @track tableStates = {};
    requiresIdentityField2 = false;
    identityField2ApiName = '';
    lookupPass = '';
    portalTexts = null;
    textStyles = {};
    // Design blocks (banner, image, text…) added in the builder's Tools tab.
    blocks = [];
    recaptchaResetNonce = 0;
    _pageRefApplied = false;

    @wire(CurrentPageReference)
    setPageRef(pageRef) {
        if (this._pageRefApplied || !pageRef || !pageRef.state) return;
        this._pageRefApplied = true;
        // An explicit ?form= wins over the site's default form (majeglise is set to Église Update).
        this.formDeveloperName = pageRef.state.form || this.formNameOverride || DEFAULT_FORM_DEVELOPER_NAME;
        this.identity1 = pageRef.state.id || '';
        this._loadFormDefinition();
    }

    async connectedCallback() {
        const saved = localStorage.getItem(LANG_KEY);
        if (saved === 'fr' || saved === 'en') {
            this.lang = saved;
        }
        try {
            this.recaptchaSiteKey = (await getRecaptchaSiteKeyApex()) || '';
        } catch (e) {
            this.recaptchaSiteKey = '';
        }
        window.addEventListener('message', this._handleRecaptchaMessage);
    }

    disconnectedCallback() {
        window.removeEventListener('message', this._handleRecaptchaMessage);
    }

    // The site page is called "Home": the browser tab shows the form's own title instead.
    _syncDocumentTitle() {
        const t = this.portalTexts || {};
        const m = this._messages.lookupTitle;
        const title = (m ? this._localizedLabel(m.fr, m.en) : this._localizedLabel(t.lookupTitleFr, t.lookupTitleEn))
            || this.i18n.lookupTitle;
        const plain = String(title || '').replace(/\s+/g, ' ').trim();
        if (plain && document.title !== plain) document.title = plain;
    }

    // ── reCAPTCHA v2 (checkbox) ─────────────────────────────────────────────
    // Lightning Web Security blocks LWC from injecting remote <script> tags
    // into <head> ("Cannot prepend META to HEAD"), so the widget can't be
    // rendered directly here. A Visualforce page was tried, but this LWR site
    // has no way to register one as a site page and a raw *.vf.force.com URL
    // returns "Invalid Page" for the site's Guest user. It's hosted as a
    // Static Resource instead — force-app/main/default/staticresources/
    // DataUpdateRecaptchaFrame.html — served same-origin as the site, embedded
    // via <iframe>, and the token is relayed back with postMessage. The token
    // carries no trust on its own; it's only meaningful once
    // DataUpdateReCaptchaService.verifyToken() checks it server-side against
    // Google, so no origin allowlisting is needed on the receiving end here.

    _handleRecaptchaMessage = (event) => {
        const data = event.data;
        if (!data || data.source !== 'dataUpdateRecaptchaFrame') return;
        if (data.type === 'token') {
            this.recaptchaToken = data.token || '';
        } else if (data.type === 'expired') {
            this.recaptchaToken = '';
        } else if (data.type === 'challengeShown') {
            this.recaptchaChallengeShown = true;
        } else if (data.type === 'challengeHidden') {
            this.recaptchaChallengeShown = false;
        }
    };

    get recaptchaFrameUrl() {
        // hl = widget language; switching FR/EN reloads the frame (a new checkbox in that language).
        return RECAPTCHA_FRAME_RESOURCE + '?k=' + encodeURIComponent(this.recaptchaSiteKey) +
            '&hl=' + (this.lang === 'en' ? 'en' : 'fr') + '&r=' + this.recaptchaResetNonce;
    }

    get recaptchaIframeClass() {
        return 'tuf-recaptcha-iframe' + (this.recaptchaChallengeShown ? ' tuf-recaptcha-iframe_expanded' : '');
    }

    _resetRecaptcha() {
        this.recaptchaToken = '';
        this.recaptchaChallengeShown = false;
        this.recaptchaResetNonce += 1;
    }

    get i18n() { return getLabels(this.lang); }

    // Screen texts the admin customised in the form builder; blank ones keep the standard text.
    // Each text comes as styled runs (bold, colour… set with the builder's text palette); word
    // ranges only apply to the custom text they were set on.
    // The form's uniform font + colors, as CSS variables for this container and the tables inside.
    get appearanceStyle() {
        return appearanceStyle(parseAppearance(this.portalTexts && this.portalTexts.appearanceJson));
    }

    get screenText() {
        const t = this.portalTexts || {};
        const i18n = this.i18n;
        const messages = this._messages;
        const out = {};
        [...TEXT_KEYS, ...MESSAGE_KEYS].forEach((key) => {
            const m = messages[key];
            const custom = m ? this._localizedLabel(m.fr, m.en) : this._localizedLabel(t[key + 'Fr'], t[key + 'En']);
            const entry = this.textStyles[key];
            out[key] = {
                runs: buildRuns(custom || i18n[key], entry, this.lang, !!custom),
                style: blockStyle(entry)
            };
        });
        return out;
    }

    // { key: { fr, en } } from Portal_Messages__c; a bad value keeps the standard messages.
    get _messages() {
        try {
            const m = JSON.parse((this.portalTexts && this.portalTexts.messagesJson) || '{}');
            return m && typeof m === 'object' && !Array.isArray(m) ? m : {};
        } catch (e) {
            return {};
        }
    }

    // Church forms (second identity = NEQ) take a church ID (EGL…), not a person ID.
    get idPlaceholder() {
        return this.identityField2ApiName === 'Enregistrement_provincial_etatique__c'
            ? this.i18n.idPlaceholderChurch : this.i18n.idPlaceholder;
    }

    get identity2Label() { return getIdentity2Labels(this.lang, this.identityField2ApiName).label; }
    get identity2Placeholder() { return getIdentity2Labels(this.lang, this.identityField2ApiName).placeholder; }

    get isLoadingStep() { return this.step === 'loading'; }
    get isConfigErrorStep() { return this.step === 'configError'; }
    get isLookupStep() { return this.step === 'lookup'; }
    get isPendingStep() { return this.step === 'pending'; }
    get isLockedStep() { return this.step === 'locked'; }
    get isFormStep() { return this.step === 'form'; }
    get isConfirmationStep() { return this.step === 'confirmation'; }

    get langFrClass() { return 'tuf-lang-btn' + (this.lang === 'fr' ? ' tuf-lang-btn_active' : ''); }
    get langEnClass() { return 'tuf-lang-btn' + (this.lang === 'en' ? ' tuf-lang-btn_active' : ''); }

    get isContinueDisabled() {
        return this.isBusy || !this.identity1 || (this.requiresIdentityField2 && !this.identity2) ||
            (this.recaptchaSiteKey && !this.recaptchaToken);
    }

    // Says what is still missing while "Continue" is disabled (a greyed button alone explains nothing).
    get continueHint() {
        if (this.isBusy) return '';
        if (!this.identity1) return format(this.i18n.hintNeedId, this.i18n.idLabel.toLowerCase());
        if (this.requiresIdentityField2 && !this.identity2) {
            return format(this.i18n.hintNeedId, (this.identity2Label || '').toLowerCase());
        }
        if (this.recaptchaSiteKey && !this.recaptchaToken) return this.i18n.hintNeedCaptcha;
        return '';
    }

    get isSubmitDisabled() {
        return this.isBusy;
    }

    // Login-screen blocks, grouped by the fixed item they follow.
    get loginBlocks() {
        const placed = placeBlocks(this.blocks.filter((b) => b.screen === 'login'), LOGIN_ANCHORS, true);
        const out = {};
        LOGIN_ANCHORS.forEach((a) => { out[a.slice(1)] = placed.get(a) || []; });
        return out;
    }

    // Message-screen blocks (locked / pending / confirm), grouped by the fixed item they follow.
    get messageBlocks() {
        const out = {};
        Object.keys(MESSAGE_SCREENS).forEach((screen) => {
            const anchors = MESSAGE_SCREENS[screen];
            const placed = placeBlocks(this.blocks.filter((b) => b.screen === screen), anchors, true);
            out[screen] = {};
            anchors.forEach((a) => { out[screen][a.slice(1)] = placed.get(a) || []; });
        });
        return out;
    }

    // Form-screen blocks before / around the title and subtitle; section blocks are in "sections".
    get formHeadBlocks() {
        const placed = this._formPlaced;
        return {
            formStart: placed.get('@formStart') || [],
            formTitle: placed.get('@formTitle') || [],
            formSubtitle: placed.get('@formSubtitle') || []
        };
    }

    // Anchors of the form screen in display order: fixed texts, then each section and its
    // visible questions — the same keys the builder writes in each block's "after".
    get _formPlaced() {
        const bySection = new Map();
        this._formItems.forEach(({ fd, tbl }) => {
            const src = fd || tbl;
            const sa = sectionAnchor(src.sectionLabelFr, src.sectionLabelEn);
            if (!bySection.has(sa)) bySection.set(sa, []);
            bySection.get(sa).push(questionAnchor(fd ? fd.fieldApiName : tbl.key));
        });
        const ordered = ['@formStart', '@formTitle', '@formSubtitle'];
        bySection.forEach((questions, sa) => ordered.push(sa, ...questions));
        return placeBlocks(this.blocks.filter((b) => b.screen === 'form'), ordered, true);
    }

    // Questions and history tables in display order: a table sits in its section like a question.
    get _formItems() {
        const items = [
            ...this.fieldDefs.map((fd, i) => ({ fd, order: fd.displayOrder, i })),
            ...this.tables.map((tbl, i) => ({ tbl, order: tbl.displayOrder, i: this.fieldDefs.length + i }))
        ];
        const rank = (x) => (x.order === null || x.order === undefined ? Number.MAX_SAFE_INTEGER : x.order);
        return items.sort((a, b) => rank(a) - rank(b) || a.i - b.i);
    }

    get hasRequiredMark() {
        return this.sections.some((s) => (s.rows || []).some((r) => (r.fields || []).some((fl) => fl.showRequiredMark)));
    }

    get sections() {
        const ro = this.readOnlyValues || {};
        const placed = this._formPlaced;
        const bySection = new Map();
        const pushBlocks = (items, anchor) => (placed.get(anchor) || []).forEach((b) => {
            items.push({ key: 'b:' + b.id, isBlock: true, block: b, fields: [], rowClass: 'tuf-block-row' });
        });
        this._formItems.forEach(({ fd, tbl }) => {
            const src = fd || tbl;
            // Grouped by the FR|EN pair (the block anchor), not the shown label: two sections
            // sharing a title in one language stay separate and keep their own blocks.
            const sectionKey = sectionAnchor(src.sectionLabelFr, src.sectionLabelEn);
            if (!bySection.has(sectionKey)) {
                const label = this._localizedLabel(src.sectionLabelFr, src.sectionLabelEn) || '';
                const section = { key: sectionKey, label, rows: [] };
                pushBlocks(section.rows, sectionKey);
                bySection.set(sectionKey, section);
            }
            if (tbl) {
                // The same table object every render, so the grid keeps what was pasted.
                bySection.get(sectionKey).rows.push({ key: 't:' + tbl.key, isTable: true, table: tbl, fields: [], rowClass: 'tuf-table-row' });
                pushBlocks(bySection.get(sectionKey).rows, questionAnchor(tbl.key));
                return;
            }
            const isReadOnly = fd.isReadOnly === true;
            const isCheckbox = !isReadOnly && fd.inputType === 'Checkbox';
            const isPicklist = !isReadOnly && fd.inputType === 'Picklist';
            const currentValue = this.formValues[fd.fieldApiName] || '';
            const roRaw = ro[fd.fieldApiName] || '';
            const roOption = fd.inputType === 'Picklist' ? (fd.picklistOptions || []).find((o) => o.value === roRaw) : null;
            const fieldVm = {
                ...fd,
                label: this._localizedLabel(fd.labelFr, fd.labelEn),
                isCheckbox,
                isPicklist,
                isPlainInput: !isReadOnly && !isCheckbox && !isPicklist,
                // "Only see" questions: the current record value, shown but never sent.
                isReadOnly,
                isReadOnlyCheckbox: isReadOnly && fd.inputType === 'Checkbox',
                isReadOnlyText: isReadOnly && fd.inputType !== 'Checkbox',
                readOnlyChecked: roRaw === 'true',
                readOnlyValue: roOption ? roOption.label : roRaw,
                readOnlyInputType: fd.inputType === 'Date' ? 'date' : 'text',
                checked: isCheckbox ? this.formValues[fd.fieldApiName] === true : false,
                value: isCheckbox ? '' : currentValue,
                // <select> has no declarative "value" binding in LWC templates — each
                // <option> carries its own "selected" flag instead.
                picklistOptions: isPicklist
                    ? (fd.picklistOptions || []).map((opt) => ({ ...opt, selected: opt.value === currentValue }))
                    : [],
                error: this.fieldErrors[fd.fieldApiName] || '',
                ariaInvalid: this.fieldErrors[fd.fieldApiName] ? 'true' : 'false',
                showRequiredMark: !isReadOnly && fd.isRequired === true,
                inputType: this._htmlInputType(fd.inputType),
                autocomplete: autocompleteFor(fd.fieldApiName, fd.inputType),
                helpText: this._localizedLabel(fd.helpFr, fd.helpEn) || this._helpTextFor(fd.inputType),
                isBusy: this.isBusy,
                // History-only fields with a mapped date column: optional "as of" date,
                // the submission date is used when left blank.
                hasHistoryDate: !isReadOnly && !!fd.historyDateKey,
                historyDateId: fd.historyDateKey ? `${fd.fieldApiName}-date` : null,
                historyDateValue: fd.historyDateKey ? this.formValues[fd.historyDateKey] || '' : ''
            };

            // Same_Row_As_Previous__c is a pure layout hint: pair this field with the previous
            // one in the same section's current row, unless that row is already full (2 fields).
            // A design block between two questions breaks the pairing.
            const rows = bySection.get(sectionKey).rows;
            const lastRow = rows[rows.length - 1];
            if (fd.sameRowAsPrevious && lastRow && !lastRow.isBlock && !lastRow.isTable && lastRow.fields.length === 1) {
                lastRow.fields.push(fieldVm);
                lastRow.rowClass = 'tuf-field-row tuf-field-row_paired';
            } else {
                rows.push({ key: fd.fieldApiName, fields: [fieldVm], rowClass: 'tuf-field-row' });
            }
            pushBlocks(rows, questionAnchor(fd.fieldApiName));
        });
        return Array.from(bySection.values());
    }

    _localizedLabel(fr, en) {
        if (this.lang === 'en') return en;
        return fr;
    }

    _htmlInputType(inputType) {
        switch (inputType) {
            case 'Email': return 'email';
            case 'Phone': return 'tel';
            case 'Date': return 'date';
            case 'Number': return 'number';
            case 'Checkbox': return 'checkbox';
            default: return 'text';
        }
    }

    _emptyValueFor(inputType) {
        return inputType === 'Checkbox' ? false : '';
    }

    _buildEmptyFormValues() {
        const values = {};
        this.fieldDefs.forEach((fd) => {
            values[fd.fieldApiName] = this._emptyValueFor(fd.inputType);
            if (fd.historyDateKey) values[fd.historyDateKey] = '';
        });
        return values;
    }

    _helpTextFor(inputType) {
        switch (inputType) {
            case 'Phone': return this.i18n.phoneHelp;
            case 'Email': return this.i18n.emailHelp;
            default: return '';
        }
    }

    async _loadFormDefinition() {
        this.step = 'loading';
        try {
            const def = await getFormDefinitionApex({ formName: this.formDeveloperName });
            if (!def.success) {
                this.step = 'configError';
                return;
            }
            this.fieldDefs = def.fields;
            this.tables = def.tables || [];
            this.requiresIdentityField2 = def.requiresIdentityField2;
            this.identityField2ApiName = def.identityField2ApiName || '';
            this.portalTexts = def.portalTexts || null;
            this.textStyles = parseStyles(this.portalTexts && this.portalTexts.stylesJson, [...TEXT_KEYS, ...MESSAGE_KEYS]);
            this.blocks = parseBlocks(this.portalTexts && this.portalTexts.blocksJson);
            this.formValues = this._buildEmptyFormValues();
            this.step = 'lookup';
        } catch (e) {
            this.step = 'configError';
        }
    }

    // ── Language ─────────────────────────────────────────────────────────────

    handleLangChange(event) {
        const newLang = event.currentTarget.dataset.lang;
        if (newLang && newLang !== this.lang) {
            this.lang = newLang;
            localStorage.setItem(LANG_KEY, newLang);
            // The reCAPTCHA frame reloads in the new language, so its earlier answer is gone.
            this.recaptchaToken = '';
            this.recaptchaChallengeShown = false;
        }
    }

    // ── Lookup step ──────────────────────────────────────────────────────────

    handleIdentity1Change(event) {
        this.identity1 = event.target.value;
    }

    handleIdentity2Change(event) {
        this.identity2 = event.target.value;
    }

    async handleContinue() {
        if (this.isContinueDisabled) return;
        this.isBusy = true;
        this.lookupErrorMessage = '';
        try {
            const result = await lookupRecordApex({
                formName: this.formDeveloperName,
                identity1: this.identity1,
                identity2: this.identity2,
                recaptchaToken: this.recaptchaToken
            });
            if (result.isLocked) {
                this.step = 'locked';
            } else if (result.alreadyPending) {
                this.step = 'pending';
            } else if (result.success) {
                this.lookupPass = result.lookupPass || '';
                this.formValues = this._buildEmptyFormValues();
                this.readOnlyValues = this._parseReadOnly(result.readOnlyValuesJson);
                this._startCheckboxesFromRecord();
                this.step = 'form';
            } else if (result.errorMessage === 'INVALID_CAPTCHA') {
                this.lookupErrorMessage = this.i18n.errCaptchaInvalid;
            } else {
                this.lookupErrorMessage = this.i18n.errLookupNotFound;
            }
        } catch (e) {
            this.lookupErrorMessage = this.i18n.errLookupGeneric;
        } finally {
            this.isBusy = false;
            this._resetRecaptcha();
        }
    }

    // Editable checkboxes start in the record's real state (sent with the read-only values),
    // so the visitor can uncheck one; only a box they actually changed is proposed.
    _startCheckboxesFromRecord() {
        const ro = this.readOnlyValues || {};
        const originals = {};
        const values = { ...this.formValues };
        this.fieldDefs.forEach((fd) => {
            if (fd.isReadOnly === true || fd.inputType !== 'Checkbox') return;
            originals[fd.fieldApiName] = ro[fd.fieldApiName] === 'true';
            values[fd.fieldApiName] = originals[fd.fieldApiName];
        });
        this._checkboxOriginals = originals;
        this.formValues = values;
    }

    _parseReadOnly(json) {
        if (!json) return {};
        try {
            const parsed = JSON.parse(json);
            return parsed && typeof parsed === 'object' ? parsed : {};
        } catch (e) {
            return {};
        }
    }

    // ── Form step ────────────────────────────────────────────────────────────

    handleFieldChange(event) {
        const field = event.currentTarget.dataset.field;
        let newValue = event.target.type === 'checkbox' ? event.target.checked : event.target.value;
        const updates = {};

        // Canadian postal codes are formatted silently as the user types ("h2x1y3" → "H2X 1Y3").
        if (isPostalCodeField(field)) {
            newValue = formatPostalCode(newValue, this.formValues[countryFieldFor(field)]);
            // Written straight to the input: when formatting drops a keystroke the tracked
            // value doesn't change, so no re-render would clear it from the field.
            if (event.target.value !== newValue) event.target.value = newValue;
        } else if (event.type === 'change' && event.target.type === 'email' && newValue) {
            // Emails in lowercase when leaving the field ("Info@Church.CA" → "info@church.ca").
            newValue = newValue.toLowerCase();
            if (event.target.value !== newValue) event.target.value = newValue;
        } else if (isCountryField(field)) {
            // Country typed after the postal code → reformat the postal code of the same address.
            const postalField = postalFieldFor(field);
            if (this.formValues[postalField]) {
                updates[postalField] = formatPostalCode(this.formValues[postalField], newValue);
            }
        }
        this.formValues = { ...this.formValues, ...updates, [field]: newValue };
        // Fixing a field clears its red message right away.
        if (this.fieldErrors[field]) {
            const errors = { ...this.fieldErrors };
            delete errors[field];
            this.fieldErrors = errors;
            if (!Object.keys(errors).length && this.submitErrorMessage === this.i18n.errFixFields) this.submitErrorMessage = '';
        }
    }

    handleFormBack() {
        this.step = 'lookup';
        this.readOnlyValues = {};
        this.submitErrorMessage = '';
        this.fieldErrors = {};
        this.lookupPass = '';
        this.tableStates = {};
        this._resetRecaptcha();
    }

    handleTableChange(event) {
        const { key, values, lineCount, errorCount } = event.detail;
        this.tableStates = { ...this.tableStates, [key]: { values, lineCount, errorCount } };
        if (this.submitErrorMessage === this.i18n.errTableFix) this.submitErrorMessage = '';
    }

    _tablesHaveErrors() {
        return Object.values(this.tableStates).some((t) => t.errorCount > 0);
    }

    _validateForm() {
        const errors = {};
        this.fieldDefs.forEach((fd) => {
            if (fd.isReadOnly === true) return;
            if (fd.inputType === 'Checkbox') {
                if (fd.isRequired && this.formValues[fd.fieldApiName] !== true) {
                    errors[fd.fieldApiName] = this.i18n.required;
                }
                return;
            }
            const val = (this.formValues[fd.fieldApiName] || '').trim();
            if (fd.isRequired && !val) {
                errors[fd.fieldApiName] = this.i18n.required;
            } else if (fd.inputType === 'Email' && val && !EMAIL_REGEX.test(val)) {
                errors[fd.fieldApiName] = this.i18n.errInvalidEmail;
            } else if (fd.inputType === 'Phone' && val && !isValidPhone(val)) {
                errors[fd.fieldApiName] = this.i18n.errInvalidPhone;
            } else if (isPostalCodeField(fd.fieldApiName)
                && isInvalidPostalCode(val, this.formValues[countryFieldFor(fd.fieldApiName)])) {
                errors[fd.fieldApiName] = this.i18n.errInvalidPostalCode;
            }
        });
        this.fieldErrors = errors;
        return Object.keys(errors).length === 0;
    }

    _hasChanges() {
        return Object.keys(this._buildProposedValues()).length > 0;
    }

    _buildProposedValues() {
        const proposed = {};
        this.fieldDefs.forEach((fd) => {
            if (fd.isReadOnly === true) return;
            if (fd.inputType === 'Checkbox') {
                const isChecked = this.formValues[fd.fieldApiName] === true;
                const wasChecked = (this._checkboxOriginals || {})[fd.fieldApiName] === true;
                if (isChecked !== wasChecked) {
                    proposed[fd.fieldApiName] = isChecked ? 'true' : 'false';
                }
                return;
            }
            let val = (this.formValues[fd.fieldApiName] || '').trim();
            if (fd.inputType === 'Email') val = val.toLowerCase();
            if (val) {
                proposed[fd.fieldApiName] = val;
                const dateVal = fd.historyDateKey ? (this.formValues[fd.historyDateKey] || '').trim() : '';
                if (dateVal) proposed[fd.historyDateKey] = dateVal;
            }
        });
        Object.keys(this.tableStates).forEach((key) => {
            const t = this.tableStates[key];
            if (t.values && t.values.length) proposed[key] = t.values;
        });
        return proposed;
    }

    async handleSubmit() {
        if (this.isSubmitDisabled) return;
        this.submitErrorMessage = '';

        if (!this._validateForm()) {
            this.submitErrorMessage = this.i18n.errFixFields;
            this._revealError();
            return;
        }
        if (this._tablesHaveErrors()) {
            this.submitErrorMessage = this.i18n.errTableFix;
            this._revealError();
            return;
        }
        if (!this._hasChanges()) {
            const m = this._messages.errNoChanges;
            this.submitErrorMessage = (m && this._localizedLabel(m.fr, m.en)) || this.i18n.errNoChanges;
            this._revealError();
            return;
        }

        this.isBusy = true;
        try {
            const result = await submitUpdateApex({
                formName: this.formDeveloperName,
                identity1: this.identity1,
                identity2: this.identity2,
                proposedValuesJson: JSON.stringify(this._buildProposedValues()),
                lookupPass: this.lookupPass
            });
            if (result.success) {
                this.step = 'confirmation';
            } else if (result.isLocked) {
                this.step = 'locked';
            } else if (result.alreadyPending) {
                this.submitErrorMessage = this.i18n.errSubmitAlreadyPending;
            } else if (result.errorMessage === 'INVALID_POSTAL_CODE') {
                // Caught server-side when the country comes from the record, not the form.
                this.fieldErrors = { ...this.fieldErrors, [result.invalidFieldApiName]: this.i18n.errInvalidPostalCode };
            } else if (result.errorMessage === 'INVALID_VALUE') {
                this.fieldErrors = { ...this.fieldErrors, [result.invalidFieldApiName]: this.i18n.errInvalidValue };
                this.submitErrorMessage = this.i18n.errInvalidValue;
            } else if (result.errorMessage === 'INVALID_CAPTCHA') {
                this.submitErrorMessage = this.i18n.errCaptchaSessionExpired;
            } else if (result.errorMessage === 'INVALID_TABLE') {
                this.submitErrorMessage = this.i18n.errTableInvalid;
            } else {
                this.submitErrorMessage = this.i18n.errSubmitGeneric;
            }
        } catch (e) {
            this.submitErrorMessage = this.i18n.errSubmitGeneric;
        } finally {
            this.isBusy = false;
            if (this.step === 'form') this._revealError();
        }
    }

    // The error can sit far above the Submit button: after the next render, bring the first
    // invalid field (or the form message) into view and put the focus on it.
    _revealError() {
        this._pendingErrorFocus = true;
    }

    renderedCallback() {
        this._syncDocumentTitle();
        if (!this._pendingErrorFocus) return;
        this._pendingErrorFocus = false;
        const target = this.template.querySelector('[aria-invalid="true"]')
            || this.template.querySelector('.tuf-error');
        if (!target) return;
        target.scrollIntoView({ behavior: 'smooth', block: 'center' });
        if (target.matches('input, select')) target.focus({ preventScroll: true });
    }

    // ── Confirmation step ────────────────────────────────────────────────────

    handleNewRequest() {
        this.step = 'lookup';
        this.readOnlyValues = {};
        this.identity1 = '';
        this.identity2 = '';
        this.lookupErrorMessage = '';
        this.submitErrorMessage = '';
        this.fieldErrors = {};
        this.lookupPass = '';
        this.tableStates = {};
        this._resetRecaptcha();
        this.formValues = this._buildEmptyFormValues();
    }
}

function isValidPhone(val) {
    if (!PHONE_CHARS_REGEX.test(val)) return false;
    const digits = val.replace(/\D/g, '').length;
    return digits >= 7 && digits <= 15;
}
