@isTest
private class ZeffyConnectDonationServiceTest {

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private static Account makePersonAccount(String fn, String ln, String email) {
        Id personRtId = [SELECT Id FROM RecordType WHERE SObjectType = 'Account'
                         AND DeveloperName = 'PersonAccount' LIMIT 1]?.Id;
        Account a = new Account(RecordTypeId = personRtId,
                                FirstName = fn, LastName = ln, PersonEmail = email);
        insert a;
        return a;
    }

    private static void linkIdentity(Id accountId, String zeffyId, String email) {
        insert new Zeffy_Identity__c(
            Account__c          = accountId,
            Zeffy_Contact_Id__c = zeffyId,
            Email__c            = email,
            Is_Primary__c       = true,
            First_Seen__c       = Date.today(),
            Source__c           = 'Webhook'
        );
    }

    private static String buildPayload(String txId, String email, String contactId) {
        return '{"id":"evt_t","type":"payment.completed","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
               '"data":{"id":"' + txId + '","status":"succeeded","type":"online",' +
               '"amount":5000,"eligible_amount":4000,' +
               '"currency":"cad","contact":"' + contactId + '",' +
               '"buyer":{"email":"' + email + '","first_name":"Test","last_name":"Donor",' +
               '"is_corporate":false,"company_name":null,' +
               '"address":{"line1":"1 Rue Test","city":"Montréal","state":"QC","postal_code":"H1A 1A1","country":"CA"}},' +
               '"payment_method":{"type":"card","brand":"visa","last4":"1234"},' +
               '"created":1737000000,"receipt_url":null,' +
               '"campaign_id":"form_ds","campaign_type":"donation_form","campaign_category":"donation",' +
               '"description":"Campagne DS","refund_status":"none","refunds":[],' +
               '"dispute":null,"fund":null,"discount":null,' +
               '"buyer_questions":[],"items":[],' +
               '"recurring":null}}';
    }

    private static String buildCorporatePayload(String txId, String contactId) {
        return '{"id":"evt_corp","type":"payment.completed","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
               '"data":{"id":"' + txId + '","status":"succeeded","type":"online",' +
               '"amount":100000,"eligible_amount":100000,' +
               '"currency":"cad","contact":"' + contactId + '",' +
               '"buyer":{"email":"corp@company.ca","first_name":null,"last_name":null,' +
               '"is_corporate":true,"company_name":"Corporation Test Inc.",' +
               '"address":null},' +
               '"payment_method":{"type":"ach","brand":null,"last4":null},' +
               '"created":1737000000,"receipt_url":null,' +
               '"campaign_id":null,"campaign_type":"donation_form","campaign_category":"donation",' +
               '"description":null,"refund_status":"none","refunds":[],' +
               '"dispute":null,"fund":{"id":"f1","code":"GEN",' +
               '"name":{"EN":"General Fund","FR":"Fonds général","ES":null}},' +
               '"discount":{"code":"CORP10","amount":500},' +
               '"buyer_questions":[{"question":"Q1","type":"text","answer":"A1"}],' +
               '"items":[{"id":"i1","type":"donation","amount":100000,"rate_title":"Don corporatif",' +
               '"contact_id":"ci1","questions":[],' +
               '"tribute":{"type":"in_honor_of","honouree_name":"Jean Paul"}}],' +
               '"recurring":null}}';
    }

    @TestSetup
    static void setup() {
        insert new Zeffy_Config__c(
            Name              = 'default',
            Webhook_Secret__c = 'test_secret',
            Is_Active__c      = true
        );
        insert new Campaign(
            Name             = 'Campagne DS',
            IsActive         = true,
            Zeffy_Form_Id__c = 'form_ds'
        );
    }

    // ─── MISSING_TX_ID ────────────────────────────────────────────────────────

    @isTest
    static void testMissingTransactionId() {
        String payload =
            '{"id":"evt_x","type":"payment.completed","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"","status":"succeeded","amount":5000,"eligible_amount":5000,' +
            '"currency":"cad","contact":"zeffy_noid",' +
            '"buyer":{"email":"noid@test.ca","first_name":"No","last_name":"Id",' +
            '"is_corporate":false,"company_name":null,"address":null},' +
            '"payment_method":null,"created":null,' +
            '"campaign_id":null,"campaign_type":null,"campaign_category":null,"description":null,' +
            '"refund_status":"none","refunds":[],"dispute":null,"fund":null,"discount":null,' +
            '"buyer_questions":[],"items":[],"recurring":null}}';

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult result =
            ZeffyConnectDonationService.processWebhookWithResult(payload);
        Test.stopTest();

        System.assertEquals('MISSING_TX_ID', result.status);
        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Review_Ticket__c]);
    }

    // ─── Corporate donor auto-match via Zeffy_Identity → GiftType=Organizational

    @isTest
    static void testCorporateDonorAutoMatchOrgGiftType() {
        Account corp = new Account(
            Name  = 'Corporation Test Inc.',
            Phone = '5141234567'
        );
        insert corp;
        linkIdentity(corp.Id, 'zeffy_corp_001', 'corp@company.ca');

        Test.startTest();
        ZeffyConnectDonationService.processWebhook(buildCorporatePayload('txn_corp_001', 'zeffy_corp_001'));
        Test.stopTest();

        List<GiftTransaction> gifts = [SELECT GiftType, Zeffy_Transaction_Id__c FROM GiftTransaction];
        System.assertEquals(1, gifts.size(), 'Corporate auto-match should create GiftTransaction');
        System.assertEquals('Organizational', gifts[0].GiftType);
    }

    // ─── createPendingTask when Auto_Task_Enabled = true ─────────────────────

    @isTest
    static void testCreatePendingTaskEnabled() {
        // Update config to enable auto task
        Zeffy_Config__c cfg = [SELECT Id FROM Zeffy_Config__c LIMIT 1];
        cfg.Auto_Task_Enabled__c = true;
        cfg.Task_Due_Days__c     = 2;
        cfg.Task_Owner_Id__c     = UserInfo.getUserId();
        update cfg;

        Test.startTest();
        ZeffyConnectDonationService.processWebhook(buildPayload('txn_task_001', 'task@test.ca', 'zeffy_task_001'));
        Test.stopTest();

        List<Zeffy_Review_Ticket__c> tickets = [SELECT Id FROM Zeffy_Review_Ticket__c];
        System.assertEquals(1, tickets.size());
        List<Task> tasks = [SELECT Id, Subject FROM Task WHERE WhatId = :tickets[0].Id];
        System.assertEquals(1, tasks.size(), 'Should create auto-task');
        System.assert(tasks[0].Subject.contains('Review pending donation'));
    }

    // ─── createPendingTask — company name donor (no first/last name) ──────────

    @isTest
    static void testCreatePendingTaskCompanyName() {
        Zeffy_Config__c cfg = [SELECT Id FROM Zeffy_Config__c LIMIT 1];
        cfg.Auto_Task_Enabled__c = true;
        cfg.Task_Due_Days__c     = 2;
        cfg.Task_Owner_Id__c     = UserInfo.getUserId();
        update cfg;

        String corpPayload =
            '{"id":"evt_cn","type":"payment.completed","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"txn_cn_001","status":"succeeded","type":"online",' +
            '"amount":10000,"eligible_amount":10000,"currency":"cad","contact":"zeffy_cn_001",' +
            '"buyer":{"email":"cn@corp.ca","first_name":null,"last_name":null,' +
            '"is_corporate":true,"company_name":"Corp TaskName Inc.","address":null},' +
            '"payment_method":null,"created":1737000000,"receipt_url":null,' +
            '"campaign_id":null,"campaign_type":null,"campaign_category":null,"description":null,' +
            '"refund_status":"none","refunds":[],"dispute":null,"fund":null,"discount":null,' +
            '"buyer_questions":[],"items":[],"recurring":null}}';

        Test.startTest();
        ZeffyConnectDonationService.processWebhook(corpPayload);
        Test.stopTest();

        List<Zeffy_Review_Ticket__c> tickets = [SELECT Id FROM Zeffy_Review_Ticket__c];
        System.assertEquals(1, tickets.size());
        Task t = [SELECT Subject FROM Task WHERE WhatId = :tickets[0].Id LIMIT 1];
        System.assert(t.Subject.contains('Corp TaskName Inc.'), 'Company name should appear in task subject');
    }

    // ─── Duplicate from Ticket side (not GiftTransaction) ─────────────────────

    @isTest
    static void testDuplicateFromTicketSide() {
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            Email__c                = 'dup@test.ca',
            Amount__c               = 50.00,
            Transaction_Status__c   = 'succeeded',
            Zeffy_Transaction_Id__c = 'txn_dup_ticket'
        );

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult result =
            ZeffyConnectDonationService.processWebhookWithResult(
                buildPayload('txn_dup_ticket', 'dup@test.ca', 'zeffy_dup_ticket'));
        Test.stopTest();

        System.assertEquals('DUPLICATE_SKIPPED', result.status);
        // Still only 1 ticket (the original)
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Review_Ticket__c]);
    }

    // ─── createGiftFromTicket — auto-creates Campaign when form_id not in SF ──

    @isTest
    static void testResolveCreateNewAutoCampaignCreation() {
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Jean',
            Last_Name__c            = 'Dupont',
            Email__c                = 'jean@test.ca',
            Amount__c               = 100.00,
            Eligible_Amount__c      = 100.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Contact_Id__c     = 'zeffy_autocampaign',
            Zeffy_Transaction_Id__c = 'txn_autocampaign_001',
            Form_Id__c              = 'new_form_not_in_sf',
            Form_Name__c            = 'Nouvelle Campagne Test'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.resolveCreateNew(ticket.Id, 'individual', 'Campaign auto-créée');
        Test.stopTest();

        // Should have auto-created the Campaign
        List<Campaign> camps = [SELECT Name, Zeffy_Form_Id__c FROM Campaign
                                WHERE Zeffy_Form_Id__c = 'new_form_not_in_sf'];
        System.assertEquals(1, camps.size(), 'Campaign should be auto-created from form_id');
        System.assertEquals('Nouvelle Campagne Test', camps[0].Name);

        // GiftTransaction should link to the new Campaign
        List<GiftTransaction> gifts = [SELECT CampaignId FROM GiftTransaction];
        System.assertEquals(1, gifts.size());
        System.assertEquals(camps[0].Id, gifts[0].CampaignId);
    }

    // ─── createGiftFromTicket — form_id present but form_name blank → no campaign ──

    @isTest
    static void testResolveCreateNewFormIdNullFormName() {
        // When Form_Name__c is null, no Campaign is auto-created (code requires non-blank form_name)
        // Gift should still succeed, just with no CampaignId
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Anna',
            Last_Name__c            = 'Test',
            Amount__c               = 25.00,
            Eligible_Amount__c      = 25.00,
            Payment_Method__c       = 'Check',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Transaction_Id__c = 'txn_nonull_001',
            Form_Id__c              = 'form_no_name',
            Form_Name__c            = null
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.resolveCreateNew(ticket.Id, 'individual', null);
        Test.stopTest();

        // No campaign created (form_name is blank) — but gift IS created
        System.assertEquals(0, [SELECT COUNT() FROM Campaign WHERE Zeffy_Form_Id__c = 'form_no_name'],
            'No Campaign should be created when Form_Name__c is blank');
        System.assertEquals(1, [SELECT COUNT() FROM GiftTransaction], 'Gift should still be created');
    }

    // ─── createGiftFromTicket — recurring ticket creates GiftCommitment ───────

    @isTest
    static void testResolveCreateNewRecurringTicketCreatesCommitment() {
        insert new Zeffy_Review_Ticket__c(
            Status__c                  = 'Pending Review',
            First_Name__c              = 'Rec',
            Last_Name__c               = 'Ticket',
            Email__c                   = 'rect@test.ca',
            Amount__c                  = 25.00,
            Eligible_Amount__c         = 25.00,
            Payment_Method__c          = 'Credit Card',
            Payment_Type__c            = 'Donation',
            Gift_Date__c               = Date.today(),
            Zeffy_Contact_Id__c        = 'zeffy_rectkt',
            Zeffy_Transaction_Id__c    = 'txn_rectkt_001',
            Is_Recurring__c            = true,
            Zeffy_Subscription_Id__c   = 'sub_rectkt_001',
            Subscription_Frequency__c  = 'monthly'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.resolveCreateNew(ticket.Id, 'individual', null);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM GiftTransaction]);
        List<GiftCommitment> cmts = [SELECT Zeffy_Subscription_Id__c FROM GiftCommitment];
        System.assertEquals(1, cmts.size(), 'GiftCommitment should be created for recurring ticket');
        System.assertEquals('sub_rectkt_001', cmts[0].Zeffy_Subscription_Id__c);
    }

    // ─── createGiftFromTicket — second resolve same sub_id → no duplicate ─────

    @isTest
    static void testResolveCreateNewRecurringNoDuplicateCommitment() {
        Account donor1 = makePersonAccount('A', 'One', 'a.one@test.ca');
        Account donor2 = makePersonAccount('B', 'Two', 'b.two@test.ca');

        Zeffy_Review_Ticket__c tkt1 = new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', First_Name__c = 'A', Last_Name__c = 'One',
            Email__c = 'a.one@test.ca', Amount__c = 25.00, Eligible_Amount__c = 25.00,
            Payment_Method__c = 'Credit Card', Payment_Type__c = 'Donation',
            Gift_Date__c = Date.today(), Zeffy_Transaction_Id__c = 'txn_sub_dup_1',
            Is_Recurring__c = true, Zeffy_Subscription_Id__c = 'sub_dup_shared'
        );
        Zeffy_Review_Ticket__c tkt2 = new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', First_Name__c = 'B', Last_Name__c = 'Two',
            Email__c = 'b.two@test.ca', Amount__c = 25.00, Eligible_Amount__c = 25.00,
            Payment_Method__c = 'Credit Card', Payment_Type__c = 'Donation',
            Gift_Date__c = Date.today(), Zeffy_Transaction_Id__c = 'txn_sub_dup_2',
            Is_Recurring__c = true, Zeffy_Subscription_Id__c = 'sub_dup_shared'
        );
        insert new List<Zeffy_Review_Ticket__c>{ tkt1, tkt2 };

        Test.startTest();
        ZeffyConnectDonationService.resolveLinkExisting(tkt1.Id, donor1.Id, null, null, false, false, false);
        ZeffyConnectDonationService.resolveLinkExisting(tkt2.Id, donor2.Id, null, null, false, false, false);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM GiftCommitment WHERE Zeffy_Subscription_Id__c = 'sub_dup_shared'],
            'Second resolve should not create duplicate GiftCommitment');
    }

    // ─── resolveLinkExisting — the name of an existing account is never changed ──

    @isTest
    static void testResolveLinkExistingUpdateNames() {
        Account existing = makePersonAccount('OldFirst', 'OldLast', 'oldname@test.ca');

        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'NewFirst',
            Last_Name__c            = 'NewLast',
            Email__c                = 'oldname@test.ca',
            Amount__c               = 50.00,
            Eligible_Amount__c      = 50.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Contact_Id__c     = 'zeffy_nameupd_001',
            Zeffy_Transaction_Id__c = 'txn_nameupd_001'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.resolveLinkExisting(
            ticket.Id, existing.Id, null, null, false, true, true
        );
        Test.stopTest();

        Account updated = [SELECT FirstName, LastName FROM Account WHERE Id = :existing.Id];
        System.assertEquals('OldFirst', updated.FirstName, 'An existing account keeps its name');
        System.assertEquals('OldLast',  updated.LastName,  'An existing account keeps its name');
    }

    // ─── @TestVisible: failAuditLog catch ─────────────────────────────────────

    @isTest
    static void testAuditLogCatchPath() {
        insert new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', Email__c = 'audlog@test.ca',
            Amount__c = 10.00, Zeffy_Transaction_Id__c = 'txn_audlog'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        ZeffyConnectDonationService.failAuditLog = true;
        Test.startTest();
        ZeffyConnectDonationService.closeTicket(ticket.Id, 'test'); // calls createAuditLog internally
        Test.stopTest();
        ZeffyConnectDonationService.failAuditLog = false;

        // closeTicket should succeed even when audit log fails
        System.assertEquals('Closed', [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :ticket.Id].Status__c);
    }

    // ─── @TestVisible: failCommitmentInsert catch ─────────────────────────────

    @isTest
    static void testCommitmentInsertCatchPath() {
        Account donor = makePersonAccount('Cmt', 'Catch', 'cmt@test.ca');
        linkIdentity(donor.Id, 'zeffy_cmt_catch', 'cmt@test.ca');

        String recurringPayload =
            '{"id":"evt_cmtcatch","type":"payment.completed","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"txn_cmt_catch","status":"succeeded","type":"online",' +
            '"amount":1500,"eligible_amount":1500,"currency":"cad","contact":"zeffy_cmt_catch",' +
            '"buyer":{"email":"cmt@test.ca","first_name":"Cmt","last_name":"Catch",' +
            '"is_corporate":false,"company_name":null,"address":null},' +
            '"payment_method":{"type":"card","brand":"visa","last4":"9999"},' +
            '"created":1737000000,"receipt_url":null,' +
            '"campaign_id":null,"campaign_type":null,"campaign_category":null,"description":null,' +
            '"refund_status":"none","refunds":[],"dispute":null,"fund":null,"discount":null,' +
            '"buyer_questions":[],"items":[],' +
            '"recurring":{"is_recurring":true,"status":"active","interval":"monthly",' +
            '"subscription_id":"sub_catch_001","current_period_start":1737000000,"current_period_end":1739678400}}}';

        ZeffyConnectDonationService.failCommitmentInsert = true;
        Test.startTest();
        ZeffyConnectDonationService.processWebhook(recurringPayload);
        Test.stopTest();
        ZeffyConnectDonationService.failCommitmentInsert = false;

        // GiftTransaction should exist even though GiftCommitment failed
        System.assertEquals(1, [SELECT COUNT() FROM GiftTransaction]);
        System.assertEquals(0, [SELECT COUNT() FROM GiftCommitment],
            'GiftCommitment should not exist when insert is forced to fail');
    }

    // ─── findAccountMatches — by email ────────────────────────────────────────

    @isTest
    static void testFindAccountMatchesByEmail() {
        Account existing = makePersonAccount('Match', 'ByEmail', 'matchme@test.ca');
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Match',
            Last_Name__c            = 'ByEmail',
            Email__c                = 'matchme@test.ca',
            Amount__c               = 50.00,
            Zeffy_Transaction_Id__c = 'txn_matchemail'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        List<ZeffyConnectDonationService.AccountMatch> matches =
            ZeffyConnectDonationService.findAccountMatches(ticket.Id);
        Test.stopTest();

        System.assertEquals(1, matches.size());
        System.assertEquals(existing.Id, matches[0].id);
        System.assert(matches[0].score >= 50, 'Email exact match should score >= 50');
    }

    // ─── findAccountMatches — by last name ────────────────────────────────────

    @isTest
    static void testFindAccountMatchesByName() {
        Account existing = makePersonAccount('Jean', 'Unique', 'jean.unique@test.ca');
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Jean',
            Last_Name__c            = 'Unique',
            Email__c                = 'nobody@test.ca',
            Amount__c               = 50.00,
            Zeffy_Transaction_Id__c = 'txn_matchname'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        List<ZeffyConnectDonationService.AccountMatch> matches =
            ZeffyConnectDonationService.findAccountMatches(ticket.Id);
        Test.stopTest();

        System.assertEquals(1, matches.size());
        System.assertEquals(existing.Id, matches[0].id);
    }

    // ─── findAccountMatches — company name match ──────────────────────────────

    @isTest
    static void testFindAccountMatchesByCompanyName() {
        Account company = new Account(Name = 'Org Unique Name');
        insert company;
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            Company_Name__c         = 'Org Unique Name',
            Amount__c               = 500.00,
            Zeffy_Transaction_Id__c = 'txn_matchcorp'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        List<ZeffyConnectDonationService.AccountMatch> matches =
            ZeffyConnectDonationService.findAccountMatches(ticket.Id);
        Test.stopTest();

        Boolean found = false;
        for (ZeffyConnectDonationService.AccountMatch m : matches) {
            if (m.id == company.Id) { found = true; break; }
        }
        System.assertEquals(true, found, 'Company name match should find the Account');
    }

    // ─── findAccountMatches — business account, name split by Zeffy ───────────

    @isTest
    static void testFindAccountMatchesBusinessFullName() {
        Account org = new Account(Name = 'Heron Family Foundation');
        insert org;
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Heron Family',
            Last_Name__c            = 'Foundation',
            Amount__c               = 250.00,
            Zeffy_Transaction_Id__c = 'txn_matchbizfull'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        List<ZeffyConnectDonationService.AccountMatch> matches =
            ZeffyConnectDonationService.findAccountMatches(ticket.Id);
        Test.stopTest();

        ZeffyConnectDonationService.AccountMatch hit;
        for (ZeffyConnectDonationService.AccountMatch m : matches) {
            if (m.id == org.Id) hit = m;
        }
        System.assertNotEquals(null, hit, 'Business account should be found');
        System.assert(hit.score >= 80, 'Exact full-name match on a business account should be a strong match: ' + hit.score);
    }

    // ─── findAccountMatches — no match → empty list ───────────────────────────

    @isTest
    static void testFindAccountMatchesEmpty() {
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Nobody',
            Last_Name__c            = 'Exists',
            Email__c                = 'zzznotfound99@test.ca',
            Amount__c               = 50.00,
            Zeffy_Transaction_Id__c = 'txn_nomatch'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        List<ZeffyConnectDonationService.AccountMatch> matches =
            ZeffyConnectDonationService.findAccountMatches(ticket.Id);
        Test.stopTest();

        System.assertEquals(0, matches.size());
    }

    // ─── getDashboardStats ────────────────────────────────────────────────────

    @isTest
    static void testGetDashboardStats() {
        Account donor = makePersonAccount('Dash', 'Stats', 'dash@test.ca');
        linkIdentity(donor.Id, 'zeffy_dash', 'dash@test.ca');
        ZeffyConnectDonationService.processWebhook(buildPayload('txn_dash_001', 'dash@test.ca', 'zeffy_dash'));

        insert new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', Email__c = 'pend@test.ca',
            Amount__c = 50.00, Zeffy_Transaction_Id__c = 'txn_dash_pending'
        );

        Test.startTest();
        Map<String, Object> stats = ZeffyConnectDonationService.getDashboardStats();
        Test.stopTest();

        System.assertNotEquals(null, stats);
        System.assertNotEquals(null, stats.get('total'));
        System.assertNotEquals(null, stats.get('byStatus'));
        System.assertNotEquals(null, stats.get('autoProcessed'));
        System.assertNotEquals(null, stats.get('manualResolved'));
        System.assertNotEquals(null, stats.get('totalAmount'));
        System.assertNotEquals(null, stats.get('byCampaign'));
        System.assertNotEquals(null, stats.get('weekly'));
        System.assertNotEquals(null, stats.get('duplicateContactIds'));
        System.assertNotEquals(null, stats.get('recentResolutions'));

        // Weekly series counts tickets (created / closed), not money
        Integer created = 0;
        for (Object o : (List<Object>) stats.get('weekly')) {
            Map<String, Object> w = (Map<String, Object>) o;
            created += (Integer) w.get('created');
            System.assertNotEquals(null, w.get('closed'));
        }
        System.assertEquals([SELECT COUNT() FROM Zeffy_Review_Ticket__c], created);
    }

    // ─── getCampaignMappings / saveCampaignMapping / searchCampaigns ──────────

    @isTest
    static void testCampaignMappingMethods() {
        Campaign c = new Campaign(Name = 'Mapping Test', IsActive = true, Zeffy_Form_Id__c = 'form_map');
        insert c;
        grantSettingsAccess();   // saveCampaignMapping requires the Settings permission

        Test.startTest();
        // getCampaignMappings
        List<Map<String, Object>> mappings = ZeffyConnectDonationService.getCampaignMappings();
        System.assert(mappings.size() >= 1, 'Should return at least 1 campaign with form_id');

        // saveCampaignMapping — update the Zeffy form ID (custom permission counts only inside runAs)
        System.runAs(new User(Id = UserInfo.getUserId())) {
            ZeffyConnectDonationService.saveCampaignMapping(c.Id, 'form_map_updated', true);
        }
        Campaign updated = [SELECT Zeffy_Form_Id__c, Is_Zeffy_Managed__c FROM Campaign WHERE Id = :c.Id];
        System.assertEquals('form_map_updated', updated.Zeffy_Form_Id__c);
        System.assertEquals(true, updated.Is_Zeffy_Managed__c);

        // saveCampaignMapping — clear formId (null passed)
        System.runAs(new User(Id = UserInfo.getUserId())) {
            ZeffyConnectDonationService.saveCampaignMapping(c.Id, null, false);
        }
        Campaign cleared = [SELECT Zeffy_Form_Id__c FROM Campaign WHERE Id = :c.Id];
        System.assertEquals(null, cleared.Zeffy_Form_Id__c, 'Blank formId should be null');

        // searchCampaigns
        List<Map<String, Object>> found = ZeffyConnectDonationService.searchCampaigns('Mapping');
        System.assertEquals(1, found.size());
        List<Map<String, Object>> all = ZeffyConnectDonationService.searchCampaigns('');
        System.assert(all.size() >= 1);
        Test.stopTest();
    }

    // ─── undoResolution ───────────────────────────────────────────────────────

    @isTest
    static void testUndoResolution() {
        Account donor = makePersonAccount('Undo', 'Me', 'undo@test.ca');
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Undo',
            Last_Name__c            = 'Me',
            Email__c                = 'undo@test.ca',
            Amount__c               = 75.00,
            Eligible_Amount__c      = 75.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Contact_Id__c     = 'zeffy_undo_001',
            Zeffy_Transaction_Id__c = 'txn_undo_001'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];
        ZeffyConnectDonationService.resolveLinkExisting(ticket.Id, donor.Id, null, null, false, false, false);

        Zeffy_Review_Ticket__c resolved = [SELECT Resolved_Gift__c FROM Zeffy_Review_Ticket__c WHERE Id = :ticket.Id];
        System.assertNotEquals(null, resolved.Resolved_Gift__c);

        Test.startTest();
        ZeffyConnectDonationService.undoResolution(ticket.Id);
        Test.stopTest();

        Zeffy_Review_Ticket__c reopened = [
            SELECT Status__c, Resolved_Account__c, Resolved_Gift__c
            FROM Zeffy_Review_Ticket__c WHERE Id = :ticket.Id
        ];
        System.assertEquals('Pending Review', reopened.Status__c, 'Ticket should be reopened');
        System.assertEquals(null, reopened.Resolved_Account__c);
        System.assertEquals(null, reopened.Resolved_Gift__c);
        System.assertEquals(0, [SELECT COUNT() FROM GiftTransaction], 'GiftTransaction should be deleted on undo');
    }

    // ─── undoResolution — auto-created campaign is removed, summary returned ──

    @isTest
    static void testUndoResolutionRemovesAutoCampaign() {
        Account donor = makePersonAccount('Camp', 'Undo', 'campundo@test.ca');
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Camp',
            Last_Name__c            = 'Undo',
            Email__c                = 'campundo@test.ca',
            Amount__c               = 40.00,
            Eligible_Amount__c      = 40.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Form_Id__c              = 'form_undo_camp',
            Form_Name__c            = 'Undo Campaign Form',
            Zeffy_Transaction_Id__c = 'txn_undo_camp'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];
        ZeffyConnectDonationService.resolveLinkExisting(ticket.Id, donor.Id, null, null, false, false, false);
        System.assertEquals(1, [SELECT COUNT() FROM Campaign WHERE Zeffy_Form_Id__c = 'form_undo_camp'],
            'Resolution should auto-create the Zeffy campaign');

        Test.startTest();
        Map<String, String> summary = ZeffyConnectDonationService.undoResolution(ticket.Id);
        Test.stopTest();

        System.assertEquals('true', summary.get('giftDeleted'));
        System.assertEquals('Undo Campaign Form', summary.get('campaignDeleted'));
        System.assertEquals('Camp Undo', summary.get('accountKept'));
        System.assertEquals(0, [SELECT COUNT() FROM Campaign WHERE Zeffy_Form_Id__c = 'form_undo_camp'],
            'Auto-created campaign nothing else uses should be deleted on undo');
        System.assertEquals(1, [SELECT COUNT() FROM Account WHERE Id = :donor.Id], 'Account is never deleted');
    }

    @isTest
    static void testUndoResolutionKeepsStaffCampaign() {
        Account donor = makePersonAccount('Staff', 'Camp', 'staffcamp@test.ca');
        insert new Campaign(Name = 'Staff Campaign', IsActive = true, Zeffy_Form_Id__c = 'form_staff_camp');
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Staff',
            Last_Name__c            = 'Camp',
            Email__c                = 'staffcamp@test.ca',
            Amount__c               = 25.00,
            Eligible_Amount__c      = 25.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Form_Id__c              = 'form_staff_camp',
            Form_Name__c            = 'Staff Campaign',
            Zeffy_Transaction_Id__c = 'txn_staff_camp'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];
        ZeffyConnectDonationService.resolveLinkExisting(ticket.Id, donor.Id, null, null, false, false, false);

        Test.startTest();
        Map<String, String> summary = ZeffyConnectDonationService.undoResolution(ticket.Id);
        Test.stopTest();

        System.assert(!summary.containsKey('campaignDeleted'), 'A campaign made by staff is never deleted');
        System.assertEquals(1, [SELECT COUNT() FROM Campaign WHERE Zeffy_Form_Id__c = 'form_staff_camp']);
    }

    @isTest
    static void testReopenClosedTicket() {
        insert new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', Email__c = 'reopen@test.ca', Amount__c = 10, Zeffy_Transaction_Id__c = 'txn_reopen'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];
        ZeffyConnectDonationService.closeTicket(ticket.Id, 'Closed by mistake');

        Test.startTest();
        ZeffyConnectDonationService.moveTicketToReview(ticket.Id, null);
        Test.stopTest();

        Zeffy_Review_Ticket__c t = [SELECT Status__c, Resolved_At__c, Resolution_Notes__c FROM Zeffy_Review_Ticket__c WHERE Id = :ticket.Id];
        System.assertEquals('Pending Review', t.Status__c);
        System.assertEquals(null, t.Resolved_At__c);
        System.assertEquals('Closed by mistake', t.Resolution_Notes__c, 'Close reason stays visible for the next reviewer');
    }

    // ─── addReviewNote — Keep Pending with a note ─────────────────────────────

    @isTest
    static void testAddReviewNote() {
        insert new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', Email__c = 'note@test.ca', Amount__c = 10, Zeffy_Transaction_Id__c = 'txn_note'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.addReviewNote(ticket.Id, 'Waiting for the donor to call back');
        ZeffyConnectDonationService.addReviewNote(ticket.Id, 'Second note');
        ZeffyConnectDonationService.addReviewNote(ticket.Id, '   '); // blank → ignored
        Test.stopTest();

        Zeffy_Review_Ticket__c t = [SELECT Status__c, Resolution_Notes__c FROM Zeffy_Review_Ticket__c WHERE Id = :ticket.Id];
        System.assertEquals('Pending Review', t.Status__c, 'Ticket stays pending');
        System.assert(t.Resolution_Notes__c.contains('Waiting for the donor to call back'));
        System.assert(t.Resolution_Notes__c.contains('Second note'));
        System.assertEquals(2, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Ticket__c = :ticket.Id AND Action__c = 'Note Added']);
    }

    @isTest
    static void testAddReviewNoteRejectsResolved() {
        insert new Zeffy_Review_Ticket__c(
            Status__c = 'Closed', Email__c = 'note2@test.ca', Amount__c = 10, Zeffy_Transaction_Id__c = 'txn_note2'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];
        Boolean thrown = false;
        Test.startTest();
        try {
            ZeffyConnectDonationService.addReviewNote(ticket.Id, 'Too late');
        } catch (AuraHandledException e) {
            thrown = true;
        }
        Test.stopTest();
        System.assert(thrown, 'Notes are only for Pending Review tickets');
    }

    // ─── undoResolution — no gift to delete ───────────────────────────────────

    @isTest
    static void testUndoResolutionNoGift() {
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Resolved - Linked',
            Email__c                = 'noundo@test.ca',
            Amount__c               = 10.00,
            Zeffy_Transaction_Id__c = 'txn_noundo',
            Resolved_Gift__c        = null
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.undoResolution(ticket.Id); // Should not throw
        Test.stopTest();

        System.assertEquals('Pending Review',
            [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :ticket.Id].Status__c);
    }

    // ─── getAuditLog — blank search ───────────────────────────────────────────

    @isTest
    static void testGetAuditLogBlank() {
        // Ticket__c is required on Zeffy_Connect_Audit_Log__c
        insert new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', Amount__c = 10.00, Zeffy_Transaction_Id__c = 'txn_al_blank'
        );
        Id ticketId = [SELECT Id FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_al_blank' LIMIT 1].Id;

        insert new Zeffy_Connect_Audit_Log__c(
            Ticket__c       = ticketId,
            Action__c       = 'Closed',
            Performed_At__c = DateTime.now()
        );

        Test.startTest();
        List<Zeffy_Connect_Audit_Log__c> logs = ZeffyConnectDonationService.getAuditLog(null);
        Test.stopTest();

        System.assertEquals(1, logs.size());
    }

    // ─── getAuditLog — with search term ──────────────────────────────────────

    @isTest
    static void testGetAuditLogWithSearch() {
        insert new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', Amount__c = 10.00, Zeffy_Transaction_Id__c = 'txn_al_search'
        );
        Id ticketId = [SELECT Id FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_al_search' LIMIT 1].Id;

        insert new Zeffy_Connect_Audit_Log__c(
            Ticket__c       = ticketId,
            Action__c       = 'Resolved - Linked',
            Performed_At__c = DateTime.now()
        );

        Test.startTest();
        List<Zeffy_Connect_Audit_Log__c> found    = ZeffyConnectDonationService.getAuditLog('Resolved');
        List<Zeffy_Connect_Audit_Log__c> notfound = ZeffyConnectDonationService.getAuditLog('ZZNOTFOUND999');
        Test.stopTest();

        System.assertNotEquals(null, found);
        System.assertNotEquals(null, notfound);
    }

    // ─── getTicketDetail ──────────────────────────────────────────────────────

    @isTest
    static void testGetTicketDetail() {
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Detail',
            Last_Name__c            = 'Test',
            Email__c                = 'detail@test.ca',
            Amount__c               = 99.00,
            Eligible_Amount__c      = 99.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Transaction_Id__c = 'txn_detail_001'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        Zeffy_Review_Ticket__c detail = ZeffyConnectDonationService.getTicketDetail(ticket.Id);
        Test.stopTest();

        System.assertNotEquals(null, detail);
        System.assertEquals('detail@test.ca', detail.Email__c);
        System.assertEquals(99.00, detail.Amount__c);
    }

    // ─── getDonationHistory — blank search ────────────────────────────────────

    @isTest
    static void testGetDonationHistoryBlank() {
        Account donor = makePersonAccount('Hist', 'Blank', 'hist@test.ca');
        linkIdentity(donor.Id, 'zeffy_hist', 'hist@test.ca');
        ZeffyConnectDonationService.processWebhook(buildPayload('txn_hist_001', 'hist@test.ca', 'zeffy_hist'));

        Test.startTest();
        List<ZeffyConnectDonationService.DonationHistoryRow> rows =
            ZeffyConnectDonationService.getDonationHistory(null);
        Test.stopTest();

        System.assertEquals(1, rows.size());
        System.assertEquals('txn_hist_001', rows[0].ZeffyTransactionId);
        System.assertEquals(false, rows[0].IsManual, 'Auto-processed gift should have IsManual=false');
    }

    // ─── getDonationHistory — with search term ────────────────────────────────

    @isTest
    static void testGetDonationHistoryWithSearch() {
        Account donor = makePersonAccount('SearchHist', 'Test', 'searchhist@test.ca');
        linkIdentity(donor.Id, 'zeffy_searchhist', 'searchhist@test.ca');
        ZeffyConnectDonationService.processWebhook(
            buildPayload('txn_srchist_001', 'searchhist@test.ca', 'zeffy_searchhist'));

        Test.startTest();
        List<ZeffyConnectDonationService.DonationHistoryRow> rows =
            ZeffyConnectDonationService.getDonationHistory('txn_srchist');
        List<ZeffyConnectDonationService.DonationHistoryRow> noRows =
            ZeffyConnectDonationService.getDonationHistory('ZZZNOTFOUND999');
        Test.stopTest();

        System.assertEquals(1, rows.size());
        System.assertEquals(0, noRows.size());
    }

    // ─── getDonationHistory — undone resolution shows, re-link to same donor hides it ──

    @isTest
    static void testGetDonationHistoryUndoneSameDonor() {
        Account donor = makePersonAccount('Undone', 'Same', 'undone.same@test.ca');
        insert new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', First_Name__c = 'Undone', Last_Name__c = 'Same',
            Amount__c = 50.00, Eligible_Amount__c = 50.00,
            Payment_Method__c = 'Credit Card', Payment_Type__c = 'Donation',
            Gift_Date__c = Date.today(), Zeffy_Transaction_Id__c = 'txn_undone_same'
        );
        Id tktId = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1].Id;
        ZeffyConnectDonationService.resolveLinkExisting(tktId, donor.Id, null, null, false, false, false);
        ZeffyConnectDonationService.undoResolution(tktId);

        Test.startTest();
        List<ZeffyConnectDonationService.DonationHistoryRow> afterUndo =
            ZeffyConnectDonationService.getDonationHistory(null);
        List<ZeffyConnectDonationService.DonationHistoryRow> searched =
            ZeffyConnectDonationService.getDonationHistory('undone same');
        List<ZeffyConnectDonationService.DonationHistoryRow> missed =
            ZeffyConnectDonationService.getDonationHistory('ZZZNOTFOUND999');
        ZeffyConnectDonationService.resolveLinkExisting(tktId, donor.Id, null, null, false, false, false);
        List<ZeffyConnectDonationService.DonationHistoryRow> afterRelink =
            ZeffyConnectDonationService.getDonationHistory(null);
        Test.stopTest();

        System.assertEquals(1, afterUndo.size(), 'Undone resolution should stay visible in History');
        System.assertEquals(true, afterUndo[0].IsUndone);
        System.assertEquals('txn_undone_same', afterUndo[0].ZeffyTransactionId);
        System.assertEquals(50.00, afterUndo[0].Amount);
        System.assertNotEquals(null, afterUndo[0].UndoneAt);
        System.assertEquals(1, searched.size(), 'Search by donor name should find the undone row');
        System.assertEquals(0, missed.size());
        System.assertEquals(1, afterRelink.size(), 'Re-link to same donor replaces the undone row');
        System.assertEquals(false, afterRelink[0].IsUndone);
    }

    @isTest
    static void testGetDonationHistoryUndoneOtherDonorKept() {
        Account first  = makePersonAccount('Undone', 'First',  'undone.first@test.ca');
        Account second = makePersonAccount('Undone', 'Second', 'undone.second@test.ca');
        insert new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', First_Name__c = 'Undone', Last_Name__c = 'Other',
            Amount__c = 20.00, Eligible_Amount__c = 20.00,
            Payment_Method__c = 'Credit Card', Payment_Type__c = 'Donation',
            Gift_Date__c = Date.today(), Zeffy_Transaction_Id__c = 'txn_undone_other'
        );
        Id tktId = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1].Id;
        ZeffyConnectDonationService.resolveLinkExisting(tktId, first.Id, null, null, false, false, false);
        ZeffyConnectDonationService.undoResolution(tktId);

        Test.startTest();
        ZeffyConnectDonationService.resolveLinkExisting(tktId, second.Id, null, null, false, false, false);
        List<ZeffyConnectDonationService.DonationHistoryRow> rows =
            ZeffyConnectDonationService.getDonationHistory(null);
        Test.stopTest();

        System.assertEquals(2, rows.size(), 'Live gift for second donor + undone row for first donor');
        Integer undone = 0;
        for (ZeffyConnectDonationService.DonationHistoryRow r : rows) if (r.IsUndone) undone++;
        System.assertEquals(1, undone);
    }

    // ─── getDonationHistory — manual resolution marks IsManual=true ───────────

    @isTest
    static void testGetDonationHistoryManual() {
        Account donor = makePersonAccount('Manual', 'Hist', 'manualhist@test.ca');
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Manual',
            Last_Name__c            = 'Hist',
            Email__c                = 'manualhist@test.ca',
            Amount__c               = 50.00,
            Eligible_Amount__c      = 50.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Contact_Id__c     = 'zeffy_manualhist',
            Zeffy_Transaction_Id__c = 'txn_manualhist'
        );
        Zeffy_Review_Ticket__c tkt = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];
        ZeffyConnectDonationService.resolveLinkExisting(tkt.Id, donor.Id, null, null, false, false, false);

        Test.startTest();
        List<ZeffyConnectDonationService.DonationHistoryRow> rows =
            ZeffyConnectDonationService.getDonationHistory(null);
        Test.stopTest();

        System.assertEquals(1, rows.size());
        System.assertEquals(true, rows[0].IsManual, 'Manually resolved gift should have IsManual=true');
        System.assertNotEquals(null, rows[0].TicketName);
    }

    // ─── getMyTasks ───────────────────────────────────────────────────────────

    @isTest
    static void testGetMyTasks() {
        Test.startTest();
        List<Map<String, Object>> tasks = ZeffyConnectDonationService.getMyTasks();
        Test.stopTest();
        // Empty is fine — just verify it doesn't throw
        System.assertNotEquals(null, tasks);
    }

    // ─── assignTicket ─────────────────────────────────────────────────────────

    @isTest
    static void testAssignTicket() {
        insert new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', First_Name__c = 'Assign',
            Last_Name__c = 'Me', Email__c = 'assign@test.ca',
            Amount__c = 50.00, Zeffy_Transaction_Id__c = 'txn_assign_001'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.assignTicket(
            ticket.Id, UserInfo.getUserId(), UserInfo.getName(), 3, 'Assigned for test'
        );
        Test.stopTest();

        Zeffy_Review_Ticket__c updated = [
            SELECT Manual_Assignee_Id__c, Manual_Assignee_Name__c
            FROM Zeffy_Review_Ticket__c WHERE Id = :ticket.Id
        ];
        System.assertEquals(UserInfo.getUserId(), updated.Manual_Assignee_Id__c);
        System.assertEquals(UserInfo.getName(), updated.Manual_Assignee_Name__c);

        List<Task> tasks = [SELECT Subject FROM Task WHERE WhatId = :ticket.Id];
        System.assertEquals(1, tasks.size());
        System.assert(tasks[0].Subject.startsWith('VIP donation review'));
    }

    // ─── assignTicket — null ticketId → early return ──────────────────────────

    @isTest
    static void testAssignTicketNullId() {
        Test.startTest();
        ZeffyConnectDonationService.assignTicket(null, UserInfo.getUserId(), 'Test', 3, null);
        Test.stopTest();
        // No exception = pass
    }

    // ─── assignTicket — cancels existing auto-task ────────────────────────────

    @isTest
    static void testAssignTicketCancelsAutoTask() {
        insert new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', First_Name__c = 'CancelTask',
            Last_Name__c = 'Test', Amount__c = 50.00, Zeffy_Transaction_Id__c = 'txn_canceltask'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        // Pre-create auto-task
        insert new Task(
            Subject      = 'Review pending donation: CancelTask Test',
            WhatId       = ticket.Id,
            OwnerId      = UserInfo.getUserId(),
            Status       = 'Not Started',
            ActivityDate = Date.today().addDays(2)
        );

        Test.startTest();
        ZeffyConnectDonationService.assignTicket(
            ticket.Id, UserInfo.getUserId(), UserInfo.getName(), 3, null
        );
        Test.stopTest();

        // Old "Review pending donation" task should be deleted, new "VIP donation review" created
        List<Task> remaining = [SELECT Subject FROM Task WHERE WhatId = :ticket.Id AND IsClosed = false];
        System.assertEquals(1, remaining.size());
        System.assert(remaining[0].Subject.startsWith('VIP donation review'));
    }

    // ─── assignTicket — note is blank → default description ──────────────────

    @isTest
    static void testAssignTicketDefaultDescription() {
        insert new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', Company_Name__c = 'Assign Corp',
            Amount__c = 100.00, Zeffy_Transaction_Id__c = 'txn_assign_corp'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.assignTicket(
            ticket.Id, UserInfo.getUserId(), UserInfo.getName(), null, null
        );
        Test.stopTest();

        Task t = [SELECT Description FROM Task WHERE WhatId = :ticket.Id LIMIT 1];
        System.assertNotEquals(null, t.Description);
    }

    // ─── clearTicketAssignment ────────────────────────────────────────────────

    @isTest
    static void testClearTicketAssignment() {
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Clear',
            Last_Name__c            = 'Me',
            Amount__c               = 50.00,
            Zeffy_Transaction_Id__c = 'txn_clear_001',
            Manual_Assignee_Id__c   = UserInfo.getUserId(),
            Manual_Assignee_Name__c = UserInfo.getName()
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        // Pre-create VIP task to cancel
        insert new Task(
            Subject      = 'VIP donation review — Clear Me',
            WhatId       = ticket.Id,
            OwnerId      = UserInfo.getUserId(),
            Status       = 'Not Started',
            ActivityDate = Date.today().addDays(3)
        );

        Test.startTest();
        ZeffyConnectDonationService.clearTicketAssignment(ticket.Id);
        Test.stopTest();

        Zeffy_Review_Ticket__c updated = [
            SELECT Manual_Assignee_Id__c, Manual_Assignee_Name__c
            FROM Zeffy_Review_Ticket__c WHERE Id = :ticket.Id
        ];
        System.assertEquals(null, updated.Manual_Assignee_Id__c);
        System.assertEquals(null, updated.Manual_Assignee_Name__c);
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId = :ticket.Id AND IsClosed = false]);
    }

    // ─── clearTicketAssignment — null ticketId → early return ────────────────

    @isTest
    static void testClearTicketAssignmentNullId() {
        Test.startTest();
        ZeffyConnectDonationService.clearTicketAssignment(null);
        Test.stopTest();
    }

    // ─── importTickets — happy path ───────────────────────────────────────────

    @isTest
    static void testImportTickets() {
        String rowsJson = '[' +
            '{"transaction_id":"CSV_TX_001","first_name":"CSV","last_name":"Donor",' +
            '"email":"csv@test.ca","phone":"5141234567","company_name":null,' +
            '"address":"1 Rue CSV","city":"Montréal","province":"QC","postal_code":"H1A 1A1","country":"CA",' +
            '"language":"fr","form_name":"Campagne CSV","form_id":"form_csv","rate_title":"Don unique",' +
            '"receipt_url":null,"note":"Note test","annotation":null,' +
            '"subscription_id":null,"subscription_frequency":null,' +
            '"payment_method":"card","payment_type":"donation_form","currency":"CAD",' +
            '"receipt_number":"RC-CSV-001","amount":"50.00","eligible_amount":"40.00",' +
            '"gift_date":"2026-01-15","is_recurring":"false"}' +
        ']';

        Test.startTest();
        Map<String, Object> result = ZeffyConnectDonationService.importTickets(rowsJson);
        Test.stopTest();

        System.assertEquals(1, result.get('imported'));
        System.assertEquals(0, result.get('skipped'));
        System.assertEquals(0, ((List<String>) result.get('errors')).size());
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Review_Ticket__c]);
    }

    // ─── importTickets — various payment_method and payment_type ─────────────

    @isTest
    static void testImportTicketsPaymentVariants() {
        String rowsJson = '[' +
            '{"transaction_id":"CSV_ACH","payment_method":"ach","payment_type":"membership",' +
            '"amount":"10.00","currency":"CAD","gift_date":"2026-01-01","is_recurring":"false"},' +
            '{"transaction_id":"CSV_CHECK","payment_method":"cheque","payment_type":"ticket",' +
            '"amount":"20.00","currency":"CAD","gift_date":"2026-01-01","is_recurring":"false"},' +
            '{"transaction_id":"CSV_CASH","payment_method":"cash","payment_type":"raffle",' +
            '"amount":"5.00","currency":"CAD","gift_date":"2026-01-01","is_recurring":"false"},' +
            '{"transaction_id":"CSV_PAYPAL","payment_method":"paypal","payment_type":"donation_campaign",' +
            '"amount":"15.00","currency":"CAD","gift_date":"2026-01-01","is_recurring":"false"},' +
            '{"transaction_id":"CSV_REC","payment_method":"interac","payment_type":"donation_form",' +
            '"amount":"25.00","currency":"CAD","gift_date":"2026-01-01","is_recurring":"true",' +
            '"subscription_id":"sub_csv_001","subscription_frequency":"monthly"},' +
            '{"transaction_id":"CSV_OUI","payment_method":"bank","payment_type":"event",' +
            '"amount":"30.00","currency":"CAD","gift_date":"2026-01-01","is_recurring":"oui"},' +
            '{"transaction_id":"CSV_BLANK_PM","payment_method":null,"payment_type":null,' +
            '"amount":"35.00","currency":"CAD","gift_date":"2026-01-01","is_recurring":"false"}' +
        ']';

        Test.startTest();
        Map<String, Object> result = ZeffyConnectDonationService.importTickets(rowsJson);
        Test.stopTest();

        System.assertEquals(7, result.get('imported'));
        // Ordered alphabetically by Zeffy_Transaction_Id__c:
        // 0=CSV_ACH, 1=CSV_BLANK_PM, 2=CSV_CASH, 3=CSV_CHECK, 4=CSV_OUI, 5=CSV_PAYPAL, 6=CSV_REC
        List<Zeffy_Review_Ticket__c> tickets = [
            SELECT Payment_Method__c, Payment_Type__c FROM Zeffy_Review_Ticket__c
            ORDER BY Zeffy_Transaction_Id__c
        ];
        System.assertEquals('ACH',         tickets[0].Payment_Method__c); // ach
        System.assertEquals('Membership',  tickets[0].Payment_Type__c);
        System.assertEquals('Credit Card', tickets[1].Payment_Method__c); // null → Credit Card
        System.assertEquals('Donation',    tickets[1].Payment_Type__c);   // null → Donation
        System.assertEquals('Cash',        tickets[2].Payment_Method__c); // cash
        System.assertEquals('Raffle',      tickets[2].Payment_Type__c);
        System.assertEquals('Check',       tickets[3].Payment_Method__c); // cheque
        System.assertEquals('Ticket',      tickets[3].Payment_Type__c);
        System.assertEquals('ACH',         tickets[4].Payment_Method__c); // bank → ACH
        System.assertEquals('Ticket',      tickets[4].Payment_Type__c);   // event → Ticket
        System.assertEquals('PayPal',      tickets[5].Payment_Method__c); // paypal
        System.assertEquals('ACH',         tickets[6].Payment_Method__c); // interac → ACH
    }

    // ─── importTickets — duplicate skipped ────────────────────────────────────

    @isTest
    static void testImportTicketsDuplicateSkipped() {
        insert new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', Amount__c = 10.00,
            Zeffy_Transaction_Id__c = 'CSV_DUP_EXISTING'
        );
        String rowsJson = '[' +
            '{"transaction_id":"CSV_DUP_EXISTING","amount":"10.00",' +
            '"currency":"CAD","gift_date":"2026-01-01","is_recurring":"false"},' +
            '{"transaction_id":"CSV_NEW_VALID","amount":"20.00",' +
            '"currency":"CAD","gift_date":"2026-01-01","is_recurring":"false"}' +
        ']';

        Test.startTest();
        Map<String, Object> result = ZeffyConnectDonationService.importTickets(rowsJson);
        Test.stopTest();

        System.assertEquals(1, result.get('imported'));
        System.assertEquals(1, result.get('skipped'));
        System.assertEquals(2, [SELECT COUNT() FROM Zeffy_Review_Ticket__c]); // 1 old + 1 new
    }

    // ─── importTickets — invalid amount/date triggers catch branches ──────────

    @isTest
    static void testImportTicketsInvalidAmountAndDate() {
        String rowsJson = '[' +
            '{"transaction_id":"CSV_BADAMT","amount":"not-a-number","eligible_amount":"also-bad",' +
            '"gift_date":"not-a-date","currency":"CAD","is_recurring":"false"}' +
        ']';

        Test.startTest();
        Map<String, Object> result = ZeffyConnectDonationService.importTickets(rowsJson);
        Test.stopTest();

        // Should still import successfully (catches swallow parse errors)
        System.assertEquals(1, result.get('imported'));
        Zeffy_Review_Ticket__c ticket = [SELECT Amount__c, Gift_Date__c FROM Zeffy_Review_Ticket__c];
        System.assertEquals(null, ticket.Amount__c, 'Amount should be null on parse failure');
        System.assertEquals(null, ticket.Gift_Date__c, 'Gift_Date should be null on parse failure');
    }

    // ─── getWebhookHealthStats ────────────────────────────────────────────────

    @isTest
    static void testGetWebhookHealthStats() {
        // @TestSetup already created a config — just update it
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        if (cfg == null) {
            cfg = new Zeffy_Config__c(SetupOwnerId = UserInfo.getOrganizationId(), Is_Active__c = true);
            insert cfg;
        } else {
            cfg.Is_Active__c = true;
            update cfg;
        }
        insert new Zeffy_Webhook_Log__c(
            Status__c      = 'SUCCESS',
            Occurred_At__c = DateTime.now().addMinutes(-2),
            Amount__c      = 50.00
        );
        insert new Zeffy_Webhook_Log__c(
            Status__c      = 'DUPLICATE_SKIPPED',
            Occurred_At__c = DateTime.now().addMinutes(-1)
        );
        insert new Zeffy_Webhook_Log__c(
            Status__c      = 'AUTH_FAILED',
            Occurred_At__c = DateTime.now()   // most recent → should be lastStatus
        );

        Test.startTest();
        Map<String, Object> stats = ZeffyConnectDonationService.getWebhookHealthStats();
        Test.stopTest();

        System.assertEquals(true,  stats.get('isActive'));
        System.assertEquals(3,     stats.get('totalAllTime'));
        System.assertNotEquals(null, stats.get('lastReceivedAt'));
        System.assertEquals('AUTH_FAILED', stats.get('lastStatus')); // last inserted
        System.assertNotEquals(null, stats.get('todayTotal'));
        System.assertEquals(3, (Integer) stats.get('todayTotal'));
        System.assertEquals(1, (Integer) stats.get('todaySuccess'));
        System.assertEquals(1, (Integer) stats.get('todayDuplicates'));
        System.assertEquals(1, (Integer) stats.get('todayErrors'));
    }

    // ─── getWebhookHealthStats — config inactive → isActive false ───────────

    @isTest
    static void testGetWebhookHealthStatsNoConfig() {
        // @TestSetup created a config — deactivate it for this test
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        if (cfg != null) {
            cfg.Is_Active__c = false;
            update cfg;
        }
        Test.startTest();
        Map<String, Object> stats = ZeffyConnectDonationService.getWebhookHealthStats();
        Test.stopTest();

        System.assertEquals(false, stats.get('isActive'));
        System.assertEquals(null, stats.get('lastReceivedAt'));
        System.assertEquals(0, (Integer) stats.get('totalAllTime'));
    }

    // ─── getWebhookLogs — no filter ───────────────────────────────────────────

    @isTest
    static void testGetWebhookLogsNoFilter() {
        insert new List<Zeffy_Webhook_Log__c>{
            new Zeffy_Webhook_Log__c(Status__c = 'SUCCESS',      Occurred_At__c = DateTime.now(), Amount__c = 50.00),
            new Zeffy_Webhook_Log__c(Status__c = 'AUTH_FAILED',  Occurred_At__c = DateTime.now())
        };

        Test.startTest();
        List<ZeffyConnectDonationService.WebhookLogRow> rows =
            ZeffyConnectDonationService.getWebhookLogs(null, null, null);
        Test.stopTest();

        System.assertEquals(2, rows.size());
    }

    // ─── getWebhookLogs — status filter + search term ────────────────────────

    @isTest
    static void testGetWebhookLogsWithFilter() {
        insert new List<Zeffy_Webhook_Log__c>{
            new Zeffy_Webhook_Log__c(
                Status__c      = 'SUCCESS',
                Occurred_At__c = DateTime.now(),
                Transaction_Id__c = 'txn_log_filter_001',
                Donor_Name__c     = 'Filtered Donor',
                Amount__c         = 75.00
            ),
            new Zeffy_Webhook_Log__c(Status__c = 'AUTH_FAILED', Occurred_At__c = DateTime.now())
        };

        Test.startTest();
        // Filter by status
        List<ZeffyConnectDonationService.WebhookLogRow> byStatus =
            ZeffyConnectDonationService.getWebhookLogs('SUCCESS', null, 50);
        // Filter by search term
        List<ZeffyConnectDonationService.WebhookLogRow> bySearch =
            ZeffyConnectDonationService.getWebhookLogs('All', 'txn_log_filter', 50);
        // No match
        List<ZeffyConnectDonationService.WebhookLogRow> none =
            ZeffyConnectDonationService.getWebhookLogs('SUCCESS', 'ZZZNOTFOUND', 50);
        Test.stopTest();

        System.assertEquals(1, byStatus.size());
        System.assertEquals('SUCCESS', byStatus[0].status);
        System.assertEquals(1, bySearch.size());
        System.assertEquals(0, none.size());
    }

    // ─── processWebhook — payload with tribute, fund, dispute, discount ───────

    @isTest
    static void testProcessWebhookRichPayload() {
        // Corporate payload with tribute + fund + dispute + discount → creates rich ticket
        Test.startTest();
        ZeffyConnectDonationService.processWebhook(buildCorporatePayload('txn_rich_001', 'zeffy_rich_new'));
        Test.stopTest();

        List<Zeffy_Review_Ticket__c> tickets = [
            SELECT Tribute_Honouree__c, Tribute_Type__c, Fund_Code__c, Fund_Name__c,
                   Dispute_Status__c, Dispute_Reason__c, Discount_Code__c,
                   Buyer_Questions__c, Is_Corporate__c, Rate_Title__c
            FROM Zeffy_Review_Ticket__c
        ];
        System.assertEquals(1, tickets.size());
        System.assertEquals('Jean Paul',      tickets[0].Tribute_Honouree__c);
        System.assertEquals('in_honor_of',    tickets[0].Tribute_Type__c);
        System.assertEquals('GEN',            tickets[0].Fund_Code__c);
        System.assertEquals('General Fund',   tickets[0].Fund_Name__c);
        System.assertEquals('CORP10',         tickets[0].Discount_Code__c);
        System.assertNotEquals(null,          tickets[0].Buyer_Questions__c);
        System.assertEquals(true,            tickets[0].Is_Corporate__c);
        System.assertEquals('Don corporatif', tickets[0].Rate_Title__c);
    }

    // ─── processWebhook — fund with FR name only (no EN) ─────────────────────

    @isTest
    static void testProcessWebhookFundFrenchName() {
        String payload =
            '{"id":"evt_fr","type":"payment.completed","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"txn_fr_fund","status":"succeeded","type":"online",' +
            '"amount":5000,"eligible_amount":5000,"currency":"cad","contact":"zeffy_fr_fund",' +
            '"buyer":{"email":"fr@fund.ca","first_name":"FR","last_name":"Fund",' +
            '"is_corporate":false,"company_name":null,"address":null},' +
            '"payment_method":null,"created":1737000000,"receipt_url":null,' +
            '"campaign_id":null,"campaign_type":null,"campaign_category":null,"description":null,' +
            '"refund_status":"none","refunds":[],"dispute":null,' +
            '"fund":{"id":"f_fr","code":"FR","name":{"EN":null,"FR":"Fonds FR Seulement","ES":null}},' +
            '"discount":null,"buyer_questions":[],"items":[],"recurring":null}}';

        Test.startTest();
        ZeffyConnectDonationService.processWebhook(payload);
        Test.stopTest();

        Zeffy_Review_Ticket__c ticket = [SELECT Fund_Name__c FROM Zeffy_Review_Ticket__c LIMIT 1];
        System.assertEquals('Fonds FR Seulement', ticket.Fund_Name__c, 'Should fall back to FR fund name');
    }

    // ─── processWebhook — null created timestamp → Date.today() fallback ──────

    @isTest
    static void testProcessWebhookNullTimestamp() {
        String payload =
            '{"id":"evt_nullts","type":"payment.completed","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"txn_nullts","status":"succeeded","type":"online",' +
            '"amount":5000,"eligible_amount":5000,"currency":"cad","contact":"zeffy_nullts",' +
            '"buyer":{"email":"nullts@test.ca","first_name":"Null","last_name":"Ts",' +
            '"is_corporate":false,"company_name":null,"address":null},' +
            '"payment_method":null,"created":null,"receipt_url":null,' +
            '"campaign_id":null,"campaign_type":null,"campaign_category":null,"description":null,' +
            '"refund_status":"none","refunds":[],"dispute":null,"fund":null,"discount":null,' +
            '"buyer_questions":[],"items":[],"recurring":null}}';

        Test.startTest();
        ZeffyConnectDonationService.processWebhook(payload);
        Test.stopTest();

        Zeffy_Review_Ticket__c ticket = [SELECT Gift_Date__c FROM Zeffy_Review_Ticket__c LIMIT 1];
        System.assertEquals(Date.today(), ticket.Gift_Date__c, 'Null timestamp should default to today');
    }

    // ─── DUPLICATE_VALUE DML catch — race condition between two simultaneous webhooks ──

    @isTest
    static void testDuplicateValueDmlRaceCatch() {
        // Simulate "first request" already inserted a ticket with this TX ID
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            Email__c                = 'race@test.ca',
            Zeffy_Transaction_Id__c = 'txn_race_001',
            Transaction_Status__c   = 'succeeded'   // first request already recorded the confirmation
        );

        // Skip isDuplicate() check so the second insert is attempted (simulates race condition)
        ZeffyConnectDonationService.skipDuplicateCheckForTest = true;
        Test.startTest();
        ZeffyConnectDonationService.WebhookResult result =
            ZeffyConnectDonationService.processWebhookWithResult(
                buildPayload('txn_race_001', 'race@test.ca', 'zeffy_race_001'));
        Test.stopTest();
        ZeffyConnectDonationService.skipDuplicateCheckForTest = false;

        System.assertEquals('DUPLICATE_SKIPPED', result.status,
            'Race condition DML duplicate should be caught as DUPLICATE_SKIPPED, not TICKET_INSERT_FAILED');
        System.assert(String.isNotBlank(result.detail), 'Detail should describe the race condition');
        // Only 1 ticket should exist (the pre-inserted one)
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_race_001']);
    }

    // ─── The robot never auto-assigns by email — even a unique match goes to review ──

    @isTest
    static void testEmailMatchUniqueAccountStillCreatesTicket() {
        makePersonAccount('Carlos', 'López', 'carlos.fb@test.ca');

        Test.startTest();
        ZeffyConnectDonationService.processWebhook(buildPayload('txn_email_fb_001', 'carlos.fb@test.ca', 'zeffy_fb_001'));
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM GiftTransaction WHERE Zeffy_Transaction_Id__c = 'txn_email_fb_001'],
            'Email alone must never auto-assign a donation');
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_email_fb_001']);
        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Identity__c WHERE Zeffy_Contact_Id__c = 'zeffy_fb_001']);
    }

    // Shared email (couple / family) → never guessed, goes to review
    @isTest
    static void testEmailMatchSharedEmailCreatesTicket() {
        makePersonAccount('Ana', 'Shared', 'family.shared@test.ca');
        makePersonAccount('Luis', 'Shared', 'family.shared@test.ca');

        Test.startTest();
        ZeffyConnectDonationService.processWebhook(buildPayload('txn_email_sh_001', 'family.shared@test.ca', 'zeffy_sh_001'));
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM GiftTransaction WHERE Zeffy_Transaction_Id__c = 'txn_email_sh_001']);
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_email_sh_001']);
        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Identity__c WHERE Zeffy_Contact_Id__c = 'zeffy_sh_001']);
    }

    @isTest
    static void testEmailFallbackNoMatchCreatesTicket() {
        // No PersonAccount with this email → creates review ticket
        Test.startTest();
        ZeffyConnectDonationService.processWebhook(buildPayload('txn_email_nm_001', 'nobody.ever@test.ca', 'zeffy_nm_001'));
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM GiftTransaction]);
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_email_nm_001'],
            'Unknown email should create review ticket');
    }

    // ─── payment.created ─────────────────────────────────────────────────────────

    private static String buildCreatedPayload(String txId) {
        return '{"id":"evt_pc","type":"payment.created","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"' + txId + '","status":"pending","amount":5000,"eligible_amount":4000,' +
            '"currency":"cad","contact":"zeffy_pc_001",' +
            '"buyer":{"email":"pc@test.ca","first_name":"Paul","last_name":"Cote",' +
            '"is_corporate":false,"company_name":null,"address":null},' +
            '"payment_method":{"type":"card","brand":"visa","last4":"5678"},' +
            '"created":1737000000,"receipt_url":null,' +
            '"campaign_id":"form_ds","campaign_type":"donation_form","campaign_category":"donation",' +
            '"description":"Campagne DS","refund_status":"none","refunds":[],' +
            '"dispute":null,"fund":null,"discount":null,"buyer_questions":[],' +
            '"items":[{"id":"item_pc","type":"donation","amount":5000,"rate_title":"Don général",' +
            '"tribute":null,"contact_id":null,"questions":[]}],' +
            '"recurring":null}}';
    }

    private static String buildUpdatedPayload(String txId, String status, String receiptUrl) {
        return '{"id":"evt_upd","type":"payment.updated","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"' + txId + '","status":"' + status + '","amount":5000,"eligible_amount":4000,' +
            '"currency":"cad","contact":"zeffy_upd_001","buyer":null,"payment_method":null,' +
            '"created":1737000000,"receipt_url":' + (receiptUrl != null ? '"' + receiptUrl + '"' : 'null') + ',' +
            '"campaign_id":null,"campaign_type":null,"campaign_category":null,"description":null,' +
            '"refund_status":"none","refunds":[],"dispute":null,"fund":null,"discount":null,' +
            '"buyer_questions":[],"items":[],"recurring":null}}';
    }

    private static String buildDeletedPayload(String txId) {
        return '{"id":"evt_del","type":"payment.deleted","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"' + txId + '","status":"deleted","amount":5000,"currency":"cad","contact":"zeffy_del_001",' +
            '"buyer":null,"payment_method":null,"created":1737000000,"receipt_url":null,' +
            '"campaign_id":null,"campaign_type":null,"campaign_category":null,"description":null,' +
            '"refund_status":"none","refunds":[],"dispute":null,"fund":null,"discount":null,' +
            '"buyer_questions":[],"items":[],"recurring":null}}';
    }

    @isTest
    static void testPaymentCreatedCreatesHoldingTicket() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Created__c = true;
        update cfg;

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult result =
            ZeffyConnectDonationService.processWebhookWithResult(buildCreatedPayload('txn_pc_001'));
        Test.stopTest();

        System.assertEquals('SUCCESS', result.status);
        Zeffy_Review_Ticket__c ticket = [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_pc_001'];
        System.assertEquals('Holding', ticket.Status__c);
    }

    @isTest
    static void testPaymentCreatedMissingTxId() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Created__c = true;
        update cfg;

        String payload = '{"id":"evt_pc_blank","type":"payment.created","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":null,"status":"pending","amount":5000,"currency":"cad","contact":null,' +
            '"buyer":null,"payment_method":null,"created":1737000000,"receipt_url":null,' +
            '"campaign_id":null,"campaign_type":null,"campaign_category":null,"description":null,' +
            '"refund_status":"none","refunds":[],"dispute":null,"fund":null,"discount":null,' +
            '"buyer_questions":[],"items":[],"recurring":null}}';

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult result = ZeffyConnectDonationService.processWebhookWithResult(payload);
        Test.stopTest();

        System.assertEquals('MISSING_TX_ID', result.status);
    }

    @isTest
    static void testPaymentCreatedDuplicateSkipped() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Created__c = true;
        update cfg;

        insert new Zeffy_Review_Ticket__c(Status__c = 'Holding', Email__c = 'dup@test.ca', Zeffy_Transaction_Id__c = 'txn_pc_dup');

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult result =
            ZeffyConnectDonationService.processWebhookWithResult(buildCreatedPayload('txn_pc_dup'));
        Test.stopTest();

        System.assertEquals('DUPLICATE_SKIPPED', result.status);
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Review_Ticket__c]);
    }

    // ─── payment.updated ─────────────────────────────────────────────────────────

    @isTest
    static void testPaymentUpdatedHoldingGraduates() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Updated__c = true;
        update cfg;

        insert new Zeffy_Review_Ticket__c(Status__c = 'Holding', Email__c = 'h@test.ca', Zeffy_Transaction_Id__c = 'txn_upd_001');

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult result =
            ZeffyConnectDonationService.processWebhookWithResult(buildUpdatedPayload('txn_upd_001', 'succeeded', 'https://zeffy.com/r/001'));
        Test.stopTest();

        System.assertEquals('SUCCESS', result.status);
        Zeffy_Review_Ticket__c t = [SELECT Status__c, Receipt_URL__c FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_upd_001'];
        System.assertEquals('Pending Review', t.Status__c, 'Holding should graduate to Pending Review');
        System.assertEquals('https://zeffy.com/r/001', t.Receipt_URL__c);
    }

    @isTest
    static void testPaymentUpdatedNonHoldingWithDisputeAndRefund() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Updated__c = true;
        update cfg;

        insert new Zeffy_Review_Ticket__c(Status__c = 'Pending Review', Email__c = 'nr@test.ca', Zeffy_Transaction_Id__c = 'txn_upd_002');

        String payload = '{"id":"evt_upd2","type":"payment.updated","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"txn_upd_002","status":"disputed","amount":5000,"eligible_amount":4000,' +
            '"currency":"cad","contact":"z_upd_002","buyer":null,"payment_method":null,' +
            '"created":1737000000,"receipt_url":null,' +
            '"refund_status":"partial","refunds":[{"id":"r1","amount":500,"status":"succeeded","created":1737001000}],' +
            '"dispute":{"id":"d1","status":"needs_response","reason":"fraudulent","amount":5000},' +
            '"campaign_id":null,"campaign_type":null,"campaign_category":null,"description":null,' +
            '"fund":null,"discount":null,"buyer_questions":[],"items":[],"recurring":null}}';

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult result = ZeffyConnectDonationService.processWebhookWithResult(payload);
        Test.stopTest();

        System.assertEquals('SUCCESS', result.status);
        Zeffy_Review_Ticket__c t = [SELECT Status__c, Dispute_Status__c, Refund_Amount__c FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_upd_002'];
        System.assertEquals('Pending Review', t.Status__c, 'Non-holding status should not change');
        System.assertEquals('needs_response', t.Dispute_Status__c);
        System.assertEquals(5.00, t.Refund_Amount__c);
    }

    @isTest
    static void testPaymentUpdatedGiftTransactionReceipt() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Updated__c = true;
        update cfg;

        Account donor = makePersonAccount('GT', 'Update', 'gtupd@test.ca');
        linkIdentity(donor.Id, 'zeffy_gt_upd', 'gtupd@test.ca');
        // Create GiftTransaction via the service to ensure required fields
        ZeffyConnectDonationService.processWebhook(buildPayload('txn_gt_upd_001', 'gtupd@test.ca', 'zeffy_gt_upd'));

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult result =
            ZeffyConnectDonationService.processWebhookWithResult(buildUpdatedPayload('txn_gt_upd_001', 'succeeded', 'https://zeffy.com/r/gt001'));
        Test.stopTest();

        System.assertEquals('SUCCESS', result.status);
        GiftTransaction gt = [SELECT Receipt_URL__c FROM GiftTransaction WHERE Zeffy_Transaction_Id__c = 'txn_gt_upd_001'];
        System.assertEquals('https://zeffy.com/r/gt001', gt.Receipt_URL__c);
    }

    @isTest
    static void testPaymentUpdatedNoMatch() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Updated__c = true;
        update cfg;

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult result =
            ZeffyConnectDonationService.processWebhookWithResult(buildUpdatedPayload('txn_nomatch_001', 'succeeded', null));
        Test.stopTest();

        System.assertEquals('IGNORED', result.status, 'No match keeps the payload for a later reprocess');
    }

    @isTest
    static void testPaymentUpdatedMissingTxId() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Updated__c = true;
        update cfg;

        String payload = '{"id":"evt_upd_blank","type":"payment.updated","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":null,"status":"succeeded","amount":5000,"currency":"cad","contact":null,' +
            '"buyer":null,"payment_method":null,"created":1737000000,"receipt_url":null,' +
            '"campaign_id":null,"campaign_type":null,"campaign_category":null,"description":null,' +
            '"refund_status":"none","refunds":[],"dispute":null,"fund":null,"discount":null,' +
            '"buyer_questions":[],"items":[],"recurring":null}}';

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult result = ZeffyConnectDonationService.processWebhookWithResult(payload);
        Test.stopTest();

        System.assertEquals('MISSING_TX_ID', result.status);
    }

    // ─── payment.deleted ─────────────────────────────────────────────────────────

    @isTest
    static void testPaymentDeletedMarksPaymentFailed() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Deleted__c = true;
        update cfg;

        insert new Zeffy_Review_Ticket__c(Status__c = 'Pending Review', Email__c = 'del@test.ca', Zeffy_Transaction_Id__c = 'txn_del_001');

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult result =
            ZeffyConnectDonationService.processWebhookWithResult(buildDeletedPayload('txn_del_001'));
        Test.stopTest();

        System.assertEquals('SUCCESS', result.status);
        System.assertEquals('Payment Failed', [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_del_001'].Status__c);
    }

    @isTest
    static void testPaymentDeletedNoMatch() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Deleted__c = true;
        update cfg;

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult result =
            ZeffyConnectDonationService.processWebhookWithResult(buildDeletedPayload('txn_del_nm_001'));
        Test.stopTest();

        System.assertEquals('SUCCESS', result.status);
        Zeffy_Review_Ticket__c tomb = [SELECT Status__c, Transaction_Status__c FROM Zeffy_Review_Ticket__c
                                       WHERE Zeffy_Transaction_Id__c = 'txn_del_nm_001'];
        System.assertEquals('Closed', tomb.Status__c, 'A deleted payment with nothing in SF leaves a closed ticket');
        System.assertEquals('deleted', tomb.Transaction_Status__c);

        // A late payment.completed for the same payment must not record a gift
        ZeffyConnectDonationService.WebhookResult late =
            ZeffyConnectDonationService.processWebhookWithResult(buildPayload('txn_del_nm_001', 'late@test.ca', 'zeffy_late_001'));
        System.assertEquals('DUPLICATE_SKIPPED', late.status);
        System.assertEquals(0, [SELECT COUNT() FROM GiftTransaction WHERE Zeffy_Transaction_Id__c = 'txn_del_nm_001']);
    }

    @isTest
    static void testPaymentDeletedMissingTxId() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Deleted__c = true;
        update cfg;

        String payload = '{"id":"evt_del_blank","type":"payment.deleted","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":null,"status":"deleted","amount":5000,"currency":"cad","contact":null,' +
            '"buyer":null,"payment_method":null,"created":1737000000,"receipt_url":null,' +
            '"campaign_id":null,"campaign_type":null,"campaign_category":null,"description":null,' +
            '"refund_status":"none","refunds":[],"dispute":null,"fund":null,"discount":null,' +
            '"buyer_questions":[],"items":[],"recurring":null}}';

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult result = ZeffyConnectDonationService.processWebhookWithResult(payload);
        Test.stopTest();

        System.assertEquals('MISSING_TX_ID', result.status);
    }

    // ─── extractBuyerQuestionsText — null, Boolean, and List answer types ───────

    @isTest
    static void testBuyerQuestionsAnswerTypes() {
        // null answer → '—' | boolean true → 'Oui / Yes' | list → joined | string already tested
        String payload = '{"id":"evt_qa","type":"payment.completed","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"txn_qa_001","status":"succeeded","type":"online",' +
            '"amount":5000,"eligible_amount":5000,"currency":"cad","contact":"zeffy_qa_001",' +
            '"buyer":{"email":"qa@test.ca","first_name":"QA","last_name":"Test",' +
            '"is_corporate":false,"company_name":null,"address":null},' +
            '"payment_method":null,"created":1737000000,"receipt_url":null,' +
            '"campaign_id":null,"campaign_type":null,"campaign_category":null,"description":null,' +
            '"refund_status":"none","refunds":[],"dispute":null,"fund":null,"discount":null,' +
            '"buyer_questions":[' +
            '{"question":"Q null","type":"text","answer":null},' +
            '{"question":"Q bool","type":"checkbox","answer":true},' +
            '{"question":"Q list","type":"checkbox_multiple","answer":["Choice A","Choice B"]}' +
            '],' +
            '"items":[],"recurring":null}}';

        Test.startTest();
        ZeffyConnectDonationService.processWebhook(payload);
        Test.stopTest();

        Zeffy_Review_Ticket__c ticket = [SELECT Buyer_Questions__c FROM Zeffy_Review_Ticket__c LIMIT 1];
        System.assertNotEquals(null, ticket.Buyer_Questions__c, 'Questions should be saved');
        System.assert(ticket.Buyer_Questions__c.contains('Q null'), 'Should have null answer question');
        System.assert(ticket.Buyer_Questions__c.contains('Oui / Yes'), 'Should have boolean answer');
        System.assert(ticket.Buyer_Questions__c.contains('Choice A'), 'Should have list answer');
    }

    // ─── getFundName — ES fallback when EN and FR are both null ─────────────────

    @isTest
    static void testFundNameEsFallback() {
        String payload = '{"id":"evt_es","type":"payment.completed","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"txn_es_fund","status":"succeeded","type":"online",' +
            '"amount":5000,"eligible_amount":5000,"currency":"cad","contact":"zeffy_es_fund",' +
            '"buyer":{"email":"es@fund.ca","first_name":"ES","last_name":"Fund",' +
            '"is_corporate":false,"company_name":null,"address":null},' +
            '"payment_method":null,"created":1737000000,"receipt_url":null,' +
            '"campaign_id":null,"campaign_type":null,"campaign_category":null,"description":null,' +
            '"refund_status":"none","refunds":[],"dispute":null,' +
            '"fund":{"id":"f_es","code":"ES","name":{"EN":null,"FR":null,"ES":"Fondo ES"}},' +
            '"discount":null,"buyer_questions":[],"items":[],"recurring":null}}';

        Test.startTest();
        ZeffyConnectDonationService.processWebhook(payload);
        Test.stopTest();

        Zeffy_Review_Ticket__c ticket = [SELECT Fund_Name__c FROM Zeffy_Review_Ticket__c LIMIT 1];
        System.assertEquals('Fondo ES', ticket.Fund_Name__c, 'Should fall back to ES fund name');
    }

    // ─── getFundName — all null → null Fund_Name__c ───────────────────────────

    @isTest
    static void testFundNameAllNull() {
        String payload = '{"id":"evt_fnull","type":"payment.completed","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"txn_fnull","status":"succeeded","type":"online",' +
            '"amount":5000,"eligible_amount":5000,"currency":"cad","contact":"zeffy_fnull",' +
            '"buyer":{"email":"fnull@test.ca","first_name":"Fund","last_name":"Null",' +
            '"is_corporate":false,"company_name":null,"address":null},' +
            '"payment_method":null,"created":1737000000,"receipt_url":null,' +
            '"campaign_id":null,"campaign_type":null,"campaign_category":null,"description":null,' +
            '"refund_status":"none","refunds":[],"dispute":null,' +
            '"fund":{"id":"f_null","code":"NULL","name":{"EN":null,"FR":null,"ES":null}},' +
            '"discount":null,"buyer_questions":[],"items":[],"recurring":null}}';

        Test.startTest();
        ZeffyConnectDonationService.processWebhook(payload);
        Test.stopTest();

        Zeffy_Review_Ticket__c ticket = [SELECT Fund_Name__c FROM Zeffy_Review_Ticket__c LIMIT 1];
        System.assertEquals(null, ticket.Fund_Name__c, 'All-null fund name should result in null');
    }

    // ─── buildDescription / createGiftTransaction with fund ──────────────────

    @isTest
    static void testGiftTransactionWithFundDescription() {
        Account donor = makePersonAccount('Fund', 'Donor', 'fund.donor@test.ca');
        linkIdentity(donor.Id, 'zeffy_fund_donor', 'fund.donor@test.ca');

        String payload = '{"id":"evt_giftfund","type":"payment.completed","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"txn_giftfund_001","status":"succeeded","type":"online",' +
            '"amount":5000,"eligible_amount":5000,"currency":"cad","contact":"zeffy_fund_donor",' +
            '"buyer":{"email":"fund.donor@test.ca","first_name":"Fund","last_name":"Donor",' +
            '"is_corporate":false,"company_name":null,"address":null},' +
            '"payment_method":{"type":"card","brand":"visa","last4":"1111"},' +
            '"created":1737000000,"receipt_url":null,' +
            '"campaign_id":null,"campaign_type":null,"campaign_category":null,' +
            '"description":"Annual Campaign",' +
            '"refund_status":"none","refunds":[],"dispute":null,' +
            '"fund":{"id":"f_gd","code":"GD","name":{"EN":"General Fund","FR":null,"ES":null}},' +
            '"discount":null,"buyer_questions":[],' +
            '"items":[{"id":"i_gd","type":"donation","amount":5000,"rate_title":"Donation","tribute":null,"contact_id":null,"questions":[]}],' +
            '"recurring":null}}';

        Test.startTest();
        ZeffyConnectDonationService.processWebhook(payload);
        Test.stopTest();

        List<GiftTransaction> gifts = [SELECT Description FROM GiftTransaction WHERE Zeffy_Transaction_Id__c = 'txn_giftfund_001'];
        System.assertEquals(1, gifts.size(), 'Should create GiftTransaction for known donor');
        System.assert(gifts[0].Description != null && gifts[0].Description.contains('Fund: General Fund'),
            'Description should include fund name: ' + gifts[0].Description);
    }

    // ─── createHoldingTicket — tribute path in items ─────────────────────────

    @isTest
    static void testPaymentCreatedWithTribute() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Created__c = true;
        update cfg;

        String payload = '{"id":"evt_tribute","type":"payment.created","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"txn_tribute_001","status":"pending","amount":5000,"eligible_amount":5000,' +
            '"currency":"cad","contact":"zeffy_tribute_001",' +
            '"buyer":{"email":"tribute@test.ca","first_name":"Gift","last_name":"In Honor",' +
            '"is_corporate":false,"company_name":null,"address":null},' +
            '"payment_method":{"type":"card","brand":"visa","last4":"9999"},' +
            '"created":1737000000,"receipt_url":null,' +
            '"campaign_id":null,"campaign_type":null,"campaign_category":null,"description":null,' +
            '"refund_status":"none","refunds":[],"dispute":null,"fund":null,"discount":null,' +
            '"buyer_questions":[],' +
            '"items":[{"id":"item_trib","type":"donation","amount":5000,"rate_title":"In Honor",' +
            '"tribute":{"type":"in_honor_of","honouree_name":"Jean Dupont"},' +
            '"contact_id":null,"questions":[]}],' +
            '"recurring":null}}';

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult result = ZeffyConnectDonationService.processWebhookWithResult(payload);
        Test.stopTest();

        System.assertEquals('SUCCESS', result.status);
        Zeffy_Review_Ticket__c ticket = [SELECT Status__c, Tribute_Type__c, Tribute_Honouree__c FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_tribute_001'];
        System.assertEquals('Holding', ticket.Status__c);
        System.assertEquals('in_honor_of', ticket.Tribute_Type__c, 'Tribute type should be saved');
        System.assertEquals('Jean Dupont', ticket.Tribute_Honouree__c, 'Tribute honouree should be saved');
    }

    // ─── upsertIdentity — blank zeffyContactId returns early ─────────────────

    @isTest
    static void testUpsertIdentityBlankId() {
        // resolveLinkExisting with blank Zeffy_Contact_Id__c → upsertIdentity early return
        Account donor = makePersonAccount('Blank', 'ZeffyId', 'blankid@test.ca');
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Blank',
            Last_Name__c            = 'ZeffyId',
            Email__c                = 'blankid@test.ca',
            Amount__c               = 30.00,
            Eligible_Amount__c      = 30.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Contact_Id__c     = null,  // blank — upsertIdentity should return early
            Zeffy_Transaction_Id__c = 'txn_blankid_001'
        );
        Zeffy_Review_Ticket__c ticket = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.resolveLinkExisting(ticket.Id, donor.Id, 'No Zeffy ID', null, false, false, false);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Identity__c], 'No identity should be created for blank Zeffy ID');
        Zeffy_Review_Ticket__c resolved = [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :ticket.Id];
        System.assertEquals('Resolved - Linked', resolved.Status__c);
    }

    // ─── contact.* events ────────────────────────────────────────────────────────

    @isTest
    static void testContactEventReceived() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Contact_Events__c = true;
        update cfg;

        String payload = '{"id":"evt_contact","type":"contact.created","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"contact_001","status":null,"amount":null,"currency":null,"contact":"z_contact_001",' +
            '"buyer":null,"payment_method":null,"created":null,"receipt_url":null,' +
            '"campaign_id":null,"campaign_type":null,"campaign_category":null,"description":null,' +
            '"refund_status":null,"refunds":[],"dispute":null,"fund":null,"discount":null,' +
            '"buyer_questions":[],"items":[],"recurring":null}}';

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult result = ZeffyConnectDonationService.processWebhookWithResult(payload);
        Test.stopTest();

        System.assertEquals('IGNORED', result.status);
        System.assert(result.message.contains('manual review'), 'Contact event should require manual review');
    }

    @isTest
    static void testIgnoredEventKeptAndReprocessGuard() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Deleted__c = false;
        upsert cfg;

        String payload = '{"id":"evt_ign","type":"payment.deleted","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"txn_ign_001"}}';
        ZeffyConnectDonationService.WebhookResult result = ZeffyConnectDonationService.processWebhookWithResult(payload);
        System.assertEquals('IGNORED', result.status, 'Toggle-off events are logged as IGNORED, not SUCCESS');

        Zeffy_Webhook_Log__c log = new Zeffy_Webhook_Log__c(Status__c = 'IGNORED', Occurred_At__c = DateTime.now(),
            Raw_Payload__c = payload, Has_Raw_Payload__c = true);
        insert log;

        grantSettingsAccess();
        Boolean threw = false;
        Test.startTest();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            try {
                ZeffyConnectDonationService.reprocessWebhookLog(log.Id);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();
        System.assert(threw, 'Reprocessing while the toggle is still off must explain why');
        System.assertEquals(true, [SELECT Has_Raw_Payload__c FROM Zeffy_Webhook_Log__c WHERE Id = :log.Id].Has_Raw_Payload__c,
            'The payload stays for a later retry');
    }

    // ─── getLinkPreview — covers full schema-scan + preview build ────────────

    @isTest
    static void testGetLinkPreviewWithIdentity() {
        Account a = makePersonAccount('Marie', 'Gagnon', 'marie.gagnon@preview.ca');
        a.BillingStreet     = '42 rue Preview';
        a.BillingCity       = 'Québec';
        a.BillingState      = 'QC';
        a.BillingPostalCode = 'G1A 1A1';
        update a;
        linkIdentity(a.Id, 'zeffy_preview_001', 'marie.gagnon@preview.ca');

        insert new Zeffy_Review_Ticket__c(
            Status__c      = 'Pending Review',
            First_Name__c  = 'Marie',
            Last_Name__c   = 'Gagnon',
            Email__c       = 'marie.gagnon@preview.ca',
            Address__c     = '42 rue Preview',
            City__c        = 'Québec',
            Province__c    = 'QC',
            Postal_Code__c = 'G1A 1A1'
        );
        Zeffy_Review_Ticket__c tkt = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.LinkPreview preview =
            ZeffyConnectDonationService.getLinkPreview(tkt.Id, a.Id);
        Test.stopTest();

        System.assertEquals(a.Id, preview.accountId);
        System.assertEquals('Marie Gagnon', preview.accountName);
        System.assertNotEquals(null, preview.emailFieldOptions, 'emailFieldOptions should be non-null');
        System.assertNotEquals(0, preview.existingZeffyIds.size(), 'Should list existing Zeffy IDs');
        System.assertEquals(false, preview.firstNamesDiffer, 'Names match — should be false');
        System.assertEquals(false, preview.lastNamesDiffer,  'Names match — should be false');
    }

    // ─── resolveCreateNew — organization type (else branch) ─────────────────

    @isTest
    static void testResolveCreateNewOrganization() {
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            Company_Name__c         = 'Org Test Inc.',
            Email__c                = 'org@test.ca',
            Amount__c               = 200.00,
            Eligible_Amount__c      = 200.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Contact_Id__c     = 'zeffy_org_001',
            Zeffy_Transaction_Id__c = 'txn_org_001'
        );
        Zeffy_Review_Ticket__c tkt = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.resolveCreateNew(tkt.Id, 'organization', null);
        Test.stopTest();

        List<Account> accts = [SELECT Name FROM Account WHERE Name = 'Org Test Inc.' LIMIT 1];
        System.assertEquals(1, accts.size(), 'Organization account should be created');
        System.assertEquals(1, [SELECT COUNT() FROM GiftTransaction]);
    }

    // ─── resolveCreateNew — eglise type with no company → buildFullName ──────

    @isTest
    static void testResolveCreateNewEgliseNoCompany() {
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Église',
            Last_Name__c            = 'Baptiste',
            Company_Name__c         = null,
            Amount__c               = 150.00,
            Eligible_Amount__c      = 150.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Transaction_Id__c = 'txn_eglise_001'
        );
        Zeffy_Review_Ticket__c tkt = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.resolveCreateNew(tkt.Id, 'eglise', null);
        Test.stopTest();

        List<Account> accts = [SELECT Name FROM Account WHERE Name LIKE '%Baptiste%' LIMIT 1];
        System.assertEquals(1, accts.size(), 'Account should be created from built full name');
        System.assertEquals(1, [SELECT COUNT() FROM GiftTransaction]);
    }

    // ─── resolveCreateNewEdited — reviewer corrects Zeffy values before creating ─

    @isTest
    static void testResolveCreateNewEditedIndividual() {
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'deb',
            Last_Name__c            = 'Witek',
            Email__c                = 'deb@gmial.com',
            Address__c              = '4 Delarine Dr',
            City__c                 = 'Burford',
            Amount__c               = 100.00,
            Eligible_Amount__c      = 100.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Contact_Id__c     = 'zeffy_edit_001',
            Zeffy_Transaction_Id__c = 'txn_edit_001'
        );
        Zeffy_Review_Ticket__c tkt = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.resolveCreateNewEdited(tkt.Id, 'individual', null, new Map<String, String>{
            'firstName' => 'Deb', 'lastName' => 'Wittek', 'email' => 'deb@gmail.com',
            'street' => '4 Delarine Drive', 'city' => 'Burford'
        });
        Test.stopTest();

        Account a = [SELECT Id, FirstName, LastName, PersonEmail, BillingStreet, BillingCity
                     FROM Account WHERE LastName = 'Wittek' LIMIT 1];
        System.assertEquals('Deb', a.FirstName);
        System.assertEquals('deb@gmail.com', a.PersonEmail);
        System.assertEquals('4 Delarine Drive', a.BillingStreet);
        System.assertEquals('Burford', a.BillingCity);

        Zeffy_Review_Ticket__c after = [SELECT First_Name__c, Email__c, Status__c, Resolution_Notes__c
                                        FROM Zeffy_Review_Ticket__c WHERE Id = :tkt.Id];
        System.assertEquals('deb', after.First_Name__c, 'Ticket keeps what Zeffy sent');
        System.assertEquals('deb@gmial.com', after.Email__c, 'Ticket keeps what Zeffy sent');
        System.assertEquals('Resolved - New Contact', after.Status__c);
        System.assertEquals(null, after.Resolution_Notes__c, 'Notes keep only what the reviewer wrote');

        Zeffy_Connect_Audit_Log__c log = [SELECT Notes__c, Account__c FROM Zeffy_Connect_Audit_Log__c
                                          WHERE Ticket__c = :tkt.Id AND Action__c = 'Account Created' LIMIT 1];
        System.assertEquals(a.Id, log.Account__c);
        System.assert(log.Notes__c.contains('Email "deb@gmial.com" → "deb@gmail.com"'), log.Notes__c);
        System.assert(log.Notes__c.contains('"4 Delarine Drive, Burford"'), log.Notes__c);
        System.assert(!log.Notes__c.contains('City "'), 'Unchanged values are not listed as corrections');
    }

    @isTest
    static void testResolveCreateNewEditedOrganizationName() {
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            Company_Name__c         = 'Eglsie Baptiste',
            Amount__c               = 50.00,
            Eligible_Amount__c      = 50.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Transaction_Id__c = 'txn_edit_002'
        );
        Zeffy_Review_Ticket__c tkt = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.resolveCreateNewEdited(tkt.Id, 'eglise', 'Typo', new Map<String, String>{
            'accountName' => 'Église Baptiste', 'phone' => '514-555-0100'
        });
        Test.stopTest();

        Account a = [SELECT Name, Phone FROM Account WHERE Name = 'Église Baptiste' LIMIT 1];
        System.assertEquals('514-555-0100', a.Phone);
        Zeffy_Review_Ticket__c after = [SELECT Company_Name__c, Resolution_Notes__c FROM Zeffy_Review_Ticket__c WHERE Id = :tkt.Id];
        System.assertEquals('Eglsie Baptiste', after.Company_Name__c);
        System.assertEquals('Typo', after.Resolution_Notes__c);
        String logNotes = [SELECT Notes__c FROM Zeffy_Connect_Audit_Log__c
                           WHERE Ticket__c = :tkt.Id AND Action__c = 'Account Created' LIMIT 1].Notes__c;
        System.assert(logNotes.contains('Account name "Eglsie Baptiste" → "Église Baptiste"'), logNotes);
    }

    // Plain link with Update (no corrections) still logs what the Account had before
    @isTest
    static void testLinkUpdateLogsBeforeAfterWithoutCorrections() {
        Account existing = makePersonAccount('Luc', 'Roy', 'luc.old@test.ca');
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Luc',
            Last_Name__c            = 'Roy',
            Email__c                = 'luc.new@test.ca',
            Amount__c               = 10.00,
            Eligible_Amount__c      = 10.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Transaction_Id__c = 'txn_log_003'
        );
        Zeffy_Review_Ticket__c tkt = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.resolveLinkExisting(tkt.Id, existing.Id, null, 'PersonEmail', false, false, false);
        Test.stopTest();

        String logNotes = [SELECT Notes__c FROM Zeffy_Connect_Audit_Log__c
                           WHERE Ticket__c = :tkt.Id AND Action__c = 'Account Updated' LIMIT 1].Notes__c;
        System.assert(logNotes.contains('"luc.old@test.ca" → "luc.new@test.ca"'), logNotes);
        System.assert(!logNotes.contains('corrected by the reviewer'), logNotes);
    }

    // ─── resolveLinkExisting — updateAddress = true ──────────────────────────

    @isTest
    static void testResolveLinkExistingUpdateAddress() {
        Account existing = makePersonAccount('Claire', 'Martin', 'claire@test.ca');
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Claire',
            Last_Name__c            = 'Martin',
            Email__c                = 'claire@test.ca',
            Address__c              = '10 rue Nouvelle',
            City__c                 = 'Laval',
            Province__c             = 'QC',
            Postal_Code__c          = 'H7A 1B2',
            Country__c              = 'CA',
            Amount__c               = 30.00,
            Eligible_Amount__c      = 30.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Contact_Id__c     = 'zeffy_addr_001',
            Zeffy_Transaction_Id__c = 'txn_addr_001'
        );
        Zeffy_Review_Ticket__c tkt = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.resolveLinkExisting(
            tkt.Id, existing.Id, null,
            null,   // emailTargetField
            true,   // updateAddress
            false,  // updateFirstName
            false   // updateLastName
        );
        Test.stopTest();

        Account updated = [SELECT BillingStreet, BillingCity FROM Account WHERE Id = :existing.Id];
        System.assertEquals('10 rue Nouvelle', updated.BillingStreet, 'BillingStreet should be updated');
        System.assertEquals('Laval', updated.BillingCity, 'BillingCity should be updated');
    }

    // ─── resolveLinkExistingEdited — reviewer corrects Zeffy values ─────────

    @isTest
    static void testResolveLinkExistingEditedValues() {
        Account existing = makePersonAccount('Sara', 'Fleury', 'old@test.ca');
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Sara',
            Last_Name__c            = 'Fleury',
            Email__c                = 'sara.typo@test.ca',
            Address__c              = '110 rue demers est',
            City__c                 = 'Princeville',
            Province__c             = 'QC',
            Postal_Code__c          = 'G6L 4M6',
            Country__c              = 'CA',
            Amount__c               = 25.00,
            Eligible_Amount__c      = 25.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Contact_Id__c     = 'zeffy_edit_001',
            Zeffy_Transaction_Id__c = 'txn_edit_001'
        );
        Zeffy_Review_Ticket__c tkt = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.resolveLinkExistingEdited(
            tkt.Id, existing.Id, 'Checked by phone',
            'PersonEmail', true, false, false,
            new Map<String, String>{
                'email'  => ' sara@test.ca ',
                'street' => '110 Rue Demers Est', // case-only fix must still apply
                'city'   => 'Princeville'         // unchanged → not logged
            }
        );
        Test.stopTest();

        Account a = [SELECT PersonEmail, BillingStreet, BillingCity, BillingPostalCode FROM Account WHERE Id = :existing.Id];
        System.assertEquals('sara@test.ca', a.PersonEmail, 'Corrected email (trimmed) should be saved');
        System.assertEquals('110 Rue Demers Est', a.BillingStreet, 'Case-only correction should be saved');
        System.assertEquals('G6L 4M6', a.BillingPostalCode, 'Unedited part keeps the Zeffy value');

        Zeffy_Review_Ticket__c after = [SELECT Email__c, Address__c, Resolution_Notes__c FROM Zeffy_Review_Ticket__c WHERE Id = :tkt.Id];
        System.assertEquals('sara.typo@test.ca', after.Email__c, 'Ticket keeps what Zeffy sent');
        System.assertEquals('110 rue demers est', after.Address__c, 'Ticket keeps what Zeffy sent');
        System.assertEquals('Checked by phone', after.Resolution_Notes__c, 'Notes keep only what the reviewer wrote');

        Zeffy_Connect_Audit_Log__c log = [SELECT Notes__c, Account__c FROM Zeffy_Connect_Audit_Log__c
                                          WHERE Ticket__c = :tkt.Id AND Action__c = 'Account Updated' LIMIT 1];
        System.assertEquals(existing.Id, log.Account__c);
        System.assert(log.Notes__c.contains('"old@test.ca" → "sara@test.ca"'), 'Before → after of the Account: ' + log.Notes__c);
        System.assert(log.Notes__c.contains('Billing address: (empty) → "110 Rue Demers Est'), log.Notes__c);
        System.assert(log.Notes__c.contains('Email "sara.typo@test.ca" → "sara@test.ca"'), 'Reviewer correction: ' + log.Notes__c);
        System.assert(!log.Notes__c.contains('City "'), 'Unchanged Zeffy values are not listed as corrections');
    }

    // ─── resolveLinkExisting — emailTargetField set ──────────────────────────

    @isTest
    static void testResolveLinkExistingWithEmailField() {
        Account existing = makePersonAccount('Paul', 'Leblanc', null);
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Paul',
            Last_Name__c            = 'Leblanc',
            Email__c                = 'paul.lb@test.ca',
            Amount__c               = 75.00,
            Eligible_Amount__c      = 75.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Contact_Id__c     = 'zeffy_email_001',
            Zeffy_Transaction_Id__c = 'txn_email_001'
        );
        Zeffy_Review_Ticket__c tkt = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        Test.startTest();
        ZeffyConnectDonationService.resolveLinkExisting(
            tkt.Id, existing.Id, null,
            'PersonEmail',  // emailTargetField
            false,          // updateAddress
            false,          // updateFirstName
            false           // updateLastName
        );
        Test.stopTest();

        Account updated = [SELECT PersonEmail FROM Account WHERE Id = :existing.Id];
        System.assertEquals('paul.lb@test.ca', updated.PersonEmail, 'PersonEmail should be updated');
    }

    // ─── closeOpenTasks — body covered when ticket has pending task ───────────

    @isTest
    static void testCloseOpenTasksBody() {
        Account a = makePersonAccount('Task', 'Closer', 'taskcloser@test.ca');
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Task',
            Last_Name__c            = 'Closer',
            Email__c                = 'taskcloser@test.ca',
            Amount__c               = 20.00,
            Eligible_Amount__c      = 20.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Contact_Id__c     = 'zeffy_taskcloser',
            Zeffy_Transaction_Id__c = 'txn_taskcloser_001'
        );
        Zeffy_Review_Ticket__c tkt = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];
        insert new Task(
            Subject      = 'Review ticket',
            WhatId       = tkt.Id,
            Status       = 'Not Started',
            ActivityDate = Date.today().addDays(2)
        );

        Test.startTest();
        ZeffyConnectDonationService.resolveLinkExisting(
            tkt.Id, a.Id, null, null, false, false, false
        );
        Test.stopTest();

        List<Task> tasks = [SELECT Status FROM Task WHERE WhatId = :tkt.Id];
        System.assertEquals('Completed', tasks[0].Status, 'Task should be closed after resolution');
    }

    // ─── getTickets — 'Assigned' filter (WHERE Manual_Assignee_Id__c != null) ─

    @isTest
    static void testGetTicketsAssignedFilter() {
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            Manual_Assignee_Id__c   = UserInfo.getUserId(),
            Manual_Assignee_Name__c = 'Test User',
            Zeffy_Transaction_Id__c = 'txn_assigned_001'
        );

        Test.startTest();
        List<Zeffy_Review_Ticket__c> results = ZeffyConnectDonationService.getTickets('Assigned');
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Assigned filter should return tickets with assignee set');
    }

    @isTest
    static void testFindAccountMatchesSort() {
        // 2 accounts with same last name → findAccountMatches triggers List.sort() → compareTo (lines 133-134)
        makePersonAccount('Alice', 'Dupont', 'alice.dup@test.ca');
        makePersonAccount('Bob',   'Dupont', 'bob.dup@test.ca');
        insert new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', Last_Name__c = 'Dupont', First_Name__c = 'Alice',
            Email__c = 'alice.dup@test.ca', Zeffy_Transaction_Id__c = 'txn_sort_001'
        );
        Zeffy_Review_Ticket__c tkt = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];
        Test.startTest();
        List<ZeffyConnectDonationService.AccountMatch> matches =
            ZeffyConnectDonationService.findAccountMatches(tkt.Id);
        Test.stopTest();
        System.assert(matches.size() >= 1, 'Should find at least one matching account');
    }

    @isTest
    static void testProcessWebhookEventDataNull() {
        // JSON parses OK but data field absent → lines 274-276
        Test.startTest();
        ZeffyConnectDonationService.WebhookResult r =
            ZeffyConnectDonationService.processWebhookWithResult('{"type":"payment.completed","id":"evt_null_001"}');
        Test.stopTest();
        System.assertEquals('INVALID_JSON', r.status, 'Should return INVALID_JSON when data is null');
    }

    @isTest
    static void testGetTicketsOpenFilter() {
        // Covers the WHERE NOT IN branch for Open filter — line 961
        insert new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', Zeffy_Transaction_Id__c = 'txn_open_filter_001'
        );
        Test.startTest();
        List<Zeffy_Review_Ticket__c> results = ZeffyConnectDonationService.getTickets('Open');
        Test.stopTest();
        System.assert(!results.isEmpty(), 'Open filter should return pending tickets');
    }

    @isTest
    static void testFormatCanadianPostal() {
        // CA without space → ticket Postal_Code__c gets space inserted (no identity → creates ticket)
        String rawCa = '{"type":"payment.completed","data":{"id":"txn_postal_ca_001",' +
            '"amount":2000,"eligible_amount":2000,"currency":"cad",' +
            '"contact":"zeffy_postal_ca_uuid_001",' +
            '"buyer":{"email":"postal.ca.unknown@test.ca","first_name":"Postal","last_name":"CA","is_corporate":false,' +
            '"address":{"line1":"123 Main St","city":"Vancouver","state":"BC","postal_code":"V6B1A1","country":"CA"}},' +
            '"payment_method":{"type":"card","brand":"visa","last4":"1111"},' +
            '"created":1737000000,"receipt_url":null,' +
            '"campaign_id":null,"campaign_type":"donation_form","campaign_category":"donation",' +
            '"description":null,"refund_status":"none","refunds":[],' +
            '"dispute":null,"fund":null,"discount":null,"recurring":null,"buyer_questions":[],' +
            '"items":[{"type":"donation","amount":2000}]}}';
        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(rawCa);
        Test.stopTest();
        Zeffy_Review_Ticket__c tktCa = [SELECT Postal_Code__c FROM Zeffy_Review_Ticket__c
            WHERE Zeffy_Transaction_Id__c = 'txn_postal_ca_001' LIMIT 1];
        System.assertEquals('V6B 1A1', tktCa.Postal_Code__c, 'CA postal code should have space inserted');

        // Non-CA country → postal code unchanged
        String rawUs = '{"type":"payment.completed","data":{"id":"txn_postal_us_001",' +
            '"amount":2000,"eligible_amount":2000,"currency":"usd",' +
            '"contact":"zeffy_postal_us_uuid_001",' +
            '"buyer":{"email":"postal.us.unknown@test.ca","first_name":"Postal","last_name":"US","is_corporate":false,' +
            '"address":{"line1":"456 Oak Ave","city":"Seattle","state":"WA","postal_code":"981011234","country":"US"}},' +
            '"payment_method":{"type":"card","brand":"visa","last4":"2222"},' +
            '"created":1737000001,"receipt_url":null,' +
            '"campaign_id":null,"campaign_type":"donation_form","campaign_category":"donation",' +
            '"description":null,"refund_status":"none","refunds":[],' +
            '"dispute":null,"fund":null,"discount":null,"recurring":null,"buyer_questions":[],' +
            '"items":[{"type":"donation","amount":2000}]}}';
        ZeffyConnectDonationService.processWebhookWithResult(rawUs);
        Zeffy_Review_Ticket__c tktUs = [SELECT Postal_Code__c FROM Zeffy_Review_Ticket__c
            WHERE Zeffy_Transaction_Id__c = 'txn_postal_us_001' LIMIT 1];
        System.assertEquals('981011234', tktUs.Postal_Code__c, 'Non-CA postal code should not be modified');
    }

    @isTest
    static void testGetFirstRateTitleAllBlank() {
        // items non-empty but all rate_title null → getFirstRateTitle loops and returns null (line 1240)
        Account a = makePersonAccount('Rate', 'Blank', 'rate.blank@test.ca');
        linkIdentity(a.Id, 'zeffy_rate_blank_001', 'rate.blank@test.ca');
        String rawBody = '{"type":"payment.completed","data":{"id":"txn_rate_blank_001",' +
            '"amount":3000,"eligible_amount":3000,"currency":"cad",' +
            '"contact":"zeffy_rate_blank_001",' +
            '"buyer":{"email":"rate.blank@test.ca","first_name":"Rate","last_name":"Blank","is_corporate":false},' +
            '"payment_method":{"type":"card","brand":"visa","last4":"9999"},' +
            '"created":1737000000,"receipt_url":null,' +
            '"campaign_id":null,"campaign_type":"donation_form","campaign_category":"donation",' +
            '"description":null,"refund_status":"none","refunds":[],' +
            '"dispute":null,"fund":null,"discount":null,"recurring":null,' +
            '"buyer_questions":[],' +
            '"items":[{"id":"i1","type":"donation","amount":3000,"rate_title":null}]}}';
        Test.startTest();
        ZeffyConnectDonationService.WebhookResult r =
            ZeffyConnectDonationService.processWebhookWithResult(rawBody);
        Test.stopTest();
        System.assertEquals('SUCCESS', r.status, 'Should auto-process known donor');
    }

    @isTest
    static void testGiftCommitmentInsertException() {
        // failCommitmentInsert forces exception inside try block — covers line 1104
        Account a = makePersonAccount('Commit', 'Fail', 'commit.fail@test.ca');
        insert new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', First_Name__c = 'Commit', Last_Name__c = 'Fail',
            Email__c = 'commit.fail@test.ca', Amount__c = 50.00, Eligible_Amount__c = 50.00,
            Payment_Method__c = 'Credit Card', Payment_Type__c = 'Donation',
            Gift_Date__c = Date.today(), Zeffy_Transaction_Id__c = 'txn_commit_fail_001',
            Is_Recurring__c = true, Zeffy_Subscription_Id__c = 'sub_commit_fail_001'
        );
        Zeffy_Review_Ticket__c tkt = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];
        ZeffyConnectDonationService.failCommitmentInsert = true;
        Test.startTest();
        ZeffyConnectDonationService.resolveLinkExisting(tkt.Id, a.Id, null, null, false, false, false);
        Test.stopTest();
        ZeffyConnectDonationService.failCommitmentInsert = false;
        System.assertEquals(1, [SELECT COUNT() FROM GiftTransaction],
            'GiftTransaction should be created despite commitment failure');
    }

    @isTest
    static void testGetDashboardStatsPopulated() {
        // Populates GiftTransaction + resolved ticket + 2 pending dups to cover lines 1313-1314, 1363-1368, 1381-1382
        Account a = makePersonAccount('Dash', 'Stats', 'dash.stats@test.ca');
        insert new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', First_Name__c = 'Dash', Last_Name__c = 'Stats',
            Email__c = 'dash.stats@test.ca', Amount__c = 100.00, Eligible_Amount__c = 100.00,
            Payment_Method__c = 'Credit Card', Payment_Type__c = 'Donation',
            Gift_Date__c = Date.today(), Zeffy_Transaction_Id__c = 'txn_dash_001',
            Zeffy_Contact_Id__c = 'zeffy_dash_001'
        );
        Zeffy_Review_Ticket__c tkt = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];
        ZeffyConnectDonationService.resolveLinkExisting(tkt.Id, a.Id, null, null, false, false, false);
        insert new List<Zeffy_Review_Ticket__c>{
            new Zeffy_Review_Ticket__c(
                Status__c = 'Pending Review', Zeffy_Transaction_Id__c = 'txn_dup_dash_001',
                Zeffy_Contact_Id__c = 'zeffy_dup_dash'
            ),
            new Zeffy_Review_Ticket__c(
                Status__c = 'Pending Review', Zeffy_Transaction_Id__c = 'txn_dup_dash_002',
                Zeffy_Contact_Id__c = 'zeffy_dup_dash'
            )
        };
        Test.startTest();
        Map<String, Object> stats = ZeffyConnectDonationService.getDashboardStats();
        Test.stopTest();
        System.assertNotEquals(null, stats.get('byStatus'));
        System.assertNotEquals(null, stats.get('weekly'));
        System.assertNotEquals(null, stats.get('duplicateContactIds'));
        System.assert(((List<String>) stats.get('duplicateContactIds')).size() >= 1,
            'Should detect duplicate contact IDs');
    }

    @isTest
    static void testGetAuditLogWithAccountSearch() {
        // Account email matches search → matchAccIds loop runs — line 1509
        makePersonAccount('Audit', 'Search', 'audit.search@test.ca');
        Test.startTest();
        List<Zeffy_Connect_Audit_Log__c> logs =
            ZeffyConnectDonationService.getAuditLog('audit.search');
        Test.stopTest();
        System.assertNotEquals(null, logs, 'Should return a list (possibly empty) with no exception');
    }

    @isTest
    static void testGetDonationHistoryAccountAndTicketLoops() {
        // Account PersonHomePhone matches search (line 1564); resolved ticket name matches (line 1571)
        Account a = makePersonAccount('DonHist', 'Searcher', null);
        a.PersonHomePhone = 'ZRT-HISTTEST';
        update a;
        insert new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', First_Name__c = 'DonHist', Last_Name__c = 'Searcher',
            Amount__c = 30.00, Eligible_Amount__c = 30.00,
            Payment_Method__c = 'Credit Card', Payment_Type__c = 'Donation',
            Gift_Date__c = Date.today(), Zeffy_Transaction_Id__c = 'txn_donhist_001'
        );
        Zeffy_Review_Ticket__c tkt = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];
        ZeffyConnectDonationService.resolveLinkExisting(tkt.Id, a.Id, null, null, false, false, false);
        Test.startTest();
        List<ZeffyConnectDonationService.DonationHistoryRow> rows =
            ZeffyConnectDonationService.getDonationHistory('ZRT-');
        Test.stopTest();
        System.assertNotEquals(null, rows, 'Should return history rows without exception');
    }

    @isTest
    static void testGetMyTasksWithOpenTask() {
        // Open Task linked to a Zeffy ticket for the running user → getMyTasks loop body runs (lines 1645-1652)
        insert new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', Zeffy_Transaction_Id__c = 'txn_mytask_001'
        );
        Zeffy_Review_Ticket__c tkt = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];
        insert new Task(
            Subject      = 'Review pending donation — My Task Test',
            WhatId       = tkt.Id,
            OwnerId      = UserInfo.getUserId(),
            Status       = 'Not Started',
            ActivityDate = Date.today().addDays(3)
        );
        Test.startTest();
        List<Map<String, Object>> tasks = ZeffyConnectDonationService.getMyTasks();
        Test.stopTest();
        System.assertEquals(1, tasks.size(), 'Should return the open task');
    }

    @isTest
    static void testClearTicketAssignmentWithCompanyName() {
        // First_Name and Last_Name blank → donorName ternary uses Company_Name__c (line 1718)
        insert new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', Company_Name__c = 'ACME Corp',
            Zeffy_Transaction_Id__c = 'txn_clear_assign_001'
        );
        Zeffy_Review_Ticket__c tkt = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];
        Test.startTest();
        ZeffyConnectDonationService.clearTicketAssignment(tkt.Id);
        Test.stopTest();
        Zeffy_Review_Ticket__c updated =
            [SELECT Manual_Assignee_Id__c FROM Zeffy_Review_Ticket__c WHERE Id = :tkt.Id];
        System.assertEquals(null, updated.Manual_Assignee_Id__c);
    }

    @isTest
    static void testImportTicketsMethodFallbackAndDuplicateError() {
        // Row 1: payment_method 'BITCOIN' → mapPaymentMethod fallback returns 'Credit Card' (line 1215)
        // Both rows share same txId → first inserted, second fails DML → errors list (line 1776)
        String today = String.valueOf(Date.today());
        String rowsJson = '[' +
            '{"transaction_id":"txn_import_dup_001","payment_method":"BITCOIN",' +
            '"amount":"15.00","eligible_amount":"15.00","gift_date":"' + today + '"},' +
            '{"transaction_id":"txn_import_dup_001","payment_method":"CARD",' +
            '"amount":"15.00","eligible_amount":"15.00","gift_date":"' + today + '"}' +
            ']';
        Test.startTest();
        Map<String, Object> result = ZeffyConnectDonationService.importTickets(rowsJson);
        Test.stopTest();
        System.assertEquals(1, result.get('imported'), 'First row should be imported');
        System.assert(!((List<String>) result.get('errors')).isEmpty(),
            'Second duplicate row should produce a DML error');
    }

    @isTest
    static void testGetTransactionTimeline() {
        // Zeffy_Webhook_Log__c with matching Transaction_Id__c → timeline loop body runs (lines 1849-1866)
        insert new Zeffy_Webhook_Log__c(
            Transaction_Id__c = 'txn_timeline_001',
            Occurred_At__c    = Datetime.now(),
            Event_Type__c     = 'payment.completed',
            Status__c         = 'SUCCESS',
            Message__c        = 'Timeline test entry'
        );
        Test.startTest();
        List<ZeffyConnectDonationService.TimelineEntry> timeline =
            ZeffyConnectDonationService.getTransactionTimeline('txn_timeline_001');
        Test.stopTest();
        System.assertEquals(1, timeline.size(), 'Should return one timeline entry');
        System.assertEquals('payment.completed', timeline[0].eventType);
        System.assertEquals('SUCCESS', timeline[0].status);
    }

    // ─── Non-duplicate DML error → TICKET_INSERT_FAILED (lines 328-330) ────────

    @isTest
    static void testNonDuplicateDmlErrorReturnsTicketInsertFailed() {
        // Campaign insert without Name = REQUIRED_FIELD_MISSING (not a dup error) → else branch
        ZeffyConnectDonationService.forceDmlBeforeProcess = true;
        Test.startTest();
        ZeffyConnectDonationService.WebhookResult res =
            ZeffyConnectDonationService.processWebhookWithResult(
                buildPayload('txn_dml_err_001', 'dml@test.ca', 'zeffy_dml_001'));
        Test.stopTest();
        ZeffyConnectDonationService.forceDmlBeforeProcess = false;

        System.assertEquals('TICKET_INSERT_FAILED', res.status,
            'Non-duplicate DML error should return TICKET_INSERT_FAILED');
        System.assert(res.detail != null && res.detail.contains('DmlException'),
            'Detail should identify the DmlException type');
    }

    // ─── General Exception (non-DML) → TICKET_INSERT_FAILED (lines 332-335) ──

    @isTest
    static void testGeneralExceptionReturnsTicketInsertFailed() {
        ZeffyConnectDonationService.forceExceptionBeforeProcess = true;
        Test.startTest();
        ZeffyConnectDonationService.WebhookResult res =
            ZeffyConnectDonationService.processWebhookWithResult(
                buildPayload('txn_exc_001', 'exc@test.ca', 'zeffy_exc_001'));
        Test.stopTest();
        ZeffyConnectDonationService.forceExceptionBeforeProcess = false;

        System.assertEquals('TICKET_INSERT_FAILED', res.status,
            'General exception should return TICKET_INSERT_FAILED');
        System.assert(res.detail != null && res.detail.contains('ForcedTestException'),
            'Detail should identify the exception type');
    }

    // ─── extractBuyerQuestionsText exception → returns null silently (lines 1324-1325) ──

    @isTest
    static void testExtractBuyerQuestionsExceptionIsSilent() {
        ZeffyConnectDonationService.failExtractBuyerQuestions = true;
        Test.startTest();
        ZeffyConnectDonationService.WebhookResult res =
            ZeffyConnectDonationService.processWebhookWithResult(
                buildPayload('txn_bq_exc_001', 'bq@test.ca', 'zeffy_bq_001'));
        Test.stopTest();
        ZeffyConnectDonationService.failExtractBuyerQuestions = false;

        System.assertEquals('SUCCESS', res.status,
            'Buyer questions parse failure should be silent — review ticket created normally');
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Review_Ticket__c],
            'Review ticket should be created even when buyer questions extraction fails');
    }

    // ─── undoResolution: gift delete failure aborts the whole undo ───────────

    @isTest
    static void testUndoResolutionGiftDeleteFailureAborts() {
        Account donor = makePersonAccount('Undo', 'Test', 'undo.gift@test.ca');
        GiftTransaction gt = new GiftTransaction(
            Name                    = 'ZF-undo-gift-001',
            DonorId                 = donor.Id,
            OriginalAmount          = 50,
            PaymentMethod           = 'Credit Card',
            GiftType                = 'Individual',
            Status                  = 'Paid',
            TransactionDate         = Date.today(),
            Zeffy_Transaction_Id__c = 'txn_undo_gift_001'
        );
        insert gt;
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Resolved - Linked',
            Zeffy_Transaction_Id__c = 'txn_undo_gift_001',
            Resolved_Account__c     = donor.Id,
            Resolved_Gift__c        = gt.Id,
            Amount__c               = 50.00
        );
        Zeffy_Review_Ticket__c tkt = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1];

        ZeffyConnectDonationService.failGiftDelete = true;
        Boolean threw = false;
        Test.startTest();
        try {
            ZeffyConnectDonationService.undoResolution(tkt.Id);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        ZeffyConnectDonationService.failGiftDelete = false;

        System.assert(threw, 'Undo must fail loudly when the gift cannot be deleted');
        Zeffy_Review_Ticket__c still = [SELECT Status__c, Resolved_Gift__c FROM Zeffy_Review_Ticket__c LIMIT 1];
        System.assertEquals('Resolved - Linked', still.Status__c,
            'Ticket stays resolved — reopening it would allow a second gift for the same payment');
        System.assertEquals(gt.Id, still.Resolved_Gift__c);
        System.assertEquals(1, [SELECT COUNT() FROM GiftTransaction WHERE Id = :gt.Id]);
    }

    // ─── HOLDING ticket graduation — donor found → auto-resolve ──────────────

    @isTest
    static void testHoldingTicketAutoResolveWithDonor() {
        // Setup: Person Account + Zeffy Identity + HOLDING ticket
        Account donor = makePersonAccount('Marie', 'Tremblay', 'marie.hold@test.ca');
        linkIdentity(donor.Id, 'zeffy_hold_contact_001', 'marie.hold@test.ca');
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Holding',
            Email__c                = 'marie.hold@test.ca',
            Amount__c               = 75.00,
            Eligible_Amount__c      = 75.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Transaction_Id__c = 'txn_hold_auto_001'
        );

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult res =
            ZeffyConnectDonationService.processWebhookWithResult(
                buildPayload('txn_hold_auto_001', 'marie.hold@test.ca', 'zeffy_hold_contact_001'));
        Test.stopTest();

        System.assertEquals('SUCCESS', res.status, 'Should auto-resolve the HOLDING ticket');
        Zeffy_Review_Ticket__c tkt = [SELECT Status__c FROM Zeffy_Review_Ticket__c LIMIT 1];
        System.assertEquals('Auto-Processed', tkt.Status__c, 'Robot-resolved ticket is marked Auto-Processed');
        System.assertEquals(1, [SELECT COUNT() FROM GiftTransaction], 'GiftTransaction should be created');
    }

    // ─── HOLDING ticket graduation — no donor → Pending Review ───────────────

    @isTest
    static void testHoldingTicketGraduatesNoDonor() {
        // Setup: HOLDING ticket with no matching Account/Identity
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Holding',
            Email__c                = 'unknown.hold@test.ca',
            Amount__c               = 50.00,
            Eligible_Amount__c      = 50.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Transaction_Id__c = 'txn_hold_pend_001'
        );

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult res =
            ZeffyConnectDonationService.processWebhookWithResult(
                buildPayload('txn_hold_pend_001', 'unknown.hold@test.ca', 'zeffy_nomatch_hold'));
        Test.stopTest();

        System.assertEquals('SUCCESS', res.status, 'Should succeed even when donor not found');
        Zeffy_Review_Ticket__c tkt = [SELECT Status__c FROM Zeffy_Review_Ticket__c LIMIT 1];
        System.assertEquals('Pending Review', tkt.Status__c, 'Ticket should graduate to Pending Review');
        System.assertEquals(0, [SELECT COUNT() FROM GiftTransaction], 'No GiftTransaction should be created');
    }

    // ─── Refund handling — GiftTransaction path ────────────────────────────────

    @isTest
    static void testRefundFullyOnGiftTransaction() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Updated__c = true;
        update cfg;

        Account donor = makePersonAccount('Marie', 'Refund', 'marie.refund@test.ca');
        linkIdentity(donor.Id, 'zeffy_ref_full', 'marie.refund@test.ca');
        // Create GiftTransaction via service (payment.completed)
        ZeffyConnectDonationService.processWebhook(buildPayload('txn_ref_full_001', 'marie.refund@test.ca', 'zeffy_ref_full'));

        String refundPayload =
            '{"id":"evt_rf1","type":"payment.updated","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"txn_ref_full_001","status":"refunded","amount":5000,"eligible_amount":4000,' +
            '"currency":"cad","contact":"zeffy_ref_full","buyer":null,"payment_method":null,' +
            '"created":1737000000,"receipt_url":"https://zeffy.com/r/ref001",' +
            '"refund_status":"refunded","refunds":[{"id":"r1","amount":5000,"status":"succeeded","created":1737010000}],' +
            '"dispute":null,"fund":null,"discount":null,"campaign_id":null,"campaign_type":null,' +
            '"campaign_category":null,"description":null,"buyer_questions":[],"items":[],"recurring":null}}';

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult result =
            ZeffyConnectDonationService.processWebhookWithResult(refundPayload);
        Test.stopTest();

        System.assertEquals('SUCCESS', result.status);
        GiftTransaction gt = [SELECT Status, IsFullyRefunded, Refund_Amount__c, Refund_Date__c, Receipt_URL__c
                              FROM GiftTransaction WHERE Zeffy_Transaction_Id__c = 'txn_ref_full_001'];
        System.assertEquals('Fully Refunded', gt.Status,  'Status should be Fully Refunded');
        System.assertEquals(50.00, gt.Refund_Amount__c,   'Refund amount: 5000 cents = $50');
        System.assertNotEquals(null, gt.Refund_Date__c,   'Refund date should be set');
        System.assertEquals('https://zeffy.com/r/ref001', gt.Receipt_URL__c);
    }

    @isTest
    static void testRefundPartialOnGiftTransaction() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Updated__c = true;
        update cfg;

        Account donor = makePersonAccount('Jean', 'Partial', 'jean.partial@test.ca');
        linkIdentity(donor.Id, 'zeffy_ref_part', 'jean.partial@test.ca');
        ZeffyConnectDonationService.processWebhook(buildPayload('txn_ref_part_001', 'jean.partial@test.ca', 'zeffy_ref_part'));

        String refundPayload =
            '{"id":"evt_rp1","type":"payment.updated","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"txn_ref_part_001","status":"partially_refunded","amount":5000,"eligible_amount":4000,' +
            '"currency":"cad","contact":"zeffy_ref_part","buyer":null,"payment_method":null,' +
            '"created":1737000000,"receipt_url":null,' +
            '"refund_status":"partially_refunded","refunds":[{"id":"r2","amount":2500,"status":"succeeded","created":1737020000}],' +
            '"dispute":null,"fund":null,"discount":null,"campaign_id":null,"campaign_type":null,' +
            '"campaign_category":null,"description":null,"buyer_questions":[],"items":[],"recurring":null}}';

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult result =
            ZeffyConnectDonationService.processWebhookWithResult(refundPayload);
        Test.stopTest();

        System.assertEquals('SUCCESS', result.status);
        GiftTransaction gt = [SELECT Status, IsPartiallyRefunded, Refund_Amount__c, Refund_Date__c
                              FROM GiftTransaction WHERE Zeffy_Transaction_Id__c = 'txn_ref_part_001'];
        System.assertEquals('Paid', gt.Status,         'Status should stay Paid for partial refund');
        System.assertEquals(25.00, gt.Refund_Amount__c, 'Refund amount: 2500 cents = $25');
        System.assertNotEquals(null, gt.Refund_Date__c, 'Refund date should be set');
    }

    @isTest
    static void testRefundOnResolvedTicket() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Updated__c = true;
        update cfg;

        // Create donor + GT + resolved ticket (simulates a donation already processed)
        Account donor = makePersonAccount('Paul', 'Resolve', 'paul.resolve@test.ca');
        GiftTransaction gt = new GiftTransaction(
            Name               = 'ZF-txn_res_ref_001',
            DonorId            = donor.Id,
            Status             = 'Paid',
            PaymentMethod      = 'Credit Card',
            OriginalAmount     = 100.00,
            TransactionDate    = Date.today(),
            Zeffy_Transaction_Id__c = 'txn_res_ref_001'
        );
        insert gt;
        insert new Zeffy_Review_Ticket__c(
            Status__c               = 'Resolved - Linked',
            Email__c                = 'paul.resolve@test.ca',
            Amount__c               = 100.00,
            Eligible_Amount__c      = 100.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Transaction_Id__c = 'txn_res_ref_001',
            Resolved_Gift__c        = gt.Id
        );

        String refundPayload =
            '{"id":"evt_rr1","type":"payment.updated","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"txn_res_ref_001","status":"refunded","amount":10000,"eligible_amount":10000,' +
            '"currency":"cad","contact":"zeffy_res_ref","buyer":null,"payment_method":null,' +
            '"created":1737000000,"receipt_url":null,' +
            '"refund_status":"refunded","refunds":[{"id":"r3","amount":10000,"status":"succeeded","created":1737030000}],' +
            '"dispute":null,"fund":null,"discount":null,"campaign_id":null,"campaign_type":null,' +
            '"campaign_category":null,"description":null,"buyer_questions":[],"items":[],"recurring":null}}';

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult result =
            ZeffyConnectDonationService.processWebhookWithResult(refundPayload);
        Test.stopTest();

        System.assertEquals('SUCCESS', result.status);
        GiftTransaction updated = [SELECT Status, IsFullyRefunded, Refund_Amount__c, Refund_Date__c
                                   FROM GiftTransaction WHERE Id = :gt.Id];
        System.assertEquals('Fully Refunded', updated.Status,  'GT status should be Fully Refunded');
        System.assertEquals(100.00, updated.Refund_Amount__c,  'GT refund amount: 10000 cents = $100');
        System.assertNotEquals(null, updated.Refund_Date__c,   'GT refund date should be set');
    }

    @isTest
    static void testResolveTicketWithPendingRefundPropagatesRefundToGT() {
        // Ticket ya tiene refund registrado (payment.updated llegó antes de la asignación)
        // Al hacer resolveCreateNew, el GT debe nacer con Status='Fully Refunded' y Refund_Amount__c
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Updated__c = true;
        update cfg;

        // Simular que el webhook payment.created creó un ticket...
        ZeffyConnectDonationService.processWebhook(
            buildPayload('txn_pending_refund_001', 'pending.refund@test.ca', 'zeffy_pr_001'));

        // ...y luego llegó payment.updated con reembolso total antes de que el staff asignara
        String refundPayload =
            '{"id":"evt_pr1","type":"payment.updated","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"txn_pending_refund_001","status":"refunded","amount":7500,"eligible_amount":7500,' +
            '"currency":"cad","contact":"zeffy_pr_001","buyer":null,"payment_method":null,' +
            '"created":1737000000,"receipt_url":null,' +
            '"refund_status":"refunded","refunds":[{"id":"r9","amount":7500,"status":"succeeded","created":1737050000}],' +
            '"dispute":null,"fund":null,"discount":null,"campaign_id":null,"campaign_type":null,' +
            '"campaign_category":null,"description":null,"buyer_questions":[],"items":[],"recurring":null}}';
        ZeffyConnectDonationService.processWebhookWithResult(refundPayload);

        // Verificar que el ticket tiene los datos de reembolso
        Zeffy_Review_Ticket__c tkt = [SELECT Id, Refund_Status__c, Refund_Amount__c
                                      FROM Zeffy_Review_Ticket__c
                                      WHERE Zeffy_Transaction_Id__c = 'txn_pending_refund_001' LIMIT 1];
        System.assertEquals('refunded', tkt.Refund_Status__c, 'Ticket debe tener Refund_Status__c');
        System.assertEquals(75.00, tkt.Refund_Amount__c,      'Ticket debe tener Refund_Amount__c');

        // Ahora el staff asigna el ticket — el GT debe nacer con el reembolso ya aplicado
        Test.startTest();
        ZeffyConnectDonationService.resolveCreateNew(tkt.Id, 'individual', 'Test notes');
        Test.stopTest();

        GiftTransaction gt = [SELECT Status, Refund_Amount__c FROM GiftTransaction
                              WHERE Zeffy_Transaction_Id__c = 'txn_pending_refund_001' LIMIT 1];
        System.assertEquals('Fully Refunded', gt.Status,  'GT debe nacer con Status Fully Refunded');
        System.assertEquals(75.00, gt.Refund_Amount__c,   'GT debe tener Refund_Amount__c del ticket');
    }

    // ─── Bulk resolve ─────────────────────────────────────────────────────────

    private static Zeffy_Review_Ticket__c bulkTicket(String txId, String zeffyId) {
        return new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Bulk',
            Last_Name__c            = 'Donor',
            Email__c                = 'bulk@test.ca',
            Amount__c               = 20.00,
            Eligible_Amount__c      = 20.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Contact_Id__c     = zeffyId,
            Zeffy_Transaction_Id__c = txId
        );
    }

    // Campaign.Name max 80 chars — unknown form + 100-char name forces a DML failure per ticket
    // Campaign creation is non-critical now (a failure no longer blocks the gift), so the
    // failure is forced on the gift itself for this transaction ID.
    private static Zeffy_Review_Ticket__c failingBulkTicket(String txId) {
        Zeffy_Review_Ticket__c t = bulkTicket(txId, null);
        t.Email__c = txId + '@fail.test.ca';   // own donor group: bulk create-new groups by email
        ZeffyConnectDonationService.failGiftForTxId = txId;
        return t;
    }

    @isTest
    static void testBulkResolveLinkExisting() {
        Account donor = makePersonAccount('Bulk', 'Link', 'bulklink@test.ca');
        List<Zeffy_Review_Ticket__c> ts = new List<Zeffy_Review_Ticket__c>{
            bulkTicket('txn_bulk_link_001', 'zeffy_bulk_link'),
            bulkTicket('txn_bulk_link_002', null),
            failingBulkTicket('txn_bulk_link_003')
        };
        insert ts;

        Test.startTest();
        Map<String,Object> res = ZeffyConnectDonationService.bulkResolveLinkExisting(
            new List<Id>{ ts[0].Id, ts[1].Id, ts[2].Id }, donor.Id, 'bulk');
        Test.stopTest();

        System.assertEquals(2, res.get('resolved'), 'Two valid tickets should resolve: ' + res.get('errors'));
        System.assertEquals(1, ((List<String>) res.get('errors')).size(), 'Failing ticket reported as error');
        System.assertEquals(2, [SELECT COUNT() FROM GiftTransaction WHERE DonorId = :donor.Id]);
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Identity__c WHERE Zeffy_Contact_Id__c = 'zeffy_bulk_link']);
    }

    @isTest
    static void testBulkResolveLinkExistingEdited() {
        Account donor = makePersonAccount('Bulk', 'Edited', 'bulkedited@test.ca');
        List<Zeffy_Review_Ticket__c> ts = new List<Zeffy_Review_Ticket__c>{
            bulkTicket('txn_bulk_edit_001', 'zeffy_bulk_edit'),
            bulkTicket('txn_bulk_edit_002', 'zeffy_bulk_edit')
        };
        insert ts;

        Map<String, String> values = new Map<String, String>{
            'BillingStreet'  => '88 Boul. Industriel',
            'BillingCity'    => 'Laval',
            'BillingState'   => '',
            'LastName'       => 'Edited-Group',
            'FirstName'      => '',              // names of an existing account are ignored
            'PersonEmail'    => '',              // an email field is never blanked
            'Not_A_Field__c' => 'ignored',       // not an allowed field
            'Description'    => 'ignored'        // real field, but not an allowed one
        };
        Test.startTest();
        Map<String,Object> res = ZeffyConnectDonationService.bulkResolveLinkExistingEdited(
            new List<Id>{ ts[0].Id, ts[1].Id }, donor.Id, 'group',
            values, new List<String>{ 'Street "88 boul industriel" → "88 Boul. Industriel"' });
        Test.stopTest();

        System.assertEquals(2, res.get('resolved'), 'Both tickets linked: ' + res.get('errors'));
        System.assertEquals(0, ((List<String>) res.get('errors')).size());
        Account a = [SELECT FirstName, LastName, BillingStreet, BillingCity, PersonEmail, Description FROM Account WHERE Id = :donor.Id];
        System.assertEquals('Laval', a.BillingCity);
        System.assertEquals('Edited', a.LastName, 'An existing account keeps its name');
        System.assertEquals('Bulk', a.FirstName, 'An existing account keeps its name');
        System.assertEquals('bulkedited@test.ca', a.PersonEmail, 'Blank email is skipped');
        System.assertEquals(null, a.Description, 'Fields outside the allowed set are ignored');
        List<Zeffy_Connect_Audit_Log__c> logs = [SELECT Notes__c FROM Zeffy_Connect_Audit_Log__c
            WHERE Action__c = 'Account Updated' AND Account__c = :donor.Id];
        System.assertEquals(1, logs.size(), 'One account log for the whole group');
        System.assert(logs[0].Notes__c.contains('corrected by the reviewer'), logs[0].Notes__c);
    }

    @isTest
    static void testBulkResolveLinkExistingEditedAccountFailure() {
        Account donor = makePersonAccount('Bulk', 'Fail', 'bulkfail@test.ca');
        Zeffy_Review_Ticket__c t = bulkTicket('txn_bulk_editf_001', null);
        insert t;
        Test.startTest();
        // Invalid email: the account update fails, the ticket is still linked and the error is reported
        Map<String,Object> res = ZeffyConnectDonationService.bulkResolveLinkExistingEdited(
            new List<Id>{ t.Id }, donor.Id, null, new Map<String, String>{ 'PersonEmail' => 'not-an-email' }, null);
        Map<String,Object> none = ZeffyConnectDonationService.bulkResolveLinkExistingEdited(
            new List<Id>(), donor.Id, null, null, null);
        Test.stopTest();

        System.assertEquals(1, res.get('resolved'));
        List<String> errs = (List<String>) res.get('errors');
        System.assertEquals(1, errs.size());
        System.assert(errs[0].startsWith('Account: '), errs[0]);
        System.assertEquals('bulkfail@test.ca', [SELECT PersonEmail FROM Account WHERE Id = :donor.Id].PersonEmail);
        System.assertEquals(0, none.get('resolved'));
    }

    @isTest
    static void testBulkResolveLinkExistingEditedNoPendingLeavesAccount() {
        Account donor = makePersonAccount('Bulk', 'Gone', 'bulkgone@test.ca');
        Zeffy_Review_Ticket__c t = bulkTicket('txn_bulk_gone_001', null);
        t.Status__c = 'Skipped';
        insert t;
        Test.startTest();
        // Resolved elsewhere while the modal was open: the account keeps its values and no log is written
        Map<String,Object> res = ZeffyConnectDonationService.bulkResolveLinkExistingEdited(
            new List<Id>{ t.Id }, donor.Id, null, new Map<String, String>{ 'BillingCity' => 'Gatineau' }, null);
        Test.stopTest();

        System.assertEquals(0, res.get('resolved'));
        System.assertEquals(1, ((List<String>) res.get('errors')).size());
        System.assertEquals(null, [SELECT BillingCity FROM Account WHERE Id = :donor.Id].BillingCity);
        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Action__c = 'Account Updated']);
    }

    @isTest
    static void testGetLinkPreviewBusinessAccount() {
        Id rt = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND DeveloperName = 'Eglise' LIMIT 1].Id;
        Account church = new Account(Name = 'Église Preview', RecordTypeId = rt);
        insert church;
        Zeffy_Review_Ticket__c t = bulkTicket('txn_preview_biz_001', null);
        insert t;
        Test.startTest();
        ZeffyConnectDonationService.LinkPreview p = ZeffyConnectDonationService.getLinkPreview(t.Id, church.Id);
        Test.stopTest();

        System.assertEquals(false, p.isPersonAccount);
        System.assertEquals(false, p.firstNamesDiffer, 'No first name to replace on a church');
        System.assertEquals(false, p.lastNamesDiffer,  'No last name to replace on a church');
        for (ZeffyConnectDonationService.EmailFieldOption o : p.emailFieldOptions) {
            System.assert(!o.value.startsWithIgnoreCase('Person'), 'Person fields are not offered: ' + o.value);
        }
    }

    @isTest
    static void testBulkResolveCreateNewNoPendingTickets() {
        Test.startTest();
        Map<String,Object> res = ZeffyConnectDonationService.bulkResolveCreateNew(new List<Id>(), 'individual', null, null, null);
        Test.stopTest();

        System.assertEquals(0, res.get('resolved'));
        System.assertEquals(1, ((List<String>) res.get('errors')).size());
    }

    @isTest
    static void testBulkResolveCreateNewIndividualRecurringFrequencies() {
        List<String> freqs = new List<String>{ 'quarterly', 'annually', 'weekly', 'biweekly' };
        List<Zeffy_Review_Ticket__c> ts = new List<Zeffy_Review_Ticket__c>();
        for (Integer i = 0; i < freqs.size(); i++) {
            Zeffy_Review_Ticket__c t = bulkTicket('txn_bulk_freq_00' + i, i == 0 ? 'zeffy_bulk_freq' : null);
            t.Is_Recurring__c           = true;
            t.Zeffy_Subscription_Id__c  = 'sub_bulk_freq_00' + i;
            t.Subscription_Frequency__c = freqs[i];
            ts.add(t);
        }
        ts.add(failingBulkTicket('txn_bulk_freq_fail'));
        insert ts;
        List<Id> ids = new List<Id>();
        for (Zeffy_Review_Ticket__c t : ts) ids.add(t.Id);

        Test.startTest();
        Map<String,Object> res = ZeffyConnectDonationService.bulkResolveCreateNew(ids, null, 'bulk', null, null);
        Test.stopTest();

        System.assertEquals(4, res.get('resolved'), String.valueOf(res.get('errors')));
        System.assertEquals(1, ((List<String>) res.get('errors')).size());
        Account donor = [SELECT IsPersonAccount FROM Account WHERE Id = :(String) res.get('accountId')];
        System.assert(donor.IsPersonAccount, 'Blank donor type defaults to individual (Person Account)');
        Date today = Date.today();
        System.assertEquals(today.addMonths(3), [SELECT NextTransactionDate FROM GiftCommitment WHERE Zeffy_Subscription_Id__c = 'sub_bulk_freq_000'].NextTransactionDate);
        System.assertEquals(today.addYears(1),  [SELECT NextTransactionDate FROM GiftCommitment WHERE Zeffy_Subscription_Id__c = 'sub_bulk_freq_001'].NextTransactionDate);
        System.assertEquals(today.addDays(7),   [SELECT NextTransactionDate FROM GiftCommitment WHERE Zeffy_Subscription_Id__c = 'sub_bulk_freq_002'].NextTransactionDate);
        System.assertEquals(today.addMonths(1), [SELECT NextTransactionDate FROM GiftCommitment WHERE Zeffy_Subscription_Id__c = 'sub_bulk_freq_003'].NextTransactionDate);
    }

    @isTest
    static void testBulkResolveCreateNewEglise() {
        Zeffy_Review_Ticket__c t = bulkTicket('txn_bulk_eglise_001', null);
        t.Company_Name__c = 'Église Bulk';
        insert t;

        Test.startTest();
        Map<String,Object> res = ZeffyConnectDonationService.bulkResolveCreateNew(new List<Id>{ t.Id }, 'eglise', null, null, null);
        Test.stopTest();

        System.assertEquals(1, res.get('resolved'), String.valueOf(res.get('errors')));
        Account donor = [SELECT Name, IsPersonAccount FROM Account WHERE Id = :(String) res.get('accountId')];
        System.assertEquals('Église Bulk', donor.Name);
        System.assert(!donor.IsPersonAccount);
    }

    // ─── Recurring installments resolved together: oldest first, one commitment ───

    private static Zeffy_Review_Ticket__c weeklyTicket(String txId, String subId, Integer daysAgo, Decimal amount) {
        Zeffy_Review_Ticket__c t = bulkTicket(txId, 'zeffy_' + subId);
        t.Is_Recurring__c           = true;
        t.Zeffy_Subscription_Id__c  = subId;
        t.Subscription_Frequency__c = 'weekly';
        t.Gift_Date__c              = Date.today().addDays(-daysAgo);
        t.Amount__c                 = amount;
        t.Eligible_Amount__c        = amount;
        return t;
    }

    @isTest
    static void testBulkRecurringResolvedOldestFirst() {
        Account donor = makePersonAccount('Weekly', 'Donor', 'weekly@test.ca');
        // Listed newest first, as the review list shows them
        List<Zeffy_Review_Ticket__c> ts = new List<Zeffy_Review_Ticket__c>{
            weeklyTicket('txn_wk_003', 'sub_wk_001', 0, 25.00),
            weeklyTicket('txn_wk_002', 'sub_wk_001', 7, 20.00),
            weeklyTicket('txn_wk_001', 'sub_wk_001', 14, 20.00)
        };
        insert ts;

        Test.startTest();
        Map<String,Object> res = ZeffyConnectDonationService.bulkResolveLinkExisting(
            new List<Id>{ ts[0].Id, ts[1].Id, ts[2].Id }, donor.Id, 'bulk weekly');
        Test.stopTest();

        System.assertEquals(3, res.get('resolved'), String.valueOf(res.get('errors')));
        List<GiftCommitment> cmts = [SELECT Id, EffectiveStartDate, NextTransactionDate, NextTransactionAmount
                                     FROM GiftCommitment WHERE Zeffy_Subscription_Id__c = 'sub_wk_001'];
        System.assertEquals(1, cmts.size(), 'One commitment for the whole subscription');
        System.assertEquals(Date.today().addDays(-14), cmts[0].EffectiveStartDate, 'Starts at the oldest installment');
        System.assertEquals(Date.today().addDays(7), cmts[0].NextTransactionDate, 'Next payment follows the newest one');
        System.assertEquals(25.00, cmts[0].NextTransactionAmount, 'Next amount from the newest installment');
        System.assertEquals(3, [SELECT COUNT() FROM GiftTransaction WHERE GiftCommitmentId = :cmts[0].Id]);
    }

    @isTest
    static void testRecurringOlderInstallmentResolvedLater() {
        Account donor = makePersonAccount('Weekly', 'Late', 'weeklylate@test.ca');
        Zeffy_Review_Ticket__c newer = weeklyTicket('txn_wkl_002', 'sub_wkl_001', 0, 30.00);
        Zeffy_Review_Ticket__c older = weeklyTicket('txn_wkl_001', 'sub_wkl_001', 7, 20.00);
        insert new List<Zeffy_Review_Ticket__c>{ newer, older };

        Test.startTest();
        ZeffyConnectDonationService.bulkResolveLinkExisting(new List<Id>{ newer.Id }, donor.Id, 'newest');
        ZeffyConnectDonationService.bulkResolveLinkExisting(new List<Id>{ older.Id }, donor.Id, 'older');
        Test.stopTest();

        GiftCommitment cmt = [SELECT EffectiveStartDate, NextTransactionDate, NextTransactionAmount
                              FROM GiftCommitment WHERE Zeffy_Subscription_Id__c = 'sub_wkl_001'];
        System.assertEquals(Date.today().addDays(-7), cmt.EffectiveStartDate, 'Start moves back to the older installment');
        System.assertEquals(Date.today().addDays(7), cmt.NextTransactionDate, 'An older installment never moves the next payment back');
        System.assertEquals(30.00, cmt.NextTransactionAmount, 'Next amount stays with the newest installment');
    }

    @isTest
    static void testRecurringCommitmentAdvanceFailureIsNonCritical() {
        Account donor = makePersonAccount('Weekly', 'Fail', 'weeklyfail@test.ca');
        List<Zeffy_Review_Ticket__c> ts = new List<Zeffy_Review_Ticket__c>{
            weeklyTicket('txn_wkf_001', 'sub_wkf_001', 7, 20.00),
            weeklyTicket('txn_wkf_002', 'sub_wkf_001', 0, 20.00)
        };
        insert ts;
        ZeffyConnectDonationService.failCommitmentAdvance = true;

        Test.startTest();
        Map<String,Object> res = ZeffyConnectDonationService.bulkResolveCreateNew(
            new List<Id>{ ts[0].Id, ts[1].Id }, 'individual', null, null, null);
        Test.stopTest();

        System.assertEquals(2, res.get('resolved'), 'Gifts are created even if the commitment cannot move: ' + res.get('errors'));
        GiftCommitment cmt = [SELECT Id, NextTransactionDate FROM GiftCommitment WHERE Zeffy_Subscription_Id__c = 'sub_wkf_001'];
        System.assertEquals(Date.today(), cmt.NextTransactionDate, 'Next payment kept from the first installment');
        System.assertEquals(2, [SELECT COUNT() FROM GiftTransaction WHERE GiftCommitmentId = :cmt.Id]);
    }

    // ─── undoResolution — recurring ticket deletes robot-created commitment ───

    @isTest
    static void testUndoResolutionDeletesCommitment() {
        Zeffy_Review_Ticket__c t = bulkTicket('txn_undo_rec_001', null);
        t.Is_Recurring__c           = true;
        t.Zeffy_Subscription_Id__c  = 'sub_undo_rec_001';
        t.Subscription_Frequency__c = 'monthly';
        insert t;
        ZeffyConnectDonationService.resolveCreateNew(t.Id, 'individual', null);
        System.assertEquals(1, [SELECT COUNT() FROM GiftCommitment WHERE Zeffy_Subscription_Id__c = 'sub_undo_rec_001']);

        Test.startTest();
        ZeffyConnectDonationService.undoResolution(t.Id);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM GiftCommitment WHERE Zeffy_Subscription_Id__c = 'sub_undo_rec_001'],
            'Robot-created commitment should be deleted on undo');
        System.assertEquals('Pending Review', [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id].Status__c);
    }

    @isTest
    static void testBulkResolveCreateNewBusinessAndOrganization() {
        Zeffy_Review_Ticket__c biz = bulkTicket('txn_bulk_biz_001', null);
        biz.Company_Name__c = 'Bulk Business Inc.';
        Zeffy_Review_Ticket__c org = bulkTicket('txn_bulk_org_001', null);
        insert new List<Zeffy_Review_Ticket__c>{ biz, org };

        Test.startTest();
        Map<String,Object> resBiz = ZeffyConnectDonationService.bulkResolveCreateNew(new List<Id>{ biz.Id }, 'business', null, null, null);
        Map<String,Object> resOrg = ZeffyConnectDonationService.bulkResolveCreateNew(new List<Id>{ org.Id }, 'organization', null, null, null);
        Test.stopTest();

        System.assertEquals(1, resBiz.get('resolved'), String.valueOf(resBiz.get('errors')));
        System.assertEquals(1, resOrg.get('resolved'), String.valueOf(resOrg.get('errors')));
        System.assertEquals('Bulk Business Inc.', [SELECT Name FROM Account WHERE Id = :(String) resBiz.get('accountId')].Name);
        System.assertEquals('Bulk Donor', [SELECT Name FROM Account WHERE Id = :(String) resOrg.get('accountId')].Name,
            'Organization without company name falls back to donor full name');
    }

    @isTest
    static void testUndoResolutionCommitmentDeleteFailureIsNonCritical() {
        Zeffy_Review_Ticket__c t = bulkTicket('txn_undo_recfail_001', null);
        t.Is_Recurring__c           = true;
        t.Zeffy_Subscription_Id__c  = 'sub_undo_recfail_001';
        t.Subscription_Frequency__c = 'monthly';
        insert t;
        ZeffyConnectDonationService.resolveCreateNew(t.Id, 'individual', null);

        Test.startTest();
        ZeffyConnectDonationService.failCommitmentDelete = true;
        ZeffyConnectDonationService.undoResolution(t.Id);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM GiftCommitment WHERE Zeffy_Subscription_Id__c = 'sub_undo_recfail_001'],
            'Commitment stays when its delete fails');
        System.assertEquals('Pending Review', [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id].Status__c,
            'Ticket still reopens even if commitment delete fails');
    }

    // ─── payment.updated: Zeffy changed the amount (Zeffy is the source of truth) ─

    private static String buildAmountPayload(String txId, Integer amountCents, Integer refundCents) {
        String refunds = refundCents != null
            ? '[{"id":"ref_amt","amount":' + refundCents + ',"status":"succeeded","created":1737000000}]'
            : '[]';
        String refundStatus = refundCents != null ? 'partially_refunded' : 'none';
        return '{"id":"evt_amt","type":"payment.updated","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"' + txId + '","status":"succeeded","amount":' + amountCents + ',"eligible_amount":0,' +
            '"currency":"cad","contact":"zeffy_amt_001","buyer":null,"payment_method":null,' +
            '"created":1737000000,"receipt_url":null,' +
            '"campaign_id":null,"campaign_type":null,"campaign_category":null,"description":null,' +
            '"refund_status":"' + refundStatus + '","refunds":' + refunds + ',"dispute":null,"fund":null,"discount":null,' +
            '"buyer_questions":[],"items":[],"recurring":null}}';
    }

    private static void enablePaymentUpdated() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Updated__c = true;
        update cfg;
    }

    private static GiftTransaction insertPaidGift(Id donorId, String txId, Decimal amount, Decimal nonTaxDeductible) {
        GiftTransaction gt = new GiftTransaction(
            Name                    = 'ZF-' + txId,
            DonorId                 = donorId,
            OriginalAmount          = amount,
            NonTaxDeductibleAmount  = nonTaxDeductible,
            PaymentMethod           = 'Credit Card',
            GiftType                = 'Individual',
            Status                  = 'Paid',
            TransactionDate         = Date.today(),
            Zeffy_Transaction_Id__c = txId
        );
        insert gt;
        return gt;
    }

    private static Zeffy_Review_Ticket__c insertLinkedTicket(Id donorId, Id giftId, String txId, Decimal amount) {
        Zeffy_Review_Ticket__c t = new Zeffy_Review_Ticket__c(
            Status__c               = 'Resolved - Linked',
            Zeffy_Transaction_Id__c = txId,
            Resolved_Account__c     = donorId,
            Resolved_Gift__c        = giftId,
            Amount__c               = amount
        );
        insert t;
        return t;
    }

    // Zeffy reports another amount for a linked payment: nothing changes, the ticket is flagged for review
    @isTest
    static void testAmountChangeFlagsLinkedTicket() {
        enablePaymentUpdated();
        Account donor = makePersonAccount('Amt', 'Flag', 'amt.flag@test.ca');
        GiftTransaction gt = insertPaidGift(donor.Id, 'txn_amt_linked', 50, 0);
        Zeffy_Review_Ticket__c t = insertLinkedTicket(donor.Id, gt.Id, 'txn_amt_linked', 50);

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult r =
            ZeffyConnectDonationService.processWebhookWithResult(buildAmountPayload('txn_amt_linked', 2000, null));
        ZeffyConnectDonationService.processWebhookWithResult(buildAmountPayload('txn_amt_linked', 2000, null)); // retry
        Test.stopTest();

        System.assert(r.message.contains('flagged for a manual review'), r.message);
        Zeffy_Review_Ticket__c after = [SELECT Status__c, Amount__c, Zeffy_Amount_Not_Applied__c FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id];
        System.assertEquals('Resolved - Linked', after.Status__c, 'Status unchanged');
        System.assertEquals(50, after.Amount__c, 'Ticket amount unchanged');
        System.assertEquals(20, after.Zeffy_Amount_Not_Applied__c, 'Zeffy amount kept for the review');
        System.assertEquals(50, [SELECT OriginalAmount FROM GiftTransaction WHERE Id = :gt.Id].OriginalAmount, 'Gift unchanged');
        List<Zeffy_Connect_Audit_Log__c> logs = [SELECT Notes__c FROM Zeffy_Connect_Audit_Log__c
                                                 WHERE Ticket__c = :t.Id AND Action__c = 'Amount Changed in Zeffy'];
        System.assertEquals(1, logs.size(), 'A retry of the same amount logs nothing new');
        System.assert(logs[0].Notes__c.contains('$20.00') && logs[0].Notes__c.contains('$50.00'), logs[0].Notes__c);
        Set<Id> open = new Set<Id>();
        for (Zeffy_Review_Ticket__c o : ZeffyConnectDonationService.getTickets('Open')) open.add(o.Id);
        System.assert(open.contains(t.Id), 'Flagged ticket shows in Open');
    }

    // Auto-matched gift (no ticket): a ticket linked to the gift is opened for the review
    @isTest
    static void testAmountChangeAutoMatchedOpensTicket() {
        enablePaymentUpdated();
        Account donor = makePersonAccount('Amt', 'Auto', 'amt.auto@test.ca');
        GiftTransaction gt = insertPaidGift(donor.Id, 'txn_amt_auto', 50, 0);

        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(buildAmountPayload('txn_amt_auto', 2000, null));
        Test.stopTest();

        System.assertEquals(50, [SELECT OriginalAmount FROM GiftTransaction WHERE Id = :gt.Id].OriginalAmount);
        Zeffy_Review_Ticket__c t = [SELECT Status__c, Amount__c, Zeffy_Amount_Not_Applied__c, Resolved_Gift__c, Resolved_Account__c
                                    FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_amt_auto'];
        System.assertEquals('Auto-Processed', t.Status__c);
        System.assertEquals(50, t.Amount__c);
        System.assertEquals(20, t.Zeffy_Amount_Not_Applied__c);
        System.assertEquals(gt.Id, t.Resolved_Gift__c);
        System.assertEquals(donor.Id, t.Resolved_Account__c);
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Ticket__c = :t.Id AND Action__c = 'Amount Changed in Zeffy']);
    }

    // Amount net of a partial refund is not an amount change; same amount → no ticket, no flag
    @isTest
    static void testAmountNetOfRefundIsNotAnAmountChange() {
        enablePaymentUpdated();
        Account donor = makePersonAccount('Amt', 'Refund', 'amt.refund@test.ca');
        insertPaidGift(donor.Id, 'txn_amt_refund', 50, 0);
        insertPaidGift(donor.Id, 'txn_amt_same', 50, 0);

        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(buildAmountPayload('txn_amt_refund', 2000, 3000));
        ZeffyConnectDonationService.processWebhookWithResult(buildAmountPayload('txn_amt_same', 5000, null));
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Review_Ticket__c]);
        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Action__c = 'Amount Changed in Zeffy']);
    }

    // Zeffy goes back to the recorded amount → the flag clears by itself
    @isTest
    static void testFlagClearedWhenZeffyMatchesRecordedAmount() {
        enablePaymentUpdated();
        Account donor = makePersonAccount('Amt', 'Heal', 'amt.heal@test.ca');
        GiftTransaction gt = insertPaidGift(donor.Id, 'txn_amt_heal', 50, 0);
        Zeffy_Review_Ticket__c t = insertLinkedTicket(donor.Id, gt.Id, 'txn_amt_heal', 50);
        t.Zeffy_Amount_Not_Applied__c = 20;
        update t;

        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(buildAmountPayload('txn_amt_heal', 5000, null));
        Test.stopTest();

        System.assertEquals(null, [SELECT Zeffy_Amount_Not_Applied__c FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id].Zeffy_Amount_Not_Applied__c);
    }

    // Staff checks it (and fixes the gift by hand if needed): flag cleared, ticket follows the gift
    @isTest
    static void testMarkAmountReviewed() {
        Account donor = makePersonAccount('Amt', 'Rev', 'amt.rev@test.ca');
        GiftTransaction gt = insertPaidGift(donor.Id, 'txn_amt_rev', 20, 0);
        Zeffy_Review_Ticket__c t = insertLinkedTicket(donor.Id, gt.Id, 'txn_amt_rev', 50);
        t.Zeffy_Amount_Not_Applied__c = 20;
        update t;

        Test.startTest();
        ZeffyConnectDonationService.markAmountReviewed(t.Id);
        ZeffyConnectDonationService.markAmountReviewed(t.Id);   // second call: nothing left to review
        Test.stopTest();

        Zeffy_Review_Ticket__c after = [SELECT Amount__c, Zeffy_Amount_Not_Applied__c, Zeffy_Amount_Reviewed__c FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id];
        System.assertEquals(20, after.Amount__c);
        System.assertEquals(null, after.Zeffy_Amount_Not_Applied__c);
        System.assertEquals(20, after.Zeffy_Amount_Reviewed__c);
        Zeffy_Connect_Audit_Log__c log = [SELECT Notes__c FROM Zeffy_Connect_Audit_Log__c WHERE Action__c = 'Amount Change Reviewed'];
        System.assertEquals('Zeffy: $20.00 — Salesforce: $20.00', log.Notes__c);
    }

    // Open ticket (no gift yet): the ticket takes the new Zeffy amount, so the gift is born right
    @isTest
    static void testAmountChangeOpenTicketTakesNewAmount() {
        enablePaymentUpdated();
        Zeffy_Review_Ticket__c t = new Zeffy_Review_Ticket__c(Status__c = 'Pending Review',
            Zeffy_Transaction_Id__c = 'txn_amt_open', Amount__c = 50, Eligible_Amount__c = 50);
        insert t;

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult r =
            ZeffyConnectDonationService.processWebhookWithResult(buildAmountPayload('txn_amt_open', 2000, null));
        Test.stopTest();

        System.assert(r.message.contains('took the new Zeffy amount'), r.message);
        Zeffy_Review_Ticket__c after = [SELECT Status__c, Amount__c, Eligible_Amount__c, Zeffy_Amount_Not_Applied__c
                                        FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id];
        System.assertEquals('Pending Review', after.Status__c);
        System.assertEquals(20, after.Amount__c);
        System.assertEquals(20, after.Eligible_Amount__c, 'Eligible amount never above the amount');
        System.assertEquals(null, after.Zeffy_Amount_Not_Applied__c, 'Open ticket is not flagged');
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Ticket__c = :t.Id AND Action__c = 'Amount Updated by Zeffy']);
    }

    // An amount staff already reviewed is not flagged again; a newer amount is
    @isTest
    static void testReviewedAmountNotFlaggedAgain() {
        enablePaymentUpdated();
        Account donor = makePersonAccount('Amt', 'Again', 'amt.again@test.ca');
        GiftTransaction gt = insertPaidGift(donor.Id, 'txn_amt_again', 50, 0);
        Zeffy_Review_Ticket__c t = insertLinkedTicket(donor.Id, gt.Id, 'txn_amt_again', 50);

        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(buildAmountPayload('txn_amt_again', 2000, null));
        ZeffyConnectDonationService.markAmountReviewed(t.Id);
        ZeffyConnectDonationService.processWebhookWithResult(buildAmountPayload('txn_amt_again', 2000, null));
        Decimal afterSame = [SELECT Zeffy_Amount_Not_Applied__c FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id].Zeffy_Amount_Not_Applied__c;
        ZeffyConnectDonationService.processWebhookWithResult(buildAmountPayload('txn_amt_again', 1500, null));
        Test.stopTest();

        System.assertEquals(null, afterSame, 'Reviewed amount does not come back to Open');
        Zeffy_Review_Ticket__c after = [SELECT Zeffy_Amount_Not_Applied__c, Zeffy_Amount_Reviewed__c FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id];
        System.assertEquals(15, after.Zeffy_Amount_Not_Applied__c, 'A different amount is flagged again');
        System.assertEquals(20, after.Zeffy_Amount_Reviewed__c);
        System.assertEquals(2, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Ticket__c = :t.Id AND Action__c = 'Amount Changed in Zeffy']);
    }

    // Only completed refunds count (a failed one gave nothing back)
    @isTest
    static void testOnlyCompletedRefundsCount() {
        ZeffyConnectDonationService.ZeffyRefund ok = new ZeffyConnectDonationService.ZeffyRefund();
        ok.status = 'succeeded';
        ZeffyConnectDonationService.ZeffyRefund failed = new ZeffyConnectDonationService.ZeffyRefund();
        failed.status = 'failed';
        ZeffyConnectDonationService.ZeffyRefund noStatus = new ZeffyConnectDonationService.ZeffyRefund();
        System.assert(ZeffyConnectDonationService.isCompletedRefund(ok));
        System.assert(!ZeffyConnectDonationService.isCompletedRefund(failed));
        System.assert(ZeffyConnectDonationService.isCompletedRefund(noStatus));

        enablePaymentUpdated();
        Account donor = makePersonAccount('Ref', 'Failed', 'ref.failed@test.ca');
        GiftTransaction gt = insertPaidGift(donor.Id, 'txn_ref_failed', 50, 0);
        String body = buildAmountPayload('txn_ref_failed', 5000, 1000).replace('"status":"succeeded","created"', '"status":"failed","created"');
        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(body);
        Test.stopTest();
        System.assertEquals(null, [SELECT Refund_Amount__c FROM GiftTransaction WHERE Id = :gt.Id].Refund_Amount__c);
    }

    private static String buildRecurringAmountPayload(String txId, Integer amountCents, Long created, String subId) {
        return buildAmountPayload(txId, amountCents, null)
            .replace('"created":1737000000', '"created":' + created)
            .replace('"recurring":null', '"recurring":{"is_recurring":true,"status":"active","interval":"monthly",' +
                '"subscription_id":"' + subId + '","current_period_start":null,"current_period_end":null}');
    }

    // A late update of an older installment does not move the commitment back; the latest one does
    @isTest
    static void testCommitmentFollowsLatestInstallmentOnly() {
        enablePaymentUpdated();
        Account donor = makePersonAccount('Cmt', 'Latest', 'cmt.latest@test.ca');
        GiftCommitment cmt = new GiftCommitment(Name = 'Zeffy Recurring sub_latest', DonorId = donor.Id, Status = 'Active',
            ScheduleType = 'Recurring', RecurrenceType = 'OpenEnded', EffectiveStartDate = Date.today().addMonths(-2),
            Zeffy_Subscription_Id__c = 'sub_latest');
        insert cmt;
        Long oldTs = DateTime.newInstanceGmt(Date.today().addMonths(-1), Time.newInstance(12, 0, 0, 0)).getTime() / 1000;
        Long newTs = DateTime.now().getTime() / 1000;
        insert new List<GiftTransaction>{
            new GiftTransaction(Name = 'ZF-old', DonorId = donor.Id, OriginalAmount = 25, PaymentMethod = 'Credit Card',
                GiftType = 'Individual', Status = 'Paid', TransactionDate = Date.today().addMonths(-1),
                TransactionDueDate = Date.today().addMonths(-1),
                Zeffy_Transaction_Id__c = 'txn_cmt_old', GiftCommitmentId = cmt.Id),
            new GiftTransaction(Name = 'ZF-new', DonorId = donor.Id, OriginalAmount = 25, PaymentMethod = 'Credit Card',
                GiftType = 'Individual', Status = 'Paid', TransactionDate = Date.today(),
                TransactionDueDate = Date.today(),
                Zeffy_Transaction_Id__c = 'txn_cmt_new', GiftCommitmentId = cmt.Id)
        };

        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(buildRecurringAmountPayload('txn_cmt_old', 1000, oldTs, 'sub_latest'));
        Decimal afterOld = [SELECT NextTransactionAmount FROM GiftCommitment WHERE Id = :cmt.Id].NextTransactionAmount;
        ZeffyConnectDonationService.processWebhookWithResult(buildRecurringAmountPayload('txn_cmt_new', 3000, newTs, 'sub_latest'));
        Test.stopTest();

        System.assertNotEquals(10, afterOld, 'Older installment does not set the commitment amount');
        System.assertEquals(30, [SELECT NextTransactionAmount FROM GiftCommitment WHERE Id = :cmt.Id].NextTransactionAmount);
    }

    // ═══ Audit fixes 2026-10-02 ═════════════════════════════════════════════

    private static void grantSettingsAccess() {
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Zeffy_Connect_Admin_Access' LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = UserInfo.getUserId(), PermissionSetId = ps.Id);
    }

    private static void enablePaymentDeleted() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Deleted__c = true;
        update cfg;
    }

    // payment.deleted on a resolved ticket cancels its gift (Paid → Unpaid → Canceled)
    @isTest
    static void testPaymentDeletedCancelsLinkedGift() {
        enablePaymentDeleted();
        Account donor = makePersonAccount('Del', 'Gift', 'del.gift@test.ca');
        GiftTransaction gt = insertPaidGift(donor.Id, 'txn_del_gt_001', 50, 0);
        Zeffy_Review_Ticket__c t = insertLinkedTicket(donor.Id, gt.Id, 'txn_del_gt_001', 50);

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult r =
            ZeffyConnectDonationService.processWebhookWithResult(buildDeletedPayload('txn_del_gt_001'));
        Test.stopTest();

        System.assertEquals('SUCCESS', r.status);
        System.assertEquals('Canceled', [SELECT Status FROM GiftTransaction WHERE Id = :gt.Id].Status);
        Zeffy_Review_Ticket__c after = [SELECT Status__c, Error_Message__c FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id];
        System.assertEquals('Payment Failed', after.Status__c);
        System.assertEquals(null, after.Error_Message__c);
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Ticket__c = :t.Id AND Action__c = 'Payment Deleted']);
    }

    // Auto-matched gift (no ticket) that can't be cancelled → a Payment Failed ticket is opened for staff
    @isTest
    static void testPaymentDeletedCancelFailureOpensTicket() {
        enablePaymentDeleted();
        Account donor = makePersonAccount('Del', 'Fail', 'del.fail@test.ca');
        GiftTransaction gt = insertPaidGift(donor.Id, 'txn_del_fail_001', 50, 0);

        ZeffyConnectDonationService.failGiftCancel = true;
        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(buildDeletedPayload('txn_del_fail_001'));
        Test.stopTest();
        ZeffyConnectDonationService.failGiftCancel = false;

        System.assertEquals('Paid', [SELECT Status FROM GiftTransaction WHERE Id = :gt.Id].Status);
        Zeffy_Review_Ticket__c t = [SELECT Status__c, Resolved_Gift__c, Error_Message__c FROM Zeffy_Review_Ticket__c
                                    WHERE Zeffy_Transaction_Id__c = 'txn_del_fail_001'];
        System.assertEquals('Payment Failed', t.Status__c);
        System.assertEquals(gt.Id, t.Resolved_Gift__c);
        System.assert(t.Error_Message__c.contains('could not be cancelled'));
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Action__c = 'Payment Delete Failed']);
    }

    // ─── Zeffy origin (data.type) ─────────────────────────────────────────────────

    private static String typedDeletedPayload(String txId, String origin) {
        return buildDeletedPayload(txId).replace('"status":"deleted"', '"status":"deleted","type":"' + origin + '"');
    }

    @isTest
    static void testOriginStoredOnTicket() {
        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(
            buildPayload('txn_orig_001', 'orig@test.ca', 'zeffy_orig_001').replace('"type":"online"', '"type":"manual"'));
        Test.stopTest();
        System.assertEquals('Manual', [SELECT Zeffy_Origin__c FROM Zeffy_Review_Ticket__c
                                       WHERE Zeffy_Transaction_Id__c = 'txn_orig_001'].Zeffy_Origin__c);
    }

    @isTest
    static void testMapOrigin() {
        System.assertEquals('Online',   ZeffyConnectDonationService.mapOrigin('online'));
        System.assertEquals('Manual',   ZeffyConnectDonationService.mapOrigin(' MANUAL '));
        System.assertEquals('Imported', ZeffyConnectDonationService.mapOrigin('imported'));
        System.assertEquals('other',    ZeffyConnectDonationService.mapOrigin('other'));
        System.assertEquals(null,       ZeffyConnectDonationService.mapOrigin(''));
    }

    // A manual payment deleted in Zeffy was a data-entry mistake: gift and ticket are removed,
    // the account stays and the Audit Log keeps what was removed
    @isTest
    static void testManualPaymentDeletedRemovesGiftAndTicket() {
        enablePaymentDeleted();
        Account donor = makePersonAccount('Man', 'Ual', 'man.ual@test.ca');
        GiftTransaction gt = insertPaidGift(donor.Id, 'txn_man_001', 100, 0);
        Zeffy_Review_Ticket__c t = insertLinkedTicket(donor.Id, gt.Id, 'txn_man_001', 100);
        insert new Zeffy_Connect_Audit_Log__c(Ticket__c = t.Id, Action__c = 'Resolved', Notes__c = 'Linked');

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult r =
            ZeffyConnectDonationService.processWebhookWithResult(typedDeletedPayload('txn_man_001', 'manual'));
        Test.stopTest();

        System.assertEquals('SUCCESS', r.status);
        System.assertEquals(0, [SELECT COUNT() FROM GiftTransaction WHERE Id = :gt.Id]);
        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id]);
        System.assertEquals(1, [SELECT COUNT() FROM Account WHERE Id = :donor.Id]);
        Zeffy_Connect_Audit_Log__c log = [SELECT Ticket__c, Account__c, Notes__c FROM Zeffy_Connect_Audit_Log__c
                                          WHERE Action__c = 'Manual Payment Deleted'];
        System.assertEquals(null, log.Ticket__c);
        System.assertEquals(donor.Id, log.Account__c);
        System.assert(log.Notes__c.contains('txn_man_001'), log.Notes__c);
        System.assert(log.Notes__c.contains('Amount: 100.00'), log.Notes__c);
        System.assert(log.Notes__c.contains('Deleted ticket:'), log.Notes__c);
        System.assert(log.Notes__c.contains('Deleted GiftTransaction:'), log.Notes__c);
        System.assert([SELECT Notes__c FROM Zeffy_Connect_Audit_Log__c WHERE Action__c = 'Resolved'].Notes__c.contains(', deleted]'));
    }

    // Monthly / pre-authorized manual payment: every gift and ticket with the transaction ID is removed,
    // and the recurring commitment goes too once no other installment uses it
    @isTest
    static void testManualRecurringDeletedRemovesCommitment() {
        enablePaymentDeleted();
        Account donor = makePersonAccount('Man', 'Rec', 'man.rec@test.ca');
        GiftCommitment solo = new GiftCommitment(Name = 'Zeffy Recurring sub_solo', DonorId = donor.Id, Status = 'Active',
            ScheduleType = 'Recurring', RecurrenceType = 'OpenEnded', EffectiveStartDate = Date.today(),
            Zeffy_Subscription_Id__c = 'sub_solo');
        GiftCommitment shared = new GiftCommitment(Name = 'Zeffy Recurring sub_shared', DonorId = donor.Id, Status = 'Active',
            ScheduleType = 'Recurring', RecurrenceType = 'OpenEnded', EffectiveStartDate = Date.today(),
            Zeffy_Subscription_Id__c = 'sub_shared');
        insert new List<GiftCommitment>{ solo, shared };
        // txn_man_rec → only installment of "solo"; txn_man_shared and txn_man_other → both on "shared"
        List<String> txIds = new List<String>{ 'txn_man_rec', 'txn_man_shared', 'txn_man_other' };
        List<GiftTransaction> gifts = new List<GiftTransaction>();
        for (Integer i = 0; i < 3; i++) {
            gifts.add(new GiftTransaction(Name = 'ZF-' + txIds[i], DonorId = donor.Id, OriginalAmount = 25,
                PaymentMethod = 'Credit Card', GiftType = 'Individual', Status = 'Paid', TransactionDate = Date.today(),
                TransactionDueDate = Date.today(),
                Zeffy_Transaction_Id__c = txIds[i], GiftCommitmentId = i == 0 ? solo.Id : shared.Id));
        }
        insert gifts;
        insertLinkedTicket(donor.Id, gifts[0].Id, 'txn_man_rec', 25);

        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(typedDeletedPayload('txn_man_rec', 'manual'));
        ZeffyConnectDonationService.processWebhookWithResult(typedDeletedPayload('txn_man_shared', 'manual'));
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM GiftTransaction WHERE Zeffy_Transaction_Id__c IN ('txn_man_rec', 'txn_man_shared')]);
        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_man_rec']);
        System.assertEquals(0, [SELECT COUNT() FROM GiftCommitment WHERE Id = :solo.Id], 'Commitment with no installment left is deleted');
        System.assertEquals(1, [SELECT COUNT() FROM GiftCommitment WHERE Id = :shared.Id], 'Commitment still used by another payment is kept');
        System.assertEquals(1, [SELECT COUNT() FROM GiftTransaction WHERE Zeffy_Transaction_Id__c = 'txn_man_other']);
        String notes = '';
        for (Zeffy_Connect_Audit_Log__c l : [SELECT Notes__c FROM Zeffy_Connect_Audit_Log__c WHERE Action__c = 'Manual Payment Deleted']) {
            notes += l.Notes__c + '\n';
        }
        System.assert(notes.contains('Deleted recurring commitment: Zeffy Recurring sub_solo'), notes);
        System.assert(notes.contains('Recurring commitment kept'), notes);
    }

    // payload without data.type: the origin stored on the gift decides
    @isTest
    static void testManualOriginFromStoredGift() {
        enablePaymentDeleted();
        Account donor = makePersonAccount('Man', 'Stored', 'man.stored@test.ca');
        GiftTransaction gt = insertPaidGift(donor.Id, 'txn_man_002', 100, 0);
        update new GiftTransaction(Id = gt.Id, Zeffy_Origin__c = 'Manual');

        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(buildDeletedPayload('txn_man_002'));
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM GiftTransaction WHERE Id = :gt.Id]);
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Action__c = 'Manual Payment Deleted']);
    }

    // If the delete fails nothing is removed and the payment is cancelled like any other
    @isTest
    static void testManualDeleteFailureFallsBackToCancel() {
        enablePaymentDeleted();
        Account donor = makePersonAccount('Man', 'Fail', 'man.fail@test.ca');
        GiftTransaction gt = insertPaidGift(donor.Id, 'txn_man_003', 100, 0);
        Zeffy_Review_Ticket__c t = insertLinkedTicket(donor.Id, gt.Id, 'txn_man_003', 100);

        ZeffyConnectDonationService.failManualDelete = true;
        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(typedDeletedPayload('txn_man_003', 'manual'));
        Test.stopTest();
        ZeffyConnectDonationService.failManualDelete = false;

        System.assertEquals('Canceled', [SELECT Status FROM GiftTransaction WHERE Id = :gt.Id].Status);
        System.assertEquals('Payment Failed', [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id].Status__c);
        Zeffy_Connect_Audit_Log__c log = [SELECT Notes__c FROM Zeffy_Connect_Audit_Log__c
                                          WHERE Ticket__c = :t.Id AND Action__c = 'Payment Deleted'];
        System.assert(log.Notes__c.contains('could not be deleted'), log.Notes__c);
    }

    // Online payments deleted in Zeffy keep their trace as Canceled
    @isTest
    static void testOnlinePaymentDeletedStaysCanceled() {
        enablePaymentDeleted();
        Account donor = makePersonAccount('On', 'Line', 'on.line@test.ca');
        GiftTransaction gt = insertPaidGift(donor.Id, 'txn_onl_001', 100, 0);

        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(typedDeletedPayload('txn_onl_001', 'online'));
        Test.stopTest();

        System.assertEquals('Canceled', [SELECT Status FROM GiftTransaction WHERE Id = :gt.Id].Status);
        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Action__c = 'Manual Payment Deleted']);
    }

    // payment.completed graduates a ticket that already expired to Delayed
    @isTest
    static void testCompletedGraduatesDelayedTicket() {
        insert new Zeffy_Review_Ticket__c(Status__c = 'Delayed', Email__c = 'late@test.ca',
                                          Zeffy_Transaction_Id__c = 'txn_delayed_001');

        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(buildPayload('txn_delayed_001', 'late@test.ca', 'zeffy_late_001'));
        Test.stopTest();

        System.assertEquals('Pending Review',
            [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_delayed_001'].Status__c);
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_delayed_001'],
            'No second ticket for the same payment');
    }

    @isTest
    static void testMoveTicketToReview() {
        Zeffy_Review_Ticket__c t = new Zeffy_Review_Ticket__c(Status__c = 'Payment Failed', Zeffy_Transaction_Id__c = 'txn_move_001');
        Zeffy_Review_Ticket__c p = new Zeffy_Review_Ticket__c(Status__c = 'Pending Review', Zeffy_Transaction_Id__c = 'txn_move_002');
        insert new List<Zeffy_Review_Ticket__c>{ t, p };

        Test.startTest();
        ZeffyConnectDonationService.moveTicketToReview(t.Id, 'customer confirmed by phone');
        Boolean threw = false;
        try {
            ZeffyConnectDonationService.moveTicketToReview(p.Id, null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals('Pending Review', [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id].Status__c);
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Ticket__c = :t.Id AND Action__c = 'Moved to Review']);
        System.assert(threw, 'Pending Review tickets cannot be "moved to review"');
    }

    // Holding/Delayed moved to review by mistake → back to the same status; Payment Failed has no way back
    @isTest
    static void testReturnTicketToWaiting() {
        Zeffy_Review_Ticket__c h = new Zeffy_Review_Ticket__c(Status__c = 'Holding', Zeffy_Transaction_Id__c = 'txn_back_001');
        Zeffy_Review_Ticket__c d = new Zeffy_Review_Ticket__c(Status__c = 'Delayed', Zeffy_Transaction_Id__c = 'txn_back_002');
        Zeffy_Review_Ticket__c f = new Zeffy_Review_Ticket__c(Status__c = 'Payment Failed', Zeffy_Transaction_Id__c = 'txn_back_003');
        insert new List<Zeffy_Review_Ticket__c>{ h, d, f };

        Test.startTest();
        ZeffyConnectDonationService.moveTicketToReview(h.Id, null);
        ZeffyConnectDonationService.moveTicketToReview(d.Id, null);
        ZeffyConnectDonationService.moveTicketToReview(f.Id, null);
        System.assertEquals('Holding', [SELECT Pre_Review_Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :h.Id].Pre_Review_Status__c);
        ZeffyConnectDonationService.returnTicketToWaiting(h.Id);
        ZeffyConnectDonationService.returnTicketToWaiting(d.Id);
        Boolean threw = false;
        try {
            ZeffyConnectDonationService.returnTicketToWaiting(f.Id);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Zeffy_Review_Ticket__c hh = [SELECT Status__c, Pre_Review_Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :h.Id];
        System.assertEquals('Holding', hh.Status__c);
        System.assertEquals(null, hh.Pre_Review_Status__c);
        System.assertEquals('Delayed', [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :d.Id].Status__c);
        System.assert(threw, 'Payment Failed tickets have no way back');
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Ticket__c = :h.Id AND Action__c = 'Returned to Holding']);
    }

    // Zeffy confirms the payment after a manual move to review → the way back closes
    @isTest
    static void testReturnTicketToWaitingBlockedAfterConfirmation() {
        Zeffy_Review_Ticket__c h = new Zeffy_Review_Ticket__c(Status__c = 'Holding', Zeffy_Transaction_Id__c = 'txn_back_010');
        insert h;
        ZeffyConnectDonationService.moveTicketToReview(h.Id, null);

        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(buildPayload('txn_back_010', 'back@test.ca', 'zeffy_back_010'));
        Boolean threw = false;
        try {
            ZeffyConnectDonationService.returnTicketToWaiting(h.Id);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Zeffy_Review_Ticket__c t = [SELECT Status__c, Pre_Review_Status__c, Transaction_Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :h.Id];
        System.assertEquals('Pending Review', t.Status__c);
        System.assertEquals(null, t.Pre_Review_Status__c);
        System.assertEquals('succeeded', t.Transaction_Status__c);
        System.assert(threw, 'Zeffy confirmed the payment — it stays in review');
    }

    // Real Zeffy payment.completed / payment.updated can omit data.status: Holding "pending" must
    // become "succeeded" on completed, and a later status-less updated must not blank it
    @isTest
    static void testTxStatusWithoutStatusInPayload() {
        insert new Zeffy_Review_Ticket__c(Status__c = 'Holding', Transaction_Status__c = 'pending',
                                          Zeffy_Transaction_Id__c = 'txn_nostatus_001');
        String completed = buildPayload('txn_nostatus_001', 'nostatus@test.ca', 'zeffy_nostatus_001')
            .replace('"status":"succeeded",', '');
        String updated = completed.replace('"type":"payment.completed"', '"type":"payment.updated"');

        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(completed);
        ZeffyConnectDonationService.processWebhookWithResult(updated);
        Test.stopTest();

        System.assertEquals('succeeded',
            [SELECT Transaction_Status__c FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_nostatus_001'].Transaction_Status__c);
    }

    // Return to Holding drops the assignment and closes the ticket's open tasks
    @isTest
    static void testReturnToWaitingClearsAssignment() {
        Zeffy_Review_Ticket__c h = new Zeffy_Review_Ticket__c(Status__c = 'Holding', Zeffy_Transaction_Id__c = 'txn_back_asg_001');
        insert h;
        ZeffyConnectDonationService.moveTicketToReview(h.Id, null);
        update new Zeffy_Review_Ticket__c(Id = h.Id, Manual_Assignee_Id__c = UserInfo.getUserId(), Manual_Assignee_Name__c = 'Reviewer');
        insert new Task(WhatId = h.Id, Subject = 'Review Zeffy donation', Status = 'Not Started', OwnerId = UserInfo.getUserId());

        Test.startTest();
        ZeffyConnectDonationService.returnTicketToWaiting(h.Id);
        Test.stopTest();

        Zeffy_Review_Ticket__c t = [SELECT Status__c, Manual_Assignee_Id__c, Manual_Assignee_Name__c FROM Zeffy_Review_Ticket__c WHERE Id = :h.Id];
        System.assertEquals('Holding', t.Status__c);
        System.assertEquals(null, t.Manual_Assignee_Id__c);
        System.assertEquals(null, t.Manual_Assignee_Name__c);
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId = :h.Id AND IsClosed = false]);
    }

    // Payment Failed because Zeffy deleted the payment cannot go back to review
    @isTest
    static void testMoveToReviewBlockedWhenZeffyDeleted() {
        Zeffy_Review_Ticket__c f = new Zeffy_Review_Ticket__c(Status__c = 'Payment Failed', Transaction_Status__c = 'deleted',
                                                              Zeffy_Transaction_Id__c = 'txn_deleted_rev_001');
        insert f;
        Boolean threw = false;
        Test.startTest();
        try {
            ZeffyConnectDonationService.moveTicketToReview(f.Id, null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'A payment deleted in Zeffy must not be reviewed again');
        System.assertEquals('Payment Failed', [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :f.Id].Status__c);
    }

    // payment.completed on a ticket already resolved (staff resolved it before Zeffy confirmed)
    // still records the payment and blocks a later return to Holding
    @isTest
    static void testCompletedConfirmsResolvedTicket() {
        insert new Zeffy_Review_Ticket__c(Status__c = 'Resolved - Linked', Transaction_Status__c = 'pending',
                                          Pre_Review_Status__c = 'Holding', Zeffy_Transaction_Id__c = 'txn_resolved_conf_001');
        String completed = buildPayload('txn_resolved_conf_001', 'resolvedconf@test.ca', 'zeffy_resolved_conf_001')
            .replace('"status":"succeeded",', '');

        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(completed);
        Test.stopTest();

        Zeffy_Review_Ticket__c t = [SELECT Status__c, Transaction_Status__c, Pre_Review_Status__c
                                    FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_resolved_conf_001'];
        System.assertEquals('Resolved - Linked', t.Status__c);
        System.assertEquals('succeeded', t.Transaction_Status__c);
        System.assertEquals(null, t.Pre_Review_Status__c);
    }

    // Bulk create-new: a Zeffy ID that is already linked keeps its account (same Zeffy ID = same donor)
    @isTest
    static void testBulkCreateNewReusesKnownZeffyId() {
        Account known = makePersonAccount('Known', 'Donor', 'known.bulk@test.ca');
        linkIdentity(known.Id, 'zid_bulk_known', 'known.bulk@test.ca');
        Zeffy_Review_Ticket__c a = bulkTicket('txn_bulk_known_001', 'zid_bulk_known');
        Zeffy_Review_Ticket__c b = bulkTicket('txn_bulk_other_001', 'zid_bulk_other');
        b.Email__c = 'other.bulk@test.ca';
        insert new List<Zeffy_Review_Ticket__c>{ a, b };
        Integer accountsBefore = [SELECT COUNT() FROM Account];

        Test.startTest();
        Map<String,Object> res = ZeffyConnectDonationService.bulkResolveCreateNew(new List<Id>{ a.Id, b.Id }, 'individual', null, null, null);
        Test.stopTest();

        System.assertEquals(2, res.get('resolved'), String.valueOf(res.get('errors')));
        System.assertEquals(2, res.get('accounts'));
        System.assertEquals(accountsBefore + 1, [SELECT COUNT() FROM Account], 'Only the unknown donor gets a new account');
        Zeffy_Review_Ticket__c ra = [SELECT Status__c, Resolved_Account__c FROM Zeffy_Review_Ticket__c WHERE Id = :a.Id];
        System.assertEquals('Resolved - Linked', ra.Status__c);
        System.assertEquals(known.Id, ra.Resolved_Account__c);
        System.assertEquals('Resolved - New Contact', [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :b.Id].Status__c);
    }

    // Undo removes the Zeffy ID link created by that resolution
    @isTest
    static void testUndoRemovesIdentityCreatedByResolution() {
        Zeffy_Review_Ticket__c t = bulkTicket('txn_undo_ident_001', 'zid_undo_ident');
        insert t;
        ZeffyConnectDonationService.resolveCreateNew(t.Id, 'individual', null);
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Identity__c WHERE Zeffy_Contact_Id__c = 'zid_undo_ident']);

        Test.startTest();
        ZeffyConnectDonationService.undoResolution(t.Id);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Identity__c WHERE Zeffy_Contact_Id__c = 'zid_undo_ident'],
            'Next payment must not auto-match the account of an undone resolution');
        System.assertEquals('Pending Review', [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id].Status__c);
    }

    // Dashboard totals are net: canceled gifts excluded, partial refunds subtracted
    @isTest
    static void testDashboardTotalsAreNet() {
        Account donor = makePersonAccount('Net', 'Totals', 'net.totals@test.ca');
        GiftTransaction paid = insertPaidGift(donor.Id, 'txn_net_paid', 100, 0);
        update new GiftTransaction(Id = paid.Id, Refund_Amount__c = 20);
        GiftTransaction cancelled = insertPaidGift(donor.Id, 'txn_net_cxl', 50, 0);
        update new GiftTransaction(Id = cancelled.Id, Status = 'Unpaid');
        update new GiftTransaction(Id = cancelled.Id, Status = 'Canceled');

        Test.startTest();
        Map<String, Object> stats = ZeffyConnectDonationService.getDashboardStats();
        Test.stopTest();

        System.assertEquals(80, (Decimal) stats.get('totalAmount'));
    }

    // Stored payload can be re-run from the webhook log by a Settings admin
    @isTest
    static void testReprocessWebhookLog() {
        Zeffy_Webhook_Log__c log = new Zeffy_Webhook_Log__c(
            Status__c = 'TICKET_INSERT_FAILED', Occurred_At__c = DateTime.now(), Transaction_Id__c = 'txn_reproc_001',
            Raw_Payload__c = buildPayload('txn_reproc_001', 'reproc@test.ca', 'zeffy_reproc_001'),
            Has_Raw_Payload__c = true);
        insert log;
        grantSettingsAccess();

        Map<String, String> r;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            r = ZeffyConnectDonationService.reprocessWebhookLog(log.Id);
            Test.stopTest();
        }

        System.assertEquals('SUCCESS', r.get('status'));
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_reproc_001']);
        Zeffy_Webhook_Log__c orig = [SELECT Raw_Payload__c, Has_Raw_Payload__c FROM Zeffy_Webhook_Log__c WHERE Id = :log.Id];
        System.assertEquals(false, orig.Has_Raw_Payload__c, 'Processed payload copy is released');
        List<ZeffyConnectDonationService.WebhookLogRow> rows = ZeffyConnectDonationService.getWebhookLogs('All', null, 10);
        System.assertEquals(2, rows.size(), 'Reprocess writes its own log row');
    }

    @isTest
    static void testReprocessWebhookLogRequiresSettingsAccess() {
        Zeffy_Webhook_Log__c log = new Zeffy_Webhook_Log__c(Status__c = 'UNHANDLED_EXCEPTION', Occurred_At__c = DateTime.now(),
            Raw_Payload__c = '{}', Has_Raw_Payload__c = true);
        insert log;
        Profile std = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(Alias = 'zcnoadm', Email = 'zc.noadmin@test.example', EmailEncodingKey = 'UTF-8',
            LastName = 'NoAdmin', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_CA', ProfileId = std.Id,
            TimeZoneSidKey = 'America/Toronto', Username = 'zc.noadmin.' + DateTime.now().getTime() + '@test.example');
        insert u;
        Boolean threw = false;
        System.runAs(u) {
            try {
                ZeffyConnectDonationService.reprocessWebhookLog(log.Id);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        System.assert(threw, 'Only Settings admins may reprocess webhooks');
    }

    @isTest
    static void testUndoAndReassignRequireZeffyAccess() {
        Profile std = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(Alias = 'zcnoacc', Email = 'zc.noaccess@test.example', EmailEncodingKey = 'UTF-8',
            LastName = 'NoAccess', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_CA', ProfileId = std.Id,
            TimeZoneSidKey = 'America/Toronto', Username = 'zc.noaccess.' + DateTime.now().getTime() + '@test.example');
        insert u;
        Account a = makePersonAccount('No', 'Access', 'no.access@test.ca');
        Zeffy_Review_Ticket__c t = new Zeffy_Review_Ticket__c(Status__c = 'Resolved - Linked', Resolved_Account__c = a.Id,
            Zeffy_Contact_Id__c = 'zeffy_noaccess');
        insert t;
        Integer denied = 0;
        System.runAs(u) {
            try { ZeffyConnectDonationService.undoResolution(t.Id); } catch (AuraHandledException e) { denied++; }
            try { ZeffyConnectDonationService.getReassignPreview(t.Id); } catch (AuraHandledException e) { denied++; }
            try { ZeffyConnectDonationService.reassignZeffyId(t.Id, a.Id); } catch (AuraHandledException e) { denied++; }
            // Reads that reach every gift (not only the user's own) need the same access
            try { ZeffyConnectDonationService.getTicketDetail(t.Id); } catch (AuraHandledException e) { denied++; }
            try { ZeffyConnectDonationService.getDashboardStats(); } catch (AuraHandledException e) { denied++; }
            try { ZeffyConnectDonationService.getDonationHistory(null); } catch (AuraHandledException e) { denied++; }
            try { ZeffyConnectDonationService.markAmountReviewed(t.Id); } catch (AuraHandledException e) { denied++; }
        }
        System.assertEquals(7, denied, 'Undo, Reassign and gift-wide reads need a Zeffy Connect permission set');
        System.assertEquals('Resolved - Linked', [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id].Status__c);
    }

    // Resolve Group: the account is built from the ticket the reviewer saw, and later batches keep
    // 'Resolved - New Contact' on the account the first batch created
    @isTest
    static void testBulkCreateUsesHeadTicketAndContinues() {
        Zeffy_Review_Ticket__c older = bulkTicket('txn_head_old', 'zeffy_head_grp');
        older.First_Name__c = 'Old'; older.Last_Name__c = 'Variant';
        insert older;
        Zeffy_Review_Ticket__c newer = bulkTicket('txn_head_new', 'zeffy_head_grp');
        newer.First_Name__c = 'Shown'; newer.Last_Name__c = 'Name';
        insert newer;
        Zeffy_Review_Ticket__c later = bulkTicket('txn_head_later', 'zeffy_head_grp');
        insert later;

        Test.startTest();
        Map<String,Object> res = ZeffyConnectDonationService.bulkResolveCreateNew(
            new List<Id>{ older.Id, newer.Id }, 'individual', null, newer.Id, null);
        Id acctId = (Id) res.get('accountId');
        Map<String,Object> res2 = ZeffyConnectDonationService.bulkResolveCreateNew(
            new List<Id>{ later.Id }, 'individual', null, newer.Id, acctId);
        Test.stopTest();

        Account a = [SELECT FirstName, LastName FROM Account WHERE Id = :acctId];
        System.assertEquals('Shown', a.FirstName, 'Built from the ticket the reviewer saw');
        System.assertEquals('Name', a.LastName);
        System.assertEquals(1, (Integer) res2.get('resolved'));
        System.assertEquals(1, [SELECT COUNT() FROM Account WHERE FirstName = 'Shown'], 'No second account');
        System.assertEquals(3, [SELECT COUNT() FROM Zeffy_Review_Ticket__c
            WHERE Status__c = 'Resolved - New Contact' AND Resolved_Account__c = :acctId]);
    }

    @isTest
    static void testGetGroupTicketsIgnoresListFilter() {
        Zeffy_Review_Ticket__c a = bulkTicket('txn_grp_all_1', 'zeffy_grp_all');
        Zeffy_Review_Ticket__c b = bulkTicket('txn_grp_all_2', 'zeffy_grp_all');
        b.Manual_Assignee_Id__c = UserInfo.getUserId();
        insert new List<Zeffy_Review_Ticket__c>{ a, b, bulkTicket('txn_grp_other', 'zeffy_grp_other') };
        System.assertEquals(2, ZeffyConnectDonationService.getGroupTickets('zeffy_grp_all').size());
        System.assertEquals(0, ZeffyConnectDonationService.getGroupTickets(null).size());
    }

    // Exact names are found even when the partial search returns many accounts; accents are ignored;
    // a person with the same full name ranks with (and, for an individual donor, before) a church
    @isTest
    static void testFindAccountMatchesExactNameAndAccents() {
        List<Account> noise = new List<Account>();
        for (Integer i = 0; i < 12; i++) noise.add(new Account(Name = 'Aaa Espoir ' + i));
        insert noise;
        Account church = new Account(Name = 'Eglise Espoir');
        Account accented = new Account(Name = 'Eglise Lumière');
        Account biz = new Account(Name = 'Jean Tremblay');
        insert new List<Account>{ church, accented, biz };
        Account person = makePersonAccount('Jean', 'Tremblay', 'jean.other@test.ca');

        Zeffy_Review_Ticket__c tChurch = bulkTicket('txn_match_church', null);
        tChurch.First_Name__c = 'Eglise'; tChurch.Last_Name__c = 'Espoir'; tChurch.Email__c = 'nobody@test.ca';
        Zeffy_Review_Ticket__c tAccent = bulkTicket('txn_match_accent', null);
        tAccent.First_Name__c = 'Église'; tAccent.Last_Name__c = 'Lumière'; tAccent.Email__c = 'nobody3@test.ca';
        Zeffy_Review_Ticket__c tJean = bulkTicket('txn_match_jean', null);
        tJean.First_Name__c = 'Jean'; tJean.Last_Name__c = 'Tremblay'; tJean.Email__c = 'nobody2@test.ca';
        insert new List<Zeffy_Review_Ticket__c>{ tChurch, tAccent, tJean };

        Test.startTest();
        List<ZeffyConnectDonationService.AccountMatch> mChurch = ZeffyConnectDonationService.findAccountMatches(tChurch.Id);
        List<ZeffyConnectDonationService.AccountMatch> mAccent = ZeffyConnectDonationService.findAccountMatches(tAccent.Id);
        List<ZeffyConnectDonationService.AccountMatch> mJean = ZeffyConnectDonationService.findAccountMatches(tJean.Id);
        Test.stopTest();

        System.assertEquals('eglise saint jean', ZeffyConnectDonationService.foldName('Église  Saint-Jean'));
        System.assertEquals(null, ZeffyConnectDonationService.foldName('  '));
        // 12 partial matches sort before it, the exact-name search still brings it first
        System.assertEquals(church.Id, mChurch[0].id);
        System.assertEquals(80, mChurch[0].score);
        System.assertEquals(accented.Id, mAccent[0].id, 'Accents are ignored when comparing names');
        System.assertEquals(80, mAccent[0].score);
        System.assertEquals(person.Id, mJean[0].id, 'Individual donor: the person account comes first');
        System.assertEquals(80, mJean[0].score);
        System.assertEquals(biz.Id, mJean[1].id);
        System.assertEquals(80, mJean[1].score);
    }

    // SOQL misses "Côté" when Zeffy sends "Cote": the SOSL search (accent-insensitive) still finds it
    @isTest
    static void testFindAccountMatchesFindsAccentedNameViaSosl() {
        Account cote = makePersonAccount('Marie', 'Côté', 'marie.cote.sosl@test.ca');
        Zeffy_Review_Ticket__c t = bulkTicket('txn_sosl_cote', 'zeffy_sosl_cote');
        t.First_Name__c = 'Marie'; t.Last_Name__c = 'Cote'; t.Email__c = 'other.sosl@test.ca';
        insert t;
        Test.setFixedSearchResults(new List<Id>{ cote.Id });

        Test.startTest();
        List<ZeffyConnectDonationService.AccountMatch> m = ZeffyConnectDonationService.findAccountMatches(t.Id);
        Test.stopTest();

        System.assertEquals(1, m.size());
        System.assertEquals(cote.Id, m[0].id);
        System.assertEquals(80, m[0].score, 'Same first and last name once accents are ignored');
        System.assertEquals('"Saint" AND "Jean"', ZeffyConnectDonationService.soslTerm(' Saint-Jean! '));
        System.assertEquals('"Smith" AND "and" AND "Sons"', ZeffyConnectDonationService.soslTerm('Smith and Sons'));
        System.assertEquals(null, ZeffyConnectDonationService.soslTerm('-'));
    }

    // ─── Robot tickets (Auto-Processed) ──────────────────────────────────────

    @isTest
    static void testAutoProcessedCreatesRobotTicket() {
        Account donor = makePersonAccount('Robot', 'Ticket', 'robot.tkt@test.ca');
        linkIdentity(donor.Id, 'zeffy_robot_tkt', 'robot.tkt@test.ca');

        Test.startTest();
        ZeffyConnectDonationService.processWebhook(buildPayload('txn_robot_tkt', 'robot.tkt@test.ca', 'zeffy_robot_tkt'));
        Test.stopTest();

        GiftTransaction gt = [SELECT Id FROM GiftTransaction WHERE Zeffy_Transaction_Id__c = 'txn_robot_tkt'];
        Zeffy_Review_Ticket__c t = [SELECT Status__c, Resolved_Account__c, Resolved_Gift__c, Resolved_By__c,
                                           Resolved_At__c, Address_Differs__c
                                    FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_robot_tkt'];
        System.assertEquals('Auto-Processed', t.Status__c);
        System.assertEquals(donor.Id, t.Resolved_Account__c);
        System.assertEquals(gt.Id, t.Resolved_Gift__c);
        System.assertEquals(null, t.Resolved_By__c, 'Resolved by the robot, not a person');
        System.assertNotEquals(null, t.Resolved_At__c);
        System.assertEquals(true, t.Address_Differs__c, 'Account has no Billing address, Zeffy sent one');
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId = :t.Id], 'No task for robot tickets');
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c
                                WHERE Action__c = 'Auto-Processed' AND Ticket__c = :t.Id]);

        // Robot tickets stay out of the Open list but have their own filter
        Set<Id> openIds = new Map<Id, Zeffy_Review_Ticket__c>(ZeffyConnectDonationService.getTickets('Open')).keySet();
        System.assert(!openIds.contains(t.Id), 'Auto-Processed tickets are not open work');
        System.assertEquals(1, ZeffyConnectDonationService.getTickets('Auto-Processed').size());

        // Still counted as robot work on the dashboard
        Map<String, Object> stats = ZeffyConnectDonationService.getDashboardStats();
        System.assertEquals(1, stats.get('autoProcessed'));
        System.assertEquals(0, stats.get('manualResolved'));
    }

    @isTest
    static void testUndoRobotTicket() {
        Account donor = makePersonAccount('Robot', 'Undo', 'robot.undo@test.ca');
        linkIdentity(donor.Id, 'zeffy_robot_undo', 'robot.undo@test.ca');
        ZeffyConnectDonationService.processWebhook(buildPayload('txn_robot_undo', 'robot.undo@test.ca', 'zeffy_robot_undo'));
        Zeffy_Review_Ticket__c t = [SELECT Id FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_robot_undo'];

        Test.startTest();
        Map<String, String> summary = ZeffyConnectDonationService.undoResolution(t.Id);
        Test.stopTest();

        System.assertEquals('true', summary.get('giftDeleted'));
        Zeffy_Review_Ticket__c after = [SELECT Status__c, Resolved_Gift__c, Address_Differs__c FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id];
        System.assertEquals('Pending Review', after.Status__c);
        System.assertEquals(null, after.Resolved_Gift__c);
        System.assertEquals(false, after.Address_Differs__c);
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Identity__c WHERE Zeffy_Contact_Id__c = 'zeffy_robot_undo'],
            'A Zeffy ID linked before the robot ran is kept');
    }

    @isTest
    static void testPaymentUpdatedSyncsReceiptOnRobotTicket() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Updated__c = true;
        update cfg;
        Account donor = makePersonAccount('Robot', 'Receipt', 'robot.rcpt@test.ca');
        linkIdentity(donor.Id, 'zeffy_robot_rcpt', 'robot.rcpt@test.ca');
        ZeffyConnectDonationService.processWebhook(buildPayload('txn_robot_rcpt', 'robot.rcpt@test.ca', 'zeffy_robot_rcpt'));

        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(
            buildUpdatedPayload('txn_robot_rcpt', 'succeeded', 'https://zeffy.com/r/robot'));
        Test.stopTest();

        System.assertEquals('https://zeffy.com/r/robot',
            [SELECT Receipt_URL__c FROM GiftTransaction WHERE Zeffy_Transaction_Id__c = 'txn_robot_rcpt'].Receipt_URL__c);
        System.assertEquals('https://zeffy.com/r/robot',
            [SELECT Receipt_URL__c FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_robot_rcpt'].Receipt_URL__c);
    }

    // ─── Address mismatch detector ───────────────────────────────────────────

    @isTest
    static void testAddressComparisonNormalizes() {
        Zeffy_Review_Ticket__c t = new Zeffy_Review_Ticket__c(
            Address__c = '1234, Boul. Saint-Laurent App. 5', City__c = 'Montréal', Postal_Code__c = 'h2x 1a1');
        Account same = new Account(BillingStreet = '1234 Boulevard St-Laurent Apt 5',
                                   BillingCity = 'MONTREAL', BillingPostalCode = 'H2X1A1');
        Account other = new Account(BillingStreet = '99 Rue Principale',
                                    BillingCity = 'Montreal', BillingPostalCode = 'H2X 1A1');
        System.assertEquals(false, ZeffyConnectDonationService.addressDiffers(t, same), 'Same address, other spelling');
        System.assertEquals(true,  ZeffyConnectDonationService.addressDiffers(t, other));
        System.assertEquals(true,  ZeffyConnectDonationService.addressDiffers(t, new Account()), 'Empty account address');
        System.assertEquals(false, ZeffyConnectDonationService.addressDiffers(new Zeffy_Review_Ticket__c(), other),
            'Zeffy sent no address');
        System.assertEquals(false, ZeffyConnectDonationService.addressDiffers(t, null));
    }

    @isTest
    static void testUpdateAccountAddressFromTicketClearsFlag() {
        Account donor = makePersonAccount('Addr', 'Update', 'addr.upd@test.ca');
        donor.BillingStreet = '99 Old Street';
        donor.BillingCity   = 'Laval';
        update donor;
        linkIdentity(donor.Id, 'zeffy_addr_upd', 'addr.upd@test.ca');
        ZeffyConnectDonationService.processWebhook(buildPayload('txn_addr_upd', 'addr.upd@test.ca', 'zeffy_addr_upd'));
        Zeffy_Review_Ticket__c t = [SELECT Id, Address_Differs__c FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_addr_upd'];
        System.assertEquals(true, t.Address_Differs__c);
        System.assertEquals(1, ZeffyConnectDonationService.getTickets('AddressDiffers').size());

        Test.startTest();
        ZeffyConnectDonationService.updateAccountAddressFromTicket(t.Id);
        Test.stopTest();

        Account after = [SELECT BillingStreet, BillingCity, BillingState, BillingPostalCode FROM Account WHERE Id = :donor.Id];
        System.assertEquals('1 Rue Test', after.BillingStreet);
        System.assertEquals('Montréal', after.BillingCity);
        System.assertEquals(false, [SELECT Address_Differs__c FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id].Address_Differs__c);
        System.assertEquals(0, ZeffyConnectDonationService.getTickets('AddressDiffers').size());
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Action__c = 'Address Updated' AND Ticket__c = :t.Id]);
    }

    @isTest
    static void testAddressFlagClearsWhenAccountFixedDirectly() {
        Account donor = makePersonAccount('Addr', 'Direct', 'addr.direct@test.ca');
        linkIdentity(donor.Id, 'zeffy_addr_direct', 'addr.direct@test.ca');
        ZeffyConnectDonationService.processWebhook(buildPayload('txn_addr_direct', 'addr.direct@test.ca', 'zeffy_addr_direct'));
        Zeffy_Review_Ticket__c t = [SELECT Id FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_addr_direct'];

        // Staff fixes the account in Salesforce, not through the ticket
        update new Account(Id = donor.Id, BillingStreet = '1 rue Test', BillingCity = 'Montreal', BillingPostalCode = 'H1A1A1');

        Test.startTest();
        Zeffy_Review_Ticket__c detail = ZeffyConnectDonationService.getTicketDetail(t.Id);
        Test.stopTest();

        System.assertEquals(false, detail.Address_Differs__c, 'Flag recomputed when the ticket is opened');
        System.assertEquals(0, ZeffyConnectDonationService.refreshAllAddressFlags(), 'Nothing left flagged');
    }

    @isTest
    static void testUpdateAccountAddressRequiresLinkedAccount() {
        Zeffy_Review_Ticket__c t = new Zeffy_Review_Ticket__c(Status__c = 'Pending Review', Address__c = '1 Rue X');
        insert t;
        Boolean threw = false;
        try {
            ZeffyConnectDonationService.updateAccountAddressFromTicket(t.Id);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'A ticket without account cannot update an address');
    }

    @isTest
    static void testGetTicketsStageFilters() {
        insert new List<Zeffy_Review_Ticket__c>{
            new Zeffy_Review_Ticket__c(Status__c = 'Holding',        Zeffy_Transaction_Id__c = 'stg_hold'),
            new Zeffy_Review_Ticket__c(Status__c = 'Payment Failed', Zeffy_Transaction_Id__c = 'stg_fail'),
            new Zeffy_Review_Ticket__c(Status__c = 'Auto-Processed', Zeffy_Transaction_Id__c = 'stg_auto'),
            new Zeffy_Review_Ticket__c(Status__c = 'Resolved - Linked', Zeffy_Transaction_Id__c = 'stg_link'),
            new Zeffy_Review_Ticket__c(Status__c = 'Closed',         Zeffy_Transaction_Id__c = 'stg_closed'),
            new Zeffy_Review_Ticket__c(Status__c = 'Skipped',        Zeffy_Transaction_Id__c = 'stg_skip')
        };
        Test.startTest();
        System.assertEquals(2, ZeffyConnectDonationService.getTickets('Waiting').size());
        System.assertEquals(1, ZeffyConnectDonationService.getTickets('Resolved').size());
        System.assertEquals(1, ZeffyConnectDonationService.getTickets('Auto-Processed').size());
        System.assertEquals(2, ZeffyConnectDonationService.getTickets('ClosedAll').size());
        System.assertEquals(6, ZeffyConnectDonationService.getTickets('All').size());
        Test.stopTest();
    }

    // ═══ Coverage for production readiness (2026-10-09) ═════════════════════

    private static String withRecurring(String body, String subId, String status) {
        return body.replace('"recurring":null', '"recurring":{"is_recurring":true,"status":"' + status + '",' +
            '"interval":"monthly","subscription_id":"' + subId + '","current_period_start":null,"current_period_end":null}');
    }

    private static GiftCommitment insertCommitment(Id donorId, String subId) {
        GiftCommitment cmt = new GiftCommitment(Name = 'Zeffy Recurring ' + subId, DonorId = donorId, Status = 'Active',
            ScheduleType = 'Recurring', RecurrenceType = 'OpenEnded', EffectiveStartDate = Date.today().addMonths(-1),
            Zeffy_Subscription_Id__c = subId);
        insert cmt;
        return cmt;
    }

    // payment.updated on an auto-matched gift (no ticket) carrying a dispute → the gift records it
    @isTest
    static void testPaymentUpdatedDisputeOnGiftWithoutTicket() {
        enablePaymentUpdated();
        Account donor = makePersonAccount('Disp', 'Gift', 'disp.gift@test.ca');
        GiftTransaction gt = insertPaidGift(donor.Id, 'txn_disp_gt', 50, 0);
        String body = buildUpdatedPayload('txn_disp_gt', 'succeeded', null).replace('"dispute":null',
            '"dispute":{"id":"d9","status":"needs_response","reason":"fraudulent","amount":5000}');

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult r = ZeffyConnectDonationService.processWebhookWithResult(body);
        Test.stopTest();

        System.assertEquals('SUCCESS', r.status);
        GiftTransaction after = [SELECT Dispute_Status__c, Dispute_Reason__c, Dispute_Amount__c FROM GiftTransaction WHERE Id = :gt.Id];
        System.assertEquals('needs_response', after.Dispute_Status__c);
        System.assertEquals('fraudulent', after.Dispute_Reason__c);
        System.assertEquals(50, after.Dispute_Amount__c);
    }

    // Online payment deleted, gift cannot be cancelled → the existing ticket carries the error
    @isTest
    static void testPaymentDeletedCancelFailureOnTicket() {
        enablePaymentDeleted();
        Account donor = makePersonAccount('Del', 'TicketFail', 'del.tfail@test.ca');
        GiftTransaction gt = insertPaidGift(donor.Id, 'txn_del_tfail', 50, 0);
        Zeffy_Review_Ticket__c t = insertLinkedTicket(donor.Id, gt.Id, 'txn_del_tfail', 50);

        ZeffyConnectDonationService.failGiftCancel = true;
        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(buildDeletedPayload('txn_del_tfail'));
        Test.stopTest();
        ZeffyConnectDonationService.failGiftCancel = false;

        Zeffy_Review_Ticket__c after = [SELECT Status__c, Error_Message__c FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id];
        System.assertEquals('Payment Failed', after.Status__c);
        System.assert(after.Error_Message__c.contains('could not be cancelled'), after.Error_Message__c);
        System.assertEquals('Paid', [SELECT Status FROM GiftTransaction WHERE Id = :gt.Id].Status);
    }

    // Manual payment deleted while only its ticket exists (no gift yet) → ticket removed, donor name from the ticket
    @isTest
    static void testManualPaymentDeletedTicketOnly() {
        enablePaymentDeleted();
        insert new Zeffy_Review_Ticket__c(Status__c = 'Pending Review', First_Name__c = 'Only', Last_Name__c = 'Ticket',
            Amount__c = 15, Gift_Date__c = Date.today(), Zeffy_Transaction_Id__c = 'txn_man_tonly');

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult r =
            ZeffyConnectDonationService.processWebhookWithResult(typedDeletedPayload('txn_man_tonly', 'manual'));
        Test.stopTest();

        System.assertEquals('SUCCESS', r.status);
        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_man_tonly']);
        String notes = [SELECT Notes__c FROM Zeffy_Connect_Audit_Log__c WHERE Action__c = 'Manual Payment Deleted'].Notes__c;
        System.assert(notes.contains('Donor: Only Ticket'), notes);
    }

    // Known donor's next monthly installment reuses the existing commitment (no second one)
    @isTest
    static void testRobotRecurringReusesExistingCommitment() {
        Account donor = makePersonAccount('Rec', 'Reuse', 'rec.reuse@test.ca');
        linkIdentity(donor.Id, 'zeffy_rec_reuse', 'rec.reuse@test.ca');
        GiftCommitment cmt = insertCommitment(donor.Id, 'sub_reuse');

        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(withRecurring(
            buildPayload('txn_rec_reuse', 'rec.reuse@test.ca', 'zeffy_rec_reuse'), 'sub_reuse', 'active'));
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM GiftCommitment WHERE Zeffy_Subscription_Id__c = 'sub_reuse']);
        System.assertEquals(cmt.Id, [SELECT GiftCommitmentId FROM GiftTransaction WHERE Zeffy_Transaction_Id__c = 'txn_rec_reuse'].GiftCommitmentId);
    }

    // Subscription cancelled in Zeffy → the commitment is Closed and logged
    @isTest
    static void testCancelledSubscriptionClosesCommitment() {
        enablePaymentUpdated();
        Account donor = makePersonAccount('Rec', 'Cancel', 'rec.cancel@test.ca');
        GiftCommitment cmt = insertCommitment(donor.Id, 'sub_cancel');
        insertPaidGift(donor.Id, 'txn_rec_cancel', 50, 0);
        String body = buildRecurringAmountPayload('txn_rec_cancel', 5000, DateTime.now().getTime() / 1000, 'sub_cancel')
            .replace('"status":"active"', '"status":"canceled"');

        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(body);
        Test.stopTest();

        GiftCommitment after = [SELECT Status, ExpectedEndDate FROM GiftCommitment WHERE Id = :cmt.Id];
        System.assertEquals('Closed', after.Status);
        System.assertEquals(Date.today(), after.ExpectedEndDate);
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Action__c = 'Recurring Updated by Zeffy']);
    }

    // A commitment sync failure is non-critical: the webhook still succeeds
    @isTest
    static void testCommitmentSyncFailureIsNonCritical() {
        enablePaymentUpdated();
        Account donor = makePersonAccount('Rec', 'SyncFail', 'rec.syncfail@test.ca');
        GiftCommitment cmt = insertCommitment(donor.Id, 'sub_syncfail');
        insertPaidGift(donor.Id, 'txn_rec_syncfail', 50, 0);
        String body = buildRecurringAmountPayload('txn_rec_syncfail', 5000, DateTime.now().getTime() / 1000, 'sub_syncfail')
            .replace('"status":"active"', '"status":"canceled"');

        ZeffyConnectDonationService.failCommitmentSync = true;
        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(body);
        Test.stopTest();
        ZeffyConnectDonationService.failCommitmentSync = false;

        System.assertEquals('Active', [SELECT Status FROM GiftCommitment WHERE Id = :cmt.Id].Status);
    }

    // Campaign creation failure never blocks the gift
    @isTest
    static void testCampaignCreateFailureStillCreatesGift() {
        Zeffy_Review_Ticket__c t = bulkTicket('txn_camp_fail', null);
        t.Form_Id__c   = 'form_camp_fail';
        t.Form_Name__c = 'Failing Campaign';
        insert t;

        ZeffyConnectDonationService.failCampaignCreate = true;
        Test.startTest();
        ZeffyConnectDonationService.resolveCreateNew(t.Id, 'individual', null);
        Test.stopTest();
        ZeffyConnectDonationService.failCampaignCreate = false;

        System.assertEquals(0, [SELECT COUNT() FROM Campaign WHERE Zeffy_Form_Id__c = 'form_camp_fail']);
        System.assertEquals(null, [SELECT CampaignId FROM GiftTransaction WHERE Zeffy_Transaction_Id__c = 'txn_camp_fail'].CampaignId);
    }

    // A bad task owner in Settings never costs the ticket: the failure is logged instead
    @isTest
    static void testPendingTaskBadOwnerIsLogged() {
        Account notAUser = makePersonAccount('Not', 'Owner', 'not.owner@test.ca');
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Auto_Task_Enabled__c = true;
        cfg.Task_Owner_Id__c     = notAUser.Id;
        upsert cfg;

        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(buildPayload('txn_task_bad', 'task.bad@test.ca', 'zeffy_task_bad'));
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_task_bad']);
        System.assertEquals(0, [SELECT COUNT() FROM Task]);
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Action__c = 'Task Not Created']);
    }

    // An Account update rejected by Salesforce (invalid email) does not block the resolution
    @isTest
    static void testResolveLinkExistingAccountUpdateFailureIsNonCritical() {
        Account donor = makePersonAccount('Upd', 'Fail', 'upd.fail@test.ca');
        Zeffy_Review_Ticket__c t = bulkTicket('txn_acc_upd_fail', null);
        insert t;

        Test.startTest();
        String warning = ZeffyConnectDonationService.resolveLinkExistingEdited(t.Id, donor.Id, null, 'PersonEmail', false, false, false,
            new Map<String, String>{ 'email' => 'not-an-email' });
        Test.stopTest();

        System.assertNotEquals(null, warning, 'Staff is told the account kept its values');
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Action__c = 'Account Not Updated']);
        System.assertEquals('upd.fail@test.ca', [SELECT PersonEmail FROM Account WHERE Id = :donor.Id].PersonEmail);
        System.assertEquals('Resolved - Linked', [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id].Status__c);
    }

    // Linking never renames the account (e.g. a church): a name sent by the reviewer is ignored, the rest is saved
    @isTest
    static void testLinkToBusinessAccountIgnoresName() {
        Account org = new Account(Name = 'Eglise Test Name');
        insert org;
        Zeffy_Review_Ticket__c t1 = bulkTicket('txn_biz_name_1', null);
        Zeffy_Review_Ticket__c t2 = bulkTicket('txn_biz_name_2', null);
        insert new List<Zeffy_Review_Ticket__c>{ t1, t2 };

        Test.startTest();
        ZeffyConnectDonationService.resolveLinkExistingEdited(t1.Id, org.Id, null, null, true, true, true,
            new Map<String, String>{ 'firstName' => 'Eglise', 'lastName' => 'X', 'city' => 'Laval' });
        Map<String,Object> res = ZeffyConnectDonationService.bulkResolveLinkExistingEdited(
            new List<Id>{ t2.Id }, org.Id, null,
            new Map<String, String>{ 'FirstName' => 'Eglise', 'LastName' => 'X', 'BillingCity' => 'Gatineau' },
            new List<String>());
        Test.stopTest();

        Account a = [SELECT Name, BillingCity FROM Account WHERE Id = :org.Id];
        System.assertEquals('Eglise Test Name', a.Name);
        System.assertEquals('Gatineau', a.BillingCity, 'Address is still saved on a business account');
        System.assertEquals(1, (Integer) res.get('resolved'));
        System.assertEquals(2, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Action__c = 'Account Updated']);
    }

    // Bulk create: a ticket with neither Zeffy ID nor email is its own group
    @isTest
    static void testBulkResolveCreateNewTicketWithoutIdOrEmail() {
        Zeffy_Review_Ticket__c t = bulkTicket('txn_bulk_noid', null);
        t.Email__c = null;
        insert t;

        Test.startTest();
        Map<String, Object> res = ZeffyConnectDonationService.bulkResolveCreateNew(new List<Id>{ t.Id }, 'individual', null, null, null);
        Test.stopTest();

        System.assertEquals(1, res.get('resolved'), String.valueOf(res.get('errors')));
    }

    @isTest
    static void testReprocessWebhookLogWithoutPayload() {
        Zeffy_Webhook_Log__c log = new Zeffy_Webhook_Log__c(Status__c = 'UNHANDLED_EXCEPTION', Occurred_At__c = DateTime.now());
        insert log;
        grantSettingsAccess();
        Boolean threw = false;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            try {
                ZeffyConnectDonationService.reprocessWebhookLog(log.Id);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        System.assert(threw, 'A log without payload cannot be reprocessed');
    }

    @isTest
    static void testUpdateAccountAddressFailureThrows() {
        Account donor = makePersonAccount('Addr', 'Fail', 'addr.fail@test.ca');
        Zeffy_Review_Ticket__c t = new Zeffy_Review_Ticket__c(Status__c = 'Resolved - Linked', Resolved_Account__c = donor.Id,
            Address__c = '1 Rue X', City__c = 'Laval', Country__c = 'CA');
        insert t;
        ZeffyConnectDonationService.failAddressUpdate = true;
        Boolean threw = false;
        try {
            ZeffyConnectDonationService.updateAccountAddressFromTicket(t.Id);
        } catch (AuraHandledException e) {
            threw = true;
        }
        ZeffyConnectDonationService.failAddressUpdate = false;
        System.assert(threw, 'Address update failure is reported to the screen');
    }

    // Top campaigns are ranked by net amount
    @isTest
    static void testDashboardRanksCampaignsByNet() {
        Account donor = makePersonAccount('Camp', 'Rank', 'camp.rank@test.ca');
        Campaign small = new Campaign(Name = 'Small Campaign', IsActive = true);
        Campaign big   = new Campaign(Name = 'Big Campaign', IsActive = true);
        Campaign tie   = new Campaign(Name = 'Tie Campaign', IsActive = true);
        insert new List<Campaign>{ small, big, tie };
        List<GiftTransaction> gifts = new List<GiftTransaction>();
        Map<String, Id> campaignByTx = new Map<String, Id>{ 'txn_rank_1' => small.Id, 'txn_rank_2' => big.Id, 'txn_rank_3' => tie.Id };
        for (String txId : campaignByTx.keySet()) {
            gifts.add(new GiftTransaction(Name = 'ZF-' + txId, DonorId = donor.Id,
                OriginalAmount = txId == 'txn_rank_2' ? 200 : 20, PaymentMethod = 'Credit Card', GiftType = 'Individual',
                Status = 'Paid', TransactionDate = Date.today(), Zeffy_Transaction_Id__c = txId,
                CampaignId = campaignByTx.get(txId)));
        }
        insert gifts;

        Test.startTest();
        Map<String, Object> stats = ZeffyConnectDonationService.getDashboardStats();
        Test.stopTest();

        List<Map<String, Object>> byCampaign = (List<Map<String, Object>>) stats.get('byCampaign');
        System.assertEquals(3, byCampaign.size());
        System.assertEquals('Big Campaign', byCampaign[0].get('name'));
    }

    // Undo keeps the recurring commitment while other installments still point to it
    @isTest
    static void testUndoResolutionKeepsCommitmentWithOtherInstallments() {
        Zeffy_Review_Ticket__c t = bulkTicket('txn_undo_keep_001', null);
        t.Is_Recurring__c           = true;
        t.Zeffy_Subscription_Id__c  = 'sub_undo_keep_001';
        t.Subscription_Frequency__c = 'monthly';
        insert t;
        ZeffyConnectDonationService.resolveCreateNew(t.Id, 'individual', null);
        GiftCommitment cmt = [SELECT Id, DonorId FROM GiftCommitment WHERE Zeffy_Subscription_Id__c = 'sub_undo_keep_001'];
        insert new GiftTransaction(Name = 'ZF-other', DonorId = cmt.DonorId, OriginalAmount = 20, PaymentMethod = 'Credit Card',
            GiftType = 'Individual', Status = 'Paid', TransactionDate = Date.today(), TransactionDueDate = Date.today(),
            Zeffy_Transaction_Id__c = 'txn_undo_keep_002', GiftCommitmentId = cmt.Id);

        Test.startTest();
        Map<String, String> summary = ZeffyConnectDonationService.undoResolution(t.Id);
        Test.stopTest();

        System.assertEquals('1', summary.get('commitmentKept'));
        System.assertEquals(1, [SELECT COUNT() FROM GiftCommitment WHERE Id = :cmt.Id]);
    }

    // A failure while cleaning up the auto-created campaign never fails the undo
    @isTest
    static void testUndoCampaignRemovalFailureIsNonCritical() {
        Account donor = makePersonAccount('Camp', 'RemFail', 'camp.remfail@test.ca');
        Zeffy_Review_Ticket__c t = bulkTicket('txn_camp_remfail', null);
        t.Form_Id__c   = 'form_camp_remfail';
        t.Form_Name__c = 'Removal Fail Form';
        insert t;
        ZeffyConnectDonationService.resolveLinkExisting(t.Id, donor.Id, null, null, false, false, false);

        ZeffyConnectDonationService.failCampaignRemoval = true;
        Test.startTest();
        Map<String, String> summary = ZeffyConnectDonationService.undoResolution(t.Id);
        Test.stopTest();
        ZeffyConnectDonationService.failCampaignRemoval = false;

        System.assertEquals('true', summary.get('giftDeleted'));
        System.assertEquals(null, summary.get('campaignDeleted'));
        System.assertEquals(1, [SELECT COUNT() FROM Campaign WHERE Zeffy_Form_Id__c = 'form_camp_remfail']);
    }

    // History search by ticket number finds the gift resolved from that ticket
    @isTest
    static void testGetDonationHistorySearchByTicketNumber() {
        Account donor = makePersonAccount('Hist', 'TicketNo', 'hist.tno@test.ca');
        Zeffy_Review_Ticket__c t = bulkTicket('txn_hist_tno', null);
        insert t;
        ZeffyConnectDonationService.resolveLinkExisting(t.Id, donor.Id, null, null, false, false, false);
        String ticketNo = [SELECT Name FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id].Name;

        Test.startTest();
        List<ZeffyConnectDonationService.DonationHistoryRow> rows = ZeffyConnectDonationService.getDonationHistory(ticketNo);
        Test.stopTest();

        System.assertEquals(1, rows.size());
    }

    // CSV import skips a payment the robot already turned into a gift (gift exists, no ticket)
    @isTest
    static void testImportTicketsSkipsExistingGift() {
        Account donor = makePersonAccount('Imp', 'Gift', 'imp.gift@test.ca');
        insertPaidGift(donor.Id, 'CSV_GT_EXISTING', 10, 0);
        String rowsJson = '[{"transaction_id":"CSV_GT_EXISTING","amount":"10.00",' +
            '"currency":"CAD","gift_date":"2026-01-01","is_recurring":"false"}]';

        Test.startTest();
        Map<String, Object> result = ZeffyConnectDonationService.importTickets(rowsJson);
        Test.stopTest();

        System.assertEquals(0, result.get('imported'));
        System.assertEquals(1, result.get('skipped'));
    }

    // ─── Reassign Zeffy ID ────────────────────────────────────────────────────

    private static Zeffy_Review_Ticket__c makeResolvedZeffyTicket(Id accountId, String zid, String txId, String subId) {
        Zeffy_Review_Ticket__c t = new Zeffy_Review_Ticket__c(
            Status__c               = 'Pending Review',
            First_Name__c           = 'Kevin',
            Last_Name__c            = 'Deen',
            Email__c                = 'kevin.deen@test.ca',
            Address__c              = '412 rue Saint-Denis',
            City__c                 = 'Montréal',
            Postal_Code__c          = 'H2X 1A1',
            Amount__c               = 20.00,
            Eligible_Amount__c      = 20.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Contact_Id__c     = zid,
            Zeffy_Transaction_Id__c = txId,
            Is_Recurring__c         = subId != null,
            Zeffy_Subscription_Id__c = subId
        );
        insert t;
        ZeffyConnectDonationService.resolveLinkExisting(t.Id, accountId, null, null, false, false, false);
        return [SELECT Id, Resolved_Gift__c, Resolved_Account__c FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id];
    }

    @isTest
    static void testReassignZeffyIdMovesEverything() {
        Account wrong = makePersonAccount('Kevin', 'Dean', 'kdean@test.ca');
        Account right = makePersonAccount('Kevin', 'Deen', 'kevin.deen@test.ca');
        right.BillingStreet = '412 rue St-Denis'; right.BillingCity = 'Montreal'; right.BillingPostalCode = 'H2X1A1';
        update right;
        Zeffy_Review_Ticket__c t1 = makeResolvedZeffyTicket(wrong.Id, 'zid_ra_1', 'tx_ra_1', 'sub_ra_1');
        Zeffy_Review_Ticket__c t2 = makeResolvedZeffyTicket(wrong.Id, 'zid_ra_1', 'tx_ra_2', 'sub_ra_1');
        Zeffy_Review_Ticket__c t3 = makeResolvedZeffyTicket(wrong.Id, 'zid_ra_1', 'tx_ra_3', null);
        // What stays on the wrong account: another Zeffy ID and a hand-entered gift
        insert new Zeffy_Identity__c(Account__c = wrong.Id, Zeffy_Contact_Id__c = 'zid_ra_other',
            Is_Primary__c = false, First_Seen__c = Date.today().addDays(1), Source__c = 'Manual');
        insert new GiftTransaction(Name = 'manual', DonorId = wrong.Id, OriginalAmount = 5, PaymentMethod = 'Check',
            GiftType = 'Individual', Status = 'Paid', TransactionDate = Date.today());
        // Children of a moved gift are carried over
        GiftDesignation gd = new GiftDesignation(Name = 'RA Fund');
        insert gd;
        insert new GiftTransactionDesignation(GiftTransactionId = t1.Resolved_Gift__c, GiftDesignationId = gd.Id,
            Amount = 20, Percent = 100);
        insert new GiftSoftCredit(GiftTransactionId = t1.Resolved_Gift__c, RecipientId = right.Id);

        Map<String, Object> preview = ZeffyConnectDonationService.getReassignPreview(t3.Id);
        System.assertEquals(3, preview.get('giftCount'));
        System.assertEquals(3, preview.get('ticketCount'));
        System.assertEquals(1, preview.get('recurringCount'));
        System.assertEquals(1, preview.get('manualGifts'));
        System.assertEquals(1, ((List<Map<String, Object>>) preview.get('otherIds')).size());

        System.assertEquals(0, ZeffyConnectDonationService.searchReassignAccounts(t3.Id, 'K').size());
        Boolean matched = false;
        for (Map<String, Object> r : ZeffyConnectDonationService.searchReassignAccounts(t3.Id, 'Kevin')) {
            if (r.get('id') == right.Id) {
                matched = true;
                System.assertEquals(true, r.get('emailMatch'));
                System.assertEquals(true, r.get('addressMatch'));
            }
        }
        System.assert(matched, 'The right account is found');

        ZeffyConnectDonationService.reassignChunkSize = 2;
        Test.startTest();
        Map<String, Object> res = ZeffyConnectDonationService.reassignZeffyId(t3.Id, right.Id);
        System.assertEquals(2, res.get('moved'));
        System.assertEquals(1, res.get('remaining'));
        Test.stopTest();   // runs the Queueable with the last ticket (the one staff opened)

        System.assertEquals(3, [SELECT COUNT() FROM Zeffy_Review_Ticket__c WHERE Resolved_Account__c = :right.Id]);
        System.assertEquals(3, [SELECT COUNT() FROM GiftTransaction WHERE DonorId = :right.Id AND Zeffy_Transaction_Id__c != null]);
        System.assertEquals(1, [SELECT COUNT() FROM GiftTransaction WHERE DonorId = :wrong.Id], 'Only the hand-entered gift stays');
        System.assertEquals(0, [SELECT COUNT() FROM GiftTransaction WHERE Id = :t1.Resolved_Gift__c], 'Old gift deleted');
        Id newGift = [SELECT Resolved_Gift__c FROM Zeffy_Review_Ticket__c WHERE Id = :t1.Id].Resolved_Gift__c;
        System.assertEquals(1, [SELECT COUNT() FROM GiftTransactionDesignation WHERE GiftTransactionId = :newGift]);
        System.assertEquals(1, [SELECT COUNT() FROM GiftSoftCredit WHERE GiftTransactionId = :newGift]);
        System.assertEquals(right.Id, [SELECT DonorId FROM GiftCommitment WHERE Zeffy_Subscription_Id__c = 'sub_ra_1'].DonorId);
        System.assertEquals(right.Id, [SELECT Account__c FROM Zeffy_Identity__c WHERE Zeffy_Contact_Id__c = 'zid_ra_1'].Account__c);
        System.assertEquals(true, [SELECT Is_Primary__c FROM Zeffy_Identity__c WHERE Zeffy_Contact_Id__c = 'zid_ra_other'].Is_Primary__c,
            'The account keeps a primary Zeffy ID');
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Action__c = 'Zeffy ID Reassigned']);
        System.assertEquals(3, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Action__c = 'Gift Rebuilt']);

        Map<String, Object> prog = ZeffyConnectDonationService.getReassignProgress(t3.Id, wrong.Id, null);
        System.assertEquals('done', prog.get('status'));
        System.assertEquals(0, prog.get('remaining'));
        System.assert(((List<Map<String, String>>) prog.get('logs')).size() > 0);
    }

    @isTest
    static void testReassignZeffyIdValidation() {
        Account a = makePersonAccount('Val', 'One', 'val1@test.ca');
        Zeffy_Review_Ticket__c open = new Zeffy_Review_Ticket__c(Status__c = 'Pending Review', Zeffy_Contact_Id__c = 'zid_val',
            Zeffy_Transaction_Id__c = 'tx_val_open', Amount__c = 1);
        insert open;
        Integer errors = 0;
        try { ZeffyConnectDonationService.getReassignPreview(open.Id); } catch (AuraHandledException e) { errors++; }
        try { ZeffyConnectDonationService.reassignZeffyId(open.Id, a.Id); } catch (AuraHandledException e) { errors++; }
        Zeffy_Review_Ticket__c t = makeResolvedZeffyTicket(a.Id, 'zid_val_2', 'tx_val_2', null);
        try { ZeffyConnectDonationService.reassignZeffyId(t.Id, a.Id); } catch (AuraHandledException e) { errors++; }
        try { ZeffyConnectDonationService.reassignZeffyId(t.Id, null); } catch (AuraHandledException e) { errors++; }
        System.assertEquals(4, errors);
    }

    @isTest
    static void testReassignZeffyIdFirstChunkFailsNothingMoves() {
        Account wrong = makePersonAccount('Fail', 'One', 'fail1@test.ca');
        Account right = makePersonAccount('Fail', 'Two', 'fail2@test.ca');
        Zeffy_Review_Ticket__c t = makeResolvedZeffyTicket(wrong.Id, 'zid_fail', 'tx_fail_1', null);
        ZeffyConnectDonationService.failReassignChunk = true;
        Boolean threw = false;
        try { ZeffyConnectDonationService.reassignZeffyId(t.Id, right.Id); } catch (AuraHandledException e) { threw = true; }
        System.assert(threw);
        System.assertEquals(wrong.Id, [SELECT Account__c FROM Zeffy_Identity__c WHERE Zeffy_Contact_Id__c = 'zid_fail'].Account__c,
            'The Zeffy ID move is rolled back too');
        System.assertEquals(wrong.Id, [SELECT Resolved_Account__c FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id].Resolved_Account__c);
    }

    @isTest
    static void testReassignZeffyIdBatchFailureIsLogged() {
        Account wrong = makePersonAccount('Batch', 'One', 'batch1@test.ca');
        Account right = makePersonAccount('Batch', 'Two', 'batch2@test.ca');
        Zeffy_Review_Ticket__c t1 = makeResolvedZeffyTicket(wrong.Id, 'zid_batch', 'tx_batch_1', null);
        makeResolvedZeffyTicket(wrong.Id, 'zid_batch', 'tx_batch_2', null);
        ZeffyConnectDonationService.reassignChunkSize = 1;
        Long since = DateTime.now().addMinutes(-1).getTime();
        Test.startTest();
        ZeffyConnectDonationService.reassignZeffyId(t1.Id, right.Id);
        ZeffyConnectDonationService.failReassignChunk = true;   // the queued batch fails
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Action__c = 'Reassign Failed']);
        Map<String, Object> prog = ZeffyConnectDonationService.getReassignProgress(t1.Id, wrong.Id, since);
        System.assertEquals('failed', prog.get('status'));
        System.assertEquals(1, prog.get('remaining'));
    }

    @isTest
    static void testReassignHelpersFallbacks() {
        Account a = makePersonAccount('Help', 'One', 'help1@test.ca');
        Zeffy_Review_Ticket__c t = makeResolvedZeffyTicket(a.Id, 'zid_help', 'tx_help_1', null);
        Set<Id> gifts = new Set<Id>{ t.Resolved_Gift__c };

        // Organization query fails → default time zone
        ZeffyConnectDonationService.orgTimeZoneId = null;
        ZeffyConnectDonationService.failOrgTimeZoneQuery = true;
        System.assertEquals('America/Toronto', ZeffyConnectDonationService.orgTimeZone());

        // A refunded gift can't be rebuilt on another account
        insert new GiftRefund(GiftTransactionId = t.Resolved_Gift__c, Amount = 1, Date = Date.today());
        System.assert(ZeffyConnectDonationService.blockedGiftIds(gifts).contains(t.Resolved_Gift__c));

        // Gift children not queryable → nothing blocked, nothing copied
        ZeffyConnectDonationService.failGiftChildQuery = true;
        System.assertEquals(0, ZeffyConnectDonationService.blockedGiftIds(gifts).size());
        System.assertEquals(0, ZeffyConnectDonationService.loadGiftChildren('GiftSoftCredit', gifts).size());

        // Finalizer: only an unhandled exception leaves a row
        ZeffyConnectDonationService.logReassignStopped(t.Id, 'zid_help', a.Id, ParentJobResult.SUCCESS, null);
        ZeffyConnectDonationService.logReassignStopped(t.Id, 'zid_help', a.Id, ParentJobResult.UNHANDLED_EXCEPTION, null);
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Action__c = 'Reassign Failed']);
    }

    @isTest
    static void testReassignPreviewCountsGiftsOfOtherIds() {
        Account wrong = makePersonAccount('Other', 'Ids', 'otherids@test.ca');
        Zeffy_Review_Ticket__c t1 = makeResolvedZeffyTicket(wrong.Id, 'zid_oi_main', 'tx_oi_1', null);
        makeResolvedZeffyTicket(wrong.Id, 'zid_oi_second', 'tx_oi_2', null);

        Map<String, Object> preview = ZeffyConnectDonationService.getReassignPreview(t1.Id);
        List<Map<String, Object>> others = (List<Map<String, Object>>) preview.get('otherIds');
        System.assertEquals(1, others.size());
        System.assertEquals('zid_oi_second', others[0].get('zeffyId'));
        System.assertEquals(1, others[0].get('gifts'));
    }

    @isTest
    static void testReassignZeffyIdBlockedGiftStaysAndMissingIdentity() {
        Account wrong = makePersonAccount('Block', 'One', 'block1@test.ca');
        Account right = makePersonAccount('Block', 'Two', 'block2@test.ca');
        linkIdentity(right.Id, 'zid_right_own', 'block2@test.ca');
        Zeffy_Review_Ticket__c t1 = makeResolvedZeffyTicket(wrong.Id, 'zid_block', 'tx_block_1', null);
        Zeffy_Review_Ticket__c t2 = makeResolvedZeffyTicket(wrong.Id, 'zid_block', 'tx_block_2', null);
        delete [SELECT Id FROM Zeffy_Identity__c WHERE Zeffy_Contact_Id__c = 'zid_block'];
        ZeffyConnectDonationService.forcedBlockedGifts = new Set<Id>{ t2.Resolved_Gift__c };
        ZeffyConnectDonationService.failAuditLog = false;

        Map<String, Object> preview = ZeffyConnectDonationService.getReassignPreview(t1.Id);
        System.assertEquals(1, preview.get('blockedCount'));
        System.assertEquals(1, preview.get('giftCount'));

        Map<String, Object> res = ZeffyConnectDonationService.reassignZeffyId(t1.Id, right.Id);
        System.assertEquals(0, res.get('remaining'));
        System.assertEquals(wrong.Id, [SELECT DonorId FROM GiftTransaction WHERE Id = :t2.Resolved_Gift__c].DonorId);
        Zeffy_Identity__c zi = [SELECT Account__c, Is_Primary__c FROM Zeffy_Identity__c WHERE Zeffy_Contact_Id__c = 'zid_block'];
        System.assertEquals(right.Id, zi.Account__c);
        System.assertEquals(false, zi.Is_Primary__c, 'The right account already had a primary Zeffy ID');
        System.assert([SELECT Notes__c FROM Zeffy_Connect_Audit_Log__c WHERE Action__c = 'Zeffy ID Reassigned'].Notes__c.contains('by hand'));
    }

    @isTest
    static void testReassignAuditLogFailureIsNotCritical() {
        Account wrong = makePersonAccount('Aud', 'One', 'aud1@test.ca');
        Account right = makePersonAccount('Aud', 'Two', 'aud2@test.ca');
        Zeffy_Review_Ticket__c t = makeResolvedZeffyTicket(wrong.Id, 'zid_aud', 'tx_aud_1', null);
        ZeffyConnectDonationService.failAuditLog = true;
        ZeffyConnectDonationService.reassignZeffyId(t.Id, right.Id);
        System.assertEquals(right.Id, [SELECT Resolved_Account__c FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id].Resolved_Account__c);
        Map<String, Object> prog = ZeffyConnectDonationService.getReassignProgress(t.Id, wrong.Id, null);
        System.assertEquals('done', prog.get('status'));
    }

    // ─── Auditor 2026-10-15 fixes ─────────────────────────────────────────────

    // A1: gift date is the donation day in the org's time zone, not the GMT day of the Guest User
    @isTest
    static void testParseUnixDateUsesOrgTimeZone() {
        ZeffyConnectDonationService.orgTimeZoneId = 'America/Toronto';
        // 2026-01-01T01:00Z = 2025-12-31 20:00 in Toronto
        System.assertEquals(Date.newInstance(2025, 12, 31), ZeffyConnectDonationService.parseUnixDate(1767229200L));
        System.assertEquals(Date.newInstance(2026, 1, 1),  ZeffyConnectDonationService.parseUnixDate(1767272400L));
        System.assertNotEquals(null, ZeffyConnectDonationService.parseUnixDate(null), 'No timestamp → today');
    }

    // A2: payment confirmed by Zeffy after staff closed the Holding ticket → back to review
    @isTest
    static void testCompletedReopensClosedTicket() {
        insert new Zeffy_Review_Ticket__c(Status__c = 'Closed', Email__c = 'closedconf@test.ca', Transaction_Status__c = 'pending',
                                          Zeffy_Transaction_Id__c = 'txn_closed_conf_001');
        Test.startTest();
        ZeffyConnectDonationService.WebhookResult r = ZeffyConnectDonationService.processWebhookWithResult(
            buildPayload('txn_closed_conf_001', 'closedconf@test.ca', 'zeffy_closed_conf'));
        Test.stopTest();

        Zeffy_Review_Ticket__c t = [SELECT Id, Status__c, Transaction_Status__c FROM Zeffy_Review_Ticket__c
                                    WHERE Zeffy_Transaction_Id__c = 'txn_closed_conf_001'];
        System.assertEquals('Pending Review', t.Status__c, r.message);
        System.assertEquals('succeeded', t.Transaction_Status__c);
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Ticket__c = :t.Id AND Action__c = 'Payment Confirmed']);
    }

    // M9: payment.completed refreshes amount and card on the graduated ticket
    @isTest
    static void testCompletedRefreshesAmountOnGraduation() {
        insert new Zeffy_Review_Ticket__c(Status__c = 'Holding', Email__c = 'grad@test.ca', Amount__c = 1,
                                          Zeffy_Transaction_Id__c = 'txn_grad_amt_001');
        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(buildPayload('txn_grad_amt_001', 'grad@test.ca', 'zeffy_grad_amt'));
        Test.stopTest();

        Zeffy_Review_Ticket__c t = [SELECT Amount__c, Eligible_Amount__c, Card_Brand__c, Card_Last4__c
                                    FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_grad_amt_001'];
        System.assertEquals(50, t.Amount__c);
        System.assertEquals(40, t.Eligible_Amount__c);
        System.assertEquals('visa', t.Card_Brand__c);
        System.assertEquals('1234', t.Card_Last4__c);
    }

    // B1: Zeffy's refund_status "none" is stored as blank
    @isTest
    static void testRefundStatusNoneStoredBlank() {
        System.assertEquals(null, ZeffyConnectDonationService.realRefundStatus('none'));
        System.assertEquals(null, ZeffyConnectDonationService.realRefundStatus(' NONE '));
        System.assertEquals(null, ZeffyConnectDonationService.realRefundStatus(null));
        System.assertEquals('refunded', ZeffyConnectDonationService.realRefundStatus('refunded'));

        ZeffyConnectDonationService.processWebhookWithResult(buildPayload('txn_none_rf_001', 'nonerf@test.ca', 'zeffy_none_rf'));
        System.assertEquals(null, [SELECT Refund_Status__c FROM Zeffy_Review_Ticket__c
                                   WHERE Zeffy_Transaction_Id__c = 'txn_none_rf_001'].Refund_Status__c);
    }

    // Zeffy API refund_status values (none/partial/full) + the older names
    @isTest
    static void testRefundStatusApiValues() {
        System.assert(ZeffyConnectDonationService.isFullRefundStatus('full'));
        System.assert(ZeffyConnectDonationService.isFullRefundStatus(' FULL '));
        System.assert(ZeffyConnectDonationService.isFullRefundStatus('refunded'));
        System.assert(!ZeffyConnectDonationService.isFullRefundStatus('partial'));
        System.assert(!ZeffyConnectDonationService.isFullRefundStatus(null));
        System.assert(ZeffyConnectDonationService.isPartialRefundStatus('partial'));
        System.assert(ZeffyConnectDonationService.isPartialRefundStatus('partially_refunded'));
        System.assert(!ZeffyConnectDonationService.isPartialRefundStatus('none'));
        System.assert(!ZeffyConnectDonationService.isPartialRefundStatus(''));
    }

    // A real Zeffy full refund ("full") marks the auto-matched gift Fully Refunded
    @isTest
    static void testFullRefundApiValueMarksGift() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Updated__c = true;
        update cfg;
        Account acc = makePersonAccount('Full', 'RefundApi', 'full.refundapi@test.ca');
        GiftTransaction gt = new GiftTransaction(Name = 'txn_full_api_001', DonorId = acc.Id, OriginalAmount = 40,
            Status = 'Paid', TransactionDate = Date.today(), PaymentMethod = 'Credit Card',
            Zeffy_Transaction_Id__c = 'txn_full_api_001');
        insert gt;
        String payload =
            '{"id":"evt_full_api","type":"payment.updated","version":1,"dispatchedAt":"2026-01-01T00:00:00Z",' +
            '"data":{"id":"txn_full_api_001","amount":4000,"eligible_amount":4000,' +
            '"currency":"cad","contact":null,"buyer":null,"payment_method":null,' +
            '"created":1737000000,"receipt_url":null,' +
            '"refund_status":"full","refunds":[{"id":"rf1","amount":4000,"status":"succeeded","created":1737050000}],' +
            '"dispute":null,"fund":null,"discount":null,"campaign_id":null,"campaign_type":null,' +
            '"campaign_category":null,"description":null,"buyer_questions":[],"items":[],"recurring":null}}';
        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(payload);
        Test.stopTest();
        GiftTransaction after = [SELECT Status, Refund_Amount__c FROM GiftTransaction WHERE Id = :gt.Id];
        System.assertEquals('Fully Refunded', after.Status);
        System.assertEquals(40, after.Refund_Amount__c);
    }

    // A3: a resolved ticket cannot be closed (its gift would be orphaned from Undo)
    @isTest
    static void testCloseResolvedTicketBlocked() {
        insert new Zeffy_Review_Ticket__c(Status__c = 'Resolved - Linked', Amount__c = 10, Zeffy_Transaction_Id__c = 'txn_close_res');
        Id tid = [SELECT Id FROM Zeffy_Review_Ticket__c LIMIT 1].Id;
        Boolean threw = false;
        try { ZeffyConnectDonationService.closeTicket(tid, 'oops'); } catch (AuraHandledException e) { threw = true; }
        System.assert(threw, 'Resolved tickets must be undone first');
        System.assertEquals('Resolved - Linked', [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :tid].Status__c);
    }

    // A3: deleted payments and tickets still holding a gift cannot be sent back to review
    @isTest
    static void testMoveToReviewBlockedForDeletedOrGift() {
        Account donor = makePersonAccount('Move', 'Gift', 'movegift@test.ca');
        GiftTransaction gt = insertPaidGift(donor.Id, 'txn_move_gift', 10, 0);
        Zeffy_Review_Ticket__c del = new Zeffy_Review_Ticket__c(Status__c = 'Closed', Transaction_Status__c = 'deleted',
            Zeffy_Transaction_Id__c = 'txn_move_del');
        Zeffy_Review_Ticket__c withGift = new Zeffy_Review_Ticket__c(Status__c = 'Payment Failed', Resolved_Gift__c = gt.Id,
            Zeffy_Transaction_Id__c = 'txn_move_gift');
        insert new List<Zeffy_Review_Ticket__c>{ del, withGift };
        Integer errors = 0;
        try { ZeffyConnectDonationService.moveTicketToReview(del.Id, null); } catch (AuraHandledException e) { errors++; }
        try { ZeffyConnectDonationService.moveTicketToReview(withGift.Id, null); } catch (AuraHandledException e) { errors++; }
        System.assertEquals(2, errors);
    }

    // A3: Undo only for resolved tickets, and it clears the amount-review flags
    @isTest
    static void testUndoGuardsAndClearsAmountFlags() {
        Zeffy_Review_Ticket__c failed = new Zeffy_Review_Ticket__c(Status__c = 'Payment Failed', Zeffy_Transaction_Id__c = 'txn_undo_pf');
        Zeffy_Review_Ticket__c deleted = new Zeffy_Review_Ticket__c(Status__c = 'Resolved - Linked', Transaction_Status__c = 'deleted',
            Zeffy_Transaction_Id__c = 'txn_undo_del');
        Zeffy_Review_Ticket__c flagged = new Zeffy_Review_Ticket__c(Status__c = 'Resolved - Linked', Amount__c = 10,
            Zeffy_Amount_Not_Applied__c = 25, Zeffy_Amount_Reviewed__c = 25, Zeffy_Transaction_Id__c = 'txn_undo_flag');
        insert new List<Zeffy_Review_Ticket__c>{ failed, deleted, flagged };
        Integer errors = 0;
        try { ZeffyConnectDonationService.undoResolution(failed.Id); } catch (AuraHandledException e) { errors++; }
        try { ZeffyConnectDonationService.undoResolution(deleted.Id); } catch (AuraHandledException e) { errors++; }
        System.assertEquals(2, errors);

        ZeffyConnectDonationService.undoResolution(flagged.Id);
        Zeffy_Review_Ticket__c t = [SELECT Status__c, Zeffy_Amount_Not_Applied__c, Zeffy_Amount_Reviewed__c
                                    FROM Zeffy_Review_Ticket__c WHERE Id = :flagged.Id];
        System.assertEquals('Pending Review', t.Status__c);
        System.assertEquals(null, t.Zeffy_Amount_Not_Applied__c);
        System.assertEquals(null, t.Zeffy_Amount_Reviewed__c);
    }

    // M1: running Reassign again after the identity already moved keeps exactly one primary on B
    @isTest
    static void testReassignRerunKeepsPrimary() {
        Account wrong = makePersonAccount('Rerun', 'One', 'rerun1@test.ca');
        Account right = makePersonAccount('Rerun', 'Two', 'rerun2@test.ca');
        Zeffy_Review_Ticket__c t1 = makeResolvedZeffyTicket(wrong.Id, 'zid_rerun', 'tx_rerun_1', null);
        Zeffy_Review_Ticket__c t2 = makeResolvedZeffyTicket(wrong.Id, 'zid_rerun', 'tx_rerun_2', null);
        // A previous run moved the identity (as non-primary) but its tickets stayed behind
        update new Zeffy_Identity__c(Id = [SELECT Id FROM Zeffy_Identity__c WHERE Zeffy_Contact_Id__c = 'zid_rerun'].Id,
            Account__c = right.Id, Is_Primary__c = false);

        Test.startTest();
        ZeffyConnectDonationService.reassignZeffyId(t1.Id, right.Id);
        Test.stopTest();

        Zeffy_Identity__c zi = [SELECT Account__c, Is_Primary__c FROM Zeffy_Identity__c WHERE Zeffy_Contact_Id__c = 'zid_rerun'];
        System.assertEquals(right.Id, zi.Account__c);
        System.assertEquals(true, zi.Is_Primary__c, 'B had no other Zeffy ID, so this one becomes its primary');
        System.assertEquals(2, [SELECT COUNT() FROM Zeffy_Review_Ticket__c WHERE Resolved_Account__c = :right.Id]);
    }

    // M2: a gift someone already moved to a third account is left alone and reported
    @isTest
    static void testReassignSkipsGiftOnAnotherAccount() {
        Account wrong = makePersonAccount('Third', 'One', 'third1@test.ca');
        Account right = makePersonAccount('Third', 'Two', 'third2@test.ca');
        Account other = makePersonAccount('Third', 'Three', 'third3@test.ca');
        Zeffy_Review_Ticket__c t1 = makeResolvedZeffyTicket(wrong.Id, 'zid_third', 'tx_third_1', null);
        // Gift moved by hand to a third account: production blocks editing DonorId on a Paid gift,
        // so the gift is created there and the ticket is pointed back to the wrong account
        Zeffy_Review_Ticket__c t2 = makeResolvedZeffyTicket(other.Id, 'zid_third', 'tx_third_2', null);
        update new Zeffy_Review_Ticket__c(Id = t2.Id, Resolved_Account__c = wrong.Id);

        Test.startTest();
        ZeffyConnectDonationService.reassignZeffyId(t1.Id, right.Id);
        Test.stopTest();

        System.assertEquals(other.Id, [SELECT DonorId FROM GiftTransaction WHERE Id = :t2.Resolved_Gift__c].DonorId,
            'The gift on the third account is not touched');
        System.assertEquals(1, [SELECT COUNT() FROM GiftTransaction WHERE DonorId = :right.Id]);
    }

    // M5: a failing ticket in a bulk link leaves nothing behind (identity rolled back)
    @isTest
    static void testBulkLinkFailureRollsBackIdentity() {
        Account donor = makePersonAccount('Bulk', 'Rollback', 'bulkrb@test.ca');
        Zeffy_Review_Ticket__c bad = bulkTicket('txn_bulk_rb_001', 'zeffy_bulk_rb');
        insert bad;
        ZeffyConnectDonationService.failGiftForTxId = 'txn_bulk_rb_001';

        Test.startTest();
        Map<String,Object> res = ZeffyConnectDonationService.bulkResolveLinkExisting(new List<Id>{ bad.Id }, donor.Id, 'bulk');
        Test.stopTest();

        System.assertEquals(0, res.get('resolved'));
        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Identity__c WHERE Zeffy_Contact_Id__c = 'zeffy_bulk_rb'],
            'The identity of the failed ticket is rolled back');
        System.assertEquals('Pending Review', [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :bad.Id].Status__c);
    }

    // M6: linking a ticket whose Zeffy ID belongs to another account leaves a visible conflict trace
    @isTest
    static void testZeffyIdConflictIsAudited() {
        Account owner  = makePersonAccount('Conf', 'Owner', 'confowner@test.ca');
        Account chosen = makePersonAccount('Conf', 'Chosen', 'confchosen@test.ca');
        linkIdentity(owner.Id, 'zid_conflict', 'confowner@test.ca');
        Zeffy_Review_Ticket__c t = bulkTicket('txn_conflict_001', 'zid_conflict');
        insert t;

        Test.startTest();
        ZeffyConnectDonationService.resolveLinkExisting(t.Id, chosen.Id, null, null, false, false, false);
        Test.stopTest();

        System.assertEquals(owner.Id, [SELECT Account__c FROM Zeffy_Identity__c WHERE Zeffy_Contact_Id__c = 'zid_conflict'].Account__c,
            'The identity is not silently moved');
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Ticket__c = :t.Id AND Action__c = 'Zeffy ID Conflict']);
        System.assertEquals(chosen.Id, [SELECT DonorId FROM GiftTransaction WHERE Zeffy_Transaction_Id__c = 'txn_conflict_001'].DonorId);
    }

    // ─── Audit round 3 (2026-10-19) ───────────────────────────────────────────

    // S1: a payload larger than the 32,000-char ticket field must not fail (500 → endless Zeffy retries)
    @isTest
    static void testOversizedPayloadIsTruncatedNotFailed() {
        String base = buildPayload('txn_big_001', 'big@test.ca', 'zeffy_big_001');
        // Pad the description so the body passes 40,000 chars and still parses
        String big = base.replace('"description":"Campagne DS"', '"description":"' + 'x'.repeat(40000) + '"');
        System.assert(big.length() > 40000);

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult r = ZeffyConnectDonationService.processWebhookWithResult(big);
        Test.stopTest();

        System.assertEquals('SUCCESS', r.status, 'Oversized payload must still be processed: ' + r.message);
        Zeffy_Review_Ticket__c t = [SELECT Raw_Payload__c FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_big_001'];
        System.assertEquals(32000, t.Raw_Payload__c.length(), 'Stored payload is cut to the field size');
    }

    // S1: invalid JSON larger than the field still leaves an Error ticket and never throws
    @isTest
    static void testOversizedInvalidJsonCreatesErrorTicket() {
        String bad = '{not json ' + 'y'.repeat(40000);
        Test.startTest();
        ZeffyConnectDonationService.WebhookResult r = ZeffyConnectDonationService.processWebhookWithResult(bad);
        Test.stopTest();
        System.assertEquals('INVALID_JSON', r.status);
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Review_Ticket__c WHERE Status__c = 'Error']);
    }

    // S3: a ticket already resolved (two tabs, stale page) cannot be resolved again → no second gift
    @isTest
    static void testResolveTwiceIsBlocked() {
        Account a = makePersonAccount('Twice', 'Resolve', 'twice@test.ca');
        Zeffy_Review_Ticket__c t = bulkTicket('txn_twice_001', null);
        insert t;
        ZeffyConnectDonationService.resolveLinkExisting(t.Id, a.Id, null, null, false, false, false);

        Integer blocked = 0;
        Test.startTest();
        try { ZeffyConnectDonationService.resolveLinkExisting(t.Id, a.Id, null, null, false, false, false); }
        catch (AuraHandledException e) { blocked++; }
        try { ZeffyConnectDonationService.resolveCreateNew(t.Id, 'individual', null); }
        catch (AuraHandledException e) { blocked++; }
        Test.stopTest();

        System.assertEquals(2, blocked, 'Only Pending Review tickets can be resolved');
        System.assertEquals(1, [SELECT COUNT() FROM GiftTransaction WHERE Zeffy_Transaction_Id__c = 'txn_twice_001']);
    }

    // S6: ticket actions and reads need a Zeffy Connect permission set
    @isTest
    static void testTicketActionsRequireZeffyAccess() {
        Profile std = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(Alias = 'zcnoac2', Email = 'zc.noaccess2@test.example', EmailEncodingKey = 'UTF-8',
            LastName = 'NoAccess2', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_CA', ProfileId = std.Id,
            TimeZoneSidKey = 'America/Toronto', Username = 'zc.noaccess2.' + DateTime.now().getTime() + '@test.example');
        insert u;
        Zeffy_Review_Ticket__c t = bulkTicket('txn_noacc_001', null);
        insert t;
        Integer denied = 0;
        System.runAs(u) {
            try { ZeffyConnectDonationService.getTickets('Pending Review'); } catch (AuraHandledException e) { denied++; }
            try { ZeffyConnectDonationService.resolveCreateNew(t.Id, 'individual', null); } catch (AuraHandledException e) { denied++; }
            try { ZeffyConnectDonationService.closeTicket(t.Id, 'x'); } catch (AuraHandledException e) { denied++; }
            try { ZeffyConnectDonationService.getAuditLog(null); } catch (AuraHandledException e) { denied++; }
            try { ZeffyConnectDonationService.getWebhookLogs(null, null, 10); } catch (AuraHandledException e) { denied++; }
            try { ZeffyConnectDonationService.saveCampaignMapping(null, 'f', true); } catch (AuraHandledException e) { denied++; }
        }
        System.assertEquals(6, denied, 'Every ticket action and gift-wide read needs Zeffy Connect access');
        System.assertEquals('Pending Review', [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id].Status__c);
    }

    // S4: payment.updated(succeeded) on a Holding ticket with a known donor resolves it like payment.completed
    @isTest
    static void testPaymentUpdatedHoldingAutoResolvesKnownDonor() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Updated__c = true;
        upsert cfg;
        Account donor = makePersonAccount('Upd', 'Known', 'upd.known@test.ca');
        linkIdentity(donor.Id, 'zeffy_upd_001', 'upd.known@test.ca');
        insert new Zeffy_Review_Ticket__c(Status__c = 'Holding', Email__c = 'upd.known@test.ca',
            Amount__c = 50, Eligible_Amount__c = 40, Payment_Method__c = 'Credit Card', Payment_Type__c = 'Donation',
            Gift_Date__c = Date.today(), Zeffy_Transaction_Id__c = 'txn_upd_known_001', Zeffy_Contact_Id__c = 'zeffy_upd_001');

        Test.startTest();
        ZeffyConnectDonationService.WebhookResult r =
            ZeffyConnectDonationService.processWebhookWithResult(buildUpdatedPayload('txn_upd_known_001', 'succeeded', null));
        Test.stopTest();

        System.assertEquals('SUCCESS', r.status, r.message);
        System.assertEquals('Auto-Processed', [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_upd_known_001'].Status__c);
        System.assertEquals(1, [SELECT COUNT() FROM GiftTransaction WHERE Zeffy_Transaction_Id__c = 'txn_upd_known_001']);
    }

    // S4: unknown donor → Pending Review plus a review task (as payment.completed does)
    @isTest
    static void testPaymentUpdatedHoldingUnknownDonorCreatesTask() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        cfg.Process_Payment_Updated__c = true;
        cfg.Auto_Task_Enabled__c = true;
        upsert cfg;
        insert new Zeffy_Review_Ticket__c(Status__c = 'Holding', Email__c = 'upd.unknown@test.ca',
            Zeffy_Transaction_Id__c = 'txn_upd_unknown_001');

        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(buildUpdatedPayload('txn_upd_unknown_001', 'succeeded', null));
        Test.stopTest();

        Zeffy_Review_Ticket__c t = [SELECT Id, Status__c FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_upd_unknown_001'];
        System.assertEquals('Pending Review', t.Status__c);
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :t.Id]);
    }

    // S5: a failed recurring commitment is visible in the ticket's audit log
    @isTest
    static void testCommitmentFailureIsAudited() {
        Account a = makePersonAccount('Cmt', 'Audit', 'cmt.audit@test.ca');
        insert new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review', First_Name__c = 'Cmt', Last_Name__c = 'Audit',
            Email__c = 'cmt.audit@test.ca', Amount__c = 20, Eligible_Amount__c = 20,
            Payment_Method__c = 'Credit Card', Payment_Type__c = 'Donation', Gift_Date__c = Date.today(),
            Zeffy_Transaction_Id__c = 'txn_cmt_audit_001', Is_Recurring__c = true, Zeffy_Subscription_Id__c = 'sub_cmt_audit_001');
        Zeffy_Review_Ticket__c t = [SELECT Id FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_cmt_audit_001'];
        ZeffyConnectDonationService.failCommitmentInsert = true;
        Test.startTest();
        ZeffyConnectDonationService.resolveLinkExisting(t.Id, a.Id, null, null, false, false, false);
        Test.stopTest();
        ZeffyConnectDonationService.failCommitmentInsert = false;

        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Ticket__c = :t.Id AND Action__c = 'Commitment Not Created']);
    }

    // S5: same for a gift the robot created on its own (auto-processed)
    @isTest
    static void testRobotCommitmentFailureIsAudited() {
        Account donor = makePersonAccount('Cmt', 'Robot', 'cmt.robot@test.ca');
        linkIdentity(donor.Id, 'zeffy_cmt_robot', 'cmt.robot@test.ca');
        String payload = buildPayload('txn_cmt_robot_001', 'cmt.robot@test.ca', 'zeffy_cmt_robot').replace('"recurring":null',
            '"recurring":{"is_recurring":true,"status":"active","interval":"monthly","subscription_id":"sub_cmt_robot_001",'
            + '"current_period_start":1737000000,"current_period_end":1739678400}');
        ZeffyConnectDonationService.failCommitmentInsert = true;
        Test.startTest();
        ZeffyConnectDonationService.processWebhookWithResult(payload);
        Test.stopTest();
        ZeffyConnectDonationService.failCommitmentInsert = false;

        Zeffy_Review_Ticket__c t = [SELECT Id, Status__c FROM Zeffy_Review_Ticket__c WHERE Zeffy_Transaction_Id__c = 'txn_cmt_robot_001'];
        System.assertEquals('Auto-Processed', t.Status__c);
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c WHERE Ticket__c = :t.Id AND Action__c = 'Commitment Not Created']);
    }

    // ─── Coverage: guard branches (2026-10-19 dry-run) ────────────────────────

    // Only an updatable Email field can receive the Zeffy email — never a name or another field
    @isTest
    static void testInvalidEmailTargetFieldRejected() {
        Account a = makePersonAccount('Bad', 'Field', 'bad.field@test.ca');
        Zeffy_Review_Ticket__c t = bulkTicket('txn_badfield_001', null);
        insert t;
        Boolean rejected = false;
        Test.startTest();
        try { ZeffyConnectDonationService.resolveLinkExisting(t.Id, a.Id, null, 'Name', false, false, false); }
        catch (AuraHandledException e) { rejected = true; }
        Test.stopTest();
        System.assert(rejected, 'A non-email target field must be rejected');
        System.assertEquals(0, [SELECT COUNT() FROM GiftTransaction WHERE Zeffy_Transaction_Id__c = 'txn_badfield_001']);
    }

    // createErrorTicket must never throw (it runs outside the router's try → would be a 500)
    @isTest
    static void testErrorTicketFailureIsSwallowed() {
        ZeffyConnectDonationService.failErrorTicketInsert = true;
        Test.startTest();
        ZeffyConnectDonationService.WebhookResult r = ZeffyConnectDonationService.processWebhookWithResult('{not json');
        Test.stopTest();
        ZeffyConnectDonationService.failErrorTicketInsert = false;
        System.assertEquals('INVALID_JSON', r.status);
        System.assertEquals(0, [SELECT COUNT() FROM Zeffy_Review_Ticket__c WHERE Status__c = 'Error']);
    }

    // SOSL is extra recall only: if it fails, the email/name matches are still returned
    @isTest
    static void testAccountSearchSurvivesSoslFailure() {
        Account a = makePersonAccount('Sosl', 'Fallback', 'sosl.fallback@test.ca');
        Zeffy_Review_Ticket__c t = bulkTicket('txn_sosl_001', null);
        t.First_Name__c = 'Sosl';
        t.Last_Name__c  = 'Fallback';
        t.Email__c      = 'sosl.fallback@test.ca';
        insert t;
        ZeffyConnectDonationService.failSoslSearch = true;
        Test.startTest();
        List<ZeffyConnectDonationService.AccountMatch> matches = ZeffyConnectDonationService.findAccountMatches(t.Id);
        Test.stopTest();
        ZeffyConnectDonationService.failSoslSearch = false;
        System.assert(!matches.isEmpty(), 'Email match must still be found without SOSL');
    }
}
