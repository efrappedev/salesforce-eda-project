import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import runScanApex from '@salesforce/apex/MergeController.runScan';

export default class MergeScanModal extends LightningElement {
    @track objectType        = 'Contact';
    @track recordLimit       = 5000;
    @track dryRun            = false;
    @track isScanning        = false;
    @track validationError   = null;
    @track hasPreviewResults = false;
    @track previewResults    = null;
    @track asyncSuccess      = false;
    @track asyncBatchJobId   = '';

    @track _matchFields = { Email: true, Phone: true, Name: false };

    objectTypeOptions = [
        { label: 'Contact', value: 'Contact' },
        { label: 'Account', value: 'Account' }
    ];

    get matchFieldOptions() {
        return [
            { value: 'Email', label: 'Courriel',  icon: 'utility:email',
              inputId: 'mf-email', checked: this._matchFields.Email,
              iconVariant: this._matchFields.Email ? 'inverse' : '' },
            { value: 'Phone', label: 'Téléphone', icon: 'utility:call',
              inputId: 'mf-phone', checked: this._matchFields.Phone,
              iconVariant: this._matchFields.Phone ? 'inverse' : '' },
            { value: 'Name',  label: 'Nom',       icon: 'utility:user',
              inputId: 'mf-name',  checked: this._matchFields.Name,
              iconVariant: this._matchFields.Name  ? 'inverse' : '' }
        ];
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
        // Accounts rarely share Email — switch default to Name+Phone which detects household dupes
        this._matchFields = event.detail.value === 'Account'
            ? { Email: false, Phone: true, Name: true }
            : { Email: true,  Phone: true, Name: false };
    }
    handleLimitChange(event)      { this.recordLimit = parseInt(event.detail.value, 10) || 5000; }
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

    // Called when user manually closes after an async scan was launched.
    handleAsyncClose() {
        // Fire scancomplete so the parent refreshes the ticket list.
        this.dispatchEvent(new CustomEvent('scancomplete', {
            detail: { isAsync: true, batchJobId: this.asyncBatchJobId,
                      ticketsCreated: 0, duplicateGroupsFound: 0 }
        }));
    }

    async runScan() {
        if (!this._hasMatchFieldSelected()) {
            this.validationError = 'Sélectionnez au moins un critère de correspondance.';
            return;
        }

        this.isScanning      = true;
        this.validationError = null;
        this.hasPreviewResults = false;

        try {
            const request = {
                objectType:  this.objectType,
                matchFields: this._selectedMatchFields(),
                recordLimit: this.recordLimit,
                dryRun:      this.dryRun
            };

            const result = await runScanApex({ request });

            if (!result.success) {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Erreur scan',
                    message: result.errorMessage,
                    variant: 'error',
                    mode: 'sticky'
                }));
                return;
            }

            if (result.isAsync) {
                // Show in-modal success state — user closes manually when ready.
                this.asyncBatchJobId = result.batchJobId;
                this.asyncSuccess    = true;
            } else if (this.dryRun) {
                this.previewResults    = result;
                this.hasPreviewResults = true;
            } else {
                this.dispatchEvent(new CustomEvent('scancomplete', {
                    detail: {
                        objectType:             this.objectType,
                        ticketsCreated:         result.ticketsCreated,
                        duplicateGroupsFound:   result.duplicateGroupsFound,
                        skippedExistingTickets: result.skippedExistingTickets || 0,
                        recordsAnalyzed:        result.recordsAnalyzed        || 0
                    }
                }));
            }
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Erreur',
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
