trigger Contact_GenerateID on Contact (before insert) {

    if ('true' == String.valueOf(Label.IDGEN_DISABLE_CONTACT_TRIGGER).toLowerCase()) return;

    // ===== Split contacts into two groups =====
    // 1. Shadow contacts of PersonAccounts → copy ID_Account__c from their Account (inverted flow)
    // 2. Regular contacts (linked to Business/Household/Org or standalone) → generate name-based ID

    final String ALPHA = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    final Integer MIN_SEQ_LEN = 4;
    final Integer OR_BLOCK    = 30;

    Map<String,String> norm = new Map<String,String>{
        'Á'=>'A','À'=>'A','Â'=>'A','Ä'=>'A','Ã'=>'A','Å'=>'A','Ā'=>'A','Ă'=>'A','Ą'=>'A',
        'á'=>'A','à'=>'A','â'=>'A','ä'=>'A','ã'=>'A','å'=>'A','ā'=>'A','ă'=>'A','ą'=>'A',
        'Æ'=>'AE','æ'=>'AE','Œ'=>'OE','œ'=>'OE','ß'=>'SS',
        'Ç'=>'C','Ć'=>'C','Č'=>'C','ç'=>'C','ć'=>'C','č'=>'C',
        'Đ'=>'D','ð'=>'D','đ'=>'D',
        'É'=>'E','È'=>'E','Ê'=>'E','Ë'=>'E','Ě'=>'E','Ē'=>'E','Ę'=>'E',
        'é'=>'E','è'=>'E','ê'=>'E','ë'=>'E','ě'=>'E','ē'=>'E','ę'=>'E',
        'Ğ'=>'G','ğ'=>'G',
        'Í'=>'I','Ì'=>'I','Î'=>'I','Ï'=>'I','Ī'=>'I','İ'=>'I','ı'=>'I',
        'í'=>'I','ì'=>'I','î'=>'I','ï'=>'I','ī'=>'I',
        'Ł'=>'L','ł'=>'L',
        'Ñ'=>'N','Ń'=>'N','ñ'=>'N','ń'=>'N',
        'Ó'=>'O','Ò'=>'O','Ô'=>'O','Ö'=>'O','Õ'=>'O','Ō'=>'O','Ø'=>'O',
        'ó'=>'O','ò'=>'O','ô'=>'O','ö'=>'O','õ'=>'O','ō'=>'O','ø'=>'O',
        'Š'=>'S','š'=>'S','Ś'=>'S','ś'=>'S','Ş'=>'S','ş'=>'S',
        'Ú'=>'U','Ù'=>'U','Û'=>'U','Ü'=>'U','Ū'=>'U',
        'ú'=>'U','ù'=>'U','û'=>'U','ü'=>'U','ū'=>'U',
        'Ý'=>'Y','Ÿ'=>'Y','ý'=>'Y','ÿ'=>'Y',
        'Ź'=>'Z','Ż'=>'Z','Ž'=>'Z','ź'=>'Z','ż'=>'Z','ž'=>'Z'
    };

    // Shadow contacts of PersonAccounts are handled by Account after insert trigger.
    // This trigger only generates name-based IDs for regular (non-PersonAccount) contacts.

    List<Contact> regularContacts = new List<Contact>();
    Map<Contact, String> contactToPrefix = new Map<Contact, String>();
    Set<String> prefixes = new Set<String>();

    for (Contact c : Trigger.new) {
        if (!String.isBlank(c.ID_Contact__c)) continue;

        // Regular contact → generate name-based ID from LastName + FirstName
        if (String.isBlank(c.LastName) || String.isBlank(c.FirstName)) continue;

        String ln3 = '';
        String src = c.LastName.trim();
        for (Integer i = 0; i < src.length() && ln3.length() < 3; i++) {
            String ch = src.substring(i, i+1);
            String rep = norm.get(ch); ch = (rep == null ? ch.toUpperCase() : rep);
            for (Integer k = 0; k < ch.length() && ln3.length() < 3; k++) {
                String ck = ch.substring(k, k+1);
                if (ALPHA.contains(ck)) ln3 += ck;
            }
        }
        String fn1 = '';
        src = c.FirstName.trim();
        for (Integer i = 0; i < src.length() && fn1.length() < 1; i++) {
            String ch = src.substring(i, i+1);
            String rep = norm.get(ch); ch = (rep == null ? ch.toUpperCase() : rep);
            for (Integer k = 0; k < ch.length() && fn1.length() < 1; k++) {
                String ck = ch.substring(k, k+1);
                if (ALPHA.contains(ck)) fn1 += ck;
            }
        }
        if (String.isBlank(ln3) || String.isBlank(fn1)) continue;

        String prefix = ln3 + fn1;
        contactToPrefix.put(c, prefix);
        prefixes.add(prefix);
        regularContacts.add(c);
    }

    if (regularContacts.isEmpty()) return;

    // Find max existing sequence per prefix in ID_Contact__c
    Map<String, Integer> foundMax = new Map<String, Integer>();
    List<String> prefList = new List<String>(prefixes);
    for (Integer i = 0; i < prefList.size(); i += OR_BLOCK) {
        Integer endIdx = Math.min(i + OR_BLOCK, prefList.size());
        List<String> ors = new List<String>();
        for (Integer j = i; j < endIdx; j++) {
            ors.add('ID_Contact__c LIKE \'' + String.escapeSingleQuotes(prefList[j]) + '%\'');
        }
        String q = 'SELECT ID_Contact__c FROM Contact WHERE ID_Contact__c != null AND (' + String.join(ors, ' OR ') + ')';
        for (Contact e : Database.query(q)) {
            String full = e.ID_Contact__c;
            if (String.isBlank(full) || full.length() < 5) continue;
            for (Integer j = i; j < endIdx; j++) {
                String p = prefList[j];
                if (full.startsWith(p)) {
                    String numStr = full.substring(4);
                    Integer k = 0;
                    while (k < numStr.length() && numStr.substring(k, k+1) == '0') k++;
                    String clean = (k < numStr.length()) ? numStr.substring(k) : '0';
                    Integer n = 0;
                    try { n = Integer.valueOf(clean); } catch (Exception ignore) {}
                    Integer cur = foundMax.containsKey(p) ? foundMax.get(p) : 0;
                    if (n > cur) foundMax.put(p, n);
                    break;
                }
            }
        }
    }

    // Assign next sequence to regular contacts
    Map<String, Integer> nextByPrefix = new Map<String, Integer>(foundMax);
    for (Contact c : regularContacts) {
        String prefix = contactToPrefix.get(c);
        if (String.isBlank(prefix)) continue;
        Integer nextNum = (nextByPrefix.containsKey(prefix) ? nextByPrefix.get(prefix) : 0) + 1;
        nextByPrefix.put(prefix, nextNum);
        String numStr = String.valueOf(nextNum);
        Integer seqLen = Math.max(MIN_SEQ_LEN, numStr.length());
        while (numStr.length() < seqLen) numStr = '0' + numStr;
        c.ID_Contact__c = prefix + numStr;
    }
}
