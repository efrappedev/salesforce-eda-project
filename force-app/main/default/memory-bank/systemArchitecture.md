# System Architecture — Safe Merge Management System

## Stack

- **Frontend:** Lightning Web Components (LWC), SLDS
- **Backend:** Apex (Service Layer Pattern, `without sharing` en servicios, `with sharing` en controller)
- **Datos:** Salesforce EDA (Education Data Architecture) + objetos custom de control
- **Deploy:** SF CLI (`sf deploy metadata`) → sandbox `sembeq--partialdev`

## Árbol de componentes LWC

```
mergeManager (orquestador principal)
  ├── mergeTicketList     (panel izquierdo: lista de tickets con filtros)
  │     └── @wire getTickets → MergeController.getTickets
  ├── mergeWizard         (panel derecho: tabs de revisión/merge)
  │     ├── mergeComparisonMatrix
  │     └── (acciones: merge, ignore, cerrar)
  └── mergeScanModal      (modal: configurar y lanzar scan)
        └── runScanApex → MergeController.runScan
```

## Clases Apex

```
MergeController.cls          (with sharing) — thin adapter LWC, sin lógica de negocio
  ├── runScan(ScanRequest)   → MergeScanService.scan()
  │     └── override recordLimit = 50000 para non-dryRun
  ├── getTickets(objectType, statusFilter)  @AuraEnabled(cacheable=true)
  ├── getComparisonMatrix(ticketId)         → MergeTicketService
  ├── executeMerge(...)                     → MergeExecutionService
  ├── updateTicketStatus / dismissTicket
  ├── deleteAllTickets()     (reset sandbox)
  ├── getEmailObjectCandidates()
  └── deleteOrphanedAccount / deleteOrphanedContact / restore*

MergeScanService.cls         (without sharing) — detección de duplicados
  ├── scan(ScanRequest) → detectByFields + detectByEmailObject
  ├── detectByFields(objectType, matchType, lim, existingKeys, groups)
  │     └── resolveFields() → Schema.DisplayType.EMAIL / PHONE / Name
  ├── detectByEmailObject(objectType, emailObjName, ...)
  ├── persistTickets(groups, objectType) → Database.insert(tickets, false)
  ├── loadExistingKeys(objectType)       → Set<String> de Match_Key__c existentes
  ├── loadExistingCandidateSets(objectType) → Set<String> canónico de IDs
  ├── deduplicateByCandidateSet()        → colapsa grupos por candidato set
  ├── resolveFields(objectType, matchType) → campos sin check FLS (intencional)
  └── enrichWithEmailObject()            → usado por MergeScanBatch.finish()

MergeScanBatch.cls           (Database.Batchable + Stateful)
  └── acumula en Map<String,String> (único tipo serializable con Stateful)

MergeExecutionService.cls    (without sharing)
  └── runMerge → Database.merge(cleanSObject, losingIds, false), lotes de 2

MergeAuditService.cls        → createPreMergeLog con snapshot JSON
MergeTicketService.cls       → buildComparisonMatrix
EDARelatedRecordsService.cls → conteo de CourseConnections, Affiliations, etc.
DataNormalizationUtil.cls    → normalizeEmail, normalizePhone, normalizeName, buildMatchKey
MergeWrappers.cls            → todos los DTOs @AuraEnabled

```

## Match Key Format

```
"Account|Phone|8195388748"
"Contact|Email|john@example.com"
"Account|Name|AMELIE-ANNE GAUTHIER ADMINISTRATIVE ACCOUNT"
```

## Campos por objeto que se scanean

| Objeto | Email | Phone | Name |
|---|---|---|---|
| Contact | Email, hed__AlternateEmail__c, hed__UniversityEmail__c | Phone, MobilePhone, HomePhone, OtherPhone | Name |
| Account | hed__Credentialing_Email__c | Phone, Fax | Name, Common_Name__c |

## Objeto email complementario

`Email_Address__c` — objeto child con campo EMAIL y lookup a Contact/Account.
Activado mediante toggle "Utiliser un objet d'emails personnalisé" en el scan modal.
Se pasa como `emailObjectApiName = 'AUTO'` → `resolveEmailObjectName()` lo autodetecta.

## Decisiones de diseño importantes

- **Sin FLS check en `resolveFields`** — intencional: scans de admin no deben ser degradados por restricciones de perfil. La clase `without sharing` ya maneja row-level security.
- **`Database.insert(tickets, false)`** — `allOrNone=false` para que un fallo en un ticket no aborte toda la inserción.
- **SObject limpio para merge** — `Schema.getGlobalDescribe().get(objectType).newSObject(masterId)` — evita `INVALID_FIELD_FOR_INSERT_UPDATE` en campos read-only.
- **Stateful batch** — solo `Map<String,String>` es serializable de forma fiable en `Database.Stateful`.
- **Governor limits** — con 8 657 Accounts y 2 match types (Phone+Name), se usan ~17 000 filas SOQL de las 50 000 permitidas. Seguro.

## Rutas de archivo locales

```
/Users/e.frappe/Downloads/SalesForce Test/Button Student Scores/Button test/
  force-app/main/default/
    classes/
      MergeController.cls
      MergeScanService.cls
      MergeScanBatch.cls
      MergeExecutionService.cls
      MergeAuditService.cls
      MergeTicketService.cls
      EDARelatedRecordsService.cls
      DataNormalizationUtil.cls
      MergeWrappers.cls
    lwc/
      mergeManager/
      mergeTicketList/
      mergeScanModal/
      mergeWizard/
      mergeComparisonMatrix/
    memory-bank/   ← este directorio
    CONTEXTO.md    ← contexto del chat anterior
```
