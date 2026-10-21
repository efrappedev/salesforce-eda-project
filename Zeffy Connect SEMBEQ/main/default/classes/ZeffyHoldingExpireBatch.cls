public class ZeffyHoldingExpireBatch implements Database.Batchable<SObject>, Schedulable {

    // Runs daily via scheduler — moves HOLDING tickets received more than N days ago to Delayed.
    // CreatedDate is the anchor: the grace period counts from when the ticket was received,
    // so repeated payment.updated events (or staff edits) never keep a ticket in Holding forever.
    // Scheduling is managed by saveEventToggles() in ZeffyConnectConfigService.

    private static final String JOB_NAME           = 'ZeffyHoldingExpireBatch';
    private static final Integer DEFAULT_GRACE_DAYS = 10;

    // ── Schedulable ──────────────────────────────────────────────────────────
    public void execute(SchedulableContext sc) {
        Database.executeBatch(new ZeffyHoldingExpireBatch(), 200);
    }

    // ── Schedule / unschedule helpers ────────────────────────────────────────
    public static void schedule() {
        unschedule();
        // Scheduled through ZeffyConnectScheduler so deploys of this class are never blocked
        System.schedule(JOB_NAME, '0 0 7 * * ?', new ZeffyConnectScheduler('ZeffyHoldingExpireBatch', 200));
    }

    public static void unschedule() {
        for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :JOB_NAME]) {
            System.abortJob(ct.Id);
        }
    }

    // ── Batchable ────────────────────────────────────────────────────────────
    public Database.QueryLocator start(Database.BatchableContext bc) {
        Zeffy_Config__c cfg = ZeffyConnectConfigService.getConfig();
        if (cfg == null || cfg.Holding_Auto_Expire_Enabled__c != true) {
            return Database.getQueryLocator('SELECT Id FROM Zeffy_Review_Ticket__c WHERE Id = null');
        }
        Integer days    = cfg.Holding_Expire_Days__c != null ? (Integer) cfg.Holding_Expire_Days__c : DEFAULT_GRACE_DAYS;
        DateTime cutoff = DateTime.now().addDays(-days);
        return Database.getQueryLocator([
            SELECT Id, Status__c
            FROM Zeffy_Review_Ticket__c
            WHERE Status__c = 'Holding'
              AND CreatedDate <= :cutoff
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Zeffy_Review_Ticket__c> scope) {
        List<Zeffy_Connect_Audit_Log__c> logs = new List<Zeffy_Connect_Audit_Log__c>();
        for (Zeffy_Review_Ticket__c t : scope) {
            t.Status__c = 'Delayed';
            logs.add(new Zeffy_Connect_Audit_Log__c(
                Ticket__c       = t.Id,
                Action__c       = 'Expired to Delayed',
                Performed_By__c = UserInfo.getUserId(),
                Performed_At__c = DateTime.now(),
                Notes__c        = 'Holding → Delayed: no payment confirmation from Zeffy within the grace period. '
                                + 'A later payment.completed still graduates it.'
            ));
        }
        if (scope.isEmpty()) return;
        update scope;
        Database.insert(logs, false);   // audit is best-effort, never blocks the expiry
    }

    public void finish(Database.BatchableContext bc) {}
}
