@isTest
private class RegenerateIdControllerTest {

    private static void applyDupBypass(Database.DMLOptions dmo) {
        dmo.DuplicateRuleHeader.allowSave = true;
        dmo.DuplicateRuleHeader.runAsCurrentUser = true;
    }

    private static Contact insertContactResilient(Contact c) {
        Database.DMLOptions dmo = new Database.DMLOptions();
        applyDupBypass(dmo);
        Database.SaveResult sr = Database.insert(new List<SObject>{ c }, dmo)[0];
        System.assert(sr.isSuccess(), 'Contact insert failed: ' +
            (sr.getErrors().isEmpty() ? 'unknown' : sr.getErrors()[0].getMessage()));
        c.Id = sr.getId();
        return c;
    }

    @isTest
    static void testPreviewContactIdRegeneration_passthroughSuccess() {
        Contact c = insertContactResilient(new Contact(FirstName = 'Rita', LastName = 'Quixote'));
        update new Contact(Id = c.Id, ID_Contact__c = null);

        Test.startTest();
        Map<Id, String> result = RegenerateIdController.previewContactIdRegeneration(new List<Id>{ c.Id });
        Test.stopTest();

        System.assert(result.containsKey(c.Id), 'Controller should pass through the service result for a regenerable contact');
        System.assert(result.get(c.Id).startsWith('QUIR'), 'Expected prefix QUIR, got: ' + result.get(c.Id));
    }

    @isTest
    static void testPreviewContactIdRegeneration_nullList_returnsEmptyMap() {
        Test.startTest();
        Map<Id, String> result = RegenerateIdController.previewContactIdRegeneration(null);
        Test.stopTest();

        System.assert(result.isEmpty(), 'A null contactIds list should not throw and should return an empty map');
    }

    @isTest
    static void testPreviewContactIdRegeneration_forcedException_throws() {
        RegenerateIdService.TEST_FORCE_SERVICE_EXCEPTION = true;
        Boolean threw = false;
        try {
            RegenerateIdController.previewContactIdRegeneration(new List<Id>{ UserInfo.getUserId() });
        } catch (AuraHandledException ex) {
            threw = true;
        } finally {
            RegenerateIdService.TEST_FORCE_SERVICE_EXCEPTION = false;
        }
        System.assert(threw, 'Expected the forced service exception to surface as an AuraHandledException');
    }
}
