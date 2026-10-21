/**
 * DmcLapsedDonorBatch
 *
 * Finds Account donors whose last GiftTransaction is older than Lapsed_Days__c
 * and creates a Task for each one, assigned to the configured owner.
 *
 * Scheduling is managed by saveAppSettings() in DmcConfigService.
 * Job name used: 'DmcLapsedDonorBatch'
 */
public class DmcLapsedDonorBatch implements Database.Batchable<SObject>, Schedulable {

    private static final String JOB_NAME = 'DmcLapsedDonorBatch';

    // ── Schedulable ───────────────────────────────────────────────────────────
    public void execute(SchedulableContext ctx) {
        Database.executeBatch(new DmcLapsedDonorBatch(), 200);
    }

    // ── Schedule / unschedule helpers ─────────────────────────────────────────
    public static void schedule(Zeffy_Config__c cfg) {
        unschedule();
        String freq = String.isNotBlank(cfg.Lapsed_Schedule_Frequency__c)
                          ? cfg.Lapsed_Schedule_Frequency__c : 'WEEKLY';
        String cron;
        if (freq == 'MONTHLY') {
            cron = '0 0 7 1 * ?'; // first day of every month at 7:00 AM
        } else {
            String day = mapDayToCron(cfg.Lapsed_Schedule_Day__c);
            cron = '0 0 7 ? * ' + day; // every configured weekday at 7:00 AM
        }
        System.schedule(JOB_NAME, cron, new DmcLapsedDonorBatch());
    }

    public static void unschedule() {
        for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :JOB_NAME]) {
            System.abortJob(ct.Id);
        }
    }

    private static String mapDayToCron(String day) {
        Map<String, String> m = new Map<String, String>{
            'MON' => 'MON', 'TUE' => 'TUE', 'WED' => 'WED',
            'THU' => 'THU', 'FRI' => 'FRI'
        };
        return m.containsKey(day) ? m.get(day) : 'MON';
    }

    // ── Batchable ─────────────────────────────────────────────────────────────
    public Database.QueryLocator start(Database.BatchableContext ctx) {
        Zeffy_Config__c cfg = DmcConfigService.getConfig();
        Integer lapsedDays  = cfg != null && cfg.Lapsed_Days__c != null
                                  ? (Integer) cfg.Lapsed_Days__c : 365;
        Date cutoff = Date.today().addDays(-lapsedDays);

        // Accounts with at least one GiftTransaction where the latest was before the cutoff
        return Database.getQueryLocator([
            SELECT Id, Name,
                   (SELECT TransactionDate FROM GiftTransactions
                    ORDER BY TransactionDate DESC LIMIT 1)
            FROM Account
            WHERE Id IN (
                SELECT DonorId FROM GiftTransaction
                WHERE TransactionDate < :cutoff
            )
            AND Id NOT IN (
                SELECT DonorId FROM GiftTransaction
                WHERE TransactionDate >= :cutoff
            )
        ]);
    }

    public void execute(Database.BatchableContext ctx, List<Account> accounts) {
        Zeffy_Config__c cfg    = DmcConfigService.getConfig();
        if (cfg == null || cfg.Lapsed_Alert_Enabled__c != true) return;

        Integer lapsedDays  = cfg.Lapsed_Days__c != null ? (Integer) cfg.Lapsed_Days__c : 365;
        Id      ownerId     = String.isNotBlank(cfg.Lapsed_Owner_Id__c)
                                  ? cfg.Lapsed_Owner_Id__c
                                  : UserInfo.getUserId();

        // Avoid duplicate tasks: skip accounts that already have an open lapsed task
        Set<Id> accountIds = new Map<Id, Account>(accounts).keySet();
        Set<Id> alreadyTasked = new Set<Id>();
        for (Task t : [SELECT WhatId FROM Task
                       WHERE WhatId IN :accountIds
                         AND Subject LIKE 'Lapsed donor%'
                         AND Status != 'Completed'
                         AND IsClosed = false]) {
            alreadyTasked.add(t.WhatId);
        }

        List<Task> tasks = new List<Task>();
        for (Account acc : accounts) {
            if (alreadyTasked.contains(acc.Id)) continue;
            tasks.add(new Task(
                Subject      = 'Lapsed donor — has not given in ' + lapsedDays + ' days: ' + acc.Name,
                ActivityDate = Date.today().addDays(3),
                OwnerId      = ownerId,
                WhatId       = acc.Id,
                Status       = 'Not Started',
                Priority     = 'Normal',
                Description  = 'This donor has not made a donation in ' + lapsedDays +
                               ' days. Consider reaching out to re-engage them.'
            ));
        }
        if (!tasks.isEmpty()) insert tasks;
    }

    public void finish(Database.BatchableContext ctx) {}
}
