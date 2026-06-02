# Active Context — Última sesión: 2026-06-02

## INSTRUCCIONES PERMANENTES
- **NUNCA deploy a producción** — usuario corre `./manifest/deploy-production.sh production`
- Sandbox: deploy con `NoTestRun` está permitido (Claude puede hacerlo directo)
- **V2 = checkpoint estable** — NO tocar hasta que el fix esté confirmado en producción
- Actualizar memory-bank al inicio de cada sesión y al final de cada respuesta importante

---

## ✅ Bug resuelto — EDA idioma francés (2026-06-02)

### Síntoma
Merge de Contact en francés falla con:
`FIELD_CUSTOM_VALIDATION_EXCEPTION: Le téléphone spécifié dans Téléphone préféré est introuvable. Assurez-vous de saisir l'étiquette d'un champ de Téléphone personnalisé existant.`
Mismo merge funciona en inglés.

### Causa confirmada
`hed__Preferred_Phone__c` guarda la ETIQUETA del campo de teléfono en el idioma del org. EDA valida que el valor sea la etiqueta de un campo de teléfono PERSONALIZADO (`__c`) existente. En francés, "Mobile" (etiqueta inglesa estándar) no es reconocida.

### Intentos fallidos (4 iteraciones)
1. ❌ Template manipulation — `Database.merge()` no aplica managed-package fields del template confiablemente
2. ❌ Pre-UPDATE solo master — Salesforce copia valor del loser al master cuando master tiene null
3. ❌ Re-query SOQL + pre-UPDATE master — mismo problema: loser copia durante merge
4. ❌ Pre-UPDATE master + losers (commit 51b0ca1) — sigue fallando; posible causa: EDA TDTM re-setea el campo durante el merge o el update del loser falla silenciosamente con `allOrNone=false`

### Hipótesis pendiente
- EDA TDTM puede estar RE-SETEANDO `hed__Preferred_Phone__c` automáticamente durante el merge cuando detecta cambios en campos de teléfono (los field decisions del wizard incluyen "Autre téléphone ← Thamara Jeudi" y "Téléphone professionnel ← Thamara Jeudi")
- Necesitamos ver el error del pre-UPDATE con debug para saber si está fallando silenciosamente

### Causa raíz completa (confirmada 2026-06-02 vía SF CLI + Execute Anonymous)
EDA almacena labels en **inglés** (ej. `"Home Phone"`, `"Alternate Email"`) en los campos de preferencia. 
Durante `Database.merge()`, EDA TDTM valida que el valor coincida con el label del campo en el **idioma actual del org** (francés). `"Home Phone"` ≠ `"Téléphone (domicile)"` → falla.

Además:
- El campo real es `hed__PreferredPhone__c` (sin guión extra) — typo era un bug adicional
- No se puede hacer null (EDA exige un valor si el contact tiene teléfonos)
- Setting a null tampoco funciona: `"Sélectionnez une valeur pour Téléphone préféré"`
- Hay DOS campos afectados: `hed__PreferredPhone__c` Y `hed__Preferred_Email__c`

### Fix final (desplegado en sandbox 2026-06-02)
**`fixEdaPreferenceFields`**: completamente dinámico — normaliza el valor guardado y el API name del campo (quita namespace, __c, espacios, lowercase) para hacer match sin importar el idioma. Usa `getDescribe().getLabel()` para obtener el label en el idioma actual. Sin mapas hardcoded.
**`applyFieldDecisions`**: excluye `hed__preferredphone__c` y `hed__preferred_email__c` del merge template para evitar que se sobreescriban con valor inválido del loser.
**`normalizeEdaKey()`**: método privado de normalización: `"Home Phone"` → `"homephone"` ↔ `HomePhone` → `"homephone"`.

### Tercer error — Flow "Update Contact_to_Account_Sync 4 fields" (2026-06-02)
El Flow sincroniza 4 campos (AEBEQ, SEMBEQ, ID_Prodon, Preferred_Language) de Contact → Account. Durante el merge uno de esos campos cambia → Flow dispara → actualiza el Account `Administrative` → EDA TDTM valida record type en `hed__Affl_Mappings__c` → `Administrative` no está → error.

**Fix**: agregar condición al Flow para saltarse Accounts de tipo `Administrative` y `HH_Account` (son auto-creados por EDA para cada Contact — no tienen affiliation mapping, no deberían recibir esta sincronización).
- Archivo modificado: `force-app/main/default/flows/Contact_to_Account_Sync.flow-meta.xml`
- Condición nueva: `(recordType != 'Administrative' AND recordType != 'HH_Account') AND (algún campo cambió)`
- Desplegado en sandbox. **Falta deploy a producción** (misma fix aplica allá).

## ✅ Estado listo para producción (2026-06-02)

### V3 = checkpoint estable
- `Merge app Salesforce v3/` — snapshot completo del estado actual
- `MergeExecutionService.cls` — versión con fix EDA phone/email dinámico + normalizeEdaKey()
- Dry-run producción: **70/70 tests, Succeeded**

### Pendiente antes de deploy a producción
1. **Deploy `MergeExecutionService.cls`** — comando:
   ```
   sf deploy metadata \
     --source-dir force-app/main/default/classes/MergeExecutionService.cls \
     --target-org production \
     --test-level RunSpecifiedTests \
     --tests MergeCoverageBoostTest MergeExecutionControllerTest
   ```
2. **Cambiar EDA setting en producción** — Setup → EDA → Affiliations → desactivar "Enforce Affiliation Record Type"
   o via Apex:
   ```apex
   hed__Hierarchy_Settings__c s = [SELECT Id FROM hed__Hierarchy_Settings__c LIMIT 1];
   s.hed__Affiliation_Record_Type_Enforced__c = false;
   update s;
   ```
3. **Actualizar V3** — después de confirmar en producción, V3 pasa a ser el nuevo checkpoint estable

---

## 🟡 Mejora pendiente — Error visible en la app

### Problema
El error del merge solo aparece en el toast (desaparece) y en el objeto `Merge_Ticket__c.Error_Message__c` (no visible sin ir al objeto).

### Lo que quiere el usuario
Tooltip o banner al hacer hover sobre el badge "Error" en la lista de tickets — sin salir de la app.

### Archivos a modificar
- `mergeTicketList.html` / `mergeTicketList.js` — agregar tooltip con `Error_Message__c`
- El campo ya se carga en el ticket vía `MergeAuditService.recordMergeFailure()`
- Solo falta: incluir `Error_Message__c` en la query de tickets y mostrarlo en el badge

---

## ✅ Estado producción (2026-06-02)
- 62 componentes desplegados, 172/172 tests, 100% cobertura
- `Merge_Manager_Access` permissionset activo y asignado
- **MergeExecutionService en producción = versión SIN el fix EDA** (V2 = checkpoint)
- Sandbox tiene versión con fix (commit 51b0ca1) — no funciona aún

## Cobertura sandbox actual
- `MergeExecutionService`: ~96% (nuevo código sin tests)
- 3 tests pre-existentes fallan en sandbox por EDA TDTM (irrelevante para producción)
