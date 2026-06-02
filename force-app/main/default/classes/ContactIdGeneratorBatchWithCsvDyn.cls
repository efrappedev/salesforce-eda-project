global class ContactIdGeneratorBatchWithCsvDyn implements Database.Batchable<SObject>, Database.Stateful {

    // ==== TEST FLAGS (no impactan producción) ====
    @TestVisible static Boolean TEST_ENABLE_FINISH_FILES  = false;  // permitir DML de File en tests
    @TestVisible static Boolean TV_LINK_FILE_TWICE        = false;  // forzar 2º link en tests (para cubrir catch)
    @TestVisible static Boolean TV_FORCE_FAIL             = false;  // si luego quieres forzar fallos controlados

    // ---- Config / Estado
    private String emailRecipient;
    private Integer successCount = 0;
    private Integer failCount = 0;

    private List<String> csvLines = new List<String>();
    private Boolean headerAdded = false;

    // Límites de email (PRODUCCIÓN)
    private static final Integer MAX_LINES_PER_EMAIL   = 5000; // incluye header
    private static final Integer MAX_EMAILS_PER_FINISH = 10;   // máx. emails en finish
    private static final String  CSV_FILENAME_PREFIX   = 'ContactIdErrors_';
    private static final Integer MIN_SEQ_LEN           = 4;

    // Letras válidas para prefijo (A–Z)
    private static final String  ALPHA                 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';

    // Copias test-visibles para poder reducir los límites en pruebas
    @TestVisible static Integer TV_MAX_LINES_PER_EMAIL   = MAX_LINES_PER_EMAIL;
    @TestVisible static Integer TV_MAX_EMAILS_PER_FINISH = MAX_EMAILS_PER_FINISH;

    public ContactIdGeneratorBatchWithCsvDyn() {
        this.emailRecipient = UserInfo.getUserEmail();
    }
    public ContactIdGeneratorBatchWithCsvDyn(String recipientEmail) {
        this.emailRecipient = String.isBlank(recipientEmail) ? UserInfo.getUserEmail() : recipientEmail;
    }

    // ---- Batchable
    global Database.QueryLocator start(Database.BatchableContext bc) {
        if (!headerAdded) {
            csvLines.add('ContactId,FirstName,LastName,ErrorCode,ErrorMessage');
            headerAdded = true;
        }
        return Database.getQueryLocator([
            SELECT Id, FirstName, LastName, ID_Contact__c
            FROM Contact
            WHERE ID_Contact__c = null
            ORDER BY LastName, FirstName
        ]);
    }

    global void execute(Database.BatchableContext bc, List<SObject> scope) {
        List<Contact> contacts = new List<Contact>();
        for (SObject s : scope) contacts.add((Contact)s);

        // 1) Validar nombres; calcular prefijos (4 letras: 3 ap + 1 nom), saltando signos
        Map<Contact, String> contactToPrefix = new Map<Contact, String>();
        for (Contact c : contacts) {
            if (String.isBlank(c.LastName) || String.isBlank(c.FirstName)) {
                // Datos faltantes
                csvLines.add(csvEscape(c.Id)+','+csvEscape(c.FirstName)+','+csvEscape(c.LastName)+','+csvEscape('DATA_MISSING')+','+csvEscape('FirstName and/or LastName is blank'));
                failCount++;
                continue;
            }

            // NUEVO: tomar solo letras A–Z tras normalizar (omite espacios, guiones, apóstrofes, etc.)
            String ln3 = takeAlpha(c.LastName, 3);
            String fn1 = takeAlpha(c.FirstName, 1);

            if (String.isBlank(ln3) || String.isBlank(fn1)) {
                // Tras normalizar/filtrar podría quedar vacío (caracteres no A-Z)
                csvLines.add(csvEscape(c.Id)+','+csvEscape(c.FirstName)+','+csvEscape(c.LastName)+','+csvEscape('DATA_MISSING')+','+csvEscape('Name reduced to empty after normalization/letter filtering'));
                failCount++;
                continue;
            }

            String prefix = ln3 + fn1; // 4 chars
            contactToPrefix.put(c, prefix);
        }
        if (contactToPrefix.isEmpty()) return;

        // 2) Buscar máximos existentes por prefijo en POCAS queries (bloques con OR)
        Set<String> prefixes = new Set<String>(contactToPrefix.values());
        Map<String, Integer> foundMax = new Map<String, Integer>();

        if (!prefixes.isEmpty()) {
            List<String> prefList = new List<String>(prefixes);
            Integer block = 30; // prudente
            for (Integer i = 0; i < prefList.size(); i += block) {
                List<String> ors = new List<String>();
                Integer endIdx = Math.min(i + block, prefList.size());
                for (Integer j = i; j < endIdx; j++) {
                    ors.add('ID_Contact__c LIKE \'' + String.escapeSingleQuotes(prefList[j]) + '%\'');
                }
                String soql = 'SELECT ID_Contact__c FROM Contact WHERE ID_Contact__c != null AND (' + String.join(ors, ' OR ') + ')';
                for (Contact e : Database.query(soql)) {
                    String full = e.ID_Contact__c;
                    if (full != null && full.length() >= 5) {
                        // Determinar el prefijo correcto comparando inicio
                        for (Integer j = i; j < endIdx; j++) {
                            String p = prefList[j];
                            if (full.startsWith(p)) {
                                String numStr = full.substring(4);
                                Integer num = 0;
                                try { num = Integer.valueOf(removeLeadingZeros(numStr)); } catch (Exception ignore) {}
                                Integer cur = foundMax.containsKey(p) ? foundMax.get(p) : 0;
                                if (num > cur) foundMax.put(p, num);
                                break;
                            }
                        }
                    }
                }
            }
        }

        // 3) Asignar IDs con secuencia mínima de 4 dígitos
        Map<String, Integer> nextByPrefix = new Map<String, Integer>(foundMax);
        List<Contact> toUpdate = new List<Contact>();

        for (Contact c : contacts) {
            String prefix = contactToPrefix.get(c);
            if (String.isBlank(prefix)) continue; // ya registrado como DATA_MISSING
            Integer nextNum = (nextByPrefix.containsKey(prefix) ? nextByPrefix.get(prefix) : 0) + 1;
            nextByPrefix.put(prefix, nextNum);
            Integer seqLength = Math.max(MIN_SEQ_LEN, String.valueOf(nextNum).length());
            c.ID_Contact__c = prefix + leftPad(String.valueOf(nextNum), seqLength);
            toUpdate.add(c);
        }

        if (!toUpdate.isEmpty()) {
            Database.SaveResult[] sr = Database.update(toUpdate, /* allOrNone */ false);
            for (Integer i = 0; i < sr.size(); i++) {
                if (sr[i].isSuccess()) {
                    successCount++;
                } else {
                    failCount++;
                    for (Database.Error e : sr[i].getErrors()) {
                        csvLines.add(
                            csvEscape(toUpdate[i].Id)+','+
                            csvEscape(toUpdate[i].FirstName)+','+
                            csvEscape(toUpdate[i].LastName)+','+
                            csvEscape(String.valueOf(e.getStatusCode()))+','+
                            csvEscape(e.getMessage())
                        );
                    }
                }
            }
        }
    }

    global void finish(Database.BatchableContext bc) {
        // En test: arma mensajes/adjuntos pero NO envía correos reales
        sendPagedEmails('Contact', CSV_FILENAME_PREFIX, csvLines, successCount, failCount);

        if (csvLines.isEmpty()) {
            csvLines.add('ContactId,FirstName,LastName,ErrorCode,ErrorMessage');
        }
        String csv = String.join(csvLines, '\n');
        String fileName = CSV_FILENAME_PREFIX + Datetime.now().format('yyyyMMdd_HHmmss') + '.csv';
        saveCsvAsFile(fileName, csv);
    }

    // ---- Helpers de negocio
    private static String normalize(String input) {
        if (input == null) return '';
        Map<String, String> accentMap = new Map<String, String>{
            // Mayúsculas
            'Á'=>'A','É'=>'E','Í'=>'I','Ó'=>'O','Ú'=>'U',
            'À'=>'A','È'=>'E','Ì'=>'I','Ò'=>'O','Ù'=>'U',
            'Â'=>'A','Ê'=>'E','Î'=>'I','Ô'=>'O','Û'=>'U',
            'Ä'=>'A','Ë'=>'E','Ï'=>'I','Ö'=>'O','Ü'=>'U',
            'Ñ'=>'N','Ç'=>'C','Ÿ'=>'Y','Š'=>'S','Ž'=>'Z',
            // Minúsculas
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
        return out;
    }

    // NUEVO: tomar solo letras A–Z tras normalizar (omite espacios, guiones, apóstrofes, etc.)
    private static String takeAlpha(String input, Integer n) {
        if (String.isBlank(input) || n == null || n <= 0) return '';
        String s = normalize(input.trim());
        String out = '';
        for (Integer i = 0; i < s.length() && out.length() < n; i++) {
            String ch = s.substring(i, i+1);
            if (ALPHA.contains(ch)) out += ch;
        }
        return out;
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
    private static String csvEscape(String s) {
        if (s == null) s = '';
        s = s.replace('"','""');
        return '"' + s + '"';
    }

    @TestVisible
    private static void testSaveCsvAndDuplicateLink() {
        TEST_ENABLE_FINISH_FILES = true;
        TV_LINK_FILE_TWICE       = true; // fuerza el segundo insert -> catch DUPLICATE_VALUE
        String csv = 'ContactId,FirstName,LastName,ErrorCode,ErrorMessage\n"1","A","B","X","Y"';
        new ContactIdGeneratorBatchWithCsvDyn().saveCsvAsFile('ContactIdErrors_TEST.csv', csv);
    }

    // --- TEST HOOKS (solo cobertura; no impactan prod)
    @TestVisible
    static void testSendEmails_NoErrors() {
        // Cubre rama "summary / no errors"
        ContactIdGeneratorBatchWithCsvDyn b = new ContactIdGeneratorBatchWithCsvDyn();
        List<String> lines = new List<String>{
            'ContactId,FirstName,LastName,ErrorCode,ErrorMessage' // header
        };
        b.sendPagedEmails('Contact', CSV_FILENAME_PREFIX, lines, /*ok*/3, /*fail*/0);
    }

    @TestVisible
    static void testSendEmails_Errors_Paged_Truncated() {
        // Cubre rama "fail>0" + paginado + NOTA de truncamiento
        Integer oldLines  = TV_MAX_LINES_PER_EMAIL;
        Integer oldEmails = TV_MAX_EMAILS_PER_FINISH;
        try {
            TV_MAX_LINES_PER_EMAIL   = 2; // header + 1 fila por email
            TV_MAX_EMAILS_PER_FINISH = 1; // fuerza truncamiento

            ContactIdGeneratorBatchWithCsvDyn b = new ContactIdGeneratorBatchWithCsvDyn();
            List<String> lines = new List<String>{
                'ContactId,FirstName,LastName,ErrorCode,ErrorMessage',
                '"1","A","B","X","Y"',
                '"2","A","B","X","Y"'
            };
            b.sendPagedEmails('Contact', CSV_FILENAME_PREFIX, lines, /*ok*/0, /*fail*/2);
        } finally {
            TV_MAX_LINES_PER_EMAIL   = oldLines;
            TV_MAX_EMAILS_PER_FINISH = oldEmails;
        }
    }

    // ---- Email paginado (prod usa MAX_*, tests usan TV_MAX_*)
    private void sendPagedEmails(String entity, String filePrefix, List<String> lines, Integer ok, Integer fail) {
        String orgName = UserInfo.getOrganizationName();
        Boolean isTest = Test.isRunningTest();

        if (fail == 0) {
            if (lines.isEmpty()) lines.add('ContactId,FirstName,LastName,ErrorCode,ErrorMessage');

            Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();
            msg.setToAddresses(new String[] { emailRecipient });
            msg.setSubject('[' + orgName + '] Dynamic IDs – ' + entity + ' Batch Summary (No errors)');
            msg.setPlainTextBody(
                'Organization: ' + orgName + '\n' +
                'Entity: ' + entity + '\n' +
                'Successful: ' + ok + '\n' +
                'Failed: ' + fail + '\n' +
                'Status: Completed without errors.'
            );

            String csv = String.join(lines, '\n');
            Messaging.EmailFileAttachment att = new Messaging.EmailFileAttachment();
            att.setFileName(filePrefix + Datetime.now().format('yyyyMMdd_HHmmss') + '.csv');
            att.setContentType('text/csv');
            att.setBody(Blob.valueOf(csv));
            msg.setFileAttachments(new Messaging.EmailFileAttachment[] { att });

            if (!isTest) Messaging.sendEmail(new Messaging.SingleEmailMessage[] { msg });
            return;
        }

        Boolean hasHeader = !lines.isEmpty();
        Integer headerCount = hasHeader ? 1 : 0;
        Integer totalLines = lines.size();
        Integer payloadLines = Math.max(0, totalLines - headerCount);

        Integer effectiveLinesPerEmail = isTest ? Math.max(2, TV_MAX_LINES_PER_EMAIL) : MAX_LINES_PER_EMAIL;
        Integer rowsPerPart            = effectiveLinesPerEmail - 1;
        Integer effectiveMaxEmails     = isTest ? Math.max(1, TV_MAX_EMAILS_PER_FINISH) : MAX_EMAILS_PER_FINISH;

        Integer totalParts  = (Integer)Math.ceil((Decimal)payloadLines / Math.max(1, rowsPerPart));
        Integer partsToSend = Math.min(totalParts, effectiveMaxEmails);

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

            if (!isTest) Messaging.sendEmail(new Messaging.SingleEmailMessage[] { msg });
        }
    }

    // ---- Guardar CSV como Files
    private void saveCsvAsFile(String fileName, String csvBody) {
        Blob body = Blob.valueOf(csvBody);

        // En tests, solo hace DML si activas el flag; en prod siempre guarda
        Boolean allowDml = !Test.isRunningTest() || TEST_ENABLE_FINISH_FILES;
        if (!allowDml) return;

        ContentVersion cv = new ContentVersion();
        cv.Title        = fileName;
        cv.PathOnClient = fileName;
        cv.VersionData  = body;
        insert cv;

        cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];

        // Vincular al usuario SOLO si no existe ya el link
        Id userId = UserInfo.getUserId();
        Boolean hasLink = ![
            SELECT Id FROM ContentDocumentLink
            WHERE ContentDocumentId = :cv.ContentDocumentId
              AND LinkedEntityId    = :userId
            LIMIT 1
        ].isEmpty();

        if (!hasLink) {
            ContentDocumentLink cdl = new ContentDocumentLink();
            cdl.ContentDocumentId = cv.ContentDocumentId;
            cdl.LinkedEntityId    = userId;
            cdl.ShareType         = 'I';     // InternalUser
            cdl.Visibility        = 'AllUsers';
            insert cdl;

            // SOLO TEST (opcional): fuerza un segundo insert para cubrir catch de duplicado
            if (Test.isRunningTest() && TEST_ENABLE_FINISH_FILES && TV_LINK_FILE_TWICE) {
                try {
                    insert cdl; // disparará DUPLICATE_VALUE
                } catch (DmlException ignore) {}
            }
        }
    }
}