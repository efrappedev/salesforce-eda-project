# CONTEXTO — Sistema de Gestión de Merges Seguro para Salesforce EDA

> Archivo de retoma de contexto. Generado a partir de la conversación previa para continuar el trabajo tras un `/clear`. Lee esto al iniciar una sesión nueva en Claude Code.

## Rol esperado del asistente
Desarrollador Senior de Salesforce (8+ años), especializado en **Salesforce EDA (Education Data Architecture)**, **LWC** y **Apex avanzado**. Prioridades: integridad de datos, escalabilidad, UI limpia con SLDS, principios SOLID, Service Layer Pattern, bulkificación y auditabilidad.

---

## 1. Objetivo del proyecto
Aplicación interna en Salesforce (LWC + Apex) para **detectar, revisar y ejecutar merges de Contacts y Accounts** de forma manual y segura. Debe:
- Generar **tickets persistentes** de duplicados.
- Permitir **comparación visual** de datos y registros relacionados (EDA).
- Mantener un **log de auditoría inmutable** con snapshots JSON del "antes" y "después".
- Estar preparada para grandes volúmenes (la lógica de escaneo y logs es bulkificada aunque el merge sea de uno en uno).

## 2. Modelo de datos (objetos de control)
- **`Merge_Ticket__c`** (el ticket): `Status__c` (New, In Review, Ready, Merged, Ignored, Error), `Object_Type__c` (Contact/Account), `Match_Type__c` (Email, Phone, Name, Mixed), `Match_Key__c` (texto normalizado), `Match_Confidence__c` (High/Medium/Low), `Candidate_Count__c`, `Selected_Master_Id__c`, `Final_Action__c`, `Error_Message__c`, `Notes__c`.
- **`Merge_Candidate__c`** (Master-Detail al ticket): `Record_Id__c` (Text 18), `Record_Name__c`, `Is_Master__c`, `Is_Losing_Record__c`, `Snapshot_JSON__c`, `Related_Info_JSON__c`.
- **`Merge_Log__c`** (auditoría inmutable): `Object_Type__c`, `Action_Type__c`, `Master_Record_Id__c`, `Losing_Record_Ids__c`, más `Master_Record_Name__c`, `Losing_Record_Names__c`, `Losing_Records_Summary__c`.

### Campos relevantes por objeto
- **Contact**: tiene campos Email directos (Email, hed__AlternateEmail__c, hed__UniversityEmail__c).
- **Account (EDA)**: **SÍ tiene un campo Email directo: `hed__Credentialing_Email__c`** (del paquete EDA). Campos usados: Name, Common_Name__c, hed__Credentialing_Email__c, Phone, Fax, AccountNumber, ID_Account__c, ID_Prodon__c, Credentialing_Identifier__c, hed__School_Code__c.
- **`Email_Address__c`**: objeto hijo con lookup (`Account__c` / a Contact) usado para detección de duplicados por email vía "objeto de emails personalizado" (toggle).

### RecordTypes de Account existentes en Salesforce
Academic_Program, Administrative, Business_Organization, Educational_Institution, HH_Account (Household), Organisme, Sports_Organization, University_Department, Eglise.

---

## 3. Arquitectura / archivos tocados
```
MergeManager (LWC) ──► MergeController (Apex, ligero)
                          ├──► MergeScanService ──► DataNormalizationUtil
                          ├──► MergeScanBatch (versión batch del scan)
                          ├──► MergeExecutionService
                          └──► MergeAuditService
```
Clases Apex principales:
- **`DataNormalizationUtil.cls`** (estable): `normalizeEmail` (trim+lowercase), `normalizePhone` (solo dígitos, quita prefijo país NA si 11 dígitos empezando en '1'), `normalizeName` (uppercase + remoción de acentos + colapsar espacios dobles), `buildMatchKey` → formato `"OBJ|TYPE|NORMALIZED_VALUE"` (ej. `Contact|Email|john@example.com`).
- **`MergeScanService.cls`**: `detectByFields()` (SOQL dinámico, agrupa por match key normalizado), `loadExistingCandidateSets`, `deduplicateByCandidateSet`.
- **`MergeScanBatch.cls`**: misma lógica en versión batch; tiene `existingCandidateSets` como campo stateful y deduplica en `finish()`.
- **`MergeExecutionService.cls`**: `runMerge(masterRecord, losingIds)` en lotes de 2 (límite nativo de `Database.merge`).
- **`MergeAuditService.cls`**: `createPreMergeLog` construye campos legibles desde `allCandidates`.
- LWC: `mergeManager`, `mergeTicketList.js`.
Hay un documento de seguimiento llamado **V2** que se actualiza tras cada cambio.

Ruta del proyecto (checkpoint que funcionaba):
`/Users/e.frappe/Downloads/SalesForce Test/Button Student Scores/Button test/force-app/main/default/Merge app Salesforce/`

---

## 4. Decisiones técnicas clave (lo que YA funciona)
- **`Database.merge(master, losingList, false)`**: `allOrNone=false` devuelve `Database.MergeResult` detallado. **OJO**: con `List<Id>` devuelve **`List<Database.MergeResult>`**, no uno solo (bug ya corregido: asignar a `List<Database.MergeResult> mrs`).
- **SObject limpio para merge**: NO pasar el SObject con todos los campos cargados (causa `INVALID_FIELD_FOR_INSERT_UPDATE` en campos read-only como Name, CreatedDate). Fix: crear SObject limpio con `Schema.getGlobalDescribe().get(objectType).newSObject(masterId)` y añadir solo overrides `isUpdateable()`.
- **Deduplicación de tickets (2 capas)** — corregido un bug donde Email/Phone/Name generaban 2-3 tickets para el mismo par de registros:
  1. **Within-scan**: colapsar grupos con idéntico *candidate set* en un solo ticket (se queda el match type de mayor confianza).
  2. **Cross-scan**: si un ticket existente ya cubre los mismos registros (con otra match key), saltar el grupo nuevo.
- **Bug LWC QueryResult corregido**: el subquery hijo `Merge_Candidates__r` llega al wire adapter como objeto `{records:[...], totalSize, done}`, NO como array. Llamar `.map()` directo lanzaba `TypeError: raw.map is not a function` y rompía `enrichedTickets` (lista devolvía 0 resultados). Fix: usar `raw.records` antes de mapear.
- Tests: 56/56 pasando en el último estado estable.

---

## 5. ⚠️ PROBLEMA PENDIENTE (donde nos quedamos)
**El scan de Account NO genera tickets** — reporta "0 match" cuando NO es cierto. Había 500+ duplicados antes.

### Historial de intentos (qué se probó y descartó)
1. Cambio previo `null emailObjectApiName = skip` rompió Account (que dependía de `Email_Address__c`). 
2. Se escondió el botón "Courriel" para Account creyendo que no tenía campo email directo → **error de análisis**: Account EDA SÍ tiene `hed__Credentialing_Email__c`. Botón restaurado.
3. Usuario probó con solo Nombre+Teléfono y con los 3 criterios (Courriel+Téléphone+Nom) → **sigue sin generar tickets**. IDs de ejemplo que SÍ son duplicados: `0018c00002FtE5TAAV`, `001Sv00000bH5NFIA0` (prefijos de org distintos: `8c` vs `Sv` → posibles migraciones distintas).

### Pistas críticas (de las reglas de duplicación nativas de Salesforce en screenshots)
- **Salesforce detecta los duplicados nativamente** con su Matching Rule usando **`FUZZY:PHONE` y `FUZZY:COMPANY NAME`** (matching DIFUSO).
- **Nosotros usamos exact match sobre valor normalizado** → esa es la diferencia clave: por eso Salesforce los cruza y nuestro scan no.
- Las cuentas muestran teléfonos idénticos (ej. `(819) 538-8748` ×2) → el match por teléfono *debería* funcionar incluso con exact match, lo que sugiere un problema adicional.

### Hipótesis abiertas a verificar
- **`isAccessible()` en `resolveFields`/`loadLiveRecords`**: el código original NO verificaba FLS, solo existencia del campo. El código nuevo agregó `dfr.isAccessible()`, que puede excluir silenciosamente campos si el usuario tiene restricciones FLS aunque los vea en UI. **Ya se quitó `isAccessible()` en un punto para igualar al original** — verificar que el deploy quedó aplicado.
- **¿Los datos existen en PartialDev?** Los IDs de ejemplo podrían ser de **producción**, no del sandbox `partialdev`. Confirmar que los registros duplicados existen en el sandbox donde se corre el scan.
- **Matching exact vs fuzzy**: puede que los nombres/teléfonos tengan diferencias invisibles (Unicode, guiones, espacios) que el normalizador no colapsa pero el fuzzy de Salesforce sí tolera.

### Próximo paso inmediato (estaba a medias)
Se iba a correr un **script de diagnóstico en Developer Console → Debug → Open Execute Anonymous Window** para confirmar la causa real. El script debe reportar:
- `NAME DUPLICATE GROUPS FOUND` (0 = nombres no coinciden tras normalización → problema de matching; >0 = bug en scan)
- `PHONE DUPLICATE GROUPS FOUND`
- Para los IDs específicos: su PhoneKey/NameKey normalizado (ver si salen "NO PHONE" o claves distintas)
- `EXISTING ACCOUNT TICKETS` (si quedaron tickets viejos que bloquean nuevos vía `existingKeys`)

---

## 6. PRÓXIMOS PASOS (orden sugerido)
1. **Reescribir/recuperar el script de diagnóstico** para Execute Anonymous y correrlo sobre los IDs `0018c00002FtE5TAAV` y `001Sv00000bH5NFIA0` en el sandbox correcto. Confirmar dónde se rompe el match.
2. **Verificar el deploy actual** en `sembeq--partialdev.sandbox`: confirmar que la versión sin `isAccessible()` está desplegada y que el botón Courriel para Account está visible.
3. **Confirmar que los registros existen en PartialDev** (no solo en producción).
4. Según el diagnóstico, decidir si hay que **acercar el matching al comportamiento fuzzy de Salesforce** (ej. mejorar `normalizePhone`/`normalizeName`, o tolerancia de nombres) en lugar de exact match estricto.
5. Re-correr scan de Account y validar que vuelven a aparecer los ~500 tickets.
6. Actualizar el documento **V2** y correr la suite de tests (mantener 56/56 o más).

## 7. Notas operativas
- Org / sandbox: `sembeq--partialdev.sandbox.my.salesforce.com`.
- Idioma de la UI: francés (botones "Courriel", "Téléphone", "Nom", "Utiliser un objet d'emails personnalisé", "Fusionner", "Restaurer").
- Mantener tests verdes y actualizar V2 tras cada cambio desplegado.
