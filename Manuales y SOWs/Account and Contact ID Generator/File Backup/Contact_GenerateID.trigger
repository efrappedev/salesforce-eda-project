trigger Contact_GenerateID on Contact (before insert) {

    // ========================= BEFORE INSERT =========================
    if (Trigger.isBefore && Trigger.isInsert) {

        // Kill switch: ID generation disabled via custom label
        if ('true' != String.valueOf(Label.IDGEN_DISABLE_CONTACT_TRIGGER).toLowerCase()) {

            // Constants
            final Integer MIN_SEQ_LEN = 4;
            final Integer OR_BLOCK    = 30;
            final String  ALPHA       = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';

            // Extended A-Z normalization (includes ligatures and special characters)
            Map<String,String> norm = new Map<String,String>{
                // A
                'Á'=>'A','À'=>'A','Â'=>'A','Ä'=>'A','Ã'=>'A','Å'=>'A','Ā'=>'A','Ă'=>'A','Ą'=>'A',
                'á'=>'A','à'=>'A','â'=>'A','ä'=>'A','ã'=>'A','å'=>'A','ā'=>'A','ă'=>'A','ą'=>'A',
                // AE / OE / SS ligatures
                'Æ'=>'AE','æ'=>'AE','Œ'=>'OE','œ'=>'OE','ß'=>'SS',
                // C
                'Ç'=>'C','Ć'=>'C','Č'=>'C','Ĉ'=>'C','Ċ'=>'C',
                'ç'=>'C','ć'=>'C','č'=>'C','ĉ'=>'C','ċ'=>'C',
                // D
                'Đ'=>'D','Ď'=>'D','ð'=>'D','đ'=>'D','ď'=>'D','Ð'=>'D',
                // E
                'É'=>'E','È'=>'E','Ê'=>'E','Ë'=>'E','Ě'=>'E','Ē'=>'E','Ę'=>'E','Ė'=>'E','Ĕ'=>'E',
                'é'=>'E','è'=>'E','ê'=>'E','ë'=>'E','ě'=>'E','ē'=>'E','ę'=>'E','ė'=>'E','ĕ'=>'E',
                // G (includes Turkish Ğ/ğ)
                'Ğ'=>'G','ğ'=>'G','Ģ'=>'G','Ġ'=>'G','Ĝ'=>'G','ĝ'=>'G','ģ'=>'G','ġ'=>'G',
                // H
                'Ĥ'=>'H','Ħ'=>'H','ĥ'=>'H','ħ'=>'H',
                // I (includes Turkish İ/ı)
                'Í'=>'I','Ì'=>'I','Î'=>'I','Ï'=>'I','Ī'=>'I','Į'=>'I','İ'=>'I','ı'=>'I',
                'í'=>'I','ì'=>'I','î'=>'I','ï'=>'I','ī'=>'I','į'=>'I',
                // J
                'Ĵ'=>'J','ĵ'=>'J',
                // K
                'Ķ'=>'K','ķ'=>'K',
                // L
                'Ł'=>'L','Ŀ'=>'L','Ĺ'=>'L','Ļ'=>'L','Ľ'=>'L',
                'ł'=>'L','ŀ'=>'L','ĺ'=>'L','ļ'=>'L','ľ'=>'L',
                // N
                'Ñ'=>'N','Ń'=>'N','Ņ'=>'N','Ň'=>'N',
                'ñ'=>'N','ń'=>'N','ņ'=>'N','ň'=>'N',
                // O (includes Ø/ø)
                'Ó'=>'O','Ò'=>'O','Ô'=>'O','Ö'=>'O','Õ'=>'O','Ő'=>'O','Ō'=>'O','Ø'=>'O',
                'ó'=>'O','ò'=>'O','ô'=>'O','ö'=>'O','õ'=>'O','ő'=>'O','ō'=>'O','ø'=>'O',
                // R
                'Ŕ'=>'R','Ř'=>'R','ŕ'=>'R','ř'=>'R',
                // S (includes Ş/Ș/Š)
                'Ś'=>'S','Ş'=>'S','Ș'=>'S','Š'=>'S',
                'ś'=>'S','ş'=>'S','ș'=>'S','š'=>'S',
                // T (includes Ț/ţ/ț)
                'Ţ'=>'T','Ț'=>'T','Ť'=>'T','ţ'=>'T','ț'=>'T','ť'=>'T',
                // TH Icelandic
                'Þ'=>'TH','þ'=>'TH',
                // U
                'Ú'=>'U','Ù'=>'U','Û'=>'U','Ü'=>'U','Ű'=>'U','Ū'=>'U','Ų'=>'U',
                'ú'=>'U','ù'=>'U','û'=>'U','ü'=>'U','ű'=>'U','ū'=>'U','ų'=>'U',
                // Y
                'Ý'=>'Y','Ÿ'=>'Y','ý'=>'Y','ÿ'=>'Y',
                // Z
                'Ź'=>'Z','Ż'=>'Z','Ž'=>'Z','ź'=>'Z','ż'=>'Z','ž'=>'Z'
            };

            // Collect prefixes for this batch
            Map<Contact,String> contactToPrefix = new Map<Contact,String>();
            Set<String> prefixes = new Set<String>();

            for (Contact c : Trigger.new) {
                if (!String.isBlank(c.ID_Contact__c)) continue;
                if (String.isBlank(c.LastName) || String.isBlank(c.FirstName)) continue;

                // Last name -> 3 letters A-Z
                String ln3 = '';
                String src = c.LastName == null ? '' : c.LastName.trim();
                for (Integer i=0; i<src.length() && ln3.length()<3; i++) {
                    String ch = src.substring(i,i+1);
                    String rep = norm.get(ch); ch = (rep==null ? ch.toUpperCase() : rep);
                    for (Integer k=0; k<ch.length() && ln3.length()<3; k++) {
                        String ck = ch.substring(k,k+1);
                        if (ALPHA.contains(ck)) ln3 += ck;
                    }
                }

                // First name -> 1 letter A-Z
                String fn1 = '';
                src = c.FirstName == null ? '' : c.FirstName.trim();
                for (Integer i=0; i<src.length() && fn1.length()<1; i++) {
                    String ch = src.substring(i,i+1);
                    String rep = norm.get(ch); ch = (rep==null ? ch.toUpperCase() : rep);
                    for (Integer k=0; k<ch.length() && fn1.length()<1; k++) {
                        String ck = ch.substring(k,k+1);
                        if (ALPHA.contains(ck)) fn1 += ck;
                    }
                }

                if (String.isBlank(ln3) || String.isBlank(fn1)) continue;
                String prefix = ln3 + fn1; // 4 pure A-Z letters
                contactToPrefix.put(c, prefix);
                prefixes.add(prefix);
            }
            if (!prefixes.isEmpty()) {
                // Find max sequence per prefix (batched OR blocks of 30)
                Map<String,Integer> foundMax = new Map<String,Integer>();
                List<String> prefList = new List<String>(prefixes);

                for (Integer i=0; i<prefList.size(); i += OR_BLOCK) {
                    Integer endIdx = Math.min(i+OR_BLOCK, prefList.size());
                    List<String> ors = new List<String>();
                    for (Integer j=i; j<endIdx; j++) {
                        ors.add('ID_Contact__c LIKE \'' + String.escapeSingleQuotes(prefList[j]) + '%\'');
                    }
                    String q = 'SELECT ID_Contact__c FROM Contact ' +
                               'WHERE ID_Contact__c != null AND (' + String.join(ors,' OR ') + ')';

                    for (Contact e : Database.query(q)) {
                        String full = e.ID_Contact__c;
                        if (String.isBlank(full) || full.length() < 5) continue;
                        for (Integer j=i; j<endIdx; j++) {
                            String p = prefList[j];
                            if (full.startsWith(p)) {
                                String numStr = (full.length() > 4) ? full.substring(4) : '';
                                // strip leading zeros
                                Integer nlen = numStr.length(), idx = 0;
                                while (idx < nlen && numStr.substring(idx,idx+1) == '0') idx++;
                                String clean = (idx < nlen) ? numStr.substring(idx) : '0';
                                Integer num = 0;
                                try { num = Integer.valueOf(clean); } catch (Exception ignore) {}
                                Integer cur = foundMax.containsKey(p) ? foundMax.get(p) : 0;
                                if (num > cur) foundMax.put(p, num);
                                break;
                            }
                        }
                    }
                }

                // Assign new sequences in memory
                Map<String,Integer> nextByPrefix = new Map<String,Integer>(foundMax);
                for (Contact c : Trigger.new) {
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
        }
    }


}