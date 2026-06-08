# Active Context — Última sesión: 2026-06-05

## INSTRUCCIONES PERMANENTES
- **NUNCA deploy a producción** — usuario corre `./manifest/deploy-production.sh production`
- Sandbox: deploy con `NoTestRun` está permitido (Claude puede hacerlo directo)
- **V2 = checkpoint estable** — NO tocar hasta que el fix esté confirmado en producción
- Actualizar memory-bank al inicio de cada sesión y al final de cada respuesta importante

## ⚠️ REGLA DE COBERTURA — DRY-RUN PRODUCCIÓN
- **NO confiar en "Succeeded"** — Salesforce acepta desde 75%, no implica 100%
- **SIEMPRE usar los 5 tests del deploy script** en el dry-run:
  `--tests EDAServiceCoverageTest --tests MergeCoverageBoostTest --tests MergeExecutionControllerTest --tests MergeScanServiceTest --tests MergeUtilityTest`
- **Leer el % real por clase** del JSON con python3 antes de reportar como listo
- Si alguna clase < 100%: identificar líneas, agregar tests con @TestVisible si es necesario, volver a dry-run

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

## ✅ Estado producción V3 — DEPLOYADO (2026-06-03)

### V3 = checkpoint estable
- `Merge app Salesforce v3/` — snapshot completo del estado actual
- `MergeExecutionService.cls` — versión con fix EDA phone/email dinámico + normalizeEdaKey()
- Dry-run producción: **70/70 tests, Succeeded**

### Lo que se deployó a producción (2026-06-03)
- `MergeExecutionService.cls` + `MergeController.cls` + `mergeTicketList` LWC + `MergeCoverageBoostTest.cls`
- 72/72 tests, 100% cobertura, seguridad revisada
- Deploy ID: `0AfON0000014RnR0AU`

### Pendiente (decisión del usuario)
- **EDA setting producción:** `hed__Affiliation_Record_Type_Enforced__c = false`
  - Usuario decidió no aplicarlo por ahora (producción en inglés, no afecta actualmente)
  - Necesario solo si producción cambia a francés o usuarios con locale francés hacen merges donde los 4 campos del Flow difieran

### GitHub
- Historial limpiado — 2 commits desde la limpieza
- `.gitignore` bloquea PDFs, manuales, Screenshots, `.claude/`, `DIAGNOSTIC_ACCOUNT_SCAN.apex`

## ✅ Feature: Ver ficha completa del candidato — mergeWizard Step 1 (2026-06-03)

### Archivos modificados
- `mergeWizard.html` — botón 👁 en header de cada tarjeta de candidato + modal con `lightning-record-form`
- `mergeWizard.js` — `@track showRecordModal/recordModalId/recordModalName`, getter `objectApiName`, handlers `handleViewRecord` (stopPropagation) y `closeRecordModal`
- `mergeWizard.css` — estilos `.candidate-view-btn` y `.record-view-modal__container`
- `mergeTicketList` — revertido a versión original (sin ojito en tarjetas de tickets)

### Comportamiento
- Botón 👁 aparece en el header de cada tarjeta de candidato (Step 1), junto al badge Master/Fusionné
- Click en 👁 → modal con `lightning-record-form layout-type="Full" mode="view"` del contacto/cuenta real
- Vista idéntica al formulario nativo de Salesforce, con scroll, todos los campos
- Click en backdrop o "Fermer" → cierra modal
- Click en la tarjeta (fuera del 👁) → sigue funcionando normal (selección de master)

## ✅ Feature: Quick Preview Modal en ticket list (2026-06-03)

### Archivos modificados
- `MergeController.cls` — nuevo método `getTicketPreview(ticketId)` → retorna `{ticket, candidates[], mergeLog}`
- `mergeTicketList.html` — botón 👁 en cada tarjeta + modal SLDS completo
- `mergeTicketList.js` — import `getTicketPreview`, estado `@track previewOpen/Loading/Data`, getters computed, handler `handlePreviewClick` (stopPropagation), `handlePreviewClose`
- `mergeTicketList.css` — estilos para botón preview, modal, tarjetas de candidatos, EDA counts
- `MergeExecutionControllerTest.cls` — 2 tests nuevos: `ctrl_getTicketPreview_returnsTicketCandidatesAndLog` y `ctrl_getTicketPreview_noLog_returnsNullMergeLog`

### Comportamiento
- Clic en tarjeta → sigue abriendo el wizard (comportamiento existente)
- Clic en botón 👁 (preview) → abre modal: candidatos con nombre, email, teléfono, móvil, EDA counts (rojo si activo), badge Master/Fusionné, info merge (quién, cuándo, master)
- Clic en backdrop → cierra modal
- Pendiente deploy sandbox

## ✅ SOW V3 generado (2026-06-03)
- `Merge app Salesforce v3/MERGE_MANAGER_SOW_V3.docx` — Word bilingüe (EN + FR)
- Versión 3.0, June 2026, SOW-MERGEMGR-2026-001
- Generado con python-docx desde `/tmp/generate_sow_v3.py`
- Cambios V3 documentados: fix cross-language EDA, Flow fix, nueva Sección 3.6, T-14 en criterios de aceptación
- Nota sobre `hed__Affiliation_Record_Type_Enforced__c`: en producción se mantiene `true` (org en inglés)

---

## ✅ Feature: Tooltip error en badge — HECHO (confirmado por usuario 2026-06-05)

Implementado antes de esta sesión. Badge "Error" en mergeTicketList ya muestra el `Error_Message__c` en tooltip al hacer hover.

---

## ✅ Export Excel — Cruce de datos Contact + EDA (2026-06-05)

### Script: `/tmp/sf_contact_export.py`
- Queries 5 objetos en producción via SF CLI (read-only)
- Genera Excel en `~/Desktop/sf_contacts_export_YYYYMMDD_HHMM.xlsx`
- **Hoja "Consolidado"**: 1 fila por Contact, datos de todos los objetos concatenados
- **Hojas detalle**: Contacts, CourseEnrollments, ProgramEnrollments, Affiliations, Relationships

### Datos extraídos (2026-06-05, 10:52)
| Objeto | Registros |
|---|---|
| Contact | 8,238 |
| Course Enrollments | 23,884 |
| Program Enrollments | 620 |
| Affiliations | 1,237 |
| Relationships | 1,060 |

### Columnas base Contact
`Contact_Id, FirstName, LastName, Name, AccountId, Account_Name, ID_Prodon_contact__c, Old_id__c, Email, Phone, MobilePhone, hed__AlternateEmail__c, hed__UniversityEmail__c`

### Columnas consolidadas (sufijos por objeto)
- CE_Count, CE_Cursos, CE_Statuses
- PE_Count, PE_Programas, PE_Cuentas, PE_Statuses
- Aff_Count, Aff_Cuentas, Aff_Roles, Aff_Statuses
- Rel_Count, Rel_Contacts, Rel_Types

### Notas técnicas
- `hed__Program_Enrollment__c` no tiene campo `hed__Program__r` — el programa viene de `hed__Program_Plan__r.Name`
- Múltiples valores del mismo objeto se concatenan con ` | ` como separador
- Script es reutilizable: `python3 /tmp/sf_contact_export.py` cualquier momento

---

## ✅ Feature: Snapshot view para losers fusionados (2026-06-08) — LISTO PARA PRODUCCIÓN

### Problema resuelto
Ojito en tarjetas "✗ Fusionné" del Step 1 mostraba "The requested resource does not exist" porque el Contact/Account fue eliminado por el merge.

### Solución implementada
- Para losers fusionados (`isMergedLoser = true`): llama `MergeController.getLoserSnapshot()` que lee `Merge_Log__c.Before_Snapshot_JSON__c` y retorna los campos del snapshot
- Para registros vivos (master, no-fusionados): comportamiento original (`lightning-record-form`)

### Archivos modificados
- `MergeWrappers.cls` — clases nuevas `SnapshotViewWrapper` y `SnapshotField`
- `MergeController.cls` — método nuevo `getLoserSnapshot(ticketId, loserId)` con `@AuraEnabled(cacheable=true)` + helper privado `sortSnapshotFields()`
- `mergeWizard.js` — import `getLoserSnapshotApex`, estado `@track showSnapshotModal/snapshotLoading/snapshotData`, `handleViewRecord` bifurcado, `closeSnapshotModal`, getters `snapshotModalName/Fields/CapturedAt/hasSnapshotFields`
- `mergeWizard.html` — modal snapshot con banner ámbar + grid 2 columnas (label arriba, valor abajo — estilo `lightning-record-form`)
- `mergeWizard.css` — `.snapshot-modal__body`, `.snapshot-banner`, `.snapshot-fields-grid`, `.snapshot-field`, `.snapshot-field__label/__value`

### Comportamiento visual
- Modal idéntico al ojito de cuentas vivas: mismo tamaño, mismo header con nombre
- Banner ámbar: "Données du journal de fusion — cet enregistrement a été fusionné et n'existe plus..."
- Campos en grid 2 col: estándar ordenados alfabéticamente primero, luego custom `__c` ordenados alfabéticamente
- Campos boolean: "Oui"/"Non"; relaciones: extrae `.Name` si existe; nulos y vacíos excluidos; `Id`, `IsDeleted`, `MasterRecordId` excluidos

### Tests agregados (MergeExecutionControllerTest.cls — 5 tests nuevos)
- `ctrl_getLoserSnapshot_returnsAllFieldTypes` — happy path, todos los tipos de campo
- `ctrl_getLoserSnapshot_noName_usesFirstLastName` — cubre else-branch de name
- `ctrl_getLoserSnapshot_noLog_returnsNull` — early return sin log
- `ctrl_getLoserSnapshot_loserNotInSnapshot_returnsNull` — early return loser ausente del snapshot
- `ctrl_sortSnapshotFields_swapsOutOfOrderLabels` — cubre swap en líneas 313-315 (@TestVisible)

### Estado deploy
- ✅ Deploy sandbox `partialdev` — Deploy ID: `0AfSv00000KM0SVKA1`
- ✅ Dry-run producción — **183/183 tests, 0 errores, MergeController 100%, MergeWrappers 100%, Status: Succeeded**
- ✅ LISTO PARA DEPLOY PRODUCCIÓN — usuario corre `./manifest/deploy-production.sh production`

---

## ✅ V4 DEPLOYADO A PRODUCCIÓN (2026-06-08)

### Qué se deployó
1. **Limpieza automática de tickets huérfanos** — `MergeExecutionService.cleanupOrphanedTickets()` + `MergeWrappers.cleanedUpTicketCount`
2. **Banner post-merge** — `mergeWizard` muestra mensaje verde con count de tickets eliminados
3. **2 tests nuevos** — `MergeExecutionControllerTest` (178/178 tests, 100% cobertura)

### Confirmación
- Dry-run con 5 test classes: **MergeExecutionService 100%, MergeWrappers 100%**
- Screenshot de la app funcionando guardado en conversación (2026-06-08)
- Comportamiento: merge → modal orphan → banner verde "N ticket(s) associé(s) supprimé(s) automatiquement — Les tickets référençant «Nom» qui a été fusionné ont été retirés…"

---

## ✅ Feature: Banner post-merge "tickets huérfanos suprimidos" (2026-06-05)

### Archivos modificados
- `mergeWizard.js` — `@track cleanedUpTicketCount`, `@track _cleanedLoserNames`, getters `hasCleanedUpTickets` / `cleanedUpTitle` / `cleanedUpDetail`, captura en bloque de éxito del merge
- `mergeWizard.html` — banner `<div class="cleanup-banner">` en ambos modales orphan (Account + Contact), condicionado por `hasCleanedUpTickets`
- `mergeWizard.css` — clase `.cleanup-banner` (verde con borde izquierdo) + subclases `__icon`, `__title`, `__detail`

### Comportamiento
- Aparece SOLO si `cleanedUpTicketCount > 0`
- Texto ejemplo (1 ticket): **"1 ticket associé supprimé automatiquement"** — Les tickets référençant « Jean Dupont » qui a été fusionné ont été retirés automatiquement…
- Texto ejemplo (N tickets): **"3 tickets associés supprimés automatiquement"** — …
- Se muestra en la pantalla donde el usuario gestiona las cuentas/contactos huérfanos post-merge
- Deploy sandbox: `0AfSv00000KLfRFKA1` ✅
- Dry-run producción: **49/49 tests, 0 fallos** ✅

---

## ✅ Feature: Limpieza automática de tickets huérfanos (2026-06-05)

### Qué hace
Después de un merge exitoso, busca todos los demás tickets que tengan al loser como candidato (`Merge_Candidate__c.Record_Id__c IN :losingIds`) y los elimina automáticamente (cascade delete sobre candidatos).

### Archivos modificados
- `MergeExecutionService.cls` — nuevo método privado `cleanupOrphanedTickets(currentTicketId, losingIds)` llamado en paso 11 de `executeMerge()`
- `MergeWrappers.cls` — campo `cleanedUpTicketCount` agregado a `MergeResult`
- `MergeExecutionControllerTest.cls` — 2 nuevos tests: `exec_merge_cleansUpOrphanedTickets_afterSuccessfulMerge` y `exec_merge_noOrphanedTickets_cleanupCountIsZero`

### Estado
- ✅ Deployado en sandbox (Deploy ID: `0AfSv00000KLYCtKAP`)
- ✅ Dry-run producción: **49/49 tests, 0 fallos** — listo para deploy real
- Funciona retroactivamente con tickets existentes

### Nota importante
Limpia tickets donde el **loser** aparece en otros tickets. No toca tickets donde el **master** también está (esos siguen siendo válidos). Para tickets ya huérfanos por merges anteriores al deploy: se limpiarán naturalmente cuando se procesen los tickets relacionados. Un script Anonymous Apex one-time queda como opción futura si el volumen es grande.

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
