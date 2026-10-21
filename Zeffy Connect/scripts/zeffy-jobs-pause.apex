// Aborts Zeffy Connect scheduled jobs (no class references, so it compiles on any org).
Integer n = 0;
for (CronTrigger ct : [SELECT Id FROM CronTrigger
                       WHERE CronJobDetail.Name IN ('ZeffyHoldingExpireBatch', 'ZeffyConnectLapsedDonorBatch')]) {
    System.abortJob(ct.Id);
    n++;
}
System.debug('ZEFFY_JOBS_PAUSED=' + n);
