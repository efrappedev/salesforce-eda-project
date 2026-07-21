import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getEditHistory from '@salesforce/apex/BulkEditController.getEditHistory';
import undoBulkEdit from '@salesforce/apex/BulkEditController.undoBulkEdit';

export default class BulkEditHistory extends LightningElement {
    isLoading = true;
    errorMessage;
    undoingLogId;
    activeUndoLogId;
    toastMessage;
    toastVariant;
    toastCountdown;

    _rawEntries = [];
    _wiredResult;
    _startedProgressFor;
    _toastIntervalId;

    TOAST_AUTO_DISMISS_SECONDS = 4;

    // Called from bulkDataEditor after a bulk edit / Record Type change run
    // completes, so the just-made change shows up here without a hard
    // refresh — this component stays mounted across tab switches (the
    // tabset doesn't unmount inactive tabs), so a plain public method is
    // enough; no pubsub/message channel needed.
    @api
    refresh() {
        this.handleRefresh();
    }

    disconnectedCallback() {
        this.clearToastTimer();
    }

    renderedCallback() {
        if (this.activeUndoLogId && this.activeUndoLogId !== this._startedProgressFor) {
            const progressCmp = this.template.querySelector(
                `[data-progress-log-id="${this.activeUndoLogId}"]`
            );
            if (progressCmp) {
                this._startedProgressFor = this.activeUndoLogId;
                progressCmp.start(this.activeUndoLogId);
            }
        }
    }

    @wire(getEditHistory, { limitCount: 50 })
    wiredHistory(result) {
        this._wiredResult = result;
        this.isLoading = false;
        if (result.data) {
            this.errorMessage = undefined;
            this._rawEntries = result.data;
        } else if (result.error) {
            this.errorMessage = (result.error.body && result.error.body.message) || 'Unable to load history.';
        }
    }

    badgeClassForStatus(status) {
        if (status === 'Completed' || status === 'Undone') {
            return 'slds-badge slds-theme_success';
        }
        if (status === 'Completed with Errors' || status === 'Undo Failed') {
            return 'slds-badge slds-theme_warning';
        }
        if (status === 'Failed') {
            return 'slds-badge slds-theme_error';
        }
        return 'slds-badge';
    }

    statusLabelForStatus(status) {
        return status === 'Undone' ? 'Already Reverted' : status;
    }

    get displayEntries() {
        return this._rawEntries.map((entry) => ({
            ...entry,
            statusBadgeClass: this.badgeClassForStatus(entry.status),
            statusLabel: this.statusLabelForStatus(entry.status),
            isUndoing: entry.logId === this.undoingLogId,
            showProgress: entry.logId === this.activeUndoLogId,
            undoDisabled: !entry.canUndo || entry.logId === this.undoingLogId,
            hasFilter: !!entry.filterFieldLabel,
            // Record Type change jobs (BulkRecordTypeController) always log
            // Field_Label__c = 'Record Type' — the normal value-edit wizard
            // can never produce that field label since RecordTypeId is
            // excluded from its field picker, so this is an unambiguous tag
            // with no Apex/wrapper changes needed.
            isRecordTypeChange: entry.fieldLabel === 'Record Type'
        }));
    }

    get hasEntries() {
        return this._rawEntries.length > 0;
    }

    get toastClass() {
        const theme = this.toastVariant === 'success' ? 'slds-theme_success' : 'slds-theme_error';
        return `slds-notify slds-notify_alert slds-theme_alert-texture ${theme} slds-m-bottom_small`;
    }

    handleRefresh() {
        this.isLoading = true;
        refreshApex(this._wiredResult).then(() => {
            this.isLoading = false;
        });
    }

    handleUndoClick(event) {
        const logId = event.currentTarget.dataset.logId;
        this.undoingLogId = logId;

        undoBulkEdit({ logId })
            .then(() => {
                this.activeUndoLogId = logId;
            })
            .catch((error) => {
                this.undoingLogId = undefined;
                this.toastVariant = 'error';
                this.toastMessage = (error && error.body && error.body.message) || 'Unable to start undo.';
            });
    }

    handleUndoDone(event) {
        this.undoingLogId = undefined;
        this.activeUndoLogId = undefined;
        this.toastVariant = event.detail.status === 'Undone' ? 'success' : 'error';
        this.toastMessage =
            event.detail.status === 'Undone' ? 'Change reverted successfully.' : 'Undo finished with errors.';
        this.handleRefresh();
        this.scheduleToastAutoDismiss();
    }

    scheduleToastAutoDismiss() {
        this.clearToastTimer();
        this.toastCountdown = this.TOAST_AUTO_DISMISS_SECONDS;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._toastIntervalId = window.setInterval(() => {
            this.toastCountdown -= 1;
            if (this.toastCountdown <= 0) {
                this.toastMessage = undefined;
                this.clearToastTimer();
            }
        }, 1000);
    }

    clearToastTimer() {
        if (this._toastIntervalId) {
            window.clearInterval(this._toastIntervalId);
            this._toastIntervalId = undefined;
        }
        this.toastCountdown = undefined;
    }

    handleToastClose() {
        this.clearToastTimer();
        this.toastMessage = undefined;
    }
}
