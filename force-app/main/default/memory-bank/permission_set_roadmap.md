# SEMBEQ — Roadmap Permission Sets + Archived Records

## Los 3 Permission Sets

| # | Nombre | Para quién | Objetos | Estado |
|---|---|---|---|---|
| 1 | `Basic_Contact_Access` | Recepción, voluntarios, acceso mínimo | Account+Contact (R/W), Relationship (R), Address (R) | Pendiente |
| 2 | `EDA_Staff_Access` | 5 admins actuales sin acceso Setup | 27 objetos EDA CRUD + 5 config read-only + 3 VF pages | ✅ Deployado sandbox 2026-06-30 |
| 3 | `Full_Access_Plus_Archive` | 2-3 personas de confianza total | EDA + Fundraising + Custom Permission `Manage_Archived_Records` | Pendiente |

---

## PS #2 — EDA_Staff_Access (completado ✅)

- Archivo: `force-app/main/default/permissionsets/EDA_Staff_Access.permissionset-meta.xml`
- Deployado a: `e.frappe@sembeq.qc.ca.partialdev`
- Incluye: Account+Contact (dependencia EDA), 27 objetos EDA CRUD+ViewAll, 5 objetos config read-only, VF pages DegreeAuditMatrix + DegreeAuditMatrixContactAction + StudentRecordsPage
- **Para aplicar:** cambiar perfil de los 5 usuarios System Administrator → Standard User, luego asignar PS

## PS #1 — Basic_Contact_Access (pendiente)

- Account: Read + Create (no Delete)
- Contact: Read + Edit + Create (no Delete)
- hed__Relationship__c: Read only
- hed__Address__c: Read only
- También será el perfil del revisor de Cases de Zeffy (ver zeffy_integration.md)

## PS #3 — Full_Access_Plus_Archive (pendiente)

- Todo lo de EDA_Staff_Access
- Todos los objetos Fundraising: Donacion__c, Donacion_Recurrente__c, Fondo__c
- Custom Permission: `Manage_Archived_Records`
- Construir después de Fundraising Fase 1

---

## Sistema Archived Records (futuro)

**Concepto:** Contactos/Accounts sin actividad en 10+ años se marcan como archivados:
- Read-only para todos excepto quienes tienen `Manage_Archived_Records`
- Desaparecen de list views normales (`Archived__c = false` como filtro)
- Siguen apareciendo en búsqueda global de Salesforce
- Admins los reactivan cambiando `Archived__c` a false

**Componentes a construir:**
1. `Archived__c` (Checkbox) + `Archived_Date__c` (Date) en Contact y Account
2. Custom Permission: `Manage_Archived_Records`
3. Validation Rule Contact: `AND(Archived__c = true, NOT($Permission.Manage_Archived_Records))`
4. Validation Rule Account: misma lógica
5. Flow programado mensual: detecta inactividad 10+ años → archiva
6. LWC banner opcional: "ARCHIVADO — Solo lectura" en record page

**Estado:** Diseñado. Implementar después de Fundraising Fase 1.
