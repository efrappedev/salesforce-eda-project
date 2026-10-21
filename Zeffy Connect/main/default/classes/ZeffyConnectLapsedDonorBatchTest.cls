@isTest
private class ZeffyConnectLapsedDonorBatchTest {

    private static final String JOB_NAME = 'ZeffyConnectLapsedDonorBatch';

    // Helper to abort any scheduled job by name (cleanup)
    private static void abortJob(String name) {
        for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :name]) {
            System.abortJob(ct.Id);
        }
    }

    // ─── schedule / unschedule ────────────────────────────────────────────────

    @isTest
    static void testScheduleAndUnschedule() {
        Zeffy_Config__c cfg = new Zeffy_Config__c(
            SetupOwnerId              = UserInfo.getOrganizationId(),
            Lapsed_Schedule_Frequency__c = 'WEEKLY',
            Lapsed_Schedule_Day__c       = 'MON',
            Lapsed_Days__c               = 365
        );

        Test.startTest();
        ZeffyConnectLapsedDonorBatch.schedule(cfg);
        Integer scheduled = [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :JOB_NAME];
        System.assertEquals(1, scheduled, 'Should be 1 scheduled job after schedule()');

        ZeffyConnectLapsedDonorBatch.unschedule();
        Integer afterUnschedule = [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :JOB_NAME];
        System.assertEquals(0, afterUnschedule, 'Should be 0 jobs after unschedule()');
        Test.stopTest();
    }

    // ─── schedule — monthly frequency ────────────────────────────────────────

    @isTest
    static void testScheduleMonthly() {
        Zeffy_Config__c cfg = new Zeffy_Config__c(
            SetupOwnerId              = UserInfo.getOrganizationId(),
            Lapsed_Schedule_Frequency__c = 'MONTHLY',
            Lapsed_Schedule_Day__c       = 'MON',
            Lapsed_Days__c               = 365
        );

        Test.startTest();
        ZeffyConnectLapsedDonorBatch.schedule(cfg);
        Integer scheduled = [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :JOB_NAME];
        System.assertEquals(1, scheduled);
        ZeffyConnectLapsedDonorBatch.unschedule();
        Test.stopTest();
    }

    // ─── schedule — all weekdays + unknown day (default to MON) ──────────────

    @isTest
    static void testScheduleAllWeekdays() {
        String[] days = new String[]{'MON','TUE','WED','THU','FRI','XYZ'};
        Test.startTest();
        for (String day : days) {
            Zeffy_Config__c cfg = new Zeffy_Config__c(
                SetupOwnerId              = UserInfo.getOrganizationId(),
                Lapsed_Schedule_Frequency__c = 'WEEKLY',
                Lapsed_Schedule_Day__c       = day
            );
            ZeffyConnectLapsedDonorBatch.schedule(cfg);
            ZeffyConnectLapsedDonorBatch.unschedule();
        }
        Test.stopTest();
    }

    // ─── schedule — null frequency defaults to WEEKLY ────────────────────────

    @isTest
    static void testScheduleNullFrequency() {
        Zeffy_Config__c cfg = new Zeffy_Config__c(
            SetupOwnerId              = UserInfo.getOrganizationId(),
            Lapsed_Schedule_Frequency__c = null,
            Lapsed_Schedule_Day__c       = 'MON'
        );
        Test.startTest();
        ZeffyConnectLapsedDonorBatch.schedule(cfg);
        ZeffyConnectLapsedDonorBatch.unschedule();
        Test.stopTest();
    }

    // ─── unschedule — when nothing is scheduled (no-op) ──────────────────────

    @isTest
    static void testUnscheduleWhenNothing() {
        Test.startTest();
        ZeffyConnectLapsedDonorBatch.unschedule(); // Should not throw
        Test.stopTest();
    }

    // ─── Schedulable.execute — fires a batch ─────────────────────────────────

    @isTest
    static void testSchedulableExecute() {
        insert new Zeffy_Config__c(
            SetupOwnerId            = UserInfo.getOrganizationId(),
            Is_Active__c            = true,
            Lapsed_Alert_Enabled__c = false,
            Lapsed_Days__c          = 365
        );

        Test.startTest();
        ZeffyConnectLapsedDonorBatch batch = new ZeffyConnectLapsedDonorBatch();
        batch.execute(null); // Schedulable execute — fires Database.executeBatch
        Test.stopTest();
        // No assertion needed — just confirming it runs without throwing
    }

    // ─── Batchable.start — returns a query locator ───────────────────────────

    @isTest
    static void testBatchStart() {
        insert new Zeffy_Config__c(
            SetupOwnerId   = UserInfo.getOrganizationId(),
            Lapsed_Days__c = 365
        );

        Test.startTest();
        ZeffyConnectLapsedDonorBatch batch = new ZeffyConnectLapsedDonorBatch();
        Database.QueryLocator ql = batch.start(null);
        Test.stopTest();

        System.assertNotEquals(null, ql, 'start() should return a query locator');
    }

    // ─── Batchable.execute — no config → skips task creation ─────────────────

    @isTest
    static void testBatchExecuteNoCfg() {
        Id personRtId = [SELECT Id FROM RecordType WHERE SObjectType = 'Account'
                         AND DeveloperName = 'PersonAccount' LIMIT 1]?.Id;
        Account a = new Account(RecordTypeId = personRtId,
                                FirstName = 'Lapsed', LastName = 'Donor', PersonEmail = 'ld@test.ca');
        insert a;

        Test.startTest();
        ZeffyConnectLapsedDonorBatch batch = new ZeffyConnectLapsedDonorBatch();
        batch.execute(null, new List<Account>{ a }); // no config in DB → exits early
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId = :a.Id]);
    }

    // ─── Batchable.execute — lapsed donor → creates Task ─────────────────────

    @isTest
    static void testBatchExecuteCreatesTask() {
        insert new Zeffy_Config__c(
            SetupOwnerId            = UserInfo.getOrganizationId(),
            Lapsed_Alert_Enabled__c = true,
            Lapsed_Days__c          = 365,
            Lapsed_Owner_Id__c      = UserInfo.getUserId()
        );

        Id personRtId = [SELECT Id FROM RecordType WHERE SObjectType = 'Account'
                         AND DeveloperName = 'PersonAccount' LIMIT 1]?.Id;
        Account donor = new Account(RecordTypeId = personRtId,
                                    FirstName = 'Marie', LastName = 'Thibodeau',
                                    PersonEmail = 'marie.t@lapsed.ca');
        insert donor;

        Test.startTest();
        ZeffyConnectLapsedDonorBatch batch = new ZeffyConnectLapsedDonorBatch();
        batch.execute(null, new List<Account>{ donor });
        Test.stopTest();

        List<Task> tasks = [SELECT Id, Subject FROM Task WHERE WhatId = :donor.Id];
        System.assertEquals(1, tasks.size(), 'Should create 1 lapsed donor task');
        System.assert(tasks[0].Subject.startsWith('Lapsed donor'), 'Task subject should start with "Lapsed donor"');
    }

    // ─── Batchable.execute — already has open lapsed task → skipped ──────────

    @isTest
    static void testBatchExecuteSkipsAlreadyTasked() {
        insert new Zeffy_Config__c(
            SetupOwnerId            = UserInfo.getOrganizationId(),
            Lapsed_Alert_Enabled__c = true,
            Lapsed_Days__c          = 365,
            Lapsed_Owner_Id__c      = UserInfo.getUserId()
        );

        Id personRtId = [SELECT Id FROM RecordType WHERE SObjectType = 'Account'
                         AND DeveloperName = 'PersonAccount' LIMIT 1]?.Id;
        Account donor = new Account(RecordTypeId = personRtId,
                                    FirstName = 'Already', LastName = 'Tasked',
                                    PersonEmail = 'at@lapsed.ca');
        insert donor;

        // Pre-existing open lapsed task
        insert new Task(
            Subject      = 'Lapsed donor — manual',
            WhatId       = donor.Id,
            OwnerId      = UserInfo.getUserId(),
            Status       = 'Not Started',
            ActivityDate = Date.today().addDays(3)
        );

        Test.startTest();
        ZeffyConnectLapsedDonorBatch batch = new ZeffyConnectLapsedDonorBatch();
        batch.execute(null, new List<Account>{ donor });
        Test.stopTest();

        // Still only 1 task (the pre-existing one)
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :donor.Id]);
    }

    // ─── Batchable.execute — lapsed enabled = false → no task ────────────────

    @isTest
    static void testBatchExecuteLapsedDisabled() {
        insert new Zeffy_Config__c(
            SetupOwnerId            = UserInfo.getOrganizationId(),
            Lapsed_Alert_Enabled__c = false,
            Lapsed_Days__c          = 365
        );

        Id personRtId = [SELECT Id FROM RecordType WHERE SObjectType = 'Account'
                         AND DeveloperName = 'PersonAccount' LIMIT 1]?.Id;
        Account donor = new Account(RecordTypeId = personRtId,
                                    FirstName = 'Not', LastName = 'Tasked',
                                    PersonEmail = 'not.tasked@lapsed.ca');
        insert donor;

        Test.startTest();
        ZeffyConnectLapsedDonorBatch batch = new ZeffyConnectLapsedDonorBatch();
        batch.execute(null, new List<Account>{ donor });
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId = :donor.Id]);
    }

    // ─── Batchable.execute — lapsedOwner blank → falls back to current user ──

    @isTest
    static void testBatchExecuteOwnerFallback() {
        insert new Zeffy_Config__c(
            SetupOwnerId            = UserInfo.getOrganizationId(),
            Lapsed_Alert_Enabled__c = true,
            Lapsed_Days__c          = 365,
            Lapsed_Owner_Id__c      = null  // blank → falls back to UserInfo.getUserId()
        );

        Id personRtId = [SELECT Id FROM RecordType WHERE SObjectType = 'Account'
                         AND DeveloperName = 'PersonAccount' LIMIT 1]?.Id;
        Account donor = new Account(RecordTypeId = personRtId,
                                    FirstName = 'No', LastName = 'Owner',
                                    PersonEmail = 'no.owner@lapsed.ca');
        insert donor;

        Test.startTest();
        ZeffyConnectLapsedDonorBatch batch = new ZeffyConnectLapsedDonorBatch();
        batch.execute(null, new List<Account>{ donor });
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :donor.Id]);
    }

    // ─── Batchable.finish — no-op ─────────────────────────────────────────────

    @isTest
    static void testBatchFinish() {
        Test.startTest();
        ZeffyConnectLapsedDonorBatch batch = new ZeffyConnectLapsedDonorBatch();
        batch.finish(null); // Should not throw
        Test.stopTest();
    }
    // ─── A lapsed task completed recently (staff already reached out) blocks a new one ───

    @isTest
    static void testBatchExecuteSkipsRecentlyCompletedTask() {
        insert new Zeffy_Config__c(
            SetupOwnerId            = UserInfo.getOrganizationId(),
            Lapsed_Alert_Enabled__c = true,
            Lapsed_Days__c          = 365,
            Lapsed_Owner_Id__c      = UserInfo.getUserId()
        );
        Id personRtId = [SELECT Id FROM RecordType WHERE SObjectType = 'Account'
                         AND DeveloperName = 'PersonAccount' LIMIT 1]?.Id;
        Account donor = new Account(RecordTypeId = personRtId,
                                    FirstName = 'Done', LastName = 'Already',
                                    PersonEmail = 'done.already@lapsed.ca');
        insert donor;
        insert new Task(
            Subject      = 'Lapsed donor — called last month',
            WhatId       = donor.Id,
            OwnerId      = UserInfo.getUserId(),
            Status       = 'Completed',
            ActivityDate = Date.today().addDays(-20)
        );

        Test.startTest();
        new ZeffyConnectLapsedDonorBatch().execute(null, new List<Account>{ donor });
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :donor.Id],
            'Completed lapsed task inside the window must not be re-created');
    }

    // ─── Only Paid gifts count: a canceled recent gift does not make the donor "active" ───

    @isTest
    static void testStartCountsOnlyPaidGifts() {
        insert new Zeffy_Config__c(
            SetupOwnerId            = UserInfo.getOrganizationId(),
            Lapsed_Alert_Enabled__c = true,
            Lapsed_Days__c          = 365,
            Lapsed_Owner_Id__c      = UserInfo.getUserId()
        );
        Id personRtId = [SELECT Id FROM RecordType WHERE SObjectType = 'Account'
                         AND DeveloperName = 'PersonAccount' LIMIT 1]?.Id;
        Account donor = new Account(RecordTypeId = personRtId,
                                    FirstName = 'Paid', LastName = 'Only',
                                    PersonEmail = 'paid.only@lapsed.ca');
        insert donor;
        insert new GiftTransaction(Name = 'old paid', DonorId = donor.Id, OriginalAmount = 25,
            PaymentMethod = 'Credit Card', GiftType = 'Individual', Status = 'Paid',
            TransactionDate = Date.today().addDays(-500));
        GiftTransaction recent = new GiftTransaction(Name = 'recent canceled', DonorId = donor.Id, OriginalAmount = 25,
            PaymentMethod = 'Credit Card', GiftType = 'Individual', Status = 'Unpaid',
            TransactionDate = Date.today().addDays(-10));
        insert recent;
        update new GiftTransaction(Id = recent.Id, Status = 'Canceled');

        Test.startTest();
        Database.executeBatch(new ZeffyConnectLapsedDonorBatch(), 200);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :donor.Id AND Subject LIKE 'Lapsed donor%'],
            'A canceled gift must not hide a lapsed donor');
    }
}
