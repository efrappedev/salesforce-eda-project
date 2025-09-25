public without sharing class ContactPostInsertHandler {

    // ===== Test knobs (para tus pruebas en el dummy) =====
    @TestVisible static String  mappingStringOverride;
    @TestVisible static Boolean forceParseException = false;

    // ===== ASÍNCRONO: se usa en AFTER INSERT =====
    @future
    public static void syncInitialDataToAccount(Set<Id> contactIds) {
        if (contactIds == null || contactIds.isEmpty()) return;
        doSync(contactIds);
    }

    // ===== SÍNCRONO: se usa en AFTER UPDATE (AccountId null -> valor) =====
    public static void syncNow(Set<Id> contactIds) {
        if (contactIds == null || contactIds.isEmpty()) return;
        doSync(contactIds);
    }

    // ===== Núcleo común =====
    private static void doSync(Set<Id> contactIds) {
        try {
            // 1) Obtener mapeos (override para tests o CMDT para producción)
            Map<String, String> pairs = buildMappings();
            if (pairs.isEmpty()) return;

            // 2) Validar que los campos existan realmente
            Map<String, SObjectField> cFields = Schema.SObjectType.Contact.fields.getMap();
            Map<String, SObjectField> aFields = Schema.SObjectType.Account.fields.getMap();

            Map<String, String> valid = new Map<String, String>();
            for (String src : pairs.keySet()) {
                String dst = pairs.get(src);
                if (cFields.containsKey(src) && aFields.containsKey(dst)) {
                    valid.put(src, dst);
                }
            }
            if (valid.isEmpty()) return;

            // 3) Query dinámico de contactos (solo los que ya tienen AccountId)
            Set<String> srcs = new Set<String>(valid.keySet());
            String selectClause = 'Id, AccountId';
            for (String f : srcs) selectClause += ',' + f;

            String cSoql = 'SELECT ' + selectClause +
                           ' FROM Contact WHERE AccountId != null AND Id IN :contactIds';
            List<Contact> cons = Database.query(cSoql);
            if (cons.isEmpty()) return;

            // 4) Traer las Accounts con los campos destino
            Set<Id> accIds = new Set<Id>();
            for (Contact c : cons) accIds.add(c.AccountId);

            Set<String> dsts = new Set<String>(valid.values());
            String accSel = 'Id';
            for (String f : dsts) accSel += ',' + f;

            String aSoql = 'SELECT ' + accSel + ' FROM Account WHERE Id IN :accIds';
            Map<Id, SObject> accMap = new Map<Id, SObject>(Database.query(aSoql));

            // 5) Preparar updates NO DESTRUCTIVOS
            Map<Id, Account> toUpd = new Map<Id, Account>();

            for (Contact c : cons) {
                SObject acc = accMap.get(c.AccountId);
                if (acc == null) continue;

                Account aUpd = toUpd.get(c.AccountId);
                if (aUpd == null) {
                    aUpd = new Account(Id = c.AccountId);
                    toUpd.put(aUpd.Id, aUpd);
                }

                for (String src : valid.keySet()) {
                    String dst = valid.get(src);
                    Object srcVal = c.get(src);
                    Object dstVal = acc.get(dst);

                    // Tipo del campo destino en Account (para decidir regla no destructiva)
                    Schema.DisplayType dstType = aFields.get(dst).getDescribe().getType();

                    Boolean shouldWrite = false;

                    if (dstType == Schema.DisplayType.Boolean) {
                        // Checkboxes: solo promovemos false->true (nunca bajamos true->false).
                        Boolean s = (srcVal == null) ? false : (Boolean) srcVal;
                        Boolean d = (dstVal == null) ? false : (Boolean) dstVal;
                        shouldWrite = (s == true && d != true);
                    } else {
                        // Texto / Número (u otros): escribir solo si destino está vacío y la fuente trae dato.
                        Boolean dstBlank = (dstVal == null || String.valueOf(dstVal).trim() == '');
                        Boolean srcHas  = (srcVal != null && String.valueOf(srcVal).trim() != '');
                        shouldWrite = (dstBlank && srcHas);
                    }

                    if (shouldWrite) {
                        aUpd.put(dst, srcVal);
                    }
                }
            }

            // 6) Ejecutar DML solo si hay cambios reales
            List<Account> finalUpd = new List<Account>();
            for (Account a : toUpd.values()) {
                if (a.getPopulatedFieldsAsMap().size() > 1) { // Id + al menos 1 campo destino
                    finalUpd.add(a);
                }
            }
            if (!finalUpd.isEmpty()) {
                try {
                    update finalUpd;
                } catch (Exception dmlEx) {
                    // Protegemos el flujo principal (FLS/sharing/etc.). Log opcional.
                }
            }

        } catch (Exception e) {
            // Log opcional si quieres trazar configuraciones inválidas, etc.
        }
    }
    
    // Exponer solo un indicador de override para usarlo desde el trigger
        public static Boolean hasTestMappingOverride() {
        return (mappingStringOverride != null && mappingStringOverride.trim() != '');
        }

    // ===== Utilidades =====
    private static Map<String,String> buildMappings() {
        Map<String,String> out = new Map<String,String>();

        // Override de pruebas (string con "ContactField__c:AccountField__c,...")
        if (mappingStringOverride != null) {
            String s = mappingStringOverride.trim();
            if (s == '') return out;

            for (String pair : s.split(',')) {
                pair = pair.trim();
                if (pair == '') continue;
                Integer idx = pair.indexOf(':');
                if (idx <= 0 || idx == pair.length() - 1) {
                    // En tests puedes forzar un fallo de parseo si lo necesitas
                    if (forceParseException) { Integer boom = Integer.valueOf('X'); }
                    continue;
                }
                String src = pair.substring(0, idx).trim();
                String dst = pair.substring(idx + 1).trim();
                if (src != '' && dst != '') out.put(src, dst);
            }
            return out;
        }

        // Producción: CMDT Field_Sync_Mapping__mdt
        for (Field_Sync_Mapping__mdt m : [
            SELECT Source_Field_API_Name__c, Target_Field_API_Name__c
            FROM Field_Sync_Mapping__mdt
        ]) {
            if (String.isBlank(m.Source_Field_API_Name__c) || String.isBlank(m.Target_Field_API_Name__c)) continue;
            out.put(m.Source_Field_API_Name__c.trim(), m.Target_Field_API_Name__c.trim());
        }
        return out;
    }
}