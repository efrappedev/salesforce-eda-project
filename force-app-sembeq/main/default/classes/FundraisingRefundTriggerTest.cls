@IsTest
private class FundraisingRefundTriggerTest {

    @TestSetup
    static void setup() {
        Contact c = new Contact(LastName = 'Refund Donor');
        insert c;

        Gift_Designation__c gd = new Gift_Designation__c(Name = 'General Fund', Is_Active__c = true);
        insert gd;

        Gift_Transaction__c g = new Gift_Transaction__c(
            Donor__c           = c.Id,
            Gift_Designation__c = gd.Id,
            Amount__c          = 500,
            Status__c          = 'Received',
            Gift_Date__c       = Date.today()
        );
        insert g;
    }

    static Gift_Transaction__c getGift() {
        return [SELECT Id, Refunded_Amount__c FROM Gift_Transaction__c LIMIT 1];
    }

    // T1: Insert refund Processed → Refunded_Amount__c se actualiza
    @IsTest
    static void t1_insertProcessedRefund_updatesRefundedAmount() {
        Gift_Transaction__c g = getGift();

        Test.startTest();
        insert new Gift_Refund__c(Gift__c = g.Id, Amount__c = 100, Status__c = 'Processed', Refund_Date__c = Date.today());
        Test.stopTest();

        Gift_Transaction__c gu = [SELECT Refunded_Amount__c FROM Gift_Transaction__c WHERE Id = :g.Id];
        System.assertEquals(100, gu.Refunded_Amount__c, 'Processed refund debe sumar');
    }

    // T2: Insert refund Pending → no cuenta
    @IsTest
    static void t2_insertPendingRefund_doesNotCount() {
        Gift_Transaction__c g = getGift();

        Test.startTest();
        insert new Gift_Refund__c(Gift__c = g.Id, Amount__c = 200, Status__c = 'Pending', Refund_Date__c = Date.today());
        Test.stopTest();

        Gift_Transaction__c gu = [SELECT Refunded_Amount__c FROM Gift_Transaction__c WHERE Id = :g.Id];
        System.assertEquals(0, gu.Refunded_Amount__c, 'Pending no debe contar');
    }

    // T3: Update Pending → Processed → Refunded_Amount__c sube
    @IsTest
    static void t3_updatePendingToProcessed_amountUpdates() {
        Gift_Transaction__c g = getGift();
        Gift_Refund__c r = new Gift_Refund__c(Gift__c = g.Id, Amount__c = 150, Status__c = 'Pending', Refund_Date__c = Date.today());
        insert r;

        Test.startTest();
        r.Status__c = 'Processed';
        update r;
        Test.stopTest();

        Gift_Transaction__c gu = [SELECT Refunded_Amount__c FROM Gift_Transaction__c WHERE Id = :g.Id];
        System.assertEquals(150, gu.Refunded_Amount__c, 'Cambio a Processed debe sumar');
    }

    // T4: Update Processed → Rejected → Refunded_Amount__c baja a cero
    @IsTest
    static void t4_updateProcessedToRejected_amountDrops() {
        Gift_Transaction__c g = getGift();
        Gift_Refund__c r = new Gift_Refund__c(Gift__c = g.Id, Amount__c = 200, Status__c = 'Processed', Refund_Date__c = Date.today());
        insert r;

        Test.startTest();
        r.Status__c = 'Rejected';
        update r;
        Test.stopTest();

        Gift_Transaction__c gu = [SELECT Refunded_Amount__c FROM Gift_Transaction__c WHERE Id = :g.Id];
        System.assertEquals(0, gu.Refunded_Amount__c, 'Rejected debe quitar el monto');
    }

    // T5: Delete refund Processed → Refunded_Amount__c a cero
    @IsTest
    static void t5_deleteProcessedRefund_amountReset() {
        Gift_Transaction__c g = getGift();
        Gift_Refund__c r = new Gift_Refund__c(Gift__c = g.Id, Amount__c = 75, Status__c = 'Processed', Refund_Date__c = Date.today());
        insert r;

        Test.startTest();
        delete r;
        Test.stopTest();

        Gift_Transaction__c gu = [SELECT Refunded_Amount__c FROM Gift_Transaction__c WHERE Id = :g.Id];
        System.assertEquals(0, gu.Refunded_Amount__c, 'Delete debe quitar el monto');
    }

    // T6: Múltiples refunds Processed → suman correctamente
    @IsTest
    static void t6_multipleProcessedRefunds_sumCorrectly() {
        Gift_Transaction__c g = getGift();

        Test.startTest();
        insert new List<Gift_Refund__c>{
            new Gift_Refund__c(Gift__c = g.Id, Amount__c = 50,  Status__c = 'Processed', Refund_Date__c = Date.today()),
            new Gift_Refund__c(Gift__c = g.Id, Amount__c = 75,  Status__c = 'Processed', Refund_Date__c = Date.today()),
            new Gift_Refund__c(Gift__c = g.Id, Amount__c = 100, Status__c = 'Pending',   Refund_Date__c = Date.today())
        };
        Test.stopTest();

        Gift_Transaction__c gu = [SELECT Refunded_Amount__c FROM Gift_Transaction__c WHERE Id = :g.Id];
        System.assertEquals(125, gu.Refunded_Amount__c, 'Solo los Processed deben sumar');
    }
}
