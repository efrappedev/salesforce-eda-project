@IsTest
private class FundraisingLYBUNTBatchTest {

    @TestSetup
    static void setup() {
        // Three contacts for distinct scenarios
        List<Contact> contacts = new List<Contact>{
            new Contact(LastName = 'C_ThisYear'),   // donated this year → neither flag
            new Contact(LastName = 'C_LastYear'),   // donated last year only → LYBUNT + SYBUNT
            new Contact(LastName = 'C_Older'),      // donated 2 years ago only → SYBUNT only
            new Contact(LastName = 'C_Both')        // donated last year AND this year → neither flag
        };
        insert contacts;
    }

    static Map<String, Id> getContactIds() {
        Map<String, Id> m = new Map<String, Id>();
        for (Contact c : [SELECT Id, LastName FROM Contact]) {
            m.put(c.LastName, c.Id);
        }
        return m;
    }

    @IsTest
    static void t1_lybuntAndSybuntFlagsSetCorrectly() {
        Map<String, Id> ids = getContactIds();
        Integer yr = Date.today().year();

        List<Gift_Transaction__c> gifts = new List<Gift_Transaction__c>{
            // C_ThisYear: gift this year
            new Gift_Transaction__c(
                Donor__c  = ids.get('C_ThisYear'),
                Amount__c = 100, Status__c = 'Received',
                Gift_Date__c = Date.newInstance(yr, 1, 15)
            ),
            // C_LastYear: gift last year only
            new Gift_Transaction__c(
                Donor__c  = ids.get('C_LastYear'),
                Amount__c = 100, Status__c = 'Received',
                Gift_Date__c = Date.newInstance(yr - 1, 6, 1)
            ),
            // C_Older: gift 2 years ago only
            new Gift_Transaction__c(
                Donor__c  = ids.get('C_Older'),
                Amount__c = 100, Status__c = 'Received',
                Gift_Date__c = Date.newInstance(yr - 2, 6, 1)
            ),
            // C_Both: gift last year AND this year
            new Gift_Transaction__c(
                Donor__c  = ids.get('C_Both'),
                Amount__c = 100, Status__c = 'Received',
                Gift_Date__c = Date.newInstance(yr - 1, 3, 1)
            ),
            new Gift_Transaction__c(
                Donor__c  = ids.get('C_Both'),
                Amount__c = 100, Status__c = 'Received',
                Gift_Date__c = Date.newInstance(yr, 2, 1)
            )
        };
        insert gifts;

        Test.startTest();
        Database.executeBatch(new FundraisingLYBUNTBatch(), 200);
        Test.stopTest();

        Map<Id, Contact> result = new Map<Id, Contact>([
            SELECT Id, LastName, LYBUNT__c, SYBUNT__c FROM Contact
        ]);

        Contact cThisYear = result.get(ids.get('C_ThisYear'));
        Contact cLastYear = result.get(ids.get('C_LastYear'));
        Contact cOlder    = result.get(ids.get('C_Older'));
        Contact cBoth     = result.get(ids.get('C_Both'));

        // Donated this year → neither flag
        System.assertEquals(false, cThisYear.LYBUNT__c, 'C_ThisYear: no LYBUNT');
        System.assertEquals(false, cThisYear.SYBUNT__c, 'C_ThisYear: no SYBUNT');

        // Donated last year only → LYBUNT (also SYBUNT since donated prior to this year)
        System.assertEquals(true,  cLastYear.LYBUNT__c, 'C_LastYear: LYBUNT=true');
        System.assertEquals(true,  cLastYear.SYBUNT__c, 'C_LastYear: SYBUNT=true');

        // Donated 2 years ago only → SYBUNT only (not LYBUNT since didn't donate last year)
        System.assertEquals(false, cOlder.LYBUNT__c, 'C_Older: no LYBUNT');
        System.assertEquals(true,  cOlder.SYBUNT__c, 'C_Older: SYBUNT=true');

        // Donated both last year and this year → neither flag
        System.assertEquals(false, cBoth.LYBUNT__c, 'C_Both: no LYBUNT');
        System.assertEquals(false, cBoth.SYBUNT__c, 'C_Both: no SYBUNT');
    }

    @IsTest
    static void t2_schedulable_executesWithoutError() {
        Test.startTest();
        System.schedule('Test LYBUNT', '0 0 2 * * ?', new FundraisingLYBUNTBatch());
        Test.stopTest();
        // No assertion needed — test passes if no exception thrown
    }

    @IsTest
    static void t3_voidedGift_doesNotTriggerFlags() {
        Map<String, Id> ids = getContactIds();
        Integer yr = Date.today().year();

        // Insert a Voided gift from last year — should NOT set LYBUNT
        insert new Gift_Transaction__c(
            Donor__c     = ids.get('C_LastYear'),
            Amount__c    = 100,
            Status__c    = 'Voided',
            Gift_Date__c = Date.newInstance(yr - 1, 6, 1)
        );

        Test.startTest();
        Database.executeBatch(new FundraisingLYBUNTBatch(), 200);
        Test.stopTest();

        Contact c = [SELECT LYBUNT__c, SYBUNT__c FROM Contact WHERE LastName = 'C_LastYear'];
        System.assertEquals(false, c.LYBUNT__c, 'Voided no debe activar LYBUNT');
        System.assertEquals(false, c.SYBUNT__c, 'Voided no debe activar SYBUNT');
    }
}
