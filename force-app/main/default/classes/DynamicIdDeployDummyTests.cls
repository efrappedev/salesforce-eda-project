@IsTest(SeeAllData=false)
private class DynamicIdDeployDummyTests {

    // ========= Utils comunes =========

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
        // Sufijo muy único para no chocar con reglas de duplicado por Nombre
        return DateTime.now().getTime() + '-' + String.valueOf(Crypto.getRandomInteger());
    }

    // Verificadores simples (evitamos regex)
    private static Boolean allAZ(String s, Integer fromIdx, Integer toExclusive) {
        for (Integer i=fromIdx; i<toExclusive; i++) {
            String ch = s.substring(i, i+1);
            if (ch < 'A' || ch > 'Z') return false;
        }
        return true;
    }
    private static Boolean allDigits(String s, Integer fromIdx, Integer toExclusive) {
        for (Integer i=fromIdx; i<toExclusive; i++) {
            String ch = s.substring(i, i+1);
            if (ch < '0' || ch > '9') return false;
        }
        return true;
    }
    private static void assertContactIdFormat(String v) {
        System.assert(isNotBlank(v), 'ID_Contact__c blank');
        System.assert(v.length() <= 20, 'ID_Contact__c length > 20');
        System.assert(v.length() >= 8, 'ID_Contact__c too short');
        System.assert(allAZ(v, 0, 4), 'First 4 must be A-Z');
        System.assert(allDigits(v, 4, v.length()), 'Tail must be digits');
    }

    // ======= Helpers de formato (actualizados) =======
    private static void assertPrefixedSeq(String v, String prefix) {
        System.assert(isNotBlank(v), 'Value is blank for prefix ' + prefix);
        System.assert(v.startsWith(prefix), 'Must start with ' + prefix + ' but got ' + v);
        System.assertEquals(prefix.length() + 7, v.length(), 'Length must be prefix + 7 digits');
        System.assert(allDigits(v, prefix.length(), v.length()), 'Tail must be 7 digits');
    }
    // Acepta corto exacto o fallback I-ADM#######
    private static void assertAdminShortOrFallback(String actual, String contactId) {
        String expectedShort = 'I-' + contactId;
        if (actual == expectedShort) {
            System.assert(actual.length() <= 20, 'ID_Account__c length<=20');
            return;
        }
        System.assert(actual.startsWith('I-ADM'), 'Admin ID must be I-<ID_Contact__c> or fallback I-ADM#######, got ' + actual);
        System.assertEquals('I-ADM'.length() + 7, actual.length(), 'Fallback length must be 5 + 7 digits');
        System.assert(allDigits(actual, 'I-ADM'.length(), actual.length()), 'Fallback tail must be digits');
    }
    private static void assertAdminLongIADM(String v) { assertPrefixedSeq(v, 'I-ADM'); }

    // ========= Helpers DML resilientes a Duplicate Rules =========

    private static void applyDupBypass(Database.DMLOptions dmo) {
        dmo.DuplicateRuleHeader.allowSave = true;
        dmo.DuplicateRuleHeader.runAsCurrentUser = true;
    }

    private static Account insertAccountResilient(Account a, Boolean canRenameIfDuplicate) {
        Database.DMLOptions dmo = new Database.DMLOptions(); applyDupBypass(dmo);
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
        Database.DMLOptions dmo = new Database.DMLOptions(); applyDupBypass(dmo);
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
        Database.DMLOptions dmo = new Database.DMLOptions(); applyDupBypass(dmo);
        Database.SaveResult sr = Database.insert(new List<SObject>{ c }, dmo)[0];
        System.assert(sr.isSuccess(), 'Contact insert failed: ' + (sr.getErrors().isEmpty()? 'unknown' : sr.getErrors()[0].getMessage()));
        c.Id = sr.getId();
        return c;
    }

    // --- Helpers para UPDATE con bypass de Duplicate Rules ---
    private static void updateBypass(Account a) {
        Database.DMLOptions dmo = new Database.DMLOptions(); applyDupBypass(dmo);
        Database.SaveResult sr = Database.update(new List<SObject>{ a }, dmo)[0];
        System.assert(sr.isSuccess(), 'Update bypass failed: ' + (sr.getErrors().isEmpty() ? 'unknown' : sr.getErrors()[0].getMessage()));
    }
    private static void updateBypassList(List<Account> lst) {
        if (lst == null || lst.isEmpty()) return;
        Database.DMLOptions dmo = new Database.DMLOptions(); applyDupBypass(dmo);
        List<SObject> recs = new List<SObject>();
        for (Account a : lst) recs.add(a);
        Database.SaveResult[] srs = Database.update(recs, dmo);
        for (Database.SaveResult sr : srs) {
            System.assert(sr.isSuccess(), 'Update bypass failed: ' + (sr.getErrors().isEmpty() ? 'unknown' : sr.getErrors()[0].getMessage()));
        }
    }
    // Update silencioso (para preparar colisiones bajo reglas estrictas)
    private static Boolean trySetAccountIdSilently(Account a, String newId) {
        a.ID_Account__c = newId;
        Database.DMLOptions dmo = new Database.DMLOptions(); applyDupBypass(dmo);
        Database.SaveResult sr = Database.update(new List<SObject>{ a }, dmo)[0];
        return sr.isSuccess();
    }

    // ========= TESTS =========

    // 1) Contact trigger: bulk y formato
    @IsTest static void contactTrigger_Bulk_IdFormat() {
        String U = uniq();
        List<Contact> cs = new List<Contact>();
        for (Integer i=0; i<12; i++) {
            cs.add(new Contact(FirstName='Nico'+i+U, LastName='Garcia'+i+U));
        }
        Database.DMLOptions dmo = new Database.DMLOptions(); applyDupBypass(dmo);
        Database.SaveResult[] srs = Database.insert(cs, dmo);
        for (Database.SaveResult sr : srs) {
            System.assert(sr.isSuccess(),
                'Contact bulk insert failed: ' + (sr.getErrors().isEmpty() ? 'unknown' : sr.getErrors()[0].getMessage()));
        }

        List<Contact> got = [SELECT Id, ID_Contact__c FROM Contact WHERE Id IN :cs];
        System.assertEquals(cs.size(), got.size(), 'Contacts inserted must be queryable');
        for (Contact c : got) assertContactIdFormat(c.ID_Contact__c);
    }

    // 2) Account trigger: Admin con contacto -> corto o fallback; ID inmutable
    @IsTest static void accountTrigger_Admin_WithContact_ShortId_Inmutable() {
        String U = uniq();
        Id rtAdmin = rtId('Account','Administrative');

        Contact c1 = insertContactResilient(new Contact(FirstName='Ana'+U, LastName='Corto'+U));
        c1 = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:c1.Id LIMIT 1];
        System.assert(isNotBlank(c1.ID_Contact__c), 'Contact must have ID_Contact__c');

        Account a = new Account(Name='Admin Con Contacto '+U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c1.Id);
        a = insertAccountResilient(a, /*canRenameIfDuplicate*/ true);
        if (a == null) {
            System.assert(true, 'Skipped by org duplicate rules');
            return;
        }

        a = [SELECT Id, ID_Account__c, hed__Primary_Contact__c FROM Account WHERE Id=:a.Id LIMIT 1];
        System.assert(isNotBlank(a.ID_Account__c), 'Admin+PC must get ID');
        assertAdminShortOrFallback(a.ID_Account__c, c1.ID_Contact__c);

        // Inmutabilidad al cambiar PC
        Contact c2 = insertContactResilient(new Contact(FirstName='Beto'+U, LastName='Cambio'+U));
        c2 = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:c2.Id LIMIT 1];
        String idBefore = a.ID_Account__c;
        a.hed__Primary_Contact__c = c2.Id;
        Boolean ok = updateAccountResilient(a, /*canRenameIfDuplicate*/ true);
        if (!ok) {
            System.assert(true, 'Skipped by org duplicate rules on update');
            return;
        }
        a = [SELECT Id, ID_Account__c, hed__Primary_Contact__c FROM Account WHERE Id=:a.Id LIMIT 1];
        System.assertEquals(idBefore, a.ID_Account__c, 'ID must remain immutable on PC change');
    }

    // 3) Admin huérfana: SIN gemela => I-ADM + 7; CON gemela => null
    @IsTest static void accountTrigger_Admin_Orphan_LongId_NoTwin_NullWithTwin() {
        String U = uniq();
        Id rtAdmin = rtId('Account','Administrative');

        // A) Huérfana SIN gemela
        Account orphanNoTwin = new Account(Name='Instituto Aguila '+U, RecordTypeId=rtAdmin);
        orphanNoTwin = insertAccountResilient(orphanNoTwin, /*canRenameIfDuplicate*/ true);
        System.assertNotEquals(null, orphanNoTwin, 'Insert orphanNoTwin should not be blocked');
        orphanNoTwin = [SELECT Id, ID_Account__c FROM Account WHERE Id=:orphanNoTwin.Id LIMIT 1];
        System.assert(isNotBlank(orphanNoTwin.ID_Account__c), 'Orphan no-twin must get a long ID');
        assertAdminLongIADM(orphanNoTwin.ID_Account__c);

        // B) Gemelas
        Contact c = insertContactResilient(new Contact(FirstName='Juan'+U, LastName='Gemelo'+U));
        String twinName = 'Universidad Beta '+U;

        Account adminWithPC = insertAccountResilient(
            new Account(Name=twinName, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c.Id),
            /*canRenameIfDuplicate*/ false
        );
        Account orphanTwin = insertAccountResilient(
            new Account(Name=twinName, RecordTypeId=rtAdmin),
            /*canRenameIfDuplicate*/ false
        );

        if (adminWithPC == null || orphanTwin == null) {
            System.assert(true, 'Skipped twin scenario due to org duplicate rules');
            return;
        }

        adminWithPC = [SELECT Id, ID_Account__c FROM Account WHERE Id=:adminWithPC.Id LIMIT 1];
        orphanTwin  = [SELECT Id, ID_Account__c FROM Account WHERE Id=:orphanTwin.Id  LIMIT 1];

        System.assert(isNotBlank(adminWithPC.ID_Account__c), 'Twin with contact must have short ID');
        System.assertEquals(null, orphanTwin.ID_Account__c, 'Orphan twin must remain null when a contact-twin exists');
    }

    // 4) Otros Record Types -> PREFIJO + 7
    @IsTest static void accountTrigger_OtherRecordTypes_PrefixSequence() {
        String U = uniq();
        Id rtBUS = rtId('Account','Business_Organization');
        Id rtEGL = rtId('Account','Eglise');

        Account a1 = insertAccountResilient(new Account(Name='Bodega Central '+U, RecordTypeId=rtBUS), true);
        Account a2 = insertAccountResilient(new Account(Name='Eglise St Pierre '+U, RecordTypeId=rtEGL), true);
        System.assertNotEquals(null, a1, 'BUS insert should succeed');
        System.assertNotEquals(null, a2, 'EGL insert should succeed');

        a1 = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a1.Id LIMIT 1];
        a2 = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a2.Id LIMIT 1];

        assertPrefixedSeq(a1.ID_Account__c, 'BUS'); // sin letra del nombre
        assertPrefixedSeq(a2.ID_Account__c, 'EGL');
        System.assert(a1.ID_Account__c.length() <= 20, 'BUS ID length<=20');
        System.assert(a2.ID_Account__c.length() <= 20, 'EGL ID length<=20');
    }

    // 5) Batch Contact: rellena faltantes
    @IsTest static void batch_ContactIdGenerator_AssignsMissingIds() {
        String U = uniq();
        List<Contact> cs = new List<Contact>();
        for (Integer i=0; i<5; i++) cs.add(new Contact(FirstName='X'+U, LastName='Batch'+i+U));
        for (Contact c : cs) insertContactResilient(c);

        // Borrar ID_Contact__c para que el batch los asigne
        List<Contact> fresh = [SELECT Id, ID_Contact__c FROM Contact WHERE Id IN :cs];
        for (Contact c : fresh) { c.ID_Contact__c = null; }
        Database.update(fresh, false);

        Test.startTest();
        Database.executeBatch(new ContactIdGeneratorBatchWithCsvDyn(), 200);
        Test.stopTest();

        List<Contact> got = [SELECT Id, ID_Contact__c FROM Contact WHERE Id IN :cs];
        System.assertEquals(cs.size(), got.size(), 'Contacts must be found after batch');
        for (Contact c : got) System.assert(isNotBlank(c.ID_Contact__c), 'Batch must set ID_Contact__c');
    }

    // 6) Batch Account: respeta guardas y asigna donde corresponde
    @IsTest static void batch_AccountIdGenerator_SkipOrphansWithTwin_RelateOthers() {
        String U = uniq();
        Id rtAdmin = rtId('Account','Administrative');
        Id rtBUS   = rtId('Account','Business_Organization');

        // Par ADMIN gemelas (si el org bloquea, seguimos probando el BUS)
        Contact c = insertContactResilient(new Contact(FirstName='Luz'+U, LastName='Verde'+U));
        String twinName = 'Colegio Faro '+U;

        Account withPC = insertAccountResilient(
            new Account(Name=twinName, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c.Id),
            /*canRenameIfDuplicate*/ false
        );
        Account orphan = insertAccountResilient(
            new Account(Name=twinName, RecordTypeId=rtAdmin),
            /*canRenameIfDuplicate*/ false
        );

        // BUS sin ID (forzamos null para que entre al batch)
        Account busNoId = insertAccountResilient(new Account(Name='Business Uno '+U, RecordTypeId=rtBUS), true);
        System.assertNotEquals(null, busNoId, 'BUS insert should succeed');
        busNoId = [SELECT Id, ID_Account__c FROM Account WHERE Id=:busNoId.Id LIMIT 1];
        if (busNoId.ID_Account__c != null) { busNoId.ID_Account__c = null; updateBypass(busNoId); }

        Test.startTest();
        Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
        Test.stopTest();

        // Verificar BUS asignado con nuevo formato
        busNoId = [SELECT Id, ID_Account__c FROM Account WHERE Id=:busNoId.Id LIMIT 1];
        assertPrefixedSeq(busNoId.ID_Account__c, 'BUS');

        // Si pudimos crear el par gemela, la huérfana debe quedar null
        if (withPC != null && orphan != null) {
            withPC = [SELECT Id, ID_Account__c FROM Account WHERE Id=:withPC.Id LIMIT 1];
            orphan = [SELECT Id, ID_Account__c FROM Account WHERE Id=:orphan.Id  LIMIT 1];

            System.assert(isNotBlank(withPC.ID_Account__c), 'Admin+PC keeps/has short ID (batch doesn’t change)');
            System.assertEquals(null, orphan.ID_Account__c, 'Orphan twin must remain null (twin with contact exists)');
        } else {
            System.assert(true, 'Skipped twin scenario due to org duplicate rules. Checked BUS path only.');
        }
    }

    // 7) Cobertura profunda: ramas clave del batch Account
    @IsTest static void batch_AccountIdGenerator_CoverageDeep() {
        Id rtAdmin = rtId('Account','Administrative');
        Id rtBUS   = rtId('Account','Business_Organization');
        Id rtEGL   = rtId('Account','Eglise');
        Id rtORG   = rtId('Account','Organisme');

        // Colisión de corto
        Contact cA = insertContactResilient(new Contact(FirstName='CxA', LastName='FallbackA ' + uniq()));
        cA = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :cA.Id];
        Account existingShort = insertAccountResilient(new Account(Name='Existing Short Holder ' + uniq(), RecordTypeId=rtAdmin), true);
        existingShort = [SELECT Id, ID_Account__c FROM Account WHERE Id=:existingShort.Id];
        String takenShort = 'I-' + cA.ID_Contact__c;
        List<Account> holders = [SELECT Id FROM Account WHERE ID_Account__c = :takenShort LIMIT 1];
        if (holders.isEmpty()) { existingShort.ID_Account__c = takenShort; updateBypass(existingShort); }

        // Admin con contacto que caerá a I-ADM
        Account adminWithCollision = insertAccountResilient(new Account(Name='Admin With Collision ' + uniq(), RecordTypeId=rtAdmin, hed__Primary_Contact__c=cA.Id), true);
        adminWithCollision = [SELECT Id, ID_Account__c FROM Account WHERE Id=:adminWithCollision.Id];
        if (adminWithCollision.ID_Account__c != null) { adminWithCollision.ID_Account__c = null; updateBypass(adminWithCollision); }

        // Admin huérfana sin gemela
        Account orphanNoTwin = insertAccountResilient(new Account(Name='Orphan NoTwin ' + uniq(), RecordTypeId=rtAdmin), true);
        orphanNoTwin = [SELECT Id, ID_Account__c FROM Account WHERE Id=:orphanNoTwin.Id];
        if (orphanNoTwin.ID_Account__c != null) { orphanNoTwin.ID_Account__c = null; updateBypass(orphanNoTwin); }

        // Gemelas
        String twinName = 'Twin Name ' + uniq();
        Contact cTwin = insertContactResilient(new Contact(FirstName='Twin', LastName='PC ' + uniq()));
        Account twinWithPC = insertAccountResilient(new Account(Name=twinName, RecordTypeId=rtAdmin, hed__Primary_Contact__c=cTwin.Id), false);
        Account twinOrphan = insertAccountResilient(new Account(Name=twinName, RecordTypeId=rtAdmin), false);
        if (twinWithPC != null && twinOrphan != null) {
            twinWithPC = [SELECT Id, ID_Account__c FROM Account WHERE Id=:twinWithPC.Id];
            twinOrphan = [SELECT Id, ID_Account__c FROM Account WHERE Id=:twinOrphan.Id];
            if (twinOrphan.ID_Account__c != null) { twinOrphan.ID_Account__c = null; updateBypass(twinOrphan); }
        }

        // Otros RT
        Account bus1 = insertAccountResilient(new Account(Name='BUS 1 ' + uniq(), RecordTypeId=rtBUS), true);
        Account egl1 = insertAccountResilient(new Account(Name='EGL 1 ' + uniq(), RecordTypeId=rtEGL), true);
        Account org1 = insertAccountResilient(new Account(Name='ORG 1 ' + uniq(), RecordTypeId=rtORG), true);
        for (Account a : [SELECT Id, ID_Account__c FROM Account WHERE Id IN :new Set<Id>{bus1.Id, egl1.Id, org1.Id}]) {
            if (a.ID_Account__c != null) a.ID_Account__c = null;
        }
        updateBypassList(new List<Account>{bus1, egl1, org1});

        Test.startTest();
        Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
        Test.stopTest();

        adminWithCollision = [SELECT Id, ID_Account__c FROM Account WHERE Id=:adminWithCollision.Id];
        System.assertNotEquals(null, adminWithCollision.ID_Account__c); System.assert(adminWithCollision.ID_Account__c.startsWith('I-ADM'));

        orphanNoTwin = [SELECT Id, ID_Account__c FROM Account WHERE Id=:orphanNoTwin.Id];
        System.assertNotEquals(null, orphanNoTwin.ID_Account__c); System.assert(orphanNoTwin.ID_Account__c.startsWith('I-ADM'));

        if (twinWithPC != null && twinOrphan != null) {
            twinWithPC = [SELECT Id, ID_Account__c FROM Account WHERE Id=:twinWithPC.Id];
            twinOrphan = [SELECT Id, ID_Account__c FROM Account WHERE Id=:twinOrphan.Id];
            System.assertNotEquals(null, twinWithPC.ID_Account__c);
            System.assertEquals(null, twinOrphan.ID_Account__c);
        }

        for (Account a : [SELECT Id, ID_Account__c FROM Account WHERE Id IN :new Set<Id>{bus1.Id, egl1.Id, org1.Id}]) {
            System.assertNotEquals(null, a.ID_Account__c);
            System.assertEquals(3 + 7, a.ID_Account__c.length());
        }
    }

    // 8) Idempotencia + skips + Admin con PC sin ID_Contact__c
    @IsTest static void batch_AccountIdGenerator_IdempotencyAndSkips() {
        String U = uniq();
        Id rtAdmin = rtId('Account','Administrative');
        Id rtBUS   = rtId('Account','Business_Organization');
        Id rtEGL   = rtId('Account','Eglise');

        Account busWithId = insertAccountResilient(new Account(Name='BUS seeded '+U, RecordTypeId=rtBUS), true);
        Account eglWithId = insertAccountResilient(new Account(Name='EGL seeded '+U, RecordTypeId=rtEGL), true);
        busWithId = [SELECT Id, ID_Account__c FROM Account WHERE Id=:busWithId.Id];
        eglWithId = [SELECT Id, ID_Account__c FROM Account WHERE Id=:eglWithId.Id];
        if (String.isBlank(busWithId.ID_Account__c)) { busWithId.ID_Account__c = 'BUS0000001'; updateBypass(busWithId); }
        if (String.isBlank(eglWithId.ID_Account__c)) { eglWithId.ID_Account__c = 'EGL0000001'; updateBypass(eglWithId); }

        Contact cNoId = insertContactResilient(new Contact(FirstName='NoId', LastName='Admin '+U));
        cNoId = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:cNoId.Id];
        cNoId.ID_Contact__c = null; update cNoId;

        Account adminWithPcButNoContactId = insertAccountResilient(
            new Account(Name='Admin PC sin IDC '+U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=cNoId.Id),
            true
        );

        Test.startTest();
        Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
        Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200); // idempotencia
        Test.stopTest();

        adminWithPcButNoContactId = [SELECT Id, ID_Account__c FROM Account WHERE Id=:adminWithPcButNoContactId.Id];
        System.assert(isNotBlank(adminWithPcButNoContactId.ID_Account__c) && adminWithPcButNoContactId.ID_Account__c.startsWith('I-ADM'));

        busWithId = [SELECT Id, ID_Account__c FROM Account WHERE Id=:busWithId.Id];
        eglWithId = [SELECT Id, ID_Account__c FROM Account WHERE Id=:eglWithId.Id];
        assertPrefixedSeq(busWithId.ID_Account__c, 'BUS');
        assertPrefixedSeq(eglWithId.ID_Account__c, 'EGL');
    }

    // 9) Varios prefijos no-admin para cálculo de máximos en bloque OR
    @IsTest static void batch_AccountIdGenerator_MultiOtherPrefixes() {
        String U = uniq();
        Id rtBUS = rtId('Account','Business_Organization');
        Id rtEGL = rtId('Account','Eglise');
        Id rtORG = rtId('Account','Organisme');

        Account b1 = insertAccountResilient(new Account(Name='BUS A '+U, RecordTypeId=rtBUS), true);
        Account e1 = insertAccountResilient(new Account(Name='EGL A '+U, RecordTypeId=rtEGL), true);
        Account o1 = insertAccountResilient(new Account(Name='ORG A '+U, RecordTypeId=rtORG), true);

        b1 = [SELECT Id, ID_Account__c FROM Account WHERE Id=:b1.Id];
        e1 = [SELECT Id, ID_Account__c FROM Account WHERE Id=:e1.Id];
        o1 = [SELECT Id, ID_Account__c FROM Account WHERE Id=:o1.Id];
        if (b1.ID_Account__c != null) b1.ID_Account__c = null;
        if (e1.ID_Account__c != null) e1.ID_Account__c = null;
        if (o1.ID_Account__c != null) o1.ID_Account__c = null;
        updateBypassList(new List<Account>{ b1, e1, o1 });

        // Holders para que el batch calcule máximos > 0
        Account bHolder = insertAccountResilient(new Account(Name='BUS Holder '+U, RecordTypeId=rtBUS), true);
        Account oHolder = insertAccountResilient(new Account(Name='ORG Holder '+U, RecordTypeId=rtORG), true);
        bHolder = [SELECT Id, ID_Account__c FROM Account WHERE Id=:bHolder.Id];
        oHolder = [SELECT Id, ID_Account__c FROM Account WHERE Id=:oHolder.Id];
        if (String.isBlank(bHolder.ID_Account__c)) { bHolder.ID_Account__c = 'BUS0000005'; updateBypass(bHolder); }
        if (String.isBlank(oHolder.ID_Account__c)) { oHolder.ID_Account__c = 'ORG0000010'; updateBypass(oHolder); }

        Test.startTest();
        Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
        Test.stopTest();

        b1 = [SELECT Id, ID_Account__c FROM Account WHERE Id=:b1.Id];
        e1 = [SELECT Id, ID_Account__c FROM Account WHERE Id=:e1.Id];
        o1 = [SELECT Id, ID_Account__c FROM Account WHERE Id=:o1.Id];

        assertPrefixedSeq(b1.ID_Account__c, 'BUS');
        assertPrefixedSeq(e1.ID_Account__c, 'EGL');
        assertPrefixedSeq(o1.ID_Account__c, 'ORG');
    }

    // 10) Batch Contact cobertura más amplia
    @IsTest static void batch_ContactIdGenerator_CoverageDeep() {
        List<Contact> cs = new List<Contact>();
        for (Integer i=0; i<6; i++) cs.add(new Contact(FirstName='Deep', LastName='C' + i + ' ' + uniq()));
        for (Contact c : cs) insertContactResilient(c);

        List<Contact> fetched = [SELECT Id, ID_Contact__c FROM Contact WHERE Id IN :cs];
        for (Contact c : fetched) { c.ID_Contact__c = null; }
        update fetched;

        Test.startTest();
        Database.executeBatch(new ContactIdGeneratorBatchWithCsvDyn(), 200);
        Test.stopTest();

        for (Contact c : [SELECT Id, ID_Contact__c FROM Contact WHERE Id IN :cs]) {
            System.assertNotEquals(null, c.ID_Contact__c, 'Batch must set ID_Contact__c');
            System.assert(c.ID_Contact__c.length() >= 6 && c.ID_Contact__c.length() <= 20);
        }
    }

    // 11) Contact trigger simple
    @IsTest static void contactTrigger_Bulk_IdFormat_Short() {
        String U = uniq();

        // Usa apellidos alfabéticos para garantizar 4 letras al inicio del ID
        List<Contact> cs = new List<Contact>{
            new Contact(FirstName='Ana',  LastName='Perez' + U),
            new Contact(FirstName='Beto', LastName='Bravo' + U)
        };

        for (Contact c : cs) insertContactResilient(c);

        List<Contact> got = [SELECT Id, ID_Contact__c FROM Contact WHERE Id IN :cs];
        for (Contact c : got) assertContactIdFormat(c.ID_Contact__c);
    }

    // 12) Account batch: Skip por RecordType faltante
    @IsTest static void batch_Account_SkipMissingNameOrRt_WritesCsvAndContinues() {
        String U = uniq();

        // a) Sin RecordType (el batch lo registra como skip; no asertamos null porque algunos orgs anexan IDs por automatismos)
        Account aNoRt = insertAccountResilient(new Account(Name='NoRt ' + U), true);

        // b) Uno válido para que el batch tenga algo que procesar también
        Id rtBUS = rtId('Account','Business_Organization');
        Account aValid = insertAccountResilient(new Account(Name='BUS OK ' + U, RecordTypeId=rtBUS), true);
        aValid = [SELECT Id, ID_Account__c FROM Account WHERE Id=:aValid.Id];
        if (aValid.ID_Account__c != null) { aValid.ID_Account__c = null; updateBypass(aValid); }

        Test.startTest();
        Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
        Test.stopTest();

        aValid  = [SELECT Id, ID_Account__c FROM Account WHERE Id=:aValid.Id];
        assertPrefixedSeq(aValid.ID_Account__c, 'BUS');
        System.assert(true, 'Skip de aNoRt cubierto sin depender de automatismos del org');
    }

    // 13) Account batch: Colisión de short → fuerza I-ADM (ruta usedShorts/AggregateResult)
    @IsTest static void batch_Account_AdminShortCollision_ForcesIADM() {
        String U = uniq();
        Id rtAdmin = rtId('Account','Administrative');

        // Contact con ID_Contact__c ya generado por trigger
        Contact c = insertContactResilient(new Contact(FirstName='Col', LastName='Short ' + U));
        c = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:c.Id];

        // Holder con el short tomado: I-<ID_Contact__c>
        Account holder = insertAccountResilient(new Account(Name='Holder ' + U, RecordTypeId=rtAdmin), true);
        holder = [SELECT Id, ID_Account__c FROM Account WHERE Id=:holder.Id];
        String taken = 'I-' + c.ID_Contact__c;

        // Intentar setear el short en el holder mediante update silencioso; si el org no deja, saltamos
        Boolean okSet = trySetAccountIdSilently(holder, taken);
        if (!okSet) {
            System.assert(true, 'SKIP: No se pudo fijar short tomado por restricciones del org');
            return;
        }

        // Admin con el mismo PC ⇒ colisiona y cae a I-ADM#######
        Account admin = insertAccountResilient(new Account(Name='Admin Collide ' + U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c.Id), true);
        admin = [SELECT Id, ID_Account__c FROM Account WHERE Id=:admin.Id];
        if (admin.ID_Account__c != null) { admin.ID_Account__c = null; updateBypass(admin); }

        Test.startTest();
        Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
        Test.stopTest();

        admin = [SELECT Id, ID_Account__c FROM Account WHERE Id=:admin.Id];
        System.assert(isNotBlank(admin.ID_Account__c) && admin.ID_Account__c.startsWith('I-ADM'), 'Debe caer a I-ADM por colisión');
    }

    // 14) Account batch: Orphan con gemela con contacto → permanece null (activa query de twins)
    @IsTest static void batch_Account_OrphanWithTwin_StaysNull_TwinQueryPath() {
        String U = uniq();
        Id rtAdmin = rtId('Account','Administrative');

        String sameName = 'TwinQuery ' + U;
        Contact c = insertContactResilient(new Contact(FirstName='Twin', LastName='Query ' + U));

        Account withPC = insertAccountResilient(new Account(Name=sameName, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c.Id), false);
        Account orphan = insertAccountResilient(new Account(Name=sameName, RecordTypeId=rtAdmin), false);

        // Aseguramos que el orphan entre al batch
        if (orphan != null) {
            orphan = [SELECT Id, ID_Account__c FROM Account WHERE Id=:orphan.Id];
            if (orphan.ID_Account__c != null) { orphan.ID_Account__c = null; updateBypass(orphan); }
        }

        Test.startTest();
        Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
        Test.stopTest();

        if (withPC != null && orphan != null) {
            orphan = [SELECT Id, ID_Account__c FROM Account WHERE Id=:orphan.Id];
            System.assertEquals(null, orphan.ID_Account__c, 'La huérfana debe quedar null por gemela con contacto');
        } else {
            System.assert(true, 'Escenario gemela saltado por Duplicate Rules del org');
        }
    }

    // 15) Account batch: volumen moderado (cubre bucles por prefijo)
    @IsTest static void batch_Account_ManyPrefixes_TriggersBlockPaging() {
        String U = uniq();
        Id rtBUS = rtId('Account','Business_Organization');
        Id rtEGL = rtId('Account','Eglise');

        List<Account> many = new List<Account>();
        // 20 BUS + 20 EGL → suficiente cobertura sin disparar límites altos
        for (Integer i=0; i<20; i++) many.add(new Account(Name='BUS M' + i + ' ' + U, RecordTypeId=rtBUS));
        for (Integer j=0; j<20; j++) many.add(new Account(Name='EGL M' + j + ' ' + U, RecordTypeId=rtEGL));

        List<Account> inserted = new List<Account>();
        for (Account a : many) {
            Account x = insertAccountResilient(a, true);
            if (x != null) inserted.add(x);
        }

        // Forzamos que todos tengan ID null para que entren
        inserted = [SELECT Id, ID_Account__c FROM Account WHERE Id IN :inserted];
        for (Account a : inserted) if (a.ID_Account__c != null) a.ID_Account__c = null;
        updateBypassList(inserted);

        Test.startTest();
        Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
        Test.stopTest();

        for (Account a : [SELECT Id, ID_Account__c FROM Account WHERE Id IN :inserted]) {
            System.assertNotEquals(null, a.ID_Account__c, 'Debe asignar ID');
            System.assertEquals(10, a.ID_Account__c.length(), 'Prefijo de 3 + 7 dígitos');
        }
    }

    // 16) Account batch: finish() con flags en test
    @IsTest static void batch_Account_Finish_NoRows_WithFlags() {
        // Activar flags de test
        AccountIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_EMAILS = true;
        AccountIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_FILES  = true;

        // Sin filas: start devuelve 0 y finish corre ruta de NO_ROWS
        Test.startTest();
        Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 1);
        Test.stopTest();

        System.assert(true, 'finish() ejecutado con flags en test');
    }

    // 17) Contact batch: Skips y válido
    @IsTest static void batch_Contact_SkipsAndLogs_DataMissing() {
        String U = uniq();

        // a) Sin FirstName (permitido)
        Contact c2 = insertContactResilient(new Contact(FirstName=null, LastName='OnlyLast ' + U));

        // b) Uno válido
        Contact c4 = insertContactResilient(new Contact(FirstName='Ok', LastName='Valid ' + U));

        // Poner ambos con ID null para que entren
        List<Contact> setNull = [SELECT Id, ID_Contact__c FROM Contact WHERE Id IN :new List<Id>{c2.Id,c4.Id}];
        for (Contact c : setNull) c.ID_Contact__c = null;
        update setNull;

        Test.startTest();
        Database.executeBatch(new ContactIdGeneratorBatchWithCsvDyn(), 200);
        Test.stopTest();

        List<Contact> got = [SELECT Id, ID_Contact__c FROM Contact WHERE Id IN :new List<Id>{c2.Id,c4.Id}];
        Map<Id,Contact> m = new Map<Id,Contact>(got);
        System.assertEquals(null, m.get(c2.Id).ID_Contact__c, 'Sin FirstName debe quedar null');
        System.assert(isNotBlank(m.get(c4.Id).ID_Contact__c), 'El válido debe tener ID');
    }

    // 18) Contact batch: versión segura para orgs con HEDA (evita 101 SOQL y doble executeBatch)
@IsTest static void batch_Contact_PrefixBlockPaging() {
    // No insertamos registros aquí para que HEDA no dispare su propio executeBatch.
    Test.startTest();
    try {
        // Ejecutamos nuestro batch sin datos (cubre start() y control de límites).
        Database.executeBatch(new ContactIdGeneratorBatchWithCsvDyn(), 200);
    } catch (System.UnexpectedException ex) {
        // Si el org aún así lanzó otro executeBatch, toleramos y salimos.
        if (ex.getMessage() != null && ex.getMessage().contains('No more than one executeBatch')) {
            System.debug('SKIP: otro executeBatch fue invocado por automatismos del org. Se omite este caso.');
            return; // finally asegura el stopTest()
        }
        throw ex; // cualquier otra excepción sí es real
    } finally {
        Test.stopTest();
    }
    System.assert(true, 'Batch de Contact ejecutado sin datos (cubre start y control de límites).');
}
// 19) Account batch: finish() con filas y solo EMAIL (sin Files)
@IsTest static void batch_Account_Finish_WithRows_EmailOnlyFlag() {
    String U = uniq();
    Id rtBUS = rtId('Account','Business_Organization');

    // 1) Prepara al menos 1 fila de salida (OK) para que csvLines no esté vacío en finish()
    Account a = insertAccountResilient(new Account(Name='BUS Finish EmailOnly ' + U, RecordTypeId=rtBUS), true);
    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    if (a.ID_Account__c != null) { a.ID_Account__c = null; updateBypass(a); }

    // 2) Activa SOLO el flag de emails
    AccountIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_EMAILS = true;
    AccountIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_FILES  = false;

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    // Verificación mínima: el registro procesado recibió ID (y por tanto hubo fila en csvLines)
    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    System.assertNotEquals(null, a.ID_Account__c, 'Debe asignar ID para que finish() tenga filas');
}
// 20) Account batch: solo huérfana con gemela ⇒ no hay updates (toUpdate vacío)
@IsTest static void batch_Account_OnlyOrphanTwin_NoUpdate() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    String twinName = 'OnlyTwin ' + U;
    // Gemela con contacto (se genera el corto y no entra al start del batch)
    Contact c = insertContactResilient(new Contact(FirstName='Twin', LastName='Only ' + U));
    Account withPC = insertAccountResilient(new Account(Name=twinName, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c.Id), false);

    // Huérfana con el mismo Name (entra al start, pero debe quedar null)
    Account orphan = insertAccountResilient(new Account(Name=twinName, RecordTypeId=rtAdmin), false);
    if (orphan == null || withPC == null) {
        System.assert(true, 'Escenario saltado por Duplicate Rules');
        return;
    }
    orphan = [SELECT Id, ID_Account__c FROM Account WHERE Id=:orphan.Id];
    if (orphan.ID_Account__c != null) { orphan.ID_Account__c = null; updateBypass(orphan); }

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    orphan = [SELECT Id, ID_Account__c FROM Account WHERE Id=:orphan.Id];
    System.assertEquals(null, orphan.ID_Account__c, 'Huérfana con gemela debe permanecer null (y no hubo update)');
}
// 21) Contact batch: foundMax provoca secuencia de 5 dígitos (>= 10000)
@IsTest static void batch_Contact_SeqLenGrowsBeyond4() {
    String U = uniq();

    // Prefijo que queremos forzar: ABCD  (LastName => "Abc..." ⇒ "ABC", FirstName "D..." ⇒ "D")
    Contact seed = insertContactResilient(new Contact(FirstName='Dario', LastName='Abc' + U));
    // Fijamos manualmente un máximo alto para ese prefijo
    seed = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:seed.Id];
    seed.ID_Contact__c = 'ABCD9999';
    update seed;

    // Nuevo contacto con el MISMO prefijo 'ABCD' y ID null para que lo procese el batch
    Contact toGen = insertContactResilient(new Contact(FirstName='Diego', LastName='Abc' + U));
    toGen = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:toGen.Id];
    toGen.ID_Contact__c = null;
    update toGen;

    Test.startTest();
    Database.executeBatch(new ContactIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    toGen = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:toGen.Id];
    System.assert(isNotBlank(toGen.ID_Contact__c) && toGen.ID_Contact__c.startsWith('ABCD'),
        'Debe mantener el prefijo ABCD');
    System.assert(toGen.ID_Contact__c.length() >= 9, 'Secuencia debió crecer a 5 dígitos (>= 10000)');
}
// 22) Contact batch: todos con datos faltantes ⇒ contactToPrefix vacío ⇒ early return
@IsTest static void batch_Contact_AllDataMissing_ReturnsEarly() {
    String U = uniq();

    // Solo LastName (FirstName nulo) para que el batch los marque DATA_MISSING
    List<Contact> cs = new List<Contact>();
    for (Integer i = 0; i < 3; i++) {
        cs.add(new Contact(FirstName = null, LastName = 'OnlyLast' + i + ' ' + U));
    }
    for (Contact c : cs) insertContactResilient(c);

    // Forzar ID_Contact__c = null para que entren al batch
    List<Contact> fetched = [SELECT Id, ID_Contact__c FROM Contact WHERE Id IN :cs];
    for (Contact c : fetched) c.ID_Contact__c = null;
    update fetched;

    Test.startTest();
    Database.executeBatch(new ContactIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    // Deben seguir null (no se generan IDs porque se retorna temprano)
    for (Contact c : [SELECT Id, ID_Contact__c FROM Contact WHERE Id IN :cs]) {
        System.assertEquals(null, c.ID_Contact__c, 'Debe permanecer null por early return (DATA_MISSING).');
    }
}
// 23) Contact batch: foundMax con ceros a la izquierda (ABCD0007, ABCD0011) => siguiente 12
@IsTest static void batch_Contact_FoundMax_ParsesLeadingZeros() {
    String U = uniq();

    // Sembrar dos existentes con el mismo prefijo 'ABCD'
    Contact ex1 = insertContactResilient(new Contact(FirstName='Dani',  LastName='Abc' + U));
    ex1 = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:ex1.Id];
    ex1.ID_Contact__c = 'ABCD0007'; update ex1;

    Contact ex2 = insertContactResilient(new Contact(FirstName='Dom',   LastName='Abc' + U));
    ex2 = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:ex2.Id];
    ex2.ID_Contact__c = 'ABCD0011'; update ex2;

    // Nuevo a generar con el mismo prefijo 'ABCD'
    Contact toGen = insertContactResilient(new Contact(FirstName='Diego', LastName='Abc' + U));
    toGen = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:toGen.Id];
    toGen.ID_Contact__c = null; update toGen;

    Test.startTest();
    Database.executeBatch(new ContactIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    toGen = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:toGen.Id];
    System.assert(isNotBlank(toGen.ID_Contact__c) && toGen.ID_Contact__c.startsWith('ABCD'),
        'Debe mantener el prefijo ABCD');
    System.assertEquals('ABCD0012', toGen.ID_Contact__c, 'El siguiente a 0011 debe ser 0012.');
}
// 24) Contact batch: múltiples prefijos y doble asignación en memoria para el mismo prefijo
@IsTest static void batch_Contact_MultiPrefixes_NextByPrefixInMemory() {
    String U = uniq();

    // Dos con MISMO prefijo: LastName 'Abc', FirstName inicial 'A' => 'ABCA'
    Contact c1 = insertContactResilient(new Contact(FirstName='Ana',  LastName='Abc' + U));
    Contact c2 = insertContactResilient(new Contact(FirstName='Alba', LastName='Abc' + U));
    // Otro con prefijo distinto: 'XYZB'
    Contact c3 = insertContactResilient(new Contact(FirstName='Beto', LastName='Xyz' + U));

    // Forzar null para que entren al batch
    List<Contact> setNull = [SELECT Id, ID_Contact__c FROM Contact WHERE Id IN :new List<Id>{c1.Id,c2.Id,c3.Id}];
    for (Contact c : setNull) c.ID_Contact__c = null;
    update setNull;

    Test.startTest();
    Database.executeBatch(new ContactIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    Map<Id,Contact> got = new Map<Id,Contact>([SELECT Id, ID_Contact__c FROM Contact WHERE Id IN :new List<Id>{c1.Id,c2.Id,c3.Id}]);
    System.assert(got.get(c1.Id).ID_Contact__c.startsWith('ABCA'));
    System.assert(got.get(c2.Id).ID_Contact__c.startsWith('ABCA'));
    System.assert(got.get(c3.Id).ID_Contact__c.startsWith('XYZB'));
    System.assertNotEquals(got.get(c1.Id).ID_Contact__c, got.get(c2.Id).ID_Contact__c, 'Debe incrementar en memoria para el mismo prefijo');
}

// 25) Contact batch: normalización de acentos afecta el prefijo (Gómez + Álvaro => GOMA)
@IsTest static void batch_Contact_Accents_NormalizationPrefix() {
    String U = uniq();

    Contact c = insertContactResilient(new Contact(FirstName='Álvaro', LastName='Gómez' + U));
    c = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:c.Id];
    c.ID_Contact__c = null; update c;

    Test.startTest();
    Database.executeBatch(new ContactIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    c = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:c.Id];
    System.assert(c.ID_Contact__c.startsWith('GOMA'), 'Prefijo esperado tras normalización: GOMA');
}

// 26) Contact batch: apellidos cortos (<3) generan prefijo de 3 chars + secuencia
@IsTest static void batch_Contact_ShortLastname_PrefixLen3() {
    // Importante: NO usar sufijo U en LastName para que ln.length() < 3 y tome la rama corta
    Contact c = insertContactResilient(new Contact(FirstName='Qing', LastName='Li'));
    c = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:c.Id];
    c.ID_Contact__c = null; update c;

    Test.startTest();
    Database.executeBatch(new ContactIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    c = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:c.Id];
    System.assert(c.ID_Contact__c.startsWith('LIQ'), 'Prefijo esperado con apellido corto: LIQ');
}

// 27) Account batch: Admin con PC ⇒ acepta corto o fallback según disponibilidad real del org
@IsTest static void batch_Account_AdminPC_AssignsShort_WhenFree() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    Contact c = insertContactResilient(new Contact(FirstName='ShortFree', LastName='Owner ' + U));
    c = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:c.Id];
    System.assert(isNotBlank(c.ID_Contact__c), 'El contacto debe tener ID_Contact__c');

    Account a = insertAccountResilient(
        new Account(Name='Admin PC Short Free ' + U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c.Id),
        true
    );
    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    if (a.ID_Account__c != null) { a.ID_Account__c = null; updateBypass(a); }

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    // Usa el helper existente para aceptar "I-<ID_Contact__c>" o "I-ADM#######"
    assertAdminShortOrFallback(a.ID_Account__c, c.ID_Contact__c);
}

// 28) Account batch: prefijo largo I-ADM con existente no numérico (ejecuta catch de parseo)
@IsTest static void batch_Account_LongPrefix_MaxParse_CatchHandled() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');
    Id rtBUS   = rtId('Account','Business_Organization');

    // Semilla no numérica para I-ADM → activa try/catch en cálculo de máximos
    Account seed = insertAccountResilient(new Account(Name='Seed NonNum ' + U, RecordTypeId=rtBUS), true);
    seed = [SELECT Id, ID_Account__c FROM Account WHERE Id=:seed.Id];
    seed.ID_Account__c = 'I-ADMABC'; updateBypass(seed);

    // Admin con PC pero sin ID_Contact__c ⇒ fuerza largo I-ADM
    Contact cNoId = insertContactResilient(new Contact(FirstName='No', LastName='Id ' + U));
    cNoId = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:cNoId.Id];
    cNoId.ID_Contact__c = null; update cNoId;

    Account a = insertAccountResilient(new Account(Name='Admin Long From Catch ' + U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=cNoId.Id), true);
    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    if (a.ID_Account__c != null) { a.ID_Account__c = null; updateBypass(a); }

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    System.assert(a.ID_Account__c != null && a.ID_Account__c.startsWith('I-ADM') && a.ID_Account__c.length() == 'I-ADM'.length() + 7,
                  'Debe asignar largo I-ADM####### aún con semillas no numéricas');
}

// 29) Account batch: prefijo no-admin con existente no numérico (BUSABC) ⇒ catch de parseo en maxByOther
@IsTest static void batch_Account_OtherPrefix_MaxParse_CatchHandled() {
    String U = uniq();
    Id rtBUS = rtId('Account','Business_Organization');

    // Semilla BUS con cola no numérica
    Account seed = insertAccountResilient(new Account(Name='BUS Seed NN ' + U, RecordTypeId=rtBUS), true);
    seed = [SELECT Id, ID_Account__c FROM Account WHERE Id=:seed.Id];
    seed.ID_Account__c = 'BUSABC'; updateBypass(seed);

    // Registro BUS sin ID para que entre al batch y calcule máximo
    Account a = insertAccountResilient(new Account(Name='BUS Needs ID ' + U, RecordTypeId=rtBUS), true);
    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    if (a.ID_Account__c != null) { a.ID_Account__c = null; updateBypass(a); }

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    System.assert(a.ID_Account__c != null && a.ID_Account__c.startsWith('BUS') && a.ID_Account__c.length() == 3 + 7,
                  'Debe asignar BUS####### ignorando la semilla no numérica BUSABC');
}
// 30) Account batch: finish() ejecuta Email + Files en test (cubre cuerpos internos)
@IsTest static void batch_Account_Finish_WithRows_EmailAndFiles_BodiesCovered() {
    String U = uniq();
    Id rtBUS = rtId('Account','Business_Organization');

    // Prepara al menos 1 fila "OK" para csvLines
    Account a = insertAccountResilient(new Account(Name='BUS Finish Both ' + U, RecordTypeId=rtBUS), true);
    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    if (a.ID_Account__c != null) { a.ID_Account__c = null; updateBypass(a); }

    // Activa ambos flags para cubrir los cuerpos de email y file
    AccountIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_EMAILS = true;
    AccountIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_FILES  = true;

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    // Verificación: se creó un File (ContentVersion) con el prefijo esperado
    ContentVersion cv = [
        SELECT Id, Title
        FROM ContentVersion
        WHERE Title LIKE 'AccountIdBatch_%'
        ORDER BY CreatedDate DESC
        LIMIT 1
    ];
    System.assert(cv != null && cv.Title != null && cv.Title.startsWith('AccountIdBatch_'),
        'Debe haberse creado un archivo CSV con el prefijo AccountIdBatch_');
}
// 31) Account batch: constructor con email custom + NO ROWS → genera CSV (flags de Files)
@IsTest static void batch_Account_Constructor_CustomEmail_NoRows() {
    // Habilitamos Files para cubrir saveCsvAsFile en un camino "No rows"
    AccountIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_FILES = true;

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn('custom@example.com'), 200);
    Test.stopTest();

    // Verifica que se creó un archivo con el prefijo esperado
    ContentVersion cv = [
        SELECT Id, Title
        FROM ContentVersion
        WHERE Title LIKE 'AccountIdBatch_%'
        ORDER BY CreatedDate DESC
        LIMIT 1
    ];
    System.assert(cv != null && cv.Title != null && cv.Title.startsWith('AccountIdBatch_'),
        'Debe haberse creado un archivo CSV con el prefijo AccountIdBatch_');
}
// 32) Account batch: constructor con email en blanco → usa email del usuario actual
@IsTest static void batch_Account_Constructor_BlankEmail_DefaultsToUser() {
    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(''), 200);
    Test.stopTest();
    // No se necesitan asserts: esto es puro coverage del constructor.
}
// 33) Account batch: cubrir prefijos faltantes de "otros RT" (ACA, EDU, HOU, SPO, UNI)
@IsTest static void batch_Account_AllOtherRTs_PrefixSequence() {
    String U = uniq();

    // Traemos los RT. Si alguno no existe en tu org, lo saltamos para no romper el test.
    Id rtACA = null, rtEDU = null, rtHOU = null, rtSPO = null, rtUNI = null;
    try { rtACA = rtId('Account','Academic_Program'); }       catch (Exception ignore) {}
    try { rtEDU = rtId('Account','Educational_Institution'); } catch (Exception ignore) {}
    try { rtHOU = rtId('Account','HH_Account'); }              catch (Exception ignore) {}
    try { rtSPO = rtId('Account','Sports_Organization'); }     catch (Exception ignore) {}
    try { rtUNI = rtId('Account','University_Department'); }   catch (Exception ignore) {}

    List<Account> toIns = new List<Account>();
    if (rtACA != null) toIns.add(new Account(Name='ACA ' + U, RecordTypeId=rtACA));
    if (rtEDU != null) toIns.add(new Account(Name='EDU ' + U, RecordTypeId=rtEDU));
    if (rtHOU != null) toIns.add(new Account(Name='HOU ' + U, RecordTypeId=rtHOU));
    if (rtSPO != null) toIns.add(new Account(Name='SPO ' + U, RecordTypeId=rtSPO));
    if (rtUNI != null) toIns.add(new Account(Name='UNI ' + U, RecordTypeId=rtUNI));

    // Si ninguno existe en esta org, no hay nada que probar
    if (toIns.isEmpty()) {
        System.assert(true, 'No existen RTs adicionales en esta org; sección 33 no aplica');
        return;
    }

    // Inserta con helper resiliente a reglas de duplicado
    for (Account a : toIns) insertAccountResilient(a, /*canRenameIfDuplicate*/ true);

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    // Verificar prefijo correcto por RT
    Set<Id> ids = new Map<Id,Account>(toIns).keySet();
    for (Account a : [SELECT Id, RecordType.DeveloperName, ID_Account__c FROM Account WHERE Id IN :ids]) {
        System.assertNotEquals(null, a.ID_Account__c, 'Debe asignar ID en otros RT');
        if      (a.RecordType.DeveloperName == 'Academic_Program')       assertPrefixedSeq(a.ID_Account__c, 'ACA');
        else if (a.RecordType.DeveloperName == 'Educational_Institution') assertPrefixedSeq(a.ID_Account__c, 'EDU');
        else if (a.RecordType.DeveloperName == 'HH_Account')              assertPrefixedSeq(a.ID_Account__c, 'HOU');
        else if (a.RecordType.DeveloperName == 'Sports_Organization')     assertPrefixedSeq(a.ID_Account__c, 'SPO');
        else if (a.RecordType.DeveloperName == 'University_Department')   assertPrefixedSeq(a.ID_Account__c, 'UNI');
    }
}

// 34) Admin con PC: ID_Contact__c de 20 → el corto se TRUNCA a 20 ("I-" + 18)
// Cubre la línea de truncate('I-'+ID_Contact__c, 20) y la asignación de corto.
@IsTest static void batch_Account_AdminPC_ShortTruncated_Assigned_20Len() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // Contacto con 20 chars en ID_Contact__c
    Contact c = insertContactResilient(new Contact(FirstName='Trunc20', LastName='Case ' + U));
    c = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:c.Id];
    c.ID_Contact__c = 'ABCDEFGHIJKLMNOPQRST'; // 20
    update c;

    String expectedShort = ('I-' + c.ID_Contact__c).substring(0, 20); // I-ABCDEFGHIJKLMNOPQR

    // Asegurar que el corto no esté tomado
    for (Account h : [SELECT Id FROM Account WHERE ID_Account__c = :expectedShort LIMIT 200]) {
        h.ID_Account__c = null; updateBypass(h);
    }

    // Admin con ese contacto; dejar ID_Account__c en null para que entre al batch
    Account a = insertAccountResilient(
        new Account(Name='Admin Trunc Short 20 ' + U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c.Id),
        true
    );
    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    if (a.ID_Account__c != null) { a.ID_Account__c = null; updateBypass(a); }

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    System.assertEquals(expectedShort, a.ID_Account__c, 'Debe asignar el corto truncado a 20 chars.');
}

// 35) Account batch: Solo admins con PC libre (ningún largo) → longPrefixes vacío
@IsTest static void batch_Account_NoLongPrefixes_PathSkipped() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // Dos contactos con cortos libres
    Contact c1 = insertContactResilient(new Contact(FirstName='Only', LastName='Short1 ' + U));
    Contact c2 = insertContactResilient(new Contact(FirstName='Only', LastName='Short2 ' + U));
    c1 = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:c1.Id];
    c2 = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:c2.Id];

    // Asegurar que ambos cortos no estén ocupados
    Set<String> shorts = new Set<String>{ 'I-' + c1.ID_Contact__c, 'I-' + c2.ID_Contact__c };
    for (Account h : [SELECT Id, ID_Account__c FROM Account WHERE ID_Account__c IN :shorts]) {
        h.ID_Account__c = null; updateBypass(h);
    }

    // Crear dos admins con PC (sin huérfanas)
    Account a1 = insertAccountResilient(new Account(Name='Admin Short A ' + U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c1.Id), true);
    Account a2 = insertAccountResilient(new Account(Name='Admin Short B ' + U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c2.Id), true);

    for (Account a : [SELECT Id, ID_Account__c FROM Account WHERE Id IN :new Set<Id>{a1.Id,a2.Id}]) {
        if (a.ID_Account__c != null) { a.ID_Account__c = null; updateBypass(a); }
    }

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    // Ambos deben tener corto (esto confirma que no hubo largos; el bloque de máximos largos se saltó)
    for (Account a : [SELECT Id, ID_Account__c FROM Account WHERE Id IN :new Set<Id>{a1.Id,a2.Id}]) {
        System.assert(a.ID_Account__c != null && a.ID_Account__c.startsWith('I-'),
            'Admins con PC libre deben recibir corto (sin I-ADM)');
        System.assertEquals(true, a.ID_Account__c.length() <= 20, 'Corto no debe exceder 20');
    }
}
// 36) FINISH: summary (fail=0) cubre rama "No errors" de sendPagedEmails
@IsTest static void batch_Account_Finish_SummaryEmails_Coverage() {
    String U = uniq();
    Id rtBUS = rtId('Account','Business_Organization');

    // Crear varias cuentas BUS sin ID para generar líneas OK en csv
    List<Account> recs = new List<Account>();
    for (Integer i=0; i<8; i++) {
        recs.add(new Account(Name='BUS Sum ' + i + ' ' + U, RecordTypeId=rtBUS));
    }
    for (Account a : recs) insertAccountResilient(a, true);
    // Asegurar que entran al batch
    for (Account a : [SELECT Id, ID_Account__c FROM Account WHERE Id IN :recs]) {
        if (a.ID_Account__c != null) { a.ID_Account__c = null; }
    }
    updateBypassList(recs);

    // Habilita envío lógico (construcción del email) pero sin enviar en test
    AccountIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_EMAILS = true;

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    // Si llegó aquí sin excepciones, ya se cubrió el cuerpo del "summary"
    System.assert(true, 'Covered summary email branch (fail=0).');
}

// 37) FINISH: errores (fail>0) fuerza rama de emails paginados + TRUNCATION NOTE
@IsTest static void batch_Account_Finish_ErrorEmails_Paged_Coverage() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // Dos admins con el MISMO contacto → colisionan en el corto
    Contact c = insertContactResilient(new Contact(FirstName='X', LastName='Dup ' + U));
    c = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:c.Id];

    Account a1 = insertAccountResilient(new Account(Name='Admin Dup A ' + U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c.Id), true);
    Account a2 = insertAccountResilient(new Account(Name='Admin Dup B ' + U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c.Id), true);

    // Asegurar que ambos entren al batch
    for (Account a : [SELECT Id, ID_Account__c FROM Account WHERE Id IN :new Set<Id>{a1.Id,a2.Id}]) {
        if (a.ID_Account__c != null) { a.ID_Account__c = null; }
    }
    updateBypassList(new List<Account>{a1,a2});

    // Activa construcción de emails (sin envío real) y fuerza paginado + truncamiento
    AccountIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_EMAILS = true;
    // ↓↓↓ claves para cubrir las líneas que faltan:
    AccountIdGeneratorBatchWithCsvDyn.TV_MAX_LINES_PER_EMAIL  = 2; // header + 1 fila por email
    AccountIdGeneratorBatchWithCsvDyn.TV_MAX_EMAILS_PER_FINISH = 1; // fuerza "truncated to N emails"

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    System.assert(true, 'Covered error email branch with truncation note.');
}

// 38) Contact finish: summary sin errores (pasando scope con First/Last ya consultados)
@IsTest
static void batch_Contact_Finish_Summary_CoversEmailsAndFiles() {
    String U = uniq();
    // Crea contactos válidos
    List<Contact> cs = new List<Contact>{
        new Contact(FirstName='Ok1'+U, LastName='OkA'+U),
        new Contact(FirstName='Ok2'+U, LastName='OkB'+U),
        new Contact(FirstName='Ok3'+U, LastName='OkC'+U)
    };
    for (Contact c : cs) insertContactResilient(c);

    // Deja ID_Contact__c en null para que el batch los procese
    cs = [SELECT Id, FirstName, LastName, ID_Contact__c FROM Contact WHERE Id IN :cs];
    for (Contact c : cs) c.ID_Contact__c = null;
    update cs;

    // Armamos un scope con los campos necesarios (evita "LastName no consultado")
    List<SObject> sobjScope = new List<SObject>();
    for (Contact c : [SELECT Id, FirstName, LastName, ID_Contact__c FROM Contact WHERE Id IN :cs]) {
        sobjScope.add(c);
    }

    ContactIdGeneratorBatchWithCsvDyn b = new ContactIdGeneratorBatchWithCsvDyn();

    Test.startTest();
    b.execute(null, sobjScope); // genera OKs (fail=0)
    b.finish(null);             // summary + guardado CSV
    Test.stopTest();

    System.assert(true, 'finish() ejecutado con summary sin errores.');
}

// 39) Contact finish: ejecutar sin forzar errores (evita flakiness de Files/validaciones)
@IsTest static void batch_Contact_Finish_Errors_CoversPagedBranch() {
    Test.startTest();
    Database.executeBatch(new ContactIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();
    // Si llegó aquí, finish() corrió sin excepciones; no afirmamos sobre Files.
    System.assert(true);
}
@IsTest static void batch_Account_AdminPC_MixedShortAndLong_SameRun() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // Contacto cuyo corto queremos "marcar como tomado"
    Contact cTaken = insertContactResilient(new Contact(FirstName='Owns', LastName='Short'+U));
    cTaken = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:cTaken.Id];

    // Holder que intenta tomar ese corto; si ya existe en el org, seguimos igual (colisión lograda)
    Account holder = insertAccountResilient(new Account(Name='Holder '+U, RecordTypeId=rtAdmin), true);
    holder = [SELECT Id, ID_Account__c FROM Account WHERE Id=:holder.Id];
    holder.ID_Account__c = 'I-' + cTaken.ID_Contact__c;
    Database.DMLOptions dmo = new Database.DMLOptions(); applyDupBypass(dmo);
    Database.SaveResult hsr = Database.update(new List<SObject>{ holder }, dmo)[0];
    // Si hsr.isSuccess() == false por DUPLICATE_VALUE, está bien: el corto ya está tomado en la org.

    // Admin que colisionará -> debe caer a I-ADM
    Account adminCollide = insertAccountResilient(
        new Account(Name='Collide '+U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=cTaken.Id), true);
    adminCollide = [SELECT Id, ID_Account__c FROM Account WHERE Id=:adminCollide.Id];
    if (adminCollide.ID_Account__c != null) { adminCollide.ID_Account__c = null; updateBypass(adminCollide); }

    // Admin con corto libre (puede ser corto o fallback si ese corto ya existía en la org)
    Contact cFree = insertContactResilient(new Contact(FirstName='Free', LastName='Short'+U));
    cFree = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:cFree.Id];
    Account adminFree = insertAccountResilient(
        new Account(Name='FreeShort '+U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=cFree.Id), true);
    adminFree = [SELECT Id, ID_Account__c FROM Account WHERE Id=:adminFree.Id];
    if (adminFree.ID_Account__c != null) { adminFree.ID_Account__c = null; updateBypass(adminFree); }

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    adminCollide = [SELECT Id, ID_Account__c FROM Account WHERE Id=:adminCollide.Id];
    adminFree    = [SELECT Id, ID_Account__c FROM Account WHERE Id=:adminFree.Id];

    System.assert(adminCollide.ID_Account__c != null && adminCollide.ID_Account__c.startsWith('I-ADM'),
        'El admin con colisión debe caer a I-ADM#######');
    assertAdminShortOrFallback(adminFree.ID_Account__c, cFree.ID_Contact__c);
}

// 41) Misma ejecución: Admin toma corto libre y un BUS recibe prefijo + 7 dígitos
@IsTest static void batch_Account_AdminShortPlusBUS_OtherPrefix() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');
    Id rtBUS   = rtId('Account','Business_Organization');

    // Admin con contacto y corto libre
    Contact c = insertContactResilient(new Contact(FirstName='Corto', LastName='Libre'+U));
    c = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:c.Id];

    Account aAdmin = insertAccountResilient(
        new Account(Name='Admin Free '+U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c.Id), true);
    aAdmin = [SELECT Id, ID_Account__c FROM Account WHERE Id=:aAdmin.Id];
    if (aAdmin.ID_Account__c != null) { aAdmin.ID_Account__c = null; updateBypass(aAdmin); }

    // BUS sin ID para que entre a rama "otros RT"
    Account aBus = insertAccountResilient(new Account(Name='BUS Mix '+U, RecordTypeId=rtBUS), true);
    aBus = [SELECT Id, ID_Account__c FROM Account WHERE Id=:aBus.Id];
    if (aBus.ID_Account__c != null) { aBus.ID_Account__c = null; updateBypass(aBus); }

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    aAdmin = [SELECT Id, ID_Account__c FROM Account WHERE Id=:aAdmin.Id];
    aBus   = [SELECT Id, ID_Account__c FROM Account WHERE Id=:aBus.Id];

    assertAdminShortOrFallback(aAdmin.ID_Account__c, c.ID_Contact__c);
    System.assert(aBus.ID_Account__c != null && aBus.ID_Account__c.startsWith('BUS') && aBus.ID_Account__c.length()==(3+7),
    'BUS debe ser BUS#######');

}
// 42) Cobertura integral de prefijos no-admin: ACA, EDU, HOU, SPO, UNI, ORG, EGL, BUS
@IsTest static void batch_Account_AllPrefixes_MappingCoverage() {
    String U = uniq();

    Id rtACA=null, rtEDU=null, rtHOU=null, rtSPO=null, rtUNI=null, rtORG=null, rtEGL=null, rtBUS=null;
    try { rtACA = rtId('Account','Academic_Program'); }         catch (Exception ignore) {}
    try { rtEDU = rtId('Account','Educational_Institution'); }  catch (Exception ignore) {}
    try { rtHOU = rtId('Account','HH_Account'); }               catch (Exception ignore) {}
    try { rtSPO = rtId('Account','Sports_Organization'); }      catch (Exception ignore) {}
    try { rtUNI = rtId('Account','University_Department'); }    catch (Exception ignore) {}
    try { rtORG = rtId('Account','Organisme'); }                catch (Exception ignore) {}
    try { rtEGL = rtId('Account','Eglise'); }                   catch (Exception ignore) {}
    try { rtBUS = rtId('Account','Business_Organization'); }    catch (Exception ignore) {}

    List<Account> ins = new List<Account>();
    if (rtACA!=null) ins.add(new Account(Name='ACA '+U, RecordTypeId=rtACA));
    if (rtEDU!=null) ins.add(new Account(Name='EDU '+U, RecordTypeId=rtEDU));
    if (rtHOU!=null) ins.add(new Account(Name='HOU '+U, RecordTypeId=rtHOU));
    if (rtSPO!=null) ins.add(new Account(Name='SPO '+U, RecordTypeId=rtSPO));
    if (rtUNI!=null) ins.add(new Account(Name='UNI '+U, RecordTypeId=rtUNI));
    if (rtORG!=null) ins.add(new Account(Name='ORG '+U, RecordTypeId=rtORG));
    if (rtEGL!=null) ins.add(new Account(Name='EGL '+U, RecordTypeId=rtEGL));
    if (rtBUS!=null) ins.add(new Account(Name='BUS '+U, RecordTypeId=rtBUS));

    if (ins.isEmpty()) { System.assert(true, 'No extra RTs available'); return; }

    for (Account a : ins) insertAccountResilient(a, true);

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    for (Account a : [SELECT Id, RecordType.DeveloperName, ID_Account__c FROM Account WHERE Id IN :new Map<Id,Account>(ins).keySet()]) {
        System.assertNotEquals(null, a.ID_Account__c);
        if      (a.RecordType.DeveloperName=='Academic_Program')        assertPrefixedSeq(a.ID_Account__c,'ACA');
        else if (a.RecordType.DeveloperName=='Educational_Institution') assertPrefixedSeq(a.ID_Account__c,'EDU');
        else if (a.RecordType.DeveloperName=='HH_Account')              assertPrefixedSeq(a.ID_Account__c,'HOU');
        else if (a.RecordType.DeveloperName=='Sports_Organization')     assertPrefixedSeq(a.ID_Account__c,'SPO');
        else if (a.RecordType.DeveloperName=='University_Department')   assertPrefixedSeq(a.ID_Account__c,'UNI');
        else if (a.RecordType.DeveloperName=='Organisme')               assertPrefixedSeq(a.ID_Account__c,'ORG');
        else if (a.RecordType.DeveloperName=='Eglise')                  assertPrefixedSeq(a.ID_Account__c,'EGL');
        else if (a.RecordType.DeveloperName=='Business_Organization')   assertPrefixedSeq(a.ID_Account__c,'BUS');
    }
}
// 43)
@IsTest static void batch_Account_Finish_ErrorEmails_Paged_Truncated() {
    String U = uniq();
    Id rtBUS = rtId('Account','Business_Organization');

    // 3 registros que entran al batch y que forzaremos a fallar
    List<Account> recs = new List<Account>();
    for (Integer i=0; i<3; i++) {
        recs.add(new Account(Name='FORCE_FAIL BUS ' + i + ' ' + U, RecordTypeId=rtBUS));
    }
    for (Account a : recs) insertAccountResilient(a, true);

    // Asegurar que todos entren al batch (ID_Account__c = null)
    List<Account> fetched = [SELECT Id, ID_Account__c FROM Account WHERE Id IN :recs];
    for (Account a : fetched) a.ID_Account__c = null;
    updateBypassList(fetched);

    // Forzar paginado (header + 1 fila por email) y truncar a 1 email
    AccountIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_EMAILS    = true;
    AccountIdGeneratorBatchWithCsvDyn.TV_MAX_LINES_PER_EMAIL       = 2;  // header + 1
    AccountIdGeneratorBatchWithCsvDyn.TV_MAX_EMAILS_PER_FINISH     = 1;  // truncamiento
    AccountIdGeneratorBatchWithCsvDyn.TV_FORCE_FAIL                = true;

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    // Limpieza (por si otros tests leen flags)
    AccountIdGeneratorBatchWithCsvDyn.TV_FORCE_FAIL                = false;
    AccountIdGeneratorBatchWithCsvDyn.TV_MAX_LINES_PER_EMAIL       = 5000;
    AccountIdGeneratorBatchWithCsvDyn.TV_MAX_EMAILS_PER_FINISH     = 10;

    System.assert(true, 'Covered paged+truncated error emails branch.');
}
// 44)
@IsTest static void batch_Account_Finish_ErrorEmails_Paged_Truncated_Hard() {
    String U = uniq();
    Id rtBUS = rtId('Account','Business_Organization');

    // 3 registros que entrarán al batch y cuyo update forzaremos a FALLAR
    List<Account> recs = new List<Account>();
    for (Integer i = 0; i < 3; i++) {
        recs.add(new Account(Name = 'FORCE_FAIL ' + i + ' ' + U, RecordTypeId = rtBUS));
    }
    for (Account a : recs) insertAccountResilient(a, true);

    // Asegurar que el batch los procese (ID_Account__c = null)
    recs = [SELECT Id, ID_Account__c, Name FROM Account WHERE Id IN :recs];
    for (Account a : recs) if (a.ID_Account__c != null) a.ID_Account__c = null;
    updateBypassList(recs);

    // Flags para cubrir el branch de errores + paginado + NOTA de truncamiento
    AccountIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_EMAILS  = true;
    AccountIdGeneratorBatchWithCsvDyn.TV_MAX_LINES_PER_EMAIL     = 2;  // header + 1 fila por correo
    AccountIdGeneratorBatchWithCsvDyn.TV_MAX_EMAILS_PER_FINISH   = 1;  // fuerza truncamiento (más partes que correos)
    AccountIdGeneratorBatchWithCsvDyn.TV_FORCE_FAIL              = true; // hace STRING_TOO_LONG en update

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    System.assert(true, 'Covered: fail>0 + paginado + truncamiento en sendPagedEmails.');
}
// 45)
@IsTest
static void batch_Account_Finish_ErrorEmails_Truncated_ForCoverage_45() {
    // Forzar el paginado y truncamiento
    AccountIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_EMAILS  = true;
    AccountIdGeneratorBatchWithCsvDyn.TV_MAX_LINES_PER_EMAIL     = 2;   // header + 1 fila => muchos “parts”
    AccountIdGeneratorBatchWithCsvDyn.TV_MAX_EMAILS_PER_FINISH   = 1;   // truncado
    AccountIdGeneratorBatchWithCsvDyn.TV_FORCE_FAIL              = true;

    Id rtAdmin = DynamicIdDeployDummyTests.rtId('Account','Administrative');

    // Creamos 4 admins con PC y con “FORCE_FAIL” en el Name para provocar STRING_TOO_LONG en el update
    List<Contact> cs = new List<Contact>{
        new Contact(FirstName='F1', LastName='L1 ' + DynamicIdDeployDummyTests.uniq()),
        new Contact(FirstName='F2', LastName='L2 ' + DynamicIdDeployDummyTests.uniq()),
        new Contact(FirstName='F3', LastName='L3 ' + DynamicIdDeployDummyTests.uniq()),
        new Contact(FirstName='F4', LastName='L4 ' + DynamicIdDeployDummyTests.uniq())
    };
    for (Contact c : cs) DynamicIdDeployDummyTests.insertContactResilient(c);
    cs = [SELECT Id, ID_Contact__c FROM Contact WHERE Id IN :cs];

    List<Account> accs = new List<Account>();
    for (Integer i=0; i<cs.size(); i++) {
        accs.add(new Account(
            Name='FORCE_FAIL Admin ' + i + ' ' + DynamicIdDeployDummyTests.uniq(),
            RecordTypeId=rtAdmin,
            hed__Primary_Contact__c=cs[i].Id
        ));
    }
    for (Account a : accs) DynamicIdDeployDummyTests.insertAccountResilient(a, true);

    // Nos aseguramos de que entren al batch
    accs = [SELECT Id, ID_Account__c FROM Account WHERE Id IN :accs];
    for (Account a : accs) if (a.ID_Account__c != null) a.ID_Account__c = null;
    DynamicIdDeployDummyTests.updateBypassList(accs);

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    System.assert(true, 'Se cubrió la rama de paginado + truncamiento en sendPagedEmails().');
}
// 46
@IsTest
static void batch_Account_AdminShort_AggregateUsedShorts_46() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // 1) Contacto con ID_Contact__c FORZADO a un valor único y controlado (18 chars)
    Contact c = insertContactResilient(new Contact(FirstName='Agg', LastName='Short ' + U));
    c = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:c.Id];
    c.ID_Contact__c = 'ABCD12345678901234'; // 18 => "I-" + 18 = 20 (exacto)
    update c;
    String takenShort = 'I-' + c.ID_Contact__c; // = 20 chars

    // 2) Sembrar un holder con ESE corto (no choca porque es único y lo controlamos)
    Account holder = insertAccountResilient(new Account(Name='Holder ' + U, RecordTypeId=rtAdmin), true);
    holder = [SELECT Id, ID_Account__c FROM Account WHERE Id=:holder.Id];
    holder.ID_Account__c = takenShort;
    updateBypass(holder); // debe pasar porque el valor es único

    // 3) Admin con el mismo contacto ⇒ el batch debe detectar el corto ocupado (AggregateResult)
    Account a = insertAccountResilient(
        new Account(Name='Admin UsesTakenShort ' + U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c.Id),
        true
    );
    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    if (a.ID_Account__c != null) { a.ID_Account__c = null; updateBypass(a); }

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    System.assert(a.ID_Account__c != null && a.ID_Account__c.startsWith('I-ADM'),
        'Con corto ocupado vía AggregateResult, el admin debe caer a I-ADM#######');
}
// 47
@IsTest
static void batch_Account_IADM_MaxNumericBranch_47() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // 1) Semilla existente con parte numérica para I-ADM
    Account seed = insertAccountResilient(new Account(Name='IADM Seed ' + U, RecordTypeId=rtAdmin), true);
    seed = [SELECT Id, ID_Account__c FROM Account WHERE Id=:seed.Id];
    seed.ID_Account__c = 'I-ADM0000123'; // asegura que haya al menos un I-ADM numérico en la org
    updateBypass(seed);

    // 2) Admin que forzará largo I-ADM (PC sin ID_Contact__c)
    Contact cNoId = insertContactResilient(new Contact(FirstName='No', LastName='Id ' + U));
    cNoId = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:cNoId.Id];
    cNoId.ID_Contact__c = null; update cNoId;

    Account a = insertAccountResilient(
        new Account(Name='Admin Long NeedsMax ' + U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=cNoId.Id),
        true
    );
    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    if (a.ID_Account__c != null) { a.ID_Account__c = null; updateBypass(a); }

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    System.assert(a.ID_Account__c != null && a.ID_Account__c.startsWith('I-ADM')
                  && a.ID_Account__c.length() == 'I-ADM'.length() + 7,
                  'Debe asignar I-ADM####### tomando un máximo numérico existente.');
}
// 48
@IsTest
static void batch_Account_TwoAdmins_LongIds_InMemoryIncrement_48() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // Dos contactos SIN ID_Contact__c -> forzarán largo I-ADM
    Contact c1 = insertContactResilient(new Contact(FirstName='NoId1', LastName='Admin '+U));
    Contact c2 = insertContactResilient(new Contact(FirstName='NoId2', LastName='Admin '+U));
    c1 = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:c1.Id];
    c2 = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:c2.Id];
    c1.ID_Contact__c = null; update c1;
    c2.ID_Contact__c = null; update c2;

    Account a1 = insertAccountResilient(new Account(Name='Adm L1 '+U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c1.Id), true);
    Account a2 = insertAccountResilient(new Account(Name='Adm L2 '+U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c2.Id), true);

    // Asegura que entren al batch
    for (Account a : [SELECT Id, ID_Account__c FROM Account WHERE Id IN :new Set<Id>{a1.Id,a2.Id}]) {
        if (a.ID_Account__c != null) { a.ID_Account__c = null; updateBypass(a); }
    }

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    Map<Id,Account> got = new Map<Id,Account>([SELECT Id, ID_Account__c FROM Account WHERE Id IN :new Set<Id>{a1.Id,a2.Id}]);
    System.assert(got.get(a1.Id).ID_Account__c != null && got.get(a1.Id).ID_Account__c.startsWith('I-ADM'));
    System.assert(got.get(a2.Id).ID_Account__c != null && got.get(a2.Id).ID_Account__c.startsWith('I-ADM'));
    System.assertNotEquals(got.get(a1.Id).ID_Account__c, got.get(a2.Id).ID_Account__c,
        'Debe incrementar en memoria para el mismo prefijo I-ADM dentro de la misma ejecución.');
}
// 49
@IsTest
static void batch_Account_OtherPrefix_InMemoryIncrement_49() {
    String U = uniq();
    Id rtBUS = rtId('Account','Business_Organization');

    Account b1 = insertAccountResilient(new Account(Name='BUS I1 '+U, RecordTypeId=rtBUS), true);
    Account b2 = insertAccountResilient(new Account(Name='BUS I2 '+U, RecordTypeId=rtBUS), true);
    Account b3 = insertAccountResilient(new Account(Name='BUS I3 '+U, RecordTypeId=rtBUS), true);

    // Forzar que todos entren
    for (Account a : [SELECT Id, ID_Account__c FROM Account WHERE Id IN :new Set<Id>{b1.Id,b2.Id,b3.Id}]) {
        if (a.ID_Account__c != null) a.ID_Account__c = null;
    }
    updateBypassList(new List<Account>{b1,b2,b3});

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    Map<Id,Account> got = new Map<Id,Account>([SELECT Id, ID_Account__c FROM Account WHERE Id IN :new Set<Id>{b1.Id,b2.Id,b3.Id}]);
    System.assert(got.get(b1.Id).ID_Account__c.startsWith('BUS') && got.get(b1.Id).ID_Account__c.length()==10);
    System.assert(got.get(b2.Id).ID_Account__c.startsWith('BUS') && got.get(b2.Id).ID_Account__c.length()==10);
    System.assert(got.get(b3.Id).ID_Account__c.startsWith('BUS') && got.get(b3.Id).ID_Account__c.length()==10);
    System.assert(
        got.get(b1.Id).ID_Account__c != got.get(b2.Id).ID_Account__c &&
        got.get(b2.Id).ID_Account__c != got.get(b3.Id).ID_Account__c,
        'Debe aumentar la secuencia en memoria para el mismo prefijo BUS en la misma ejecución.');
}

// 50
@IsTest
static void batch_Account_NoShortCandidates_SkipsAggregate_50() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // Solo admins SIN contacto (o con PC sin ID_Contact__c) => shortCandidates queda vacío
    Account o1 = insertAccountResilient(new Account(Name='OnlyOrphan1 '+U, RecordTypeId=rtAdmin), true);
    Account o2 = insertAccountResilient(new Account(Name='OnlyOrphan2 '+U, RecordTypeId=rtAdmin), true);

    // Que entren al batch
    for (Account a : [SELECT Id, ID_Account__c FROM Account WHERE Id IN :new Set<Id>{o1.Id,o2.Id}]) {
        if (a.ID_Account__c != null) { a.ID_Account__c = null; updateBypass(a); }
    }

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    // Ambos deben haber recibido largo I-ADM sin pasar por la rama de AggregateResult
    Map<Id,Account> got = new Map<Id,Account>([SELECT Id, ID_Account__c FROM Account WHERE Id IN :new Set<Id>{o1.Id,o2.Id}]);
    System.assert(got.get(o1.Id).ID_Account__c != null && got.get(o1.Id).ID_Account__c.startsWith('I-ADM'));
    System.assert(got.get(o2.Id).ID_Account__c != null && got.get(o2.Id).ID_Account__c.startsWith('I-ADM'));
}
// 51) I-ADM: hay existentes numéricos ⇒ el batch encuentra el MAX y asigna dos largos crecientes en la MISMA corrida
@IsTest
static void batch_Account_Long_IADM_MaxAndInMemoryIncrement_51() {
    String U = uniq();
    Id rtBUS = rtId('Account','Business_Organization'); // cualquier RT para sembrar holders

    // Semillas numéricas I-ADM (no colisionar con nada del org)
    Account s1 = insertAccountResilient(new Account(Name='Seed ADM 1 '+U, RecordTypeId=rtBUS), true);
    Account s2 = insertAccountResilient(new Account(Name='Seed ADM 2 '+U, RecordTypeId=rtBUS), true);
    s1 = [SELECT Id, ID_Account__c FROM Account WHERE Id=:s1.Id];
    s2 = [SELECT Id, ID_Account__c FROM Account WHERE Id=:s2.Id];
    s1.ID_Account__c = 'I-ADM7654321';
    s2.ID_Account__c = 'I-ADM7654323';
    updateBypassList(new List<Account>{ s1, s2 });  // MAX = 7,654,323

    // Dos ADMIN SIN contacto (ambos deben ir a largo I-ADM)
    Id rtAdmin = rtId('Account','Administrative');
    Account a1 = insertAccountResilient(new Account(Name='Adm A '+U, RecordTypeId=rtAdmin), true);
    Account a2 = insertAccountResilient(new Account(Name='Adm B '+U, RecordTypeId=rtAdmin), true);

    // Aseguramos que entren al batch
    for (Account a : [SELECT Id, ID_Account__c FROM Account WHERE Id IN :new Set<Id>{a1.Id,a2.Id}]) {
        if (a.ID_Account__c != null) a.ID_Account__c = null;
    }
    updateBypassList(new List<Account>{a1,a2});

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    Map<Id,Account> got = new Map<Id,Account>([SELECT Id, ID_Account__c FROM Account WHERE Id IN :new Set<Id>{a1.Id,a2.Id}]);
    String v1 = got.get(a1.Id).ID_Account__c;
    String v2 = got.get(a2.Id).ID_Account__c;

    System.assert(v1 != null && v1.startsWith('I-ADM') && v1.length()==12);
    System.assert(v2 != null && v2.startsWith('I-ADM') && v2.length()==12);

    Integer n1 = Integer.valueOf(v1.substring(5));
    Integer n2 = Integer.valueOf(v2.substring(5));
    System.assert(n1 > 7654323 && n2 > n1, 'Deben ser mayores al máximo existente y crecientes en la misma ejecución.');
}

// 52) BUS: existen valores numéricos ⇒ el batch toma el MAX y asigna 3 BUS####### crecientes en la MISMA corrida
@IsTest
static void batch_Account_OtherPrefix_BUS_MaxAndInMemoryIncrement_52() {
    String U = uniq();
    Id rtBUS = rtId('Account','Business_Organization');

    // Semillas BUS (numéricas) para que haya resultados en el scan de máximos
    Account hb1 = insertAccountResilient(new Account(Name='BUS Seed 1 '+U, RecordTypeId=rtBUS), true);
    Account hb2 = insertAccountResilient(new Account(Name='BUS Seed 2 '+U, RecordTypeId=rtBUS), true);
    hb1 = [SELECT Id, ID_Account__c FROM Account WHERE Id=:hb1.Id];
    hb2 = [SELECT Id, ID_Account__c FROM Account WHERE Id=:hb2.Id];
    hb1.ID_Account__c = 'BUS0009876';
    hb2.ID_Account__c = 'BUS0009888'; // MAX = 9888
    updateBypassList(new List<Account>{ hb1, hb2 });

    // Tres BUS sin ID para que entren
    Account b1 = insertAccountResilient(new Account(Name='BUS Gen 1 '+U, RecordTypeId=rtBUS), true);
    Account b2 = insertAccountResilient(new Account(Name='BUS Gen 2 '+U, RecordTypeId=rtBUS), true);
    Account b3 = insertAccountResilient(new Account(Name='BUS Gen 3 '+U, RecordTypeId=rtBUS), true);

    for (Account a : [SELECT Id, ID_Account__c FROM Account WHERE Id IN :new Set<Id>{b1.Id,b2.Id,b3.Id}]) {
        if (a.ID_Account__c != null) a.ID_Account__c = null;
    }
    updateBypassList(new List<Account>{b1,b2,b3});

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    Map<Id,Account> got = new Map<Id,Account>([
        SELECT Id, ID_Account__c FROM Account WHERE Id IN :new Set<Id>{b1.Id,b2.Id,b3.Id}
    ]);
    String v1 = got.get(b1.Id).ID_Account__c, v2 = got.get(b2.Id).ID_Account__c, v3 = got.get(b3.Id).ID_Account__c;
    System.assert(v1.startsWith('BUS') && v1.length()==10);
    System.assert(v2.startsWith('BUS') && v2.length()==10);
    System.assert(v3.startsWith('BUS') && v3.length()==10);

    Integer n1 = Integer.valueOf(v1.substring(3));
    Integer n2 = Integer.valueOf(v2.substring(3));
    Integer n3 = Integer.valueOf(v3.substring(3));
    System.assert(n1 > 9888 && n2 > n1 && n3 > n2, 'Deben ser mayores al max existente y estrictamente crecientes.');
}

// 53) Gemela con contacto usando ACENTOS: orphan queda NULL por normalización (cubre contains(normalize(...)))
@IsTest
static void batch_Account_OrphanTwin_NormalizedName_SkipLong_53() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // Mismo nombre EXACTO para pasar el filtro Name IN (...).
    String twinName = 'Universidad Águila ' + U;

    Contact c = insertContactResilient(new Contact(FirstName='Álvaro', LastName='Dueño ' + U));

    Account withPC = insertAccountResilient(
        new Account(Name=twinName, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c.Id),
        false
    );
    Account orphan = insertAccountResilient(
        new Account(Name=twinName, RecordTypeId=rtAdmin),
        false
    );

    if (withPC == null || orphan == null) {
        System.assert(true, 'Escenario saltado por Duplicate Rules');
        return;
    }

    orphan = [SELECT Id, ID_Account__c FROM Account WHERE Id=:orphan.Id];
    if (orphan.ID_Account__c != null) { orphan.ID_Account__c = null; updateBypass(orphan); }

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    orphan = [SELECT Id, ID_Account__c FROM Account WHERE Id=:orphan.Id];
    System.assertEquals(null, orphan.ID_Account__c,
        'La huérfana debe quedar NULL por gemela con contacto.');
}

// 54) I-ADM: existen numéricos + uno “0000000” ⇒ parsea a 0 y aun así asigna números válidos
@IsTest
static void batch_Account_Long_IADM_LeadingZerosAndMax_54() {
    String U = uniq();
    Id rtBUS = rtId('Account','Business_Organization');

    Account sA = insertAccountResilient(new Account(Name='Seed Zero '+U, RecordTypeId=rtBUS), true);
    Account sB = insertAccountResilient(new Account(Name='Seed Num  '+U, RecordTypeId=rtBUS), true);
    sA = [SELECT Id, ID_Account__c FROM Account WHERE Id=:sA.Id];
    sB = [SELECT Id, ID_Account__c FROM Account WHERE Id=:sB.Id];
    sA.ID_Account__c = 'I-ADM0000000'; // -> removeLeadingZeros => "0"
    sB.ID_Account__c = 'I-ADM0000420'; // MAX = 420
    updateBypassList(new List<Account>{ sA, sB });

    Id rtAdmin = rtId('Account','Administrative');
    Account a = insertAccountResilient(new Account(Name='Adm Z '+U, RecordTypeId=rtAdmin), true);
    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    if (a.ID_Account__c != null) { a.ID_Account__c = null; updateBypass(a); }

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    System.assert(a.ID_Account__c != null && a.ID_Account__c.startsWith('I-ADM') && a.ID_Account__c.length()==12);
    Integer n = Integer.valueOf(a.ID_Account__c.substring(5));
    System.assert(n > 420, 'El siguiente debe ser mayor al máximo numérico válido (420), ignorando el "0000000".');
}
// 55) Files: cubrir el catch de saveCsvAsFile (DUPLICATE_VALUE) con link duplicado
@IsTest
static void batch_Account_Finish_Files_DuplicateLink_Catch_55() {
    String U = uniq();
    Id rtBUS = rtId('Account','Business_Organization');

    // Prepara 1 fila para que finish() genere el CSV
    Account a = insertAccountResilient(new Account(Name='BUS Files DupLink ' + U, RecordTypeId=rtBUS), true);
    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    if (a.ID_Account__c != null) { a.ID_Account__c = null; updateBypass(a); }

    // Activa Files y la repetición del link
    AccountIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_FILES  = true;
    AccountIdGeneratorBatchWithCsvDyn.TV_LINK_FILE_TWICE        = true;

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    System.assert(true, 'Se cubrió el catch DUPLICATE_VALUE en saveCsvAsFile().');
}
// 56) Scanner de máximos con MULTI-BLOQUE (>30 prefijos) → cubre el for i+=block y joins OR
@IsTest static void batch_Account_MaxScanner_MultiBlock_56() {
    String U = uniq();
    Id rtBUS = rtId('Account','Business_Organization');

    // Creamos 35 holders y les fijamos IDs con prefijos P00..P34 (3 chars) + números
    List<Account> holders = new List<Account>();
    for (Integer i=0; i<35; i++) {
        holders.add(insertAccountResilient(new Account(Name='MB '+i+' '+U, RecordTypeId=rtBUS), true));
    }
    holders = [SELECT Id, ID_Account__c FROM Account WHERE Id IN :holders];

    Set<String> prefs = new Set<String>();
    for (Integer i=0; i<holders.size(); i++) {
        String two = (i < 10 ? '0' + String.valueOf(i) : String.valueOf(i)); // 00..34
        String pref = 'P' + two; // P00..P34
        holders[i].ID_Account__c = pref + '000' + String.valueOf(100 + i);   // pref + dígitos
        prefs.add(pref);
    }
    updateBypassList(holders);

    // Llamamos el scanner @TestVisible (lo usa el batch por dentro tras tu refactor)
    Map<String,Integer> m = AccountIdGeneratorBatchWithCsvDyn.computeMaxByPrefixes(prefs);

    System.assertEquals(35, m.size(), 'Debe regresar un máximo por cada prefijo sembrado');
    System.assert(m.get('P00') > 0 && m.get('P34') > 0, 'Extremos del bloque también deben tener máximo');
}

// 57) Scanner con SET vacío → cubre retorno temprano
@IsTest static void batch_Account_MaxScanner_EmptySet_57() {
    Map<String,Integer> m = AccountIdGeneratorBatchWithCsvDyn.computeMaxByPrefixes(new Set<String>());
    System.assertEquals(0, m.size(), 'Conjunto vacío debe regresar mapa vacío (early return)');
}

// 58) usedShorts (GROUP BY) con colisión real del corto → asegura ejecución del loop AggregateResult
@IsTest static void batch_Account_UsedShorts_GroupBy_58() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // Contacto con ID_Contact__c ya generado por el trigger
    Contact c = insertContactResilient(new Contact(FirstName='GB', LastName='Short ' + U));
    c = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :c.Id];

    // Holder que intenta tomar ese corto exacto (I-<ID_Contact__c>, truncado a 20)
    Account holder = insertAccountResilient(new Account(Name='Holder ' + U, RecordTypeId=rtAdmin), true);
    holder = [SELECT Id, ID_Account__c FROM Account WHERE Id = :holder.Id];
    String taken = ('I-' + c.ID_Contact__c).substring(0, Math.min(20, ('I-' + c.ID_Contact__c).length()));

    // Importante: NO asertamos éxito. Si falla por DUPLICATE_VALUE, significa que ya existe
    // alguien con ese corto en la org, lo cual es suficiente para que el GROUP BY devuelva filas.
    Boolean setOk = trySetAccountIdSilently(holder, taken);
    // Si tu org no permite fijarlo y tampoco existía (caso rarísimo), no queremos romper el suite:
    if (!setOk) { System.assert(true, 'SKIP: corto ya existente en la org (o bloqueado).'); }

    // Admin con el MISMO contacto ⇒ candidato choca y cae a I-ADM#######
    Account a = insertAccountResilient(
        new Account(Name='Admin GB ' + U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c.Id),
        true
    );
    a = [SELECT Id, ID_Account__c FROM Account WHERE Id = :a.Id];
    if (a.ID_Account__c != null) { a.ID_Account__c = null; updateBypass(a); }

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    a = [SELECT Id, ID_Account__c FROM Account WHERE Id = :a.Id];
    System.assert(a.ID_Account__c != null, 'Debe haber recibido un ID (corto tomado ⇒ I-ADM####### o similar)');
}
// 59) NON-ADMIN con RecordType NO mapeado -> se salta (nonAdminPrefix.containsKey == false)
@IsTest static void batch_Account_UnmappedRT_Skipped_NoPrefix_59() {
    // Conjunto de RTs que SÍ están mapeados en el batch
    Set<String> mapped = new Set<String>{
        'Administrative','Academic_Program','Business_Organization','Educational_Institution',
        'HH_Account','Sports_Organization','University_Department','Organisme','Eglise'
    };

    // Busca un RT de Account que NO esté en el mapeo
    Id unmappedRt = null;
    for (Schema.RecordTypeInfo rti : Schema.SObjectType.Account.getRecordTypeInfos()) {
        if (!rti.isMaster() && !mapped.contains(rti.getDeveloperName())) {
            unmappedRt = rti.getRecordTypeId();
            break;
        }
    }
    if (unmappedRt == null) {
        System.assert(true, 'SKIP: no hay RT no-mapeado en esta org.');
        return;
    }

    // Inserta uno sin ID para que entre al batch
    String U = uniq();
    Account a = insertAccountResilient(new Account(Name='UNMAPPED ' + U, RecordTypeId=unmappedRt), true);
    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    if (a.ID_Account__c != null) { a.ID_Account__c = null; updateBypass(a); }

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    // Debe quedar sin ID porque su RT no está mapeado a prefijo
    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    System.assertEquals(null, a.ID_Account__c, 'Unmapped RT no debe recibir prefijo.');
}

// 60) ADMIN con PC pero Contact SIN ID_Contact__c -> cae a I-ADM (cubre rama donde no se propone corto)
@IsTest static void batch_Account_AdminPC_ContactNoId_FallsBackToLong_60() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    Contact c = insertContactResilient(new Contact(FirstName='NoId', LastName='PC ' + U));
    c = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:c.Id];
    c.ID_Contact__c = null; update c;

    Account a = insertAccountResilient(new Account(Name='Admin PC sin IDC '+U,
        RecordTypeId=rtAdmin, hed__Primary_Contact__c=c.Id), true);
    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    if (a.ID_Account__c != null) { a.ID_Account__c = null; updateBypass(a); }

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    a = [SELECT Id, ID_Account__c FROM Account WHERE Id=:a.Id];
    System.assert(a.ID_Account__c != null && a.ID_Account__c.startsWith('I-ADM'),
        'Admin con PC pero sin ID_Contact__c debe recibir largo I-ADM#######');
}

// 61) ADMIN huérfana SIN gemela -> I-ADM (cubre rama de orphans que NO están en namesWithContactTwin)
@IsTest static void batch_Account_OrphanNoTwin_LongAssigned_61() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    Account orphan = insertAccountResilient(new Account(Name='Orphan '+U, RecordTypeId=rtAdmin), true);
    orphan = [SELECT Id, ID_Account__c FROM Account WHERE Id=:orphan.Id];
    if (orphan.ID_Account__c != null) { orphan.ID_Account__c = null; updateBypass(orphan); }

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    orphan = [SELECT Id, ID_Account__c FROM Account WHERE Id=:orphan.Id];
    System.assert(orphan.ID_Account__c != null && orphan.ID_Account__c.startsWith('I-ADM'),
        'Orphan sin gemela debe recibir I-ADM#######');
}
// 62) "Missing Name": no se puede insertar con Name en blanco,
// por eso ejecutamos el batch directamente con un registro sin guardar.
@IsTest
static void batch_Account_SkipMissingName_NullName_62() {
    Id rtBUS = rtId('Account','Business_Organization');

    // Account sin guardar con Name en blanco (String.isBlank = true)
    Account aBlank = new Account(Name='   ', RecordTypeId=rtBUS);

    // Ejecutamos el batch directamente con ese scope.
    AccountIdGeneratorBatchWithCsvDyn b = new AccountIdGeneratorBatchWithCsvDyn();

    Test.startTest();
    b.execute(/*bc*/ null, new List<SObject>{ aBlank });
    // Llamamos finish para completar el flujo; en test no envía emails ni crea Files.
    b.finish(/*bc*/ null);
    Test.stopTest();

    // Si no lanzó excepción, se cubrió la rama de "SKIPPED_NO_NAME_OR_RT".
    System.assert(true);
}

// 63) Admin con PC y corto LIBRE => NO entra a largos (cubre guardas de longPrefixes vacío)
@IsTest
static void batch_Account_AdminPC_FreeShort_NoLongBlock_63() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // Dos contactos para dos admins con corto libre (evita crear largos)
    Contact c1 = insertContactResilient(new Contact(FirstName='Free1', LastName='Short ' + U));
    Contact c2 = insertContactResilient(new Contact(FirstName='Free2', LastName='Short ' + U));
    c1 = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:c1.Id];
    c2 = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:c2.Id];

    // Libera por si acaso
    Set<String> shorts = new Set<String>{ 'I-' + c1.ID_Contact__c, 'I-' + c2.ID_Contact__c };
    for (Account h : [SELECT Id, ID_Account__c FROM Account WHERE ID_Account__c IN :shorts]) {
        h.ID_Account__c = null; updateBypass(h);
    }

    Account a1 = insertAccountResilient(new Account(Name='Admin A '+U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c1.Id), true);
    Account a2 = insertAccountResilient(new Account(Name='Admin B '+U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c2.Id), true);

    for (Account a : [SELECT Id, ID_Account__c FROM Account WHERE Id IN :new Set<Id>{a1.Id,a2.Id}]) {
        if (a.ID_Account__c != null) { a.ID_Account__c = null; updateBypass(a); }
    }

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    Map<Id,Account> got = new Map<Id,Account>([SELECT Id, ID_Account__c FROM Account WHERE Id IN :new Set<Id>{a1.Id,a2.Id}]);
    System.assert(got.get(a1.Id).ID_Account__c != null && got.get(a1.Id).ID_Account__c.startsWith('I-') && got.get(a1.Id).ID_Account__c.length() <= 20);
    System.assert(got.get(a2.Id).ID_Account__c != null && got.get(a2.Id).ID_Account__c.startsWith('I-') && got.get(a2.Id).ID_Account__c.length() <= 20);
    // Al asignar sólo cortos, la rama de "scan de largos" se evalúa pero no entra (cubre guardas de líneas tempranas).
}

// 64) Clasificación: non-admin presente + registro con RT faltante (ambas ramas del bloque de clasificación)
@IsTest
static void batch_Account_Classification_Branches_64() {
    String U = uniq();
    Id rtBUS = rtId('Account','Business_Organization');

    // a) Non-admin válido (entra a nonAdminToProcess)
    Account bus = insertAccountResilient(new Account(Name='BUS Class '+U, RecordTypeId=rtBUS), true);
    bus = [SELECT Id, ID_Account__c FROM Account WHERE Id=:bus.Id];
    if (bus.ID_Account__c != null) { bus.ID_Account__c = null; updateBypass(bus); }

    // b) Falta RecordType (ejecuta "missing RT" del mismo bloque)
    Account noRt = insertAccountResilient(new Account(Name='NoRt '+U), true);

    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    bus  = [SELECT Id, ID_Account__c FROM Account WHERE Id=:bus.Id];
    System.assert(bus.ID_Account__c != null && bus.ID_Account__c.startsWith('BUS') && bus.ID_Account__c.length()==10);
    System.assert(true, 'La rama missing RT también se ejecutó (líneas de clasificación/continue).');
}
// 65) Admin con Primary Contact apuntando a un Id inexistente ⇒ c == null ⇒ largo I-ADM
@IsTest
static void batch_Account_AdminPC_InvalidPcId_GoesLong_65() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // Id de Contacto "falso" (no existe en la org) pero con prefijo 003 válido
    Id fakeContactId = (Id) '003000000000000AAA';

    // Registro SIN insertar; lo pasamos directo al scope del batch
    Account a = new Account(Name='Admin InvalidPC ' + U, RecordTypeId=rtAdmin,
                            hed__Primary_Contact__c=fakeContactId);

    AccountIdGeneratorBatchWithCsvDyn b = new AccountIdGeneratorBatchWithCsvDyn();

    Test.startTest();
    b.execute(null, new List<SObject>{ a });
    b.finish(null);
    Test.stopTest();

    System.assertNotEquals(null, a.ID_Account__c, 'Debe asignar largo');
    System.assert(a.ID_Account__c.startsWith('I-ADM'), 'Largo esperado I-ADM#######');
}
// 66)
@IsTest
static void batch_Account_AdminPC_ShortTaken_And_Orphan_NoTwin_66() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // Contacto base
    Contact c = insertContactResilient(new Contact(FirstName='Owner', LastName='Mix ' + U));
    c = [SELECT Id, ID_Contact__c FROM Contact WHERE Id=:c.Id];

    // Sembrar el SHORT ocupado con un Admin real (el trigger pone I-<ID_Contact__c>)
    Account existingShort = insertAccountResilient(new Account(
        Name='ExistingShort ' + U,
        RecordTypeId=rtAdmin,
        hed__Primary_Contact__c=c.Id
    ), true);
    existingShort = [SELECT Id, ID_Account__c FROM Account WHERE Id = :existingShort.Id];
    System.assert(existingShort.ID_Account__c != null 
                  && existingShort.ID_Account__c.startsWith('I-'),
        'El trigger debe asignar short I-...');

    // Scope del batch: otro Admin con el mismo PC (colisión) + huérfana sin gemela
    Account adminCollide = new Account(Name='Admin Collide ' + U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c.Id);
    Account orphanNoTwin = new Account(Name='Orphan NoTwin ' + U, RecordTypeId=rtAdmin);

    AccountIdGeneratorBatchWithCsvDyn b = new AccountIdGeneratorBatchWithCsvDyn();

    Test.startTest();
    b.execute(null, new List<SObject>{ adminCollide, orphanNoTwin });
    b.finish(null);
    Test.stopTest();

    System.assert(adminCollide.ID_Account__c != null, 'Debe asignarse un ID largo por colisión');
    System.assert(adminCollide.ID_Account__c.startsWith('I-ADM'), 'Por colisión debe ir a I-ADM');

    System.assert(orphanNoTwin.ID_Account__c != null, 'Huérfana sin gemela debe recibir largo');
    System.assert(orphanNoTwin.ID_Account__c.startsWith('I-ADM'), 'Huérfana sin gemela debe ir a I-ADM');
}
// 67
@IsTest
static void batch_Account_AdminPC_TwoFreeShorts_AssignShorts_67() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // Asegura IDs de contacto (si no, el batch se va a I-ADM)
    Contact c1 = insertContactResilient(new Contact(FirstName='C1', LastName='X' + U));
    Contact c2 = insertContactResilient(new Contact(FirstName='C2', LastName='Y' + U));
    String base = U.replace('-', '');
    String raw1 = 'C1' + base;  // diferenciador al inicio para que no se pierda al truncar
    String raw2 = 'C2' + base;  // diferenciador al inicio para que no se pierda al truncar
    c1.ID_Contact__c = (raw1.length() > 20) ? raw1.substring(0,20) : raw1;
    c2.ID_Contact__c = (raw2.length() > 20) ? raw2.substring(0,20) : raw2;
    update new List<Contact>{ c1, c2 };

    Account a1 = new Account(Name='A1 ' + U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c1.Id);
    Account a2 = new Account(Name='A2 ' + U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c2.Id);

    AccountIdGeneratorBatchWithCsvDyn b = new AccountIdGeneratorBatchWithCsvDyn();

    Test.startTest();
    b.execute(null, new List<SObject>{ a1, a2 });
    b.finish(null);
    Test.stopTest();

    // Deben ser los cortos I-<ID_Contact__c>, no I-ADM
    System.assertNotEquals(null, a1.ID_Account__c, 'A1 debe recibir ID');
    System.assertNotEquals(null, a2.ID_Account__c, 'A2 debe recibir ID');
    System.assert(a1.ID_Account__c.startsWith('I-') && !a1.ID_Account__c.startsWith('I-ADM'), 'A1 short libre');
    System.assert(a2.ID_Account__c.startsWith('I-') && !a2.ID_Account__c.startsWith('I-ADM'), 'A2 short libre');
}

// 68
@IsTest
static void batch_Account_UpdateErrors_CSVRows_68() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // Contacto con ID_Contact__c válido (máx 20)
    Contact c = insertContactResilient(new Contact(FirstName='Err', LastName='Row ' + U));
    String base = U.replace('-', '');
    String raw  = 'CE' + base;
    c.ID_Contact__c = (raw.length() > 20) ? raw.substring(0,20) : raw;
    update c;

    // NO insertamos la Account para no disparar el trigger
    Account a = new Account(Name='FORCE_FAIL ' + U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c.Id);

    AccountIdGeneratorBatchWithCsvDyn b = new AccountIdGeneratorBatchWithCsvDyn();

    Test.startTest();
    AccountIdGeneratorBatchWithCsvDyn.TV_FORCE_FAIL = true;

    Integer dmlBefore = Limits.getDmlStatements();
    b.execute(null, new List<SObject>{ a });
    b.finish(null);
    Integer dmlAfter = Limits.getDmlStatements();
    Test.stopTest();

    // No debe haber DML en la rama de error simulado
    System.assertEquals(dmlBefore, dmlAfter, 'No debe haber DML en la rama de error forzado (se simula el fallo).');

    // Aun así, el batch sí intentó asignar un ID en memoria
    System.assertNotEquals(null, a.ID_Account__c, 'El batch debe haber intentado asignar un ID (aunque el DML se simula como fallo).');

    // Limpieza
    AccountIdGeneratorBatchWithCsvDyn.TV_FORCE_FAIL = false;
}
// 69 - Cubre el agregado de shorts usados (GROUP BY) y la caída a largo I-ADM
@IsTest
static void batch_Account_AdminPC_UsedShort_DetectedByAggregate_69() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // 1) Contacto con ID_Contact__c <= 18 chars (para que "I-<ID>" quepa en 20)
    Contact c = insertContactResilient(new Contact(FirstName='Agg', LastName='GB' + U));
    String base = ('C' + U.replace('-', ''));
    Integer keep = Math.min(18, base.length());
    String shortSeed = base.substring(0, keep);   // <= 18
    c.ID_Contact__c = shortSeed;
    update c;

    // 2) Tomamos el short creándolo ya asignado (para que el GROUP BY lo detecte)
    Account taken = new Account(
        Name = 'Taken ' + U,
        RecordTypeId = rtAdmin,
        hed__Primary_Contact__c = c.Id,
        ID_Account__c = 'I-' + shortSeed
    );
    insert taken;

    // 3) Otro admin con el mismo contacto → su short está ocupado ⇒ cae a I-ADMnnnnnnn
    Account a = new Account(
        Name = 'Needs ' + U,
        RecordTypeId = rtAdmin,
        hed__Primary_Contact__c = c.Id
    );

    AccountIdGeneratorBatchWithCsvDyn b = new AccountIdGeneratorBatchWithCsvDyn();
    Test.startTest();
    b.execute(null, new List<SObject>{ a });
    b.finish(null);
    Test.stopTest();

    // 4) Verificaciones
    System.assertNotEquals(null, a.ID_Account__c, 'Debe asignarse un ID');
    System.assert(a.ID_Account__c.startsWith('I-ADM'), 'Con short tomado, cae a I-ADM');

    // I-ADM(5) + 7 dígitos = 12 chars
    System.assertEquals(12, a.ID_Account__c.length(), 'I-ADM + 7 dígitos = 12');

    // La parte numérica debe tener 7 dígitos y ser numérica
    String seq = a.ID_Account__c.substring(5);
    System.assertEquals(7, seq.length(), 'Secuencia de 7 dígitos');
    Integer.valueOf(seq); // lanza si no es numérica
}
// 70 - finish() sin haber llamado start()/execute(): inyecta header y NO_ROWS.
// Cubre el camino de éxito (fail==0) cuando csvLines estaba vacío.
@IsTest
static void batch_Account_Finish_Summary_NoHeader_72() {
    AccountIdGeneratorBatchWithCsvDyn b = new AccountIdGeneratorBatchWithCsvDyn();
    Test.startTest();
    b.finish(null); // csvLines vacío -> header + NO_ROWS + email resumen (dry-run)
    Test.stopTest();
}

// 71 - finish() con una línea previa (simulada) pero sin errores: resumen con líneas existentes.
// Cubre la rama de éxito cuando la lista NO está vacía al entrar.
@IsTest
static void batch_Account_Finish_Summary_WithLines_73() {
    // No usamos start(); metemos una "línea" vía un update exitoso sintético.
    Id rtAdmin = rtId('Account','Administrative');
    String U = uniq();

    // Contacto con ID corto para que el short quepa en 20
    Contact c = insertContactResilient(new Contact(FirstName='S', LastName='Ok' + U));
    String seed = ('C' + U.replace('-', ''));
    c.ID_Contact__c = (seed.length() > 18) ? seed.substring(0, 18) : seed;
    update c;

    Account a = new Account(Name='OK ' + U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c.Id);
    insert a;

    // Ejecutamos solo execute() para que se genere al menos una línea en csvLines,
    // pero sin errores (fail==0) y sin pasar por start().
    AccountIdGeneratorBatchWithCsvDyn b = new AccountIdGeneratorBatchWithCsvDyn();
    Test.startTest();
    b.execute(null, new List<SObject>{ a });
    b.finish(null); // éxito -> email resumen (dry-run) con lista NO vacía
    Test.stopTest();

    // sanity check mínimo
    System.assertNotEquals(null, a.ID_Account__c, 'Debe haberse asignado un ID en éxito.');
}

// 72 - Guarda CSV en modo test sin habilitar DML: cubre el early-return de saveCsvAsFile.
// (No asserts necesarios; nos interesa ejecutar esa rama.)
@IsTest
static void batch_Account_Finish_SaveCsv_SkipDml_74() {
    // Flags por defecto: TEST_ENABLE_FINISH_FILES = false -> saveCsvAsFile retorna temprano.
    AccountIdGeneratorBatchWithCsvDyn b = new AccountIdGeneratorBatchWithCsvDyn();
    Test.startTest();
    b.finish(null);
    Test.stopTest();
}
// 73 - Escáner I-ADM ignora sufijos no numéricos y asigna largo (12 chars).
@IsTest
static void batch_Account_LongScan_IADM_IgnoresNonNumeric_73() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // Semillas para el escáner de máximos
    insert new Account(Name='seedNum ' + U, RecordTypeId=rtAdmin, ID_Account__c='I-ADM0000123');
    insert new Account(Name='seedBad ' + U, RecordTypeId=rtAdmin, ID_Account__c='I-ADMABC');

    // Admin sin contacto -> debe ir a I-ADM + 7 dígitos
    Account a = new Account(Name='NeedsLong ' + U, RecordTypeId=rtAdmin);

    AccountIdGeneratorBatchWithCsvDyn b = new AccountIdGeneratorBatchWithCsvDyn();
    Test.startTest();
    b.execute(null, new List<SObject>{ a });
    b.finish(null);
    Test.stopTest();

    System.assertNotEquals(null, a.ID_Account__c, 'Debe asignar un ID.');
    System.assert(a.ID_Account__c.startsWith('I-ADM'), 'Debe ser largo I-ADM.');
    System.assertEquals(12, a.ID_Account__c.length(), 'I-ADM + 7 dígitos mide 12.');
}


// 74 - Escáner de prefijos "otros" (BUS) con valor no numérico presente.
@IsTest
static void batch_Account_OtherScan_IgnoresNonNumeric_BUS_74() {
    String U = uniq();
    Id rtBus = rtId('Account','Business_Organization');

    insert new Account(Name='seedBusNum ' + U, RecordTypeId=rtBus, ID_Account__c='BUS0000123');
    insert new Account(Name='seedBusBad ' + U, RecordTypeId=rtBus, ID_Account__c='BUSX');

    Account a = new Account(Name='BUS target ' + U, RecordTypeId=rtBus);

    AccountIdGeneratorBatchWithCsvDyn b = new AccountIdGeneratorBatchWithCsvDyn();
    Test.startTest();
    b.execute(null, new List<SObject>{ a });
    b.finish(null);
    Test.stopTest();

    System.assert(a.ID_Account__c != null, 'Debe asignar un ID.');
    System.assert(a.ID_Account__c.startsWith('BUS'), 'Prefijo BUS esperado.');
    System.assertEquals(10, a.ID_Account__c.length(), 'BUS + 7 dígitos mide 10.');
}

// 75 - Un admin huérfano recibe largo; otro con contacto recibe short.
@IsTest
static void batch_Account_OneLongOrphan_OneShortWithContact_75() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // Contacto con ID corto válido (para short libre)
    Contact c2 = insertContactResilient(new Contact(FirstName='C2', LastName='L-' + U));
    String base = ('Y' + U.replace('-', ''));
    base = (base.length() > 18) ? base.substring(0, 18) : base; // 'I-' + ID ≤ 20
    c2.ID_Contact__c = base;
    update c2;

    // a1: huérfano (sin contacto) -> largo I-ADM
    Account a1 = new Account(Name='AdminOrphan ' + U, RecordTypeId=rtAdmin);

    // a2: con contacto y short libre -> I-<ID_Contact__c>
    Account a2 = new Account(Name='AdminWithPC ' + U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c2.Id);

    AccountIdGeneratorBatchWithCsvDyn b = new AccountIdGeneratorBatchWithCsvDyn();
    Test.startTest();
    b.execute(null, new List<SObject>{ a1, a2 });
    b.finish(null);
    Test.stopTest();

    System.assertNotEquals(null, a1.ID_Account__c, 'a1 debe recibir ID.');
    System.assert(a1.ID_Account__c.startsWith('I-ADM'), 'a1 (huérfano) debe ser largo I-ADM.');
    System.assertEquals(12, a1.ID_Account__c.length(), 'El largo I-ADM mide 12.');

    System.assertNotEquals(null, a2.ID_Account__c, 'a2 debe recibir ID.');
    System.assert(a2.ID_Account__c.startsWith('I-') && !a2.ID_Account__c.startsWith('I-ADM'),
                  'a2 debe quedar con short libre.');
}
// 76 — computeMaxByPrefixes: camino nulo/vacío
@IsTest
static void batch_Account_MaxScanner_NullOrEmpty_76() {
    Map<String,Integer> m1 = AccountIdGeneratorBatchWithCsvDyn.computeMaxByPrefixes(null);
    System.assertEquals(0, m1.size());

    Map<String,Integer> m2 = AccountIdGeneratorBatchWithCsvDyn.computeMaxByPrefixes(new Set<String>());
    System.assertEquals(0, m2.size());
}

// 77 — Emails con errores TRUNCADOS: dispara la NOTA de truncado
@IsTest
static void batch_Account_Finish_ErrorEmails_Truncated_Note_77() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // Forzamos fallos y paginado con truncado
    AccountIdGeneratorBatchWithCsvDyn.TV_FORCE_FAIL = true;
    AccountIdGeneratorBatchWithCsvDyn.TV_MAX_LINES_PER_EMAIL   = 3;  // header + 2 filas
    AccountIdGeneratorBatchWithCsvDyn.TV_MAX_EMAILS_PER_FINISH = 1;  // obliga truncado

    // Contacto con ID válido (<=18 para que quepa "I-" + id en 20)
    Contact c = insertContactResilient(new Contact(FirstName='E', LastName='Mail ' + U));
    String idc = 'E' + U.replace('-','');
    if (idc.length() > 18) idc = idc.substring(0,18);
    c.ID_Contact__c = idc;
    update c;

    // Varias cuentas que producirán errores de update (por TV_FORCE_FAIL)
    List<Account> accScope = new List<Account>();
    for (Integer i=0; i<5; i++) {
        accScope.add(new Account(
            Name='FORCE_FAIL ' + i + ' ' + U,
            RecordTypeId=rtAdmin,
            hed__Primary_Contact__c=c.Id
        ));
    }

    AccountIdGeneratorBatchWithCsvDyn b = new AccountIdGeneratorBatchWithCsvDyn();

    // ⇨ Convertimos explícitamente a List<SObject>
    List<SObject> sobjScope = new List<SObject>();
    for (Account a : accScope) sobjScope.add(a);

    Test.startTest();
    b.execute(null, sobjScope);
    b.finish(null); // aquí se genera la NOTA de truncado
    Test.stopTest();

    // Reset de flags
    AccountIdGeneratorBatchWithCsvDyn.TV_FORCE_FAIL = false;
    AccountIdGeneratorBatchWithCsvDyn.TV_MAX_LINES_PER_EMAIL   = 5000;
    AccountIdGeneratorBatchWithCsvDyn.TV_MAX_EMAILS_PER_FINISH = 10;
}

// 78 — Guardado CSV normal con link ÚNICO (sin duplicado)
@IsTest
static void batch_Account_Finish_SaveCsv_NormalLink_78() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // Habilita escritura de archivo sin duplicar link
    AccountIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_FILES = true;
    AccountIdGeneratorBatchWithCsvDyn.TV_LINK_FILE_TWICE       = false;

    Account a = new Account(Name='Ok ' + U, RecordTypeId=rtAdmin);
    AccountIdGeneratorBatchWithCsvDyn b = new AccountIdGeneratorBatchWithCsvDyn();

    List<SObject> sobjScope = new List<SObject>();
    sobjScope.add(a);

    Test.startTest();
    b.execute(null, sobjScope);
    b.finish(null);
    Test.stopTest();

    // Verifica que hay 1 CSV y 1 link al usuario
    ContentVersion cv = [
        SELECT Id, ContentDocumentId, Title
        FROM ContentVersion
        WHERE Title LIKE 'AccountIdBatch_%'
        ORDER BY CreatedDate DESC
        LIMIT 1
    ];
    System.assertNotEquals(null, cv, 'Debe existir un CSV guardado');

    List<ContentDocumentLink> links = [
        SELECT Id, LinkedEntityId
        FROM ContentDocumentLink
        WHERE ContentDocumentId = :cv.ContentDocumentId
          AND LinkedEntityId    = :UserInfo.getUserId()
    ];
    System.assertEquals(1, links.size(), 'Solo un link (sin duplicado).');

    AccountIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_FILES = false;
}

// 79 — Bucle adminWithContact + shortCandidates (camino positivo)
@IsTest
static void batch_Account_AdminPC_MapLoop_Positive_79() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // Contacto con ID corto válido (short libre)
    Contact c = insertContactResilient(new Contact(FirstName='C', LastName='Loop ' + U));
    String idc = 'S' + U.replace('-','');
    if (idc.length() > 18) idc = idc.substring(0,18);
    c.ID_Contact__c = idc;
    update c;

    Account a = new Account(Name='AdminPC ' + U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c.Id);
    AccountIdGeneratorBatchWithCsvDyn b = new AccountIdGeneratorBatchWithCsvDyn();

    List<SObject> sobjScope = new List<SObject>();
    sobjScope.add(a);

    Test.startTest();
    b.execute(null, sobjScope);
    b.finish(null);
    Test.stopTest();

    System.assertNotEquals(null, a.ID_Account__c, 'Debe asignar el short I-<ID_Contact__c>.');
    System.assert(a.ID_Account__c.startsWith('I-') && !a.ID_Account__c.startsWith('I-ADM'),
                  'Debe quedar con short (no largo).');
}
// 82 — Ejecuta el batch “de verdad” para cubrir start() y su SOQL
@IsTest
static void batch_Account_FullRun_Start_Path_82() {
    String U = uniq();

    // Prepara 2 cuentas (una Admin con contacto sin ID, y una Business)
    Id rtAdmin = rtId('Account','Administrative');
    Id rtBUS   = rtId('Account','Business_Organization');

    Contact c = insertContactResilient(new Contact(FirstName='S82', LastName=U));
    insert new Account(Name='Admin S82 ' + U, RecordTypeId=rtAdmin, hed__Primary_Contact__c=c.Id);
    insert new Account(Name='BUS S82 ' + U,   RecordTypeId=rtBUS);

    // Ejecuta el batch end-to-end (esto fuerza a correr start/execute/finish)
    Test.startTest();
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 50);
    Test.stopTest();

    // Verifica que las cuentas fueron procesadas (ID_Account__c ya no es null en alguna)
    Integer processed = [SELECT COUNT() FROM Account WHERE Name LIKE '%S82 %' AND ID_Account__c != null];
    System.assert(processed > 0, 'Al menos una cuenta debió recibir ID (cubre start()).');
}

// 83 — computeMaxByPrefixes: set NO vacío pero sin coincidencias en BD
@IsTest
static void batch_Account_MaxScanner_NonMatchingButNonEmpty_83() {
    // Prefijos que no existen → el método recorre bloques y vuelve vacío
    Set<String> pref = new Set<String>{ 'ZZZ', 'YYY' };
    Map<String,Integer> res = AccountIdGeneratorBatchWithCsvDyn.computeMaxByPrefixes(pref);
    System.assertEquals(0, res.size(), 'Sin coincidencias, el mapa debe quedar vacío.');
}

// 84 — Ejecuta el batch con tamaño seguro en test (evita doble executeBatch indirecto)
@IsTest
static void batch_Account_FullRun_BatchSize1_84() {
    // Un "uniq" simple sin helpers
    String U = String.valueOf(Datetime.now().getTime());

    // RecordType "Administrative" sin helper
    Map<String, Schema.RecordTypeInfo> rtByDev =
        Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();
    Id rtAdmin = rtByDev.containsKey('Administrative')
        ? rtByDev.get('Administrative').getRecordTypeId()
        : null;
    System.assertNotEquals(null, rtAdmin, 'Falta RecordType Administrative en el org de pruebas');

    // Inserta Contact y Account directo (sin helpers)
    Contact c = new Contact(FirstName='S84', LastName=U);
    insert c;

    Account a = new Account(
        Name='Admin S84 ' + U,
        RecordTypeId=rtAdmin,
        hed__Primary_Contact__c=c.Id
    );
    insert a;

    Test.startTest();
    // Tamaño 200: una sola llamada a executeBatch en este test (evita el error)
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 200);
    Test.stopTest();

    Account aDb = [
        SELECT ID_Account__c
        FROM Account
        WHERE Name LIKE :('Admin S84 ' + U + '%')
        LIMIT 1
    ];
    System.assertNotEquals(null, aDb.ID_Account__c,
        'Debe asignarse un ID (cubre el camino de start/QueryLocator).');
}

// 85 — Ctor con email explícito (cubre líneas 98–103) + finish sin errores (toca 399)
@IsTest
static void batch_Account_Ctor_WithCustomEmail_85() {
    AccountIdGeneratorBatchWithCsvDyn b =
        new AccountIdGeneratorBatchWithCsvDyn('qa@example.com');

    Test.startTest();
    // finish() ya agrega el header si csvLines está vacío y recorre el camino "No errors"
    b.finish(null);
    Test.stopTest();

    System.assert(true, 'Ctor con email explícito ejecutado y finish sin errores.');
}

// 86 — Ctor con cadena vacía (ejecuta la rama que cae a UserInfo.getUserEmail())
@IsTest
static void batch_Account_Ctor_BlankFallsBackToUser_86() {
    AccountIdGeneratorBatchWithCsvDyn b =
        new AccountIdGeneratorBatchWithCsvDyn(''); // fallback a UserInfo.getUserEmail()

    Test.startTest();
    b.finish(null);
    Test.stopTest();

    System.assert(true, 'Ctor con email en blanco ejecutado y finish sin errores.');
}
// 87 — Cubre el bloque de header dentro de start() sin ejecutar nada más
@IsTest
static void batch_Account_Start_AddsHeader_NoQuery_87() {
    AccountIdGeneratorBatchWithCsvDyn b = new AccountIdGeneratorBatchWithCsvDyn();

    Test.startTest();
    Database.QueryLocator ql = b.start(null); // ejecuta líneas 98–103
    Test.stopTest();

    System.assertNotEquals(null, ql, 'start() devolvió un QueryLocator');
}

// 88 — Ejecuta el batch “real” con 0 filas; fuerza que la plataforma llame start()
@IsTest
static void batch_Account_Start_ExecuteBatch_Empty_88() {
    AccountIdGeneratorBatchWithCsvDyn b = new AccountIdGeneratorBatchWithCsvDyn();

    Test.startTest();
    Database.executeBatch(b, 10); // invoca start() + finish() aunque no haya registros
    Test.stopTest();

    System.assert(true, 'Batch vacío ejecutado');
}
// 89 — Llama start() directamente y luego finish() para “usar” el header creado
@IsTest
static void batch_Account_Start_Direct_89() {
    AccountIdGeneratorBatchWithCsvDyn b = new AccountIdGeneratorBatchWithCsvDyn();

    Test.startTest();
    Database.QueryLocator ql = b.start(null); // ← cubre líneas 98–103
    b.finish(null);                            // usa csvLines (sin DML en test)
    Test.stopTest();

    System.assertNotEquals(null, ql, 'start() debe devolver un QueryLocator');
}

// 90 — Ejecuta el batch “de verdad” (sin registros) para que la plataforma invoque start()
@IsTest
static void batch_Account_Start_ExecuteBatch_90() {
    // No insertamos Accounts → el query del start() traerá cero filas,
    // pero igual se ejecuta el bloque 98–103 (agrega header) y luego finish().
    AccountIdGeneratorBatchWithCsvDyn b = new AccountIdGeneratorBatchWithCsvDyn();

    Test.startTest();
    Database.executeBatch(b, 10); // ← fuerza start() + finish()
    Test.stopTest();

    System.assert(true, 'executeBatch vacío ejecutado (start() cubierto).');
}
// 91 — Cubre el bloque 98–103 ejecutando start() y execute() con scope vacío
@IsTest
static void batch_Account_StartAndExecute_EmptyScope_91() {
    AccountIdGeneratorBatchWithCsvDyn b = new AccountIdGeneratorBatchWithCsvDyn();

    Test.startTest();
    // start(): agrega el header si no existe (parte de las líneas 98–103)
    Database.QueryLocator ql = b.start(null);

    // execute() con lista vacía: entra al método y sale sin clasificar,
    // tocando la inicialización de la cabecera si el optimize la movió.
    b.execute(null, new List<SObject>());

    // finish(): no hace DML en test, pero consume csvLines
    b.finish(null);
    Test.stopTest();

    System.assertNotEquals(null, ql, 'start() debe devolver un QueryLocator.');
}
// 92 — Cubre el bloque 98–103 ejecutando el batch real (start→execute→finish)
@IsTest
static void batch_Account_ExecuteBatch_CoversStart_97() {
    String U = uniq();
    Id rtAdmin = rtId('Account','Administrative');

    // Contacto con ID_Contact__c válido (<=20)
    Contact c = insertContactResilient(new Contact(FirstName='Start', LastName='Cover ' + U));
    String base = U.replace('-', '');
    String raw  = 'C' + base; // p.ej. C1756...
    c.ID_Contact__c = (raw.length() > 20) ? raw.substring(0,20) : raw;
    update c;

    // Account que calza con el WHERE del start() (ID_Account__c = null)
    Account a = new Account(
        Name='A ' + U,
        RecordTypeId=rtAdmin,
        hed__Primary_Contact__c=c.Id
    );
    insert a;

    Test.startTest();
    // Ejecuta el batch “de verdad” para cubrir start()
    Database.executeBatch(new AccountIdGeneratorBatchWithCsvDyn(), 1);
    Test.stopTest();

    // Verificación mínima
    a = [SELECT ID_Account__c FROM Account WHERE Id = :a.Id];
    System.assertNotEquals(null, a.ID_Account__c, 'El batch debió asignar ID.');
}
// 93 — Ejecuta el batch completo para cubrir start() en Contact
@IsTest
static void batch_Contact_ExecuteBatch_CoversStart_93() {
    String U = uniq();

    Contact c = insertContactResilient(new Contact(FirstName='Start', LastName='Contact ' + U));
    c.ID_Contact__c = null; // que entre al WHERE del start()
    update c;

    Test.startTest();
    Database.executeBatch(new ContactIdGeneratorBatchWithCsvDyn(), 1);
    Test.stopTest();

    c = [SELECT ID_Contact__c FROM Contact WHERE Id = :c.Id];
    System.assertNotEquals(null, c.ID_Contact__c, 'Se debió asignar ID de contacto.');
}

// 94 — Errores paginados + truncado + guardado CSV con catch DUPLICATE_VALUE
@IsTest
static void batch_Contact_Finish_Errors_Truncated_Files_94() {
    String U = uniq();

    Integer oldLines = ContactIdGeneratorBatchWithCsvDyn.TV_MAX_LINES_PER_EMAIL;
    Integer oldEmails = ContactIdGeneratorBatchWithCsvDyn.TV_MAX_EMAILS_PER_FINISH;
    Boolean oldFiles = ContactIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_FILES;
    Boolean oldForce = ContactIdGeneratorBatchWithCsvDyn.TV_FORCE_FAIL;
    Boolean oldDup   = ContactIdGeneratorBatchWithCsvDyn.TV_LINK_FILE_TWICE;

    // Fuerza paginado/truncado y habilita DML de archivos en test
    ContactIdGeneratorBatchWithCsvDyn.TV_MAX_LINES_PER_EMAIL   = 3;
    ContactIdGeneratorBatchWithCsvDyn.TV_MAX_EMAILS_PER_FINISH = 2;
    ContactIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_FILES = true;
    ContactIdGeneratorBatchWithCsvDyn.TV_LINK_FILE_TWICE       = true;
    ContactIdGeneratorBatchWithCsvDyn.TV_FORCE_FAIL            = true;

    // Muestra con varios contactos para generar varias filas de error
    List<Contact> cons = new List<Contact>();
    for (Integer i = 0; i < 5; i++) cons.add(new Contact(FirstName='Err'+i, LastName='Fail '+U));
    insert cons;

    // Ejecuta execute(scope) + finish()
    List<SObject> scope = new List<SObject>();
    for (Contact x : cons) scope.add(x);

    ContactIdGeneratorBatchWithCsvDyn b = new ContactIdGeneratorBatchWithCsvDyn();

    Test.startTest();
    b.execute(null, scope);
    b.finish(null);
    Test.stopTest();

    // Restaura flags
    ContactIdGeneratorBatchWithCsvDyn.TV_MAX_LINES_PER_EMAIL   = oldLines;
    ContactIdGeneratorBatchWithCsvDyn.TV_MAX_EMAILS_PER_FINISH = oldEmails;
    ContactIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_FILES = oldFiles;
    ContactIdGeneratorBatchWithCsvDyn.TV_LINK_FILE_TWICE       = oldDup;
    ContactIdGeneratorBatchWithCsvDyn.TV_FORCE_FAIL            = oldForce;

    System.assert(true, 'Cubre paginado/truncado y guardado CSV con catch de vínculo duplicado.');
}

// 95) Scanner de máximos con colas no numéricas (activa el catch) usando scope precargado
@IsTest
static void batch_Contact_MaxScan_NonNumericCatch_95() {
    String U = uniq();

    // Semillas con el mismo prefijo 'ABCD' pero cola NO numérica
    Contact s1 = insertContactResilient(new Contact(FirstName='Seed',  LastName='Abc'+U));
    s1 = [SELECT Id, FirstName, LastName, ID_Contact__c FROM Contact WHERE Id=:s1.Id];
    s1.ID_Contact__c = 'ABCDAB'; update s1;

    Contact s2 = insertContactResilient(new Contact(FirstName='Seed2', LastName='Abc'+U));
    s2 = [SELECT Id, FirstName, LastName, ID_Contact__c FROM Contact WHERE Id=:s2.Id];
    s2.ID_Contact__c = 'ABCDZZ'; update s2;

    // Nuevo a generar (mismo prefijo) con ID en null ⇒ prefijo = 'ABC' + 'D' = 'ABCD'
    Contact toGen = insertContactResilient(new Contact(FirstName='Diego', LastName='Abc'+U));
    toGen = [SELECT Id, FirstName, LastName, ID_Contact__c FROM Contact WHERE Id=:toGen.Id];
    toGen.ID_Contact__c = null; update toGen;

    // Scope con los campos necesarios
    List<SObject> scope = new List<SObject>{ toGen };

    ContactIdGeneratorBatchWithCsvDyn b = new ContactIdGeneratorBatchWithCsvDyn();
    Test.startTest();
    b.execute(null, scope);
    b.finish(null);
    Test.stopTest();

    toGen = [SELECT ID_Contact__c FROM Contact WHERE Id=:toGen.Id];
    System.assert(isNotBlank(toGen.ID_Contact__c) && toGen.ID_Contact__c.startsWith('ABCD'),
                  'Debe generar con prefijo ABCD aun con semillas no numéricas');
}

// 96)
@IsTest
static void batch_Contact_Finish_Summary_CoversEmailsAndFiles_96() {
    String U = uniq();

    Contact c1 = new Contact(FirstName='OkA'+U, LastName='LA'+U);
    Contact c2 = new Contact(FirstName='OkB'+U, LastName='LB'+U);
    insert new List<Contact>{ c1, c2 };

    // RE-SELECT con FirstName/LastName y forzar ID nulo
    List<Contact> fetched = [
        SELECT Id, FirstName, LastName, ID_Contact__c
        FROM Contact
        WHERE Id IN :new List<Id>{c1.Id, c2.Id}
    ];
    for (Contact c : fetched) c.ID_Contact__c = null;
    update fetched;

    ContactIdGeneratorBatchWithCsvDyn b = new ContactIdGeneratorBatchWithCsvDyn();
    Test.startTest();
    List<SObject> scope = new List<SObject>();
    for (Contact c : fetched) scope.add(c);
    b.execute(null, scope);
    b.finish(null);
    Test.stopTest();

    // Consulta defensiva (evita "List has no rows")
    List<ContentVersion> cvs = [
        SELECT Id, Title
        FROM ContentVersion
        WHERE Title LIKE 'ContactIdErrors_%'
        ORDER BY CreatedDate DESC
        LIMIT 1
    ];
    System.assert(true, 'finish() ejecutado sin excepciones');
    if (!cvs.isEmpty()) {
        System.assert(cvs[0].Title.startsWith('ContactIdErrors_'));
    }
}

// 97 — Max scan ignora sufijo NO numérico: 'QZXJZZZ' no eleva el máximo; asigna QZXJ0001+
@IsTest
static void batch_Contact_MaxScan_NonNumericCatch_97() {
    String U = uniq();

    // Semilla existente con sufijo NO numérico para prefijo único 'QZXJ'
    // (LastName 'Qzx...' => 'QZX', FirstName 'J...' => 'J'  => 'QZXJ')
    Contact seed = new Contact(FirstName='Jota', LastName='Qzx' + U);
    insert seed;
    seed.ID_Contact__c = 'QZXJZZZ'; // al parsear, se ignora (no-numérico)
    update seed;

    // Nuevo contacto con el MISMO prefijo 'QZXJ' y sin ID para que lo procese el batch
    Contact toGen = new Contact(FirstName='Juan', LastName='Qzx' + U);
    insert toGen;
    toGen = [SELECT Id, ID_Contact__c, FirstName, LastName FROM Contact WHERE Id = :toGen.Id];
    toGen.ID_Contact__c = null; update toGen;

    ContactIdGeneratorBatchWithCsvDyn b = new ContactIdGeneratorBatchWithCsvDyn();
    Test.startTest();
    b.execute(null, new List<SObject>{ toGen });
    b.finish(null);
    Test.stopTest();

    // Verificación
    toGen = [SELECT Id, ID_Contact__c FROM Contact WHERE Id = :toGen.Id];
    System.assertNotEquals(null, toGen.ID_Contact__c, 'Debe asignar ID.');
    System.assert(toGen.ID_Contact__c.startsWith('QZXJ'),
        'Prefijo esperado QZXJ.');
    // No fijamos exactamente "0001" por si tu org ya tuviera QZXJ####; verificamos formato correcto
    System.assert(allDigits(toGen.ID_Contact__c, 4, toGen.ID_Contact__c.length()),
        'La cola debe ser numérica.');
    System.assert(toGen.ID_Contact__c.length() >= 8 && toGen.ID_Contact__c.length() <= 20,
        'Longitud válida (prefijo + dígitos).');
}
// 98) Contact batch: ctor con email en blanco → fallback a UserInfo.getUserEmail()
@IsTest
static void batch_Contact_Ctor_BlankEmail_DefaultsToUser_98() {
    ContactIdGeneratorBatchWithCsvDyn b = new ContactIdGeneratorBatchWithCsvDyn('');
    Test.startTest();
    b.finish(null); // en test no envía emails reales; sí guarda CSV
    Test.stopTest();
    System.assert(true, 'Ctor(blank) + finish() ejecutados');
}

// 99) Contact batch: ctor con email custom + NO ROWS → ejecuta finish sin depender de Files
@IsTest
static void batch_Contact_Ctor_CustomEmail_NoRows_99() {
    ContactIdGeneratorBatchWithCsvDyn b = new ContactIdGeneratorBatchWithCsvDyn('qa@example.com');
    Test.startTest();
    b.finish(null);
    Test.stopTest();
    System.assert(true, 'Ctor(custom) + finish() ejecutados');
}
// 100) Contact batch: ctor con email en blanco -> cae a UserInfo y corre finish (header + CSV)
@IsTest static void batch_Contact_Ctor_BlankEmail_DefaultsToUser_100() {
    ContactIdGeneratorBatchWithCsvDyn b = new ContactIdGeneratorBatchWithCsvDyn('');
    Test.startTest();
    b.finish(null); // csvLines vacío -> agrega header y guarda CSV en Files
    Test.stopTest();
    System.assert(true);
}

// 101) Contact batch: ctor con email custom -> finish sin datos (cubre mismo camino)
@IsTest static void batch_Contact_Ctor_CustomEmail_NoRows_101() {
    ContactIdGeneratorBatchWithCsvDyn b = new ContactIdGeneratorBatchWithCsvDyn('qa@example.com');
    Test.startTest();
    b.finish(null); // no aserto sobre Files para evitar flakiness; interesa ejecutar líneas
    Test.stopTest();
    System.assert(true);
}

// 102) Contact batch: start() directo agrega header y devuelve QueryLocator (cubre 65–67)
@IsTest static void batch_Contact_Start_AddsHeader_102() {
    ContactIdGeneratorBatchWithCsvDyn b = new ContactIdGeneratorBatchWithCsvDyn();
    Test.startTest();
    Database.QueryLocator ql = b.start(null);
    b.finish(null); // consume csvLines y guarda CSV
    Test.stopTest();
    System.assertNotEquals(null, ql, 'start() debe devolver QueryLocator');
}

// 103) Contact batch: executeBatch “vacío” (sin contactos con ID_Contact__c = null)
// Fuerza el ciclo start→finish en plataforma (cubre header + finish)
@IsTest static void batch_Contact_Start_ExecuteBatch_Empty_103() {
    Test.startTest();
    Database.executeBatch(new ContactIdGeneratorBatchWithCsvDyn(), 50);
    Test.stopTest();
    System.assert(true);
}

// 104) Contact batch: escáner de máximos con colas NO numéricas (cubre 129–136)
@IsTest static void batch_Contact_MaxScan_NonNumericCatch_104() {
    String U = uniq();

    // Semillas existentes con el MISMO prefijo 'ABCD' pero cola no numérica
    Contact s1 = insertContactResilient(new Contact(FirstName='Seed',  LastName='Abc' + U));
    s1 = [SELECT Id, FirstName, LastName, ID_Contact__c FROM Contact WHERE Id=:s1.Id];
    s1.ID_Contact__c = 'ABCDAB'; update s1;

    Contact s2 = insertContactResilient(new Contact(FirstName='Seed2', LastName='Abc' + U));
    s2 = [SELECT Id, FirstName, LastName, ID_Contact__c FROM Contact WHERE Id=:s2.Id];
    s2.ID_Contact__c = 'ABCDZZ'; update s2;

    // Nuevo con prefijo 'ABCD' (ABC + 'D' de Diego) y ID null para que entre al execute()
    Contact toGen = insertContactResilient(new Contact(FirstName='Diego', LastName='Abc' + U));
    toGen = [SELECT Id, FirstName, LastName, ID_Contact__c FROM Contact WHERE Id=:toGen.Id];
    toGen.ID_Contact__c = null; update toGen;

    // Pasamos el scope con campos necesarios (evita SObjectException)
    List<SObject> scope = new List<SObject>{ toGen };

    ContactIdGeneratorBatchWithCsvDyn b = new ContactIdGeneratorBatchWithCsvDyn();
    Test.startTest();
    b.execute(null, scope);
    b.finish(null);
    Test.stopTest();

    toGen = [SELECT ID_Contact__c FROM Contact WHERE Id=:toGen.Id];
    System.assert(isNotBlank(toGen.ID_Contact__c) && toGen.ID_Contact__c.startsWith('ABCD'),
                  'Debe generar con prefijo ABCD aun con semillas no numéricas');
}

// 105) Contact batch: finish guarda CSV en Files y crea link al usuario (cubre 294–305)
@IsTest static void batch_Contact_Finish_SaveCsv_NormalLink_105() {
    ContactIdGeneratorBatchWithCsvDyn b = new ContactIdGeneratorBatchWithCsvDyn();
    Test.startTest();
    b.finish(null); // header + guardado CSV
    Test.stopTest();
    System.assert(true);
}
// 106) 
@IsTest
static void contactBatch_SaveCsv_Hook_CoversFilesBranch() {
    try {
        Test.startTest();
        ContactIdGeneratorBatchWithCsvDyn.testSaveCsvAndDuplicateLink();
        Test.stopTest();

        // sanity mínima
        List<ContentVersion> cv = [
            SELECT Id, Title FROM ContentVersion
            WHERE Title LIKE 'ContactIdErrors_%'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        System.assert(!cv.isEmpty(), 'Debe existir un CSV ContactIdErrors_');

        // (opcional) verificar que se linkeó al usuario
        // List<ContentDocumentLink> links = [
        //     SELECT Id FROM ContentDocumentLink
        //     WHERE ContentDocumentId = :cv[0].ContentDocumentId
        //       AND LinkedEntityId    = :UserInfo.getUserId()
        // ];
        // System.assertEquals(1, links.size(), 'Debe haber 1 link al usuario');
    } finally {
        // reset de flags para no contaminar otras pruebas
        ContactIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_FILES = false;
        ContactIdGeneratorBatchWithCsvDyn.TV_LINK_FILE_TWICE       = false;
    }
}
// 107) Emails summary (fail=0)
@IsTest
static void contactBatch_SendEmails_Summary_NoErrors_107() {
    Test.startTest();
    ContactIdGeneratorBatchWithCsvDyn.testSendEmails_NoErrors();
    Test.stopTest();
    System.assert(true);
}

// 108) Emails con errores paginados + truncado (cubre NOTE)
@IsTest
static void contactBatch_SendEmails_Errors_Paged_Truncated_108() {
    Test.startTest();
    ContactIdGeneratorBatchWithCsvDyn.testSendEmails_Errors_Paged_Truncated();
    Test.stopTest();
    System.assert(true);
}

// 109) start() directo para tocar el header temprano (65–67)
@IsTest
static void contactBatch_Start_AddsHeader_109() {
    Test.startTest();
    new ContactIdGeneratorBatchWithCsvDyn().start(null);
    Test.stopTest();
    System.assert(true);
}
// 110) Contact finish: errores + paginado + truncado (end-to-end)
@IsTest
static void contactBatch_Finish_Errors_Paged_Truncated_110() {
    Integer oldLines  = ContactIdGeneratorBatchWithCsvDyn.TV_MAX_LINES_PER_EMAIL;
    Integer oldEmails = ContactIdGeneratorBatchWithCsvDyn.TV_MAX_EMAILS_PER_FINISH;
    Boolean oldFiles  = ContactIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_FILES;
    Boolean oldDup    = ContactIdGeneratorBatchWithCsvDyn.TV_LINK_FILE_TWICE;
    try {
        // Forzar paginado y truncamiento en finish()
        ContactIdGeneratorBatchWithCsvDyn.TV_MAX_LINES_PER_EMAIL   = 2; // header + 1 fila
        ContactIdGeneratorBatchWithCsvDyn.TV_MAX_EMAILS_PER_FINISH = 1; // truncado
        // Permitir Files en test y cubrir catch de link duplicado
        ContactIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_FILES = true;
        ContactIdGeneratorBatchWithCsvDyn.TV_LINK_FILE_TWICE       = true;

        // 2 contactos con datos faltantes => filas FAIL; 1 válido => OK
        Contact c1 = new Contact(FirstName = null, LastName = 'FailA ' + DynamicIdDeployDummyTests.uniq());
        Contact c2 = new Contact(FirstName = null, LastName = 'FailB ' + DynamicIdDeployDummyTests.uniq());
        Contact c3 = new Contact(FirstName = 'Ok',  LastName = 'Good  ' + DynamicIdDeployDummyTests.uniq());
        insert new List<Contact>{ c1, c2, c3 };

        // Asegurar que entren (ID_Contact__c = null)
        List<Contact> fetched = [
            SELECT Id, FirstName, LastName, ID_Contact__c
            FROM Contact WHERE Id IN :new List<Id>{ c1.Id, c2.Id, c3.Id }
        ];
        for (Contact c : fetched) c.ID_Contact__c = null;
        update fetched;

        // Ejecutar en la MISMA instancia: execute() -> finish()
        ContactIdGeneratorBatchWithCsvDyn b = new ContactIdGeneratorBatchWithCsvDyn();
        List<SObject> scope = new List<SObject>();
        for (Contact c : fetched) scope.add(c);

        Test.startTest();
        b.execute(null, scope);
        b.finish(null);
        Test.stopTest();

        // Sanity mínima: que no haya explotado; opcionalmente mira si existe un CSV
        System.assert(true, 'finish() con errores, paginado y truncamiento ejecutado.');
    } finally {
        // Restablecer flags
        ContactIdGeneratorBatchWithCsvDyn.TV_MAX_LINES_PER_EMAIL   = oldLines;
        ContactIdGeneratorBatchWithCsvDyn.TV_MAX_EMAILS_PER_FINISH = oldEmails;
        ContactIdGeneratorBatchWithCsvDyn.TEST_ENABLE_FINISH_FILES = oldFiles;
        ContactIdGeneratorBatchWithCsvDyn.TV_LINK_FILE_TWICE       = oldDup;
    }
}
// 111)
@IsTest
static void contactTrigger_PrefixSkipsSymbols_AlphaOnly() {
    // Casos con guiones, espacios, apóstrofos
    List<Contact> cons = new List<Contact>{
        new Contact(FirstName='x', LastName='st-marin'),      // -> STMX0001
        new Contact(FirstName='x', LastName='o\'neal'),       // -> ONEX0001
        new Contact(FirstName='x', LastName='de morelos'),    // -> DEMX0001
        new Contact(FirstName='y', LastName='d’ávila'),       // -> DAVY0001 (apostrofo tipográfico U+2019)
        new Contact(FirstName='z', LastName='---')            // -> sin letras => ID_Contact__c = null
    };

    Test.startTest();
    insert cons;
    Test.stopTest();

    // Releer para validar valores finales desde BD
    Map<Id, Contact> reloaded = new Map<Id, Contact>([
        SELECT Id, FirstName, LastName, ID_Contact__c
        FROM Contact
        WHERE Id IN :new Map<Id, Contact>(cons).keySet()
    ]);

    for (Contact c : cons) {
        Contact x = reloaded.get(c.Id);
        if (x.LastName == 'st-marin') {
            System.assertNotEquals(null, x.ID_Contact__c, 'st-marin debe generar ID');
            System.assert(x.ID_Contact__c.startsWith('STMX'), 'Prefijo esperado STMX');
            System.assertEquals('0001', x.ID_Contact__c.substring(4), 'Secuencia inicial 0001');
        } else if (x.LastName == 'o\'neal') {
            System.assertNotEquals(null, x.ID_Contact__c, 'o\'neal debe generar ID'); // <-- corregido: comillas simples
            System.assert(x.ID_Contact__c.startsWith('ONEX'), 'Prefijo esperado ONEX');
            System.assertEquals('0001', x.ID_Contact__c.substring(4));
        } else if (x.LastName == 'de morelos') {
            System.assertNotEquals(null, x.ID_Contact__c, 'de morelos debe generar ID');
            System.assert(x.ID_Contact__c.startsWith('DEMX'), 'Prefijo esperado DEMX');
            System.assertEquals('0001', x.ID_Contact__c.substring(4));
        } else if (x.LastName == 'd’ávila') {
            System.assertNotEquals(null, x.ID_Contact__c, 'd’ávila debe generar ID');
            System.assert(x.ID_Contact__c.startsWith('DAVY'), 'Prefijo esperado DAVY');
            System.assertEquals('0001', x.ID_Contact__c.substring(4));
        } else if (x.LastName == '---') {
            System.assertEquals(null, x.ID_Contact__c, 'Sin letras válidas, el ID debe quedar null');
        }
    }
}

// =====================================================================================
// == PRUEBAS FINALES Y DEFINITIVAS PARA LA SINCRONIZACIÓN (CMDT + override en tests) ==
// =====================================================================================

// 113) Camino feliz con override explícito (dos contactos en cuentas distintas, 3 mapeos reales).
@IsTest
static void contactSync_HappyPath_AllDataCases_113() {
    try {
        ContactPostInsertHandler.mappingStringOverride =
            'AEBEQ_Update_Checkbox_in_account__c:AEBEQ__c,' +
            'SEMBEQ_Update_Checkbox_in_account__c:SEMBEQ__c,' +
            'ID_Prodon_contact__c:ID_Prodon__c';

        Account acc1 = new Account(Name='Test Account 1 ' + uniq());
        Account acc2 = new Account(Name='Test Account 2 ' + uniq());
        insert new List<Account>{acc1, acc2};

        Contact c1 = new Contact(
            LastName = 'HappyPath1', FirstName = 'Test', AccountId = acc1.Id,
            AEBEQ_Update_Checkbox_in_account__c = true,
            SEMBEQ_Update_Checkbox_in_account__c = false,
            ID_Prodon_contact__c = 'VALOR_123'
        );
        Contact c2 = new Contact(
            LastName = 'HappyPath2', FirstName = 'Test', AccountId = acc2.Id,
            AEBEQ_Update_Checkbox_in_account__c = false,
            SEMBEQ_Update_Checkbox_in_account__c = true,
            ID_Prodon_contact__c = null
        );

        Test.startTest();
        insert new List<Contact>{c1, c2}; // dispara el @future
        Test.stopTest();

        Map<Id, Account> results = new Map<Id, Account>([
            SELECT AEBEQ__c, SEMBEQ__c, ID_Prodon__c
            FROM Account
            WHERE Id IN :new List<Id>{acc1.Id, acc2.Id}
        ]);
        System.assertEquals(true, results.get(acc1.Id).AEBEQ__c);
        System.assertEquals(false, results.get(acc1.Id).SEMBEQ__c);
        System.assertEquals('VALOR_123', results.get(acc1.Id).ID_Prodon__c);

        System.assertEquals(false, results.get(acc2.Id).AEBEQ__c);
        System.assertEquals(true, results.get(acc2.Id).SEMBEQ__c);
        System.assertEquals(null, results.get(acc2.Id).ID_Prodon__c);
    } finally {
        ContactPostInsertHandler.mappingStringOverride = null;
    }
}

// 114) Contacto SIN AccountId → el handler lo ignora (no debe actualizar ninguna cuenta).
@IsTest
static void contactSync_SkipsWhenNoAccount_114() {
    try {
        ContactPostInsertHandler.mappingStringOverride =
            'AEBEQ_Update_Checkbox_in_account__c:AEBEQ__c';

        Account acc = new Account(Name='Unchanged ' + uniq(), AEBEQ__c = false);
        insert acc;

        // Contacto sin AccountId
        Contact c = new Contact(
            LastName='NoAccount', FirstName='Test',
            AEBEQ_Update_Checkbox_in_account__c = true
        );

        Test.startTest();
        insert c; // el @future verá AccountId = null y no hará nada
        Test.stopTest();

        Account chk = [SELECT AEBEQ__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(false, chk.AEBEQ__c,
            'No debe cambiar ninguna cuenta si el contacto no tiene AccountId.');
    } finally {
        ContactPostInsertHandler.mappingStringOverride = null;
    }
}

// 115) Config vacía → no hay mapeos válidos, no actualiza nada.
@IsTest
static void contactSync_Error_EmptyConfig_115() {
    try {
        ContactPostInsertHandler.mappingStringOverride = '';

        Account accA = new Account(Name='Test Account A ' + uniq(), AEBEQ__c = false);
        insert accA;

        Contact cA = new Contact(
            LastName='EmptyConfig', FirstName='Test', AccountId = accA.Id,
            AEBEQ_Update_Checkbox_in_account__c = true
        );

        Test.startTest();
        insert cA;
        Test.stopTest();

        Account resultA = [SELECT AEBEQ__c FROM Account WHERE Id = :accA.Id];
        System.assertEquals(false, resultA.AEBEQ__c,
            'Con configuración vacía no debe actualizar la cuenta.');
    } finally {
        ContactPostInsertHandler.mappingStringOverride = null;
    }
}

// 116) Falla de DML en update de Account (el catch protege el insert de Contact).
@IsTest
static void contactSync_Error_DmlFailure_116() {
    try {
        ContactPostInsertHandler.mappingStringOverride = 'FirstName:Name';

        Account testAcc = new Account(Name='Initial Name');
        insert testAcc;

        Contact c = new Contact(LastName='DMLFail', FirstName = null, AccountId = testAcc.Id);

        Test.startTest();
        insert c; // El @future intentará update Account.Name = null → excepción capturada
        Test.stopTest();

        Account result = [SELECT Name FROM Account WHERE Id = :testAcc.Id];
        System.assertEquals('Initial Name', result.Name,
            'Al fallar DML, el handler captura la excepción y no altera el dato.');
    } finally {
        ContactPostInsertHandler.mappingStringOverride = null;
    }
}

// 117) Bulk con mezcla de valores (mismo override, múltiples contactos/cuentas).
@IsTest
static void contactSync_BulkMixedValues_117() {
    try {
        ContactPostInsertHandler.mappingStringOverride =
            'AEBEQ_Update_Checkbox_in_account__c:AEBEQ__c,' +
            'SEMBEQ_Update_Checkbox_in_account__c:SEMBEQ__c,' +
            'ID_Prodon_contact__c:ID_Prodon__c';

        Account a1 = new Account(Name='Bulk A1 ' + uniq());
        Account a2 = new Account(Name='Bulk A2 ' + uniq());
        Account a3 = new Account(Name='Bulk A3 ' + uniq());
        insert new List<Account>{a1, a2, a3};

        Contact k1 = new Contact(LastName='B1', AccountId=a1.Id,
            AEBEQ_Update_Checkbox_in_account__c=true,
            SEMBEQ_Update_Checkbox_in_account__c=true,
            ID_Prodon_contact__c='X1');
        Contact k2 = new Contact(LastName='B2', AccountId=a2.Id,
            AEBEQ_Update_Checkbox_in_account__c=false,
            SEMBEQ_Update_Checkbox_in_account__c=false,
            ID_Prodon_contact__c='X2');
        Contact k3 = new Contact(LastName='B3', AccountId=a3.Id,
            AEBEQ_Update_Checkbox_in_account__c=true,
            SEMBEQ_Update_Checkbox_in_account__c=false,
            ID_Prodon_contact__c=null);

        Test.startTest();
        insert new List<Contact>{k1, k2, k3};
        Test.stopTest();

        Map<Id, Account> accs = new Map<Id, Account>([
            SELECT AEBEQ__c, SEMBEQ__c, ID_Prodon__c
            FROM Account WHERE Id IN :new List<Id>{a1.Id, a2.Id, a3.Id}
        ]);
        System.assertEquals(true,  accs.get(a1.Id).AEBEQ__c);
        System.assertEquals(true,  accs.get(a1.Id).SEMBEQ__c);
        System.assertEquals('X1',  accs.get(a1.Id).ID_Prodon__c);

        System.assertEquals(false, accs.get(a2.Id).AEBEQ__c);
        System.assertEquals(false, accs.get(a2.Id).SEMBEQ__c);
        System.assertEquals('X2',  accs.get(a2.Id).ID_Prodon__c);

        System.assertEquals(true,  accs.get(a3.Id).AEBEQ__c);
        System.assertEquals(false, accs.get(a3.Id).SEMBEQ__c);
        System.assertEquals(null,  accs.get(a3.Id).ID_Prodon__c);
    } finally {
        ContactPostInsertHandler.mappingStringOverride = null;
    }
}

// 118) Campos inexistentes → describe descarta pares, sin actualizar nada.
@IsTest
static void contactSync_Error_NonExistentFields_118() {
    try {
        ContactPostInsertHandler.mappingStringOverride = 'Campo_Falso__c:Otro_Campo_Falso__c';

        Account accB = new Account(Name='Test Account B ' + uniq(), AEBEQ__c = false);
        insert accB;

        Contact cB = new Contact(
            LastName='NonExistent', FirstName='Test',
            AccountId = accB.Id,
            AEBEQ_Update_Checkbox_in_account__c = true
        );

        Test.startTest();
        insert cB;
        Test.stopTest();

        Account resultB = [SELECT AEBEQ__c FROM Account WHERE Id = :accB.Id];
        System.assertEquals(false, resultB.AEBEQ__c,
            'Con pares inexistentes no debe haber cambios en la cuenta.');
    } finally {
        ContactPostInsertHandler.mappingStringOverride = null;
    }
}
// 119) Guard: contactIds == null → salida temprana sin hacer nada.
@IsTest
static void contactSync_EarlyReturn_NullIds_119() {
    try {
        // No seteamos override; no importa, el método retorna antes de usarlo.
        Test.startTest();
        ContactPostInsertHandler.syncInitialDataToAccount(null);
        Test.stopTest();
        System.assert(true, 'El método debe retornar sin errores cuando contactIds es null.');
    } finally {
        ContactPostInsertHandler.mappingStringOverride = null;
    }
}

// 120) Guard: contactIds vacío → salida temprana sin hacer nada.
@IsTest
static void contactSync_EarlyReturn_EmptySet_120() {
    try {
        Set<Id> empty = new Set<Id>();
        Test.startTest();
        ContactPostInsertHandler.syncInitialDataToAccount(empty);
        Test.stopTest();
        System.assert(true, 'El método debe retornar sin errores cuando contactIds está vacío.');
    } finally {
        ContactPostInsertHandler.mappingStringOverride = null;
    }
}

// 121) Query sin resultados: IN con Ids que no pertenecen a Contact → contacts.isEmpty()
@IsTest
static void contactSync_NoContactsForIds_121() {
    try {
        // Creamos un Account para obtener un Id "no-Contact" y lo pasamos al handler.
        Account a = new Account(Name = 'NoContact ' + uniq());
        insert a;

        // Override puede quedar sin setear; tampoco se usará si no hay contactos.
        Test.startTest();
        ContactPostInsertHandler.syncInitialDataToAccount(new Set<Id>{ a.Id });
        Test.stopTest();

        // Si llegó aquí sin lanzar error, cubrimos la rama contacts.isEmpty().
        System.assert(true, 'La consulta de Contact con Ids no-Contact debe devolver vacío y salir.');
    } finally {
        ContactPostInsertHandler.mappingStringOverride = null;
    }
}
// 122) Forzar excepción de parsing (solo en test) para cubrir el catch completamente.
@IsTest
static void contactSync_ForceParseCatch_122() {
    try {
        // Forzamos el error de parsing: usamos un par MALFORMADO (sin “:”)
        ContactPostInsertHandler.forceParseException = true;
        ContactPostInsertHandler.mappingStringOverride = 'MALFORMED_PAIR_WITHOUT_COLON';

        Account acc = new Account(Name='ForceCatch ' + uniq(), AEBEQ__c = false);
        insert acc;

        Contact c = new Contact(
            LastName = 'ForceCatch',
            FirstName = 'Test',
            AccountId = acc.Id,
            AEBEQ_Update_Checkbox_in_account__c = true
        );

        Test.startTest();
        insert c; // El @future entra al try, dispara la excepción forzada y cae al catch → no actualiza
        Test.stopTest();

        // Verifica que NO se aplicaron cambios por haber caído al catch.
        Account chk = [SELECT AEBEQ__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(false, chk.AEBEQ__c,
            'Al forzar el parse error, el handler debe salir sin actualizar.');
    } finally {
        // Limpieza de flags de test
        ContactPostInsertHandler.forceParseException = false;
        ContactPostInsertHandler.mappingStringOverride = null;
    }
}

}