public with sharing class ZeffyDonationService {

    // ─── Zeffy payload wrapper classes ───────────────────────────────────────

    public class ZeffyEvent {
        public String id;
        public String type;          // "payment.completed"
        public String version;
        public String dispatchedAt;
        public ZeffyPayment data;
    }

    public class ZeffyPayment {
        public String  id;           // Zeffy payment/order ID → Zeffy_Transaction_Id__c
        public String  status;       // "paid", "succeeded"
        public String  type;         // "donation", "ticket", "membership", "raffle"
        public Decimal amount;       // in dollars (CAD/USD)
        public Decimal eligibleAmount;
        public String  currencyIso;  // "CAD", "USD" — renamed: "currency" is reserved in Apex
        public String  paymentMethod;
        public String  created;      // ISO datetime of payment
        public String  receiptNumber;
        public String  receiptUrl;
        public String  rateTitle;
        public String  note;
        public String  annotation;
        public Boolean isRecurring;
        public String  subscriptionId;
        public String  subscriptionFrequency;
        public String  expirationDate;
        public ZeffyContact contact;
        public ZeffyCampaign campaign;
    }

    public class ZeffyContact {
        public String         id;
        public String         firstName;
        public String         lastName;
        public String         name;        // fallback full name if first/last not split
        public String         email;
        public String         phoneNumber;
        public String         companyName;
        public String         language;
        public ZeffyAddress   address;
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

    // ─── Main entry point (called by ZeffyWebhookReceiver) ───────────────────

    public static void processWebhook(String rawBody) {
        ZeffyEvent event;
        try {
            // "currency" is reserved in Apex — remap the JSON key before deserializing
            String processedBody = rawBody.replace('"currency":', '"currencyIso":');
            event = (ZeffyEvent) JSON.deserialize(processedBody, ZeffyEvent.class);
        } catch (Exception ex) {
            // Cannot parse — create an error ticket so nothing is lost
            createErrorTicket(rawBody, 'JSON parse error: ' + ex.getMessage().abbreviate(500));
            return;
        }

        if (event == null || event.data == null) return;
        if (event.type != null && !event.type.equalsIgnoreCase('payment.completed')) return;

        ZeffyPayment payment = event.data;

        // Dedup: skip if already processed (check both Gift_Transaction__c and Zeffy_Review_Ticket__c)
        if (String.isNotBlank(payment.id) && isDuplicate(payment.id)) return;

        // Match Contact by Zeffy Contact ID first, then email
        Contact donor = findDonor(payment);

        if (donor != null) {
            createGiftTransaction(payment, donor.Id, rawBody);
        } else {
            createReviewTicket(payment, rawBody);
        }
    }

    // ─── Donor lookup ─────────────────────────────────────────────────────────

    private static Contact findDonor(ZeffyPayment payment) {
        // 1. Match by Zeffy Contact ID
        if (payment.contact != null && String.isNotBlank(payment.contact.id)) {
            List<Contact> byId = [
                SELECT Id, FirstName, LastName, Email
                FROM Contact
                WHERE Zeffy_Contact_Id__c = :payment.contact.id
                LIMIT 1
            ];
            if (!byId.isEmpty()) return byId[0];
        }
        // 2. Match by email (secondary — common when Zeffy Contact ID not in payload)
        if (payment.contact != null && String.isNotBlank(payment.contact.email)) {
            List<Contact> byEmail = [
                SELECT Id, FirstName, LastName, Email, Zeffy_Contact_Id__c
                FROM Contact
                WHERE Email = :payment.contact.email
                LIMIT 1
            ];
            if (!byEmail.isEmpty()) {
                // Stamp Zeffy ID for future auto-match
                Contact c = byEmail[0];
                if (String.isBlank(c.Zeffy_Contact_Id__c) &&
                    payment.contact != null && String.isNotBlank(payment.contact.id)) {
                    update new Contact(Id = c.Id, Zeffy_Contact_Id__c = payment.contact.id);
                }
                return c;
            }
        }
        return null;
    }

    // ─── Auto-create Gift Transaction for known donor ─────────────────────────

    private static void createGiftTransaction(ZeffyPayment p, Id contactId, String rawBody) {
        Id campaignId = resolveCampaign(p);

        Gift_Transaction__c gt = new Gift_Transaction__c(
            Donor__c                 = contactId,
            Amount__c                = p.amount,
            Eligible_Amount__c       = p.eligibleAmount,
            Payment_Method__c        = mapPaymentMethod(p.paymentMethod),
            Payment_Type__c          = mapPaymentType(p.type),
            Status__c                = 'Received',
            Gift_Date__c             = parseDate(p.created),
            Campaign__c              = campaignId,
            Source__c                = 'Zeffy',
            Language__c              = p.contact != null ? p.contact.language : null,
            Rate_Title__c            = p.rateTitle,
            Note__c                  = p.note,
            Annotation__c            = p.annotation,
            Tax_Receipt_Number__c    = p.receiptNumber,
            Receipt_URL__c           = p.receiptUrl,
            Zeffy_Transaction_Id__c  = p.id,
            Zeffy_Raw_Payload__c     = rawBody
        );
        insert gt;

        // Create/update Gift Commitment for recurring payments
        if (p.isRecurring == true && String.isNotBlank(p.subscriptionId)) {
            createOrUpdateCommitment(p, contactId);
        }

        // Update Contact summary fields (last gift date, amount)
        updateContactSummary(contactId, p);
    }

    private static void createOrUpdateCommitment(ZeffyPayment p, Id contactId) {
        List<Gift_Commitment__c> existing = [
            SELECT Id FROM Gift_Commitment__c
            WHERE Zeffy_Subscription_Id__c = :p.subscriptionId LIMIT 1
        ];
        if (existing.isEmpty()) {
            insert new Gift_Commitment__c(
                Donor__c                  = contactId,
                Amount__c                 = p.amount,
                Frequency__c              = mapFrequency(p.subscriptionFrequency),
                Status__c                 = 'Active',
                Start_Date__c             = parseDate(p.created),
                Zeffy_Subscription_Id__c  = p.subscriptionId,
                Source__c                 = 'Zeffy'
            );
        }
    }

    private static void updateContactSummary(Id contactId, ZeffyPayment p) {
        Date giftDate = parseDate(p.created);
        Contact c = new Contact(Id = contactId);
        c.Last_Gift_Date__c   = giftDate;
        c.Last_Gift_Amount__c = p.amount;
        // Total_Lifetime_Giving__c and Total_Gift_Count__c will be maintained by Flow (Phase 2)
        update c;
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
    }

    private static void createErrorTicket(String rawBody, String errorMsg) {
        Zeffy_Review_Ticket__c ticket = new Zeffy_Review_Ticket__c(
            Status__c       = 'Error',
            Raw_Payload__c  = rawBody,
            Error_Message__c = errorMsg
        );
        insert ticket;
    }

    // ─── Review resolution methods (called from zeffyReviewManager LWC) ───────

    @AuraEnabled
    public static void resolveCreateNew(Id ticketId, String donorType, String notes) {
        Zeffy_Review_Ticket__c t = loadTicket(ticketId);
        String safeType = String.isBlank(donorType) ? 'individual' : donorType.toLowerCase();

        if (safeType == 'individual') {
            // EDA: Household Account + Contact
            Id hhRt = getRecordTypeId('Account', 'HH_Account');
            Account acct = new Account(
                Name         = buildFullName(t.First_Name__c, t.Last_Name__c),
                RecordTypeId = hhRt
            );
            insert acct;

            Contact donor = new Contact(
                FirstName           = t.First_Name__c,
                LastName            = String.isNotBlank(t.Last_Name__c) ? t.Last_Name__c : 'Zeffy',
                Email               = t.Email__c,
                Phone               = t.Phone__c,
                MailingStreet       = t.Address__c,
                MailingCity         = t.City__c,
                MailingState        = t.Province__c,
                MailingPostalCode   = t.Postal_Code__c,
                MailingCountry      = t.Country__c,
                Zeffy_Contact_Id__c = t.Zeffy_Contact_Id__c,
                AccountId           = acct.Id
            );
            insert donor;

            Id giftId = createGiftFromTicketContact(t, donor.Id, acct.Id);
            resolveTicket(t.Id, 'Resolved - New Contact', donor.Id, giftId, notes);
        } else {
            // Église or Organisme — Account only, no Contact
            String rtName = safeType == 'eglise' ? 'Eglise' : 'Organisme';
            Id rtId = getRecordTypeId('Account', rtName);
            String acctName = String.isNotBlank(t.Company_Name__c)
                ? t.Company_Name__c
                : buildFullName(t.First_Name__c, t.Last_Name__c);
            Account acct = new Account(
                Name         = acctName,
                RecordTypeId = rtId,
                Phone        = t.Phone__c,
                BillingStreet       = t.Address__c,
                BillingCity         = t.City__c,
                BillingState        = t.Province__c,
                BillingPostalCode   = t.Postal_Code__c,
                BillingCountry      = t.Country__c
            );
            insert acct;

            Id giftId = createGiftFromTicketAccount(t, acct.Id);
            resolveTicket(t.Id, 'Resolved - New Contact', null, giftId, notes);
        }
    }

    @AuraEnabled
    public static void resolveLinkExisting(Id ticketId, Id contactId, String notes) {
        Zeffy_Review_Ticket__c t = loadTicket(ticketId);

        if (String.isNotBlank(t.Zeffy_Contact_Id__c)) {
            Contact existing = [SELECT Id, Zeffy_Contact_Id__c FROM Contact WHERE Id = :contactId LIMIT 1];
            if (String.isBlank(existing.Zeffy_Contact_Id__c)) {
                update new Contact(Id = contactId, Zeffy_Contact_Id__c = t.Zeffy_Contact_Id__c);
            }
        }

        Id giftId = createGiftFromTicketContact(t, contactId, null);
        resolveTicket(t.Id, 'Resolved - Linked', contactId, giftId, notes);
    }

    @AuraEnabled
    public static void skipTicket(Id ticketId, String reason) {
        update new Zeffy_Review_Ticket__c(
            Id                 = ticketId,
            Status__c          = 'Skipped',
            Resolved_By__c     = UserInfo.getUserId(),
            Resolved_At__c     = DateTime.now(),
            Resolution_Notes__c = reason
        );
    }

    @AuraEnabled(cacheable=true)
    public static List<Zeffy_Review_Ticket__c> getTickets(String statusFilter) {
        String soql =
            'SELECT Id, Name, Status__c, First_Name__c, Last_Name__c, Email__c, ' +
            '       Amount__c, Currency__c, Payment_Type__c, Gift_Date__c, ' +
            '       Form_Name__c, Is_Recurring__c, Company_Name__c, CreatedDate ' +
            'FROM Zeffy_Review_Ticket__c ';
        if (String.isNotBlank(statusFilter) && statusFilter != 'All') {
            soql += 'WHERE Status__c = \'' + String.escapeSingleQuotes(statusFilter) + '\' ';
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
                   Resolved_Contact__c, Resolved_Contact__r.Name,
                   Resolved_Gift__c, Resolved_Gift__r.Name,
                   Resolved_By__c, Resolved_By__r.Name,
                   Resolved_At__c, Resolution_Notes__c
            FROM Zeffy_Review_Ticket__c
            WHERE Id = :ticketId
            LIMIT 1
        ];
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    private static Boolean isDuplicate(String transactionId) {
        return [SELECT COUNT() FROM Gift_Transaction__c WHERE Zeffy_Transaction_Id__c = :transactionId] > 0
            || [SELECT COUNT() FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = :transactionId] > 0;
    }

    private static Zeffy_Review_Ticket__c loadTicket(Id ticketId) {
        return [
            SELECT Id, Status__c, Zeffy_Contact_Id__c, First_Name__c, Last_Name__c,
                   Email__c, Phone__c, Company_Name__c, Language__c,
                   Address__c, City__c, Province__c, Postal_Code__c, Country__c,
                   Amount__c, Eligible_Amount__c,
                   Currency__c, Payment_Method__c, Payment_Type__c, Gift_Date__c,
                   Rate_Title__c, Receipt_Number__c, Receipt_URL__c,
                   Form_Id__c, Form_Name__c, Is_Recurring__c,
                   Zeffy_Subscription_Id__c, Subscription_Frequency__c,
                   Zeffy_Transaction_Id__c, Note__c, Annotation__c, Raw_Payload__c
            FROM Zeffy_Review_Ticket__c
            WHERE Id = :ticketId LIMIT 1
        ];
    }

    private static Id createGiftFromTicket(Zeffy_Review_Ticket__c t, Id contactId) {
        return createGiftFromTicketContact(t, contactId, null);
    }

    private static Id createGiftFromTicketContact(Zeffy_Review_Ticket__c t, Id contactId, Id accountId) {
        Id campaignId = null;
        if (String.isNotBlank(t.Form_Id__c)) {
            List<Campaign> cmp = [SELECT Id FROM Campaign WHERE Zeffy_Form_Id__c = :t.Form_Id__c LIMIT 1];
            if (!cmp.isEmpty()) {
                campaignId = cmp[0].Id;
            } else if (String.isNotBlank(t.Form_Name__c)) {
                Campaign newCmp = new Campaign(
                    Name = t.Form_Name__c,
                    IsActive = true,
                    Zeffy_Form_Id__c = t.Form_Id__c
                );
                insert newCmp;
                campaignId = newCmp.Id;
            }
        }

        Gift_Transaction__c gt = new Gift_Transaction__c(
            Donor__c                = contactId,         // null for org/church donors
            Donor_Account__c        = accountId,         // always populated
            Amount__c               = t.Amount__c,
            Eligible_Amount__c      = t.Eligible_Amount__c,
            Payment_Method__c       = t.Payment_Method__c,
            Payment_Type__c         = t.Payment_Type__c,
            Status__c               = 'Received',
            Gift_Date__c            = t.Gift_Date__c,
            Campaign__c             = campaignId,
            Source__c               = 'Zeffy',
            Language__c             = t.Language__c,
            Rate_Title__c           = t.Rate_Title__c,
            Note__c                 = t.Note__c,
            Annotation__c           = t.Annotation__c,
            Tax_Receipt_Number__c   = t.Receipt_Number__c,
            Receipt_URL__c          = t.Receipt_URL__c,
            Zeffy_Transaction_Id__c = t.Zeffy_Transaction_Id__c,
            Zeffy_Raw_Payload__c    = t.Raw_Payload__c
        );
        insert gt;

        if (t.Is_Recurring__c && String.isNotBlank(t.Zeffy_Subscription_Id__c)) {
            List<Gift_Commitment__c> existing = [
                SELECT Id FROM Gift_Commitment__c
                WHERE Zeffy_Subscription_Id__c = :t.Zeffy_Subscription_Id__c LIMIT 1
            ];
            if (existing.isEmpty()) {
                insert new Gift_Commitment__c(
                    Donor__c                 = contactId,
                    Amount__c                = t.Amount__c,
                    Frequency__c             = mapFrequency(t.Subscription_Frequency__c),
                    Status__c                = 'Active',
                    Start_Date__c            = t.Gift_Date__c,
                    Zeffy_Subscription_Id__c = t.Zeffy_Subscription_Id__c,
                    Source__c                = 'Zeffy'
                );
            }
        }

        return gt.Id;
    }

    private static void resolveTicket(Id ticketId, String status, Id contactId, Id giftId, String notes) {
        update new Zeffy_Review_Ticket__c(
            Id                  = ticketId,
            Status__c           = status,
            Resolved_Contact__c = contactId,
            Resolved_Gift__c    = giftId,
            Resolved_By__c      = UserInfo.getUserId(),
            Resolved_At__c      = DateTime.now(),
            Resolution_Notes__c = notes
        );
    }

    private static Id resolveCampaign(ZeffyPayment p) {
        if (p.campaign == null || String.isBlank(p.campaign.id)) return null;
        List<Campaign> campaigns = [
            SELECT Id FROM Campaign WHERE Zeffy_Form_Id__c = :p.campaign.id LIMIT 1
        ];
        if (!campaigns.isEmpty()) return campaigns[0].Id;
        Campaign newCmp = new Campaign(
            Name             = String.isNotBlank(p.campaign.name) ? p.campaign.name : ('Zeffy Form ' + p.campaign.id),
            IsActive         = true,
            Zeffy_Form_Id__c = p.campaign.id
        );
        insert newCmp;
        return newCmp.Id;
    }

    private static Id createGiftFromTicketAccount(Zeffy_Review_Ticket__c t, Id accountId) {
        return createGiftFromTicketContact(t, null, accountId);
    }

    private static Id getRecordTypeId(String sObjectType, String developerName) {
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = :sObjectType AND DeveloperName = :developerName AND IsActive = true
            LIMIT 1
        ];
        return rts.isEmpty() ? null : rts[0].Id;
    }

    private static String buildFullName(String firstName, String lastName) {
        String fn = String.isNotBlank(firstName) ? firstName : '';
        String ln = String.isNotBlank(lastName)  ? lastName  : 'Zeffy Donor';
        return (fn + ' ' + ln).trim();
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
        if (m.contains('BANK') || m.contains('TRANSFER') || m.contains('INTERAC') || m.contains('EFT')) return 'Bank Transfer';
        if (m.contains('CHECK') || m.contains('CHEQUE')) return 'Check';
        if (m.contains('CASH')) return 'Cash';
        return 'Other';
    }

    private static String mapPaymentType(String raw) {
        if (String.isBlank(raw)) return 'Donation';
        String t = raw.toUpperCase();
        if (t.contains('TICKET') || t.contains('EVENT')) return 'Ticket';
        if (t.contains('MEMBER')) return 'Membership';
        if (t.contains('RAFFLE') || t.contains('LOTTERY')) return 'Raffle';
        if (t.contains('DONATION') || t.contains('GIFT')) return 'Donation';
        return 'Other';
    }

    private static String mapFrequency(String raw) {
        if (String.isBlank(raw)) return 'Monthly';
        String f = raw.toUpperCase();
        if (f.contains('MONTH')) return 'Monthly';
        if (f.contains('QUARTER')) return 'Quarterly';
        if (f.contains('ANNUAL') || f.contains('YEAR')) return 'Annual';
        return 'Monthly';
    }
}
