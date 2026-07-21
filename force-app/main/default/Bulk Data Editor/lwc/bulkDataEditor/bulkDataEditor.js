import { LightningElement, wire } from 'lwc';
import getEditableObjects from '@salesforce/apex/BulkEditController.getEditableObjects';
import getEditableFields from '@salesforce/apex/BulkEditController.getEditableFields';
import getValueDistribution from '@salesforce/apex/BulkEditController.getValueDistribution';
import getFilterableFields from '@salesforce/apex/BulkEditController.getFilterableFields';
import getFilterFieldValueDistribution from '@salesforce/apex/BulkEditController.getFilterFieldValueDistribution';
import getPicklistValues from '@salesforce/apex/BulkEditController.getPicklistValues';
import startBulkEdit from '@salesforce/apex/BulkEditController.startBulkEdit';

const NUMERIC_TYPES = new Set(['DOUBLE', 'INTEGER', 'CURRENCY', 'PERCENT']);

const STEP_ORDER = ['object', 'field', 'value', 'newvalue', 'run'];

export default class BulkDataEditor extends LightningElement {
    activeTab = 'edit';

    // Top-level chooser between the existing value-match wizard and the
    // newer Record Type search-and-select flow — a different selection
    // model (explicit record IDs vs. a matched value), so it's rendered by
    // its own component (bulkRecordTypeChange) rather than folded into this
    // wizard's steps.
    mode = 'values';

    // Explicit wizard step — only one step's box is ever rendered at a
    // time. Driven by navigation (forward on selection, backward via the
    // Back buttons / path clicks), never derived from data presence, so a
    // failed load can't leave the template trying to render a step whose
    // data never arrived.
    wizardStep = 'object';

    // Step 1 — object
    objectOptions = [];
    isLoadingObjects = true;
    objectsError;
    selectedObjectApiName;
    selectedObjectLabel;

    // Step 2 — field
    fieldOptions = [];
    isLoadingFields = false;
    selectedFieldApiName;
    selectedFieldLabel;
    selectedFieldDataType;

    // Step 3 — value distribution
    distribution;
    isLoadingDistribution = false;
    selectedBucket;

    // Step 3 — optional cross-filter criterion (e.g. only rows where
    // Mailing State = Quebec), ANDed into the main value distribution and
    // the eventual update WHERE clause. Only one filter can be active at a
    // time. The filter column is always visible next to the value column
    // (not a separate picking mode) so choosing a filter never changes the
    // page layout.
    filterFieldOptions = [];
    isLoadingFilterFields = false;
    selectedFilterFieldApiName;
    selectedFilterFieldLabel;
    filterDistribution;
    isLoadingFilterDistribution = false;
    selectedFilterBucket;

    // Step 4 — new value
    newValueInput = '';
    newValueIsBlank = false;
    picklistValues = [];

    // Confirm + run
    showConfirmModal = false;
    currentLogId;
    currentBatchJobId;
    showProgress = false;
    runSummary;

    @wire(getEditableObjects)
    wiredObjects({ data, error }) {
        this.isLoadingObjects = false;
        if (data) {
            this.objectOptions = data.map((o) => ({ label: o.label, value: o.apiName }));
        } else if (error) {
            this.objectsError = (error.body && error.body.message) || 'Unable to load objects.';
        }
    }

    // ---------------------------------------------------------------
    // Step derivation for the visual path / gating what renders
    // ---------------------------------------------------------------

    get activeWizardStep() {
        return this.showProgress ? 'run' : this.wizardStep;
    }

    get pathSteps() {
        const currentIndex = STEP_ORDER.indexOf(this.activeWizardStep);
        return [
            { key: 'object', label: '1. Object', className: this.stepClass(0, currentIndex) },
            { key: 'field', label: '2. Field', className: this.stepClass(1, currentIndex) },
            { key: 'value', label: '3. Value to replace', className: this.stepClass(2, currentIndex) },
            { key: 'newvalue', label: '4. New value & confirm', className: this.stepClass(3, currentIndex) },
            { key: 'run', label: '5. Apply', className: this.stepClass(4, currentIndex) }
        ];
    }

    stepClass(stepIndex, currentIndex) {
        let cls = 'slds-path__item';
        if (stepIndex < currentIndex) {
            cls += ' slds-is-complete wizard-step-clickable';
        } else if (stepIndex === currentIndex) {
            cls += ' slds-is-current slds-is-active';
        } else {
            cls += ' slds-is-incomplete';
        }
        return cls;
    }

    get isValuesMode() {
        return this.mode === 'values';
    }

    get isRecordTypeMode() {
        return this.mode === 'recordtype';
    }

    get modeOptions() {
        return [
            { label: 'Edit field values', value: 'values' },
            { label: 'Change Record Type', value: 'recordtype' }
        ];
    }

    handleModeChange(event) {
        this.mode = event.detail.value;
    }

    get isObjectStep() {
        return !this.showProgress && this.wizardStep === 'object';
    }

    get isFieldStep() {
        return !this.showProgress && this.wizardStep === 'field';
    }

    get isValueStep() {
        return !this.showProgress && this.wizardStep === 'value';
    }

    get isNewValueStep() {
        return !this.showProgress && this.wizardStep === 'newvalue';
    }

    get isFieldSelectDisabled() {
        return !this.selectedObjectApiName || this.isLoadingFields;
    }

    get selectedFieldIsPicklist() {
        return this.selectedFieldDataType === 'PICKLIST';
    }

    get selectedFieldIsBoolean() {
        return this.selectedFieldDataType === 'BOOLEAN';
    }

    get selectedFieldIsDate() {
        return this.selectedFieldDataType === 'DATE';
    }

    get selectedFieldIsNumeric() {
        return NUMERIC_TYPES.has(this.selectedFieldDataType);
    }

    get selectedFieldIsText() {
        return !this.selectedFieldIsPicklist && !this.selectedFieldIsBoolean && !this.selectedFieldIsDate && !this.selectedFieldIsNumeric;
    }

    get booleanOptions() {
        return [
            { label: 'True', value: 'true' },
            { label: 'False', value: 'false' }
        ];
    }

    get picklistOptions() {
        return this.picklistValues.map((v) => ({ label: v, value: v }));
    }

    get oldValueDisplay() {
        if (!this.selectedBucket) return '';
        return this.selectedBucket.isBlank ? '(Blank)' : this.selectedBucket.displayValue;
    }

    get newValueDisplay() {
        return this.newValueIsBlank ? '(Blank)' : this.newValueInput;
    }

    get affectedCount() {
        return this.selectedBucket ? this.selectedBucket.recordCount : 0;
    }

    get confirmDisabled() {
        return !this.newValueIsBlank && !this.newValueInput;
    }

    get hasFilter() {
        return !!this.selectedFilterBucket;
    }

    get filterValueDisplay() {
        if (!this.selectedFilterBucket) return '';
        return this.selectedFilterBucket.isBlank ? '(Blank)' : this.selectedFilterBucket.displayValue;
    }

    get wizardContainerClass() {
        return this.isValueStep ? 'wizard-container wizard-container_wide' : 'wizard-container';
    }

    get selectedFilterRawValue() {
        return this.selectedFilterBucket ? this.selectedFilterBucket.rawValue : undefined;
    }

    get selectedFilterIsBlank() {
        return this.selectedFilterBucket ? this.selectedFilterBucket.isBlank : false;
    }

    get selectedBucketRawValue() {
        return this.selectedBucket ? this.selectedBucket.rawValue : undefined;
    }

    get selectedBucketIsBlank() {
        return this.selectedBucket ? this.selectedBucket.isBlank : false;
    }

    get showStep3Footer() {
        return !!this.selectedBucket;
    }

    get step3StatusText() {
        if (!this.selectedBucket) {
            return '';
        }
        const scope = this.hasFilter ? 'filtered record(s)' : 'record(s)';
        return `Confirming the current value for ${this.affectedCount} ${scope}.`;
    }

    // ---------------------------------------------------------------
    // Handlers
    // ---------------------------------------------------------------

    handleTabActive(event) {
        this.activeTab = event.target.value;
    }

    handleObjectChange(event) {
        this.selectedObjectApiName = event.detail.value;
        const found = this.objectOptions.find((o) => o.value === this.selectedObjectApiName);
        this.selectedObjectLabel = found ? found.label : this.selectedObjectApiName;
        this.resetFromField();
        this.wizardStep = 'field';
        this.loadFields();
    }

    loadFields() {
        this.objectsError = undefined;
        this.isLoadingFields = true;
        this.fieldOptions = [];
        getEditableFields({ objectApiName: this.selectedObjectApiName })
            .then((data) => {
                this.fieldOptions = data.map((f) => ({ label: f.label, value: f.apiName, dataType: f.dataType }));
            })
            .catch((error) => {
                this.objectsError = (error.body && error.body.message) || 'Unable to load fields.';
            })
            .finally(() => {
                this.isLoadingFields = false;
            });
    }

    handleFieldChange(event) {
        this.selectedFieldApiName = event.detail.value;
        const found = this.fieldOptions.find((f) => f.value === this.selectedFieldApiName);
        this.selectedFieldLabel = found ? found.label : this.selectedFieldApiName;
        this.selectedFieldDataType = found ? found.dataType : undefined;
        this.resetFromValues();
        this.wizardStep = 'value';
        this.loadDistribution();
        this.loadFilterFields();
        if (this.selectedFieldIsPicklist) {
            this.loadPicklistValues();
        }
    }

    loadDistribution() {
        this.objectsError = undefined;
        this.isLoadingDistribution = true;
        this.distribution = undefined;
        getValueDistribution({
            objectApiName: this.selectedObjectApiName,
            fieldApiName: this.selectedFieldApiName,
            filterFieldApiName: this.selectedFilterFieldApiName,
            filterValue: this.hasFilter && !this.selectedFilterBucket.isBlank ? this.selectedFilterBucket.rawValue : null,
            filterIsBlankValue: this.hasFilter ? this.selectedFilterBucket.isBlank : null
        })
            .then((data) => {
                this.distribution = data;
            })
            .catch((error) => {
                this.objectsError = (error.body && error.body.message) || 'Unable to load value distribution.';
            })
            .finally(() => {
                this.isLoadingDistribution = false;
            });
    }

    // -----------------------------------------------------------
    // Optional filter (cross-criterion) within Step 3
    // -----------------------------------------------------------

    loadFilterFields() {
        this.objectsError = undefined;
        this.isLoadingFilterFields = true;
        this.filterFieldOptions = [];
        getFilterableFields({ objectApiName: this.selectedObjectApiName, excludeFieldApiName: this.selectedFieldApiName })
            .then((data) => {
                this.filterFieldOptions = data.map((f) => ({ label: f.label, value: f.apiName }));
            })
            .catch((error) => {
                this.objectsError = (error.body && error.body.message) || 'Unable to load filterable fields.';
            })
            .finally(() => {
                this.isLoadingFilterFields = false;
            });
    }

    handleFilterFieldChange(event) {
        this.selectedFilterFieldApiName = event.detail.value;
        const found = this.filterFieldOptions.find((f) => f.value === this.selectedFilterFieldApiName);
        this.selectedFilterFieldLabel = found ? found.label : this.selectedFilterFieldApiName;
        this.selectedFilterBucket = undefined;
        this.filterDistribution = undefined;
        this.selectedBucket = undefined;
        if (this.selectedFilterFieldApiName) {
            this.loadFilterDistribution();
        }
        this.loadDistribution();
    }

    loadFilterDistribution() {
        this.objectsError = undefined;
        this.isLoadingFilterDistribution = true;
        this.filterDistribution = undefined;
        getFilterFieldValueDistribution({ objectApiName: this.selectedObjectApiName, fieldApiName: this.selectedFilterFieldApiName })
            .then((data) => {
                this.filterDistribution = data;
            })
            .catch((error) => {
                this.objectsError = (error.body && error.body.message) || 'Unable to load filter values.';
            })
            .finally(() => {
                this.isLoadingFilterDistribution = false;
            });
    }

    handleFilterValueSelect(event) {
        const detail = event.detail;
        const isSame =
            this.selectedFilterBucket &&
            this.selectedFilterBucket.isBlank === detail.isBlank &&
            this.selectedFilterBucket.rawValue === detail.rawValue;
        this.selectedFilterBucket = isSame ? undefined : detail;
        // The counts behind the main value picker are now stale since the
        // filter narrows the candidate rows — clear the prior selection and
        // reload so the user picks from the filtered counts.
        this.selectedBucket = undefined;
        this.loadDistribution();
    }

    handleRemoveFilter() {
        this.selectedFilterFieldApiName = undefined;
        this.selectedFilterFieldLabel = undefined;
        this.filterDistribution = undefined;
        this.selectedFilterBucket = undefined;
        this.selectedBucket = undefined;
        this.loadDistribution();
    }

    loadPicklistValues() {
        getPicklistValues({ objectApiName: this.selectedObjectApiName, fieldApiName: this.selectedFieldApiName }).then(
            (data) => {
                this.picklistValues = data;
            }
        );
    }

    handleBucketSelect(event) {
        const detail = event.detail;
        const isSame =
            this.selectedBucket && this.selectedBucket.isBlank === detail.isBlank && this.selectedBucket.rawValue === detail.rawValue;
        this.selectedBucket = isSame ? undefined : detail;
    }

    handleContinueToNewValue() {
        if (!this.selectedBucket) {
            return;
        }
        this.newValueInput = '';
        this.newValueIsBlank = false;
        this.wizardStep = 'newvalue';
    }

    handleCancelValueSelection() {
        this.selectedBucket = undefined;
    }

    handleBackToObject() {
        this.objectsError = undefined;
        this.resetFromField();
        this.wizardStep = 'object';
    }

    handleBackToField() {
        this.objectsError = undefined;
        this.resetFromValues();
        this.wizardStep = 'field';
    }

    handleBackToValue() {
        this.objectsError = undefined;
        this.selectedBucket = undefined;
        this.newValueInput = '';
        this.newValueIsBlank = false;
        this.wizardStep = 'value';
    }

    handlePathStepClick(event) {
        if (this.showProgress) {
            return;
        }
        const key = event.currentTarget.dataset.key;
        const currentIndex = STEP_ORDER.indexOf(this.wizardStep);
        const targetIndex = STEP_ORDER.indexOf(key);
        if (targetIndex === -1 || targetIndex >= currentIndex) {
            return;
        }
        if (key === 'object') {
            this.handleBackToObject();
        } else if (key === 'field') {
            this.handleBackToField();
        } else if (key === 'value') {
            this.handleBackToValue();
        }
    }

    handleNewValueChange(event) {
        this.newValueInput = event.detail ? event.detail.value : event.target.value;
    }

    handleNewValueBlankToggle(event) {
        this.newValueIsBlank = event.target.checked;
        if (this.newValueIsBlank) {
            this.newValueInput = '';
        }
    }

    handleOpenConfirm() {
        if (this.confirmDisabled) {
            return;
        }
        this.showConfirmModal = true;
    }

    handleCancelConfirm() {
        this.showConfirmModal = false;
    }

    handleConfirmRun() {
        this.objectsError = undefined;
        this.showConfirmModal = false;
        this.showProgress = true;
        this.runSummary = undefined;

        startBulkEdit({
            objectApiName: this.selectedObjectApiName,
            fieldApiName: this.selectedFieldApiName,
            objectLabel: this.selectedObjectLabel,
            fieldLabel: this.selectedFieldLabel,
            oldValue: this.selectedBucket.isBlank ? null : this.selectedBucket.rawValue,
            isBlankValue: this.selectedBucket.isBlank,
            newValue: this.newValueIsBlank ? null : this.newValueInput,
            newValueIsBlank: this.newValueIsBlank,
            filterFieldApiName: this.selectedFilterFieldApiName,
            filterFieldLabel: this.selectedFilterFieldLabel,
            filterValue: this.hasFilter && !this.selectedFilterBucket.isBlank ? this.selectedFilterBucket.rawValue : null,
            filterIsBlankValue: this.hasFilter ? this.selectedFilterBucket.isBlank : null
        })
            .then((result) => {
                this.currentLogId = result.logId;
                this.currentBatchJobId = result.batchJobId;
                const progressCmp = this.template.querySelector('c-bulk-edit-progress[data-role="run"]');
                if (progressCmp) {
                    // Pass the ids directly rather than relying on the log-id
                    // property binding: this .then() runs outside LWC's render
                    // lifecycle, so the reactive re-render triggered by setting
                    // this.currentLogId above is not guaranteed to have reached
                    // the child yet.
                    progressCmp.start(result.logId, result.batchJobId);
                }
            })
            .catch((error) => {
                this.showProgress = false;
                this.objectsError = (error.body && error.body.message) || 'Unable to start the mass update.';
            });
    }

    handleRunDone(event) {
        this.runSummary = event.detail;
        this.refreshHistory();
    }

    // The History tab's component stays mounted (the tabset doesn't unmount
    // inactive tabs) but only queries once via @wire, so a just-completed
    // run here or in the Record Type Change flow wouldn't show up there
    // without this — call its public refresh() instead of a hard reload.
    refreshHistory() {
        const historyCmp = this.template.querySelector('c-bulk-edit-history');
        if (historyCmp) {
            historyCmp.refresh();
        }
    }

    handleRecordTypeRunDone() {
        this.refreshHistory();
    }

    handleStartAnother() {
        this.showProgress = false;
        this.currentLogId = undefined;
        this.currentBatchJobId = undefined;
        this.runSummary = undefined;
        this.resetFromValues();
        this.wizardStep = 'value';
        this.loadDistribution();
        this.loadFilterFields();
    }

    handleStartOver() {
        this.showProgress = false;
        this.currentLogId = undefined;
        this.currentBatchJobId = undefined;
        this.runSummary = undefined;
        this.selectedObjectApiName = undefined;
        this.selectedObjectLabel = undefined;
        this.resetFromField();
        this.wizardStep = 'object';
    }

    resetFromField() {
        this.selectedFieldApiName = undefined;
        this.selectedFieldLabel = undefined;
        this.selectedFieldDataType = undefined;
        this.fieldOptions = [];
        this.resetFromValues();
    }

    resetFromValues() {
        this.distribution = undefined;
        this.selectedBucket = undefined;
        this.newValueInput = '';
        this.newValueIsBlank = false;
        this.picklistValues = [];
        this.resetFilter();
    }

    resetFilter() {
        this.filterFieldOptions = [];
        this.isLoadingFilterFields = false;
        this.selectedFilterFieldApiName = undefined;
        this.selectedFilterFieldLabel = undefined;
        this.filterDistribution = undefined;
        this.isLoadingFilterDistribution = false;
        this.selectedFilterBucket = undefined;
    }
}
