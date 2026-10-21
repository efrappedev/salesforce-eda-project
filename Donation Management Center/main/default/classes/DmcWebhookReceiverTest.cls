@isTest
private class DmcWebhookReceiverTest {

    // ─── Payload builders ─────────────────────────────────────────────────────

    private static String buildPayload(String transactionId, String email, String contactId) {
        return '{"id":"evt_test","type":"payment.completed","version":"1","dispatchedAt":"2026-01-01T00:00:00Z",' +
               '"data":{"id":"' + transactionId + '","status":"completed","type":"Donation",' +
               '"amount":100.00,"eligibleAmount":80.00,"platformFee":3.50,' +
               '"currency":"CAD","paymentMethod":"Credit Card",' +
               '"created":"2026-01-15T10:00:00Z","receiptNumber":"R-001",' +
               '"receiptUrl":"https://zeffy.com/receipt/R-001","rateTitle":"Donación general",' +
               '"note":"Test note","annotation":"Test annotation",' +
               '"isRecurring":false,"subscriptionId":null,"subscriptionFrequency":null,' +
               '"contact":{"id":"' + contactId + '","firstName":"Juan","lastName":"Pérez",' +
               '"name":"Juan Pérez","email":"' + email + '","phoneNumber":"5141234567",' +
               '"companyName":null,"language":"fr",' +
               '"address":{"address":"123 Rue Test","city":"Montréal","region":"QC",' +
               '"state":null,"postalCode":"H1A 1A1","country":"Canada"}},' +
               '"campaign":{"id":"form_abc","name":"Campaña Test"}}}';
    }

    private static String buildRecurringPayload(String transactionId, String subId) {
        return '{"id":"evt_rec","type":"payment.completed","version":"1","dispatchedAt":"2026-01-01T00:00:00Z",' +
               '"data":{"id":"' + transactionId + '","status":"completed","type":"Donation",' +
               '"amount":25.00,"eligibleAmount":25.00,"platformFee":1.50,' +
               '"currency":"CAD","paymentMethod":"Credit Card",' +
               '"created":"2026-01-20T09:00:00Z","receiptNumber":"R-003","receiptUrl":null,' +
               '"rateTitle":"Abonnement mensuel","note":null,"annotation":null,' +
               '"isRecurring":true,"subscriptionId":"' + subId + '","subscriptionFrequency":"Monthly",' +
               '"contact":{"id":"zeffy_rec_001","firstName":"Marie","lastName":"Tremblay",' +
               '"name":"Marie Tremblay","email":"marie.rec@test.ca","phoneNumber":null,' +
               '"companyName":null,"language":"fr",' +
               '"address":{"address":null,"city":null,"region":null,"state":null,"postalCode":null,"country":null}},' +
               '"campaign":null}}';
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

    // Helper: create a PersonAccount
    private static Account makePersonAccount(String firstName, String lastName, String email) {
        Id personRtId = [SELECT Id FROM RecordType WHERE SObjectType = 'Account'
                         AND DeveloperName = 'PersonAccount' LIMIT 1]?.Id;
        Account a = new Account(RecordTypeId = personRtId,
                                FirstName = firstName, LastName = lastName, PersonEmail = email);
        insert a;
        return a;
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
        DmcWebhookReceiver.handleWebhook();
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Review_Ticket__c],
            'Payload without secret should be blocked');
    }

    // ─── Unknown donor → ticket ───────────────────────────────────────────────

    @isTest
    static void testNewDonorCreatesReviewTicket() {
        Test.startTest();
        DmcDonationService.processWebhook(buildPayload('txn_new_001', 'nuevo@test.ca', 'zeffy_new_001'));
        Test.stopTest();

        List<Zeffy_Review_Ticket__c> tickets = [
            SELECT Status__c, Email__c, Amount__c, Zeffy_Transaction_Id__c, Eligible_Amount__c
            FROM Zeffy_Review_Ticket__c
        ];
        System.assertEquals(1, tickets.size(), 'Should create 1 review ticket');
        System.assertEquals('Pending Review', tickets[0].Status__c);
        System.assertEquals('nuevo@test.ca', tickets[0].Email__c);
        System.assertEquals(100.00, tickets[0].Amount__c);
        System.assertEquals(80.00, tickets[0].Eligible_Amount__c);
        System.assertEquals('txn_new_001', tickets[0].Zeffy_Transaction_Id__c);
    }

    // ─── Known donor found via Zeffy_Identity__c → auto GiftTransaction ───────

    @isTest
    static void testKnownDonorByZeffyIdentityCreatesGift() {
        Account donor = makePersonAccount('Ana', 'García', 'ana@test.ca');
        linkIdentity(donor.Id, 'zeffy_known_001', 'ana@test.ca');

        Test.startTest();
        DmcDonationService.processWebhook(buildPayload('txn_known_001', 'ana@test.ca', 'zeffy_known_001'));
        Test.stopTest();

        List<GiftTransaction> gifts = [
            SELECT Id, DonorId, OriginalAmount, NonTaxDeductibleAmount, Status, Zeffy_Transaction_Id__c
            FROM GiftTransaction
        ];
        System.assertEquals(1, gifts.size(), 'Should auto-create 1 GiftTransaction');
        System.assertEquals(donor.Id, gifts[0].DonorId);
        System.assertEquals(100.00, gifts[0].OriginalAmount);
        System.assertEquals(20.00, gifts[0].NonTaxDeductibleAmount);  // 100 - 80
        System.assertEquals('Paid', gifts[0].Status);
        System.assertEquals('txn_known_001', gifts[0].Zeffy_Transaction_Id__c);

        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Review_Ticket__c],
            'Known donor should not create ticket');
    }

    // ─── Email fallback → auto GiftTransaction + creates Zeffy_Identity__c ────

    @isTest
    static void testKnownDonorByEmailFallbackCreatesGift() {
        Account donor = makePersonAccount('Carlos', 'López', 'carlos@test.ca');
        // No Zeffy_Identity__c yet — robot falls back to PersonEmail

        Test.startTest();
        DmcDonationService.processWebhook(buildPayload('txn_email_001', 'carlos@test.ca', 'zeffy_email_001'));
        Test.stopTest();

        List<GiftTransaction> gifts = [SELECT Id, DonorId FROM GiftTransaction];
        System.assertEquals(1, gifts.size(), 'Should create gift via email fallback');
        System.assertEquals(donor.Id, gifts[0].DonorId);

        // New Zeffy_Identity__c should have been created
        List<Zeffy_Identity__c> identities = [
            SELECT Zeffy_Contact_Id__c, Account__c FROM Zeffy_Identity__c
        ];
        System.assertEquals(1, identities.size(), 'Should create Zeffy_Identity__c on email match');
        System.assertEquals('zeffy_email_001', identities[0].Zeffy_Contact_Id__c);
        System.assertEquals(donor.Id, identities[0].Account__c);
    }

    // ─── Second Zeffy ID for same person (multi-ID scenario) ─────────────────

    @isTest
    static void testSecondZeffyIdLinksToSameAccount() {
        Account donor = makePersonAccount('Sofia', 'Dupont', 'sofia@test.ca');
        linkIdentity(donor.Id, 'zeffy_first_001', 'sofia@test.ca');

        // Same person, NEW Zeffy contact ID (registered twice in Zeffy), different email
        Test.startTest();
        DmcDonationService.processWebhook(buildPayload('txn_multi_001', 'sofia.new@test.ca', 'zeffy_second_001'));
        Test.stopTest();

        // Robot doesn't know this person (new email, new Zeffy ID) → creates ticket
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Review_Ticket__c],
            'Unknown Zeffy ID + new email should create a review ticket');
    }

    // ─── Dedup ────────────────────────────────────────────────────────────────

    @isTest
    static void testDuplicateTransactionBlocked() {
        Account donor = makePersonAccount('Pedro', 'Martínez', 'pedro@test.ca');
        linkIdentity(donor.Id, 'zeffy_dup_001', 'pedro@test.ca');

        String payload = buildPayload('txn_dup_001', 'pedro@test.ca', 'zeffy_dup_001');

        Test.startTest();
        DmcDonationService.processWebhook(payload);
        DmcDonationService.processWebhook(payload);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM GiftTransaction],
            'Duplicate transaction should be blocked');
    }

    // ─── Non-payment events ignored ───────────────────────────────────────────

    @isTest
    static void testNonPaymentEventIgnored() {
        String payload = '{"id":"evt_x","type":"refund.processed","version":"1","dispatchedAt":"2026-01-01T00:00:00Z",' +
                         '"data":{"id":"txn_refund","status":"refunded"}}';
        Test.startTest();
        DmcDonationService.processWebhook(payload);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Review_Ticket__c], 'Refund event ignored');
        System.assertEquals(0, [SELECT COUNT() FROM GiftTransaction], 'Refund event creates no gift');
    }

    // ─── Invalid JSON → error ticket ──────────────────────────────────────────

    @isTest
    static void testInvalidJsonCreatesErrorTicket() {
        Test.startTest();
        DmcDonationService.processWebhook('{not valid json!!!}');
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
        DmcDonationService.resolveCreateNew(ticket.Id, 'individual', 'Creado desde test');
        Test.stopTest();

        Zeffy_Review_Ticket__c resolved = [
            SELECT Status__c, Resolved_Account__c, Resolved_Gift__c
            FROM Zeffy_Review_Ticket__c WHERE Id = :ticket.Id
        ];
        System.assertEquals('Resolved - New Contact', resolved.Status__c);
        System.assertNotEquals(null, resolved.Resolved_Account__c, 'Should set Resolved_Account__c');
        System.assertNotEquals(null, resolved.Resolved_Gift__c, 'Should set Resolved_Gift__c');

        Account newAcct = [SELECT IsPersonAccount, FirstName, LastName, PersonEmail
                           FROM Account WHERE Id = :resolved.Resolved_Account__c];
        System.assertEquals(true, newAcct.IsPersonAccount, 'Should create PersonAccount');
        System.assertEquals('Laura', newAcct.FirstName);
        System.assertEquals('Morales', newAcct.LastName);
        System.assertEquals('laura@test.ca', newAcct.PersonEmail);

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
        DmcDonationService.resolveCreateNew(ticket.Id, 'eglise', 'Iglesia nueva');
        Test.stopTest();

        Zeffy_Review_Ticket__c resolved = [SELECT Resolved_Account__c FROM Zeffy_Review_Ticket__c WHERE Id = :ticket.Id];
        Account church = [SELECT Name, RecordType.DeveloperName, IsPersonAccount
                          FROM Account WHERE Id = :resolved.Resolved_Account__c];
        System.assertEquals('Eglise', church.RecordType.DeveloperName, 'Should use Eglise record type');
        System.assertEquals(false, church.IsPersonAccount);
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
            Payment_Method__c       = 'ACH',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Transaction_Id__c = 'txn_org_001'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        DmcDonationService.resolveCreateNew(ticket.Id, 'org', 'Organización nueva');
        Test.stopTest();

        Zeffy_Review_Ticket__c resolved = [SELECT Resolved_Account__c FROM Zeffy_Review_Ticket__c WHERE Id = :ticket.Id];
        Account org = [SELECT RecordType.DeveloperName FROM Account WHERE Id = :resolved.Resolved_Account__c];
        System.assertEquals('Org_Business_Account', org.RecordType.DeveloperName);
    }

    // ─── resolveLinkExisting — no email/address update ────────────────────────

    @isTest
    static void testResolveLinkExistingBasic() {
        Account existing = makePersonAccount('Sofia', 'Rodríguez', 'sofia@test.ca');

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
        DmcDonationService.resolveLinkExisting(ticket.Id, existing.Id, 'Vinculado', null, false);
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
        Account existing = makePersonAccount('Pedro', 'Ruiz', 'pedro.old@test.ca');

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
        DmcDonationService.resolveLinkExisting(ticket.Id, existing.Id, '', 'PersonEmail', false);
        Test.stopTest();

        Account updated = [SELECT PersonEmail FROM Account WHERE Id = :existing.Id];
        System.assertEquals('pedro.new@test.ca', updated.PersonEmail, 'Email should be updated on Account');
    }

    // ─── resolveLinkExisting — address update ─────────────────────────────────

    @isTest
    static void testResolveLinkExistingUpdateAddress() {
        Account existing = makePersonAccount('Maria', 'Santos', 'maria@test.ca');
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
        DmcDonationService.resolveLinkExisting(ticket.Id, existing.Id, '', null, true);
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
        Account existing = makePersonAccount('Jacques', 'Leblanc', 'jl@test.ca');
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
        DmcDonationService.LinkPreview preview = DmcDonationService.getLinkPreview(ticket.Id, existing.Id);
        Test.stopTest();

        System.assertNotEquals(null, preview, 'Preview should not be null');
        System.assertEquals('jl@test.ca',     preview.accountEmail);
        System.assertEquals('jl.new@test.ca', preview.ticketEmail);
        System.assertEquals(true,             preview.emailsDiffer, 'Emails differ');
        System.assertEquals(true,             preview.addressesDiffer, 'Addresses differ');
        System.assertEquals(1, preview.existingZeffyIds.size(), 'Should show 1 existing Zeffy ID');
    }

    // ─── skipTicket ───────────────────────────────────────────────────────────

    @isTest
    static void testSkipTicket() {
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            Email__c                = 'skip@test.ca',
            Amount__c               = 10.00,
            Zeffy_Transaction_Id__c = 'txn_skip_001'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        DmcDonationService.skipTicket(ticket.Id, 'Ticket de prueba');
        Test.stopTest();

        System.assertEquals('Skipped',
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
        List<Zeffy_Review_Ticket__c> pending = DmcDonationService.getTickets('Pending Review');
        List<Zeffy_Review_Ticket__c> all     = DmcDonationService.getTickets('All');
        Test.stopTest();

        System.assertEquals(1, pending.size(), 'Should return 1 pending ticket');
        System.assertEquals(2, all.size(),     'Should return all 2 tickets');
    }

    // ─── Recurring → GiftCommitment created ───────────────────────────────────

    @isTest
    static void testRecurringDonationCreatesCommitment() {
        Account donor = makePersonAccount('Marie', 'Tremblay', 'marie.rec@test.ca');
        linkIdentity(donor.Id, 'zeffy_rec_001', 'marie.rec@test.ca');

        Test.startTest();
        DmcDonationService.processWebhook(buildRecurringPayload('txn_rec_001', 'sub_monthly_001'));
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM GiftTransaction], 'Should create 1 GiftTransaction');

        List<GiftCommitment> commitments = [
            SELECT Zeffy_Subscription_Id__c, Status FROM GiftCommitment
        ];
        System.assertEquals(1, commitments.size(), 'Should create 1 GiftCommitment');
        System.assertEquals('sub_monthly_001', commitments[0].Zeffy_Subscription_Id__c);
        System.assertEquals('Active', commitments[0].Status);
    }

    // ─── Currency reserved keyword remap ─────────────────────────────────────

    @isTest
    static void testCurrencyFieldRemapped() {
        Test.startTest();
        DmcDonationService.processWebhook(buildPayload('txn_curr_001', 'curr@test.ca', 'zeffy_curr_001'));
        Test.stopTest();

        Zeffy_Review_Ticket__c ticket = [SELECT Currency__c FROM Zeffy_Review_Ticket__c LIMIT 1];
        System.assertEquals('CAD', ticket.Currency__c, 'Currency should be mapped from "currency" JSON key');
    }
}
