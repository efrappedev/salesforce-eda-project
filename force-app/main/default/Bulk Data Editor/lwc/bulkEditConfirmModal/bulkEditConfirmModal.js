import { LightningElement, api } from 'lwc';

export default class BulkEditConfirmModal extends LightningElement {
    @api objectLabel;
    @api fieldLabel;
    @api oldValueDisplay;
    @api newValueDisplay;
    @api affectedCount = 0;
    @api isLoadingCount = false;
    @api filterFieldLabel;
    @api filterValueDisplay;

    acknowledged = false;

    get hasFilter() {
        return !!this.filterFieldLabel;
    }

    get confirmDisabled() {
        return !this.acknowledged || this.isLoadingCount || this.affectedCount === 0;
    }

    get affectedCountLabel() {
        if (this.isLoadingCount) {
            return 'Counting matching records...';
        }
        if (this.affectedCount === 1) {
            return '1 record will be updated';
        }
        return `${this.affectedCount} records will be updated`;
    }

    get zeroRecordsWarning() {
        return !this.isLoadingCount && this.affectedCount === 0;
    }

    handleAcknowledgeChange(event) {
        this.acknowledged = event.target.checked;
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }

    handleConfirm() {
        if (this.confirmDisabled) {
            return;
        }
        this.dispatchEvent(new CustomEvent('confirm'));
    }
}
