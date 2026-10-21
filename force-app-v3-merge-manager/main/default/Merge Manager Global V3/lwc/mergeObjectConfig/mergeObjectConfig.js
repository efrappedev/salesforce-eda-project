import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRelatedListsInfo } from 'lightning/uiRelatedListApi';
import { getLabels, format } from 'c/mergeManagerI18n';
import getDiscoverableObjects       from '@salesforce/apex/MergeController.getDiscoverableObjects';
import getRelatedObjectConfigs      from '@salesforce/apex/MergeController.getRelatedObjectConfigs';
import saveObjectConfigsBatch       from '@salesforce/apex/MergeController.saveObjectConfigsBatch';
import getCustomCloseReasonsApex    from '@salesforce/apex/MergeController.getCustomCloseReasons';
import saveCustomCloseReasonsApex   from '@salesforce/apex/MergeController.saveCustomCloseReasons';
import getAvailableLookupFieldsApex from '@salesforce/apex/MergeController.getAvailableLookupFields';
import getReasonConfigApex          from '@salesforce/apex/MergeController.getReasonConfig';
import saveReasonConfigApex         from '@salesforce/apex/MergeController.saveReasonConfig';
import renameReasonApex             from '@salesforce/apex/MergeController.renameReason';

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
    @track _pendingLang = 'fr';

    @track activeSection      = 'language';
    @track selectedType       = 'Account';   // Account-first default for non-EDA orgs
    @track items              = [];
    @track isLoading          = false;
    @track isSaving           = false;
    @track errorMessage       = null;

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

    // Layer 2 — layout api names (populated when wire resolves)
    _acctLayoutApiNames = new Set();
    _contLayoutApiNames = new Set();

    // Data cache for wire-triggered recompute
    _loaded       = false;
    _discoverable = [];
    _configs      = [];
    _manualPool   = [];   // standard objects not shown in main list (for Layer 3)

    // Layer 3 — manual add state
    @track showManualAdd       = false;
    @track manualSelectedObj   = '';
    @track manualLookupOptions = [];   // [{ label, value }]
    @track manualSelectedField = '';
    @track manualFieldLoading  = false;

    get i18n() { return getLabels(this.lang); }

    // ── Layer 2: Related lists wires (object-level, no recordId needed) ───────

    @wire(getRelatedListsInfo, { parentObjectApiName: 'Account' })
    wiredAcctLayout({ data }) {
        if (data) {
            this._acctLayoutApiNames = new Set(
                (data.relatedLists || []).map(r => r.sobjectApiName)
            );
            this._recomputeItems();
        }
    }

    @wire(getRelatedListsInfo, { parentObjectApiName: 'Contact' })
    wiredContLayout({ data }) {
        if (data) {
            this._contLayoutApiNames = new Set(
                (data.relatedLists || []).map(r => r.sobjectApiName)
            );
            this._recomputeItems();
        }
    }

    _recomputeItems() {
        if (!this._loaded) return;
        this._buildItems(this._discoverable, this._configs);
    }

    // ── Language ──────────────────────────────────────────────────────────────
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
    get isLanguageSection() { return this.activeSection === 'language'; }
    get isObjectsSection()  { return this.activeSection === 'objects';  }
    get isReasonsSection()  { return this.activeSection === 'reasons';  }

    get navItemLanguageClass() {
        return 'settings-nav__item' + (this.isLanguageSection ? ' settings-nav__item_active' : '');
    }
    get navItemObjectsClass() {
        return 'settings-nav__item' + (this.isObjectsSection ? ' settings-nav__item_active' : '');
    }
    get navItemReasonsClass() {
        return 'settings-nav__item' + (this.isReasonsSection ? ' settings-nav__item_active' : '');
    }

    handleSectionChange(event) {
        this.activeSection = event.currentTarget.dataset.section;
    }

    // ── Objects data loading ──────────────────────────────────────────────────
    connectedCallback() {
        this._pendingLang = this.lang;
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
        this.isLoading     = true;
        this.errorMessage  = null;
        this.showManualAdd = false;
        this._loaded       = false;
        Promise.all([
            getDiscoverableObjects({ parentObjectType: this.selectedType }),
            getRelatedObjectConfigs()
        ])
        .then(([discoverable, configs]) => {
            this._discoverable = discoverable;
            this._configs      = configs;
            this._loaded       = true;
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

        // Main checklist: custom (__c) objects + already-configured standard objects
        // Standard objects not yet configured live in _manualPool for Layer 3.
        const displaySet = new Set();
        const toDisplay = discoverable.filter(d => {
            if (d.apiName.endsWith('__c') || cfgMap[d.apiName]) {
                displaySet.add(d.apiName);
                return true;
            }
            return false;
        });

        this.items = toDisplay.map(d => {
            const existing = cfgMap[d.apiName];
            return {
                key:         d.apiName,
                apiName:     d.apiName,
                lookupField: d.lookupField,
                schemaLabel: d.label,
                customLabel: existing ? existing.Name : d.label,
                checked:     existing ? true : firstTime
            };
        });

        // Layer 3 pool: all standard (non-__c) objects not yet in the main list
        this._manualPool = discoverable.filter(d => !displaySet.has(d.apiName));
    }

    // ── Objects getters ───────────────────────────────────────────────────────
    get accountTabClass() {
        return 'cfg-tab' + (this.selectedType === 'Account' ? ' cfg-tab_active' : '');
    }
    get contactTabClass() {
        return 'cfg-tab' + (this.selectedType === 'Contact' ? ' cfg-tab_active' : '');
    }
    get checkedItems() {
        return this.items.filter(i => i.checked).map(i => ({ ...i, rowClass: 'cfg-card cfg-card_active' }));
    }
    get uncheckedItems() {
        return this.items.filter(i => !i.checked).map(i => ({ ...i, rowClass: 'cfg-card' }));
    }
    get hasCheckedItems()       { return this.checkedItems.length > 0; }
    get hasUncheckedItems()     { return this.uncheckedItems.length > 0; }
    get hasItems()              { return this.items.length > 0; }
    get itemsFoundLabel()       { return this.items.length + ' ' + this.i18n.configDiscovered; }
    get checkedSectionLabel()   { return this.i18n.configActiveLabel + ' (' + this.checkedItems.length + ')'; }
    get uncheckedSectionLabel() { return this.i18n.configAvailLabel  + ' (' + this.uncheckedItems.length + ')'; }
    get saveLabel()             { return this.isSaving ? this.i18n.saving : this.i18n.save; }

    // Layer 3 getters
    get manualObjOptions() {
        const placeholder = [{ label: this.i18n.manualObjPlaceholder, value: '' }];
        // Pool: standard objects NOT already in the main checklist (raw discoverable shape: label/apiName/lookupField)
        const pool = this._manualPool.map(d => ({
            label: d.label + ' (' + d.apiName + ')',
            value: d.apiName
        }));
        return placeholder.concat(pool);
    }
    get hasManualFieldOptions() { return this.manualLookupOptions.length > 0; }
    get manualAddDisabled() {
        return !this.manualSelectedObj
            || this.manualFieldLoading
            || (this.hasManualFieldOptions && !this.manualSelectedField);
    }

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
        const apiName = evt.currentTarget.dataset.api;
        const checked = evt.target.checked;
        this.items = this.items.map(i => i.apiName === apiName ? { ...i, checked } : i);
    }

    handleLabelChange(evt) {
        const apiName = evt.currentTarget.dataset.api;
        const value   = evt.target.value;
        this.items = this.items.map(i => i.apiName === apiName ? { ...i, customLabel: value } : i);
    }

    // ── Layer 3: manual add ───────────────────────────────────────────────────
    handleToggleManualAdd() {
        this.showManualAdd = !this.showManualAdd;
        if (!this.showManualAdd) {
            this._resetManualAdd();
        } else {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                const panel = this.template.querySelector('.settings-panel');
                if (panel) panel.scrollTop = panel.scrollHeight;
            }, 0);
        }
    }

    handleManualObjChange(evt) {
        this.manualSelectedObj   = evt.detail.value;
        this.manualLookupOptions = [];
        this.manualSelectedField = '';
        if (!this.manualSelectedObj) return;

        const poolItem = this._manualPool.find(d => d.apiName === this.manualSelectedObj);
        this.manualFieldLoading = true;
        getAvailableLookupFieldsApex({
            objectApiName: this.manualSelectedObj,
            parentType:    this.selectedType
        })
        .then(fields => {
            if (fields.length <= 1) {
                this.manualSelectedField = fields.length === 1
                    ? fields[0].fieldName
                    : (poolItem ? poolItem.lookupField : '');
                this.manualLookupOptions = [];
            } else {
                this.manualLookupOptions = fields.map(f => ({
                    label: f.fieldLabel + ' (' + f.fieldName + ')',
                    value: f.fieldName
                }));
                const typeId = this.selectedType + 'Id';
                const match = fields.find(f => f.fieldName === typeId)
                           || fields.find(f => f.fieldName.toLowerCase().startsWith(this.selectedType.toLowerCase()))
                           || (poolItem ? fields.find(f => f.fieldName === poolItem.lookupField) : null);
                this.manualSelectedField = match ? match.fieldName : '';
            }
        })
        .catch(() => {
            this.manualSelectedField = poolItem ? poolItem.lookupField : '';
            this.manualLookupOptions = [];
        })
        .finally(() => { this.manualFieldLoading = false; });
    }

    handleManualFieldChange(evt) {
        this.manualSelectedField = evt.detail.value;
    }

    handleManualAdd() {
        const obj   = this.manualSelectedObj;
        const field = this.manualSelectedField;
        if (!obj || !field) return;

        const poolItem = this._manualPool.find(d => d.apiName === obj);
        if (poolItem) {
            // Move from pool into the main checklist as checked
            this._manualPool = this._manualPool.filter(d => d.apiName !== obj);
            this.items = [...this.items, {
                key:         obj,
                apiName:     obj,
                lookupField: field,
                schemaLabel: poolItem.label,
                customLabel: poolItem.label,
                checked:     true,
                fromLayout:  false
            }];
        }
        this._resetManualAdd();
        this.showManualAdd = false;
    }

    _resetManualAdd() {
        this.manualSelectedObj   = '';
        this.manualLookupOptions = [];
        this.manualSelectedField = '';
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
        // Focus the input after LWC re-renders
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
