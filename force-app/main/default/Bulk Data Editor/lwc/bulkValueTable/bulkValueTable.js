import { LightningElement, api } from 'lwc';

export default class BulkValueTable extends LightningElement {
    @api isPicklist = false;
    @api selectedRawValue;
    @api selectedIsBlank = false;

    _buckets = [];
    searchTerm = '';

    @api
    get buckets() {
        return this._buckets;
    }
    set buckets(value) {
        this._buckets = value || [];
    }

    get hasBuckets() {
        return this._buckets.length > 0;
    }

    get filteredBuckets() {
        const term = (this.searchTerm || '').toLowerCase();
        const list = term
            ? this._buckets.filter((b) => (b.displayValue || '').toLowerCase().includes(term))
            : this._buckets;

        return list.map((bucket) => {
            const isSelected = this.isRowSelected(bucket);
            return {
                ...bucket,
                rowKey: bucket.isBlank ? '__blank__' : bucket.rawValue,
                rowClass: 'value-row' + (isSelected ? ' value-row_selected' : ''),
                checkboxClass: 'value-checkbox' + (isSelected ? ' value-checkbox_checked' : ''),
                isSelected,
                blankBadgeClass: bucket.isBlank ? 'slds-badge slds-theme_warning' : 'slds-hide'
            };
        });
    }

    isRowSelected(bucket) {
        if (bucket.isBlank) {
            return this.selectedIsBlank === true;
        }
        if (this.selectedRawValue === undefined || this.selectedRawValue === null) {
            return false;
        }
        return bucket.rawValue === this.selectedRawValue;
    }

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
    }

    handleRowClick(event) {
        const rowKey = event.currentTarget.dataset.rowKey;
        const bucket = this._buckets.find((b) => (b.isBlank ? '__blank__' : b.rawValue) === rowKey);
        if (!bucket) {
            return;
        }
        this.dispatchEvent(
            new CustomEvent('select', {
                detail: {
                    rawValue: bucket.rawValue,
                    displayValue: bucket.displayValue,
                    isBlank: bucket.isBlank,
                    recordCount: bucket.recordCount
                }
            })
        );
    }
}
