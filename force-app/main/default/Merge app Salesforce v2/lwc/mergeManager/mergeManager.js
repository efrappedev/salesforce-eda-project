import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import deleteAllTicketsApex from '@salesforce/apex/MergeController.deleteAllTickets';
import isSandboxOrgApex    from '@salesforce/apex/MergeController.isSandboxOrg';

const MATCH_TYPE_ICON = {
    Email: 'utility:email',
    Phone: 'utility:call',
    Name:  'utility:user'
};

export default class MergeManager extends LightningElement {
    @track openTabs    = [];   // [{ ticketId, label, matchType }]
    @track activeTabId = null;
    @track showScanModal      = false;
    @track showResetModal     = false;
    @track isResetting        = false;
    @track _scanModalObjectType = 'Contact';

    // Wire: hide Reset button in production (IsSandbox=false)
    @wire(isSandboxOrgApex)
    _isSandboxResult;

    get showResetButton() {
        return this._isSandboxResult?.data === true;
    }

    // ── Lifecycle: dynamic height ─────────────────────────────────────────────

    _resizeHandler = null;
    _heightSet = false;

    connectedCallback() {
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

    // ── Computed ──────────────────────────────────────────────────────────────

    get hasNoTabs() {
        return this.openTabs.length === 0;
    }

    get enrichedTabs() {
        return this.openTabs.map(t => ({
            ...t,
            icon:       MATCH_TYPE_ICON[t.matchType] || 'utility:merge',
            tabClass:   `mm-tab${t.ticketId === this.activeTabId ? ' mm-tab_active' : ''}`,
            panelClass: t.ticketId === this.activeTabId ? 'mm-panel' : 'mm-panel slds-hide'
        }));
    }

    // ── Tab management ────────────────────────────────────────────────────────

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
    }

    handleTabActivate(event) {
        const id = event.currentTarget.dataset.id;
        if (id) this.activeTabId = id;
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
            // Activate the adjacent tab, or null if none left
            this.activeTabId = newTabs.length > 0
                ? newTabs[Math.min(idx, newTabs.length - 1)].ticketId
                : null;
        }
    }

    // ── Wizard outcomes ───────────────────────────────────────────────────────

    handleMergeComplete(event) {
        const { logId, mergedRecordId, ticketId } = event.detail;
        this._closeTab(ticketId);
        this._toast('Fusion réussie', `Master : ${mergedRecordId} · Log : ${logId}`, 'success');
        this._refreshList();
    }

    handleDismissed(event) {
        const { ticketId } = event.detail;
        this._closeTab(ticketId);
        this._refreshList();
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
        if (isAsync) {
            this._toast('Scan en cours', 'Rafraîchissez la liste dans 1–3 minutes.', 'info');
        } else if (ticketsCreated === 0 && duplicateGroupsFound === 0) {
            const analyzed = recordsAnalyzed > 0
                ? `${recordsAnalyzed} enregistrement(s) analysé(s) — ` : '';
            this._toast(
                'Aucun doublon détecté',
                analyzed + 'Aucun doublon trouvé, ou tous les doublons ont déjà un ticket ouvert.',
                'info'
            );
        } else {
            const skipped = skippedExistingTickets > 0
                ? ` · ${skippedExistingTickets} déjà couverts` : '';
            this._toast(
                'Scan terminé',
                `${recordsAnalyzed || 0} analysé(s) · ${duplicateGroupsFound} groupe(s)${skipped} · ${ticketsCreated} ticket(s) créé(s)`,
                'success'
            );
        }
        this._refreshList(objectType);
    }

    // ── Reset ─────────────────────────────────────────────────────────────────

    openResetModal()  { this.showResetModal = true; }
    closeResetModal() { this.showResetModal = false; }

    async confirmReset() {
        this.isResetting = true;
        try {
            const deleted = await deleteAllTicketsApex();
            this.showResetModal = false;
            this.openTabs   = [];
            this.activeTabId = null;
            this._toast('Réinitialisé', `${deleted} ticket(s) supprimé(s).`, 'success');
            this._refreshList();
        } catch (err) {
            this._toast('Erreur', err.body?.message || err.message, 'error');
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
