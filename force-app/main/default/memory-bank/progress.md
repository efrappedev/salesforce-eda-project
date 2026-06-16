# Progress — Safe Merge Management System

## ✅ 11 tests fallando → 0 + dry-run producción re-verificado (2026-06-16)

Investigados y arreglados los 11 fallos detectados en la sesión anterior. Causa: dependían del schema real (incompleto) de `Email_Address__c` o de configs reales (`Related_Object_Config__c`) en lugar de usar el patrón `@TestVisible` ya establecido en el repo. Fix vía qualification-checks (`resolveEmailObjectName`) en lugar de existence-checks, y un nuevo flag `RelatedRecordsService.TEST_FORCE_EDA_FALLBACK_CONFIGS`.

**Sandbox: 199/199 tests, 0 fallos.** Cobertura 100% en `MergeScanService`, `MergeController`, `RelatedRecordsService`.

**Dry-run producción — CORREGIDO**: el primer intento apuntó `--source-dir` a toda la carpeta `classes/`, arrastrando Apex no relacionado del org con sus propios errores/cambios, lo cual causó `status: "Failed"` por code coverage warnings ajenas (no errores reales). El usuario corrigió: el dry-run debe ir SIEMPRE delimitado a los `--source-dir` exactos del Merge Manager (lista de `manifest/deploy-production.sh`), y la verificación que cuenta es siempre contra PRODUCCIÓN (no sandbox). Repetido con el scope correcto: `status: "Succeeded"`, 0 errores, 187/187 tests, 63/63 componentes, sin coverage warnings. Cobertura inicial: `MergeExecutionService` 99.3%, `MergeController` 98.7%, resto 100%.

**100% literal alcanzado**: se agregaron flags `@TestVisible` (`TEST_FORCE_ACCOUNT_NOT_DELETABLE`/`TEST_FORCE_CONTACT_NOT_DELETABLE` en `MergeController`, `TEST_FORCE_MERGE_PERMISSION_DENIED` en `MergeExecutionService`) + 3 tests nuevos para cubrir el branch `throw` de los checks CRUD del fix de seguridad de esta sesión. Dry-run final producción: **190/190 tests, 63/63 componentes, las 10 clases al 100% literal.** Listo para `./manifest/deploy-production.sh production`.

**Hallazgo nuevo:** `classes/` (carpeta target de producción) tiene una inconsistencia estructural pre-existente respecto a V1/V2 — usa `EDARelatedRecordsService.cls` en lugar de `RelatedRecordsService.cls`. Detectado porque rompía la compilación de `MergeCoverageBoostTest.cls` copiado de V2. Corregido. **Lección:** no asumir que `classes/` es un espejo limpio de V1/V2 al copiar archivos de test.

---

## ✅ Security Review hardening — CRUD/FLS (2026-06-16)

Auditoría de seguridad solicitada por el usuario sobre `classes/*.cls` (V2 como referencia). Hallazgos: cero hardcoded credentials, cero XSS, SOQL dinámico seguro (bind vars), pero **cero `isDeletable()` en todo el repo** y **cero `WITH SECURITY_ENFORCED`/`stripInaccessible()`**. 4/5 service classes son `without sharing` sin checks CRUD compensatorios en los deletes más sensibles.

**3 fixes aplicados** (idénticos en `classes/`, `Global V1/classes/`, `Global V2/classes/`):
1. `MergeController.deleteOrphanedAccount` — `Account.isDeletable()` check antes del delete.
2. `MergeController.deleteOrphanedContact` — `Contact.isDeletable()` check antes del delete.
3. `MergeExecutionService.executeMerge` — nuevo `validateMergePermissions()`: `isUpdateable()` + `isDeletable()` antes de `Database.merge()`.
4. `MergeTicketService.buildFieldList` — los priority fields ahora respetan `isAccessible()` (gap de FLS: antes podían exponer un campo sin permiso de lectura en el comparison matrix).

**Deploy:** sandbox V2/classes, Deploy ID `0AfSv00000KQvYcKAL`, Succeeded. Coverage post-fix: MergeController 99%, MergeExecutionService 99%, MergeTicketService 100% — sin regresión. `classes/` y `V1/` tienen el mismo fix pero aún no deployados (listos para próximo deploy producción).

**11 fallos de test preexistentes detectados** (no causados por este fix) en `MergeScanServiceTest`/`MergeCoverageBoostTest`/`RelatedRecordsServiceTest` — relacionados a auto-detección de "email object"/EDA, parecen ambientales del sandbox actual. No investigados aún.

---

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

## ✅ Fix: Badge Fusionné + ojito snapshot para Account merges (2026-06-09)

- `MergeTicketService.cls` — `missingRecordIds` ahora usa `Losing_Record_Ids__c` del log como fuente de verdad, no solo SOQL live-record check
- Dry-run producción: **MergeTicketService 243/243 (100%), 178/178 tests, Succeeded**
- Sandbox deploy ID: `0AfSv00000KMNDlKAP`

## ✅ Fix: relación EDA creada al revés (2026-06-10)

- `mergeWizard.js` — swap `contactId1/contactId2` en el call Apex: `[1]→contactId1, [0]→contactId2`
- EDA: `Type` describe el rol del **Related Contact**, no del Contact — la relación debe insertarse desde B hacia A para que A quede con el rol elegido
- Dry-run: **187/187 tests, 100% — LISTO PARA PRODUCCIÓN**

## ✅ Fix: toast "Relation créée ↔ (null)" (2026-06-10)

- Solo LWC — Apex/metadata sin cambios
- `mergeWizard.js` — captura `nameA/nameB/type` antes de `closeRelModal()`; toast: `NombreA ↔ NombreB (Tipo)`
- Intento de log `Merge_Log__c` revertido — bloqueaba `Require_Before_Snapshot` validation rule
- Deploy sandbox: Succeeded ✅
- **Dry-run producción: 187/187 tests, 100% todas las clases — LISTO PARA PRODUCCIÓN**

## ✅ Fix cobertura: MergeController línea 220 (2026-06-09)
- `TEST_EDA_NOT_AVAILABLE` flag agregado — simula EDA ausente para cubrir el `throw` de `createRelationship`
- Test nuevo: `ctrl_createRelationship_edaFlagNotAvailable_throws`
- Dry-run: **MergeController 291/291 (100%), 187/187 tests, Succeeded**

## ✅ Mejoras UI (2026-06-09) — en sandbox
- mergeTicketList: status badge coloreado en top-right (New=azul, Merged=verde, Error=rojo, Closed=negro, Ignored=gris); sin High/Med/Low
- mergeWizard: ojito junto al nombre en tarjetas; botón "Créer une relation" en footer con tooltip
- Modal relación: título sin "EDA"; flecha → en lugar de ↔

## ✅ Investigación: EDA Wife/Wife recíproco (2026-06-09)

**Algoritmo confirmado**: EDA usa `fila[Name=tipo].columna[género_original]` para el recíproco.
**Causa del error Edgar/Priscila**: Priscila (Female) eligió "Wife" (su propio tipo) en lugar de "Husband" (el tipo de su pareja). Con la config original, hay que elegir el tipo de la PAREJA.
**Resolución**: No era bug — error de uso. Config sin cambios en sandbox ni producción.

---

## ✅ Feature: La Tuerca — Configuración de objetos relacionados (2026-06-11)

### Objeto custom
- `Related_Object_Config__c` — 7 campos: Name (label), Object_API_Name__c, Parent_Field__c, Object_Type__c, Status_Field__c, Active_Status_Values__c, Sort_Order__c, Is_Active__c
- `Merge_Manager_Access` permissionset actualizado con CRUD en el objeto

### Apex
- `RelatedRecordsService.getObjectConfigs()` — lee primero de `Related_Object_Config__c` WHERE Is_Active__c=true; fallback a detección EDA si no hay registros
- `MergeController` — 5 nuevos métodos: `getRelatedObjectConfigs`, `saveRelatedObjectConfig`, `deleteRelatedObjectConfig`, `objectExists`, `getLookupFieldsForObject`

### LWC
- `mergeObjectConfig` — modal con tabla de configs + formulario add/edit:
  - Validación de API name con `objectExists()` (ícono ✓/✗)
  - Carga automática de campos lookup con `getLookupFieldsForObject()`
  - Auto-selección si solo hay 1 campo de lookup disponible
- `mergeManager.html/js` — botón ⚙ (utility:settings) agregado junto al bote de basura; abre `c-merge-object-config`

### Deploy sandbox V3 (child relationships + iconos + gear fix)
- `getDiscoverableObjects` usa `getChildRelationships()` en Contact/Account — solo muestra hijos verdaderos, filtra referencias incidentales (`isNillable()=true`)
- Gear movido a fila scan con `slds-grid_align-spread` — queda al extremo derecho
- Iconos corregidos a solo nombres SLDS válidos (fallback: `standard:custom_object`)
- Modal cierra al guardar
- Label arriba, número abajo en tarjetas del wizard
- Deploy ID: `0AfSv00000KNyuQKAT` — Succeeded ✅

### Deploy sandbox V2 (UX rediseño)
- Flujo simplificado: sistema auto-descubre objetos custom con lookup a Contact/Account
- Usuario solo ve lista con checkboxes + label editable — sin API names manuales
- `getDiscoverableObjects(parentType)` — escanea Schema, devuelve [{label, apiName, lookupField}]
- `saveObjectConfigsBatch(parentType, json)` — reemplaza todos los configs del tipo con batch
- Deploy ID: `0AfSv00000KO26nKAD` — 73/73 componentes, Succeeded ✅

---

## ✅ Feature: Multi-idioma FR/EN/ES — Global V1 (2026-06-12)

### Arquitectura
- `c/i18n` — módulo utilitario (solo .js + meta.xml, sin HTML); exporta `getLabels(lang)` y `format(template, ...args)`
- ~100+ claves por idioma (FR/EN/ES) en `LABELS` const; fallback a FR
- `format()` reemplaza placeholders `{0}`, `{1}`, etc.

### Componentes actualizados
- `mergeManager` — selector `[FR] [EN] [ES]` en header; `@track lang` + `localStorage`; propaga `lang` a todos los hijos
- `mergeTicketList` — `@api lang`, `get i18n()`, `statusOptions`/`enrichedTickets` dinámicos
- `mergeScanModal` — `@api lang`, `get i18n()`, `matchFieldOptions`/`previewTitle` dinámicos
- `mergeObjectConfig` — `@api lang`, `get i18n()`, todos los labels dinámicos
- `mergeWizard` — `@api lang`, `get i18n()`, `candidateCards`, `ticketSubtitle`, `cleanedUpMessage`, `closedReasonOptions`, `KEY_FIELD_DEF`, `MATCH_TYPE_KEY` dinámicos
- `mergeComparisonMatrix` — `@api lang`, `get i18n()`, todos los textos del HTML dinámicos

### Deploy sandbox
- Deploy ID: `0AfSv00000KOSCXKA5` — Succeeded ✅ (2026-06-12)

## ✅ Governor Limits — Correcciones aplicadas (2026-06-12)

### RelatedRecordsService.cls
- `GD_CACHE` estático + helper `gd()` — evita llamadas redundantes a `Schema.getGlobalDescribe()`
- Cap de `MAX_CONFIGS = 40` en `getBulkCounts()` — máximo 80 SOQL desde este servicio (2 por objeto)
- `isEDAAvailable()` usa `gd()` en lugar de `Schema.getGlobalDescribe()` directo

### MergeScanService.cls
- `GD_CACHE` estático + helper `gd()` — compartido entre `resolveFields()`, `isEmailAddressObjectAvailable()`, `detectByEmailObject()`, `enrichWithEmailObject()`, `resolveEmailObjectName()`
- `LIMIT 50000` añadido en `loadExistingKeys()` — previene `Too many query rows: 50001`
- `LIMIT 50000` añadido en ambas queries de `loadExistingCandidateSets()` (tickets + candidates)
- `LIMIT 50000` añadido en query dinámica de `enrichWithEmailObject()` (la única sin LIMIT)

### Deploy sandbox: Succeeded ✅

## ✅ Fix: DegreeAuditMatrixContactAction — tabla visual (2026-06-15)

4 bugs apilados resueltos en la página VF de Contact Action:
1. Selector `#studentDetailPanel` nunca matcheaba el DOM (ID de `apex:outputPanel` se cualifica) → cambiado a `#daContactVF`
2. `DegreeAuditCSS.css`: `border-collapse: separate` → `collapse` + `.opt-sub th` sin `border-top`
3. `lightningStylesheets="true"` → `false` (eliminó interferencia SLDS)
4. `.ico` en `<td>` → movido a `<span>` interno (`.ico` tiene `display:inline-block`, rompía el ancho de columna)
5. CSS `:has(+ .opt-sub)` para quitar micro rayita antes de headers grises
- **Sandbox**: ✅ validado
- **Producción**: pendiente — usuario corre deploy con `--ignore-conflicts`

## ✅ Fix: PlanCreditCalculator — Credits_Earned NULL (2026-06-15)

- 377 PEs sandbox procesados (15 con créditos, 362 en 0) ✅
- 353 PEs producción procesados (72 con créditos, 281 en 0) ✅ — corrido por el usuario
- Violette Chaperon: 0% → 5% (1.5u / 30u)

---

## ✅ Global V2 — Validación producción 100% (2026-06-15)

- **Deploy ID validación**: `0AfON0000014rUz0AI` — `sf project deploy validate`
- **10 clases, 1894 líneas, 100% real** — sin ninguna clase por debajo del 100%
- **2 bugs de test corregidos** (no existían en sandbox, solo fallan en producción por validation rules):
  - Validation rule: `Status='Merged'` requiere `Selected_Master_Id__c` → agregado en test getDashboardStats
  - Validation rule: `Status='Closed'` requiere `Closed_Reason__c` → agregado `'Already Resolved'` en test getDashboardStats
- Carpeta: `force-app/main/default/Merge Manager Salesforce Global V2/`

## ⏳ Pendiente inmediato

1. ~~**Tooltip de error en badge**~~ — HECHO
2. ~~**Limpieza automática de tickets huérfanos**~~ — DEPLOYADO producción 2026-06-08
3. ~~**Snapshot view para losers fusionados**~~ — LISTO PARA PRODUCCIÓN
4. ~~**Fix Account merge badge/ojito**~~ — LISTO PARA PRODUCCIÓN
5. ~~**Fix cobertura MergeController**~~ — LISTO PARA PRODUCCIÓN 2026-06-09
6. **Deploy producción pendiente** — 6 componentes: MergeController, MergeWrappers, MergeExecutionControllerTest, MergeTicketService, mergeWizard LWC, mergeTicketList LWC — dry-run ✅ 187/187 tests 100%
7. **Borrar tickets ya huérfanos existentes** — script Anonymous Apex one-time si el usuario lo necesita

## ✅ Merge Manager Global V1 — Refactorización EDA-agnóstica (2026-06-11)

### Bloqueante de compilación eliminado
`EDARelatedRecordsService` tenía SOQL estático contra `hed__Course_Enrollment__c`, `hed__Program_Enrollment__c`, `hed__Affiliation__c` y referencias de campo estáticas — todo bloqueaba la compilación en orgs sin EDA.

### Solución implementada
- `RelatedRecordsService.cls` (nuevo) — SOQL dinámico con `Database.query()`, runtime auto-detección vía `Schema.getGlobalDescribe().containsKey()`
- `EDARelatedRecordsService.cls` — ahora es un wrapper de delegación sin SOQL propio
- `MergeWrappers.EDACountsWrapper` → `RelatedCountsWrapper` con `List<RelatedCount>` genérica
- UI (`mergeComparisonMatrix`, `mergeWizard`) — renderiza la lista genérica con `for:each`
- `MergeExecutionService.cls` — SOQL affiliations convertido a dinámico

### Deploy sandbox ✅ `0AfSv00000KNwNyKAL`

---

## ✅ Merge Manager Salesforce Global V1 — deployado a sandbox (2026-06-11)

- Carpeta: `force-app/main/default/Merge Manager Salesforce Global V1/`
- Contiene: 15 clases, 5 LWC, 3 objetos, app + flexipage + permissionset + tab — SIN código SEMBEQ
- Feature Relationship eliminada: `createRelationship`, `getRelationshipTypes` del Apex; todo el wizard UI del LWC
- Deploy sandbox confirmado: `createRelationship = REMOVED`, `getRelationshipTypes = REMOVED` ✅
- Próximo paso: refactorizar `EDARelatedRecordsService` y todo código EDA-specific a versión genérica

## ✅ Merge Manager Salesforce Global V1 — carpeta creada (2026-06-11)

Backup limpio con SOLO los archivos de Merge Manager (sin nada SEMBEQ):
- 15 clases, 5 LWC, 3 objetos custom, app + flexipage + permissionset + tab
- Ruta: `force-app/main/default/Merge Manager Salesforce Global V1/`
- Punto de partida para refactorización EDA-agnóstica

## 🗺️ Stack futuro — Merge Manager

### Refactorización EDA-agnóstica (prioridad: PRONTO)
**Objetivo:** hacer que Merge Manager funcione en cualquier org Salesforce, con o sin EDA.
Requisito para AppExchange / venta como producto.

**Bloqueantes actuales:**
- `EDARelatedRecordsService` — queries estáticas contra `hed__Course_Enrollment__c`, `hed__Affiliation__c`, `hed__Program_Enrollment__c` → no compila sin EDA
- `MergeTicketService.KEY_COMPARISON_FIELDS` — campos `hed__` hardcodeados → ignorados si no existen (ya tiene check) ✅ parcial
- `MergeExecutionService.fixEdaPreferenceFields()` — solo corre si los campos existen, defensivo ✅
- LWC contadores Cours/Prog/Afil — mostrar solo si `isEDAAvailable = true` (getter ya existe) ✅ parcial
- `createRelationship` / `getRelationshipTypes` — ya protegidos con null check ✅

**Plan de refactorización:**
1. `EDARelatedRecordsService` → todo pasa a dynamic SOQL con `Schema.getGlobalDescribe()` check
2. `MergeTicketService` → `KEY_COMPARISON_FIELDS` filtra automáticamente campos que no existen
3. LWC wizard → contadores EDA se ocultan si `isEDAAvailable = false`
4. Tests → agregar suite para org sin EDA (mock `isEDAAvailable = false`)

### AppExchange / Managed Package (después de refactorización)
- 2GP preferido (encaja con flujo Git actual)
- Namespace prefix a definir
- Security Review de Salesforce (semanas de proceso)
- Declarar EDA como optional dependency
- Revisar `deleteAllTickets` para security review
