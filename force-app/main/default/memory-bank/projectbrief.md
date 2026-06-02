# Project Brief — Safe Merge Management System

## Objetivo principal

Aplicación interna en **Salesforce EDA (Education Data Architecture)** para detectar, comparar y ejecutar merges de registros duplicados de **Contact** y **Account** de forma manual, controlada y auditable.

## Organización

- **Org / Sandbox activo:** `sembeq--partialdev.sandbox.my.salesforce.com`
- **Usuario:** `e.frappe@sembeq.qc.ca.partialdev`
- **Idioma UI:** Francés (botones: Courriel, Téléphone, Nom, Fusionner, etc.)

## Requisitos clave

1. **Detección de duplicados** — scan por Email, Teléfono y/o Nombre con normalización (trim, lowercase, sin acentos, solo dígitos).
2. **Tickets persistentes** — cada grupo de duplicados genera un `Merge_Ticket__c` con candidatos (`Merge_Candidate__c`) para revisión humana.
3. **Comparación visual** — matriz lado a lado con todos los campos relevantes por candidato, incluyendo registros EDA relacionados.
4. **Merge seguro** — `Database.merge(master, losingList, false)` en lotes de 2, con SObject limpio (sin campos read-only).
5. **Log de auditoría inmutable** — `Merge_Log__c` con snapshot JSON del "antes" y "después".
6. **Soporte Account EDA** — Account SÍ tiene campo Email directo: `hed__Credentialing_Email__c`.
7. **Escalabilidad** — scan síncrono hasta 50 000 registros; bulkificación en toda la lógica de negocio.

## Objetos de control (custom)

| Objeto | Rol |
|---|---|
| `Merge_Ticket__c` | Ticket del caso de duplicación. Status: New → In Review → Ready → Merged / Ignored / Error |
| `Merge_Candidate__c` | Master-Detail al ticket. Un registro por candidato, con snapshot JSON |
| `Merge_Log__c` | Auditoría inmutable. Se escribe una vez, nunca se modifica |

## RecordTypes de Account en producción

`Academic_Program`, `Administrative`, `Business_Organization`, `Educational_Institution`, `HH_Account`, `Organisme`, `Sports_Organization`, `University_Department`, `Eglise`

## Sandbox PartialDev — datos conocidos

- Total Accounts: **8 657**
- Grupos de teléfono duplicados detectados: **~709** (con LIMIT 50 000)
- Tickets Contact activos previos: varios (de scans anteriores)
- Tickets Account activos al inicio de esta sesión: **0** (usuario hizo Reset)
