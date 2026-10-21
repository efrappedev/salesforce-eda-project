public with sharing class DmcDonationService {

    // ─── Zeffy payload wrapper classes ───────────────────────────────────────

    public class ZeffyEvent {
        public String id;
        public String type;
        public String version;
        public String dispatchedAt;
        public ZeffyPayment data;
    }

    public class ZeffyPayment {
        public String  id;
        public String  status;
        public String  type;
        public Decimal amount;
        public Decimal eligibleAmount;
        public Decimal platformFee;
        public String  currencyIso;   // "currency" is reserved in Apex
        public String  paymentMethod;
        public String  created;
        public String  receiptNumber;
        public String  receiptUrl;
        public String  rateTitle;
        public String  note;
        public String  annotation;
        public Boolean isRecurring;
        public String  subscriptionId;
        public String  subscriptionFrequency;
        public ZeffyContact contact;
        public ZeffyCampaign campaign;
    }

    public class ZeffyContact {
        public String       id;
        public String       firstName;
        public String       lastName;
        public String       name;
        public String       email;
        public String       phoneNumber;
        public String       companyName;
        public String       language;
        public ZeffyAddress address;
    }

    public class ZeffyCampaign {
        public String id;
        public String name;
    }

    public class ZeffyAddress {
        public String address;
        public String city;
        public String region;
        public String state;
        public String postalCode;
        public String country;
    }

    // Returned to LWC for auto-match candidate cards
    public class AccountMatch implements Comparable {
        @AuraEnabled public String  id;
        @AuraEnabled public String  name;
        @AuraEnabled public String  email;
        @AuraEnabled public String  phone;
        @AuraEnabled public String  city;
        @AuraEnabled public String  matchType; // kept for compatibility
        @AuraEnabled public Integer score;     // 0-100
        public Integer compareTo(Object other) {
            return ((AccountMatch) other).score - this.score; // sort DESC
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<AccountMatch> findAccountMatches(Id ticketId) {
        Zeffy_Review_Ticket__c t = [
            SELECT First_Name__c, Last_Name__c, Email__c, Company_Name__c
            FROM Zeffy_Review_Ticket__c WHERE Id = :ticketId LIMIT 1
        ];
        Map<Id, AccountMatch> matchMap = new Map<Id, AccountMatch>();

        String tEmail   = String.isNotBlank(t.Email__c)        ? t.Email__c.toLowerCase().trim()        : null;
        String tFirst   = String.isNotBlank(t.First_Name__c)   ? t.First_Name__c.toLowerCase().trim()   : null;
        String tLast    = String.isNotBlank(t.Last_Name__c)     ? t.Last_Name__c.toLowerCase().trim()    : null;
        String tCompany = String.isNotBlank(t.Company_Name__c)  ? t.Company_Name__c.toLowerCase().trim() : null;

        // 1. Match by email (exact)
        if (tEmail != null) {
            for (Account a : [SELECT Id, Name, FirstName, LastName, PersonEmail, Phone, BillingCity
                              FROM Account WHERE PersonEmail = :t.Email__c LIMIT 10]) {
                AccountMatch m = buildAccountMatch(a);
                m.score = calcScore(m.email, a.FirstName, a.LastName, a.Name, tEmail, tFirst, tLast, tCompany);
                matchMap.put(a.Id, m);
            }
        }

        // 2. Match by last name or company name
        if (tLast != null || tCompany != null) {
            String nameLike = '%' + (tLast != null ? t.Last_Name__c.trim() : t.Company_Name__c.trim()) + '%';
            for (Account a : [SELECT Id, Name, FirstName, LastName, PersonEmail, Phone, BillingCity
                              FROM Account WHERE Name LIKE :nameLike LIMIT 10]) {
                if (!matchMap.containsKey(a.Id)) {
                    AccountMatch m = buildAccountMatch(a);
                    m.score = calcScore(m.email, a.FirstName, a.LastName, a.Name, tEmail, tFirst, tLast, tCompany);
                    matchMap.put(a.Id, m);
                }
            }
        }

        // Sort by score DESC, return top 10
        List<AccountMatch> sorted = matchMap.values();
        sorted.sort();
        List<AccountMatch> top = new List<AccountMatch>();
        for (Integer i = 0; i < Math.min(10, sorted.size()); i++) {
            top.add(sorted[i]);
        }
        return top;
    }

    private static AccountMatch buildAccountMatch(Account a) {
        AccountMatch m  = new AccountMatch();
        m.id    = a.Id;
        m.name  = a.Name;
        m.email = a.PersonEmail;
        m.phone = a.Phone;
        m.city  = a.BillingCity;
        return m;
    }

    private static Integer calcScore(String acctEmail, String acctFirst, String acctLast, String acctName,
                                     String tEmail, String tFirst, String tLast, String tCompany) {
        Integer s = 0;
        // Email exact match: 50 pts
        if (tEmail != null && String.isNotBlank(acctEmail) && acctEmail.toLowerCase().trim() == tEmail) s += 50;
        // Last name / company match: 30 pts
        if (tLast != null && String.isNotBlank(acctLast) && acctLast.toLowerCase().trim() == tLast) {
            s += 30;
        } else if (tCompany != null && String.isNotBlank(acctName) && acctName.toLowerCase().contains(tCompany)) {
            s += 30;
        }
        // First name match: 20 pts
        if (tFirst != null && String.isNotBlank(acctFirst) && acctFirst.toLowerCase().trim() == tFirst) s += 20;
        return s;
    }

    // Returned to LWC for the "link existing" preview
    public class LinkPreview {
        @AuraEnabled public String  accountId;
        @AuraEnabled public String  accountName;
        @AuraEnabled public String  ticketFirstName;
        @AuraEnabled public String  accountFirstName;
        @AuraEnabled public Boolean firstNamesDiffer;
        @AuraEnabled public String  ticketLastName;
        @AuraEnabled public String  accountLastName;
        @AuraEnabled public Boolean lastNamesDiffer;
        @AuraEnabled public String  accountEmail;
        @AuraEnabled public String  ticketEmail;
        @AuraEnabled public Boolean emailsDiffer;
        @AuraEnabled public String  accountAddress;
        @AuraEnabled public String  ticketAddress;
        @AuraEnabled public Boolean addressesDiffer;
        @AuraEnabled public List<String>          existingZeffyIds;
        @AuraEnabled public List<EmailFieldOption> emailFieldOptions;
    }

    public class EmailFieldOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        @AuraEnabled public String currentValue; // current value on the Account record
        public EmailFieldOption(String lbl, String val, String cur) {
            label = lbl; value = val; currentValue = cur;
        }
    }

    // ─── Main entry point ────────────────────────────────────────────────────

    public static void processWebhook(String rawBody) {
        ZeffyEvent event;
        try {
            String processedBody = rawBody.replace('"currency":', '"currencyIso":');
            event = (ZeffyEvent) JSON.deserialize(processedBody, ZeffyEvent.class);
        } catch (Exception ex) {
            createErrorTicket(rawBody, 'JSON parse error: ' + ex.getMessage().abbreviate(500));
            return;
        }

        if (event == null || event.data == null) return;
        if (event.type != null && !event.type.equalsIgnoreCase('payment.completed')) return;

        ZeffyPayment payment = event.data;
        if (String.isNotBlank(payment.id) && isDuplicate(payment.id)) return;

        Account donor = findDonor(payment);

        if (donor != null) {
            createGiftTransaction(payment, donor.Id, rawBody);
        } else {
            createReviewTicket(payment, rawBody);
        }
    }

    // ─── Donor lookup — queries Zeffy_Identity__c first ──────────────────────

    private static Account findDonor(ZeffyPayment payment) {
        if (payment.contact == null) return null;

        // 1. Primary: search by Zeffy Contact ID in identity history
        if (String.isNotBlank(payment.contact.id)) {
            List<Zeffy_Identity__c> byId = [
                SELECT Account__c FROM Zeffy_Identity__c
                WHERE Zeffy_Contact_Id__c = :payment.contact.id LIMIT 1
            ];
            if (!byId.isEmpty()) {
                List<Account> accts = [SELECT Id, Name FROM Account WHERE Id = :byId[0].Account__c LIMIT 1];
                if (!accts.isEmpty()) return accts[0];
            }
        }

        // 2. Fallback: PersonEmail match — only for PersonAccounts
        if (String.isNotBlank(payment.contact.email)) {
            List<Account> byEmail = [
                SELECT Id, Name FROM Account
                WHERE PersonEmail = :payment.contact.email AND IsPersonAccount = true LIMIT 1
            ];
            if (!byEmail.isEmpty()) {
                Account found = byEmail[0];
                // Register this new Zeffy ID in the identity history
                if (String.isNotBlank(payment.contact.id)) {
                    upsertIdentity(found.Id, payment.contact.id, payment.contact.email, 'Webhook');
                }
                return found;
            }
        }

        return null;
    }

    // ─── Auto-create NPC GiftTransaction for known donor ─────────────────────

    private static void createGiftTransaction(ZeffyPayment p, Id accountId, String rawBody) {
        Id campaignId = resolveCampaign(p);
        Decimal eligible    = p.eligibleAmount != null ? p.eligibleAmount : p.amount;
        Decimal nonDeductible = (p.amount != null && p.amount > eligible) ? (p.amount - eligible) : 0;

        String gtName = 'ZF-' + (String.isNotBlank(p.id) ? p.id.abbreviate(40) : String.valueOf(Date.today()));
        GiftTransaction gt = new GiftTransaction(
            Name                     = gtName,
            DonorId                  = accountId,
            OriginalAmount           = p.amount,
            NonTaxDeductibleAmount   = nonDeductible,
            GatewayTransactionFee    = p.platformFee,
            PaymentMethod            = mapPaymentMethod(p.paymentMethod),
            GiftType                 = mapGiftType(p.type),
            Status                   = 'Paid',
            TransactionDate          = parseDate(p.created),
            CampaignId               = campaignId,
            Description              = buildDescription(p),
            Zeffy_Transaction_Id__c  = p.id,
            Receipt_URL__c           = p.receiptUrl,
            Rate_Title__c            = p.rateTitle,
            Note__c                  = p.note,
            Annotation__c            = p.annotation,
            Language__c              = p.contact != null ? p.contact.language : null,
            Zeffy_Raw_Payload__c     = rawBody
        );
        insert gt;

        if (p.isRecurring == true && String.isNotBlank(p.subscriptionId)) {
            createOrUpdateCommitment(p, accountId);
        }
    }

    private static void createOrUpdateCommitment(ZeffyPayment p, Id accountId) {
        List<GiftCommitment> existing = [
            SELECT Id FROM GiftCommitment WHERE Zeffy_Subscription_Id__c = :p.subscriptionId LIMIT 1
        ];
        if (existing.isEmpty()) {
            try {
                insert new GiftCommitment(
                    Name                     = 'Zeffy Recurring ' + p.subscriptionId.abbreviate(40),
                    DonorId                  = accountId,
                    Status                   = 'Active',
                    ScheduleType             = 'Recurring',
                    RecurrenceType           = 'OpenEnded',
                    EffectiveStartDate       = parseDate(p.created),
                    Zeffy_Subscription_Id__c = p.subscriptionId
                );
            } catch (Exception ex) {
                System.debug('GiftCommitment insert failed (non-critical): ' + ex.getMessage());
            }
        }
    }

    // ─── Create review ticket for unknown donor ───────────────────────────────

    private static void createReviewTicket(ZeffyPayment p, String rawBody) {
        ZeffyContact c = p.contact;
        ZeffyAddress a = (c != null) ? c.address : null;

        Zeffy_Review_Ticket__c ticket = new Zeffy_Review_Ticket__c(
            Status__c                  = 'Pending Review',
            Zeffy_Contact_Id__c        = c != null ? c.id : null,
            First_Name__c              = c != null ? c.firstName : null,
            Last_Name__c               = c != null ? c.lastName : null,
            Email__c                   = c != null ? c.email : null,
            Phone__c                   = c != null ? c.phoneNumber : null,
            Company_Name__c            = c != null ? c.companyName : null,
            Language__c                = c != null ? c.language : null,
            Address__c                 = a != null ? a.address : null,
            City__c                    = a != null ? a.city : null,
            Province__c                = a != null ? (String.isNotBlank(a.region) ? a.region : a.state) : null,
            Postal_Code__c             = a != null ? a.postalCode : null,
            Country__c                 = a != null ? a.country : null,
            Amount__c                  = p.amount,
            Eligible_Amount__c         = p.eligibleAmount,
            Currency__c                = p.currencyIso,
            Payment_Method__c          = mapPaymentMethod(p.paymentMethod),
            Payment_Type__c            = mapPaymentType(p.type),
            Gift_Date__c               = parseDate(p.created),
            Rate_Title__c              = p.rateTitle,
            Receipt_Number__c          = p.receiptNumber,
            Receipt_URL__c             = p.receiptUrl,
            Form_Id__c                 = p.campaign != null ? p.campaign.id : null,
            Form_Name__c               = p.campaign != null ? p.campaign.name : null,
            Is_Recurring__c            = p.isRecurring != null ? p.isRecurring : false,
            Zeffy_Subscription_Id__c   = p.subscriptionId,
            Subscription_Frequency__c  = p.subscriptionFrequency,
            Zeffy_Transaction_Id__c    = p.id,
            Note__c                    = p.note,
            Annotation__c              = p.annotation,
            Raw_Payload__c             = rawBody
        );
        insert ticket;
        createPendingTask(ticket, c);
    }

    private static void createPendingTask(Zeffy_Review_Ticket__c ticket, ZeffyContact c) {
        Zeffy_Config__c cfg = DmcConfigService.getConfig();
        if (cfg == null || cfg.Auto_Task_Enabled__c != true) return;

        String donorName = '';
        if (c != null) {
            List<String> parts = new List<String>();
            if (String.isNotBlank(c.firstName)) parts.add(c.firstName);
            if (String.isNotBlank(c.lastName))  parts.add(c.lastName);
            donorName = String.join(parts, ' ');
            if (String.isBlank(donorName) && String.isNotBlank(c.companyName)) {
                donorName = c.companyName;
            }
        }

        Integer dueDays = cfg.Task_Due_Days__c != null ? (Integer) cfg.Task_Due_Days__c : 2;
        String  subject = 'Review pending donation' + (String.isNotBlank(donorName) ? ': ' + donorName : '');
        Id      ownerId = String.isNotBlank(cfg.Task_Owner_Id__c) ? cfg.Task_Owner_Id__c : UserInfo.getUserId();

        insert new Task(
            Subject      = subject,
            ActivityDate = Date.today().addDays(dueDays),
            OwnerId      = ownerId,
            WhatId       = ticket.Id,
            Status       = 'Not Started',
            Priority     = 'Normal',
            Description  = 'A new Zeffy donation arrived and needs review in DMC.'
        );
    }

    private static void createErrorTicket(String rawBody, String errorMsg) {
        insert new Zeffy_Review_Ticket__c(
            Status__c        = 'Error',
            Raw_Payload__c   = rawBody,
            Error_Message__c = errorMsg
        );
    }

    // ─── LWC: preview before linking to existing account ─────────────────────

    @AuraEnabled(cacheable=true)
    public static LinkPreview getLinkPreview(Id ticketId, Id accountId) {
        Zeffy_Review_Ticket__c t = [
            SELECT Email__c, First_Name__c, Last_Name__c, Address__c, City__c, Province__c, Postal_Code__c, Country__c
            FROM Zeffy_Review_Ticket__c WHERE Id = :ticketId LIMIT 1
        ];
        // Scan Account schema for Email-type fields (dynamic — picks up custom fields automatically)
        List<String>         emailApiNames  = new List<String>();
        Map<String, String>  emailLabelMap  = new Map<String, String>();
        Map<String, Schema.SObjectField> allAccountFields = Schema.SObjectType.Account.fields.getMap();
        for (String fname : allAccountFields.keySet()) {
            Schema.DescribeFieldResult fd = allAccountFields.get(fname).getDescribe();
            if (fd.getType() == Schema.DisplayType.Email && fd.isUpdateable()) {
                emailApiNames.add(fd.getName());
                emailLabelMap.put(fd.getName(), fd.getLabel());
            }
        }

        // Build dynamic SOQL including all email fields + standard address/name/firstname/lastname fields
        Set<String> colSet = new Set<String>{'id','name','firstname','lastname','billingstreet','billingcity','billingstate','billingpostalcode','billingcountry'};
        List<String> selectCols = new List<String>{'Id','Name','FirstName','LastName','BillingStreet','BillingCity','BillingState','BillingPostalCode','BillingCountry'};
        for (String fname : emailApiNames) {
            if (!colSet.contains(fname.toLowerCase())) {
                selectCols.add(fname);
                colSet.add(fname.toLowerCase());
            }
        }
        String acctQuery = 'SELECT ' + String.join(selectCols, ', ') + ' FROM Account WHERE Id = :accountId LIMIT 1';
        Account a = (Account) Database.query(acctQuery);

        List<Zeffy_Identity__c> identities = [
            SELECT Zeffy_Contact_Id__c, Email__c, Is_Primary__c, First_Seen__c
            FROM Zeffy_Identity__c WHERE Account__c = :accountId
            ORDER BY Is_Primary__c DESC, First_Seen__c ASC
        ];

        String mainEmail = (String) a.get('PersonEmail');

        LinkPreview preview = new LinkPreview();
        preview.accountId         = accountId;
        preview.accountName       = a.Name;
        preview.ticketFirstName   = t.First_Name__c;
        preview.accountFirstName  = a.FirstName;
        preview.firstNamesDiffer  = String.isNotBlank(t.First_Name__c) && t.First_Name__c != a.FirstName;
        preview.ticketLastName    = t.Last_Name__c;
        preview.accountLastName   = a.LastName;
        preview.lastNamesDiffer   = String.isNotBlank(t.Last_Name__c) && t.Last_Name__c != a.LastName;
        preview.accountEmail      = mainEmail;
        preview.ticketEmail       = t.Email__c;
        preview.emailsDiffer      = String.isNotBlank(t.Email__c) && t.Email__c != mainEmail;

        String acctAddr = buildAddressString(a.BillingStreet, a.BillingCity, a.BillingState, a.BillingPostalCode);
        String tktAddr  = buildAddressString(t.Address__c, t.City__c, t.Province__c, t.Postal_Code__c);
        preview.accountAddress  = acctAddr;
        preview.ticketAddress   = tktAddr;
        preview.addressesDiffer = String.isNotBlank(tktAddr) && tktAddr != acctAddr;

        preview.existingZeffyIds = new List<String>();
        for (Zeffy_Identity__c zi : identities) {
            preview.existingZeffyIds.add(zi.Zeffy_Contact_Id__c +
                (String.isNotBlank(zi.Email__c) ? ' (' + zi.Email__c + ')' : '') +
                (zi.Is_Primary__c ? ' ★' : ''));
        }

        // Build email field options including the current value from the Account record
        List<EmailFieldOption> emailOpts = new List<EmailFieldOption>();
        for (String fname : emailApiNames) {
            String currentVal = (String) a.get(fname);
            emailOpts.add(new EmailFieldOption(emailLabelMap.get(fname), fname, currentVal));
        }
        preview.emailFieldOptions = emailOpts;

        return preview;
    }

    // ─── Resolution methods (called from LWC) ────────────────────────────────

    @AuraEnabled
    public static void resolveCreateNew(Id ticketId, String donorType, String notes) {
        Zeffy_Review_Ticket__c t = loadTicket(ticketId);
        String safeType = String.isBlank(donorType) ? 'individual' : donorType.toLowerCase();

        Account donor;
        if (safeType == 'individual') {
            Id personRtId = getRecordTypeId('Account', 'PersonAccount');
            donor = new Account(
                RecordTypeId        = personRtId,
                FirstName           = t.First_Name__c,
                LastName            = String.isNotBlank(t.Last_Name__c) ? t.Last_Name__c : 'Zeffy',
                PersonEmail         = t.Email__c,
                PersonMobilePhone   = t.Phone__c,
                BillingStreet       = t.Address__c,
                BillingCity         = t.City__c,
                BillingState        = t.Province__c,
                BillingPostalCode   = t.Postal_Code__c,
                BillingCountry      = t.Country__c
            );
        } else {
            String rtName = safeType == 'eglise' ? 'Eglise' : 'Org_Business_Account';
            Id rtId = getRecordTypeId('Account', rtName);
            String acctName = String.isNotBlank(t.Company_Name__c)
                ? t.Company_Name__c
                : buildFullName(t.First_Name__c, t.Last_Name__c);
            donor = new Account(
                RecordTypeId     = rtId,
                Name             = acctName,
                Phone            = t.Phone__c,
                BillingStreet    = t.Address__c,
                BillingCity      = t.City__c,
                BillingState     = t.Province__c,
                BillingPostalCode = t.Postal_Code__c,
                BillingCountry   = t.Country__c
            );
        }
        insert donor;

        // Register Zeffy identity
        if (String.isNotBlank(t.Zeffy_Contact_Id__c)) {
            upsertIdentity(donor.Id, t.Zeffy_Contact_Id__c, t.Email__c, 'Ticket');
        }

        Id giftId = createGiftFromTicket(t, donor.Id);
        resolveTicket(t.Id, 'Resolved - New Contact', donor.Id, giftId, notes);
    }

    @AuraEnabled
    public static void resolveLinkExisting(
        Id ticketId, Id accountId, String notes,
        String emailTargetField, Boolean updateAddress,
        Boolean updateFirstName, Boolean updateLastName
    ) {
        Zeffy_Review_Ticket__c t = loadTicket(ticketId);

        // Add new Zeffy ID to identity history (never overwrites existing IDs)
        if (String.isNotBlank(t.Zeffy_Contact_Id__c)) {
            upsertIdentity(accountId, t.Zeffy_Contact_Id__c, t.Email__c, 'Ticket');
        }

        // Optionally save email to a specific Account field and/or update address/name
        Account toUpdate = new Account(Id = accountId);
        Boolean doUpdate = false;

        if (String.isNotBlank(emailTargetField) && String.isNotBlank(t.Email__c)) {
            toUpdate.put(emailTargetField, t.Email__c);
            doUpdate = true;
        }
        if (updateAddress == true) {
            toUpdate.BillingStreet     = t.Address__c;
            toUpdate.BillingCity       = t.City__c;
            toUpdate.BillingState      = t.Province__c;
            toUpdate.BillingPostalCode = t.Postal_Code__c;
            toUpdate.BillingCountry    = t.Country__c;
            doUpdate = true;
        }
        if (updateFirstName == true && String.isNotBlank(t.First_Name__c)) {
            toUpdate.FirstName = t.First_Name__c;
            doUpdate = true;
        }
        if (updateLastName == true && String.isNotBlank(t.Last_Name__c)) {
            toUpdate.LastName = t.Last_Name__c;
            doUpdate = true;
        }
        if (doUpdate) {
            try { update toUpdate; } catch (Exception ex) {
                System.debug('Account update non-critical: ' + ex.getMessage());
            }
        }

        Id giftId = createGiftFromTicket(t, accountId);
        resolveTicket(t.Id, 'Resolved - Linked', accountId, giftId, notes);
    }

    @AuraEnabled
    public static void skipTicket(Id ticketId, String reason) {
        update new Zeffy_Review_Ticket__c(
            Id                  = ticketId,
            Status__c           = 'Skipped',
            Resolved_By__c      = UserInfo.getUserId(),
            Resolved_At__c      = DateTime.now(),
            Resolution_Notes__c = reason
        );
        createAuditLog(ticketId, 'Skipped', null, reason);
    }

    @AuraEnabled(cacheable=true)
    public static List<Zeffy_Review_Ticket__c> getTickets(String statusFilter) {
        String soql =
            'SELECT Id, Name, Status__c, First_Name__c, Last_Name__c, Email__c, ' +
            '       Amount__c, Currency__c, Payment_Type__c, Gift_Date__c, ' +
            '       Form_Name__c, Is_Recurring__c, Company_Name__c, CreatedDate, ' +
            '       Manual_Assignee_Id__c, Manual_Assignee_Name__c ' +
            'FROM Zeffy_Review_Ticket__c ';
        if (String.isNotBlank(statusFilter) && statusFilter != 'All') {
            if (statusFilter == 'Open') {
                soql += 'WHERE Status__c NOT IN (\'Resolved - Linked\', \'Resolved - New Contact\', \'Resolved - New Account\', \'Skipped\') ';
            } else {
                soql += 'WHERE Status__c = \'' + String.escapeSingleQuotes(statusFilter) + '\' ';
            }
        }
        soql += 'ORDER BY CreatedDate DESC LIMIT 200';
        return Database.query(soql);
    }

    @AuraEnabled(cacheable=true)
    public static Zeffy_Review_Ticket__c getTicketDetail(Id ticketId) {
        return [
            SELECT Id, Name, Status__c, Error_Message__c,
                   Zeffy_Contact_Id__c, First_Name__c, Last_Name__c,
                   Email__c, Phone__c, Company_Name__c, Language__c,
                   Address__c, City__c, Province__c, Postal_Code__c, Country__c,
                   Amount__c, Eligible_Amount__c,
                   Currency__c, Payment_Method__c, Payment_Type__c, Gift_Date__c,
                   Rate_Title__c, Receipt_Number__c, Receipt_URL__c,
                   Form_Id__c, Form_Name__c, Is_Recurring__c,
                   Zeffy_Subscription_Id__c, Subscription_Frequency__c,
                   Zeffy_Transaction_Id__c, Note__c, Annotation__c,
                   Resolved_Account__c, Resolved_Account__r.Name,
                   Resolved_Gift__c, Resolved_Gift__r.Name,
                   Resolved_By__c, Resolved_By__r.Name,
                   Resolved_At__c, Resolution_Notes__c,
                   Manual_Assignee_Id__c, Manual_Assignee_Name__c
            FROM Zeffy_Review_Ticket__c
            WHERE Id = :ticketId LIMIT 1
        ];
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    private static Boolean isDuplicate(String transactionId) {
        return [SELECT COUNT() FROM GiftTransaction WHERE Zeffy_Transaction_Id__c = :transactionId] > 0
            || [SELECT COUNT() FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = :transactionId] > 0;
    }

    // Upsert a Zeffy_Identity__c — safe to call even if the ID already exists
    private static void upsertIdentity(Id accountId, String zeffyContactId, String email, String source) {
        if (String.isBlank(zeffyContactId)) return;

        List<Zeffy_Identity__c> existing = [
            SELECT Id FROM Zeffy_Identity__c WHERE Zeffy_Contact_Id__c = :zeffyContactId LIMIT 1
        ];

        Boolean isFirst = [SELECT COUNT() FROM Zeffy_Identity__c WHERE Account__c = :accountId] == 0;

        if (existing.isEmpty()) {
            insert new Zeffy_Identity__c(
                Account__c          = accountId,
                Zeffy_Contact_Id__c = zeffyContactId,
                Email__c            = email,
                Is_Primary__c       = isFirst,
                First_Seen__c       = Date.today(),
                Source__c           = source
            );
        }
        // If it already exists pointing to this same account, nothing to do
    }

    private static Zeffy_Review_Ticket__c loadTicket(Id ticketId) {
        return [
            SELECT Id, Status__c, Zeffy_Contact_Id__c, First_Name__c, Last_Name__c,
                   Email__c, Phone__c, Company_Name__c, Language__c,
                   Address__c, City__c, Province__c, Postal_Code__c, Country__c,
                   Amount__c, Eligible_Amount__c,
                   Payment_Method__c, Payment_Type__c, Gift_Date__c,
                   Rate_Title__c, Receipt_Number__c, Receipt_URL__c,
                   Form_Id__c, Form_Name__c, Is_Recurring__c,
                   Zeffy_Subscription_Id__c, Subscription_Frequency__c,
                   Zeffy_Transaction_Id__c, Note__c, Annotation__c, Raw_Payload__c
            FROM Zeffy_Review_Ticket__c WHERE Id = :ticketId LIMIT 1
        ];
    }

    private static Id createGiftFromTicket(Zeffy_Review_Ticket__c t, Id accountId) {
        Id campaignId = null;
        if (String.isNotBlank(t.Form_Id__c)) {
            List<Campaign> cmp = [SELECT Id FROM Campaign WHERE Zeffy_Form_Id__c = :t.Form_Id__c LIMIT 1];
            if (!cmp.isEmpty()) {
                campaignId = cmp[0].Id;
            } else if (String.isNotBlank(t.Form_Name__c)) {
                Campaign nc = new Campaign(Name = t.Form_Name__c, IsActive = true, Zeffy_Form_Id__c = t.Form_Id__c);
                insert nc;
                campaignId = nc.Id;
            }
        }

        Decimal eligible     = t.Eligible_Amount__c != null ? t.Eligible_Amount__c : t.Amount__c;
        Decimal nonDeductible = (t.Amount__c != null && t.Amount__c > eligible) ? (t.Amount__c - eligible) : 0;

        String gtName = 'ZF-' + (String.isNotBlank(t.Zeffy_Transaction_Id__c)
            ? t.Zeffy_Transaction_Id__c.abbreviate(40) : String.valueOf(Date.today()));
        GiftTransaction gt = new GiftTransaction(
            Name                    = gtName,
            DonorId                 = accountId,
            OriginalAmount          = t.Amount__c,
            NonTaxDeductibleAmount  = nonDeductible,
            PaymentMethod           = String.isNotBlank(t.Payment_Method__c) ? t.Payment_Method__c : 'Credit Card',
            GiftType                = (t.Payment_Type__c == 'Donation') ? 'Individual' : 'Organizational',
            Status                  = 'Paid',
            TransactionDate         = t.Gift_Date__c,
            CampaignId              = campaignId,
            Zeffy_Transaction_Id__c = t.Zeffy_Transaction_Id__c,
            Receipt_URL__c          = t.Receipt_URL__c,
            Rate_Title__c           = t.Rate_Title__c,
            Note__c                 = t.Note__c,
            Annotation__c           = t.Annotation__c,
            Language__c             = t.Language__c,
            Zeffy_Raw_Payload__c    = t.Raw_Payload__c
        );
        insert gt;

        if (t.Is_Recurring__c && String.isNotBlank(t.Zeffy_Subscription_Id__c)) {
            List<GiftCommitment> existingCmt = [
                SELECT Id FROM GiftCommitment WHERE Zeffy_Subscription_Id__c = :t.Zeffy_Subscription_Id__c LIMIT 1
            ];
            if (existingCmt.isEmpty()) {
                try {
                    insert new GiftCommitment(
                        Name                     = 'Zeffy Recurring ' + t.Zeffy_Subscription_Id__c.abbreviate(40),
                        DonorId                  = accountId,
                        Status                   = 'Active',
                        ScheduleType             = 'Recurring',
                        RecurrenceType           = 'OpenEnded',
                        EffectiveStartDate       = t.Gift_Date__c,
                        Zeffy_Subscription_Id__c = t.Zeffy_Subscription_Id__c
                    );
                } catch (Exception ex) {
                    System.debug('GiftCommitment insert failed (non-critical): ' + ex.getMessage());
                }
            }
        }
        return gt.Id;
    }

    private static void resolveTicket(Id ticketId, String status, Id accountId, Id giftId, String notes) {
        update new Zeffy_Review_Ticket__c(
            Id                  = ticketId,
            Status__c           = status,
            Resolved_Account__c = accountId,
            Resolved_Gift__c    = giftId,
            Resolved_By__c      = UserInfo.getUserId(),
            Resolved_At__c      = DateTime.now(),
            Resolution_Notes__c = notes
        );
        createAuditLog(ticketId, status, accountId, notes);
    }

    private static void createAuditLog(Id ticketId, String action, Id accountId, String notes) {
        try {
            insert new DMC_Audit_Log__c(
                Ticket__c       = ticketId,
                Action__c       = action,
                Performed_By__c = UserInfo.getUserId(),
                Performed_At__c = DateTime.now(),
                Account__c      = accountId,
                Notes__c        = notes
            );
        } catch (Exception e) {
            System.debug('createAuditLog failed (non-critical): ' + e.getMessage());
        }
    }

    private static Id resolveCampaign(ZeffyPayment p) {
        if (p.campaign == null || String.isBlank(p.campaign.id)) return null;
        List<Campaign> campaigns = [SELECT Id FROM Campaign WHERE Zeffy_Form_Id__c = :p.campaign.id LIMIT 1];
        if (!campaigns.isEmpty()) return campaigns[0].Id;
        Campaign nc = new Campaign(
            Name             = String.isNotBlank(p.campaign.name) ? p.campaign.name : ('Zeffy Form ' + p.campaign.id),
            IsActive         = true,
            Zeffy_Form_Id__c = p.campaign.id
        );
        insert nc;
        return nc.Id;
    }

    private static Id getRecordTypeId(String sObjectType, String developerName) {
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = :sObjectType AND DeveloperName = :developerName AND IsActive = true LIMIT 1
        ];
        return rts.isEmpty() ? null : rts[0].Id;
    }

    private static String buildFullName(String firstName, String lastName) {
        String fn = String.isNotBlank(firstName) ? firstName : '';
        String ln = String.isNotBlank(lastName)  ? lastName  : 'Zeffy Donor';
        return (fn + ' ' + ln).trim();
    }

    private static String buildAddressString(String street, String city, String state, String zip) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(street)) parts.add(street);
        if (String.isNotBlank(city))   parts.add(city);
        if (String.isNotBlank(state))  parts.add(state);
        if (String.isNotBlank(zip))    parts.add(zip);
        return String.join(parts, ', ');
    }

    private static String buildDescription(ZeffyPayment p) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(p.rateTitle))  parts.add('Rate: ' + p.rateTitle);
        if (String.isNotBlank(p.note))       parts.add('Note: ' + p.note);
        if (String.isNotBlank(p.annotation)) parts.add('Annotation: ' + p.annotation);
        return parts.isEmpty() ? null : String.join(parts, ' | ').abbreviate(255);
    }

    private static Date parseDate(String iso) {
        if (String.isBlank(iso)) return Date.today();
        try { return Date.valueOf(iso.substring(0, 10)); }
        catch (Exception e) { return Date.today(); }
    }

    private static String mapPaymentMethod(String raw) {
        if (String.isBlank(raw)) return 'Credit Card';
        String m = raw.toUpperCase();
        if (m.contains('CREDIT') || m.contains('CARD') || m.contains('VISA') || m.contains('MASTERCARD')) return 'Credit Card';
        if (m.contains('BANK') || m.contains('ACH') || m.contains('INTERAC') || m.contains('EFT')) return 'ACH';
        if (m.contains('CHECK') || m.contains('CHEQUE')) return 'Check';
        if (m.contains('CASH')) return 'Cash';
        if (m.contains('PAYPAL')) return 'PayPal';
        return 'Credit Card';
    }

    private static String mapGiftType(String raw) {
        if (String.isBlank(raw)) return 'Individual';
        String t = raw.toUpperCase();
        if (t.contains('MEMBER') || t.contains('ORG') || t.contains('TICKET')) return 'Organizational';
        return 'Individual';
    }

    private static String mapPaymentType(String raw) {
        if (String.isBlank(raw)) return 'Donation';
        String t = raw.toUpperCase();
        if (t.contains('TICKET') || t.contains('EVENT')) return 'Ticket';
        if (t.contains('MEMBER')) return 'Membership';
        if (t.contains('RAFFLE') || t.contains('LOTTERY')) return 'Raffle';
        return 'Donation';
    }

    private static String mapFrequency(String raw) {
        if (String.isBlank(raw)) return 'Monthly';
        String f = raw.toUpperCase();
        if (f.contains('QUARTER')) return 'Quarterly';
        if (f.contains('ANNUAL') || f.contains('YEAR')) return 'Annually';
        return 'Monthly';
    }

    // ─── LWC: dashboard statistics ───────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getDashboardStats() {
        Map<String, Object> stats = new Map<String, Object>();

        // Counts by status
        Map<String, Integer> byStatus = new Map<String, Integer>();
        for (AggregateResult ar : [
            SELECT Status__c s, COUNT(Id) cnt
            FROM Zeffy_Review_Ticket__c
            GROUP BY Status__c
        ]) {
            byStatus.put((String) ar.get('s'), (Integer) ar.get('cnt'));
        }
        stats.put('byStatus', byStatus);
        stats.put('total', [SELECT COUNT() FROM Zeffy_Review_Ticket__c]);

        // Recent resolutions (last 10, shown as up to 5 in LWC)
        List<Zeffy_Review_Ticket__c> recent = [
            SELECT Id, Name, First_Name__c, Last_Name__c, Company_Name__c,
                   Amount__c, Currency__c, Status__c, Resolved_At__c,
                   Resolved_By__c, Resolved_By__r.Name,
                   Resolved_Account__r.Name
            FROM Zeffy_Review_Ticket__c
            WHERE Status__c LIKE 'Resolved%'
            ORDER BY Resolved_At__c DESC NULLS LAST
            LIMIT 10
        ];
        stats.put('recentResolutions', recent);

        return stats;
    }

    // ─── LWC: undo resolution — deletes gift and reopens ticket ──────────────

    @AuraEnabled
    public static void undoResolution(Id ticketId) {
        Zeffy_Review_Ticket__c ticket = [
            SELECT Id, Status__c, Resolved_Gift__c, Resolved_Account__c
            FROM Zeffy_Review_Ticket__c
            WHERE Id = :ticketId
            LIMIT 1
        ];

        Id prevAccountId = ticket.Resolved_Account__c;

        // Delete the associated GiftTransaction if it exists
        if (ticket.Resolved_Gift__c != null) {
            try {
                delete [SELECT Id FROM GiftTransaction WHERE Id = :ticket.Resolved_Gift__c LIMIT 1];
            } catch (Exception e) {
                System.debug('undoResolution: gift delete skipped — ' + e.getMessage());
            }
        }

        // Reopen the ticket
        ticket.Status__c           = 'Pending Review';
        ticket.Resolved_Account__c = null;
        ticket.Resolved_By__c      = null;
        ticket.Resolved_At__c      = null;
        ticket.Resolution_Notes__c = null;
        ticket.Resolved_Gift__c    = null;
        update ticket;

        createAuditLog(ticketId, 'Rolled Back', prevAccountId, null);
    }

    @AuraEnabled
    public static List<DMC_Audit_Log__c> getAuditLog() {
        return [
            SELECT Id, Name,
                   Ticket__c, Ticket__r.Name,
                   Action__c,
                   Performed_By__c, Performed_By__r.Name,
                   Performed_At__c,
                   Account__c, Account__r.Name,
                   Notes__c
            FROM DMC_Audit_Log__c
            ORDER BY Performed_At__c DESC
            LIMIT 200
        ];
    }

    // ─── Donation history row (returned to LWC Donation History tab) ──────────

    public class DonationHistoryRow {
        @AuraEnabled public String  Id;
        @AuraEnabled public String  Name;
        @AuraEnabled public String  DonorName;
        @AuraEnabled public Decimal Amount;
        @AuraEnabled public String  TransactionDate;
        @AuraEnabled public String  PaymentMethod;
        @AuraEnabled public String  ZeffyTransactionId;
        @AuraEnabled public String  TicketName;   // null = auto-processed
        @AuraEnabled public Boolean IsManual;
    }

    @AuraEnabled
    public static List<DonationHistoryRow> getDonationHistory() {
        List<GiftTransaction> gifts = [
            SELECT Id, Name, DonorId, OriginalAmount, TransactionDate,
                   PaymentMethod, Zeffy_Transaction_Id__c
            FROM GiftTransaction
            WHERE Zeffy_Transaction_Id__c != null
            ORDER BY TransactionDate DESC LIMIT 200
        ];
        if (gifts.isEmpty()) return new List<DonationHistoryRow>();

        // Look up Account names (DonorId is polymorphic — separate query is safe)
        Set<Id> donorIds = new Set<Id>();
        for (GiftTransaction g : gifts) {
            if (g.DonorId != null) donorIds.add(g.DonorId);
        }
        Map<Id, String> accountNames = new Map<Id, String>();
        for (Account a : [SELECT Id, Name FROM Account WHERE Id IN :donorIds]) {
            accountNames.put(a.Id, a.Name);
        }

        // Find which gifts came from manual ticket resolution
        Set<Id> giftIds = (new Map<Id, GiftTransaction>(gifts)).keySet();
        Map<Id, String> giftToTicket = new Map<Id, String>();
        for (Zeffy_Review_Ticket__c t : [
            SELECT Resolved_Gift__c, Name
            FROM Zeffy_Review_Ticket__c
            WHERE Resolved_Gift__c IN :giftIds
        ]) {
            giftToTicket.put(t.Resolved_Gift__c, t.Name);
        }

        List<DonationHistoryRow> result = new List<DonationHistoryRow>();
        for (GiftTransaction g : gifts) {
            DonationHistoryRow row = new DonationHistoryRow();
            row.Id                 = g.Id;
            row.Name               = g.Name;
            row.DonorName          = accountNames.containsKey(g.DonorId)
                                     ? accountNames.get(g.DonorId) : '—';
            row.Amount             = g.OriginalAmount;
            row.TransactionDate    = g.TransactionDate != null
                                     ? String.valueOf(g.TransactionDate) : '—';
            row.PaymentMethod      = g.PaymentMethod;
            row.ZeffyTransactionId = g.Zeffy_Transaction_Id__c;
            row.TicketName         = giftToTicket.containsKey(g.Id)
                                     ? giftToTicket.get(g.Id) : null;
            row.IsManual           = giftToTicket.containsKey(g.Id);
            result.add(row);
        }
        return result;
    }

    // ─── Manually assign a ticket to a specific person ────────────────────────
    // Cancels the global auto-task (if open), creates a personal task, and
    // stamps the ticket with the special assignee so the card badge shows it.
    @AuraEnabled
    public static void assignTicket(Id ticketId, String ownerId, String ownerName,
                                    Integer dueDays, String note) {
        if (ticketId == null || String.isBlank(ownerId)) return;

        // 1. Cancel any open global auto-task for this ticket
        List<Task> existing = [
            SELECT Id FROM Task
            WHERE WhatId = :ticketId
              AND Subject LIKE 'Review pending donation%'
              AND IsClosed = false
        ];
        if (!existing.isEmpty()) delete existing;

        // 2. Create the personal task
        Integer days = (dueDays != null && dueDays > 0) ? dueDays : 3;
        Zeffy_Review_Ticket__c t = [SELECT Name, First_Name__c, Last_Name__c, Company_Name__c
                                    FROM Zeffy_Review_Ticket__c WHERE Id = :ticketId LIMIT 1];
        List<String> nameParts = new List<String>();
        if (String.isNotBlank(t.First_Name__c)) nameParts.add(t.First_Name__c);
        if (String.isNotBlank(t.Last_Name__c))  nameParts.add(t.Last_Name__c);
        String donorName = nameParts.isEmpty()
            ? (String.isNotBlank(t.Company_Name__c) ? t.Company_Name__c : t.Name)
            : String.join(nameParts, ' ');

        insert new Task(
            Subject      = 'VIP donation review — ' + donorName,
            ActivityDate = Date.today().addDays(days),
            OwnerId      = ownerId,
            WhatId       = ticketId,
            Status       = 'Not Started',
            Priority     = 'High',
            Description  = String.isNotBlank(note) ? note
                : 'This donor has been personally assigned to you for review in DMC.'
        );

        // 3. Stamp the ticket so the card badge reflects the special assignee
        update new Zeffy_Review_Ticket__c(
            Id                     = ticketId,
            Manual_Assignee_Id__c   = ownerId,
            Manual_Assignee_Name__c = ownerName
        );
    }

    // ─── CSV bulk import (max 500 rows per call, call in chunks from LWC) ────

    @AuraEnabled
    public static Map<String,Object> importTickets(String rowsJson) {
        List<Object> rawRows = (List<Object>) JSON.deserializeUntyped(rowsJson);

        // Collect transaction IDs to detect duplicates
        Set<String> incomingTxIds = new Set<String>();
        for (Object o : rawRows) {
            String txId = csvStr((Map<String,Object>) o, 'transaction_id');
            if (String.isNotBlank(txId)) incomingTxIds.add(txId);
        }
        Set<String> existingTxIds = new Set<String>();
        if (!incomingTxIds.isEmpty()) {
            for (Zeffy_Review_Ticket__c t : [
                SELECT Zeffy_Transaction_Id__c FROM Zeffy_Review_Ticket__c
                WHERE Zeffy_Transaction_Id__c IN :incomingTxIds
            ]) {
                existingTxIds.add(t.Zeffy_Transaction_Id__c);
            }
        }

        List<Zeffy_Review_Ticket__c> toInsert = new List<Zeffy_Review_Ticket__c>();
        Integer skipped = 0;
        for (Object o : rawRows) {
            Map<String,Object> row = (Map<String,Object>) o;
            String txId = csvStr(row, 'transaction_id');
            if (String.isNotBlank(txId) && existingTxIds.contains(txId)) {
                skipped++;
                continue;
            }
            toInsert.add(buildTicketFromCsvRow(row));
        }

        Integer imported = 0;
        List<String> errors = new List<String>();
        if (!toInsert.isEmpty()) {
            for (Database.SaveResult sr : Database.insert(toInsert, false)) {
                if (sr.isSuccess()) {
                    imported++;
                } else {
                    if (errors.size() < 10) errors.add(sr.getErrors()[0].getMessage());
                }
            }
        }
        return new Map<String,Object>{ 'imported' => imported, 'skipped' => skipped, 'errors' => errors };
    }

    private static Zeffy_Review_Ticket__c buildTicketFromCsvRow(Map<String,Object> row) {
        Zeffy_Review_Ticket__c t = new Zeffy_Review_Ticket__c();
        t.Status__c                   = 'Pending Review';
        t.Zeffy_Transaction_Id__c     = csvStr(row, 'transaction_id');
        t.Zeffy_Contact_Id__c         = csvStr(row, 'contact_id');
        t.First_Name__c               = csvStr(row, 'first_name');
        t.Last_Name__c                = csvStr(row, 'last_name');
        t.Email__c                    = csvStr(row, 'email');
        t.Phone__c                    = csvStr(row, 'phone');
        t.Company_Name__c             = csvStr(row, 'company_name');
        t.Address__c                  = csvStr(row, 'address');
        t.City__c                     = csvStr(row, 'city');
        t.Province__c                 = csvStr(row, 'province');
        t.Postal_Code__c              = csvStr(row, 'postal_code');
        t.Country__c                  = csvStr(row, 'country');
        t.Language__c                 = csvStr(row, 'language');
        t.Form_Name__c                = csvStr(row, 'form_name');
        t.Form_Id__c                  = csvStr(row, 'form_id');
        t.Rate_Title__c               = csvStr(row, 'rate_title');
        t.Receipt_URL__c              = csvStr(row, 'receipt_url');
        t.Note__c                     = csvStr(row, 'note');
        t.Annotation__c               = csvStr(row, 'annotation');
        t.Zeffy_Subscription_Id__c    = csvStr(row, 'subscription_id');
        t.Subscription_Frequency__c   = csvStr(row, 'subscription_frequency');
        t.Payment_Method__c           = mapPaymentMethod(csvStr(row, 'payment_method'));
        t.Payment_Type__c             = mapPaymentType(csvStr(row, 'payment_type'));
        String cur = csvStr(row, 'currency');
        t.Currency__c = String.isNotBlank(cur) ? cur : 'CAD';
        t.Receipt_Number__c = csvStr(row, 'receipt_number');
        // Amount
        String amtStr = csvStr(row, 'amount');
        if (String.isNotBlank(amtStr)) {
            try { t.Amount__c = Decimal.valueOf(amtStr.replaceAll('[^0-9.]','')); } catch(Exception e) {}
        }
        String eligStr = csvStr(row, 'eligible_amount');
        if (String.isNotBlank(eligStr)) {
            try { t.Eligible_Amount__c = Decimal.valueOf(eligStr.replaceAll('[^0-9.]','')); } catch(Exception e) {}
        }
        // Gift date — accept YYYY-MM-DD or ISO datetime
        String dt = csvStr(row, 'gift_date');
        if (String.isNotBlank(dt)) {
            try { t.Gift_Date__c = Date.valueOf(dt.length() > 10 ? dt.substring(0,10) : dt); } catch(Exception e) {}
        }
        // Is recurring
        String rec = csvStr(row, 'is_recurring');
        t.Is_Recurring__c = (rec == 'true' || rec == '1' || rec == 'yes' || rec == 'oui');
        return t;
    }

    private static String csvStr(Map<String,Object> row, String key) {
        Object v = row.get(key);
        if (v == null) return null;
        String s = String.valueOf(v).trim();
        return String.isBlank(s) ? null : s;
    }
}
