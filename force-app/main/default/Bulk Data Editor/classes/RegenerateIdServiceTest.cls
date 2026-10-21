@isTest
private class RegenerateIdServiceTest {

    // Contact_GenerateID.trigger only fires on before-insert, so every
    // inserted Contact below already gets an ID_Contact__c auto-assigned by
    // the existing org trigger. Clearing it afterwards via update (which the
    // trigger does NOT listen for) reproduces the real workflow this feature
    // targets: user blanks the field, then needs it regenerated on demand.
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

    private static void clearIdContact(Id contactId) {
        update new Contact(Id = contactId, ID_Contact__c = null);
    }

    // ---------------------------------------------------------------

    @isTest
    static void testComputeNewContactIds_emptySet_returnsEmptyMap() {
        Test.startTest();
        Map<Id, String> result = RegenerateIdService.computeNewContactIds(new Set<Id>());
        Test.stopTest();

        System.assert(result.isEmpty(), 'An empty input set should return an empty map');
    }

    @isTest
    static void testComputeNewContactIds_nullSet_returnsEmptyMap() {
        Test.startTest();
        Map<Id, String> result = RegenerateIdService.computeNewContactIds(null);
        Test.stopTest();

        System.assert(result.isEmpty(), 'A null input set should return an empty map, not throw');
    }

    @isTest
    static void testComputeNewContactIds_nonexistentId_returnsEmptyMap() {
        Id fakeId = (Id) '003000000000001AAA';

        Test.startTest();
        Map<Id, String> result = RegenerateIdService.computeNewContactIds(new Set<Id>{ fakeId });
        Test.stopTest();

        System.assert(result.isEmpty(), 'An Id that matches no Contact should be silently omitted, not throw');
    }

    @isTest
    static void testComputeNewContactIds_sequentialAndCollisionSafe_respectsExistingMax() {
        // Seed: keeps its trigger-assigned ID_Contact__c intact, so it
        // represents the "existing max already in the org" for this prefix.
        Contact seed = insertContactResilient(new Contact(FirstName = 'Amy', LastName = 'Zyxridge'));
        seed = [SELECT ID_Contact__c FROM Contact WHERE Id = :seed.Id LIMIT 1];
        Integer seedNum = Integer.valueOf(seed.ID_Contact__c.substring(4));

        // Two more Contacts sharing the exact same prefix (LastName 'Zyx' ->
        // ln3='ZYX', FirstName starting with 'A' -> fn1='A'), inserted in the
        // same DML so the trigger itself would already have to collision-
        // avoid between them — then both are cleared to simulate the user
        // blanking the field before asking for regeneration.
        Contact c1 = new Contact(FirstName = 'Amanda', LastName = 'Zyxridge');
        Contact c2 = new Contact(FirstName = 'Amos', LastName = 'Zyxridge');
        Database.DMLOptions dmo = new Database.DMLOptions();
        applyDupBypass(dmo);
        Database.SaveResult[] srs = Database.insert(new List<Contact>{ c1, c2 }, dmo);
        for (Database.SaveResult sr : srs) {
            System.assert(sr.isSuccess(), 'Bulk contact insert failed');
        }
        clearIdContact(srs[0].getId());
        clearIdContact(srs[1].getId());

        Test.startTest();
        Map<Id, String> result = RegenerateIdService.computeNewContactIds(new Set<Id>{ srs[0].getId(), srs[1].getId() });
        Test.stopTest();

        System.assertEquals(2, result.size(), 'Both cleared contacts should get a regenerated value');
        String v1 = result.get(srs[0].getId());
        String v2 = result.get(srs[1].getId());
        System.assert(v1.startsWith('ZYXA'), 'Expected prefix ZYXA, got: ' + v1);
        System.assert(v2.startsWith('ZYXA'), 'Expected prefix ZYXA, got: ' + v2);
        System.assertNotEquals(v1, v2, 'Two contacts sharing a prefix in the same call must not collide');

        Integer num1 = Integer.valueOf(v1.substring(4));
        Integer num2 = Integer.valueOf(v2.substring(4));
        System.assert(num1 > seedNum, 'Regenerated sequence must continue past the existing org max, not restart from it');
        System.assert(num2 > seedNum, 'Regenerated sequence must continue past the existing org max, not restart from it');
    }

    @isTest
    static void testComputeNewContactIds_ignoresShortAndMalformedExistingIds() {
        // Real, trigger-assigned baseline for prefix "WOVB" — the true
        // existing max findMaxSequenceByPrefix must still find and respect.
        Contact good = insertContactResilient(new Contact(FirstName = 'Bea', LastName = 'Wovoxen'));
        good = [SELECT ID_Contact__c FROM Contact WHERE Id = :good.Id LIMIT 1];
        Integer goodNum = Integer.valueOf(good.ID_Contact__c.substring(4));

        // Two "polluting" existing records sharing the same prefix, hand-set
        // (bypassing the insert-only trigger) to the two shapes
        // findMaxSequenceByPrefix must tolerate without throwing or
        // corrupting the sequence: an old-format short Id with no sequence
        // digits at all (< 5 chars — hits the length guard/continue), and a
        // malformed non-numeric suffix (hits the try/catch around
        // Integer.valueOf).
        Contact shortId = insertContactResilient(new Contact(FirstName = 'Bianca', LastName = 'Wovoxen'));
        update new Contact(Id = shortId.Id, ID_Contact__c = 'WOVB');
        Contact malformedId = insertContactResilient(new Contact(FirstName = 'Bruno', LastName = 'Wovoxen'));
        update new Contact(Id = malformedId.Id, ID_Contact__c = 'WOVBXXXX');

        Contact target = insertContactResilient(new Contact(FirstName = 'Beto', LastName = 'Wovoxen'));
        clearIdContact(target.Id);

        Test.startTest();
        Map<Id, String> result = RegenerateIdService.computeNewContactIds(new Set<Id>{ target.Id });
        Test.stopTest();

        String newId = result.get(target.Id);
        System.assert(newId != null && newId.startsWith('WOVB'), 'Expected prefix WOVB, got: ' + newId);
        Integer newNum = Integer.valueOf(newId.substring(4));
        System.assert(newNum > goodNum, 'Sequence must continue past the real existing max, ignoring the short/malformed polluting records');
    }

    @isTest
    static void testComputeNewContactIds_blankFirstName_skipped() {
        Contact c = insertContactResilient(new Contact(FirstName = null, LastName = 'Norname'));
        clearIdContact(c.Id);

        Test.startTest();
        Map<Id, String> result = RegenerateIdService.computeNewContactIds(new Set<Id>{ c.Id });
        Test.stopTest();

        System.assert(!result.containsKey(c.Id), 'A Contact with a blank FirstName cannot form a usable prefix and must be omitted');
    }

    @isTest
    static void testComputeNewContactIds_accentedCharacters_normalized() {
        Contact c = insertContactResilient(new Contact(FirstName = 'Óscar', LastName = 'Núñez'));
        clearIdContact(c.Id);

        Test.startTest();
        Map<Id, String> result = RegenerateIdService.computeNewContactIds(new Set<Id>{ c.Id });
        Test.stopTest();

        System.assert(result.containsKey(c.Id), 'Accented First/Last Name should still produce a usable prefix');
        System.assert(result.get(c.Id).startsWith('NUNO'), 'Expected accent-normalized prefix NUNO, got: ' + result.get(c.Id));
    }

    @isTest
    static void testComputeNewContactIds_forcedException_throws() {
        RegenerateIdService.TEST_FORCE_SERVICE_EXCEPTION = true;
        Boolean threw = false;
        try {
            RegenerateIdService.computeNewContactIds(new Set<Id>{ UserInfo.getUserId() });
        } catch (BulkEditException ex) {
            threw = true;
        } finally {
            RegenerateIdService.TEST_FORCE_SERVICE_EXCEPTION = false;
        }
        System.assert(threw, 'Expected the forced service exception to surface');
    }
}
