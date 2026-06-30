import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getLabels, format } from 'c/i18n';
import getDiscoverableObjects  from '@salesforce/apex/MergeController.getDiscoverableObjects';
import getRelatedObjectConfigs from '@salesforce/apex/MergeController.getRelatedObjectConfigs';
import saveObjectConfigsBatch  from '@salesforce/apex/MergeController.saveObjectConfigsBatch';

const CUSTOM_REASONS_KEY = 'mergeManager_customCloseReasons';

export default class MergeObjectConfig extends LightningElement {
    @api lang = 'fr';
    @track _pendingLang = 'fr';

    @track activeSection     = 'language';
    @track selectedType      = 'Contact';
    @track items             = [];
    @track isLoading         = false;
    @track isSaving          = false;
    @track errorMessage      = null;
    @track customCloseReasons = [];
    @track newReasonInput     = '';

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
        this._loadCustomReasons();
        this.loadAll();
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
    get predefinedReasonsList() {
        const t = this.i18n;
        return [
            { value: 'same-household', label: t.closeReasonSameHousehold },
            { value: 'same-phone',     label: t.closeReasonSamePhone     },
            { value: 'same-email',     label: t.closeReasonSameEmail     },
            { value: 'not-duplicate',  label: t.closeReasonNotDuplicate  },
            { value: 'already-merged', label: t.closeReasonAlreadyMerged }
        ];
    }

    get hasCustomReasons() { return this.customCloseReasons.length > 0; }

    get customReasonsItems() {
        return this.customCloseReasons.map((r, i) => ({ id: `cr_${i}`, value: r }));
    }

    _loadCustomReasons() {
        try {
            const stored = localStorage.getItem(CUSTOM_REASONS_KEY);
            this.customCloseReasons = stored ? JSON.parse(stored) : [];
        } catch(e) { this.customCloseReasons = []; }
    }

    _saveCustomReasons() {
        try {
            localStorage.setItem(CUSTOM_REASONS_KEY, JSON.stringify(this.customCloseReasons));
        } catch(e) { /* ignore */ }
    }

    handleReasonInput(event)  { this.newReasonInput = event.target.value; }

    addCustomReason() {
        const r = (this.newReasonInput || '').trim();
        if (!r || this.customCloseReasons.includes(r)) return;
        this.customCloseReasons = [...this.customCloseReasons, r];
        this.newReasonInput = '';
        this._saveCustomReasons();
    }

    removeCustomReason(event) {
        const val = event.currentTarget.dataset.value;
        this.customCloseReasons = this.customCloseReasons.filter(r => r !== val);
        this._saveCustomReasons();
    }

    // ── Shared ────────────────────────────────────────────────────────────────
    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }

    _msg(err) {
        return (err && err.body && err.body.message) ? err.body.message : this.i18n.unknownError;
    }
}
