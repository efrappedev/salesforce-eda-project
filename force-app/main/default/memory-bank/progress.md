# Progress — Safe Merge Management System

## ✅ Estado producción V3 (2026-06-03) — CURRENT

### Deploy producción COMPLETO — V3
| Clase | Cobertura |
|---|---|
| DataNormalizationUtil | 100% |
| EDARelatedRecordsService | 100% |
| MergeAuditService | 100% |
| MergeController | 100% (incl. getTicketPreview — nuevo en V3) |
| MergeExecutionService | 100% |
| MergeScanBatch | 100% |
| MergeScanService | 100% |
| MergeTicketService | 100% |
| MergeWrappers | 100% |
| SnapshotService | 100% |

**Tests producción:** 172/172 pasan, 0 fallos

---

## 🔧 Bug activo — EDA idioma (2026-06-02)

**Campo:** `hed__Preferred_Phone__c` / `hed__Preferred_Email__c`
**Error:** `FIELD_CUSTOM_VALIDATION_EXCEPTION` en merge de Contact cuando org está en francés
**Causa raíz completa:** 3 bugs apilados descubiertos vía SF CLI diagnóstico directo:
1. Typo en API name: `hed__Preferred_Phone__c` → `hed__PreferredPhone__c`
2. EDA valida labels en idioma actual del org — "Home Phone" ≠ "Téléphone (domicile)" en francés
3. `hed__Affiliation_Record_Type_Enforced__c = true` + org en francés → EDA lanzaba error al actualizar Account `Administrative` durante el merge (bug de comportamiento EDA según idioma)

**Fix MergeExecutionService.cls (V3):**
- `fixEdaPreferenceFields()`: remapeo dinámico via `normalizeEdaKey()` — sin hardcoding de idioma
- `applyFieldDecisions()`: excluye `hed__preferredphone__c` y `hed__preferred_email__c` del merge template
- `normalizeEdaKey()`: método nuevo que normaliza API names y picklist values para match cross-language

**Fix EDA config sandbox:** `hed__Affiliation_Record_Type_Enforced__c = false`

**Estado:** ✅ Desplegado en producción (2026-06-03) — 72/72 tests, 100% cobertura MergeExecutionService + MergeController

---

## ✅ Funciona (estable)

### Apex
- Scan Contact y Account — genera tickets correctamente
- Merge Contact — funciona en inglés ✅, francés pendiente de confirmar
- Merge Account — funciona
- `deleteAllTickets` — solo en sandbox (guard de producción activo)
- Detección de cuentas y contactos huérfanos

### LWC
- Modal de scan, matriz de comparación, wizard, ticket list
- Refresh imperativo, sin wire cache, sin race conditions
- Error ahora se escribe en `Merge_Ticket__c.Error_Message__c` para visibilidad

### Permisos
- `Merge_Manager_Access` permissionset en producción (sin campos Email_Address__c)
- Asignado a Edgar Frappe en producción

---

## ✅ Bugs corregidos (historial)

| Bug | Descripción | Estado |
|---|---|---|
| Bug 1-10 | Varios (ver sesiones anteriores) | ✅ |
| Bug 11 | Scan Account 0-ticket + FLS + sync path | ✅ |
| Bug 12 | EDA TDTM rechaza merge en francés — `hed__Preferred_Phone__c` | ⏳ en prueba |

---

## ✅ Feature: Ojito — Ver ficha completa en Step 1 del wizard (2026-06-03)

- `mergeWizard` LWC — botón 👁 en header de cada tarjeta de candidato
- Click en 👁 → modal con `lightning-record-form layout-type="Full" mode="view"`
- `MergeController.getTicketPreview()` — método Apex nuevo (+ 2 tests en MergeExecutionControllerTest)
- Dry-run en producción: 47/47 ✅ — listo para deploy con el comando del usuario
- GitHub actualizado con estos cambios (sin SOW ni documentos sensibles)

## ✅ SOW V3 generado (2026-06-03) — LOCAL ONLY

- `Merge app Salesforce v3/MERGE_MANAGER_SOW_V3.docx` — Word bilingüe (EN + FR), no va a GitHub
- Script generador: `/tmp/generate_sow_v3.py`

## ✅ Export de datos Contact + EDA a Excel (2026-06-05)

- Script: `/tmp/sf_contact_export.py` — reutilizable
- Salida: `~/Desktop/sf_contacts_export_YYYYMMDD_HHMM.xlsx`
- 1 fila por Contact con datos de 5 objetos EDA concatenados
- 8,238 contactos, 23,884 course enrollments, 620 program enrollments, 1,237 affiliations, 1,060 relationships

## ✅ Feature: Limpieza automática de tickets huérfanos + Banner (2026-06-05 → 2026-06-08)

### Apex
- `MergeExecutionService.cleanupOrphanedTickets()` — elimina tickets donde el loser aparece como candidato en otros tickets post-merge
- `MergeWrappers.MergeResult.cleanedUpTicketCount` — retorna cuántos tickets fueron eliminados
- 2 nuevos tests en `MergeExecutionControllerTest`: `exec_merge_cleansUpOrphanedTickets` y `exec_merge_noOrphanedTickets_cleanupCountIsZero`

### LWC
- `mergeWizard.js` — `@track cleanedUpMessage` (string directo, más robusto que getter booleano en LWC)
- `mergeWizard.html` — banner `<div class="cleanup-banner">` en ambos modales orphan (Account + Contact)
- `mergeWizard.css` — `.cleanup-banner` verde con borde izquierdo

### Deploy producción V4 (2026-06-08)
- **178/178 tests, 100% cobertura** (`MergeExecutionService` 100%, `MergeWrappers` 100%)
- Deploy ID via `./manifest/deploy-production.sh production`
- Confirmado funcionando en sandbox (screenshot guardado en conversación)
- **Lección aprendida:** usar los 5 test classes del script para dry-run — "Succeeded" no implica 100%

### Regla dry-run producción (nueva)
Siempre correr con:
`--tests EDAServiceCoverageTest --tests MergeCoverageBoostTest --tests MergeExecutionControllerTest --tests MergeScanServiceTest --tests MergeUtilityTest`
Luego parsear JSON con python3 para ver % real por clase.

## ✅ Feature: Snapshot view para losers fusionados — ojito en tarjeta "Fusionné" (2026-06-08)

### Apex
- `MergeWrappers.cls` — `SnapshotViewWrapper` + `SnapshotField` (wrappers nuevos para el LWC)
- `MergeController.cls` — `getLoserSnapshot(ticketId, loserId)` lee `Before_Snapshot_JSON__c` del `Merge_Log__c`, resuelve labels vía Schema.describe, ordena campos (estándar → custom, ambos alfa por label)

### LWC
- `mergeWizard.js` — `handleViewRecord` bifurcado: loser fusionado → llama `getLoserSnapshot` + abre modal snapshot; vivo → comportamiento original
- `mergeWizard.html` — nuevo modal con banner ámbar "datos del diario de fusión" + grid 2 columnas
- `mergeWizard.css` — `.snapshot-fields-grid`, `.snapshot-field`, `.snapshot-banner`

### Tests (5 nuevos en MergeExecutionControllerTest.cls)
- `ctrl_getLoserSnapshot_returnsAllFieldTypes` — todos los tipos de campo
- `ctrl_getLoserSnapshot_noName_usesFirstLastName` — else-branch name
- `ctrl_getLoserSnapshot_noLog_returnsNull` — early return sin log
- `ctrl_getLoserSnapshot_loserNotInSnapshot_returnsNull` — early return loser ausente
- `ctrl_sortSnapshotFields_swapsOutOfOrderLabels` — swap directo vía @TestVisible

### Deploy
- ✅ Sandbox `partialdev` — Deploy ID: `0AfSv00000KM0SVKA1`
- ✅ Dry-run producción — **183/183 tests, MergeController 100%, MergeWrappers 100%, Succeeded**
- ✅ LISTO PARA PRODUCCIÓN — usuario corre `./manifest/deploy-production.sh production`

## ⏳ Pendiente

1. ~~**Tooltip de error en badge**~~ — HECHO
2. ~~**Limpieza automática de tickets huérfanos**~~ — DEPLOYADO producción 2026-06-08
3. ~~**Snapshot view para losers fusionados**~~ — LISTO PARA PRODUCCIÓN 2026-06-08
4. **Borrar tickets ya huérfanos existentes** — script Anonymous Apex one-time si el usuario lo necesita
