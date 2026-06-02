# Progress — Safe Merge Management System

## ✅ Estado producción (2026-06-02)

### Deploy producción COMPLETO
| Clase | Cobertura |
|---|---|
| DataNormalizationUtil | 100% |
| EDARelatedRecordsService | 100% |
| MergeAuditService | 100% |
| MergeController | 100% |
| MergeExecutionService | 100% (producción) / 96% (sandbox — fix en progreso) |
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

**Estado:** ✅ Resuelto en sandbox — dry-run producción: 70/70 tests, Succeeded

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

## ⏳ Pendiente

1. **Confirmar fix francés** — usuario prueba merge en sandbox con org en francés
2. **Cobertura** — agregar tests para `fixEdaPreferenceFields` + `clearIfInvalid` (líneas 96% → 100%)
3. **Deploy producción** — usuario corre `./manifest/deploy-production.sh production`
4. **Actualizar V2** — solo después de confirmar en producción (V2 = checkpoint estable)
5. **Borrar tickets de prueba** — usando Anonymous Apex en producción (ver activeContext sesión anterior)
