trigger Account_GenerateID on Account (before insert, before update, after insert) {

    if ('true' == String.valueOf(Label.IDGEN_DISABLE_ACCOUNT_TRIGGER).toLowerCase()) return;

    // ===========================
    // ======= BEFORE: assign IDs =======
    // ===========================
    if (Trigger.isBefore) {

    // ===== Record Types by DeveloperName =====
    Map<String, Schema.RecordTypeInfo> rtByDev =
        Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();

    Id personRtId    = rtByDev.containsKey('PersonAccount')        ? rtByDev.get('PersonAccount').getRecordTypeId()        : null;
    Id businessRtId  = rtByDev.containsKey('Business_Account')     ? rtByDev.get('Business_Account').getRecordTypeId()     : null;
    Id householdRtId = rtByDev.containsKey('Household')            ? rtByDev.get('Household').getRecordTypeId()            : null;
    Id orgRtId       = rtByDev.containsKey('Org_Business_Account') ? rtByDev.get('Org_Business_Account').getRecordTypeId() : null;
    Id egliseRtId    = rtByDev.containsKey('Eglise')               ? rtByDev.get('Eglise').getRecordTypeId()               : null;

    // ===== Constants =====
    final Integer MAX_LEN      = 20;
    final Integer SEQ_LEN_PERS = 4;
    final Integer SEQ_LEN_ORG  = 7;
    final String  ALPHA        = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';

    // ===== Extended Unicode normalization =====
    Map<String,String> norm = new Map<String,String>{
        'Á'=>'A','À'=>'A','Â'=>'A','Ä'=>'A','Ã'=>'A','Å'=>'A','Ā'=>'A','Ă'=>'A','Ą'=>'A',
        'á'=>'A','à'=>'A','â'=>'A','ä'=>'A','ã'=>'A','å'=>'A','ā'=>'A','ă'=>'A','ą'=>'A',
        'Æ'=>'AE','æ'=>'AE','Œ'=>'OE','œ'=>'OE','ß'=>'SS',
        'Ç'=>'C','Ć'=>'C','Č'=>'C','Ĉ'=>'C','Ċ'=>'C',
        'ç'=>'C','ć'=>'C','č'=>'C','ĉ'=>'C','ċ'=>'C',
        'Đ'=>'D','Ď'=>'D','ð'=>'D','đ'=>'D','ď'=>'D','Ð'=>'D',
        'É'=>'E','È'=>'E','Ê'=>'E','Ë'=>'E','Ě'=>'E','Ē'=>'E','Ę'=>'E','Ė'=>'E','Ĕ'=>'E',
        'é'=>'E','è'=>'E','ê'=>'E','ë'=>'E','ě'=>'E','ē'=>'E','ę'=>'E','ė'=>'E','ĕ'=>'E',
        'Ğ'=>'G','ğ'=>'G','Ģ'=>'G','Ġ'=>'G','Ĝ'=>'G','ĝ'=>'G','ģ'=>'G','ġ'=>'G',
        'Ĥ'=>'H','Ħ'=>'H','ĥ'=>'H','ħ'=>'H',
        'Í'=>'I','Ì'=>'I','Î'=>'I','Ï'=>'I','Ī'=>'I','Į'=>'I','İ'=>'I','ı'=>'I',
        'í'=>'I','ì'=>'I','î'=>'I','ï'=>'I','ī'=>'I','į'=>'I',
        'Ĵ'=>'J','ĵ'=>'J',
        'Ķ'=>'K','ķ'=>'K',
        'Ł'=>'L','Ŀ'=>'L','Ĺ'=>'L','Ļ'=>'L','Ľ'=>'L',
        'ł'=>'L','ŀ'=>'L','ĺ'=>'L','ļ'=>'L','ľ'=>'L',
        'Ñ'=>'N','Ń'=>'N','Ņ'=>'N','Ň'=>'N',
        'ñ'=>'N','ń'=>'N','ņ'=>'N','ň'=>'N',
        'Ó'=>'O','Ò'=>'O','Ô'=>'O','Ö'=>'O','Õ'=>'O','Ő'=>'O','Ō'=>'O','Ø'=>'O',
        'ó'=>'O','ò'=>'O','ô'=>'O','ö'=>'O','õ'=>'O','ő'=>'O','ō'=>'O','ø'=>'O',
        'Ŕ'=>'R','Ř'=>'R','ŕ'=>'R','ř'=>'R',
        'Ś'=>'S','Ş'=>'S','Ș'=>'S','Š'=>'S','ś'=>'S','ş'=>'S','ș'=>'S','š'=>'S',
        'Ţ'=>'T','Ț'=>'T','Ť'=>'T','ţ'=>'T','ț'=>'T','ť'=>'T',
        'Þ'=>'TH','þ'=>'TH',
        'Ú'=>'U','Ù'=>'U','Û'=>'U','Ü'=>'U','Ű'=>'U','Ū'=>'U','Ų'=>'U',
        'ú'=>'U','ù'=>'U','û'=>'U','ü'=>'U','ű'=>'U','ū'=>'U','ų'=>'U',
        'Ý'=>'Y','Ÿ'=>'Y','ý'=>'Y','ÿ'=>'Y',
        'Ź'=>'Z','Ż'=>'Z','Ž'=>'Z','ź'=>'Z','ż'=>'Z','ž'=>'Z'
    };

    // ===== Detect RecordType change on update =====
    Map<Id, Id> oldRtByAcc = new Map<Id, Id>();
    if (Trigger.isUpdate) {
        for (Account aOld : Trigger.old) oldRtByAcc.put(aOld.Id, aOld.RecordTypeId);
    }

    // ===== Classify records and compute prefixes =====
    List<Account>         toProcess = new List<Account>();
    Map<Account, String>  toPrefix  = new Map<Account, String>();
    Map<Account, Integer> toSeqLen  = new Map<Account, Integer>();

    for (Account a : Trigger.new) {
        if (a.RecordTypeId == null) continue;

        Boolean typeChanged = Trigger.isUpdate
            && oldRtByAcc.containsKey(a.Id)
            && a.RecordTypeId != oldRtByAcc.get(a.Id);
        Boolean mustAssign = Trigger.isInsert || typeChanged || String.isBlank(a.ID_Account__c);
        if (!mustAssign) continue;

        if (a.RecordTypeId == personRtId) {
            // PersonAccount: I-BROA0001 (3 chars last name + 1 char first name + 4 digits)
            if (String.isBlank(a.LastName)) continue;
            String ln3 = '';
            String src = a.LastName.trim();
            for (Integer i = 0; i < src.length() && ln3.length() < 3; i++) {
                String ch = src.substring(i, i+1);
                String rep = norm.get(ch); ch = (rep == null ? ch.toUpperCase() : rep);
                for (Integer k = 0; k < ch.length() && ln3.length() < 3; k++) {
                    String ck = ch.substring(k, k+1);
                    if (ALPHA.contains(ck)) ln3 += ck;
                }
            }
            String fn1 = '';
            src = String.isBlank(a.FirstName) ? '' : a.FirstName.trim();
            for (Integer i = 0; i < src.length() && fn1.length() < 1; i++) {
                String ch = src.substring(i, i+1);
                String rep = norm.get(ch); ch = (rep == null ? ch.toUpperCase() : rep);
                for (Integer k = 0; k < ch.length() && fn1.length() < 1; k++) {
                    String ck = ch.substring(k, k+1);
                    if (ALPHA.contains(ck)) fn1 += ck;
                }
            }
            if (String.isBlank(ln3) || String.isBlank(fn1)) continue;
            toPrefix.put(a, 'I-' + ln3 + fn1);
            toSeqLen.put(a, SEQ_LEN_PERS);
            toProcess.add(a);
        }
        // DeveloperName "Business_Account" = label "Organization Business Account" → ORG
        // DeveloperName "Org_Business_Account" = label "Business Account" → BUS
        else if (a.RecordTypeId == businessRtId)  { toPrefix.put(a, 'ORG'); toSeqLen.put(a, SEQ_LEN_ORG); toProcess.add(a); }
        else if (a.RecordTypeId == householdRtId) { toPrefix.put(a, 'HOU'); toSeqLen.put(a, SEQ_LEN_ORG); toProcess.add(a); }
        else if (a.RecordTypeId == orgRtId)       { toPrefix.put(a, 'BUS'); toSeqLen.put(a, SEQ_LEN_ORG); toProcess.add(a); }
        else if (a.RecordTypeId == egliseRtId)    { toPrefix.put(a, 'EGL'); toSeqLen.put(a, SEQ_LEN_ORG); toProcess.add(a); }
    }

    if (toProcess.isEmpty()) return;

    // ===== Find max existing sequence per prefix (batched in blocks of 30) =====
    Set<String> prefixSet = new Set<String>(toPrefix.values());
    Map<String, Integer> maxByPrefix = new Map<String, Integer>();
    List<String> prefList = new List<String>(prefixSet);
    Integer block = 30;
    for (Integer i = 0; i < prefList.size(); i += block) {
        Integer endIdx = Math.min(i + block, prefList.size());
        List<String> ors = new List<String>();
        for (Integer j = i; j < endIdx; j++) {
            ors.add('ID_Account__c LIKE \'' + String.escapeSingleQuotes(prefList[j]) + '%\'');
        }
        String soql = 'SELECT ID_Account__c FROM Account WHERE ID_Account__c != null AND ('
            + String.join(ors, ' OR ') + ')';
        for (Account e : Database.query(soql)) {
            String full = e.ID_Account__c;
            for (Integer j = i; j < endIdx; j++) {
                String p = prefList[j];
                if (full != null && full.startsWith(p) && full.length() > p.length()) {
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

    // ===== Assign next sequence =====
    for (Account a : toProcess) {
        String  p      = toPrefix.get(a);
        Integer seqLen = toSeqLen.get(a);
        Integer next   = (maxByPrefix.containsKey(p) ? maxByPrefix.get(p) : 0) + 1;
        maxByPrefix.put(p, next);
        String seq = String.valueOf(next);
        while (seq.length() < seqLen) seq = '0' + seq;
        String val = p + seq;
        if (val.length() > MAX_LEN) val = val.substring(0, MAX_LEN);
        a.ID_Account__c = val;
    }

    } // end if (Trigger.isBefore)

    // ===========================
    // ======= AFTER INSERT: mirror ID_Account__c to shadow Contact =======
    // After the PersonAccount is committed, PersonContactId is available.
    // The Contact before insert cannot see ID_Account__c yet (same DML batch),
    // so we update the shadow contact here with a DML after commit.
    // ===========================
    if (Trigger.isAfter && Trigger.isInsert) {
        Map<String, Schema.RecordTypeInfo> rtByDevAfter =
            Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName();
        Id personRtIdAfter = rtByDevAfter.containsKey('PersonAccount') ? rtByDevAfter.get('PersonAccount').getRecordTypeId() : null;
        if (personRtIdAfter == null) return;

        List<Id> personAccIds = new List<Id>();
        for (Account a : Trigger.new) {
            if (a.RecordTypeId == personRtIdAfter && !String.isBlank(a.ID_Account__c)) {
                personAccIds.add(a.Id);
            }
        }
        if (personAccIds.isEmpty()) return;

        // Re-query to get PersonContactId (not in Trigger.new for before insert context)
        List<Contact> toUpdate = new List<Contact>();
        for (Account a : [
            SELECT Id, ID_Account__c, PersonContactId
            FROM Account
            WHERE Id IN :personAccIds AND PersonContactId != null
        ]) {
            toUpdate.add(new Contact(Id = a.PersonContactId, ID_Contact__c = a.ID_Account__c));
        }
        if (!toUpdate.isEmpty()) update toUpdate;
    }
}
