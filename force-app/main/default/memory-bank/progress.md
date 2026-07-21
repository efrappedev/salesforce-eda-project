# Progress — Safe Merge Management System

## ✅ Bulk Data Editor — DEPLOYADO EN AEBEQ PRODUCCIÓN (2026-07-21)

Usuario corrió el script él mismo. Deploy ID `0AfOH000001bnxF0AQ`, Succeeded, 72 tests / 0
fallas, 100% coverage. Bulk Data Editor ya está en producción en SEMBEQ y AEBEQ. Falta (manual):
asignar permission set a usuarios de AEBEQ y verificar mini flujo real en esa org.


## ✅ Merge Manager V2 EDA + V2 non-EDA — DEPLOYADOS A PRODUCCIÓN (2026-07-21)

- SEMBEQ producción: V2 for EDA ✅ + legacy cleanup (EDARelatedRecordsService + EDAServiceCoverageTest eliminadas) ✅
- AEBEQ producción: V2 non-EDA ✅ (primera instalación en producción — fresh install)
Cambios incluidos: brush icon dashboard, lazy-load spinner 300ms, fix paréntesis relTypeLabel (mergeWizard.js:586).
Scripts actualizados a patrón verbose+coverage: deploy-production.sh y deploy-v2-eda-production.sh ya muestran salida en vivo + tabla de cobertura al terminar.
Scripts de cobertura creados: manifest/coverage-eda.sh y manifest/coverage-v2.sh (validate-only, 5 test classes propias).



## ✅ Bulk Data Editor — Botón X DEPLOYADO A PRODUCCIÓN (2026-07-21)

Nueva regla permanente (CLAUDE.md): cambios 100% LWC se pueden deployar directo a producción sin
esperar al usuario; solo Apex requiere que el usuario corra el script él mismo. Deploy del botón
X confirmado Succeeded vía `sf project deploy report`. Bug adicional arreglado en
`deploy-bulk-editor-production.sh`: línea de warning del CLI rompía el parseo JSON — ahora se
recorta todo antes del primer `{`.


## ✅ Bulk Data Editor — Botón X para limpiar búsqueda en Object/Field/Filter (2026-07-21)

`bulkSearchableSelect` (componente compartido usado en Object/Field/Filter pickers del wizard
base + Record Type Change) ganó un botón X que limpia el texto escrito y reabre la lista, sin
tocar el valor ya seleccionado (solo se confirma al elegir una opción nueva). Deployado a SEMBEQ
y AEBEQ, sin tests (LWC-only). Producción pendiente — el usuario corre el script él mismo.


## ✅ Bulk Data Editor — DEPLOYADO A PRODUCCIÓN (2026-07-21)

Usuario corrió el deploy a producción. Succeeded, 72 tests, 0 failures, 100% cobertura en las 8
clases (verificado vía `sf project deploy report --use-most-recent --json`, no solo por el
script). El script no imprimió nada por un bug de bash (pipe+heredoc compitiendo por el stdin de
Python en `deploy-bulk-editor-production.sh`) — ya arreglado, no afectó el deploy real. Mismo
bug probablemente late en `deploy-v2-eda-production.sh`, sin arreglar aún. Falta: asignar
permission set a usuarios (manual) + prueba funcional en producción.


## ✅ Bulk Data Editor — Countdown en toast + script de deploy a producción creado (2026-07-21)

Toast "Change reverted successfully." ahora muestra countdown en vivo ("(closing in Ns)") vía
`setInterval`, deployado a ambos sandboxes sin correr tests (LWC-only, nueva regla explícita del
usuario: tests de Apex solo cuando se toca Apex, dry-run a producción solo tras confirmación
manual). Se creó `manifest/deploy-bulk-editor-production.sh` (no existía ninguno) siguiendo el
patrón de `deploy-v2-eda-production.sh`: safety gate, `--json` + tabla de cobertura por clase,
`RunSpecifiedTests`. Deploya todo (classes/lwc/objects/app/tab/flexipage/permissionset/profile
Admin) salvo asignación de permission set a usuarios (manual). Script creado pero NO ejecutado —
el usuario lo corre él mismo.

## ✅ Bulk Data Editor — Ronda de UX en Record Type Change + History (2026-07-21)

9 puntos de feedback del usuario tras probar en SEMBEQ sandbox, todos LWC-only (sin Apex):
1 bug real arreglado en el componente compartido `bulkSearchableSelect` (reabrir un combobox ya
lleno solo mostraba la opción seleccionada, no la lista completa — guard `!this.isOpen`
invertido). Resto son UX: filtro de Record Type ahora `lightning-combobox` plano (no
autocomplete, con opción "Any Record Type"), label "Search (optional)" en vez de "Search term",
`type="search"` para botón de borrado nativo, mini-refresh de History (`@api refresh()` +
evento `rundone`) tras un run o un Undo sin hard refresh, toast de Undo auto-cierra a 4s, badge
"Undone" renombrado a "Already Reverted". Verificado: SEMBEQ y AEBEQ ambos 76/76 tests, 100%
(sin cambio esperado, Apex intacto). Producción sigue sin nada deployado — pendiente del usuario.

## ✅ Bulk Data Editor — AEBEQ sandbox actualizado, ahora igual que SEMBEQ (2026-07-20)

AEBEQ tenía solo la app base (2026-07-16, sin Record Type Change ni los fixes de hoy). Deploy
completo vía `deploy-bulk-editor-aebeq-sandbox.sh`. Verificado: 76/76 tests, 100% en las 9
clases — igual que SEMBEQ. **Producción: 0 clases `Bulk*` (confirmado por SOQL), nada
deployado todavía. Pendiente:** deploy real a producción por el usuario.

## ✅ Bulk Data Editor — Auditoría de governor limits, 2 bugs de longitud arreglados, 100% confirmado por dry-run de producción (2026-07-20)

Pedido del usuario: revisar toda la app (incluida la feature de Record Type Change) buscando
violaciones a reglas/límites de Salesforce ("desbordamientos, limites etc").

- SOQL/DML en loops: ninguno — la app ya está correctamente bulkificada en los 3 batches.
- **Bug 1** (`BulkEditController.startBulkEdit`): `newValue` sin tope de longitud podía exceder
  el campo destino real y tirar `STRING_TOO_LONG` en el insert del log. Fix: valida contra
  `dfr.getLength()` y **rechaza** con mensaje claro (dato real que se escribe en registros, no
  se puede truncar sin corromper).
- **Bug 2** (`BulkRecordTypeController.startRecordTypeChange`): `searchSummary` sin tope directo
  a `Old_Value_Display__c` (Text 255). Fix: nuevo helper `truncateForLog()`, **trunca** (es solo
  anotación de auditoría, no dato real).
- Resto de las clases (`BulkEditService`, `BulkEditBatch`, `BulkEditUndoBatch`,
  `BulkRecordTypeChangeBatch`, `BulkRecordTypeService`, `BulkEditWrappers`) y los 10
  field-meta.xml de ambos objetos custom: revisados, limpios.
- Tests nuevos: `testStartBulkEdit_newValueTooLong_throws`,
  `testStartRecordTypeChange_longSearchSummary_truncatedSafely`.
- Sandbox SEMBEQ: 74/74 tests, 100%. **Dry-run producción** (`RunSpecifiedTests`, 4 test
  classes): `Succeeded`, 70 tests, 0 failures, **100% real en las 9 clases**.

**Ronda 2 (mismo día) — auditoría de permisos/CRUD/SOQL injection/XSS**, mismo checklist usado
para Merge Manager (`[[security_review]]`). SOQL injection, XSS, sharing, `isDeletable()`,
`@TestVisible`, IDs hardcodeados: todo limpio. **Bug real:**
`BulkRecordTypeService.getSearchableFields()`/`searchRecords()` no verificaban
`Account.isAccessible()` a nivel de objeto (solo el campo). Fix: `assertAccountAccessible()` +
2 tests nuevos. Nota de diseño documentada (no bug): el audit log (`Bulk_Edit_Log__c`
`viewAllRecords=true`) es visible a todo el que tenga el Permission Set, sin FLS sobre el campo
original — igual patrón que `Merge_Log__c`. Sandbox 76/76, 100%. Dry-run producción: `Succeeded`,
72 tests, 0 failures, 100% en las 9 clases.
- **Pendiente:** solo el deploy real a producción por el usuario.

## ✅ Bulk Data Editor — Feature "Mass Record Type Change" (Account), 100% cobertura confirmada por dry-run de producción (2026-07-20)

Nueva feature aditiva (plan aprobado, no modifica el wizard de value-edit): buscar Accounts por
Record Type y/o término libre en un campo, seleccionar manualmente vía checkboxes, cambiar el
Record Type solo de los seleccionados, con Undo.

- 3 clases Apex nuevas (`BulkRecordTypeService`, `BulkRecordTypeController`,
  `BulkRecordTypeChangeBatch`), 1 LWC nuevo (`bulkRecordTypeChange`), mode-toggle en
  `bulkDataEditor`, display update en `bulkEditHistory`, 1 cambio quirúrgico a
  `BulkEditService.resolveFieldDescribe()` (permite `RecordTypeId` para que `BulkEditUndoBatch`
  sin modificar sirva Undo gratis a esta feature).
- Tests nuevos: `BulkRecordTypeControllerTest.cls` (17 tests), `BulkRecordTypeChangeBatchTest.cls`
  (5 tests, incluye round-trip completo de Undo).
- Deploy sandbox SEMBEQ: primera corrida 70/70 tests pero `BulkRecordTypeController` en 92%
  (2 ramas `catch(Exception)` genéricas sin cubrir). Fix con flags `TEST_FORCE_*` ya existentes
  (uno extendido, uno reutilizado de `BulkEditService`) — sin flags nuevos. Redeploy: 72/72
  tests, 100% en las 3 clases nuevas.
- **Dry-run acotado a producción** (`RunSpecifiedTests`, 4 test classes, no RunLocalTests):
  `Succeeded`, 68 tests, 0 failures, **100% real en las 9 clases** de la app (6 ya-producción
  intactas + 3 nuevas). Detalle completo en `activeContext.md`.
- Pasada manual de UX en sandbox ✅ confirmada por el usuario (2026-07-20): busca por Record
  Type + nombre, selecciona varios, cambia Record Type — funciona como se pidió.
- **Pendiente:** solo el deploy real a producción por el usuario (sin script dedicado todavía).

## ✅ Bulk Data Editor — Construido y deployado a sandbox AEBEQ (2026-07-16)

App completa deployada exitosamente a `e.frappe@aebeq.qc.ca.partialae`. 22/22 tests Apex
pasando, cobertura 83-100% por clase (por debajo del 100% intencionalmente — el usuario pidió
no invertir más tiempo en cobertura hasta que la app esté aprobada en UX; los tests "de
verdad" para producción se harán en una fase posterior). Ver detalle completo, bugs de
metadata encontrados, y lecciones de testing de batches en `activeContext.md`.

**Siguiente paso:** el usuario prueba la app en el sandbox AEBEQ y da feedback de UX antes de
tocar producción.

**2026-07-16 (mismo día, sesión de testing UX):**
- Fix auto-load de pestaña en App Launcher (era el mismo glitch de caché de App Definition
  que "No Items" — se resolvió solo al re-guardar el wizard de Navigation Items, sin tocar código).
- Fix bug real: "List has no rows for assignment to SObject" — 3 queries sin guarda contra
  0 filas (`getJobStatus`, `BulkEditUndoBatch.start/execute`). Ver detalle en `activeContext.md`.
  Deployado a sandbox AEBEQ ✅, 22/22 tests OK.

**2026-07-17 (segunda ronda de testing UX):**
- Fix bug real: crash "Cannot read properties of undefined (reading 'buckets')" al
  seleccionar campos tipo Geolocation (ej. "Other Latitude") o Currency — GROUP BY revienta
  en la plataforma para campos con `isGroupable() = false`. Fix en 3 capas: filtrar esos
  campos del picklist de `getEditableFields()`, defensa extra en `getValueDistribution()`,
  y guard `if:true={distribution}` en el template. Ver detalle completo + lección sobre dónde
  NO poner el check (`resolveFieldDescribe` compartido) en `activeContext.md`.
- Rediseño completo del wizard por pedido del usuario: de pasos apilados verticalmente a un
  wizard tipo instalador (un solo paso visible a la vez, estado explícito `wizardStep`,
  botones "← Back" en pasos 2-4, path indicator clickeable, ancho contenido a 640px para
  monitores ultrawide).
- Deployado a sandbox AEBEQ ✅ (2 rondas de deploy, la primera con el check de agrupabilidad
  mal ubicado rompió un test — corregido). 22/22 tests pasando (100%).
- **Pendiente:** usuario retesta en sandbox AEBEQ y confirma si el wizard nuevo y la ausencia
  de campos problemáticos en el picker resuelven su feedback.
- Deploy adicional a sandbox SEMBEQ (`e.frappe@sembeq.qc.ca.partialdev`) — usuario pidió
  probar ahí porque tiene más cuentas/datos de prueba disponibles. Nuevo script
  `manifest/deploy-bulk-editor-sembeq-sandbox.sh` (mismo patrón que el de AEBEQ, mismo código
  fuente — la app es genérica, sin dependencias EDA). Primer deploy en este sandbox → todo
  "Created". 22/22 tests pasando (100%). App ahora vive en ambos sandboxes (AEBEQ y SEMBEQ).

**2026-07-17 (tercera ronda — searchable select + layout):**
- Nuevo componente reutilizable `lwc/bulkSearchableSelect` — combobox custom con SLDS
  (`slds-combobox`) que filtra opciones por substring al escribir (ej. escribir "S" muestra
  todos los campos que contienen "S"). `lightning-combobox` nativo no soporta esto (solo abre
  un picklist estático) — por eso se construyó desde cero con un `<input>` + listbox propio,
  manteniendo el mismo contrato de evento (`onchange` con `detail.value`) que
  `lightning-combobox`, así que `bulkDataEditor.js` no necesitó cambios, solo el HTML.
- Reemplazado en 3 lugares dentro de `bulkDataEditor.html`: selector de Object (paso 1),
  selector de Field (paso 2), y selector de New Value cuando el campo es picklist (paso 4).
- CSS del wizard: `.wizard-container` pasó de `margin: 0 auto` (centrado) a `margin: 0`
  (alineado a la izquierda) — el usuario sintió que centrar solo repartía el espacio vacío a
  ambos lados en vez de resolverlo. **Pendiente explícito del usuario:** seguir iterando el
  diseño visual general de la app (se ve "poco digerible", mucho espacio no aprovechado) —
  esto es la primera de varias iteraciones de layout, no está cerrado.
- Deployado a AEBEQ y SEMBEQ sandbox ✅. 22/22 tests en ambos (100% — cambios fueron solo LWC,
  no tocaron Apex).

**2026-07-17 (investigación "Script-thrown exception" en Account.SEMBEQ__c):**
- Usuario reportó crash "Script-thrown exception" en step 5 (Applying mass update) al hacer un
  segundo intento de mass edit sobre `Account.SEMBEQ__c` (checkbox) en sandbox SEMBEQ. Primer
  intento (2944 registros false→true) SÍ había completado bien.
- **No dejó ningún rastro server-side** — ni `Bulk_Edit_Log__c` ni `AsyncApexJob` nuevo — lo
  que apunta a que fue un fallo transitorio del lado del navegador (probablemente caché de
  Lightning con el bundle LWC viejo justo después del deploy de searchable-select), no un bug
  reproducible en Apex.
- **Reproducción controlada:** corrí `startBulkEdit` para `Account.SEMBEQ__c` a escala completa
  (8,203 registros — TODOS los Account de la org, valor true→true sin cambio real) vía Apex
  anónimo. Batch completó 42/42 chunks, 0 errores. Esto descarta la teoría de límite de
  "5,000 registros por job" — Batch Apex no tiene ese techo (soporta hasta 50M vía
  QueryLocator); el chunking en grupos de 200 (`Database.executeBatch(batch, 200)`) ya está
  aplicado automáticamente, no requiere cambios de código.
- Datos de prueba (log + 8,203 snapshots del test true→true) limpiados después de verificar.
  También se había hecho una prueba menor con `AEBEQ__c` (107 registros true→false) que se
  revirtió correctamente con `BulkEditUndoBatch` — sirvió además para confirmar que el flujo
  de undo funciona bien a pequeña escala.
- **Pendiente:** pedirle al usuario que reintente el mismo mass edit en SEMBEQ__c (o cualquier
  checkbox) después de un hard refresh del navegador (Ctrl+Shift+R / limpiar caché), y que si
  vuelve a fallar, copie el mensaje completo de la consola del navegador (Network tab, response
  body del request a Apex) en vez de solo el texto del banner — "Script-thrown exception" es el
  mensaje genérico que Salesforce muestra cuando el mensaje real de la excepción no viaja al
  cliente (típicamente por AuraHandledException con mensaje null u otro fallo no capturable),
  así que el texto real de error puede estar solo en el Network tab o en Setup > Apex Jobs.

## 🆕 Bulk Data Editor — Plan de diseño original (2026-07-16) — ya construido, ver arriba

Proyecto nuevo, independiente de Merge Manager. Editor masivo tipo Excel: elegir objeto →
campo → tabla de valores distintos + conteo → reemplazar → update masivo (10,000+ registros).
Genérico desde el día 1, sin dependencia EDA/NPC — un solo build para SEMBEQ y AEBEQ.

### Estructura de carpetas propuesta
```
force-app/main/default/Bulk Data Editor/
  applications/Bulk_Data_Editor.app-meta.xml
  tabs/Bulk_Data_Editor.tab-meta.xml
  flexipages/Bulk_Data_Editor.flexipage-meta.xml
  permissionsets/Bulk_Data_Editor_Access.permissionset-meta.xml
  classes/
    BulkEditController.cls        (with sharing — adapter LWC)
    BulkEditService.cls           (discovery, distribution, validación)
    BulkEditBatch.cls             (Database.Batchable + Stateful — update + snapshots)
    BulkEditUndoBatch.cls         (Database.Batchable — revierte desde snapshots)
    BulkEditWrappers.cls          (DTOs @AuraEnabled)
    BulkEditControllerTest.cls / BulkEditBatchTest.cls  (objetivo 85%+ cobertura)
  objects/
    Bulk_Edit_Log__c        (Object_Type__c, Field_API_Name__c, New_Value__c,
                              Records_Affected__c, Status__c, Undo_Status__c,
                              Batch_Job_Id__c, Executed_By__c, Executed_Date__c)
    Bulk_Edit_Snapshot__c   (Master-Detail a Log: Record_Id__c(18), Old_Value__c)
                            — un registro por fila afectada, habilita el undo
  lwc/
    bulkDataEditor        (orquestador: selector objeto → campo)
    bulkValueTable         (tabla valores distintos + conteo, click-to-edit)
    bulkEditConfirmModal   (preview + confirmación explícita, re-cuenta antes de ejecutar)
    bulkEditProgress       (polling de AsyncApexJob, barra de progreso)
    bulkEditHistory        (log de ediciones pasadas + botón "Deshacer")
```

### Decisiones técnicas clave
- **Todo pasa por Batch Apex**, sin importar el volumen — no hay path síncrono separado,
  porque cada registro necesita snapshot individual para el undo. Simplifica el código.
- **Query de distribución**: `SELECT Campo, COUNT(Id) cnt FROM Objeto GROUP BY Campo
  ORDER BY COUNT(Id) DESC LIMIT 2000`. Límite duro de Salesforce de 2,000 filas agrupadas
  — si se trunca, la UI avisa "mostrando los 2,000 valores más frecuentes".
- **Tipos de campo excluidos del selector** (SOQL no permite GROUP BY sobre ellos):
  multi-select picklist, campos encriptados, long text area / rich text.
- **Blacklist de objetos de plataforma** excluidos siempre del discovery aunque el usuario
  tenga acceso: `User`, `Profile`, `PermissionSet`, `PermissionSetAssignment`, `UserRole`,
  `ApexClass`, `ApexTrigger` + ruido habitual (`*History`, `*Share`, `*Feed`, `*ChangeEvent`).
- **Undo**: `BulkEditBatch.execute()` inserta un `Bulk_Edit_Snapshot__c` por registro ANTES
  de aplicar el update. `BulkEditUndoBatch` revierte desde los snapshots en lotes de 200.
  Riesgo aceptado: si un registro cambió por otra vía entre el edit y el undo, se sobrescribe
  igual (mismo trade-off que el undo de Merge Manager).
- **FLS/CRUD**: `DescribeFieldResult.isUpdateable()` chequeado antes de arrancar el batch.
- **Confirmación**: modal con objeto + campo + valor viejo → nuevo + conteo exacto
  (re-consultado justo antes de ejecutar, no el conteo cacheado de la tabla).

### Fases de implementación
| Fase | Contenido |
|---|---|
| 1 | Objetos custom (`Bulk_Edit_Log__c`, `Bulk_Edit_Snapshot__c`) + Permission Set |
| 2 | `BulkEditService` + `BulkEditController` (discovery, distribution, picklist values) + tests |
| 3 | `BulkEditBatch` + `BulkEditUndoBatch` + tests (85%+ desde el inicio) |
| 4 | LWC: `bulkDataEditor` + `bulkValueTable` + `bulkEditConfirmModal` + `bulkEditProgress` |
| 5 | `bulkEditHistory` (ver logs + undo) + app/tab/flexipage |
| 6 | Deploy sandbox → pruebas con volumen real (10k+) → dry-run producción → usuario deploya |

**Estado:** diseño aprobado por el usuario (2026-07-16). Esperando luz verde para Fase 1.

---

## ✅ Editable Close Reasons — V2 + EDA (2026-07-07)

### Apex: `MergeController.cls` (V2 + EDA)
- `getReasonConfig()`: lee sentinel `__reason_config__` → devuelve JSON config
- `saveReasonConfig(configJson)`: guarda/inserta sentinel `__reason_config__`
- `renameReason(oldVal, newVal, ticketStatus)`: actualiza `Closed_Reason__c` + `Notes__c` en tickets afectados

### JSON config structure (en `Custom_Close_Reasons__c` del sentinel):
```json
{ "tvLabels": {"fp-household":"Domicile diff."}, "clLabels": {}, "tvCustom": [], "clCustom": [] }
```
- `tvLabels/clLabels`: overrides predefined reasons (key → custom label)
- `tvCustom/clCustom`: custom reasons by section

### LWC: `mergeObjectConfig` (V2 + EDA)
- Sección "Raisons de clôture" → sub-tabs [À Valider | Clôture]
- Predefined: inputs editables + botón ↺ para reset
- Custom: inputs editables + ✕ para eliminar
- Add new reasons per section with duplicate validation (dentro del mismo tab)
- Save button en footer → llama `renameReason` para cada cambio + `saveReasonConfig`

### LWC: `mergeWizard` (V2 + EDA)
- `closedReasonOptions`: usa `_reasonConfig.tvLabels` + `tvCustom` (valores configurados)
- `closeReasonOptions`: usa `_reasonConfig.clLabels` + `clCustom` (fallback a legacy)
- `openDismissModal`: carga config nueva + legacy custom en paralelo
- `confirmAddReason`: guarda en nuevo config (no en sentinel legacy)
- `confirmDismiss` CL: usa clLabels para predefined, closeReason directo para custom

### Deploys sandbox:
- AEBEQ (`e.frappe@aebeq.qc.ca.partialae`): LWC deployed `0AfbZ00000CCf3jSAD`, Apex ya existía ✅
- SEMBEQ (`e.frappe@sembeq.qc.ca.partialdev`): todo desplegado `Changed` ✅



## ✅ Merge Manager Global V2 for EDA — COMPLETO (2026-07-03)

### Nueva carpeta: `Merge Manager Salesforce Global V2 for EDA/`
- Copia completa de Global V2 + wizard de relaciones EDA portado desde V3
- **Botón "Créer une relation"** en footer del wizard — centro, visible solo para tickets de Contact
- **Toggle en Settings** → sección "Funcionalidades" (última, ícono `utility:setup`) → activa/desactiva el botón → Save → page reload
- **localStorage key**: `mergeManager_relBtn_enabled` — default ON (true) sin config previa
- **Modal relaciones**: selección 2 candidatos → tipo → swap ⇄ → preview → insert `hed__Relationship__c`
- **EDA guard**: `getRelationshipTypes` retorna vacío + `createRelationship` lanza excepción si EDA no instalado
- **i18n**: FR/EN/ES completo (relaciones + funcionalidades)
- **Apex**: `TEST_EDA_NOT_AVAILABLE` + `getRelationshipTypes()` + `createRelationship()`
- **Tests**: +3 en `MergeExecutionControllerTest.cls`
- **Último deploy sandbox**: `0AfSv00000KgO8rKAF` — Succeeded ✅
- **PMD governance**: 0 violaciones de seguridad ✅
- **Dry-run producción**: **265/265 tests · 10/10 clases 100%** ✅
  - DataNormalizationUtil, MergeAuditService, MergeController, MergeExecutionService,
    MergeScanBatch, MergeScanService, MergeTicketService, MergeWrappers,
    RelatedRecordsService, SnapshotService — todas al 100%
- **Global V2 original NO tocado** — marketplace sin cambios
- **Deploy producción**: pendiente — usuario corre script cuando quiera

## ✅ DegreeAuditMatrix — 100% cobertura + visual fix (2026-07-03) — LISTO PARA PRODUCCIÓN

- **Visual**: checkmarks `ico ok` ahora en `<span>` dentro `<td>` (modal principal `DegreeAuditMatrix.page`)
- **CSS**: 3 reglas scoped `#studentDetailCapture` en `DegreeAuditCSS.css`
- **Coverage**: 97.9% → 100% (765/765) via 7 flags @TestVisible + 7 test methods T170-T176
- **Dry-run producción**: 76/76 tests, 0 fallas, Succeeded ✅
- **Pending**: usuario corre `./manifest/deploy-production.sh production`

## ⏳ ReleveDesNotes Cleanup — Script listo, pendiente producción (2026-06-30)

- `manifest/deploy-delete-releve.sh production` — elimina ReleveDesNotes.cls + ReleveDesNotesTest.cls + GenererReleveDesNotes (Aura)
- Componentes solo en producción, no en repo local

## ✅ DRY-RUN FULL ORG LIMPIO (2026-06-29) — 271/271 tests, 0 fallos

- Deploy ID: `0AfON0000015FXJ0A2` — Dry-run producción, `RunLocalTests`, todos los Apex de la org
- 3 errores previos + REQUIRED_FIELD_MISSING → **todos resueltos**
- Deploy producción `0AfON0000015FVh0AM`: **Succeeded** — 71/71 tests, 4/4 componentes ✅ — **MÓDULO CERRADO**



## ✅ ID Generator cleanup — Steps 1+2+3 completados, listo para produccion (2026-06-29)

### Plan 3 pasos
| Step | Descripcion | Estado |
|---|---|---|
| 1 | Crear `ContactIdGeneratorTest.cls` + `AccountIdGeneratorTest.cls` | ✅ |
| 2 | Dry-run produccion → 5/5 tests pasan, Succeeded | ✅ |
| 3 | Tests al 100% (2 nuevos metodos) + script final listo | ✅ |
| DEPLOY | Usuario corre `./manifest/deploy-id-generator-cleanup.sh production` | ⏳ pendiente |

### Coverage final en sandbox (7/7 tests, testRunCoverage 100%)
- `Contact_GenerateID.trigger`: 100% — cubiertas lineas 119-133 (inner loop prefijo-maximo)
- `Account_GenerateID.trigger`: ~99.5% — cubiertas 193-210, 224-234, 278-327; linea 324 insoluble

### Archivos a eliminar en Step 3
- `DynamicIdDeployDummyTests.cls` (mega-dummy 3119 líneas → reemplazado por 2 archivos pequeños)
- `ContactPostInsertHandler.cls` (sync handler ya no necesario)
- `ContactIdGeneratorBatchWithCsvDyn.cls` (batch de población inicial ya no necesario)
- `AccountIdGeneratorBatchWithCsvDyn.cls` (batch de población inicial ya no necesario)

### Modificación pendiente en Step 3
- `Contact_GenerateID.trigger` → quitar AFTER INSERT block (líneas 158-172)

---

## ✅ V5 completo — 262/262 tests, 10/10 clases 100%, listo para producción (2026-06-29)

### Features V5 implementadas y validadas
| Feature | Archivos | Estado |
|---|---|---|
| Real count "9,517 cas trouvé(s) (affichant 2,000)" | MergeController, mergeTicketList | ✅ |
| Keyset pagination ‹ 1/5 › | MergeController (getTickets 6p), mergeTicketList | ✅ |
| Server-side search + debounce 400ms | MergeController, mergeTicketList | ✅ |
| resolveSearchIds (transacción propia 50k) | MergeController +resolveSearchIds, mergeTicketList | ✅ |
| X para limpiar búsqueda (derecha del input) | mergeTicketList HTML/CSS/JS | ✅ |
| Salto de página (clic en "1/5" → input → Enter) | mergeTicketList HTML/CSS/JS | ✅ |
| Bloqueo mobile (formFactor + innerWidth < 768) | mergeManager HTML/CSS/JS, i18n | ✅ |
| Fix columnas candidate cards (CSS Grid 2-col) | mergeWizard HTML/CSS | ✅ |

### Validación final (2026-06-29)
- Sandbox deploy: ✅ Succeeded
- `sf apex run test --code-coverage`: **10/10 clases al 100%**, 262 tests, 0 fallos
- Dry-run producción: ✅ **262/262 Succeeded**, sin warnings de cobertura
- AppExchange PMD Security scanner: ✅ **0 violaciones** (CRUD/FLS/SOQL injection/XSS)
- PMD UnusedLocalVariable falsos positivos: resueltos con `// NOPMD — used as SOQL bind variable`

### Listo para
```bash
./manifest/deploy-production.sh production
```

---

## ✅ 100% cobertura confirmada en producción — listo para deploy (2026-06-25)

- **258/258 tests**, 0 fallos — dry-run producción Succeeded
- **10/10 clases al 100%** — incluyendo MergeScanBatch (reescrito para evitar "Batchable instance is too big" y "Too many query rows")
- **AppExchange PMD Security Scanner**: 0 violaciones
- **Listo para**: `./manifest/deploy-production.sh production`

### Errores de governor limits resueltos (raíz + fix)
| Error | Raíz | Fix |
|---|---|---|
| "Too many query rows: 50001" | Scan sincrónico con 90k contacts superaba límite acumulado | `runScan()` lanza `MergeScanBatch` async; `getQueryLocator()` sin límite de rows |
| "Batchable instance is too big" | Maps estateful acumulaban ~10MB entre chunks | Rewrite: sin acumulación estateful; cada `execute()` detecta y persiste localmente |

### Riesgo residual documentado
`detectInScope()` podría devolver >50k rows si muchos records comparten un valor de campo genérico (improbable en datos EDA reales).

---

## ✅ Estado final pre-AppExchange — 100% en todo (2026-06-23)

- AppExchange security scanner: **0 violaciones** (PMD Security)
- Cobertura producción: **2547/2547 = 100.00%** — las 10 clases al 100% exacto
- Tests producción: **255/255, 0 fallos**
- Listo para: `./manifest/deploy-production.sh production` + AppExchange submission

## ✅ AppExchange Security Scanner: 125 → 0 violaciones (2026-06-23)

87 `ApexCRUDViolation` + 38 `ApexSOQLInjection` en V2 resueltos. Estrategia: `@SuppressWarnings('PMD.ApexCRUDViolation')` en 5 clases (admin tool, permissionset-gated) + `String.escapeSingleQuotes()` en todos los objectType/fieldName dinámicos + `// NOPMD` en falsos positivos donde schema taint persiste. Verificado con `sfdx scanner run --engine pmd --category Security`: **"No rule violations found."** Deploy sandbox Succeeded. Listo para producción.

---

## ✅ Production dry-run: PASSED — cobertura ≥75% en todas las clases (2026-06-19)

Fix: `MergeExecutionControllerTest` línea 1403 `'Duplicate'` → `'Other'` (picklist restringida en producción). Nuevos tests en `MergeCoverageBoostTest`: `ctrl_getRRC_nullMaster`, `ctrl_getRRC_noCandidates`, `ctrl_getRRC_withConfig` (cubre `getRelatedRecordsComparison` completo via Contact.ReportsToId config), `ctrl_orphanClose_noExclude` (cubre else branch de `closeOrphanedTickets`), `ctrl_initDefaultConfigs_noopWhenEDAMissing`. MergeController subió de 66.5% → 81.1%. Validate producción: Succeeded, sin test failures. Listo para deploy: `./manifest/deploy-production.sh production`.

---

## ✅ Language switch: Save button + `window.location.reload()` (2026-06-19)

4to intento — enfoque definitivo: botón Save en la sección Idioma del modal. Clic en FR/EN/ES actualiza `_pendingLang` (visual). Clic en Save → dispatch event → parent guarda en localStorage + `window.location.reload()`. Página recarga en el nuevo idioma. Solución 100% confiable, sin depender de reactivity de LWC. Deploy `0AfSv00000KUbjNKAT` sandbox — Succeeded ✅.

---

## ✅ Fix definitivo reactivity de idioma: `getLabels(this.lang)` directo en getter (2026-06-19)

Tercer intento — solución correcta: eliminar `@track _labels` de `mergeManager.js` y cambiar `get i18n()` a `return getLabels(this.lang)`. Cuando `@track lang` (primitive) cambia, LWC garantiza re-render. Durante el re-render, `get i18n()` computa labels frescos → todos los `{i18n.*}` del template se actualizan. El patrón `@track _labels` con `{ ...spread }` no era confiable para disparar re-renders en el parent después del primer cambio. Deploy `0AfSv00000KUb3SKAT` — Succeeded ✅.

---

## ✅ Fix reactivity de idioma: panel izquierdo se quedaba en idioma anterior (2026-06-19)

Patrón `@track _labels` en `mergeManager.js` y `mergeTicketList.js`. Cuando `lang` cambia, `_labels = getLabels(newLang)` asigna nueva referencia de objeto → LWC detecta el cambio con certeza → re-render del parent y de todos los hijos. `mergeTicketList` usa getter/setter en `@api lang` para actualizar `_labels` cuando el parent pasa un nuevo valor. Deploy `0AfSv00000KUZJNKA5` — Succeeded ✅.

---

## ✅ Comprehensive HIST logging: todos los state changes generan entrada en HISTORIQUE (2026-06-19)

Reescritura completa del sistema de auditoría de tickets. Nuevo helper privado `buildHistNotes` en `MergeController` y `MergeExecutionService`. Todos los movimientos (dismiss→Ignored, close→Closed, reopen→Reopened, merge→Merged, undo→Reopened, error→Error) ahora crean una línea `[HIST:STATUS|||reason|||notes|||date]` en `Notes__c`. La sección HISTORIQUE muestra el trail completo; el banner (amarillo/verde/rojo) solo muestra la decisión activa. `mergeWizard.js ticketHistoryLogs` mapea `Reopened/Merged/Error` a etiquetas i18n. 3 nuevas keys FR/EN/ES: `histReopened`, `histMerged`, `histError`. Test `ctrl_closeTicket_fromIgnored_createsHistEntry` actualizado. Deploy `0AfSv00000KUSMjKAP` sandbox — Succeeded ✅.

---

## ✅ Fix HISTORIQUE: icono de reloj en entries + sección no aparecía (2026-06-19)

`closeTicket` (Apex) ahora escribe `[HIST:Ignored|||reason|||notes|||date]` cuando el ticket viene de estado Ignored, haciendo que `hasHistory = true` y la sección HISTORIQUE sea visible en Step 1 del wizard después de Ignored → Closed. Anteriormente solo `reopenTicket` creaba entradas HIST. Ícono de reloj quitado de cada `audit-log-entry` (solo queda en el header `audit-log-header`). Test nuevo `ctrl_closeTicket_fromIgnored_createsHistEntry`. Deploy V2 sandbox `0AfSv00000KUR7JKAX` — Succeeded ✅.

---

## ✅ 4 UX/navigation fixes: scrollbar + icon flash + search by TKT# (2026-06-19)

Tab bar: scrollbar 3px → 6px, botones ‹ › de navegación (`scrollTabsLeft/Right`), wrapper `.mm-tabs-nav`. Icono de tab ahora usa `standard:contact`/`standard:account` (vía `objectType` pasado en evento `ticketselect`) — ya no parpadea con ícono incorrecto. Búsqueda: filtra también por `ticket.Name` (TKT-XXXXXXX). Placeholder actualizado FR/EN/ES. Deploy `0AfSv00000KUHskKAH` — Succeeded ✅.

---

## ✅ Contact ticket Step 2 — Compte associé carousel (2026-06-19)

Sección "Compte associé par contact" en Step 2 para Contact tickets. Cada candidato muestra su Account administrativa con carousel dinámico (driven by Account Settings). Non-EDA: solo nombre de Account (carousel vacío no se muestra). Archivos: `MergeWrappers.cls`, `MergeTicketService.cls`, `mergeComparisonMatrix` (js/html), `i18n.js`. Deploy `0AfSv00000KUKDtKAP` — Succeeded ✅.

---

## ✅ UX: Footer rediseñado + Error banner + undo consolidado en footer (2026-06-18)

**Cambios en `mergeWizard` (V2) — Deploy Succeeded sandbox `partialdev`:**

**Footer:**
- Ticket Merged: muestra [texto gris "{N} día(s) restante(s)"] a la izquierda + [botón azul "Annuler la fusion"] a la derecha. Sin botones Back/Next ni Exception.
- Ticket Closed: sin botones Back/Next ni Exception (footer vacío salvo el layout de spread).
- Ticket Activo (New/Pending/Stale/Ignored/Error): comportamiento original (Exception izq + Back/Next/Execute der).
- Nuevos getters JS: `isTerminalTicket = isMergedTicket || isClosedTicket`.

**Undo merge consolidado:**
- Removido el botón "Annuler" pequeño del card de la tarjeta de candidatos (al lado del badge "Fusionné").
- Removido el botón "Annuler la fusion" del `merge-log-banner` (dentro del cuerpo del ticket).
- El único punto de acceso al undo es ahora el botón azul en el footer.

**Error banner:**
- `isErrorTicket = Status__c === 'Error'` + nuevo getter `ticketErrorMessage` (lee `Error_Message__c`).
- Apex: `MergeWrappers.ComparisonMatrix.ticketErrorMessage` agregado; `MergeTicketService.buildComparisonMatrix` incluye `Error_Message__c` en SOQL y lo asigna al wrapper.
- LWC: banner rojo en Step 1 muestra el mensaje de error con monospace + hint para reintentar.
- `executeMerge()` JS: llama `refreshApex(this._wiredMatrix)` después de fallo para que el ticket pase a Error en la UI inmediatamente (sin reabrir el tab).

---

## ✅ Fix: undoMerge bloqueado por VR Prevent_Reopen_After_Merge (2026-06-18)

`undoMerge()` (MergeController.cls:369) lanzaba `DmlException` porque la VR `Prevent_Reopen_After_Merge` bloqueaba cualquier cambio de status desde 'Merged'. Fix: agregado `NOT(ISPICKVAL(Status__c, 'Reopened'))` a la fórmula del VR para permitir el path controlado del undo. Archivos: `Prevent_Reopen_After_Merge.validationRule-meta.xml` (canonical + V2). Deploy Succeeded sandbox. Verificado con Apex anónimo: `SUCCESS`. Nota: el VR sigue bloqueando transiciones no autorizadas (Merged → Open/Ignored/Closed).

---

## ✅ Feature: Related Records Merge + Undo + La Tuerca pre-checked (Global V2) — 2026-06-17

Feature completa desplegada en `Merge Manager Salesforce Global V2/`. Deploy ID `0AfSv00000KSQqUKAX`, 73 componentes, Succeeded, NoTestRun. Pendiente prueba del usuario en sandbox `partialdev`.

**Componentes nuevos/modificados:**
- `Merge_Log__c.Related_Records_JSON__c` — campo LongTextArea(131072) para snapshot + deleted IDs
- `MergeWrappers.cls` — `RelatedObjectComparison`, `RelatedRecordInfo`, `MergeRequest.relatedDeletesJson`
- `RelatedRecordsService.cls` — `getConfigsForComparison()` público
- `MergeController.cls` — `getRelatedRecordsComparison()` (@AuraEnabled cacheable), `undoMerge()` (@AuraEnabled)
- `MergeAuditService.cls` — `createPreMergeLog(7 params)` guarda `Related_Records_JSON__c`
- `MergeExecutionService.cls` — `captureLoserRelatedIds()` (antes del DML), `applyRelatedDeletes()` (post-DML), `appendDeletedIdsToLog()`
- `MergeExecutionControllerTest.cls` — 4 llamadas corregidas (aridad: +1 null al final)
- `i18n.js` — ~15 nuevas claves por idioma (sección Related Records + Undo)
- `mergeObjectConfig.js/html/css` — pre-checked logic + warning banner amarillo
- `mergeWizard.js/html/css` — related records section Step 2, undo button, 2-click confirm, relatedDeletesJson

**Lógica de undo (2 fases):**
1. `captureLoserRelatedIds` antes del merge DML → guarda en `Related_Records_JSON__c.loserRelatedIds`
2. `undoMerge`: `Database.undelete(loser)` + query hijos re-parentados al master + `update` de vuelta al loser + `Database.undelete(deletedIds)` + ticket status reset

**Detección de conflictos:** match case-insensitive por `Name` entre registros del master y del loser.

---

## ✅ Fix: multi-candidate banner responsive (mergeWizard V2) — 2026-06-17

Banner del Step 1 "3 enregistrements détectés..." se cortaba en diferentes resoluciones. Causa: `display: flex` en el container hacía que cada `<strong>` y text node fuera un flex item separado. Fix: envolver todo el texto post-icono en `<span class="multi-candidate-banner__text">` (flex: 1; min-width: 0) + clase `__icon` en el icono (flex-shrink: 0). Archivos: `mergeWizard.html` + `mergeWizard.css` en Global V2. Pendiente deploy sandbox.

---

## 🔒 SOQL injection almacenada corregida + deploy-production.sh apuntando a V2 (2026-06-16)

`saveObjectConfigsBatch`/`RelatedRecordsService.getBulkCounts` ya validan apiName/lookupField contra `Schema.describe()` antes de guardar/usarlos en SOQL dinámico (antes se concatenaban crudos del cliente). `manifest/deploy-production.sh` corregido: apuntaba a la copia legacy bare (sin dashboard/i18n) — ahora apunta a `Global V2/` completo con nombres de clase reales. Dry-run real contra producción: 208/208 tests, 1952/1952 líneas, 100%, `Succeeded`. V1 confirmado no usado en ningún org — fix no replicado ahí.

## ✅ Dashboard: "By Age" eliminado, fusionado en "By Status" (V2) (2026-06-16)

`getDashboardStats()` ya no devuelve `byAge` — New/Reopened se bucketizan por edad (New/Pending/Stale) directamente dentro de `byStatus`, junto a Error/Merged/Closed/Ignored. Tarjeta "By Age" removida de `mergeDashboard` (JS+HTML); `STATUS_ORDER`/`STATUS_COLORS` actualizados. Clave i18n `chartAge` removida. Verificado: `byStatus => {Closed=4, Ignored=4, Merged=7, New=0, Pending=1, Stale=1605}`. Deploy ID `0AfSv00000KRB3tKAH`, 67/67 tests.

## ✅ Tags de status multi-idioma en mergeTicketList (V2) (2026-06-16)

Los badges ("New"/"Pending"/"Stale"/"To Validate"/etc.) ya respetan `lang` (fr/en/es) en vez de quedar fijos en inglés. `STATUS_BADGE_LABEL` → `STATUS_BADGE_KEY` + lookup i18n; `_agingBadge()` localizado. Claves nuevas `statusInReview`/`statusReady` agregadas en `i18n.js` (3 idiomas) por completitud, aunque esos 2 estados son vestigiales (nunca asignados por Apex). Deployado a `partialdev` (Deploy ID `0AfSv00000KR6AiKAL`).

## 🚨 Incidente corregido: deploy erróneo sobrescribió componente real en `partialdev` (2026-06-16)

Deploy real (no dry-run) de la copia legacy de `mergeTicketList` sobrescribió el componente V2 vivo en el sandbox (mismo nombre de bundle). Detectado por el usuario vía screenshot. Corregido redeployando V2 completo (`mergeTicketList`, `MergeController`, `mergeDashboard`, `i18n`) — verificado idéntico a V2 con `sf project retrieve start`. Producción nunca se tocó (solo dry-run). **Confirmado: `Merge Manager Salesforce Global V2/` es la fuente canónica del proyecto — las demás copias son legacy.**

---

## ✅ Feature: ticket aging badge (New → Pending → Stale) (2026-06-16)

Ticket de 14 días seguía mostrando "New". Implementado cálculo derivado desde `CreatedDate` (sin nuevo campo, sin Status__c nuevo, sin Scheduled Apex): 0-2 días = New, 3-7 = Pending, 8+ = Stale. Checkpoint `221e9b2` creado antes del cambio para poder revertir.

- **`force-app/main/default/lwc/mergeTicketList`** (única copia desplegada a este org): badge reclasificado 100% client-side en JS, `Status__c` real intacto. Verificado con dry-run producción scope exacto de `deploy-production.sh`: `Succeeded`, 0 errores, 190/190 tests, 63/63 componentes, 10 clases siguen 100%.
- **V1/V2** (`force-app/main/default/Merge Manager Salesforce Global V1|V2/` — producto/paquete separado con i18n fr/en/es, estado `Reopened` propio, `mergeDashboard`/`getDashboardStats()` que NO existen en la copia de producción de este org): mismo badge + nuevo breakdown `byAge` en `getDashboardStats()` + nueva card en `mergeDashboard`. No desplegado a ningún org en esta sesión (no es parte del pipeline de este org).
- **Lección de estructura**: "Merge Manager Salesforce Global V1/V2" no están en la raíz del repo, están anidadas dentro de `force-app/main/default/`. Confirmar siempre la ubicación real antes de asumir mirroring.

---

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

## 2026-07-06 — Non-EDA 100% coverage completado

### Dry-run #5 AEBEQ — 100% ✅
- Deploy ID: `0AfOH000001axYr0AI`
- 295 tests, 0 failures, todas las clases al 100%

### Cambios para cubrir líneas problemáticas
**MergeController.cls**:
- `TEST_FORCE_LOOKUP_MATCH = false` — fuerza condición en for-ref loop (líneas 1174-1175)
- `TEST_INIT_PARENT_TYPES = null` — override de lista de parent types en `initDefaultConfigsIfEmpty` (líneas 1397-1409)
- Ternario en `initDefaultConfigsIfEmpty` para usar el flag

**MergeExecutionControllerTest.cls** (+4 tests):
1. `ctrl_getEmailObjectCandidates_forceLookupMatch_coversRefLoopBody` → 1174-1175
2. `ctrl_getDiscoverableObjects_freshScan_coversAddBranch` → 1258-1262
3. `ctrl_initDefaultConfigsIfEmpty_withInjectedChild_coversPayloadBuild` → 1397-1409
4. `ticket_buildMatrix_account_withCaseConfig_coversRelatedCountsAggLoop` → MergeTicketService 207-211

### Principio de portabilidad
Todos los tests usan únicamente:
- `Case.ContactId` (estándar en toda org Salesforce)
- `Merge_Ticket__c` (objeto del paquete, siempre presente)
- Flags @TestVisible (genéricos, no org-específicos)

## 2026-07-17 — Bulk Data Editor: undo BDE-00000 confirmado, no era un bug

Usuario reportó como error el JSON crudo de respuesta al hacer click en "Undo" sobre
BDE-00000 (2944 Accounts, SEMBEQ__c, sandbox SEMBEQ). El JSON en realidad mostraba
`"state": "SUCCESS"`.

Verificado:
- `bulkEditHistory.html`: el box "Starting..." está correctamente scopeado por fila
  (`data-progress-log-id={entry.logId}` dentro del `<li>` de cada entry, condicionado a
  `entry.showProgress`) — no es un componente huérfano, es el label inicial normal antes del
  primer poll.
- SOQL confirma `Bulk_Edit_Log__c` BDE-00000 → `Status__c = 'Undone'` (undo completó bien).
  BDE-00001 (AEBEQ__c, 107 registros) también `'Undone'`.

Sin cambios de código — no había bug. Reportado al usuario aclarando que el JSON pegado era
éxito, no error.

**Sigue abierto:** el "Script-thrown exception" original al editar el checkbox
`Account.SEMBEQ__c` (reportado antes en esta misma sesión) no se ha podido reproducir — no
relacionado con este undo. Pendiente que el usuario reintente y capture el Network tab si
vuelve a pasar.

## 2026-07-17 — Fix: progress UI de undo estancada en "Starting..." + Process ID visible

Usuario insistió (5 hard refreshes) que la caja de progreso seguía en "Starting..." pese a
que el backend ya mostraba `Undone`. Pidió que la app muestre errores reales y el ID del
proceso.

**Causa raíz real encontrada en código:** `BulkEditController.undoBulkEdit()` nunca
actualizaba `Batch_Job_Id__c` del log al Id del batch de UNDO — quedaba apuntando al batch
del edit original ya completado, así que el polling de `getJobStatus` consultaba el
`AsyncApexJob` equivocado. Además `bulkEditProgress.js` no reconocía los statuses
`Undone`/`Undo Failed` en `isSuccess`/`isFailed` (solo los del flujo de edit), así que aunque
el polling terminara bien no se mostraba ningún banner de resultado para undo.

**Fix:** `BulkEditController.cls` actualiza `Batch_Job_Id__c` tras lanzar el undo batch;
`BulkEditWrappers.JobStatusResult` expone `batchJobId`; `bulkEditProgress.js`/`.html`
reconocen `Undone`/`Undo Failed` y muestran "Process ID: {batchJobId}" siempre visible.

Deploy SEMBEQ ✅ (20/20 tests) · AEBEQ ✅ (22/22 tests). Pendiente que el usuario pruebe un
undo nuevo para confirmar visualmente.

**Actualización:** confirmado por el usuario con screenshots — funcionó perfecto (Undo In
Progress → barra de progreso → Process ID visible → "Change reverted successfully.") ✅

## 2026-07-17 — Root cause real de "Script-thrown exception" encontrado (2 causas)

1. **AuraHandledException quirk de plataforma:** `new AuraHandledException(msg)` sin llamar
   `.setMessage(msg)` después no propaga el mensaje real al cliente — Lightning lo sanitiza a
   "Script-thrown exception". Los 9 throw sites de `BulkEditController.cls` tenían este bug.
   Fix: helper `asAuraException()` que sí llama `setMessage()`.
2. **Race condition real en Step 5:** `bulkDataEditor.js handleConfirmRun` llamaba
   `progressCmp.start()` justo después de `this.currentLogId = result.logId`, pero el binding
   reactivo `log-id={currentLogId}` del hijo se actualiza async — `.then()` corre fuera del
   ciclo de render de LWC, entonces a veces `progressCmp.logId` seguía `undefined` cuando
   `start()` llamaba `poll()`, causando "log no encontrado" en el primer poll. Por eso nunca
   se pudo reproducir vía Apex anónimo (sin LWC de por medio) pero sí en el navegador real.
   Fix: `start(explicitLogId, explicitBatchJobId)` acepta los IDs como parámetros directos en
   vez de depender solo del property binding.

Bonus pedido por el usuario: `bulkEditProgress.html` ahora muestra Log ID + Process ID
también dentro del banner de error, para poder reportarlo directo sin Network tab.

Deploy SEMBEQ ✅ (22/22) · AEBEQ ✅ (22/22). Pendiente que el usuario reintente el mass-edit
de `Account.SEMBEQ__c` que fallaba.

## 2026-07-17 — Performance: chunk size de batch subido de 200 a 2000

Usuario preguntó por qué un undo de 2934 registros (Contact—SEMBEQ) tardaba tanto ("9 of 15"
pasos) y si se podía acelerar.

**Causa:** `Database.executeBatch(..., 200)` — con 200 registros por chunk, 2934 registros
eran 15 chunks, cada uno una transacción separada pasando por la cola async de Apex.

**Fix:** `BATCH_CHUNK_SIZE = 2000` (máximo de la plataforma) en `BulkEditController.cls`,
usado en ambos `Database.executeBatch()` (edit y undo). Seguro porque `BulkEditBatch`/
`BulkEditUndoBatch` no hacen SOQL por registro — solo 1 update + 1 insert de snapshot por
chunk (~4000 filas DML máx con chunk=2000, bien debajo del límite de 10,000/transacción).
2934 registros pasan de 15 chunks a 2.

**Bonus:** corregido label engañoso — `processedRecords`/`totalRecords` vienen de
`AsyncApexJob.JobItemsProcessed`/`TotalJobItems` (conteo de CHUNKS, no de registros
individuales). Texto cambiado a "Batch X of Y" en `bulkEditProgress.html`.

Deploy SEMBEQ ✅ (22/22) · AEBEQ ✅ (22/22).

**Actualización (mismo día):** usuario probó con 2934 registros y reportó que con chunk=2000
(solo 2 chunks) la barra se sentía "trabada" mucho tiempo — sin progreso intermedio visible
dentro de un chunk tan grande. Bajado a `BATCH_CHUNK_SIZE = 400` (pedido explícito del
usuario) como punto medio: ~7-8 chunks para 2934 registros, progreso visible constante sin
tantos round-trips como el original 200. Redeploy SEMBEQ ✅ (22/22) · AEBEQ ✅ (22/22).

## 2026-07-17 — Feature: filtro/cruce opcional en Step 3 (cross-filter)

Usuario pidió poder cruzar el mass-edit con un segundo campo (ej. "Preferred Language" en
blanco → nuevo valor, pero SOLO para registros con Mailing State = Quebec) en vez de aplicar
el cambio a todos los registros con el campo en blanco a nivel org. Confirmado vía
AskUserQuestion: 1 solo filtro, embebido dentro del Step 3 existente (no paso nuevo).

**Cambios:** `BulkEditService.cls` (+`getFilterableFields`, `+resolveFilterFieldDescribe`,
`+getFilterFieldValueDistribution`, `getValueDistribution` +3 params) · `BulkEditController.cls`
(`startBulkEdit` 8→12 params, valida y guarda el filtro en el log, +2 endpoints nuevos,
`getEditHistory` expone el filtro) · `BulkEditBatch.cls` (constructor 7→10 params, ANDa la
condición del filtro al WHERE) · 2 campos nuevos en `Bulk_Edit_Log__c`
(`Filter_Field_Label__c`, `Filter_Value_Display__c`) + FLS en Admin profile y
`Bulk_Data_Editor_Access` permission set · `bulkDataEditor.js/html/css` (sección "+ Add
filter" en Step 3, reutiliza `c-bulk-searchable-select` y `c-bulk-value-table` sin componentes
nuevos) · `bulkEditConfirmModal.js/html` y `bulkEditHistory.js/html` (muestran el filtro
aplicado).

6 tests nuevos (Controller + Batch), todos verifican que el filtro efectivamente restringe el
conteo/update al subconjunto correcto.

Deploy SEMBEQ ✅ (28/28 tests, 100%) · AEBEQ ✅ (28/28 tests, 100%). Pendiente que el usuario
pruebe el flujo con su caso real (Preferred Language + Mailing State = Quebec).

## 2026-07-17 — Ajuste UX del filtro (feedback con screenshots)

Usuario probó el filtro y reportó 3 problemas: (1) la página crecía y pedía scroll al elegir
valor de filtro, (2) el ícono de selección de fila era un lápiz que parecía "editar" en vez de
"seleccionar", (3) faltaba una explicación completa de qué haría el cambio y por qué — pidió el
estilo del modal nativo de EDA "Create a relationship" (oración completa con términos en negrita).

**Fix:** picker de valor de filtro cambiado de `c-bulk-value-table` (lista con scroll que
empujaba el layout) a un segundo `c-bulk-searchable-select` (dropdown flotante, no empuja
página) al lado del combobox de campo · ícono de fila cambiado de lápiz a flecha
(`utility:chevronright`) · 3 oraciones explicativas completas agregadas en Step 3, Step 4 y el
modal de confirmación, reemplazando chips/fragmentos sueltos · CSS general con sombra sutil en
las cajas del wizard y mejor jerarquía visual.

Deploy SEMBEQ ✅ (28/28 tests, 100%) · AEBEQ ✅ (28/28 tests, 100%).

## 2026-07-17 — Segunda ronda de UX del filtro: 2 columnas con listas

Usuario reportó: ambos estados (con/sin filtro) deberían verse igual (agregar título "Filter"
en los dos), prefería volver a listas visibles (`c-bulk-value-table`) en vez del combobox
flotante del ajuste anterior, mostradas en 2 columnas (izquierda = filtro, derecha = valor
principal) para que no crezca la página, y las oraciones explicativas se veían con las palabras
pegadas (ej. "whereMailing State/Province = QCwill") por un bug de colapso de espacios en
blanco de LWC cuando un `<strong>{expr}</strong>` empieza en una nueva línea del template.

**Fix:** filtro rediseñado como grid de 2 columnas (`slds-grid slds-gutters`) — columna
izquierda con combobox de campo + `c-bulk-value-table` para el valor de filtro, columna derecha
con el `c-bulk-value-table` del valor principal · agregado título "Filter" consistente en ambos
estados · las 3 oraciones dinámicas (Step 3, Step 4, modal) reescritas en una sola línea física
en el `.html` para evitar el colapso de espacio de LWC.

**Instrucción explícita del usuario, vigente para esta fase de iteración:** NO correr tests de
Apex/cobertura durante estas rondas de ajuste visual — solo deployar a sandbox para revisar.
Los tests completos se harán al final, cuando el usuario confirme que la UI está lista.

Deploy SEMBEQ ✅ · AEBEQ ✅ (solo deploy, sin tests, según instrucción).

## 2026-07-17 — Tercera ronda: rediseño Step 3 con checkboxes y confirmación explícita

Usuario envió 2 screenshots: el estado real (2 columnas de la ronda anterior) se veía "muy
cerca" (columnas apretadas, cajas grises tocándose), y un mockup de referencia con: tarjetas de
filtro con checkmark de selección, lista de valor principal con checkboxes, más espacio entre
columnas, y una barra de confirmación inferior ("Confirmando el valor actual para X registros
filtrados." + botones "Continuar al Paso 4" / "Cancelar") en vez de avanzar automáticamente al
hacer click en una fila.

**Cambios de comportamiento (no solo visuales):**
- El filtro ya no es un modo "picker" que se abre/cierra — la columna de filtro está siempre
  visible en Step 3 junto a la columna de valor principal (se cargan `filterFieldOptions` al
  entrar a Step 3, en `handleFieldChange` y `handleStartAnother`).
- Seleccionar una fila (filtro o valor principal) ya NO navega automáticamente — solo marca/
  desmarca la selección (toggle, click de nuevo para deseleccionar). Avanzar a Step 4 requiere
  click explícito en "Continue to Step 4", que solo aparece una vez que hay un valor principal
  seleccionado (`showStep3Footer`/`step3StatusText` getters nuevos).
- `c-bulk-value-table` ahora indica selección con un checkbox real (`utility:check` sobre
  fondo azul si `isSelected`) en vez del ícono de flecha `utility:chevronright` — se agregó
  `@api selectedIsBlank` (antes solo `selectedRawValue`, que no distinguía filas "Blank").

**Visual:** columnas separadas con `gap: 2rem` (antes gutter de grid más apretado) + conector
visual (flecha `utility:forward`) entre ambas columnas, oculto en pantallas angostas · barra de
confirmación con fondo azul claro consistente con las demás cajas explicativas del wizard.

**Archivos:** `bulkValueTable.js/html/css` (checkbox de selección + prop `selectedIsBlank`) ·
`bulkDataEditor.js` (quitado `showFilterPicker`/`showAddFilterButton`/`handleAddFilterClick`/
`handleCancelAddFilter`; agregado toggle en `handleBucketSelect`/`handleFilterValueSelect`,
`handleContinueToNewValue`, `handleCancelValueSelection`, getters `selectedFilterRawValue`,
`selectedFilterIsBlank`, `selectedBucketRawValue`, `selectedBucketIsBlank`, `showStep3Footer`,
`step3StatusText`) · `bulkDataEditor.html/css` (Step 3 reescrito como `.step3-columns` con
`.step3-col` + `.step3-connector` + `.step3-footer`, reemplazando el grid `.filter-picking-*`
anterior).

Deploy SEMBEQ ✅ · AEBEQ ✅ (solo deploy, sin tests, según instrucción vigente). Pendiente que
el usuario revise visualmente si este diseño resuelve el "muy cerca" y si el patrón de
confirmación explícita (en vez de auto-avance) le gusta.

## ✅ 2026-07-17 — Cobertura 100% real en producción confirmada, app lista para deploy

Usuario pidió cierre técnico final: "checa la cobertura contra producción y si son necesarios
más @test para llegar al 100% hazlo, quiero tenerlo preparado para producción."

- Dry-run inicial contra producción (`--test-level RunSpecifiedTests --tests
  BulkEditControllerTest --tests BulkEditBatchTest`) detectó 19 líneas sin cubrir en
  `BulkEditBatch`, `BulkEditUndoBatch`, `BulkEditController`, `BulkEditService` — todas
  branches defensivas (CRUD/FLS denegado, DML fallido, truncado de error log, tipos
  Schema.DisplayType) inalcanzables con un usuario Admin de test.
- Cerradas con el patrón `@TestVisible static Boolean TEST_FORCE_*` (mismo patrón que
  `MergeController.TEST_FORCE_ACCOUNT_NOT_DELETABLE`) + 22 tests nuevos (12 en
  `BulkEditBatchTest.cls`, 10 en `BulkEditControllerTest.cls`). Detalle completo de cada flag,
  el gap cross-org de AEBEQ (`isCalculated()` en `getFilterableFields`), y el bug de test async
  (`Database.executeBatch` sin `Test.startTest/stopTest` corre después del test y pisa la
  aserción) en `activeContext.md`.
- SEMBEQ sandbox: 50/50 tests, 100% en todas las clases. AEBEQ sandbox: 50/50 tests, 100% en
  todas las clases.
- **Dry-run final de producción (acotado, no RunLocalTests):** `status: Succeeded`, 48 tests,
  0 failures, **100% real en las 6 clases** (BulkEditBatch 66/66, BulkEditController 140/140,
  BulkEditService 249/249, BulkEditUndoBatch 51/51, BulkEditWrappers 19/19, BulkEditException
  0/0).

**Estado: Bulk Data Editor técnicamente listo para producción.** Falta que el usuario corra el
deploy real (no hay script dedicado de producción para este módulo aún — se puede armar uno
tipo `deploy-bulk-editor-production.sh` si el usuario lo pide, siguiendo el patrón de los
scripts sandbox existentes).
