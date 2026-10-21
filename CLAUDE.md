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

- **Cambios que tocan Apex (`.cls`):** NUNCA hacer deploy directo a producción. El usuario siempre corre el script de producción él mismo (ej. `./manifest/deploy-production.sh production`).
- **Cambios 100% LWC (sin ningún `.cls` tocado):** SÍ se puede correr el script de deploy a producción directamente, sin esperar a que el usuario lo corra. Confirmado explícitamente por el usuario (2026-07-21): "si solo es LWC puedes actualizarlo, solo no se actualiza APEX".
- Solo hacer dry-run/validate si el usuario lo pide explícitamente.

## REGLA: Un proyecto = una carpeta con el nombre del proyecto

**Cada nueva app o proyecto Salesforce vive en su propia carpeta raíz nombrada igual que el proyecto/app.** No usar patrones genéricos como `force-app-X`.

**Estructura estándar de cada carpeta de proyecto:**
```
Nombre del Proyecto/
├── main/default/        ← metadata Salesforce (registrado en sfdx-project.json)
│   ├── classes/
│   ├── lwc/
│   ├── objects/
│   ├── permissionsets/
│   └── ...
├── scripts/             ← scripts de utilidad (Python, bash, etc.)
├── demo-data/           ← CSVs u otros datos de prueba/demo
└── deploy-production.sh ← script de deploy a producción para ESTE proyecto
```

**Proyectos actuales:**
| Carpeta | Proyecto | Org |
|---|---|---|
| `Zeffy Connect/` | Robot Zeffy→Salesforce (Zeffy Connect) | AEBEQ |
| `Donation Management Center/` | ⚠️ CARPETA ANTIGUA — usar `Zeffy Connect/` | AEBEQ |
| `force-app-aebeq/` | Componentes generales AEBEQ (ID gen, triggers) | AEBEQ |
| `force-app-sembeq/` | Componentes generales SEMBEQ | SEMBEQ |
| `force-app/` | EDA Merge Manager (proyecto principal) | SEMBEQ |

**Para proyectos nuevos:** crear la carpeta con el nombre exacto del proyecto antes de escribir ningún archivo. El script de deploy va DENTRO de la carpeta del proyecto, no en `manifest/`.

---

## REGLA CRÍTICA: Nomenclatura única por org (evitar colisión de nombres)

**En Salesforce, el nombre de un componente (clase Apex, bundle LWC, objeto custom, campo, App,
Tab, FlexiPage, Permission Set) es único por org — sin importar en qué carpeta del repo viva
localmente.** Dos carpetas distintas pueden tener cada una su propio archivo `SnapshotService.cls`
o `lwc/i18n/`, y a nivel de código fuente/Git conviven sin problema — pero en el org destino, el
deploy más reciente de cualquiera de las dos **pisa silenciosamente** a la otra, porque para
Salesforce ambas son literalmente el mismo componente (mismo nombre = mismo componente).

**Por eso, cualquier componente nuevo (sobre todo genérico/reutilizable: `i18n`, `Utils`, `Helper`,
`Wrapper`, `SnapshotService`, `AuditService`, etc.) debe llevar el nombre de la app al principio**
(ej. `DataUpdateI18n`, `MergeI18n`, `BulkEditorUtils`) — nunca un nombre genérico sin prefijo,
aunque parezca que "por ahora" no hay nada más con ese nombre en el org.

**Nombres demasiado largos → abreviar el prefijo de la app (regla del usuario, 2026-10-15):** si
con el prefijo completo un nombre pasa el límite de Salesforce (clases Apex: 40 caracteres) o queda
muy largo, se usa la abreviatura de la app en vez del prefijo completo. Para Data Update Center:
`Duc` en Apex (ej. `DucMultiTicketReviewControllerTest`), `duc` en LWC (ej. `ducMultiTicketReview`)
y `DUC_` en API names (ej. `DUC_Multi_Ticket_Review`). Nunca quitar el prefijo por completo ni
recortar la parte descriptiva del nombre. Antes de usar la abreviatura, verificar que no choque con
otro componente del repo, igual que con el prefijo completo.

**Antes de nombrar un componente nuevo:** verificar que ningún otro folder del repo (`force-app/`,
`force-app-aebeq/`, `force-app-sembeq/`, etc.) ya use exactamente ese nombre. Si dos apps
necesitan lógica realmente idéntica y compartida (no solo casualmente parecida), preferir que una
sea la fuente de verdad y la otra la reference/importe, en vez de mantener copias duplicadas con
el mismo nombre en carpetas distintas.

**Precedente real (2026-08-24):** el LWC `i18n` de "Ticket Update App" pisó silenciosamente al
`i18n` de Merge Manager en AEBEQ sandbox (302 claves de traducción faltantes, sin que nadie lo
notara) porque ambas carpetas usaban el mismo nombre genérico. Mismo hallazgo con
`SnapshotService.cls`, duplicado idéntico en 7 carpetas del repo — sin daño visible solo porque
las copias coincidían byte a byte, pero listo para romperse en el momento en que alguna divergiera.
Fix aplicado: renombrado a `dataUpdateI18n` / `DataUpdateSnapshotService`. Detalle completo en
`memory-bank/activeContext.md` (entrada 2026-08-24).

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
