import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import hasSettingsAccess   from '@salesforce/customPermission/Zeffy_Connect_Settings_Access';
import getTickets          from '@salesforce/apex/ZeffyConnectDonationService.getTickets';
import getTicketDetail     from '@salesforce/apex/ZeffyConnectDonationService.getTicketDetail';
import getLinkPreview      from '@salesforce/apex/ZeffyConnectDonationService.getLinkPreview';
import resolveLinkExistingEdited from '@salesforce/apex/ZeffyConnectDonationService.resolveLinkExistingEdited';
import resolveCreateNewEdited from '@salesforce/apex/ZeffyConnectDonationService.resolveCreateNewEdited';
import closeTicket         from '@salesforce/apex/ZeffyConnectDonationService.closeTicket';
import getMyTasks          from '@salesforce/apex/ZeffyConnectDonationService.getMyTasks';
import getDashboardStats   from '@salesforce/apex/ZeffyConnectDonationService.getDashboardStats';
import undoResolution      from '@salesforce/apex/ZeffyConnectDonationService.undoResolution';
import getAuditLog         from '@salesforce/apex/ZeffyConnectDonationService.getAuditLog';
import getDonationHistory  from '@salesforce/apex/ZeffyConnectDonationService.getDonationHistory';
import loadConfig          from '@salesforce/apex/ZeffyConnectConfigService.loadConfig';
import saveConfig             from '@salesforce/apex/ZeffyConnectConfigService.saveConfig';
import sendTestWebhook        from '@salesforce/apex/ZeffyConnectConfigService.sendTestWebhook';
import saveLanguage        from '@salesforce/apex/ZeffyConnectConfigService.saveLanguage';
import saveAppSettings     from '@salesforce/apex/ZeffyConnectConfigService.saveAppSettings';
import searchOwners        from '@salesforce/apex/ZeffyConnectConfigService.searchOwners';
import searchAccounts      from '@salesforce/apex/ZeffyConnectConfigService.searchAccounts';
import assignTicket        from '@salesforce/apex/ZeffyConnectDonationService.assignTicket';
import importTickets       from '@salesforce/apex/ZeffyConnectDonationService.importTickets';
import findAccountMatches  from '@salesforce/apex/ZeffyConnectDonationService.findAccountMatches';
import getCampaignMappings    from '@salesforce/apex/ZeffyConnectDonationService.getCampaignMappings';
import saveCampaignMapping    from '@salesforce/apex/ZeffyConnectDonationService.saveCampaignMapping';
import searchCampaigns        from '@salesforce/apex/ZeffyConnectDonationService.searchCampaigns';
import clearTicketAssignment  from '@salesforce/apex/ZeffyConnectDonationService.clearTicketAssignment';
import getWebhookHealthStats    from '@salesforce/apex/ZeffyConnectDonationService.getWebhookHealthStats';
import getWebhookLogs           from '@salesforce/apex/ZeffyConnectDonationService.getWebhookLogs';
import saveEventToggles         from '@salesforce/apex/ZeffyConnectConfigService.saveEventToggles';
import saveTicketActions        from '@salesforce/apex/ZeffyConnectConfigService.saveTicketActions';
import getTransactionTimeline   from '@salesforce/apex/ZeffyConnectDonationService.getTransactionTimeline';
import getFundsWithCampaigns    from '@salesforce/apex/ZeffyConnectFundService.getFundsWithCampaigns';
import getActiveFunds           from '@salesforce/apex/ZeffyConnectFundService.getActiveFunds';
import createFund               from '@salesforce/apex/ZeffyConnectFundService.createFund';
import assignCampaignToFund     from '@salesforce/apex/ZeffyConnectFundService.assignCampaignToFund';
import updateTicketFund         from '@salesforce/apex/ZeffyConnectFundService.updateTicketFund';
import bulkResolveLinkExisting  from '@salesforce/apex/ZeffyConnectDonationService.bulkResolveLinkExisting';
import bulkResolveCreateNew     from '@salesforce/apex/ZeffyConnectDonationService.bulkResolveCreateNew';
import bulkResolveLinkExistingEdited from '@salesforce/apex/ZeffyConnectDonationService.bulkResolveLinkExistingEdited';
import addReviewNote            from '@salesforce/apex/ZeffyConnectDonationService.addReviewNote';
import moveTicketToReview       from '@salesforce/apex/ZeffyConnectDonationService.moveTicketToReview';
import returnTicketToWaiting    from '@salesforce/apex/ZeffyConnectDonationService.returnTicketToWaiting';
import updateAccountAddressFromTicket from '@salesforce/apex/ZeffyConnectDonationService.updateAccountAddressFromTicket';
import reprocessWebhookLog      from '@salesforce/apex/ZeffyConnectDonationService.reprocessWebhookLog';
import markAmountReviewed  from '@salesforce/apex/ZeffyConnectDonationService.markAmountReviewed';
import getReassignPreview       from '@salesforce/apex/ZeffyConnectDonationService.getReassignPreview';
import searchReassignAccounts   from '@salesforce/apex/ZeffyConnectDonationService.searchReassignAccounts';
import reassignZeffyId          from '@salesforce/apex/ZeffyConnectDonationService.reassignZeffyId';
import getReassignProgress      from '@salesforce/apex/ZeffyConnectDonationService.getReassignProgress';
import getGroupTickets          from '@salesforce/apex/ZeffyConnectDonationService.getGroupTickets';
import LightningConfirm         from 'lightning/confirm';

const PAGE_SIZE = 500;
const LP_SIZE   = 500;   // left-panel ticket list page size
const DUP_CACHE = new WeakMap(); // tickets array → Set of repeated Zeffy Contact IDs (non-reactive)
const GAP_CACHE = new WeakMap(); // stats.monthly / stats.weekly array → same series with empty weeks/months filled

// ── i18n label map ────────────────────────────────────────────────────────────
const LABELS = {
    en: {
        // Settings
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
        credWebhookUrl:       'Webhook URL',
        credWebhookUrlHint:   'Paste your Salesforce Site webhook URL here (used for the Test Webhook button in System → Health).',
        credInfo:             'Where to find these values',
        credInfoLine1:        'Log in to Zeffy → Settings → Integrations → API',
        credInfoLine2:        'Webhook Secret is shown when creating a new webhook endpoint',
        credHint:             'Current values are masked. Type a new value to replace — leave blank to keep existing.',
        testWebhookTitle:     'Test Webhook',
        testWebhookOpen:      'Test Webhook',
        testWebhookDesc:      'Sends a signed test payload to your Salesforce Site endpoint, simulating a real Zeffy event.',
        testWebhookEvent:     'Event type',
        testWebhookSend:      'Send test',
        testWebhookSending:   'Sending…',
        testWebhookOk:        'Webhook received and processed.',
        testWebhookFail:      'Webhook failed.',
        testWebhookTxId:      'Transaction ID',
        testLogBadge:         'TEST',
        healthDupBadge:       'DUPLICATE',
        saveBtn:              'Save',
        savingBtn:            'Saving...',
        savedToast:           'Settings saved',
        savedCredsToast:      'Zeffy credentials updated successfully.',
        savedAppToast:        'Automation settings saved.',
        mon: 'Monday', tue: 'Tuesday', wed: 'Wednesday', thu: 'Thursday', fri: 'Friday',
        freqWeekly: 'Weekly', freqMonthly: 'Monthly',
        lapsedFrequencyLabel: 'Frequency',
        navImport:            'CSV Import',
        navCampaigns:         'Campaign Mapping',
        importDesc:           'Upload a CSV file to bulk-create Pending Review tickets from historical Zeffy donations. Up to 500 rows per batch — large files are split automatically. Duplicate transaction IDs are skipped.',
        btnDownloadTemplate:  'Download CSV Template',
        importClickToSelect:  'Click to select a CSV file',
        importRowsWord:       'rows',
        importingProgress:    'imported…',
        ticketsCreated:       'tickets created',
        duplicatesSkipped:    'duplicates skipped',
        errorsCount:          'errors',
        btnImportAnother:     'Import another file',
        campSearchPlaceholder:'Search campaign to link...',
        campZeffyFormId:      'Zeffy Form ID',
        campFormIdPlaceholder:'e.g. abc123',
        campZeffyManaged:     'Zeffy Managed (auto-created by robot)',
        colZeffyFormId:       'Zeffy Form ID',
        colType:              'Type',
        noCampaigns:          'No campaigns linked to Zeffy yet.',
        campHint:             'Link existing Salesforce campaigns to Zeffy form IDs. Campaigns marked Zeffy Managed were created automatically by the robot.',
        btnImport:            'Import',
        btnClose:             'Close',
        // Left panel
        searchPlaceholder:    'Search name, email, ticket #...',
        ticketsWord:          'tickets',
        ofWord:               'of',
        pageJumpHint:         'Click to jump to page',
        pagePrev:             'Previous page',
        pageNext:             'Next page',
        noTickets:            'No tickets found.',
        collapse:             '▲ Collapse',
        showMore:             '▼ Show {n} more {w}',
        // Tab bar
        tabDashboard:         'Dashboard',
        tabHistory:           'Donation History',
        tabAudit:             'Audit Log',
        tabLogs:              'Logs',
        tabMyTasks:           'My Tasks',
        // Dashboard
        dashEyebrow:          'Dashboard',
        dashOverview:         'Overview',
        dashTilesHint:        'Click a tile to filter the list.',
        dashAutoMatch:        'Auto-match rate',
        dashAutoMatchSub:     '{0} of {1} resolved by the robot',
        dashMonthTotal:       'Processed in',
        srcRobot:             'Robot',
        srcStaff:             'Staff',
        colOn:                'On',
        colBy:                'By',
        statTotal:            'Total Tickets',
        statPending:          'Pending Review',
        statResolved:         'Resolved',
        statErrors:           'Errors',
        statDelayed:          'Delayed',
        statClosed:           'Closed',
        statAutoMatched:      'Auto-Matched',
        statMatchRate:        'Match Rate',
        statTotalProcessed:   'Total Processed Monthly',
        monthNames:           ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'],
        chartWeekly:          'Tickets per Week',
        wkCreated:            'Created',
        wkClosed:             'Closed',
        wkThisWeek:           'This Week',
        wkLastWeek:           '{0} last week',
        wkStillOpen:          'Still open',
        dashTopCampaigns:     'Top Campaigns',
        colCampaign:          'Campaign',
        colDonations:         'Donations',
        colTotal:             'Total',
        dashRecentRes:        'Recent Resolutions',
        colTicket:            'Ticket #',
        colDonor:             'Donor',
        colAmount:            'Amount',
        colStatus:            'Status',
        colResolvedOn:        'Resolved On',
        colResolvedBy:        'Resolved By',
        noRecentRes:          'No recent resolutions.',
        // Donation history
        histTitle:            'Donation History',
        histSub:              'All donations processed by the robot — auto and manual',
        histSearch:           'Search by name, phone, ticket # or transaction ID...',
        colSource:            'Source',
        colGiftNum:           'Gift #',
        colDate:              'Date',
        colPayment:           'Payment',
        colZeffyTx:           'Zeffy TX ID',
        noDonations:          'No donations found.',
        pagPrev:              '‹ Prev',
        pagNext:              'Next ›',
        // My Tasks
        myTasksTitle:         'My Tasks',
        myTasksSub:           'Open Zeffy Connect tasks assigned to you',
        due:                  'Due',
        allCaughtUp:          'All caught up!',
        noTasks:              'You have no open Zeffy Connect tasks.',
        // Ticket detail — section titles
        secDonorDetails:      'Donor Details',
        chipPayment:          'Payment: {0}',
        showAllDetails:       'Show all details',
        hideAllDetails:       'Hide details',
        secDonorInfo:         'Donor Information',
        secGiftDetails:       'Gift Details',
        secCardDetails:       'Card Details',
        secFund:              'Fund',
        secCampaign:          'Campaign',
        secTribute:           'Tribute',
        secDispute:           'Dispute',
        secRefund:            'Refund',
        secDiscount:          'Discount',
        secBuyerQuestions:    'Buyer Questions',
        secZeffyNotes:        'Zeffy Notes',
        // Ticket detail — field labels
        fldFirstName:         'First Name',
        fldLastName:          'Last Name',
        fldCompany:           'Company / Church',
        fldEmail:             'Email',
        fldPhone:             'Phone',
        fldContactPerson:     'Contact person',
        fldCampaign:          'Campaign',
        cardOrg:              'Org:',
        cardDonor:            'Donor:',
        cardContact:          'Contact:',
        fldOrigin:            'Origin in Zeffy',
        originOnline:         'Online',
        originOnlineHint:     'Zeffy form',
        originManual:         'Manual',
        originManualHint:     'entered by staff in Zeffy',
        originImported:       'Imported',
        originImportedHint:   'imported into Zeffy',
        fldLanguage:          'Language',
        fldAddress:           'Address',
        fldCity:              'City',
        fldProvince:          'Province',
        fldPostalCode:        'Postal Code',
        fldCountry:           'Country',
        fldZeffyContactId:    'Zeffy Contact ID',
        fldAmount:            'Amount',
        fldEligibleAmount:    'Eligible Amount',
        fldPaymentMethod:     'Payment Method',
        fldGiftDate:          'Gift Date',
        fldFormName:          'Form Name',
        fldIsRecurring:       'Is Recurring',
        fldTransactionId:     'Transaction ID',
        fldZeffyReceipt:      'Zeffy Receipt',
        viewReceipt:          'View receipt ↗',
        fldTxStatus:          'Payment Status',
        txPending:            'Pending',
        txSucceeded:          'Succeeded',
        txFailed:             'Failed',
        txDeleted:            'Deleted',
        txRefunded:           'Refunded',
        fldCardBrand:         'Card Brand',
        fldLast4:             'Last 4 Digits',
        fldFundName:          'Fund Name',
        fldFundCode:          'Fund Code',
        fldFundId:            'Fund ID',
        fldCategory:          'Category',
        fldCorporateDonor:    'Corporate Donor',
        fldTributeType:       'Tribute Type',
        fldInHonourOf:        'In Honour Of',
        fldStatus:            'Status',
        fldReason:            'Reason',
        fldCode:              'Code',
        fldNote:              'Note',
        fldAnnotation:        'Annotation',
        fldCurrency:          'Currency',
        fldPaymentType:       'Payment Type',
        fldSubscriptionFreq:  'Subscription Frequency',
        fldReceiptNumber:     'Receipt Number',
        fldLinkedAccount:     'Linked Account',
        fldResolvedOn:        'Resolved On',
        fldResolvedBy:        'Resolved By',
        fldName:              'Name',
        fldDate:              'Date',
        fldForm:              'Form',
        fldRecurring:         'Recurring',
        fldPayment:           'Payment',
        yes:                  'Yes',
        no:                   'No',
        // Action buttons
        btnException:         'Exception',
        btnViewMatches:       'Review & Match Donor',
        btnFollowup:          'Follow-up Assignment',
        btnCancel:            'Cancel',
        btnBack:              'Back',
        btnContinue:          'Continue',
        btnAssign:            'Assign',
        btnRemoveAssign:      'Remove Assignment',
        btnLink:              'Link & Record Donation',
        btnCreateDonation:    'Create & Record Donation',
        btnCreate:            'New',
        btnYesUndo:           'Yes, Undo',
        btnUndoResolution:    'Undo Resolution',
        // Exception modal
        excTitle:             'Exception',
        excSub:               'How do you want to handle this ticket?',
        excCloseCard:         'Close',
        excCloseDesc:         'Ticket is closed — donation will not be processed.',
        excKeepPending:       'Keep Pending',
        excKeepPendingDesc:   'Leave as Pending Review — add a note for the next reviewer.',
        excNoteLabel:         'Note / Reason (optional)',
        excSkipLabel:         'Skip Ticket',
        excCloseLabel:        'Close Ticket',
        excKeepLabel:         'Keep Pending',
        // Undo modal
        undoTitle:            'Undo Resolution',
        undoBody:             'This will delete the GiftTransaction, the recurring commitment (if no other installment uses it) and the Zeffy campaign created by this resolution (if nothing else uses it), then reopen the ticket to Pending Review. The linked Account will NOT be deleted. This action is logged in the Audit Log. Continue?',
        // Follow-up assignment modal
        assignTitle:          'Follow-up Assignment',
        assignBody:           'Assign this ticket to a specific person for follow-up. This overrides the global auto-task.',
        assignSearch:         'Search user or queue...',
        assignDueDays:        'Due in (days)',
        assignNote:           'Note (optional)',
        // Wizard
        wizTitle:             'Review & Match Donor',
        wizStep1:             'Select Account',
        wizStep2:             'Review & Confirm',
        wizHint:              'Is this donor already in Salesforce?',
        wizModeLink:          'Existing account',
        wizModeLinkDesc:      'Link this donation to a donor already in Salesforce',
        wizModeCreate:        'New account',
        wizModeCreateDesc:    'Create a new donor record from the Zeffy data',
        wizCreateTypeTitle:   'What kind of account?',
        wizPossibleMatches:   'Possible Matches for:',
        wizCheckDetails:      'Check the details',
        wizNoMatches:         'No automatic matches found.',
        wizSearchSF:          'Search Salesforce Account',
        wizSearchPlaceholder: 'Name or email...',
        wizOrCreate:          'or create a new account',
        wizIndividual:        'Individual',
        wizChurch:            'Church (Église)',
        wizOrg:               'Organization',
        wizBusiness:          'Business',
        colZeffyIncoming:     'Zeffy (incoming)',
        colSFCurrent:         'Salesforce (current)',
        colUpdate:            'Update',
        cmpDiffers:           'Different',
        wizNoZeffyId:         'No Zeffy ID yet — this will be the first',
        wizTargetField:       'Target field',
        wizSelectField:       '— Select field —',
        wizNoEmailFields:     'No email-type fields found on Account.',
        wizEditHint:          'Click the pencil to correct a Zeffy value. Check Update to save it to the account. The ticket keeps what Zeffy sent.',
        wizEditValue:         'Correct this value',
        wizDiscardEdit:       'Discard correction',
        wizEditNeedsUpdate:   'Check Update to save this correction to the account.',
        rvFromZeffy:          'From Zeffy',
        rvSfAccount:          'Salesforce account',
        rvIdFirst:            'First Zeffy ID',
        rvIdNth:              'Zeffy ID #{n}',
        rvIdsOnAccount:       'Zeffy IDs already on this account: {ids}',
        rvEmails:             'Emails',
        rvAddrBilling:        'Billing',
        rvEmpty:              'empty',
        rvTagSame:            'SAME',
        rvSameLocked:         'Already saved here. To save a different email, edit it with the pencil.',
        rvSameLockedAddr:     'The account already has this address. To save a different one, edit it with the pencil.',
        rvTagAdd:             'ADD',
        rvTagReplace:         'REPLACE',
        rvNotOnAccount:       'Not on this account',
        rvAlreadyOnAccount:   'Already on the account',
        rvNameKept:           'Different — the account keeps its name',
        rvPickSlot:           'Pick a slot on the right to save it.',
        rvWillReplace:        'Will replace the {field}.',
        rvWillAdd:            'Will be added as {field}.',
        rvClickToReplace:     'Click the slot on the right to replace it.',
        rvWillReplaceShort:   'Will replace what the account has.',
        rvClickAgain:         'Click again to leave it as it is.',
        rvConfirmTitle:       'When you confirm',
        rvSumRecord:          'Record ',
        rvSumOn:              ' on ',
        rvSumEmailAdd:        'Add ',
        rvSumEmailReplace:    'Replace {field} with ',
        rvSumAs:              ' as ',
        rvSumEmailsSame:      'Emails stay as they are',
        rvSumAddrReplace:     'Replace the billing address with ',
        rvSumAddrSame:        'Address stays as it is',
        rvSumFoot:            'The Zeffy ticket keeps exactly what Zeffy sent. Every change goes to the Audit Log (before → after).',
        rvAddNote:            '+ Add a note for the history',
        rvLinkRecord:         'Link & record {amount}',
        wizCreateEditHint:    'Corrections are saved to the new account. The ticket keeps what Zeffy sent.',
        wizAccountName:       'Account name',
        wizStreet:            'Street',
        wizInvalidEmail:      'Enter a valid email address.',
        wizResolutionNotes:   'Resolution Notes (optional)',
        wizCreateDesc:        'A new Salesforce Account will be created using the Zeffy donor information below, and the donation will be recorded.',
        wizDonorSection:      'Donor',
        wizDonationSection:   'Zeffy Donation',
        // Audit log
        auditTitle:           'Audit Log',
        auditSub:             'Full history of resolutions, creations, and rollbacks',
        auditSearch:          'Search by ticket #, name, email, phone, log #, performed by...',
        colAction:            'Action',
        colLogNum:            'Log #',
        colAccount:           'Account',
        colPerformedBy:       'Performed By',
        colDateTime:          'Date & Time',
        colNotes:             'Notes',
        noAuditLog:           'No audit log entries found.',
        // Status filter options
        statusOpen:           'Open (except resolved)',
        statusAll:            'All Statuses',
        statusPending:        'Pending Review',
        statusLinked:         'Resolved - Linked',
        statusNewContact:     'Resolved - New Contact',
        statusDelayed:        'Delayed',
        statusAssigned:       'Assigned',
        statusClosed:         'Closed',
        statusError:          'Error',
        statusSkipped:        'Skipped',
        statusAuto:           'Auto-processed (robot)',
        stageWaiting:         'Holding · Payment Failed',
        stageResolved:        'Resolved by staff (Linked · New contact)',
        stageRobot:           'Resolved by robot (auto-processed)',
        stageAddress:         'Updates',
        stageAssigned:        'Assigned to someone',
        stageClosed:          'Closed (Closed · Error)',
        cardFilterHint:       'Show these tickets in the list',
        statusAddrDiffers:    '📍 Address differs',
        tooltipAuto:          'The robot recognized the donor by Zeffy ID and recorded the donation on its own. You can open it, check it and undo it.',
        resolvedByRobot:      'Zeffy Connect robot',
        chipAddrDiffers:      '📍 Address differs',
        addrDiffTitle:        'The Zeffy address is different from the account address',
        addrDiffBody:         'The donor entered this address in Zeffy (usually the one on the receipt). Update the account if the Zeffy address is the current one.',
        addrZeffy:            'Zeffy (donor)',
        addrSalesforce:       'Salesforce (account billing)',
        addrEmpty:            '(no address)',
        btnUpdateAddress:     'Update address',
        addrUpdatedTitle:     'Address updated',
        addrUpdatedBody:      'The account now has the Zeffy address.',
        keptPendingTitle:     'Ticket left in Pending Review',
        fldClosedOn:          'Closed On',
        btnReopen:            'Reopen ticket',
        loading:              'Loading',
        ticketWord:           'ticket',
        dupWarnTitle:         'Possible duplicate',
        dupWarnBody:          '{0} already exists in Salesforce with a {1}% match. Link the donation to that account unless you are sure this is a different donor.',
        dupWarnUse:           'Use {0}',
        reviewerNotes:        'Notes for the reviewer',
        noteSavedTitle:       'Note saved',
        noteSavedBody:        'The ticket stays in Pending Review.',
        undoneTitle:          'Resolution undone',
        statusHolding:        'Holding',
        statusPaymentFailed:  'Payment Failed',
        tooltipPaymentFailed: 'Zeffy reported the payment as failed or deleted.',
        chipDispute:          'Dispute',
        chipRefund:           'Refund',
        btnMoveToReview:      'Move to review',
        btnCloseTicket:       'Close ticket',
        moveReviewToast:      'Ticket moved to Pending Review',
        btnReturnHolding:     'Return to Holding',
        btnReturnDelayed:     'Return to Delayed',
        returnWaitingToast:   'Ticket sent back to {0}',
        closeConfirmTitle:    'Close this ticket?',
        closeConfirmBody:     'The ticket will be closed without creating a gift. You can add a note for the audit log.',
        closeConfirmNote:     'Note (optional)',
        closedToast:          'Ticket closed',
        bulkAccountsCreated:  '{n} account(s) created or reused.',
        btnReprocess:         'Reprocess',
        amtReviewChip:        'Amount changed',
        amtReviewTitle:       'Zeffy reports a different amount',
        amtReviewBody:        'Zeffy now reports {new} for this payment; Salesforce has {old}. Nothing was changed automatically — check it, update the GiftTransaction by hand if needed, then mark it as reviewed.',
        btnAmtReviewed:       'Mark as reviewed',
        amtReviewedToast:     'Amount marked as reviewed',
        reprocessToast:       'Webhook reprocessed: {status}',
        reprocessConfirm:     'Run this stored webhook payload through Zeffy Connect again?',
        tooltipHolding:       'Waiting for Zeffy to confirm the payment. It moves to Pending Review on its own.',
        tooltipPending:       'In active review — no expiry timer. Staff is working this ticket.',
        tooltipResolved:      'Donation has been matched and recorded in Salesforce.',
        tooltipDelayed:       'Zeffy never confirmed the payment within the waiting period.',
        tooltipClosed:        'Ticket closed — donation will not be processed.',
        tooltipError:         'An error occurred while processing this ticket.',
        tooltipSkipped:       'Ticket was skipped during review.',
        tooltipCountdown:     'Resets each time Zeffy sends an update for this ticket.',
        resolveGroupBtn:      'Resolve {n} tickets',
        bulkModalTitle:       'Resolve Group',
        bulkStep1Hint:        'Select or create one Account — all tickets will be linked to it.',
        bulkStep2Title:       'Confirm Bulk Resolution',
        bulkTicketsLabel:     'Tickets to resolve',
        bulkIdLabel:          'Zeffy ID',
        bulkIdSame:           'same on all {n} tickets',
        bulkAllMatch:         'name, email and address match',
        bulkVarShow:          'See differences',
        bulkVarHide:          'Hide',
        bulkVarNameHdr:       'Name',
        bulkVarEmailHdr:      'Email',
        bulkVarAddrHdr:       'Address',
        bulkShowAllMatches:   'Show all matches ({n}) ▾',
        bulkShowFewer:        'Show fewer ▴',
        bulkVarNoEmail:       '(no email)',
        bulkVarNoAddr:        '(no address)',
        bulkConfirmBtn:       'Resolve {n} tickets',
        bulkProgress:         'Resolving… batch {i} of {n}',
        bulkNotSent:          '{n} tickets were not sent — open the group again to finish them.',
        rvAcctNotUpdated:     'Donation recorded — the account was not updated',
        bulkSuccessToast:     '{n} tickets resolved successfully.',
        bulkPartialToast:     '{resolved} of {total} tickets resolved. {errors} errors.',
        bgTicketsAmt:         '{n} tickets ({amount})',
        bgTicketsCount:       '{n} tickets',
        bgSeeAmounts:         'See amounts ▾',
        bgHideAmounts:        'Hide ▴',
        bgLinkBtn:            'Link & record {n} tickets',
        bgPickEmail:          'Pick an email here, then click a slot on the right to save it.',
        bgPickAddr:           'Choose which address Zeffy sent is the right one.',
        bgRecent:             'most recent',
        bgAssignedTo:         '→ {field}',
        bgNewAccount:         'New account',
        bgAllEmailsOn:        'All on the account',
        holdingDaysLeft:      '{0} days left',
        holdingExpiresToday:  'Expires today',
        // Nav group headers
        navGroupGeneral:      'General',
        navGroupAutomation:   'Automation',
        navGroupAdmin:        'Administration',
        navGroupZeffy:        'Zeffy Integration',
        navGroupData:         'Data Management',
        navGroupSystem:       'System',
        navCreds:             'Zeffy Connection',
        navTicketActions:     'Ticket Actions',
        ticketActionsTitle:   'Ticket Actions',
        ticketActionsDesc:    'Choose which optional actions reviewers see at the bottom of each ticket.',
        showFollowupLabel:    'Show "Follow-up Assignment" button',
        showFollowupHint:     'When off, the button is hidden for everyone. Tickets that already have a follow-up assignee keep showing it.',
        savedTicketActionsToast: 'Ticket actions updated.',
        // Robot Health
        navHealth:            'Robot Health',
        healthTitle:          'Robot Health',
        healthSub:            'Monitor webhook calls and diagnose connection issues',
        healthActive:         'Connection active — robot is running',
        healthInactive:       'Connection inactive (paused in Credentials)',
        healthLastReceived:   'Last Webhook Received',
        healthNever:          'Never',
        healthLast24h:        'Last 24 hours',
        healthLast7d:         'Last 7 days',
        healthCalls:          'Total Calls',
        healthSuccess:        'Successful',
        healthErrors:         'Errors',
        healthLogTitle:       'Webhook Log',
        healthSearchHolder:   'Search TX ID, donor, message...',
        healthFilterAll:      'All statuses',
        healthColDate:        'Date',
        healthColStatus:      'Status',
        healthColTxId:        'TX ID',
        healthColDonor:       'Donor',
        healthColAmount:      'Amount',
        healthColMessage:     'Message',
        healthNoLogs:         'No webhook logs found.',
        healthLoadMore:       'Load more',
        healthDetail:         'Technical Detail',
        healthRefresh:        'Refresh',
        healthToday:          'Today',
        healthGapTitle:       'No contact since',
        healthGapCopy:        'Copy date for Zeffy CSV export',
        healthErrChip:        'Errors',
        healthDupChip:        'Duplicates',
        healthRateChip:       'Success',
        // Event Processing
        navEvents:            'Event Processing',
        eventsTitle:          'Event Processing',
        eventsDesc:           'Control which Zeffy webhook events the robot processes automatically.',
        evtCompletedLabel:    'payment.completed — Create ticket or GiftTransaction',
        evtCompletedAlwaysOn: 'ON (always)',
        evtCreatedLabel:      'payment.created — Create Holding ticket (funnel visibility)',
        evtCreatedHint:       'Creates a Holding ticket when a donation form is submitted, before payment is confirmed. Useful to track abandonment and bank rejections.',
        evtUpdatedLabel:      'payment.updated — Update existing ticket / GiftTransaction',
        evtUpdatedHint:       'Updates fields on existing records when Zeffy sends changes (e.g. receipt URL, refund status). Also graduates Holding tickets to Pending Review when payment is confirmed.',
        evtDeletedLabel:      'payment.deleted — Mark ticket as Payment Failed',
        evtDeletedHint:       'Marks existing tickets as Payment Failed when Zeffy deletes the payment.',
        evtContactLabel:      'contact.* — Receive Zeffy contact events (manual review only)',
        evtContactHint:       'Logs contact.created / contact.updated / contact.deleted events. The robot never auto-updates Accounts — staff always reviews manually.',
        evtHoldingExpireLabel: 'Auto-expire HOLDING tickets → Delayed',
        expireOffTitle:        'Auto-expire for HOLDING tickets is off.',
        expireOffMsg:          'Switched off {0} ago ({1}). HOLDING tickets are not moving to Delayed.',
        expireOffBtn:          'Turn back on',
        expireOffOnToast:      'Auto-expire for HOLDING tickets is back on.',
        evtHoldingExpireHint:  'Automatically moves HOLDING tickets to Delayed after the configured number of days since the ticket was created.',
        evtHoldingExpireDaysLabel: 'Expiry window (days)',
        savedEventsToast:     'Event processing settings saved.',
        evtOn:                'ON',
        evtOff:               'OFF',
        // Tooltips
        ttRefresh:            'Refresh',
        ttSettings:           'Settings',
        ttClose:              'Close',
        ttOlder:              'Older',
        ttNewer:              'Newer',
        ttClearSearch:        'Clear search',
        ttOpenTicket:         'Open ticket',
        histUndone:           'Undone',
        histUndoneTip:        'Resolution undone {0} by {1} — the gift was deleted. Disappears if the ticket is linked to this donor again.',
        ttTimeline:           'View transaction timeline',
        ttRemove:             'Remove',
        // Timeline modal
        loadingComparison:    'Loading comparison...',
        timelineTitle:        'Transaction Timeline',
        timelineLoading:      'Loading…',
        timelineEmpty:        'No timeline entries found for this transaction.',
        wizFund:              'Fund',
        // Funds
        navFunds:             'Funds',
        fundsTitle:           'Fund Management',
        fundsDesc:            'Create funds and assign Zeffy campaigns to them. Each campaign can belong to only one fund. When a new donation arrives, the robot automatically fills in the fund from the campaign mapping.',
        fundsUnassigned:      'Unassigned',
        fundsNewFund:         'New Fund',
        fundNamePlaceholder:  'Fund name',
        fundDescPlaceholder:  'Description (optional)',
        fundCreate:           'Create',
        fundCancel:           'Cancel',
        fundCreated:          'Fund created.',
        fundAssigned:         'Campaign assigned.',
        fundNoFunds:          'No funds yet. Create one to get started.',
        fundNoCampaigns:      'No campaigns in this fund.',
        fundUnassignedEmpty:  'All campaigns are assigned to a fund.',
        moveTo:               'Move to fund',
        fldFund:              'Fund',
        fundNone:             '— None —',
        fundSaved:            'Fund saved.',
        // Reassign Zeffy ID wizard
        raZeffyId:            'Zeffy ID',
        raLink:               '⇄ Wrong account? Reassign',
        raTitle:              'Reassign Zeffy ID',
        raStep1:              'What moves',
        raStep2:              'Correct account',
        raStep3:              'Confirm',
        raLoading:            'Loading…',
        raIdEyebrow:          'Zeffy ID that will change account',
        raCurrently:          'Currently linked to ',
        raMovesTogether:      'Everything linked to this Zeffy ID moves together',
        raGifts:              'Gifts',
        raRecurring:          'Recurring donations',
        raTickets:            'Tickets',
        raRefunds:            'Refunds kept as-is',
        raStaysWith:          'Stays with {name} (not touched)',
        raOtherId:            'other Zeffy ID · {n} gifts',
        raManualGifts:        'Gifts entered by hand (no Zeffy ID)',
        raGiftsN:             '{n} gifts',
        raNothingStays:       'Nothing else is linked to this account.',
        raBlocked:            '{n} gift(s) have refund or stewardship records in Salesforce. They stay on {name} and must be moved by hand.',
        raSearchLabel:        'Find the account that should own this Zeffy ID',
        raSearchPh:           'Name or email…',
        raCurrentAccount:     'Current account',
        raNoResults:          'No account found.',
        raFrom:               'From',
        raTo:                 'To',
        raEmail:              'Email',
        raAddress:            'Address',
        raZeffyIds:           'Zeffy IDs',
        raSame:               '✓ same as Zeffy',
        raEmailMatch:         'The email on the Zeffy payment matches this account',
        raAddrMatch:          'The address on the Zeffy payment matches this account',
        raNextChoose:         'Next: choose account',
        raNextReview:         'Next: review',
        raDoBtn:              'Reassign {n} gifts',
        raDoBtnOne:           'Reassign 1 gift',
        raDoBtnNone:          'Reassign',
        raBack:               'Back',
        raWorking:            'Working…',
        raClose:              'Close',
        raSumRebuild:         'Rebuild ',
        raSumGifts:           '{n} gifts ({amt})',
        raSumOn:              ' on ',
        raSumRemoveFrom:      ' and remove them from {name}. Refund status and campaign are carried over.',
        raSumMove:            'Move ',
        raSumRecurring:       '{n} recurring donations',
        raSumTo:              ' to ',
        raSumPoint:           'Point ',
        raSumTickets:         '{n} tickets',
        raSumTicketsPost:     ' to the new account and gifts',
        raSumFuture:          'Send future payments with this Zeffy ID to ',
        raSumKeepIds:         '{name} keeps its other Zeffy IDs ({n})',
        raSumKeepManual:      '{name} keeps its {n} hand-entered gifts',
        raSumFoot:            'Every change goes to the Audit Log (old record → new record).',
        raBgTitle:            'Runs in the background',
        raBgBody:             '{n} gifts are processed in batches of 200. You can close this window; the move keeps going. If a batch fails, that batch is rolled back and nothing is left half-moved.',
        raAckPre:             'I checked that ',
        raAckPost:            ' is the right person for this Zeffy ID.',
        raMoving:             'Moving gifts…',
        raProgress:           '{done} of {total} tickets moved',
        raDoneTitle:          'Zeffy ID reassigned',
        raDoneBody:           '{g} gifts, {r} recurring donations and {t} tickets now belong to {name}.',
        raAuditLog:           'Audit Log',
        raColAction:          'Action',
        raColRecord:          'Record',
        raColOld:             'Old',
        raColNew:             'New',
        raColBy:              'By',
        raMoreRows:           '… {n} more rows',
        raFailed:             'A batch failed and was rolled back; nothing of that batch moved. Open Reassign again to continue.',
        raToastDone:          'Zeffy ID reassigned',
    },
    fr: {
        // Settings
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
        credWebhookUrl:       'URL du webhook',
        credWebhookUrlHint:   'Collez ici l\'URL Site Salesforce de votre webhook (utilisée par le bouton Test dans Système → Santé).',
        credInfo:             'Où trouver ces valeurs',
        credInfoLine1:        'Connectez-vous à Zeffy → Paramètres → Intégrations → API',
        credInfoLine2:        'Le secret webhook s\'affiche à la création d\'un nouveau point de terminaison',
        credHint:             'Les valeurs actuelles sont masquées. Saisissez une nouvelle valeur pour remplacer — laisser vide pour conserver.',
        testWebhookTitle:     'Test Webhook',
        testWebhookOpen:      'Test Webhook',
        testWebhookDesc:      'Envoie un payload signé à votre endpoint Site Salesforce, simulant un vrai événement Zeffy.',
        testWebhookEvent:     'Type d\'événement',
        testWebhookSend:      'Envoyer le test',
        testWebhookSending:   'Envoi…',
        testWebhookOk:        'Webhook reçu et traité.',
        testWebhookFail:      'Échec du webhook.',
        testWebhookTxId:      'ID de transaction',
        testLogBadge:         'TEST',
        healthDupBadge:       'DOUBLON',
        saveBtn:              'Enregistrer',
        savingBtn:            'Enregistrement...',
        savedToast:           'Paramètres enregistrés',
        savedCredsToast:      'Identifiants Zeffy mis à jour.',
        savedAppToast:        'Paramètres d\'automatisation enregistrés.',
        mon: 'Lundi', tue: 'Mardi', wed: 'Mercredi', thu: 'Jeudi', fri: 'Vendredi',
        freqWeekly: 'Hebdomadaire', freqMonthly: 'Mensuel',
        lapsedFrequencyLabel: 'Fréquence',
        navImport:            'Importation CSV',
        navCampaigns:         'Association campagnes',
        importDesc:           'Téléversez un fichier CSV pour créer en masse des billets En attente à partir de dons Zeffy historiques. Maximum 500 lignes par lot — les gros fichiers sont divisés automatiquement. Les ID de transaction en double sont ignorés.',
        btnDownloadTemplate:  'Télécharger le modèle CSV',
        importClickToSelect:  'Cliquer pour sélectionner un fichier CSV',
        importRowsWord:       'lignes',
        importingProgress:    'importés…',
        ticketsCreated:       'billets créés',
        duplicatesSkipped:    'doublons ignorés',
        errorsCount:          'erreurs',
        btnImportAnother:     'Importer un autre fichier',
        campSearchPlaceholder:'Rechercher une campagne à lier...',
        campZeffyFormId:      'ID formulaire Zeffy',
        campFormIdPlaceholder:'ex: abc123',
        campZeffyManaged:     'Géré par Zeffy (créé automatiquement par le robot)',
        colZeffyFormId:       'ID formulaire Zeffy',
        colType:              'Type',
        noCampaigns:          'Aucune campagne liée à Zeffy pour l\'instant.',
        campHint:             'Liez les campagnes Salesforce existantes aux ID de formulaire Zeffy. Les campagnes marquées Géré par Zeffy ont été créées automatiquement par le robot.',
        btnImport:            'Importer',
        btnClose:             'Fermer',
        // Left panel
        searchPlaceholder:    'Chercher nom, courriel, billet #...',
        ticketsWord:          'billets',
        ofWord:               'de',
        pageJumpHint:         'Cliquer pour aller à la page',
        pagePrev:             'Page précédente',
        pageNext:             'Page suivante',
        noTickets:            'Aucun billet trouvé.',
        collapse:             '▲ Réduire',
        showMore:             '▼ Voir {n} {w} de plus',
        // Tab bar
        tabDashboard:         'Tableau de bord',
        tabHistory:           'Historique des dons',
        tabAudit:             'Journal d\'audit',
        tabLogs:              'Journaux',
        tabMyTasks:           'Mes tâches',
        // Dashboard
        dashEyebrow:          'Tableau de bord',
        dashOverview:         'Aperçu',
        dashTilesHint:        'Cliquez sur une tuile pour filtrer la liste.',
        dashAutoMatch:        'Taux d\'appariement auto.',
        dashAutoMatchSub:     '{0} sur {1} résolus par le robot',
        dashMonthTotal:       'Traité en',
        srcRobot:             'Robot',
        srcStaff:             'Personnel',
        colOn:                'Le',
        colBy:                'Par',
        statTotal:            'Total des billets',
        statPending:          'En attente',
        statResolved:         'Résolus',
        statErrors:           'Erreurs',
        statDelayed:          'Retardés',
        statClosed:           'Fermés',
        statAutoMatched:      'Appariés auto.',
        statMatchRate:        'Taux d\'appariement',
        statTotalProcessed:   'Total traité mensuel',
        monthNames:           ['janv.','févr.','mars','avr.','mai','juin','juil.','août','sept.','oct.','nov.','déc.'],
        chartWeekly:          'Billets par semaine',
        wkCreated:            'Reçus',
        wkClosed:             'Fermés',
        wkThisWeek:           'Cette semaine',
        wkLastWeek:           '{0} la sem. passée',
        wkStillOpen:          'Encore ouverts',
        dashTopCampaigns:     'Meilleures campagnes',
        colCampaign:          'Campagne',
        colDonations:         'Dons',
        colTotal:             'Total',
        dashRecentRes:        'Résolutions récentes',
        colTicket:            'Billet #',
        colDonor:             'Donateur',
        colAmount:            'Montant',
        colStatus:            'Statut',
        colResolvedOn:        'Résolu le',
        colResolvedBy:        'Résolu par',
        noRecentRes:          'Aucune résolution récente.',
        // Donation history
        histTitle:            'Historique des dons',
        histSub:              'Tous les dons traités par le robot — auto et manuels',
        histSearch:           'Chercher par nom, téléphone, billet # ou ID transaction...',
        colSource:            'Source',
        colGiftNum:           'Don #',
        colDate:              'Date',
        colPayment:           'Paiement',
        colZeffyTx:           'ID TX Zeffy',
        noDonations:          'Aucun don trouvé.',
        pagPrev:              '‹ Préc.',
        pagNext:              'Suiv. ›',
        // My Tasks
        myTasksTitle:         'Mes tâches',
        myTasksSub:           'Tâches Zeffy Connect ouvertes assignées à vous',
        due:                  'Échéance',
        allCaughtUp:          'Tout est à jour!',
        noTasks:              'Vous n\'avez aucune tâche Zeffy Connect ouverte.',
        // Ticket detail — section titles
        secDonorDetails:      'Infos du donateur',
        chipPayment:          'Paiement : {0}',
        showAllDetails:       'Voir tous les détails',
        hideAllDetails:       'Masquer les détails',
        secDonorInfo:         'Informations du donateur',
        secGiftDetails:       'Détails du don',
        secCardDetails:       'Détails de la carte',
        secFund:              'Fonds',
        secCampaign:          'Campagne',
        secTribute:           'Hommage',
        secDispute:           'Litige',
        secRefund:            'Remboursement',
        secDiscount:          'Rabais',
        secBuyerQuestions:    'Questions de l\'acheteur',
        secZeffyNotes:        'Notes Zeffy',
        // Ticket detail — field labels
        fldFirstName:         'Prénom',
        fldLastName:          'Nom de famille',
        fldCompany:           'Compagnie / Église',
        fldEmail:             'Courriel',
        fldPhone:             'Téléphone',
        fldContactPerson:     'Personne-ressource',
        fldCampaign:          'Campagne',
        cardOrg:              'Org. :',
        cardDonor:            'Donateur :',
        cardContact:          'Contact :',
        fldOrigin:            'Origine dans Zeffy',
        originOnline:         'En ligne',
        originOnlineHint:     'formulaire Zeffy',
        originManual:         'Manuelle',
        originManualHint:     'saisie par le personnel dans Zeffy',
        originImported:       'Importée',
        originImportedHint:   'importée dans Zeffy',
        fldLanguage:          'Langue',
        fldAddress:           'Adresse',
        fldCity:              'Ville',
        fldProvince:          'Province',
        fldPostalCode:        'Code postal',
        fldCountry:           'Pays',
        fldZeffyContactId:    'ID Contact Zeffy',
        fldAmount:            'Montant',
        fldEligibleAmount:    'Montant admissible',
        fldPaymentMethod:     'Mode de paiement',
        fldGiftDate:          'Date du don',
        fldFormName:          'Nom du formulaire',
        fldIsRecurring:       'Récurrent',
        fldTransactionId:     'ID de transaction',
        fldZeffyReceipt:      'Reçu Zeffy',
        viewReceipt:          'Voir le reçu ↗',
        fldTxStatus:          'Statut du paiement',
        txPending:            'En attente',
        txSucceeded:          'Réussi',
        txFailed:             'Échoué',
        txDeleted:            'Supprimé',
        txRefunded:           'Remboursé',
        fldCardBrand:         'Marque de carte',
        fldLast4:             '4 derniers chiffres',
        fldFundName:          'Nom du fonds',
        fldFundCode:          'Code du fonds',
        fldFundId:            'ID du fonds',
        fldCategory:          'Catégorie',
        fldCorporateDonor:    'Donateur corporatif',
        fldTributeType:       'Type d\'hommage',
        fldInHonourOf:        'En l\'honneur de',
        fldStatus:            'Statut',
        fldReason:            'Raison',
        fldCode:              'Code',
        fldNote:              'Note',
        fldAnnotation:        'Annotation',
        fldCurrency:          'Devise',
        fldPaymentType:       'Type de paiement',
        fldSubscriptionFreq:  'Fréquence d\'abonnement',
        fldReceiptNumber:     'Numéro de reçu',
        fldLinkedAccount:     'Compte lié',
        fldResolvedOn:        'Résolu le',
        fldResolvedBy:        'Résolu par',
        fldName:              'Nom',
        fldDate:              'Date',
        fldForm:              'Formulaire',
        fldRecurring:         'Récurrent',
        fldPayment:           'Paiement',
        yes:                  'Oui',
        no:                   'Non',
        // Action buttons
        btnException:         'Exception',
        btnViewMatches:       'Réviser et associer le donateur',
        btnFollowup:          'Assignation de suivi',
        btnCancel:            'Annuler',
        btnBack:              'Retour',
        btnContinue:          'Continuer',
        btnAssign:            'Assigner',
        btnRemoveAssign:      'Retirer l\'assignation',
        btnLink:              'Lier et enregistrer le don',
        btnCreateDonation:    'Créer et enregistrer le don',
        btnCreate:            'Nouveau',
        btnYesUndo:           'Oui, annuler',
        btnUndoResolution:    'Annuler la résolution',
        // Exception modal
        excTitle:             'Exception',
        excSub:               'Comment souhaitez-vous traiter ce billet?',
        excCloseCard:         'Fermer',
        excCloseDesc:         'Le billet est fermé — le don ne sera pas traité.',
        excKeepPending:       'Laisser en attente',
        excKeepPendingDesc:   'Laisser en attente de révision — ajouter une note pour le prochain réviseur.',
        excNoteLabel:         'Note / Raison (optionnel)',
        excSkipLabel:         'Ignorer le billet',
        excCloseLabel:        'Fermer le billet',
        excKeepLabel:         'Laisser en attente',
        // Undo modal
        undoTitle:            'Annuler la résolution',
        undoBody:             'Cela supprimera la GiftTransaction, l\'engagement récurrent (si aucun autre versement ne l\'utilise) et la campagne Zeffy créée par cette résolution (si rien d\'autre ne l\'utilise), puis rouvrira le billet à En attente de révision. Le compte lié ne sera PAS supprimé. Cette action est enregistrée dans le journal d\'audit. Continuer?',
        // Follow-up assignment modal
        assignTitle:          'Assignation de suivi',
        assignBody:           'Assignez ce billet à une personne spécifique pour un suivi. Ceci remplace la tâche automatique globale.',
        assignSearch:         'Rechercher utilisateur ou file...',
        assignDueDays:        'Échéance (jours)',
        assignNote:           'Note (optionnel)',
        // Wizard
        wizTitle:             'Réviser et associer le donateur',
        wizStep1:             'Sélectionner un compte',
        wizStep2:             'Réviser et confirmer',
        wizHint:              'Ce donateur existe-t-il déjà dans Salesforce ?',
        wizModeLink:          'Compte existant',
        wizModeLinkDesc:      'Relier ce don à un donateur déjà dans Salesforce',
        wizModeCreate:        'Nouveau compte',
        wizModeCreateDesc:    'Créer un nouveau donateur à partir des données Zeffy',
        wizCreateTypeTitle:   'Quel type de compte ?',
        wizPossibleMatches:   'Correspondances possibles pour :',
        wizCheckDetails:      'Vérifier les détails',
        wizNoMatches:         'Aucune correspondance automatique trouvée.',
        wizSearchSF:          'Rechercher un compte Salesforce',
        wizSearchPlaceholder: 'Nom ou courriel...',
        wizOrCreate:          'ou créer un nouveau compte',
        wizIndividual:        'Individuel',
        wizChurch:            'Église',
        wizOrg:               'Organisation',
        wizBusiness:          'Entreprise',
        colZeffyIncoming:     'Zeffy (entrant)',
        colSFCurrent:         'Salesforce (actuel)',
        colUpdate:            'Mettre à jour',
        cmpDiffers:           'Différent',
        wizNoZeffyId:         'Pas encore d\'ID Zeffy — ce sera le premier',
        wizTargetField:       'Champ cible',
        wizSelectField:       '— Sélectionner un champ —',
        wizNoEmailFields:     'Aucun champ de type courriel trouvé sur le compte.',
        wizEditHint:          'Cliquez sur le crayon pour corriger une valeur Zeffy. Cochez Mettre à jour pour l’enregistrer dans le compte. Le billet garde ce que Zeffy a envoyé.',
        wizEditValue:         'Corriger cette valeur',
        wizDiscardEdit:       'Annuler la correction',
        wizEditNeedsUpdate:   'Cochez Mettre à jour pour enregistrer cette correction dans le compte.',
        rvFromZeffy:          'De Zeffy',
        rvSfAccount:          'Compte Salesforce',
        rvIdFirst:            'Premier ID Zeffy',
        rvIdNth:              'ID Zeffy n° {n}',
        rvIdsOnAccount:       'ID Zeffy déjà sur ce compte : {ids}',
        rvEmails:             'Courriels',
        rvAddrBilling:        'Facturation',
        rvEmpty:              'vide',
        rvTagSame:            'IDENTIQUE',
        rvSameLocked:         'Déjà enregistré ici. Pour enregistrer un autre courriel, modifiez-le avec le crayon.',
        rvSameLockedAddr:     'Le compte a déjà cette adresse. Pour en enregistrer une autre, modifiez-la avec le crayon.',
        rvTagAdd:             'AJOUT',
        rvTagReplace:         'REMPLACE',
        rvNotOnAccount:       'Pas sur ce compte',
        rvAlreadyOnAccount:   'Déjà sur le compte',
        rvNameKept:           'Différent — le compte garde son nom',
        rvPickSlot:           'Choisissez un emplacement à droite pour l’enregistrer.',
        rvWillReplace:        'Remplacera le champ {field}.',
        rvWillAdd:            'Sera ajouté comme {field}.',
        rvClickToReplace:     'Cliquez sur l’emplacement à droite pour le remplacer.',
        rvWillReplaceShort:   'Remplacera la valeur du compte.',
        rvClickAgain:         'Cliquez de nouveau pour ne rien changer.',
        rvConfirmTitle:       'À la confirmation',
        rvSumRecord:          'Enregistrer ',
        rvSumOn:              ' sur ',
        rvSumEmailAdd:        'Ajouter ',
        rvSumEmailReplace:    'Remplacer {field} par ',
        rvSumAs:              ' comme ',
        rvSumEmailsSame:      'Les courriels restent tels quels',
        rvSumAddrReplace:     'Remplacer l’adresse de facturation par ',
        rvSumAddrSame:        'L’adresse reste telle quelle',
        rvSumFoot:            'Le billet Zeffy garde exactement ce que Zeffy a envoyé. Chaque changement va dans le journal d’audit (avant → après).',
        rvAddNote:            '+ Ajouter une note pour l’historique',
        rvLinkRecord:         'Lier et enregistrer {amount}',
        wizCreateEditHint:    'Les corrections sont enregistrées dans le nouveau compte. Le billet garde ce que Zeffy a envoyé.',
        wizAccountName:       'Nom du compte',
        wizStreet:            'Rue',
        wizInvalidEmail:      'Entrez une adresse courriel valide.',
        wizResolutionNotes:   'Notes de résolution (optionnel)',
        wizCreateDesc:        'Un nouveau compte Salesforce sera créé en utilisant les informations du donateur Zeffy ci-dessous, et le don sera enregistré.',
        wizDonorSection:      'Donateur',
        wizDonationSection:   'Don Zeffy',
        // Audit log
        auditTitle:           'Journal d\'audit',
        auditSub:             'Historique complet des résolutions, créations et annulations',
        auditSearch:          'Chercher par billet #, nom, courriel, téléphone, journal #, effectué par...',
        colAction:            'Action',
        colLogNum:            'Journal #',
        colAccount:           'Compte',
        colPerformedBy:       'Effectué par',
        colDateTime:          'Date et heure',
        colNotes:             'Notes',
        noAuditLog:           'Aucune entrée dans le journal d\'audit.',
        // Status filter options
        statusOpen:           'Ouvert (sauf résolu)',
        statusAll:            'Tous les statuts',
        statusPending:        'En attente de révision',
        statusLinked:         'Résolu - Lié',
        statusNewContact:     'Résolu - Nouveau contact',
        statusDelayed:        'Retardé',
        statusAssigned:       'Assignés',
        statusClosed:         'Fermé',
        statusError:          'Erreur',
        statusSkipped:        'Ignoré',
        statusAuto:           'Traité automatiquement (robot)',
        stageWaiting:         'Retenu · Paiement échoué',
        stageResolved:        'Résolus par le personnel (Lié · Nouveau contact)',
        stageRobot:           'Résolus par le robot (traités automatiquement)',
        stageAddress:         'Mises à jour',
        stageAssigned:        'Assignés à quelqu\'un',
        stageClosed:          'Fermés (Fermé · Erreur)',
        cardFilterHint:       'Afficher ces billets dans la liste',
        statusAddrDiffers:    '📍 Adresse différente',
        tooltipAuto:          'Le robot a reconnu le donateur par son ID Zeffy et a enregistré le don lui-même. Vous pouvez l’ouvrir, le vérifier et l’annuler.',
        resolvedByRobot:      'Robot Zeffy Connect',
        chipAddrDiffers:      '📍 Adresse différente',
        addrDiffTitle:        'L’adresse Zeffy est différente de celle du compte',
        addrDiffBody:         'Le donateur a saisi cette adresse dans Zeffy (en général celle du reçu). Mettez le compte à jour si l’adresse Zeffy est l’adresse actuelle.',
        addrZeffy:            'Zeffy (donateur)',
        addrSalesforce:       'Salesforce (facturation du compte)',
        addrEmpty:            '(aucune adresse)',
        btnUpdateAddress:     'Mettre à jour l’adresse',
        addrUpdatedTitle:     'Adresse mise à jour',
        addrUpdatedBody:      'Le compte a maintenant l’adresse Zeffy.',
        keptPendingTitle:     'Billet laissé en attente de révision',
        fldClosedOn:          'Fermé le',
        btnReopen:            'Rouvrir le billet',
        loading:              'Chargement',
        ticketWord:           'billet',
        dupWarnTitle:         'Doublon possible',
        dupWarnBody:          '{0} existe déjà dans Salesforce avec une correspondance de {1} %. Reliez le don à ce compte, sauf si vous êtes certain qu\'il s\'agit d\'un autre donateur.',
        dupWarnUse:           'Utiliser {0}',
        reviewerNotes:        'Notes pour le réviseur',
        noteSavedTitle:       'Note enregistrée',
        noteSavedBody:        'Le billet reste en attente de révision.',
        undoneTitle:          'Résolution annulée',
        statusHolding:        'En attente',
        statusPaymentFailed:  'Paiement échoué',
        tooltipPaymentFailed: 'Zeffy a signalé le paiement comme échoué ou supprimé.',
        chipDispute:          'Litige',
        chipRefund:           'Remboursement',
        btnMoveToReview:      'Passer en révision',
        btnCloseTicket:       'Fermer le billet',
        moveReviewToast:      'Billet passé en révision',
        btnReturnHolding:     'Remettre en attente',
        btnReturnDelayed:     'Remettre en retardé',
        returnWaitingToast:   'Billet remis en {0}',
        closeConfirmTitle:    'Fermer ce billet ?',
        closeConfirmBody:     'Le billet sera fermé sans créer de don. Vous pouvez ajouter une note pour le journal d\'audit.',
        closeConfirmNote:     'Note (facultative)',
        closedToast:          'Billet fermé',
        bulkAccountsCreated:  '{n} compte(s) créé(s) ou réutilisé(s).',
        btnReprocess:         'Retraiter',
        amtReviewChip:        'Montant modifié',
        amtReviewTitle:       'Zeffy indique un autre montant',
        amtReviewBody:        'Zeffy indique maintenant {new} pour ce paiement; Salesforce a {old}. Rien n’a été modifié automatiquement — vérifiez, modifiez la GiftTransaction à la main au besoin, puis marquez-le comme vérifié.',
        btnAmtReviewed:       'Marquer comme vérifié',
        amtReviewedToast:     'Montant marqué comme vérifié',
        reprocessToast:       'Webhook retraité : {status}',
        reprocessConfirm:     'Relancer ce webhook enregistré dans Zeffy Connect ?',
        tooltipHolding:       'En attente de la confirmation du paiement par Zeffy. Passe seul en révision.',
        tooltipPending:       'En cours de révision active — pas de minuterie d\'expiration. Un membre du personnel traite ce billet.',
        tooltipResolved:      'Le don a été associé et enregistré dans Salesforce.',
        tooltipDelayed:       'Zeffy n\'a jamais confirmé le paiement pendant la période d\'attente.',
        tooltipClosed:        'Billet fermé — le don ne sera pas traité.',
        tooltipError:         'Une erreur s\'est produite lors du traitement de ce billet.',
        tooltipSkipped:       'Le billet a été ignoré lors de la révision.',
        tooltipCountdown:     'Se réinitialise chaque fois que Zeffy envoie une mise à jour pour ce billet.',
        resolveGroupBtn:      'Résoudre {n} billets',
        bulkModalTitle:       'Résoudre le groupe',
        bulkStep1Hint:        'Sélectionnez ou créez un compte — tous les billets y seront liés.',
        bulkStep2Title:       'Confirmer la résolution en lot',
        bulkTicketsLabel:     'Billets à résoudre',
        bulkIdLabel:          'ID Zeffy',
        bulkIdSame:           'identique sur les {n} billets',
        bulkAllMatch:         'nom, courriel et adresse identiques',
        bulkVarShow:          'Voir les différences',
        bulkVarHide:          'Masquer',
        bulkVarNameHdr:       'Nom',
        bulkVarEmailHdr:      'Courriel',
        bulkVarAddrHdr:       'Adresse',
        bulkShowAllMatches:   'Voir toutes les correspondances ({n}) ▾',
        bulkShowFewer:        'Afficher moins ▴',
        bulkVarNoEmail:       '(sans courriel)',
        bulkVarNoAddr:        '(sans adresse)',
        bulkConfirmBtn:       'Résoudre {n} billets',
        bulkProgress:         'Résolution… lot {i} sur {n}',
        bulkNotSent:          '{n} billets n\'ont pas été envoyés — rouvrez le groupe pour les terminer.',
        rvAcctNotUpdated:     'Don enregistré — le compte n\'a pas été mis à jour',
        bulkSuccessToast:     '{n} billets résolus avec succès.',
        bulkPartialToast:     '{resolved} sur {total} billets résolus. {errors} erreurs.',
        bgTicketsAmt:         '{n} billets ({amount})',
        bgTicketsCount:       '{n} billets',
        bgSeeAmounts:         'Voir les montants ▾',
        bgHideAmounts:        'Masquer ▴',
        bgLinkBtn:            'Lier et enregistrer {n} billets',
        bgPickEmail:          'Choisissez un courriel ici, puis cliquez sur un emplacement à droite pour l’enregistrer.',
        bgPickAddr:           'Choisissez quelle adresse envoyée par Zeffy est la bonne.',
        bgRecent:             'la plus récente',
        bgAssignedTo:         '→ {field}',
        bgNewAccount:         'Nouveau compte',
        bgAllEmailsOn:        'Tous déjà sur le compte',
        holdingDaysLeft:      '{0} jours restants',
        holdingExpiresToday:  'Expire aujourd\'hui',
        // Nav group headers
        navGroupGeneral:      'Général',
        navGroupAutomation:   'Automatisation',
        navGroupAdmin:        'Administration',
        navGroupZeffy:        'Intégration Zeffy',
        navGroupData:         'Données',
        navGroupSystem:       'Système',
        navCreds:             'Connexion Zeffy',
        navTicketActions:     'Actions du billet',
        ticketActionsTitle:   'Actions du billet',
        ticketActionsDesc:    'Choisissez les actions optionnelles affichées au bas de chaque billet.',
        showFollowupLabel:    'Afficher le bouton « Assignation de suivi »',
        showFollowupHint:     'Désactivé, le bouton est masqué pour tous. Les billets qui ont déjà une personne assignée au suivi continuent de l’afficher.',
        savedTicketActionsToast: 'Actions du billet mises à jour.',
        // Robot Health
        navHealth:            'Santé du robot',
        healthTitle:          'Santé du robot',
        healthSub:            'Surveiller les appels webhook et diagnostiquer les problèmes',
        healthActive:         'Connexion active — le robot fonctionne',
        healthInactive:       'Connexion inactive (suspendue dans Identifiants)',
        healthLastReceived:   'Dernier webhook reçu',
        healthNever:          'Jamais',
        healthLast24h:        'Dernières 24 heures',
        healthLast7d:         'Derniers 7 jours',
        healthCalls:          'Appels totaux',
        healthSuccess:        'Réussis',
        healthErrors:         'Erreurs',
        healthLogTitle:       'Journal webhook',
        healthSearchHolder:   'Chercher ID TX, donateur, message...',
        healthFilterAll:      'Tous les statuts',
        healthColDate:        'Date',
        healthColStatus:      'Statut',
        healthColTxId:        'ID TX',
        healthColDonor:       'Donateur',
        healthColAmount:      'Montant',
        healthColMessage:     'Message',
        healthNoLogs:         'Aucun journal webhook trouvé.',
        healthLoadMore:       'Charger plus',
        healthDetail:         'Détail technique',
        healthRefresh:        'Actualiser',
        healthToday:          'Aujourd\'hui',
        healthGapTitle:       'Pas de contact depuis',
        healthGapCopy:        'Copier la date pour l\'export CSV Zeffy',
        healthErrChip:        'Erreurs',
        healthDupChip:        'Doublons',
        healthRateChip:       'Succès',
        // Traitement des événements
        navEvents:            'Traitement des événements',
        eventsTitle:          'Traitement des événements',
        eventsDesc:           'Contrôlez quels événements Zeffy le robot traite automatiquement.',
        evtCompletedLabel:    'payment.completed — Créer billet ou GiftTransaction',
        evtCompletedAlwaysOn: 'Toujours actif',
        evtCreatedLabel:      'payment.created — Créer billet En attente (visibilité entonnoir)',
        evtCreatedHint:       'Crée un billet En attente quand un formulaire est soumis, avant confirmation du paiement. Utile pour suivre les abandons et rejets bancaires.',
        evtUpdatedLabel:      'payment.updated — Mettre à jour billet / GiftTransaction',
        evtUpdatedHint:       'Met à jour les champs existants quand Zeffy envoie des modifications (ex: URL du reçu, statut remboursement). Fait aussi passer les billets En attente à En révision quand le paiement est confirmé.',
        evtDeletedLabel:      'payment.deleted — Marquer billet comme Paiement échoué',
        evtDeletedHint:       'Marque les billets existants comme Paiement échoué quand Zeffy supprime le paiement.',
        evtContactLabel:      'contact.* — Recevoir les événements contacts Zeffy (révision manuelle)',
        evtContactHint:       'Enregistre les événements contact.created / contact.updated / contact.deleted. Le robot ne met jamais à jour les comptes automatiquement — le personnel révise toujours manuellement.',
        evtHoldingExpireLabel: 'Expiration automatique billets HOLDING → Retardé',
        expireOffTitle:        'L’expiration automatique des billets HOLDING est désactivée.',
        expireOffMsg:          'Désactivée depuis {0} ({1}). Les billets HOLDING ne passent plus à Retardé.',
        expireOffBtn:          'Réactiver',
        expireOffOnToast:      'L’expiration automatique des billets HOLDING est réactivée.',
        evtHoldingExpireHint:  'Déplace automatiquement les billets HOLDING vers Retardé après le nombre de jours configuré depuis la création du billet.',
        evtHoldingExpireDaysLabel: 'Fenêtre d\'expiration (jours)',
        savedEventsToast:     'Paramètres de traitement des événements enregistrés.',
        evtOn:                'Actif',
        evtOff:               'Inactif',
        // Infobulles
        ttRefresh:            'Actualiser',
        ttSettings:           'Paramètres',
        ttClose:              'Fermer',
        ttOlder:              'Plus anciens',
        ttNewer:              'Plus récents',
        ttClearSearch:        'Effacer la recherche',
        ttOpenTicket:         'Ouvrir le billet',
        histUndone:           'Annulé',
        histUndoneTip:        'Résolution annulée le {0} par {1} — le don a été supprimé. Disparaît si le billet est relié de nouveau à ce donateur.',
        ttTimeline:           'Voir la chronologie',
        ttRemove:             'Supprimer',
        // Modal chronologie
        loadingComparison:    'Chargement de la comparaison...',
        timelineTitle:        'Chronologie de la transaction',
        timelineLoading:      'Chargement…',
        timelineEmpty:        'Aucune entrée de chronologie pour cette transaction.',
        wizFund:              'Fonds',
        // Fonds
        navFunds:             'Fonds',
        fundsTitle:           'Gestion des fonds',
        fundsDesc:            'Créez des fonds et assignez les campagnes Zeffy à chacun. Une campagne ne peut appartenir qu\'à un seul fonds. Quand un don arrive, le robot remplit automatiquement le fonds selon le mappage des campagnes.',
        fundsUnassigned:      'Non assignées',
        fundsNewFund:         'Nouveau fonds',
        fundNamePlaceholder:  'Nom du fonds',
        fundDescPlaceholder:  'Description (optionnelle)',
        fundCreate:           'Créer',
        fundCancel:           'Annuler',
        fundCreated:          'Fonds créé.',
        fundAssigned:         'Campagne assignée.',
        fundNoFunds:          'Aucun fonds. Créez-en un pour commencer.',
        fundNoCampaigns:      'Aucune campagne dans ce fonds.',
        fundUnassignedEmpty:  'Toutes les campagnes sont assignées à un fonds.',
        moveTo:               'Déplacer vers',
        fldFund:              'Fonds',
        fundNone:             '— Aucun —',
        fundSaved:            'Fonds enregistré.',
        // Assistant Réassigner le Zeffy ID
        raZeffyId:            'Zeffy ID',
        raLink:               '⇄ Mauvais compte ? Réassigner',
        raTitle:              'Réassigner le Zeffy ID',
        raStep1:              'Ce qui est déplacé',
        raStep2:              'Bon compte',
        raStep3:              'Confirmer',
        raLoading:            'Chargement…',
        raIdEyebrow:          'Zeffy ID qui change de compte',
        raCurrently:          'Actuellement relié à ',
        raMovesTogether:      'Tout ce qui est lié à ce Zeffy ID est déplacé ensemble',
        raGifts:              'Dons',
        raRecurring:          'Dons récurrents',
        raTickets:            'Billets',
        raRefunds:            'Remboursements conservés',
        raStaysWith:          'Reste avec {name} (non modifié)',
        raOtherId:            'autre Zeffy ID · {n} dons',
        raManualGifts:        'Dons saisis à la main (sans Zeffy ID)',
        raGiftsN:             '{n} dons',
        raNothingStays:       'Rien d’autre n’est lié à ce compte.',
        raBlocked:            '{n} don(s) ont des remboursements ou un suivi dans Salesforce. Ils restent sur {name} et doivent être déplacés à la main.',
        raSearchLabel:        'Trouvez le compte à qui appartient ce Zeffy ID',
        raSearchPh:           'Nom ou courriel…',
        raCurrentAccount:     'Compte actuel',
        raNoResults:          'Aucun compte trouvé.',
        raFrom:               'De',
        raTo:                 'À',
        raEmail:              'Courriel',
        raAddress:            'Adresse',
        raZeffyIds:           'Zeffy IDs',
        raSame:               '✓ identique à Zeffy',
        raEmailMatch:         'Le courriel du paiement Zeffy correspond à ce compte',
        raAddrMatch:          'L’adresse du paiement Zeffy correspond à ce compte',
        raNextChoose:         'Suivant : choisir le compte',
        raNextReview:         'Suivant : vérifier',
        raDoBtn:              'Réassigner {n} dons',
        raDoBtnOne:           'Réassigner 1 don',
        raDoBtnNone:          'Réassigner',
        raBack:               'Retour',
        raWorking:            'En cours…',
        raClose:              'Fermer',
        raSumRebuild:         'Recréer ',
        raSumGifts:           '{n} dons ({amt})',
        raSumOn:              ' sur ',
        raSumRemoveFrom:      ' et les retirer de {name}. Le statut de remboursement et la campagne sont conservés.',
        raSumMove:            'Déplacer ',
        raSumRecurring:       '{n} dons récurrents',
        raSumTo:              ' vers ',
        raSumPoint:           'Relier ',
        raSumTickets:         '{n} billets',
        raSumTicketsPost:     ' au nouveau compte et aux nouveaux dons',
        raSumFuture:          'Envoyer les futurs paiements de ce Zeffy ID à ',
        raSumKeepIds:         '{name} garde ses autres Zeffy IDs ({n})',
        raSumKeepManual:      '{name} garde ses {n} dons saisis à la main',
        raSumFoot:            'Chaque changement est inscrit au journal d’audit (ancien → nouveau).',
        raBgTitle:            'S’exécute en arrière-plan',
        raBgBody:             '{n} dons sont traités par lots de 200. Vous pouvez fermer cette fenêtre; le déplacement continue. Si un lot échoue, il est annulé et rien ne reste à moitié déplacé.',
        raAckPre:             'J’ai vérifié que ',
        raAckPost:            ' est la bonne personne pour ce Zeffy ID.',
        raMoving:             'Déplacement des dons…',
        raProgress:           '{done} sur {total} billets déplacés',
        raDoneTitle:          'Zeffy ID réassigné',
        raDoneBody:           '{g} dons, {r} dons récurrents et {t} billets appartiennent maintenant à {name}.',
        raAuditLog:           'Journal d’audit',
        raColAction:          'Action',
        raColRecord:          'Enregistrement',
        raColOld:             'Ancien',
        raColNew:             'Nouveau',
        raColBy:              'Par',
        raMoreRows:           '… {n} autres lignes',
        raFailed:             'Un lot a échoué et a été annulé; rien de ce lot n’a été déplacé. Ouvrez Réassigner de nouveau pour continuer.',
        raToastDone:          'Zeffy ID réassigné',
    },
};


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

const TOAST_FR = {
    'Error': 'Erreur',
    'Success': 'Succès',
    'Saved': 'Enregistré',
    'Error loading comparison': 'Erreur de chargement de la comparaison',
    'Error loading tasks': 'Erreur de chargement des tâches',
    'Error loading tickets': 'Erreur de chargement des billets',
    'Error loading ticket': 'Erreur de chargement du billet',
    'Error saving settings': 'Erreur lors de l\'enregistrement des paramètres',
    'CSV Error': 'Erreur CSV',
    'Donor linked and donation recorded.': 'Donateur relié et don enregistré.',
    'Account created and donation recorded.': 'Compte créé et don enregistré.',
    'Ticket closed': 'Billet fermé',
    'Assignment removed': 'Assignation retirée',
    'The personal follow-up assignment was cleared.': 'L\'assignation de suivi personnel a été retirée.',
    'Task assigned': 'Tâche assignée',
    'Campaign mapping updated': 'Correspondance de campagne mise à jour',
};

// Audit actions whose notes list one Account change per line
const ACCOUNT_LOG_ACTIONS = new Set(['Account Updated', 'Account Created', 'Address Updated', 'Manual Payment Deleted']);

// Pencil rows → edit keys and the preview value each one restores when the correction is discarded
const EDIT_GROUPS = {
    email:     { email: 'ticketEmail' },
    firstName: { firstName: 'ticketFirstName' },
    lastName:  { lastName: 'ticketLastName' },
    address:   { street: 'ticketStreet', city: 'ticketCity', province: 'ticketProvince',
                 postalCode: 'ticketPostalCode', country: 'ticketCountry' }
};

// Zeffy's name vs the account's (person: first + last, otherwise Account.Name), ignoring case and accents
const _normName = v => (v || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/\s+/g, ' ').trim().toLowerCase();
function _nameDiffers(zeffyName, p) {
    const acct = [p.accountFirstName, p.accountLastName].filter(Boolean).join(' ') || p.accountName;
    return !!_normName(zeffyName) && _normName(zeffyName) !== _normName(acct);
}

export default class ZeffyConnectReviewManager extends LightningElement {

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
    @track chartPage = 0;       // 0 = most recent 8 weeks; 1 = previous 8 weeks; etc.
    _duplicateContactIds = new Set();
    _expandedDupGroups   = new Set(); // Zeffy_Contact_Id__c values with expanded card groups
    @track myTasks          = [];
    @track isMyTasksLoading = false;
    @track activeMainTab    = 'list';  // 'list' | 'mytasks' | 'dashboard'

    // ── Campaign mapping state ─────────────────────────────────────────────────
    @track campaignMappings         = [];
    @track isLoadingCampaigns       = false;
    @track campaignSearchTerm       = '';
    @track campaignSearchResults    = [];
    @track editingMapping           = null;  // {id, name, formId, isZeffyManaged}
    _campaignSearchTimer            = null;

    // ── Audit log state ────────────────────────────────────────────────────────
    @track auditLog = [];
    @track isLoadingAudit = false;
    @track auditSearchTerm = '';
    @track auditPage = 1;
    _auditSearchTimer = null;

    // ── Donation history state ─────────────────────────────────────────────────
    @track donationHistory = [];
    @track isLoadingHistory = false;
    @track historySearchTerm = '';
    @track historyPage = 1;
    _historySearchTimer = null;

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
    _previewSeq = 0; // latest getLinkPreview request
    @track preview            = null;
    @track isLoadingPreview   = false;
    @track accountSearch          = '';
    @track accountSearchResults   = [];
    @track emailTargetField       = '';
    @track emailFieldOptions      = [];
    @track updateEmailEnabled     = false;
    @track updateAddressEnabled   = false;
    // Pencil per row: correcting a Zeffy value is separate from Update (write it to the Account)
    @track editing = {};
    // Create mode: pencil on the Donor section corrects the values the new Account is built from
    @track createEditing = false;
    @track createEdit    = {};
    // Values the reviewer may correct before they are written to the Account (prefilled from the ticket)
    @track edit = {};
    // Notes box on the link step stays closed until the reviewer asks for it
    @track rvNotesOpen = false;

    // ── Auto-match candidates ──────────────────────────────────────────────────
    @track matchCandidates    = [];
    @track isLoadingMatches   = false;

    // ── Create New (inside wizard) ─────────────────────────────────────────────
    @track donorTypeForNew    = 'individual';

    // ── Exception modal ────────────────────────────────────────────────────────
    @track showExceptionModal = false;
    @track exceptionType      = 'pending';  // 'close' | 'pending' (legacy 'skip' behaves like close)
    @track showCloseConfirm   = false;
    closeConfirmNotes         = '';

    // ── Follow-up Assignment modal ─────────────────────────────────────────────
    @track showAssignModal    = false;

    // ── Undo state ─────────────────────────────────────────────────────────────
    @track showUndoConfirm = false;
    // Reassign Zeffy ID wizard
    @track raOpen = false;
    @track raStep = 1;
    @track raPreview = null;
    @track raResults = [];
    @track raChosen = null;
    @track raLogs = [];
    raSearchTerm = '';
    raSearching = false;
    raAck = false;
    raRunning = false;
    raDone = false;
    raError = null;
    raRemaining = null;
    raLogCount = 0;
    _raStartedAt = null;
    _raFromAccountId = null;
    _raPollTimer = null;
    _raSearchTimer = null;
    isMarkingAmountReviewed = false;
    showAllDetails = false;   // full detail sections collapsed by default; blue card always visible

    get detailsToggleLabel()  { return this.showAllDetails ? this.lbl.hideAllDetails : this.lbl.showAllDetails; }
    get detailsChevronClass() { return this.showAllDetails ? 'details-toggle__chev details-toggle__chev--open' : 'details-toggle__chev'; }
    get detailsAriaExpanded() { return this.showAllDetails ? 'true' : 'false'; }
    handleToggleAllDetails()  { this.showAllDetails = !this.showAllDetails; }

    // ── Bulk resolve modal ─────────────────────────────────────────────────────
    @track showBulkModal         = false;
    @track bulkStep              = 1;      // 1 = account selection, 2 = confirm
    @track bulkMode              = 'link'; // 'link' | 'create'
    @track _bulkGroupCid         = null;
    @track _bulkGroupTickets     = [];     // raw ticket objects from this.tickets
    @track _bulkSelectedAcctId   = null;
    @track _bulkSelectedAcctName = '';
    @track _bulkCreateType       = 'individual';
    @track _bulkCandidates       = [];
    _bulkListOpen                = true;
    @track _bulkLoadingCandidates = false;
    @track _bulkNotes            = '';
    @track _bulkVariationsOpen   = false;
    @track _isBulkResolving      = false;
    @track _bulkBatch            = null;   // { i, n } while the group is being sent
    // Group review (step 2, link): same idea as the single-ticket review, for every email/address in the group
    @track _bgPreview            = null;   // getLinkPreview of the head ticket: account values + email fields
    @track _bgLoading            = false;
    @track _bgEmails             = [];     // [{ key, orig, value, count, editing }] distinct group emails
    @track _bgActiveEmail        = null;   // email key picked on the left, waiting for a slot
    @track _bgAssign             = {};     // Account email field API name → email key
    @track _bgAddrs              = [];     // distinct group addresses, most recent flagged
    @track _bgAddrKey            = null;
    @track _bgAddrEditing        = false;
    @track _bgAddrEdit           = {};
    @track _bgUpdateAddress      = false;
    @track _bgShowAmounts        = false;
    @track _bgNotesOpen          = false;

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
    @track settingsApiKey         = '';
    @track settingsSecret         = '';
    @track settingsIsActive       = true;
    @track settingsWebhookUrl     = '';
    @track isLoadingSettings      = false;
    @track isSavingSettings       = false;
    @track isSavingAppSettings    = false;
    @track testWebhookEvent       = 'payment.completed';
    @track isSendingTest          = false;
    @track testWebhookResult      = null;
    @track showTestModal          = false;
    @track settingsSection     = 'language';  // 'language' | 'tasks' | 'lapsed' | 'import' | 'credentials' | 'campaigns' | 'health' | 'funds'

    // ── Fund management state ──────────────────────────────────────────────────
    @track fundData            = [];    // List<FundRow> from getFundsWithCampaigns
    @track activeFunds         = [];    // [{value, label}] for combobox options
    @track isLoadingFunds      = false;
    @track showNewFundForm     = false;
    @track newFundName         = '';
    @track newFundDesc         = '';
    @track isSavingFund        = false;
    @track resolutionFund      = '';    // fund selected in resolution wizard step 2

    // CSV Import
    @track importRows        = [];
    @track importFileName    = '';
    @track importDone        = 0;
    @track importSkipped     = 0;
    @track importErrors      = [];
    @track importTotal       = 0;
    @track isImporting       = false;
    @track importComplete    = false;

    // Left-panel ticket list pagination
    @track _listPage         = 1;
    @track _editingListPage  = false;

    // Robot Health state
    @track healthStats          = null;
    @track isLoadingHealth      = false;
    @track webhookLogs          = [];
    @track isLoadingLogs        = false;
    @track healthLogFilter      = 'All';
    @track healthLogSearch      = '';
    @track _monthIdx            = null;  // null = most recent month
    @track expandedLogId        = null;
    _healthLogSearchTimer       = null;

    // Language
    @track currentLanguage  = 'en';
    @track _lbl             = { ...LABELS.en };

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

    // Event processing toggles
    @track evtPaymentCreated  = false;
    @track evtPaymentUpdated       = true;
    @track evtPaymentDeleted       = true;
    @track evtContactEvents        = false;
    @track evtHoldingExpireEnabled = false;
    @track evtHoldingExpireDays    = 10;
    @track showFollowupSetting     = false;  // org-level, admin-controlled
    @track holdingExpireOn         = true;   // saved state (not the unsaved toggle in Settings)
    @track holdingExpireDisabledAt = null;   // ISO string, set when auto-expire was switched off
    @track isReenablingExpire      = false;
    @track isSavingTicketActions   = false;

    // Transaction timeline modal
    @track showTimeline       = false;
    isUpdatingAddress         = false;
    @track timelineLoading    = false;
    @track timelineEntries    = [];
    @track timelineTicketName = '';

    // ── Static options ─────────────────────────────────────────────────────────
    // Ordered by ticket life: to do → waiting → finished → cross-cutting views → everything
    get statusOptions() {
        const l = this.lbl;
        return [
            { label: l.statusOpen,     value: 'Open' },
            { label: l.stageWaiting,   value: 'Waiting' },
            { label: l.statusDelayed,  value: 'Delayed' },
            { label: l.stageResolved,  value: 'Resolved' },
            { label: l.stageRobot,     value: 'Auto-Processed' },
            { label: l.stageClosed,    value: 'ClosedAll' },
            { label: l.stageAddress,   value: 'AddressDiffers' },
            // Only offered while the follow-up assignment button is turned on in Settings
            ...(this.showFollowupSetting ? [{ label: l.stageAssigned, value: 'Assigned' }] : []),
            { label: l.statusAll,      value: 'All' },
            // The Pending Review card picks an exact status that has no entry of its own in the list
            ...(this.statusFilter === 'Pending Review'
                ? [{ label: this._statusLabel(this.statusFilter), value: this.statusFilter }] : []),
        ];
    }

    get donorTypeOptions()     { return DONOR_TYPE_OPTIONS; }
    get addressChoiceOptions() { return ADDRESS_CHOICE_OPTIONS; }

    get ticketFundOptions() {
        const opts = [{ label: this.lbl.fundNone, value: '' }];
        (this.activeFunds || []).forEach(f => opts.push({ label: f.label, value: f.value }));
        return opts;
    }
    get ticketFundValue() {
        return (this.ticket && this.ticket.Fund__c) ? this.ticket.Fund__c : '';
    }
    get ticketFundLabel() {
        if (!this.ticket || !this.ticket.Fund__c) return '—';
        const match = (this.activeFunds || []).find(f => f.value === this.ticket.Fund__c);
        return match ? match.label : (this.ticket['Fund__r'] ? this.ticket['Fund__r'].Name : '—');
    }

    get fundMoveOptions() {
        const opts = [{ label: this.lbl.fundNone, value: '' }];
        (this.fundData || []).filter(f => f.id !== null).forEach(f => {
            opts.push({ label: f.name, value: f.id });
        });
        return opts;
    }

    // ── i18n ───────────────────────────────────────────────────────────────────
    get lbl() { return this._lbl; }

    _setLanguage(lang) {
        const l = lang || 'en';
        this.currentLanguage = l;
        this._lbl = { ...(LABELS[l] || LABELS.en) };
    }

    // ── Locale-aware formatting (dates in the user's time zone, CAD money per language) ──
    get _locale() { return this.currentLanguage === 'fr' ? 'fr-CA' : 'en-CA'; }

    _money(v, currency, decimals = 2) {
        if (v == null || v === '') return '—';
        const code = currency ? String(currency).toUpperCase() : 'CAD';
        try {
            return new Intl.NumberFormat(this._locale, {
                style: 'currency', currency: code, currencyDisplay: 'symbol',
                minimumFractionDigits: decimals, maximumFractionDigits: decimals
            }).format(Number(v));
        } catch (e) {
            return Number(v).toFixed(decimals) + ' ' + code;
        }
    }

    // Date/time values (ISO with Z) shown in the browser's time zone
    _dateTime(v, withTime = true) {
        if (!v) return '—';
        const d = new Date(v);
        if (isNaN(d.getTime())) return String(v);
        const opts = { year: 'numeric', month: 'short', day: 'numeric' };
        if (withTime) { opts.hour = '2-digit'; opts.minute = '2-digit'; }
        return d.toLocaleString(this._locale, opts);
    }

    _statusLabel(st) {
        const l = this.lbl;
        const map = {
            'Pending Review': l.statusPending, 'Holding': l.statusHolding, 'Delayed': l.statusDelayed,
            'Payment Failed': l.statusPaymentFailed, 'Resolved - Linked': l.statusLinked,
            'Resolved - New Contact': l.statusNewContact, 'Closed': l.statusClosed,
            'Skipped': l.statusSkipped, 'Error': l.statusError, 'Auto-Processed': l.statusAuto,
        };
        return map[st] || st || '';
    }
    get resolvedOnLabel() { return this.ticket && this.ticket.Status__c === 'Closed' ? this.lbl.fldClosedOn : this.lbl.fldResolvedOn; }
    get ticketEligibleDisplay() {
        return this.ticket && this.ticket.Eligible_Amount__c != null
            ? this._money(this.ticket.Eligible_Amount__c, this.ticket.Currency__c) : '—';
    }
    get ticketResolvedAtDisplay() { return this.ticket ? this._dateTime(this.ticket.Resolved_At__c) : ''; }
    get ticketStatusLabel() { return this.ticket ? this._statusLabel(this.ticket.Status__c) : ''; }

    _refundIsReal(st) { return !!st && String(st).toLowerCase() !== 'none'; }

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

    get canClearAssignment()    { return !this.assignOwnerId && !!(this.ticket && this.ticket.Manual_Assignee_Id__c); }
    get assignBtnLabel()        { return this.isAssigning ? this.lbl.savingBtn : (this.canClearAssignment ? this.lbl.btnRemoveAssign : this.lbl.btnAssign); }
    get assignBtnVariant()      { return this.canClearAssignment ? 'destructive' : 'brand'; }
    get isAssignDisabled()      { return (!this.assignOwnerId && !this.canClearAssignment) || this.isAssigning; }

    get saveBtnLabel()        { return this.lbl.saveBtn; }
    get saveAppBtnLabel()     { return this.isSavingAppSettings ? this.lbl.savingBtn : this.lbl.saveBtn; }
    get saveCredsBtnLabel()   { return this.isSavingSettings    ? this.lbl.savingBtn : this.lbl.saveBtn; }
    get saveTicketActionsBtnLabel() { return this.isSavingTicketActions ? this.lbl.savingBtn : this.lbl.saveBtn; }
    // Hidden unless an admin turns it on — but a ticket that already has an assignee keeps it visible
    // Banner when Holding auto-expire was switched off and left off for more than 12 hours
    get _expireOffHours() {
        if (this.holdingExpireOn || !this.holdingExpireDisabledAt) return null;
        return (Date.now() - new Date(this.holdingExpireDisabledAt).getTime()) / 3600000;
    }
    get showExpireOffBanner() { const h = this._expireOffHours; return h !== null && h >= 12; }
    get expireOffMessage() {
        const h = this._expireOffHours || 0;
        const fr = this.currentLanguage === 'fr';
        const ago = h >= 48 ? Math.floor(h / 24) + (fr ? ' jours' : ' days')
                            : Math.floor(h) + (fr ? ' h' : ' hours');
        const since = new Date(this.holdingExpireDisabledAt).toLocaleString(fr ? 'fr-CA' : 'en-CA',
            { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
        return this.lbl.expireOffMsg.replace('{0}', ago).replace('{1}', since);
    }

    get showFollowupButton() {
        return this.showFollowupSetting || !!(this.ticket && this.ticket.Manual_Assignee_Name__c);
    }
    // Zeffy's raw payment status (pending / succeeded / failed / deleted…) in the user's language
    get txStatusLabel() {
        const raw = this.ticket && this.ticket.Transaction_Status__c;
        if (!raw) return '—';
        const l = this.lbl;
        const map = { pending: l.txPending, succeeded: l.txSucceeded, failed: l.txFailed,
                      deleted: l.txDeleted, refunded: l.txRefunded };
        return map[raw.toLowerCase()] || (raw.charAt(0).toUpperCase() + raw.slice(1));
    }

    // Settings section nav
    get isSettingsLang()      { return this.settingsSection === 'language'; }
    get isSettingsTasks()     { return this.settingsSection === 'tasks'; }
    get isSettingsLapsed()    { return this.settingsSection === 'lapsed'; }
    get isSettingsImport()    { return this.settingsSection === 'import'; }
    get isSettingsCreds()     { return this.settingsSection === 'credentials'; }
    get isSettingsTicketActions() { return this.settingsSection === 'ticketActions'; }
    get isSettingsCampaigns() { return this.settingsSection === 'campaigns'; }
    get isSettingsHealth()    { return this.settingsSection === 'health'; }
    get isSettingsEvents()    { return this.settingsSection === 'events'; }
    get isSettingsFunds()     { return this.settingsSection === 'funds'; }

    get navLangClass()      { return 'sn-item' + (this.settingsSection === 'language'      ? ' sn-item--active' : ''); }
    get navTasksClass()     { return 'sn-item' + (this.settingsSection === 'tasks'         ? ' sn-item--active' : ''); }
    get navLapsedClass()    { return 'sn-item' + (this.settingsSection === 'lapsed'        ? ' sn-item--active' : ''); }
    get navImportClass()    { return 'sn-item' + (this.settingsSection === 'import'        ? ' sn-item--active' : ''); }
    get navCredsClass()     { return 'sn-item' + (this.settingsSection === 'credentials'   ? ' sn-item--active' : ''); }
    get navTicketActionsClass() { return 'sn-item' + (this.settingsSection === 'ticketActions' ? ' sn-item--active' : ''); }
    get navCampaignsClass() { return 'sn-item' + (this.settingsSection === 'campaigns'     ? ' sn-item--active' : ''); }
    get navEventsClass()    { return 'sn-item' + (this.settingsSection === 'events'        ? ' sn-item--active' : ''); }
    get navHealthClass()    { return 'sn-item' + (this.settingsSection === 'health'        ? ' sn-item--active' : ''); }
    get navFundsClass()     { return 'sn-item' + (this.settingsSection === 'funds'         ? ' sn-item--active' : ''); }

    get testWebhookEventOptions() {
        return [
            { label: 'payment.completed', value: 'payment.completed' },
            { label: 'payment.created',   value: 'payment.created'   },
            { label: 'payment.updated',   value: 'payment.updated'   },
            { label: 'payment.deleted',   value: 'payment.deleted'   },
        ];
    }
    get testWebhookResultSuccess() { return this.testWebhookResult && this.testWebhookResult.success; }
    get testWebhookResultFail()    { return this.testWebhookResult && !this.testWebhookResult.success; }
    get testWebhookSendLabel()     { return this.isSendingTest ? this.lbl.testWebhookSending : this.lbl.testWebhookSend; }
    get testWebhookResultMessage() {
        if (!this.testWebhookResult) return '';
        if (this.testWebhookResult.success) return this.lbl.testWebhookOk;
        return this.testWebhookResult.message || this.lbl.testWebhookFail;
    }

    get healthIsActive()    { return !!(this.healthStats && this.healthStats.isActive); }
    get healthStatusClass() {
        return this.healthIsActive
            ? 'health-dot health-dot--ok'
            : 'health-dot health-dot--warn';
    }
    get healthStatusLabel() { return this.healthIsActive ? this.lbl.healthActive : this.lbl.healthInactive; }

    get healthLastReceived() {
        if (!this.healthStats || !this.healthStats.lastReceivedAt) return this.lbl.healthNever;
        const d = new Date(this.healthStats.lastReceivedAt);
        const lang = this.currentLanguage === 'fr' ? 'fr-CA' : 'en-CA';
        return d.toLocaleString(lang, { month: 'short', day: 'numeric', year: 'numeric', hour: '2-digit', minute: '2-digit' });
    }
    get healthRelativeTime() {
        if (!this.healthStats || !this.healthStats.lastReceivedAt) return '';
        const diffMs = Date.now() - new Date(this.healthStats.lastReceivedAt).getTime();
        const mins   = Math.floor(diffMs / 60000);
        if (mins < 2)   return this.currentLanguage === 'fr' ? 'À l\'instant' : 'Just now';
        if (mins < 60)  return this.currentLanguage === 'fr' ? `Il y a ${mins} min` : `${mins} min ago`;
        const hrs = Math.floor(mins / 60);
        if (hrs < 24)   return this.currentLanguage === 'fr' ? `Il y a ${hrs} h` : `${hrs} hr ago`;
        const days = Math.floor(hrs / 24);
        return this.currentLanguage === 'fr' ? `Il y a ${days} j` : `${days}d ago`;
    }

    // Gap alert: active but no webhook in > 4 hours
    get healthHasGap() {
        if (!this.healthStats || !this.healthStats.isActive) return false;
        if (!this.healthStats.lastReceivedAt) return false;
        const diffHrs = (Date.now() - new Date(this.healthStats.lastReceivedAt).getTime()) / 3600000;
        return diffHrs > 4;
    }
    get healthGapSince() {
        if (!this.healthStats || !this.healthStats.lastReceivedAt) return '—';
        const d = new Date(this.healthStats.lastReceivedAt);
        const lang = this.currentLanguage === 'fr' ? 'fr-CA' : 'en-CA';
        return d.toLocaleString(lang, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
    }
    _healthGapDateForCopy() {
        if (!this.healthStats || !this.healthStats.lastReceivedAt) return '';
        const d = new Date(this.healthStats.lastReceivedAt);
        const pad = n => String(n).padStart(2, '0');
        return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
    }

    // Today chip values
    get healthTodayTotal()      { return this.healthStats ? (this.healthStats.todayTotal      || 0) : 0; }
    get healthTodayErrors()     { return this.healthStats ? (this.healthStats.todayErrors     || 0) : 0; }
    get healthTodayDuplicates() { return this.healthStats ? (this.healthStats.todayDuplicates || 0) : 0; }
    get healthSuccessRate()     {
        if (!this.healthStats || !this.healthStats.todayTotal) return '—';
        return this.healthStats.todaySuccessPct + '%';
    }
    get healthTodayErrClass()   { return this.healthTodayErrors > 0   ? 'hchip hchip--err' : 'hchip'; }

    get hasWebhookLogs()       { return this.webhookLogs && this.webhookLogs.length > 0; }
    get healthLogFilterOptions() {
        return [
            { label: this.lbl.healthFilterAll, value: 'All' },
            { label: 'SUCCESS',           value: 'SUCCESS' },
            { label: 'DUPLICATE_SKIPPED', value: 'DUPLICATE_SKIPPED' },
            { label: 'AUTH_FAILED',       value: 'AUTH_FAILED' },
            { label: 'EMPTY_PAYLOAD',     value: 'EMPTY_PAYLOAD' },
            { label: 'INVALID_JSON',      value: 'INVALID_JSON' },
            { label: 'MISSING_TX_ID',     value: 'MISSING_TX_ID' },
            { label: 'SERVICE_INACTIVE',  value: 'SERVICE_INACTIVE' },
            { label: 'IGNORED',           value: 'IGNORED' },
            { label: 'NO_CONFIG',         value: 'NO_CONFIG' },
            { label: 'TICKET_INSERT_FAILED', value: 'TICKET_INSERT_FAILED' },
            { label: 'GIFT_TX_FAILED',    value: 'GIFT_TX_FAILED' },
            { label: 'APEX_LIMIT_ERROR',  value: 'APEX_LIMIT_ERROR' },
            { label: 'UNHANDLED_EXCEPTION', value: 'UNHANDLED_EXCEPTION' },
        ];
    }

    get importHasRows()     { return this.importRows.length > 0; }
    get importProgressPct() { return this.importTotal > 0 ? Math.round(this.importDone / this.importTotal * 100) : 0; }
    get importHasErrors()   { return this.importErrors.length > 0; }
    get importProgressStyle() { return 'width:' + this.importProgressPct + '%'; }
    get importBtnLabel()    { return this.lbl.btnImport + ' ' + this.importRows.length + ' ' + this.lbl.ticketsWord; }

    get headerSettingsClass() {
        return 'icon-btn' + (this.showSettings ? ' icon-btn--active' : '');
    }

    // ── Panel getters ──────────────────────────────────────────────────────────
    get hasZeffyConnectSettings()      { return hasSettingsAccess; }
    get isRightTabDashboard() { return this.activePanel === 'dashboard'; }
    get isRightTabHistory()   { return this.activePanel === 'history'; }
    get isRightTabAudit()     { return this.activePanel === 'audit'; }
    get isRightTabMyTasks()   { return this.activePanel === 'mytasks'; }
    get isRightTabTicket()    {
        return this.activePanel !== 'dashboard' &&
               this.activePanel !== 'history' &&
               this.activePanel !== 'audit' &&
               this.activePanel !== 'mytasks';
    }

    get rpDashboardClass() { return 'rp-tab' + (this.activePanel === 'dashboard' ? ' rp-tab--active' : ''); }
    get rpLogsClass()      { return 'rp-tab' + (this.activePanel === 'history' || this.activePanel === 'audit' ? ' rp-tab--active' : ''); }
    get logsHistoryBtnClass() { return 'logs-switch__btn' + (this.activePanel === 'history' ? ' logs-switch__btn--active' : ''); }
    get logsAuditBtnClass()   { return 'logs-switch__btn' + (this.activePanel === 'audit'   ? ' logs-switch__btn--active' : ''); }
    get rpMyTasksClass()   { return 'rp-tab' + (this.activePanel === 'mytasks'   ? ' rp-tab--active' : ''); }

    get myTasksBadge()     { return this.myTasks.length > 0 ? String(this.myTasks.length) : null; }

    get myTasksOverdue() {
        const today = new Date().toISOString().slice(0, 10);
        return this.myTasks.filter(t => t.dueDate && t.dueDate < today).length;
    }

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
               (bs['Resolved - New Contact'] || 0);
    }
    get errorCount()   { return this._byStatus('Error'); }
    get delayedCount() { return this._byStatus('Delayed'); }
    get closedCount()  { return this._byStatus('Closed'); }

    // Dashboard cards double as list filters. Errors and Closed share the ClosedAll filter,
    // so the clicked card is remembered to highlight only that one.
    _activeCard;
    _cardClass(color, card, filter) {
        const active = this.statusFilter === filter &&
                       (this._activeCard ? this._activeCard === card : card !== 'error');
        return 'kpi kpi--' + color + (active ? ' kpi--active' : '');
    }
    get cardTotalClass()    { return this._cardClass('ink',    'total',    'All'); }
    get cardPendingClass()  { return this._cardClass('amber',  'pending',  'Pending Review'); }
    get cardResolvedClass() { return this._cardClass('green',  'resolved', 'Resolved'); }
    get cardErrorClass()    { return this._cardClass('red',    'error',    'ClosedAll'); }
    get cardDelayedClass()  { return this._cardClass('orange', 'delayed',  'Delayed'); }
    get cardClosedClass()   { return this._cardClass('gray',   'closed',   'ClosedAll'); }
    handleStatCardFilter(event) {
        const { filter, card } = event.currentTarget.dataset;
        if (!filter) return;
        this._activeCard = card;
        if (filter === this.statusFilter) return;
        this.statusFilter = filter;
        this._listPage = 1;
        this.loadTickets();
    }
    handleStatCardKey(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleStatCardFilter(event);
        }
    }

    _byStatus(key) {
        if (!this.stats || !this.stats.byStatus) return 0;
        return this.stats.byStatus[key] || 0;
    }

    // ── Dashboard extended getters ────────────────────────────────────────────
    get autoProcessedCount() { return (this.stats && this.stats.autoProcessed != null) ? this.stats.autoProcessed : 0; }
    get manualResolvedCount() { return (this.stats && this.stats.manualResolved != null) ? this.stats.manualResolved : 0; }
    get matchRatePct()        { return (this.stats && this.stats.matchRatePct   != null) ? this.stats.matchRatePct  : 0; }
    get matchRateSub() {
        return this.lbl.dashAutoMatchSub.replace('{0}', this.autoProcessedCount)
            .replace('{1}', this.autoProcessedCount + this.manualResolvedCount);
    }
    get matchMeterStyle() { return 'width:' + Math.min(100, Math.max(0, this.matchRatePct)) + '%'; }
    get totalAmountDisplay() {
        return this._money(this.stats && this.stats.totalAmount != null ? this.stats.totalAmount : 0);
    }

    // ── Monthly navigator ──────────────────────────────────────────────────────
    // Apex only returns months that have gifts — fill gaps with $0 up to the current month
    get _monthlyData() {
        const raw = (this.stats && this.stats.monthly) ? this.stats.monthly : [];
        if (GAP_CACHE.has(raw)) return GAP_CACHE.get(raw);
        const byKey = new Map(raw.map(m => [m.year * 12 + (m.month - 1), m]));
        const now = new Date();
        const nowKey = now.getFullYear() * 12 + now.getMonth();
        const keys = [...byKey.keys()];
        const startKey = keys.length ? Math.min(...keys) : nowKey;
        const endKey   = keys.length ? Math.max(nowKey, ...keys) : nowKey;
        const filled = [];
        for (let k = startKey; k <= endKey; k++) {
            filled.push(byKey.get(k) || { year: Math.floor(k / 12), month: (k % 12) + 1, total: 0, count: 0 });
        }
        GAP_CACHE.set(raw, filled);
        return filled;
    }
    get _effectiveMonthIdx() {
        const data = this._monthlyData;
        if (!data.length) return -1;
        if (this._monthIdx === null || this._monthIdx >= data.length) return data.length - 1;
        return Math.max(0, this._monthIdx);
    }
    get currentMonthEntry() {
        const data = this._monthlyData;
        return this._effectiveMonthIdx >= 0 ? data[this._effectiveMonthIdx] : null;
    }
    get currentMonthLabel() {
        const e = this.currentMonthEntry;
        if (!e) {
            const now = new Date();
            return this.lbl.monthNames[now.getMonth()] + ' ' + now.getFullYear();
        }
        return this.lbl.monthNames[(e.month || 1) - 1] + ' ' + e.year;
    }
    get monthAmountDisplay() {
        const e = this.currentMonthEntry;
        return this._money(e ? (e.total || 0) : 0);
    }
    get cannotGoPrev() { return this._effectiveMonthIdx <= 0; }
    get cannotGoNext() { return this._effectiveMonthIdx >= this._monthlyData.length - 1; }
    handleMonthPrev() { this._monthIdx = Math.max(0, this._effectiveMonthIdx - 1); }
    handleMonthNext() { this._monthIdx = Math.min(this._monthlyData.length - 1, this._effectiveMonthIdx + 1); }

    get byCampaignList() {
        if (!this.stats || !this.stats.byCampaign) return [];
        const max = Math.max(...this.stats.byCampaign.map(c => parseFloat(c.total || 0)), 1);
        return this.stats.byCampaign.map((c, i) => ({
            key:   c.id || 'c' + i,
            name:  c.name || '—',
            total: this._money(c.total || 0),
            count: c.count || 0,
            trackStyle: 'width:' + Math.round(100 * parseFloat(c.total || 0) / max) + '%',
        }));
    }
    get hasByCampaign() { return this.byCampaignList.length > 0; }
    get weeklyAllData() {
        // Apex returns only weeks with gifts (last 168 days, SOQL WEEK_IN_YEAR: week 1 = Jan 1–7).
        // Fill every week of that window with $0 so quiet weeks are visible.
        const raw = (this.stats && this.stats.weekly) ? this.stats.weekly : [];
        if (GAP_CACHE.has(raw)) return GAP_CACHE.get(raw);
        const byKey = new Map(raw.map(w => [w.year + '-' + w.week, w]));
        const filled = [];
        const seen = new Set();
        const today = new Date();
        for (let i = 168; i >= 0; i--) {
            const d = new Date(today.getFullYear(), today.getMonth(), today.getDate() - i);
            // UTC math: local dates are 23h/25h apart across DST, which shifted the week by a day
            const doy = Math.round((Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()) - Date.UTC(d.getFullYear(), 0, 1)) / 86400000) + 1;
            const week = Math.floor((doy - 1) / 7) + 1;
            const key = d.getFullYear() + '-' + week;
            if (seen.has(key)) continue;
            seen.add(key);
            filled.push(byKey.get(key) || { year: d.getFullYear(), week, created: 0, closed: 0 });
        }
        GAP_CACHE.set(raw, filled);
        return filled;
    }
    get chartPageCount() { return Math.max(1, Math.ceil(this.weeklyAllData.length / 8)); }
    get chartHasPrev()      { return this.chartPage < this.chartPageCount - 1; }
    get chartHasNext()      { return this.chartPage > 0; }
    get chartPrevDisabled() { return !this.chartHasPrev; }
    get chartNextDisabled() { return !this.chartHasNext; }
    get weeklyList() {
        const all = this.weeklyAllData;
        // Page 0 = most recent 8 weeks (end of array); page 1 = previous 8; etc.
        const end   = all.length - (this.chartPage * 8);
        const start = Math.max(0, end - 8);
        const slice = all.slice(start, end);
        const maxCount = Math.max(...slice.map(w => Math.max(w.created || 0, w.closed || 0)), 1);
        // tallest bar at 85% so its number still fits above it
        const h = n => 'height:' + Math.max(2, Math.round(85 * (n || 0) / maxCount)) + '%';
        return slice.map((w, i) => {
            // Approximate week start: use week number to compute a date label
            const approxDate = new Date(w.year, 0, 1 + (w.week - 1) * 7);
            const label = approxDate.toLocaleDateString(this._locale, { month: 'short', day: 'numeric' });
            return {
                key:          w.year + '-' + w.week,
                label,
                created:      w.created || 0,
                closed:       w.closed || 0,
                createdTitle: this.lbl.wkCreated + ': ' + (w.created || 0),
                closedTitle:  this.lbl.wkClosed + ': ' + (w.closed || 0),
                createdStyle: h(w.created),
                closedStyle:  h(w.closed),
                colClass:     'wk-col' + (i === slice.length - 1 ? ' wk-col--last' : ''),
            };
        });
    }
    // Current week vs the one before, from the same weekly series
    get thisWeek() {
        const all = this.weeklyAllData;
        const cur = all[all.length - 1] || {};
        const prev = all[all.length - 2] || {};
        const last = n => this.lbl.wkLastWeek.replace('{0}', n || 0);
        return { created: cur.created || 0, closed: cur.closed || 0,
                 prevCreated: last(prev.created), prevClosed: last(prev.closed) };
    }
    // Tickets still waiting on someone: review, holding, delayed, payment failed, error
    get stillOpenCount() {
        // same statuses as the Open list (Delayed has its own filter)
        return ['Pending Review', 'Holding', 'Payment Failed', 'Error']
            .reduce((n, st) => n + this._byStatus(st), 0);
    }
    get hasWeekly() { return this.weeklyAllData.length > 0; }

    get hasCampaignMappings() { return this.campaignMappings.length > 0; }

    get hasRecentResolutions() { return this.recentResolutionsList.length > 0; }

    get recentResolutionsList() {
        if (!this.stats || !this.stats.recentResolutions) return [];
        return this.stats.recentResolutions.slice(0, 5).map(r => {
            const nameParts = [r.First_Name__c, r.Last_Name__c].filter(Boolean);
            const displayName = r.Company_Name__c || (nameParts.length > 0 ? nameParts.join(' ') : '—');
            const acctId = r.Resolved_Account__c;
            return {
                Id: r.Id,
                Status__c: r.Status__c,
                ticketName: r.Name,
                donorDisplayName: displayName,
                accountUrl: acctId ? '/lightning/r/Account/' + acctId + '/view' : null,
                hasAccountLink: !!acctId,
                amountDisplay: this._money(r.Amount__c, r.Currency__c),
                statusBadgeClass: 'status-badge status-badge--' + this._statusClass(r.Status__c),
                statusLabel: this._statusLabel(r.Status__c),
                resolvedAtDisplay: this._dateTime(r.Resolved_At__c, false),
                resolvedByName: (r.Resolved_By__r && r.Resolved_By__r.Name) ? r.Resolved_By__r.Name : '—',
                sourceClass: 'src-pill ' + (r.Status__c === 'Auto-Processed' ? 'src-pill--robot' : 'src-pill--staff'),
                sourceLabel: r.Status__c === 'Auto-Processed' ? this.lbl.srcRobot : this.lbl.srcStaff,
            };
        });
    }

    handleOpenResolutionTicket(event) {
        const { ticketId, donorName, ticketName } = event.currentTarget.dataset;
        if (!ticketId) return;
        if (!this.openTabs.find(t => t.id === ticketId)) {
            this.openTabs = [...this.openTabs, {
                id: ticketId,
                donorName: donorName || ticketName || ticketId,
                ticketName: ticketName || ticketId
            }];
        }
        this.activePanel = ticketId;
        this.selectedTicketId = ticketId;
        this.resetResolutionState();
        this.loadDetail();
    }

    // ── Audit log getters ──────────────────────────────────────────────────────
    get hasAuditLog()      { return this.auditLogList.length > 0; }
    get auditLogCount()    { return this.auditLogList.length; }
    get auditTotalPages()  { return Math.max(1, Math.ceil(this.auditLogList.length / PAGE_SIZE)); }
    get pagedAuditLogList() {
        const start = (this.auditPage - 1) * PAGE_SIZE;
        return this.auditLogList.slice(start, start + PAGE_SIZE);
    }
    get auditPageInfo() {
        const total = this.auditLogList.length;
        if (total === 0) return '0';
        const start = (this.auditPage - 1) * PAGE_SIZE + 1;
        const end   = Math.min(this.auditPage * PAGE_SIZE, total);
        return start + '–' + end + ' / ' + total;
    }
    get auditPrevDisabled() { return this.auditPage <= 1; }
    get auditNextDisabled() { return this.auditPage >= this.auditTotalPages; }
    get auditShowPagination() { return this.auditLogList.length > PAGE_SIZE; }

    // ── Donation history getters ───────────────────────────────────────────────
    get hasHistory()       { return this.historyList.length > 0; }
    get historyCount()     { return this.historyList.length; }
    get historyTotalPages(){ return Math.max(1, Math.ceil(this.historyList.length / PAGE_SIZE)); }
    get pagedHistoryList() {
        const start = (this.historyPage - 1) * PAGE_SIZE;
        return this.historyList.slice(start, start + PAGE_SIZE);
    }
    get historyPageInfo() {
        const total = this.historyList.length;
        if (total === 0) return '0';
        const start = (this.historyPage - 1) * PAGE_SIZE + 1;
        const end   = Math.min(this.historyPage * PAGE_SIZE, total);
        return start + '–' + end + ' / ' + total;
    }
    get historyPrevDisabled() { return this.historyPage <= 1; }
    get historyNextDisabled() { return this.historyPage >= this.historyTotalPages; }
    get historyShowPagination() { return this.historyList.length > PAGE_SIZE; }

    get historyList() {
        if (!this.donationHistory) return [];
        return this.donationHistory.map(r => ({
            Id:                r.Id,
            Name:              r.IsUndone ? '—' : r.Name,
            rowClass:          r.IsUndone ? 'history-row--undone' : '',
            undoneTip:         r.IsUndone
                ? this.lbl.histUndoneTip.replace('{0}', r.UndoneAt
                    ? this._fmtDate(r.UndoneAt) + ' ' + String(r.UndoneAt).substring(11) : '—').replace('{1}', r.UndoneBy || '—')
                : '',
            DonorName:         r.DonorName || '—',
            amountDisplay:     this._money(r.Amount),
            TransactionDate:   this._fmtDate(r.TransactionDate),
            PaymentMethod:     r.PaymentMethod || '—',
            ZeffyTransactionId: r.ZeffyTransactionId || '—',
            TicketName:        r.TicketName || '',
            TicketId:          r.TicketId  || null,
            hasTicket:         !!r.TicketId,
            IsManual:          r.IsManual,
            sourceClass:       'src-pill ' + (r.IsUndone ? 'src-pill--undone'
                                 : r.IsManual ? 'src-pill--staff' : 'src-pill--robot'),
            sourceLabel:       r.IsUndone ? this.lbl.histUndone : r.IsManual ? this.lbl.srcStaff : this.lbl.srcRobot,
        }));
    }

    get auditLogList() {
        if (!this.auditLog) return [];
        return this.auditLog.map(log => ({
            Id:              log.Id,
            Name:            log.Name,
            Action__c:       log.Action__c,
            Notes__c:        log.Notes__c || '',
            ticketId:        log.Ticket__c || null,
            ticketName:      (log.Ticket__r && log.Ticket__r.Name) ? log.Ticket__r.Name : '—',
            hasTicket:       !!log.Ticket__c,
            accountName:     (log.Account__r && log.Account__r.Name) ? log.Account__r.Name : '—',
            performedByName: (log.Performed_By__r && log.Performed_By__r.Name) ? log.Performed_By__r.Name : '—',
            performedAtDisplay: this._dateTime(log.Performed_At__c),
            actionClass: 'action-badge ' + this._actionBadgeClass(log.Action__c),
            actionLabel: this._actionLabel(log.Action__c),
            // Before → after logs are one change per line; show them whole instead of one cut line
            notesClass:  ACCOUNT_LOG_ACTIONS.has(log.Action__c) ? 'lt-notes lt-notes--lines' : 'lt-notes',
        }));
    }

    _actionLabel(action) {
        if (this.currentLanguage !== 'fr' || !action) return action;
        const fr = {
            'Resolved - Linked': 'Résolu - Relié', 'Resolved - New Contact': 'Résolu - Nouveau compte',
            'Rolled Back': 'Annulé', 'Closed': 'Fermé', 'Skipped': 'Ignoré', 'Note Added': 'Note ajoutée',
            'Moved to Review': 'Passé en révision', 'Campaign Created': 'Campagne créée',
            'Amount Fixed Manually': 'Montant corrigé manuellement', 'Amount Update Failed': 'Échec mise à jour du montant',
            'Amount Updated by Zeffy': 'Montant mis à jour par Zeffy', 'Amount Changed in Zeffy': 'Montant modifié dans Zeffy', 'Amount Change Reviewed': 'Changement de montant vérifié', 'Assigned': 'Assigné', 'Unassigned': 'Désassigné',
            'Auto-Processed': 'Traité automatiquement', 'CSV Import': 'Import CSV',
            'Campaign Fund Changed': 'Fonds de campagne modifié', 'Campaign Mapping Changed': 'Correspondance de campagne modifiée',
            'Dispute Updated': 'Litige mis à jour', 'Fund Changed': 'Fonds modifié', 'Payment Confirmed': 'Paiement confirmé',
            'Payment Delete Failed': 'Échec suppression du paiement', 'Payment Deleted': 'Paiement supprimé',
            'Recurring Updated by Zeffy': 'Récurrent mis à jour par Zeffy', 'Refund Received': 'Remboursement reçu',
            'Task Not Created': 'Tâche non créée', 'Address Updated': 'Adresse mise à jour',
            'Account Updated': 'Compte mis à jour', 'Account Not Updated': 'Compte non mis à jour', 'Account Created': 'Compte créé', 'Manual Payment Deleted': 'Paiement manuel supprimé',
            'Zeffy ID Reassigned': 'Zeffy ID réassigné', 'Gift Rebuilt': 'Don recréé', 'Recurring Moved': 'Récurrent déplacé',
            'Reassign Failed': 'Échec de la réassignation', 'Zeffy ID Conflict': 'Conflit de Zeffy ID',
            'Event Ignored': 'Événement ignoré',
        };
        return fr[action] || action;
    }

    _actionBadgeClass(action) {
        if (!action) return '';
        if (action.startsWith('Resolved')) return 'action-badge--resolved';
        if (action === 'Rolled Back')       return 'action-badge--rollback';
        if (action === 'Skipped')           return 'action-badge--skipped';
        if (action.startsWith('Amount'))    return 'action-badge--amount';
        return '';
    }

    // Strip diacritics for accent-insensitive search (French/Spanish names)
    _norm(s) {
        if (!s) return '';
        return s.normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase();
    }

    // Zeffy Contact IDs that appear on more than one ticket in the loaded list (any status,
    // e.g. one Pending Review + one Holding) — same donor, shown as one stack.
    get _listDupContactIds() {
        const list = this.tickets || [];
        if (DUP_CACHE.has(list)) return DUP_CACHE.get(list);
        const counts = {};
        for (const t of list) {
            if (t.Zeffy_Contact_Id__c) counts[t.Zeffy_Contact_Id__c] = (counts[t.Zeffy_Contact_Id__c] || 0) + 1;
        }
        const dupIds = new Set(Object.keys(counts).filter(k => counts[k] > 1));
        DUP_CACHE.set(list, dupIds);
        return dupIds;
    }

    // ── Filtered ticket list — with duplicate grouping ────────────────────────
    get filteredTickets() {
        let list = this.tickets || [];
        // Every word must match somewhere (full name "Jane Doe" spans First + Last);
        // \s+ also collapses pasted non-breaking/double spaces.
        const words = this._norm(this.searchText || '').split(/\s+/).filter(w => w);
        if (words.length) {
            list = list.filter(t => {
                const hay = this._norm([
                    t.First_Name__c, t.Last_Name__c, t.Email__c, t.Name, t.Company_Name__c
                ].filter(v => v).join(' ')).replace(/\s+/g, ' ');
                return words.every(w => hay.includes(w));
            });
        }

        // Group tickets that share a Zeffy_Contact_Id__c and are duplicates
        const dupIds = this._listDupContactIds;
        const grouped = [];
        const seenGroups = {};
        for (const t of list) {
            const cid = t.Zeffy_Contact_Id__c;
            const isDup = cid && dupIds.has(cid);
            if (!isDup) {
                grouped.push({ isGroup: false, card: this._buildTicketCard(t) });
                continue;
            }
            if (seenGroups[cid] === undefined) {
                seenGroups[cid] = grouped.length;
                grouped.push({ isGroup: true, cid, cards: [this._buildTicketCard(t)] });
            } else {
                grouped[seenGroups[cid]].cards.push(this._buildTicketCard(t));
            }
        }

        // Build final flat list for template
        const result = [];
        for (const item of grouped) {
            if (!item.isGroup) {
                result.push({ ...item.card, isGroupHead: false, isGroupExtra: false });
                continue;
            }
            const isExpanded = this._expandedDupGroups.has(item.cid);
            const pendingInGroup = item.cards.filter(c => c.Status__c === 'Pending Review').length;
            const head = {
                ...item.cards[0],
                isGroupHead:      true,
                isGroupExtra:     false,
                groupCid:         item.cid,
                groupCount:       item.cards.length,
                groupCountLabel:  item.cards.length + ' ' + this.lbl.ticketsWord,
                groupExpanded:    isExpanded,
                dupStackClass:    'ticket-card-stack' + (isExpanded ? '' : ' ticket-card-stack--collapsed'),
                expandLabel:      isExpanded ? this.lbl.collapse : this.lbl.showMore.replace('{n}', item.cards.length - 1)
                                                 .replace('{w}', item.cards.length - 1 === 1 ? this.lbl.ticketWord : this.lbl.ticketsWord),
                bulkResolveLabel: this.lbl.resolveGroupBtn.replace('{n}', pendingInGroup),
                hasBulkPending:   pendingInGroup >= 1,
            };
            result.push(head);
            if (isExpanded) {
                for (let i = 1; i < item.cards.length; i++) {
                    const extra = item.cards[i];
                    result.push({ ...extra, cardClass: extra.cardClass + ' ticket-card--group-member', isGroupHead: false, isGroupExtra: true });
                }
                // Expanded: the Collapse / Resolve row closes the group, below the last ticket
                result.push({
                    Id: 'sep-' + item.cid, isGroupSeparator: true, isGroupHead: false, isGroupExtra: false,
                    groupCid: item.cid, expandLabel: head.expandLabel,
                    bulkResolveLabel: head.bulkResolveLabel, hasBulkPending: head.hasBulkPending
                });
            }
        }
        return result;
    }

    get hasFilteredTickets() { return this.filteredTickets.length > 0; }
    get ticketCount()        { return (this.tickets || []).length; }

    // ── Left-panel pagination ──────────────────────────────────────────────────
    get _filteredRealCount() {
        return this.filteredTickets.filter(t => !t.isGroupSeparator && !t.isGroupExtra).length;
    }
    get listTotalPages()     { return Math.max(1, Math.ceil(this._filteredRealCount / LP_SIZE)); }
    get showListPagination() { return this.listTotalPages > 1; }
    get listPrevDisabled()   { return this._listPage === 1; }
    get listNextDisabled()   { return this._listPage >= this.listTotalPages; }
    get listPageLabel()      { return this._listPage + '/' + this.listTotalPages; }
    get listEditingPage()    { return this._editingListPage; }

    get ticketCountLabel() {
        const word = n => n === 1 ? this.lbl.ticketWord : this.lbl.ticketsWord;
        // A collapsed duplicate group is one card but counts all its tickets
        const count = list => list.reduce((n, t) =>
            t.isGroupSeparator || t.isGroupExtra ? n : n + (t.isGroupHead ? t.groupCount : 1), 0);
        const total = count(this.filteredTickets);
        if (!this.showListPagination) return total + ' ' + word(total);
        const pageCount = count(this.pagedTickets);
        return pageCount + ' ' + this.lbl.ofWord + ' ' + total + ' ' + word(total);
    }

    get pagedTickets() {
        const start = (this._listPage - 1) * LP_SIZE;
        return this.filteredTickets.slice(start, start + LP_SIZE);
    }

    _fmtDate(iso) {
        if (!iso) return '—';
        const [y, m, d] = String(iso).substring(0, 10).split('-');
        const months = this.currentLanguage === 'fr'
            ? ['janv.','févr.','mars','avr.','mai','juin','juil.','août','sept.','oct.','nov.','déc.']
            : ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
        if (!m || !d) return iso;
        return this.currentLanguage === 'fr'
            ? +d + ' ' + months[+m - 1] + ' ' + y
            : months[+m - 1] + ' ' + +d + ', ' + y;
    }

    _buildTicketCard(t) {
        const sc = this._statusClass(t.Status__c);
        const nameParts = [t.First_Name__c, t.Last_Name__c].filter(Boolean);
        const donorName = t.Company_Name__c || (nameParts.length > 0 ? nameParts.join(' ') : '—');
        const amountDisplay = this._money(t.Amount__c, t.Currency__c);
        const currencyLabel = '';
        const isActive = t.Id === this.activePanel;
        const isOpen   = !isActive && this.openTabs.some(tab => tab.id === t.Id);
        let cardClass = 'ticket-card status--' + sc;
        if (isActive)    cardClass += ' ticket-card--active';
        else if (isOpen) cardClass += ' ticket-card--open';
        const isDuplicate = t.Zeffy_Contact_Id__c
            ? this._listDupContactIds.has(t.Zeffy_Contact_Id__c)
            : false;

        // Countdown for HOLDING tickets — based on CreatedDate, same anchor as ZeffyHoldingExpireBatch
        let holdingCountdown = null;
        if (t.Status__c === 'Holding' && t.CreatedDate) {
            const msPerDay  = 24 * 60 * 60 * 1000;
            const daysSince = Math.floor((Date.now() - new Date(t.CreatedDate).getTime()) / msPerDay);
            const daysLeft  = 10 - daysSince;
            const l = this.lbl;
            const cdTooltip = l.tooltipCountdown;
            if (daysLeft <= 0) {
                holdingCountdown = { label: l.holdingExpiresToday, cssClass: 'holding-countdown holding-countdown--critical', tooltip: cdTooltip };
            } else if (daysLeft <= 2) {
                holdingCountdown = { label: l.holdingDaysLeft.replace('{0}', daysLeft), cssClass: 'holding-countdown holding-countdown--danger',  tooltip: cdTooltip };
            } else if (daysLeft <= 5) {
                holdingCountdown = { label: l.holdingDaysLeft.replace('{0}', daysLeft), cssClass: 'holding-countdown holding-countdown--warning', tooltip: cdTooltip };
            } else {
                holdingCountdown = { label: l.holdingDaysLeft.replace('{0}', daysLeft), cssClass: 'holding-countdown holding-countdown--ok',      tooltip: cdTooltip };
            }
        }

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
            Zeffy_Contact_Id__c:     t.Zeffy_Contact_Id__c || '',
            Manual_Assignee_Name__c: t.Manual_Assignee_Name__c || '',
            hasDispute:              this._refundIsReal(t.Dispute_Status__c),
            needsAmountReview:       t.Zeffy_Amount_Not_Applied__c != null,
            disputeChip:             this._refundIsReal(t.Dispute_Status__c) ? this.lbl.chipDispute + ': ' + this._fmtLabel(t.Dispute_Status__c) : '',
            hasRefund:               this._refundIsReal(t.Refund_Status__c),
            refundChip:              this._refundIsReal(t.Refund_Status__c) ? this.lbl.chipRefund + ': ' + this._fmtLabel(t.Refund_Status__c) : '',
            addressDiffers:          !!t.Address_Differs__c,
            donorName,
            amountDisplay,
            currencyLabel,
            dateDisplay:      this._fmtDate(t.Gift_Date__c),
            cardClass,
            statusBadgeClass: 'status-badge status-badge--' + sc,
            statusLabel:      this._statusLabel(t.Status__c),
            statusTooltip:    this._statusTooltip(t.Status__c),
            isDuplicate,
            holdingCountdown,
        };
    }

    _statusClass(status) {
        if (!status) return 'pending';
        if (status === 'Pending Review')   return 'pending';
        if (status.startsWith('Resolved')) return 'resolved';
        if (status === 'Auto-Processed')   return 'auto';
        if (status === 'Error')            return 'error';
        if (status === 'Skipped')          return 'skipped';
        if (status === 'Delayed')          return 'delayed';
        if (status === 'Payment Failed')   return 'error';
        return 'pending';
    }

    _statusTooltip(status) {
        const l = this.lbl;
        if (!status || status === 'Pending Review') return l.tooltipPending;
        if (status === 'Holding')                   return l.tooltipHolding;
        if (status.startsWith('Resolved'))          return l.tooltipResolved;
        if (status === 'Auto-Processed')            return l.tooltipAuto;
        if (status === 'Delayed')                   return l.tooltipDelayed;
        if (status === 'Closed')                    return l.tooltipClosed;
        if (status === 'Error')                     return l.tooltipError;
        if (status === 'Skipped')                   return l.tooltipSkipped;
        if (status === 'Payment Failed')            return l.tooltipPaymentFailed;
        return '';
    }

    // ── Ticket detail getters ──────────────────────────────────────────────────
    get isPending() {
        return this.ticket && this.ticket.Status__c === 'Pending Review';
    }
    get canUndo() {
        return this.ticket && this.ticket.Status__c &&
            (this.ticket.Status__c === 'Resolved - Linked' ||
             this.ticket.Status__c === 'Resolved - New Contact' ||
             this.ticket.Status__c === 'Auto-Processed');
    }
    get isAutoProcessed() { return this.ticket && this.ticket.Status__c === 'Auto-Processed'; }

    // ── Address mismatch (📍): Zeffy address vs the account's Billing address ──
    get showAddressDiff() { return !!(this.ticket && this.ticket.Address_Differs__c && this.ticket.Resolved_Account__r); }
    get addrZeffyLines() {
        const t = this.ticket || {};
        return this._addrLines(t.Address__c, t.City__c, t.Province__c, t.Postal_Code__c, t.Country__c);
    }
    get addrAccountLines() {
        const a = (this.ticket && this.ticket.Resolved_Account__r) || {};
        return this._addrLines(a.BillingStreet, a.BillingCity, a.BillingState, a.BillingPostalCode, a.BillingCountry);
    }
    _addrLines(street, city, state, zip, country) {
        const cityLine = [city, state, zip].filter(Boolean).join(', ');
        const lines = [street, cityLine, country].filter(Boolean);
        if (!lines.length) lines.push(this.lbl.addrEmpty);
        return lines.map((text, i) => ({ key: 'l' + i, text }));
    }
    handleUpdateAddress() {
        this.isUpdatingAddress = true;
        updateAccountAddressFromTicket({ ticketId: this.selectedTicketId })
            .then(() => {
                this.showToast(this.lbl.addrUpdatedTitle, this.lbl.addrUpdatedBody, 'success');
                this.loadDetail();
                this.loadTickets();
                this.loadAuditLog();
            })
            .catch(err => this.showToast('Error', this.extractError(err), 'error'))
            .finally(() => { this.isUpdatingAddress = false; });
    }
    // Waiting / failed states that staff can pull into review or close by hand
    get ticketStatusTooltip() { return this.ticket ? this._statusTooltip(this.ticket.Status__c) : ''; }
    // Payment Failed because Zeffy deleted the payment: its gift was cancelled, so it can be closed
    // but not reviewed again (a new resolution would record the donation twice)
    get isZeffyDeleted() {
        const t = this.ticket;
        return !!(t && t.Status__c === 'Payment Failed' && (t.Transaction_Status__c || '').toLowerCase() === 'deleted');
    }
    get showResolvedBanner()  { return !this.canMoveToReview || this.isZeffyDeleted; }
    get donorSectionTitle()   { return this.canMoveToReview ? this.lbl.secDonorDetails : this.lbl.secDonorInfo; }
    // Pending Review reached by hand from Holding/Delayed, before Zeffy confirmed the payment
    get canReturnToWaiting() {
        const t = this.ticket;
        return !!(t && t.Status__c === 'Pending Review'
            && (t.Pre_Review_Status__c === 'Holding' || t.Pre_Review_Status__c === 'Delayed')
            && (t.Transaction_Status__c || '').toLowerCase() !== 'succeeded');
    }
    get returnToWaitingLabel() {
        return this.ticket && this.ticket.Pre_Review_Status__c === 'Delayed'
            ? this.lbl.btnReturnDelayed : this.lbl.btnReturnHolding;
    }

    get canMoveToReview() {
        const st = this.ticket && this.ticket.Status__c;
        return st === 'Holding' || st === 'Delayed' || st === 'Payment Failed';
    }
    get canReopen() { return this.ticket && this.ticket.Status__c === 'Closed'; }
    get isRecurringLabel()    { return this.ticket && this.ticket.Is_Recurring__c ? this.lbl.yes : this.lbl.no; }
    get hasNoteOrAnnotation() { return this.ticket && (this.ticket.Note__c || this.ticket.Annotation__c); }
    get isCorporateLabel()    { return this.ticket && this.ticket.Is_Corporate__c ? this.lbl.yes : this.lbl.no; }

    _fmtLabel(s) {
        if (!s) return '';
        return s.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
    }
    get tributeTypeLabel()    { return this._fmtLabel(this.ticket && this.ticket.Tribute_Type__c); }
    get disputeStatusLabel()  { return this._fmtLabel(this.ticket && this.ticket.Dispute_Status__c); }
    get disputeReasonLabel()  { return this._fmtLabel(this.ticket && this.ticket.Dispute_Reason__c); }
    get refundStatusLabel()   { return this._fmtLabel(this.ticket && this.ticket.Refund_Status__c); }

    get ticketDonorName() {
        if (!this.ticket) return '';
        const nameParts = [this.ticket.First_Name__c, this.ticket.Last_Name__c].filter(Boolean);
        return nameParts.length > 0 ? nameParts.join(' ') : (this.ticket.Company_Name__c || '—');
    }
    // Donor card: when Zeffy sent an organization name it is the title; the person who paid goes below
    get donorCardTitle() {
        return (this.ticket && this.ticket.Company_Name__c) || this.ticketDonorName;
    }
    get donorCardKind() {
        return this.ticket && this.ticket.Company_Name__c ? this.lbl.cardOrg : this.lbl.cardDonor;
    }
    get donorCardContact() {
        const t = this.ticket;
        if (!t || !t.Company_Name__c) return '';
        const person = [t.First_Name__c, t.Last_Name__c].filter(Boolean).join(' ');
        return person && person !== t.Company_Name__c ? person : '';
    }
    // Where the payment came from in Zeffy (online form, entered by hand, imported)
    get donorCardOrigin() {
        const o = this.ticket && this.ticket.Zeffy_Origin__c;
        if (!o) return null;
        const map = {
            Online:   { icon: '💻', label: this.lbl.originOnline,   hint: this.lbl.originOnlineHint },
            Manual:   { icon: '✍️', label: this.lbl.originManual,   hint: this.lbl.originManualHint },
            Imported: { icon: '📥', label: this.lbl.originImported, hint: this.lbl.originImportedHint }
        };
        const m = map[o] || { icon: '🔗', label: o, hint: '' };
        return { ...m, pillClass: 'origin-pill origin-pill--' + o.toLowerCase() };
    }
    // Payment alerts next to the blue card: only when Zeffy sent something worth seeing
    get paymentAlertChips() {
        const t = this.ticket;
        if (!t) return [];
        const chips = [];
        const tx = t.Transaction_Status__c;
        if (tx && tx.toLowerCase() !== 'succeeded') {
            chips.push({ key: 'pay', cls: 'pay-chip pay-chip--warn',
                         text: this.lbl.chipPayment.replace('{0}', this.txStatusLabel) });
        }
        // Zeffy sends refund_status "none" on every normal payment — only a real refund gets the chip
        if (this._refundIsReal(t.Refund_Status__c) || t.Refund_Amount__c) {
            const parts = [this._refundIsReal(t.Refund_Status__c) ? this.refundStatusLabel : null,
                           t.Refund_Amount__c != null ? this._money(t.Refund_Amount__c, t.Currency__c) : null];
            chips.push({ key: 'refund', cls: 'pay-chip pay-chip--refund',
                         text: [this.lbl.chipRefund, parts.filter(Boolean).join(' · ')].filter(Boolean).join(': ') });
        }
        if (this._refundIsReal(t.Dispute_Status__c)) {
            const parts = [this.disputeStatusLabel,
                           t.Dispute_Amount__c != null ? this._money(t.Dispute_Amount__c, t.Currency__c) : null];
            chips.push({ key: 'dispute', cls: 'pay-chip pay-chip--dispute',
                         text: [this.lbl.chipDispute, parts.filter(Boolean).join(' · ')].filter(Boolean).join(': ') });
        }
        return chips;
    }
    get hasPaymentAlerts() { return this.paymentAlertChips.length > 0; }

    get ticketAmountDisplay() {
        if (!this.ticket || this.ticket.Amount__c == null) return '';
        return this._money(this.ticket.Amount__c, this.ticket.Currency__c);
    }
    // ── Zeffy reports another amount: flagged for a manual review ──────────────
    get amountNeedsReview() {
        return this.ticket && this.ticket.Zeffy_Amount_Not_Applied__c != null;
    }
    get amountReviewBody() {
        if (!this.amountNeedsReview) return '';
        const t = this.ticket;
        const recorded = t.Resolved_Gift__r && t.Resolved_Gift__r.OriginalAmount != null
            ? t.Resolved_Gift__r.OriginalAmount : t.Amount__c;
        return this.lbl.amtReviewBody
            .replace('{new}', this._money(t.Zeffy_Amount_Not_Applied__c, t.Currency__c))
            .replace('{old}', this._money(recorded, t.Currency__c));
    }
    handleMarkAmountReviewed() {
        this.isMarkingAmountReviewed = true;
        markAmountReviewed({ ticketId: this.selectedTicketId })
            .then(() => {
                this.showToast(this.lbl.amtReviewedToast, '', 'success');
                this.loadDetail();
                this.loadTickets();
                this.loadAuditLog();
            })
            .catch(err => this.showToast('Error', this.extractError(err), 'error'))
            .finally(() => { this.isMarkingAmountReviewed = false; });
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
    get wizardNextDisabled()   { return !this.wizardStep2Enabled; }
    get isWizardLinkModeStr()  { return String(this.isWizardLinkMode); }
    get isWizardCreateModeStr(){ return String(this.isWizardCreateMode); }
    get wizModeLinkClass()     { return 'wiz-mode-card' + (this.isWizardLinkMode   ? ' wiz-mode-card--active' : ''); }
    get wizModeCreateClass()   { return 'wiz-mode-card' + (this.isWizardCreateMode ? ' wiz-mode-card--active' : ''); }

    get wizardStep1Class()  { return 'wiz-step' + (this.matchesStep >= 1 ? ' wiz-step--active' : ''); }
    get wizardStep2Class()  { return 'wiz-step' + (this.matchesStep >= 2 ? ' wiz-step--active' : ''); }

    get hasZeffyAddress() {
        return this.ticket && (this.ticket.Address__c || this.ticket.City__c || this.ticket.Province__c);
    }
    get zeffyAddressDisplay() {
        if (!this.ticket) return '';
        return [this.ticket.Address__c, this.ticket.City__c, this.ticket.Province__c, this.ticket.Postal_Code__c,
            this._countryName(this.ticket.Country__c)].filter(Boolean).join(', ');
    }
    // Zeffy sends the country as an ISO code ("CA") — show its name; anything else is shown as received
    _countryName(code) {
        if (!code || !/^[A-Za-z]{2}$/.test(code)) return code;
        try { return new Intl.DisplayNames(['en'], { type: 'region' }).of(code.toUpperCase()) || code; } catch (e) { return code; }
    }

    get accountMatchingInfo() {
        return {
            primaryField:     { fieldPath: 'Name' },
            additionalFields: [{ fieldPath: 'PersonEmail' }]
        };
    }

    get createTypeBtnLabel() {
        const l = this.lbl;
        const map = { individual: l.wizIndividual, eglise: l.wizChurch, org: l.wizOrg, business: l.wizBusiness };
        return map[this.donorTypeForNew] || l.wizIndividual;
    }
    get createBtnClassIndividual() { return 'create-type-btn' + (this.donorTypeForNew === 'individual' ? ' create-type-btn--active' : ''); }
    get createBtnClassEglise()     { return 'create-type-btn' + (this.donorTypeForNew === 'eglise'     ? ' create-type-btn--active' : ''); }
    get createBtnClassOrg()        { return 'create-type-btn' + (this.donorTypeForNew === 'org'        ? ' create-type-btn--active' : ''); }
    get createBtnClassBusiness()   { return 'create-type-btn' + (this.donorTypeForNew === 'business'   ? ' create-type-btn--active' : ''); }
    get ticketGiftDateDisplay() {
        return this.ticket ? this._fmtDate(this.ticket.Gift_Date__c) : '—';
    }

    get followupLabel() {
        if (this.ticket && this.ticket.Manual_Assignee_Name__c) return this.ticket.Manual_Assignee_Name__c;
        return this.lbl.btnFollowup;
    }

    // Best suggestion ≥ 80 % while staff is about to create a new account → warn about a duplicate
    get duplicateWarning() {
        if (!this.isWizardCreateMode || !this.matchCandidates || !this.matchCandidates.length) return null;
        const best = this.matchCandidates.reduce((a, c) => ((c.score || 0) > (a.score || 0) ? c : a));
        if ((best.score || 0) < 80) return null;
        return {
            id:    best.id,
            name:  best.name,
            body:  this.lbl.dupWarnBody.replace('{0}', best.name).replace('{1}', best.score),
            btn:   this.lbl.dupWarnUse.replace('{0}', best.name),
        };
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
        if (this.exceptionType === 'skip')    return this.lbl.excSkipLabel;
        if (this.exceptionType === 'close')   return this.lbl.excCloseLabel;
        return this.lbl.excKeepLabel;
    }
    get excCardSkipClass()     { return 'exc-card' + (this.exceptionType === 'skip'    ? ' exc-card--selected' : ''); }
    get excCardCloseClass()    { return 'exc-card' + (this.exceptionType === 'close'   ? ' exc-card--selected' : ''); }
    get excConfirmVariant()    { return this.exceptionType === 'pending' ? 'brand' : 'destructive'; }
    get excCardPendingClass()  { return 'exc-card' + (this.exceptionType === 'pending' ? ' exc-card--selected' : ''); }

    // Comparison getters
    get hasExistingIds()  { return this.preview && this.preview.existingZeffyIds && this.preview.existingZeffyIds.length > 0; }
    // Wizard step 2: rows where Zeffy and Salesforce disagree are highlighted
    get emailRowClass()   { return (this.preview && this.preview.emailsDiffer) ? 'cmp-row cmp-row--differs' : 'cmp-row'; }
    get emailDiffClass()  { return (this.preview && this.preview.emailsDiffer) ? 'text-diff' : ''; }
    get isLinkDisabled()  {
        return !this.selectedAccountId || !this.preview || this.isLoadingPreview || this.isEditedEmailInvalid;
    }
    get isEditedEmailInvalid() {
        const v = (this.edit.email || '').trim();
        return this.editing.email && this.updateEmailEnabled && !!v && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v);
    }
    get zeffyCellFirstNameClass() { return this._zeffyCellClass(this.editing.firstName); }
    get zeffyCellLastNameClass()  { return this._zeffyCellClass(this.editing.lastName); }
    get zeffyCellEmailClass()     { return this._zeffyCellClass(this.editing.email); }
    // Edited but Update unchecked: the correction would go nowhere, so say so
    get emailEditNeedsUpdate()     { return !!this.editing.email     && !this.updateEmailEnabled; }
    get addressEditNeedsUpdate()   { return !!this.editing.address   && !this.updateAddressEnabled; }
    _zeffyCellClass(editing) { return editing ? 'cmp-row__zeffy cmp-row__zeffy--editing' : 'cmp-row__zeffy cmp-row__zeffy--pen'; }
    get editEmailClass()   { return this.isEditedEmailInvalid ? 'cmp-edit cmp-edit--invalid' : 'cmp-edit'; }
    // Live one-line view of the (possibly corrected) address, same shape as the Apex preview
    get editedAddress() {
        const e = this.edit;
        return [e.street, e.city, e.province, e.postalCode, e.country].filter(v => v && v.trim()).join(', ');
    }

    // ── Lifecycle ──────────────────────────────────────────────────────────────
    connectedCallback() {
        this.loadTickets();
        this.loadDashboardStats();
        this.loadLanguage();
    }

    loadLanguage() {
        loadConfig()
            .then(result => {
                this._setLanguage(result.language);
                this.showFollowupSetting = result.showFollowup === 'true';
                this.holdingExpireOn         = result.holdingExpireEnabled === 'true';
                this.holdingExpireDisabledAt = result.holdingExpireDisabledAt || null;
            })
            .catch(() => {});
    }

    // ── Settings modal open/close ──────────────────────────────────────────────
    handleOpenSettings() {
        this.showSettings = true;
        this.loadSettings();
    }

    handleCloseSettings() {
        this.showSettings = false;
        this.loadLanguage(); // re-sync saved values (discards unsaved toggle changes)
    }

    handleDialogClick(event) {
        event.stopPropagation();
    }

    // ── Permanent tab handlers (Dashboard / Donation History / Audit Log) ──────
    handleRightTabChange(event) {
        const tab = event.currentTarget.dataset.tab;
        const prev = this.activePanel;
        this.activePanel = tab;
        // Reload on every switch so actions taken in a ticket since the last visit show up
        if (tab === 'history' && prev !== 'history') {
            this.loadDonationHistory();
        }
        if (tab === 'audit' && prev !== 'audit') {
            this.loadAuditLog();
        }
        if (tab === 'mytasks') {
            this.loadMyTasks();
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
        this._activeCard = null;
        this.statusFilter = event.detail.value;
        this._listPage = 1;
        this.loadTickets();
    }

    handleSearch(event) {
        this.searchText = event.target.value;
        this._listPage = 1;
    }

    // ── Left-panel pagination handlers ────────────────────────────────────────
    handleListPrevPage() {
        if (this._listPage > 1) { this._listPage--; this._editingListPage = false; }
    }
    handleListNextPage() {
        if (this._listPage < this.listTotalPages) { this._listPage++; this._editingListPage = false; }
    }
    handleListPageLabelClick() { this._editingListPage = true; }
    handleListPageInputKey(event) {
        if (event.key === 'Enter') this._applyListPageInput(event.target.value);
        if (event.key === 'Escape') this._editingListPage = false;
    }
    handleListPageInputBlur(event) { this._applyListPageInput(event.target.value); }
    _applyListPageInput(val) {
        const target = parseInt(val, 10);
        if (!isNaN(target) && target >= 1 && target <= this.listTotalPages) {
            this._listPage = target;
        }
        this._editingListPage = false;
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

    // ── Audit log search + pagination ──────────────────────────────────────────
    handleAuditSearchInput(event) {
        this.auditSearchTerm = event.target.value;
        this.auditPage = 1;
        clearTimeout(this._auditSearchTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._auditSearchTimer = setTimeout(() => { this.loadAuditLog(); }, 400);
    }

    handleAuditClearSearch() {
        this.auditSearchTerm = '';
        this.auditPage = 1;
        this.loadAuditLog();
    }

    handleAuditOpenTicket(event) {
        const ticketId   = event.currentTarget.dataset.id;
        const ticketName = event.currentTarget.dataset.name;
        const accountName = event.currentTarget.dataset.account;
        if (!ticketId) return;
        // Prefer: donor name from left-panel list → accountName from log → ticket number
        const raw = this.tickets.find(t => t.Id === ticketId);
        const nameParts = raw ? [raw.First_Name__c, raw.Last_Name__c].filter(Boolean) : [];
        const donorName = nameParts.length > 0
            ? nameParts.join(' ')
            : (raw && raw.Company_Name__c
                ? raw.Company_Name__c
                : (accountName && accountName !== '—' ? accountName : ticketName));
        if (!this.openTabs.find(t => t.id === ticketId)) {
            this.openTabs = [...this.openTabs, { id: ticketId, donorName, ticketName }];
        }
        this.activePanel = ticketId;
        this.selectedTicketId = ticketId;
        this.resetResolutionState();
        this.loadDetail();
    }

    handleHistoryOpenTicket(event) {
        const ticketId   = event.currentTarget.dataset.id;
        const ticketName = event.currentTarget.dataset.name;
        const donorName  = event.currentTarget.dataset.donor;
        if (!ticketId) return;
        const raw = this.tickets.find(t => t.Id === ticketId);
        const nameParts = raw ? [raw.First_Name__c, raw.Last_Name__c].filter(Boolean) : [];
        const label = nameParts.length > 0
            ? nameParts.join(' ')
            : (raw && raw.Company_Name__c
                ? raw.Company_Name__c
                : (donorName && donorName !== '—' ? donorName : ticketName));
        if (!this.openTabs.find(t => t.id === ticketId)) {
            this.openTabs = [...this.openTabs, { id: ticketId, donorName: label, ticketName }];
        }
        this.activePanel = ticketId;
        this.selectedTicketId = ticketId;
        this.resetResolutionState();
        this.loadDetail();
    }

    handleAuditPrevPage() {
        if (this.auditPage > 1) this.auditPage -= 1;
    }

    handleAuditNextPage() {
        if (this.auditPage < this.auditTotalPages) this.auditPage += 1;
    }

    // ── Donation history search + pagination ───────────────────────────────────
    handleHistorySearchInput(event) {
        this.historySearchTerm = event.target.value;
        this.historyPage = 1;
        clearTimeout(this._historySearchTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._historySearchTimer = setTimeout(() => { this.loadDonationHistory(); }, 400);
    }

    handleHistoryClearSearch() {
        this.historySearchTerm = '';
        this.historyPage = 1;
        this.loadDonationHistory();
    }

    handleHistoryPrevPage() {
        if (this.historyPage > 1) this.historyPage -= 1;
    }

    handleHistoryNextPage() {
        if (this.historyPage < this.historyTotalPages) this.historyPage += 1;
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
        this._previewSeq++; // drop a comparison still loading
        this.isLoadingPreview  = false;
        this.preview                  = null;
        this.accountSearch            = '';
        this.accountSearchResults     = [];
        this.emailFieldOptions        = [];
        this.emailTargetField         = '';
        this.updateEmailEnabled       = false;
        this.updateAddressEnabled     = false;
        this.edit                     = {};
        this.editing                  = {};
        this._rvPencilPrev            = {};
        this.createEditing            = false;
        this.createEdit               = {};
        this.resolutionNotes          = '';
        this.rvNotesOpen              = false;
    }

    handleWizardBack() {
        if (this.matchesStep === 2) {
            this.matchesStep = 1;
            if (this.matchesMode === 'link') {
                this.selectedAccountId = null;
                this._previewSeq++; // drop a comparison still loading
                this.isLoadingPreview  = false;
                this.preview           = null;
                this.emailFieldOptions = [];
                this.emailTargetField  = '';
            }
        }
    }

    handleWizardNext() {
        if (this.matchesStep === 1 && this.wizardStep2Enabled) {
            this.matchesStep = 2;
            // Pre-populate fund: use ticket's current fund, else first available fund
            this.resolutionFund = (this.ticket && this.ticket.Fund__c)
                || (this.activeFunds.length > 0 ? this.activeFunds[0].value : '');
        }
    }

    handleResolutionFundChange(event) { this.resolutionFund = event.detail.value || ''; }

    handleSelectCandidate(event) {
        const id = event.currentTarget.dataset.id;
        this.matchesMode = 'link';
        this._loadPreviewForAccount(id);
    }

    handleAccountSelected(event) {
        const id = event.detail.recordId;
        if (!id) { this.selectedAccountId = null; this._previewSeq++; this.isLoadingPreview = false; this.preview = null; this.emailFieldOptions = []; return; }
        this.matchesMode = 'link';
        this._loadPreviewForAccount(id);
    }

    handleWizardModeChange(event) {
        const mode = event.currentTarget.dataset.mode;
        if (mode === this.matchesMode) return;
        this.matchesMode       = mode;
        this.selectedAccountId = null;
        this._previewSeq++; // drop a comparison still loading
        this.isLoadingPreview  = false;
        this.preview           = null;
        this.emailFieldOptions = [];
        this.emailTargetField  = '';
    }

    handleSelectCreateMode(event) {
        this.matchesMode      = 'create';
        this.donorTypeForNew  = event.currentTarget.dataset.type || 'individual';
        this.selectedAccountId = null;
        this._previewSeq++; // drop a comparison still loading
        this.isLoadingPreview  = false;
        this.preview           = null;
        this.createEditing     = false;
        this.createEdit        = {};
    }

    get isCreateIndividual() { return this.donorTypeForNew === 'individual'; }
    // Name the new non-individual Account gets: company name, else the donor's full name
    get createDefaultAccountName() {
        const t = this.ticket || {};
        return t.Company_Name__c || [t.First_Name__c, t.Last_Name__c].filter(Boolean).join(' ');
    }
    get isCreateEmailInvalid() {
        const v = (this.createEdit.email || '').trim();
        return this.createEditing && this.isCreateIndividual && !!v && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v);
    }
    get createEmailClass() { return this.isCreateEmailInvalid ? 'cmp-edit cmp-edit--invalid' : 'cmp-edit'; }

    // Pencil on: start from what Zeffy sent. Off: discard every correction.
    handleToggleCreateEdit() {
        if (this.createEditing) {
            this.createEditing = false;
            this.createEdit    = {};
            return;
        }
        const t = this.ticket || {};
        this.createEdit = {
            firstName:   t.First_Name__c  || '',
            lastName:    t.Last_Name__c   || '',
            accountName: this.createDefaultAccountName,
            email:       t.Email__c       || '',
            phone:       t.Phone__c       || '',
            street:      t.Address__c     || '',
            city:        t.City__c        || '',
            province:    t.Province__c    || '',
            postalCode:  t.Postal_Code__c || '',
            country:     t.Country__c     || ''
        };
        this.createEditing = true;
    }
    handleCreateEditValue(event) {
        this.createEdit = { ...this.createEdit, [event.target.dataset.field]: event.target.value };
    }
    // Only the fields the chosen account type actually stores are sent
    _createEditedValues() {
        if (!this.createEditing) return null;
        const e = this.createEdit;
        const keys = this.isCreateIndividual
            ? ['firstName', 'lastName', 'email', 'phone', 'street', 'city', 'province', 'postalCode', 'country']
            : ['accountName', 'phone', 'street', 'city', 'province', 'postalCode', 'country'];
        const out = {};
        keys.forEach(k => { out[k] = e[k]; });
        return out;
    }

    _loadPreviewForAccount(accountId) {
        this.selectedAccountId = accountId;
        this.preview           = null;
        this.emailFieldOptions = [];
        this.emailTargetField  = '';
        this.updateEmailEnabled     = false;
        this.updateAddressEnabled   = false;
        this.isLoadingPreview  = true;
        // Every request gets a number: only the latest one (same ticket and account) may fill the comparison
        const req = ++this._previewSeq;
        getLinkPreview({ ticketId: this.selectedTicketId, accountId })
            .then(result => {
                if (req !== this._previewSeq) return; // another ticket or account was picked meanwhile
                this.preview           = result;
                this.emailFieldOptions = result.emailFieldOptions || [];
                this.editing = {};
                this._rvPencilPrev = {};
                this.edit = {
                    email:      result.ticketEmail      || '',
                    firstName:  result.ticketFirstName  || '',
                    lastName:   result.ticketLastName   || '',
                    street:     result.ticketStreet     || '',
                    city:       result.ticketCity       || '',
                    province:   result.ticketProvince   || '',
                    postalCode: result.ticketPostalCode || '',
                    country:    result.ticketCountry    || ''
                };
                this.isLoadingPreview  = false;
            })
            .catch(err => {
                if (req !== this._previewSeq) return;
                this.isLoadingPreview = false;
                this.showToast('Error loading comparison', this.extractError(err), 'error');
            });
    }

    handleEmailFieldChange(event)  { this.emailTargetField    = event.detail.value; }
    handleToggleEmail(event)       { this.updateEmailEnabled     = event.target.checked; if (!event.target.checked) this.emailTargetField = ''; }
    handleToggleAddress(event)     { this.updateAddressEnabled   = event.target.checked; }
    handleEditValue(event)         { this.edit = { ...this.edit, [event.target.dataset.field]: event.target.value }; }

    // Pencil on/off. Turning it off discards the correction and puts back what Zeffy sent.
    handleTogglePencil(event) {
        const row = event.currentTarget.dataset.row;
        const on  = !this.editing[row];
        this.editing = { ...this.editing, [row]: on };
        // Correcting a value means the reviewer wants it saved: pick where it goes
        if (on) { this._rvSavePrev(row); this._rvAutoSelect(row); }
        else this._rvRestorePrev(row);
        if (!on && this.preview) {
            const restored = { ...this.edit };
            const group = EDIT_GROUPS[row] || {};
            Object.keys(group).forEach(k => { restored[k] = this.preview[group[k]] || ''; });
            this.edit = restored;
        }
    }

    // ── Review step (link): slots on the Salesforce side ───────────────────────
    // Email: click a slot to save the Zeffy email there, click it again to leave emails alone
    handleRvEmailSlot(event) {
        if (this.rvEmailMatchKey) return;
        const key = event.currentTarget.dataset.key;
        if (this.updateEmailEnabled && this.emailTargetField === key) {
            this.updateEmailEnabled = false;
            this.emailTargetField   = '';
        } else {
            this.updateEmailEnabled = true;
            this.emailTargetField   = key;
        }
    }
    // Address: one slot, replace or not
    handleRvToggleRow(event) {
        const row = event.currentTarget.dataset.row;
        if (row === 'address' && !this.rvAddrSame) this.updateAddressEnabled = !this.updateAddressEnabled;
    }
    handleRvOpenNotes() { this.rvNotesOpen = true; }

    // Discarding a correction puts back the replace choices the reviewer had before opening the pencil
    _rvSavePrev(row) {
        const prev = { ...(this._rvPencilPrev || {}) };
        if (row === 'address')   prev.address   = this.updateAddressEnabled;
        if (row === 'email')     prev.email     = { on: this.updateEmailEnabled, target: this.emailTargetField };
        this._rvPencilPrev = prev;
    }
    _rvRestorePrev(row) {
        const prev = this._rvPencilPrev || {};
        if (!(row in prev)) return;
        if (row === 'address')   this.updateAddressEnabled   = prev.address;
        if (row === 'email')   { this.updateEmailEnabled = prev.email.on; this.emailTargetField = prev.email.target; }
        const rest = { ...prev }; delete rest[row];
        this._rvPencilPrev = rest;
    }
    _rvAutoSelect(row) {
        if (row === 'address')   this.updateAddressEnabled   = true;
        if (row === 'email' && !this.updateEmailEnabled && !this.rvEmailMatchKey) {
            const opts = this._rvEmailOptions();
            if (!opts.length) return;
            const empty = opts.find(o => !o.currentValue);
            this.updateEmailEnabled = true;
            this.emailTargetField   = (empty || opts[0]).value;
        }
    }
    // Main email (PersonEmail) first, then the rest in label order
    _rvEmailOptions() {
        const opts = [...(this.emailFieldOptions || [])];
        return opts.sort((a, b) => {
            if (a.value === 'PersonEmail') return -1;
            if (b.value === 'PersonEmail') return 1;
            return (a.label || '').localeCompare(b.label || '');
        });
    }
    get rvZeffyEmail() {
        return ((this.editing.email ? this.edit.email : (this.preview && this.preview.ticketEmail)) || '').trim();
    }
    get rvZeffyEmailDisplay() { return this.rvZeffyEmail || '—'; }
    // Slot that already holds the Zeffy email: nothing to save, the other slots are locked
    get rvEmailMatchKey() {
        const z = this.rvZeffyEmail.toLowerCase();
        if (!z) return null;
        const hit = this._rvEmailOptions().find(o => (o.currentValue || '').toLowerCase() === z);
        return hit ? hit.value : null;
    }
    get rvEmailTarget() {
        if (this.rvEmailMatchKey) return null;
        if (!this.updateEmailEnabled || !this.emailTargetField) return null;
        return (this.emailFieldOptions || []).find(o => o.value === this.emailTargetField) || null;
    }
    get rvEmailSlots() {
        const zeffy  = this.rvZeffyEmail;
        const target = this.rvEmailTarget;
        const match  = this.rvEmailMatchKey;
        if (match) {
            return this._rvEmailOptions().map(o => {
                const same = o.value === match;
                const cur  = o.currentValue || '';
                return {
                    key: o.value, label: o.label, on: false, checked: same ? 'true' : 'false',
                    disabled: true, same,
                    display: cur || this.lbl.rvEmpty,
                    svClass: cur ? 'rv-sv' : 'rv-sv rv-sv--empty',
                    tag:     same ? this.lbl.rvTagSame : '',
                    title:   same ? this.lbl.rvSameLocked : o.label + ': ' + (cur || this.lbl.rvEmpty),
                    cls:     'rv-slot rv-slot--locked' + (same ? ' rv-slot--same' : '')
                };
            });
        }
        return this._rvEmailOptions().map(o => {
            const on  = !!target && target.value === o.value;
            const cur = o.currentValue || '';
            return {
                key:     o.value,
                label:   o.label,
                on,
                checked: on ? 'true' : 'false',
                current: on ? cur : '',
                newVal:  zeffy,
                display: cur || this.lbl.rvEmpty,
                svClass: cur ? 'rv-sv' : 'rv-sv rv-sv--empty',
                disabled: false, same: false,
                tag:     on ? (cur ? this.lbl.rvTagReplace : this.lbl.rvTagAdd) : '',
                title:   o.label + ': ' + (cur || this.lbl.rvEmpty),
                cls:     'rv-slot' + (on ? ' rv-slot--target' : '')
            };
        });
    }
    get rvEmailBadge() {
        const z = this.rvZeffyEmail.toLowerCase();
        if (!z) return null;
        const found = (this.emailFieldOptions || []).some(o => (o.currentValue || '').toLowerCase() === z);
        return found
            ? { label: this.lbl.rvAlreadyOnAccount, cls: 'rv-chip rv-chip--same' }
            : { label: this.lbl.rvNotOnAccount,     cls: 'rv-chip rv-chip--diff' };
    }
    get rvEmailHint() {
        if (this.rvEmailMatchKey) return '';
        const t = this.rvEmailTarget;
        if (!t) return this.lbl.rvPickSlot;
        return (t.currentValue ? this.lbl.rvWillReplace : this.lbl.rvWillAdd).replace('{field}', t.label);
    }
    _rvSlot(on, current, newVal) {
        return {
            on,
            checked: on ? 'true' : 'false',
            current: on ? (current || '') : '',
            newVal,
            display: current || this.lbl.rvEmpty,
            tag:     on ? (current ? this.lbl.rvTagReplace : this.lbl.rvTagAdd) : '',
            title:   on ? this.lbl.rvClickAgain : this.lbl.rvClickToReplace,
            cls:     'rv-slot rv-slot--single' + (on ? ' rv-slot--target' : '')
        };
    }
    // Linking never renames the account: Salesforce keeps its name, Zeffy's is only shown for comparison
    // (it is used only when a new account is created)
    get rvZeffyFullName() { const p = this.preview || {}; return [p.ticketFirstName, p.ticketLastName].map(v => (v || '').trim()).filter(Boolean).join(' '); }
    get rvNameDiffers() { const p = this.preview || {}; return _nameDiffers(this.rvZeffyFullName, p); }
    get rvZeffyAddr()  { return (this.editing.address   ? this.editedAddress  : (this.preview && this.preview.ticketAddress))   || ''; }
    get rvAddrSlot() {
        if (this.rvAddrSame) {
            const cur = (this.preview && this.preview.accountAddress) || '';
            return { on: false, checked: 'true', disabled: true, current: '', newVal: '', display: cur,
                tag: this.lbl.rvTagSame, title: this.lbl.rvSameLockedAddr,
                cls: 'rv-slot rv-slot--single rv-slot--locked rv-slot--same' };
        }
        return { ...this._rvSlot(this.updateAddressEnabled, this.preview && this.preview.accountAddress, this.rvZeffyAddr), disabled: false };
    }
    // Same address once case, spaces and punctuation are ignored (e.g. corrected with the pencil to match)
    // The country is left out, like the Apex check: tickets say "CA", accounts "Canada"
    get rvAddrSame() {
        const norm = v => (v || '').toLowerCase().replace(/[^a-z0-9\u00c0-\u017f]/g, '');
        const e = this.editing.address ? this.edit : null;
        const p = this.preview || {};
        const z = norm(e ? [e.street, e.city, e.province, e.postalCode].filter(v => v && v.trim()).join(', ')
                         : [p.ticketStreet, p.ticketCity, p.ticketProvince, p.ticketPostalCode].filter(v => v && v.trim()).join(', '));
        return !!z && z === norm(p.accountAddressCore);
    }
    get rvAddrWillUpdate() { return this.updateAddressEnabled && !this.rvAddrSame; }
    get rvAddrChip() {
        return this.rvAddrSame
            ? { label: this.lbl.rvAlreadyOnAccount, cls: 'rv-chip rv-chip--same' }
            : { label: this.lbl.cmpDiffers,         cls: 'rv-chip rv-chip--diff' };
    }
    get rvAddrHint()  {
        if (this.rvAddrSame) return '';
        return this.updateAddressEnabled ? this.lbl.rvWillReplaceShort : this.lbl.rvClickToReplace;
    }
    _rvArrow(on) { return 'rv-arrow' + (on ? ' rv-arrow--on' : ''); }
    get rvArrowEmailClass() { return this._rvArrow(!!this.rvEmailTarget); }
    get rvArrowAddrClass()  { return this._rvArrow(this.rvAddrWillUpdate); }
    get rvArrowNameClass()  { return this._rvArrow(false); }
    // New Zeffy ID is always added next to the ones the account already has (multi-ID)
    get rvIdChipLabel() {
        const n = ((this.preview && this.preview.existingZeffyIds) || []).length + 1;
        return n === 1 ? this.lbl.rvIdFirst : this.lbl.rvIdNth.replace('{n}', n);
    }
    get rvExistingIdsTitle() {
        const ids = (this.preview && this.preview.existingZeffyIds) || [];
        return ids.length ? this.lbl.rvIdsOnAccount.replace('{ids}', ids.join(', ')) : '';
    }
    get rvLinkLabel() {
        const amt = this.ticketAmountDisplay;
        return amt ? this.lbl.rvLinkRecord.replace('{amount}', amt) : this.lbl.btnLink;
    }
    get rvSummary() {
        const L = this.lbl;
        const p = this.preview || {};
        const ok = 'rv-result__item rv-result__item--do';
        const keep = 'rv-result__item rv-result__item--keep';
        const form = this.ticket && this.ticket.Form_Name__c ? ' (' + this.ticket.Form_Name__c + ')' : '';
        const items = [{ key: 'rec', cls: ok, icon: 'utility:check', pre: L.rvSumRecord, bold: this.ticketAmountDisplay + form, mid: L.rvSumOn, bold2: p.accountName || '', post: '' }];
        const t = this.rvEmailTarget;
        if (t) {
            items.push(t.currentValue
                ? { key: 'em', cls: ok, icon: 'utility:check', pre: L.rvSumEmailReplace.replace('{field}', t.label), bold: this.rvZeffyEmail, mid: '', bold2: '', post: '' }
                : { key: 'em', cls: ok, icon: 'utility:check', pre: L.rvSumEmailAdd, bold: this.rvZeffyEmail, mid: L.rvSumAs, bold2: t.label, post: '' });
        } else {
            items.push({ key: 'em', cls: keep, icon: 'utility:dash', pre: L.rvSumEmailsSame, bold: '', mid: '', bold2: '', post: '' });
        }
        if (p.addressesDiffer) {
            items.push(this.rvAddrWillUpdate
                ? { key: 'ad', cls: ok,   icon: 'utility:check', pre: L.rvSumAddrReplace, bold: this.rvZeffyAddr, mid: '', bold2: '', post: '' }
                : { key: 'ad', cls: keep, icon: 'utility:dash',  pre: L.rvSumAddrSame,    bold: '', mid: '', bold2: '', post: '' });
        }
        return items;
    }

    // Only rows both corrected (pencil) and checked for Update are sent; Apex logs real changes in the notes
    _editedValues() {
        const e = this.edit;
        const out = {};
        const ed = this.editing;
        if (ed.email     && this.updateEmailEnabled && !this.rvEmailMatchKey) out.email = e.email;
        if (ed.address   && this.rvAddrWillUpdate) {
            Object.assign(out, { street: e.street, city: e.city, province: e.province,
                postalCode: e.postalCode, country: e.country });
        }
        return out;
    }

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
        this._previewSeq++; // drop a comparison still loading
        this.isLoadingPreview  = false;
        this.preview              = null;
    }

    handleConfirmLink() {
        if (!this.selectedAccountId) return;
        const fundSave = this.resolutionFund
            ? updateTicketFund({ ticketId: this.selectedTicketId, fundId: this.resolutionFund })
            : Promise.resolve();
        fundSave
            .then(() => resolveLinkExistingEdited({
                ticketId:         this.selectedTicketId,
                accountId:        this.selectedAccountId,
                notes:            this.resolutionNotes,
                emailTargetField: this.updateEmailEnabled && !this.rvEmailMatchKey ? (this.emailTargetField || null) : null,
                updateAddress:    this.rvAddrWillUpdate,
                updateFirstName:  false,
                updateLastName:   false,
                editedValues:     this._editedValues(),
            }))
            .then(warning => {
                this.showMatchesModal = false;
                if (warning) this.showToast(this.lbl.rvAcctNotUpdated, warning, 'warning');
                else this.showToast('Success', 'Donor linked and donation recorded.', 'success');
                this.afterResolve();
            })
            .catch(err => this.showToast('Error', this.extractError(err), 'error'));
    }

    handleConfirmCreate() {
        if (this.isCreateEmailInvalid) return;
        const fundSave = this.resolutionFund
            ? updateTicketFund({ ticketId: this.selectedTicketId, fundId: this.resolutionFund })
            : Promise.resolve();
        fundSave
            .then(() => resolveCreateNewEdited({
                ticketId:     this.selectedTicketId,
                donorType:    this.donorTypeForNew,
                notes:        this.resolutionNotes,
                editedValues: this._createEditedValues(),
            }))
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
        this.exceptionType      = 'pending';
        this.resolutionNotes    = '';
    }

    handleCloseExceptionModal() { this.showExceptionModal = false; }

    handleExceptionTypeChange(event) { this.exceptionType = event.currentTarget.dataset.type; }

    handleConfirmException() {
        if (this.exceptionType === 'pending') {
            // Keep as Pending Review — the note (if any) is saved for the next reviewer
            const note = (this.resolutionNotes || '').trim();
            if (!note) {
                this.showExceptionModal = false;
                this.showToast(this.lbl.keptPendingTitle, '', 'info');
                return;
            }
            addReviewNote({ ticketId: this.selectedTicketId, note })
                .then(() => {
                    this.showExceptionModal = false;
                    this.resolutionNotes    = '';
                    this.showToast(this.lbl.noteSavedTitle, this.lbl.noteSavedBody, 'success');
                    this.afterResolve();
                })
                .catch(err => this.showToast('Error', this.extractError(err), 'error'));
            return;
        }
        // Status already says Closed: only a real reason is stored (shown again if the ticket is reopened)
        const reason = (this.resolutionNotes || '').trim() || null;
        closeTicket({ ticketId: this.selectedTicketId, reason })
            .then(() => {
                this.showExceptionModal = false;
                this.showToast(this.lbl.closedToast, '', 'success');
                this.afterResolve();
            })
            .catch(err => this.showToast('Error', this.extractError(err), 'error'));
    }

    // ── Follow-up Assignment modal ─────────────────────────────────────────────
    handleOpenAssignModal() {
        this.showAssignModal = true;
        // Pre-populate with current assignee so the chip appears on open
        if (this.ticket && this.ticket.Manual_Assignee_Id__c) {
            this.assignOwnerId     = this.ticket.Manual_Assignee_Id__c;
            this.assignOwnerName   = this.ticket.Manual_Assignee_Name__c;
            this.assignOwnerSearch = this.ticket.Manual_Assignee_Name__c;
        }
    }
    handleCloseAssignModal() {
        this.showAssignModal = false;
        this.handleClearAssignOwner();
    }

    handleNotesChange(event) { this.resolutionNotes = event.detail.value; }

    // ── Settings section nav ──────────────────────────────────────────────────
    handleChartPrev() { if (this.chartHasPrev) this.chartPage++; }
    handleChartNext() { if (this.chartHasNext) this.chartPage--; }

    handleToggleDupGroup(event) {
        const cid = event.currentTarget.dataset.cid;
        if (!cid) return;
        if (this._expandedDupGroups.has(cid)) {
            this._expandedDupGroups.delete(cid);
        } else {
            this._expandedDupGroups.add(cid);
        }
        // Force re-render by replacing the Set reference
        this._expandedDupGroups = new Set(this._expandedDupGroups);
    }

    handleSettingsSectionChange(event) {
        this.settingsSection = event.currentTarget.dataset.section;
        if (this.settingsSection === 'campaigns') {
            this.loadCampaignMappings();
        } else if (this.settingsSection === 'health') {
            this.loadHealthData();
        } else if (this.settingsSection === 'funds') {
            this.loadFundData();
        }
    }

    // ── Fund Management ───────────────────────────────────────────────────────

    loadFundData() {
        this.isLoadingFunds = true;
        Promise.all([getFundsWithCampaigns(), getActiveFunds()])
            .then(([funds, active]) => {
                this.fundData    = funds;
                this.activeFunds = active;
            })
            .catch(err => this.showToast('Error', this.extractError(err), 'error'))
            .finally(() => { this.isLoadingFunds = false; });
    }

    handleToggleNewFundForm() {
        this.showNewFundForm = !this.showNewFundForm;
        this.newFundName = '';
        this.newFundDesc = '';
    }

    handleNewFundNameChange(event) { this.newFundName = event.detail.value; }
    handleNewFundDescChange(event) { this.newFundDesc = event.detail.value; }

    handleCreateFund() {
        if (!this.newFundName.trim()) return;
        this.isSavingFund = true;
        createFund({ name: this.newFundName.trim(), description: this.newFundDesc.trim() })
            .then(() => {
                this.showToast(this.lbl.fundCreated, '', 'success');
                this.showNewFundForm = false;
                this.newFundName = '';
                this.newFundDesc = '';
                this.loadFundData();
            })
            .catch(err => this.showToast('Error', this.extractError(err), 'error'))
            .finally(() => { this.isSavingFund = false; });
    }

    handleAssignCampaignToFund(event) {
        const campaignId = event.currentTarget.dataset.campaignid;
        const fundId     = event.detail.value || null;
        assignCampaignToFund({ campaignId, fundId })
            .then(() => {
                this.showToast(this.lbl.fundAssigned, '', 'success');
                this.loadFundData();
            })
            .catch(err => this.showToast('Error', this.extractError(err), 'error'));
    }

    handleTicketFundChange(event) {
        const fundId = event.detail.value || null;
        if (!this.ticket) return;
        updateTicketFund({ ticketId: this.ticket.Id, fundId })
            .then(() => {
                this.ticket = { ...this.ticket, Fund__c: fundId };
                this.showToast(this.lbl.fundSaved, '', 'success');
            })
            .catch(err => this.showToast('Error', this.extractError(err), 'error'));
    }

    // ── Robot Health ──────────────────────────────────────────────────────────

    loadHealthData() {
        this.loadHealthStats();
        this.loadHealthLogs();
    }

    loadHealthStats() {
        this.isLoadingHealth = true;
        getWebhookHealthStats()
            .then(stats => { this.healthStats = stats; })
            .catch(err  => { console.error('getWebhookHealthStats error', err); })
            .finally(() => { this.isLoadingHealth = false; });
    }

    loadHealthLogs() {
        this.isLoadingLogs = true;
        getWebhookLogs({ statusFilter: this.healthLogFilter, searchTerm: this.healthLogSearch, maxRows: 200 })
            .then(logs => {
                this.webhookLogs = logs.map(l => {
                    const isDupSkip = l.status === 'DUPLICATE_SKIPPED';
                    const isSuccess = l.status === 'SUCCESS';
                    const isWarning = l.status === 'SERVICE_INACTIVE' || l.status === 'IGNORED' || isDupSkip;
                    const isError   = !isSuccess && !isWarning;
                    const isTest    = !!(l.transactionId && String(l.transactionId).startsWith('TEST-'));
                    return {
                        ...l,
                        isSuccess,
                        isError,
                        isWarning,
                        isDupSkip,
                        isTest,
                        rowClass:      isError ? 'health-row--error' : (isWarning ? 'health-row--warn' : ''),
                        badgeClass:    isSuccess ? 'health-badge health-badge--ok' : (isDupSkip ? 'health-badge health-badge--dup' : (isWarning ? 'health-badge health-badge--warn' : 'health-badge health-badge--err')),
                        displayStatus: isDupSkip ? this.lbl.healthDupBadge : l.status,
                        showDetail:    l.id === this.expandedLogId,
                        canReprocess:  l.hasPayload === true && hasSettingsAccess === true,
                        formattedDate: l.occurredAt ? this._dateTime(l.occurredAt) : '',
                        formattedAmount: l.amount != null ? this._money(l.amount) : '',
                    };
                });
            })
            .catch(err => { console.error('getWebhookLogs error', err); })
            .finally(() => { this.isLoadingLogs = false; });
    }

    handleHealthRefresh() {
        this.loadHealthData();
    }

    handleHealthLogFilterChange(event) {
        this.healthLogFilter = event.target.value;
        this.loadHealthLogs();
    }

    handleHealthLogSearch(event) {
        this.healthLogSearch = event.target.value;
        clearTimeout(this._healthLogSearchTimer);
        this._healthLogSearchTimer = setTimeout(() => { this.loadHealthLogs(); }, 400);
    }

    handleToggleLogDetail(event) {
        const id = event.currentTarget.dataset.id;
        this.expandedLogId = this.expandedLogId === id ? null : id;
        this.webhookLogs = this.webhookLogs.map(l => ({ ...l, showDetail: l.id === this.expandedLogId }));
    }

    handleCopyGapDate() {
        const txt = this._healthGapDateForCopy();
        if (!txt) return;
        navigator.clipboard.writeText(txt).then(() => {
            this.dispatchEvent(new ShowToastEvent({ title: '', message: txt + ' copied', variant: 'success' }));
        }).catch(() => {});
    }

    // ── Settings handlers — Notifications ─────────────────────────────────────
    // ── My Tasks tab ──────────────────────────────────────────────────────────
    handleMyTasksTab() {
        this.activeMainTab = 'mytasks';
        this.loadMyTasks();
    }

    loadMyTasks() {
        this.isMyTasksLoading = true;
        getMyTasks()
            .then(result => {
                this.myTasks          = result || [];
                this.isMyTasksLoading = false;
            })
            .catch(err => {
                this.isMyTasksLoading = false;
                this.showToast('Error loading tasks', this.extractError(err), 'error');
            });
    }

    handleTaskClick(event) {
        const ticketId = event.currentTarget.dataset.ticketid;
        if (!ticketId) return;
        this.activeMainTab = 'list';
        if (this.tickets && this.tickets.length > 0) {
            this._openTicketById(ticketId);
        } else {
            this.isLoading = true;
            getTickets({ statusFilter: 'All' })
                .then(result => {
                    this.tickets = result;
                    this.isLoading = false;
                    this._openTicketById(ticketId);
                })
                .catch(() => {
                    this.isLoading = false;
                    this._openTicketById(ticketId);
                });
        }
    }

    // ── Settings handlers — Language ───────────────────────────────────────────
    handleLanguageChange(event) {
        const lang = event.detail.value;
        this._setLanguage(lang);
        saveLanguage({ language: lang })
            .catch(err => console.error('Error saving language', this.extractError(err)));
    }

    handleLangPillClick(event) {
        const lang = event.currentTarget.dataset.lang;
        if (!lang || lang === this.currentLanguage) return;
        this._setLanguage(lang);
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
        if (!this.selectedTicketId) return;
        this.isAssigning = true;

        if (this.canClearAssignment) {
            clearTicketAssignment({ ticketId: this.selectedTicketId })
                .then(() => {
                    this.isAssigning = false;
                    this.showToast('Assignment removed', 'The personal follow-up assignment was cleared.', 'success');
                    this.showAssignModal = false;
                    this.handleClearAssignOwner();
                    this.loadDetail();
                    this.loadTickets();
                    this.loadMyTasks();
                })
                .catch(err => {
                    this.isAssigning = false;
                    this.showToast('Error', this.extractError(err), 'error');
                });
            return;
        }

        if (!this.assignOwnerId) return;
        assignTicket({
            ticketId:  this.selectedTicketId,
            ownerId:   this.assignOwnerId,
            ownerName: this.assignOwnerName,
            dueDays:   this.assignDueDays,
            note:      this.assignNote,
        })
            .then(() => {
                this.isAssigning = false;
                this.showToast('Task assigned', this.currentLanguage === 'fr'
                    ? 'Une tâche personnelle a été créée pour ' + this.assignOwnerName + '. La tâche automatique globale (s\'il y en avait une) a été annulée.'
                    : 'A personal task was created for ' + this.assignOwnerName + '. The global auto-task (if any) was cancelled.', 'success');
                this.showAssignModal = false;
                this.handleClearAssignOwner();
                this.assignNote = '';
                this.assignDueDays = 3;
                this.loadDetail();
                this.loadTickets();
                this.loadMyTasks();
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

    // ── Event toggle handlers ─────────────────────────────────────────────────
    handleEvtPaymentCreatedToggle(e)  { this.evtPaymentCreated = e.detail.checked; }
    handleEvtPaymentUpdatedToggle(e)       { this.evtPaymentUpdated       = e.detail.checked; }
    handleEvtPaymentDeletedToggle(e)       { this.evtPaymentDeleted       = e.detail.checked; }
    handleEvtContactEventsToggle(e)        { this.evtContactEvents        = e.detail.checked; }
    handleEvtHoldingExpireToggle(e)        { this.evtHoldingExpireEnabled = e.detail.checked; }
    handleEvtHoldingExpireDaysChange(e)    { this.evtHoldingExpireDays    = parseInt(e.detail.value, 10) || 10; }

    // ── Settings handlers — Ticket actions (admin only) ───────────────────────
    handleShowFollowupToggle(e) { this.showFollowupSetting = e.detail.checked; }

    handleSaveTicketActions() {
        this.isSavingTicketActions = true;
        saveTicketActions({ showFollowup: this.showFollowupSetting })
            .then(() => {
                this.isSavingTicketActions = false;
                this.showToast(this.lbl.savedToast, this.lbl.savedTicketActionsToast, 'success');
                if (!this.showFollowupSetting && this.statusFilter === 'Assigned') {
                    this.statusFilter = 'Open';
                    this._listPage = 1;
                    this.loadTickets();
                }
            })
            .catch(err => {
                this.isSavingTicketActions = false;
                this.showToast('Error', this.extractError(err), 'error');
                this.loadSettings();
            });
    }

    handleSaveEventToggles() {
        saveEventToggles({
            processPaymentCreated:  this.evtPaymentCreated,
            processPaymentUpdated:  this.evtPaymentUpdated,
            processPaymentDeleted:  this.evtPaymentDeleted,
            processContactEvents:   this.evtContactEvents,
            holdingExpireEnabled:   this.evtHoldingExpireEnabled,
            holdingExpireDays:      this.evtHoldingExpireDays,
        })
            .then(() => {
                this.showToast(this.lbl.savedToast, this.lbl.savedEventsToast, 'success');
                this.loadLanguage(); // refresh banner state
            })
            .catch(err => this.showToast('Error', this.extractError(err), 'error'));
    }

    // One-click re-enable from the banner — keeps every other saved event toggle as is
    handleReenableHoldingExpire() {
        this.isReenablingExpire = true;
        loadConfig()
            .then(r => saveEventToggles({
                processPaymentCreated: r.processPaymentCreated === 'true',
                processPaymentUpdated: r.processPaymentUpdated !== 'false',
                processPaymentDeleted: r.processPaymentDeleted !== 'false',
                processContactEvents:  r.processContactEvents  === 'true',
                holdingExpireEnabled:  true,
                holdingExpireDays:     parseInt(r.holdingExpireDays, 10) || 10,
            }))
            .then(() => {
                this.isReenablingExpire = false;
                this.holdingExpireOn = true;
                this.holdingExpireDisabledAt = null;
                this.evtHoldingExpireEnabled = true;
                this.showToast(this.lbl.savedToast, this.lbl.expireOffOnToast, 'success');
            })
            .catch(err => {
                this.isReenablingExpire = false;
                this.showToast('Error', this.extractError(err), 'error');
            });
    }

    // ── Transaction timeline modal ─────────────────────────────────────────────
    handleOpenTimeline(event) {
        const txId  = event.currentTarget.dataset.txid;
        const name  = event.currentTarget.dataset.name || '';
        if (!txId) return;
        this.showTimeline    = true;
        this.timelineLoading = true;
        this.timelineEntries = [];
        this.timelineTicketName = name;
        getTransactionTimeline({ transactionId: txId })
            .then(result => {
                this.timelineEntries = result;
                this.timelineLoading = false;
            })
            .catch(err => {
                this.timelineLoading = false;
                console.error('getTransactionTimeline error', err);
            });
    }

    handleCloseTimeline() { this.showTimeline = false; }

    // ── Settings handlers — App settings save ─────────────────────────────────
    handleModalSave() {
        if (this.settingsSection === 'credentials') {
            this.handleSaveSettings();
        } else if (this.settingsSection === 'events') {
            this.handleSaveEventToggles();
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
    handleSettingsApiKeyChange(event)     { this.settingsApiKey    = event.detail.value; }
    handleSettingsSecretChange(event)     { this.settingsSecret    = event.detail.value; }
    handleSettingsActiveChange(event)     { this.settingsIsActive  = event.detail.checked; }
    handleSettingsWebhookUrlChange(event) { this.settingsWebhookUrl = event.detail.value; }

    handleSaveSettings() {
        this.isSavingSettings = true;
        saveConfig({
            apiKey:             this.settingsApiKey,
            webhookSecret:      this.settingsSecret,
            isActive:           this.settingsIsActive,
            webhookEndpointUrl: this.settingsWebhookUrl,
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

    handleOpenTestModal()  { this.showTestModal = true;  this.testWebhookResult = null; }
    handleCloseTestModal() { this.showTestModal = false; this.testWebhookResult = null; }

    handleTestWebhookEventChange(event) { this.testWebhookEvent = event.detail.value; }

    handleSendTestWebhook() {
        this.isSendingTest     = true;
        this.testWebhookResult = null;
        sendTestWebhook({ eventType: this.testWebhookEvent })
            .then(result => {
                this.isSendingTest     = false;
                this.testWebhookResult = result;
            })
            .catch(err => {
                this.isSendingTest     = false;
                this.testWebhookResult = { success: false, message: this.extractError(err) };
            });
    }

    // ── Undo handlers ──────────────────────────────────────────────────────────
    handleUndo()       { this.showUndoConfirm = true; }
    handleCancelUndo() { this.showUndoConfirm = false; }

    // What the undo removed / kept, in the staff's language
    _undoSummaryText(r) {
        const fr = this.currentLanguage === 'fr';
        const parts = [];
        if (r.giftDeleted)       parts.push(fr ? 'Don (GiftTransaction) supprimé' : 'Gift (GiftTransaction) deleted');
        if (r.commitmentDeleted) parts.push(fr ? 'engagement récurrent supprimé' : 'recurring commitment deleted');
        if (r.commitmentKept)    parts.push(fr ? 'engagement récurrent conservé (' + r.commitmentKept + ' autre(s) versement(s))'
                                               : 'recurring commitment kept (' + r.commitmentKept + ' other installment(s))');
        if (r.campaignDeleted)   parts.push(fr ? 'campagne « ' + r.campaignDeleted + ' » supprimée'
                                               : 'campaign "' + r.campaignDeleted + '" deleted');
        if (r.identityRemoved)   parts.push(fr ? 'lien Zeffy ID ' + r.identityRemoved + ' retiré'
                                               : 'Zeffy ID link ' + r.identityRemoved + ' removed');
        if (r.accountKept)       parts.push(fr ? 'compte « ' + r.accountKept + ' » conservé (à supprimer manuellement si créé par erreur)'
                                               : 'account "' + r.accountKept + '" kept (delete it manually if it was created by mistake)');
        const head = fr ? 'Billet rouvert. ' : 'Ticket reopened. ';
        return head + (parts.length ? parts.join(' · ') + '.' : '');
    }

    handleConfirmUndo() {
        this.showUndoConfirm = false;
        undoResolution({ ticketId: this.selectedTicketId })
            .then(summary => {
                this.showToast(this.lbl.undoneTitle, this._undoSummaryText(summary || {}), 'success');
                this.resetResolutionState();
                this.loadDetail();
                this.loadTickets();
                this.loadDashboardStats();
                this.loadAuditLog();
                this.loadDonationHistory();
            })
            .catch(err => this.showToast('Error', this.extractError(err), 'error'));
    }

    // ── Reassign Zeffy ID wizard ───────────────────────────────────────────────
    // Moves everything of ONE Zeffy ID from the linked account to the right one (gifts are rebuilt
    // on the new account in batches of 200; Apex polls report progress).
    get showZeffyIdRow() { return !!(this.ticket && this.ticket.Zeffy_Contact_Id__c && this.ticket.Resolved_Account__r); }
    get canReassign()    { return this.showZeffyIdRow && this.canUndo; }

    _raFmt(text, vals) {
        let out = text || '';
        Object.keys(vals || {}).forEach(k => { out = out.split('{' + k + '}').join(vals[k]); });
        return out;
    }
    _raNum(n) { return new Intl.NumberFormat(this._locale).format(Number(n || 0)); }

    handleOpenReassign() {
        clearInterval(this._raPollTimer);
        this.raOpen = true;
        this.raStep = 1;
        this.raPreview = null;
        this.raResults = [];
        this.raChosen = null;
        this.raLogs = [];
        this.raSearchTerm = '';
        this.raAck = false;
        this.raRunning = false;
        this.raDone = false;
        this.raError = null;
        this.raRemaining = null;
        getReassignPreview({ ticketId: this.selectedTicketId })
            .then(p => {
                this.raPreview = p;
                this._raFromAccountId = p.fromAccountId;
            })
            .catch(err => {
                this.raOpen = false;
                this.showToast('Error', this.extractError(err), 'error');
            });
    }

    handleRaClose() {
        clearInterval(this._raPollTimer);
        clearTimeout(this._raSearchTimer);
        const changed = this.raDone || this.raRunning;
        this.raOpen = false;
        this.raRunning = false;
        if (changed) this._raReload();
    }

    _raReload() {
        this.loadDetail();
        this.loadTickets();
        this.loadDashboardStats();
        this.loadAuditLog();
        this.loadDonationHistory();
    }

    handleRaBack() { if (this.raStep > 1) this.raStep -= 1; }

    handleRaNext() {
        if (this.raStep < 3) { this.raStep += 1; return; }
        if (this.raDone) { this.handleRaClose(); return; }
        this._raStart();
    }

    handleRaSearch(e) {
        const term = e.target.value;
        this.raSearchTerm = term;
        clearTimeout(this._raSearchTimer);
        if (!term || term.trim().length < 2) { this.raResults = []; return; }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._raSearchTimer = setTimeout(() => {
            this.raSearching = true;
            searchReassignAccounts({ ticketId: this.selectedTicketId, searchTerm: term })
                .then(rows => { this.raResults = rows || []; })
                .catch(err => this.showToast('Error', this.extractError(err), 'error'))
                .finally(() => { this.raSearching = false; });
        }, 300);
    }

    handleRaPick(e) {
        const id = e.currentTarget.dataset.id;
        if (!id || id === this._raFromAccountId) return;
        this.raChosen = this.raResults.find(r => r.id === id) || null;
        this.raAck = false;
    }

    handleRaAck(e) { this.raAck = e.target.checked; }

    _raStart() {
        this.raRunning = true;
        this.raError = null;
        reassignZeffyId({ ticketId: this.selectedTicketId, targetAccountId: this.raChosen.id })
            .then(r => {
                this._raStartedAt = r.startedAt;
                this.raRemaining = r.remaining;
                this._raPoll();
                if (r.remaining > 0) {
                    // eslint-disable-next-line @lwc/lwc/no-async-operation
                    this._raPollTimer = setInterval(() => this._raPoll(), 3000);
                }
            })
            .catch(err => {
                this.raRunning = false;
                this.raError = this.extractError(err);
            });
    }

    _raPoll() {
        getReassignProgress({
            ticketId: this.selectedTicketId, fromAccountId: this._raFromAccountId, sinceMillis: this._raStartedAt
        })
            .then(p => {
                this.raRemaining = p.remaining;
                if (p.status === 'failed') {
                    clearInterval(this._raPollTimer);
                    this.raRunning = false;
                    this.raError = this.lbl.raFailed + (p.error ? ' (' + p.error + ')' : '');
                } else if (p.status === 'done') {
                    clearInterval(this._raPollTimer);
                    this.raRunning = false;
                    this.raDone = true;
                    this.raLogs = (p.logs || []).map((l, i) => this._raLogRow(l, i));
                    this.raLogCount = p.logCount || 0;
                    this.showToast(this.lbl.raToastDone, '', 'success');
                }
            })
            .catch(err => {
                clearInterval(this._raPollTimer);
                this.raRunning = false;
                this.raError = this.extractError(err);
            });
    }

    // Notes are "record: oldId → newId" (gift), "record: id" (recurring) or "Zeffy ID x: A → B." (summary)
    _raLogRow(l, i) {
        const notes = l.notes || '';
        let record = notes, oldV = '', newV = '';
        const sum = notes.match(/^Zeffy ID (\S+): (.+?) → (.+?)\.(\s|$)/);
        const arrow = notes.match(/^(.*): (\S+) → (\S+)$/);
        const plain = notes.match(/^(.*): (\S+)$/);
        if (sum) { record = sum[1].length > 13 ? sum[1].slice(0, 8) + '…' + sum[1].slice(-4) : sum[1]; oldV = sum[2]; newV = sum[3]; }
        else if (arrow) { record = arrow[1]; oldV = arrow[2]; newV = arrow[3]; }
        else if (plain) { record = plain[1]; oldV = plain[2]; newV = this.currentLanguage === 'fr' ? 'identique' : 'same'; }
        return { key: 'ra' + i, action: this._actionLabel(l.action), record, oldV, newV, by: l.by || '' };
    }

    get raLoadingPreview() { return this.raOpen && !this.raPreview; }
    get raIsStep1() { return this.raStep === 1; }
    get raIsStep2() { return this.raStep === 2; }
    get raIsStep3() { return this.raStep === 3; }
    get raShowConfirm() { return this.raIsStep3 && !this.raRunning && !this.raDone; }
    get raShowRun()     { return this.raIsStep3 && this.raRunning; }
    get raShowDone()    { return this.raIsStep3 && this.raDone; }
    get raSteps() {
        const l = this.lbl;
        return [l.raStep1, l.raStep2, l.raStep3].map((label, i) => {
            const n = i + 1;
            const done = n < this.raStep || this.raDone;
            const on = n === this.raStep && !this.raDone;
            return { key: 'rs' + n, label, dot: done ? '✓' : String(n),
                cls: 'ra-step' + (on ? ' ra-step--on' : '') + (done ? ' ra-step--done' : '') };
        });
    }
    get raFromName() { return this.raPreview && this.raPreview.fromAccount ? this.raPreview.fromAccount.name : ''; }
    get raToName()   { return this.raChosen ? this.raChosen.name : ''; }
    get raGiftCount()      { return this.raPreview ? this.raPreview.giftCount : 0; }
    get raGiftCountFmt()   { return this._raNum(this.raGiftCount); }
    get raGiftTotalFmt()   { return this.raPreview ? this._money(this.raPreview.giftTotal) : ''; }
    get raRecurringFmt()   { return this._raNum(this.raPreview && this.raPreview.recurringCount); }
    get raTicketFmt()      { return this._raNum(this.raPreview && this.raPreview.ticketCount); }
    get raRefundFmt()      { return this._raNum(this.raPreview && this.raPreview.refundCount); }
    get raGiftsLabel()     { return this.lbl.raGifts + ' · ' + this.raGiftTotalFmt; }
    get raStaysTitle()     { return this._raFmt(this.lbl.raStaysWith, { name: this.raFromName }); }
    get raOtherIds() {
        const ids = (this.raPreview && this.raPreview.otherIds) || [];
        return ids.map(o => ({ key: o.zeffyId, zeffyId: o.zeffyId, text: this._raFmt(this.lbl.raOtherId, { n: this._raNum(o.gifts) }) }));
    }
    get raHasManual()      { return !!(this.raPreview && this.raPreview.manualGifts > 0); }
    get raManualText()     { return this._raFmt(this.lbl.raGiftsN, { n: this._raNum(this.raPreview && this.raPreview.manualGifts) }); }
    get raNothingStays()   { return this.raOtherIds.length === 0 && !this.raHasManual; }
    get raBlockedText() {
        const n = this.raPreview ? this.raPreview.blockedCount : 0;
        return n > 0 ? this._raFmt(this.lbl.raBlocked, { n: this._raNum(n), name: this.raFromName }) : null;
    }
    get raResultRows() {
        return (this.raResults || []).map(r => {
            const isSame = r.id === this._raFromAccountId;
            const isSel = this.raChosen && this.raChosen.id === r.id;
            const sub = [r.email || r.kind, r.city].filter(x => x).join(' · ');
            return { ...r, sub, isSame, disabled: isSame,
                cls: 'ra-acct' + (isSame ? ' ra-acct--same' : '') + (isSel ? ' ra-acct--sel' : '') };
        });
    }
    get raNoResults() { return !this.raSearching && this.raSearchTerm && this.raSearchTerm.trim().length >= 2 && this.raResults.length === 0; }
    get raFrom() { return (this.raPreview && this.raPreview.fromAccount) || {}; }
    get raHasMatch() { return !!(this.raChosen && (this.raChosen.emailMatch || this.raChosen.addressMatch)); }
    get raSummary() {
        const l = this.lbl;
        const p = this.raPreview || {};
        const to = this.raToName;
        const from = this.raFromName;
        const ok = 'ra-check ra-check--do';
        const items = [];
        if (p.giftCount > 0) items.push({ key: 'g', cls: ok, icon: 'utility:check', pre: l.raSumRebuild,
            bold: this._raFmt(l.raSumGifts, { n: this.raGiftCountFmt, amt: this.raGiftTotalFmt }), mid: l.raSumOn,
            bold2: to, post: this._raFmt(l.raSumRemoveFrom, { name: from }) });
        if (p.recurringCount > 0) items.push({ key: 'r', cls: ok, icon: 'utility:check', pre: l.raSumMove,
            bold: this._raFmt(l.raSumRecurring, { n: this.raRecurringFmt }), mid: l.raSumTo, bold2: to, post: '' });
        if (p.ticketCount > 0) items.push({ key: 't', cls: ok, icon: 'utility:check', pre: l.raSumPoint,
            bold: this._raFmt(l.raSumTickets, { n: this.raTicketFmt }), mid: l.raSumTicketsPost, bold2: '', post: '' });
        items.push({ key: 'f', cls: ok, icon: 'utility:check', pre: l.raSumFuture, bold: to, mid: '', bold2: '', post: '' });
        const keep = 'ra-check';
        if (this.raOtherIds.length) items.push({ key: 'ki', cls: keep, icon: 'utility:dash',
            pre: this._raFmt(l.raSumKeepIds, { name: from, n: this.raOtherIds.length }), bold: '', mid: '', bold2: '', post: '' });
        if (this.raHasManual) items.push({ key: 'km', cls: keep, icon: 'utility:dash',
            pre: this._raFmt(l.raSumKeepManual, { name: from, n: this._raNum(p.manualGifts) }), bold: '', mid: '', bold2: '', post: '' });
        if (p.blockedCount > 0) items.push({ key: 'kb', cls: keep, icon: 'utility:dash',
            pre: this.raBlockedText, bold: '', mid: '', bold2: '', post: '' });
        return items;
    }
    get raShowBackground() { return this.raGiftCount > 200; }
    get raBgBody() { return this._raFmt(this.lbl.raBgBody, { n: this.raGiftCountFmt }); }
    get raTotalTickets() {
        const p = this.raPreview || {};
        return Math.max(1, (p.ticketCount || 0));
    }
    get raDoneCount() {
        const rem = this.raRemaining == null ? this.raTotalTickets : this.raRemaining;
        return Math.max(0, this.raTotalTickets - rem);
    }
    get raBarStyle() { return 'width:' + Math.round(this.raDoneCount * 100 / this.raTotalTickets) + '%'; }
    get raProgressText() {
        return this._raFmt(this.lbl.raProgress, { done: this._raNum(this.raDoneCount), total: this._raNum(this.raTotalTickets) });
    }
    get raDoneBody() {
        return this._raFmt(this.lbl.raDoneBody, { g: this.raGiftCountFmt, r: this.raRecurringFmt, t: this.raTicketFmt, name: this.raToName });
    }
    get raMoreRows() {
        const more = this.raLogCount - this.raLogs.length;
        return more > 0 ? this._raFmt(this.lbl.raMoreRows, { n: this._raNum(more) }) : null;
    }
    get raHasLogs() { return this.raLogs.length > 0; }
    get raShowBack()   { return this.raStep > 1 && !this.raRunning && !this.raDone; }
    get raShowCancel() { return !this.raRunning && !this.raDone; }
    get raNextLabel() {
        const l = this.lbl;
        if (this.raStep === 1) return l.raNextChoose;
        if (this.raStep === 2) return l.raNextReview;
        if (this.raDone) return l.raClose;
        if (this.raRunning) return l.raWorking;
        const n = this.raGiftCount;
        return n === 0 ? l.raDoBtnNone : (n === 1 ? l.raDoBtnOne : this._raFmt(l.raDoBtn, { n: this.raGiftCountFmt }));
    }
    get raNextDisabled() {
        if (!this.raPreview) return true;
        if (this.raStep === 2) return !this.raChosen;
        if (this.raStep === 3 && !this.raDone) return this.raRunning || !this.raAck;
        return false;
    }

    disconnectedCallback() {
        clearInterval(this._raPollTimer);
        clearTimeout(this._raSearchTimer);
    }

    // ── Holding / Delayed / Payment Failed actions ─────────────────────────────
    handleMoveToReview() {
        moveTicketToReview({ ticketId: this.selectedTicketId, notes: null })
            .then(() => {
                this.showToast(this.lbl.moveReviewToast, '', 'success');
                this.loadDetail();
                this.loadTickets();
                this.loadAuditLog();
                this.loadDashboardStats();
            })
            .catch(err => this.showToast('Error', this.extractError(err), 'error'));
    }
    handleReturnToWaiting() {
        const prev = this.ticket.Pre_Review_Status__c === 'Delayed' ? this.lbl.statusDelayed : this.lbl.statusHolding;
        returnTicketToWaiting({ ticketId: this.selectedTicketId })
            .then(() => {
                this.showToast(this.lbl.returnWaitingToast.replace('{0}', prev), '', 'success');
                this.loadDetail();
                this.loadTickets();
                this.loadAuditLog();
                this.loadDashboardStats();
            })
            .catch(err => this.showToast('Error', this.extractError(err), 'error'));
    }
    handleOpenCloseConfirm()   { this.closeConfirmNotes = ''; this.showCloseConfirm = true; }
    handleCancelCloseConfirm() { this.showCloseConfirm = false; }
    handleCloseConfirmNotes(event) { this.closeConfirmNotes = event.target.value; }
    handleConfirmCloseTicket() {
        const reason = (this.closeConfirmNotes || '').trim() || null;
        closeTicket({ ticketId: this.selectedTicketId, reason })
            .then(() => {
                this.showCloseConfirm = false;
                this.showToast(this.lbl.closedToast, '', 'success');
                this.afterResolve();
            })
            .catch(err => this.showToast('Error', this.extractError(err), 'error'));
    }

    // ── Webhook log: reprocess a stored payload ────────────────────────────────
    async handleReprocessLog(event) {
        const logId = event.currentTarget.dataset.id;
        const ok = await LightningConfirm.open({ label: this.lbl.btnReprocess, message: this.lbl.reprocessConfirm, theme: 'default' });
        if (!ok) return;
        reprocessWebhookLog({ logId })
            .then(r => {
                const variant = r.status === 'SUCCESS' || r.status === 'DUPLICATE_SKIPPED' ? 'success' : 'warning';
                this.showToast(this.lbl.reprocessToast.replace('{status}', r.status), r.message || '', variant);
                this.loadHealthLogs();
                this.loadTickets();
            })
            .catch(err => this.showToast('Error', this.extractError(err), 'error'));
    }

    // ── Bulk resolve ───────────────────────────────────────────────────────────
    get bulkGroupTicketList() {
        return this._bulkGroupTickets.map(t => {
            const nameParts = [t.First_Name__c, t.Last_Name__c].filter(Boolean);
            const name = t.Company_Name__c || (nameParts.length > 0 ? nameParts.join(' ') : '—');
            const amt  = this._money(t.Amount__c, t.Currency__c);
            return { id: t.Id, name: t.Name, donor: name, amount: amt, status: t.Status__c };
        });
    }
    // Group summary for step 1: the group always shares one Zeffy ID (that is how the list
    // groups it); what can differ is the name/email typed on each donation — show only that.
    _bulkVariants(valueOf, emptyLabel) {
        const byKey = new Map();
        for (const t of this._bulkGroupTickets) {
            const raw = (valueOf(t) || '').trim();
            const key = this._norm(raw).replace(/\s+/g, ' ');
            const v = byKey.get(key) || { key, value: raw, count: 0 };
            v.count++;
            byKey.set(key, v);
        }
        return [...byKey.values()]
            .sort((a, b) => b.count - a.count)
            .map(v => ({ key: v.key || '∅', raw: v.value, value: v.value || emptyLabel || this.lbl.bulkVarNoEmail, count: '×' + v.count }));
    }
    // Same order as bulkHeadName: the person's name first, the company only when there is none
    get bulkNameVariants() {
        return this._bulkVariants(t => [t.First_Name__c, t.Last_Name__c].filter(Boolean).join(' ') || t.Company_Name__c, '—');
    }
    get bulkEmailVariants() { return this._bulkVariants(t => t.Email__c); }
    get bulkAddrVariants()  {
        return this._bulkVariants(t => this._bgAddrText(this._bgAddrParts(t)), this.lbl.bulkVarNoAddr);
    }
    get bulkIdSameText()    { return this.lbl.bulkIdSame.replace('{n}', this._bulkGroupTickets.length); }
    get bulkHasVariations() { return this.bulkNamesVary || this.bulkEmailsVary || this.bulkAddrsVary; }
    get bulkNamesVary()     { return this.bulkNameVariants.length > 1; }
    get bulkEmailsVary()    { return this.bulkEmailVariants.length > 1; }
    get bulkAddrsVary()     { return this.bulkAddrVariants.length > 1; }
    // Donor box shows only the most used value; the others are under "See differences"
    _bulkMainValue(variants) { const v = variants.find(x => x.raw); return v ? v.raw : ''; }
    get bulkMainName()  { return this._bulkMainValue(this.bulkNameVariants) || this.bulkHeadName; }
    get bulkMainEmail() { return this._bulkMainValue(this.bulkEmailVariants); }
    get bulkMainAddr()  { return this._bulkMainValue(this.bulkAddrVariants); }
    get bulkVarToggleLabel() { return this._bulkVariationsOpen ? this.lbl.bulkVarHide + ' ▴' : this.lbl.bulkVarShow + ' ▾'; }
    get bulkVarOpenStr() { return String(this._bulkVariationsOpen); }
    handleBulkToggleVariations() { this._bulkVariationsOpen = !this._bulkVariationsOpen; }

    get bulkPendingTickets() {
        return this._bulkGroupTickets.filter(t => t.Status__c === 'Pending Review');
    }
    get bulkPendingCount() { return this.bulkPendingTickets.length; }
    get bulkConfirmLabel() {
        return (this.lbl.bulkConfirmBtn || 'Resolve {n} tickets').replace('{n}', this.bulkPendingCount);
    }
    get bulkSelectedAcctDisplay() {
        return this._bulkSelectedAcctName || (this._bgPreview && this._bgPreview.accountName) || '—';
    }
    get isBulkStep1() { return this.bulkStep === 1; }
    get isBulkStep2() { return this.bulkStep === 2; }
    get isBulkLinkMode()   { return this.bulkMode === 'link'; }
    get isBulkCreateMode() { return this.bulkMode === 'create'; }
    get isBulkLinkModeStr()   { return String(this.isBulkLinkMode); }
    get isBulkCreateModeStr() { return String(this.isBulkCreateMode); }
    get bulkModeLinkClass()   { return 'wiz-mode-card' + (this.isBulkLinkMode   ? ' wiz-mode-card--active' : ''); }
    get bulkModeCreateClass() { return 'wiz-mode-card' + (this.isBulkCreateMode ? ' wiz-mode-card--active' : ''); }
    get bulkStep1Class()      { return 'wiz-step' + (this.bulkStep >= 1 ? ' wiz-step--active' : ''); }
    get bulkStep2Class()      { return 'wiz-step' + (this.bulkStep >= 2 ? ' wiz-step--active' : ''); }
    // "Possible matches for" uses the ticket the candidates were searched with (first pending one)
    get _bulkHeadTicket()     { return this.bulkPendingTickets[0] || this._bulkGroupTickets[0]; }
    get bulkHeadName() {
        const t = this._bulkHeadTicket;
        if (!t) return '';
        const nameParts = [t.First_Name__c, t.Last_Name__c].filter(Boolean);
        return nameParts.length > 0 ? nameParts.join(' ') : (t.Company_Name__c || '—');
    }
    get bulkHeadEmail() { const t = this._bulkHeadTicket; return t ? t.Email__c : ''; }
    handleBulkModeChange(event) {
        const mode = event.currentTarget.dataset.mode;
        if (mode === this.bulkMode) return;
        this.bulkMode              = mode;
        this._bulkListOpen         = true;
        this._bulkSelectedAcctId   = null;
        this._bulkSelectedAcctName = '';
        this._bulkCandidates = this._bulkCandidates.map(c => ({ ...c, cardClass: 'candidate-card' }));
    }
    get bulkCreateBtnClassIndividual() { return 'create-type-btn' + (this._bulkCreateType === 'individual' ? ' create-type-btn--active' : ''); }
    get bulkCreateBtnClassOrg()        { return 'create-type-btn' + (this._bulkCreateType === 'org'        ? ' create-type-btn--active' : ''); }
    get bulkCreateBtnClassEglise()     { return 'create-type-btn' + (this._bulkCreateType === 'eglise'     ? ' create-type-btn--active' : ''); }
    get bulkCreateBtnClassBusiness()   { return 'create-type-btn' + (this._bulkCreateType === 'business'   ? ' create-type-btn--active' : ''); }
    get bulkStep2IsReady()  { return this.isBulkLinkMode ? !!this._bulkSelectedAcctId : true; }
    // The whole group must be loaded first: step 2 shows the emails and addresses of every ticket
    get isBulkNextDisabled()    { return !this.bulkStep2IsReady || this._bulkLoadingCandidates; }
    get isBulkConfirmDisabled() {
        return this._isBulkResolving || !this.bulkStep2IsReady || this.bulkPendingCount === 0
            || (this.isBulkLinkMode && (this._bgLoading || !this._bgPreview || this.bgInvalidEmail));
    }

    handleBulkResolveGroup(event) {
        const cid = event.currentTarget.dataset.cid;
        if (!cid || this._isBulkResolving) return; // a group is still being sent
        this._bulkGroupCid         = cid;
        this._bulkGroupTickets     = (this.tickets || []).filter(t => t.Zeffy_Contact_Id__c === cid);
        this._bulkSelectedAcctId   = null;
        this._bulkSelectedAcctName = '';
        this._bulkCreateType       = 'individual';
        this._bulkCandidates       = [];
        this._bulkNotes            = '';
        this._bulkVariationsOpen   = false;
        this._bulkListOpen         = true;
        this._bgPreview            = null;
        this.bulkStep              = 1;
        this.bulkMode              = 'link';
        this._isBulkResolving      = false;
        this.showBulkModal         = true;
        this._bulkLoadingCandidates = true;
        // The list only holds what the current filter shows: load every ticket of this Zeffy ID
        getGroupTickets({ zeffyContactId: cid })
            .then(rows => {
                if (cid !== this._bulkGroupCid) return; // another group was opened meanwhile
                if (rows && rows.length) this._bulkGroupTickets = rows;
            })
            .catch(() => { /* keep the tickets the list already had */ })
            .finally(() => { if (cid === this._bulkGroupCid) this._bulkLoadMatches(cid); });
    }
    _bulkLoadMatches(cid) {
        const headTicket = this.bulkPendingTickets[0];
        if (!headTicket) { this._bulkLoadingCandidates = false; return; }
        findAccountMatches({ ticketId: headTicket.Id })
            .then(res => {
                if (cid !== this._bulkGroupCid) return;
                this._bulkCandidates = (res || []).map(c => ({
                    ...c,
                    cardClass: 'candidate-card' + (this._bulkSelectedAcctId === c.id ? ' candidate-card--selected' : ''),
                    badgeClass: 'candidate-badge candidate-badge--score candidate-badge--' + ((c.score || 0) >= 80 ? 'high' : (c.score || 0) >= 50 ? 'mid' : 'low'),
                    scoreLabel: (c.score || 0) + '%',
                }));
            })
            .catch(() => { if (cid === this._bulkGroupCid) this._bulkCandidates = []; })
            .finally(() => { if (cid === this._bulkGroupCid) this._bulkLoadingCandidates = false; });
    }
    handleCloseBulkModal() {
        if (this._isBulkResolving) return; // closing mid-way would hide which tickets were sent
        this.showBulkModal = false;
    }
    get bulkResolving() { return this._isBulkResolving; }
    get bulkProgressLabel() {
        const b = this._bulkBatch;
        return b ? this.lbl.bulkProgress.replace('{i}', b.i).replace('{n}', b.n) : '';
    }
    handleBulkCandidateSelect(event) {
        const id   = event.currentTarget.dataset.id;
        const name = event.currentTarget.dataset.name;
        this._bulkSelectedAcctId   = id;
        this._bulkSelectedAcctName = name;
        this.bulkMode = 'link';
        this._bulkListOpen = false;
        this._bulkCandidates = this._bulkCandidates.map(c => ({
            ...c,
            cardClass: 'candidate-card' + (c.id === id ? ' candidate-card--selected' : ''),
        }));
    }
    handleBulkAccountSelected(event) {
        const rec = event.detail && event.detail.recordId;
        if (rec) {
            const c = this._bulkCandidates.find(x => x.id === rec);
            this._bulkSelectedAcctId   = rec;
            this._bulkSelectedAcctName = c ? c.name : ''; // otherwise taken from the step-2 preview
            this.bulkMode = 'link';
            this._bulkListOpen = false;
        } else {
            this._bulkSelectedAcctId   = null;
            this._bulkSelectedAcctName = '';
            this._bulkListOpen = true;
        }
        this._bulkCandidates = this._bulkCandidates.map(c => ({
            ...c,
            cardClass: 'candidate-card' + (rec && c.id === rec ? ' candidate-card--selected' : ''),
        }));
    }
    // Once an account is picked, the matches list shrinks to that card so step 1 fits without scrolling
    get bulkListCollapsed() { return this.isBulkLinkMode && !!this._bulkSelectedAcctId && !this._bulkListOpen; }
    get bulkVisibleCandidates() {
        return this.bulkListCollapsed
            ? this._bulkCandidates.filter(c => c.id === this._bulkSelectedAcctId)
            : this._bulkCandidates;
    }
    get bulkHasVisibleCandidates() { return this.bulkVisibleCandidates.length > 0; }
    get bulkCandListClass() {
        return 'candidates-scroll-list' + (this.bulkListCollapsed ? ' candidates-scroll-list--compact' : '');
    }
    get bulkShowAllLabel() {
        return this.bulkListCollapsed
            ? this.lbl.bulkShowAllMatches.replace('{n}', this._bulkCandidates.length)
            : this.lbl.bulkShowFewer;
    }
    // Toggle between the picked card and the full list (only once an account from the list is picked)
    get bulkShowAllVisible() {
        if (!this.isBulkLinkMode || !this._bulkSelectedAcctId || !this._bulkCandidates.length) return false;
        return !this.bulkListCollapsed || this.bulkVisibleCandidates.length < this._bulkCandidates.length;
    }
    get bulkShowAllExpanded() { return this.bulkListCollapsed ? 'false' : 'true'; }
    handleBulkShowAllMatches() { this._bulkListOpen = !this._bulkListOpen; }
    // About to create a new account while a strong match already exists → warn about a duplicate
    get bulkDuplicateWarning() {
        if (!this.isBulkCreateMode || !this._bulkCandidates.length) return null;
        const best = this._bulkCandidates.reduce((a, c) => ((c.score || 0) > (a.score || 0) ? c : a));
        if ((best.score || 0) < 80) return null;
        return {
            id:   best.id,
            name: best.name,
            body: this.lbl.dupWarnBody.replace('{0}', best.name).replace('{1}', best.score),
            btn:  this.lbl.dupWarnUse.replace('{0}', best.name),
        };
    }
    handleBulkSelectCreateType(event) {
        this._bulkCreateType = event.currentTarget.dataset.type;
        this.bulkMode = 'create';
        this._bulkSelectedAcctId   = null;
        this._bulkSelectedAcctName = '';
        this._bulkCandidates = this._bulkCandidates.map(c => ({ ...c, cardClass: 'candidate-card' }));
    }
    handleBulkNext() {
        if (this.isBulkLinkMode && !this._bulkSelectedAcctId) return;
        this._bgShowAmounts = false;
        this._bgNotesOpen   = !!this._bulkNotes;
        if (this.isBulkLinkMode) this._bgInit();
        this.bulkStep = 2;
    }
    handleBulkBack() {
        if (this._isBulkResolving) return;
        this.bulkStep = 1;
    }
    handleBulkNotesChange(event) {
        this._bulkNotes = event.target.value;
    }

    // ── Group review (step 2, link mode) ───────────────────────────────────────
    get _bgTickets() { return this.bulkPendingTickets.length ? this.bulkPendingTickets : this._bulkGroupTickets; }
    _bgAddrParts(t) {
        return { street: t.Address__c || '', city: t.City__c || '', province: t.Province__c || '',
                 postalCode: t.Postal_Code__c || '', country: t.Country__c || '' };
    }
    _bgAddrText(a) {
        return [a.street, a.city, a.province, a.postalCode, a.country].filter(v => v && v.trim()).join(', ');
    }
    _bgNormAddr(v) { return (v || '').toLowerCase().replace(/[^a-z0-9\u00c0-\u017f]/g, ''); }

    _bgInit() {
        // Back then Next on the same account keeps what the reviewer already chose
        if (this._bgPreview && this._bgPreview.accountId === this._bulkSelectedAcctId) return;
        const tickets = this._bgTickets;
        // Distinct emails, most used first
        const em = new Map();
        tickets.forEach(t => {
            const raw = (t.Email__c || '').trim();
            if (!raw) return;
            const key = raw.toLowerCase();
            const e = em.get(key) || { key, orig: raw, value: raw, count: 0, editing: false };
            e.count++;
            em.set(key, e);
        });
        this._bgEmails = [...em.values()].sort((a, b) => b.count - a.count);
        // Distinct addresses; the one on the latest donation is the default
        const ad = new Map();
        let recentKey = null;
        let recentAt  = '';
        tickets.forEach(t => {
            const parts = this._bgAddrParts(t);
            const text  = this._bgAddrText(parts);
            if (!text) return;
            const key = this._bgNormAddr(text);
            const a = ad.get(key) || { key, ...parts, text, count: 0 };
            a.count++;
            ad.set(key, a);
            const at = String(t.Gift_Date__c || t.CreatedDate || '');
            if (at > recentAt) { recentAt = at; recentKey = key; }
        });
        this._bgAddrs   = [...ad.values()].sort((a, b) => b.count - a.count).map(a => ({ ...a, recent: ad.size > 1 && a.key === recentKey }));
        this._bgAddrKey = recentKey;
        this._bgAddrEditing = false;
        this._bgAddrEdit    = {};
        this._bgUpdateAddress = false;
        this._bgAssign      = {};
        this._bgActiveEmail = null;
        this._bgPreview     = null;
        const head = this._bulkHeadTicket;
        if (!head) return;
        this._bgLoading = true;
        const acctId = this._bulkSelectedAcctId;
        getLinkPreview({ ticketId: head.Id, accountId: acctId })
            .then(p => {
                if (acctId !== this._bulkSelectedAcctId) return; // the reviewer picked another account meanwhile
                this._bgPreview  = p;
                const first = this._bgEmails.find(e => !this._bgOnAccount(e.value));
                this._bgActiveEmail = first ? first.key : null;
            })
            .catch(err => { if (acctId === this._bulkSelectedAcctId) this.showToast('Error', this.extractError(err), 'error'); })
            // Only the latest request ends the loading state (an older one must not enable Confirm)
            .finally(() => { if (acctId === this._bulkSelectedAcctId) this._bgLoading = false; });
    }

    // Account email fields, main email (PersonEmail) first
    get _bgEmailOptions() {
        const opts = [...((this._bgPreview && this._bgPreview.emailFieldOptions) || [])];
        return opts.sort((a, b) => {
            if (a.value === 'PersonEmail') return -1;
            if (b.value === 'PersonEmail') return 1;
            return (a.label || '').localeCompare(b.label || '');
        });
    }
    get bgHasEmailFields() { return this._bgEmailOptions.length > 0; }
    _bgOnAccount(value) {
        const v = (value || '').trim().toLowerCase();
        return !!v && this._bgEmailOptions.some(o => (o.currentValue || '').toLowerCase() === v);
    }
    _bgEmailValid(v) { return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test((v || '').trim()); }
    _bgFieldOf(key) { return Object.keys(this._bgAssign).find(f => this._bgAssign[f] === key) || null; }
    _bgFieldLabel(api) { const o = this._bgEmailOptions.find(x => x.value === api); return o ? o.label : api; }

    get bgShowEmails() { return this._bgEmails.length > 0; }
    get bgEmailRows() {
        const multi = this._bgEmails.length > 1;
        return this._bgEmails.map(e => {
            const on     = this._bgOnAccount(e.value);
            const field  = this._bgFieldOf(e.key);
            const active = !on && this._bgActiveEmail === e.key;
            const invalid = e.editing && !this._bgEmailValid(e.value);
            return {
                key: e.key, value: e.value, editing: e.editing, invalid,
                count: multi ? '×' + e.count : '',
                chip: on ? { label: this.lbl.rvAlreadyOnAccount, cls: 'rv-chip rv-chip--same' } : null,
                assigned: field ? this.lbl.bgAssignedTo.replace('{field}', this._bgFieldLabel(field)) : '',
                checked: active ? 'true' : 'false',
                disabled: on,
                inputCls: invalid ? 'cmp-edit cmp-edit--invalid' : 'cmp-edit',
                cls: 'bg-opt' + (active ? ' bg-opt--on' : '') + (on ? ' bg-opt--same' : '') + (field ? ' bg-opt--assigned' : '')
            };
        });
    }
    get bgEmailBadge() {
        if (!this._bgEmails.length || !this._bgPreview) return null;
        return this._bgEmails.every(e => this._bgOnAccount(e.value))
            ? { label: this.lbl.bgAllEmailsOn, cls: 'rv-chip rv-chip--same' }
            : { label: this.lbl.rvNotOnAccount, cls: 'rv-chip rv-chip--diff' };
    }
    get bgEmailHint() {
        if (!this._bgEmails.some(e => !this._bgOnAccount(e.value))) return '';
        return this.lbl.bgPickEmail;
    }
    get bgEmailSlots() {
        const groupVals = new Set(this._bgEmails.map(e => (e.value || '').trim().toLowerCase()).filter(Boolean));
        const canAssign = !!this._bgActiveEmail;
        return this._bgEmailOptions.map(o => {
            const cur  = o.currentValue || '';
            const key  = this._bgAssign[o.value];
            const em   = key ? this._bgEmails.find(e => e.key === key) : null;
            const same = !em && !!cur && groupVals.has(cur.toLowerCase());
            if (same) {
                return { key: o.value, label: o.label, on: false, checked: 'true', disabled: true,
                    display: cur, svClass: 'rv-sv', tag: this.lbl.rvTagSame, title: this.lbl.rvSameLocked,
                    cls: 'rv-slot rv-slot--locked rv-slot--same' };
            }
            const on = !!em;
            return {
                key: o.value, label: o.label, on, checked: on ? 'true' : 'false',
                current: on ? cur : '', newVal: on ? em.value : '',
                display: cur || this.lbl.rvEmpty, svClass: cur ? 'rv-sv' : 'rv-sv rv-sv--empty',
                disabled: !on && !canAssign,
                tag: on ? (cur ? this.lbl.rvTagReplace : this.lbl.rvTagAdd) : '',
                title: on ? this.lbl.rvClickAgain : o.label + ': ' + (cur || this.lbl.rvEmpty),
                cls: 'rv-slot' + (on ? ' rv-slot--target' : '') + (!on && !canAssign ? ' rv-slot--locked' : '')
            };
        });
    }
    get bgArrowEmailClass() { return this._rvArrow(Object.keys(this._bgAssign).length > 0); }
    handleBgPickEmail(event) {
        const key = event.currentTarget.dataset.key;
        const e = this._bgEmails.find(x => x.key === key);
        if (!e || this._bgOnAccount(e.value)) return;
        this._bgActiveEmail = key;
    }
    // A slot takes the email picked on the left; each email goes to one field only. Click again to free it.
    handleBgEmailSlot(event) {
        const field = event.currentTarget.dataset.key;
        const assign = { ...this._bgAssign };
        if (assign[field]) {
            this._bgActiveEmail = assign[field];
            delete assign[field];
            this._bgAssign = assign;
            return;
        }
        const key = this._bgActiveEmail;
        if (!key) return;
        Object.keys(assign).forEach(f => { if (assign[f] === key) delete assign[f]; });
        assign[field] = key;
        this._bgAssign = assign;
        // Move on to the next email that still has no place
        const next = this._bgEmails.find(e => !this._bgOnAccount(e.value) && !Object.values(assign).includes(e.key));
        this._bgActiveEmail = next ? next.key : null;
    }
    // Pencil on: remember where this email was going. Pencil off (discard): put the value, its
    // field and the picked email back as they were before editing.
    handleBgEmailPencil(event) {
        const key = event.currentTarget.dataset.key;
        const cur = this._bgEmails.find(x => x.key === key);
        if (!cur) return;
        if (!cur.editing) {
            const prev = { field: this._bgFieldOf(key), active: this._bgActiveEmail };
            this._bgEmails = this._bgEmails.map(e => e.key === key ? { ...e, editing: true, prev } : e);
            if (!this._bgOnAccount(cur.value)) this._bgActiveEmail = key;
            return;
        }
        const prev = cur.prev || {};
        this._bgEmails = this._bgEmails.map(e => e.key === key ? { ...e, editing: false, value: e.orig, prev: null } : e);
        const assign = { ...this._bgAssign };
        Object.keys(assign).forEach(f => { if (assign[f] === key) delete assign[f]; });
        if (prev.field && !assign[prev.field]) assign[prev.field] = key;
        this._bgAssign = assign;
        this._bgActiveEmail = prev.active !== undefined ? prev.active : this._bgActiveEmail;
    }
    handleBgEmailInput(event) {
        const key = event.currentTarget.dataset.key;
        const value = event.target.value;
        this._bgEmails = this._bgEmails.map(e => e.key === key ? { ...e, value } : e);
        // Corrected to an email the account already has: nothing to save for it
        if (this._bgOnAccount(value)) {
            const assign = { ...this._bgAssign };
            Object.keys(assign).forEach(f => { if (assign[f] === key) delete assign[f]; });
            this._bgAssign = assign;
            if (this._bgActiveEmail === key) this._bgActiveEmail = null;
        }
    }

    // Name: the head ticket's name, shown for comparison only (linking never renames the account)
    get bgZeffyFullName() {
        const p = this._bgPreview || {};
        return [p.ticketFirstName, p.ticketLastName].map(v => (v || '').trim()).filter(Boolean).join(' ') || this.bulkHeadName;
    }
    get bgNameDiffers() { return _nameDiffers(this.bgZeffyFullName, this._bgPreview || {}); }

    // Address: pick which of the group's addresses is the right one, then replace Billing or not
    get bgShowAddress() { return this._bgAddrs.length > 0; }
    get bgAddrMulti() { return this._bgAddrs.length > 1; }
    get bgAddrOptions() {
        return this._bgAddrs.map(a => {
            const on = a.key === this._bgAddrKey;
            return { key: a.key, text: a.text, count: '×' + a.count, recent: a.recent,
                checked: on ? 'true' : 'false', cls: 'bg-opt' + (on ? ' bg-opt--on' : '') };
        });
    }
    get _bgAddrChosen() {
        if (this._bgAddrEditing) return this._bgAddrEdit;
        return this._bgAddrs.find(a => a.key === this._bgAddrKey) || this._bgAddrs[0] || {};
    }
    get bgZeffyAddr() { return this._bgAddrText(this._bgAddrChosen); }
    get bgAddrEdit()  { return this._bgAddrEdit; }
    get bgAddrSame() {
        const z = this._bgNormAddr(this._bgAddrText({ ...this._bgAddrChosen, country: '' }));
        return !!z && z === this._bgNormAddr(this._bgPreview && this._bgPreview.accountAddressCore);
    }
    get bgAddrWillUpdate() { return this._bgUpdateAddress && !this.bgAddrSame && !!this.bgZeffyAddr; }
    get bgAddrChip() {
        return this.bgAddrSame
            ? { label: this.lbl.rvAlreadyOnAccount, cls: 'rv-chip rv-chip--same' }
            : { label: this.lbl.cmpDiffers,         cls: 'rv-chip rv-chip--diff' };
    }
    get bgAddrSlot() {
        const cur = (this._bgPreview && this._bgPreview.accountAddress) || '';
        if (this.bgAddrSame) {
            return { on: false, checked: 'true', disabled: true, current: '', newVal: '', display: cur,
                tag: this.lbl.rvTagSame, title: this.lbl.rvSameLockedAddr,
                cls: 'rv-slot rv-slot--single rv-slot--locked rv-slot--same' };
        }
        return { ...this._rvSlot(this._bgUpdateAddress, cur, this.bgZeffyAddr), disabled: false };
    }
    get bgAddrHint() {
        if (this.bgAddrSame) return '';
        return this._bgUpdateAddress ? this.lbl.rvWillReplaceShort : this.lbl.rvClickToReplace;
    }
    get bgArrowAddrClass() { return this._rvArrow(this.bgAddrWillUpdate); }
    get bgArrowNameClass() { return this._rvArrow(false); }
    handleBgPickAddr(event) {
        this._bgAddrKey = event.currentTarget.dataset.key;
        this._bgAddrEditing = false;
    }
    handleBgToggleAddr() { if (!this.bgAddrSame) this._bgUpdateAddress = !this._bgUpdateAddress; }
    handleBgAddrPencil() {
        const on = !this._bgAddrEditing;
        if (on) {
            const a = this._bgAddrs.find(x => x.key === this._bgAddrKey) || this._bgAddrs[0] || {};
            this._bgAddrEdit = { street: a.street || '', city: a.city || '', province: a.province || '',
                postalCode: a.postalCode || '', country: a.country || '' };
            this._bgUpdateAddressPrev = this._bgUpdateAddress;
            this._bgUpdateAddress = true;
        } else {
            this._bgUpdateAddress = !!this._bgUpdateAddressPrev;
        }
        this._bgAddrEditing = on;
    }
    handleBgAddrInput(event) { this._bgAddrEdit = { ...this._bgAddrEdit, [event.target.dataset.field]: event.target.value }; }

    // Totals and amounts (folded behind "See amounts")
    get bgTotalDisplay() {
        const ts = this._bgTickets;
        const total = ts.reduce((sum, t) => sum + (Number(t.Amount__c) || 0), 0);
        return this._money(total, ts.length ? ts[0].Currency__c : undefined);
    }
    get bgTicketsAmtText() {
        return this.lbl.bgTicketsAmt.replace('{n}', this.bulkPendingCount).replace('{amount}', this.bgTotalDisplay);
    }
    get bgMetaText() { return this.lbl.bgTicketsCount.replace('{n}', this.bulkPendingCount); }
    get bgRange() {
        const ds = this._bgTickets.map(t => t.Gift_Date__c).filter(Boolean).sort();
        if (!ds.length) return '';
        return ds[0] === ds[ds.length - 1] ? ds[0] : ds[0] + ' → ' + ds[ds.length - 1];
    }
    get bgAmountRows() {
        return this._bgTickets.map(t => ({ id: t.Id, name: t.Name, date: t.Gift_Date__c || '',
            amount: this._money(t.Amount__c, t.Currency__c) }));
    }
    get bgShowAmounts() { return this._bgShowAmounts; }
    get bgAmountsToggleLabel() { return this._bgShowAmounts ? this.lbl.bgHideAmounts : this.lbl.bgSeeAmounts; }
    handleBgToggleAmounts() { this._bgShowAmounts = !this._bgShowAmounts; }
    get bgNotesOpen() { return this._bgNotesOpen; }
    handleBgOpenNotes() { this._bgNotesOpen = true; }
    get bgRecordAccount() { return this.isBulkLinkMode ? this.bulkSelectedAcctDisplay : this.bulkHeadName + ' (' + this.lbl.bgNewAccount + ')'; }

    get bgSummary() {
        const L = this.lbl;
        const ok = 'rv-result__item rv-result__item--do';
        const keep = 'rv-result__item rv-result__item--keep';
        const items = [];
        const fields = Object.keys(this._bgAssign);
        fields.forEach(f => {
            const o = this._bgEmailOptions.find(x => x.value === f) || { label: f };
            const e = this._bgEmails.find(x => x.key === this._bgAssign[f]);
            if (!e) return;
            items.push(o.currentValue
                ? { key: 'em' + f, cls: ok, icon: 'utility:check', pre: L.rvSumEmailReplace.replace('{field}', o.label), bold: e.value, mid: '', bold2: '' }
                : { key: 'em' + f, cls: ok, icon: 'utility:check', pre: L.rvSumEmailAdd, bold: e.value, mid: L.rvSumAs, bold2: o.label });
        });
        if (!fields.length) items.push({ key: 'em', cls: keep, icon: 'utility:dash', pre: L.rvSumEmailsSame, bold: '', mid: '', bold2: '' });
        if (this.bgShowAddress) {
            items.push(this.bgAddrWillUpdate
                ? { key: 'ad', cls: ok,   icon: 'utility:check', pre: L.rvSumAddrReplace, bold: this.bgZeffyAddr, mid: '', bold2: '' }
                : { key: 'ad', cls: keep, icon: 'utility:dash',  pre: L.rvSumAddrSame,    bold: '', mid: '', bold2: '' });
        }
        return items;
    }
    get bgLinkLabel() { return this.lbl.bgLinkBtn.replace('{n}', this.bulkPendingCount); }
    get bgInvalidEmail() {
        return Object.values(this._bgAssign).some(k => {
            const e = this._bgEmails.find(x => x.key === k);
            return e && !this._bgEmailValid(e.value);
        });
    }

    // What the account gets, plus the reviewer's corrections for the log
    _bgPayload() {
        const values = {};
        const corrections = [];
        Object.keys(this._bgAssign).forEach(f => {
            const e = this._bgEmails.find(x => x.key === this._bgAssign[f]);
            if (!e) return;
            values[f] = e.value.trim();
            if (e.value.trim() !== e.orig) corrections.push('Email "' + e.orig + '" → "' + e.value.trim() + '"');
        });
        if (this.bgAddrWillUpdate) {
            const a = this._bgAddrChosen;
            Object.assign(values, { BillingStreet: a.street || '', BillingCity: a.city || '', BillingState: a.province || '',
                BillingPostalCode: a.postalCode || '', BillingCountry: a.country || '' });
            if (this._bgAddrEditing) {
                const orig = this._bgAddrs.find(x => x.key === this._bgAddrKey) || {};
                const before = this._bgAddrText(orig);
                if (before !== this.bgZeffyAddr) {
                    corrections.push('Address "' + before + '" → "' + this.bgZeffyAddr + '"');
                }
            }
        }
        return { values, corrections };
    }
    // Tickets go to Apex in batches so a large group stays under the per-call query limits.
    // The first batch carries the account changes; the next ones only link (create mode reuses the
    // account the first batch created).
    async handleBulkConfirm() {
        if (this._isBulkResolving) return;
        // Oldest payment first: a recurring commitment starts at the first installment and each
        // newer one moves its next payment forward, also across batches
        const byGiftDate = t => String(t.Gift_Date__c || '9999') + String(t.CreatedDate || '');
        const pendingIds = [...this.bulkPendingTickets]
            .sort((a, b) => byGiftDate(a).localeCompare(byGiftDate(b)))
            .map(t => t.Id);
        if (!pendingIds.length) return;
        this._isBulkResolving = true;
        const notes = this._bulkNotes || '';
        const BATCH = 10;
        const batches = [];
        for (let i = 0; i < pendingIds.length; i += BATCH) batches.push(pendingIds.slice(i, i + BATCH));
        const head = this._bulkHeadTicket;
        const headTicketId = head ? head.Id : null;
        let acctId = this._bulkSelectedAcctId;
        const edited = this.isBulkLinkMode && this._bgPreview ? this._bgPayload() : null;
        let editsSent = false;
        let resolved = 0;
        let accounts = 0;
        let created = false;   // batch 1 created the account (not one already linked to the Zeffy ID)
        let sent = 0;
        const errors = [];
        try {
            for (let i = 0; i < batches.length; i++) {
                const ids = batches[i];
                this._bulkBatch = { i: i + 1, n: batches.length };
                let result;
                if (this.isBulkLinkMode && edited && !editsSent) {
                    // The account changes ride with the first batch that actually links something
                    result = await bulkResolveLinkExistingEdited({ ticketIds: ids, accountId: acctId, notes,
                        accountValues: edited.values, corrections: edited.corrections });
                    editsSent = (result.resolved || 0) > 0;
                } else if (this.isBulkLinkMode) {
                    result = await bulkResolveLinkExisting({ ticketIds: ids, accountId: acctId, notes });
                } else {
                    // Create: built from the ticket the reviewer saw; later batches join that same new account
                    // An account already linked to the Zeffy ID is found again by Apex: those stay Linked
                    const createdId = i > 0 && created ? acctId : null;
                    result = await bulkResolveCreateNew({ ticketIds: ids, donorType: this._bulkCreateType, notes,
                        headTicketId, accountId: createdId });
                    if (i === 0) {
                        created  = result.created === true;
                        accounts = created ? (result.accounts || 0) : 0;
                        acctId   = result.accountId;
                    }
                }
                sent += ids.length;
                resolved += result.resolved || 0;
                errors.push(...(result.errors || []));
                if (!acctId) break; // the new account could not be created: nothing to link the rest to
            }
        } catch (err) {
            errors.push(this.extractError(err));
        }
        // Batches never sent (a call failed or no account): say so, they stay Pending Review
        const notSent = pendingIds.length - sent;
        if (notSent > 0) errors.push(this.lbl.bulkNotSent.replace('{n}', notSent));
        this._isBulkResolving = false;
        this._bulkBatch = null;
        this.showBulkModal = false;
        const acctMsg = !this.isBulkLinkMode && accounts ? this.lbl.bulkAccountsCreated.replace('{n}', accounts) : '';
        if (errors.length === 0 && resolved > 0) {
            const msg = (this.lbl.bulkSuccessToast || '{n} tickets resolved.').replace('{n}', resolved);
            this.showToast(msg, acctMsg, 'success');
        } else {
            const msg = (this.lbl.bulkPartialToast || '{resolved} of {total} resolved. {errors} errors.')
                .replace('{resolved}', resolved)
                .replace('{total}', pendingIds.length)
                .replace('{errors}', errors.length);
            this.showToast(msg, errors.join('; '), resolved > 0 ? 'warning' : 'error');
        }
        this.loadTickets();
        this.loadDashboardStats();
    }

    // ── Resizable columns ──────────────────────────────────────────────────────
    _HISTORY_COL_DEFAULTS = ['90px', '75px', '150px', '85px', '85px', '80px', '80px', '130px'];
    _AUDIT_COL_DEFAULTS   = ['120px', '150px', '75px', '140px', '110px', '200px'];

    renderedCallback() {
        ['history', 'audit'].forEach(tableKey => {
            const table = this.template.querySelector('[data-table="' + tableKey + '"]');
            if (!table) return;
            const cols = table.querySelectorAll('col');
            // Skip if already initialized (first col already has a width)
            if (!cols.length || cols[0].style.width) return;
            this._applyStoredColWidths(tableKey, table);
        });
    }

    handleColResizeStart(event) {
        event.preventDefault();
        const colIdx   = parseInt(event.currentTarget.dataset.col, 10);
        const tableKey = event.currentTarget.dataset.table;
        const table    = this.template.querySelector('[data-table="' + tableKey + '"]');
        if (!table) return;
        const cols = table.querySelectorAll('col');
        const col  = cols[colIdx];
        if (!col) return;
        // Use the actual rendered th width as start point
        const th         = table.querySelectorAll('thead th')[colIdx];
        const startWidth = th ? th.offsetWidth : (parseInt(col.style.width, 10) || 80);
        const startX     = event.clientX;
        const resizerEl  = event.currentTarget;
        resizerEl.classList.add('col-resizer--active');

        const onMove = (e) => {
            const newWidth = Math.max(30, startWidth + e.clientX - startX);
            col.style.width = newWidth + 'px';
            this._updateTableWidth(table, cols);
        };
        const onEnd = () => {
            resizerEl.classList.remove('col-resizer--active');
            document.removeEventListener('mousemove', onMove);
            document.removeEventListener('mouseup', onEnd);
            this._saveColWidths(tableKey, table);
        };
        document.addEventListener('mousemove', onMove);
        document.addEventListener('mouseup', onEnd);
    }

    _applyStoredColWidths(tableKey, tableEl) {
        const defaults = tableKey === 'history' ? this._HISTORY_COL_DEFAULTS : this._AUDIT_COL_DEFAULTS;
        let widths = defaults;
        let hasStored = false;
        try {
            const stored = localStorage.getItem('zcColWidths2_' + tableKey);
            const parsed = stored ? JSON.parse(stored) : null;
            // Ignore saved widths from a different column layout
            if (Array.isArray(parsed) && parsed.length === defaults.length) { widths = parsed; hasStored = true; }
        } catch(e) { /* ignore */ }

        // On first load (no stored widths) scale proportional defaults to fill the wrapper
        if (!hasStored) {
            const wrapperWidth = tableEl.parentElement ? tableEl.parentElement.offsetWidth : 0;
            const defaultSum   = widths.reduce((s, w) => s + parseInt(w, 10), 0);
            if (wrapperWidth > 0) {
                const scale = wrapperWidth / defaultSum;
                widths = widths.map(w => Math.round(parseInt(w, 10) * scale) + 'px');
            }
        }

        const cols = tableEl.querySelectorAll('col');
        widths.forEach((w, i) => { if (cols[i]) cols[i].style.width = w; });
        this._updateTableWidth(tableEl, cols);
    }

    _updateTableWidth(tableEl, cols) {
        // Table width = exact sum of columns — only the dragged column changes (true Excel behavior)
        const total = Array.from(cols).reduce((s, c) => s + (parseInt(c.style.width, 10) || 0), 0);
        tableEl.style.width = total + 'px';
    }

    _saveColWidths(tableKey, tableEl) {
        try {
            const cols   = tableEl.querySelectorAll('col');
            const widths = Array.from(cols).map(c => c.style.width || '');
            localStorage.setItem('zcColWidths2_' + tableKey, JSON.stringify(widths));
        } catch(e) { /* ignore */ }
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

    _openTicketById(id) {
        if (!id) return;
        if (!this.openTabs.find(t => t.id === id)) {
            // Use list data if available, otherwise placeholder — loadDetail fills the rest
            const raw = this.tickets.find(t => t.Id === id);
            const nameParts = raw ? [raw.First_Name__c, raw.Last_Name__c].filter(Boolean) : [];
            const donorName = nameParts.length > 0
                ? nameParts.join(' ')
                : (raw && (raw.Company_Name__c || raw.Name)) || '...';
            this.openTabs = [...this.openTabs, { id, donorName, ticketName: raw ? raw.Name : id }];
        }
        this.activePanel = id;
        this.selectedTicketId = id;
        this.resetResolutionState();
        this.loadDetail();
    }

    loadDetail() {
        this.isLoadingDetail = true;
        Promise.all([
            getTicketDetail({ ticketId: this.selectedTicketId }),
            this.activeFunds.length === 0 ? getActiveFunds() : Promise.resolve(this.activeFunds),
        ])
            .then(([result, funds]) => {
                this.ticket = result
                    ? { ...result, resolvedAccountUrl: result.Resolved_Account__c
                            ? '/lightning/r/Account/' + result.Resolved_Account__c + '/view'
                            : null }
                    : result;
                this.activeFunds = funds;
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
            .then(result => {
                this.stats = result;
                const dupIds = result.duplicateContactIds || [];
                this._duplicateContactIds = new Set(dupIds);
            })
            .catch(err => { console.error('Error loading dashboard stats', this.extractError(err)); });
    }

    loadCampaignMappings() {
        this.isLoadingCampaigns = true;
        getCampaignMappings()
            .then(result => {
                this.campaignMappings    = result;
                this.isLoadingCampaigns  = false;
            })
            .catch(err => {
                this.isLoadingCampaigns = false;
                console.error('Error loading campaign mappings', this.extractError(err));
            });
    }

    loadAuditLog() {
        this.isLoadingAudit = true;
        getAuditLog({ searchTerm: this.auditSearchTerm || '' })
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
                this._setLanguage(result.language);
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
                // Event processing toggles
                this.evtPaymentCreated  = result.processPaymentCreated === 'true';
                this.evtPaymentUpdated  = result.processPaymentUpdated !== 'false';
                this.evtPaymentDeleted  = result.processPaymentDeleted !== 'false';
                this.evtContactEvents        = result.processContactEvents   === 'true';
                this.evtHoldingExpireEnabled = result.holdingExpireEnabled   === 'true';
                this.evtHoldingExpireDays    = parseInt(result.holdingExpireDays, 10) || 10;
                // Ticket actions
                this.showFollowupSetting     = result.showFollowup === 'true';
                // Webhook test URL
                this.settingsWebhookUrl = result.webhookEndpointUrl || '';

                this.isLoadingSettings = false;
            })
            .catch(err => {
                this.isLoadingSettings = false;
                console.error('Error loading settings', this.extractError(err));
            });
    }

    loadDonationHistory() {
        this.isLoadingHistory = true;
        getDonationHistory({ searchTerm: this.historySearchTerm || '' })
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
        this.showAllDetails = false;
        this.resolutionNotes      = '';
        this.selectedAccountId    = null;
        this._previewSeq++; // drop a comparison still loading
        this.isLoadingPreview  = false;
        this.preview              = null;
        this.accountSearch            = '';
        this.accountSearchResults     = [];
        this.emailTargetField         = '';
        this.emailFieldOptions        = [];
        this.updateEmailEnabled       = false;
        this.updateAddressEnabled     = false;
        this.edit                     = {};
        this.editing                  = {};
        this._rvPencilPrev            = {};
        this.createEditing            = false;
        this.createEdit               = {};
        this.matchCandidates      = [];
        this.isLoadingMatches     = false;
        this.donorTypeForNew      = 'individual';
        this.showMatchesModal     = false;
        this.matchesStep          = 1;
        this.matchesMode          = 'link';
        this.showExceptionModal   = false;
        this.exceptionType        = 'close';
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
        if (this.currentLanguage === 'fr') {
            title   = TOAST_FR[title]   || title;
            message = TOAST_FR[message] || message;
        }
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

    get csvTemplateUrl() {
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
        const csv = '﻿' + headers + '\r\n' + example + '\r\n';
        return 'data:text/csv;charset=utf-8,' + encodeURIComponent(csv);
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

    // ── Campaign mapping handlers ──────────────────────────────────────────────
    handleCampaignSearchInput(event) {
        this.campaignSearchTerm = event.target.value;
        clearTimeout(this._campaignSearchTimer);
        this._campaignSearchTimer = setTimeout(() => {
            if (this.campaignSearchTerm.length >= 2) {
                searchCampaigns({ searchTerm: this.campaignSearchTerm })
                    .then(r => { this.campaignSearchResults = r; })
                    .catch(() => {});
            } else {
                this.campaignSearchResults = [];
            }
        }, 300);
    }

    handleSelectCampaignResult(event) {
        const id      = event.currentTarget.dataset.id;
        const name    = event.currentTarget.dataset.name;
        const formId  = event.currentTarget.dataset.formid || '';
        const managed = event.currentTarget.dataset.managed === 'true';
        this.editingMapping = { id, name, formId, isZeffyManaged: managed };
        this.campaignSearchTerm    = '';
        this.campaignSearchResults = [];
    }

    handleMappingFormIdChange(event) {
        this.editingMapping = { ...this.editingMapping, formId: event.target.value };
    }

    handleMappingManagedChange(event) {
        this.editingMapping = { ...this.editingMapping, isZeffyManaged: event.target.checked };
    }

    handleSaveCampaignMapping() {
        if (!this.editingMapping) return;
        saveCampaignMapping({
            campaignId:     this.editingMapping.id,
            formId:         this.editingMapping.formId,
            isZeffyManaged: this.editingMapping.isZeffyManaged,
        })
            .then(() => {
                this.showToast('Saved', 'Campaign mapping updated', 'success');
                this.editingMapping = null;
                this.loadCampaignMappings();
            })
            .catch(err => this.showToast('Error', this.extractError(err), 'error'));
    }

    handleCancelCampaignMapping() {
        this.editingMapping        = null;
        this.campaignSearchTerm    = '';
        this.campaignSearchResults = [];
    }

    get hasCampaignSearchResults() { return this.campaignSearchResults.length > 0; }

    get campaignMappingsList() {
        return this.campaignMappings.map(c => ({
            ...c,
            managedLabel: c.isZeffyManaged ? 'Zeffy' : 'Manual',
            managedClass: 'camp-badge ' + (c.isZeffyManaged ? 'camp-badge--zeffy' : 'camp-badge--manual'),
        }));
    }
}
