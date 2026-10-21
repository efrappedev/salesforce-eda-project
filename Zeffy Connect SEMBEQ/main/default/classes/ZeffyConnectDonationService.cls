// inherited sharing: with sharing when called from LWC (@AuraEnabled entry point);
// without sharing when called by ZeffyConnectWebhookReceiver (Guest User, HMAC-validated).
public inherited sharing class ZeffyConnectDonationService {

    @TestVisible private static Boolean failAuditLog              = false;
    @TestVisible private static Boolean failCommitmentInsert      = false;
    @TestVisible private static Boolean skipDuplicateCheckForTest = false;
    @TestVisible private static Boolean forceDmlBeforeProcess       = false;
    @TestVisible private static Boolean forceExceptionBeforeProcess = false;
    @TestVisible private static Boolean failExtractBuyerQuestions   = false;
    @TestVisible private static Boolean failGiftDelete              = false;
    @TestVisible private static Boolean failCommitmentDelete        = false;
    @TestVisible private static Boolean failCommitmentSync          = false;
    @TestVisible private static Boolean failCampaignCreate          = false;
    @TestVisible private static Boolean failAddressUpdate           = false;
    @TestVisible private static Boolean failCampaignRemoval         = false;
    @TestVisible private static Boolean failSoslSearch              = false;
    @TestVisible private static Boolean failErrorTicketInsert       = false;

    @TestVisible class ForcedTestException extends Exception {}

    // ─── Zeffy payload wrapper classes (mirrors real Zeffy API snake_case) ────

    public class ZeffyEvent {
        public String     id;
        public String     type;
        public Integer    version;
        public String     dispatchedAt;
        public ZeffyPayment data;
    }

    public class ZeffyPayment {
        public String  id;
        public String  status;
        public String  type;           // online | manual | imported
        public Long    created;        // Unix timestamp (seconds)
        public Decimal amount;         // cents
        public Decimal eligible_amount;
        public String  currencyIso;    // filled by pre-processing replace("currency":"→"currencyIso":)
        public String  refund_status;
        public String  campaign_id;
        public String  campaign_type;
        public String  campaign_category;
        public String  description;    // campaign title
        public String  occurrence_id;
        public String  receipt_url;
        public String  contact;        // Zeffy Contact UUID (unique per email — primary match key)
        public ZeffyBuyer              buyer;
        public ZeffyPaymentMethod      payment_method;
        public ZeffyFund               fund;
        public ZeffyDispute            dispute;
        public ZeffyRecurring          recurring;
        public ZeffyDiscount           discount;
        public List<ZeffyRefund>        refunds;
        public List<ZeffyItem>          items;
        // buyer_questions omitted — answer field is polymorphic (String|Boolean|Array)
        // extracted separately via deserializeUntyped() in extractBuyerQuestionsText()
    }

    public class ZeffyBuyer {
        public String  email;
        public String  first_name;
        public String  last_name;
        public Boolean is_corporate;
        public String  company_name;
        public ZeffyAddress address;
    }

    public class ZeffyAddress {
        public String line1;
        public String city;
        public String state;
        public String postal_code;
        public String country;
    }

    public class ZeffyPaymentMethod {
        public String type;
        public String brand;
        public String last4;
    }

    public class ZeffyFund {
        public String            id;
        public String            code;
        public ZeffyFundName     name;
    }

    public class ZeffyFundName {
        public String EN;
        public String FR;
        public String ES;
    }

    public class ZeffyDispute {
        public String  id;
        public Decimal amount;
        public String  status;
        public String  reason;
        public Long    created;
    }

    public class ZeffyRecurring {
        public Boolean is_recurring;
        public String  status;
        public String  interval;
        public String  subscription_id;
        public Long    current_period_start;
        public Long    current_period_end;
    }

    public class ZeffyDiscount {
        public String  code;
        public Decimal amount;
    }

    public class ZeffyRefund {
        public String  id;
        public Decimal amount;
        public String  status;
        public Long    created;
    }

    public class ZeffyItem {
        public String  id;
        public String  type;
        public Decimal amount;
        public String  rate_title;
        public String  contact_id;
        // questions omitted — answer is polymorphic; extracted via deserializeUntyped()
        public ZeffyTribute tribute;
    }

    public class ZeffyTribute {
        public String type;
        public String honouree_name;
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
        public Boolean preferred = false;      // account type fits the donor (person vs church/business)
        public Integer compareTo(Object other) {
            AccountMatch o = (AccountMatch) other;
            if (o.score != this.score) return o.score - this.score; // sort DESC
            return (o.preferred ? 1 : 0) - (this.preferred ? 1 : 0);
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<AccountMatch> findAccountMatches(Id ticketId) {
        requireZeffyAccess();
        Zeffy_Review_Ticket__c t = [
            SELECT First_Name__c, Last_Name__c, Email__c, Company_Name__c, Is_Corporate__c
            FROM Zeffy_Review_Ticket__c WHERE Id = :ticketId LIMIT 1
        ];
        Map<Id, AccountMatch> matchMap = new Map<Id, AccountMatch>();

        String tEmail   = String.isNotBlank(t.Email__c)        ? t.Email__c.toLowerCase().trim()        : null;
        String tFirst   = String.isNotBlank(t.First_Name__c)   ? t.First_Name__c.toLowerCase().trim()   : null;
        String tLast    = String.isNotBlank(t.Last_Name__c)     ? t.Last_Name__c.toLowerCase().trim()    : null;
        String tCompany = String.isNotBlank(t.Company_Name__c)  ? t.Company_Name__c.toLowerCase().trim() : null;
        // On equal scores, a person comes first for an individual donor and a
        // church/business/organization for a company donation (Zeffy is_corporate or company_name)
        Boolean ticketIsOrg = tCompany != null || t.Is_Corporate__c == true;
        String fullName = ((String.isNotBlank(t.First_Name__c) ? t.First_Name__c : '') + ' '
            + (String.isNotBlank(t.Last_Name__c) ? t.Last_Name__c : '')).normalizeSpace();

        // SEMBEQ (EDA, no Person Accounts): a person is a Contact in an Administrative Account;
        // churches, businesses and organizations are Accounts. Candidates are collected as
        // Account Ids from both Account and Contact fields.
        Set<Id> candidateIds = new Set<Id>();
        // 1. Match by email (exact) — Account email fields + Contact.Email → AccountId
        if (tEmail != null) candidateIds.addAll(findAccountIdsByEmail(t.Email__c.trim(), 10));
        // 2. Exact name first, so the right account is never pushed out by the LIMIT of the LIKE search:
        //    same first + last name (person Contact) or Account.Name = full name / company (church, business)
        if (tFirst != null && tLast != null) {
            for (Contact c : [SELECT AccountId FROM Contact
                              WHERE FirstName = :t.First_Name__c.trim() AND LastName = :t.Last_Name__c.trim()
                                AND AccountId != null LIMIT 10]) {
                candidateIds.add(c.AccountId);
            }
        }
        Set<String> exactNames = new Set<String>();
        if (String.isNotBlank(fullName)) exactNames.add(fullName);
        if (tCompany != null) exactNames.add(t.Company_Name__c.normalizeSpace());
        if (!exactNames.isEmpty()) {
            for (Account a : [SELECT Id FROM Account WHERE Name IN :exactNames LIMIT 10]) candidateIds.add(a.Id);
        }
        // 3. Partial match by last name (Account.Name + Contact.LastName) and by company name
        Set<String> likes = new Set<String>();
        if (tLast != null)    likes.add('%' + t.Last_Name__c.trim() + '%');
        if (tCompany != null) likes.add('%' + t.Company_Name__c.trim() + '%');
        for (String nameLike : likes) {
            for (Account a : [SELECT Id FROM Account WHERE Name LIKE :nameLike ORDER BY Name LIMIT 10]) {
                candidateIds.add(a.Id);
            }
        }
        if (tLast != null) {
            String lastLike = '%' + t.Last_Name__c.trim() + '%';
            for (Contact c : [SELECT AccountId FROM Contact
                              WHERE LastName LIKE :lastLike AND AccountId != null LIMIT 10]) {
                candidateIds.add(c.AccountId);
            }
        }
        // 4. SOQL is accent and hyphen sensitive: SOSL also finds "Côté" for "Cote", "Saint Jean" for "Saint-Jean"
        String soslTerms = soslTerm(tCompany != null ? t.Company_Name__c : t.Last_Name__c);
        if (soslTerms != null) {
            try {
                if (failSoslSearch) throw new System.SearchException('Forced SOSL failure');
                List<List<SObject>> hits = Search.query('FIND \'' + soslTerms + '\' IN NAME FIELDS RETURNING '
                    + 'Account(Id LIMIT 10), Contact(AccountId WHERE AccountId != null LIMIT 10)');
                for (Account a : (List<Account>) hits[0]) candidateIds.add(a.Id);
                for (Contact c : (List<Contact>) hits[1]) candidateIds.add(c.AccountId);
            } catch (Exception e) {
                // Extra recall only: the email and name searches above are enough on their own
                System.debug('Account SOSL search skipped: ' + e.getMessage());
            }
        }
        for (Account a : queryAccountsWithContacts(candidateIds)) {
            if (matchMap.containsKey(a.Id)) continue;
            AccountMatch m = buildAccountMatch(a);
            m.score = calcAccountScore(a, tEmail, tFirst, tLast, tCompany);
            m.preferred = isPersonAccount(a) != ticketIsOrg;
            matchMap.put(a.Id, m);
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
        m.name  = accountDisplayName(a);
        m.email = accountEmail(a);
        m.phone = a.Phone;
        m.city  = a.BillingCity;
        m.matchType = isPersonAccount(a) ? 'Person'
                    : (a.RecordType != null ? a.RecordType.Name : null);
        return m;
    }

    // ─── SEMBEQ Account helpers (no Person Accounts — email lives on Account custom fields or Contacts)

    // A person in SEMBEQ = an EDA Administrative Account (its Contact carries the names/email)
    private static Boolean isPersonAccount(Account a) {
        return a != null && a.RecordType != null && a.RecordType.DeveloperName == 'Administrative';
    }

    // A person shows by the Contact's name, never as "X Administrative Account"
    private static String accountDisplayName(Account a) {
        if (isPersonAccount(a) && a.Contacts != null && !a.Contacts.isEmpty()) {
            Contact c = a.Contacts[0];
            return ((String.isNotBlank(c.FirstName) ? c.FirstName : '') + ' ' + c.LastName).normalizeSpace();
        }
        return a.Name;
    }

    private static List<Account> queryAccountsWithContacts(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) return new List<Account>();
        return [
            SELECT Id, Name, Phone, BillingCity, Email_Address__c, Email_Personal__c,
                   RecordType.DeveloperName, RecordType.Name,
                   (SELECT Id, FirstName, LastName, Email FROM Contacts ORDER BY CreatedDate LIMIT 5)
            FROM Account WHERE Id IN :accountIds LIMIT 50
        ];
    }

    // Account Ids whose Account email fields or Contact.Email match exactly
    private static Set<Id> findAccountIdsByEmail(String email, Integer lim) {
        Set<Id> ids = new Set<Id>();
        if (String.isBlank(email)) return ids;
        for (Account a : [SELECT Id FROM Account
                          WHERE Email_Address__c = :email OR Email_Personal__c = :email LIMIT :lim]) {
            ids.add(a.Id);
        }
        for (Contact c : [SELECT AccountId FROM Contact
                          WHERE Email = :email AND AccountId != null LIMIT :lim]) {
            ids.add(c.AccountId);
        }
        return ids;
    }

    private static String accountEmail(Account a) {
        if (String.isNotBlank(a.Email_Address__c))  return a.Email_Address__c;
        if (String.isNotBlank(a.Email_Personal__c)) return a.Email_Personal__c;
        if (a.Contacts != null) {
            for (Contact c : a.Contacts) { if (String.isNotBlank(c.Email)) return c.Email; }
        }
        return null;
    }

    // Best score across the Account itself and each of its Contacts
    private static Integer calcAccountScore(Account a, String tEmail, String tFirst, String tLast, String tCompany) {
        Integer best = calcScore(accountEmail(a), null, null, a.Name, tEmail, tFirst, tLast, tCompany);
        String fLast = foldName(tLast), aName = foldName(a.Name);
        if (fLast != null && aName != null && aName.contains(fLast)) best = Math.max(best, 30);
        if (a.Contacts != null) {
            for (Contact c : a.Contacts) {
                String em = String.isNotBlank(c.Email) ? c.Email : accountEmail(a);
                best = Math.max(best, calcScore(em, c.FirstName, c.LastName, a.Name, tEmail, tFirst, tLast, tCompany));
            }
        }
        return best;
    }

    // Donor Contact for a gift: Contact matching the payer email, else EDA primary contact,
    // else the only Contact of the Account. Churches/organizations usually return null.
    private static Id resolveDonorContactId(Id accountId, String email) {
        if (accountId == null) return null;
        List<Account> accts = [
            SELECT hed__Primary_Contact__c,
                   (SELECT Id, Email FROM Contacts ORDER BY CreatedDate LIMIT 2)
            FROM Account WHERE Id = :accountId LIMIT 1
        ];
        if (accts.isEmpty()) return null;
        Account a = accts[0];
        if (String.isNotBlank(email)) {
            List<Contact> byEmail = [SELECT Id FROM Contact WHERE AccountId = :accountId AND Email = :email LIMIT 1];
            if (!byEmail.isEmpty()) return byEmail[0].Id;
        }
        if (a.hed__Primary_Contact__c != null) return a.hed__Primary_Contact__c;
        if (a.Contacts.size() == 1) return a.Contacts[0].Id;
        return null;
    }

    private static final Map<String, String> NAME_FOLD = new Map<String, String>{
        'à' => 'a', 'á' => 'a', 'â' => 'a', 'ã' => 'a', 'ä' => 'a', 'å' => 'a', 'æ' => 'ae',
        'ç' => 'c', 'è' => 'e', 'é' => 'e', 'ê' => 'e', 'ë' => 'e',
        'ì' => 'i', 'í' => 'i', 'î' => 'i', 'ï' => 'i', 'ñ' => 'n',
        'ò' => 'o', 'ó' => 'o', 'ô' => 'o', 'õ' => 'o', 'ö' => 'o', 'œ' => 'oe',
        'ù' => 'u', 'ú' => 'u', 'û' => 'u', 'ü' => 'u', 'ý' => 'y', 'ÿ' => 'y', '-' => ' '
    };
    // Words of a name as a SOSL search (all words must match), or null if there is nothing to search
    @TestVisible
    private static String soslTerm(String name) {
        if (String.isBlank(name)) return null;
        String clean = name.replaceAll('[?&|!{}\\[\\]()^~*:\\\\"\'+\\-]', ' ').normalizeSpace();
        List<String> words = new List<String>();
        for (String w : clean.split(' ')) if (w.length() > 1) words.add(w);
        // Each word quoted: "and", "or", "not" in a name ("Smith and Sons") are words, not operators
        return words.isEmpty() ? null : '"' + String.join(words, '" AND "') + '"';
    }

    // Lower case, no accents, single spaces: "Église  Saint-Jean" → "eglise saint jean"
    @TestVisible
    private static String foldName(String v) {
        if (String.isBlank(v)) return null;
        String r = v.toLowerCase();
        for (String k : NAME_FOLD.keySet()) r = r.replace(k, NAME_FOLD.get(k));
        r = r.normalizeSpace();
        return String.isBlank(r) ? null : r;
    }

    private static Integer calcScore(String acctEmail, String acctFirst, String acctLast, String acctName,
                                     String tEmail, String tFirst, String tLast, String tCompany) {
        Integer s = 0;
        String aFirst = foldName(acctFirst), aLast = foldName(acctLast), aName = foldName(acctName);
        String fFirst = foldName(tFirst), fLast = foldName(tLast), fCompany = foldName(tCompany);
        // Email exact match: 50 pts
        if (tEmail != null && String.isNotBlank(acctEmail) && acctEmail.toLowerCase().trim() == tEmail) s += 50;
        // Last name / company match: 30 pts
        if (fLast != null && aLast != null && aLast == fLast) {
            s += 30;
        } else if (fCompany != null && aName != null && aName.contains(fCompany)) {
            s += 30;
        }
        // First name match: 20 pts
        if (fFirst != null && aFirst != null && aFirst == fFirst) s += 20;
        // Same full name scores 80 for a person and for a church/business alike. Church / business /
        // org accounts have no First/Last: Zeffy splits their name across both ("Heron Family" +
        // "Foundation"), so the full name (or company) is compared with Account.Name
        if (aLast != null) {
            if (fFirst != null && fLast != null && aFirst == fFirst && aLast == fLast) s += 30;
        } else if (aName != null) {
            String tFull = ((fFirst != null ? fFirst : '') + ' ' + (fLast != null ? fLast : '')).normalizeSpace();
            if ((String.isNotBlank(tFull) && aName == tFull) || (fCompany != null && aName == fCompany)) {
                s += 80;
            }
        }
        return Math.min(s, 100);
    }

    // Returned to LWC for the "link existing" preview
    public class LinkPreview {
        @AuraEnabled public String  accountId;
        @AuraEnabled public String  accountName;
        @AuraEnabled public Boolean isPersonAccount;
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
        @AuraEnabled public String  accountAddressCore; // without the country, for the "same address" check
        @AuraEnabled public String  ticketAddress;
        @AuraEnabled public Boolean addressesDiffer;
        // Address parts, so the reviewer can correct them before updating the Account
        @AuraEnabled public String  ticketStreet;
        @AuraEnabled public String  ticketCity;
        @AuraEnabled public String  ticketProvince;
        @AuraEnabled public String  ticketPostalCode;
        @AuraEnabled public String  ticketCountry;
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

    // ─── Structured result returned to ZeffyConnectWebhookReceiver ─────────

    public class WebhookResult {
        public String  status;        // matches Zeffy_Webhook_Log__c Status__c picklist
        public String  transactionId;
        public String  donorName;
        public Decimal amount;        // dollars (not cents)
        public String  message;       // short human-readable summary
        public String  detail;        // technical detail for diagnostics
        public String  eventType;     // payment.created, payment.completed, payment.updated, etc.
        public Boolean retryable = false; // true → receiver answers 5xx so Zeffy retries (all DML rolled back)
    }

    // ─── Main entry point (keeps old signature for legacy callers) ───────────

    public static void processWebhook(String rawBody) {
        processWebhookWithResult(rawBody);
    }

    public static WebhookResult processWebhookWithResult(String rawBody) {
        WebhookResult res = new WebhookResult();

        // 1. Parse JSON
        ZeffyEvent event;
        try {
            String processedBody = rawBody.replace('"currency":', '"currencyIso":');
            event = (ZeffyEvent) JSON.deserialize(processedBody, ZeffyEvent.class);
        } catch (Exception ex) {
            createErrorTicket(rawBody, 'JSON parse error: ' + ex.getMessage().abbreviate(500));
            res.status  = 'INVALID_JSON';
            res.message = 'Could not parse Zeffy JSON payload.';
            res.detail  = ex.getMessage().abbreviate(500);
            return res;
        }

        if (event == null || event.data == null) {
            res.status  = 'INVALID_JSON';
            res.message = 'Zeffy payload parsed but event or data was null.';
            return res;
        }

        res.eventType = event.type;

        ZeffyPayment payment = event.data;
        if (String.isNotBlank(payment.id)) {
            res.transactionId = payment.id;
            res.amount        = payment.amount != null ? payment.amount / 100 : null;
        }
        if (payment.buyer != null) {
            List<String> parts = new List<String>();
            if (String.isNotBlank(payment.buyer.first_name)) parts.add(payment.buyer.first_name);
            if (String.isNotBlank(payment.buyer.last_name))  parts.add(payment.buyer.last_name);
            if (parts.isEmpty() && String.isNotBlank(payment.buyer.company_name)) parts.add(payment.buyer.company_name);
            res.donorName = parts.isEmpty() ? null : String.join(parts, ' ');
        }

        // 2. Route by event type
        Zeffy_Config__c cfg = ZeffyConnectConfigService.getConfig();
        String evtType = event.type != null ? event.type.toLowerCase() : '';

        // All-or-nothing: a failure halfway (e.g. GT inserted, ticket update failed) must not leave
        // partial records behind — Zeffy retries the whole event and idempotency handles the rest.
        Savepoint sp = Database.setSavepoint();
        try {
            if (forceDmlBeforeProcess) { insert new Campaign(); }
            if (forceExceptionBeforeProcess) throw new ForcedTestException('Forced test exception');
            if (evtType.equals('payment.completed')) {
                processPaymentCompleted(payment, rawBody, res);

            } else if (evtType.equals('payment.created') && cfg != null && cfg.Process_Payment_Created__c) {
                processPaymentCreated(payment, rawBody, res);

            } else if (evtType.equals('payment.updated') && cfg != null && cfg.Process_Payment_Updated__c) {
                processPaymentUpdated(payment, rawBody, res);

            } else if (evtType.equals('payment.deleted') && cfg != null && cfg.Process_Payment_Deleted__c) {
                processPaymentDeleted(payment, rawBody, res);

            } else if (evtType.startsWith('contact.') && cfg != null && cfg.Process_Contact_Events__c) {
                // Nothing is created for contact events yet: the payload stays in the webhook log
                // so staff can read it (manual review) instead of it vanishing as a SUCCESS.
                res.status  = 'IGNORED';
                res.message = 'Contact event "' + event.type + '" received — not processed automatically, manual review required (payload kept in the log).';

            } else {
                // Toggle off or unsupported type: logged with its payload so it can be reprocessed
                // from Robot Health once the matching toggle is turned on.
                res.status  = 'IGNORED';
                res.message = 'Event type "' + event.type + '" ignored (toggle off or unsupported) — payload kept, reprocess it after turning the toggle on.';
            }
        } catch (DmlException dml) {
            Database.rollback(sp);
            // Only a collision on the transaction ID is a duplicate retry. Other unique keys (subscription,
            // Zeffy contact, form) colliding = a parallel event created it first → retryable, the retry links to it.
            // The DML message does not always name the field (often "<unknown>"), so check the data instead.
            Boolean isUniqueErr = dml.getDmlType(0) == StatusCode.DUPLICATE_VALUE || dml.getMessage().contains('DUPLICATE_VALUE');
            Boolean isDupErr = isUniqueErr && String.isNotBlank(res.transactionId) && isDuplicate(res.transactionId);
            if (isDupErr) {
                res.status  = 'DUPLICATE_SKIPPED';
                res.message = 'Transaction ' + (String.isNotBlank(res.transactionId) ? res.transactionId : '?') + ' already exists — duplicate webhook retry from Zeffy.';
                res.detail  = 'Race condition: two simultaneous webhooks for the same transaction ID. First one succeeded. DML: ' + dml.getMessage().abbreviate(500);
            } else {
                res.status    = 'TICKET_INSERT_FAILED';
                res.retryable = true;
                res.message = 'DML error processing "' + event.type + '": ' + dml.getMessage().abbreviate(400);
                res.detail  = 'Type: DmlException | Line: ' + dml.getLineNumber() + ' | Stack: ' + dml.getStackTraceString().abbreviate(3000);
            }
        } catch (Exception ex) {
            Database.rollback(sp);
            res.status    = 'TICKET_INSERT_FAILED';
            res.retryable = true;
            res.message = 'Unexpected error processing "' + event.type + '": ' + ex.getMessage().abbreviate(400);
            res.detail  = 'Type: ' + ex.getTypeName() + ' | Line: ' + ex.getLineNumber() + ' | Stack: ' + ex.getStackTraceString().abbreviate(3000);
        }

        return res;
    }

    // ─── payment.completed — full auto-match + gift or review ticket ─

    private static void processPaymentCompleted(ZeffyPayment payment, String rawBody, WebhookResult res) {
        if (String.isBlank(payment.id)) {
            res.status  = 'MISSING_TX_ID';
            res.message = 'Zeffy payment has no transaction ID (payment.id is blank).';
            return;
        }
        // Zeffy's payment.completed can come without data.status — the event itself means paid.
        // Without this the ticket's "pending" (from payment.created) was wiped to blank.
        if (String.isBlank(payment.status)) payment.status = 'succeeded';

        // Graduate a ticket created by payment.created → payment.completed. Delayed (Holding expired
        // by ZeffyHoldingExpireBatch) and Payment Failed (unless Zeffy deleted it) graduate too:
        // a late confirmation must never be dropped as a duplicate.
        List<Zeffy_Review_Ticket__c> holdingList = [
            SELECT Id, Status__c FROM Zeffy_Review_Ticket__c
            WHERE Zeffy_Transaction_Id__c = :payment.id
              AND (Status__c IN ('Holding', 'Delayed')
                   OR (Status__c = 'Payment Failed' AND Transaction_Status__c != 'deleted'))
            LIMIT 1
        ];
        if (!holdingList.isEmpty()) {
            Zeffy_Review_Ticket__c tkt = holdingList[0];
            String prevStatus = tkt.Status__c;
            // Update receipt URL and transaction status before any further action
            tkt.Transaction_Status__c = String.isNotBlank(payment.status) ? payment.status : null;
            if (String.isNotBlank(payment.receipt_url)) tkt.Receipt_URL__c = payment.receipt_url;
            // payment.completed is the final word on what was paid: refresh what payment.created
            // may have sent incomplete (amount, eligible amount, card) before the gift is built.
            if (payment.amount != null)          tkt.Amount__c          = payment.amount / 100;
            if (payment.eligible_amount != null) tkt.Eligible_Amount__c = payment.eligible_amount / 100;
            if (payment.payment_method != null) {
                tkt.Payment_Method__c = mapPaymentMethod(payment.payment_method);
                if (String.isNotBlank(payment.payment_method.brand)) tkt.Card_Brand__c = payment.payment_method.brand;
                if (String.isNotBlank(payment.payment_method.last4)) tkt.Card_Last4__c = payment.payment_method.last4;
            }

            Account donor = findDonor(payment);
            if (donor != null) {
                // Auto-resolve: link Zeffy Identity + create gift + close ticket
                tkt.Status__c = 'Pending Review';
                update tkt;
                linkExistingCore(tkt.Id, donor.Id,
                    'Auto-resolved: payment confirmed, donor matched via ' + lastDonorMatchMethod + '.',
                    null, false, false, false, null);
                // Resolved by the robot, not by a person
                update new Zeffy_Review_Ticket__c(Id = tkt.Id, Status__c = 'Auto-Processed', Resolved_By__c = null);
                res.status    = 'SUCCESS';
                res.message   = prevStatus + ' ticket auto-resolved: gift created for "' + donor.Name + '".';
                res.detail    = 'Transaction ID: ' + payment.id + ' | Account: ' + donor.Id;
                res.donorName = donor.Name;
            } else {
                // Donor not found — promote to Pending Review for manual handling
                tkt.Status__c = 'Pending Review';
                update tkt;
                createAuditLog(tkt.Id, 'Payment Confirmed', null,
                    prevStatus + ' → Pending Review (payment.completed) — donor not found, manual review needed.');
                createPendingTask(tkt, payment.buyer);
                res.status  = 'SUCCESS';
                res.message = prevStatus + ' ticket graduated to Pending Review — donor not found, manual review needed.';
                res.detail  = 'Transaction ID: ' + payment.id;
            }
            return;
        }

        // Ticket already past Holding/Delayed (moved to review by hand, resolved, or created before
        // its completed event was recorded): record the confirmation so the Payment Status is right
        // and the ticket can no longer be sent back to Holding/Delayed. Review stays manual.
        List<Zeffy_Review_Ticket__c> manualList = [
            SELECT Id, Status__c, Pre_Review_Status__c, Resolved_Gift__c FROM Zeffy_Review_Ticket__c
            WHERE Zeffy_Transaction_Id__c = :payment.id
              AND (Transaction_Status__c = null OR Transaction_Status__c NOT IN ('succeeded', 'deleted'))
            LIMIT 1
        ];
        if (!manualList.isEmpty()) {
            Zeffy_Review_Ticket__c mt = manualList[0];
            String prevStatus = mt.Status__c;
            mt.Transaction_Status__c = String.isNotBlank(payment.status) ? payment.status : 'succeeded';
            if (String.isNotBlank(payment.receipt_url)) mt.Receipt_URL__c = payment.receipt_url;
            mt.Pre_Review_Status__c = null;
            // Closed/Skipped without a gift (e.g. a Holding the staff gave up on): the money is now
            // real in Zeffy, so the ticket must come back for review or the donation is lost.
            Boolean reopen = (prevStatus == 'Closed' || prevStatus == 'Skipped') && mt.Resolved_Gift__c == null;
            if (reopen) mt.Status__c = 'Pending Review';
            update mt;
            if (reopen) {
                createAuditLog(mt.Id, 'Payment Confirmed', null,
                    'Payment confirmed by Zeffy (payment.completed) after the ticket was ' + prevStatus
                    + ' — reopened to Pending Review so the donation is not lost.');
                createPendingTask(mt, payment.buyer);
                res.message = prevStatus + ' ticket reopened to Pending Review: Zeffy confirmed the payment.';
            } else {
                createAuditLog(mt.Id, 'Payment Confirmed', null,
                    'Payment confirmed by Zeffy (payment.completed) — ticket was already in ' + prevStatus + '.');
                res.message = 'Payment confirmed for a ticket already in ' + prevStatus + '.';
            }
            res.status  = 'SUCCESS';
            res.detail  = 'Transaction ID: ' + payment.id;
            return;
        }

        if (!skipDuplicateCheckForTest && isDuplicate(payment.id)) {
            res.status  = 'DUPLICATE_SKIPPED';
            res.message = 'Transaction ' + payment.id + ' already exists in SF — skipped.';
            res.detail  = 'Zeffy_Transaction_Id__c = ' + payment.id + ' found in Gift_Transaction__c or Zeffy_Review_Ticket__c.';
            return;
        }
        String buyerQuestionsText = extractBuyerQuestionsText(rawBody);
        Account donor = findDonor(payment);
        if (donor != null) {
            Id gtId = createGiftTransaction(payment, donor.Id, rawBody);
            // Every robot action gets its own ticket (status Auto-Processed) so staff can open it,
            // follow it up and undo it like any manual resolution. No task: nothing to review.
            String autoNotes = 'Auto-processed by the robot: donor matched via ' + lastDonorMatchMethod + '.';
            Zeffy_Review_Ticket__c autoTkt = buildReviewTicket(payment, rawBody, buyerQuestionsText);
            autoTkt.Status__c           = 'Auto-Processed';
            autoTkt.Resolved_Account__c = donor.Id;
            autoTkt.Resolved_Gift__c    = gtId;
            autoTkt.Resolved_At__c      = DateTime.now();
            autoTkt.Resolution_Notes__c = autoNotes;
            autoTkt.Address_Differs__c  = addressDiffers(autoTkt, loadBillingAddress(donor.Id));
            insert autoTkt;
            if (commitmentError != null) {
                logCommitmentNotCreated(autoTkt.Id, donor.Id, autoTkt.Zeffy_Subscription_Id__c, commitmentError);
                commitmentError = null;
            }
            createAuditLog(autoTkt.Id, 'Auto-Processed', donor.Id,
                'Gift ' + gtId + ' created automatically (donor matched via ' + lastDonorMatchMethod
                + ') — Zeffy transaction ' + payment.id + ', ' + formatMoney(payment.amount != null ? payment.amount / 100 : null) + '.');
            res.status    = 'SUCCESS';
            res.message   = 'Auto-processed: gift created for "' + donor.Name + '".';
            res.detail    = 'Transaction ID: ' + payment.id + ' | Account: ' + donor.Id;
            res.donorName = donor.Name;
        } else {
            createReviewTicket(payment, rawBody, buyerQuestionsText);
            res.status  = 'SUCCESS';
            res.message = 'Review ticket created — donor not found in SF.';
            res.detail  = 'Transaction ID: ' + payment.id;
        }
    }

    // ─── payment.created — create Holding ticket (funnel visibility) ──────────

    private static void processPaymentCreated(ZeffyPayment payment, String rawBody, WebhookResult res) {
        if (String.isBlank(payment.id)) {
            res.status  = 'MISSING_TX_ID';
            res.message = 'payment.created: no transaction ID.';
            return;
        }
        if (!skipDuplicateCheckForTest && isDuplicate(payment.id)) {
            res.status  = 'DUPLICATE_SKIPPED';
            res.message = 'Holding ticket already exists for ' + payment.id + ' — skipped.';
            res.detail  = 'Zeffy_Transaction_Id__c = ' + payment.id + ' found in Gift_Transaction__c or Zeffy_Review_Ticket__c.';
            return;
        }
        String buyerQuestionsText = extractBuyerQuestionsText(rawBody);
        createHoldingTicket(payment, rawBody, buyerQuestionsText);
        res.status  = 'SUCCESS';
        res.message = 'Holding ticket created — awaiting payment confirmation.';
        res.detail  = 'Transaction ID: ' + payment.id;
    }

    // ─── payment.updated — upsert existing ticket or gift ──────────

    private static void processPaymentUpdated(ZeffyPayment payment, String rawBody, WebhookResult res) {
        if (String.isBlank(payment.id)) {
            res.status  = 'MISSING_TX_ID';
            res.message = 'payment.updated: no transaction ID.';
            return;
        }
        String txId = payment.id;

        // Check if a Holding ticket needs to graduate to Pending Review
        // (payment.updated can follow payment.created once payment succeeds)
        List<Zeffy_Review_Ticket__c> tickets = [
            SELECT Id, Status__c, Receipt_URL__c, Transaction_Status__c,
                   Refund_Status__c, Refund_Amount__c, Dispute_Status__c,
                   Dispute_Amount__c, Dispute_Reason__c, Resolved_Gift__c,
                   Resolved_Account__c, Amount__c, Eligible_Amount__c,
                   Zeffy_Amount_Not_Applied__c, Zeffy_Amount_Reviewed__c
            FROM Zeffy_Review_Ticket__c
            WHERE Zeffy_Transaction_Id__c = :txId
            LIMIT 1
        ];

        String newTxStatus = String.isNotBlank(payment.status) ? payment.status : null;
        Decimal refundTotal = 0;
        if (payment.refunds != null) {
            for (ZeffyRefund r : payment.refunds) { if (r.amount != null && isCompletedRefund(r)) refundTotal += r.amount; }
        }
        Boolean isFullyRefunded     = isFullRefundStatus(payment.refund_status);
        Boolean isPartiallyRefunded = isPartialRefundStatus(payment.refund_status);
        Boolean hasRefund           = isFullyRefunded || isPartiallyRefunded;
        Date    refundDate          = getLatestRefundDate(payment.refunds);
        Decimal newAmount           = payment.amount != null ? payment.amount / 100 : null;

        if (!tickets.isEmpty()) {
            Zeffy_Review_Ticket__c t = tickets[0];
            Boolean wasHolding = t.Status__c == 'Holding' || t.Status__c == 'Delayed';
            String  prevStatus = t.Status__c;
            Decimal prevRefund  = t.Refund_Amount__c;
            String  prevDispute = t.Dispute_Status__c;
            // A payment.updated without data.status keeps the last known status instead of blanking it
            if (newTxStatus != null) t.Transaction_Status__c = newTxStatus;
            if (String.isNotBlank(payment.receipt_url)) t.Receipt_URL__c    = payment.receipt_url;
            if (realRefundStatus(payment.refund_status) != null) t.Refund_Status__c = payment.refund_status;
            if (refundTotal > 0) t.Refund_Amount__c = refundTotal / 100;
            if (payment.dispute != null) {
                if (String.isNotBlank(payment.dispute.status)) t.Dispute_Status__c = payment.dispute.status;
                if (String.isNotBlank(payment.dispute.reason)) t.Dispute_Reason__c = payment.dispute.reason;
                if (payment.dispute.amount != null) t.Dispute_Amount__c = payment.dispute.amount / 100;
            }
            // Graduate Holding → Pending Review if payment now succeeded
            if (wasHolding && 'succeeded'.equalsIgnoreCase(newTxStatus)) {
                t.Status__c = 'Pending Review';
            }
            // Confirmed payment: a ticket moved to review by hand can no longer go back to Holding
            if ('succeeded'.equalsIgnoreCase(newTxStatus)) t.Pre_Review_Status__c = null;
            Gift_Transaction__c linkedGt = null;
            if (t.Resolved_Gift__c != null) {
                List<Gift_Transaction__c> linked = [
                    SELECT Id, Status__c, Amount__c FROM Gift_Transaction__c WHERE Id = :t.Resolved_Gift__c LIMIT 1
                ];
                if (!linked.isEmpty()) linkedGt = linked[0];
            }
            // Zeffy reports another amount.
            // Open ticket (no gift yet): the ticket simply takes the new amount, so the gift is born right.
            // Closed or robot ticket (gift exists): the gift is never changed, the ticket is flagged for a
            // manual review. An amount staff already reviewed is not flagged again.
            Decimal recorded     = linkedGt != null ? linkedGt.Amount__c : t.Amount__c;
            Boolean amountChange = isAmountChange(recorded, newAmount, refundTotal / 100);
            // Closed/Skipped without a gift also just follow Zeffy: nothing to protect, and if the ticket
            // is reopened later (payment confirmed after close) it already carries the right amount.
            Boolean openTicket   = linkedGt == null;
            Boolean followAmount = amountChange && openTicket;
            Boolean newFlag      = amountChange && !openTicket
                && t.Zeffy_Amount_Not_Applied__c != newAmount && t.Zeffy_Amount_Reviewed__c != newAmount;
            if (followAmount) {
                t.Amount__c = newAmount;
                if (t.Eligible_Amount__c != null && t.Eligible_Amount__c > newAmount) t.Eligible_Amount__c = newAmount;
                t.Zeffy_Amount_Not_Applied__c = null;
            } else if (newFlag) {
                t.Zeffy_Amount_Not_Applied__c = newAmount;
            } else if (t.Zeffy_Amount_Not_Applied__c != null && !amountChange && newAmount != null) {
                t.Zeffy_Amount_Not_Applied__c = null;   // Zeffy went back to the recorded amount
            }
            update t;
            if (followAmount) {
                createAuditLog(t.Id, 'Amount Updated by Zeffy', t.Resolved_Account__c,
                    'Zeffy: ' + formatMoney(recorded) + ' → ' + formatMoney(newAmount)
                    + '. Open ticket, no gift yet: the ticket took the new amount.');
            }
            if (newFlag) logAmountChange(t.Id, t.Resolved_Account__c, recorded, newAmount);
            // Same graduation as payment.completed (a later completed is skipped as a duplicate, so this is
            // the only chance): known donor → robot resolves it; otherwise a review task for the staff.
            String graduatedMsg = null;
            if (wasHolding && t.Status__c == 'Pending Review') {
                createAuditLog(t.Id, 'Payment Confirmed', null, prevStatus + ' → Pending Review (payment.updated: succeeded).');
                Account donor = findDonor(payment);
                if (donor != null) {
                    linkExistingCore(t.Id, donor.Id,
                        'Auto-resolved: payment confirmed (payment.updated), donor matched via ' + lastDonorMatchMethod + '.',
                        null, false, false, false, null);
                    update new Zeffy_Review_Ticket__c(Id = t.Id, Status__c = 'Auto-Processed', Resolved_By__c = null);
                    res.donorName = donor.Name;
                    graduatedMsg = prevStatus + ' ticket auto-resolved: gift created for "' + donor.Name + '".';
                } else {
                    createPendingTask(t, payment.buyer);
                    graduatedMsg = prevStatus + ' ticket graduated to Pending Review — donor not found, manual review needed.';
                }
            }
            // If ticket has a linked gift and a refund/dispute arrived → update the GT too.
            // Robot tickets (Auto-Processed) also keep the gift's receipt URL in sync, as before they existed.
            Boolean syncReceipt = linkedGt != null && t.Status__c == 'Auto-Processed'
                && String.isNotBlank(payment.receipt_url);
            if (linkedGt != null && (hasRefund || payment.dispute != null || syncReceipt)) {
                Gift_Transaction__c gtUpd = new Gift_Transaction__c(Id = linkedGt.Id);
                if (syncReceipt) gtUpd.Receipt_URL__c = payment.receipt_url;
                if (hasRefund) applyRefund(gtUpd, isFullyRefunded, refundTotal, refundDate);
                if (payment.dispute != null) applyDispute(gtUpd, payment.dispute);
                update gtUpd;
            }
            logRefundAndDispute(t.Id, t.Resolved_Account__c, payment, prevRefund, prevDispute, refundTotal);
            syncCommitmentFor(payment);
            res.status  = 'SUCCESS';
            res.message = graduatedMsg != null
                ? graduatedMsg
                : followAmount
                    ? 'Open ticket took the new Zeffy amount (' + formatMoney(recorded) + ' → ' + formatMoney(newAmount) + ').'
                    : amountChange
                        ? amountChangeMessage(recorded, newAmount)
                        : 'Ticket updated via payment.updated.';
            res.detail  = 'Transaction ID: ' + txId;
            return;
        }

        // No ticket found — check if a gift was already created (auto-matched donor)
        List<Gift_Transaction__c> gts = [
            SELECT Id, Status__c, Receipt_URL__c, Refunded_Amount__c, Refund_Date__c,
                   Amount__c, Donor_Account__c, Dispute_Status__c, CreatedDate
            FROM Gift_Transaction__c WHERE Zeffy_Transaction_Id__c = :txId LIMIT 1
        ];
        if (!gts.isEmpty()) {
            Gift_Transaction__c gt = gts[0];
            Id ticketId = null;
            // Auto-matched donation (no ticket) and Zeffy reports another amount: nothing is changed,
            // a ticket linked to the gift is opened so staff reviews it manually
            Boolean amountChange = isAmountChange(gt.Amount__c, newAmount, refundTotal / 100);
            if (amountChange) {
                Zeffy_Review_Ticket__c tkt = buildReviewTicket(payment, rawBody, extractBuyerQuestionsText(rawBody));
                // payment.updated comes without data.status; an existing GT means Zeffy completed it
                if (String.isBlank(tkt.Transaction_Status__c)) tkt.Transaction_Status__c = 'succeeded';
                tkt.Status__c                   = 'Auto-Processed';
                tkt.Amount__c                   = gt.Amount__c;
                tkt.Zeffy_Amount_Not_Applied__c = newAmount;
                tkt.Resolved_Gift__c            = gt.Id;
                tkt.Resolved_Account__c         = gt.Donor_Account__c;
                tkt.Resolved_At__c              = gt.CreatedDate;   // when the robot matched it, not today
                tkt.Resolution_Notes__c         = 'Auto-matched by Zeffy ID.';
                insert tkt;
                ticketId = tkt.Id;
                logAmountChange(ticketId, gt.Donor_Account__c, gt.Amount__c, newAmount);
            }
            Gift_Transaction__c upd = new Gift_Transaction__c(Id = gt.Id);
            Boolean needsUpdate = false;
            if (String.isNotBlank(payment.receipt_url)) { upd.Receipt_URL__c = payment.receipt_url; needsUpdate = true; }
            if (hasRefund) {
                applyRefund(upd, isFullyRefunded, refundTotal, refundDate);
                needsUpdate = true;
            }
            if (payment.dispute != null) {
                applyDispute(upd, payment.dispute);
                needsUpdate = true;
            }
            if (needsUpdate) update upd;
            logRefundAndDispute(ticketId, gt.Donor_Account__c, payment,
                gt.Refunded_Amount__c, gt.Dispute_Status__c, refundTotal);
            syncCommitmentFor(payment);
            res.status  = 'SUCCESS';
            res.message = amountChange
                ? amountChangeMessage(gt.Amount__c, newAmount)
                : 'gift updated via payment.updated.';
            res.detail  = 'Transaction ID: ' + txId;
            return;
        }

        // Nothing to update yet (events out of order, or the payment came before go-live): keep the
        // payload in the log (IGNORED) so it can be reprocessed once the payment exists.
        res.status  = 'IGNORED';
        res.message = 'payment.updated: no matching ticket or gift yet — payload kept, reprocess it once the payment exists.';
        res.detail  = 'Transaction ID: ' + txId;
    }

    // ─── Refunds & disputes (payment.updated) ─────────────────────────────────

    // SEMBEQ: a full refund marks the gift Refunded (excluded from totals); the refunded amount
    // and date are kept on the gift. Nothing is ever deleted.
    private static void applyRefund(Gift_Transaction__c upd, Boolean full, Decimal refundCents, Date refundDate) {
        if (full) upd.Status__c = 'Refunded';
        if (refundCents > 0) upd.Refunded_Amount__c = refundCents / 100;
        if (refundDate != null) upd.Refund_Date__c = refundDate;
    }

    private static void applyDispute(Gift_Transaction__c upd, ZeffyDispute d) {
        if (String.isNotBlank(d.status)) upd.Dispute_Status__c = d.status;
        if (String.isNotBlank(d.reason)) upd.Dispute_Reason__c = d.reason;
        if (d.amount != null) upd.Dispute_Amount__c = d.amount / 100;
    }

    // Audit only when Zeffy reports something new (a retry of the same event logs nothing).
    private static void logRefundAndDispute(Id ticketId, Id accountId, ZeffyPayment p,
                                            Decimal prevRefund, String prevDispute, Decimal refundCents) {
        Decimal refund = refundCents != null && refundCents > 0 ? refundCents / 100 : null;
        if (refund != null && refund != prevRefund) {
            createAuditLog(ticketId, 'Refund Received', accountId,
                'Zeffy ' + p.id + ': ' + (String.isNotBlank(p.refund_status) ? p.refund_status : 'refund')
                + ' — ' + formatMoney(refund) + ' (previously ' + formatMoney(prevRefund) + ').');
        }
        if (p.dispute != null && String.isNotBlank(p.dispute.status)
                && !p.dispute.status.equalsIgnoreCase(prevDispute)) {
            createAuditLog(ticketId, 'Dispute Updated', accountId,
                'Zeffy ' + p.id + ': dispute ' + p.dispute.status
                + (String.isNotBlank(p.dispute.reason) ? ' (' + p.dispute.reason + ')' : '')
                + (p.dispute.amount != null ? ' — ' + formatMoney(p.dispute.amount / 100) : '') + '.');
        }
    }

    private static void syncCommitmentFor(ZeffyPayment p) {
        String subId = p.recurring != null ? p.recurring.subscription_id : null;
        if (String.isBlank(subId)) return;
        List<Gift_Commitment__c> cmts = [
            SELECT Id, Status__c, Amount__c FROM Gift_Commitment__c
            WHERE Zeffy_Subscription_Id__c = :subId LIMIT 1

        ];
        if (!cmts.isEmpty()) syncCommitment(cmts[0], p);
    }

    // ─── Amount reported differently by Zeffy (payment.updated) ───────────────
    // Zeffy does not let staff edit an amount, so this should not happen. If it ever does, Salesforce
    // changes nothing on its own: the ticket is flagged (Zeffy_Amount_Not_Applied__c), shows in Open with
    // a warning, and staff checks it and marks it as reviewed.

    // A refund is not an amount change: Zeffy may report amount net of refunds.
    @TestVisible
    private static Boolean isAmountChange(Decimal recorded, Decimal newAmount, Decimal refundAmount) {
        if (newAmount == null || recorded == null || recorded == newAmount) return false;
        if (refundAmount != null && refundAmount > 0 && recorded - refundAmount == newAmount) return false;
        return true;
    }

    private static void logAmountChange(Id ticketId, Id accountId, Decimal recorded, Decimal newAmount) {
        createAuditLog(ticketId, 'Amount Changed in Zeffy', accountId,
            'Zeffy now reports ' + formatMoney(newAmount) + ' — Salesforce has ' + formatMoney(recorded)
            + '. Nothing was changed; flagged for a manual review.');
    }

    private static String amountChangeMessage(Decimal recorded, Decimal newAmount) {
        return 'Zeffy reports another amount (' + formatMoney(recorded) + ' → ' + formatMoney(newAmount)
            + ') — nothing changed, ticket flagged for a manual review.';
    }

    // LWC: staff checked the amount reported by Zeffy (and fixed the gift by hand if needed)
    @AuraEnabled
    public static void markAmountReviewed(Id ticketId) {
        requireZeffyAccess();
        new GiftAccess().markReviewed(ticketId);
    }

    private static void markAmountReviewedImpl(Id ticketId) {
        Zeffy_Review_Ticket__c t = [
            SELECT Id, Amount__c, Zeffy_Amount_Not_Applied__c, Resolved_Gift__c, Resolved_Account__c
            FROM Zeffy_Review_Ticket__c WHERE Id = :ticketId LIMIT 1
        ];
        if (t.Zeffy_Amount_Not_Applied__c == null) return;
        Decimal zeffyAmount = t.Zeffy_Amount_Not_Applied__c;
        List<Gift_Transaction__c> gts = t.Resolved_Gift__c == null ? new List<Gift_Transaction__c>() :
            [SELECT Amount__c FROM Gift_Transaction__c WHERE Id = :t.Resolved_Gift__c LIMIT 1];
        if (!gts.isEmpty() && gts[0].Amount__c != null) t.Amount__c = gts[0].Amount__c;   // ticket follows the gift as staff left it
        t.Zeffy_Amount_Reviewed__c    = zeffyAmount;   // the same amount is not flagged again
        t.Zeffy_Amount_Not_Applied__c = null;
        update t;
        createAuditLog(t.Id, 'Amount Change Reviewed', t.Resolved_Account__c,
            'Zeffy: ' + formatMoney(zeffyAmount) + ' — Salesforce: ' + formatMoney(t.Amount__c));
    }

    private static String formatMoney(Decimal amount) {
        return amount == null ? '—' : '$' + String.valueOf(amount.setScale(2));
    }

    // ─── payment.deleted — ticket → Payment Failed, Gift_Transaction__c → Canceled ─
    // A payment deleted in Zeffy must not stay Received in Salesforce (tax receipts, totals).
    // If the cancellation fails the ticket carries the error so staff fixes it by hand.

    @TestVisible private static Boolean failGiftCancel = false;

    private static void processPaymentDeleted(ZeffyPayment payment, String rawBody, WebhookResult res) {
        if (String.isBlank(payment.id)) {
            res.status  = 'MISSING_TX_ID';
            res.message = 'payment.deleted: no transaction ID.';
            return;
        }
        String txId = payment.id;
        List<Zeffy_Review_Ticket__c> tickets = [
            SELECT Id, Name, Status__c, Transaction_Status__c, Resolved_Gift__c, Resolved_Account__c,
                   First_Name__c, Last_Name__c, Company_Name__c, Amount__c, Gift_Date__c, Zeffy_Origin__c
            FROM Zeffy_Review_Ticket__c
            WHERE Zeffy_Transaction_Id__c = :txId
            ORDER BY CreatedDate
        ];
        List<Gift_Transaction__c> gts = [
            SELECT Id, Name, Status__c, Donor_Account__c, Donor_Account__r.Name, Donor__r.Name, Amount__c,
                   Gift_Date__c, Zeffy_Origin__c, Recurring_Gift__c, Recurring_Gift__r.Name
            FROM Gift_Transaction__c
            WHERE Zeffy_Transaction_Id__c = :txId
            ORDER BY CreatedDate
        ];
        Gift_Transaction__c gt = gts.isEmpty() ? null : gts[0];
        Zeffy_Review_Ticket__c existing = tickets.isEmpty() ? null : tickets[0];

        // A manual payment (entered by hand by staff) that Zeffy deletes was a data-entry mistake:
        // it no longer exists in Zeffy, so it is removed from Salesforce too. Online and imported
        // payments stay as Canceled (a real payment that never arrived keeps its trace).
        String origin = mapOrigin(payment.type);
        if (origin == null && gt != null) origin = gt.Zeffy_Origin__c;
        if (origin == null && existing != null) origin = existing.Zeffy_Origin__c;
        String manualDeleteError;
        if (origin == 'Manual' && (gt != null || existing != null)) {
            manualDeleteError = deleteManualPayment(txId, tickets, gts);
            if (manualDeleteError == null) {
                res.status  = 'SUCCESS';
                res.message = 'payment.deleted: manual payment removed from Salesforce.';
                res.detail  = 'Transaction ID: ' + txId;
                return;
            }
        }

        String cancelError = gt != null ? cancelGift(gt) : null;
        Id accountId = gt != null ? gt.Donor_Account__c : (tickets.isEmpty() ? null : tickets[0].Resolved_Account__c);

        Zeffy_Review_Ticket__c t;
        if (!tickets.isEmpty()) {
            t = tickets[0];
            String prevStatus = t.Status__c;
            t.Status__c             = 'Payment Failed';
            t.Transaction_Status__c = 'deleted';
            t.Error_Message__c      = cancelError != null
                ? ('Zeffy deleted this payment but the gift could not be cancelled: ' + cancelError).left(1000)
                : null;
            update t;
            res.message = 'Ticket ' + prevStatus + ' → Payment Failed via payment.deleted.';
        } else if (cancelError != null) {
            // Auto-matched gift (no ticket) that could not be cancelled → open a ticket for staff
            t = buildReviewTicket(payment, rawBody, extractBuyerQuestionsText(rawBody));
            t.Status__c             = 'Payment Failed';
            t.Transaction_Status__c = 'deleted';
            t.Resolved_Gift__c      = gt.Id;
            t.Resolved_Account__c   = gt.Donor_Account__c;
            t.Error_Message__c      = ('Zeffy deleted this payment but the gift could not be cancelled: '
                                       + cancelError).left(1000);
            insert t;
            res.message = 'payment.deleted: gift could not be cancelled — ticket opened for staff.';
        } else if (gt != null) {
            res.message = 'payment.deleted: gift cancelled.';
        } else {
            // Nothing in Salesforce yet (events out of order): keep a Closed "deleted" ticket so a late
            // payment.completed is skipped as a duplicate instead of recording a Paid gift.
            Zeffy_Review_Ticket__c tomb = buildReviewTicket(payment, rawBody, extractBuyerQuestionsText(rawBody));
            tomb.Status__c             = 'Closed';
            tomb.Transaction_Status__c = 'deleted';
            tomb.Resolution_Notes__c   = 'Zeffy deleted this payment before any other event reached Salesforce. '
                + 'Kept closed so a late confirmation is not recorded as a gift.';
            insert tomb;
            res.message = 'payment.deleted: no matching ticket or gift — closed ticket kept so a late payment.completed is ignored.';
        }

        if (gt != null || t != null) {
            String note = 'Zeffy deleted payment ' + txId + '.'
                + (gt == null ? '' : cancelError == null
                    ? ' Gift_Transaction__c ' + gt.Id + ': ' + gt.Status__c + ' → Canceled.'
                    : ' gift ' + gt.Id + ' NOT cancelled: ' + cancelError)
                + (manualDeleteError == null ? ''
                    : ' Manual payment could not be deleted (' + manualDeleteError + ') — cancelled instead.');
            createAuditLog(t != null ? t.Id : null, cancelError == null ? 'Payment Deleted' : 'Payment Delete Failed',
                accountId, note.left(32000));
        }
        res.status = 'SUCCESS';
        res.detail = 'Transaction ID: ' + txId;
    }

    @TestVisible private static Boolean failManualDelete = false;

    // Deletes everything tied to a manual payment deleted in Zeffy (all go to the Recycle Bin): every
    // Gift_Transaction__c and ticket carrying its transaction ID and, for a monthly / pre-authorized payment,
    // the recurring Gift_Commitment__c once no other installment points to it. The Account and its Zeffy ID
    // are kept. The Audit Log entry survives the tickets (lookup SetNull), so its note carries everything
    // needed to know what was removed. Returns null on success, or the error with nothing deleted — the
    // caller then cancels as for any other payment.
    private static String deleteManualPayment(String txId, List<Zeffy_Review_Ticket__c> tickets,
                                              List<Gift_Transaction__c> gifts) {
        Savepoint sp = Database.setSavepoint();
        try {
            if (failManualDelete) throw new ForcedTestException('Forced manual delete failure');
            Gift_Transaction__c gt   = gifts.isEmpty() ? null : gifts[0];
            Zeffy_Review_Ticket__c t = tickets.isEmpty() ? null : tickets[0];
            List<String> lines = new List<String>{
                'Zeffy deleted manual payment ' + txId + ' (entered by hand in Zeffy) — removed from Salesforce.'
            };
            String donor = gt != null && gt.Donor__c != null ? gt.Donor__r.Name
                : gt != null && gt.Donor_Account__c != null ? gt.Donor_Account__r.Name
                : t != null ? (String.isNotBlank(t.Company_Name__c) ? t.Company_Name__c
                    : buildFullName(t.First_Name__c, t.Last_Name__c)) : null;
            Decimal amount = gt != null ? gt.Amount__c : t != null ? t.Amount__c : null;
            Date giftDate  = gt != null ? gt.Gift_Date__c : t != null ? t.Gift_Date__c : null;
            if (String.isNotBlank(donor)) lines.add('Donor: ' + donor);
            if (amount != null)   lines.add('Amount: ' + amount.setScale(2).toPlainString());
            if (giftDate != null) lines.add('Gift date: ' + String.valueOf(giftDate));
            Map<Id, String> commitments = new Map<Id, String>();
            for (Gift_Transaction__c g : gifts) {
                lines.add('Deleted gift: ' + g.Name + ' (' + g.Id + ', was ' + g.Status__c + ')');
                if (g.Recurring_Gift__c != null) commitments.put(g.Recurring_Gift__c, g.Recurring_Gift__r.Name);
            }
            Set<Id> ticketIds = new Map<Id, Zeffy_Review_Ticket__c>(tickets).keySet();
            for (Zeffy_Review_Ticket__c tk : tickets) {
                lines.add('Deleted ticket: ' + tk.Name + ' (' + tk.Id + ', was ' + tk.Status__c + ')');
            }
            Id accountId = gt != null ? gt.Donor_Account__c : t != null ? t.Resolved_Account__c : null;
            if (!tickets.isEmpty()) {
                // Detach the log history first so it stays readable without the ticket
                Map<Id, String> ticketNames = new Map<Id, String>();
                for (Zeffy_Review_Ticket__c tk : tickets) ticketNames.put(tk.Id, tk.Name);
                List<Zeffy_Connect_Audit_Log__c> history = [
                    SELECT Id, Ticket__c, Notes__c FROM Zeffy_Connect_Audit_Log__c WHERE Ticket__c IN :ticketIds
                ];
                for (Zeffy_Connect_Audit_Log__c h : history) {
                    h.Notes__c = ('[Ticket ' + ticketNames.get(h.Ticket__c) + ', deleted] '
                        + (h.Notes__c == null ? '' : h.Notes__c)).left(32000);
                }
                if (!history.isEmpty()) update history;
            }
            if (!gifts.isEmpty())   delete gifts;
            if (!tickets.isEmpty()) delete tickets;
            // Monthly / pre-authorized: the recurring commitment goes too, unless other installments use it
            if (!commitments.isEmpty()) {
                Set<Id> inUse = new Set<Id>();
                for (Gift_Transaction__c other : [SELECT Recurring_Gift__c FROM Gift_Transaction__c
                                                  WHERE Recurring_Gift__c IN :commitments.keySet()]) {
                    inUse.add(other.Recurring_Gift__c);
                }
                List<Gift_Commitment__c> toDelete = new List<Gift_Commitment__c>();
                for (Id cmtId : commitments.keySet()) {
                    if (inUse.contains(cmtId)) {
                        lines.add('Recurring commitment kept (other installments): ' + commitments.get(cmtId) + ' (' + cmtId + ')');
                    } else {
                        toDelete.add(new Gift_Commitment__c(Id = cmtId));
                        lines.add('Deleted recurring commitment: ' + commitments.get(cmtId) + ' (' + cmtId + ')');
                    }
                }
                if (!toDelete.isEmpty()) delete toDelete;
            }
            lines.add('Everything above is in the Recycle Bin for 15 days.');
            createAuditLog(null, 'Manual Payment Deleted', accountId, String.join(lines, '\n').left(32000));
            return null;
        } catch (Exception e) {
            Database.rollback(sp);
            return e.getMessage();
        }
    }

    // Returns null on success, or the error (gift left untouched).
    // SEMBEQ custom object: Received → Canceled directly (no NPC status rules).
    private static String cancelGift(Gift_Transaction__c gt) {
        if (gt.Status__c == 'Canceled') return null;
        Savepoint sp = Database.setSavepoint();
        try {
            if (failGiftCancel) throw new ForcedTestException('Forced gift cancel failure');
            update new Gift_Transaction__c(Id = gt.Id, Status__c = 'Canceled');
            return null;
        } catch (Exception e) {
            Database.rollback(sp);
            return e.getMessage();
        }
    }

    // ─── Donor lookup ─────────────────────────────────────────────────────────
    // The robot matches ONLY by Zeffy Contact UUID (Zeffy_Identity__c): same Zeffy ID = same account.
    // Email is never used to auto-assign (not reliable: shared, mistyped, reused) — an unknown Zeffy ID
    // always goes to a review ticket, where staff can search by name/email and link it manually.
    @TestVisible private static String lastDonorMatchMethod;

    private static Account findDonor(ZeffyPayment payment) {
        lastDonorMatchMethod = null;
        String zeffyContactId = payment.contact;  // UUID string from "contact" field
        if (String.isNotBlank(zeffyContactId)) {
            List<Zeffy_Identity__c> byId = [
                SELECT Account__c FROM Zeffy_Identity__c
                WHERE Zeffy_Contact_Id__c = :zeffyContactId LIMIT 1
            ];
            if (!byId.isEmpty()) {
                List<Account> accts = [SELECT Id, Name FROM Account WHERE Id = :byId[0].Account__c LIMIT 1];
                if (!accts.isEmpty()) {
                    lastDonorMatchMethod = 'Zeffy ID';
                    return accts[0];
                }
            }
        }

        return null;
    }

    // ─── Auto-create Gift_Transaction__c for known donor ─────────────────────

    private static Id createGiftTransaction(ZeffyPayment p, Id accountId, String rawBody) {
        Id      campaignId    = findOrCreateCampaign(p.campaign_id, p.description);
        Boolean isRecurring   = p.recurring != null && p.recurring.is_recurring == true;
        String  subId         = p.recurring != null ? p.recurring.subscription_id : null;

        ZeffyBuyer  b = p.buyer;
        String tributeType = null;
        String tributeHonouree = null;
        if (p.items != null) {
            for (ZeffyItem item : p.items) {
                if (item.tribute != null) {
                    tributeType     = item.tribute.type;
                    tributeHonouree = item.tribute.honouree_name;
                    break;
                }
            }
        }
        // SEMBEQ: person = Contact (Donor__c) + its Administrative Account (Donor_Account__c)
        Id donorContactId = resolveDonorContactId(accountId, b != null ? b.email : null);
        // Create commitment FIRST so Recurring_Gift__c is set in the initial gift insert
        Id commitmentId = null;
        if (isRecurring && String.isNotBlank(subId)) {
            commitmentId = createOrUpdateCommitment(p, accountId, donorContactId);
        }

        Gift_Transaction__c gt = new Gift_Transaction__c(
            Donor_Account__c         = accountId,
            Donor__c                 = donorContactId,
            Recurring_Gift__c        = commitmentId,
            Amount__c                = p.amount != null ? p.amount / 100 : 0,
            Eligible_Amount__c       = p.eligible_amount != null ? p.eligible_amount / 100 : null,
            Payment_Method__c        = mapPaymentMethod(p.payment_method),
            Payment_Type__c          = mapPaymentType(p.campaign_type),
            Status__c                = isFullRefundStatus(p.refund_status) ? 'Refunded' : 'Received',
            Source__c                = 'Zeffy',
            Gift_Date__c             = parseUnixDate(p.created),
            Campaign__c              = campaignId,
            Notes__c                 = buildDescription(p),
            Zeffy_Transaction_Id__c  = p.id,
            Zeffy_Origin__c          = mapOrigin(p.type),
            Receipt_URL__c           = p.receipt_url,
            Rate_Title__c            = getFirstRateTitle(p),
            Zeffy_Raw_Payload__c     = rawBody?.left(32000),
            Currency__c              = String.isNotBlank(p.currencyIso) ? p.currencyIso.toUpperCase() : null,
            Is_Recurring__c          = isRecurring,
            Card_Brand__c            = p.payment_method != null ? p.payment_method.brand : null,
            Card_Last4__c            = p.payment_method != null ? p.payment_method.last4 : null,
            Fund_Code__c             = p.fund != null ? p.fund.code : null,
            Fund_Name__c             = getFundName(p.fund),
            Campaign_Category__c     = p.campaign_category,
            Dispute_Status__c        = p.dispute != null ? p.dispute.status : null,
            Dispute_Reason__c        = p.dispute != null ? p.dispute.reason : null,
            Dispute_Amount__c        = p.dispute != null && p.dispute.amount != null ? p.dispute.amount / 100 : null,
            Zeffy_Fund__c            = lookupFundByFormId(p.campaign_id),
            Tribute_Type__c          = tributeType,
            Tribute_Honouree__c      = tributeHonouree,
            Buyer_Questions__c       = extractBuyerQuestionsText(rawBody),
            Payer_Name__c            = buildFullName(b != null ? b.first_name : null, b != null ? b.last_name : null),
            Payer_Email__c           = b != null ? b.email : null
        );
        insert gt;
        return gt.Id;
    }

    // Set when the robot could not create the recurring Gift_Commitment__c (gift still created)
    private static String commitmentError;

    private static Id createOrUpdateCommitment(ZeffyPayment p, Id accountId, Id donorContactId) {
        String subId = p.recurring != null ? p.recurring.subscription_id : null;
        if (String.isBlank(subId)) return null;
        List<Gift_Commitment__c> existing = [
            SELECT Id, Status__c, Amount__c FROM Gift_Commitment__c
            WHERE Zeffy_Subscription_Id__c = :subId LIMIT 1
        ];
        if (!existing.isEmpty()) {
            syncCommitment(existing[0], p);
            return existing[0].Id;
        }
        try {
            if (failCommitmentInsert) throw new System.SObjectException('Forced commitment failure');
            Date nextDate   = p.recurring.current_period_end != null
                ? parseUnixDate(p.recurring.current_period_end) : null;
            Id cmtCampaignId = findOrCreateCampaign(p.campaign_id, p.description);
            Gift_Commitment__c cmt = new Gift_Commitment__c(
                Donor_Account__c         = accountId,
                Donor__c                 = donorContactId,
                Status__c                = 'Active',
                Source__c                = 'Zeffy',
                Frequency__c             = mapFrequency(p.recurring.interval),
                Start_Date__c            = parseUnixDate(p.created),
                Amount__c                = p.amount != null ? p.amount / 100 : null,
                Next_Payment_Date__c     = nextDate,
                Campaign__c              = cmtCampaignId,
                Zeffy_Subscription_Id__c = subId
            );
            insert cmt;
            return cmt.Id;
        } catch (Exception ex) {
            // Non-critical for the gift, but staff must see it: logged on the robot ticket once it exists
            commitmentError = ex.getMessage();
            System.debug('Gift_Commitment__c insert failed (non-critical): ' + ex.getMessage());
            return null;
        }
    }

    // Keeps a robot-created Gift_Commitment__c in line with Zeffy: a new installment amount, or the
    // subscription cancelled in Zeffy (recurring.status) → commitment Cancelled. Non-critical.
    // A late update of an older installment must not move the commitment back to an old amount
    private static Boolean isLatestInstallment(Id commitmentId, ZeffyPayment p) {
        Date paid = p.created != null ? parseUnixDate(p.created) : null;
        if (paid == null) return true;
        return [SELECT COUNT() FROM Gift_Transaction__c
                WHERE Recurring_Gift__c = :commitmentId AND Gift_Date__c > :paid] == 0;
    }

    private static void syncCommitment(Gift_Commitment__c cmt, ZeffyPayment p) {
        try {
            if (failCommitmentSync) throw new ForcedTestException('Forced commitment sync failure');
            Gift_Commitment__c upd = new Gift_Commitment__c(Id = cmt.Id);
            List<String> changes = new List<String>();
            Decimal amt = p.amount != null ? p.amount / 100 : null;
            if (amt != null && amt != cmt.Amount__c && !isCancelledSubscription(p)
                    && isLatestInstallment(cmt.Id, p)) {
                upd.Amount__c = amt;
                changes.add('next installment ' + formatMoney(cmt.Amount__c) + ' → ' + formatMoney(amt));
            }
            if (isCancelledSubscription(p) && cmt.Status__c != 'Cancelled') {
                upd.Status__c   = 'Cancelled';
                upd.End_Date__c = Date.today();
                changes.add('subscription cancelled in Zeffy (' + p.recurring.status + ') → commitment Cancelled');
            }
            if (changes.isEmpty()) return;
            update upd;
            createAuditLog(null, 'Recurring Updated by Zeffy', null,
                'Subscription ' + p.recurring.subscription_id + ': ' + String.join(changes, '; ') + '.');
        } catch (Exception ex) {
            System.debug('Gift_Commitment__c sync failed (non-critical): ' + ex.getMessage());

        }
    }

    private static Boolean isCancelledSubscription(ZeffyPayment p) {
        if (p.recurring == null || String.isBlank(p.recurring.status)) return false;
        String st = p.recurring.status.toLowerCase();
        return st == 'canceled' || st == 'cancelled' || st == 'ended' || st == 'inactive';
    }

    // Shared by the automatic (webhook) and the manual (ticket) paths: the Campaign mapped to
    // the Zeffy form, created on first use. Creation failure never blocks the gift.
    private static Id findOrCreateCampaign(String formId, String formName) {
        if (String.isBlank(formId)) return null;
        Id existing = lookupCampaignByFormId(formId);
        if (existing != null || String.isBlank(formName)) return existing;
        Savepoint sp = Database.setSavepoint();
        try {
            if (failCampaignCreate) throw new ForcedTestException('Forced campaign create failure');
            Campaign nc = new Campaign(Name = formName.abbreviate(80), IsActive = true,
                                       Zeffy_Form_Id__c = formId, Is_Zeffy_Managed__c = true);
            insert nc;
            createAuditLog(null, 'Campaign Created', null,
                'Campaign "' + nc.Name + '" created automatically for Zeffy form ' + formId + '.');
            return nc.Id;
        } catch (Exception ex) {
            Database.rollback(sp);
            System.debug('Campaign create failed (non-critical): ' + ex.getMessage());
            return null;
        }
    }

    private static Date nextDateFromFrequency(Date giftDate, String frequency) {
        if (giftDate == null) return null;
        if (String.isBlank(frequency)) return giftDate.addMonths(1);
        switch on frequency.toLowerCase() {
            when 'monthly'            { return giftDate.addMonths(1); }
            when 'quarterly'          { return giftDate.addMonths(3); }
            when 'annually', 'yearly' { return giftDate.addYears(1); }
            when 'weekly'             { return giftDate.addDays(7); }
            when else                 { return giftDate.addMonths(1); }
        }
    }

    // ─── Create review ticket for unknown donor ───────────────────────────────

    private static void createReviewTicket(ZeffyPayment p, String rawBody, String buyerQuestionsText) {
        Zeffy_Review_Ticket__c ticket = buildReviewTicket(p, rawBody, buyerQuestionsText);
        insert ticket;
        createPendingTask(ticket, p.buyer);
    }

    private static Zeffy_Review_Ticket__c buildReviewTicket(ZeffyPayment p, String rawBody, String buyerQuestionsText) {
        ZeffyBuyer  b = p.buyer;
        ZeffyAddress a = (b != null) ? b.address : null;
        Boolean isRecurring = p.recurring != null && p.recurring.is_recurring == true;
        Id fundId = lookupFundByFormId(p.campaign_id);

        // Aggregate refund total
        Decimal refundTotal = 0;
        if (p.refunds != null) {
            for (ZeffyRefund r : p.refunds) { if (r.amount != null && isCompletedRefund(r)) refundTotal += r.amount; }
        }

        // First tribute (if any donation item has one)
        String tributeType = null;
        String tributeHonouree = null;
        if (p.items != null) {
            for (ZeffyItem item : p.items) {
                if (item.tribute != null) {
                    tributeType      = item.tribute.type;
                    tributeHonouree  = item.tribute.honouree_name;
                    break;
                }
            }
        }

        return new Zeffy_Review_Ticket__c(
            Status__c                  = 'Pending Review',
            Zeffy_Contact_Id__c        = p.contact,
            First_Name__c              = b != null ? b.first_name : null,
            Last_Name__c               = b != null ? b.last_name  : null,
            Email__c                   = b != null ? b.email       : null,
            Company_Name__c            = b != null ? b.company_name : null,
            Is_Corporate__c            = b != null && b.is_corporate == true,
            Address__c                 = a != null ? a.line1       : null,
            City__c                    = a != null ? a.city        : null,
            Province__c                = a != null ? a.state       : null,
            Postal_Code__c             = a != null ? formatCanadianPostal(a.postal_code, a.country) : null,
            Country__c                 = a != null ? a.country     : null,
            Amount__c                  = p.amount        != null ? p.amount / 100 : null,
            Eligible_Amount__c         = p.eligible_amount != null ? p.eligible_amount / 100 : null,
            Currency__c                = String.isNotBlank(p.currencyIso) ? p.currencyIso.toUpperCase() : null,
            Payment_Method__c          = mapPaymentMethod(p.payment_method),
            Card_Brand__c              = p.payment_method != null ? p.payment_method.brand : null,
            Card_Last4__c              = p.payment_method != null ? p.payment_method.last4 : null,
            Payment_Type__c            = mapPaymentType(p.campaign_type),
            Zeffy_Origin__c            = mapOrigin(p.type),
            Gift_Date__c               = parseUnixDate(p.created),
            Rate_Title__c              = getFirstRateTitle(p),
            Receipt_URL__c             = p.receipt_url,
            Form_Id__c                 = p.campaign_id,
            Form_Name__c               = p.description?.left(255),
            Campaign_Category__c       = p.campaign_category,
            Is_Recurring__c            = isRecurring,
            Zeffy_Subscription_Id__c   = p.recurring != null ? p.recurring.subscription_id : null,
            Subscription_Frequency__c  = p.recurring != null ? p.recurring.interval : null,
            Fund_Id__c                 = p.fund != null ? p.fund.id   : null,
            Fund_Code__c               = p.fund != null ? p.fund.code : null,
            Fund_Name__c               = getFundName(p.fund),
            Dispute_Status__c          = p.dispute != null ? p.dispute.status : null,
            Dispute_Reason__c          = p.dispute != null ? p.dispute.reason : null,
            Dispute_Amount__c          = p.dispute != null && p.dispute.amount != null ? p.dispute.amount / 100 : null,
            Refund_Status__c           = realRefundStatus(p.refund_status),
            Refund_Amount__c           = refundTotal > 0 ? refundTotal / 100 : null,
            Discount_Code__c           = p.discount != null ? p.discount.code : null,
            Discount_Amount__c         = p.discount != null && p.discount.amount != null ? p.discount.amount / 100 : null,
            Buyer_Questions__c         = buyerQuestionsText,
            Tribute_Type__c            = tributeType,
            Tribute_Honouree__c        = tributeHonouree,
            Transaction_Status__c      = String.isNotBlank(p.status) ? p.status : null,
            Zeffy_Transaction_Id__c    = p.id,
            Raw_Payload__c             = rawBody?.left(32000),
            Fund__c                    = fundId
        );
    }

    // ─── Create holding ticket for payment.created (pending payment) ──────────

    private static void createHoldingTicket(ZeffyPayment p, String rawBody, String buyerQuestionsText) {
        ZeffyBuyer  b = p.buyer;
        ZeffyAddress a = (b != null) ? b.address : null;
        Boolean isRecurring = p.recurring != null && p.recurring.is_recurring == true;
        Id fundId = lookupFundByFormId(p.campaign_id);

        String tributeType = null, tributeHonouree = null;
        if (p.items != null) {
            for (ZeffyItem item : p.items) {
                if (item.tribute != null) { tributeType = item.tribute.type; tributeHonouree = item.tribute.honouree_name; break; }
            }
        }

        insert new Zeffy_Review_Ticket__c(
            Status__c                  = 'Holding',
            Transaction_Status__c      = String.isNotBlank(p.status) ? p.status : 'pending',
            Zeffy_Contact_Id__c        = p.contact,
            First_Name__c              = b != null ? b.first_name  : null,
            Last_Name__c               = b != null ? b.last_name   : null,
            Email__c                   = b != null ? b.email       : null,
            Company_Name__c            = b != null ? b.company_name : null,
            Is_Corporate__c            = b != null && b.is_corporate == true,
            Address__c                 = a != null ? a.line1       : null,
            City__c                    = a != null ? a.city        : null,
            Province__c                = a != null ? a.state       : null,
            Postal_Code__c             = a != null ? formatCanadianPostal(a.postal_code, a.country) : null,
            Country__c                 = a != null ? a.country     : null,
            Amount__c                  = p.amount        != null ? p.amount / 100 : null,
            Eligible_Amount__c         = p.eligible_amount != null ? p.eligible_amount / 100 : null,
            Currency__c                = String.isNotBlank(p.currencyIso) ? p.currencyIso.toUpperCase() : null,
            Payment_Method__c          = mapPaymentMethod(p.payment_method),
            Card_Brand__c              = p.payment_method != null ? p.payment_method.brand : null,
            Card_Last4__c              = p.payment_method != null ? p.payment_method.last4 : null,
            Payment_Type__c            = mapPaymentType(p.campaign_type),
            Zeffy_Origin__c            = mapOrigin(p.type),
            Gift_Date__c               = parseUnixDate(p.created),
            Rate_Title__c              = getFirstRateTitle(p),
            Receipt_URL__c             = p.receipt_url,
            Form_Id__c                 = p.campaign_id,
            Form_Name__c               = p.description?.left(255),
            Campaign_Category__c       = p.campaign_category,
            Is_Recurring__c            = isRecurring,
            Zeffy_Subscription_Id__c   = p.recurring != null ? p.recurring.subscription_id : null,
            Subscription_Frequency__c  = p.recurring != null ? p.recurring.interval : null,
            Fund_Id__c                 = p.fund != null ? p.fund.id   : null,
            Fund_Code__c               = p.fund != null ? p.fund.code : null,
            Fund_Name__c               = getFundName(p.fund),
            Buyer_Questions__c         = buyerQuestionsText,
            Tribute_Type__c            = tributeType,
            Tribute_Honouree__c        = tributeHonouree,
            Zeffy_Transaction_Id__c    = p.id,
            Raw_Payload__c             = rawBody?.left(32000),
            Fund__c                    = fundId
        );
    }

    private static void createPendingTask(Zeffy_Review_Ticket__c ticket, ZeffyBuyer b) {
        Zeffy_Config__c cfg = ZeffyConnectConfigService.getConfig();
        if (cfg == null || cfg.Auto_Task_Enabled__c != true) return;

        String donorName = '';
        if (b != null) {
            List<String> parts = new List<String>();
            if (String.isNotBlank(b.first_name)) parts.add(b.first_name);
            if (String.isNotBlank(b.last_name))  parts.add(b.last_name);
            donorName = String.join(parts, ' ');
            if (String.isBlank(donorName) && String.isNotBlank(b.company_name)) {
                donorName = b.company_name;
            }
        }

        Integer dueDays = cfg.Task_Due_Days__c != null ? (Integer) cfg.Task_Due_Days__c : 2;
        String  subject = 'Review pending donation' + (String.isNotBlank(donorName) ? ': ' + donorName : '');
        Id      ownerId = String.isNotBlank(cfg.Task_Owner_Id__c) ? cfg.Task_Owner_Id__c : UserInfo.getUserId();

        // A bad Task_Owner_Id__c (inactive user, wrong ID) must never cost the ticket itself
        Savepoint sp = Database.setSavepoint();
        try {
            insert new Task(
                Subject      = subject,
                ActivityDate = Date.today().addDays(dueDays),
                OwnerId      = ownerId,
                WhatId       = ticket.Id,
                Status       = 'Not Started',
                Priority     = 'Normal',
                Description  = 'A new Zeffy donation arrived and needs review in Zeffy Connect.'
            );
        } catch (Exception ex) {
            Database.rollback(sp);
            createAuditLog(ticket.Id, 'Task Not Created', null,
                ('Review task could not be created (owner ' + ownerId + '): ' + ex.getMessage()).left(32000));
        }
    }

    private static void createErrorTicket(String rawBody, String errorMsg) {
        // Must never throw: it runs outside the router's try — an exception here = 500 + endless Zeffy retries
        try {
            if (failErrorTicketInsert) throw new System.DmlException('Forced error-ticket failure');
            insert new Zeffy_Review_Ticket__c(
                Status__c        = 'Error',
                Raw_Payload__c   = rawBody?.left(32000),
                Error_Message__c = errorMsg?.left(1000)
            );
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'createErrorTicket failed: ' + ex.getMessage());
        }
    }

    // ─── LWC: preview before linking to existing account ─────────────────────

    @AuraEnabled(cacheable=true)
    public static LinkPreview getLinkPreview(Id ticketId, Id accountId) {
        requireZeffyAccess();
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

        // Build dynamic SOQL including all email fields + standard address/name fields
        Set<String> colSet = new Set<String>{'id','name','recordtype.developername','recordtype.name','billingstreet','billingcity','billingstate','billingpostalcode','billingcountry','email_address__c','email_personal__c'};
        List<String> selectCols = new List<String>{'Id','Name','RecordType.DeveloperName','RecordType.Name','BillingStreet','BillingCity','BillingState','BillingPostalCode','BillingCountry','Email_Address__c','Email_Personal__c'};
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

        // SEMBEQ: a person is a Contact in an Administrative Account — first/last name live on the
        // Contact. Church / business / organization accounts have no donor Contact → names not compared.
        Boolean isPerson = isPersonAccount(a);
        Id donorContactId = isPerson ? resolveDonorContactId(accountId, t.Email__c) : null;
        Contact dc = donorContactId != null
            ? [SELECT FirstName, LastName, Email FROM Contact WHERE Id = :donorContactId LIMIT 1]
            : null;
        String mainEmail = (String) a.get('Email_Address__c');
        if (String.isBlank(mainEmail)) mainEmail = (String) a.get('Email_Personal__c');
        if (String.isBlank(mainEmail) && dc != null) mainEmail = dc.Email;
        String acctFirst = dc != null ? dc.FirstName : null;
        String acctLast  = dc != null ? dc.LastName  : null;

        LinkPreview preview = new LinkPreview();
        preview.accountId         = accountId;
        preview.accountName       = dc != null ? buildFullName(dc.FirstName, dc.LastName) : a.Name;
        preview.ticketFirstName   = t.First_Name__c;
        preview.accountFirstName  = acctFirst;
        preview.isPersonAccount   = isPerson;
        preview.firstNamesDiffer  = dc != null && String.isNotBlank(t.First_Name__c) && t.First_Name__c != acctFirst;
        preview.ticketLastName    = t.Last_Name__c;
        preview.accountLastName   = acctLast;
        preview.lastNamesDiffer   = dc != null && String.isNotBlank(t.Last_Name__c) && t.Last_Name__c != acctLast;
        preview.accountEmail      = mainEmail;
        preview.ticketEmail       = t.Email__c;
        preview.emailsDiffer      = String.isNotBlank(t.Email__c) && t.Email__c != mainEmail;

        String acctAddr = buildAddressString(a.BillingStreet, a.BillingCity, a.BillingState, a.BillingPostalCode);
        String tktAddr  = buildAddressString(t.Address__c, t.City__c, t.Province__c, t.Postal_Code__c);
        // Shown with the country at the end; the "differs" check ignores it (many accounts have no country)
        preview.accountAddress  = buildAddressString(a.BillingStreet, a.BillingCity, a.BillingState, a.BillingPostalCode, a.BillingCountry);
        preview.ticketAddress   = buildAddressString(t.Address__c, t.City__c, t.Province__c, t.Postal_Code__c, t.Country__c);
        preview.addressesDiffer = String.isNotBlank(tktAddr) && tktAddr != acctAddr;
        preview.accountAddressCore = acctAddr;
        preview.ticketStreet     = t.Address__c;
        preview.ticketCity       = t.City__c;
        preview.ticketProvince   = t.Province__c;
        preview.ticketPostalCode = t.Postal_Code__c;
        preview.ticketCountry    = t.Country__c;

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
        requireZeffyAccess();
        resolveCreateNewEdited(ticketId, donorType, notes, null);
    }

    // Same as resolveCreateNew, but the reviewer may correct the Zeffy values the new Account is
    // built from. editedValues keys: firstName, lastName, accountName (non-individual), email,
    // phone, street, city, province, postalCode, country. A missing key keeps the ticket value.
    // The ticket itself (what Zeffy sent) is never changed; corrections go to the 'Account Created' log.
    @AuraEnabled
    public static void resolveCreateNewEdited(Id ticketId, String donorType, String notes,
            Map<String, String> editedValues) {
        requireZeffyAccess();
        Zeffy_Review_Ticket__c t = loadTicket(ticketId);
        requirePendingReview(t);
        String safeType = String.isBlank(donorType) ? 'individual' : donorType.toLowerCase();
        Map<String, String> edits = editedValues == null ? new Map<String, String>() : editedValues;
        List<String> corrections = new List<String>();

        // In-memory copy feeds the Account; the original ticket still feeds the identity and the gift
        Zeffy_Review_Ticket__c src = t.clone(true, true, false, false);
        src.First_Name__c  = editedValue(edits, 'firstName',  t.First_Name__c,  'First name',  corrections);
        src.Last_Name__c   = editedValue(edits, 'lastName',   t.Last_Name__c,   'Last name',   corrections);
        String defaultName = String.isNotBlank(t.Company_Name__c)
            ? t.Company_Name__c : buildFullName(t.First_Name__c, t.Last_Name__c);
        src.Company_Name__c = editedValue(edits, 'accountName', defaultName, 'Account name', corrections);
        src.Email__c       = editedValue(edits, 'email',      t.Email__c,       'Email',       corrections);
        src.Phone__c       = editedValue(edits, 'phone',      t.Phone__c,       'Phone',       corrections);
        src.Address__c     = editedValue(edits, 'street',     t.Address__c,     'Street',      corrections);
        src.City__c        = editedValue(edits, 'city',       t.City__c,        'City',        corrections);
        src.Province__c    = editedValue(edits, 'province',   t.Province__c,    'Province',    corrections);
        src.Postal_Code__c = editedValue(edits, 'postalCode', t.Postal_Code__c, 'Postal code', corrections);
        src.Country__c     = editedValue(edits, 'country',    t.Country__c,     'Country',     corrections);

        Account donor = insertDonorAccount(src, safeType);
        createAuditLog(t.Id, 'Account Created', donor.Id, accountCreatedLog(donor, safeType, corrections));

        // Register Zeffy identity
        if (String.isNotBlank(t.Zeffy_Contact_Id__c)) {
            upsertIdentity(donor.Id, t.Zeffy_Contact_Id__c, t.Email__c, 'Ticket', t.Id);
        }

        List<Id> ids = createGiftFromTicket(t, donor.Id);
        resolveTicket(t.Id, 'Resolved - New Contact', donor.Id, ids[0], notes);
    }

    @AuraEnabled
    public static void resolveLinkExisting(
        Id ticketId, Id accountId, String notes,
        String emailTargetField, Boolean updateAddress,
        Boolean updateFirstName, Boolean updateLastName
    ) {
        requireZeffyAccess();
        resolveLinkExistingEdited(ticketId, accountId, notes, emailTargetField,
            updateAddress, updateFirstName, updateLastName, null);
    }

    // Same as resolveLinkExisting, but the reviewer may correct the Zeffy values before they
    // are written to the Account. editedValues keys: email, street, city,
    // province, postalCode, country. A missing key keeps the ticket value. The ticket itself
    // (what Zeffy sent) is never changed; the 'Account Updated' log keeps before → after and corrections.
    // Returns a warning when the account could not be updated (the donation is still recorded),
    // null otherwise.
    @AuraEnabled
    public static String resolveLinkExistingEdited(
        Id ticketId, Id accountId, String notes,
        String emailTargetField, Boolean updateAddress,
        Boolean updateFirstName, Boolean updateLastName,
        Map<String, String> editedValues
    ) {
        requireZeffyAccess();
        return linkExistingCore(ticketId, accountId, notes, emailTargetField,
            updateAddress, updateFirstName, updateLastName, editedValues);
    }

    // Body of resolveLinkExistingEdited without the access check: the webhook auto-resolve runs as the
    // Site Guest User (no permission set, HMAC already validated) and calls this directly.
    private static String linkExistingCore(
        Id ticketId, Id accountId, String notes,
        String emailTargetField, Boolean updateAddress,
        Boolean updateFirstName, Boolean updateLastName,
        Map<String, String> editedValues
    ) {
        Zeffy_Review_Ticket__c t = loadTicket(ticketId);
        requirePendingReview(t);
        Map<String, String> edits = editedValues == null ? new Map<String, String>() : editedValues;
        List<String> corrections = new List<String>();

        String email     = editedValue(edits, 'email',      t.Email__c,       'Email',       corrections);
        String street    = editedValue(edits, 'street',     t.Address__c,     'Street',      corrections);
        String city      = editedValue(edits, 'city',       t.City__c,        'City',        corrections);
        String province  = editedValue(edits, 'province',   t.Province__c,    'Province',    corrections);
        String postal    = editedValue(edits, 'postalCode', t.Postal_Code__c, 'Postal code', corrections);
        String country   = editedValue(edits, 'country',    t.Country__c,     'Country',     corrections);

        // Add new Zeffy ID to identity history (never overwrites existing IDs)
        if (String.isNotBlank(t.Zeffy_Contact_Id__c)) {
            upsertIdentity(accountId, t.Zeffy_Contact_Id__c, t.Email__c, 'Ticket', t.Id);
        }

        // Optionally save email to a specific Account field and/or update the address. The name of an
        // existing account is never changed (updateFirstName/updateLastName are ignored): the account
        // keeps its Salesforce name, Zeffy's name is only used when a new account is created
        Account toUpdate = new Account(Id = accountId);
        Boolean doUpdate = false;

        if (String.isNotBlank(emailTargetField) && String.isNotBlank(email)) {
            // Only an updatable Email field: never a name or any other field
            Schema.SObjectField ef = Schema.SObjectType.Account.fields.getMap().get(emailTargetField.toLowerCase());
            if (ef == null || ef.getDescribe().getType() != Schema.DisplayType.Email || !ef.getDescribe().isUpdateable()) {
                throw new AuraHandledException('Invalid email field: ' + emailTargetField);
            }
            toUpdate.put(ef.getDescribe().getName(), email);
            doUpdate = true;
        }
        if (updateAddress == true) {
            toUpdate.BillingStreet     = street;
            toUpdate.BillingCity       = city;
            toUpdate.BillingState      = province;
            toUpdate.BillingPostalCode = postal;
            toUpdate.BillingCountry    = country;
            doUpdate = true;
        }
        String warning;
        if (doUpdate) {
            Account before = loadAccountSnapshot(accountId, toUpdate);
            Savepoint sp = Database.setSavepoint();
            try {
                update toUpdate;
                List<String> changes = accountChanges(before, toUpdate);
                if (!changes.isEmpty()) {
                    createAuditLog(t.Id, 'Account Updated', accountId, accountUpdatedLog(changes, corrections));
                }
            } catch (Exception ex) {
                // Non-blocking: the donation is still recorded, but staff is told and it stays in the log
                Database.rollback(sp);
                warning = 'The account kept its values: ' + ex.getMessage();
                createAuditLog(t.Id, 'Account Not Updated', accountId, warning.abbreviate(32000));
            }
        }

        List<Id> ids = createGiftFromTicket(t, accountId);
        resolveTicket(t.Id, 'Resolved - Linked', accountId, ids[0], notes);
        return warning;
    }

    // Returns the reviewer's corrected value when it differs from the ticket value, else the ticket value.
    private static String editedValue(Map<String, String> edits, String key, String ticketValue,
            String label, List<String> corrections) {
        if (!edits.containsKey(key)) return ticketValue;
        String v = edits.get(key) == null ? null : edits.get(key).trim();
        if (String.isBlank(v)) v = null;
        // equals(), not ==: a case-only fix ("demers" → "Demers") is a real correction
        if (v == null ? ticketValue == null : v.equals(ticketValue)) return ticketValue;
        corrections.add(label + ' "' + (ticketValue == null ? '' : ticketValue) + '" → "' + (v == null ? '' : v) + '"');
        return v;
    }

    // ─── Account change log (before → after) ──────────────────────────────────
    // Every field a resolution writes to an Account is logged with its previous Salesforce value,
    // so nothing the reviewer overwrites is lost. Reviewer corrections of the Zeffy values go in
    // the same entry; the ticket keeps what Zeffy sent.

    private static final List<String> BILLING_FIELDS = new List<String>{
        'BillingStreet', 'BillingCity', 'BillingState', 'BillingPostalCode', 'BillingCountry'
    };

    // Current values of exactly the fields about to be written
    private static Account loadAccountSnapshot(Id accountId, Account toUpdate) {
        Set<String> fields = new Set<String>(toUpdate.getPopulatedFieldsAsMap().keySet());
        fields.remove('Id');
        if (fields.isEmpty()) return new Account(Id = accountId);
        List<Account> rows = Database.query('SELECT ' + String.join(new List<String>(fields), ', ')
            + ' FROM Account WHERE Id = :accountId LIMIT 1');
        return rows.isEmpty() ? new Account(Id = accountId) : rows[0];
    }

    // One line per field whose value actually changed; the Billing address is one line
    private static List<String> accountChanges(Account before, Account after) {
        List<String> lines = new List<String>();
        Map<String, Object> written = after.getPopulatedFieldsAsMap();
        Map<String, Schema.SObjectField> describe = Schema.SObjectType.Account.fields.getMap();
        Boolean addressWritten = false;
        for (String f : written.keySet()) {
            if (f == 'Id') continue;
            if (BILLING_FIELDS.contains(f)) { addressWritten = true; continue; }
            String oldVal = valueText(before, f);
            String newVal = valueText(after, f);
            if (oldVal.equals(newVal)) continue;
            Schema.SObjectField sf = describe.get(f.toLowerCase());
            String label = sf == null ? f : sf.getDescribe().getLabel() + ' (' + f + ')';
            lines.add(label + ': ' + quoted(oldVal) + ' → ' + quoted(newVal));
        }
        if (addressWritten) {
            String oldAddr = billingText(before);
            String newAddr = billingText(after);
            if (!oldAddr.equals(newAddr)) {
                lines.add('Billing address: ' + quoted(oldAddr) + ' → ' + quoted(newAddr));
            }
        }
        return lines;
    }

    private static String valueText(Account a, String field) {
        Object v = a.getPopulatedFieldsAsMap().get(field);
        return v == null ? '' : String.valueOf(v).trim();
    }

    private static String billingText(Account a) {
        List<String> parts = new List<String>();
        for (String f : BILLING_FIELDS) {
            String v = valueText(a, f);
            if (v.length() > 0) parts.add(v);
        }
        return String.join(parts, ', ');
    }

    private static String quoted(String v) { return String.isBlank(v) ? '(empty)' : '"' + v + '"'; }

    private static String accountUpdatedLog(List<String> changes, List<String> corrections) {
        String log = 'Account fields changed (before → after):\n' + String.join(changes, '\n');
        if (!corrections.isEmpty()) {
            log += '\n\nZeffy values corrected by the reviewer (Zeffy → saved):\n' + String.join(corrections, '\n');
        }
        return log.abbreviate(32000); // Notes__c length
    }

    private static String accountCreatedLog(Account donor, String safeType, List<String> corrections) {
        List<String> lines = new List<String>();
        Map<String, Object> written = donor.getPopulatedFieldsAsMap();
        Map<String, Schema.SObjectField> describe = Schema.SObjectType.Account.fields.getMap();
        for (String f : written.keySet()) {
            if (f == 'Id' || f == 'RecordTypeId' || BILLING_FIELDS.contains(f)) continue;
            String v = valueText(donor, f);
            if (v.length() == 0) continue;
            Schema.SObjectField sf = describe.get(f.toLowerCase());
            lines.add((sf == null ? f : sf.getDescribe().getLabel()) + ': ' + quoted(v));
        }
        String addr = billingText(donor);
        if (addr.length() > 0) lines.add('Billing address: ' + quoted(addr));
        String log = 'New ' + safeType + ' account created from the Zeffy data:\n' + String.join(lines, '\n');
        log += corrections.isEmpty()
            ? '\n\nNo values were corrected.'
            : '\n\nZeffy values corrected by the reviewer (Zeffy → saved):\n' + String.join(corrections, '\n');
        return log.abbreviate(32000); // Notes__c length
    }

    @AuraEnabled
    public static Map<String,Object> bulkResolveLinkExisting(List<Id> ticketIds, Id accountId, String notes) {
        requireZeffyAccess();
        return linkTicketsToAccount(ticketIds, accountId, notes);
    }

    // Group version of resolveLinkExistingEdited: the reviewer decides once what the account keeps
    // (several group emails into different email fields, the chosen address, the name) and the
    // account is updated a single time before every ticket is linked. accountValues keys are Account
    // API names: updateable Email fields, FirstName, LastName and the Billing* fields; anything else is
    // ignored. corrections lists the Zeffy values the reviewer fixed with the pencil, for the log.
    @AuraEnabled
    public static Map<String,Object> bulkResolveLinkExistingEdited(List<Id> ticketIds, Id accountId, String notes,
            Map<String, String> accountValues, List<String> corrections) {
        requireZeffyAccess();
        // Tickets resolved elsewhere meanwhile: leave the account untouched
        List<Zeffy_Review_Ticket__c> pending = ticketIds == null ? new List<Zeffy_Review_Ticket__c>() : [
            SELECT Id FROM Zeffy_Review_Ticket__c WHERE Id IN :ticketIds AND Status__c = 'Pending Review' ORDER BY CreatedDate ASC
        ];
        if (pending.isEmpty()) {
            return new Map<String,Object>{ 'resolved' => 0, 'errors' => new List<String>{ 'No Pending Review tickets found' } };
        }
        Account toUpdate = new Account(Id = accountId);
        Boolean doUpdate = false;
        if (accountValues != null && !accountValues.isEmpty()) {
            // The name of an existing account is never changed: only email and Billing fields
            Set<String> allowed = new Set<String>();
            for (String f : BILLING_FIELDS) allowed.add(f.toLowerCase());
            Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.Account.fields.getMap();
            for (String fname : fieldMap.keySet()) {
                Schema.DescribeFieldResult fd = fieldMap.get(fname).getDescribe();
                if (fd.getType() == Schema.DisplayType.Email && fd.isUpdateable()) allowed.add(fname);
            }
            for (String key : accountValues.keySet()) {
                if (key == null || !allowed.contains(key.toLowerCase())) continue;
                if (!fieldMap.get(key.toLowerCase()).getDescribe().isUpdateable()) continue;
                String v = accountValues.get(key) == null ? null : accountValues.get(key).trim();
                if (String.isBlank(v)) v = null;
                // An email is never blanked; an address part may be (the chosen address has no unit, etc.)
                if (v == null && fieldMap.get(key.toLowerCase()).getDescribe().getType() == Schema.DisplayType.Email) continue;
                toUpdate.put(fieldMap.get(key.toLowerCase()).getDescribe().getName(), v);
                doUpdate = true;
            }
        }
        List<String> errors = new List<String>();
        if (doUpdate) {
            Account before = loadAccountSnapshot(accountId, toUpdate);
            try {
                update toUpdate;
                List<String> changes = accountChanges(before, toUpdate);
                if (!changes.isEmpty()) {
                    createAuditLog(pending[0].Id, 'Account Updated', accountId,
                        accountUpdatedLog(changes, corrections == null ? new List<String>() : corrections));
                }
            } catch (Exception ex) {
                // The tickets are still linked; the reviewer sees why the account kept its values
                errors.add('Account: ' + ex.getMessage());
                createAuditLog(pending[0].Id, 'Account Not Updated', accountId,
                    'The account kept its values: ' + ex.getMessage());
            }
        }
        Map<String,Object> result = linkTicketsToAccount(ticketIds, accountId, notes);
        ((List<String>) result.get('errors')).addAll(errors);
        return result;
    }

    private static Map<String,Object> linkTicketsToAccount(List<Id> ticketIds, Id accountId, String notes) {
        List<Zeffy_Review_Ticket__c> tickets = [
            SELECT Id, Name, Status__c, Zeffy_Contact_Id__c, First_Name__c, Last_Name__c, Email__c,
                   Amount__c, Eligible_Amount__c, Currency__c, Payment_Method__c, Payment_Type__c, Zeffy_Origin__c,
                   Gift_Date__c, Form_Id__c, Form_Name__c, Is_Recurring__c,
                   Zeffy_Subscription_Id__c, Subscription_Frequency__c, Zeffy_Transaction_Id__c,
                   Refund_Status__c, Refund_Amount__c, Campaign_Category__c,
                   Dispute_Status__c, Dispute_Reason__c, Dispute_Amount__c,
                   Tribute_Type__c, Tribute_Honouree__c, Is_Corporate__c, Fund_Id__c,
                   Language__c, Rate_Title__c, Receipt_Number__c, Receipt_URL__c,
                   Note__c, Annotation__c, Raw_Payload__c, Card_Brand__c, Card_Last4__c,
                   Fund_Code__c, Fund_Name__c, Buyer_Questions__c, Fund__c
            FROM Zeffy_Review_Ticket__c
            WHERE Id IN :ticketIds AND Status__c = 'Pending Review'
            ORDER BY Gift_Date__c ASC NULLS LAST, CreatedDate ASC
        ];
        Integer resolved = 0;
        List<String> errors = new List<String>();
        for (Zeffy_Review_Ticket__c t : tickets) {
            // Per ticket all-or-nothing: a failure must not leave a gift/identity behind on a ticket
            // that stays in Pending Review (the next attempt would hit DUPLICATE_VALUE)
            Savepoint sp = Database.setSavepoint();
            try {
                if (String.isNotBlank(t.Zeffy_Contact_Id__c)) {
                    upsertIdentity(accountId, t.Zeffy_Contact_Id__c, t.Email__c, 'Ticket', t.Id);
                }
                List<Id> ids = createGiftFromTicket(t, accountId);
                resolveTicket(t.Id, 'Resolved - Linked', accountId, ids[0], notes);
                resolved++;
            } catch (Exception ex) {
                Database.rollback(sp);
                errors.add(t.Name + ': ' + ex.getMessage());
            }
        }
        return new Map<String,Object>{ 'resolved' => resolved, 'errors' => errors };
    }

    @TestVisible private static Boolean forceManualAdminAccount = false;   // tests: EDA did not create the Administrative Account

    // Inserts the donor for a ticket and returns the Account that becomes Donor_Account__c / Resolved_Account__c.
    // SEMBEQ (EDA, no Person Accounts):
    //   individual   → Contact; EDA creates its Administrative Account (fallback: created here)
    //   eglise       → Account RT Eglise
    //   business     → Account RT Business_Organization
    //   organization → Account RT Organisme
    // The returned Account carries only the values written, for the 'Account Created' log.
    private static Account insertDonorAccount(Zeffy_Review_Ticket__c t, String safeType) {
        if (safeType == 'individual') {
            Contact c = new Contact(
                FirstName         = t.First_Name__c,
                LastName          = String.isNotBlank(t.Last_Name__c) ? t.Last_Name__c : 'Zeffy',
                Email             = t.Email__c,
                Phone             = t.Phone__c,
                MailingStreet     = t.Address__c,
                MailingCity       = t.City__c,
                MailingState      = t.Province__c,
                MailingPostalCode = t.Postal_Code__c,
                MailingCountry    = t.Country__c
            );
            insert c;
            Id accId = [SELECT AccountId FROM Contact WHERE Id = :c.Id LIMIT 1].AccountId;
            if (accId == null || forceManualAdminAccount) {
                Account admin = new Account(
                    RecordTypeId = getRecordTypeId('Account', 'Administrative'),
                    Name         = buildFullName(c.FirstName, c.LastName) + ' Administrative Account'
                );
                insert admin;
                update new Contact(Id = c.Id, AccountId = admin.Id);
                accId = admin.Id;
            }
            Account donor = new Account(
                Id                = accId,
                Phone             = t.Phone__c,
                BillingStreet     = t.Address__c,
                BillingCity       = t.City__c,
                BillingState      = t.Province__c,
                BillingPostalCode = t.Postal_Code__c,
                BillingCountry    = t.Country__c
            );
            update donor;
            donor.Name = buildFullName(c.FirstName, c.LastName);
            return donor;
        }
        String rtName = safeType == 'eglise'   ? 'Eglise'
                      : safeType == 'business' ? 'Business_Organization'
                      : 'Organisme';
        Account donor = new Account(
            RecordTypeId      = getRecordTypeId('Account', rtName),
            Name              = String.isNotBlank(t.Company_Name__c)
                ? t.Company_Name__c : buildFullName(t.First_Name__c, t.Last_Name__c),
            Email_Address__c  = t.Email__c,
            Phone             = t.Phone__c,
            BillingStreet     = t.Address__c,
            BillingCity       = t.City__c,
            BillingState      = t.Province__c,
            BillingPostalCode = t.Postal_Code__c,
            BillingCountry    = t.Country__c
        );
        insert donor;
        return donor;
    }

    // One donor per distinct Zeffy contact (or email when the contact ID is missing): selecting
    // tickets from several people never merges them into one Account. A Zeffy ID that is already
    // linked keeps its Account (same Zeffy ID = same donor). Each donor group is all-or-nothing.
    // Resolve Group passes headTicketId (the ticket whose name the reviewer saw: the account is built
    // from it) and, for the batches after the first, accountId: the account the first batch created,
    // so every ticket of the group ends as 'Resolved - New Contact'.
    @AuraEnabled
    public static Map<String,Object> bulkResolveCreateNew(List<Id> ticketIds, String donorType, String notes,
            Id headTicketId, Id accountId) {
        requireZeffyAccess();
        List<Zeffy_Review_Ticket__c> tickets = [
            SELECT Id, Name, Status__c, Zeffy_Contact_Id__c, First_Name__c, Last_Name__c, Email__c,
                   Phone__c, Company_Name__c, Address__c, City__c, Province__c, Postal_Code__c, Country__c,
                   Amount__c, Eligible_Amount__c, Currency__c, Payment_Method__c, Payment_Type__c, Zeffy_Origin__c,
                   Gift_Date__c, Form_Id__c, Form_Name__c, Is_Recurring__c,
                   Zeffy_Subscription_Id__c, Subscription_Frequency__c, Zeffy_Transaction_Id__c,
                   Refund_Status__c, Refund_Amount__c, Campaign_Category__c,
                   Dispute_Status__c, Dispute_Reason__c, Dispute_Amount__c,
                   Tribute_Type__c, Tribute_Honouree__c, Is_Corporate__c, Fund_Id__c,
                   Language__c, Rate_Title__c, Receipt_Number__c, Receipt_URL__c,
                   Note__c, Annotation__c, Raw_Payload__c, Card_Brand__c, Card_Last4__c,
                   Fund_Code__c, Fund_Name__c, Buyer_Questions__c, Fund__c
            FROM Zeffy_Review_Ticket__c
            WHERE Id IN :ticketIds AND Status__c = 'Pending Review'
            ORDER BY Gift_Date__c ASC NULLS LAST, CreatedDate ASC
        ];
        if (tickets.isEmpty()) {
            return new Map<String,Object>{ 'resolved' => 0, 'errors' => new List<String>{ 'No Pending Review tickets found' } };
        }
        String safeType = String.isBlank(donorType) ? 'individual' : donorType.toLowerCase();

        // Group tickets by donor
        Map<String, List<Zeffy_Review_Ticket__c>> groups = new Map<String, List<Zeffy_Review_Ticket__c>>();
        Set<String> contactIds = new Set<String>();
        for (Zeffy_Review_Ticket__c t : tickets) {
            String key = String.isNotBlank(t.Zeffy_Contact_Id__c) ? 'zid:' + t.Zeffy_Contact_Id__c
                       : String.isNotBlank(t.Email__c)           ? 'email:' + t.Email__c.trim().toLowerCase()
                       : 'ticket:' + t.Id;
            if (!groups.containsKey(key)) groups.put(key, new List<Zeffy_Review_Ticket__c>());
            groups.get(key).add(t);
            if (String.isNotBlank(t.Zeffy_Contact_Id__c)) contactIds.add(t.Zeffy_Contact_Id__c);
        }
        Map<String, Id> linkedAccount = new Map<String, Id>();
        for (Zeffy_Identity__c zi : [SELECT Zeffy_Contact_Id__c, Account__c FROM Zeffy_Identity__c
                                     WHERE Zeffy_Contact_Id__c IN :contactIds]) {
            linkedAccount.put(zi.Zeffy_Contact_Id__c, zi.Account__c);
        }

        Integer resolved = 0;
        List<String> errors = new List<String>();
        List<String> accountIds = new List<String>();
        Boolean created = false;   // the account was created by this group (not already linked to the Zeffy ID)
        for (List<Zeffy_Review_Ticket__c> grp : groups.values()) {
            Zeffy_Review_Ticket__c head = grp[0];
            for (Zeffy_Review_Ticket__c t : grp) if (t.Id == headTicketId) head = t;
            Savepoint sp = Database.setSavepoint();
            try {
                Boolean continuing = accountId != null;
                Id donorId = continuing ? accountId
                    : String.isNotBlank(head.Zeffy_Contact_Id__c) ? linkedAccount.get(head.Zeffy_Contact_Id__c) : null;
                Boolean isNew = continuing || donorId == null;
                if (donorId == null) {
                    Account donor = insertDonorAccount(head, safeType);
                    donorId = donor.Id;
                }
                for (Zeffy_Review_Ticket__c t : grp) {
                    if (String.isNotBlank(t.Zeffy_Contact_Id__c)) {
                        upsertIdentity(donorId, t.Zeffy_Contact_Id__c, t.Email__c, 'Ticket', t.Id);
                    }
                    List<Id> ids = createGiftFromTicket(t, donorId);
                    resolveTicket(t.Id, isNew ? 'Resolved - New Contact' : 'Resolved - Linked', donorId, ids[0], notes);
                }
                resolved += grp.size();
                accountIds.add(String.valueOf(donorId));
                if (isNew) created = true;
            } catch (Exception ex) {
                Database.rollback(sp);
                List<String> names = new List<String>();
                for (Zeffy_Review_Ticket__c t : grp) names.add(t.Name);
                errors.add(String.join(names, ', ') + ': ' + ex.getMessage());
            }
        }
        return new Map<String,Object>{
            'resolved'   => resolved,
            'accountId'  => accountIds.isEmpty() ? null : accountIds[0],
            'accountIds' => accountIds,
            'accounts'   => accountIds.size(),
            'created'    => created,
            'errors'     => errors
        };
    }

    @AuraEnabled
    public static void closeTicket(Id ticketId, String reason) {
        requireZeffyAccess();
        // A resolved ticket owns a live gift: closing it would hide the gift from the Undo path
        String current = [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :ticketId LIMIT 1].Status__c;
        if (RESOLVED_STATUSES.contains(current)) {
            throw new AuraHandledException('A resolved ticket cannot be closed (current: ' + current + '). Use Undo first.');
        }
        update new Zeffy_Review_Ticket__c(
            Id                  = ticketId,
            Status__c           = 'Closed',
            Resolved_By__c      = UserInfo.getUserId(),
            Resolved_At__c      = DateTime.now(),
            Resolution_Notes__c = reason
        );
        createAuditLog(ticketId, 'Closed', null, reason);
        closeOpenTasks(ticketId);
    }

    private static final Set<String> RESOLVED_STATUSES = new Set<String>{
        'Resolved - New Contact', 'Resolved - Linked', 'Auto-Processed'
    };

    // Way out for tickets the robot parked: Holding (payment not confirmed yet), Delayed (Holding
    // expired) and Payment Failed — staff decides the payment is real and reviews it manually.
    // Also reopens a ticket staff Closed by mistake (no gift exists for a Closed ticket); the close
    // reason stays in the notes so the next reviewer sees why it had been closed.
    @AuraEnabled
    public static void moveTicketToReview(Id ticketId, String notes) {
        requireZeffyAccess();
        Zeffy_Review_Ticket__c t = [SELECT Id, Status__c, Transaction_Status__c, Resolved_Gift__c FROM Zeffy_Review_Ticket__c WHERE Id = :ticketId LIMIT 1];
        if (!new Set<String>{ 'Holding', 'Delayed', 'Payment Failed', 'Closed' }.contains(t.Status__c)) {
            throw new AuraHandledException('Only Holding, Delayed, Payment Failed or Closed tickets can be moved to review (current: '
                + t.Status__c + ').');
        }
        // Zeffy deleted the payment and its gift was cancelled: reviewing it again would record it twice.
        // Applies to any status (Payment Failed → Closed → Reopen used to slip through), and to any
        // ticket still pointing to a gift (resolving again would collide on the transaction ID).
        if ('deleted'.equalsIgnoreCase(t.Transaction_Status__c)) {
            throw new AuraHandledException('Zeffy deleted this payment, so it cannot be reviewed again. Close the ticket instead.');
        }
        if (t.Resolved_Gift__c != null) {
            throw new AuraHandledException('This ticket is still linked to a gift, so it cannot be reviewed again.');
        }
        Zeffy_Review_Ticket__c upd = new Zeffy_Review_Ticket__c(Id = ticketId, Status__c = 'Pending Review');
        // Holding/Delayed: Zeffy never confirmed the payment, so staff can still send it back
        upd.Pre_Review_Status__c = (t.Status__c == 'Holding' || t.Status__c == 'Delayed') ? t.Status__c : null;
        if (t.Status__c == 'Closed') {
            upd.Resolved_By__c = null;
            upd.Resolved_At__c = null;
        }
        update upd;
        createAuditLog(ticketId, 'Moved to Review', null,
            (t.Status__c + ' → Pending Review' + (String.isNotBlank(notes) ? ': ' + notes : '')).left(32000));
    }

    // Undo of moveTicketToReview for Holding/Delayed tickets: back to the status it had. Only while
    // Zeffy has not confirmed the payment — a confirmed payment belongs in Pending Review. The
    // Holding countdown runs from CreatedDate, so the ticket keeps its original days.
    @AuraEnabled
    public static void returnTicketToWaiting(Id ticketId) {
        requireZeffyAccess();
        Zeffy_Review_Ticket__c t = [
            SELECT Id, Status__c, Pre_Review_Status__c, Transaction_Status__c, Resolved_Gift__c, Manual_Assignee_Name__c
            FROM Zeffy_Review_Ticket__c WHERE Id = :ticketId LIMIT 1
        ];
        if (t.Status__c != 'Pending Review' || String.isBlank(t.Pre_Review_Status__c)
                || 'succeeded'.equalsIgnoreCase(t.Transaction_Status__c) || t.Resolved_Gift__c != null) {
            throw new AuraHandledException('Only tickets moved to review by hand from Holding or Delayed, '
                + 'with no payment confirmation from Zeffy, can be sent back.');
        }
        // A waiting ticket is nobody's work yet: drop the assignment and close its review tasks
        update new Zeffy_Review_Ticket__c(Id = ticketId, Status__c = t.Pre_Review_Status__c, Pre_Review_Status__c = null,
                                          Manual_Assignee_Id__c = null, Manual_Assignee_Name__c = null);
        closeOpenTasks(ticketId);
        createAuditLog(ticketId, 'Returned to ' + t.Pre_Review_Status__c, null,
            'Pending Review → ' + t.Pre_Review_Status__c + ' (sent back by staff'
            + (String.isNotBlank(t.Manual_Assignee_Name__c) ? '; assignment to ' + t.Manual_Assignee_Name__c + ' removed' : '') + ').');
    }

    // "Keep Pending" with a note: the ticket stays in Pending Review and the note is kept on the
    // ticket (shown to the next reviewer) and in the audit log. Notes accumulate, newest last.
    @AuraEnabled
    public static void addReviewNote(Id ticketId, String note) {
        requireZeffyAccess();
        if (String.isBlank(note)) return;
        Zeffy_Review_Ticket__c t = [SELECT Id, Status__c, Resolution_Notes__c FROM Zeffy_Review_Ticket__c WHERE Id = :ticketId LIMIT 1];
        if (t.Status__c != 'Pending Review') {
            throw new AuraHandledException('Notes can only be added to Pending Review tickets (current: ' + t.Status__c + ').');
        }
        String entry = '[' + DateTime.now().format('yyyy-MM-dd HH:mm') + ' ' + UserInfo.getName() + '] ' + note.trim();
        String all   = String.isBlank(t.Resolution_Notes__c) ? entry : t.Resolution_Notes__c + '\n' + entry;
        // Field holds 1000 chars: keep the newest notes
        update new Zeffy_Review_Ticket__c(Id = ticketId, Resolution_Notes__c = all.right(1000));
        createAuditLog(ticketId, 'Note Added', null, note.trim().left(32000));
    }

    // Re-runs a webhook whose processing failed, from the payload kept in Zeffy_Webhook_Log__c.
    // Idempotent: if Zeffy's own retry already got through, the result is DUPLICATE_SKIPPED.
    @AuraEnabled
    public static Map<String, String> reprocessWebhookLog(Id logId) {
        ZeffyConnectConfigService.requireSettingsAccess();
        return new GiftAccess().reprocess(logId);   // same reach as the webhook itself
    }

    private static Map<String, String> reprocessWebhookLogImpl(Id logId) {
        Zeffy_Webhook_Log__c log = [SELECT Id, Name, Raw_Payload__c FROM Zeffy_Webhook_Log__c WHERE Id = :logId LIMIT 1];
        if (String.isBlank(log.Raw_Payload__c)) {
            throw new AuraHandledException('This log has no stored payload to reprocess.');
        }
        WebhookResult r = processWebhookWithResult(log.Raw_Payload__c);
        if (r.status == 'IGNORED') {
            // Still ignored: keep the original log and its payload untouched for a later retry
            throw new AuraHandledException('This event is still ignored: turn on its toggle in Zeffy Connect Settings, then reprocess it.');
        }
        insert new Zeffy_Webhook_Log__c(
            Status__c         = r.status,
            Occurred_At__c    = DateTime.now(),
            Transaction_Id__c = r.transactionId,
            Donor_Name__c     = r.donorName,
            Amount__c         = r.amount,
            Event_Type__c     = r.eventType,
            Message__c        = ('Manual reprocess of ' + log.Name + ' by ' + UserInfo.getName() + ': '
                                 + (r.message != null ? r.message : '')).abbreviate(2000),
            Detail__c         = r.detail != null ? r.detail.abbreviate(5000) : null,
            Raw_Payload__c    = r.retryable ? log.Raw_Payload__c : null,
            Has_Raw_Payload__c = r.retryable
        );
        // The original log never keeps a second copy: when the retry failed again the new log holds it
        update new Zeffy_Webhook_Log__c(Id = log.Id, Raw_Payload__c = null, Has_Raw_Payload__c = false);
        return new Map<String, String>{ 'status' => r.status, 'message' => r.message };
    }

    private static final String TICKET_LIST_FIELDS =
            'SELECT Id, Name, Status__c, First_Name__c, Last_Name__c, Email__c, ' +
            '       Amount__c, Currency__c, Payment_Type__c, Gift_Date__c, ' +
            '       Form_Name__c, Is_Recurring__c, Company_Name__c, CreatedDate, LastModifiedDate, ' +
            '       Zeffy_Contact_Id__c, Manual_Assignee_Id__c, Manual_Assignee_Name__c, Zeffy_Amount_Not_Applied__c, ' +
            '       Dispute_Status__c, Refund_Status__c, Address_Differs__c, Resolved_Account__c, ' +
            '       Address__c, City__c, Province__c, Postal_Code__c, Country__c ' +
            'FROM Zeffy_Review_Ticket__c ';

    // Resolve Group: every ticket of a Zeffy ID, not only the ones the current list filter shows
    @AuraEnabled(cacheable=false)
    public static List<Zeffy_Review_Ticket__c> getGroupTickets(String zeffyContactId) {
        requireZeffyAccess();
        if (String.isBlank(zeffyContactId)) return new List<Zeffy_Review_Ticket__c>();
        return Database.query(TICKET_LIST_FIELDS
            + 'WHERE Zeffy_Contact_Id__c = :zeffyContactId ORDER BY CreatedDate DESC LIMIT 2000');
    }

    @AuraEnabled(cacheable=false)
    public static List<Zeffy_Review_Ticket__c> getTickets(String statusFilter) {
        requireZeffyAccess();
        // Flagged tickets are rechecked first: an address fixed directly on the account clears its 📍
        if (statusFilter == 'AddressDiffers' || statusFilter == 'Resolved' || statusFilter == 'Auto-Processed' || statusFilter == 'All') {
            refreshAddressFlags(new Map<Id, Zeffy_Review_Ticket__c>([
                SELECT Id FROM Zeffy_Review_Ticket__c WHERE Address_Differs__c = true LIMIT 2000
            ]).keySet());
        }
        String soql = TICKET_LIST_FIELDS;
        if (String.isNotBlank(statusFilter) && statusFilter != 'All') {
            if (statusFilter == 'Open') {
                soql += 'WHERE (Status__c NOT IN (\'Resolved - Linked\', \'Resolved - New Contact\', \'Auto-Processed\', \'Skipped\', \'Closed\', \'Delayed\') ' +
                        '       OR Zeffy_Amount_Not_Applied__c != null) ';
            } else if (statusFilter == 'Assigned') {
                soql += 'WHERE Manual_Assignee_Id__c != null ';
            } else if (statusFilter == 'AddressDiffers') {
                soql += 'WHERE Address_Differs__c = true ';
            } else if (statusFilter == 'Waiting') {
                soql += 'WHERE Status__c IN (\'Holding\', \'Payment Failed\') ';
            } else if (statusFilter == 'Resolved') {
                soql += 'WHERE Status__c LIKE \'Resolved%\' ';
            } else if (statusFilter == 'ClosedAll') {
                soql += 'WHERE Status__c IN (\'Closed\', \'Error\', \'Skipped\') ';
            } else {
                soql += 'WHERE Status__c = \'' + String.escapeSingleQuotes(statusFilter) + '\' ';
            }
        }
        soql += 'ORDER BY CreatedDate DESC LIMIT 2000';
        return Database.query(soql);
    }

    @AuraEnabled(cacheable=false)
    public static Zeffy_Review_Ticket__c getTicketDetail(Id ticketId) {
        requireZeffyAccess();
        return new GiftAccess().ticketDetail(ticketId);   // the resolved gift may belong to someone else
    }

    private static Zeffy_Review_Ticket__c getTicketDetailImpl(Id ticketId) {
        refreshAddressFlags(new Set<Id>{ ticketId });
        return [
            SELECT Id, Name, Status__c, Error_Message__c,
                   Zeffy_Contact_Id__c, First_Name__c, Last_Name__c,
                   Email__c, Phone__c, Company_Name__c, Language__c,
                   Address__c, City__c, Province__c, Postal_Code__c, Country__c,
                   Amount__c, Eligible_Amount__c,
                   Currency__c, Payment_Method__c, Payment_Type__c, Zeffy_Origin__c, Gift_Date__c,
                   Rate_Title__c, Receipt_Number__c, Receipt_URL__c,
                   Form_Id__c, Form_Name__c, Is_Recurring__c,
                   Zeffy_Subscription_Id__c, Subscription_Frequency__c,
                   Zeffy_Transaction_Id__c, Note__c, Annotation__c,
                   Is_Corporate__c, Card_Brand__c, Card_Last4__c,
                   Fund_Id__c, Fund_Name__c, Fund_Code__c,
                   Campaign_Category__c,
                   Tribute_Type__c, Tribute_Honouree__c,
                   Dispute_Status__c, Dispute_Reason__c, Dispute_Amount__c,
                   Refund_Status__c, Refund_Amount__c,
                   Discount_Code__c, Discount_Amount__c,
                   Buyer_Questions__c,
                   Resolved_Account__c, Resolved_Account__r.Name,
                   Resolved_Account__r.BillingStreet, Resolved_Account__r.BillingCity,
                   Resolved_Account__r.BillingState, Resolved_Account__r.BillingPostalCode,
                   Resolved_Account__r.BillingCountry, Address_Differs__c,
                   Resolved_Gift__c, Resolved_Gift__r.Name, Resolved_Gift__r.Amount__c,
                   Resolved_Gift__r.Status__c,
                   Resolved_By__c, Resolved_By__r.Name,
                   Resolved_At__c, Resolution_Notes__c,
                   Manual_Assignee_Id__c, Manual_Assignee_Name__c,
                   Transaction_Status__c, Zeffy_Amount_Not_Applied__c, Pre_Review_Status__c,
                   Fund__c, Fund__r.Name
            FROM Zeffy_Review_Ticket__c
            WHERE Id = :ticketId LIMIT 1
        ];
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    private static Boolean isDuplicate(String transactionId) {
        return [SELECT COUNT() FROM Gift_Transaction__c WHERE Zeffy_Transaction_Id__c = :transactionId] > 0
            || [SELECT COUNT() FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = :transactionId] > 0;
    }

    // Upsert a Zeffy_Identity__c — safe to call even if the ID already exists
    private static void upsertIdentity(Id accountId, String zeffyContactId, String email, String source, Id ticketId) {
        if (String.isBlank(zeffyContactId)) return;

        List<Zeffy_Identity__c> existing = [
            SELECT Id, Account__c, Account__r.Name FROM Zeffy_Identity__c WHERE Zeffy_Contact_Id__c = :zeffyContactId LIMIT 1
        ];
        // The Zeffy ID belongs to another account: the gift is still recorded where staff chose, but
        // the robot will keep matching future payments to the other account — leave a visible trace.
        if (!existing.isEmpty() && existing[0].Account__c != accountId) {
            createAuditLog(ticketId, 'Zeffy ID Conflict', accountId,
                ('Zeffy ID ' + zeffyContactId + ' is already linked to "'
                + (existing[0].Account__r != null ? existing[0].Account__r.Name : String.valueOf(existing[0].Account__c))
                + '". This gift was recorded on the chosen account, but future payments will still match "'
                + (existing[0].Account__r != null ? existing[0].Account__r.Name : String.valueOf(existing[0].Account__c))
                + '". Use Reassign Zeffy ID to move it if that is wrong.').left(32000));
            return;
        }

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
                   Amount__c, Eligible_Amount__c, Currency__c,
                   Payment_Method__c, Payment_Type__c, Zeffy_Origin__c, Gift_Date__c,
                   Rate_Title__c, Receipt_Number__c, Receipt_URL__c,
                   Form_Id__c, Form_Name__c, Is_Recurring__c,
                   Zeffy_Subscription_Id__c, Subscription_Frequency__c,
                   Zeffy_Transaction_Id__c, Note__c, Annotation__c, Raw_Payload__c,
                   Refund_Status__c, Refund_Amount__c,
                   Card_Brand__c, Card_Last4__c,
                   Fund_Code__c, Fund_Name__c, Campaign_Category__c,
                   Dispute_Status__c, Dispute_Reason__c, Dispute_Amount__c,
                   Tribute_Type__c, Tribute_Honouree__c, Buyer_Questions__c,
                   Is_Corporate__c, Fund__c
            FROM Zeffy_Review_Ticket__c WHERE Id = :ticketId LIMIT 1
        ];
    }

    @TestVisible private static String failGiftForTxId;   // tests: force the gift creation of one ticket to fail
    @TestVisible private static Boolean failCommitmentAdvance = false;

    // Installments resolved after the commitment exists (Resolve Group, or one by one in any order):
    // the commitment starts at the oldest installment and its next payment follows the newest one.
    // An older installment never moves the next payment back. Non-critical: the gift is still created.
    private static void advanceCommitmentFromTicket(Gift_Commitment__c cmt, Zeffy_Review_Ticket__c t) {
        if (t.Gift_Date__c == null || cmt.Status__c == 'Cancelled' || cmt.Status__c == 'Completed') return;
        try {
            if (failCommitmentAdvance) throw new ForcedTestException('Forced commitment advance failure');
            Date nextDate = nextDateFromFrequency(t.Gift_Date__c, t.Subscription_Frequency__c);
            if (cmt.Next_Payment_Date__c == null || nextDate > cmt.Next_Payment_Date__c) {
                Gift_Commitment__c upd = new Gift_Commitment__c(Id = cmt.Id, Next_Payment_Date__c = nextDate);
                if (t.Amount__c != null) upd.Amount__c = t.Amount__c;
                new GiftAccess().updateCommitment(upd);
                cmt.Next_Payment_Date__c = nextDate;
            }
        } catch (Exception ex) {
            System.debug('Gift_Commitment__c next payment not advanced (non-critical): ' + ex.getMessage());
        }
        // Kept apart: if the update of the start date fails, the next payment above still moved
        try {
            if (failCommitmentAdvance) throw new ForcedTestException('Forced commitment start failure');
            if (cmt.Start_Date__c == null || t.Gift_Date__c < cmt.Start_Date__c) {
                new GiftAccess().updateCommitment(new Gift_Commitment__c(Id = cmt.Id, Start_Date__c = t.Gift_Date__c));
                cmt.Start_Date__c = t.Gift_Date__c;
            }
        } catch (Exception ex) {
            System.debug('Gift_Commitment__c start date not moved (non-critical): ' + ex.getMessage());
        }
    }

    private static List<Id> createGiftFromTicket(Zeffy_Review_Ticket__c t, Id accountId) {
        if (failGiftForTxId != null && failGiftForTxId == t.Zeffy_Transaction_Id__c) {
            throw new ForcedTestException('Forced gift creation failure');
        }
        Id campaignId = findOrCreateCampaign(t.Form_Id__c, t.Form_Name__c);

        Boolean ticketFullyRefunded = isFullRefundStatus(t.Refund_Status__c);
        // SEMBEQ: person = Contact (Donor__c) + its Administrative Account (Donor_Account__c)
        Id donorContactId = resolveDonorContactId(accountId, t.Email__c);

        // Create Gift_Commitment__c FIRST so Recurring_Gift__c is set in the initial gift insert
        Id newCmtId = null;
        if (t.Is_Recurring__c && String.isNotBlank(t.Zeffy_Subscription_Id__c)) {
            // Without sharing: a commitment owned by someone else must still be found, or a duplicate is created
            List<Gift_Commitment__c> existingCmt = new GiftAccess().commitmentsBySubscription(t.Zeffy_Subscription_Id__c);
            if (existingCmt.isEmpty()) {
                try {
                    if (failCommitmentInsert) throw new System.SObjectException('Forced commitment failure');
                    Gift_Commitment__c cmt = new Gift_Commitment__c(
                        Donor_Account__c         = accountId,
                        Donor__c                 = donorContactId,
                        Status__c                = 'Active',
                        Source__c                = 'Zeffy',
                        Frequency__c             = mapFrequency(t.Subscription_Frequency__c),
                        Start_Date__c            = t.Gift_Date__c,
                        Amount__c                = t.Amount__c,
                        Next_Payment_Date__c     = nextDateFromFrequency(t.Gift_Date__c, t.Subscription_Frequency__c),
                        Campaign__c              = campaignId,
                        Zeffy_Subscription_Id__c = t.Zeffy_Subscription_Id__c
                    );
                    insert cmt;
                    newCmtId = cmt.Id;
                } catch (Exception ex) {
                    System.debug('Gift_Commitment__c insert failed (non-critical): ' + ex.getMessage());
                    logCommitmentNotCreated(t.Id, accountId, t.Zeffy_Subscription_Id__c, ex.getMessage());
                }
            } else {
                newCmtId = existingCmt[0].Id;
                advanceCommitmentFromTicket(existingCmt[0], t);
            }
        }

        Gift_Transaction__c gt = new Gift_Transaction__c(
            Donor_Account__c        = accountId,
            Donor__c                = donorContactId,
            Recurring_Gift__c       = newCmtId,
            Amount__c               = t.Amount__c,
            Eligible_Amount__c      = t.Eligible_Amount__c,
            Payment_Method__c       = String.isNotBlank(t.Payment_Method__c) ? t.Payment_Method__c : 'Credit Card',
            Payment_Type__c         = String.isNotBlank(t.Payment_Type__c) ? t.Payment_Type__c : 'Donation',
            Status__c               = ticketFullyRefunded ? 'Refunded' : 'Received',
            Source__c               = 'Zeffy',
            Gift_Date__c            = t.Gift_Date__c,
            Campaign__c             = campaignId,
            Notes__c                = t.Form_Name__c,
            Zeffy_Transaction_Id__c = t.Zeffy_Transaction_Id__c,
            Zeffy_Origin__c         = t.Zeffy_Origin__c,
            Receipt_URL__c          = t.Receipt_URL__c,
            Rate_Title__c           = t.Rate_Title__c,
            Note__c                 = t.Note__c,
            Annotation__c          = t.Annotation__c,
            Language__c             = t.Language__c,
            Zeffy_Raw_Payload__c    = t.Raw_Payload__c?.left(32000),
            Refunded_Amount__c      = (t.Refund_Amount__c != null && t.Refund_Amount__c > 0) ? t.Refund_Amount__c : null,

            Currency__c             = t.Currency__c,
            Is_Recurring__c         = t.Is_Recurring__c,
            Card_Brand__c           = t.Card_Brand__c,
            Card_Last4__c           = t.Card_Last4__c,
            Fund_Code__c            = t.Fund_Code__c,
            Fund_Name__c            = t.Fund_Name__c,
            Campaign_Category__c    = t.Campaign_Category__c,
            Dispute_Status__c       = t.Dispute_Status__c,
            Dispute_Reason__c       = t.Dispute_Reason__c,
            Dispute_Amount__c       = t.Dispute_Amount__c,
            Zeffy_Fund__c           = t.Fund__c,
            Tribute_Type__c         = t.Tribute_Type__c,
            Tribute_Honouree__c     = t.Tribute_Honouree__c,
            Buyer_Questions__c      = t.Buyer_Questions__c,
            Payer_Name__c           = buildFullName(t.First_Name__c, t.Last_Name__c),
            Payer_Email__c          = t.Email__c
        );
        // Without sharing: linking to a commitment owned by someone else needs no read access to it
        new GiftAccess().insertGift(gt);
        return new List<Id>{ gt.Id, newCmtId };
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
        closeOpenTasks(ticketId);
        refreshAddressFlags(new Set<Id>{ ticketId });
    }

    // ─── Address mismatch detector ────────────────────────────────────────────
    // After a resolution the Zeffy address (what the donor typed, usually what the receipt shows) is
    // compared with the account's Billing address. Flagged tickets show 📍 and can update the account.

    private static Account loadBillingAddress(Id accountId) {
        if (accountId == null) return null;
        List<Account> accs = [
            SELECT Id, BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry
            FROM Account WHERE Id = :accountId LIMIT 1
        ];
        return accs.isEmpty() ? null : accs[0];
    }

    @TestVisible
    private static Boolean addressDiffers(Zeffy_Review_Ticket__c t, Account a) {
        if (t == null || a == null) return false;
        String tStreet = normalizeAddressPart(t.Address__c);
        String tCity   = normalizeAddressPart(t.City__c);
        String tZip    = normalizePostal(t.Postal_Code__c);
        // Zeffy sent no address → nothing to compare
        if (String.isBlank(tStreet) && String.isBlank(tCity) && String.isBlank(tZip)) return false;
        if (String.isNotBlank(tStreet) && tStreet != normalizeAddressPart(a.BillingStreet)) return true;
        if (String.isNotBlank(tCity)   && tCity   != normalizeAddressPart(a.BillingCity))   return true;
        if (String.isNotBlank(tZip)    && tZip    != normalizePostal(a.BillingPostalCode))  return true;
        return false;
    }

    // Equivalent spellings collapse to one token. "St" is Saint in Quebec and Street elsewhere,
    // so both map to the same token — a street name never differs only by that word.
    private static final Map<String, String> ADDRESS_ABBREVIATIONS = new Map<String, String>{
        'street' => 'st', 'str' => 'st', 'saint' => 'st', 'sainte' => 'st', 'ste' => 'st',
        'ave' => 'avenue', 'av' => 'avenue', 'blvd' => 'boulevard', 'boul' => 'boulevard',
        'bd' => 'boulevard', 'rd' => 'road', 'dr' => 'drive', 'ch' => 'chemin',
        'apt' => 'app', 'appt' => 'app', 'apartment' => 'app', 'suite' => 'app', 'unit' => 'app',
        'e' => 'est', 'east' => 'est', 'o' => 'ouest', 'w' => 'ouest', 'west' => 'ouest',
        'n' => 'nord', 'north' => 'nord', 's' => 'sud', 'south' => 'sud', 'mtl' => 'montreal'
    };

    @TestVisible
    private static String normalizeAddressPart(String s) {
        if (String.isBlank(s)) return '';
        String v = s.toLowerCase();
        v = v.replaceAll('[àâä]', 'a').replaceAll('[éèêë]', 'e').replaceAll('[îï]', 'i')
             .replaceAll('[ôö]', 'o').replaceAll('[ùûü]', 'u').replaceAll('ç', 'c');
        v = v.replaceAll('[^a-z0-9]+', ' ').trim();
        List<String> words = new List<String>();
        for (String w : v.split(' ')) {
            if (String.isBlank(w)) continue;
            words.add(ADDRESS_ABBREVIATIONS.containsKey(w) ? ADDRESS_ABBREVIATIONS.get(w) : w);
        }
        return String.join(words, ' ');
    }

    private static String normalizePostal(String s) {
        return String.isBlank(s) ? '' : s.replaceAll('[^A-Za-z0-9]', '').toUpperCase();
    }

    // Recomputes the 📍 flag of the given resolved tickets against the current account address —
    // so a fix made directly on the account clears the flag too. Only writes tickets that change.
    public static void refreshAddressFlags(Set<Id> ticketIds) {
        if (ticketIds == null || ticketIds.isEmpty()) return;
        List<Zeffy_Review_Ticket__c> tickets = [
            SELECT Id, Status__c, Address__c, City__c, Postal_Code__c, Address_Differs__c, Resolved_Account__c,
                   Resolved_Account__r.BillingStreet, Resolved_Account__r.BillingCity,
                   Resolved_Account__r.BillingPostalCode
            FROM Zeffy_Review_Ticket__c WHERE Id IN :ticketIds
        ];
        List<Zeffy_Review_Ticket__c> changed = new List<Zeffy_Review_Ticket__c>();
        for (Zeffy_Review_Ticket__c t : tickets) {
            Boolean resolved = t.Status__c != null
                && (t.Status__c.startsWith('Resolved') || t.Status__c == 'Auto-Processed');
            Boolean differs = resolved && t.Resolved_Account__c != null
                && addressDiffers(t, t.Resolved_Account__r);
            if (differs != t.Address_Differs__c) {
                changed.add(new Zeffy_Review_Ticket__c(Id = t.Id, Address_Differs__c = differs));
            }
        }
        if (!changed.isEmpty()) update changed;
    }

    // Backfill / maintenance: recompute the flag on every resolved ticket (run once per org after deploy)
    public static Integer refreshAllAddressFlags() {
        Set<Id> ids = new Map<Id, Zeffy_Review_Ticket__c>([
            SELECT Id FROM Zeffy_Review_Ticket__c
            WHERE Resolved_Account__c != null OR Address_Differs__c = true
            LIMIT 5000
        ]).keySet();
        refreshAddressFlags(ids);
        return [SELECT COUNT() FROM Zeffy_Review_Ticket__c WHERE Address_Differs__c = true];
    }

    // "Update address" button: copies the Zeffy address of the ticket to the account's Billing address
    @AuraEnabled
    public static void updateAccountAddressFromTicket(Id ticketId) {
        requireZeffyAccess();
        Zeffy_Review_Ticket__c t = [
            SELECT Id, Address__c, City__c, Province__c, Postal_Code__c, Country__c, Resolved_Account__c
            FROM Zeffy_Review_Ticket__c WHERE Id = :ticketId LIMIT 1
        ];
        if (t.Resolved_Account__c == null) {
            throw new AuraHandledException('This ticket is not linked to an account.');
        }
        Account a = loadBillingAddress(t.Resolved_Account__c);
        String oldAddr = buildAddressString(a.BillingStreet, a.BillingCity, a.BillingState, a.BillingPostalCode, a.BillingCountry);
        a.BillingStreet     = t.Address__c;
        a.BillingCity       = t.City__c;
        a.BillingState      = t.Province__c;
        a.BillingPostalCode = t.Postal_Code__c;
        if (String.isNotBlank(t.Country__c)) a.BillingCountry = t.Country__c;
        try {
            if (failAddressUpdate) throw new ForcedTestException('Forced address update failure');
            update a;
        } catch (Exception e) {
            throw new AuraHandledException('The account address could not be updated: ' + e.getMessage());
        }
        String newAddr = buildAddressString(a.BillingStreet, a.BillingCity, a.BillingState, a.BillingPostalCode, a.BillingCountry);
        createAuditLog(ticketId, 'Address Updated', a.Id,
            ('Billing address: ' + (String.isBlank(oldAddr) ? '(empty)' : oldAddr) + ' → ' + newAddr).abbreviate(32000));
        // Other tickets of the same donor may now match too
        refreshAddressFlags(new Map<Id, Zeffy_Review_Ticket__c>([
            SELECT Id FROM Zeffy_Review_Ticket__c WHERE Resolved_Account__c = :a.Id LIMIT 2000
        ]).keySet());
    }

    private static void closeOpenTasks(Id ticketId) {
        List<Task> open = [SELECT Id FROM Task WHERE WhatId = :ticketId AND IsClosed = false];
        if (open.isEmpty()) return;
        for (Task t : open) t.Status = 'Completed';
        update open;
    }

    // Used by the other Zeffy Connect services (fund, config) so every change lands in one log
    public static void logAction(Id ticketId, String action, Id accountId, String notes) {
        createAuditLog(ticketId, action, accountId, notes);
    }

    private static void logCommitmentNotCreated(Id ticketId, Id accountId, String subscriptionId, String error) {
        createAuditLog(ticketId, 'Commitment Not Created', accountId,
            'The gift was recorded, but its recurring commitment (Zeffy subscription ' + subscriptionId
            + ') could not be created: ' + String.valueOf(error).abbreviate(500)
            + ' — create it by hand or fix the cause and undo/redo the resolution.');
    }

    private static void createAuditLog(Id ticketId, String action, Id accountId, String notes) {
        try {
            if (failAuditLog) throw new System.SObjectException('Forced audit log failure');
            insert new Zeffy_Connect_Audit_Log__c(
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

    // Read-only fund lookup by Zeffy form ID — safe for Guest Site User (no DML)
    private static Id lookupFundByFormId(String formId) {
        if (String.isBlank(formId)) return null;
        List<Campaign> camps = [SELECT Zeffy_Fund__c FROM Campaign WHERE Zeffy_Form_Id__c = :formId LIMIT 1];
        return camps.isEmpty() ? null : camps[0].Zeffy_Fund__c;
    }

    // Read-only campaign lookup by Zeffy form ID — safe for Guest Site User (no DML)
    private static Id lookupCampaignByFormId(String formId) {
        if (String.isBlank(formId)) return null;
        List<Campaign> camps = [SELECT Id FROM Campaign WHERE Zeffy_Form_Id__c = :formId LIMIT 1];
        return camps.isEmpty() ? null : camps[0].Id;
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
        return buildAddressString(street, city, state, zip, null);
    }

    private static String buildAddressString(String street, String city, String state, String zip, String country) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(street))  parts.add(street);
        if (String.isNotBlank(city))    parts.add(city);
        if (String.isNotBlank(state))   parts.add(state);
        if (String.isNotBlank(zip))     parts.add(zip);
        if (String.isNotBlank(country)) parts.add(country);
        return String.join(parts, ', ');
    }

    private static String buildDescription(ZeffyPayment p) {
        List<String> parts = new List<String>();
        String rt = getFirstRateTitle(p);
        if (String.isNotBlank(rt))           parts.add('Rate: ' + rt);
        if (String.isNotBlank(p.description)) parts.add('Campaign: ' + p.description);
        if (p.fund != null && String.isNotBlank(getFundName(p.fund))) parts.add('Fund: ' + getFundName(p.fund));
        return parts.isEmpty() ? null : String.join(parts, ' | ').abbreviate(255);
    }

    // Unix timestamp (seconds) → Salesforce Date in the org's time zone.
    // The webhook runs as the Site Guest User (GMT), so DateTime.date() would shift
    // evening donations to the next day (Dec 31 20:00 Montréal → Jan 1, wrong tax year).
    @TestVisible
    private static Date parseUnixDate(Long unixTs) {
        if (unixTs == null || unixTs == 0) return orgToday();
        return toOrgDate(DateTime.newInstance(unixTs * 1000L));
    }

    @TestVisible private static String orgTimeZoneId;
    @TestVisible private static Boolean failOrgTimeZoneQuery = false;
    @TestVisible
    private static String orgTimeZone() {
        if (orgTimeZoneId == null) {
            try {
                if (failOrgTimeZoneQuery) throw new ForcedTestException('Forced Organization query failure');
                orgTimeZoneId = [SELECT TimeZoneSidKey FROM Organization LIMIT 1].TimeZoneSidKey;
            } catch (Exception e) {
                orgTimeZoneId = 'America/Toronto';
            }
        }
        return orgTimeZoneId;
    }

    private static Date toOrgDate(DateTime dt) {
        return Date.valueOf(dt.format('yyyy-MM-dd', orgTimeZone()));
    }

    private static Date orgToday() {
        return toOrgDate(DateTime.now());
    }

    // A failed, pending or canceled refund gave nothing back; a refund without a status counts (payload unknown)
    @TestVisible
    private static Boolean isCompletedRefund(ZeffyRefund r) {
        return String.isBlank(r.status) || 'succeeded'.equalsIgnoreCase(r.status);
    }

    private static Date getLatestRefundDate(List<ZeffyRefund> refunds) {
        if (refunds == null || refunds.isEmpty()) return null;
        Long maxTs = 0;
        for (ZeffyRefund r : refunds) {
            if (r.created != null && r.created > maxTs && isCompletedRefund(r)) maxTs = r.created;
        }
        return maxTs > 0 ? toOrgDate(Datetime.newInstance(maxTs * 1000L)) : null;
    }

    // Zeffy sends refund_status "none" on every normal payment: store it as blank so nothing
    // downstream (chips, reports, filters) mistakes it for a refund.
    @TestVisible
    private static String realRefundStatus(String raw) {
        return String.isBlank(raw) || raw.trim().equalsIgnoreCase('none') ? null : raw;
    }

    // Zeffy API: refund_status = none / partial / full. The older names (refunded / partially_refunded)
    // are still accepted so tickets stored before the fix keep working.
    @TestVisible
    private static Boolean isFullRefundStatus(String raw) {
        if (String.isBlank(raw)) return false;
        String st = raw.trim().toLowerCase();
        return st == 'full' || st == 'refunded';
    }

    @TestVisible
    private static Boolean isPartialRefundStatus(String raw) {
        if (String.isBlank(raw)) return false;
        String st = raw.trim().toLowerCase();
        return st == 'partial' || st == 'partially_refunded';
    }

    private static String mapPaymentMethod(ZeffyPaymentMethod pm) {
        return mapPaymentMethod(pm != null ? pm.type : null);
    }

    // Gift_Transaction__c.Payment_Method__c (restricted): Credit Card / Check / Cash / Bank Transfer / PayPal / Other.
    // Overload used by CSV import (passes raw string directly). Blank = online card payment;
    // an unknown non-blank value goes to Other instead of being mislabeled as a card.
    private static String mapPaymentMethod(String raw) {
        if (String.isBlank(raw)) return 'Credit Card';
        String t = raw.toUpperCase();
        if (t == 'CARD' || t.contains('CREDIT') || t.contains('VISA') || t.contains('MASTERCARD')) return 'Credit Card';
        if (t.contains('BANK') || t.contains('ACH') || t.contains('INTERAC') || t.contains('EFT') || t.contains('PAD')) return 'Bank Transfer';
        if (t.contains('CHECK') || t.contains('CHEQUE')) return 'Check';
        if (t.contains('CASH')) return 'Cash';
        if (t.contains('PAYPAL')) return 'PayPal';
        return 'Other';
    }

    // Gift_Commitment__c.Frequency__c (restricted): Weekly / Monthly / Quarterly / Annual.
    // Biweekly has no picklist value → Monthly (the next payment date keeps the real cadence).
    @TestVisible
    private static String mapFrequency(String raw) {
        if (String.isBlank(raw)) return 'Monthly';
        String f = raw.toLowerCase();
        if (f == 'weekly' || f == 'week')               return 'Weekly';
        if (f.contains('quarter'))                     return 'Quarterly';
        if (f.contains('annual') || f.contains('year')) return 'Annual';
        return 'Monthly';
    }


    // Map campaign_type to Payment_Type__c picklist
    private static String mapPaymentType(String raw) {
        if (String.isBlank(raw)) return 'Donation';
        String t = raw.toUpperCase();
        if (t.contains('TICKET') || t.contains('EVENT')) return 'Ticket';
        if (t.contains('MEMBER')) return 'Membership';
        if (t.contains('RAFFLE') || t.contains('LOTTERY')) return 'Raffle';
        return 'Donation';
    }

    // Zeffy data.type: where the payment came from (online form, entered by hand by staff, imported).
    @TestVisible private static String mapOrigin(String raw) {
        if (String.isBlank(raw)) return null;
        String t = raw.trim().toLowerCase();
        if (t == 'online')   return 'Online';
        if (t == 'manual')   return 'Manual';
        if (t == 'imported') return 'Imported';
        return raw.trim().left(255);
    }

    // First rate_title from items array (donation or ticket line item)
    private static String getFirstRateTitle(ZeffyPayment p) {
        if (p.items == null || p.items.isEmpty()) return null;
        for (ZeffyItem item : p.items) {
            if (String.isNotBlank(item.rate_title)) return item.rate_title;
        }
        return null;
    }

    // Resolve fund name preferring org language (EN fallback → FR → ES)
    private static String getFundName(ZeffyFund fund) {
        if (fund == null || fund.name == null) return null;
        if (String.isNotBlank(fund.name.EN)) return fund.name.EN;
        if (String.isNotBlank(fund.name.FR)) return fund.name.FR;
        if (String.isNotBlank(fund.name.ES)) return fund.name.ES;
        return null;
    }

    // Canadian postal codes arrive from Zeffy without the mandatory middle space (e.g. "V1M1Y3").
    // Only applies to CA — other countries use their own formats without a space.
    private static String formatCanadianPostal(String postal, String country) {
        if (String.isBlank(postal) || !'CA'.equalsIgnoreCase(country)) return postal;
        String p = postal.trim();
        if (p.length() == 6) return p.substring(0, 3).toUpperCase() + ' ' + p.substring(3).toUpperCase();
        return postal;
    }

    // Extract and format buyer_questions from raw JSON using deserializeUntyped().
    // Required because ZeffyQuestionAnswer.answer is polymorphic: String, Boolean, or String[]
    // per the Zeffy API spec — Object fields break Apex typed deserialization silently.
    private static String extractBuyerQuestionsText(String rawBody) {
        try {
            if (failExtractBuyerQuestions) throw new ForcedTestException('Forced buyer questions failure');
            Map<String,Object> rawEvt  = (Map<String,Object>) JSON.deserializeUntyped(rawBody);
            Map<String,Object> rawData = (Map<String,Object>) rawEvt.get('data');
            if (rawData == null) return null;
            Object rawQ = rawData.get('buyer_questions');
            if (!(rawQ instanceof List<Object>)) return null;
            List<Object> qList = (List<Object>) rawQ;
            if (qList.isEmpty()) return null;

            List<String> lines = new List<String>();
            for (Object item : qList) {
                if (!(item instanceof Map<String,Object>)) continue;
                Map<String,Object> qa = (Map<String,Object>) item;
                String q   = qa.get('question') != null ? String.valueOf(qa.get('question')) : '?';
                Object raw = qa.get('answer');
                String ans;
                if (raw == null) {
                    ans = '—';
                } else if (raw instanceof Boolean) {
                    ans = ((Boolean) raw) ? 'Oui / Yes' : 'Non / No';
                } else if (raw instanceof List<Object>) {
                    List<String> parts = new List<String>();
                    for (Object o : (List<Object>) raw) parts.add(String.valueOf(o));
                    ans = String.join(parts, ', ');
                } else {
                    ans = String.valueOf(raw);
                }
                lines.add('Q: ' + q + '\nA: ' + ans);
            }
            return lines.isEmpty() ? null : String.join(lines, '\n\n').abbreviate(10000);
        } catch (Exception ex) {
            return null;
        }
    }

    // ─── LWC: dashboard statistics ───────────────────────────────────────────

    // Dashboard totals are net: canceled / refunded / voided gifts are excluded and partial
    // refunds are subtracted (Net_Amount__c is a formula, so it can't be aggregated).
    private static final List<String> EXCLUDED_FROM_TOTALS = new List<String>{ 'Canceled', 'Refunded', 'Voided' };

    private static Decimal netOf(AggregateResult ar) {
        Decimal total    = (Decimal) ar.get('total');
        Decimal refunded = (Decimal) ar.get('refunded');
        return (total == null ? 0 : total) - (refunded == null ? 0 : refunded);
    }

    private class CampaignNetDesc implements System.Comparator<Map<String, Object>> {
        public Integer compare(Map<String, Object> a, Map<String, Object> b) {
            Decimal x = (Decimal) a.get('total'), y = (Decimal) b.get('total');
            return x == y ? 0 : (x > y ? -1 : 1);
        }
    }

    // One {year, week, created, closed} entry per calendar week, shared by both weekly ticket queries
    private static Map<String, Object> weekBucket(Map<String, Map<String, Object>> weekly, AggregateResult ar) {
        String key = ar.get('yr') + '-' + ar.get('wk');
        if (!weekly.containsKey(key)) {
            weekly.put(key, new Map<String, Object>{
                'year' => ar.get('yr'), 'week' => ar.get('wk'), 'created' => 0, 'closed' => 0
            });
        }
        return weekly.get(key);
    }

    // Not cacheable: called imperatively after every resolve / undo and must reflect them at once
    @AuraEnabled
    public static Map<String, Object> getDashboardStats() {
        requireZeffyAccess();
        return new GiftAccess().dashboardStats();   // totals count every Zeffy gift, not only the user's own
    }

    private static Map<String, Object> getDashboardStatsImpl() {
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

        // Auto-processed: gifts with Zeffy ID that have NO resolved ticket
        Set<Id> resolvedGiftIds = new Set<Id>();
        for (Zeffy_Review_Ticket__c t : [
            SELECT Resolved_Gift__c FROM Zeffy_Review_Ticket__c
            WHERE Resolved_Gift__c != null AND Status__c != 'Auto-Processed'
        ]) {
            resolvedGiftIds.add(t.Resolved_Gift__c);
        }
        Integer autoProcessed = [
            SELECT COUNT() FROM Gift_Transaction__c
            WHERE Zeffy_Transaction_Id__c != null AND Id NOT IN :resolvedGiftIds
        ];
        Integer manualResolved = [
            SELECT COUNT() FROM Zeffy_Review_Ticket__c WHERE Status__c LIKE 'Resolved%'
        ];
        stats.put('autoProcessed', autoProcessed);
        stats.put('manualResolved', manualResolved);

        // Total amount and match rate
        AggregateResult totalAmtResult = [
            SELECT SUM(Amount__c) total, SUM(Refunded_Amount__c) refunded FROM Gift_Transaction__c
            WHERE Zeffy_Transaction_Id__c != null AND Status__c NOT IN :EXCLUDED_FROM_TOTALS
        ];
        Decimal totalAmt = netOf(totalAmtResult);
        stats.put('totalAmount', totalAmt);
        Integer totalProcessed = autoProcessed + manualResolved;
        stats.put('matchRatePct', totalProcessed > 0 ? Math.round(100.0 * autoProcessed / totalProcessed) : 0);

        // Top 5 campaigns by amount
        List<Map<String, Object>> campaignStats = new List<Map<String, Object>>();
        for (AggregateResult ar : [
            SELECT Campaign__c cid, Campaign__r.Name cname, SUM(Amount__c) total, SUM(Refunded_Amount__c) refunded, COUNT(Id) cnt
            FROM Gift_Transaction__c
            WHERE Zeffy_Transaction_Id__c != null AND Campaign__c != null
              AND Status__c NOT IN :EXCLUDED_FROM_TOTALS
            GROUP BY Campaign__c, Campaign__r.Name
        ]) {
            campaignStats.add(new Map<String, Object>{
                'id'    => ar.get('cid'),
                'name'  => ar.get('cname'),
                'total' => netOf(ar),
                'count' => ar.get('cnt')
            });
        }
        // Rank by net amount (refunds subtracted), the figure the dashboard shows
        campaignStats.sort(new CampaignNetDesc());
        while (campaignStats.size() > 5) campaignStats.remove(campaignStats.size() - 1);
        stats.put('byCampaign', campaignStats);

        // Weekly tickets — last 24 weeks: how many arrived and how many were closed (any way: robot, linked, created, closed)
        Datetime twentyFourWeeksAgo = Datetime.newInstance(Date.today().addDays(-168), Time.newInstance(0, 0, 0, 0));
        Map<String, Map<String, Object>> weekly = new Map<String, Map<String, Object>>();
        for (AggregateResult ar : [
            SELECT CALENDAR_YEAR(convertTimezone(CreatedDate)) yr, WEEK_IN_YEAR(convertTimezone(CreatedDate)) wk, COUNT(Id) cnt
            FROM Zeffy_Review_Ticket__c
            WHERE CreatedDate >= :twentyFourWeeksAgo
            GROUP BY CALENDAR_YEAR(convertTimezone(CreatedDate)), WEEK_IN_YEAR(convertTimezone(CreatedDate))
        ]) {
            weekBucket(weekly, ar).put('created', ar.get('cnt'));
        }
        for (AggregateResult ar : [
            SELECT CALENDAR_YEAR(convertTimezone(Resolved_At__c)) yr, WEEK_IN_YEAR(convertTimezone(Resolved_At__c)) wk, COUNT(Id) cnt
            FROM Zeffy_Review_Ticket__c
            WHERE Resolved_At__c >= :twentyFourWeeksAgo
            GROUP BY CALENDAR_YEAR(convertTimezone(Resolved_At__c)), WEEK_IN_YEAR(convertTimezone(Resolved_At__c))
        ]) {
            weekBucket(weekly, ar).put('closed', ar.get('cnt'));
        }
        stats.put('weekly', weekly.values());

        // Monthly totals — all time (for month navigator in dashboard)
        List<Map<String, Object>> monthlyStats = new List<Map<String, Object>>();
        for (AggregateResult ar : [
            SELECT CALENDAR_YEAR(Gift_Date__c) yr, CALENDAR_MONTH(Gift_Date__c) mo,
                   SUM(Amount__c) total, SUM(Refunded_Amount__c) refunded, COUNT(Id) cnt
            FROM Gift_Transaction__c
            WHERE Zeffy_Transaction_Id__c != null AND Gift_Date__c != null
              AND Status__c NOT IN :EXCLUDED_FROM_TOTALS
            GROUP BY CALENDAR_YEAR(Gift_Date__c), CALENDAR_MONTH(Gift_Date__c)
            ORDER BY CALENDAR_YEAR(Gift_Date__c), CALENDAR_MONTH(Gift_Date__c)

        ]) {
            monthlyStats.add(new Map<String, Object>{
                'year'  => ar.get('yr'),
                'month' => ar.get('mo'),
                'total' => netOf(ar),
                'count' => ar.get('cnt')
            });
        }
        stats.put('monthly', monthlyStats);

        // Duplicate detection: Zeffy Contact IDs with more than one pending ticket
        List<String> dupContactIds = new List<String>();
        for (AggregateResult ar : [
            SELECT Zeffy_Contact_Id__c cid, COUNT(Id) cnt
            FROM Zeffy_Review_Ticket__c
            WHERE Status__c = 'Pending Review' AND Zeffy_Contact_Id__c != null
            GROUP BY Zeffy_Contact_Id__c
            HAVING COUNT(Id) > 1
        ]) {
            dupContactIds.add((String) ar.get('cid'));
        }
        stats.put('duplicateContactIds', dupContactIds);

        // Recent resolutions
        List<Zeffy_Review_Ticket__c> recent = [
            SELECT Id, Name, First_Name__c, Last_Name__c, Company_Name__c,
                   Amount__c, Currency__c, Status__c, Resolved_At__c,
                   Resolved_By__c, Resolved_By__r.Name,
                   Resolved_Account__c, Resolved_Account__r.Name
            FROM Zeffy_Review_Ticket__c
            WHERE Status__c LIKE 'Resolved%' OR Status__c = 'Auto-Processed'
            ORDER BY Resolved_At__c DESC NULLS LAST
            LIMIT 10
        ];
        stats.put('recentResolutions', recent);

        return stats;
    }

    @AuraEnabled(cacheable=false)
    public static List<Map<String, Object>> getCampaignMappings() {
        requireZeffyAccess();
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Campaign c : [
            SELECT Id, Name, Zeffy_Form_Id__c, Is_Zeffy_Managed__c, IsActive
            FROM Campaign
            WHERE Zeffy_Form_Id__c != null
            ORDER BY Name
            LIMIT 200
        ]) {
            result.add(new Map<String, Object>{
                'id'            => c.Id,
                'name'          => c.Name,
                'formId'        => c.Zeffy_Form_Id__c,
                'isZeffyManaged'=> c.Is_Zeffy_Managed__c,
                'isActive'      => c.IsActive
            });
        }
        return result;
    }

    @AuraEnabled
    public static void saveCampaignMapping(Id campaignId, String formId, Boolean isZeffyManaged) {
        ZeffyConnectConfigService.requireSettingsAccess();
        update new Campaign(
            Id                  = campaignId,
            Zeffy_Form_Id__c    = String.isNotBlank(formId) ? formId : null,
            Is_Zeffy_Managed__c = isZeffyManaged != null ? isZeffyManaged : false
        );
        createAuditLog(null, 'Campaign Mapping Changed', null,
            'Campaign ' + campaignId + ' → Zeffy form ' + (String.isNotBlank(formId) ? formId : '(none)')
            + ', managed by Zeffy: ' + (isZeffyManaged == true));
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> searchCampaigns(String searchTerm) {
        requireZeffyAccess();
        String q = '%' + (String.isBlank(searchTerm) ? '' : searchTerm) + '%';
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Campaign c : [
            SELECT Id, Name, Zeffy_Form_Id__c, Is_Zeffy_Managed__c
            FROM Campaign
            WHERE Name LIKE :q
            ORDER BY Name LIMIT 10
        ]) {
            result.add(new Map<String, Object>{
                'id'      => c.Id,
                'name'    => c.Name,
                'formId'  => c.Zeffy_Form_Id__c,
                'managed' => c.Is_Zeffy_Managed__c
            });
        }
        return result;
    }

    // ─── LWC: undo resolution — deletes gift and reopens ticket ──────────────

    // Returns what was undone so the screen can tell staff: giftDeleted, commitmentDeleted,
    // commitmentKept (other installments), campaignDeleted (name), identityRemoved (name), accountKept (name).
    @AuraEnabled
    public static Map<String, String> undoResolution(Id ticketId) {
        requireZeffyAccess();
        return new GiftAccess().undo(ticketId);
    }
    private static Map<String, String> undoResolutionImpl(Id ticketId) {
        Zeffy_Review_Ticket__c ticket = [
            SELECT Id, Status__c, Resolved_Gift__c, Resolved_Account__c, Zeffy_Subscription_Id__c,
                   Amount__c, Zeffy_Contact_Id__c, Resolved_At__c, Transaction_Status__c
            FROM Zeffy_Review_Ticket__c
            WHERE Id = :ticketId
            LIMIT 1
        ];
        // Undo reopens the ticket for a new resolution: never for a payment Zeffy deleted (its
        // cancelled gift is the trace) nor for tickets that were never resolved.
        if ('deleted'.equalsIgnoreCase(ticket.Transaction_Status__c)
                || new Set<String>{ 'Holding', 'Delayed', 'Payment Failed', 'Closed', 'Skipped', 'Error' }.contains(ticket.Status__c)) {
            throw new AuraHandledException('Only resolved tickets can be undone (current: ' + ticket.Status__c
                + ('deleted'.equalsIgnoreCase(ticket.Transaction_Status__c) ? ', deleted in Zeffy' : '') + ').');
        }

        Id prevAccountId = ticket.Resolved_Account__c;
        List<String> notes = new List<String>();
        Map<String, String> summary = new Map<String, String>();
        Savepoint sp = Database.setSavepoint();

        // Campaign of the gift, captured before the gift is deleted (auto-created campaigns are cleaned up below)
        Id giftCampaignId;
        if (ticket.Resolved_Gift__c != null) {
            List<Gift_Transaction__c> gts = [SELECT Campaign__c FROM Gift_Transaction__c WHERE Id = :ticket.Resolved_Gift__c LIMIT 1];
            if (!gts.isEmpty()) giftCampaignId = gts[0].Campaign__c;
        }

        // Delete the Gift_Transaction__c created during resolution — if it can't be deleted the undo
        // is aborted: reopening the ticket would let staff create a second gift for the same payment.
        if (ticket.Resolved_Gift__c != null) {
            try {
                if (failGiftDelete) throw new ForcedTestException('Forced gift delete failure');
                List<Gift_Transaction__c> gifts = [SELECT Id FROM Gift_Transaction__c WHERE Id = :ticket.Resolved_Gift__c LIMIT 1];
                delete gifts;
                if (!gifts.isEmpty()) {
                    summary.put('giftDeleted', 'true');
                    notes.add('Gift deleted.');
                }
            } catch (Exception e) {
                Database.rollback(sp);
                throw new AuraHandledException('The gift could not be deleted, nothing was undone: '
                    + e.getMessage());
            }
        }

        // Delete the robot-created Gift_Commitment__c (identified by subscription ID; manually created
        // commitments never have one) — only when no other installment still points to it.
        if (String.isNotBlank(ticket.Zeffy_Subscription_Id__c)) {
            try {
                if (failCommitmentDelete) throw new ForcedTestException('Forced commitment delete failure');
                List<Gift_Commitment__c> cmts = [
                    SELECT Id FROM Gift_Commitment__c
                    WHERE Zeffy_Subscription_Id__c = :ticket.Zeffy_Subscription_Id__c LIMIT 1
                ];
                if (!cmts.isEmpty()) {
                    Integer others = [SELECT COUNT() FROM Gift_Transaction__c WHERE Recurring_Gift__c = :cmts[0].Id];
                    if (others == 0) {
                        delete cmts;
                        summary.put('commitmentDeleted', 'true');
                        notes.add('Recurring commitment deleted.');
                    } else {
                        summary.put('commitmentKept', String.valueOf(others));
                        notes.add('Recurring commitment kept (' + others + ' other installment(s)).');
                    }
                }
            } catch (Exception e) {
                notes.add('Recurring commitment not deleted: ' + e.getMessage());
            }
        }

        // Remove the Zeffy ID link this resolution registered, so the next payment is not
        // auto-matched to the wrong donor. Kept when anything else already relies on it.
        String removedIdentity = removeIdentityFromResolution(ticket);
        if (removedIdentity != null) {
            summary.put('identityRemoved', removedIdentity);
            notes.add('Zeffy ID link removed: ' + removedIdentity + '.');
        }

        String removedCampaign = removeCampaignFromResolution(giftCampaignId, ticket.Resolved_At__c);
        if (removedCampaign != null) {
            summary.put('campaignDeleted', removedCampaign);
            notes.add('Campaign "' + removedCampaign + '" deleted (created by this resolution, nothing else uses it).');
        }

        // The account is never deleted: it may be a real donor and staff decides what to do with it
        if (prevAccountId != null) {
            List<Account> accs = queryAccountsWithContacts(new Set<Id>{ prevAccountId });
            if (!accs.isEmpty()) {
                String accName = accountDisplayName(accs[0]);
                summary.put('accountKept', accName);
                notes.add('Account kept: ' + accName + '.');
            }
        }

        // Reopen the ticket
        ticket.Status__c           = 'Pending Review';
        ticket.Address_Differs__c  = false;
        ticket.Resolved_Account__c = null;
        ticket.Resolved_By__c      = null;
        ticket.Resolved_At__c      = null;
        ticket.Resolution_Notes__c = null;
        ticket.Resolved_Gift__c    = null;
        // The amount warning belonged to the deleted gift; the reopened ticket already holds Zeffy's amount
        ticket.Zeffy_Amount_Not_Applied__c = null;
        ticket.Zeffy_Amount_Reviewed__c    = null;
        update ticket;

        createAuditLog(ticketId, 'Rolled Back', prevAccountId, notes.isEmpty() ? null : String.join(notes, ' '));
        return summary;
    }

    // Deletes the Zeffy campaign this ticket's resolution auto-created (Is_Zeffy_Managed__c, created
    // at resolution time) when no gift, commitment, opportunity, member or child campaign uses it any
    // more — i.e. the undone donor was its only donor. With any other donor it is always kept.
    // Staff-made campaigns and campaigns that existed before the resolution are never touched.
    private static String removeCampaignFromResolution(Id campaignId, DateTime resolvedAt) {
        if (campaignId == null || resolvedAt == null) return null;
        try {
            if (failCampaignRemoval) throw new ForcedTestException('Forced campaign removal failure');
            List<Campaign> cs = [
                SELECT Id, Name, CreatedDate, Is_Zeffy_Managed__c FROM Campaign WHERE Id = :campaignId LIMIT 1
            ];
            if (cs.isEmpty() || !cs[0].Is_Zeffy_Managed__c) return null;
            Campaign c = cs[0];
            if (c.CreatedDate < resolvedAt.addMinutes(-1) || c.CreatedDate > resolvedAt.addMinutes(1)) return null;
            if ([SELECT COUNT() FROM Gift_Transaction__c WHERE Campaign__c = :c.Id] > 0) return null;
            if ([SELECT COUNT() FROM Gift_Commitment__c  WHERE Campaign__c = :c.Id] > 0) return null;
            if ([SELECT COUNT() FROM CampaignMember  WHERE CampaignId = :c.Id] > 0) return null;
            if ([SELECT COUNT() FROM Campaign        WHERE ParentId   = :c.Id] > 0) return null;
            if ([SELECT COUNT() FROM Opportunity     WHERE CampaignId = :c.Id] > 0) return null;
            delete c;
            return c.Name;
        } catch (Exception e) {
            // Leftover campaign is harmless; the undo itself must not fail because of it
            return null;
        }
    }

    // Deletes the Zeffy_Identity__c this ticket's resolution created (same account, created at
    // resolution time) unless another resolved ticket or a later Zeffy gift of that account uses it.
    private static String removeIdentityFromResolution(Zeffy_Review_Ticket__c ticket) {
        if (String.isBlank(ticket.Zeffy_Contact_Id__c) || ticket.Resolved_Account__c == null
                || ticket.Resolved_At__c == null) return null;
        // The robot only matches an existing Zeffy ID, it never registers one → nothing to remove
        if (ticket.Status__c == 'Auto-Processed') return null;
        List<Zeffy_Identity__c> ids = [
            SELECT Id, Name, CreatedDate FROM Zeffy_Identity__c
            WHERE Zeffy_Contact_Id__c = :ticket.Zeffy_Contact_Id__c
              AND Account__c = :ticket.Resolved_Account__c
            LIMIT 1
        ];
        if (ids.isEmpty()) return null;
        Zeffy_Identity__c zi = ids[0];
        // Existed before this resolution (linked earlier by staff or by an older payment) → keep
        if (zi.CreatedDate < ticket.Resolved_At__c.addMinutes(-1)) return null;
        Integer otherTickets = [
            SELECT COUNT() FROM Zeffy_Review_Ticket__c
            WHERE Id != :ticket.Id AND Zeffy_Contact_Id__c = :ticket.Zeffy_Contact_Id__c
              AND Resolved_Account__c = :ticket.Resolved_Account__c
              AND (Status__c LIKE 'Resolved%' OR Status__c = 'Auto-Processed')
        ];
        Integer laterGifts = [
            SELECT COUNT() FROM Gift_Transaction__c
            WHERE Donor_Account__c = :ticket.Resolved_Account__c AND Zeffy_Transaction_Id__c != null
              AND CreatedDate > :zi.CreatedDate.addMinutes(1)
        ];
        if (otherTickets > 0 || laterGifts > 0) return null;
        delete zi;
        return zi.Name;
    }

    @AuraEnabled
    public static List<Zeffy_Connect_Audit_Log__c> getAuditLog(String searchTerm) {
        requireZeffyAccess();
        if (String.isBlank(searchTerm)) {
            return [
                SELECT Id, Name,
                       Ticket__c, Ticket__r.Name,
                       Action__c,
                       Performed_By__c, Performed_By__r.Name,
                       Performed_At__c,
                       Account__c, Account__r.Name,
                       Notes__c
                FROM Zeffy_Connect_Audit_Log__c
                ORDER BY Performed_At__c DESC
                LIMIT 2000
            ];
        }
        String q = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
        Set<Id> matchAccIds = findAccountIdsByLike(q, 500);
        return [
            SELECT Id, Name,
                   Ticket__c, Ticket__r.Name,
                   Action__c,
                   Performed_By__c, Performed_By__r.Name,
                   Performed_At__c,
                   Account__c, Account__r.Name,
                   Notes__c
            FROM Zeffy_Connect_Audit_Log__c
            WHERE Name LIKE :q
               OR Ticket__r.Name LIKE :q
               OR Account__r.Name LIKE :q
               OR Performed_By__r.Name LIKE :q
               OR Account__c IN :matchAccIds
            ORDER BY Performed_At__c DESC
            LIMIT 2000
        ];
    }

    // ─── Donation history row (returned to LWC Donation History tab) ──────────

    public class DonationHistoryRow implements Comparable {
        @AuraEnabled public String  Id;
        @AuraEnabled public String  Name;
        @AuraEnabled public String  DonorName;
        @AuraEnabled public Decimal Amount;
        @AuraEnabled public String  TransactionDate;
        @AuraEnabled public String  PaymentMethod;
        @AuraEnabled public String  ZeffyTransactionId;
        @AuraEnabled public String  TicketName;   // null = auto-processed
        @AuraEnabled public String  TicketId;     // Zeffy_Review_Ticket__c Id
        @AuraEnabled public Boolean IsManual;
        @AuraEnabled public Boolean IsUndone;     // gift was deleted by Undo and not re-linked to the same donor
        @AuraEnabled public String  UndoneAt;
        @AuraEnabled public String  UndoneBy;

        // Newest first; rows without a date go last
        public Integer compareTo(Object other) {
            String a = this.TransactionDate;
            String b = ((DonationHistoryRow) other).TransactionDate;
            Boolean aNone = String.isBlank(a) || a == '—';
            Boolean bNone = String.isBlank(b) || b == '—';
            if (aNone && bNone) return 0;
            if (aNone) return 1;
            if (bNone) return -1;
            return b.compareTo(a);
        }
    }

    @AuraEnabled
    public static List<DonationHistoryRow> getDonationHistory(String searchTerm) {
        requireZeffyAccess();
        return new GiftAccess().donationHistory(searchTerm);
    }

    private static List<DonationHistoryRow> getDonationHistoryImpl(String searchTerm) {
        List<Gift_Transaction__c> gifts;
        if (String.isBlank(searchTerm)) {
            gifts = [
                SELECT Id, Name, Donor_Account__c, Donor_Account__r.Name, Donor__c, Donor__r.Name,
                       Amount__c, Gift_Date__c, Payment_Method__c, Zeffy_Transaction_Id__c
                FROM Gift_Transaction__c
                WHERE Zeffy_Transaction_Id__c != null
                ORDER BY Gift_Date__c DESC LIMIT 2000
            ];
        } else {
            String q = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
            // Accounts matching by name, phone or email (Account fields + its Contacts)
            Set<Id> matchAccIds = findAccountIdsByLike(q, 500);
            // Find gift IDs linked to matching tickets
            Set<Id> matchGiftIds = new Set<Id>();
            for (Zeffy_Review_Ticket__c t : [
                SELECT Resolved_Gift__c FROM Zeffy_Review_Ticket__c
                WHERE Name LIKE :q AND Resolved_Gift__c != null
                LIMIT 500
            ]) { matchGiftIds.add(t.Resolved_Gift__c); }
            gifts = [
                SELECT Id, Name, Donor_Account__c, Donor_Account__r.Name, Donor__c, Donor__r.Name,
                       Amount__c, Gift_Date__c, Payment_Method__c, Zeffy_Transaction_Id__c
                FROM Gift_Transaction__c
                WHERE Zeffy_Transaction_Id__c != null
                  AND (Zeffy_Transaction_Id__c LIKE :q
                       OR Donor_Account__c IN :matchAccIds
                       OR Id IN :matchGiftIds)
                ORDER BY Gift_Date__c DESC LIMIT 2000
            ];
        }

        // Find which gifts came from manual ticket resolution (robot gifts also have an
        // Auto-Processed ticket, but they are not manual)
        Set<Id> giftIds = (new Map<Id, Gift_Transaction__c>(gifts)).keySet();
        Map<Id, String> giftToTicket   = new Map<Id, String>();
        Map<Id, String> giftToTicketId = new Map<Id, String>();
        Set<Id> robotGiftIds           = new Set<Id>();
        for (Zeffy_Review_Ticket__c t : [
            SELECT Id, Resolved_Gift__c, Name, Status__c
            FROM Zeffy_Review_Ticket__c
            WHERE Resolved_Gift__c IN :giftIds
        ]) {
            giftToTicket.put(t.Resolved_Gift__c, t.Name);
            giftToTicketId.put(t.Resolved_Gift__c, t.Id);
            if (t.Status__c == 'Auto-Processed') robotGiftIds.add(t.Resolved_Gift__c);
        }

        List<DonationHistoryRow> result = new List<DonationHistoryRow>();
        for (Gift_Transaction__c g : gifts) {
            DonationHistoryRow row = new DonationHistoryRow();
            row.Id                 = g.Id;
            row.Name               = g.Name;
            // A person shows by its Contact, a church/organization by its Account
            row.DonorName          = g.Donor__c != null ? g.Donor__r.Name
                                   : g.Donor_Account__c != null ? g.Donor_Account__r.Name : '—';
            row.Amount             = g.Amount__c;
            row.TransactionDate    = g.Gift_Date__c != null
                                     ? String.valueOf(g.Gift_Date__c) : '—';
            row.PaymentMethod      = g.Payment_Method__c;
            row.ZeffyTransactionId = g.Zeffy_Transaction_Id__c;
            row.TicketName         = giftToTicket.containsKey(g.Id)
                                     ? giftToTicket.get(g.Id) : null;
            row.TicketId           = giftToTicketId.containsKey(g.Id)
                                     ? giftToTicketId.get(g.Id) : null;
            row.IsManual           = giftToTicket.containsKey(g.Id) && !robotGiftIds.contains(g.Id);
            row.IsUndone           = false;
            result.add(row);
        }
        result.addAll(getUndoneHistoryRows(searchTerm));
        result.sort();
        return result;
    }

    // SEMBEQ: Account Ids matching a LIKE term by Account name/phone/email fields or by the
    // name/email/phone of one of its Contacts (a person is a Contact in an Administrative Account)
    private static Set<Id> findAccountIdsByLike(String q, Integer lim) {
        Set<Id> ids = new Set<Id>();
        for (Account a : [
            SELECT Id FROM Account
            WHERE Name LIKE :q OR Phone LIKE :q OR Alternative_Phone__c LIKE :q
               OR Email_Address__c LIKE :q OR Email_Personal__c LIKE :q
            LIMIT :lim
        ]) { ids.add(a.Id); }
        for (Contact c : [
            SELECT AccountId FROM Contact
            WHERE AccountId != null
              AND (Name LIKE :q OR Email LIKE :q OR Phone LIKE :q OR MobilePhone LIKE :q OR HomePhone LIKE :q)
            LIMIT :lim
        ]) { ids.add(c.AccountId); }
        return ids;
    }

    // Undo deletes the gift, so undone donations are rebuilt from the audit log.
    // One row per (ticket, donor) — latest undo wins. Dropped once the ticket is re-linked
    // to that same donor; kept if it was re-linked to someone else.
    @TestVisible
    private static List<DonationHistoryRow> getUndoneHistoryRows(String searchTerm) {
        String q = String.isBlank(searchTerm) ? null : searchTerm.trim().toLowerCase();
        Map<String, DonationHistoryRow> byKey = new Map<String, DonationHistoryRow>();
        for (Zeffy_Connect_Audit_Log__c l : [
            SELECT Id, Ticket__c, Ticket__r.Name, Ticket__r.Amount__c, Ticket__r.Gift_Date__c,
                   Ticket__r.Payment_Method__c,
                   Ticket__r.Zeffy_Transaction_Id__c, Ticket__r.Resolved_Account__c,
                   Account__c, Account__r.Name, Performed_At__c, Performed_By__r.Name
            FROM Zeffy_Connect_Audit_Log__c
            WHERE Action__c = 'Rolled Back' AND Ticket__c != null
            ORDER BY Performed_At__c DESC
            LIMIT 2000
        ]) {
            String key = l.Ticket__c + '|' + l.Account__c;
            if (byKey.containsKey(key)) continue;                                  // keep latest only
            if (l.Account__c != null && l.Account__c == l.Ticket__r.Resolved_Account__c) {
                byKey.put(key, null);                                              // re-linked to same donor
                continue;
            }
            DonationHistoryRow row = new DonationHistoryRow();
            row.Id                 = l.Id;
            row.Name               = l.Ticket__r.Zeffy_Transaction_Id__c;
            row.DonorName          = l.Account__r != null ? l.Account__r.Name : '—';
            row.Amount             = l.Ticket__r.Amount__c;
            row.TransactionDate    = l.Ticket__r.Gift_Date__c != null
                                     ? String.valueOf(l.Ticket__r.Gift_Date__c) : '—';
            row.PaymentMethod      = l.Ticket__r.Payment_Method__c;
            row.ZeffyTransactionId = l.Ticket__r.Zeffy_Transaction_Id__c;
            row.TicketName         = l.Ticket__r.Name;
            row.TicketId           = l.Ticket__c;
            row.IsManual           = true;
            row.IsUndone           = true;
            row.UndoneAt           = l.Performed_At__c != null
                                     ? l.Performed_At__c.format('yyyy-MM-dd HH:mm') : null;
            row.UndoneBy           = l.Performed_By__r != null ? l.Performed_By__r.Name : null;
            if (q != null) {
                String hay = ((row.TicketName ?? '') + ' ' + (row.DonorName ?? '') + ' '
                             + (row.ZeffyTransactionId ?? '')).toLowerCase();
                if (!hay.contains(q)) continue;
            }
            byKey.put(key, row);
        }
        List<DonationHistoryRow> rows = new List<DonationHistoryRow>();
        for (DonationHistoryRow r : byKey.values()) if (r != null) rows.add(r);
        return rows;
    }

    // ─── My Tasks: open tasks related to Zeffy tickets for the current user ─────
    @AuraEnabled(cacheable=false)
    public static List<Map<String, Object>> getMyTasks() {
        requireZeffyAccess();
        List<Task> tasks = [
            SELECT Id, Subject, ActivityDate, WhatId, What.Name, Priority, Status, Description
            FROM Task
            WHERE OwnerId = :UserInfo.getUserId()
              AND IsClosed = false
              AND WhatId != null
              AND What.Type = 'Zeffy_Review_Ticket__c'
            ORDER BY ActivityDate ASC NULLS LAST, CreatedDate ASC
            LIMIT 50
        ];
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Task t : tasks) {
            result.add(new Map<String, Object>{
                'id'          => t.Id,
                'subject'     => t.Subject,
                'dueDate'     => t.ActivityDate != null ? String.valueOf(t.ActivityDate) : null,
                'ticketId'    => String.valueOf(t.WhatId),
                'ticketName'  => t.What != null ? t.What.Name : null,
                'priority'    => t.Priority,
                'description' => t.Description
            });
        }
        return result;
    }

    // ─── Manually assign a ticket to a specific person ────────────────────────
    // Cancels the global auto-task (if open), creates a personal task, and
    // stamps the ticket with the special assignee so the card badge shows it.
    @AuraEnabled
    public static void assignTicket(Id ticketId, String ownerId, String ownerName,
                                    Integer dueDays, String note) {
        requireZeffyAccess();
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
                : 'This donor has been personally assigned to you for review in Zeffy Connect.'
        );

        // 3. Stamp the ticket so the card badge reflects the special assignee
        update new Zeffy_Review_Ticket__c(
            Id                      = ticketId,
            Manual_Assignee_Id__c   = ownerId,
            Manual_Assignee_Name__c = ownerName
        );
        createAuditLog(ticketId, 'Assigned', null,
            ('Assigned to ' + ownerName + ' (due in ' + days + ' day(s))'
             + (String.isNotBlank(note) ? ': ' + note : '')).left(32000));
    }

    @AuraEnabled
    public static void clearTicketAssignment(Id ticketId) {
        requireZeffyAccess();
        if (ticketId == null) return;
        Zeffy_Review_Ticket__c t = [
            SELECT Name, First_Name__c, Last_Name__c, Company_Name__c,
                   Manual_Assignee_Id__c, Manual_Assignee_Name__c
            FROM Zeffy_Review_Ticket__c WHERE Id = :ticketId LIMIT 1
        ];
        String prevAssigneeId = t.Manual_Assignee_Id__c;
        List<String> np = new List<String>();
        if (String.isNotBlank(t.First_Name__c)) np.add(t.First_Name__c);
        if (String.isNotBlank(t.Last_Name__c))  np.add(t.Last_Name__c);
        String donorName = np.isEmpty()
            ? (String.isNotBlank(t.Company_Name__c) ? t.Company_Name__c : t.Name)
            : String.join(np, ' ');

        List<Task> personal = [
            SELECT Id FROM Task
            WHERE WhatId = :ticketId
              AND Subject LIKE 'VIP donation review%'
              AND IsClosed = false
        ];
        if (!personal.isEmpty()) delete personal;
        update new Zeffy_Review_Ticket__c(
            Id                      = ticketId,
            Manual_Assignee_Id__c   = null,
            Manual_Assignee_Name__c = null
        );
        createAuditLog(ticketId, 'Unassigned', null,
            'Assignment removed' + (String.isNotBlank(t.Manual_Assignee_Name__c) ? ' (was ' + t.Manual_Assignee_Name__c + ')' : '') + '.');
    }

    // ─── CSV bulk import (max 500 rows per call, call in chunks from LWC) ────

    @AuraEnabled
    public static Map<String,Object> importTickets(String rowsJson) {
        requireZeffyAccess();
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
            // Payments the robot already auto-processed have a gift but no ticket
            // Without sharing: a gift owned by someone else is still an existing payment
            for (Gift_Transaction__c g : new GiftAccess().giftsByTransactionIds(incomingTxIds)) {
                existingTxIds.add(g.Zeffy_Transaction_Id__c);
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
        if (imported > 0 || !errors.isEmpty()) {
            createAuditLog(null, 'CSV Import', null,
                'CSV import: ' + imported + ' ticket(s) created, ' + skipped + ' already in Salesforce'
                + (errors.isEmpty() ? '.' : ', ' + errors.size() + ' error(s): ' + String.join(errors, ' | ')).left(30000));
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
        t.Zeffy_Origin__c             = mapOrigin(csvStr(row, 'origin'));
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

    // ─── Transaction timeline (for modal in ticket detail view) ─────────────

    public class TimelineEntry {
        @AuraEnabled public String  occurredAt;
        @AuraEnabled public String  eventType;
        @AuraEnabled public String  status;
        @AuraEnabled public String  message;
    }

    @AuraEnabled(cacheable=false)
    public static List<TimelineEntry> getTransactionTimeline(String transactionId) {
        requireZeffyAccess();
        List<TimelineEntry> timeline = new List<TimelineEntry>();
        if (String.isBlank(transactionId)) return timeline;
        for (Zeffy_Webhook_Log__c log : [
            SELECT Occurred_At__c, Event_Type__c, Status__c, Message__c
            FROM Zeffy_Webhook_Log__c
            WHERE Transaction_Id__c = :transactionId
            ORDER BY Occurred_At__c ASC
            LIMIT 50
        ]) {
            TimelineEntry e  = new TimelineEntry();
            e.occurredAt = log.Occurred_At__c != null ? log.Occurred_At__c.format('yyyy-MM-dd HH:mm:ss') : '';
            e.eventType  = String.isNotBlank(log.Event_Type__c) ? log.Event_Type__c : '—';
            e.status     = log.Status__c;
            e.message    = log.Message__c;
            timeline.add(e);
        }
        return timeline;
    }

    // ─── Robot Health: summary stats for Settings → Robot Health section ─────

    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getWebhookHealthStats() {
        requireZeffyAccess();
        Map<String, Object> stats = new Map<String, Object>();

        Zeffy_Config__c cfg = ZeffyConnectConfigService.getConfig();
        stats.put('isActive', cfg != null && cfg.Is_Active__c);

        // Last webhook received
        List<Zeffy_Webhook_Log__c> lastLog = [
            SELECT Occurred_At__c, Status__c
            FROM Zeffy_Webhook_Log__c
            ORDER BY Occurred_At__c DESC NULLS LAST
            LIMIT 1
        ];
        stats.put('lastReceivedAt', lastLog.isEmpty() ? null : String.valueOf(lastLog[0].Occurred_At__c));
        stats.put('lastStatus',     lastLog.isEmpty() ? null : lastLog[0].Status__c);

        // ── Today stats (since midnight in org timezone) ──────────────────────
        DateTime todayStart = DateTime.newInstance(Date.today(), Time.newInstance(0, 0, 0, 0));
        Integer todayTotal = 0, todaySuccess = 0, todayErrors = 0, todayDuplicates = 0;
        for (AggregateResult ar : [
            SELECT Status__c s, COUNT(Id) cnt
            FROM Zeffy_Webhook_Log__c
            WHERE Occurred_At__c >= :todayStart
            GROUP BY Status__c
        ]) {
            String  st  = (String)  ar.get('s');
            Integer ct  = (Integer) ar.get('cnt');
            todayTotal += ct;
            if      (st == 'SUCCESS')            todaySuccess    += ct;
            else if (st == 'DUPLICATE_SKIPPED' || st == 'IGNORED')  todayDuplicates += ct;
            else                                  todayErrors     += ct;
        }
        Integer todaySuccessPct = todayTotal > 0
            ? (Integer) Math.round(100.0 * todaySuccess / todayTotal) : 0;
        stats.put('todayTotal',      todayTotal);
        stats.put('todaySuccess',    todaySuccess);
        stats.put('todayErrors',     todayErrors);
        stats.put('todayDuplicates', todayDuplicates);
        stats.put('todaySuccessPct', todaySuccessPct);

        // ── Last 7 days (for secondary reference) ─────────────────────────────
        DateTime sevenDaysAgo = DateTime.now().addDays(-7);
        Integer total7 = 0, success7 = 0, error7 = 0;
        for (AggregateResult ar : [
            SELECT Status__c s, COUNT(Id) cnt
            FROM Zeffy_Webhook_Log__c
            WHERE Occurred_At__c >= :sevenDaysAgo
            GROUP BY Status__c
        ]) {
            String  st  = (String)  ar.get('s');
            Integer ct  = (Integer) ar.get('cnt');
            total7 += ct;
            if (st == 'SUCCESS' || st == 'DUPLICATE_SKIPPED' || st == 'IGNORED') success7 += ct;
            else                                               error7   += ct;
        }
        stats.put('totalLast7Days',   total7);
        stats.put('successLast7Days', success7);
        stats.put('errorLast7Days',   error7);

        stats.put('totalAllTime', [SELECT COUNT() FROM Zeffy_Webhook_Log__c]);

        return stats;
    }

    // ─── Robot Health: paginated log rows for Settings → Robot Health ─────────

    public class WebhookLogRow {
        @AuraEnabled public String  id;
        @AuraEnabled public String  name;
        @AuraEnabled public String  status;
        @AuraEnabled public String  occurredAt;
        @AuraEnabled public String  transactionId;
        @AuraEnabled public String  donorName;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public String  message;
        @AuraEnabled public String  detail;
        @AuraEnabled public Boolean hasPayload;
    }

    @AuraEnabled(cacheable=false)
    public static List<WebhookLogRow> getWebhookLogs(String statusFilter, String searchTerm, Integer maxRows) {
        requireZeffyAccess();
        Integer lim = (maxRows != null && maxRows > 0 && maxRows <= 2000) ? maxRows : 200;

        String soql = 'SELECT Id, Name, Status__c, Occurred_At__c, Transaction_Id__c, ' +
                      '       Donor_Name__c, Amount__c, Message__c, Detail__c, Has_Raw_Payload__c ' +
                      'FROM Zeffy_Webhook_Log__c ';

        List<String> wheres = new List<String>();
        if (String.isNotBlank(statusFilter) && statusFilter != 'All') {
            wheres.add('Status__c = \'' + String.escapeSingleQuotes(statusFilter) + '\'');
        }
        if (String.isNotBlank(searchTerm)) {
            String q = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
            // Message__c is LongTextArea — not filterable in SOQL
            wheres.add('(Transaction_Id__c LIKE \'' + q + '\' OR Donor_Name__c LIKE \'' + q + '\')');
        }
        if (!wheres.isEmpty()) {
            soql += 'WHERE ' + String.join(wheres, ' AND ') + ' ';
        }
        soql += 'ORDER BY Occurred_At__c DESC LIMIT ' + lim;

        List<WebhookLogRow> result = new List<WebhookLogRow>();
        for (Zeffy_Webhook_Log__c log : Database.query(soql)) {
            WebhookLogRow row = new WebhookLogRow();
            row.id            = log.Id;
            row.name          = log.Name;
            row.status        = log.Status__c;
            row.occurredAt    = log.Occurred_At__c != null ? String.valueOf(log.Occurred_At__c) : null;
            row.transactionId = log.Transaction_Id__c;
            row.donorName     = log.Donor_Name__c;
            row.amount        = log.Amount__c;
            row.message       = log.Message__c;
            row.detail        = log.Detail__c;
            row.hasPayload    = log.Has_Raw_Payload__c == true;
            result.add(row);
        }
        return result;
    }

    // ─── LWC: Reassign Zeffy ID — move everything of ONE Zeffy ID from account A to account B ──
    //
    // Used when a Zeffy ID was linked to the wrong account (by staff, so the robot kept sending
    // payments there). Scope = the gifts of the resolved tickets with that Zeffy ID on account A.
    // NPC does not allow changing the donor of a Paid / Fully Refunded gift, so every gift is
    // rebuilt on B (all createable fields, soft credits and designations) and the old one deleted.
    // The Zeffy ID moves first so new payments already go to B. Work runs in chunks of 200, one
    // savepoint per chunk: a failed chunk is rolled back and logged, and running it again continues
    // with what is left. A has no trace left except the Audit Log.

    @TestVisible private static Integer reassignChunkSize = 200;
    @TestVisible private static Boolean failReassignChunk = false;
    @TestVisible private static Integer reassignJobsEnqueued = 0;

    @AuraEnabled
    public static Map<String, Object> getReassignPreview(Id ticketId) {
        requireZeffyAccess();
        return new GiftAccess().reassignPreview(ticketId);
    }
    private static Map<String, Object> getReassignPreviewImpl(Id ticketId) {
        Zeffy_Review_Ticket__c t = [
            SELECT Id, Name, Status__c, Zeffy_Contact_Id__c, Resolved_Account__c, Resolved_Account__r.Name,
                   Email__c, Address__c, City__c, Province__c, Postal_Code__c
            FROM Zeffy_Review_Ticket__c WHERE Id = :ticketId LIMIT 1
        ];
        if (String.isBlank(t.Zeffy_Contact_Id__c) || t.Resolved_Account__c == null) {
            throw new AuraHandledException('This ticket has no Zeffy ID linked to an account.');
        }
        String zid  = t.Zeffy_Contact_Id__c;
        Id fromId   = t.Resolved_Account__c;

        List<Zeffy_Review_Ticket__c> scope = reassignScope(zid, fromId, null, 50000);
        Set<Id> giftIds = new Set<Id>();
        Set<String> subIds = new Set<String>();
        for (Zeffy_Review_Ticket__c s : scope) {
            if (s.Resolved_Gift__c != null) giftIds.add(s.Resolved_Gift__c);
            if (String.isNotBlank(s.Zeffy_Subscription_Id__c)) subIds.add(s.Zeffy_Subscription_Id__c);
        }
        Set<Id> blocked = blockedGiftIds(giftIds, fromId);
        Decimal total = 0;
        Integer refunds = 0;
        Integer gifts = 0;
        for (Gift_Transaction__c g : [
            SELECT Id, Amount__c, Status__c, Refunded_Amount__c FROM Gift_Transaction__c
            WHERE Id IN :giftIds AND Donor_Account__c = :fromId
        ]) {
            if (blocked.contains(g.Id)) continue;
            gifts++;
            total += g.Amount__c != null ? g.Amount__c : 0;
            if (g.Status__c == 'Refunded' || (g.Refunded_Amount__c != null && g.Refunded_Amount__c > 0)) refunds++;
        }
        Integer recurring = subIds.isEmpty() ? 0 : [
            SELECT COUNT() FROM Gift_Commitment__c WHERE Donor_Account__c = :fromId AND Zeffy_Subscription_Id__c IN :subIds
        ];

        // What stays on A: its other Zeffy IDs and the gifts entered by hand
        List<Map<String, Object>> otherIds = new List<Map<String, Object>>();
        List<Zeffy_Identity__c> others = [
            SELECT Zeffy_Contact_Id__c FROM Zeffy_Identity__c
            WHERE Account__c = :fromId AND Zeffy_Contact_Id__c != :zid ORDER BY Is_Primary__c DESC, First_Seen__c ASC
        ];
        Map<String, Integer> giftsPerId = new Map<String, Integer>();
        if (!others.isEmpty()) {
            Set<String> otherZids = new Set<String>();
            for (Zeffy_Identity__c zi : others) otherZids.add(zi.Zeffy_Contact_Id__c);
            for (AggregateResult ar : [
                SELECT Zeffy_Contact_Id__c zid, COUNT(Id) n FROM Zeffy_Review_Ticket__c
                WHERE Resolved_Account__c = :fromId AND Zeffy_Contact_Id__c IN :otherZids AND Resolved_Gift__c != null
                GROUP BY Zeffy_Contact_Id__c
            ]) giftsPerId.put((String) ar.get('zid'), (Integer) ar.get('n'));
        }
        for (Zeffy_Identity__c zi : others) {
            Integer n = giftsPerId.get(zi.Zeffy_Contact_Id__c);
            otherIds.add(new Map<String, Object>{ 'zeffyId' => zi.Zeffy_Contact_Id__c, 'gifts' => n == null ? 0 : n });
        }
        Integer manualGifts = [
            SELECT COUNT() FROM Gift_Transaction__c WHERE Donor_Account__c = :fromId AND Zeffy_Transaction_Id__c = null
        ];

        return new Map<String, Object>{
            'ticketId'       => t.Id,
            'zeffyId'        => zid,
            'fromAccountId'  => fromId,
            'fromAccount'    => describeAccount(fromId, t),
            'giftCount'      => gifts,
            'giftTotal'      => total,
            'recurringCount' => recurring,
            'ticketCount'    => scope.size(),
            'refundCount'    => refunds,
            'blockedCount'   => blocked.size(),
            'otherIds'       => otherIds,
            'manualGifts'    => manualGifts
        };
    }

    // Account picker of the Reassign wizard: same donor types as the resolve wizard, plus
    // whether the Zeffy payment's email / address match each account.
    @AuraEnabled
    public static List<Map<String, Object>> searchReassignAccounts(Id ticketId, String searchTerm) {
        requireZeffyAccess();
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        if (String.isBlank(searchTerm) || searchTerm.trim().length() < 2) return result;
        Zeffy_Review_Ticket__c t = [
            SELECT Id, Email__c, Address__c, City__c, Province__c, Postal_Code__c
            FROM Zeffy_Review_Ticket__c WHERE Id = :ticketId LIMIT 1
        ];
        for (Map<String, String> a : ZeffyConnectConfigService.searchAccounts(searchTerm)) {
            result.add(describeAccount((Id) a.get('id'), t));
        }
        return result;
    }

    private static Map<String, Object> describeAccount(Id accountId, Zeffy_Review_Ticket__c t) {
        Account a = [
            SELECT Id, Name, Email_Address__c, Email_Personal__c, RecordType.DeveloperName, RecordType.Name,
                   BillingStreet, BillingCity, BillingState, BillingPostalCode,
                   (SELECT Id, FirstName, LastName, Email FROM Contacts ORDER BY CreatedDate LIMIT 5)
            FROM Account WHERE Id = :accountId LIMIT 1
        ];
        // SEMBEQ: the payment email may sit on the Account or on any of its Contacts
        Boolean emailMatch = false;
        if (String.isNotBlank(t.Email__c)) {
            String em = t.Email__c.trim();
            emailMatch = em.equalsIgnoreCase(a.Email_Address__c?.trim()) || em.equalsIgnoreCase(a.Email_Personal__c?.trim());
            for (Contact c : a.Contacts) if (em.equalsIgnoreCase(c.Email?.trim())) emailMatch = true;
        }
        Boolean hasZeffyAddress = String.isNotBlank(t.Address__c) || String.isNotBlank(t.City__c) || String.isNotBlank(t.Postal_Code__c);
        Boolean addressMatch = hasZeffyAddress && !addressDiffers(t, a);
        return new Map<String, Object>{
            'id'           => a.Id,
            'name'         => accountDisplayName(a),
            'email'        => accountEmail(a),
            'kind'         => isPersonAccount(a) ? 'Person' : (a.RecordType == null ? null : a.RecordType.Name),
            'city'         => a.BillingCity,
            'address'      => buildAddressString(a.BillingStreet, a.BillingCity, a.BillingState, a.BillingPostalCode),
            'zeffyIds'     => [SELECT COUNT() FROM Zeffy_Identity__c WHERE Account__c = :a.Id],
            'emailMatch'   => emailMatch,
            'addressMatch' => addressMatch
        };
    }

    // Starts the move. The Zeffy ID and the first chunk run now (one savepoint: on failure nothing
    // changes and staff sees the error); the rest continues in a Queueable chain.
    @AuraEnabled
    public static Map<String, Object> reassignZeffyId(Id ticketId, Id targetAccountId) {
        requireZeffyAccess();
        return new GiftAccess().reassign(ticketId, targetAccountId);
    }
    private static Map<String, Object> reassignZeffyIdImpl(Id ticketId, Id targetAccountId) {
        Zeffy_Review_Ticket__c t = [
            SELECT Id, Zeffy_Contact_Id__c, Resolved_Account__c, Email__c
            FROM Zeffy_Review_Ticket__c WHERE Id = :ticketId LIMIT 1
        ];
        if (String.isBlank(t.Zeffy_Contact_Id__c) || t.Resolved_Account__c == null) {
            throw new AuraHandledException('This ticket has no Zeffy ID linked to an account.');
        }
        if (targetAccountId == null || targetAccountId == t.Resolved_Account__c) {
            throw new AuraHandledException('Choose an account different from the current one.');
        }
        String zid = t.Zeffy_Contact_Id__c;
        Id fromId  = t.Resolved_Account__c;

        Long startedAt = DateTime.now().getTime();
        Savepoint sp = Database.setSavepoint();
        Map<String, Object> res;
        try {
            moveIdentity(zid, fromId, targetAccountId, t.Email__c);
            res = runReassignChunk(ticketId, zid, fromId, targetAccountId);
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException('Nothing was moved: ' + e.getMessage());
        }
        if ((Integer) res.get('remaining') > 0) enqueueReassign(ticketId, zid, fromId, targetAccountId);
        res.put('startedAt', startedAt);
        return res;
    }

    // Polled by the wizard: how many tickets are still on A, and whether the job finished or failed.
    @AuraEnabled
    public static Map<String, Object> getReassignProgress(Id ticketId, Id fromAccountId, Long sinceMillis) {
        requireZeffyAccess();
        Zeffy_Review_Ticket__c t = [SELECT Zeffy_Contact_Id__c FROM Zeffy_Review_Ticket__c WHERE Id = :ticketId LIMIT 1];
        Integer remaining = countReassignRemaining(t.Zeffy_Contact_Id__c, fromAccountId);
        DateTime since = sinceMillis == null ? DateTime.now().addHours(-1) : DateTime.newInstance(sinceMillis).addSeconds(-5);
        String status = remaining == 0 ? 'done' : 'running';
        String error;
        for (Zeffy_Connect_Audit_Log__c l : [
            SELECT Action__c, Notes__c FROM Zeffy_Connect_Audit_Log__c
            WHERE Ticket__c = :ticketId AND Performed_At__c >= :since
              AND Action__c IN ('Zeffy ID Reassigned', 'Reassign Failed')
            ORDER BY Performed_At__c DESC LIMIT 1
        ]) {
            if (l.Action__c == 'Reassign Failed') { status = 'failed'; error = l.Notes__c; }
            else status = 'done';
        }
        Map<String, Object> res = new Map<String, Object>{ 'remaining' => remaining, 'status' => status, 'error' => error };
        if (status == 'done') {
            // What the wizard shows at the end: the newest rows of this move and how many there are
            String[] actions = new String[]{ 'Zeffy ID Reassigned', 'Gift Moved', 'Recurring Moved' };
            List<Map<String, String>> logs = new List<Map<String, String>>();
            for (Zeffy_Connect_Audit_Log__c l : [
                SELECT Action__c, Notes__c, Performed_By__r.Name FROM Zeffy_Connect_Audit_Log__c
                WHERE Ticket__c = :ticketId AND Performed_At__c >= :since AND Action__c IN :actions
                ORDER BY Performed_At__c DESC, Name DESC LIMIT 5
            ]) {
                logs.add(new Map<String, String>{ 'action' => l.Action__c, 'notes' => l.Notes__c,
                    'by' => l.Performed_By__r == null ? null : l.Performed_By__r.Name });
            }
            res.put('logs', logs);
            res.put('logCount', [
                SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c
                WHERE Ticket__c = :ticketId AND Performed_At__c >= :since AND Action__c IN :actions
            ]);
        }
        return res;
    }

    // ─── Gifts owned by other users ──────────────────────────────────────────
    // Gift_Transaction__c/Gift_Commitment__c are Private: staff only sees its own gifts. Undo, Reassign and
    // the recurring-commitment lookup must reach every gift of the donor, so they run without
    // sharing — Undo and Reassign only after requireZeffyAccess() (the webhook guest has no PS).
    // Inner classes don't inherit sharing; the inherited-sharing Impl methods run in this mode.
    private without sharing class GiftAccess {
        Map<String, String> undo(Id ticketId) { return undoResolutionImpl(ticketId); }
        Map<String, Object> reassignPreview(Id ticketId) { return getReassignPreviewImpl(ticketId); }
        Map<String, Object> reassign(Id ticketId, Id toId) { return reassignZeffyIdImpl(ticketId, toId); }
        Map<String, Object> reassignChunk(Id ticketId, String zid, Id fromId, Id toId) {
            return runReassignChunk(ticketId, zid, fromId, toId);
        }
        List<Gift_Commitment__c> commitmentsBySubscription(String subId) {
            return [SELECT Id, Status__c, Start_Date__c, Next_Payment_Date__c FROM Gift_Commitment__c
                    WHERE Zeffy_Subscription_Id__c = :subId LIMIT 1];
        }
        void updateCommitment(Gift_Commitment__c c) { update c; }
        void insertGift(Gift_Transaction__c gt) { insert gt; }
        List<Gift_Transaction__c> giftsByTransactionIds(Set<String> txIds) {
            return [SELECT Zeffy_Transaction_Id__c FROM Gift_Transaction__c WHERE Zeffy_Transaction_Id__c IN :txIds];
        }
        void markReviewed(Id ticketId) { markAmountReviewedImpl(ticketId); }
        Zeffy_Review_Ticket__c ticketDetail(Id ticketId) { return getTicketDetailImpl(ticketId); }
        Map<String, Object> dashboardStats() { return getDashboardStatsImpl(); }
        List<DonationHistoryRow> donationHistory(String searchTerm) { return getDonationHistoryImpl(searchTerm); }
        Map<String, String> reprocess(Id logId) { return reprocessWebhookLogImpl(logId); }
    }

    // Zeffy Connect users only (either permission set), or admins (Modify All Data)
    // Zeffy_Connect_Admin_Access is an add-on ("never on its own"), so it does not count here.
    // Cached per user: bulk paths call guarded methods many times in one transaction.
    private static Map<Id, Boolean> zeffyAccessByUser = new Map<Id, Boolean>();
    private static void requireZeffyAccess() {
        Id uid = UserInfo.getUserId();
        if (!zeffyAccessByUser.containsKey(uid)) {
            Integer n = [
                SELECT COUNT() FROM PermissionSetAssignment
                WHERE AssigneeId = :uid
                  AND (PermissionSet.Name = 'Zeffy_Connect_Access'
                       OR PermissionSet.PermissionsModifyAllData = true)
            ];
            zeffyAccessByUser.put(uid, n > 0);
        }
        if (!zeffyAccessByUser.get(uid)) throw new AuraHandledException('You need Zeffy Connect access to do this.');
    }

    // Resolving twice (two tabs, stale page) would create a second gift for the same payment
    private static void requirePendingReview(Zeffy_Review_Ticket__c t) {
        if (t.Status__c != 'Pending Review') {
            throw new AuraHandledException('This ticket is no longer pending review (current: ' + t.Status__c
                + '). Refresh the page.');
        }
    }

    public inherited sharing class ReassignJob implements Queueable {
        private Id ticketId; private String zid; private Id fromId; private Id toId;
        public ReassignJob(Id ticketId, String zid, Id fromId, Id toId) {
            this.ticketId = ticketId; this.zid = zid; this.fromId = fromId; this.toId = toId;
        }
        public void execute(QueueableContext ctx) {
            // Limit errors cannot be caught: the finalizer still records the failure for the wizard
            System.attachFinalizer(new ReassignFinalizer(ticketId, zid, fromId));
            Savepoint sp = Database.setSavepoint();
            Map<String, Object> res;
            try {
                res = new GiftAccess().reassignChunk(ticketId, zid, fromId, toId);
            } catch (Exception e) {
                Database.rollback(sp);
                createAuditLog(ticketId, 'Reassign Failed', fromId,
                    'Zeffy ID ' + zid + ': a batch failed and was rolled back, nothing of it moved. '
                    + 'Open Reassign again to continue. Error: ' + e.getMessage());
                return;
            }
            if ((Integer) res.get('remaining') > 0) enqueueReassign(ticketId, zid, fromId, toId);
        }
    }

    public inherited sharing class ReassignFinalizer implements Finalizer {
        private Id ticketId; private String zid; private Id fromId;
        public ReassignFinalizer(Id ticketId, String zid, Id fromId) {
            this.ticketId = ticketId; this.zid = zid; this.fromId = fromId;
        }
        public void execute(FinalizerContext ctx) {
            logReassignStopped(ticketId, zid, fromId, ctx.getResult(), ctx.getException());
        }
    }
    // A queued batch that died on an uncatchable error (limits): leave a row the wizard can show
    @TestVisible
    private static void logReassignStopped(Id ticketId, String zid, Id fromId, ParentJobResult result, Exception e) {
        if (result != ParentJobResult.UNHANDLED_EXCEPTION) return;
        createAuditLog(ticketId, 'Reassign Failed', fromId,
            'Zeffy ID ' + zid + ': a batch stopped (' + (e != null ? e.getMessage() : 'unknown error')
            + ') and was rolled back. Open Reassign again to continue.');
    }

    private static void enqueueReassign(Id ticketId, String zid, Id fromId, Id toId) {
        reassignJobsEnqueued++;
        // A Queueable cannot chain another one inside a test
        if (Test.isRunningTest() && System.isQueueable()) return;
        System.enqueueJob(new ReassignJob(ticketId, zid, fromId, toId));
    }

    // Moves the Zeffy_Identity__c to B (created when missing) and keeps one primary ID per account.
    // Safe to run again after a failed batch: the identity may already be on B.
    private static void moveIdentity(String zid, Id fromId, Id toId, String email) {
        List<Zeffy_Identity__c> zis = [
            SELECT Id, Account__c FROM Zeffy_Identity__c WHERE Zeffy_Contact_Id__c = :zid LIMIT 1
        ];
        Boolean toHasPrimary = [SELECT COUNT() FROM Zeffy_Identity__c
                                WHERE Account__c = :toId AND Is_Primary__c = true
                                  AND Zeffy_Contact_Id__c != :zid] > 0;
        if (zis.isEmpty()) {
            insert new Zeffy_Identity__c(Account__c = toId, Zeffy_Contact_Id__c = zid, Email__c = email,
                Is_Primary__c = !toHasPrimary, First_Seen__c = Date.today(), Source__c = 'Manual');
        } else if (zis[0].Account__c != toId) {
            update new Zeffy_Identity__c(Id = zis[0].Id, Account__c = toId, Is_Primary__c = !toHasPrimary);
        }
        ensurePrimaryIdentity(fromId);
        ensurePrimaryIdentity(toId);
    }

    // An account with Zeffy IDs always has exactly one primary: the oldest one when none is marked.
    private static void ensurePrimaryIdentity(Id accountId) {
        List<Zeffy_Identity__c> ids = [
            SELECT Id, Is_Primary__c FROM Zeffy_Identity__c WHERE Account__c = :accountId
            ORDER BY First_Seen__c ASC NULLS LAST, CreatedDate ASC
        ];
        if (ids.isEmpty()) return;
        for (Zeffy_Identity__c z : ids) { if (z.Is_Primary__c) return; }
        update new Zeffy_Identity__c(Id = ids[0].Id, Is_Primary__c = true);
    }

    // Resolved tickets of this Zeffy ID still on A. The ticket staff opened goes last so that, if a
    // batch fails, Reassign can be opened again from the same ticket (it is still on A).
    private static List<Zeffy_Review_Ticket__c> reassignScope(String zid, Id fromId, Id lastTicketId, Integer lim) {
        List<Zeffy_Review_Ticket__c> scope = [
            SELECT Id, Name, Resolved_Gift__c, Zeffy_Subscription_Id__c
            FROM Zeffy_Review_Ticket__c
            WHERE Zeffy_Contact_Id__c = :zid AND Resolved_Account__c = :fromId
              AND (Status__c LIKE 'Resolved%' OR Status__c = 'Auto-Processed')
              AND Id != :lastTicketId
            ORDER BY Gift_Date__c ASC NULLS LAST, Id
            LIMIT :lim
        ];
        if (lastTicketId != null && scope.size() < lim) {
            scope.addAll([
                SELECT Id, Name, Resolved_Gift__c, Zeffy_Subscription_Id__c
                FROM Zeffy_Review_Ticket__c
                WHERE Id = :lastTicketId AND Zeffy_Contact_Id__c = :zid AND Resolved_Account__c = :fromId
                  AND (Status__c LIKE 'Resolved%' OR Status__c = 'Auto-Processed')
            ]);
        }
        return scope;
    }

    private static Integer countReassignRemaining(String zid, Id fromId) {
        List<Zeffy_Review_Ticket__c> scope = reassignScope(zid, fromId, null, 50000);
        Set<Id> giftIds = new Set<Id>();
        for (Zeffy_Review_Ticket__c s : scope) if (s.Resolved_Gift__c != null) giftIds.add(s.Resolved_Gift__c);
        Set<Id> blocked = blockedGiftIds(giftIds, fromId);
        Integer n = 0;
        for (Zeffy_Review_Ticket__c s : scope) if (!blocked.contains(s.Resolved_Gift__c)) n++;
        return n;
    }

    // SEMBEQ: Gift_Transaction__c.Donor_Account__c is an editable lookup, so gifts move in place
    // (refunds, soft credits and splits stay attached). Only a gift already on another account
    // (moved by hand) stays where it is.
    @TestVisible private static Set<Id> forcedBlockedGifts = new Set<Id>();
    @TestVisible
    private static Set<Id> blockedGiftIds(Set<Id> giftIds, Id fromId) {
        Set<Id> blocked = new Set<Id>();
        if (giftIds.isEmpty()) return blocked;
        for (Id g : forcedBlockedGifts) if (giftIds.contains(g)) blocked.add(g);
        for (Gift_Transaction__c g : [SELECT Id FROM Gift_Transaction__c
                                      WHERE Id IN :giftIds AND Donor_Account__c != :fromId]) {
            blocked.add(g.Id);
        }
        return blocked;
    }

    // One chunk: moves up to reassignChunkSize gifts to B (Donor_Account__c + its donor Contact) with
    // their tickets and recurring donations. Writes the summary Audit Log row when nothing is left.
    private static Map<String, Object> runReassignChunk(Id originTicketId, String zid, Id fromId, Id toId) {
        if (failReassignChunk) throw new ForcedTestException('Forced reassign chunk failure');
        List<Zeffy_Review_Ticket__c> candidates = reassignScope(zid, fromId, originTicketId, 50000);
        Set<Id> allGiftIds = new Set<Id>();
        for (Zeffy_Review_Ticket__c s : candidates) if (s.Resolved_Gift__c != null) allGiftIds.add(s.Resolved_Gift__c);
        Set<Id> blocked = blockedGiftIds(allGiftIds, fromId);
        List<Zeffy_Review_Ticket__c> scope = new List<Zeffy_Review_Ticket__c>();
        Integer movable = 0;
        for (Zeffy_Review_Ticket__c s : candidates) {
            if (blocked.contains(s.Resolved_Gift__c)) continue;
            movable++;
            if (scope.size() < reassignChunkSize) scope.add(s);
        }

        Set<Id> giftIds = new Set<Id>();
        Set<String> subIds = new Set<String>();
        for (Zeffy_Review_Ticket__c s : scope) {
            if (s.Resolved_Gift__c != null) giftIds.add(s.Resolved_Gift__c);
            if (String.isNotBlank(s.Zeffy_Subscription_Id__c)) subIds.add(s.Zeffy_Subscription_Id__c);
        }
        List<Zeffy_Connect_Audit_Log__c> logs = new List<Zeffy_Connect_Audit_Log__c>();
        // Person → the Contact of B gets the credit; church/organization → no Contact
        String toEmail = [SELECT Email__c FROM Zeffy_Review_Ticket__c WHERE Id = :originTicketId LIMIT 1].Email__c;
        Id toContactId = resolveDonorContactId(toId, toEmail);

        if (!giftIds.isEmpty()) {
            List<Gift_Transaction__c> gifts = [
                SELECT Id, Name FROM Gift_Transaction__c WHERE Id IN :giftIds AND Donor_Account__c = :fromId
            ];
            for (Gift_Transaction__c g : gifts) {
                g.Donor_Account__c = toId;
                g.Donor__c         = toContactId;
                logs.add(reassignLog(originTicketId, 'Gift Moved', toId, g.Name + ': ' + g.Id));
            }
            update gifts;
        }

        if (!subIds.isEmpty()) {
            List<Gift_Commitment__c> cmts = [
                SELECT Id, Name FROM Gift_Commitment__c WHERE Donor_Account__c = :fromId AND Zeffy_Subscription_Id__c IN :subIds
            ];
            for (Gift_Commitment__c c : cmts) {
                c.Donor_Account__c = toId;
                c.Donor__c         = toContactId;
                logs.add(reassignLog(originTicketId, 'Recurring Moved', toId, c.Name + ': ' + c.Id));
            }
            update cmts;
        }

        Set<Id> movedTickets = new Set<Id>();
        for (Zeffy_Review_Ticket__c s : scope) {
            s.Resolved_Account__c = toId;
            movedTickets.add(s.Id);
        }
        update scope;
        refreshAddressFlags(movedTickets);

        Integer remaining = movable - scope.size();
        if (remaining == 0) {
            Map<Id, Account> names = new Map<Id, Account>(queryAccountsWithContacts(new Set<Id>{ fromId, toId }));
            String notes = 'Zeffy ID ' + zid + ': ' + accountDisplayName(names.get(fromId))
                + ' → ' + accountDisplayName(names.get(toId)) + '.';
            if (!blocked.isEmpty()) {
                notes += ' ' + blocked.size() + ' gift(s) stayed where they are (already on another account) '
                    + 'and must be moved by hand.';
            }
            logs.add(reassignLog(originTicketId, 'Zeffy ID Reassigned', toId, notes));
        }
        insertAuditLogs(logs);
        return new Map<String, Object>{
            'moved'     => scope.size(),
            'remaining' => remaining,
            'blocked'   => blocked.size()
        };
    }

    private static Zeffy_Connect_Audit_Log__c reassignLog(Id ticketId, String action, Id accountId, String notes) {
        return new Zeffy_Connect_Audit_Log__c(Ticket__c = ticketId, Action__c = action,
            Performed_By__c = UserInfo.getUserId(), Performed_At__c = DateTime.now(),
            Account__c = accountId, Notes__c = notes);
    }

    private static void insertAuditLogs(List<Zeffy_Connect_Audit_Log__c> logs) {
        if (logs.isEmpty()) return;
        try {
            if (failAuditLog) throw new System.SObjectException('Forced audit log failure');
            insert logs;
        } catch (Exception e) {
            System.debug('insertAuditLogs failed (non-critical): ' + e.getMessage());
        }
    }
}
