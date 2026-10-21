@isTest
private class ZeffyHoldingExpireBatchTest {

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static void enableExpiry(Integer days) {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        if (cfg == null || cfg.Id == null) {
            cfg = new Zeffy_Config__c(SetupOwnerId = UserInfo.getOrganizationId());
        }
        cfg.Holding_Auto_Expire_Enabled__c = true;
        cfg.Holding_Expire_Days__c         = days;
        upsert cfg;
    }

    private static void disableExpiry() {
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        if (cfg == null || cfg.Id == null) {
            cfg = new Zeffy_Config__c(SetupOwnerId = UserInfo.getOrganizationId());
        }
        cfg.Holding_Auto_Expire_Enabled__c = false;
        upsert cfg;
    }

    private static Zeffy_Review_Ticket__c makeHoldingTicket(String txId) {
        Zeffy_Review_Ticket__c t = new Zeffy_Review_Ticket__c(
            Status__c               = 'Holding',
            Email__c                = txId + '@test.ca',
            Amount__c               = 50.00,
            Eligible_Amount__c      = 50.00,
            Payment_Method__c       = 'Credit Card',
            Payment_Type__c         = 'Donation',
            Gift_Date__c            = Date.today(),
            Zeffy_Transaction_Id__c = txId
        );
        insert t;
        return t;
    }

    // ── Tests — batch disabled → nothing moved ────────────────────────────────

    @isTest
    static void testBatchDisabledSkipsAll() {
        disableExpiry();
        makeHoldingTicket('txn_exp_disabled_001');

        Test.startTest();
        Database.executeBatch(new ZeffyHoldingExpireBatch(), 200);
        Test.stopTest();

        Zeffy_Review_Ticket__c t = [SELECT Status__c FROM Zeffy_Review_Ticket__c LIMIT 1];
        System.assertEquals('Holding', t.Status__c, 'Ticket must stay Holding when feature is disabled');
    }

    // ── Tests — batch enabled, ticket NOT yet expired → stays Holding ─────────

    @isTest
    static void testBatchEnabledTicketNotExpiredStaysHolding() {
        enableExpiry(10);
        // Ticket created now — LastModifiedDate is today, well within 10-day window
        makeHoldingTicket('txn_exp_fresh_001');

        Test.startTest();
        Database.executeBatch(new ZeffyHoldingExpireBatch(), 200);
        Test.stopTest();

        Zeffy_Review_Ticket__c t = [SELECT Status__c FROM Zeffy_Review_Ticket__c LIMIT 1];
        System.assertEquals('Holding', t.Status__c, 'Fresh ticket must stay Holding');
    }

    // ── Tests — batch enabled, no config → defaults to 10 days ───────────────

    @isTest
    static void testBatchNullDaysDefaultsTen() {
        // Enable but leave Holding_Expire_Days__c null
        Zeffy_Config__c cfg = Zeffy_Config__c.getOrgDefaults();
        if (cfg == null || cfg.Id == null) {
            cfg = new Zeffy_Config__c(SetupOwnerId = UserInfo.getOrganizationId());
        }
        cfg.Holding_Auto_Expire_Enabled__c = true;
        cfg.Holding_Expire_Days__c         = null;
        upsert cfg;

        makeHoldingTicket('txn_exp_nulldays_001');

        Test.startTest();
        Database.executeBatch(new ZeffyHoldingExpireBatch(), 200);
        Test.stopTest();

        // Fresh ticket — still Holding (default 10 days, ticket just created)
        Zeffy_Review_Ticket__c t = [SELECT Status__c FROM Zeffy_Review_Ticket__c LIMIT 1];
        System.assertEquals('Holding', t.Status__c, 'Fresh ticket stays Holding even with null days config');
    }

    // ── Tests — schedulable wrapper ───────────────────────────────────────────

    @isTest
    static void testSchedulableExecutesDelegation() {
        Test.startTest();
        ZeffyHoldingExpireBatch batch = new ZeffyHoldingExpireBatch();
        String jobId = System.schedule('ZeffyHoldingExpireBatchTest_Schedulable', '0 0 3 * * ?', batch);
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'System.schedule should return a valid job ID');
    }

    // ── Tests — schedule() and unschedule() helpers ───────────────────────────

    @isTest
    static void testScheduleCreatesJob() {
        Test.startTest();
        ZeffyHoldingExpireBatch.schedule();
        Test.stopTest();

        List<CronTrigger> jobs = [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'ZeffyHoldingExpireBatch'];
        System.assertEquals(1, jobs.size(), 'schedule() should create exactly one scheduled job');
    }

    @isTest
    static void testUnscheduleRemovesJob() {
        ZeffyHoldingExpireBatch.schedule();
        Test.startTest();
        ZeffyHoldingExpireBatch.unschedule();
        Test.stopTest();

        List<CronTrigger> jobs = [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'ZeffyHoldingExpireBatch'];
        System.assertEquals(0, jobs.size(), 'unschedule() should remove the scheduled job');
    }

    @isTest
    static void testUnscheduleNoOpWhenNotScheduled() {
        // Calling unschedule when nothing is scheduled should not throw
        Test.startTest();
        ZeffyHoldingExpireBatch.unschedule();
        Test.stopTest();
        System.assert(true, 'unschedule() with no existing job should not throw');
    }

    @isTest
    static void testScheduleReschedules() {
        // Calling schedule() twice should not create duplicate jobs
        ZeffyHoldingExpireBatch.schedule();
        Test.startTest();
        ZeffyHoldingExpireBatch.schedule();
        Test.stopTest();

        List<CronTrigger> jobs = [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'ZeffyHoldingExpireBatch'];
        System.assertEquals(1, jobs.size(), 'schedule() called twice should still result in one job');
    }

    // ── Tests — execute() moves Holding tickets to Delayed ────────────────────
    // CreatedDate is set via Test.setCreatedDate in the start() test; execute() is called directly here.

    @isTest
    static void testExecuteMarksTicketsDelayed() {
        Zeffy_Review_Ticket__c t = makeHoldingTicket('txn_exp_execute_001');

        Test.startTest();
        new ZeffyHoldingExpireBatch().execute(null, new List<Zeffy_Review_Ticket__c>{ t });
        new ZeffyHoldingExpireBatch().execute(null, new List<Zeffy_Review_Ticket__c>());
        Test.stopTest();

        System.assertEquals('Delayed', [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :t.Id].Status__c,
            'Expired Holding ticket must move to Delayed');
        System.assertEquals(1, [SELECT COUNT() FROM Zeffy_Connect_Audit_Log__c
                                WHERE Ticket__c = :t.Id AND Action__c = 'Expired to Delayed'],
            'Holding → Delayed must leave an audit entry');
    }

    // Grace period is anchored on CreatedDate: an old ticket expires even if it was edited today
    @isTest
    static void testStartPicksTicketsByCreatedDate() {
        enableExpiry(10);
        Zeffy_Review_Ticket__c oldT = makeHoldingTicket('txn_exp_old_001');
        Zeffy_Review_Ticket__c newT = makeHoldingTicket('txn_exp_new_001');
        Test.setCreatedDate(oldT.Id, DateTime.now().addDays(-11));
        update new Zeffy_Review_Ticket__c(Id = oldT.Id, Note__c = 'touched today');

        Test.startTest();
        Database.executeBatch(new ZeffyHoldingExpireBatch(), 200);
        Test.stopTest();

        System.assertEquals('Delayed', [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :oldT.Id].Status__c);
        System.assertEquals('Holding', [SELECT Status__c FROM Zeffy_Review_Ticket__c WHERE Id = :newT.Id].Status__c);
    }
}
