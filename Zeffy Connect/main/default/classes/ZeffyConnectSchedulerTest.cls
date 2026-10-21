@isTest
private class ZeffyConnectSchedulerTest {

    // Guards against a rename: every batch the app schedules must resolve by name
    @isTest
    static void testScheduledBatchesResolve() {
        System.assert(ZeffyConnectScheduler.newBatch('ZeffyHoldingExpireBatch') instanceof ZeffyHoldingExpireBatch);
        System.assert(ZeffyConnectScheduler.newBatch('ZeffyConnectLapsedDonorBatch') instanceof ZeffyConnectLapsedDonorBatch);
    }

    @isTest
    static void testUnknownBatchThrows() {
        Boolean thrown = false;
        try {
            ZeffyConnectScheduler.newBatch('ZeffyDoesNotExistBatch');
        } catch (ZeffyConnectScheduler.ZeffySchedulerException e) {
            thrown = true;
        }
        System.assert(thrown, 'Unknown batch name must fail loudly');
    }

    @isTest
    static void testExecuteLaunchesBatch() {
        Test.startTest();
        new ZeffyConnectScheduler('ZeffyHoldingExpireBatch', null).execute(null);
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM AsyncApexJob
                                WHERE JobType = 'BatchApex' AND ApexClass.Name = 'ZeffyHoldingExpireBatch'],
                            'Scheduler should launch the named batch');
    }

    @isTest
    static void testScheduleUsesScheduler() {
        Test.startTest();
        ZeffyHoldingExpireBatch.schedule();
        Test.stopTest();
        CronTrigger ct = [SELECT CronJobDetail.Name FROM CronTrigger
                          WHERE CronJobDetail.Name = 'ZeffyHoldingExpireBatch' LIMIT 1];
        System.assertNotEquals(null, ct);
    }
}
