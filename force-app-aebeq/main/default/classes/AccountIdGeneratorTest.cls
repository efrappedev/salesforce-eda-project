@IsTest(SeeAllData=false)
private class AccountIdGeneratorTest {

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

    private static void assertOrgId(String v, String prefix) {
        System.assert(isNotBlank(v), 'ID is blank for prefix ' + prefix);
        System.assert(v.startsWith(prefix), 'Must start with ' + prefix + ', got: ' + v);
        System.assertEquals(prefix.length() + 7, v.length(), 'Length must be prefix + 7 digits, got: ' + v);
        System.assert(allDigits(v, prefix.length(), v.length()), 'Tail must be 7 digits, got: ' + v);
    }

    private static void assertPersonId(String v) {
        // Expected format: I-BROA0001 — prefix "I-" + 3 A-Z (last) + 1 A-Z (first) + 4+ digits
        System.assert(isNotBlank(v), 'PersonAccount ID is blank');
        System.assert(v.startsWith('I-'), 'PersonAccount ID must start with I-, got: ' + v);
        System.assert(v.length() >= 10, 'PersonAccount ID too short: ' + v);
        System.assert(v.length() <= 20, 'PersonAccount ID too long: ' + v);
        System.assert(allAZ(v, 2, 6), 'Chars 3-6 must be A-Z (name prefix), got: ' + v);
        System.assert(allDigits(v, 6, v.length()), 'Tail must be digits, got: ' + v);
    }

    private static void applyDupBypass(Database.DMLOptions dmo) {
        dmo.DuplicateRuleHeader.allowSave = true;
        dmo.DuplicateRuleHeader.runAsCurrentUser = true;
    }

    private static Account insertResilient(Account a) {
        Database.DMLOptions dmo = new Database.DMLOptions();
        applyDupBypass(dmo);
        Database.SaveResult sr = Database.insert(new List<SObject>{ a }, dmo)[0];
        System.assert(sr.isSuccess(), 'Insert failed: ' +
            (sr.getErrors().isEmpty() ? 'unknown' : sr.getErrors()[0].getMessage()));
        a.Id = sr.getId();
        return a;
    }

    private static Id rtId(String devName) {
        RecordType rt = [SELECT Id FROM RecordType WHERE SobjectType='Account' AND DeveloperName=:devName LIMIT 1];
        return rt.Id;
    }

    // 1) PersonAccount → name-based ID (BROA0001 format)
    @IsTest
    static void personAccount_NameBasedId_Format() {
        String U = uniq();
        Account a = insertResilient(new Account(
            RecordTypeId = rtId('PersonAccount'),
            LastName = 'Brown' + U,
            FirstName = 'Alex'
        ));
        a = [SELECT ID_Account__c FROM Account WHERE Id = :a.Id LIMIT 1];
        assertPersonId(a.ID_Account__c);
        System.assert(a.ID_Account__c.startsWith('I-BRO'), 'Prefix must derive from LastName "Brown", got: ' + a.ID_Account__c);
        System.assert(a.ID_Account__c.substring(5, 6) == 'A', 'Char 6 must derive from FirstName "Alex", got: ' + a.ID_Account__c);
    }

    // 2) PersonAccount with accented name → normalized prefix
    @IsTest
    static void personAccount_AccentedName_Normalized() {
        String U = uniq();
        Account a = insertResilient(new Account(
            RecordTypeId = rtId('PersonAccount'),
            LastName = 'Hébert' + U,
            FirstName = 'Élodie'
        ));
        a = [SELECT ID_Account__c FROM Account WHERE Id = :a.Id LIMIT 1];
        assertPersonId(a.ID_Account__c);
        System.assert(a.ID_Account__c.startsWith('I-HEB'), 'Hébert → I-HEB, got: ' + a.ID_Account__c);
        System.assert(a.ID_Account__c.substring(5, 6) == 'E', 'Élodie → E at pos 6, got: ' + a.ID_Account__c);
    }

    // 3) PersonAccount sequence increment: 2 people same prefix → different IDs
    @IsTest
    static void personAccount_SequenceIncrement() {
        String U = uniq();
        Id rtPA = rtId('PersonAccount');
        Account a1 = insertResilient(new Account(RecordTypeId=rtPA, LastName='Dupont'+U, FirstName='Marie'));
        Account a2 = insertResilient(new Account(RecordTypeId=rtPA, LastName='Dupont'+U, FirstName='Marc'));
        a1 = [SELECT ID_Account__c FROM Account WHERE Id = :a1.Id LIMIT 1];
        a2 = [SELECT ID_Account__c FROM Account WHERE Id = :a2.Id LIMIT 1];
        assertPersonId(a1.ID_Account__c);
        assertPersonId(a2.ID_Account__c);
        System.assertNotEquals(a1.ID_Account__c, a2.ID_Account__c, 'Must get different IDs');
        Integer n1 = Integer.valueOf(a1.ID_Account__c.substring(6));  // skip "I-DUPM" prefix
        Integer n2 = Integer.valueOf(a2.ID_Account__c.substring(6));
        System.assert(n2 > n1, 'Second sequence (' + n2 + ') must exceed first (' + n1 + ')');
    }

    // 4) PersonAccount: update name does NOT reset ID (immutable)
    @IsTest
    static void personAccount_IdImmutableOnUpdate() {
        String U = uniq();
        Account a = insertResilient(new Account(RecordTypeId=rtId('PersonAccount'), LastName='Roy'+U, FirstName='Jean'));
        a = [SELECT ID_Account__c FROM Account WHERE Id=:a.Id LIMIT 1];
        String orig = a.ID_Account__c;
        System.assert(isNotBlank(orig), 'Must have ID after insert');
        Database.DMLOptions dmo = new Database.DMLOptions();
        applyDupBypass(dmo);
        a.LastName = 'Smith' + U;
        System.assert(Database.update(new List<SObject>{a}, dmo)[0].isSuccess(), 'Update must succeed');
        a = [SELECT ID_Account__c FROM Account WHERE Id=:a.Id LIMIT 1];
        System.assertEquals(orig, a.ID_Account__c, 'ID must not change after update');
    }

    // 5) Eglise → EGL + 7 digits
    @IsTest
    static void eglise_PrefixFormat() {
        String U = uniq();
        Account a = insertResilient(new Account(Name='Eglise Test '+U, RecordTypeId=rtId('Eglise')));
        a = [SELECT ID_Account__c FROM Account WHERE Id=:a.Id LIMIT 1];
        assertOrgId(a.ID_Account__c, 'EGL');
    }

    // 6) Org_Business_Account (label "Business Account") → BUS + 7 digits
    @IsTest
    static void orgBusinessAccount_PrefixFormat() {
        String U = uniq();
        Account a = insertResilient(new Account(Name='Business Test '+U, RecordTypeId=rtId('Org_Business_Account')));
        a = [SELECT ID_Account__c FROM Account WHERE Id=:a.Id LIMIT 1];
        assertOrgId(a.ID_Account__c, 'BUS');
    }

    // 7) Business_Account (label "Organization Business Account") → ORG + 7 digits
    @IsTest
    static void businessAccount_PrefixFormat() {
        String U = uniq();
        Account a = insertResilient(new Account(Name='Org Test '+U, RecordTypeId=rtId('Business_Account')));
        a = [SELECT ID_Account__c FROM Account WHERE Id=:a.Id LIMIT 1];
        assertOrgId(a.ID_Account__c, 'ORG');
    }

    // 8) Household → HOU + 7 digits
    @IsTest
    static void household_PrefixFormat() {
        String U = uniq();
        Account a = insertResilient(new Account(Name='Household Test '+U, RecordTypeId=rtId('Household')));
        a = [SELECT ID_Account__c FROM Account WHERE Id=:a.Id LIMIT 1];
        assertOrgId(a.ID_Account__c, 'HOU');
    }

    // 9) Bulk PersonAccount: 5 people in one DML → all get unique valid IDs
    @IsTest
    static void personAccount_BulkInsert_UniqueIds() {
        String U = uniq();
        Id rtPA = rtId('PersonAccount');
        List<Account> accs = new List<Account>();
        for (Integer i = 0; i < 5; i++) {
            accs.add(new Account(RecordTypeId=rtPA, LastName='Tremblay'+i+U, FirstName='Test'));
        }
        Database.DMLOptions dmo = new Database.DMLOptions();
        applyDupBypass(dmo);
        Database.SaveResult[] srs = Database.insert(accs, dmo);
        for (Database.SaveResult sr : srs) {
            System.assert(sr.isSuccess(), 'Bulk insert must succeed: ' +
                (sr.getErrors().isEmpty() ? 'unknown' : sr.getErrors()[0].getMessage()));
        }
        Set<String> ids = new Set<String>();
        for (Account a : [SELECT ID_Account__c FROM Account WHERE Id IN :accs]) {
            assertPersonId(a.ID_Account__c);
            System.assert(!ids.contains(a.ID_Account__c), 'Duplicate ID: ' + a.ID_Account__c);
            ids.add(a.ID_Account__c);
        }
    }

    // 10) Org sequence continuity: seed existing → inner loop of maxByPrefix executes
    @IsTest
    static void eglise_SequenceContinuity_InnerLoop() {
        String U = uniq();
        Id rtEgl = rtId('Eglise');
        Account seed = insertResilient(new Account(Name='Eglise Seed '+U, RecordTypeId=rtEgl));
        seed = [SELECT ID_Account__c FROM Account WHERE Id=:seed.Id LIMIT 1];
        assertOrgId(seed.ID_Account__c, 'EGL');
        Integer seedSeq = Integer.valueOf(seed.ID_Account__c.substring(3));

        Account next = insertResilient(new Account(Name='Eglise Next '+U, RecordTypeId=rtEgl));
        next = [SELECT ID_Account__c FROM Account WHERE Id=:next.Id LIMIT 1];
        assertOrgId(next.ID_Account__c, 'EGL');
        Integer nextSeq = Integer.valueOf(next.ID_Account__c.substring(3));
        System.assert(nextSeq > seedSeq, 'Next (' + nextSeq + ') must exceed seed (' + seedSeq + ')');
    }
}
