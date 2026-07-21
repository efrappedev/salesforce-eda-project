import { LightningElement, wire } from 'lwc';
import getRecordTypesForObject from '@salesforce/apex/BulkRecordTypeController.getRecordTypesForObject';
import getSearchableFields from '@salesforce/apex/BulkRecordTypeController.getSearchableFields';
import searchRecords from '@salesforce/apex/BulkRecordTypeController.searchRecords';
import startRecordTypeChange from '@salesforce/apex/BulkRecordTypeController.startRecordTypeChange';

const COLUMNS = [
    { label: 'Name', fieldName: 'name', type: 'text' },
    { label: 'Current Record Type', fieldName: 'recordTypeLabel', type: 'text' }
];

// Own mini step machine (search -> select -> newtype -> run), separate from
// bulkDataEditor's value-match wizard: the selection model here is explicit
// record IDs chosen by the user, not a matched value, so it can't reuse that
// wizard's steps as-is.
export default class BulkRecordTypeChange extends LightningElement {
    columns = COLUMNS;
    wizardStep = 'search';
    loadError;

    // Search step
    recordTypeOptions = [];
    searchFieldOptions = [];
    selectedRecordTypeIdFilter = '';
    selectedRecordTypeFilterLabel;
    selectedSearchFieldApiName;
    selectedSearchFieldLabel;
    searchTerm = '';
    isSearching = false;
    searchError;

    // Select step
    searchResults = [];
    selectedRows = [];

    // New type step
    selectedNewRecordTypeId;
    selectedNewRecordTypeLabel;
    showConfirmModal = false;

    // Run step
    currentLogId;
    currentBatchJobId;
    showProgress = false;
    runSummary;

    @wire(getRecordTypesForObject)
    wiredRecordTypes({ data, error }) {
        if (data) {
            this.recordTypeOptions = data.map((rt) => ({ label: rt.label, value: rt.recordTypeId }));
        } else if (error) {
            this.loadError = (error.body && error.body.message) || 'Unable to load Record Types.';
        }
    }

    @wire(getSearchableFields)
    wiredSearchableFields({ data, error }) {
        if (data) {
            this.searchFieldOptions = data.map((f) => ({ label: f.label, value: f.apiName }));
            if (!this.selectedSearchFieldApiName) {
                const nameOption = this.searchFieldOptions.find((f) => f.value === 'Name');
                if (nameOption) {
                    this.selectedSearchFieldApiName = nameOption.value;
                    this.selectedSearchFieldLabel = nameOption.label;
                }
            }
        } else if (error) {
            this.loadError = (error.body && error.body.message) || 'Unable to load searchable fields.';
        }
    }

    // ---------------------------------------------------------------
    // Step gating
    // ---------------------------------------------------------------

    get isSearchStep() {
        return !this.showProgress && this.wizardStep === 'search';
    }

    get isSelectStep() {
        return !this.showProgress && this.wizardStep === 'select';
    }

    get isNewTypeStep() {
        return !this.showProgress && this.wizardStep === 'newtype';
    }

    get recordTypeFilterOptions() {
        return [{ label: 'Any Record Type', value: '' }, ...this.recordTypeOptions];
    }

    get searchDisabled() {
        const hasRecordTypeFilter = !!this.selectedRecordTypeIdFilter;
        const hasTermFilter = !!(this.searchTerm && this.selectedSearchFieldApiName);
        return this.isSearching || (!hasRecordTypeFilter && !hasTermFilter);
    }

    get searchSummary() {
        const parts = [];
        if (this.selectedRecordTypeFilterLabel) {
            parts.push(`Record Type = ${this.selectedRecordTypeFilterLabel}`);
        }
        if (this.searchTerm && this.selectedSearchFieldLabel) {
            parts.push(`${this.selectedSearchFieldLabel} contains '${this.searchTerm}'`);
        }
        return parts.length ? parts.join('; ') : 'All Accounts';
    }

    get selectedCount() {
        return this.selectedRows.length;
    }

    get continueToNewTypeDisabled() {
        return this.selectedCount === 0;
    }

    get hasSearchResults() {
        return this.searchResults.length > 0;
    }

    get oldValueDisplaySummary() {
        const labels = new Set(this.selectedRows.map((r) => r.recordTypeLabel || '(None)'));
        return Array.from(labels).join(', ');
    }

    get confirmDisabled() {
        return !this.selectedNewRecordTypeId;
    }

    // ---------------------------------------------------------------
    // Handlers — search
    // ---------------------------------------------------------------

    handleRecordTypeFilterChange(event) {
        this.selectedRecordTypeIdFilter = event.detail.value;
        const found = this.recordTypeOptions.find((rt) => rt.value === this.selectedRecordTypeIdFilter);
        this.selectedRecordTypeFilterLabel = found ? found.label : undefined;
    }

    handleSearchFieldChange(event) {
        this.selectedSearchFieldApiName = event.detail.value;
        const found = this.searchFieldOptions.find((f) => f.value === this.selectedSearchFieldApiName);
        this.selectedSearchFieldLabel = found ? found.label : this.selectedSearchFieldApiName;
    }

    handleSearchTermChange(event) {
        this.searchTerm = event.target.value;
    }

    handleSearch() {
        if (this.searchDisabled) {
            return;
        }
        this.searchError = undefined;
        this.isSearching = true;
        searchRecords({
            recordTypeIdFilter: this.selectedRecordTypeIdFilter,
            searchFieldApiName: this.selectedSearchFieldApiName,
            searchTerm: this.searchTerm
        })
            .then((data) => {
                this.searchResults = data.map((r) => ({
                    id: r.id,
                    name: r.name,
                    recordTypeLabel: r.recordTypeLabel || '(None)'
                }));
                this.selectedRows = [];
                this.wizardStep = 'select';
            })
            .catch((error) => {
                this.searchError = (error.body && error.body.message) || 'Unable to search records.';
            })
            .finally(() => {
                this.isSearching = false;
            });
    }

    // ---------------------------------------------------------------
    // Handlers — select
    // ---------------------------------------------------------------

    handleRowSelection(event) {
        this.selectedRows = event.detail.selectedRows;
    }

    handleContinueToNewType() {
        if (this.continueToNewTypeDisabled) {
            return;
        }
        this.selectedNewRecordTypeId = undefined;
        this.selectedNewRecordTypeLabel = undefined;
        this.wizardStep = 'newtype';
    }

    handleBackToSearch() {
        this.searchError = undefined;
        this.wizardStep = 'search';
    }

    // ---------------------------------------------------------------
    // Handlers — new type / confirm / run
    // ---------------------------------------------------------------

    handleNewRecordTypeChange(event) {
        this.selectedNewRecordTypeId = event.detail.value;
        const found = this.recordTypeOptions.find((rt) => rt.value === this.selectedNewRecordTypeId);
        this.selectedNewRecordTypeLabel = found ? found.label : undefined;
    }

    handleBackToSelect() {
        this.wizardStep = 'select';
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

        startRecordTypeChange({
            recordIdsCsv: this.selectedRows.map((r) => r.id).join(','),
            selectedCount: this.selectedRows.length,
            newRecordTypeId: this.selectedNewRecordTypeId,
            newRecordTypeLabel: this.selectedNewRecordTypeLabel,
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
                this.searchError = (error.body && error.body.message) || 'Unable to start the Record Type change.';
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
        this.searchResults = [];
        this.selectedRows = [];
        this.selectedNewRecordTypeId = undefined;
        this.selectedNewRecordTypeLabel = undefined;
        this.wizardStep = 'search';
    }
}
