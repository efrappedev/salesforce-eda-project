import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import hasSettingsAccess   from '@salesforce/customPermission/DMC_Settings_Access';
import getTickets          from '@salesforce/apex/DmcDonationService.getTickets';
import getTicketDetail     from '@salesforce/apex/DmcDonationService.getTicketDetail';
import getLinkPreview      from '@salesforce/apex/DmcDonationService.getLinkPreview';
import resolveLinkExisting from '@salesforce/apex/DmcDonationService.resolveLinkExisting';
import resolveCreateNew    from '@salesforce/apex/DmcDonationService.resolveCreateNew';
import skipTicket          from '@salesforce/apex/DmcDonationService.skipTicket';
import getDashboardStats   from '@salesforce/apex/DmcDonationService.getDashboardStats';
import undoResolution      from '@salesforce/apex/DmcDonationService.undoResolution';
import getAuditLog         from '@salesforce/apex/DmcDonationService.getAuditLog';
import getDonationHistory  from '@salesforce/apex/DmcDonationService.getDonationHistory';
import loadConfig          from '@salesforce/apex/DmcConfigService.loadConfig';
import saveConfig          from '@salesforce/apex/DmcConfigService.saveConfig';
import saveLanguage        from '@salesforce/apex/DmcConfigService.saveLanguage';
import saveAppSettings     from '@salesforce/apex/DmcConfigService.saveAppSettings';
import searchOwners        from '@salesforce/apex/DmcConfigService.searchOwners';
import searchAccounts      from '@salesforce/apex/DmcConfigService.searchAccounts';
import assignTicket        from '@salesforce/apex/DmcDonationService.assignTicket';
import importTickets       from '@salesforce/apex/DmcDonationService.importTickets';
import findAccountMatches  from '@salesforce/apex/DmcDonationService.findAccountMatches';

// ── i18n label map ────────────────────────────────────────────────────────────
const LABELS = {
    en: {
        settingsTitle:        'Settings',
        langSection:          'Language',
        langLabel:            'Display language',
        taskSection:          'Pending Ticket Tasks',
        taskEnable:           'Create a task when a ticket arrives for review',
        taskDueDays:          'Due in (days)',
        taskAssignTo:         'Assign to',
        taskSearchPlaceholder:'Search user or queue...',
        lapsedSection:        'Lapsed Donor Alerts',
        lapsedEnable:         'Alert when a donor has not given in',
        lapsedDays:           'days',
        lapsedSchedule:       'Run every',
        lapsedAssignTo:       'Assign tasks to',
        credSection:          'Zeffy Credentials',
        credActive:           'Connection active',
        credApiKey:           'API Key',
        credSecret:           'Webhook Secret',
        credInfo:             'Where to find these values',
        credInfoLine1:        'Log in to Zeffy → Settings → Integrations → API',
        credInfoLine2:        'Webhook Secret is shown when creating a new webhook endpoint',
        saveBtn:              'Save',
        savingBtn:            'Saving...',
        savedToast:           'Settings saved',
        savedCredsToast:      'Zeffy credentials updated successfully.',
        savedAppToast:        'Automation settings saved.',
        mon: 'Monday', tue: 'Tuesday', wed: 'Wednesday', thu: 'Thursday', fri: 'Friday',
        freqWeekly: 'Weekly', freqMonthly: 'Monthly',
        lapsedFrequencyLabel: 'Frequency',
    },
    fr: {
        settingsTitle:        'Paramètres',
        langSection:          'Langue',
        langLabel:            'Langue d\'affichage',
        taskSection:          'Tâches — Dons en attente',
        taskEnable:           'Créer une tâche quand un don arrive en attente de révision',
        taskDueDays:          'Échéance (jours)',
        taskAssignTo:         'Assigner à',
        taskSearchPlaceholder:'Rechercher utilisateur ou file...',
        lapsedSection:        'Alertes — Donateurs inactifs',
        lapsedEnable:         'Alerter quand un donateur n\'a pas donné depuis',
        lapsedDays:           'jours',
        lapsedSchedule:       'Exécuter chaque',
        lapsedAssignTo:       'Assigner les tâches à',
        credSection:          'Identifiants Zeffy',
        credActive:           'Connexion active',
        credApiKey:           'Clé API',
        credSecret:           'Secret du webhook',
        credInfo:             'Où trouver ces valeurs',
        credInfoLine1:        'Connectez-vous à Zeffy → Paramètres → Intégrations → API',
        credInfoLine2:        'Le secret webhook s\'affiche à la création d\'un nouveau point de terminaison',
        saveBtn:              'Enregistrer',
        savingBtn:            'Enregistrement...',
        savedToast:           'Paramètres enregistrés',
        savedCredsToast:      'Identifiants Zeffy mis à jour.',
        savedAppToast:        'Paramètres d\'automatisation enregistrés.',
        mon: 'Lundi', tue: 'Mardi', wed: 'Mercredi', thu: 'Jeudi', fri: 'Vendredi',
        freqWeekly: 'Hebdomadaire', freqMonthly: 'Mensuel',
        lapsedFrequencyLabel: 'Fréquence',
    },
};

const STATUS_OPTIONS = [
    { label: 'Open (except resolved/skipped)', value: 'Open' },
    { label: 'All Statuses',                   value: 'All' },
    { label: 'Pending Review',                 value: 'Pending Review' },
    { label: 'Resolved - Linked',              value: 'Resolved - Linked' },
    { label: 'Resolved - New Contact',         value: 'Resolved - New Contact' },
    { label: 'Skipped',                        value: 'Skipped' },
    { label: 'Error',                          value: 'Error' },
];

const DONOR_TYPE_OPTIONS = [
    { label: 'Individual (Person Account)', value: 'individual' },
    { label: 'Church (Eglise Account)',     value: 'eglise' },
    { label: 'Organization (Org Account)', value: 'org' },
];

// Email choice options are now dynamic (loaded from getLinkPreview schema scan)

const ADDRESS_CHOICE_OPTIONS = [
    { label: 'Keep current Salesforce address', value: 'keep' },
    { label: 'Update with Zeffy address',        value: 'update' },
];

export default class DmcReviewManager extends LightningElement {

    // ── List state ─────────────────────────────────────────────────────────────
    @track tickets = [];
    @track statusFilter = 'Open';
    @track searchText = '';
    @track isLoading = false;

    // ── Tab/panel state ────────────────────────────────────────────────────────
    @track activePanel = 'dashboard';  // 'dashboard' | 'audit' | ticketId
    @track openTabs = [];              // [{id, donorName, ticketName}]

    // ── Dashboard state ────────────────────────────────────────────────────────
    @track stats = {};

    // ── Audit log state ────────────────────────────────────────────────────────
    @track auditLog = [];
    @track isLoadingAudit = false;

    // ── Donation history state ─────────────────────────────────────────────────
    @track donationHistory = [];
    @track isLoadingHistory = false;

    // ── Detail state ───────────────────────────────────────────────────────────
    @track selectedTicketId = null;
    @track ticket = null;
    @track isLoadingDetail = false;

    // ── Resolution notes ───────────────────────────────────────────────────────
    @track resolutionNotes = '';

    // ── View Matches wizard modal ──────────────────────────────────────────────
    @track showMatchesModal   = false;
    @track matchesStep        = 1;       // 1 = select, 2 = compare / 2b = create
    @track matchesMode        = 'link';  // 'link' | 'create'

    // ── Account selection & comparison (inside wizard) ─────────────────────────
    @track selectedAccountId  = null;
    @track preview            = null;
    @track isLoadingPreview   = false;
    @track accountSearch          = '';
    @track accountSearchResults   = [];
    @track emailTargetField       = '';
    @track emailFieldOptions      = [];
    @track updateEmailEnabled     = false;
    @track updateAddressEnabled   = false;
    @track updateFirstNameEnabled = false;
    @track updateLastNameEnabled  = false;

    // ── Auto-match candidates ──────────────────────────────────────────────────
    @track matchCandidates    = [];
    @track isLoadingMatches   = false;

    // ── Create New (inside wizard) ─────────────────────────────────────────────
    @track donorTypeForNew    = 'individual';

    // ── Exception modal ────────────────────────────────────────────────────────
    @track showExceptionModal = false;
    @track exceptionType      = 'skip';  // 'skip' | 'close' | 'pending'

    // ── Follow-up Assignment modal ─────────────────────────────────────────────
    @track showAssignModal    = false;

    // ── Undo state ─────────────────────────────────────────────────────────────
    @track showUndoConfirm = false;

    // ── Manual assignment state ────────────────────────────────────────────────
    @track assignOwnerId      = '';
    @track assignOwnerName    = '';
    @track assignOwnerSearch  = '';
    @track assignOwnerResults = [];
    @track assignDueDays      = 3;
    @track assignNote         = '';
    @track isAssigning        = false;

    // ── Settings state ─────────────────────────────────────────────────────────
    @track showSettings        = false;
    @track settingsApiKey      = '';
    @track settingsSecret      = '';
    @track settingsIsActive    = true;
    @track isLoadingSettings   = false;
    @track isSavingSettings    = false;
    @track isSavingAppSettings = false;
    @track settingsSection     = 'language';  // 'language' | 'tasks' | 'lapsed' | 'import' | 'credentials'

    // CSV Import
    @track importRows        = [];
    @track importFileName    = '';
    @track importDone        = 0;
    @track importSkipped     = 0;
    @track importErrors      = [];
    @track importTotal       = 0;
    @track isImporting       = false;
    @track importComplete    = false;

    // Language
    @track currentLanguage  = 'en';

    // Task automation
    @track autoTaskEnabled  = false;
    @track taskDueDays      = 2;
    @track taskOwnerId      = '';
    @track taskOwnerName    = '';
    @track taskOwnerSearch  = '';
    @track taskOwnerResults = [];

    // Lapsed donor
    @track lapsedEnabled      = false;
    @track lapsedDays         = 365;
    @track lapsedOwnerId      = '';
    @track lapsedOwnerName    = '';
    @track lapsedOwnerSearch  = '';
    @track lapsedOwnerResults = [];
    @track lapsedScheduleDay  = 'MON';
    @track lapsedFrequency    = 'WEEKLY';

    // ── Static options ─────────────────────────────────────────────────────────
    get statusOptions()        { return STATUS_OPTIONS; }
    get donorTypeOptions()     { return DONOR_TYPE_OPTIONS; }
    get addressChoiceOptions() { return ADDRESS_CHOICE_OPTIONS; }

    // ── i18n ───────────────────────────────────────────────────────────────────
    get lbl() { return LABELS[this.currentLanguage] || LABELS.en; }

    get languageOptions() {
        return [
            { label: 'English', value: 'en' },
            { label: 'Français', value: 'fr' },
        ];
    }

    get scheduleDayOptions() {
        const l = this.lbl;
        return [
            { label: l.mon, value: 'MON' },
            { label: l.tue, value: 'TUE' },
            { label: l.wed, value: 'WED' },
            { label: l.thu, value: 'THU' },
            { label: l.fri, value: 'FRI' },
        ];
    }

    get frequencyOptions() {
        const l = this.lbl;
        return [
            { label: l.freqWeekly,  value: 'WEEKLY' },
            { label: l.freqMonthly, value: 'MONTHLY' },
        ];
    }

    get showLapsedDayPicker() { return this.lapsedFrequency === 'WEEKLY'; }

    get langBtnEnClass() {
        return 'lang-pill' + (this.currentLanguage === 'en' ? ' lang-pill--active' : '');
    }
    get langBtnFrClass() {
        return 'lang-pill' + (this.currentLanguage === 'fr' ? ' lang-pill--active' : '');
    }

    get showModalSaveBtn() {
        return this.settingsSection !== 'language';
    }

    get hasTaskOwnerResults()      { return this.taskOwnerResults.length > 0; }
    get hasLapsedOwnerResults()    { return this.lapsedOwnerResults.length > 0; }
    get hasAssignOwnerResults()    { return this.assignOwnerResults.length > 0; }
    get hasAccountSearchResults()  { return this.accountSearchResults.length > 0; }

    get assignBtnLabel()        { return this.isAssigning ? 'Assigning...' : 'Assign'; }
    get isAssignDisabled()      { return !this.assignOwnerId || this.isAssigning; }

    get saveBtnLabel()        { return this.lbl.saveBtn; }
    get saveAppBtnLabel()     { return this.isSavingAppSettings ? this.lbl.savingBtn : this.lbl.saveBtn; }
    get saveCredsBtnLabel()   { return this.isSavingSettings    ? this.lbl.savingBtn : this.lbl.saveBtn; }

    // Settings section nav
    get isSettingsLang()  { return this.settingsSection === 'language'; }
    get isSettingsTasks() { return this.settingsSection === 'tasks'; }
    get isSettingsLapsed(){ return this.settingsSection === 'lapsed'; }
    get isSettingsImport(){ return this.settingsSection === 'import'; }
    get isSettingsCreds() { return this.settingsSection === 'credentials'; }

    get navLangClass()  { return 'sn-item' + (this.settingsSection === 'language'     ? ' sn-item--active' : ''); }
    get navTasksClass() { return 'sn-item' + (this.settingsSection === 'tasks'        ? ' sn-item--active' : ''); }
    get navLapsedClass(){ return 'sn-item' + (this.settingsSection === 'lapsed'       ? ' sn-item--active' : ''); }
    get navImportClass(){ return 'sn-item' + (this.settingsSection === 'import'       ? ' sn-item--active' : ''); }
    get navCredsClass() { return 'sn-item' + (this.settingsSection === 'credentials'  ? ' sn-item--active' : ''); }

    get importHasRows()     { return this.importRows.length > 0; }
    get importProgressPct() { return this.importTotal > 0 ? Math.round(this.importDone / this.importTotal * 100) : 0; }
    get importHasErrors()   { return this.importErrors.length > 0; }
    get importProgressStyle() { return 'width:' + this.importProgressPct + '%'; }

    get headerSettingsClass() {
        return 'icon-btn' + (this.showSettings ? ' icon-btn--active' : '');
    }

    // ── Panel getters ──────────────────────────────────────────────────────────
    get hasDmcSettings()      { return hasSettingsAccess; }
    get isRightTabDashboard() { return this.activePanel === 'dashboard'; }
    get isRightTabHistory()   { return this.activePanel === 'history'; }
    get isRightTabAudit()     { return this.activePanel === 'audit'; }
    get isRightTabTicket()    {
        return this.activePanel !== 'dashboard' &&
               this.activePanel !== 'history' &&
               this.activePanel !== 'audit';
    }

    get rpDashboardClass() { return 'rp-tab' + (this.activePanel === 'dashboard' ? ' rp-tab--active' : ''); }
    get rpHistoryClass()   { return 'rp-tab' + (this.activePanel === 'history'   ? ' rp-tab--active' : ''); }
    get rpAuditClass()     { return 'rp-tab' + (this.activePanel === 'audit'     ? ' rp-tab--active' : ''); }

    get hasOpenTabs() { return this.openTabs.length > 0; }

    get openTabsList() {
        return this.openTabs.map(tab => ({
            id:        tab.id,
            donorName: tab.donorName,
            tabClass:  'rp-tab rp-tab--ticket' + (this.activePanel === tab.id ? ' rp-tab--active' : ''),
        }));
    }

    // ── Dashboard counts ───────────────────────────────────────────────────────
    get totalCount()   { return (this.stats && this.stats.total != null) ? this.stats.total : 0; }
    get pendingCount() { return this._byStatus('Pending Review'); }
    get resolvedCount() {
        if (!this.stats || !this.stats.byStatus) return 0;
        const bs = this.stats.byStatus;
        return (bs['Resolved - Linked'] || 0) +
               (bs['Resolved - New Contact'] || 0) +
               (bs['Resolved - New Account'] || 0);
    }
    get errorCount()   { return this._byStatus('Error'); }
    get skippedCount() { return this._byStatus('Skipped'); }

    _byStatus(key) {
        if (!this.stats || !this.stats.byStatus) return 0;
        return this.stats.byStatus[key] || 0;
    }

    get hasRecentResolutions() { return this.recentResolutionsList.length > 0; }

    get recentResolutionsList() {
        if (!this.stats || !this.stats.recentResolutions) return [];
        return this.stats.recentResolutions.slice(0, 5).map(r => {
            const nameParts = [r.First_Name__c, r.Last_Name__c].filter(Boolean);
            const displayName = nameParts.length > 0 ? nameParts.join(' ') : (r.Company_Name__c || '—');
            return {
                Id: r.Id,
                Status__c: r.Status__c,
                donorDisplayName: displayName,
                amountDisplay: r.Amount__c != null
                    ? '$' + parseFloat(r.Amount__c).toFixed(2) + (r.Currency__c ? ' ' + r.Currency__c : '')
                    : '—',
                statusBadgeClass: 'status-badge status-badge--' + this._statusClass(r.Status__c),
                resolvedAtDisplay: r.Resolved_At__c ? String(r.Resolved_At__c).substring(0, 10) : '—',
                resolvedByName: (r.Resolved_By__r && r.Resolved_By__r.Name) ? r.Resolved_By__r.Name : '—',
            };
        });
    }

    // ── Audit log getters ──────────────────────────────────────────────────────
    get hasAuditLog()   { return this.auditLogList.length > 0; }
    get auditLogCount() { return this.auditLogList.length; }

    // ── Donation history getters ───────────────────────────────────────────────
    get hasHistory()    { return this.historyList.length > 0; }
    get historyCount()  { return this.historyList.length; }

    get historyList() {
        if (!this.donationHistory) return [];
        return this.donationHistory.map(r => ({
            Id:                r.Id,
            Name:              r.Name,
            DonorName:         r.DonorName || '—',
            amountDisplay:     r.Amount != null ? '$' + parseFloat(r.Amount).toFixed(2) : '—',
            TransactionDate:   r.TransactionDate || '—',
            PaymentMethod:     r.PaymentMethod || '—',
            ZeffyTransactionId: r.ZeffyTransactionId || '—',
            TicketName:        r.TicketName || '',
            IsManual:          r.IsManual,
            sourceClass:       'source-badge ' + (r.IsManual ? 'source-badge--manual' : 'source-badge--auto'),
            sourceLabel:       r.IsManual ? ('Manual · ' + r.TicketName) : 'Auto-processed',
        }));
    }

    get auditLogList() {
        if (!this.auditLog) return [];
        return this.auditLog.map(log => ({
            Id:              log.Id,
            Name:            log.Name,
            Action__c:       log.Action__c,
            Notes__c:        log.Notes__c || '',
            ticketName:      (log.Ticket__r && log.Ticket__r.Name) ? log.Ticket__r.Name : '—',
            accountName:     (log.Account__r && log.Account__r.Name) ? log.Account__r.Name : '—',
            performedByName: (log.Performed_By__r && log.Performed_By__r.Name) ? log.Performed_By__r.Name : '—',
            performedAtDisplay: log.Performed_At__c
                ? String(log.Performed_At__c).substring(0, 16).replace('T', ' ')
                : '—',
            actionClass: 'action-badge ' + this._actionBadgeClass(log.Action__c),
        }));
    }

    _actionBadgeClass(action) {
        if (!action) return '';
        if (action.startsWith('Resolved')) return 'action-badge--resolved';
        if (action === 'Rolled Back')       return 'action-badge--rollback';
        if (action === 'Skipped')           return 'action-badge--skipped';
        return '';
    }

    // ── Filtered ticket list ───────────────────────────────────────────────────
    get filteredTickets() {
        let list = this.tickets || [];
        const q = this.searchText ? this.searchText.trim().toLowerCase() : '';
        if (q) {
            list = list.filter(t =>
                (t.First_Name__c   && t.First_Name__c.toLowerCase().includes(q))   ||
                (t.Last_Name__c    && t.Last_Name__c.toLowerCase().includes(q))    ||
                (t.Email__c        && t.Email__c.toLowerCase().includes(q))        ||
                (t.Name            && t.Name.toLowerCase().includes(q))            ||
                (t.Company_Name__c && t.Company_Name__c.toLowerCase().includes(q))
            );
        }
        return list.map(t => this._buildTicketCard(t));
    }

    get hasFilteredTickets() { return this.filteredTickets.length > 0; }
    get ticketCount()        { return this.filteredTickets.length; }

    _buildTicketCard(t) {
        const sc = this._statusClass(t.Status__c);
        const nameParts = [t.First_Name__c, t.Last_Name__c].filter(Boolean);
        const donorName = nameParts.length > 0 ? nameParts.join(' ') : (t.Company_Name__c || '—');
        const amountDisplay = t.Amount__c != null
            ? '$' + parseFloat(t.Amount__c).toFixed(2) + (t.Currency__c ? ' ' + t.Currency__c : '')
            : '';
        const isActive = t.Id === this.activePanel;
        const isOpen   = !isActive && this.openTabs.some(tab => tab.id === t.Id);
        let cardClass = 'ticket-card status--' + sc;
        if (isActive)    cardClass += ' ticket-card--active';
        else if (isOpen) cardClass += ' ticket-card--open';
        return {
            Id:                      t.Id,
            Name:                    t.Name,
            First_Name__c:           t.First_Name__c,
            Last_Name__c:            t.Last_Name__c,
            Email__c:                t.Email__c,
            Company_Name__c:         t.Company_Name__c,
            Amount__c:               t.Amount__c,
            Currency__c:             t.Currency__c,
            Gift_Date__c:            t.Gift_Date__c,
            Status__c:               t.Status__c,
            Manual_Assignee_Name__c: t.Manual_Assignee_Name__c || '',
            donorName,
            amountDisplay,
            cardClass,
            statusBadgeClass: 'status-badge status-badge--' + sc,
        };
    }

    _statusClass(status) {
        if (!status) return 'pending';
        if (status === 'Pending Review')   return 'pending';
        if (status.startsWith('Resolved')) return 'resolved';
        if (status === 'Error')            return 'error';
        if (status === 'Skipped')          return 'skipped';
        return 'pending';
    }

    // ── Ticket detail getters ──────────────────────────────────────────────────
    get isPending() {
        return this.ticket && this.ticket.Status__c === 'Pending Review';
    }
    get canUndo() {
        return this.ticket && this.ticket.Status__c &&
            (this.ticket.Status__c === 'Resolved - Linked' ||
             this.ticket.Status__c === 'Resolved - New Contact' ||
             this.ticket.Status__c === 'Resolved - New Account');
    }
    get isRecurringLabel()    { return this.ticket && this.ticket.Is_Recurring__c ? 'Yes' : 'No'; }
    get hasNoteOrAnnotation() { return this.ticket && (this.ticket.Note__c || this.ticket.Annotation__c); }

    get ticketDonorName() {
        if (!this.ticket) return '';
        const nameParts = [this.ticket.First_Name__c, this.ticket.Last_Name__c].filter(Boolean);
        return nameParts.length > 0 ? nameParts.join(' ') : (this.ticket.Company_Name__c || '—');
    }
    get ticketAmountDisplay() {
        if (!this.ticket || this.ticket.Amount__c == null) return '';
        return '$' + parseFloat(this.ticket.Amount__c).toFixed(2) +
            (this.ticket.Currency__c ? ' ' + this.ticket.Currency__c : '');
    }
    get ticketStatusBadgeClass() {
        if (!this.ticket) return 'status-badge';
        return 'status-badge status-badge--' + this._statusClass(this.ticket.Status__c);
    }

    // ── Wizard / candidate getters ────────────────────────────────────────────
    get hasMatchCandidates()   { return this.matchCandidates.length > 0; }
    get isWizardStep1()        { return this.matchesStep === 1; }
    get isWizardStep2()        { return this.matchesStep === 2; }
    get isWizardLinkMode()     { return this.matchesMode === 'link'; }
    get isWizardCreateMode()   { return this.matchesMode === 'create'; }
    get wizardStep2Enabled()   { return this.matchesMode === 'create' || !!this.selectedAccountId; }

    get wizardStep1Class()  { return 'wiz-step' + (this.matchesStep >= 1 ? ' wiz-step--active' : ''); }
    get wizardStep2Class()  { return 'wiz-step' + (this.matchesStep >= 2 ? ' wiz-step--active' : ''); }

    get hasZeffyAddress() {
        return this.ticket && (this.ticket.Address__c || this.ticket.City__c || this.ticket.Province__c);
    }
    get zeffyAddressDisplay() {
        if (!this.ticket) return '';
        return [this.ticket.Address__c, this.ticket.City__c, this.ticket.Province__c, this.ticket.Postal_Code__c]
            .filter(Boolean).join(', ');
    }

    get accountMatchingInfo() {
        return {
            primaryField:     { fieldPath: 'Name' },
            additionalFields: [{ fieldPath: 'PersonEmail' }]
        };
    }

    get createTypeBtnLabel() {
        const map = { individual: 'Individual', eglise: 'Church (Église)', org: 'Organization' };
        return map[this.donorTypeForNew] || 'Individual';
    }
    get createBtnClassIndividual() { return 'create-type-btn' + (this.donorTypeForNew === 'individual' ? ' create-type-btn--active' : ''); }
    get createBtnClassEglise()     { return 'create-type-btn' + (this.donorTypeForNew === 'eglise'     ? ' create-type-btn--active' : ''); }
    get createBtnClassOrg()        { return 'create-type-btn' + (this.donorTypeForNew === 'org'        ? ' create-type-btn--active' : ''); }
    get ticketGiftDateDisplay() {
        if (!this.ticket || !this.ticket.Gift_Date__c) return '—';
        const d = new Date(this.ticket.Gift_Date__c);
        return d.toLocaleDateString('en-CA', { year: 'numeric', month: 'short', day: 'numeric' });
    }

    get followupLabel() {
        if (this.ticket && this.ticket.Manual_Assignee_Name__c) return this.ticket.Manual_Assignee_Name__c;
        return 'Follow-up Assignment';
    }

    get candidateList() {
        return this.matchCandidates.map(c => {
            const score = c.score != null ? c.score : 0;
            let tier = score >= 80 ? 'high' : score >= 50 ? 'mid' : 'low';
            return {
                ...c,
                scoreLabel:  score + '%',
                badgeClass:  'candidate-badge candidate-badge--score candidate-badge--' + tier,
                isSelected:  c.id === this.selectedAccountId,
                cardClass:   'candidate-card' + (c.id === this.selectedAccountId ? ' candidate-card--selected' : ''),
            };
        });
    }

    // Email field combobox: FieldName: currentValue → zeffyEmail
    get emailFieldComboOptions() {
        const zeffyEmail = (this.ticket && this.ticket.Email__c) ? this.ticket.Email__c : '';
        const base = [{ label: '— Select field —', value: '' }];
        return base.concat((this.emailFieldOptions || []).map(f => {
            const from = f.currentValue ? f.currentValue : '(empty)';
            return { label: `${f.label}: ${from} → ${zeffyEmail}`, value: f.value };
        }));
    }

    get hasEmailFieldOptions() { return this.emailFieldOptions && this.emailFieldOptions.length > 0; }

    // Exception getters
    get isExceptionSkip()    { return this.exceptionType === 'skip'; }
    get isExceptionClose()   { return this.exceptionType === 'close'; }
    get isExceptionPending() { return this.exceptionType === 'pending'; }
    get exceptionConfirmLabel() {
        if (this.exceptionType === 'skip')    return 'Skip Ticket';
        if (this.exceptionType === 'close')   return 'Close Ticket';
        return 'Keep Pending';
    }
    get excCardSkipClass()     { return 'exc-card' + (this.exceptionType === 'skip'    ? ' exc-card--selected' : ''); }
    get excCardCloseClass()    { return 'exc-card' + (this.exceptionType === 'close'   ? ' exc-card--selected' : ''); }
    get excCardPendingClass()  { return 'exc-card' + (this.exceptionType === 'pending' ? ' exc-card--selected' : ''); }

    // Comparison getters
    get hasExistingIds()  { return this.preview && this.preview.existingZeffyIds && this.preview.existingZeffyIds.length > 0; }
    get emailDiffClass()  { return (this.preview && this.preview.emailsDiffer) ? 'text-diff' : ''; }
    get isLinkDisabled()  { return !this.selectedAccountId || !this.preview || this.isLoadingPreview; }

    // ── Lifecycle ──────────────────────────────────────────────────────────────
    connectedCallback() {
        this.loadTickets();
        this.loadDashboardStats();
        this.loadLanguage();
    }

    loadLanguage() {
        loadConfig()
            .then(result => { this.currentLanguage = result.language || 'en'; })
            .catch(() => {});
    }

    // ── Settings modal open/close ──────────────────────────────────────────────
    handleOpenSettings() {
        this.showSettings = true;
        this.loadSettings();
    }

    handleCloseSettings() {
        this.showSettings = false;
    }

    handleDialogClick(event) {
        event.stopPropagation();
    }

    // ── Permanent tab handlers (Dashboard / Donation History / Audit Log) ──────
    handleRightTabChange(event) {
        const tab = event.currentTarget.dataset.tab;
        this.activePanel = tab;
        if (tab === 'history' && this.donationHistory.length === 0) {
            this.loadDonationHistory();
        }
        if (tab === 'audit' && this.auditLog.length === 0) {
            this.loadAuditLog();
        }
    }

    // ── Ticket tab handlers ────────────────────────────────────────────────────
    handleActivateTab(event) {
        const id = event.currentTarget.dataset.id;
        if (!id || this.activePanel === id) return;
        this.activePanel = id;
        this.selectedTicketId = id;
        this.resetResolutionState();
        this.loadDetail();
    }

    handleCloseTab(event) {
        event.stopPropagation();
        const id = event.currentTarget.dataset.id;
        const idx = this.openTabs.findIndex(t => t.id === id);
        this.openTabs = this.openTabs.filter(t => t.id !== id);
        if (this.activePanel === id) {
            if (this.openTabs.length > 0) {
                const next = this.openTabs[Math.min(idx, this.openTabs.length - 1)];
                this.activePanel = next.id;
                this.selectedTicketId = next.id;
                this.resetResolutionState();
                this.loadDetail();
            } else {
                this.activePanel = 'dashboard';
                this.selectedTicketId = null;
                this.ticket = null;
            }
        }
    }

    // ── List handlers ──────────────────────────────────────────────────────────
    handleStatusChange(event) {
        this.statusFilter = event.detail.value;
        this.loadTickets();
    }

    handleSearch(event) {
        this.searchText = event.target.value;
    }

    handleRefresh() {
        this.loadTickets();
        this.loadDashboardStats();
        if (this.selectedTicketId) this.loadDetail();
        if (this.activePanel === 'history') this.loadDonationHistory();
        if (this.activePanel === 'audit')   this.loadAuditLog();
    }

    handleRefreshAudit() {
        this.loadAuditLog();
    }

    handleRefreshHistory() {
        this.loadDonationHistory();
    }

    handleSelectTicket(event) {
        const id = event.currentTarget.dataset.id;
        if (!id) return;
        if (!this.openTabs.find(t => t.id === id)) {
            const raw = this.tickets.find(t => t.Id === id);
            const nameParts = raw ? [raw.First_Name__c, raw.Last_Name__c].filter(Boolean) : [];
            const donorName = nameParts.length > 0
                ? nameParts.join(' ')
                : (raw && raw.Company_Name__c ? raw.Company_Name__c : (raw ? raw.Name : id));
            this.openTabs = [...this.openTabs, { id, donorName, ticketName: raw ? raw.Name : id }];
        }
        this.activePanel = id;
        this.selectedTicketId = id;
        this.resetResolutionState();
        this.loadDetail();
    }

    // ── View Matches wizard ────────────────────────────────────────────────────
    handleOpenMatchesModal() {
        this.showMatchesModal = true;
        this.matchesStep      = 1;
        this.matchesMode      = 'link';
    }

    handleCloseMatchesModal() {
        this.showMatchesModal         = false;
        this.selectedAccountId        = null;
        this.preview                  = null;
        this.accountSearch            = '';
        this.accountSearchResults     = [];
        this.emailFieldOptions        = [];
        this.emailTargetField         = '';
        this.updateEmailEnabled       = false;
        this.updateAddressEnabled     = false;
        this.updateFirstNameEnabled   = false;
        this.updateLastNameEnabled    = false;
        this.resolutionNotes          = '';
    }

    handleWizardBack() {
        if (this.matchesStep === 2) {
            this.matchesStep = 1;
            if (this.matchesMode === 'link') {
                this.selectedAccountId = null;
                this.preview           = null;
                this.emailFieldOptions = [];
                this.emailTargetField  = '';
            }
        }
    }

    handleWizardNext() {
        if (this.matchesStep === 1 && this.wizardStep2Enabled) {
            this.matchesStep = 2;
        }
    }

    handleSelectCandidate(event) {
        const id = event.currentTarget.dataset.id;
        this.matchesMode = 'link';
        this._loadPreviewForAccount(id);
    }

    handleAccountSelected(event) {
        const id = event.detail.recordId;
        if (!id) { this.selectedAccountId = null; this.preview = null; this.emailFieldOptions = []; return; }
        this.matchesMode = 'link';
        this._loadPreviewForAccount(id);
    }

    handleSelectCreateMode(event) {
        this.matchesMode      = 'create';
        this.donorTypeForNew  = event.currentTarget.dataset.type || 'individual';
        this.selectedAccountId = null;
        this.preview           = null;
    }

    _loadPreviewForAccount(accountId) {
        this.selectedAccountId = accountId;
        this.preview           = null;
        this.emailFieldOptions = [];
        this.emailTargetField  = '';
        this.isLoadingPreview  = true;
        getLinkPreview({ ticketId: this.selectedTicketId, accountId })
            .then(result => {
                this.preview           = result;
                this.emailFieldOptions = result.emailFieldOptions || [];
                this.isLoadingPreview  = false;
            })
            .catch(err => {
                this.isLoadingPreview = false;
                this.showToast('Error loading comparison', this.extractError(err), 'error');
            });
    }

    handleEmailFieldChange(event)  { this.emailTargetField    = event.detail.value; }
    handleToggleEmail(event)       { this.updateEmailEnabled     = event.target.checked; if (!event.target.checked) this.emailTargetField = ''; }
    handleToggleAddress(event)     { this.updateAddressEnabled   = event.target.checked; }
    handleToggleFirstName(event)   { this.updateFirstNameEnabled = event.target.checked; }
    handleToggleLastName(event)    { this.updateLastNameEnabled  = event.target.checked; }

    handleAccountSearchInput(event) {
        this.accountSearch = event.target.value;
        if (this.accountSearch.length < 2) { this.accountSearchResults = []; return; }
        searchAccounts({ searchTerm: this.accountSearch })
            .then(res => { this.accountSearchResults = res; })
            .catch(() => { this.accountSearchResults = []; });
    }
    handleSelectAccountResult(event) {
        const id   = event.currentTarget.dataset.id;
        const name = event.currentTarget.dataset.name;
        this.accountSearch        = name;
        this.accountSearchResults = [];
        this.handleAccountSelected({ detail: { recordId: id } });
    }
    handleClearAccountSearch() {
        this.accountSearch        = '';
        this.accountSearchResults = [];
        this.selectedAccountId    = null;
        this.preview              = null;
    }

    handleConfirmLink() {
        if (!this.selectedAccountId) return;
        resolveLinkExisting({
            ticketId:         this.selectedTicketId,
            accountId:        this.selectedAccountId,
            notes:            this.resolutionNotes,
            emailTargetField: this.updateEmailEnabled ? (this.emailTargetField || null) : null,
            updateAddress:    this.updateAddressEnabled,
            updateFirstName:  this.updateFirstNameEnabled,
            updateLastName:   this.updateLastNameEnabled,
        })
            .then(() => {
                this.showMatchesModal = false;
                this.showToast('Success', 'Donor linked and donation recorded.', 'success');
                this.afterResolve();
            })
            .catch(err => this.showToast('Error', this.extractError(err), 'error'));
    }

    handleConfirmCreate() {
        resolveCreateNew({
            ticketId:  this.selectedTicketId,
            donorType: this.donorTypeForNew,
            notes:     this.resolutionNotes,
        })
            .then(() => {
                this.showMatchesModal = false;
                this.showToast('Success', 'Account created and donation recorded.', 'success');
                this.afterResolve();
            })
            .catch(err => this.showToast('Error', this.extractError(err), 'error'));
    }

    // ── Exception modal ────────────────────────────────────────────────────────
    handleOpenExceptionModal() {
        this.showExceptionModal = true;
        this.exceptionType      = 'skip';
        this.resolutionNotes    = '';
    }

    handleCloseExceptionModal() { this.showExceptionModal = false; }

    handleExceptionTypeChange(event) { this.exceptionType = event.currentTarget.dataset.type; }

    handleConfirmException() {
        if (this.exceptionType === 'pending') {
            // Keep as Pending Review — no Apex call needed
            this.showExceptionModal = false;
            this.resolutionNotes    = '';
            return;
        }
        const reason = (this.exceptionType === 'close' ? 'Closed: ' : 'Skipped: ') + (this.resolutionNotes || '');
        skipTicket({ ticketId: this.selectedTicketId, reason })
            .then(() => {
                this.showExceptionModal = false;
                this.showToast(this.exceptionType === 'close' ? 'Ticket closed' : 'Ticket skipped', '', 'success');
                this.afterResolve();
            })
            .catch(err => this.showToast('Error', this.extractError(err), 'error'));
    }

    // ── Follow-up Assignment modal ─────────────────────────────────────────────
    handleOpenAssignModal()  { this.showAssignModal = true; }
    handleCloseAssignModal() { this.showAssignModal = false; }

    handleNotesChange(event) { this.resolutionNotes = event.detail.value; }

    // ── Settings section nav ──────────────────────────────────────────────────
    handleSettingsSectionChange(event) {
        this.settingsSection = event.currentTarget.dataset.section;
    }

    // ── Settings handlers — Language ───────────────────────────────────────────
    handleLanguageChange(event) {
        const lang = event.detail.value;
        this.currentLanguage = lang;
        saveLanguage({ language: lang })
            .catch(err => console.error('Error saving language', this.extractError(err)));
    }

    handleLangPillClick(event) {
        const lang = event.currentTarget.dataset.lang;
        if (!lang || lang === this.currentLanguage) return;
        this.currentLanguage = lang;
        saveLanguage({ language: lang })
            .catch(err => console.error('Error saving language', this.extractError(err)));
    }

    // ── Settings handlers — Task automation ───────────────────────────────────
    handleAutoTaskToggle(event)   { this.autoTaskEnabled = event.detail.checked; }
    handleTaskDueDaysChange(event){ this.taskDueDays     = parseInt(event.detail.value, 10) || 2; }

    handleTaskOwnerFocus() {
        if (this.taskOwnerResults.length === 0) {
            this._searchOwners(this.taskOwnerSearch, 'task');
        }
    }

    handleTaskOwnerSearch(event) {
        this.taskOwnerSearch = event.target.value;
        this._searchOwners(this.taskOwnerSearch, 'task');
    }

    handleSelectTaskOwner(event) {
        const id   = event.currentTarget.dataset.id;
        const name = event.currentTarget.dataset.name;
        this.taskOwnerId      = id;
        this.taskOwnerName    = name;
        this.taskOwnerSearch  = name;
        this.taskOwnerResults = [];
    }

    handleClearTaskOwner() {
        this.taskOwnerId      = '';
        this.taskOwnerName    = '';
        this.taskOwnerSearch  = '';
        this.taskOwnerResults = [];
    }

    // ── Settings handlers — Lapsed donor ──────────────────────────────────────
    handleLapsedToggle(event)          { this.lapsedEnabled     = event.detail.checked; }
    handleLapsedDaysChange(event)      { this.lapsedDays        = parseInt(event.detail.value, 10) || 365; }
    handleLapsedScheduleChange(event)  { this.lapsedScheduleDay = event.detail.value; }
    handleLapsedFrequencyChange(event) { this.lapsedFrequency   = event.detail.value; }

    handleLapsedOwnerFocus() {
        if (this.lapsedOwnerResults.length === 0) {
            this._searchOwners(this.lapsedOwnerSearch, 'lapsed');
        }
    }

    handleLapsedOwnerSearch(event) {
        this.lapsedOwnerSearch = event.target.value;
        this._searchOwners(this.lapsedOwnerSearch, 'lapsed');
    }

    handleSelectLapsedOwner(event) {
        const id   = event.currentTarget.dataset.id;
        const name = event.currentTarget.dataset.name;
        this.lapsedOwnerId      = id;
        this.lapsedOwnerName    = name;
        this.lapsedOwnerSearch  = name;
        this.lapsedOwnerResults = [];
    }

    handleClearLapsedOwner() {
        this.lapsedOwnerId      = '';
        this.lapsedOwnerName    = '';
        this.lapsedOwnerSearch  = '';
        this.lapsedOwnerResults = [];
    }

    // ── Manual assignment handlers ────────────────────────────────────────────
    handleAssignOwnerFocus() {
        if (this.assignOwnerResults.length === 0) {
            this._searchOwners(this.assignOwnerSearch, 'assign');
        }
    }

    handleAssignOwnerSearch(event) {
        this.assignOwnerSearch = event.target.value;
        this._searchOwners(this.assignOwnerSearch, 'assign');
    }

    handleSelectAssignOwner(event) {
        const id   = event.currentTarget.dataset.id;
        const name = event.currentTarget.dataset.name;
        this.assignOwnerId      = id;
        this.assignOwnerName    = name;
        this.assignOwnerSearch  = name;
        this.assignOwnerResults = [];
    }

    handleClearAssignOwner() {
        this.assignOwnerId      = '';
        this.assignOwnerName    = '';
        this.assignOwnerSearch  = '';
        this.assignOwnerResults = [];
    }

    handleAssignDueDaysChange(event) {
        this.assignDueDays = parseInt(event.detail.value, 10) || 3;
    }

    handleAssignNoteChange(event) {
        this.assignNote = event.detail.value;
    }

    handleCreateAssignment() {
        if (!this.assignOwnerId || !this.selectedTicketId) return;
        this.isAssigning = true;
        assignTicket({
            ticketId:  this.selectedTicketId,
            ownerId:   this.assignOwnerId,
            ownerName: this.assignOwnerName,
            dueDays:   this.assignDueDays,
            note:      this.assignNote,
        })
            .then(() => {
                this.isAssigning = false;
                this.showToast('Task assigned', 'A personal task was created for ' + this.assignOwnerName + '. The global auto-task (if any) was cancelled.', 'success');
                this.showAssignModal = false;
                this.handleClearAssignOwner();
                this.assignNote = '';
                this.assignDueDays = 3;
                this.loadDetail();
                this.loadTickets();
            })
            .catch(err => {
                this.isAssigning = false;
                this.showToast('Error', this.extractError(err), 'error');
            });
    }

    _searchOwners(term, target) {
        searchOwners({ searchTerm: term || '' })
            .then(results => {
                if (target === 'task')   this.taskOwnerResults   = results;
                if (target === 'lapsed') this.lapsedOwnerResults = results;
                if (target === 'assign') this.assignOwnerResults = results;
            })
            .catch(err => console.error('Error searching owners', this.extractError(err)));
    }

    // ── Settings handlers — App settings save ─────────────────────────────────
    handleModalSave() {
        if (this.settingsSection === 'credentials') {
            this.handleSaveSettings();
        } else {
            this.handleSaveAppSettings();
        }
    }

    handleSaveAppSettings() {
        this.isSavingAppSettings = true;
        saveAppSettings({
            autoTaskEnabled:         this.autoTaskEnabled,
            taskDueDays:             this.taskDueDays,
            taskOwnerId:             this.taskOwnerId,
            taskOwnerName:           this.taskOwnerName,
            lapsedEnabled:           this.lapsedEnabled,
            lapsedDays:              this.lapsedDays,
            lapsedOwnerId:           this.lapsedOwnerId,
            lapsedOwnerName:         this.lapsedOwnerName,
            lapsedScheduleDay:       this.lapsedScheduleDay,
            lapsedScheduleFrequency: this.lapsedFrequency,
        })
            .then(() => {
                this.isSavingAppSettings = false;
                this.showToast(this.lbl.savedToast, this.lbl.savedAppToast, 'success');
            })
            .catch(err => {
                this.isSavingAppSettings = false;
                this.showToast('Error', this.extractError(err), 'error');
            });
    }

    // ── Settings handlers — Credentials (admin only) ──────────────────────────
    handleSettingsApiKeyChange(event)   { this.settingsApiKey   = event.detail.value; }
    handleSettingsSecretChange(event)   { this.settingsSecret   = event.detail.value; }
    handleSettingsActiveChange(event)   { this.settingsIsActive = event.detail.checked; }

    handleSaveSettings() {
        this.isSavingSettings = true;
        saveConfig({
            apiKey:        this.settingsApiKey,
            webhookSecret: this.settingsSecret,
            isActive:      this.settingsIsActive,
        })
            .then(() => {
                this.isSavingSettings = false;
                this.settingsApiKey = '';
                this.settingsSecret = '';
                this.showToast(this.lbl.savedToast, this.lbl.savedCredsToast, 'success');
                this.loadSettings();
            })
            .catch(err => {
                this.isSavingSettings = false;
                this.showToast('Error saving settings', this.extractError(err), 'error');
            });
    }

    // ── Undo handlers ──────────────────────────────────────────────────────────
    handleUndo()       { this.showUndoConfirm = true; }
    handleCancelUndo() { this.showUndoConfirm = false; }

    handleConfirmUndo() {
        this.showUndoConfirm = false;
        undoResolution({ ticketId: this.selectedTicketId })
            .then(() => {
                this.showToast('Resolution undone', 'Ticket reopened and logged for audit.', 'success');
                this.resetResolutionState();
                this.loadDetail();
                this.loadTickets();
                this.loadDashboardStats();
                this.loadAuditLog();
            })
            .catch(err => this.showToast('Error', this.extractError(err), 'error'));
    }

    // ── Data loading ───────────────────────────────────────────────────────────
    loadTickets() {
        this.isLoading = true;
        getTickets({ statusFilter: this.statusFilter })
            .then(result => {
                this.tickets = result;
                this.isLoading = false;
            })
            .catch(err => {
                this.isLoading = false;
                this.showToast('Error loading tickets', this.extractError(err), 'error');
            });
    }

    loadDetail() {
        this.isLoadingDetail = true;
        getTicketDetail({ ticketId: this.selectedTicketId })
            .then(result => {
                this.ticket = result;
                this.isLoadingDetail = false;
                if (result && result.Status__c === 'Pending Review') {
                    this.loadMatchCandidates();
                }
            })
            .catch(err => {
                this.isLoadingDetail = false;
                this.showToast('Error loading ticket', this.extractError(err), 'error');
            });
    }

    loadMatchCandidates() {
        this.isLoadingMatches = true;
        this.matchCandidates  = [];
        findAccountMatches({ ticketId: this.selectedTicketId })
            .then(result => {
                this.matchCandidates  = result || [];
                this.isLoadingMatches = false;
            })
            .catch(err => {
                this.isLoadingMatches = false;
                console.error('Error loading candidates', this.extractError(err));
            });
    }

    loadDashboardStats() {
        getDashboardStats()
            .then(result => { this.stats = result; })
            .catch(err => { console.error('Error loading dashboard stats', this.extractError(err)); });
    }

    loadAuditLog() {
        this.isLoadingAudit = true;
        getAuditLog()
            .then(result => {
                this.auditLog = result;
                this.isLoadingAudit = false;
            })
            .catch(err => {
                this.isLoadingAudit = false;
                console.error('Error loading audit log', this.extractError(err));
            });
    }

    loadSettings() {
        this.isLoadingSettings = true;
        loadConfig()
            .then(result => {
                // Credentials
                this.settingsApiKey   = result.apiKey        || '';
                this.settingsSecret   = result.webhookSecret || '';
                this.settingsIsActive = result.isActive !== 'false';
                // Language
                this.currentLanguage  = result.language      || 'en';
                // Task automation
                this.autoTaskEnabled  = result.autoTaskEnabled === 'true';
                this.taskDueDays      = parseInt(result.taskDueDays, 10) || 2;
                this.taskOwnerId      = result.taskOwnerId   || '';
                this.taskOwnerName    = result.taskOwnerName || '';
                this.taskOwnerSearch  = result.taskOwnerName || '';
                // Lapsed donor
                this.lapsedEnabled      = result.lapsedEnabled === 'true';
                this.lapsedDays         = parseInt(result.lapsedDays, 10) || 365;
                this.lapsedOwnerId      = result.lapsedOwnerId    || '';
                this.lapsedOwnerName    = result.lapsedOwnerName  || '';
                this.lapsedOwnerSearch  = result.lapsedOwnerName  || '';
                this.lapsedScheduleDay  = result.lapsedScheduleDay      || 'MON';
                this.lapsedFrequency    = result.lapsedScheduleFrequency || 'WEEKLY';

                this.isLoadingSettings = false;
            })
            .catch(err => {
                this.isLoadingSettings = false;
                console.error('Error loading settings', this.extractError(err));
            });
    }

    loadDonationHistory() {
        this.isLoadingHistory = true;
        getDonationHistory()
            .then(result => {
                this.donationHistory = result;
                this.isLoadingHistory = false;
            })
            .catch(err => {
                this.isLoadingHistory = false;
                console.error('Error loading donation history', this.extractError(err));
            });
    }

    // ── Helpers ────────────────────────────────────────────────────────────────
    afterResolve() {
        this.resetResolutionState();
        this.loadDetail();
        this.loadTickets();
        this.loadDashboardStats();
        this.loadAuditLog();
        this.loadDonationHistory();
    }

    resetResolutionState() {
        this.resolutionNotes      = '';
        this.selectedAccountId    = null;
        this.preview              = null;
        this.accountSearch            = '';
        this.accountSearchResults     = [];
        this.emailTargetField         = '';
        this.emailFieldOptions        = [];
        this.updateEmailEnabled       = false;
        this.updateAddressEnabled     = false;
        this.updateFirstNameEnabled   = false;
        this.updateLastNameEnabled    = false;
        this.matchCandidates      = [];
        this.isLoadingMatches     = false;
        this.donorTypeForNew      = 'individual';
        this.showMatchesModal     = false;
        this.matchesStep          = 1;
        this.matchesMode          = 'link';
        this.showExceptionModal   = false;
        this.exceptionType        = 'skip';
        this.showAssignModal      = false;
        this.showUndoConfirm      = false;
        this.assignOwnerId        = '';
        this.assignOwnerName      = '';
        this.assignOwnerSearch    = '';
        this.assignOwnerResults   = [];
        this.assignNote           = '';
        this.assignDueDays        = 3;
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    extractError(err) {
        if (err && err.body && err.body.message) return err.body.message;
        if (err && err.message) return err.message;
        return JSON.stringify(err);
    }

    // ── CSV Import handlers ────────────────────────────────────────────────────

    handleImportFileChange(event) {
        const file = event.target.files[0];
        if (!file) return;
        this.importFileName = file.name;
        this.importRows = [];
        this.importComplete = false;
        this.importErrors = [];
        const reader = new FileReader();
        reader.onload = (e) => {
            try {
                this.importRows = this._parseCSV(e.target.result);
            } catch(ex) {
                this.showToast('CSV Error', ex.message, 'error');
            }
        };
        reader.readAsText(file, 'UTF-8');
    }

    handleDownloadTemplate() {
        const headers = [
            'transaction_id','contact_id','first_name','last_name','email','phone',
            'company_name','address','city','province','postal_code','country','language',
            'amount','eligible_amount','currency','payment_method','payment_type',
            'gift_date','form_name','form_id','is_recurring','subscription_id',
            'subscription_frequency','rate_title','receipt_number','receipt_url',
            'note','annotation'
        ].join(',');
        const example = [
            'TX-2024-001','ZEFFY-CONTACT-001','John','Doe','john.doe@example.com',
            '514-555-0100','','123 Main St','Montreal','QC','H2X 1A1','CA','fr',
            '120.00','120.00','CAD','credit card','Donation',
            '2024-01-15','Annual Fund','form-abc','false','','',
            '','12345','','','Merci beaucoup!'
        ].join(',');
        const csv = headers + '\r\n' + example + '\r\n';
        const a = document.createElement('a');
        a.href = 'data:text/csv;charset=utf-8,' + encodeURIComponent(csv);
        a.download = 'zeffy_import_template.csv';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
    }

    async handleStartImport() {
        if (!this.importHasRows || this.isImporting) return;
        this.isImporting    = true;
        this.importComplete = false;
        this.importDone     = 0;
        this.importSkipped  = 0;
        this.importErrors   = [];
        this.importTotal    = this.importRows.length;

        const CHUNK = 500;
        let done = 0, skipped = 0, errors = [];

        for (let i = 0; i < this.importRows.length; i += CHUNK) {
            const chunk = this.importRows.slice(i, i + CHUNK);
            try {
                const result = await importTickets({ rowsJson: JSON.stringify(chunk) });
                done    += result.imported || 0;
                skipped += result.skipped  || 0;
                if (result.errors && result.errors.length) {
                    errors = errors.concat(result.errors.slice(0, 5));
                }
            } catch(ex) {
                errors.push('Chunk ' + (Math.floor(i / CHUNK) + 1) + ': ' + this.extractError(ex));
            }
            this.importDone    = done;
            this.importSkipped = skipped;
            this.importErrors  = [...errors];
        }

        this.isImporting    = false;
        this.importComplete = true;
        if (done > 0) this.loadTickets();  // refresh ticket list
    }

    handleClearImport() {
        this.importRows     = [];
        this.importFileName = '';
        this.importDone     = 0;
        this.importSkipped  = 0;
        this.importErrors   = [];
        this.importTotal    = 0;
        this.isImporting    = false;
        this.importComplete = false;
    }

    _parseCSV(text) {
        const lines = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');
        const nonEmpty = lines.filter(l => l.trim().length > 0);
        if (nonEmpty.length < 2) throw new Error('CSV must have a header row and at least one data row.');
        const headers = this._parseCSVLine(nonEmpty[0]).map(h => h.trim().toLowerCase());
        const rows = [];
        for (let i = 1; i < nonEmpty.length; i++) {
            const vals = this._parseCSVLine(nonEmpty[i]);
            const obj  = {};
            headers.forEach((h, idx) => { obj[h] = (vals[idx] || '').trim(); });
            // skip completely empty rows
            if (Object.values(obj).some(v => v.length > 0)) rows.push(obj);
        }
        return rows;
    }

    _parseCSVLine(line) {
        const result = [];
        let current = '', inQuotes = false;
        for (let i = 0; i < line.length; i++) {
            const ch = line[i];
            if (ch === '"') {
                if (inQuotes && line[i + 1] === '"') { current += '"'; i++; }
                else inQuotes = !inQuotes;
            } else if (ch === ',' && !inQuotes) {
                result.push(current); current = '';
            } else {
                current += ch;
            }
        }
        result.push(current);
        return result;
    }
}
