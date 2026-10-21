public class AdmissionsDecisionHandler {

    private static final Map<String, String> DECISION_TO_STATUS = new Map<String, String>{
        'Admitted'                 => 'Accepted',
        'Admitted with Conditions' => 'Accepted',
        'Waitlisted'               => 'Waitlisted',
        'Deferred'                 => 'Deferred',
        'Rejected'                 => 'Rejected'
    };

    public static void handle(List<Admissions_Decision__c> newDecisions, Map<Id, Admissions_Decision__c> oldMap) {
        Set<Id> appIds = new Set<Id>();
        for (Admissions_Decision__c dec : newDecisions) {
            if (dec.Application__c != null) appIds.add(dec.Application__c);
        }
        if (appIds.isEmpty()) return;

        Map<Id, hed__Application__c> appMap = new Map<Id, hed__Application__c>([
            SELECT Id, hed__Application_Status__c, hed__Applicant__c, Program__c
            FROM hed__Application__c
            WHERE Id IN :appIds
        ]);

        List<hed__Application__c> appsToUpdate = new List<hed__Application__c>();
        List<hed__Program_Enrollment__c> enrollmentsToCreate = new List<hed__Program_Enrollment__c>();

        for (Admissions_Decision__c dec : newDecisions) {
            Boolean isNew    = oldMap == null || !oldMap.containsKey(dec.Id);
            Boolean changed  = !isNew && oldMap.get(dec.Id).Decision__c != dec.Decision__c;
            if (!isNew && !changed) continue;

            hed__Application__c app = appMap.get(dec.Application__c);
            if (app == null) continue;

            String newAppStatus = DECISION_TO_STATUS.get(dec.Decision__c);
            if (newAppStatus != null && app.hed__Application_Status__c != newAppStatus) {
                appsToUpdate.add(new hed__Application__c(
                    Id = app.Id,
                    hed__Application_Status__c = newAppStatus
                ));
            }

            // Auto-enroll on Admitted decision (insert only, to avoid duplicates)
            if (isNew && (dec.Decision__c == 'Admitted' || dec.Decision__c == 'Admitted with Conditions')
                && app.hed__Applicant__c != null) {
                hed__Program_Enrollment__c pe = new hed__Program_Enrollment__c(
                    hed__Contact__c      = app.hed__Applicant__c,
                    hed__Program_Plan__c = app.Program__c
                );
                enrollmentsToCreate.add(pe);
            }
        }

        if (!appsToUpdate.isEmpty())      update appsToUpdate;
        if (!enrollmentsToCreate.isEmpty()) insert enrollmentsToCreate;
    }
}
