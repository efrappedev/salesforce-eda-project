# CLAUDE.md — EDA Safe Merge Management System

## REGLA CRÍTICA: Actualizar memory-bank SIEMPRE

**OBLIGATORIO en CADA mensaje del usuario, sin excepción:**

1. **AL INICIO** de cada conversación: leer todos los archivos de `force-app/main/default/memory-bank/` antes de responder.
2. **AL FINAL** de cada respuesta: actualizar `activeContext.md` y `progress.md` con lo que se hizo en ese mensaje.
3. Si no hay nada nuevo técnico que registrar, agregar mínimo la fecha y el tipo de interacción.
4. Si el usuario hace `/clear` y regresa, releer el memory-bank completo antes de responder.

**Archivos a mantener:**
- `force-app/main/default/memory-bank/activeContext.md` — estado actual, próximos pasos
- `force-app/main/default/memory-bank/progress.md` — bugs, cobertura, funcionalidades
- `force-app/main/default/memory-bank/systemArchitecture.md` — arquitectura (solo si cambia)

---

## Proyecto

**EDA Safe Merge Management System** — Salesforce Apex + LWC para detección y merge seguro de duplicados en orgs EDA.

- **Org producción:** `e.frappe@sembeq.qc.ca` (alias: `production`)
- **Sandbox:** `e.frappe@sembeq.qc.ca.partialdev` (alias: default)
- **Repo GitHub:** `github.com/efrappedev/salesforce-eda-project`

## Reglas de deploy

- **NUNCA hacer deploy directamente.** El usuario siempre corre: `./manifest/deploy-production.sh production`
- Solo hacer dry-run/validate si el usuario lo pide explícitamente.

## Stack

- Apex: `MergeController`, `MergeScanService`, `MergeScanBatch`, `MergeTicketService`, `MergeExecutionService`, `EDARelatedRecordsService`, `MergeAuditService`, `SnapshotService`, `DataNormalizationUtil`, `MergeWrappers`
- LWC: `mergeManager`, `mergeTicketList`, `mergeScanModal`, `mergeWizard`, `mergeComparisonMatrix`
- Objetos custom: `Merge_Ticket__c`, `Merge_Candidate__c`, `Merge_Log__c`

---

## Proyecto secundario: Android iJiami Bypass

Si el usuario menciona **Android, iJiami, Frida, APK, Xuper, bypass o emulador**:

1. **LEER INMEDIATAMENTE:** `android/CONTEXTO.md` — contiene todo el estado técnico actual
2. Scripts de trabajo en: `android/scripts/`
3. APKs NO están en el repo (binarios propietarios) — el usuario los tiene localmente en `Apk/`
4. **Responder siempre en español**

### Setup rápido en máquina nueva
```bash
# Emulador (Android Studio + AVD instalado):
export PATH="$PATH:~/Library/Android/sdk/platform-tools:~/Library/Python/3.9/bin"
adb root && adb shell "/data/local/tmp/frida-server &"
frida -U -f com.android.mgstv -l android/scripts/kills_only.js

# Solo Fire TV (solo necesita adb):
adb connect <ip_firetv>
adb logcat | grep -iE "http|url|portal|brasiliptv"
```
