public without sharing class FundraisingScholarshipService {

    // ─── Scholarship_Allocation__c → Scholarship__c.Total_Allocated__c ──────
    // Triggered by FundraisingScholarshipTrigger (on Scholarship_Allocation__c)
    public static void rollupAllocations(Set<Id> scholarshipIds) {
        if (scholarshipIds.isEmpty()) return;

        Map<Id, Decimal> allocatedMap = new Map<Id, Decimal>();

        for (Scholarship_Allocation__c a : [
            SELECT Scholarship__c, Monthly_Amount__c, Number_of_Payments__c
            FROM Scholarship_Allocation__c
            WHERE Scholarship__c IN :scholarshipIds AND Status__c != 'Cancelled'
        ]) {
            Decimal monthly = a.Monthly_Amount__c    != null ? a.Monthly_Amount__c    : 0;
            Decimal count   = a.Number_of_Payments__c != null ? a.Number_of_Payments__c : 0;
            Decimal current = allocatedMap.containsKey(a.Scholarship__c)
                              ? allocatedMap.get(a.Scholarship__c) : 0;
            allocatedMap.put(a.Scholarship__c, current + (monthly * count));
        }

        List<Scholarship__c> toUpdate = new List<Scholarship__c>();
        for (Id sid : scholarshipIds) {
            toUpdate.add(new Scholarship__c(
                Id                 = sid,
                Total_Allocated__c = allocatedMap.containsKey(sid) ? allocatedMap.get(sid) : 0
            ));
        }
        update toUpdate;
    }

    // ─── Scholarship_Payment__c → Allocation.Amount_Disbursed__c + Scholarship.Total_Disbursed__c
    // Triggered by FundraisingPaymentTrigger (on Scholarship_Payment__c)
    public static void rollupPayments(Set<Id> allocationIds) {
        if (allocationIds.isEmpty()) return;

        // Step 1: roll up to Allocation
        Map<Id, Decimal> disbursedPerAlloc = new Map<Id, Decimal>();

        for (AggregateResult ar : [
            SELECT Allocation__c aid, SUM(Amount__c) tot
            FROM Scholarship_Payment__c
            WHERE Allocation__c IN :allocationIds AND Status__c = 'Paid'
            GROUP BY Allocation__c
        ]) {
            disbursedPerAlloc.put((Id) ar.get('aid'), (Decimal) ar.get('tot'));
        }

        List<Scholarship_Allocation__c> allocToUpdate = new List<Scholarship_Allocation__c>();
        for (Id aid : allocationIds) {
            allocToUpdate.add(new Scholarship_Allocation__c(
                Id                  = aid,
                Amount_Disbursed__c = disbursedPerAlloc.containsKey(aid)
                                      ? disbursedPerAlloc.get(aid) : 0
            ));
        }
        update allocToUpdate;

        // Step 2: roll up to Scholarship via the affected allocations
        Set<Id> scholarshipIds = new Set<Id>();
        for (Scholarship_Allocation__c a : [
            SELECT Scholarship__c FROM Scholarship_Allocation__c WHERE Id IN :allocationIds
        ]) {
            if (a.Scholarship__c != null) scholarshipIds.add(a.Scholarship__c);
        }
        if (scholarshipIds.isEmpty()) return;

        Map<Id, Decimal> disbursedPerSchol = new Map<Id, Decimal>();
        for (AggregateResult ar : [
            SELECT Allocation__r.Scholarship__c sid, SUM(Amount__c) tot
            FROM Scholarship_Payment__c
            WHERE Allocation__r.Scholarship__c IN :scholarshipIds AND Status__c = 'Paid'
            GROUP BY Allocation__r.Scholarship__c
        ]) {
            disbursedPerSchol.put((Id) ar.get('sid'), (Decimal) ar.get('tot'));
        }

        List<Scholarship__c> scholToUpdate = new List<Scholarship__c>();
        for (Id sid : scholarshipIds) {
            scholToUpdate.add(new Scholarship__c(
                Id                 = sid,
                Total_Disbursed__c = disbursedPerSchol.containsKey(sid)
                                     ? disbursedPerSchol.get(sid) : 0
            ));
        }
        update scholToUpdate;
    }
}
