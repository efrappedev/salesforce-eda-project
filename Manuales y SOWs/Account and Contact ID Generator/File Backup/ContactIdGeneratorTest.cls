@IsTest(SeeAllData=false)
private class ContactIdGeneratorTest {

    // ========= Helpers =========

    private static Boolean isNotBlank(String s) { return s != null && s.trim().length() > 0; }

    private static String uniq() {
        return DateTime.now().getTime() + '-' + String.valueOf(Crypto.getRandomInteger());
    }

    private static Boolean allAZ(String s, Integer fromIdx, Integer toExclusive) {
        for (Integer i = fromIdx; i < toExclusive; i++) {
            String ch = s.substring(i, i + 1);
            if (ch < 'A' || ch > 'Z') return false;
        }
        return true;
    }

    private static Boolean allDigits(String s, Integer fromIdx, Integer toExclusive) {
        for (Integer i = fromIdx; i < toExclusive; i++) {
            String ch = s.substring(i, i + 1);
            if (ch < '0' || ch > '9') return false;
        }
        return true;
    }

    private static void assertContactIdFormat(String v) {
        System.assert(isNotBlank(v), 'ID_Contact__c blank');
        System.assert(v.length() <= 20, 'ID_Contact__c length > 20');
        System.assert(v.length() >= 8,  'ID_Contact__c too short');
        System.assert(allAZ(v, 0, 4),              'First 4 must be A-Z');
        System.assert(allDigits(v, 4, v.length()), 'Tail must be digits');
    }

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

    // ========= Tests =========

    // 1) Bulk insert 12 contactos — verifica formato de ID_Contact__c
    @IsTest
    static void contactTrigger_Bulk_IdFormat() {
        String U = uniq();
        List<Contact> cs = new List<Contact>();
        for (Integer i = 0; i < 12; i++) {
            cs.add(new Contact(FirstName = 'Nico' + i + U, LastName = 'Garcia' + i + U));
        }
        Database.DMLOptions dmo = new Database.DMLOptions();
        applyDupBypass(dmo);
        Database.SaveResult[] srs = Database.insert(cs, dmo);
        for (Database.SaveResult sr : srs) {
            System.assert(sr.isSuccess(),
                'Contact bulk insert failed: ' +
                (sr.getErrors().isEmpty() ? 'unknown' : sr.getErrors()[0].getMessage()));
        }
        List<Contact> got = [SELECT Id, ID_Contact__c FROM Contact WHERE Id IN :cs];
        System.assertEquals(cs.size(), got.size(), 'Contacts inserted must be queryable');
        for (Contact c : got) assertContactIdFormat(c.ID_Contact__c);
    }

    // 2) 2 contactos con apellidos alfabéticos simples — verifica formato
    @IsTest
    static void contactTrigger_Bulk_IdFormat_Short() {
        String U = uniq();
        List<Contact> cs = new List<Contact>{
            new Contact(FirstName = 'Ana',  LastName = 'Perez' + U),
            new Contact(FirstName = 'Beto', LastName = 'Bravo' + U)
        };
        for (Contact c : cs) insertContactResilient(c);
        List<Contact> got = [SELECT Id, ID_Contact__c FROM Contact WHERE Id IN :cs];
        for (Contact c : got) assertContactIdFormat(c.ID_Contact__c);
    }

    // 3) Seed con mismo prefijo → segundo insert cubre el inner loop de búsqueda de máximo (líneas 119-133)
    @IsTest
    static void contactTrigger_SequenceIncrement() {
        String U = uniq();
        // LastName 'Per'+U → ln3='PER'; FirstName 'Ana' → fn1='A' → prefijo 'PERA'
        Contact seed = insertContactResilient(new Contact(FirstName = 'Ana', LastName = 'Per' + U));
        seed = [SELECT ID_Contact__c FROM Contact WHERE Id = :seed.Id LIMIT 1];
        assertContactIdFormat(seed.ID_Contact__c);
        System.assert(seed.ID_Contact__c.startsWith('PERA'), 'Seed prefix must be PERA, got: ' + seed.ID_Contact__c);

        // Segundo contacto con idéntico prefijo PERA: el trigger encuentra seed en la query SOQL
        // → el inner loop (líneas 119-133) ejecuta → extrae el número → asigna PERA000X+1
        Contact second = insertContactResilient(new Contact(FirstName = 'Alice', LastName = 'Per' + U));
        second = [SELECT ID_Contact__c FROM Contact WHERE Id = :second.Id LIMIT 1];
        assertContactIdFormat(second.ID_Contact__c);
        System.assert(second.ID_Contact__c.startsWith('PERA'), 'Second prefix must also be PERA, got: ' + second.ID_Contact__c);
        System.assertNotEquals(seed.ID_Contact__c, second.ID_Contact__c, 'Sequence must increment');
        Integer numSeed   = Integer.valueOf(seed.ID_Contact__c.substring(4));
        Integer numSecond = Integer.valueOf(second.ID_Contact__c.substring(4));
        System.assert(numSecond > numSeed, 'Second sequence (' + numSecond + ') must exceed seed (' + numSeed + ')');
    }
}