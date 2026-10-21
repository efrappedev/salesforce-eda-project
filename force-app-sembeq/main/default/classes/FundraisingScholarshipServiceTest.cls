@IsTest
private class FundraisingScholarshipServiceTest {

    @TestSetup
    static void setup() {
        Contact student = new Contact(LastName = 'Student Test');
        insert student;

        Scholarship__c s = new Scholarship__c(
            Name          = 'Test Scholarship',
            Total_Amount__c = 10000,
            Status__c     = 'Active',
            Start_Date__c = Date.today()
        );
        insert s;
    }

    static Contact getStudent() {
        return [SELECT Id FROM Contact WHERE LastName = 'Student Test' LIMIT 1];
    }
    static Scholarship__c getScholarship() {
        return [SELECT Id, Total_Allocated__c, Total_Disbursed__c FROM Scholarship__c LIMIT 1];
    }

    static Scholarship_Allocation__c makeAlloc(Id scholarshipId, Id studentId, Decimal monthly, Integer payments, String status) {
        return new Scholarship_Allocation__c(
            Scholarship__c       = scholarshipId,
            Student__c           = studentId,
            Monthly_Amount__c    = monthly,
            Number_of_Payments__c = payments,
            Status__c            = status,
            Start_Date__c        = Date.today()
        );
    }

    // ─── Allocation roll-ups ─────────────────────────────────────────────────

    // T1: Insert Active allocation → Total_Allocated__c se actualiza
    @IsTest
    static void t1_insertAllocation_totalAllocatedUpdates() {
        Scholarship__c s = getScholarship();

        Test.startTest();
        insert makeAlloc(s.Id, getStudent().Id, 500, 4, 'Active'); // 500*4 = 2000
        Test.stopTest();

        Scholarship__c su = [SELECT Total_Allocated__c FROM Scholarship__c WHERE Id = :s.Id];
        System.assertEquals(2000, su.Total_Allocated__c, 'Total_Allocated debe ser 2000');
    }

    // T2: Insert Cancelled allocation → no cuenta
    @IsTest
    static void t2_insertCancelledAllocation_doesNotCount() {
        Scholarship__c s = getScholarship();

        Test.startTest();
        insert makeAlloc(s.Id, getStudent().Id, 500, 4, 'Cancelled');
        Test.stopTest();

        Scholarship__c su = [SELECT Total_Allocated__c FROM Scholarship__c WHERE Id = :s.Id];
        System.assertEquals(0, su.Total_Allocated__c, 'Cancelled no debe contar');
    }

    // T3: Update allocation status Active → Cancelled → Total_Allocated__c baja
    @IsTest
    static void t3_cancelAllocation_totalAllocatedDrops() {
        Scholarship__c s = getScholarship();
        Scholarship_Allocation__c a = makeAlloc(s.Id, getStudent().Id, 300, 6, 'Active'); // 1800
        insert a;

        Test.startTest();
        a.Status__c = 'Cancelled';
        update a;
        Test.stopTest();

        Scholarship__c su = [SELECT Total_Allocated__c FROM Scholarship__c WHERE Id = :s.Id];
        System.assertEquals(0, su.Total_Allocated__c, 'Cancelar debe quitar el monto');
    }

    // T4: Delete allocation → Total_Allocated__c a cero
    @IsTest
    static void t4_deleteAllocation_totalAllocatedReset() {
        Scholarship__c s = getScholarship();
        Scholarship_Allocation__c a = makeAlloc(s.Id, getStudent().Id, 200, 3, 'Active'); // 600
        insert a;

        Test.startTest();
        delete a;
        Test.stopTest();

        Scholarship__c su = [SELECT Total_Allocated__c FROM Scholarship__c WHERE Id = :s.Id];
        System.assertEquals(0, su.Total_Allocated__c, 'Delete debe quitar el monto');
    }

    // T5: Múltiples allocations → suman correctamente (Cancelled excluida)
    @IsTest
    static void t5_multipleAllocations_onlyActiveCount() {
        Scholarship__c s  = getScholarship();
        Contact st = getStudent();

        Test.startTest();
        insert new List<Scholarship_Allocation__c>{
            makeAlloc(s.Id, st.Id, 500, 4, 'Active'),    // 2000
            makeAlloc(s.Id, st.Id, 250, 4, 'Completed'), // 1000
            makeAlloc(s.Id, st.Id, 300, 4, 'Cancelled')  // 0
        };
        Test.stopTest();

        Scholarship__c su = [SELECT Total_Allocated__c FROM Scholarship__c WHERE Id = :s.Id];
        System.assertEquals(3000, su.Total_Allocated__c, 'Active + Completed = 3000');
    }

    // ─── Payment roll-ups ────────────────────────────────────────────────────

    // T6: Insert payment Paid → Amount_Disbursed__c en Allocation + Total_Disbursed__c en Scholarship
    @IsTest
    static void t6_insertPaidPayment_disbursedUpdates() {
        Scholarship__c s = getScholarship();
        Scholarship_Allocation__c a = makeAlloc(s.Id, getStudent().Id, 500, 4, 'Active');
        insert a;

        Test.startTest();
        insert new Scholarship_Payment__c(
            Allocation__c  = a.Id,
            Amount__c      = 500,
            Status__c      = 'Paid',
            Payment_Date__c = Date.today()
        );
        Test.stopTest();

        Scholarship_Allocation__c au = [SELECT Amount_Disbursed__c FROM Scholarship_Allocation__c WHERE Id = :a.Id];
        Scholarship__c su = [SELECT Total_Disbursed__c FROM Scholarship__c WHERE Id = :s.Id];
        System.assertEquals(500, au.Amount_Disbursed__c, 'Allocation Amount_Disbursed debe ser 500');
        System.assertEquals(500, su.Total_Disbursed__c,  'Scholarship Total_Disbursed debe ser 500');
    }

    // T7: Insert payment Scheduled → no cuenta
    @IsTest
    static void t7_insertScheduledPayment_doesNotCount() {
        Scholarship__c s = getScholarship();
        Scholarship_Allocation__c a = makeAlloc(s.Id, getStudent().Id, 500, 4, 'Active');
        insert a;

        Test.startTest();
        insert new Scholarship_Payment__c(
            Allocation__c   = a.Id,
            Amount__c       = 500,
            Status__c       = 'Scheduled',
            Payment_Date__c = Date.today()
        );
        Test.stopTest();

        Scholarship__c su = [SELECT Total_Disbursed__c FROM Scholarship__c WHERE Id = :s.Id];
        System.assertEquals(0, su.Total_Disbursed__c, 'Scheduled no debe contar');
    }

    // T8: Update Scheduled → Paid → roll-ups se actualizan
    @IsTest
    static void t8_updatePaymentToPaid_disbursedUpdates() {
        Scholarship__c s = getScholarship();
        Scholarship_Allocation__c a = makeAlloc(s.Id, getStudent().Id, 500, 4, 'Active');
        insert a;
        Scholarship_Payment__c p = new Scholarship_Payment__c(
            Allocation__c = a.Id, Amount__c = 300, Status__c = 'Scheduled', Payment_Date__c = Date.today()
        );
        insert p;

        Test.startTest();
        p.Status__c = 'Paid';
        update p;
        Test.stopTest();

        Scholarship__c su = [SELECT Total_Disbursed__c FROM Scholarship__c WHERE Id = :s.Id];
        System.assertEquals(300, su.Total_Disbursed__c, 'Paid debe sumar 300');
    }

    // T9: Delete payment Paid → roll-ups bajan
    @IsTest
    static void t9_deletePaidPayment_disbursedReset() {
        Scholarship__c s = getScholarship();
        Scholarship_Allocation__c a = makeAlloc(s.Id, getStudent().Id, 500, 4, 'Active');
        insert a;
        Scholarship_Payment__c p = new Scholarship_Payment__c(
            Allocation__c = a.Id, Amount__c = 500, Status__c = 'Paid', Payment_Date__c = Date.today()
        );
        insert p;

        Test.startTest();
        delete p;
        Test.stopTest();

        Scholarship_Allocation__c au = [SELECT Amount_Disbursed__c FROM Scholarship_Allocation__c WHERE Id = :a.Id];
        Scholarship__c su = [SELECT Total_Disbursed__c FROM Scholarship__c WHERE Id = :s.Id];
        System.assertEquals(0, au.Amount_Disbursed__c, 'Delete debe quitar el monto en Allocation');
        System.assertEquals(0, su.Total_Disbursed__c,  'Delete debe quitar el monto en Scholarship');
    }

    // T10: Múltiples allocations y payments → Total_Disbursed__c suma todas
    @IsTest
    static void t10_multipleAllocationsPayments_scholarshipTotalCorrect() {
        Scholarship__c s  = getScholarship();
        Contact st = getStudent();

        Scholarship_Allocation__c a1 = makeAlloc(s.Id, st.Id, 500, 4, 'Active');
        Scholarship_Allocation__c a2 = makeAlloc(s.Id, st.Id, 300, 6, 'Active');
        insert new List<Scholarship_Allocation__c>{ a1, a2 };

        Test.startTest();
        insert new List<Scholarship_Payment__c>{
            new Scholarship_Payment__c(Allocation__c = a1.Id, Amount__c = 500, Status__c = 'Paid',      Payment_Date__c = Date.today()),
            new Scholarship_Payment__c(Allocation__c = a2.Id, Amount__c = 300, Status__c = 'Paid',      Payment_Date__c = Date.today()),
            new Scholarship_Payment__c(Allocation__c = a2.Id, Amount__c = 300, Status__c = 'Scheduled', Payment_Date__c = Date.today())
        };
        Test.stopTest();

        Scholarship__c su = [SELECT Total_Disbursed__c FROM Scholarship__c WHERE Id = :s.Id];
        System.assertEquals(800, su.Total_Disbursed__c, 'Solo Paid de ambas allocations: 500+300=800');
    }
}
