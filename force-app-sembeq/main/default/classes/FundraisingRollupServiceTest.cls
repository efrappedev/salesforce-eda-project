@IsTest
private class FundraisingRollupServiceTest {

    // ─── Shared setup ────────────────────────────────────────────────────────
    @TestSetup
    static void setup() {
        // Contact (donante individual)
        Contact c = new Contact(LastName = 'Donor Test');
        insert c;

        // Gift_Designation__c (fondo)
        Gift_Designation__c gd = new Gift_Designation__c(Name = 'General Fund', Is_Active__c = true);
        insert gd;

        // Gift_Commitment__c (compromiso recurrente)
        Gift_Commitment__c gc = new Gift_Commitment__c(
            Donor__c   = c.Id,
            Amount__c  = 100,
            Frequency__c = 'Monthly',
            Status__c  = 'Active',
            Start_Date__c = Date.today()
        );
        insert gc;
    }

    // ─── Helper ──────────────────────────────────────────────────────────────
    static Contact getContact() {
        return [SELECT Id FROM Contact WHERE LastName = 'Donor Test' LIMIT 1];
    }
    static Gift_Designation__c getDesignation() {
        return [SELECT Id FROM Gift_Designation__c WHERE Name = 'General Fund' LIMIT 1];
    }
    static Gift_Commitment__c getCommitment() {
        return [SELECT Id FROM Gift_Commitment__c LIMIT 1];
    }

    static Gift_Transaction__c makeGift(Id contactId, Id designId, Id commitId, Decimal amt, String status) {
        return new Gift_Transaction__c(
            Donor__c           = contactId,
            Gift_Designation__c = designId,
            Recurring_Gift__c  = commitId,
            Amount__c          = amt,
            Status__c          = status,
            Gift_Date__c       = Date.today()
        );
    }

    // ─── T1: insert un gift Received → Contact roll-up correcto ──────────────
    @IsTest
    static void t1_insertGift_contactRollupsUpdated() {
        Contact c  = getContact();
        Gift_Designation__c gd = getDesignation();

        Test.startTest();
        insert makeGift(c.Id, gd.Id, null, 150, 'Received');
        Test.stopTest();

        Contact cu = [SELECT Total_Lifetime_Giving__c, Last_Gift_Amount__c,
                             Last_Gift_Date__c, First_Gift_Date__c, Total_Gift_Count__c
                      FROM Contact WHERE Id = :c.Id];
        System.assertEquals(150, cu.Total_Lifetime_Giving__c, 'Total_Lifetime_Giving');
        System.assertEquals(150, cu.Last_Gift_Amount__c,      'Last_Gift_Amount');
        System.assertEquals(Date.today(), cu.Last_Gift_Date__c,   'Last_Gift_Date');
        System.assertEquals(Date.today(), cu.First_Gift_Date__c,  'First_Gift_Date');
        System.assertEquals(1,   cu.Total_Gift_Count__c,      'Total_Gift_Count');
    }

    // ─── T2: insert un gift Received → Designation roll-up correcto ──────────
    @IsTest
    static void t2_insertGift_designationRollupsUpdated() {
        Contact c  = getContact();
        Gift_Designation__c gd = getDesignation();

        Test.startTest();
        insert makeGift(c.Id, gd.Id, null, 200, 'Received');
        Test.stopTest();

        Gift_Designation__c gdu = [SELECT Total_Raised__c, Current_Year_Total__c
                                   FROM Gift_Designation__c WHERE Id = :gd.Id];
        System.assertEquals(200, gdu.Total_Raised__c,      'Total_Raised');
        System.assertEquals(200, gdu.Current_Year_Total__c, 'Current_Year_Total');
    }

    // ─── T3: insert un gift Received → Commitment roll-up correcto ───────────
    @IsTest
    static void t3_insertGift_commitmentRollupsUpdated() {
        Contact c  = getContact();
        Gift_Commitment__c gc = getCommitment();

        Test.startTest();
        insert makeGift(c.Id, null, gc.Id, 100, 'Received');
        Test.stopTest();

        Gift_Commitment__c gcu = [SELECT Total_Paid__c, Payment_Count__c
                                  FROM Gift_Commitment__c WHERE Id = :gc.Id];
        System.assertEquals(100, gcu.Total_Paid__c,    'Total_Paid');
        System.assertEquals(1,   gcu.Payment_Count__c, 'Payment_Count');
    }

    // ─── T4: gift Voided no cuenta en los roll-ups ───────────────────────────
    @IsTest
    static void t4_voidedGift_notCounted() {
        Contact c  = getContact();
        Gift_Designation__c gd = getDesignation();

        Test.startTest();
        insert makeGift(c.Id, gd.Id, null, 999, 'Voided');
        Test.stopTest();

        Contact cu = [SELECT Total_Lifetime_Giving__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals(0, cu.Total_Lifetime_Giving__c, 'Voided no debe contar');
    }

    // ─── T5: update Status Received→Voided → roll-ups bajan ─────────────────
    @IsTest
    static void t5_updateStatusToVoided_rollupsDecrease() {
        Contact c  = getContact();
        Gift_Designation__c gd = getDesignation();
        Gift_Transaction__c g = makeGift(c.Id, gd.Id, null, 300, 'Received');
        insert g;

        Test.startTest();
        g.Status__c = 'Voided';
        update g;
        Test.stopTest();

        Contact cu = [SELECT Total_Lifetime_Giving__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals(0, cu.Total_Lifetime_Giving__c, 'Void debe quitar el monto');
    }

    // ─── T6: delete gift → roll-ups a cero ───────────────────────────────────
    @IsTest
    static void t6_deleteGift_rollupsReset() {
        Contact c  = getContact();
        Gift_Designation__c gd = getDesignation();
        Gift_Transaction__c g = makeGift(c.Id, gd.Id, null, 250, 'Received');
        insert g;

        Test.startTest();
        delete g;
        Test.stopTest();

        Contact cu = [SELECT Total_Lifetime_Giving__c, Total_Gift_Count__c
                      FROM Contact WHERE Id = :c.Id];
        System.assertEquals(0, cu.Total_Lifetime_Giving__c, 'Delete debe quitar el monto');
        System.assertEquals(0, cu.Total_Gift_Count__c,      'Delete debe quitar el count');
    }

    // ─── T7: undelete gift → roll-ups se restauran ───────────────────────────
    @IsTest
    static void t7_undeleteGift_rollupsRestored() {
        Contact c  = getContact();
        Gift_Designation__c gd = getDesignation();
        Gift_Transaction__c g = makeGift(c.Id, gd.Id, null, 75, 'Received');
        insert g;
        delete g;

        Test.startTest();
        undelete g;
        Test.stopTest();

        Contact cu = [SELECT Total_Lifetime_Giving__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals(75, cu.Total_Lifetime_Giving__c, 'Undelete debe restaurar el monto');
    }

    // ─── T8: múltiples gifts → Last_Gift_Amount es el más reciente ───────────
    @IsTest
    static void t8_multipleGifts_lastAmountIsCorrect() {
        Contact c  = getContact();
        Gift_Designation__c gd = getDesignation();

        Gift_Transaction__c g1 = makeGift(c.Id, gd.Id, null, 100, 'Received');
        g1.Gift_Date__c = Date.today().addDays(-10);
        Gift_Transaction__c g2 = makeGift(c.Id, gd.Id, null, 500, 'Received');
        g2.Gift_Date__c = Date.today();

        Test.startTest();
        insert new List<Gift_Transaction__c>{ g1, g2 };
        Test.stopTest();

        Contact cu = [SELECT Total_Lifetime_Giving__c, Last_Gift_Amount__c, Total_Gift_Count__c
                      FROM Contact WHERE Id = :c.Id];
        System.assertEquals(600, cu.Total_Lifetime_Giving__c, 'Total ambos gifts');
        System.assertEquals(500, cu.Last_Gift_Amount__c,      'Last gift es el de hoy');
        System.assertEquals(2,   cu.Total_Gift_Count__c,      'Count = 2');
    }

    // ─── T9: cambio de Donor__c → old y new donor se recalculan ─────────────
    @IsTest
    static void t9_updateDonor_bothContactsRecalculated() {
        Contact c  = getContact();
        Contact c2 = new Contact(LastName = 'Donor Test 2');
        insert c2;
        Gift_Transaction__c g = makeGift(c.Id, null, null, 400, 'Received');
        insert g;

        Test.startTest();
        g.Donor__c = c2.Id;
        update g;
        Test.stopTest();

        Contact cu1 = [SELECT Total_Lifetime_Giving__c FROM Contact WHERE Id = :c.Id];
        Contact cu2 = [SELECT Total_Lifetime_Giving__c FROM Contact WHERE Id = :c2.Id];
        System.assertEquals(0,   cu1.Total_Lifetime_Giving__c, 'Old donor debe quedar en 0');
        System.assertEquals(400, cu2.Total_Lifetime_Giving__c, 'New donor debe tener el monto');
    }

    // ─── T10: bulk 200 gifts → sin governor limit errors ─────────────────────
    @IsTest
    static void t10_bulkInsert_noGovernorErrors() {
        Contact c  = getContact();
        Gift_Designation__c gd = getDesignation();

        List<Gift_Transaction__c> gifts = new List<Gift_Transaction__c>();
        for (Integer i = 0; i < 200; i++) {
            gifts.add(makeGift(c.Id, gd.Id, null, 10, 'Received'));
        }

        Test.startTest();
        insert gifts;
        Test.stopTest();

        Contact cu = [SELECT Total_Lifetime_Giving__c, Total_Gift_Count__c FROM Contact WHERE Id = :c.Id];
        System.assertEquals(2000, cu.Total_Lifetime_Giving__c, 'Total 200 * 10');
        System.assertEquals(200,  cu.Total_Gift_Count__c,      'Count = 200');
    }
}
