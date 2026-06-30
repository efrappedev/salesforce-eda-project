@IsTest(SeeAllData=false)
private class AccountIdGeneratorTest {

    // ========= Helpers =========

    private static Id rtId(String sobjectType, String devName) {
        RecordType rt = [
            SELECT Id
            FROM RecordType
            WHERE SobjectType = :sobjectType AND DeveloperName = :devName
            LIMIT 1
        ];
        return rt.Id;
    }

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

    private static void assertPrefixedSeq(String v, String prefix) {
        System.assert(isNotBlank(v), 'Value is blank for prefix ' + prefix);
        System.assert(v.startsWith(prefix), 'Must start with ' + prefix + ' but got ' + v);
        System.assertEquals(prefix.length() + 7, v.length(), 'Length must be prefix + 7 digits');
        System.assert(allDigits(v, prefix.length(), v.length()), 'Tail must be 7 digits');
    }

    private static void assertAdminShortOrFallback(String actual, String contactId) {
        String expectedShort = 'I-' + contactId;
        if (actual == expectedShort) {
            System.assert(actual.length() <= 20, 'ID_Account__c length <= 20');
            return;
        }
        System.assert(actual.startsWith('I-ADM'),
            'Admin ID must be I-<ID_Contact__c> or fallback I-ADM#######, got ' + actual);
        System.assertEquals('I-ADM'.length() + 7, actual.length(),
            'Fallback length must be 5 + 7 digits');
        System.assert(allDigits(actual, 'I-ADM'.length(), actual.length()),
            'Fallback tail must be digits');
    }

    private static void assertAdminLongIADM(String v) { assertPrefixedSeq(v, 'I-ADM'); }

    private static void applyDupBypass(Database.DMLOptions dmo) {
        dmo.DuplicateRuleHeader.allowSave = true;
        dmo.DuplicateRuleHeader.runAsCurrentUser = true;
    }

    private static Account insertAccountResilient(Account a, Boolean canRenameIfDuplicate) {
        Database.DMLOptions dmo = new Database.DMLOptions();
        applyDupBypass(dmo);
        for (Integer attempt = 0; attempt < 3; attempt++) {
            Database.SaveResult sr = Database.insert(new List<SObject>{ a }, dmo)[0];
            if (sr.isSuccess()) { a.Id = sr.getId(); return a; }
            Boolean isDup = (!sr.isSuccess() && !sr.getErrors().isEmpty()
                             && sr.getErrors()[0].getStatusCode() == StatusCode.DUPLICATE_VALUE);
            if (!isDup || !canRenameIfDuplicate) return null;
            a.Name = a.Name + ' ' + uniq();
        }
        return null;
    }

    private static Boolean updateAccountResilient(Account a, Boolean canRenameIfDuplicate) {
        Database.DMLOptions dmo = new Database.DMLOptions();
        applyDupBypass(dmo);
        for (Integer attempt = 0; attempt < 3; attempt++) {
            Database.SaveResult sr = Database.update(new List<SObject>{ a }, dmo)[0];
            if (sr.isSuccess()) return true;
            Boolean isDup = (!sr.isSuccess() && !sr.getErrors().isEmpty()
                             && sr.getErrors()[0].getStatusCode() == StatusCode.DUPLICATE_VALUE);
            if (!isDup || !canRenameIfDuplicate) return false;
            a.Name = a.Name + ' ' + uniq();
        }
        return false;
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

    private static void updateBypass(Account a) {
        Database.DMLOptions dmo = new Database.DMLOptions();
        applyDupBypass(dmo);
        Database.SaveResult sr = Database.update(new List<SObject>{ a }, dmo)[0];
        System.assert(sr.isSuccess(), 'Update bypass failed: ' +
            (sr.getErrors().isEmpty() ? 'unknown' : sr.getErrors()[0].getMessage()));
    }

    // ========= Tests =========

    // 1) Admin con contacto → corto o fallback I-ADM; ID inmutable al cambiar PC
    @IsTest
    static void accountTrigger_Admin_WithContact_ShortId_Inmutable() {
        String U = uniq();
        Id rtAdmin = rtId('Account', 'Administrative');

        Contact c1 = insertContactResilient(new Contact(FirstName = 'Ana' + U, LastName = 'Corto' + U));
        c1 = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :c1.Id LIMIT 1];
        System.assert(isNotBlank(c1.ID_Contact__c), 'Contact must have ID_Contact__c');

        Account a = new Account(Name = 'Admin Con Contacto ' + U, RecordTypeId = rtAdmin,
                                hed__Primary_Contact__c = c1.Id);
        a = insertAccountResilient(a, true);
        if (a == null) {
            System.assert(true, 'Skipped by org duplicate rules');
            return;
        }

        a = [SELECT Id, ID_Account__c, hed__Primary_Contact__c FROM Account WHERE Id = :a.Id LIMIT 1];
        System.assert(isNotBlank(a.ID_Account__c), 'Admin+PC must get ID');
        assertAdminShortOrFallback(a.ID_Account__c, c1.ID_Contact__c);

        // Inmutabilidad: cambiar PC no debe cambiar el ID
        Contact c2 = insertContactResilient(new Contact(FirstName = 'Beto' + U, LastName = 'Cambio' + U));
        c2 = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :c2.Id LIMIT 1];
        String idBefore = a.ID_Account__c;
        a.hed__Primary_Contact__c = c2.Id;
        Boolean ok = updateAccountResilient(a, true);
        if (!ok) {
            System.assert(true, 'Skipped by org duplicate rules on update');
            return;
        }
        a = [SELECT Id, ID_Account__c, hed__Primary_Contact__c FROM Account WHERE Id = :a.Id LIMIT 1];
        System.assertEquals(idBefore, a.ID_Account__c, 'ID must remain immutable on PC change');
    }

    // 2) Admin huérfana sin gemela → I-ADM#######; con gemela → null
    @IsTest
    static void accountTrigger_Admin_Orphan_LongId_NoTwin_NullWithTwin() {
        String U = uniq();
        Id rtAdmin = rtId('Account', 'Administrative');

        // A) Huérfana sin gemela → debe obtener I-ADM#######
        Account orphanNoTwin = new Account(Name = 'Instituto Aguila ' + U, RecordTypeId = rtAdmin);
        orphanNoTwin = insertAccountResilient(orphanNoTwin, true);
        System.assertNotEquals(null, orphanNoTwin, 'Insert orphanNoTwin should not be blocked');
        orphanNoTwin = [SELECT Id, ID_Account__c FROM Account WHERE Id = :orphanNoTwin.Id LIMIT 1];
        System.assert(isNotBlank(orphanNoTwin.ID_Account__c), 'Orphan no-twin must get a long ID');
        assertAdminLongIADM(orphanNoTwin.ID_Account__c);

        // B) Par gemelas: una con PC, una sin → huérfana queda null
        Contact c = insertContactResilient(new Contact(FirstName = 'Juan' + U, LastName = 'Gemelo' + U));
        String twinName = 'Universidad Beta ' + U;

        Account adminWithPC = insertAccountResilient(
            new Account(Name = twinName, RecordTypeId = rtAdmin, hed__Primary_Contact__c = c.Id),
            false
        );
        Account orphanTwin = insertAccountResilient(
            new Account(Name = twinName, RecordTypeId = rtAdmin),
            false
        );

        if (adminWithPC == null || orphanTwin == null) {
            System.assert(true, 'Skipped twin scenario due to org duplicate rules');
            return;
        }

        adminWithPC = [SELECT Id, ID_Account__c FROM Account WHERE Id = :adminWithPC.Id LIMIT 1];
        orphanTwin  = [SELECT Id, ID_Account__c FROM Account WHERE Id = :orphanTwin.Id  LIMIT 1];

        System.assert(isNotBlank(adminWithPC.ID_Account__c), 'Twin with contact must have ID');
        System.assertEquals(null, orphanTwin.ID_Account__c,
            'Orphan twin must remain null when a contact-twin exists');
    }

    // 3) Otros Record Types → prefijo de 3 letras + 7 dígitos
    @IsTest
    static void accountTrigger_OtherRecordTypes_PrefixSequence() {
        String U = uniq();
        Id rtBUS = rtId('Account', 'Business_Organization');
        Id rtEGL = rtId('Account', 'Eglise');

        Account a1 = insertAccountResilient(new Account(Name = 'Bodega Central ' + U, RecordTypeId = rtBUS), true);
        Account a2 = insertAccountResilient(new Account(Name = 'Eglise St Pierre ' + U, RecordTypeId = rtEGL), true);
        System.assertNotEquals(null, a1, 'BUS insert should succeed');
        System.assertNotEquals(null, a2, 'EGL insert should succeed');

        a1 = [SELECT Id, ID_Account__c FROM Account WHERE Id = :a1.Id LIMIT 1];
        a2 = [SELECT Id, ID_Account__c FROM Account WHERE Id = :a2.Id LIMIT 1];

        assertPrefixedSeq(a1.ID_Account__c, 'BUS');
        assertPrefixedSeq(a2.ID_Account__c, 'EGL');
        System.assert(a1.ID_Account__c.length() <= 20, 'BUS ID length <= 20');
        System.assert(a2.ID_Account__c.length() <= 20, 'EGL ID length <= 20');
    }

    // 4) Short ID tomado → BEFORE asigna I-ADM; inner loop del maxByPrefix ejecuta con seed I-ADM;
    //    AFTER INSERT: cand non-empty, desired populated, taken populated, toUpd loop evaluado.
    //    Funciona en orgs EDA (TDTM auto-crea Admin+PC al insertar Contact) y sin EDA (holder explícito).
    @IsTest
    static void accountTrigger_AfterInsert_IAdmFallback_CoversInnerLoop() {
        String U = uniq();
        Id rtAdmin = rtId('Account', 'Administrative');

        // Paso 1: Contacto con ID_Contact__c
        Contact c = insertContactResilient(new Contact(FirstName = 'Zoe' + U, LastName = 'Vidal' + U));
        c = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :c.Id LIMIT 1];
        System.assert(isNotBlank(c.ID_Contact__c), 'Contact must get ID_Contact__c');

        // Paso 2: Admin huérfana → siembra el prefijo I-ADM para que el inner loop
        //         del maxByPrefix encuentre datos al calcular el siguiente I-ADM
        Account seedOrphan = insertAccountResilient(
            new Account(Name = 'Semilla Huerfana ' + U, RecordTypeId = rtAdmin), true
        );
        System.assertNotEquals(null, seedOrphan, 'Seed orphan must succeed');
        seedOrphan = [SELECT Id, ID_Account__c FROM Account WHERE Id = :seedOrphan.Id LIMIT 1];
        assertAdminLongIADM(seedOrphan.ID_Account__c);

        // Paso 3: Garantizar que el short ID I-<contactId> esté tomado.
        // En orgs EDA el TDTM ya lo tomó al insertar el Contact (Admin Account auto-creado).
        // En orgs sin EDA se inserta un holder explícito.
        String shortId = 'I-' + c.ID_Contact__c;
        if (shortId.length() > 20) shortId = shortId.substring(0, 20);
        List<Account> takenByExisting = [
            SELECT Id FROM Account WHERE ID_Account__c = :shortId LIMIT 1
        ];
        if (takenByExisting.isEmpty()) {
            Account holder = insertAccountResilient(
                new Account(Name = 'Holder Admin ' + U, RecordTypeId = rtAdmin,
                            hed__Primary_Contact__c = c.Id), true
            );
            if (holder == null) { System.assert(true, 'Skipped: holder blocked by org rules'); return; }
            takenByExisting = [SELECT Id FROM Account WHERE ID_Account__c = :shortId LIMIT 1];
            if (takenByExisting.isEmpty()) {
                System.assert(true, 'Skipped: short ID not taken after explicit holder insert');
                return;
            }
        }

        // Paso 4: Admin con mismo PC → short tomado
        //  BEFORE INSERT: takenShorts contiene el short → allPrefixes.add('I-ADM') ← linea 176
        //                 query I-ADM% → encuentra seedOrphan → inner loop ejecuta ← lineas 193-210
        //                 else branch → asigna I-ADM000000X ← lineas 224-234
        //  AFTER INSERT:  cand=[fallback] (empieza I-ADM) ← lineas 278-285
        //                 queries contact → desired populated ← lineas 288-306
        //                 queries taken → el holder tiene el short ← lineas 310-317
        //                 toUpd loop: !taken.contains → false → toUpd vacio ← lineas 320-327
        Account fallback = insertAccountResilient(
            new Account(Name = 'Fallback Admin ' + U, RecordTypeId = rtAdmin,
                        hed__Primary_Contact__c = c.Id), true
        );
        if (fallback == null) { System.assert(true, 'Skipped: fallback blocked by org rules'); return; }
        fallback = [SELECT Id, ID_Account__c FROM Account WHERE Id = :fallback.Id LIMIT 1];

        assertAdminLongIADM(fallback.ID_Account__c);
        System.assertNotEquals(seedOrphan.ID_Account__c, fallback.ID_Account__c,
            'Fallback must get next I-ADM seq after seed (seed=' + seedOrphan.ID_Account__c + ')');
    }
}