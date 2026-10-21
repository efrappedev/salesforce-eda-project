// Scoped, on-demand counterpart to ContactIdGeneratorBatchWithCsvDyn: same
// prefix+sequence algorithm (LastName 3 letters + FirstName 1 letter,
// accent-normalized, min 4-digit sequence), but limited to a caller-supplied
// list of Contact Ids instead of every Contact org-wide, and with no
// email/CSV/ContentVersion side effects — this is a pure compute, no DML.
// Contact_GenerateID.trigger only fires on "before insert", so there is no
// update-context path that can regenerate an existing Contact's ID_Contact__c
// for us the way Account_GenerateID.trigger's before-update branch does; the
// caller is expected to write the returned values via
// BulkPasteUpdateController.startPasteUpdate().
public without sharing class RegenerateIdService {

    private static final Integer MIN_SEQ_LEN = 4;
    private static final String ALPHA = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';

    @TestVisible private static Boolean TEST_FORCE_SERVICE_EXCEPTION = false;

    private static final Map<String, String> ACCENT_MAP = new Map<String, String>{
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

    public static Map<Id, String> computeNewContactIds(Set<Id> contactIds) {
        if (TEST_FORCE_SERVICE_EXCEPTION) {
            throw new BulkEditException('Forced error for test coverage.');
        }
        Map<Id, String> newIdByContactId = new Map<Id, String>();
        if (contactIds == null || contactIds.isEmpty()) {
            return newIdByContactId;
        }

        Map<Id, String> prefixByContactId = new Map<Id, String>();
        for (Contact c : [SELECT Id, FirstName, LastName FROM Contact WHERE Id IN :contactIds]) {
            String ln3 = takeAlpha(c.LastName, 3);
            String fn1 = takeAlpha(c.FirstName, 1);
            if (String.isBlank(ln3) || String.isBlank(fn1)) {
                continue;
            }
            prefixByContactId.put(c.Id, ln3 + fn1);
        }
        if (prefixByContactId.isEmpty()) {
            return newIdByContactId;
        }

        Map<String, Integer> nextByPrefix = findMaxSequenceByPrefix(new Set<String>(prefixByContactId.values()));

        for (Id contactId : prefixByContactId.keySet()) {
            String prefix = prefixByContactId.get(contactId);
            Integer nextNum = (nextByPrefix.containsKey(prefix) ? nextByPrefix.get(prefix) : 0) + 1;
            nextByPrefix.put(prefix, nextNum);
            Integer seqLength = Math.max(MIN_SEQ_LEN, String.valueOf(nextNum).length());
            newIdByContactId.put(contactId, prefix + leftPad(String.valueOf(nextNum), seqLength));
        }
        return newIdByContactId;
    }

    // Mirrors ContactIdGeneratorBatchWithCsvDyn's "block of LIKE ORs" lookup
    // — same query shape, just against the smaller prefix set derived from
    // the caller's scoped Contact list instead of every missing-Id Contact.
    // NOTE: unlike the batch (block=30 is safe there because execute() runs
    // in 200-record chunks, well under the 200-SOQL-query batch/queueable
    // limit), this method runs synchronously from an @AuraEnabled call, where
    // the whole paste (up to BulkPasteUpdateService.MAX_SEARCH_VALUES = 5000)
    // lands in ONE transaction capped at 100 SOQL queries. block=30 would
    // need up to 167 queries for 5000 distinct prefixes and throw
    // System.LimitException: Too many SOQL queries. block=200 keeps this
    // under 25 queries even at the 5000-value cap, with each OR-list query
    // (~200 * ~35 chars) still far under the 20,000-char SOQL length limit.
    private static Map<String, Integer> findMaxSequenceByPrefix(Set<String> prefixes) {
        Map<String, Integer> foundMax = new Map<String, Integer>();
        List<String> prefList = new List<String>(prefixes);
        Integer block = 200;
        for (Integer i = 0; i < prefList.size(); i += block) {
            List<String> ors = new List<String>();
            Integer endIdx = Math.min(i + block, prefList.size());
            for (Integer j = i; j < endIdx; j++) {
                ors.add('ID_Contact__c LIKE \'' + String.escapeSingleQuotes(prefList[j]) + '%\'');
            }
            String soql = 'SELECT ID_Contact__c FROM Contact WHERE ID_Contact__c != null AND (' + String.join(ors, ' OR ') + ')';
            for (Contact e : Database.query(soql)) {
                String full = e.ID_Contact__c;
                if (full == null || full.length() < 5) {
                    continue;
                }
                for (Integer j = i; j < endIdx; j++) {
                    String p = prefList[j];
                    if (full.startsWith(p)) {
                        Integer num = 0;
                        try {
                            num = Integer.valueOf(removeLeadingZeros(full.substring(4)));
                        } catch (Exception ignore) {
                        }
                        Integer cur = foundMax.containsKey(p) ? foundMax.get(p) : 0;
                        if (num > cur) {
                            foundMax.put(p, num);
                        }
                        break;
                    }
                }
            }
        }
        return foundMax;
    }

    // Only ever called from takeAlpha() with input.trim() after a
    // String.isBlank(input) guard already returned '' for a null/blank
    // input, so input here is never null — no null-check needed.
    private static String normalize(String input) {
        String out = '';
        for (Integer i = 0; i < input.length(); i++) {
            String ch = input.substring(i, i + 1);
            out += ACCENT_MAP.containsKey(ch) ? ACCENT_MAP.get(ch) : ch.toUpperCase();
        }
        return out;
    }

    private static String takeAlpha(String input, Integer n) {
        if (String.isBlank(input)) {
            return '';
        }
        String s = normalize(input.trim());
        String out = '';
        for (Integer i = 0; i < s.length() && out.length() < n; i++) {
            String ch = s.substring(i, i + 1);
            if (ALPHA.contains(ch)) {
                out += ch;
            }
        }
        return out;
    }

    private static String leftPad(String s, Integer size) {
        while (s.length() < size) {
            s = '0' + s;
        }
        return s;
    }

    private static String removeLeadingZeros(String s) {
        Integer len = s.length();
        Integer i = 0;
        for (i = 0; i < len; i++) {
            if (s.substring(i, i + 1) != '0') {
                break;
            }
        }
        return (i < len) ? s.substring(i) : '0';
    }
}
