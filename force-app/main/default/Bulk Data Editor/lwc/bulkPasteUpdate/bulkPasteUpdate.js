import { LightningElement, wire } from 'lwc';
import getEditableObjects from '@salesforce/apex/BulkEditController.getEditableObjects';
import getEditableFields from '@salesforce/apex/BulkEditController.getEditableFields';
import getPicklistValues from '@salesforce/apex/BulkEditController.getPicklistValues';
import getSearchableFields from '@salesforce/apex/BulkPasteUpdateController.getSearchableFields';
import matchRecords from '@salesforce/apex/BulkPasteUpdateController.matchRecords';
import startPasteUpdate from '@salesforce/apex/BulkPasteUpdateController.startPasteUpdate';

const NUMERIC_TYPES = new Set(['DOUBLE', 'INTEGER', 'CURRENCY', 'PERCENT']);

const STEP_ORDER = ['object', 'searchfield', 'field', 'paste', 'match', 'run'];

const COLUMNS = [
    { label: 'Search value', fieldName: 'searchValue', type: 'text' },
    { label: 'Matched record', fieldName: 'recordDisplay', type: 'text' },
    { label: 'Old value', fieldName: 'oldValueDisplay', type: 'text' },
    { label: 'New value', fieldName: 'newValueDisplay', type: 'text' },
    { label: 'Status', fieldName: 'status', type: 'text' }
];

// Own mini step machine (object -> searchfield -> field -> paste -> match ->
// run), separate from bulkDataEditor's value-match wizard and
// bulkRecordTypeChange's search-and-select wizard: the selection model here
// is "paste a list of external-id-style values, match each to at most one
// record", which neither of those flows supports.
export default class BulkPasteUpdate extends LightningElement {
    columns = COLUMNS;
    wizardStep = 'object';
    loadError;

    // Step: object
    objectOptions = [];
    isLoadingObjects = true;
    selectedObjectApiName;
    selectedObjectLabel;

    // Step: search field
    searchFieldOptions = [];
    isLoadingSearchFields = false;
    selectedSearchFieldApiName;
    selectedSearchFieldLabel;

    // Step: field to change
    fieldOptions = [];
    isLoadingFields = false;
    selectedFieldApiName;
    selectedFieldLabel;
    selectedFieldDataType;
    picklistValues = [];

    // Step: paste
    pasteSearchValues = '';
    useSameValue = false;
    uniformNewValueInput = '';
    uniformNewValueIsBlank = false;
    pasteNewValues = '';
    pasteError;
    newValueBySearchValue = new Map();

    // Step: match & review
    isMatching = false;
    matchError;
    matchResults = [];
    showConfirmModal = false;

    // Step: run
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
            this.loadError = (error.body && error.body.message) || 'Unable to load objects.';
        }
    }

    // ---------------------------------------------------------------
    // Step gating
    // ---------------------------------------------------------------

    get activeWizardStep() {
        return this.showProgress ? 'run' : this.wizardStep;
    }

    get pathSteps() {
        const currentIndex = STEP_ORDER.indexOf(this.activeWizardStep);
        const steps = [
            { key: 'object', label: '1. Object', stepIndex: 0 },
            { key: 'searchfield', label: '2. Search field', stepIndex: 1 },
            { key: 'field', label: '3. Field to change', stepIndex: 2 },
            { key: 'paste', label: '4. Paste values', stepIndex: 3 },
            { key: 'match', label: '5. Review matches', stepIndex: 4 },
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
        } else if (key === 'searchfield') {
            this.handleBackToSearchField();
        } else if (key === 'field') {
            this.handleBackToField();
        } else if (key === 'paste') {
            this.handleBackToPaste();
        }
    }

    get searchColumnLabel() {
        return this.selectedSearchFieldLabel
            ? `${this.selectedSearchFieldLabel} — values to search for (one per line)`
            : 'Values to search for (one per line)';
    }

    get newColumnLabel() {
        return this.selectedFieldLabel
            ? `${this.selectedFieldLabel} — new values (one per line)`
            : 'New values (one per line)';
    }

    // Widened only when the two paste columns are both visible (per-row
    // distinct values), same reasoning as bulkDataEditor's wizard-container_wide.
    get containerClass() {
        return this.wizardStep === 'paste' ? 'pu-container pu-container_wide' : 'pu-container';
    }

    get isObjectStep() {
        return !this.showProgress && this.wizardStep === 'object';
    }

    get isSearchFieldStep() {
        return !this.showProgress && this.wizardStep === 'searchfield';
    }

    get isFieldStep() {
        return !this.showProgress && this.wizardStep === 'field';
    }

    get isPasteStep() {
        return !this.showProgress && this.wizardStep === 'paste';
    }

    get isMatchStep() {
        return !this.showProgress && this.wizardStep === 'match';
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

    get searchLines() {
        return this.pasteSearchValues
            .split('\n')
            .map((v) => v.trim())
            .filter((v) => v.length > 0);
    }

    get newLines() {
        return this.pasteNewValues
            .split('\n')
            .map((v) => v.trim())
            .filter((v) => v.length > 0);
    }

    get matchDisabled() {
        if (this.isMatching || this.searchLines.length === 0) {
            return true;
        }
        if (this.useSameValue) {
            return !this.uniformNewValueIsBlank && !this.uniformNewValueInput;
        }
        return this.newLines.length !== this.searchLines.length;
    }

    get lineCountMismatch() {
        return !this.useSameValue && this.pasteNewValues.length > 0 && this.newLines.length !== this.searchLines.length;
    }

    get matchedRows() {
        return this.matchResults.filter((r) => r.status === 'Matched');
    }

    get matchedCount() {
        return this.matchedRows.length;
    }

    get hasUnmatchedRows() {
        return this.matchResults.some((r) => r.status !== 'Matched');
    }

    get excludedCount() {
        return this.matchResults.length - this.matchedCount;
    }

    get confirmDisabled() {
        return this.matchedCount === 0;
    }

    get uniformValueDisplay() {
        return this.uniformNewValueIsBlank ? '(Blank)' : this.uniformNewValueInput;
    }

    get newValueDisplaySummary() {
        if (this.useSameValue) {
            return this.uniformValueDisplay;
        }
        return `(${this.matchedCount} distinct value(s))`;
    }

    get searchSummary() {
        return `${this.selectedSearchFieldLabel} matched against ${this.searchLines.length} pasted value(s)`;
    }

    // ---------------------------------------------------------------
    // Handlers — object / search field / field
    // ---------------------------------------------------------------

    handleObjectChange(event) {
        this.selectedObjectApiName = event.detail.value;
        const found = this.objectOptions.find((o) => o.value === this.selectedObjectApiName);
        this.selectedObjectLabel = found ? found.label : this.selectedObjectApiName;
        this.resetFromSearchField();
        this.wizardStep = 'searchfield';
        this.loadSearchFields();
    }

    loadSearchFields() {
        this.loadError = undefined;
        this.isLoadingSearchFields = true;
        this.searchFieldOptions = [];
        getSearchableFields({ objectApiName: this.selectedObjectApiName })
            .then((data) => {
                this.searchFieldOptions = data.map((f) => ({ label: f.label, value: f.apiName }));
            })
            .catch((error) => {
                this.loadError = (error.body && error.body.message) || 'Unable to load searchable fields.';
            })
            .finally(() => {
                this.isLoadingSearchFields = false;
            });
    }

    handleSearchFieldChange(event) {
        this.selectedSearchFieldApiName = event.detail.value;
        const found = this.searchFieldOptions.find((f) => f.value === this.selectedSearchFieldApiName);
        this.selectedSearchFieldLabel = found ? found.label : this.selectedSearchFieldApiName;
        this.resetFromField();
        this.wizardStep = 'field';
        this.loadFields();
    }

    loadFields() {
        this.loadError = undefined;
        this.isLoadingFields = true;
        this.fieldOptions = [];
        getEditableFields({ objectApiName: this.selectedObjectApiName })
            .then((data) => {
                this.fieldOptions = data.map((f) => ({ label: f.label, value: f.apiName, dataType: f.dataType }));
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
        this.selectedFieldDataType = found ? found.dataType : undefined;
        this.resetFromPaste();
        this.wizardStep = 'paste';
        if (this.selectedFieldIsPicklist) {
            this.loadPicklistValues();
        }
    }

    loadPicklistValues() {
        getPicklistValues({ objectApiName: this.selectedObjectApiName, fieldApiName: this.selectedFieldApiName }).then((data) => {
            this.picklistValues = data;
        });
    }

    // ---------------------------------------------------------------
    // Handlers — paste
    // ---------------------------------------------------------------

    handleSearchValuesChange(event) {
        this.pasteSearchValues = event.target.value;
    }

    handleUseSameValueToggle(event) {
        this.useSameValue = event.target.checked;
    }

    handleUniformValueChange(event) {
        this.uniformNewValueInput = event.detail ? event.detail.value : event.target.value;
    }

    handleUniformBlankToggle(event) {
        this.uniformNewValueIsBlank = event.target.checked;
        if (this.uniformNewValueIsBlank) {
            this.uniformNewValueInput = '';
        }
    }

    handleNewValuesChange(event) {
        this.pasteNewValues = event.target.value;
    }

    handleMatch() {
        if (this.matchDisabled) {
            return;
        }
        this.pasteError = undefined;
        this.matchError = undefined;
        this.isMatching = true;
        const searchValues = this.searchLines;

        if (!this.useSameValue) {
            this.newValueBySearchValue = new Map();
            const newLines = this.newLines;
            searchValues.forEach((sv, i) => {
                if (!this.newValueBySearchValue.has(sv)) {
                    this.newValueBySearchValue.set(sv, newLines[i]);
                }
            });
        }

        matchRecords({
            objectApiName: this.selectedObjectApiName,
            searchFieldApiName: this.selectedSearchFieldApiName,
            searchValues,
            targetFieldApiName: this.selectedFieldApiName
        })
            .then((data) => {
                this.matchResults = data
                    .map((r) => ({
                        ...r,
                        recordDisplay: r.recordDisplay || (r.status === 'NotFound' ? '(not found)' : '(excluded — duplicate)'),
                        // currentValue only comes back for Matched/Duplicate rows
                        // (NotFound has no record to read it from) — '—' there
                        // instead of '(Blank)' so it isn't misread as "the field
                        // was empty" when really there's simply no record.
                        oldValueDisplay: r.status === 'NotFound' ? '—' : r.currentValue || '(Blank)',
                        newValueDisplay: this.useSameValue ? this.uniformValueDisplay : this.newValueBySearchValue.get(r.searchValue) || '(Blank)'
                    }))
                    // Excluded rows (NotFound / Duplicate) surface first so they're
                    // visible without scrolling through hundreds of Matched rows —
                    // Array.sort is stable, so relative order within each group is
                    // otherwise unchanged from the pasted order.
                    .sort((a, b) => (a.status === 'Matched') - (b.status === 'Matched'));
                this.wizardStep = 'match';
            })
            .catch((error) => {
                this.matchError = (error.body && error.body.message) || 'Unable to match records.';
            })
            .finally(() => {
                this.isMatching = false;
            });
    }

    // ---------------------------------------------------------------
    // Handlers — match & review / confirm / run
    // ---------------------------------------------------------------

    handleBackToObject() {
        this.loadError = undefined;
        this.resetFromSearchField();
        this.wizardStep = 'object';
    }

    handleBackToSearchField() {
        this.loadError = undefined;
        this.resetFromField();
        this.wizardStep = 'searchfield';
    }

    handleBackToField() {
        this.loadError = undefined;
        this.resetFromPaste();
        this.wizardStep = 'field';
    }

    handleBackToPaste() {
        this.matchError = undefined;
        this.matchResults = [];
        this.wizardStep = 'paste';
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
        this.showConfirmModal = false;
        this.showProgress = true;
        this.runSummary = undefined;

        const newValueByRecordId = {};
        this.matchedRows.forEach((r) => {
            const value = this.useSameValue
                ? this.uniformNewValueIsBlank
                    ? ''
                    : this.uniformNewValueInput
                : this.newValueBySearchValue.get(r.searchValue) || '';
            newValueByRecordId[r.recordId] = value;
        });

        startPasteUpdate({
            objectApiName: this.selectedObjectApiName,
            objectLabel: this.selectedObjectLabel,
            fieldApiName: this.selectedFieldApiName,
            fieldLabel: this.selectedFieldLabel,
            searchFieldLabel: this.selectedSearchFieldLabel,
            newValueByRecordId,
            matchedCount: this.matchedCount,
            searchSummary: this.searchSummary
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
                this.matchError = (error.body && error.body.message) || 'Unable to start the update.';
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
        this.resetFromPaste();
        this.wizardStep = 'paste';
    }

    handleStartOver() {
        this.showProgress = false;
        this.currentLogId = undefined;
        this.currentBatchJobId = undefined;
        this.runSummary = undefined;
        this.selectedObjectApiName = undefined;
        this.selectedObjectLabel = undefined;
        this.resetFromSearchField();
        this.wizardStep = 'object';
    }

    resetFromSearchField() {
        this.selectedSearchFieldApiName = undefined;
        this.selectedSearchFieldLabel = undefined;
        this.searchFieldOptions = [];
        this.resetFromField();
    }

    resetFromField() {
        this.selectedFieldApiName = undefined;
        this.selectedFieldLabel = undefined;
        this.selectedFieldDataType = undefined;
        this.fieldOptions = [];
        this.picklistValues = [];
        this.resetFromPaste();
    }

    resetFromPaste() {
        this.pasteSearchValues = '';
        this.useSameValue = false;
        this.uniformNewValueInput = '';
        this.uniformNewValueIsBlank = false;
        this.pasteNewValues = '';
        this.pasteError = undefined;
        this.newValueBySearchValue = new Map();
        this.matchError = undefined;
        this.matchResults = [];
    }
}
