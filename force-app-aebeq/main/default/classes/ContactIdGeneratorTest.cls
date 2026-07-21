@IsTest(SeeAllData=false)
private class ContactIdGeneratorTest {

    private static Boolean isNotBlank(String s) { return s != null && s.trim().length() > 0; }

    private static String uniq() {
        return String.valueOf(DateTime.now().getTime()) + String.valueOf(Crypto.getRandomInteger());
    }

    private static Boolean allAZ(String s, Integer startIdx, Integer endIdx) {
        for (Integer i = startIdx; i < endIdx; i++) {
            String ch = s.substring(i, i + 1);
            if (ch < 'A' || ch > 'Z') return false;
        }
        return true;
    }

    private static Boolean allDigits(String s, Integer startIdx, Integer endIdx) {
        for (Integer i = startIdx; i < endIdx; i++) {
            String ch = s.substring(i, i + 1);
            if (ch < '0' || ch > '9') return false;
        }
        return true;
    }

    // Format for regular contacts: TREMA0001 (4 A-Z + digits)
    private static void assertContactIdFormat(String v) {
        System.assert(isNotBlank(v), 'ID_Contact__c is blank');
        System.assert(v.length() >= 8, 'ID_Contact__c too short: ' + v);
        System.assert(v.length() <= 20, 'ID_Contact__c too long: ' + v);
        System.assert(allAZ(v, 0, 4), 'First 4 chars must be A-Z, got: ' + v);
        System.assert(allDigits(v, 4, v.length()), 'Tail must be digits, got: ' + v);
    }

    // Format for shadow contacts (mirrors PersonAccount ID): I-BROA0001 — "I-" + 4 A-Z + digits
    private static void assertPersonContactId(String v) {
        System.assert(isNotBlank(v), 'Shadow contact ID is blank');
        System.assert(v.startsWith('I-'), 'Shadow contact ID must start with I-, got: ' + v);
        System.assert(v.length() >= 10, 'Shadow contact ID too short: ' + v);
        System.assert(v.length() <= 20, 'Shadow contact ID too long: ' + v);
        System.assert(allAZ(v, 2, 6), 'Chars 3-6 must be A-Z, got: ' + v);
        System.assert(allDigits(v, 6, v.length()), 'Tail must be digits, got: ' + v);
    }

    private static void applyDupBypass(Database.DMLOptions dmo) {
        dmo.DuplicateRuleHeader.allowSave = true;
        dmo.DuplicateRuleHeader.runAsCurrentUser = true;
    }

    private static Account insertPersonAccount(String lastName, String firstName) {
        Database.DMLOptions dmo = new Database.DMLOptions();
        applyDupBypass(dmo);
        Id rtPA = [SELECT Id FROM RecordType WHERE SobjectType='Account' AND DeveloperName='PersonAccount' LIMIT 1].Id;
        Account a = new Account(RecordTypeId=rtPA, LastName=lastName, FirstName=firstName);
        Database.SaveResult sr = Database.insert(new List<SObject>{a}, dmo)[0];
        System.assert(sr.isSuccess(), 'PersonAccount insert failed: ' +
            (sr.getErrors().isEmpty() ? 'unknown' : sr.getErrors()[0].getMessage()));
        a.Id = sr.getId();
        return a;
    }

    private static Contact insertContact(Contact c) {
        Database.DMLOptions dmo = new Database.DMLOptions();
        applyDupBypass(dmo);
        Database.SaveResult sr = Database.insert(new List<SObject>{c}, dmo)[0];
        System.assert(sr.isSuccess(), 'Contact insert failed: ' +
            (sr.getErrors().isEmpty() ? 'unknown' : sr.getErrors()[0].getMessage()));
        c.Id = sr.getId();
        return c;
    }

    // 1) PersonAccount → shadow Contact gets ID_Contact__c = Account.ID_Account__c (inverted flow)
    @IsTest
    static void shadowContact_MirrorsAccountId() {
        String U = uniq();
        Account pa = insertPersonAccount('Brown' + U, 'Alice');
        pa = [SELECT ID_Account__c, PersonContactId FROM Account WHERE Id = :pa.Id LIMIT 1];

        System.assert(isNotBlank(pa.ID_Account__c), 'Account must have ID_Account__c after insert');
        System.assert(pa.PersonContactId != null, 'PersonContactId must be set');

        Contact shadowContact = [SELECT ID_Contact__c FROM Contact WHERE Id = :pa.PersonContactId LIMIT 1];
        System.assertEquals(pa.ID_Account__c, shadowContact.ID_Contact__c,
            'Shadow Contact.ID_Contact__c must equal Account.ID_Account__c');
    }

    // 2) Shadow Contact prefix matches Account prefix (derived from name)
    @IsTest
    static void shadowContact_PrefixMatchesAccountName() {
        String U = uniq();
        Account pa = insertPersonAccount('Hébert' + U, 'Éric');
        pa = [SELECT ID_Account__c, PersonContactId FROM Account WHERE Id = :pa.Id LIMIT 1];

        assertPersonContactId(pa.ID_Account__c);
        System.assert(pa.ID_Account__c.startsWith('I-HEB'), 'Hébert → I-HEB, got: ' + pa.ID_Account__c);
        System.assert(pa.ID_Account__c.substring(5,6) == 'E', 'Éric → E at pos 6, got: ' + pa.ID_Account__c);

        Contact shadow = [SELECT ID_Contact__c FROM Contact WHERE Id = :pa.PersonContactId LIMIT 1];
        System.assertEquals(pa.ID_Account__c, shadow.ID_Contact__c, 'Shadow must mirror Account ID');
    }

    // 3) Regular Contact (standalone, no Account) → gets name-based ID_Contact__c
    @IsTest
    static void regularContact_StandaloneId() {
        String U = uniq();
        Contact c = insertContact(new Contact(LastName='Tremblay'+U, FirstName='Marie'));
        c = [SELECT ID_Contact__c FROM Contact WHERE Id = :c.Id LIMIT 1];
        assertContactIdFormat(c.ID_Contact__c);
        System.assert(c.ID_Contact__c.startsWith('TRE'), 'Tremblay → TRE, got: ' + c.ID_Contact__c);
        System.assert(c.ID_Contact__c.substring(3,4) == 'M', 'Marie → M, got: ' + c.ID_Contact__c);
    }

    // 4) Regular Contact linked to Business_Account → independent name-based ID (not mirrored)
    @IsTest
    static void regularContact_LinkedToBusinessAccount_OwnId() {
        String U = uniq();
        Id rtBUS = [SELECT Id FROM RecordType WHERE SobjectType='Account' AND DeveloperName='Business_Account' LIMIT 1].Id;
        Account biz = new Account(Name='Biz Test '+U, RecordTypeId=rtBUS);
        Database.DMLOptions dmo = new Database.DMLOptions();
        applyDupBypass(dmo);
        Database.insert(new List<SObject>{biz}, dmo);

        Contact c = insertContact(new Contact(LastName='Roy'+U, FirstName='Jean', AccountId=biz.Id));
        c = [SELECT ID_Contact__c FROM Contact WHERE Id = :c.Id LIMIT 1];
        assertContactIdFormat(c.ID_Contact__c);
        System.assert(c.ID_Contact__c.startsWith('ROY'), 'Roy → ROY, got: ' + c.ID_Contact__c);

        biz = [SELECT ID_Account__c FROM Account WHERE Id = :biz.Id LIMIT 1];
        System.assertNotEquals(biz.ID_Account__c, c.ID_Contact__c,
            'Regular contact must NOT mirror Business Account ID');
    }

    // 5) Regular Contact sequence increment: 2 contacts same prefix → unique sequential IDs
    @IsTest
    static void regularContact_SequenceIncrement() {
        String U = uniq();
        Contact c1 = insertContact(new Contact(LastName='Dupont'+U, FirstName='Marc'));
        Contact c2 = insertContact(new Contact(LastName='Dupont'+U, FirstName='Michel'));
        c1 = [SELECT ID_Contact__c FROM Contact WHERE Id = :c1.Id LIMIT 1];
        c2 = [SELECT ID_Contact__c FROM Contact WHERE Id = :c2.Id LIMIT 1];
        assertContactIdFormat(c1.ID_Contact__c);
        assertContactIdFormat(c2.ID_Contact__c);
        System.assertNotEquals(c1.ID_Contact__c, c2.ID_Contact__c, 'Must get different IDs');
        Integer n1 = Integer.valueOf(c1.ID_Contact__c.substring(4));
        Integer n2 = Integer.valueOf(c2.ID_Contact__c.substring(4));
        System.assert(n2 > n1, 'Second sequence (' + n2 + ') must exceed first (' + n1 + ')');
    }

    // 6) Shadow + Regular with same name prefix → separate formats, separate sequences
    //    Shadow gets I-BROA* (mirrors Account ID); Regular gets BROA* (independent sequence)
    //    Because shadow ID starts with "I-", it does NOT appear in the regular contact's LIKE 'BROA%' query.
    @IsTest
    static void shadowAndRegular_SamePrefix_SchemesAreIndependent() {
        String U = uniq();
        Account pa = insertPersonAccount('Brown'+U, 'Alice');
        pa = [SELECT ID_Account__c, PersonContactId FROM Account WHERE Id = :pa.Id LIMIT 1];
        assertPersonContactId(pa.ID_Account__c);
        System.assert(pa.ID_Account__c.startsWith('I-BRO'), 'Brown → I-BRO prefix');

        Contact shadow = [SELECT ID_Contact__c FROM Contact WHERE Id = :pa.PersonContactId LIMIT 1];
        System.assertEquals(pa.ID_Account__c, shadow.ID_Contact__c, 'Shadow mirrors Account ID');

        // Regular contact with same name: gets BROA* format (no I-), independent from shadow's I-BROA* sequence
        Contact regular = insertContact(new Contact(LastName='Brown'+U, FirstName='Andrew'));
        regular = [SELECT ID_Contact__c FROM Contact WHERE Id = :regular.Id LIMIT 1];
        assertContactIdFormat(regular.ID_Contact__c);
        System.assert(regular.ID_Contact__c.startsWith('BROA'), 'Regular Brown/Andrew → BROA (no I-)');
        System.assertNotEquals(shadow.ID_Contact__c, regular.ID_Contact__c, 'Shadow and regular must have different IDs');
    }
}
