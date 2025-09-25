trigger Account_GenerateID on Account (before insert, before update, after insert, after update) {

    // Kill switch global (como ya lo tenías)
    if ('true' == String.valueOf(Label.IDGEN_DISABLE_ACCOUNT_TRIGGER).toLowerCase()) return;

    // ===========================
    // ======= BEFORE (SIN CAMBIOS DE LÓGICA) =======
    // ===========================
    if (Trigger.isBefore) {
        // ===== RecordTypes por DeveloperName =====
        Map<String, Schema.RecordTypeInfo> rtByDev =
            Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();

        Id adminRtId          = rtByDev.containsKey('Administrative')          ? rtByDev.get('Administrative').getRecordTypeId()          : null;
        Id academicRtId       = rtByDev.containsKey('Academic_Program')        ? rtByDev.get('Academic_Program').getRecordTypeId()        : null;
        Id businessRtId       = rtByDev.containsKey('Business_Organization')   ? rtByDev.get('Business_Organization').getRecordTypeId()   : null;
        Id educationRtId      = rtByDev.containsKey('Educational_Institution') ? rtByDev.get('Educational_Institution').getRecordTypeId() : null;
        Id householdRtId      = rtByDev.containsKey('HH_Account')              ? rtByDev.get('HH_Account').getRecordTypeId()              : null;
        Id sportsRtId         = rtByDev.containsKey('Sports_Organization')     ? rtByDev.get('Sports_Organization').getRecordTypeId()     : null;
        Id universityDeptRtId = rtByDev.containsKey('University_Department')   ? rtByDev.get('University_Department').getRecordTypeId()   : null;
        Id organismeRtId      = rtByDev.containsKey('Organisme')               ? rtByDev.get('Organisme').getRecordTypeId()               : null;
        Id egliseRtId         = rtByDev.containsKey('Eglise')                  ? rtByDev.get('Eglise').getRecordTypeId()                  : null;

        // ===== Constantes =====
        final Integer MAX_LEN = 20;
        final Integer SEQ_LEN = 7;

        // ===== Mapa de acentos para normalización (reutilizable) =====
        Map<String, String> accentMap = new Map<String, String>{
            'Á'=>'A','É'=>'E','Í'=>'I','Ó'=>'O','Ú'=>'U',
            'À'=>'A','È'=>'E','Ì'=>'I','Ò'=>'O','Ù'=>'U',
            'Â'=>'A','Ê'=>'E','Î'=>'I','Ô'=>'O','Û'=>'U',
            'Ä'=>'A','Ë'=>'E','Ï'=>'I','Ö'=>'O','Ü'=>'U',
            'Ñ'=>'N','Ç'=>'C','Ÿ'=>'Y','Š'=>'S','Ž'=>'Z',
            'á'=>'A','é'=>'E','í'=>'I','ó'=>'O','ú'=>'U',
            'à'=>'A','è'=>'E','ì'=>'I','ò'=>'O','ù'=>'U',
            'â'=>'A','ê'=>'E','î'=>'I','ô'=>'O','û'=>'U',
            'ä'=>'A','ë'=>'E','ï'=>'I','ö'=>'O','ü'=>'U',
            'ñ'=>'N','ç'=>'C','ÿ'=>'Y','š'=>'S','ž'=>'Z',
            'Æ'=>'AE','Œ'=>'OE','æ'=>'AE','œ'=>'OE','ß'=>'SS'
        };

        // ===== Colecciones de trabajo =====
        Set<Id> contactIds = new Set<Id>();
        Map<Id, Account> adminWithContact = new Map<Id, Account>();
        Map<Account, String> adminWithContactLongPrefix = new Map<Account, String>(); // 'I-ADM'

        List<Account> adminOrphans = new List<Account>();
        Map<Account, String> orphanToPrefix = new Map<Account, String>(); // 'I-ADM'
        Set<String> orphanNamesRaw = new Set<String>();

        List<Account> otherRtToProcess = new List<Account>();
        Map<Account, String> otherToPrefix = new Map<Account, String>();

        // Para detectar cambio de RecordType
        Map<Id, Id> oldRtByAcc = new Map<Id, Id>();
        if (Trigger.isUpdate) {
            for (Account aOld : Trigger.old) oldRtByAcc.put(aOld.Id, aOld.RecordTypeId);
        }

        // Precalcular nombre normalizado por Account (evita repetir lógica)
        Map<Id, String> normNameById = new Map<Id, String>();
        for (Account a : Trigger.new) {
            String nm = (a.Name == null) ? '' : a.Name.trim();
            String normalized = '';
            if (nm != '') {
                for (Integer i=0; i<nm.length(); i++) {
                    String ch = nm.substring(i, i+1);
                    normalized += accentMap.containsKey(ch) ? accentMap.get(ch) : ch.toUpperCase();
                }
            }
            normNameById.put(a.Id, normalized);
        }

        // ===== Recorrido principal =====
        for (Account a : Trigger.new) {
            if (String.isBlank(a.Name) || a.RecordTypeId == null) continue;

            Boolean typeChanged = Trigger.isUpdate && oldRtByAcc.containsKey(a.Id) && a.RecordTypeId != oldRtByAcc.get(a.Id);
            String nameNorm = normNameById.get(a.Id);
            if (nameNorm == null || nameNorm.length() == 0) continue;

            // ==== Administrative ====
            if (a.RecordTypeId == adminRtId) {
                Boolean mustAssign = Trigger.isInsert || typeChanged || String.isBlank(a.ID_Account__c);

                if (mustAssign && a.hed__Primary_Contact__c != null) {
                    contactIds.add(a.hed__Primary_Contact__c);
                    adminWithContact.put(a.Id, a);
                    adminWithContactLongPrefix.put(a, 'I-ADM');
                }
                else if (mustAssign && a.hed__Primary_Contact__c == null) {
                    adminOrphans.add(a);
                    orphanToPrefix.put(a, 'I-ADM');
                    orphanNamesRaw.add(a.Name);
                }
                continue;
            }

            // ==== Otros Record Types ====
            Boolean mustAssignOther = Trigger.isInsert || typeChanged || String.isBlank(a.ID_Account__c);
            if (!mustAssignOther) continue;

            if      (a.RecordTypeId == academicRtId)        { otherToPrefix.put(a, 'ACA'); otherRtToProcess.add(a); }
            else if (a.RecordTypeId == businessRtId)        { otherToPrefix.put(a, 'BUS'); otherRtToProcess.add(a); }
            else if (a.RecordTypeId == educationRtId)       { otherToPrefix.put(a, 'EDU'); otherRtToProcess.add(a); }
            else if (a.RecordTypeId == householdRtId)       { otherToPrefix.put(a, 'HOU'); otherRtToProcess.add(a); }
            else if (a.RecordTypeId == sportsRtId)          { otherToPrefix.put(a, 'SPO'); otherRtToProcess.add(a); }
            else if (a.RecordTypeId == universityDeptRtId)  { otherToPrefix.put(a, 'UNI'); otherRtToProcess.add(a); }
            else if (a.RecordTypeId == organismeRtId)       { otherToPrefix.put(a, 'ORG'); otherRtToProcess.add(a); }
            else if (a.RecordTypeId == egliseRtId)          { otherToPrefix.put(a, 'EGL'); otherRtToProcess.add(a); }
        }

        // ==== Administrative CON contacto: intentar corto y, si choca, caer a largo ====
        Map<Id, Contact> contactsById = new Map<Id, Contact>();
        if (!contactIds.isEmpty()) {
            contactsById = new Map<Id, Contact>([
                SELECT Id, ID_Contact__c FROM Contact WHERE Id IN :contactIds
            ]);
        }

        Map<Account, String> shortByAcc = new Map<Account, String>();
        Set<String> shortCandidates = new Set<String>();
        for (Id accId : adminWithContact.keySet()) {
            Account a = adminWithContact.get(accId);
            Contact c = contactsById.get(a.hed__Primary_Contact__c);
            if (c != null && !String.isBlank(c.ID_Contact__c)) {
                String s = 'I-' + c.ID_Contact__c;
                shortByAcc.put(a, s);
                shortCandidates.add(s);
            }
        }
        Set<String> takenShorts = new Set<String>();
        if (!shortCandidates.isEmpty()) {
            for (Account e : [
                SELECT Id, ID_Account__c
                FROM Account
                WHERE ID_Account__c IN :shortCandidates
            ]) {
                takenShorts.add(e.ID_Account__c);
            }
        }

        // ==== Administrative SIN contacto: evitar “gemela con contacto” ====
        Set<String> namesWithContactTwin = new Set<String>();
        if (!orphanNamesRaw.isEmpty()) {
            for (Account t : [
                SELECT Id, Name
                FROM Account
                WHERE RecordTypeId = :adminRtId
                  AND hed__Primary_Contact__c != null
                  AND Name IN :orphanNamesRaw
            ]) {
                // normalize(t.Name)
                String tn = (t.Name == null) ? '' : t.Name;
                String tnNorm = '';
                for (Integer i=0; i<tn.length(); i++) {
                    String ch = tn.substring(i, i+1);
                    tnNorm += accentMap.containsKey(ch) ? accentMap.get(ch) : ch.toUpperCase();
                }
                namesWithContactTwin.add(tnNorm);
            }
        }

        // ==== Reunir prefijos que requieren secuencia ====
        Set<String> allPrefixes = new Set<String>();
        for (Account a : adminOrphans) {
            String aNorm = normNameById.get(a.Id);
            if (!namesWithContactTwin.contains(aNorm)) {
                allPrefixes.add(orphanToPrefix.get(a)); // 'I-ADM'
            }
        }
        for (Account a : otherRtToProcess) allPrefixes.add(otherToPrefix.get(a)); // 'BUS','EGL', etc.
        for (Account a : shortByAcc.keySet()) {
            if (takenShorts.contains(shortByAcc.get(a))) {
                allPrefixes.add(adminWithContactLongPrefix.get(a)); // 'I-ADM'
            }
        }

        // ==== Calcular máximos por prefijo ====
        Map<String, Integer> maxByPrefix = new Map<String, Integer>();
        if (!allPrefixes.isEmpty()) {
            List<String> prefList = new List<String>(allPrefixes);
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
                    for (Integer j=i; j<endIdx; j++) {
                        String p = prefList[j];
                        if (full != null && full.startsWith(p) && full.length() > p.length()) {
                            // removeLeadingZeros inline
                            String digits = full.substring(p.length());
                            Integer k = 0;
                            while (k < digits.length() && digits.substring(k, k+1) == '0') k++;
                            String trimmed = (k < digits.length()) ? digits.substring(k) : '0';
                            Integer n = 0;
                            try { n = Integer.valueOf(trimmed); } catch (Exception ignore) {}
                            Integer cur = maxByPrefix.containsKey(p) ? maxByPrefix.get(p) : 0;
                            if (n > cur) maxByPrefix.put(p, n);
                            break;
                        }
                    }
                }
            }
        }

        // ==== Asignaciones finales ====
        // Admin con contacto: corto si libre; si no, largo (I-ADM + secuencia)
        for (Account a : adminWithContact.values()) {
            Contact c = contactsById.get(a.hed__Primary_Contact__c);
            if (c == null || String.isBlank(c.ID_Contact__c)) continue;

            String shortId = 'I-' + c.ID_Contact__c;
            if (!takenShorts.contains(shortId)) {
                // truncate inline
                if (shortId.length() > MAX_LEN) shortId = shortId.substring(0, MAX_LEN);
                a.ID_Account__c = shortId;
            } else {
                String p = adminWithContactLongPrefix.get(a); // 'I-ADM'
                Integer next = (maxByPrefix.containsKey(p) ? maxByPrefix.get(p) : 0) + 1;
                maxByPrefix.put(p, next);
                // leftPad inline
                String seq = String.valueOf(next);
                while (seq.length() < SEQ_LEN) seq = '0' + seq;
                String val = p + seq;
                if (val.length() > MAX_LEN) val = val.substring(0, MAX_LEN);
                a.ID_Account__c = val;
            }
        }

        // Admin huérfanas: I-ADM + 7 dígitos, salvo gemela con contacto (queda null)
        for (Account a : adminOrphans) {
            String aNorm = normNameById.get(a.Id);
            if (namesWithContactTwin.contains(aNorm)) {
                a.ID_Account__c = null;
                continue;
            }
            String p = orphanToPrefix.get(a); // 'I-ADM'
            Integer next = (maxByPrefix.containsKey(p) ? maxByPrefix.get(p) : 0) + 1;
            maxByPrefix.put(p, next);
            String seq = String.valueOf(next);
            while (seq.length() < SEQ_LEN) seq = '0' + seq;
            String val = p + seq;
            if (val.length() > MAX_LEN) val = val.substring(0, MAX_LEN);
            a.ID_Account__c = val;
        }

        // Otros RT: prefijo + 7 dígitos
        for (Account a : otherRtToProcess) {
            String p = otherToPrefix.get(a); // 'BUS','EGL','ORG', etc.
            Integer next = (maxByPrefix.containsKey(p) ? maxByPrefix.get(p) : 0) + 1;
            maxByPrefix.put(p, next);
            String seq = String.valueOf(next);
            while (seq.length() < SEQ_LEN) seq = '0' + seq;
            String val = p + seq;
            if (val.length() > MAX_LEN) val = val.substring(0, MAX_LEN);
            a.ID_Account__c = val;
        }
    }

    // ===========================
    // ======= AFTER (EXTRA para importación EDA de Contactos) =======
    // ===========================
    if (Trigger.isAfter) {
        // RecordType Administrative
        Map<String, Schema.RecordTypeInfo> byDev = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();
        Id adminRtId = byDev.containsKey('Administrative') ? byDev.get('Administrative').getRecordTypeId() : null;
        if (adminRtId == null) return;

        // Candidatos: Admin + con contacto + (ID vacío o con prefijo huérfano I-ADM...)
        List<Account> cand = new List<Account>();
        for (Account a : Trigger.new) {
            if (a.RecordTypeId == adminRtId
                && a.hed__Primary_Contact__c != null
                && (String.isBlank(a.ID_Account__c) || a.ID_Account__c.startsWith('I-ADM'))) {
                cand.add(a);
            }
        }
        if (cand.isEmpty()) return;

        // Traer ID_Contact__c de los contactos
        Set<Id> contactIds = new Set<Id>();
        for (Account a : cand) contactIds.add(a.hed__Primary_Contact__c);
        Map<Id, Contact> cById = new Map<Id, Contact>([
            SELECT Id, ID_Contact__c
            FROM Contact
            WHERE Id IN :contactIds
        ]);

        // Construir candidatos a corto y recolectar para verificar duplicados
        Map<Id, String> desired = new Map<Id, String>(); // AccId -> "I-AAAA0001"
        Set<String> shortCandidates = new Set<String>();
        for (Account a : cand) {
            Contact c = cById.get(a.hed__Primary_Contact__c);
            if (c != null && !String.isBlank(c.ID_Contact__c)) {
                String s = 'I-' + c.ID_Contact__c;
                desired.put(a.Id, s);
                shortCandidates.add(s);
            }
        }
        if (desired.isEmpty()) return;

        // Verificar si alguno ya está tomado
        Set<String> taken = new Set<String>();
        for (Account e : [
            SELECT ID_Account__c
            FROM Account
            WHERE ID_Account__c IN :shortCandidates
        ]) {
            taken.add(e.ID_Account__c);
        }

        // Actualizar solo los libres
        List<Account> toUpd = new List<Account>();
        for (Account a : cand) {
            String s = desired.get(a.Id);
            if (!String.isBlank(s) && !taken.contains(s)) {
                toUpd.add(new Account(Id = a.Id, ID_Account__c = s));
            }
        }
        if (!toUpd.isEmpty()) update toUpd;
    }
}