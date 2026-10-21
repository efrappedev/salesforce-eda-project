public without sharing class FundraisingRollupService {

    public static void recalculateByParents(
        Set<Id> contactIds,
        Set<Id> designationIds,
        Set<Id> commitmentIds
    ) {
        if (!contactIds.isEmpty())     rollupContacts(contactIds);
        if (!designationIds.isEmpty()) rollupDesignations(designationIds);
        if (!commitmentIds.isEmpty())  rollupCommitments(commitmentIds);
    }

    // ─── Contact ────────────────────────────────────────────────────────────
    @TestVisible
    static void rollupContacts(Set<Id> contactIds) {
        Map<Id, Decimal>  totalMap     = new Map<Id, Decimal>();
        Map<Id, Date>     lastDateMap  = new Map<Id, Date>();
        Map<Id, Date>     firstDateMap = new Map<Id, Date>();
        Map<Id, Integer>  cntMap       = new Map<Id, Integer>();
        Map<Id, Decimal>  lastAmtMap   = new Map<Id, Decimal>();

        for (AggregateResult ar : [
            SELECT Donor__c cid,
                   SUM(Amount__c) tot,
                   MAX(Gift_Date__c) mxDate,
                   MIN(Gift_Date__c) mnDate,
                   COUNT(Id) n
            FROM Gift_Transaction__c
            WHERE Donor__c IN :contactIds AND Status__c = 'Received'
            GROUP BY Donor__c
        ]) {
            Id cid = (Id) ar.get('cid');
            totalMap.put(cid,     (Decimal) ar.get('tot'));
            lastDateMap.put(cid,  (Date)    ar.get('mxDate'));
            firstDateMap.put(cid, (Date)    ar.get('mnDate'));
            cntMap.put(cid,       ((Decimal) ar.get('n')).intValue());
        }

        // Most recent Received gift amount per contact
        for (Gift_Transaction__c g : [
            SELECT Donor__c, Amount__c
            FROM Gift_Transaction__c
            WHERE Donor__c IN :contactIds AND Status__c = 'Received'
            ORDER BY Gift_Date__c DESC NULLS LAST, CreatedDate DESC NULLS LAST
        ]) {
            if (!lastAmtMap.containsKey(g.Donor__c)) lastAmtMap.put(g.Donor__c, g.Amount__c);
        }

        List<Contact> toUpdate = new List<Contact>();
        for (Id cid : contactIds) {
            toUpdate.add(new Contact(
                Id                       = cid,
                Total_Lifetime_Giving__c = totalMap.containsKey(cid)     ? totalMap.get(cid)     : 0,
                Last_Gift_Date__c        = lastDateMap.containsKey(cid)  ? lastDateMap.get(cid)  : null,
                Last_Gift_Amount__c      = lastAmtMap.containsKey(cid)   ? lastAmtMap.get(cid)   : null,
                First_Gift_Date__c       = firstDateMap.containsKey(cid) ? firstDateMap.get(cid) : null,
                Total_Gift_Count__c      = cntMap.containsKey(cid)       ? cntMap.get(cid)       : 0
            ));
        }
        update toUpdate;
    }

    // ─── Gift_Designation__c ────────────────────────────────────────────────
    @TestVisible
    static void rollupDesignations(Set<Id> designationIds) {
        Map<Id, Decimal> totalRaisedMap  = new Map<Id, Decimal>();
        Map<Id, Decimal> currentYearMap  = new Map<Id, Decimal>();

        Integer yr        = Date.today().year();
        Date    yearStart = Date.newInstance(yr, 1, 1);
        Date    yearEnd   = Date.newInstance(yr, 12, 31);

        for (AggregateResult ar : [
            SELECT Gift_Designation__c did, SUM(Amount__c) tot
            FROM Gift_Transaction__c
            WHERE Gift_Designation__c IN :designationIds AND Status__c = 'Received'
            GROUP BY Gift_Designation__c
        ]) {
            totalRaisedMap.put((Id) ar.get('did'), (Decimal) ar.get('tot'));
        }

        for (AggregateResult ar : [
            SELECT Gift_Designation__c did, SUM(Amount__c) tot
            FROM Gift_Transaction__c
            WHERE Gift_Designation__c IN :designationIds AND Status__c = 'Received'
              AND Gift_Date__c >= :yearStart AND Gift_Date__c <= :yearEnd
            GROUP BY Gift_Designation__c
        ]) {
            currentYearMap.put((Id) ar.get('did'), (Decimal) ar.get('tot'));
        }

        List<Gift_Designation__c> toUpdate = new List<Gift_Designation__c>();
        for (Id did : designationIds) {
            toUpdate.add(new Gift_Designation__c(
                Id                    = did,
                Total_Raised__c       = totalRaisedMap.containsKey(did)  ? totalRaisedMap.get(did)  : 0,
                Current_Year_Total__c = currentYearMap.containsKey(did)  ? currentYearMap.get(did)  : 0
            ));
        }
        update toUpdate;
    }

    // ─── Gift_Refund__c → Refunded_Amount__c on Gift_Transaction__c ─────────
    public static void rollupRefunds(Set<Id> giftIds) {
        if (giftIds.isEmpty()) return;

        Map<Id, Decimal> refundedMap = new Map<Id, Decimal>();

        for (AggregateResult ar : [
            SELECT Gift__c gid, SUM(Amount__c) tot
            FROM Gift_Refund__c
            WHERE Gift__c IN :giftIds AND Status__c = 'Processed'
            GROUP BY Gift__c
        ]) {
            refundedMap.put((Id) ar.get('gid'), (Decimal) ar.get('tot'));
        }

        List<Gift_Transaction__c> toUpdate = new List<Gift_Transaction__c>();
        for (Id gid : giftIds) {
            toUpdate.add(new Gift_Transaction__c(
                Id                 = gid,
                Refunded_Amount__c = refundedMap.containsKey(gid) ? refundedMap.get(gid) : 0
            ));
        }
        update toUpdate;
    }

    // ─── Gift_Commitment__c ─────────────────────────────────────────────────
    @TestVisible
    static void rollupCommitments(Set<Id> commitmentIds) {
        Map<Id, Decimal>  totalPaidMap = new Map<Id, Decimal>();
        Map<Id, Integer>  payCntMap    = new Map<Id, Integer>();

        for (AggregateResult ar : [
            SELECT Recurring_Gift__c cid, SUM(Amount__c) tot, COUNT(Id) n
            FROM Gift_Transaction__c
            WHERE Recurring_Gift__c IN :commitmentIds AND Status__c = 'Received'
            GROUP BY Recurring_Gift__c
        ]) {
            Id cid = (Id) ar.get('cid');
            totalPaidMap.put(cid, (Decimal) ar.get('tot'));
            payCntMap.put(cid,    ((Decimal) ar.get('n')).intValue());
        }

        List<Gift_Commitment__c> toUpdate = new List<Gift_Commitment__c>();
        for (Id cid : commitmentIds) {
            toUpdate.add(new Gift_Commitment__c(
                Id               = cid,
                Total_Paid__c    = totalPaidMap.containsKey(cid) ? totalPaidMap.get(cid) : 0,
                Payment_Count__c = payCntMap.containsKey(cid)    ? payCntMap.get(cid)    : 0
            ));
        }
        update toUpdate;
    }
}
