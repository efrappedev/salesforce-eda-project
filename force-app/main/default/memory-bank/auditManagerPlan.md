# Merge Audit Manager — Plan de construcción
**Estado:** DISEÑADO — pendiente construcción (esperar resultado pruebas sandbox)
**Fecha de diseño:** 2026-07-13

---

## Resumen

App Salesforce separada del App Launcher para auditar el historial completo de tickets
(V3 legacy + V2) en SEMBEQ. Independiente del Merge Manager — ninguna dependencia cruzada.
El único vínculo entre las dos apps es el objeto `Merge_Ticket__c` compartido.

---

## Archivos a crear (todos en `Merge Manager Salesforce Global V2 for EDA/`)

```
classes/
  MergeAuditController.cls
  MergeAuditController.cls-meta.xml
  MergeAuditControllerTest.cls
  MergeAuditControllerTest.cls-meta.xml

lwc/mergeAuditManager/
  mergeAuditManager.html
  mergeAuditManager.js
  mergeAuditManager.css
  mergeAuditManager.js-meta.xml

applications/
  Merge_Audit_Manager.app-meta.xml

flexipages/
  Merge_Audit_Manager.flexipage-meta.xml

tabs/
  Merge_Audit_Manager.tab-meta.xml
```

---

## MergeAuditController — 4 métodos

| Método | Descripción |
|--------|-------------|
| `getAuditTickets(objectType, statusFilter, legacyOnly, searchTerm, pageSize, offset)` | Lista paginada de todos los Merge_Ticket__c |
| `getAuditTicketCount(objectType, statusFilter, legacyOnly, searchTerm)` | Conteo para paginación |
| `getAuditTicketDetail(ticketId)` | Ticket + candidatos + logs (logs solo para V2; V3 no tiene link) |
| `reopenTicket(ticketId)` | Solo Ignored/Closed → Status='Reopened'. **Bloquea explícitamente Merged.** |

**Independencia total:** no importa ninguna clase del Merge Manager.

---

## UI — Layout 2 paneles

### Panel izquierdo (1/3) — lista
- Filtro: Tipo objeto (Contact / Account / Todos)
- Filtro: Status — Todos / Histórico / Activo / Merged / Ignored / Closed / Reopened
- Búsqueda por texto
- Toggle: "Solo tickets V3 heredados" (Match_Key__c IS NULL)
- Paginación offset (100/página)
- Cada fila: número, badge V3/V2, badge status, nombres candidatos, fecha

### Panel derecho (2/3) — detalle
- Header: `#XXXX`, badge V3/V2, badge status, botón cerrar
- Info grid: Type, Match Type, Confianza, Raison fermeture, Notes, fechas
- Sección **Candidatos**: nombre + ID
- Sección **Historique** (logs):
  - V2 tickets: muestra Merge_Log__c enlazados
  - V3 tickets: banner "Logs V3 no vinculados a tickets individuales"
- Footer de acción:
  - `Merged` → banner azul "Fusión permanente — solo lectura" (SIN botón reopen)
  - `Ignored` o `Closed` → botón "Rouvrir dans Merge Manager"
  - `Reopened` → badge verde "Ya reabierto" (informativo)
  - `New/In Review/Ready` → "Ya activo en Merge Manager"

---

## Identificación V3 legacy

`Match_Key__c IS NULL` → ticket V3
`Match_Key__c IS NOT NULL` → ticket V2

El toggle y el badge visual se basan en este campo.

---

## Mecanismo de comunicación entre apps

```
Audit App  ──(DML update Status='Reopened')──→  Merge_Ticket__c (objeto compartido)
                                                       ↑
Merge Manager  ──────────────────────────────(SOQL read)──┘
```

No hay pub/sub, platform events, ni dependencias de código.
Ambas apps leen el mismo objeto. Los cambios se reflejan al hacer refresh.

---

## Reglas del botón Reopen

| Status actual | Acción disponible |
|---------------|-------------------|
| Merged | ❌ Solo lectura (fusión permanente) |
| Ignored | ✅ Reopen → Status='Reopened' |
| Closed | ✅ Reopen → Status='Reopened' |
| Reopened | ℹ️ Ya reabierto (informativo) |
| New/In Review/Ready/Error | ℹ️ Ya activo en Merge Manager |

---

## Validaciones Apex verificadas (sin fricción)

- `Prevent_Reopen_After_Merge`: permite explícitamente `Merged → Reopened`  
  → Audit App bloquea Merged ANTES de llegar a esta VR (doble protección)
- `Require_Closed_Reason_When_Ignored`: usa ISCHANGED(Status__c) — evalúa el nuevo Status  
  → `Ignored → Reopened`: nuevo status es 'Reopened' (no Ignored) → VR NO se dispara ✅
- `Require_Master_When_Merged`: también con ISCHANGED → seguro en INSERT ✅

---

## NOTA IMPORTANTE

NO construir hasta que:
1. El usuario confirme el comportamiento en sandbox post-partial-refresh
2. El usuario dé el go-ahead explícito para construir el Audit Manager
