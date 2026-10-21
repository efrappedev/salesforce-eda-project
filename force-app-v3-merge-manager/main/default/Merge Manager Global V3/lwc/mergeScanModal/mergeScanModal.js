import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getLabels, format } from 'c/mergeManagerI18n';
import runScanApex from '@salesforce/apex/MergeController.runScan';

export default class MergeScanModal extends LightningElement {

    _defaultObjectType = 'Account';
    @api
    set defaultObjectType(val) {
        this._defaultObjectType = val || 'Account';
        if (this._defaultObjectType === 'Account') {
            this.objectType   = 'Account';
            this._matchFields = { Email: false, Phone: true, Name: true };
        } else {
            this.objectType   = 'Contact';
            this._matchFields = { Email: true,  Phone: true, Name: false };
        }
    }
    get defaultObjectType() { return this._defaultObjectType; }

    @api lang = 'fr';

    @track objectType         = 'Account';
    @track recordLimit        = 5000;
    @track dryRun             = false;
    @track isScanning         = false;
    @track validationError    = null;
    @track hasPreviewResults  = false;
    @track previewResults     = null;
    @track asyncSuccess       = false;
    @track asyncBatchJobId    = '';
    @track useEmailObject     = false;

    @track _matchFields = { Email: false, Phone: true, Name: true };

    get i18n() { return getLabels(this.lang); }

    get objectTypeOptions() {
        const t = this.i18n;
        return [
            { label: t.objectTypeAccount, value: 'Account' },
            { label: t.objectTypeContact, value: 'Contact' }
        ];
    }

    get asyncRefreshSuffix() {
        return this.i18n.asyncRefreshSuffix;
    }

    get matchFieldOptions() {
        const t = this.i18n;
        return [
            { value: 'Name',  label: t.matchName,  icon: 'utility:user',
              inputId: 'mf-name',  checked: this._matchFields.Name,
              iconVariant: this._matchFields.Name  ? 'inverse' : '' },
            { value: 'Phone', label: t.matchPhone, icon: 'utility:call',
              inputId: 'mf-phone', checked: this._matchFields.Phone,
              iconVariant: this._matchFields.Phone ? 'inverse' : '' },
            { value: 'Email', label: t.matchEmail, icon: 'utility:email',
              inputId: 'mf-email', checked: this._matchFields.Email,
              iconVariant: this._matchFields.Email ? 'inverse' : '' }
        ];
    }

    get previewTitle() {
        if (!this.previewResults) return '';
        return format(this.i18n.previewApercu, `${this.previewResults.duplicateGroupsFound} ${this.i18n.previewGroups}`);
    }

    get isScanDisabled() {
        return this.isScanning || !this._hasMatchFieldSelected();
    }

    get showForm() {
        return !this.asyncSuccess;
    }

    // ── Handlers ──────────────────────────────────────────────────────────────

    handleObjectTypeChange(event) {
        this.objectType = event.detail.value;
        this._matchFields = event.detail.value === 'Account'
            ? { Email: false, Phone: true, Name: true }
            : { Email: true,  Phone: true, Name: false };
    }

    handleUseEmailObjectChange(event) {
        this.useEmailObject = event.detail.checked;
    }

    handleLimitChange(event) { this.recordLimit = parseInt(event.detail.value, 10) || 5000; }
    handleDryRunChange(event) {
        this.dryRun            = event.detail.checked;
        this.hasPreviewResults = false;
    }

    handleMatchFieldChange(event) {
        const value   = event.target.value;
        const checked = event.target.checked;
        this._matchFields = { ...this._matchFields, [value]: checked };
        this.validationError = null;
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('closescan'));
    }

    handleAsyncClose() {
        this.dispatchEvent(new CustomEvent('scancomplete', {
            detail: { isAsync: true, batchJobId: this.asyncBatchJobId,
                      ticketsCreated: 0, duplicateGroupsFound: 0 }
        }));
    }

    async runScan() {
        if (!this._hasMatchFieldSelected()) {
            this.validationError = this.i18n.scanValidation;
            return;
        }

        this.isScanning      = true;
        this.validationError = null;
        this.hasPreviewResults = false;

        const objectTypeSnapshot = this.objectType;

        try {
            const params = {
                objType:            objectTypeSnapshot,
                matchFields:        this._selectedMatchFields(),
                recordLimit:        this.recordLimit,
                dryRun:             this.dryRun,
                emailObjectApiName: this.useEmailObject ? 'AUTO' : null
            };

            // eslint-disable-next-line no-console
            console.log('[MergeScanModal] runScan →', JSON.stringify(params));

            const result = await runScanApex(params);

            if (!result.success) {
                this.dispatchEvent(new ShowToastEvent({
                    title:   this.i18n.toastScanError,
                    message: result.errorMessage,
                    variant: 'error',
                    mode:    'sticky'
                }));
                return;
            }

            if (result.isAsync) {
                this.asyncBatchJobId = result.batchJobId;
                this.asyncSuccess    = true;
            } else if (this.dryRun) {
                this.previewResults    = result;
                this.hasPreviewResults = true;
            } else {
                this.dispatchEvent(new CustomEvent('scancomplete', {
                    detail: {
                        objectType:             objectTypeSnapshot,
                        ticketsCreated:         result.ticketsCreated,
                        duplicateGroupsFound:   result.duplicateGroupsFound,
                        skippedExistingTickets: result.skippedExistingTickets || 0,
                        recordsAnalyzed:        result.recordsAnalyzed        || 0
                    }
                }));
            }
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({
                title:   this.i18n.error,
                message: error.body?.message || error.message,
                variant: 'error'
            }));
        } finally {
            this.isScanning = false;
        }
    }

    // ── Private ───────────────────────────────────────────────────────────────

    _hasMatchFieldSelected() {
        return Object.values(this._matchFields).some(Boolean);
    }

    _selectedMatchFields() {
        return Object.entries(this._matchFields)
            .filter(([, checked]) => checked)
            .map(([field]) => field);
    }
}
