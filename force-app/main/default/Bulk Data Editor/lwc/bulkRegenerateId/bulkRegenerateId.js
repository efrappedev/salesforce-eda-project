import { LightningElement } from 'lwc';
import getSearchableFields from '@salesforce/apex/BulkPasteUpdateController.getSearchableFields';
import matchRecords from '@salesforce/apex/BulkPasteUpdateController.matchRecords';
import startPasteUpdate from '@salesforce/apex/BulkPasteUpdateController.startPasteUpdate';
import previewContactIdRegeneration from '@salesforce/apex/RegenerateIdController.previewContactIdRegeneration';

const STEP_ORDER = ['object', 'searchfield', 'paste', 'match', 'run'];

// Account_GenerateID.trigger fires on before-update and self-assigns
// whenever ID_Account__c is blank, so writing blank through the existing
// startPasteUpdate is enough — Contact_GenerateID.trigger only fires on
// before-insert, so Contact needs its new value computed up front by
// RegenerateIdController and written directly instead of relying on a
// trigger. See the "Regenerate ID" plan for the full reasoning.
const TARGET_FIELD_BY_OBJECT = {
    Account: { apiName: 'ID_Account__c', label: 'Account custom ID (ID_Account__c)' },
    Contact: { apiName: 'ID_Contact__c', label: 'Contact custom ID (ID_Contact__c)' }
};

const COLUMNS = [
    { label: 'Search value', fieldName: 'searchValue', type: 'text' },
    { label: 'Matched record', fieldName: 'recordDisplay', type: 'text' },
    { label: 'Current ID', fieldName: 'oldIdDisplay', type: 'text' },
    { label: 'New ID', fieldName: 'newIdDisplay', type: 'text' },
    { label: 'Status', fieldName: 'status', type: 'text' }
];

// Own mini step machine (object -> searchfield -> paste -> match -> run),
// one step shorter than bulkPasteUpdate's since the target field and the
// fact that it's being regenerated are both implied by the object choice —
// there's no "field to change" or "new value" step here.
export default class BulkRegenerateId extends LightningElement {
    columns = COLUMNS;
    wizardStep = 'object';
    loadError;

    // Step: object — exactly Account / Contact, not the general
    // getEditableObjects wire, since this tab only makes sense for the two
    // objects that have a custom-ID-generation trigger.
    objectOptions = [
        { label: 'Account', value: 'Account' },
        { label: 'Contact', value: 'Contact' }
    ];
    selectedObjectApiName;
    selectedObjectLabel;

    // Step: search field
    searchFieldOptions = [];
    isLoadingSearchFields = false;
    selectedSearchFieldApiName;
    selectedSearchFieldLabel;

    // Step: paste
    pasteSearchValues = '';

    // Step: match & review
    isMatching = false;
    matchError;
    matchResults = [];
    newIdByRecordId = new Map();
    showConfirmModal = false;

    // Step: run
    currentLogId;
    currentBatchJobId;
    showProgress = false;
    runSummary;

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
            { key: 'paste', label: '3. Paste values', stepIndex: 2 },
            { key: 'match', label: '4. Review matches', stepIndex: 3 },
            { key: 'run', label: '5. Apply', stepIndex: 4 }
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
        } else if (key === 'paste') {
            this.handleBackToPaste();
        }
    }

    get isObjectStep() {
        return !this.showProgress && this.wizardStep === 'object';
    }

    get isSearchFieldStep() {
        return !this.showProgress && this.wizardStep === 'searchfield';
    }

    get isPasteStep() {
        return !this.showProgress && this.wizardStep === 'paste';
    }

    get isMatchStep() {
        return !this.showProgress && this.wizardStep === 'match';
    }

    get isContactObject() {
        return this.selectedObjectApiName === 'Contact';
    }

    get targetField() {
        return TARGET_FIELD_BY_OBJECT[this.selectedObjectApiName];
    }

    get searchColumnLabel() {
        return this.selectedSearchFieldLabel
            ? `${this.selectedSearchFieldLabel} — values to search for (one per line)`
            : 'Values to search for (one per line)';
    }

    get containerClass() {
        return this.wizardStep === 'match' ? 'ri-container ri-container_wide' : 'ri-container';
    }

    get searchLines() {
        return this.pasteSearchValues
            .split('\n')
            .map((v) => v.trim())
            .filter((v) => v.length > 0);
    }

    get matchDisabled() {
        return this.isMatching || this.searchLines.length === 0;
    }

    get matchedRows() {
        return this.matchResults.filter((r) => r.status === 'Matched');
    }

    // For Account every Matched row is regenerable (blanking + the live
    // trigger does the rest). For Contact only rows RegenerateIdController
    // could actually compute a new value for are regenerable — a Matched
    // Contact with a blank/unusable First or Last Name is excluded.
    get regenerableRows() {
        return this.matchedRows.filter((r) => (this.isContactObject ? this.newIdByRecordId.has(r.recordId) : true));
    }

    get matchedCount() {
        return this.regenerableRows.length;
    }

    get hasExcludedRows() {
        return this.matchResults.length !== this.regenerableRows.length;
    }

    get confirmDisabled() {
        return this.matchedCount === 0;
    }

    get displayResults() {
        return this.matchResults.map((r) => {
            let newIdDisplay = '—';
            if (r.status === 'Matched') {
                if (this.isContactObject) {
                    newIdDisplay = this.newIdByRecordId.has(r.recordId)
                        ? this.newIdByRecordId.get(r.recordId)
                        : 'Cannot regenerate — missing First/Last Name';
                } else {
                    newIdDisplay = '(auto-generated on save)';
                }
            }
            return {
                ...r,
                recordDisplay: r.recordDisplay || (r.status === 'NotFound' ? '(not found)' : '(excluded — duplicate)'),
                oldIdDisplay: r.status === 'NotFound' ? '—' : r.currentValue || '(Blank)',
                newIdDisplay
            };
        });
    }

    get newValueDisplaySummary() {
        return this.isContactObject ? '(distinct new ID computed per record)' : '(auto-generated per record on save)';
    }

    get searchSummary() {
        return `${this.selectedSearchFieldLabel} matched against ${this.searchLines.length} pasted value(s) — regenerating ${this.targetField.apiName}`;
    }

    // ---------------------------------------------------------------
    // Handlers — object / search field
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
        this.resetFromPaste();
        this.wizardStep = 'paste';
    }

    // ---------------------------------------------------------------
    // Handlers — paste / match
    // ---------------------------------------------------------------

    handleSearchValuesChange(event) {
        this.pasteSearchValues = event.target.value;
    }

    handleMatch() {
        if (this.matchDisabled) {
            return;
        }
        this.matchError = undefined;
        this.isMatching = true;
        const searchValues = this.searchLines;

        matchRecords({
            objectApiName: this.selectedObjectApiName,
            searchFieldApiName: this.selectedSearchFieldApiName,
            searchValues,
            targetFieldApiName: this.targetField ? this.targetField.apiName : null
        })
            .then((data) => {
                this.matchResults = data;
                this.wizardStep = 'match';
                if (this.isContactObject) {
                    return this.loadContactPreview();
                }
                this.newIdByRecordId = new Map();
                return undefined;
            })
            .catch((error) => {
                this.matchError = (error.body && error.body.message) || 'Unable to match records.';
            })
            .finally(() => {
                this.isMatching = false;
            });
    }

    loadContactPreview() {
        const contactIds = this.matchedRows.map((r) => r.recordId).filter((id) => id);
        if (contactIds.length === 0) {
            this.newIdByRecordId = new Map();
            return undefined;
        }
        return previewContactIdRegeneration({ contactIds })
            .then((data) => {
                this.newIdByRecordId = new Map(Object.entries(data));
            })
            .catch((error) => {
                this.matchError = (error.body && error.body.message) || 'Unable to compute new Contact IDs.';
                this.newIdByRecordId = new Map();
            });
    }

    // ---------------------------------------------------------------
    // Handlers — back navigation
    // ---------------------------------------------------------------

    handleBackToObject() {
        this.loadError = undefined;
        this.resetFromSearchField();
        this.wizardStep = 'object';
    }

    handleBackToSearchField() {
        this.loadError = undefined;
        this.resetFromPaste();
        this.wizardStep = 'searchfield';
    }

    handleBackToPaste() {
        this.matchError = undefined;
        this.matchResults = [];
        this.newIdByRecordId = new Map();
        this.wizardStep = 'paste';
    }

    // ---------------------------------------------------------------
    // Handlers — confirm / run
    // ---------------------------------------------------------------

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
        this.regenerableRows.forEach((r) => {
            newValueByRecordId[r.recordId] = this.isContactObject ? this.newIdByRecordId.get(r.recordId) : '';
        });

        startPasteUpdate({
            objectApiName: this.selectedObjectApiName,
            objectLabel: this.selectedObjectLabel,
            fieldApiName: this.targetField.apiName,
            fieldLabel: this.targetField.label,
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
                    // See bulkPasteUpdate.handleConfirmRun for why the ids are
                    // passed directly instead of relying on property binding.
                    progressCmp.start(result.logId, result.batchJobId);
                }
            })
            .catch((error) => {
                this.showProgress = false;
                this.matchError = (error.body && error.body.message) || 'Unable to start the regeneration.';
            });
    }

    handleRunDone(event) {
        this.runSummary = event.detail;
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
        this.resetFromPaste();
    }

    resetFromPaste() {
        this.pasteSearchValues = '';
        this.matchError = undefined;
        this.matchResults = [];
        this.newIdByRecordId = new Map();
    }
}
