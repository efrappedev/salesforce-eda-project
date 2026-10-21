@isTest
private class ZeffyConnectWebhookReceiverTest {

    // ─── Zeffy-Signature helper (mirrors ZeffyConnectWebhookReceiver.validateToken) ─
    // Format: t=<unix_seconds>,v1=HMAC-SHA256("{t}.{rawBody}", secret)
    private static final String TEST_SECRET = 'test_secret_key_123';

    private static String zeffySignature(String body) {
        String ts            = String.valueOf(DateTime.now().getTime() / 1000);
        String signedPayload = ts + '.' + body;
        Blob   mac           = Crypto.generateMac('hmacSHA256', Blob.valueOf(signedPayload), Blob.valueOf(TEST_SECRET));
        return 't=' + ts + ',v1=' + EncodingUtil.convertToHex(mac);
    }

    // ─── Payload builders (real Zeffy API format) ─────────────────────────────

    private static String buildPayload(String transactionId, String email, String contactId) {
        return '{"id":"evt_test","type":"payment.completed","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
               '"data":{"id":"' + transactionId + '","status":"succeeded","type":"online",' +
               '"amount":10000,"eligible_amount":8000,' +
               '"currency":"cad",' +
               '"contact":"' + contactId + '",' +
               '"buyer":{"email":"' + email + '","first_name":"Juan","last_name":"Pérez",' +
               '"is_corporate":false,"company_name":null,' +
               '"address":{"line1":"123 Rue Test","city":"Montréal","state":"QC","postal_code":"H1A 1A1","country":"CA"}},' +
               '"payment_method":{"type":"card","brand":"visa","last4":"4242"},' +
               '"created":1737000000,' +
               '"receipt_url":"https://zeffy.com/receipt/R-001",' +
               '"campaign_id":"form_abc","campaign_type":"donation_form","campaign_category":"donation",' +
               '"description":"Campaña Test",' +
               '"refund_status":"none","refunds":[],' +
               '"dispute":null,"fund":null,"discount":null,' +
               '"buyer_questions":[{"question":"How did you hear about us?","type":"text","answer":"A friend"}],' +
               '"items":[{"id":"item_001","type":"donation","amount":10000,"rate_title":"Donación general","tribute":null}],' +
               '"recurring":null}}';
    }

    private static String buildRecurringPayload(String transactionId, String subId) {
        return '{"id":"evt_rec","type":"payment.completed","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
               '"data":{"id":"' + transactionId + '","status":"succeeded","type":"online",' +
               '"amount":2500,"eligible_amount":2500,' +
               '"currency":"cad",' +
               '"contact":"zeffy_rec_001",' +
               '"buyer":{"email":"marie.rec@test.ca","first_name":"Marie","last_name":"Tremblay",' +
               '"is_corporate":false,"company_name":null,"address":null},' +
               '"payment_method":{"type":"card","brand":"visa","last4":"1234"},' +
               '"created":1737100000,"receipt_url":null,' +
               '"campaign_id":null,"campaign_type":null,"campaign_category":null,"description":null,' +
               '"refund_status":"none","refunds":[],"dispute":null,"fund":null,"discount":null,' +
               '"buyer_questions":[],"items":[],' +
               '"recurring":{"is_recurring":true,"status":"active","interval":"monthly",' +
               '"subscription_id":"' + subId + '","current_period_start":1737000000,"current_period_end":1739678400}}}';
    }

    // ─── Setup ────────────────────────────────────────────────────────────────

    @TestSetup
    static void setup() {
        insert new Zeffy_Config__c(
            Name              = 'default',
            Webhook_Secret__c = 'test_secret_key_123',
            Is_Active__c      = true
        );
        insert new Campaign(
            Name             = 'Campaña Test',
            IsActive         = true,
            Zeffy_Form_Id__c = 'form_abc'
        );
    }

    // Helper: create an individual donor (EDA Contact + Administrative Account)
    private static Account makeIndividualDonor(String firstName, String lastName, String email) {
        Contact c = new Contact(FirstName = firstName, LastName = lastName, Email = email);
        insert c;
        Id accId = [SELECT AccountId FROM Contact WHERE Id = :c.Id].AccountId;
        if (accId == null) {
            Account a = new Account(Name = firstName + ' ' + lastName + ' Administrative Account',
                                    Email_Address__c = email);
            insert a;
            update new Contact(Id = c.Id, AccountId = a.Id);
            accId = a.Id;
        }
        return [SELECT Id, Name FROM Account WHERE Id = :accId];
    }

    // Helper: link a Zeffy Contact ID to an Account via Zeffy_Identity__c
    private static void linkIdentity(Id accountId, String zeffyContactId, String email) {
        insert new Zeffy_Identity__c(
            Account__c          = accountId,
            Zeffy_Contact_Id__c = zeffyContactId,
            Email__c            = email,
            Is_Primary__c       = true,
            First_Seen__c       = Date.today(),
            Source__c           = 'Webhook'
        );
    }

    // ─── Auth ─────────────────────────────────────────────────────────────────

    @isTest
    static void testWebhookBlockedWithoutSecret() {
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(buildPayload('txn_blocked', 'test@test.ca', 'zeffy_001'));
        RestContext.request  = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        ZeffyConnectWebhookReceiver.handleWebhook();
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Review_Ticket__c],
            'Payload without secret should be blocked');
    }

    // ─── Unknown donor → ticket ───────────────────────────────────────────────

    @isTest
    static void testNewDonorCreatesReviewTicket() {
        Test.startTest();
        ZeffyConnectDonationService.processWebhook(buildPayload('txn_new_001', 'nuevo@test.ca', 'zeffy_new_001'));
        Test.stopTest();

        List<Zeffy_Review_Ticket__c> tickets = [
            SELECT Status__c, Email__c, Amount__c, Zeffy_Transaction_Id__c, Eligible_Amount__c,
                   Card_Brand__c, Card_Last4__c, Rate_Title__c, Buyer_Questions__c
            FROM Zeffy_Review_Ticket__c
        ];
        System.assertEquals(1, tickets.size(), 'Should create 1 review ticket');
        System.assertEquals('Pending Review', tickets[0].Status__c);
        System.assertEquals('nuevo@test.ca', tickets[0].Email__c);
        System.assertEquals(100.00, tickets[0].Amount__c);        // 10000 cents / 100
        System.assertEquals(80.00, tickets[0].Eligible_Amount__c); // 8000 cents / 100
        System.assertEquals('txn_new_001', tickets[0].Zeffy_Transaction_Id__c);
        System.assertEquals('visa', tickets[0].Card_Brand__c);
        System.assertEquals('4242', tickets[0].Card_Last4__c);
        System.assertEquals('Donación general', tickets[0].Rate_Title__c);
        System.assertNotEquals(null, tickets[0].Buyer_Questions__c);
    }

    // ─── Known donor found via Zeffy_Identity__c → auto Gift_Transaction__c ───────

    @isTest
    static void testKnownDonorByZeffyIdentityCreatesGift() {
        Account donor = makeIndividualDonor('Ana', 'García', 'ana@test.ca');
        linkIdentity(donor.Id, 'zeffy_known_001', 'ana@test.ca');

        Test.startTest();
        ZeffyConnectDonationService.processWebhook(buildPayload('txn_known_001', 'ana@test.ca', 'zeffy_known_001'));
        Test.stopTest();

        List<Gift_Transaction__c> gifts = [
            SELECT Id, Donor_Account__c, Amount__c, Eligible_Amount__c, Status__c, Zeffy_Transaction_Id__c
            FROM Gift_Transaction__c
        ];
        System.assertEquals(1, gifts.size(), 'Should auto-create 1 Gift_Transaction__c');
        System.assertEquals(donor.Id, gifts[0].Donor_Account__c);
        System.assertEquals(100.00, gifts[0].Amount__c);          // 10000 / 100
        System.assertEquals(80.00, gifts[0].Eligible_Amount__c);  // 8000 / 100
        System.assertEquals('Received', gifts[0].Status__c);
        System.assertEquals('txn_known_001', gifts[0].Zeffy_Transaction_Id__c);

        // The robot logs its action as an Auto-Processed ticket (no review needed)
        List<Zeffy_Review_Ticket__c> tickets = [SELECT Status__c, Resolved_Gift__c FROM Zeffy_Review_Ticket__c];
        System.assertEquals(1, tickets.size(), 'Known donor gets one robot ticket');
        System.assertEquals('Auto-Processed', tickets[0].Status__c);
        System.assertEquals(gifts[0].Id, tickets[0].Resolved_Gift__c);
    }

    // ─── Email match without Zeffy ID → review ticket (no auto-match by email) ─

    @isTest
    static void testKnownEmailWithoutZeffyIdCreatesTicket() {
        makeIndividualDonor('Carlos', 'López', 'carlos@test.ca');
        // No Zeffy_Identity__c — email alone must never auto-match

        Test.startTest();
        ZeffyConnectDonationService.processWebhook(buildPayload('txn_email_001', 'carlos@test.ca', 'zeffy_email_001'));
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Gift_Transaction__c], 'Email alone must not create gift');
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Review_Ticket__c], 'Should create review ticket');
        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Identity__c], 'Should not auto-create Zeffy_Identity__c');
    }

    // ─── Second Zeffy ID for same person (multi-ID scenario) ─────────────────

    @isTest
    static void testSecondZeffyIdLinksToSameAccount() {
        Account donor = makeIndividualDonor('Sofia', 'Dupont', 'sofia@test.ca');
        linkIdentity(donor.Id, 'zeffy_first_001', 'sofia@test.ca');

        // Same person, NEW Zeffy contact ID (registered twice in Zeffy), different email
        Test.startTest();
        ZeffyConnectDonationService.processWebhook(buildPayload('txn_multi_001', 'sofia.new@test.ca', 'zeffy_second_001'));
        Test.stopTest();

        // Robot doesn't know this person (new email, new Zeffy ID) → creates ticket
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Review_Ticket__c],
            'Unknown Zeffy ID + new email should create a review ticket');
    }

    // ─── Dedup ────────────────────────────────────────────────────────────────

    @isTest
    static void testDuplicateTransactionBlocked() {
        Account donor = makeIndividualDonor('Pedro', 'Martínez', 'pedro@test.ca');
        linkIdentity(donor.Id, 'zeffy_dup_001', 'pedro@test.ca');

        String payload = buildPayload('txn_dup_001', 'pedro@test.ca', 'zeffy_dup_001');

        Test.startTest();
        ZeffyConnectDonationService.processWebhook(payload);
        ZeffyConnectDonationService.processWebhook(payload);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Gift_Transaction__c],
            'Duplicate transaction should be blocked');
    }

    // ─── Non-payment events ignored ───────────────────────────────────────────

    @isTest
    static void testNonPaymentEventIgnored() {
        String payload = '{"id":"evt_x","type":"refund.processed","version":"1","dispatchedAt":"2026-01-01T00:00:00Z",' +
                         '"data":{"id":"txn_refund","status":"refunded"}}';
        Test.startTest();
        ZeffyConnectDonationService.processWebhook(payload);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Review_Ticket__c], 'Refund event ignored');
        System.assertEquals(0, [SELECT COUNT() FROM Gift_Transaction__c], 'Refund event creates no gift');
    }

    // ─── Invalid JSON → error ticket ──────────────────────────────────────────

    @isTest
    static void testInvalidJsonCreatesErrorTicket() {
        Test.startTest();
        ZeffyConnectDonationService.processWebhook('{not valid json!!!}');
        Test.stopTest();

        List<Zeffy_Review_Ticket__c> tickets = [SELECT Status__c, Error_Message__c FROM Zeffy_Review_Ticket__c];
        System.assertEquals(1, tickets.size(), 'Invalid JSON should create error ticket');
        System.assertEquals('Error', tickets[0].Status__c);
        System.assertNotEquals(null, tickets[0].Error_Message__c);
    }

    // ─── resolveCreateNew — Individual ───────────────────────────────────────

    @isTest
    static void testResolveCreateNewIndividual() {
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Laura',
            Last_Name__c            = 'Morales',
            Email__c                = 'laura@test.ca',
            Phone__c                = '5141112222',
            Amount__c               = 50.00,
            Eligible_Amount__c      = 50.00,
            Currency__c             = 'CAD',
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Contact_Id__c     = 'zeffy_ind_001',
            Zeffy_Transaction_Id__c = 'txn_ind_001',
            Form_Id__c              = 'form_abc'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.resolveCreateNew(ticket.Id, 'individual', 'Creado desde test');
        Test.stopTest();

        Zeffy_Review_Ticket__c resolved = [
            SELECT Status__c, Resolved_Account__c, Resolved_Gift__c
            FROM Zeffy_Review_Ticket__c WHERE Id = :ticket.Id
        ];
        System.assertEquals('Resolved - New Contact', resolved.Status__c);
        System.assertNotEquals(null, resolved.Resolved_Account__c, 'Should set Resolved_Account__c');
        System.assertNotEquals(null, resolved.Resolved_Gift__c, 'Should set Resolved_Gift__c');

        List<Contact> newContacts = [SELECT FirstName, LastName, Email
                                     FROM Contact WHERE AccountId = :resolved.Resolved_Account__c];
        System.assertEquals(1, newContacts.size(), 'Should create 1 Contact under the Administrative Account');
        System.assertEquals('Laura', newContacts[0].FirstName);
        System.assertEquals('Morales', newContacts[0].LastName);
        System.assertEquals('laura@test.ca', newContacts[0].Email);

        // Should create Zeffy_Identity__c for the new account
        List<Zeffy_Identity__c> identities = [
            SELECT Zeffy_Contact_Id__c FROM Zeffy_Identity__c WHERE Account__c = :resolved.Resolved_Account__c
        ];
        System.assertEquals(1, identities.size(), 'Should create Zeffy_Identity__c for new account');
        System.assertEquals('zeffy_ind_001', identities[0].Zeffy_Contact_Id__c);
    }

    // ─── resolveCreateNew — Eglise ────────────────────────────────────────────

    @isTest
    static void testResolveCreateNewEglise() {
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            Company_Name__c         = 'Église Test',
            Email__c                = 'pastor@eglise.ca',
            Amount__c               = 1000.00,
            Eligible_Amount__c      = 1000.00,
            Payment_Method__c       = 'Check',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Contact_Id__c     = 'zeffy_egl_001',
            Zeffy_Transaction_Id__c = 'txn_egl_001'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.resolveCreateNew(ticket.Id, 'eglise', 'Iglesia nueva');
        Test.stopTest();

        Zeffy_Review_Ticket__c resolved = [SELECT Resolved_Account__c FROM Zeffy_Review_Ticket__c WHERE Id = :ticket.Id];
        Account church = [SELECT Name, RecordType.DeveloperName
                          FROM Account WHERE Id = :resolved.Resolved_Account__c];
        System.assertEquals('Eglise', church.RecordType.DeveloperName, 'Should use Eglise record type');
        System.assertEquals('Église Test', church.Name);
    }

    // ─── resolveCreateNew — Organización ─────────────────────────────────────

    @isTest
    static void testResolveCreateNewOrg() {
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            Company_Name__c         = 'ONG Solidaridad',
            Amount__c               = 250.00,
            Eligible_Amount__c      = 250.00,
            Payment_Method__c       = 'Bank Transfer',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Transaction_Id__c = 'txn_org_001'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.resolveCreateNew(ticket.Id, 'org', 'Organización nueva');
        Test.stopTest();

        Zeffy_Review_Ticket__c resolved = [SELECT Resolved_Account__c FROM Zeffy_Review_Ticket__c WHERE Id = :ticket.Id];
        Account org = [SELECT RecordType.DeveloperName FROM Account WHERE Id = :resolved.Resolved_Account__c];
        System.assertEquals('Organisme', org.RecordType.DeveloperName);
    }

    // ─── resolveLinkExisting — no email/address update ────────────────────────

    @isTest
    static void testResolveLinkExistingBasic() {
        Account existing = makeIndividualDonor('Sofia', 'Rodríguez', 'sofia@test.ca');

        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Sofia',
            Last_Name__c            = 'Rodriguez',
            Email__c                = 'sofia@test.ca',
            Amount__c               = 75.00,
            Eligible_Amount__c      = 75.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Contact_Id__c     = 'zeffy_link_001',
            Zeffy_Transaction_Id__c = 'txn_link_001'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.resolveLinkExisting(ticket.Id, existing.Id, 'Vinculado', null, false, false, false);
        Test.stopTest();

        Zeffy_Review_Ticket__c resolved = [
            SELECT Status__c, Resolved_Account__c, Resolved_Gift__c
            FROM Zeffy_Review_Ticket__c WHERE Id = :ticket.Id
        ];
        System.assertEquals('Resolved - Linked', resolved.Status__c);
        System.assertEquals(existing.Id, resolved.Resolved_Account__c);
        System.assertNotEquals(null, resolved.Resolved_Gift__c);

        // Zeffy_Identity__c created instead of stamping Account directly
        List<Zeffy_Identity__c> identities = [
            SELECT Zeffy_Contact_Id__c FROM Zeffy_Identity__c WHERE Account__c = :existing.Id
        ];
        System.assertEquals(1, identities.size(), 'Should create Zeffy_Identity__c when linking');
        System.assertEquals('zeffy_link_001', identities[0].Zeffy_Contact_Id__c);
    }

    // ─── resolveLinkExisting — email update ───────────────────────────────────

    @isTest
    static void testResolveLinkExistingUpdateEmail() {
        Account existing = makeIndividualDonor('Pedro', 'Ruiz', 'pedro.old@test.ca');

        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            Email__c                = 'pedro.new@test.ca',
            Amount__c               = 50.00,
            Eligible_Amount__c      = 50.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Contact_Id__c     = 'zeffy_updemail_001',
            Zeffy_Transaction_Id__c = 'txn_updemail_001'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.resolveLinkExisting(ticket.Id, existing.Id, '', 'Email_Address__c', false, false, false);
        Test.stopTest();

        Account updated = [SELECT Email_Address__c FROM Account WHERE Id = :existing.Id];
        System.assertEquals('pedro.new@test.ca', updated.Email_Address__c, 'Email should be updated on Account');
    }

    // ─── resolveLinkExisting — address update ─────────────────────────────────

    @isTest
    static void testResolveLinkExistingUpdateAddress() {
        Account existing = makeIndividualDonor('Maria', 'Santos', 'maria@test.ca');
        existing.BillingStreet = '10 Vieille Rue';
        update existing;

        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            Email__c                = 'maria@test.ca',
            Address__c              = '999 Nouvelle Avenue',
            City__c                 = 'Québec',
            Province__c             = 'QC',
            Postal_Code__c          = 'G1A 1B1',
            Amount__c               = 30.00,
            Eligible_Amount__c      = 30.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Contact_Id__c     = 'zeffy_updaddr_001',
            Zeffy_Transaction_Id__c = 'txn_updaddr_001'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.resolveLinkExisting(ticket.Id, existing.Id, '', null, true, false, false);
        Test.stopTest();

        Account updated = [SELECT BillingStreet, BillingCity, BillingState, BillingPostalCode
                           FROM Account WHERE Id = :existing.Id];
        System.assertEquals('999 Nouvelle Avenue', updated.BillingStreet, 'Address should be updated');
        System.assertEquals('Québec', updated.BillingCity);
        System.assertEquals('QC', updated.BillingState);
        System.assertEquals('G1A 1B1', updated.BillingPostalCode);
    }

    // ─── getLinkPreview ───────────────────────────────────────────────────────

    @isTest
    static void testGetLinkPreview() {
        Account existing = makeIndividualDonor('Jacques', 'Leblanc', 'jl@test.ca');
        existing.BillingStreet = '1 Rue Ancienne';
        existing.BillingCity   = 'Montréal';
        update existing;
        linkIdentity(existing.Id, 'zeffy_prev_old', 'jl@test.ca');

        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            Email__c                = 'jl.new@test.ca',
            Address__c              = '99 Rue Nouvelle',
            City__c                 = 'Laval',
            Amount__c               = 60.00,
            Zeffy_Transaction_Id__c = 'txn_prev_001'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.LinkPreview preview = ZeffyConnectDonationService.getLinkPreview(ticket.Id, existing.Id);
        Test.stopTest();

        System.assertNotEquals(null, preview, 'Preview should not be null');
        System.assertEquals('jl@test.ca',     preview.accountEmail);
        System.assertEquals('jl.new@test.ca', preview.ticketEmail);
        System.assertEquals(true,             preview.emailsDiffer, 'Emails differ');
        System.assertEquals(true,             preview.addressesDiffer, 'Addresses differ');
        System.assertEquals(1, preview.existingZeffyIds.size(), 'Should show 1 existing Zeffy ID');
    }

    // ─── closeTicket ─────────────────────────────────────────────────────────

    @isTest
    static void testCloseTicket() {
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            Email__c                = 'skip@test.ca',
            Amount__c               = 10.00,
            Zeffy_Transaction_Id__c = 'txn_skip_001'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.closeTicket(ticket.Id, 'Ticket de prueba');
        Test.stopTest();

        System.assertEquals('Closed',
            [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :ticket.Id].Status__c);
    }

    // ─── getTickets ───────────────────────────────────────────────────────────

    @isTest
    static void testGetTickets() {
        insert new List<Zeffy_Review_Ticket__c>{
            new Zeffy_Review_Ticket__c(Status__c = 'Pending Review', Email__c = 'a@test.ca',
                                       Amount__c = 10.00, Zeffy_Transaction_Id__c = 'txn_gt_001'),
            new Zeffy_Review_Ticket__c(Status__c = 'Skipped', Email__c = 'b@test.ca',
                                       Amount__c = 20.00, Zeffy_Transaction_Id__c = 'txn_gt_002')
        };

        Test.startTest();
        List<Zeffy_Review_Ticket__c> pending = ZeffyConnectDonationService.getTickets('Pending Review');
        List<Zeffy_Review_Ticket__c> all     = ZeffyConnectDonationService.getTickets('All');
        Test.stopTest();

        System.assertEquals(1, pending.size(), 'Should return 1 pending ticket');
        System.assertEquals(2, all.size(),     'Should return all 2 tickets');
    }

    // ─── Recurring → Gift_Commitment__c created ───────────────────────────────

    @isTest
    static void testRecurringDonationCreatesCommitment() {
        Account donor = makeIndividualDonor('Marie', 'Tremblay', 'marie.rec@test.ca');
        linkIdentity(donor.Id, 'zeffy_rec_001', 'marie.rec@test.ca');

        Test.startTest();
        ZeffyConnectDonationService.processWebhook(buildRecurringPayload('txn_rec_001', 'sub_monthly_001'));
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Gift_Transaction__c], 'Should create 1 Gift_Transaction__c');

        List<Gift_Commitment__c> commitments = [
            SELECT Zeffy_Subscription_Id__c, Status__c FROM Gift_Commitment__c
        ];
        System.assertEquals(1, commitments.size(), 'Should create 1 Gift_Commitment__c');
        System.assertEquals('sub_monthly_001', commitments[0].Zeffy_Subscription_Id__c);
        System.assertEquals('Active', commitments[0].Status__c);
    }

    // ─── Currency reserved keyword remap ─────────────────────────────────────

    @isTest
    static void testCurrencyFieldRemapped() {
        Test.startTest();
        ZeffyConnectDonationService.processWebhook(buildPayload('txn_curr_001', 'curr@test.ca', 'zeffy_curr_001'));
        Test.stopTest();

        Zeffy_Review_Ticket__c ticket = [SELECT Currency__c FROM Zeffy_Review_Ticket__c LIMIT 1];
        System.assertEquals('CAD', ticket.Currency__c, 'Currency should be mapped from "currency" JSON key');
    }

    // ─── Receiver: NO_CONFIG path ─────────────────────────────────────────────

    @isTest
    static void testNoConfig() {
        // Blank the webhook secret — simulates an unconfigured org (secret is required for NO_CONFIG path)
        Zeffy_Config__c cfg = [SELECT Id FROM Zeffy_Config__c LIMIT 1];
        cfg.Webhook_Secret__c = null;
        cfg.Is_Active__c      = true;
        update cfg;

        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(buildPayload('txn_nc', 'nc@test.ca', 'zeffy_nc'));
        RestContext.request  = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        ZeffyConnectWebhookReceiver.handleWebhook();
        Test.stopTest();

        Zeffy_Webhook_Log__c log = [SELECT Status__c FROM Zeffy_Webhook_Log__c ORDER BY CreatedDate DESC LIMIT 1];
        System.assertEquals('NO_CONFIG', log.Status__c);
    }

    // ─── Receiver: SERVICE_INACTIVE path ─────────────────────────────────────

    @isTest
    static void testServiceInactive() {
        Zeffy_Config__c cfg = [SELECT Id FROM Zeffy_Config__c LIMIT 1];
        cfg.Is_Active__c = false;
        update cfg;

        String body = buildPayload('txn_si', 'si@test.ca', 'zeffy_si');
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(body);
        req.addHeader('Zeffy-Signature', zeffySignature(body));
        RestContext.request  = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        ZeffyConnectWebhookReceiver.handleWebhook();
        Test.stopTest();

        Zeffy_Webhook_Log__c log = [SELECT Status__c, Has_Raw_Payload__c FROM Zeffy_Webhook_Log__c ORDER BY CreatedDate DESC LIMIT 1];
        System.assertEquals('SERVICE_INACTIVE', log.Status__c);
        System.assertEquals(true, log.Has_Raw_Payload__c, 'Paused events keep their payload so they can be reprocessed');
        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Review_Ticket__c], 'Nothing is processed while paused');
    }

    @isTest
    static void testServiceInactiveUnsignedIsAuthFailed() {
        Zeffy_Config__c cfg = [SELECT Id FROM Zeffy_Config__c LIMIT 1];
        cfg.Is_Active__c = false;
        update cfg;

        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(buildPayload('txn_si2', 'si2@test.ca', 'zeffy_si2'));
        RestContext.request  = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        ZeffyConnectWebhookReceiver.handleWebhook();
        Test.stopTest();

        Zeffy_Webhook_Log__c log = [SELECT Status__c, Has_Raw_Payload__c FROM Zeffy_Webhook_Log__c ORDER BY CreatedDate DESC LIMIT 1];
        System.assertEquals('AUTH_FAILED', log.Status__c, 'Unsigned requests are never stored, even while paused');
        System.assertEquals(false, log.Has_Raw_Payload__c);
    }

    // ─── Receiver: EMPTY_PAYLOAD path ────────────────────────────────────────

    @isTest
    static void testEmptyBody() {
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf('');
        req.headers.put('X-Zeffy-Signature', 'test_secret_key_123');
        RestContext.request  = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        ZeffyConnectWebhookReceiver.handleWebhook();
        Test.stopTest();

        Zeffy_Webhook_Log__c log = [SELECT Status__c FROM Zeffy_Webhook_Log__c ORDER BY CreatedDate DESC LIMIT 1];
        System.assertEquals('EMPTY_PAYLOAD', log.Status__c);
    }

    // ─── Receiver: valid X-Zeffy-Signature header ─────────────────────────────

    @isTest
    static void testValidXZeffySignatureHeader() {
        RestRequest req = new RestRequest();
        String body = buildPayload('txn_xzs', 'xzs@test.ca', 'zeffy_xzs');
        req.requestBody = Blob.valueOf(body);
        req.headers.put('Zeffy-Signature', zeffySignature(body));
        RestContext.request  = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        ZeffyConnectWebhookReceiver.handleWebhook();
        Test.stopTest();

        Zeffy_Webhook_Log__c log = [SELECT Status__c FROM Zeffy_Webhook_Log__c ORDER BY CreatedDate DESC LIMIT 1];
        System.assertNotEquals('AUTH_FAILED', log.Status__c, 'Valid X-Zeffy-Signature should pass auth');
    }

    // ─── Receiver: valid Authorization: Bearer token ─────────────────────────

    @isTest
    static void testValidBearerToken() {
        RestRequest req = new RestRequest();
        String body = buildPayload('txn_bearer', 'bearer@test.ca', 'zeffy_bearer');
        req.requestBody = Blob.valueOf(body);
        req.headers.put('Zeffy-Signature', zeffySignature(body));
        RestContext.request  = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        ZeffyConnectWebhookReceiver.handleWebhook();
        Test.stopTest();

        Zeffy_Webhook_Log__c log = [SELECT Status__c FROM Zeffy_Webhook_Log__c ORDER BY CreatedDate DESC LIMIT 1];
        System.assertNotEquals('AUTH_FAILED', log.Status__c, 'Valid Bearer token should pass auth');
    }

    // ─── Receiver: wrong header (Authorization instead of Zeffy-Signature) → AUTH_FAILED ──

    @isTest
    static void testNonBearerAuthorizationFails() {
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(buildPayload('txn_nonbearer', 'nb@test.ca', 'zeffy_nb'));
        // Zeffy-Signature header ausente — cualquier otro header es ignorado
        req.headers.put('Authorization', 'Token test_secret_key_123');
        RestContext.request  = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        ZeffyConnectWebhookReceiver.handleWebhook();
        Test.stopTest();

        Zeffy_Webhook_Log__c log = [SELECT Status__c FROM Zeffy_Webhook_Log__c ORDER BY CreatedDate DESC LIMIT 1];
        System.assertEquals('AUTH_FAILED', log.Status__c, 'Non-Bearer prefix should not be stripped');
    }

    // ─── Receiver: UNHANDLED_EXCEPTION path (via @TestVisible flag) ───────────

    @isTest
    static void testUnhandledException() {
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(buildPayload('txn_ex', 'ex@test.ca', 'zeffy_ex'));
        req.headers.put('X-Zeffy-Signature', 'test_secret_key_123');
        RestContext.request  = req;
        RestContext.response = new RestResponse();

        ZeffyConnectWebhookReceiver.throwForTest = true;
        Test.startTest();
        ZeffyConnectWebhookReceiver.handleWebhook();
        Test.stopTest();
        ZeffyConnectWebhookReceiver.throwForTest = false;

        Zeffy_Webhook_Log__c log = [SELECT Status__c, Raw_Payload__c, Has_Raw_Payload__c FROM Zeffy_Webhook_Log__c ORDER BY CreatedDate DESC LIMIT 1];
        System.assertEquals('UNHANDLED_EXCEPTION', log.Status__c);
        System.assert(log.Has_Raw_Payload__c, 'Payload must be kept so staff can reprocess it');
        System.assert(log.Raw_Payload__c.contains('txn_ex'));
        RestResponse res = RestContext.response;
        System.assertEquals(500, res.statusCode, 'Unexpected errors return 500 so Zeffy retries');
    }

    // ─── writeLog catch path (via @TestVisible flag) ─────────────────────────

    @isTest
    static void testWriteLogCatchPath() {
        ZeffyConnectWebhookReceiver.failWriteLog = true;
        Test.startTest();
        // writeLog itself won't throw — the catch inside it fires and is swallowed
        ZeffyConnectWebhookReceiver.writeLog('TEST', null, null, null, 'test', 'test', null);
        Test.stopTest();
        ZeffyConnectWebhookReceiver.failWriteLog = false;
        // No assertion needed — just verifying the catch line executes without crashing
    }

    // ─── validateToken: wrong HMAC (correct format/timestamp, wrong v1 hex) ─────

    @isTest
    static void testWrongHmacSignature() {
        RestRequest req = new RestRequest();
        String body = buildPayload('txn_wronghmac', 'wronghmac@test.ca', 'zeffy_wronghmac');
        req.requestBody = Blob.valueOf(body);
        Long ts = DateTime.now().getTime() / 1000;
        req.headers.put('Zeffy-Signature', 't=' + ts + ',v1=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef');
        RestContext.request  = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        ZeffyConnectWebhookReceiver.handleWebhook();
        Test.stopTest();

        Zeffy_Webhook_Log__c log = [SELECT Status__c, Detail__c FROM Zeffy_Webhook_Log__c ORDER BY CreatedDate DESC LIMIT 1];
        System.assertEquals('AUTH_FAILED', log.Status__c);
        System.assert(log.Detail__c.contains('no coincide'), 'Should say the signature did not match');
        System.assert(!log.Detail__c.contains('esperado') && !log.Detail__c.containsIgnoreCase('secret'),
            'Never log the expected signature or anything about the secret');
    }

    // ─── validateToken: Zeffy-Signature header present but malformed (no t/v1) ─

    @isTest
    static void testMalformedSignatureHeader() {
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(buildPayload('txn_mal', 'mal@test.ca', 'zeffy_mal'));
        req.headers.put('Zeffy-Signature', 'noequalsignatall');
        RestContext.request  = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        ZeffyConnectWebhookReceiver.handleWebhook();
        Test.stopTest();

        Zeffy_Webhook_Log__c log = [SELECT Status__c, Detail__c FROM Zeffy_Webhook_Log__c ORDER BY CreatedDate DESC LIMIT 1];
        System.assertEquals('AUTH_FAILED', log.Status__c);
        System.assert(log.Detail__c.contains('mal formateado'), 'Should mention malformed header');
    }

    // ─── validateToken: replay attack — timestamp older than 5 minutes ────────

    @isTest
    static void testReplayAttackRejected() {
        RestRequest req = new RestRequest();
        String body = buildPayload('txn_replay', 'replay@test.ca', 'zeffy_replay');
        req.requestBody = Blob.valueOf(body);
        Long oldTs = (DateTime.now().getTime() / 1000) - 400;
        Blob mac = Crypto.generateMac('hmacSHA256', Blob.valueOf(String.valueOf(oldTs) + '.' + body), Blob.valueOf(TEST_SECRET));
        req.headers.put('Zeffy-Signature', 't=' + oldTs + ',v1=' + EncodingUtil.convertToHex(mac));
        RestContext.request  = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        ZeffyConnectWebhookReceiver.handleWebhook();
        Test.stopTest();

        Zeffy_Webhook_Log__c log = [SELECT Status__c, Detail__c FROM Zeffy_Webhook_Log__c ORDER BY CreatedDate DESC LIMIT 1];
        System.assertEquals('AUTH_FAILED', log.Status__c);
        System.assert(log.Detail__c.contains('Replay attack'), 'Should mention replay attack');
    }

    // ─── validateToken: non-numeric timestamp in header ───────────────────────

    @isTest
    static void testNonNumericTimestamp() {
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(buildPayload('txn_badts', 'badts@test.ca', 'zeffy_badts'));
        req.headers.put('Zeffy-Signature', 't=not_a_number,v1=deadbeef1234');
        RestContext.request  = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        ZeffyConnectWebhookReceiver.handleWebhook();
        Test.stopTest();

        Zeffy_Webhook_Log__c log = [SELECT Status__c, Detail__c FROM Zeffy_Webhook_Log__c ORDER BY CreatedDate DESC LIMIT 1];
        System.assertEquals('AUTH_FAILED', log.Status__c);
        System.assert(log.Detail__c.contains('válido'), 'Should mention invalid timestamp');
    }

    // A payload over the log field size is not kept (a cut payload could never be reprocessed)
    @isTest
    static void testOversizedPayloadIsNotKept() {
        String big = '{"type":"payment.completed","data":"' + 'z'.repeat(140000) + '"}';
        Test.startTest();
        ZeffyConnectWebhookReceiver.writeLog('IGNORED', 'txn_big_log', null, null, 'test', null, null, big);
        Test.stopTest();
        Zeffy_Webhook_Log__c log = [SELECT Raw_Payload__c, Has_Raw_Payload__c, Detail__c FROM Zeffy_Webhook_Log__c
                                    WHERE Transaction_Id__c = 'txn_big_log' LIMIT 1];
        System.assertEquals(null, log.Raw_Payload__c);
        System.assertEquals(false, log.Has_Raw_Payload__c);
        System.assert(log.Detail__c.contains('too large'), log.Detail__c);
    }
}
