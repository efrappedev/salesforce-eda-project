@IsTest
public class ZeffyWebhookReceiverTest {

    @TestSetup
    static void makeData() {
        // Active config with empty secret (dev mode — skip token validation)
        insert new Zeffy_Config__c(
            SetupOwnerId     = UserInfo.getOrganizationId(),
            API_Key__c       = 'test-api-key',
            Webhook_Secret__c = '',
            Is_Active__c     = true
        );
        Account acct = new Account(Name = 'Jean Dupont');
        insert acct;
        insert new Contact(
            FirstName           = 'Jean',
            LastName            = 'Dupont',
            Email               = 'jean@test.com',
            AccountId           = acct.Id,
            Zeffy_Contact_Id__c = 'zeffy-known-001'
        );
    }

    // ── payload builder ───────────────────────────────────────────────────────

    static String buildPayload(String zeffyContactId, String orderId,
                               Boolean isRecurring, String subId) {
        String recurring = isRecurring ? 'true' : 'false';
        String subVal    = subId != null ? '"' + subId + '"' : 'null';
        return '{"id":"evt-001","type":"payment.completed","version":"1",' +
               '"dispatchedAt":"2026-09-14T10:00:00Z",' +
               '"data":{"id":"' + orderId + '","status":"paid","type":"donation",' +
               '"amount":100,"eligibleAmount":100,"netAmount":96.50,"platformFee":3.50,' +
               '"currency":"CAD","paymentMethod":"CREDIT_CARD",' +
               '"created":"2026-09-14T10:00:00Z","receiptNumber":"RC-001",' +
               '"receiptUrl":"https://zeffy.com/receipt/001",' +
               '"note":"Merci pour votre travail","annotation":null,' +
               '"isRecurring":' + recurring + ',"subscriptionId":' + subVal + ',' +
               '"subscriptionFrequency":"monthly",' +
               '"contact":{"id":"' + zeffyContactId + '",' +
               '"firstName":"Jean","lastName":"Dupont","email":"jean@test.com",' +
               '"phoneNumber":"+15141234567","language":"fr",' +
               '"address":{"address":"123 Rue Main","city":"Montreal",' +
               '"region":"QC","postalCode":"H1A1A1","country":"CA"}},' +
               '"campaign":{"id":"form-001","name":"Campagne 2026"}}}';
    }

    static void setupRestContext(String body) {
        RestRequest req   = new RestRequest();
        req.requestBody   = Blob.valueOf(body);
        req.httpMethod    = 'POST';
        RestContext.request  = req;
        RestContext.response = new RestResponse();
    }

    // ── tests ─────────────────────────────────────────────────────────────────

    @IsTest
    static void testKnownDonor_createsGiftTransaction() {
        String payload = buildPayload('zeffy-known-001', 'ord-auto-001', false, null);
        setupRestContext(payload);

        Test.startTest();
        ZeffyWebhookReceiver.handleWebhook();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        List<Gift_Transaction__c> gifts = [SELECT Id, Amount__c, Source__c
                                           FROM Gift_Transaction__c
                                           WHERE Zeffy_Transaction_Id__c = 'ord-auto-001'];
        System.assertEquals(1, gifts.size());
        System.assertEquals(100, gifts[0].Amount__c);
        System.assertEquals('Zeffy', gifts[0].Source__c);
        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Review_Ticket__c]);
    }

    @IsTest
    static void testUnknownDonor_createsReviewTicket() {
        String payload = buildPayload('zeffy-unknown-999', 'ord-review-001', false, null);
        setupRestContext(payload);

        Test.startTest();
        ZeffyWebhookReceiver.handleWebhook();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        List<Zeffy_Review_Ticket__c> tickets = [
            SELECT Id, Status__c, First_Name__c, Amount__c
            FROM Zeffy_Review_Ticket__c
            WHERE Zeffy_Transaction_Id__c = 'ord-review-001'
        ];
        System.assertEquals(1, tickets.size());
        System.assertEquals('Pending Review', tickets[0].Status__c);
        System.assertEquals('Jean', tickets[0].First_Name__c);
        System.assertEquals(100, tickets[0].Amount__c);
        System.assertEquals(0, [SELECT COUNT() FROM Gift_Transaction__c]);
    }

    @IsTest
    static void testDuplicate_skipsProcessing() {
        Contact donor = [SELECT Id FROM Contact WHERE Zeffy_Contact_Id__c = 'zeffy-known-001' LIMIT 1];
        insert new Gift_Transaction__c(
            Donor__c                = donor.Id,
            Amount__c               = 100,
            Status__c               = 'Received',
            Gift_Date__c            = Date.today(),
            Zeffy_Transaction_Id__c = 'ord-dup-001'
        );
        String payload = buildPayload('zeffy-known-001', 'ord-dup-001', false, null);
        setupRestContext(payload);

        Test.startTest();
        ZeffyWebhookReceiver.handleWebhook();
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Gift_Transaction__c WHERE Zeffy_Transaction_Id__c = 'ord-dup-001']);
    }

    @IsTest
    static void testRecurring_createsGiftCommitment() {
        String payload = buildPayload('zeffy-known-001', 'ord-rec-001', true, 'sub-123');
        setupRestContext(payload);

        Test.startTest();
        ZeffyWebhookReceiver.handleWebhook();
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Gift_Commitment__c WHERE Zeffy_Subscription_Id__c = 'sub-123']);
    }

    @IsTest
    static void testInvalidToken_returns401() {
        // Override config to require a secret
        Zeffy_Config__c cfg = Zeffy_Config__c.getInstance();
        cfg.Webhook_Secret__c = 'my-real-secret';
        update cfg;

        String payload = buildPayload('zeffy-known-001', 'ord-token-001', false, null);
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(payload);
        req.httpMethod  = 'POST';
        req.addHeader('X-Zeffy-Signature', 'wrong-token');
        RestContext.request  = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        ZeffyWebhookReceiver.handleWebhook();
        Test.stopTest();

        System.assertEquals(401, RestContext.response.statusCode);
        System.assertEquals(0, [SELECT COUNT() FROM Gift_Transaction__c]);
        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Review_Ticket__c]);
    }

    @IsTest
    static void testPaused_returns200WithoutProcessing() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getInstance();
        cfg.Is_Active__c = false;
        update cfg;

        String payload = buildPayload('zeffy-known-001', 'ord-paused-001', false, null);
        setupRestContext(payload);

        Test.startTest();
        ZeffyWebhookReceiver.handleWebhook();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(0, [SELECT COUNT() FROM Gift_Transaction__c]);
    }

    @IsTest
    static void testResolveCreateNew() {
        Zeffy_Review_Ticket__c ticket = new Zeffy_Review_Ticket__c(
            Status__c           = 'Pending Review',
            Zeffy_Contact_Id__c = 'zeffy-new-888',
            First_Name__c       = 'Maria',
            Last_Name__c        = 'Garcia',
            Email__c            = 'maria@test.com',
            Amount__c           = 50,
            Gift_Date__c        = Date.today(),
            Payment_Method__c   = 'Credit Card',
            Zeffy_Transaction_Id__c = 'ord-new-001'
        );
        insert ticket;

        Test.startTest();
        ZeffyDonationService.resolveCreateNew(ticket.Id, 'Reviewed and created');
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Contact WHERE Zeffy_Contact_Id__c = 'zeffy-new-888']);
        System.assertEquals(1, [SELECT COUNT() FROM Gift_Transaction__c WHERE Zeffy_Transaction_Id__c = 'ord-new-001']);
        Zeffy_Review_Ticket__c updated = [SELECT Status__c, Resolved_Contact__c FROM Zeffy_Review_Ticket__c WHERE Id = :ticket.Id];
        System.assertEquals('Resolved - New Contact', updated.Status__c);
        System.assertNotEquals(null, updated.Resolved_Contact__c);
    }

    @IsTest
    static void testResolveLinkExisting() {
        Contact donor = [SELECT Id FROM Contact WHERE Zeffy_Contact_Id__c = 'zeffy-known-001' LIMIT 1];
        Zeffy_Review_Ticket__c ticket = new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            Zeffy_Contact_Id__c     = 'zeffy-link-777',
            First_Name__c           = 'Jean',
            Last_Name__c            = 'Dupont',
            Amount__c               = 75,
            Gift_Date__c            = Date.today(),
            Zeffy_Transaction_Id__c = 'ord-link-001'
        );
        insert ticket;

        Test.startTest();
        ZeffyDonationService.resolveLinkExisting(ticket.Id, donor.Id, 'Linked to existing contact');
        Test.stopTest();

        System.assertEquals('zeffy-link-777', [SELECT Zeffy_Contact_Id__c FROM Contact WHERE Id = :donor.Id].Zeffy_Contact_Id__c);
        System.assertEquals(1, [SELECT COUNT() FROM Gift_Transaction__c WHERE Zeffy_Transaction_Id__c = 'ord-link-001']);
        System.assertEquals('Resolved - Linked', [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :ticket.Id].Status__c);
    }

    @IsTest
    static void testSkipTicket() {
        Zeffy_Review_Ticket__c ticket = new Zeffy_Review_Ticket__c(
            Status__c           = 'Pending Review',
            First_Name__c       = 'Test',
            Last_Name__c        = 'Skip',
            Amount__c           = 10,
            Zeffy_Transaction_Id__c = 'ord-skip-001'
        );
        insert ticket;

        Test.startTest();
        ZeffyDonationService.skipTicket(ticket.Id, 'Test donation — skip');
        Test.stopTest();

        System.assertEquals('Skipped', [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :ticket.Id].Status__c);
    }

    @IsTest
    static void testConfigService_saveAndLoad() {
        Test.startTest();
        ZeffyConfigService.saveConfig('new-api-key-12345', 'new-secret-xyz', true);
        Map<String, String> cfg = ZeffyConfigService.loadConfig();
        Test.stopTest();

        System.assertNotEquals(null, cfg);
        System.assertEquals('true', cfg.get('isConfigured'));
        System.assertEquals('true', cfg.get('isActive'));
        // Values should be masked
        System.assert(cfg.get('apiKey').contains('****'), 'API key should be masked');
    }

    @IsTest
    static void testEmailMatch_stampsZeffyId() {
        // Contact exists with same email but no Zeffy ID
        Account acct = new Account(Name = 'Email Match Test');
        insert acct;
        Contact c = new Contact(FirstName='Sophie', LastName='Test', Email='sophie@test.com', AccountId=acct.Id);
        insert c;

        String payload = buildPayload('zeffy-email-match-001', 'ord-email-001', false, null)
            .replace('"jean@test.com"', '"sophie@test.com"')
            .replace('"zeffy-email-match-001"', '"zeffy-email-match-001"');
        // Rebuild with sophie's email
        payload = '{"id":"evt-002","type":"payment.completed","version":"1",' +
                  '"dispatchedAt":"2026-09-14T10:00:00Z",' +
                  '"data":{"id":"ord-email-001","status":"paid","type":"donation",' +
                  '"amount":25,"currency":"CAD","paymentMethod":"CREDIT_CARD",' +
                  '"created":"2026-09-14T10:00:00Z",' +
                  '"isRecurring":false,"subscriptionId":null,' +
                  '"contact":{"id":"zeffy-email-match-001","firstName":"Sophie",' +
                  '"lastName":"Test","email":"sophie@test.com"},' +
                  '"campaign":null}}';
        setupRestContext(payload);

        Test.startTest();
        ZeffyWebhookReceiver.handleWebhook();
        Test.stopTest();

        // Should have matched by email and created a gift (not a ticket)
        System.assertEquals(1, [SELECT COUNT() FROM Gift_Transaction__c WHERE Zeffy_Transaction_Id__c = 'ord-email-001']);
        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'ord-email-001']);
        // Zeffy ID should have been stamped on the contact
        System.assertEquals('zeffy-email-match-001', [SELECT Zeffy_Contact_Id__c FROM Contact WHERE Id = :c.Id].Zeffy_Contact_Id__c);
    }

    @IsTest
    static void testGetTickets_returnsAll() {
        insert new Zeffy_Review_Ticket__c(
            Status__c='Pending Review', First_Name__c='A', Last_Name__c='B',
            Amount__c=10, Zeffy_Transaction_Id__c='ord-list-001'
        );

        Test.startTest();
        List<Zeffy_Review_Ticket__c> tickets = ZeffyDonationService.getTickets('All');
        Test.stopTest();

        System.assertEquals(1, tickets.size());
    }

    @IsTest
    static void testGetTicketDetail() {
        Zeffy_Review_Ticket__c t = new Zeffy_Review_Ticket__c(
            Status__c='Pending Review', First_Name__c='Detail', Last_Name__c='Test',
            Amount__c=200, Zeffy_Transaction_Id__c='ord-detail-001'
        );
        insert t;

        Test.startTest();
        Zeffy_Review_Ticket__c result = ZeffyDonationService.getTicketDetail(t.Id);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals('Pending Review', result.Status__c);
        System.assertEquals(200, result.Amount__c);
    }

    @IsTest
    static void testMalformedPayload_createsErrorTicket() {
        setupRestContext('{invalid json}}}');

        Test.startTest();
        ZeffyWebhookReceiver.handleWebhook();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        List<Zeffy_Review_Ticket__c> errors = [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Status__c = 'Error'];
        System.assertEquals(1, errors.size());
    }
}
