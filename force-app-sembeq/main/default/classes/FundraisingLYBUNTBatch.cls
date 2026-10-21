// Scheduled batch that refreshes LYBUNT / SYBUNT checkboxes on all Contacts.
// LYBUNT = donated last calendar year but NOT this calendar year.
// SYBUNT = donated any prior year but NOT this calendar year.
//
// Schedule from Setup > Apex Classes > Schedule or via Anonymous Apex:
//   System.schedule('Fundraising LYBUNT/SYBUNT Daily', '0 0 2 * * ?', new FundraisingLYBUNTBatch());
public class FundraisingLYBUNTBatch implements Database.Batchable<SObject>, Schedulable {

    public void execute(SchedulableContext sc) {
        Database.executeBatch(new FundraisingLYBUNTBatch(), 200);
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        // Only process contacts that have at least one Gift_Transaction__c
        return Database.getQueryLocator([
            SELECT Id
            FROM Contact
            WHERE Id IN (SELECT Donor__c FROM Gift_Transaction__c WHERE Status__c = 'Received')
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Contact> scope) {
        Set<Id> contactIds = new Map<Id, Contact>(scope).keySet();

        Integer thisYear = Date.today().year();
        Integer lastYear = thisYear - 1;

        Date thisYearStart = Date.newInstance(thisYear, 1, 1);
        Date lastYearStart = Date.newInstance(lastYear, 1, 1);
        Date lastYearEnd   = Date.newInstance(lastYear, 12, 31);

        Set<Id> donatedThisYear = new Set<Id>();
        Set<Id> donatedLastYear = new Set<Id>();
        Set<Id> donatedAnyPrior = new Set<Id>();

        for (AggregateResult ar : [
            SELECT Donor__c cid
            FROM Gift_Transaction__c
            WHERE Donor__c IN :contactIds
              AND Status__c = 'Received'
              AND Gift_Date__c >= :thisYearStart
            GROUP BY Donor__c
        ]) {
            donatedThisYear.add((Id) ar.get('cid'));
        }

        for (AggregateResult ar : [
            SELECT Donor__c cid
            FROM Gift_Transaction__c
            WHERE Donor__c IN :contactIds
              AND Status__c = 'Received'
              AND Gift_Date__c >= :lastYearStart
              AND Gift_Date__c <= :lastYearEnd
            GROUP BY Donor__c
        ]) {
            donatedLastYear.add((Id) ar.get('cid'));
        }

        for (AggregateResult ar : [
            SELECT Donor__c cid
            FROM Gift_Transaction__c
            WHERE Donor__c IN :contactIds
              AND Status__c = 'Received'
              AND Gift_Date__c < :thisYearStart
            GROUP BY Donor__c
        ]) {
            donatedAnyPrior.add((Id) ar.get('cid'));
        }

        List<Contact> toUpdate = new List<Contact>();
        for (Contact c : scope) {
            Boolean lybunt = !donatedThisYear.contains(c.Id) && donatedLastYear.contains(c.Id);
            Boolean sybunt = !donatedThisYear.contains(c.Id) && donatedAnyPrior.contains(c.Id);
            toUpdate.add(new Contact(
                Id       = c.Id,
                LYBUNT__c = lybunt,
                SYBUNT__c = sybunt
            ));
        }
        update toUpdate;
    }

    public void finish(Database.BatchableContext bc) {}
}
