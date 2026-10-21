import { LightningElement, track, wire } from 'lwc';
import getCanManageForms from '@salesforce/apex/DataUpdateFormAdminController.getCanManageForms';
import { getLabels, format } from 'c/dataUpdateI18n';
import { ticketNumber } from 'c/dataUpdateUi';

const LANG_KEY = 'dataUpdateCenter_lang';

export default class RequestUpdateApp extends LightningElement {
    @track lang = 'fr';
    @track openTabs = [];
    @track activeTabId = null;
    @track isDashboardActive = true;
    @track _dashboardLoading = true;
    _dashboardMounted = false;
    @track isLockedListActive = false;
    @track selectedFormFilter = '';
    @track selectedStatusFilter = '';
    _lockedListMounted = false;
    showBuilderModal = false;

    // Form Builder is for form admins only (Data_Update_Center_Form_Admin); Apex enforces it too.
    @wire(getCanManageForms)
    canManageForms;

    get showBuilderButton() {
        return !!(this.canManageForms && this.canManageForms.data);
    }

    _resizeHandler = null;
    _rafId = null;

    connectedCallback() {
        try {
            const saved = localStorage.getItem(LANG_KEY);
            if (saved === 'fr' || saved === 'en') {
                this.lang = saved;
            }
        } catch (e) {
            // storage unavailable — keep default language
        }
        this._resizeHandler = () => this._applyHeight();
        window.addEventListener('resize', this._resizeHandler);
        // Re-calculate after Salesforce async chrome (banners, etc.) finishes loading.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => this._applyHeight(), 800);
        // Mount dashboard after request list has priority on first render.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this._dashboardMounted = true;
            this._dashboardLoading = false;
        }, 300);
    }

    disconnectedCallback() {
        if (this._resizeHandler) {
            window.removeEventListener('resize', this._resizeHandler);
        }
    }

    renderedCallback() {
        this._applyHeight();
        this._scrollActiveTabIntoView();
    }

    // Keep the active tab visible in the horizontal tab strip (new tab opened at the end,
    // tab picked from the list, tab closed...). Only scrolls the strip, never the page.
    _scrollActiveTabIntoView() {
        const strip = this.template.querySelector('.duc-wtabs');
        const tab = strip && strip.querySelector('.duc-wtab_on');
        const key = tab ? (tab.dataset.id || tab.dataset.fixed || '') + '|' + this.enrichedTabs.length : '';
        if (!tab || key === this._scrolledTabKey) return;
        this._scrolledTabKey = key;
        const pad = 24;
        const left = tab.getBoundingClientRect().left - strip.getBoundingClientRect().left + strip.scrollLeft;
        const right = left + tab.offsetWidth;
        if (left - pad < strip.scrollLeft) {
            strip.scrollTo({ left: Math.max(0, left - pad), behavior: 'smooth' });
        } else if (right + pad > strip.scrollLeft + strip.clientWidth) {
            strip.scrollTo({ left: right + pad - strip.clientWidth, behavior: 'smooth' });
        }
    }

    _applyHeight() {
        if (this._rafId) cancelAnimationFrame(this._rafId);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._rafId = window.requestAnimationFrame(() => {
            const host = this.template.host;
            const top = host.getBoundingClientRect().top;
            if (top > 0 && top < window.innerHeight) {
                host.style.height = `${window.innerHeight - top - 4}px`;
                // The Lightning page adds its own bottom padding — shrink by whatever still makes the page scroll,
                // so only the app's panes scroll (no extra page scrollbar).
                const extra = document.documentElement.scrollHeight - window.innerHeight;
                if (extra > 0) host.style.height = `${Math.max(320, window.innerHeight - top - 4 - extra)}px`;
            }
        });
    }

    get i18n() { return getLabels(this.lang); }

    get langFrClass() { return 'duc-seg-btn' + (this.lang === 'fr' ? ' duc-seg-btn_on' : ''); }
    get langEnClass() { return 'duc-seg-btn' + (this.lang === 'en' ? ' duc-seg-btn_on' : ''); }
    get langFrPressed() { return String(this.lang === 'fr'); }
    get langEnPressed() { return String(this.lang === 'en'); }

    handleLangChange(event) {
        const newLang = event.currentTarget.dataset.lang;
        if (newLang && newLang !== this.lang) {
            this.lang = newLang;
            try {
                localStorage.setItem(LANG_KEY, newLang);
            } catch (e) {
                // storage unavailable — language only kept for this session
            }
        }
    }

    openBuilderModal() { this.showBuilderModal = true; }
    closeBuilderModal() { this.showBuilderModal = false; }

    // ── Computed ─────────────────────────────────────────────────────────────

    get dashboardTabClass() { return `duc-wtab${this.isDashboardActive ? ' duc-wtab_on' : ''}`; }
    get dashboardSelected() { return String(this.isDashboardActive); }
    get dashboardPanelClass() { return `duc-pane${this.isDashboardActive ? '' : ' duc-hide'}`; }
    get showDashboard() { return this._dashboardMounted; }

    get lockedListTabClass() { return `duc-wtab${this.isLockedListActive ? ' duc-wtab_on' : ''}`; }
    get lockedSelected() { return String(this.isLockedListActive); }
    get lockedListPanelClass() { return `duc-pane${this.isLockedListActive ? '' : ' duc-hide'}`; }
    get showLockedList() { return this._lockedListMounted; }

    get enrichedTabs() {
        return this.openTabs.map((t) => {
            const isActive = !this.isDashboardActive && !this.isLockedListActive && t.requestId === this.activeTabId;
            // The tab shows the name only; the ticket number stays in the tooltip to tell same-name tabs apart.
            const tag = t.isGroup
                ? (t.count > 1 ? format(this.i18n.grpTicketsFmt, t.count) : '')
                : (t.number ? '#' + ticketNumber(t.number).full : '');
            return {
                ...t,
                tag,
                hasTag: !!tag && t.isGroup,
                fullLabel: tag ? t.label + ' · ' + tag : t.label,
                closeLabel: this.i18n.rdClose + ' : ' + (tag ? t.label + ' · ' + tag : t.label),
                isActive,
                ariaSelected: String(isActive),
                tabClass: `duc-wtab${isActive ? ' duc-wtab_on' : ''}`,
                panelClass: isActive ? 'duc-pane duc-pane_detail' : 'duc-pane duc-pane_detail duc-hide'
            };
        });
    }

    // ── Tab management ──────────────────────────────────────────────────────

    handleDashboardTabClick() {
        this.isDashboardActive = true;
        this.isLockedListActive = false;
        this._dashboardMounted = true;
        this._dashboardLoading = false;
    }

    handleLockedListTabClick() {
        const wasMounted = this._lockedListMounted;
        this.isDashboardActive = false;
        this.isLockedListActive = true;
        this._lockedListMounted = true;
        // Already mounted = possibly stale (tickets applied/unlocked meanwhile) — reload it.
        if (wasMounted) this._refreshLockedList();
    }

    handleTabKey(event) {
        if (event.target !== event.currentTarget) return;
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            event.currentTarget.click();
        }
    }

    handleFormFilterChange(event) {
        this.selectedFormFilter = event.detail.formName || '';
        this.selectedStatusFilter = event.detail.status || '';
    }

    handleStatusFilter(event) {
        const { status, form } = event.detail || {};
        const list = this.template.querySelector('c-data-update-request-list');
        if (list) list.setFilters(status, form);
    }

    handleRequestSelect(event) {
        const { requestId, label, status, rollbackAsk, groupCount, number } = event.detail;
        const token = rollbackAsk ? Date.now() : null;
        const already = this.openTabs.find((t) => t.requestId === requestId);
        if (already) {
            if (token || status || groupCount !== undefined) {
                this.openTabs = this.openTabs.map((t) => (t.requestId === requestId
                    ? {
                        ...t,
                        status: status || t.status,
                        rollbackAskToken: token || t.rollbackAskToken,
                        groupCount: groupCount !== undefined ? groupCount : t.groupCount,
                        number: number || t.number
                    }
                    : t));
            }
        } else {
            this.openTabs = [...this.openTabs, {
                requestId,
                label: label || requestId.substring(0, 12),
                status: status || 'New',
                rollbackAskToken: token,
                groupCount: groupCount || 0,
                number: number || ''
            }];
        }
        this.activeTabId = requestId;
        this.isDashboardActive = false;
        this.isLockedListActive = false;
        this._revealWorkspace();
    }

    // Narrow screens stack the workspace under the list: scroll down to the ticket just opened.
    _revealWorkspace() {
        if (!window.matchMedia || !window.matchMedia('(max-width: 860px)').matches) return;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            const ws = this.template.querySelector('.duc-ws');
            if (ws && ws.scrollIntoView) ws.scrollIntoView({ block: 'start', behavior: 'smooth' });
        });
    }

    // "Review N together" (list card or the banner of a ticket): one tab per record.
    handleGroupSelect(event) {
        const { targetRecordId, name, count } = event.detail || {};
        if (!targetRecordId) return;
        const tabId = 'grp:' + targetRecordId;
        if (!this.openTabs.find((t) => t.requestId === tabId)) {
            this.openTabs = [...this.openTabs, {
                requestId: tabId,
                isGroup: true,
                targetRecordId,
                label: name || targetRecordId,
                count: count || 0,
                status: 'New'
            }];
        }
        // Already open: just bring it to the front — reloading it would drop the choices not applied yet.
        this.activeTabId = tabId;
        this.isDashboardActive = false;
        this.isLockedListActive = false;
        this._revealWorkspace();
    }

    handleGroupApplied(event) {
        const ids = (event.detail && event.detail.requestIds) || [];
        this._refreshList();
        this._refreshDashboard();
        // Ticket tabs already open for those tickets show their new status / history.
        this.template.querySelectorAll('c-data-update-review-panel').forEach((panel) => {
            if (ids.includes(panel.recordId)) panel.refresh();
        });
        const grpId = 'grp:' + ((event.detail && event.detail.targetRecordId) || '');
        // tickets left open after a partial apply keep showing in the tab ("2 tickets")
        const remaining = (event.detail && event.detail.remaining) || 0;
        this.openTabs = this.openTabs.map((t) => {
            if (ids.includes(t.requestId)) return { ...t, groupCount: 0 };
            return t.requestId === grpId ? { ...t, count: remaining } : t;
        });
    }

    // The group panels keep the choices not applied yet when they reload.
    _refreshGroups() {
        this.template.querySelectorAll('c-data-update-multi-ticket-review').forEach((g) => g.refresh());
    }

    handleTabActivate(event) {
        const id = event.currentTarget.dataset.id;
        if (id) {
            this.activeTabId = id;
            this.isDashboardActive = false;
            this.isLockedListActive = false;
        }
    }

    handleTabClose(event) {
        event.stopPropagation();
        this._closeTab(event.currentTarget.dataset.id);
    }

    _closeTab(requestId) {
        const idx = this.openTabs.findIndex((t) => t.requestId === requestId);
        if (idx === -1) return;
        const newTabs = this.openTabs.filter((t) => t.requestId !== requestId);
        this.openTabs = newTabs;
        if (this.activeTabId === requestId) {
            if (newTabs.length > 0) {
                this.activeTabId = newTabs[Math.min(idx, newTabs.length - 1)].requestId;
            } else {
                this.activeTabId = null;
                this.isDashboardActive = true;
                this.isLockedListActive = false;
            }
        }
    }

    // ── Review panel outcomes ────────────────────────────────────────────────

    handleReviewCloseTab(event) {
        this._closeTab(event.detail.requestId);
    }

    handleReviewApplied(event) {
        // Keep the tab open after apply: staff sees the result and can roll back from it.
        const requestId = event.detail.requestId;
        this.openTabs = this.openTabs.map((t) =>
            t.requestId === requestId ? { ...t, status: event.detail.status || 'Applied' } : t
        );
        this._refreshList();
        this._refreshDashboard();
        this._refreshGroups();
    }

    handleReviewRollback(event) {
        // Request goes back to 'Reopened' on rollback — keep the tab open so staff can
        // keep working the request.
        const requestId = event.detail.requestId;
        this.openTabs = this.openTabs.map((t) =>
            t.requestId === requestId ? { ...t, status: 'Reopened' } : t
        );
        this._refreshList();
        this._refreshDashboard();
        this._refreshGroups();
    }

    handleRequestChanged(event) {
        this._refreshDashboard();
        this._refreshList();
        this._refreshGroups();

        const { requestId, status } = event.detail || {};
        if (!requestId) return;

        if (status) {
            this.openTabs = this.openTabs.map((t) =>
                t.requestId === requestId ? { ...t, status } : t
            );
        }

        // Only refresh panels when the change came from outside them (list quick actions).
        if (event.target && event.target.tagName && event.target.tagName.toLowerCase() === 'c-data-update-review-panel') {
            return;
        }
        const panels = this.template.querySelectorAll('c-data-update-review-panel');
        panels.forEach((panel) => {
            if (panel.recordId === requestId) panel.refresh();
        });
    }

    _refreshList() {
        const list = this.template.querySelector('c-data-update-request-list');
        if (list) list.refresh();
        this._refreshLockedList();
    }

    _refreshLockedList() {
        const locked = this.template.querySelector('c-data-update-locked-list');
        if (locked) locked.refresh();
    }

    // Unlocks from the Locked List: the request list, dashboard and open panels show lock state too.
    handleLocksChanged() {
        const list = this.template.querySelector('c-data-update-request-list');
        if (list) list.refresh();
        this._refreshDashboard();
        this.template.querySelectorAll('c-data-update-review-panel').forEach((panel) => panel.refresh());
    }

    _refreshDashboard() {
        const dash = this.template.querySelector('c-data-update-dashboard');
        if (dash) dash.refresh();
    }
}
