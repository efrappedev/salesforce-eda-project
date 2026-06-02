global class AccountIdGeneratorBatchWithCsvDyn implements Database.Batchable<SObject>, Database.Stateful {

    // ==== TEST FLAGS (para controlar side-effects en tests) ====
    @TestVisible static Boolean TEST_ENABLE_FINISH_EMAILS = false;
    @TestVisible static Boolean TEST_ENABLE_FINISH_FILES  = false;
    @TestVisible static Boolean TV_LINK_FILE_TWICE        = false;

    // ---- Config / Estado
    private String  emailRecipient;
    private Integer successCount = 0;
    private Integer failCount    = 0;

    private List<String> csvLines   = new List<String>();
    private Boolean      headerAdded = false;

    // Límites de email (producción)
    private static final Integer MAX_LINES_PER_EMAIL   = 5000;  // incluye header
    private static final Integer MAX_EMAILS_PER_FINISH = 10;    // máx. correos por finish
    private static final String  CSV_FILENAME_PREFIX   = 'AccountIdBatch_';

    // ---- SOLO PARA TESTS (se pueden sobreescribir desde los @IsTest)
    @TestVisible static Integer TV_MAX_LINES_PER_EMAIL   = MAX_LINES_PER_EMAIL;
    @TestVisible static Integer TV_MAX_EMAILS_PER_FINISH = MAX_EMAILS_PER_FINISH;
    @TestVisible static Boolean TV_FORCE_FAIL            = false;

    public AccountIdGeneratorBatchWithCsvDyn() {
        this.emailRecipient = UserInfo.getUserEmail();
    }
    public AccountIdGeneratorBatchWithCsvDyn(String recipientEmail) {
        this.emailRecipient = String.isBlank(recipientEmail) ? UserInfo.getUserEmail() : recipientEmail;
    }

    // ---- Batchable
    global Database.QueryLocator start(Database.BatchableContext bc) {
        if (!headerAdded) {
            csvLines.add('AccountId,Name,RecordTypeId,PrimaryContactId,OutcomeCode,OutcomeMessage');
            headerAdded = true;
        }
        return Database.getQueryLocator([
            SELECT Id, Name, RecordTypeId, RecordType.DeveloperName, hed__Primary_Contact__c, ID_Account__c
            FROM Account
            WHERE ID_Account__c = null
            ORDER BY Name
        ]);
    }

    global void execute(Database.BatchableContext bc, List<SObject> scope) {
        final Integer MAX_LEN = 20;
        final Integer SEQ_LEN = 7;

        // RecordTypes por DeveloperName
        Map<String, Schema.RecordTypeInfo> rtByDev =
            Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();

        Id adminRtId          = rtByDev.containsKey('Administrative')           ? rtByDev.get('Administrative').getRecordTypeId()           : null;
        Id academicRtId       = rtByDev.containsKey('Academic_Program')         ? rtByDev.get('Academic_Program').getRecordTypeId()         : null;
        Id businessRtId       = rtByDev.containsKey('Business_Organization')    ? rtByDev.get('Business_Organization').getRecordTypeId()    : null;
        Id educationRtId      = rtByDev.containsKey('Educational_Institution')  ? rtByDev.get('Educational_Institution').getRecordTypeId()  : null;
        Id householdRtId      = rtByDev.containsKey('HH_Account')               ? rtByDev.get('HH_Account').getRecordTypeId()               : null;
        Id sportsRtId         = rtByDev.containsKey('Sports_Organization')      ? rtByDev.get('Sports_Organization').getRecordTypeId()      : null;
        Id universityDeptRtId = rtByDev.containsKey('University_Department')    ? rtByDev.get('University_Department').getRecordTypeId()    : null;
        Id organismeRtId      = rtByDev.containsKey('Organisme')                ? rtByDev.get('Organisme').getRecordTypeId()                : null;
        Id egliseRtId         = rtByDev.containsKey('Eglise')                   ? rtByDev.get('Eglise').getRecordTypeId()                   : null;

        List<Account> accts = new List<Account>();
        for (SObject s : scope) accts.add((Account)s);

        // ---- Colecciones por tipo
        List<Account> adminWithContact = new List<Account>();
        Set<Id> adminPCIds = new Set<Id>();

        List<Account> adminNoContact = new List<Account>();
        Set<String> orphanNamesRaw = new Set<String>(); // para detectar gemela con contacto

        List<Account> nonAdminToProcess = new List<Account>();
        Map<Account, String> nonAdminPrefix = new Map<Account, String>();

        // Clasificar
        for (Account a : accts) {
            if (String.isBlank(a.Name) || a.RecordTypeId == null) {
                csvLines.add(csv(a.Id,a.Name,a.RecordTypeId,a.hed__Primary_Contact__c,'SKIPPED_NO_NAME_OR_RT','Skipped: missing Name or RecordType'));
                continue;
            }
            Boolean isAdmin = (adminRtId != null && a.RecordTypeId == adminRtId);

            if (isAdmin) {
                if (a.hed__Primary_Contact__c != null) {
                    adminWithContact.add(a);
                    adminPCIds.add(a.hed__Primary_Contact__c);
                } else {
                    adminNoContact.add(a);
                    orphanNamesRaw.add(a.Name);
                }
            } else {
                // Prefijos fijos sin 1ª letra del nombre
                if      (a.RecordTypeId == academicRtId)        nonAdminPrefix.put(a, 'ACA');
                else if (a.RecordTypeId == businessRtId)        nonAdminPrefix.put(a, 'BUS');
                else if (a.RecordTypeId == educationRtId)       nonAdminPrefix.put(a, 'EDU');
                else if (a.RecordTypeId == householdRtId)       nonAdminPrefix.put(a, 'HOU');
                else if (a.RecordTypeId == sportsRtId)          nonAdminPrefix.put(a, 'SPO');
                else if (a.RecordTypeId == universityDeptRtId)  nonAdminPrefix.put(a, 'UNI');
                else if (a.RecordTypeId == organismeRtId)       nonAdminPrefix.put(a, 'ORG');
                else if (a.RecordTypeId == egliseRtId)          nonAdminPrefix.put(a, 'EGL');
                if (nonAdminPrefix.containsKey(a)) nonAdminToProcess.add(a);
            }
        }

        // ---- ADMIN + contacto: proponer cortos y detectar colisiones (con guion)
        Map<Account,String> shortIdByAcc = new Map<Account,String>();
        Set<String> shortCandidates = new Set<String>();
        if (!adminPCIds.isEmpty()) {
            Map<Id, Contact> cons = new Map<Id, Contact>([
                SELECT Id, ID_Contact__c FROM Contact WHERE Id IN :adminPCIds
            ]);
            for (Account a : adminWithContact) {
                Contact c = cons.get(a.hed__Primary_Contact__c);
                if (c != null && !String.isBlank(c.ID_Contact__c)) {
                    String shortId = truncate('I-' + c.ID_Contact__c, MAX_LEN); // ahora I-XXXX
                    shortIdByAcc.put(a, shortId);
                    shortCandidates.add(shortId);
                }
            }
        }

        Set<String> usedShorts = new Set<String>();
        if (!shortCandidates.isEmpty()) {
            for (AggregateResult ar : [
                SELECT ID_Account__c s, COUNT(Id) c
                FROM Account
                WHERE ID_Account__c IN :shortCandidates
                GROUP BY ID_Account__c
            ]) {
                String s = (String)ar.get('s');
                if (!String.isBlank(s)) usedShorts.add(s);
            }
        }

        // ---- Detectar “gemela con contacto” para huérfanas (mismo Name, Administrative y con contacto)
        Set<String> namesWithContactTwin = new Set<String>();
        if (!orphanNamesRaw.isEmpty() && adminRtId != null) {
            for (Account t : [
                SELECT Id, Name
                FROM Account
                WHERE RecordTypeId = :adminRtId
                  AND hed__Primary_Contact__c != null
                  AND Name IN :orphanNamesRaw
            ]) namesWithContactTwin.add(normalize(t.Name));
        }

        // ---- Prefijos largos y máximos (fallback largo fijo: I-ADM)
        List<Account> needLong = new List<Account>();
        Map<Account,String> longPrefixByAcc = new Map<Account,String>();
        Set<String> longPrefixes = new Set<String>();

        // Admin con contacto que chocan o sin ID de contacto -> I-ADM
        for (Account a : adminWithContact) {
            String proposedShort = shortIdByAcc.get(a);
            if (String.isBlank(proposedShort) || usedShorts.contains(proposedShort)) {
                String p = 'I-ADM';
                longPrefixByAcc.put(a, p);
                longPrefixes.add(p);
                needLong.add(a);
            }
        }
        // Admin sin contacto -> I-ADM, salvo gemela con contacto (se deja null)
        for (Account a : adminNoContact) {
            if (namesWithContactTwin.contains(normalize(a.Name))) continue; // dejar null
            String p = 'I-ADM';
            longPrefixByAcc.put(a, p);
            longPrefixes.add(p);
            needLong.add(a);
        }

        // ---- Máximos por prefijo largo (I-ADM)
        Map<String,Integer> maxByLong = new Map<String,Integer>();
        if (!longPrefixes.isEmpty()) {
            List<String> prefList = new List<String>(longPrefixes);
            Integer block = 30;
            for (Integer i=0; i<prefList.size(); i+=block) {
                Integer endIdx = Math.min(i+block, prefList.size());
                List<String> ors = new List<String>();
                for (Integer j=i; j<endIdx; j++) {
                    ors.add('ID_Account__c LIKE \'' + String.escapeSingleQuotes(prefList[j]) + '%\'');
                }
                String soql = 'SELECT ID_Account__c FROM Account WHERE ID_Account__c != null AND (' + String.join(ors,' OR ') + ')';
                for (Account e : Database.query(soql)) {
                    String full = e.ID_Account__c;
                    if (String.isBlank(full)) continue;
                    for (Integer j=i; j<endIdx; j++) {
                        String p = prefList[j];
                        if (full.startsWith(p) && full.length() > p.length()) {
                            Integer n = 0;
                            try { n = Integer.valueOf(removeLeadingZeros(full.substring(p.length()))); } catch (Exception ignore) {}
                            Integer cur = maxByLong.containsKey(p) ? maxByLong.get(p) : 0;
                            if (n > cur) maxByLong.put(p, n);
                            break;
                        }
                    }
                }
            }
        }

        // ---- Asignar largos (I-ADM + 7 dígitos)
        for (Account a : needLong) {
            String p = longPrefixByAcc.get(a); // 'I-ADM'
            Integer next = (maxByLong.containsKey(p) ? maxByLong.get(p) : 0) + 1;
            maxByLong.put(p, next);
            a.ID_Account__c = truncate(p + leftPad(String.valueOf(next), SEQ_LEN), MAX_LEN);
        }

        // ---- Asignar cortos (I-<ID_Contact__c>) a los que no recibieron largo
        for (Account a : adminWithContact) {
            if (!String.isBlank(a.ID_Account__c)) continue; // ya recibió largo
            String shortId = shortIdByAcc.get(a);
            if (!String.isBlank(shortId) && !usedShorts.contains(shortId)) {
                a.ID_Account__c = shortId;
            }
        }

        // ---- Otros Record Types ⇒ prefijos fijos + 7 dígitos (sin 1ª letra del nombre)
        if (!nonAdminToProcess.isEmpty()) {
            Set<String> prefixes = new Set<String>();
            for (Account a : nonAdminToProcess) prefixes.add(nonAdminPrefix.get(a));

            Map<String,Integer> maxByOther = new Map<String,Integer>();
            if (!prefixes.isEmpty()) {
                List<String> prefList = new List<String>(prefixes);
                Integer block = 30;
                for (Integer i=0; i<prefList.size(); i+=block) {
                    Integer endIdx = Math.min(i+block, prefList.size());
                    List<String> ors = new List<String>();
                    for (Integer j=i; j<endIdx; j++) {
                        ors.add('ID_Account__c LIKE \'' + String.escapeSingleQuotes(prefList[j]) + '%\'');
                    }
                    String soql = 'SELECT ID_Account__c FROM Account WHERE ID_Account__c != null AND (' + String.join(ors,' OR ') + ')';
                    for (Account e : Database.query(soql)) {
                        String full = e.ID_Account__c;
                        if (String.isBlank(full)) continue;
                        for (Integer j=i; j<endIdx; j++) {
                            String p = prefList[j];
                            if (full.startsWith(p) && full.length() > p.length()) {
                                Integer n = 0;
                                try { n = Integer.valueOf(removeLeadingZeros(full.substring(p.length()))); } catch (Exception ignore) {}
                                Integer cur = maxByOther.containsKey(p) ? maxByOther.get(p) : 0;
                                if (n > cur) maxByOther.put(p, n);
                                break;
                            }
                        }
                    }
                }
            }

            for (Account a : nonAdminToProcess) {
                String p = nonAdminPrefix.get(a); // 'BUS','EGL','ORG', etc.
                Integer next = (maxByOther.containsKey(p) ? maxByOther.get(p) : 0) + 1;
                maxByOther.put(p, next);
                a.ID_Account__c = truncate(p + leftPad(String.valueOf(next), SEQ_LEN), MAX_LEN);
            }
        }

// ---- Guardar (éxito parcial) SOLO las que ahora tienen ID
List<Account> toUpdate = new List<Account>();
for (Account a : accts) if (!String.isBlank(a.ID_Account__c)) toUpdate.add(a);

if (!toUpdate.isEmpty()) {
    // En tests: simular fallos sin DML para que BD quede intacta
    if (Test.isRunningTest() && TV_FORCE_FAIL) {
        for (Account aTmp : toUpdate) {
            failCount++;
            csvLines.add(csv(
                aTmp.Id,
                aTmp.Name,
                aTmp.RecordTypeId,
                aTmp.hed__Primary_Contact__c,
                'STRING_TOO_LONG',
                'Forced failure in test to exercise error path'
            ));
        }
    } else {
        Database.SaveResult[] sr = Database.update(toUpdate, /* allOrNone */ false);
        for (Integer i = 0; i < sr.size(); i++) {
            if (sr[i].isSuccess()) {
                successCount++;
                csvLines.add(csv(
                    toUpdate[i].Id,
                    toUpdate[i].Name,
                    toUpdate[i].RecordTypeId,
                    toUpdate[i].hed__Primary_Contact__c,
                    'OK',
                    'ID assigned'
                ));
            } else {
                failCount++;
                for (Database.Error e : sr[i].getErrors()) {
                    csvLines.add(csv(
                        toUpdate[i].Id,
                        toUpdate[i].Name,
                        toUpdate[i].RecordTypeId,
                        toUpdate[i].hed__Primary_Contact__c,
                        String.valueOf(e.getStatusCode()),
                        e.getMessage()
                    ));
                }
            }
        }
    }
}


}

    global void finish(Database.BatchableContext bc) {
        // Asegura un CSV mínimo para ambos caminos
        if (csvLines.isEmpty()) {
            csvLines.add('AccountId,Name,RecordTypeId,PrimaryContactId,OutcomeCode,OutcomeMessage');
            csvLines.add('"","","","","NO_ROWS","No accounts needed updates"');
        }

        // Siempre construye y (en test) simula emails
        sendPagedEmails('Account (Unified IDs with fallback)', CSV_FILENAME_PREFIX, csvLines, successCount, failCount);

        // Siempre intenta guardar el CSV; en test saveCsvAsFile sale si TEST_ENABLE_FINISH_FILES=false
        String csv = String.join(csvLines, '\n');
        String fileName = CSV_FILENAME_PREFIX + Datetime.now().format('yyyyMMdd_HHmmss') + '.csv';
        saveCsvAsFile(fileName, csv);
    }

    // ---- Helpers
private static String normalize(String input) {
    if (input == null) return '';
    Map<String, String> accentMap = new Map<String, String>{
        // Mayúsculas
        'Á'=>'A','É'=>'E','Í'=>'I','Ó'=>'O','Ú'=>'U',
        'À'=>'A','È'=>'E','Ì'=>'I','Ò'=>'O','Ù'=>'U',
        'Â'=>'A','Ê'=>'E','Î'=>'I','Ô'=>'O','Û'=>'U',
        'Ä'=>'A','Ë'=>'E','Ï'=>'I','Ö'=>'O','Ü'=>'U',
        'Ñ'=>'N','Ç'=>'C','Ÿ'=>'Y','Š'=>'S','Ž'=>'Z',
        // Minúsculas añadidas
        'á'=>'A','é'=>'E','í'=>'I','ó'=>'O','ú'=>'U',
        'à'=>'A','è'=>'E','ì'=>'I','ò'=>'O','ù'=>'U',
        'â'=>'A','ê'=>'E','î'=>'I','ô'=>'O','û'=>'U',
        'ä'=>'A','ë'=>'E','ï'=>'I','ö'=>'O','ü'=>'U',
        'ñ'=>'N','ç'=>'C','ÿ'=>'Y','š'=>'S','ž'=>'Z',
        // Ligaduras (por si aparecen)
        'Æ'=>'AE','Œ'=>'OE','æ'=>'AE','œ'=>'OE','ß'=>'SS'
    };
    String out = '';
    for (Integer i = 0; i < input.length(); i++) {
        String ch = input.substring(i, i+1);
        out += accentMap.containsKey(ch) ? accentMap.get(ch) : ch.toUpperCase();
    }
    return out; // SIN replaceAll; no limpia espacios/guiones, solo quita acentos
}
    private static String leftPad(String s, Integer size) {
        while (s.length() < size) s = '0' + s;
        return s;
    }
    private static String removeLeadingZeros(String s) {
        Integer len = s.length(), i = 0;
        for (i = 0; i < len; i++) if (s.substring(i,i+1) != '0') break;
        return (i < len) ? s.substring(i) : '0';
    }
    private static String truncate(String s, Integer maxLen) {
        return (s.length() > maxLen) ? s.substring(0, maxLen) : s;
    }
    private static String csvEscape(String s) {
        if (s == null) s = '';
        s = s.replace('"','""');
        return '"' + s + '"';
    }
    private static String csv(Id accId, String name, Id rtId, Id pcId, String code, String msg) {
        return csvEscape(String.valueOf(accId))+','+
               csvEscape(name)+','+
               csvEscape(String.valueOf(rtId))+','+
               csvEscape(String.valueOf(pcId))+','+
               csvEscape(code)+','+
               csvEscape(msg);
    }

    @TestVisible
    private static Map<String,Integer> computeMaxByPrefixes(Set<String> prefixes) {
        Map<String,Integer> result = new Map<String,Integer>();
        if (prefixes == null || prefixes.isEmpty()) return result;

        List<String> prefList = new List<String>(prefixes);
        Integer block = 30;

        for (Integer i = 0; i < prefList.size(); i += block) {
            Integer endIdx = Math.min(i + block, prefList.size());

            List<String> ors = new List<String>();
            for (Integer j = i; j < endIdx; j++) {
                ors.add('ID_Account__c LIKE \'' + String.escapeSingleQuotes(prefList[j]) + '%\'');
            }

            String soql = 'SELECT ID_Account__c FROM Account ' +
                          'WHERE ID_Account__c != null AND (' + String.join(ors, ' OR ') + ')';

            for (Account e : Database.query(soql)) {
                String full = e.ID_Account__c;
                if (String.isBlank(full)) continue;

                for (Integer j = i; j < endIdx; j++) {
                    String p = prefList[j];
                    if (full.startsWith(p) && full.length() > p.length()) {
                        Integer n = 0;
                        try { n = Integer.valueOf(removeLeadingZeros(full.substring(p.length()))); }
                        catch (Exception ignore) {}
                        Integer cur = result.containsKey(p) ? result.get(p) : 0;
                        if (n > cur) result.put(p, n);
                        break;
                    }
                }
            }
        }
        return result;
    }

    // ---- Email paginado  (cambiado a “dry-run” en test)
    private void sendPagedEmails(String entity, String filePrefix, List<String> lines, Integer ok, Integer fail) {
        // En test: ejecuta toda la lógica pero NO envía correos
        Boolean dryRun = Test.isRunningTest();
        String orgName = UserInfo.getOrganizationName();

        // Sin errores → un solo correo de resumen
        if (fail == 0) {
            if (lines.isEmpty()) lines.add('AccountId,Name,RecordTypeId,PrimaryContactId,OutcomeCode,OutcomeMessage');

            Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();
            msg.setToAddresses(new String[] { emailRecipient });
            msg.setSubject('[' + orgName + '] Dynamic IDs – ' + entity + ' Summary (No errors)');
            msg.setPlainTextBody(
                'Organization: ' + orgName + '\n' +
                'Entity: ' + entity + '\n' +
                'Successful: ' + ok + '\n' +
                'Failed: ' + fail + '\n' +
                'Status: Completed.'
            );

            String csv = String.join(lines, '\n');
            Messaging.EmailFileAttachment att = new Messaging.EmailFileAttachment();
            att.setFileName(filePrefix + Datetime.now().format('yyyyMMdd_HHmmss') + '.csv');
            att.setContentType('text/csv');
            att.setBody(Blob.valueOf(csv));
            msg.setFileAttachments(new Messaging.EmailFileAttachment[] { att });

            if (!dryRun) Messaging.sendEmail(new Messaging.SingleEmailMessage[] { msg });
            return;
        }

        // Hay errores → partir en N correos
        Boolean hasHeader = !lines.isEmpty();
        Integer headerCount = hasHeader ? 1 : 0;
        Integer totalLines = lines.size();
        Integer payloadLines = Math.max(0, totalLines - headerCount);

        // Usar variables test-visibles en lugar de las constantes
        Integer linesPerEmail = Math.max(2, TV_MAX_LINES_PER_EMAIL); // header + al menos 1 fila
        Integer rowsPerPart   = linesPerEmail - 1;
        Integer maxEmails     = Math.max(1, TV_MAX_EMAILS_PER_FINISH);

        Integer totalParts  = (Integer)Math.ceil((Decimal)payloadLines / Math.max(1, rowsPerPart));
        Integer partsToSend = Math.min(totalParts, maxEmails);

        for (Integer part = 1; part <= partsToSend; part++) {
            Integer startDataIdx = headerCount + (part - 1) * rowsPerPart;
            Integer endDataIdxExclusive = Math.min(totalLines, startDataIdx + rowsPerPart);

            List<String> chunk = new List<String>();
            if (hasHeader) chunk.add(lines[0]);
            for (Integer j = startDataIdx; j < endDataIdxExclusive; j++) chunk.add(lines[j]);

            Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();
            msg.setToAddresses(new String[] { emailRecipient });
            msg.setSubject('[' + orgName + '] Dynamic IDs – ' + entity + ' Errors (Part ' + part + ' of ' + totalParts + ')');

            String body =
                'Organization: ' + orgName + '\n' +
                'Entity: ' + entity + '\n' +
                'Successful: ' + ok + '\n' +
                'Failed: ' + fail + '\n' +
                'This email includes error details Part ' + part + ' of ' + totalParts + '.';
            if (totalParts > partsToSend) {
                body += '\n\nNOTE: Output truncated to ' + partsToSend + ' emails (max). Re-run after fixes if you need the remaining rows.';
            }
            msg.setPlainTextBody(body);

            String csv = String.join(chunk, '\n');
            Messaging.EmailFileAttachment att = new Messaging.EmailFileAttachment();
            att.setFileName(filePrefix + Datetime.now().format('yyyyMMdd_HHmmss') + '_part' + part + 'of' + totalParts + '.csv');
            att.setContentType('text/csv');
            att.setBody(Blob.valueOf(csv));
            msg.setFileAttachments(new Messaging.EmailFileAttachment[] { att });

            if (!dryRun) Messaging.sendEmail(new Messaging.SingleEmailMessage[] { msg });
        }
    }

    // ---- Guardar CSV como File  (permite DML en test si el flag lo pide)
    private void saveCsvAsFile(String fileName, String csvBody) {
        Blob body = Blob.valueOf(csvBody);

        Boolean allowDml = !Test.isRunningTest() || TEST_ENABLE_FINISH_FILES;
        if (!allowDml) return;

        ContentVersion cv = new ContentVersion();
        cv.Title        = fileName;
        cv.PathOnClient = fileName;
        cv.VersionData  = body;
        insert cv;

        cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];

        // Vincular al usuario actual; si ya está vinculado, ignorar el duplicado
        try {
            ContentDocumentLink cdl = new ContentDocumentLink();
            cdl.ContentDocumentId = cv.ContentDocumentId;
            cdl.LinkedEntityId    = UserInfo.getUserId();
            cdl.ShareType         = 'I';
            cdl.Visibility        = 'AllUsers';
            insert cdl;

            // --- SOLO TEST: fuerza un segundo insert idéntico para cubrir el catch DUPLICATE_VALUE
            if (Test.isRunningTest() && TEST_ENABLE_FINISH_FILES && TV_LINK_FILE_TWICE) {
                insert cdl; // dispara DUPLICATE_VALUE
            }
        } catch (DmlException e) {
            if (!String.valueOf(e).contains('DUPLICATE_VALUE')) throw e;
            // Si ya estaba vinculado, lo ignoramos.
        }
    }
}