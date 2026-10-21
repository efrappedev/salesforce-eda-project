@isTest
private class ZeffyConnectFundServiceTest {

    @TestSetup
    static void setup() {
        insert new Zeffy_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Is_Active__c = true,
            Webhook_Secret__c = 'testsecret'
        );
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    static Zeffy_Fund__c makeFund(String name) {
        Zeffy_Fund__c f = new Zeffy_Fund__c(Name = name, Is_Active__c = true);
        insert f;
        return f;
    }

    static Campaign makeCampaign(String name, String formId, Id fundId) {
        Campaign c = new Campaign(
            Name = name,
            Is_Zeffy_Managed__c = true,
            Zeffy_Form_Id__c = formId,
            Zeffy_Fund__c = fundId
        );
        insert c;
        return c;
    }

    // ── Tests ─────────────────────────────────────────────────────────────────

    @isTest
    static void testGetFundsWithCampaigns_empty() {
        Test.startTest();
        List<ZeffyConnectFundService.FundRow> rows = ZeffyConnectFundService.getFundsWithCampaigns();
        Test.stopTest();
        // Only the unassigned bucket (id=null)
        System.assertEquals(1, rows.size());
        System.assertEquals(null, rows[0].id);
    }

    @isTest
    static void testGetFundsWithCampaigns_withData() {
        Zeffy_Fund__c f1 = makeFund('General Fund');
        Zeffy_Fund__c f2 = makeFund('Mission Fund');
        Campaign c1 = makeCampaign('Collecte 2025', 'FORM-001', f1.Id);
        Campaign c2 = makeCampaign('Gala 2025',     'FORM-002', f1.Id);
        Campaign c3 = makeCampaign('Unlinked Form',  'FORM-003', null);

        Test.startTest();
        List<ZeffyConnectFundService.FundRow> rows = ZeffyConnectFundService.getFundsWithCampaigns();
        Test.stopTest();

        // unassigned + f1 + f2
        System.assertEquals(3, rows.size());
        ZeffyConnectFundService.FundRow unassigned = rows[0];
        System.assertEquals(null, unassigned.id);
        System.assertEquals(1, unassigned.campaigns.size());
        System.assertEquals('Unlinked Form', unassigned.campaigns[0].name);

        ZeffyConnectFundService.FundRow general = rows[1]; // alphabetical: General Fund
        System.assertEquals('General Fund', general.name);
        System.assertEquals(2, general.campaigns.size());
    }

    @isTest
    static void testGetActiveFunds() {
        makeFund('Fund A');
        makeFund('Fund B');
        Zeffy_Fund__c inactive = new Zeffy_Fund__c(Name = 'Old Fund', Is_Active__c = false);
        insert inactive;

        Test.startTest();
        List<Map<String, String>> opts = ZeffyConnectFundService.getActiveFunds();
        Test.stopTest();

        System.assertEquals(2, opts.size());
        System.assert(opts[0].containsKey('value'));
        System.assert(opts[0].containsKey('label'));
    }

    @isTest
    static void testCreateFund() {
        Test.startTest();
        String newId = ZeffyConnectFundService.createFund('Nouveau Fonds', 'Test description');
        Test.stopTest();

        System.assertNotEquals(null, newId);
        Zeffy_Fund__c created = [SELECT Name, Description__c, Is_Active__c FROM Zeffy_Fund__c WHERE Id = :newId];
        System.assertEquals('Nouveau Fonds', created.Name);
        System.assertEquals('Test description', created.Description__c);
        System.assertEquals(true, created.Is_Active__c);
    }

    @isTest
    static void testAssignCampaignToFund() {
        Zeffy_Fund__c f1 = makeFund('Fund 1');
        Zeffy_Fund__c f2 = makeFund('Fund 2');
        Campaign c = makeCampaign('Test Campaign', 'FORM-X', f1.Id);

        Test.startTest();
        ZeffyConnectFundService.assignCampaignToFund(c.Id, f2.Id);
        Test.stopTest();

        Campaign updated = [SELECT Zeffy_Fund__c FROM Campaign WHERE Id = :c.Id];
        System.assertEquals(f2.Id, updated.Zeffy_Fund__c);
    }

    @isTest
    static void testAssignCampaignToFund_removesFund() {
        Zeffy_Fund__c f = makeFund('Fund');
        Campaign c = makeCampaign('Test Campaign', 'FORM-Y', f.Id);

        Test.startTest();
        ZeffyConnectFundService.assignCampaignToFund(c.Id, null);
        Test.stopTest();

        Campaign updated = [SELECT Zeffy_Fund__c FROM Campaign WHERE Id = :c.Id];
        System.assertEquals(null, updated.Zeffy_Fund__c);
    }

    @isTest
    static void testUpdateTicketFund() {
        Zeffy_Fund__c f = makeFund('Donations Fund');
        Zeffy_Review_Ticket__c ticket = new Zeffy_Review_Ticket__c(
            Status__c = 'Pending Review',
            Zeffy_Transaction_Id__c = 'TX-FUND-TEST-001'
        );
        insert ticket;

        Test.startTest();
        ZeffyConnectFundService.updateTicketFund(ticket.Id, f.Id);
        Test.stopTest();

        Zeffy_Review_Ticket__c updated = [SELECT Fund__c FROM Zeffy_Review_Ticket__c WHERE Id = :ticket.Id];
        System.assertEquals(f.Id, updated.Fund__c);
    }

    @isTest
    static void testResolveFundFromCampaign_found() {
        Zeffy_Fund__c f = makeFund('Resolve Fund');
        Campaign c = makeCampaign('My Form', 'FORM-RES', f.Id);

        Test.startTest();
        Id resolved = ZeffyConnectFundService.resolveFundFromCampaign(c.Id);
        Test.stopTest();

        System.assertEquals(f.Id, resolved);
    }

    @isTest
    static void testResolveFundFromCampaign_noFund() {
        Campaign c = makeCampaign('No Fund Form', 'FORM-NOFUND', null);

        Test.startTest();
        Id resolved = ZeffyConnectFundService.resolveFundFromCampaign(c.Id);
        Test.stopTest();

        System.assertEquals(null, resolved);
    }

    @isTest
    static void testResolveFundFromCampaign_nullId() {
        Test.startTest();
        Id resolved = ZeffyConnectFundService.resolveFundFromCampaign(null);
        Test.stopTest();
        System.assertEquals(null, resolved);
    }
    // Resolved ticket: the fund change follows to the linked Gift_Transaction__c and is audited
    @isTest
    static void testUpdateTicketFund_syncsResolvedGift() {
        Zeffy_Fund__c f = makeFund('Building Fund');
        Account donor = new Account(Name = 'Fund Sync Administrative Account', Email_Address__c = 'fund.sync@test.ca');
        insert donor;
        Gift_Transaction__c gt = new Gift_Transaction__c(Donor_Account__c = donor.Id, Amount__c = 30,
            Payment_Method__c = 'Credit Card', Status__c = 'Received',
            Gift_Date__c = Date.today(), Zeffy_Transaction_Id__c = 'TX-FUND-SYNC');
        insert gt;
        Zeffy_Review_Ticket__c ticket = new Zeffy_Review_Ticket__c(
            Status__c = 'Resolved - Linked', Zeffy_Transaction_Id__c = 'TX-FUND-SYNC',
            Resolved_Gift__c = gt.Id, Resolved_Account__c = donor.Id);
        insert ticket;

        Test.startTest();
        ZeffyConnectFundService.updateTicketFund(ticket.Id, f.Id);
        Test.stopTest();

        System.assertEquals(f.Id, [SELECT Zeffy_Fund__c FROM Gift_Transaction__c WHERE Id = :gt.Id].Zeffy_Fund__c);
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c
                                WHERE Ticket__c = :ticket.Id AND Action__c = 'Fund Changed']);
    }

    @isTest
    static void testAssignCampaignToFund_isAudited() {
        Zeffy_Fund__c f = makeFund('Audit Fund');
        Campaign c = makeCampaign('Audit Campaign', 'FORM-AUD', null);

        Test.startTest();
        ZeffyConnectFundService.assignCampaignToFund(c.Id, f.Id);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c
                                WHERE Ticket__c = null AND Action__c = 'Campaign Fund Changed']);
    }
}
