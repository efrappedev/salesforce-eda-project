import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getLabels, format } from 'c/i18n';
import getDiscoverableObjects      from '@salesforce/apex/MergeController.getDiscoverableObjects';
import getRelatedObjectConfigs     from '@salesforce/apex/MergeController.getRelatedObjectConfigs';
import saveObjectConfigsBatch      from '@salesforce/apex/MergeController.saveObjectConfigsBatch';
import getCustomCloseReasonsApex   from '@salesforce/apex/MergeController.getCustomCloseReasons';
import saveCustomCloseReasonsApex  from '@salesforce/apex/MergeController.saveCustomCloseReasons';
import getReasonConfigApex         from '@salesforce/apex/MergeController.getReasonConfig';
import saveReasonConfigApex        from '@salesforce/apex/MergeController.saveReasonConfig';
import renameReasonApex            from '@salesforce/apex/MergeController.renameReason';

const REL_BTN_KEY = 'mergeManager_relBtn_enabled';

const TV_REASONS = [
    { key: 'fp-household', storedDefault: 'False Positive - Same Household',    i18nKey: 'reasonHouseholdLong'    },
    { key: 'fp-org',       storedDefault: 'False Positive - Same Organization', i18nKey: 'reasonOrganizationLong' },
    { key: 'fp-phone',     storedDefault: 'False Positive - Shared Phone',      i18nKey: 'reasonSharedPhoneLong'  },
    { key: 'fp-email',     storedDefault: 'False Positive - Shared Email',      i18nKey: 'reasonSharedEmailLong'  },
    { key: 'resolved',     storedDefault: 'Already Resolved',                   i18nKey: 'reasonResolvedLong'     },
    { key: 'out-of-scope', storedDefault: 'Out of Scope',                       i18nKey: 'reasonOutOfScopeLong'   },
    { key: 'other',        storedDefault: 'Other',                              i18nKey: 'reasonOtherLong'        },
];
const CL_REASONS = [
    { key: 'same-household', sfDefault: 'False Positive - Same Household', i18nKey: 'closeReasonSameHousehold'  },
    { key: 'same-phone',     sfDefault: 'False Positive - Shared Phone',   i18nKey: 'closeReasonSamePhone'      },
    { key: 'same-email',     sfDefault: 'False Positive - Shared Email',   i18nKey: 'closeReasonSameEmail'      },
    { key: 'not-duplicate',  sfDefault: 'Out of Scope',                    i18nKey: 'closeReasonNotDuplicate'   },
    { key: 'already-merged', sfDefault: 'Already Resolved',                i18nKey: 'closeReasonAlreadyMerged'  },
];

export default class MergeObjectConfig extends LightningElement {
    @api lang = 'fr';
    @track _pendingLang    = 'fr';
    @track _pendingRelEnabled = true;

    @track activeSection     = 'language';
    @track selectedType      = 'Contact';
    @track items             = [];
    @track isLoading         = false;
    @track isSaving          = false;
    @track errorMessage      = null;

    // ── Close reasons state ───────────────────────────────────────────────────
    @track activeReasonTab   = 'tv';
    @track _tvEdits          = {};
    @track _clEdits          = {};
    @track _tvCustomItems    = [];
    @track _clCustomItems    = [];
    @track newTvReason       = '';
    @track newClReason       = '';
    @track reasonError       = null;
    @track isReasonSaving    = false;
    @track isReasonLoading   = false;
    @track _editingKey       = null;
    _tvOrigLabels            = {};
    _clOrigLabels            = {};

    get i18n() { return getLabels(this.lang); }

    // ── Language ─────────────────────────────────────────────────────────────
    get langFrClass() { return 'cfg-lang-btn' + (this._pendingLang === 'fr' ? ' cfg-lang-btn_active' : ''); }
    get langEnClass() { return 'cfg-lang-btn' + (this._pendingLang === 'en' ? ' cfg-lang-btn_active' : ''); }
    get langEsClass() { return 'cfg-lang-btn' + (this._pendingLang === 'es' ? ' cfg-lang-btn_active' : ''); }

    handleLangChange(event) {
        this._pendingLang = event.currentTarget.dataset.lang;
    }

    handleLangSave() {
        this.dispatchEvent(new CustomEvent('langchange', { detail: { lang: this._pendingLang } }));
    }

    // ── Section nav ───────────────────────────────────────────────────────────
    get isFeaturesSection()  { return this.activeSection === 'features'; }
    get isLanguageSection()  { return this.activeSection === 'language'; }
    get isObjectsSection()   { return this.activeSection === 'objects';  }
    get isReasonsSection()   { return this.activeSection === 'reasons';  }

    get navItemFeaturesClass() {
        return 'settings-nav__item' + (this.isFeaturesSection ? ' settings-nav__item_active' : '');
    }
    get navItemLanguageClass() {
        return 'settings-nav__item' + (this.isLanguageSection ? ' settings-nav__item_active' : '');
    }
    get navItemObjectsClass() {
        return 'settings-nav__item' + (this.isObjectsSection ? ' settings-nav__item_active' : '');
    }
    get navItemReasonsClass() {
        return 'settings-nav__item' + (this.isReasonsSection ? ' settings-nav__item_active' : '');
    }

    // ── Features (EDA toggles) ────────────────────────────────────────────────
    get relBtnToggleClass() {
        return 'feature-toggle__track' + (this._pendingRelEnabled ? ' feature-toggle__track_on' : '');
    }

    handleRelBtnToggle() {
        this._pendingRelEnabled = !this._pendingRelEnabled;
    }

    handleFeaturesSave() {
        this.dispatchEvent(new CustomEvent('featureschange', {
            detail: { relBtnEnabled: this._pendingRelEnabled }
        }));
    }

    handleSectionChange(event) {
        this.activeSection = event.currentTarget.dataset.section;
    }

    // ── Objects data loading ──────────────────────────────────────────────────
    connectedCallback() {
        this._pendingLang       = this.lang;
        this._pendingRelEnabled = localStorage.getItem(REL_BTN_KEY) !== 'false';
        this._loadReasonConfig();
        this.loadAll();
    }

    _loadReasonConfig() {
        this.isReasonLoading = true;
        Promise.all([
            getReasonConfigApex()
                .then(json => { try { return JSON.parse(json || '{}'); } catch(e) { return {}; } })
                .catch(() => ({})),
            getCustomCloseReasonsApex().catch(() => [])
        ]).then(([cfg, legacy]) => {
            if (!cfg.clCustom || !cfg.clCustom.length) cfg = { ...cfg, clCustom: legacy };
            this._initReasonState(cfg);
        }).finally(() => { this.isReasonLoading = false; });
    }

    _initReasonState(cfg) {
        const tvLabels = cfg.tvLabels || {};
        const clLabels = cfg.clLabels || {};
        const tvCustom = cfg.tvCustom || [];
        const clCustom = cfg.clCustom || [];
        this._tvEdits       = { ...tvLabels };
        this._clEdits       = { ...clLabels };
        this._tvOrigLabels  = { ...tvLabels };
        this._clOrigLabels  = { ...clLabels };
        this._tvCustomItems = tvCustom.map((v, i) => ({ id: 'tv_' + i, value: v, orig: v }));
        this._clCustomItems = clCustom.map((v, i) => ({ id: 'cl_' + i, value: v, orig: v }));
    }

    loadAll() {
        this.isLoading    = true;
        this.errorMessage = null;
        Promise.all([
            getDiscoverableObjects({ parentObjectType: this.selectedType }),
            getRelatedObjectConfigs()
        ])
        .then(([discoverable, configs]) => {
            this._buildItems(discoverable, configs);
        })
        .catch(err => { this.errorMessage = this._msg(err); })
        .finally(() => { this.isLoading = false; });
    }

    _buildItems(discoverable, allConfigs) {
        const typeConfigs = allConfigs.filter(c => c.Object_Type__c === this.selectedType);
        const firstTime   = typeConfigs.length === 0;
        const cfgMap = {};
        for (const c of typeConfigs) {
            cfgMap[c.Object_API_Name__c] = c;
        }
        this.items = discoverable.map(d => {
            const existing = cfgMap[d.apiName];
            return {
                key:         d.apiName,
                apiName:     d.apiName,
                lookupField: d.lookupField,
                schemaLabel: d.label,
                customLabel: existing ? existing.Name : d.label,
                checked:     firstTime ? true : !!existing
            };
        });
    }

    // ── Objects getters ───────────────────────────────────────────────────────
    get contactTabClass() {
        return 'cfg-tab' + (this.selectedType === 'Contact' ? ' cfg-tab_active' : '');
    }
    get accountTabClass() {
        return 'cfg-tab' + (this.selectedType === 'Account' ? ' cfg-tab_active' : '');
    }
    get checkedItems() {
        return this.items.filter(i => i.checked).map(i => ({ ...i, rowClass: 'cfg-card cfg-card_active' }));
    }
    get uncheckedItems() {
        return this.items.filter(i => !i.checked).map(i => ({ ...i, rowClass: 'cfg-card' }));
    }
    get hasCheckedItems()      { return this.checkedItems.length > 0; }
    get hasUncheckedItems()    { return this.uncheckedItems.length > 0; }
    get hasItems()             { return this.items.length > 0; }
    get itemsFoundLabel()      { return this.items.length + ' ' + this.i18n.configDiscovered; }
    get checkedSectionLabel()  { return this.i18n.configActiveLabel + ' (' + this.checkedItems.length + ')'; }
    get uncheckedSectionLabel(){ return this.i18n.configAvailLabel + ' (' + this.uncheckedItems.length + ')'; }
    get saveLabel()            { return this.isSaving ? this.i18n.saving : this.i18n.save; }

    // ── Objects interactions ──────────────────────────────────────────────────
    handleTypeChange(evt) {
        const type = evt.currentTarget.dataset.type;
        if (type === this.selectedType) return;
        this.selectedType = type;
        this.items = [];
        this.loadAll();
    }

    handleSelectAll()   { this.items = this.items.map(i => ({ ...i, checked: true  })); }
    handleUnselectAll() { this.items = this.items.map(i => ({ ...i, checked: false })); }

    handleToggle(evt) {
        const api     = evt.currentTarget.dataset.api;
        const checked = evt.target.checked;
        this.items = this.items.map(i => i.apiName === api ? { ...i, checked } : i);
    }

    handleLabelChange(evt) {
        const api   = evt.currentTarget.dataset.api;
        const value = evt.target.value;
        this.items = this.items.map(i => i.apiName === api ? { ...i, customLabel: value } : i);
    }

    handleSave() {
        this.errorMessage = null;
        const checked = this.checkedItems;
        const payload = JSON.stringify(checked.map(i => ({
            apiName:     i.apiName,
            lookupField: i.lookupField,
            customLabel: (i.customLabel || i.schemaLabel).trim()
        })));
        this.isSaving = true;
        saveObjectConfigsBatch({ parentType: this.selectedType, configsJson: payload })
            .then(() => {
                this.dispatchEvent(new ShowToastEvent({
                    title:   this.i18n.toastConfigSaved,
                    message: format(this.i18n.toastConfigMsgFmt, checked.length, this.selectedType),
                    variant: 'success'
                }));
                this.dispatchEvent(new CustomEvent('configsaved'));
                this.handleClose();
            })
            .catch(err => {
                const msg = this._msg(err);
                this.errorMessage = msg;
                this.dispatchEvent(new ShowToastEvent({ title: this.i18n.error, message: msg, variant: 'error' }));
            })
            .finally(() => { this.isSaving = false; });
    }

    // ── Close reasons ─────────────────────────────────────────────────────────
    get reasonTabTvClass() { return 'cfg-tab' + (this.activeReasonTab === 'tv' ? ' cfg-tab_active' : ''); }
    get reasonTabClClass() { return 'cfg-tab' + (this.activeReasonTab === 'cl' ? ' cfg-tab_active' : ''); }
    get isReasonTabTv()   { return this.activeReasonTab === 'tv'; }
    get isReasonTabCl()   { return this.activeReasonTab === 'cl'; }

    handleReasonTabChange(evt) {
        this.activeReasonTab = evt.currentTarget.dataset.tab;
        this.reasonError = null;
    }

    get tvPredefinedItems() {
        const t = this.i18n;
        return TV_REASONS.map(r => {
            const defaultLabel = t[r.i18nKey] || r.storedDefault;
            const currentVal   = r.key in this._tvEdits ? this._tvEdits[r.key] : defaultLabel;
            return {
                key:         r.key,
                label:       currentVal,
                placeholder: defaultLabel,
                isModified:  currentVal !== defaultLabel,
                isEditing:   this._editingKey === r.key
            };
        });
    }

    get clPredefinedItems() {
        const t = this.i18n;
        return CL_REASONS.map(r => {
            const defaultLabel = t[r.i18nKey] || r.sfDefault;
            const currentVal   = r.key in this._clEdits ? this._clEdits[r.key] : defaultLabel;
            return {
                key:         r.key,
                label:       currentVal,
                placeholder: defaultLabel,
                isModified:  currentVal !== defaultLabel,
                isEditing:   this._editingKey === r.key
            };
        });
    }

    get tvCustomItems() {
        return this._tvCustomItems.map(i => ({ ...i, isEditing: this._editingKey === i.id }));
    }
    get clCustomItems() {
        return this._clCustomItems.map(i => ({ ...i, isEditing: this._editingKey === i.id }));
    }
    get hasTvCustomItems() { return this._tvCustomItems.length > 0; }
    get hasClCustomItems() { return this._clCustomItems.length > 0; }
    get reasonSaveLabel()  { return this.isReasonSaving ? this.i18n.saving : this.i18n.save; }

    handleReasonLabelChange(evt) {
        const key   = evt.currentTarget.dataset.key;
        const tab   = evt.currentTarget.dataset.tab;
        const value = evt.target.value;
        if (tab === 'tv') {
            this._tvEdits = { ...this._tvEdits, [key]: value };
        } else {
            this._clEdits = { ...this._clEdits, [key]: value };
        }
        this.reasonError = null;
    }

    handleReasonReset(evt) {
        const key = evt.currentTarget.dataset.key;
        const tab = evt.currentTarget.dataset.tab;
        if (tab === 'tv') {
            const edits = { ...this._tvEdits };
            delete edits[key];
            this._tvEdits = edits;
        } else {
            const edits = { ...this._clEdits };
            delete edits[key];
            this._clEdits = edits;
        }
        this.reasonError = null;
    }

    handleEditStart(evt) {
        const { key, id } = evt.currentTarget.dataset;
        this._editingKey = key || id;
        Promise.resolve().then(() => {
            const sel = key ? `input[data-key="${key}"]` : `input[data-id="${id}"]`;
            const input = this.template.querySelector(sel);
            if (input) { input.focus(); input.select(); }
        });
    }

    handleEditEnd() {
        this._editingKey = null;
    }

    handleCustomReasonChange(evt) {
        const id    = evt.currentTarget.dataset.id;
        const tab   = evt.currentTarget.dataset.tab;
        const value = evt.target.value;
        if (tab === 'tv') {
            this._tvCustomItems = this._tvCustomItems.map(i => i.id === id ? { ...i, value } : i);
        } else {
            this._clCustomItems = this._clCustomItems.map(i => i.id === id ? { ...i, value } : i);
        }
        this.reasonError = null;
    }

    handleRemoveCustomReason(evt) {
        const id  = evt.currentTarget.dataset.id;
        const tab = evt.currentTarget.dataset.tab;
        if (tab === 'tv') {
            this._tvCustomItems = this._tvCustomItems.filter(i => i.id !== id);
        } else {
            this._clCustomItems = this._clCustomItems.filter(i => i.id !== id);
        }
    }

    handleNewReasonInput(evt) {
        const tab = evt.currentTarget.dataset.tab;
        if (tab === 'tv') {
            this.newTvReason = evt.target.value;
        } else {
            this.newClReason = evt.target.value;
        }
    }

    addCustomReason(evt) {
        const tab    = evt.currentTarget.dataset.tab;
        const reason = (tab === 'tv' ? this.newTvReason : this.newClReason).trim();
        if (!reason) return;
        const allLabels = tab === 'tv' ? this._getAllTvLabels() : this._getAllClLabels();
        if (allLabels.some(l => l.toLowerCase() === reason.toLowerCase())) {
            this.reasonError = this.i18n.reasonDuplicateError;
            return;
        }
        if (tab === 'tv') {
            this._tvCustomItems = [...this._tvCustomItems, { id: 'tv_' + Date.now(), value: reason, orig: '' }];
            this.newTvReason = '';
        } else {
            this._clCustomItems = [...this._clCustomItems, { id: 'cl_' + Date.now(), value: reason, orig: '' }];
            this.newClReason = '';
        }
        this.reasonError = null;
    }

    _getAllTvLabels() {
        const t = this.i18n;
        const predefined = TV_REASONS.map(r => {
            const v = r.key in this._tvEdits ? this._tvEdits[r.key] : (t[r.i18nKey] || r.storedDefault);
            return (v || '').trim();
        }).filter(Boolean);
        const custom = this._tvCustomItems.map(i => (i.value || '').trim()).filter(Boolean);
        return [...predefined, ...custom];
    }

    _getAllClLabels() {
        const t = this.i18n;
        const predefined = CL_REASONS.map(r => {
            const v = r.key in this._clEdits ? this._clEdits[r.key] : (t[r.i18nKey] || r.sfDefault);
            return (v || '').trim();
        }).filter(Boolean);
        const custom = this._clCustomItems.map(i => (i.value || '').trim()).filter(Boolean);
        return [...predefined, ...custom];
    }

    _validateNoDuplicates() {
        const tvLabels = this._getAllTvLabels().map(l => l.toLowerCase());
        if (new Set(tvLabels).size !== tvLabels.length) return false;
        const clLabels = this._getAllClLabels().map(l => l.toLowerCase());
        if (new Set(clLabels).size !== clLabels.length) return false;
        return true;
    }

    async handleReasonSave() {
        if (!this._validateNoDuplicates()) {
            this.reasonError = this.i18n.reasonDuplicateError;
            return;
        }
        this.reasonError    = null;
        this.isReasonSaving = true;
        try {
            const t       = this.i18n;
            const renames = [];

            for (const r of TV_REASONS) {
                if (!(r.key in this._tvEdits)) continue;
                const oldStored = this._tvOrigLabels[r.key] || r.storedDefault;
                const newLabel  = (this._tvEdits[r.key] || '').trim() || r.storedDefault;
                if (oldStored !== newLabel) {
                    renames.push(renameReasonApex({ oldVal: oldStored, newVal: newLabel, ticketStatus: 'Ignored' }));
                }
            }
            for (const item of this._tvCustomItems) {
                if (item.orig && item.value.trim() && item.orig !== item.value.trim()) {
                    renames.push(renameReasonApex({ oldVal: item.orig, newVal: item.value.trim(), ticketStatus: 'Ignored' }));
                }
            }
            for (const r of CL_REASONS) {
                if (!(r.key in this._clEdits)) continue;
                const oldStored = this._clOrigLabels[r.key] || r.sfDefault;
                const newLabel  = (this._clEdits[r.key] || '').trim() || r.sfDefault;
                if (oldStored !== newLabel) {
                    renames.push(renameReasonApex({ oldVal: oldStored, newVal: newLabel, ticketStatus: 'Closed' }));
                }
            }
            for (const item of this._clCustomItems) {
                if (item.orig && item.value.trim() && item.orig !== item.value.trim()) {
                    renames.push(renameReasonApex({ oldVal: item.orig, newVal: item.value.trim(), ticketStatus: 'Closed' }));
                }
            }
            await Promise.all(renames);

            const tvLabels = {};
            for (const r of TV_REASONS) {
                if (r.key in this._tvEdits) {
                    const v = (this._tvEdits[r.key] || '').trim();
                    if (v) tvLabels[r.key] = v;
                }
            }
            const clLabels = {};
            for (const r of CL_REASONS) {
                if (r.key in this._clEdits) {
                    const v = (this._clEdits[r.key] || '').trim();
                    if (v) clLabels[r.key] = v;
                }
            }
            const tvCustom = this._tvCustomItems.map(i => i.value.trim()).filter(Boolean);
            const clCustom = this._clCustomItems.map(i => i.value.trim()).filter(Boolean);

            await saveReasonConfigApex({ configJson: JSON.stringify({ tvLabels, clLabels, tvCustom, clCustom }) });

            this._tvOrigLabels  = { ...tvLabels };
            this._clOrigLabels  = { ...clLabels };
            this._tvCustomItems = tvCustom.map((v, i) => ({ id: 'tv_' + i, value: v, orig: v }));
            this._clCustomItems = clCustom.map((v, i) => ({ id: 'cl_' + i, value: v, orig: v }));

            this.dispatchEvent(new ShowToastEvent({
                title:   this.i18n.toastReasonSaved || 'Raisons enregistrées',
                variant: 'success'
            }));
            this.dispatchEvent(new CustomEvent('configsaved'));
        } catch (err) {
            const msg = this._msg(err);
            this.reasonError = msg;
            this.dispatchEvent(new ShowToastEvent({ title: this.i18n.error, message: msg, variant: 'error' }));
        } finally {
            this.isReasonSaving = false;
        }
    }

    // ── Shared ────────────────────────────────────────────────────────────────
    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }

    _msg(err) {
        const m = err?.body?.message || err?.message || err?.body?.pageErrors?.[0]?.message;
        return m || this.i18n.unknownError;
    }
}
