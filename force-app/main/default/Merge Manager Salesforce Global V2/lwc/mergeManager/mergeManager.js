import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getLabels, format } from 'c/i18n';
import deleteAllTicketsApex from '@salesforce/apex/MergeController.deleteAllTickets';
import isSandboxOrgApex    from '@salesforce/apex/MergeController.isSandboxOrg';

const LANG_KEY = 'mergeManager_lang';

const MATCH_TYPE_ICON = {
    Email: 'utility:email',
    Phone: 'utility:call',
    Name:  'utility:user'
};

export default class MergeManager extends LightningElement {
    @track openTabs           = [];
    @track activeTabId        = null;
    @track isDashboardActive  = true;
    @track showScanModal         = false;
    @track showResetModal        = false;
    @track showObjectConfigModal = false;
    @track isResetting           = false;
    @track _scanModalObjectType = 'Contact';
    @track lang = 'en';

    @wire(isSandboxOrgApex)
    _isSandboxResult;

    get showResetButton() {
        return this._isSandboxResult?.data === true;
    }

    get i18n() { return getLabels(this.lang); }

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    _resizeHandler = null;
    _heightSet = false;

    connectedCallback() {
        const saved = localStorage.getItem(LANG_KEY);
        if (saved === 'en' || saved === 'es' || saved === 'fr') {
            this.lang = saved;
        }
        this._resizeHandler = () => this._applyHeight();
        window.addEventListener('resize', this._resizeHandler);
    }

    disconnectedCallback() {
        if (this._resizeHandler) {
            window.removeEventListener('resize', this._resizeHandler);
        }
    }

    renderedCallback() {
        if (!this._heightSet) {
            this._applyHeight();
        }
    }

    _applyHeight() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        window.requestAnimationFrame(() => {
            const host = this.template.host;
            const top  = host.getBoundingClientRect().top;
            if (top > 0 && top < window.innerHeight) {
                host.style.height = `${window.innerHeight - top - 4}px`;
                this._heightSet = true;
            }
        });
    }

    // ── Language change (dispatched from mergeObjectConfig) ───────────────────

    handleLangChange(event) {
        const newLang = event.detail?.lang;
        if (newLang && newLang !== this.lang) {
            this.lang = newLang;
            localStorage.setItem(LANG_KEY, newLang);
        }
    }

    // ── Computed ──────────────────────────────────────────────────────────────

    get dashboardTabClass() {
        return `mm-tab${this.isDashboardActive ? ' mm-tab_active' : ''}`;
    }

    get dashboardPanelClass() {
        return `mm-panel${this.isDashboardActive ? '' : ' slds-hide'}`;
    }

    get enrichedTabs() {
        return this.openTabs.map(t => {
            const isActive = !this.isDashboardActive && t.ticketId === this.activeTabId;
            return {
                ...t,
                icon:       MATCH_TYPE_ICON[t.matchType] || 'utility:merge',
                tabClass:   `mm-tab${isActive ? ' mm-tab_active' : ''}`,
                panelClass: isActive ? 'mm-panel' : 'mm-panel slds-hide'
            };
        });
    }

    // ── Tab management ────────────────────────────────────────────────────────

    handleDashboardTabClick() {
        this.isDashboardActive = true;
    }

    handleTicketSelect(event) {
        const { ticketId, ticketLabel, matchType } = event.detail;
        const already = this.openTabs.find(t => t.ticketId === ticketId);
        if (already) {
            this.activeTabId = ticketId;
        } else {
            this.openTabs = [...this.openTabs, {
                ticketId,
                label:     ticketLabel || ticketId.substring(0, 12),
                matchType: matchType   || 'Email'
            }];
            this.activeTabId = ticketId;
        }
        this.isDashboardActive = false;
    }

    handleTabActivate(event) {
        const id = event.currentTarget.dataset.id;
        if (id) {
            this.activeTabId = id;
            this.isDashboardActive = false;
        }
    }

    handleTabClose(event) {
        event.stopPropagation();
        this._closeTab(event.currentTarget.dataset.id);
    }

    _closeTab(ticketId) {
        const idx     = this.openTabs.findIndex(t => t.ticketId === ticketId);
        if (idx === -1) return;
        const newTabs = this.openTabs.filter(t => t.ticketId !== ticketId);
        this.openTabs = newTabs;
        if (this.activeTabId === ticketId) {
            if (newTabs.length > 0) {
                this.activeTabId = newTabs[Math.min(idx, newTabs.length - 1)].ticketId;
            } else {
                this.activeTabId     = null;
                this.isDashboardActive = true;
            }
        }
    }

    // ── Wizard outcomes ───────────────────────────────────────────────────────

    handleMergeComplete(event) {
        const { logId, mergedRecordId, ticketId } = event.detail;
        this._closeTab(ticketId);
        this._toast(
            this.i18n.toastMergeSuccess,
            format(this.i18n.toastMasterLog, mergedRecordId, logId),
            'success'
        );
        this._refreshList();
    }

    handleDismissed(event) {
        const { status } = event.detail;
        // Keep the tab open — the wizard already refreshed its matrix so the
        // Ignored/Closed banner is visible immediately. Closing the tab here would
        // require the user to reopen the ticket and fight the wire cache to see it.
        this._refreshList();
        const title = status === 'Ignored' ? this.i18n.tabToValidate : this.i18n.closedBadge;
        this._toast(title, '', 'success');
    }

    handleTicketReopened(event) {
        const { ticketId } = event.detail;
        this.template.querySelectorAll('c-merge-wizard').forEach(w => {
            if (w.ticketId === ticketId) w.refreshMatrix();
        });
    }

    // ── Scan modal ────────────────────────────────────────────────────────────

    openScanModal() {
        const list = this.template.querySelector('c-merge-ticket-list');
        this._scanModalObjectType = list?.currentObjectType || 'Contact';
        this.showScanModal = true;
    }
    closeScanModal() { this.showScanModal = false; }

    handleScanComplete(event) {
        this.showScanModal = false;
        const { isAsync, ticketsCreated, duplicateGroupsFound,
                skippedExistingTickets, recordsAnalyzed, objectType } = event.detail;
        const t = this.i18n;
        if (isAsync) {
            this._toast(t.toastScanAsync, t.toastScanAsyncMsg, 'info');
        } else if (ticketsCreated === 0 && duplicateGroupsFound === 0) {
            const analyzed = recordsAnalyzed > 0
                ? `${recordsAnalyzed} ${t.records} — ` : '';
            this._toast(t.toastNoDuplicate, analyzed + t.toastNoDuplicateMsg, 'info');
        } else {
            const skipped = skippedExistingTickets > 0
                ? format(t.toastAlreadyCovered, skippedExistingTickets) : '';
            this._toast(
                t.toastScanDone,
                format(t.toastAnalyzed, recordsAnalyzed || 0, duplicateGroupsFound, skipped, ticketsCreated),
                'success'
            );
        }
        this._refreshList(objectType);
    }

    // ── Object config ─────────────────────────────────────────────────────────

    openObjectConfigModal()  { this.showObjectConfigModal = true; }
    closeObjectConfigModal() { this.showObjectConfigModal = false; }
    handleConfigSaved() {
        this.template.querySelectorAll('c-merge-wizard')
            .forEach(w => w.refreshMatrix());
    }

    // ── Reset ─────────────────────────────────────────────────────────────────

    openResetModal()  { this.showResetModal = true; }
    closeResetModal() { this.showResetModal = false; }

    async confirmReset() {
        this.isResetting = true;
        try {
            const deleted = await deleteAllTicketsApex();
            this.showResetModal  = false;
            this.openTabs        = [];
            this.activeTabId     = null;
            this.isDashboardActive = true;
            this._toast(
                this.i18n.toastResetDone,
                format(this.i18n.toastTicketsDeleted, deleted),
                'success'
            );
            this._refreshList();
        } catch (err) {
            this._toast(this.i18n.error, err.body?.message || err.message, 'error');
        } finally {
            this.isResetting = false;
        }
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    _refreshList(objectType) {
        const list = this.template.querySelector('c-merge-ticket-list');
        if (list) list.refresh(objectType);
    }

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
