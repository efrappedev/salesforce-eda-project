import { LightningElement } from 'lwc';
import getEditableObjects from '@salesforce/apex/BulkEditController.getEditableObjects';
import getFilterableFields from '@salesforce/apex/BulkEditController.getFilterableFields';
import getFilterFieldValueDistribution from '@salesforce/apex/BulkEditController.getFilterFieldValueDistribution';
import getCleanableFields from '@salesforce/apex/BulkCleanFieldController.getCleanableFields';
import previewCleanup from '@salesforce/apex/BulkCleanFieldController.previewCleanup';
import startCleanField from '@salesforce/apex/BulkCleanFieldController.startCleanField';

const STEP_ORDER = ['object', 'field', 'filter', 'rules', 'preview', 'run'];

const PREVIEW_COLUMNS = [
    { label: 'Record', fieldName: 'recordDisplay', type: 'text' },
    { label: 'Before', fieldName: 'beforeValue', type: 'text' },
    { label: 'After', fieldName: 'afterValue', type: 'text' }
];

// Own mini step machine (object -> field -> filter -> rules -> preview ->
// run). Unlike bulkDataEditor's value-match wizard, there is no "current
// value to replace" step here: this reads each record's own live value from
// Salesforce server-side and cleans it in place, so paste/match/clipboard
// round-trips (which silently mangle invisible characters like U+202F) never
// enter the picture. See project_prodon_french_narrow_space_bug.
export default class BulkCleanField extends LightningElement {
    previewColumns = PREVIEW_COLUMNS;
    wizardStep = 'object';
    loadError;

    // Step: object
    objectOptions = [];
    isLoadingObjects = true;
    selectedObjectApiName;
    selectedObjectLabel;

    // Step: field
    fieldOptions = [];
    isLoadingFields = false;
    selectedFieldApiName;
    selectedFieldLabel;

    // Step: filter (optional) — same pattern as bulkDataEditor's Step 3
    // column 1, reused here so the filter experience feels identical.
    filterFieldOptions = [];
    isLoadingFilterFields = false;
    selectedFilterFieldApiName;
    selectedFilterFieldLabel;
    filterDistribution;
    isLoadingFilterDistribution = false;
    selectedFilterBucket;

    // Step: rules — free-typed custom text, not a fixed preset, so it covers
    // "todos" (any character or word) per the user's request. Gated behind
    // its own unchecked-by-default checkbox so the field's placeholder
    // example is never mistaken for a value that's actually being applied.
    normalizeSpaces = true;
    collapseSpaces = true;
    trimEdges = true;
    removeCustomText = false;
    customCharsToStrip = '';

    // Step: preview
    isLoadingPreview = false;
    previewError;
    previewResult;

    // Confirm + run
    showConfirmModal = false;
    currentLogId;
    currentBatchJobId;
    showProgress = false;
    runSummary;

    connectedCallback() {
        this.loadObjects();
    }

    loadObjects() {
        this.isLoadingObjects = true;
        getEditableObjects()
            .then((data) => {
                this.objectOptions = data.map((o) => ({ label: o.label, value: o.apiName }));
            })
            .catch((error) => {
                this.loadError = (error.body && error.body.message) || 'Unable to load objects.';
            })
            .finally(() => {
                this.isLoadingObjects = false;
            });
    }

    // ---------------------------------------------------------------
    // Step gating / path
    // ---------------------------------------------------------------

    get activeWizardStep() {
        return this.showProgress ? 'run' : this.wizardStep;
    }

    get pathSteps() {
        const currentIndex = STEP_ORDER.indexOf(this.activeWizardStep);
        const steps = [
            { key: 'object', label: '1. Object', stepIndex: 0 },
            { key: 'field', label: '2. Field', stepIndex: 1 },
            { key: 'filter', label: '3. Filter (optional)', stepIndex: 2 },
            { key: 'rules', label: '4. Cleaning rules', stepIndex: 3 },
            { key: 'preview', label: '5. Preview', stepIndex: 4 },
            { key: 'run', label: '6. Apply', stepIndex: 5 }
        ];
        return steps.map((step, i) => {
            const isComplete =
                step.stepIndex < currentIndex || (step.stepIndex === currentIndex && Boolean(this.runSummary));
            const isCurrent = step.stepIndex === currentIndex;
            let chipClass = 'step-chip';
            if (isComplete) {
                chipClass += ' step-chip_complete';
            } else if (isCurrent) {
                chipClass += ' step-chip_current';
            } else {
                chipClass += ' step-chip_incomplete';
            }
            return {
                ...step,
                isComplete,
                isLast: i === steps.length - 1,
                chipClass
            };
        });
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
        } else if (key === 'filter') {
            this.handleBackToFilter();
        } else if (key === 'rules') {
            this.handleBackToRules();
        }
    }

    get isObjectStep() {
        return !this.showProgress && this.wizardStep === 'object';
    }

    get isFieldStep() {
        return !this.showProgress && this.wizardStep === 'field';
    }

    get isFilterStep() {
        return !this.showProgress && this.wizardStep === 'filter';
    }

    get isRulesStep() {
        return !this.showProgress && this.wizardStep === 'rules';
    }

    get isPreviewStep() {
        return !this.showProgress && this.wizardStep === 'preview';
    }

    // ---------------------------------------------------------------
    // Step: object / field
    // ---------------------------------------------------------------

    handleObjectChange(event) {
        this.selectedObjectApiName = event.detail.value;
        const found = this.objectOptions.find((o) => o.value === this.selectedObjectApiName);
        this.selectedObjectLabel = found ? found.label : this.selectedObjectApiName;
        this.resetFromField();
        this.wizardStep = 'field';
        this.loadFields();
    }

    loadFields() {
        this.loadError = undefined;
        this.isLoadingFields = true;
        this.fieldOptions = [];
        getCleanableFields({ objectApiName: this.selectedObjectApiName })
            .then((data) => {
                this.fieldOptions = data.map((f) => ({ label: f.label, value: f.apiName }));
            })
            .catch((error) => {
                this.loadError = (error.body && error.body.message) || 'Unable to load fields.';
            })
            .finally(() => {
                this.isLoadingFields = false;
            });
    }

    handleFieldChange(event) {
        this.selectedFieldApiName = event.detail.value;
        const found = this.fieldOptions.find((f) => f.value === this.selectedFieldApiName);
        this.selectedFieldLabel = found ? found.label : this.selectedFieldApiName;
        this.resetFromFilter();
        this.wizardStep = 'filter';
        this.loadFilterFields();
    }

    // ---------------------------------------------------------------
    // Step: filter (optional)
    // ---------------------------------------------------------------

    loadFilterFields() {
        this.loadError = undefined;
        this.isLoadingFilterFields = true;
        this.filterFieldOptions = [];
        getFilterableFields({ objectApiName: this.selectedObjectApiName, excludeFieldApiName: this.selectedFieldApiName })
            .then((data) => {
                this.filterFieldOptions = data.map((f) => ({ label: f.label, value: f.apiName }));
            })
            .catch((error) => {
                this.loadError = (error.body && error.body.message) || 'Unable to load filterable fields.';
            })
            .finally(() => {
                this.isLoadingFilterFields = false;
            });
    }

    handleFilterFieldChange(event) {
        this.selectedFilterFieldApiName = event.detail.value;
        const found = this.filterFieldOptions.find((f) => f.value === this.selectedFilterFieldApiName);
        this.selectedFilterFieldLabel = found ? found.label : this.selectedFilterFieldApiName;
        this.filterDistribution = undefined;
        this.selectedFilterBucket = undefined;
        if (this.selectedFilterFieldApiName) {
            this.loadFilterDistribution();
        }
    }

    loadFilterDistribution() {
        this.loadError = undefined;
        this.isLoadingFilterDistribution = true;
        this.filterDistribution = undefined;
        getFilterFieldValueDistribution({ objectApiName: this.selectedObjectApiName, fieldApiName: this.selectedFilterFieldApiName })
            .then((data) => {
                this.filterDistribution = data;
            })
            .catch((error) => {
                this.loadError = (error.body && error.body.message) || 'Unable to load filter values.';
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
    }

    handleRemoveFilter() {
        this.selectedFilterFieldApiName = undefined;
        this.selectedFilterFieldLabel = undefined;
        this.filterDistribution = undefined;
        this.selectedFilterBucket = undefined;
    }

    handleContinueToRules() {
        this.wizardStep = 'rules';
    }

    get hasFilter() {
        return !!this.selectedFilterFieldApiName && !!this.selectedFilterBucket;
    }

    get filterValueDisplay() {
        if (!this.selectedFilterBucket) return '';
        return this.selectedFilterBucket.isBlank ? '(Blank)' : this.selectedFilterBucket.displayValue;
    }

    get selectedFilterRawValue() {
        return this.selectedFilterBucket ? this.selectedFilterBucket.rawValue : undefined;
    }

    get selectedFilterIsBlank() {
        return this.selectedFilterBucket ? this.selectedFilterBucket.isBlank : false;
    }

    get effectiveFilterFieldApiName() {
        return this.hasFilter ? this.selectedFilterFieldApiName : null;
    }

    get effectiveFilterValue() {
        return this.hasFilter && !this.selectedFilterBucket.isBlank ? this.selectedFilterBucket.rawValue : null;
    }

    get effectiveFilterIsBlank() {
        return this.hasFilter ? this.selectedFilterBucket.isBlank : null;
    }

    // ---------------------------------------------------------------
    // Step: rules
    // ---------------------------------------------------------------

    handleNormalizeSpacesToggle(event) {
        this.normalizeSpaces = event.target.checked;
    }

    handleCollapseSpacesToggle(event) {
        this.collapseSpaces = event.target.checked;
    }

    handleTrimEdgesToggle(event) {
        this.trimEdges = event.target.checked;
    }

    handleRemoveCustomTextToggle(event) {
        this.removeCustomText = event.target.checked;
    }

    handleCustomCharsChange(event) {
        this.customCharsToStrip = event.detail ? event.detail.value : event.target.value;
    }

    get customTextInputDisabled() {
        return !this.removeCustomText;
    }

    // Only non-empty while the checkbox is checked — so leftover text left
    // in the (now disabled) input from an earlier check/uncheck never
    // silently applies, and the placeholder example is never mistaken for
    // an active value.
    get effectiveCustomCharsToStrip() {
        return this.removeCustomText && this.customCharsToStrip && this.customCharsToStrip.length > 0 ? this.customCharsToStrip : null;
    }

    get rulesSummary() {
        const parts = [];
        if (this.normalizeSpaces) parts.push('Normalize spaces');
        if (this.collapseSpaces) parts.push('Collapse spaces');
        if (this.trimEdges) parts.push('Trim edges');
        if (this.effectiveCustomCharsToStrip) {
            parts.push(`Remove: ${this.effectiveCustomCharsToStrip}`);
        }
        return parts.length ? parts.join('; ') : '(no rules selected)';
    }

    get noRulesSelected() {
        return !this.normalizeSpaces && !this.collapseSpaces && !this.trimEdges && !this.effectiveCustomCharsToStrip;
    }

    handleRunPreview() {
        this.previewError = undefined;
        this.isLoadingPreview = true;
        this.previewResult = undefined;

        previewCleanup({
            objectApiName: this.selectedObjectApiName,
            fieldApiName: this.selectedFieldApiName,
            filterFieldApiName: this.effectiveFilterFieldApiName,
            filterValue: this.effectiveFilterValue,
            filterIsBlankValue: this.effectiveFilterIsBlank,
            normalizeSpaces: this.normalizeSpaces,
            collapseSpaces: this.collapseSpaces,
            trimEdges: this.trimEdges,
            customCharsToStrip: this.effectiveCustomCharsToStrip
        })
            .then((result) => {
                this.previewResult = result;
                this.wizardStep = 'preview';
            })
            .catch((error) => {
                this.previewError = (error.body && error.body.message) || 'Unable to load a preview.';
            })
            .finally(() => {
                this.isLoadingPreview = false;
            });
    }

    // ---------------------------------------------------------------
    // Step: preview
    // ---------------------------------------------------------------

    get previewChangedRows() {
        return this.previewResult ? this.previewResult.rows.filter((r) => r.willChange) : [];
    }

    // The 200-record preview sample covers every matching record whenever
    // totalMatching is under the cap — in that case sampleWouldChange is
    // not an estimate, it's the exact count the batch will update, since
    // it's the same cleanValue() logic run over the same rows.
    get previewIsExhaustive() {
        return !!this.previewResult && this.previewResult.sampleSize >= this.previewResult.totalMatching;
    }

    get previewSampleText() {
        if (!this.previewResult) return '';
        const { sampleSize, sampleWouldChange, totalMatching } = this.previewResult;
        if (this.previewIsExhaustive) {
            return `${sampleWouldChange} of ${totalMatching} matching record(s) would change. The rest are already clean.`;
        }
        return `${sampleWouldChange} of the first ${sampleSize} record(s) scanned would change. Running will scan and clean all ${totalMatching} matching record(s), not just this sample.`;
    }

    get previewHasChanges() {
        return this.previewChangedRows.length > 0;
    }

    // Mirrors previewSampleText's exhaustive-vs-sampled distinction: the
    // confirm modal's "N records will be updated" must mean records that
    // will actually change, not every candidate the WHERE clause matched —
    // unlike the other tabs, Clean Field's batch skips records that don't
    // need cleaning, so totalMatching alone would overstate the impact.
    get previewAffectedCount() {
        if (!this.previewResult) return 0;
        return this.previewIsExhaustive ? this.previewResult.sampleWouldChange : this.previewResult.totalMatching;
    }

    // ---------------------------------------------------------------
    // Back navigation
    // ---------------------------------------------------------------

    handleBackToObject() {
        this.loadError = undefined;
        this.resetFromField();
        this.wizardStep = 'object';
    }

    handleBackToField() {
        this.loadError = undefined;
        this.resetFromFilter();
        this.wizardStep = 'field';
    }

    handleBackToFilter() {
        this.loadError = undefined;
        this.previewError = undefined;
        this.previewResult = undefined;
        this.wizardStep = 'filter';
    }

    handleBackToRules() {
        this.previewError = undefined;
        this.previewResult = undefined;
        this.wizardStep = 'rules';
    }

    // ---------------------------------------------------------------
    // Confirm / run
    // ---------------------------------------------------------------

    handleOpenConfirm() {
        this.showConfirmModal = true;
    }

    handleCancelConfirm() {
        this.showConfirmModal = false;
    }

    handleConfirmRun() {
        this.loadError = undefined;
        this.showConfirmModal = false;
        this.showProgress = true;
        this.runSummary = undefined;

        startCleanField({
            objectApiName: this.selectedObjectApiName,
            objectLabel: this.selectedObjectLabel,
            fieldApiName: this.selectedFieldApiName,
            fieldLabel: this.selectedFieldLabel,
            filterFieldApiName: this.effectiveFilterFieldApiName,
            filterFieldLabel: this.hasFilter ? this.selectedFilterFieldLabel : null,
            filterValue: this.effectiveFilterValue,
            filterIsBlankValue: this.effectiveFilterIsBlank,
            normalizeSpaces: this.normalizeSpaces,
            collapseSpaces: this.collapseSpaces,
            trimEdges: this.trimEdges,
            customCharsToStrip: this.effectiveCustomCharsToStrip
        })
            .then((result) => {
                this.currentLogId = result.logId;
                this.currentBatchJobId = result.batchJobId;
                const progressCmp = this.template.querySelector('c-bulk-edit-progress[data-role="run"]');
                if (progressCmp) {
                    // See bulkDataEditor.handleConfirmRun for why the ids are
                    // passed directly instead of relying on property binding.
                    progressCmp.start(result.logId, result.batchJobId);
                }
            })
            .catch((error) => {
                this.showProgress = false;
                this.loadError = (error.body && error.body.message) || 'Unable to start the cleanup.';
            });
    }

    handleRunDone(event) {
        this.runSummary = event.detail;
        // Lets bulkDataEditor refresh the (separately mounted) History tab
        // without the user needing a hard refresh to see this run.
        this.dispatchEvent(new CustomEvent('rundone'));
    }

    handleStartAnother() {
        this.showProgress = false;
        this.currentLogId = undefined;
        this.currentBatchJobId = undefined;
        this.runSummary = undefined;
        this.previewResult = undefined;
        this.wizardStep = 'rules';
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
        this.fieldOptions = [];
        this.resetFromFilter();
    }

    resetFromFilter() {
        this.filterFieldOptions = [];
        this.isLoadingFilterFields = false;
        this.selectedFilterFieldApiName = undefined;
        this.selectedFilterFieldLabel = undefined;
        this.filterDistribution = undefined;
        this.isLoadingFilterDistribution = false;
        this.selectedFilterBucket = undefined;
        this.normalizeSpaces = true;
        this.collapseSpaces = true;
        this.trimEdges = true;
        this.removeCustomText = false;
        this.customCharsToStrip = '';
        this.previewError = undefined;
        this.previewResult = undefined;
    }
}
