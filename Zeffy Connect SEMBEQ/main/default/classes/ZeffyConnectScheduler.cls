/**
 * ZeffyConnectScheduler
 *
 * The only class Zeffy Connect ever hands to System.schedule().
 * It resolves the batch by name at run time (Type.forName), so there is no compile-time
 * link from the scheduled job to the batch or to ZeffyConnectConfigService. That keeps
 * Salesforce from blocking deploys with "This schedulable class has jobs pending".
 *
 * Keep this class tiny and stable — changing it while a job is scheduled is still blocked.
 */
public class ZeffyConnectScheduler implements Schedulable {

    private final String  batchClassName;
    private final Integer scopeSize;

    public ZeffyConnectScheduler(String batchClassName, Integer scopeSize) {
        this.batchClassName = batchClassName;
        this.scopeSize      = scopeSize != null ? scopeSize : 200;
    }

    public void execute(SchedulableContext sc) {
        Database.executeBatch(newBatch(batchClassName), scopeSize);
    }

    // Fails loudly (visible in Apex Jobs) if the batch was renamed or removed
    @TestVisible
    private static Database.Batchable<SObject> newBatch(String className) {
        Type t = String.isBlank(className) ? null : Type.forName(className);
        if (t == null) {
            throw new ZeffySchedulerException('Zeffy Connect scheduled batch not found: ' + className);
        }
        return (Database.Batchable<SObject>) t.newInstance();
    }

    public class ZeffySchedulerException extends Exception {}
}
