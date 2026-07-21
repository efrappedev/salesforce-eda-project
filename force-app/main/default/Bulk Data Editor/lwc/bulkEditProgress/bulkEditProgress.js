import { LightningElement, api } from 'lwc';
import getJobStatus from '@salesforce/apex/BulkEditController.getJobStatus';

const POLL_INTERVAL_MS = 2000;

export default class BulkEditProgress extends LightningElement {
    @api logId;

    status;
    isPolling = false;
    errorMessage;
    _initialBatchJobId;

    _pollTimer;

    // Accepts logId/batchJobId directly instead of relying solely on the
    // @api logId property binding: a caller that sets this.currentLogId and
    // immediately calls progressCmp.start() in the same synchronous block
    // (outside a renderedCallback) can race LWC's async reactive re-render,
    // so this.logId may still be undefined when start() runs. Passing the
    // id explicitly here closes that race.
    @api
    start(explicitLogId, explicitBatchJobId) {
        if (explicitLogId) {
            this.logId = explicitLogId;
        }
        this._initialBatchJobId = explicitBatchJobId;
        this.isPolling = true;
        this.status = undefined;
        this.errorMessage = undefined;
        this.poll();
    }

    disconnectedCallback() {
        this.clearTimer();
    }

    poll() {
        getJobStatus({ logId: this.logId })
            .then((result) => {
                this.status = result;
                if (result.isDone) {
                    this.isPolling = false;
                    this.clearTimer();
                    this.dispatchEvent(new CustomEvent('done', { detail: result }));
                } else {
                    this._pollTimer = setTimeout(() => this.poll(), POLL_INTERVAL_MS);
                }
            })
            .catch((error) => {
                this.isPolling = false;
                this.errorMessage = (error && error.body && error.body.message) || 'Unable to retrieve job status.';
            });
    }

    clearTimer() {
        if (this._pollTimer) {
            clearTimeout(this._pollTimer);
            this._pollTimer = undefined;
        }
    }

    get progressPercent() {
        if (!this.status || !this.status.totalRecords) {
            return 0;
        }
        return Math.min(100, Math.round((this.status.processedRecords / this.status.totalRecords) * 100));
    }

    get progressStyle() {
        return `width: ${this.progressPercent}%`;
    }

    get statusLabel() {
        return this.status ? this.status.status : 'Starting...';
    }

    get showProgressBar() {
        return this.status && this.status.totalRecords > 0;
    }

    get isSuccess() {
        return this.status && (this.status.status === 'Completed' || this.status.status === 'Undone');
    }

    get isPartial() {
        return this.status && this.status.status === 'Completed with Errors';
    }

    get isFailed() {
        return this.status && (this.status.status === 'Failed' || this.status.status === 'Undo Failed');
    }

    get batchJobId() {
        return (this.status && this.status.batchJobId) || this._initialBatchJobId;
    }

    get resultIconName() {
        if (this.isSuccess) {
            return 'utility:success';
        }
        if (this.isFailed) {
            return 'utility:error';
        }
        if (this.isPartial) {
            return 'utility:warning';
        }
        return 'utility:spinner';
    }
}
