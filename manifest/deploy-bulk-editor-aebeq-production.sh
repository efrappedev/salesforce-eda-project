#!/bin/bash
# ============================================================
# Bulk Data Editor — AEBEQ PRODUCTION Deploy
# ============================================================
# Deploys ONLY the Bulk Data Editor application, from the
# canonical source: "Bulk Data Editor/" (same source tree used
# for SEMBEQ — this app has no EDA/org-specific dependencies).
# Does NOT touch any other existing AEBEQ production metadata.
#
# Org: e.frappe@aebeq.qc.ca (AEBEQ production — no CLI alias set)
#
# ESTADO ACTUAL DEL ORG (verificado con `sf org list metadata`, 2026-08-11):
#   Ya existe en AEBEQ producción: BulkEditBatch, BulkEditController,
#   BulkEditException, BulkEditService, BulkEditUndoBatch, BulkEditWrappers,
#   BulkRecordTypeChangeBatch, BulkRecordTypeController,
#   BulkRecordTypeService (+ sus 4 test classes), objetos
#   Bulk_Edit_Log__c/Bulk_Edit_Snapshot__c, app/tab/flexipage
#   Bulk_Data_Editor, permission set Bulk_Data_Editor_Access, y los LWC
#   bulkDataEditor, bulkEditConfirmModal, bulkEditHistory, bulkEditProgress,
#   bulkRecordTypeChange, bulkSearchableSelect, bulkValueTable.
#
#   Falta (nunca se subió): Apex BulkPasteUpdateController,
#   BulkPasteUpdateBatch, RegenerateIdService, RegenerateIdController
#   (+ sus 4 test classes), BulkCleanFieldService/Controller/Batch (+ sus 3
#   test classes), y los LWC bulkPasteUpdate / bulkRegenerateId /
#   bulkCleanField. Dry-run de producción verificado 2026-08-14: 152/152
#   tests, 100% cobertura en las 17 clases del app completo.
#
# Este script sigue deployando la carpeta COMPLETA — es la forma correcta
# de actualizar: sf project deploy start es idempotente por componente.
# Lo que ya existe y no cambió queda "Unchanged"; lo que ya existe pero
# se modificó desde el último deploy se actualiza ("Changed"); lo que
# falta (Paste Update + Regenerate ID + Clean Field) se crea ("Created").
# No requiere separar "primera instalación" de "actualización".
#
# WHAT THIS DOES NOT DO:
#   - Asignar el permission set a usuarios nuevos (manual, como siempre —
#     los usuarios que YA lo tienen asignado reciben automáticamente el
#     acceso a las 4 clases nuevas en cuanto se agreguen al permission set)
#   - Dar FLS/objeto access a otros profiles distintos de Admin
#
# Usage:
#   chmod +x manifest/deploy-bulk-editor-aebeq-production.sh
#   ./manifest/deploy-bulk-editor-aebeq-production.sh
# ============================================================

set -e

TARGET_ORG="e.frappe@aebeq.qc.ca"

echo ""
echo "⚠️  DESTINO: AEBEQ PRODUCCIÓN ($TARGET_ORG)"
echo ""
echo "Bulk Data Editor YA está instalado en AEBEQ producción (Bulk Edit +"
echo "Record Type Change). Este deploy actualiza la carpeta completa:"
echo "  - Lo que ya existe y no cambió: queda 'Unchanged'"
echo "  - Lo que ya existe pero se modificó desde el último deploy: se actualiza"
echo "  - Lo que falta (Paste Update + Regenerate ID + Clean Field, Apex y LWC): se crea"
echo ""
echo "NO asigna el permission set a usuarios nuevos — eso se hace a mano después."
echo "Los usuarios que YA tienen el permission set reciben automáticamente"
echo "acceso a las clases nuevas en cuanto se agregan al permission set."
echo ""
echo "¿Continuar? Escribe CONFIRMAR para proceder:"
read -r CONFIRM
if [ "$CONFIRM" != "CONFIRMAR" ]; then
  echo "Cancelado."
  exit 0
fi

BASE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$BASE/force-app/main/default/Bulk Data Editor"

echo ""
echo "========================================================"
echo "  Bulk Data Editor — AEBEQ PRODUCTION DEPLOY"
echo "  Target: $TARGET_ORG"
echo "========================================================"
echo ""

DEPLOY_OUTPUT=$(sf project deploy start \
  --source-dir "$SRC/classes" \
  --source-dir "$SRC/lwc" \
  --source-dir "$SRC/objects" \
  --source-dir "$SRC/applications" \
  --source-dir "$SRC/tabs" \
  --source-dir "$SRC/flexipages" \
  --source-dir "$SRC/permissionsets" \
  --source-dir "$SRC/profiles" \
  --test-level RunSpecifiedTests \
  --tests BulkEditControllerTest \
  --tests BulkEditBatchTest \
  --tests BulkRecordTypeControllerTest \
  --tests BulkRecordTypeChangeBatchTest \
  --tests BulkPasteUpdateControllerTest \
  --tests BulkPasteUpdateBatchTest \
  --tests RegenerateIdServiceTest \
  --tests RegenerateIdControllerTest \
  --tests BulkCleanFieldServiceTest \
  --tests BulkCleanFieldControllerTest \
  --tests BulkCleanFieldBatchTest \
  --target-org "$TARGET_ORG" \
  --json 2>&1)

DEPLOY_OUTPUT="$DEPLOY_OUTPUT" python3 - << 'PYEOF'
import json, os, sys

raw = os.environ.get('DEPLOY_OUTPUT', '')
# sf sometimes prepends a "Warning: cli update available" line to stdout
# even with --json, which breaks a naive json.loads() on the full blob.
if '{' in raw:
    raw = raw[raw.index('{'):]
try:
    data = json.loads(raw)
except:
    print(raw)
    sys.exit(1)

result = data.get('result', {})
status = result.get('status', 'Unknown')
deploy_id = result.get('id', 'N/A')
success = result.get('success', False)

print(f"\n{'='*55}")
print(f"  Deploy ID : {deploy_id}")
print(f"  Status    : {status}")
print(f"  Success   : {success}")
print(f"{'='*55}\n")

# Test results — nested in details.runTestResult
details = result.get('details', {})
tests = details.get('runTestResult', result.get('runTestResult', {}))
total = result.get('numberTestsCompleted', tests.get('numTestsRun', 0))
failures = tests.get('failures', [])

if total:
    print(f"Tests: {total} run | {len(failures)} failures")

if failures:
    print("\n⛔ Test failures:")
    for f in failures[:5]:
        print(f"  [{f.get('methodName','?')}] {f.get('message','')[:120]}")

# Coverage table
coverage = tests.get('codeCoverage', [])
if coverage:
    print("\n📊 Coverage:")
    print(f"  {'Class':<45} {'Lines':>8} {'%':>6}")
    print(f"  {'-'*45} {'-'*8} {'-'*6}")
    for c in sorted(coverage, key=lambda x: x.get('name','')):
        name = c.get('name','')
        total_lines = int(c.get('numLocations', 0))
        covered = int(c.get('numLocationsNotCovered', 0))
        if total_lines > 0:
            pct = round((total_lines - covered) / total_lines * 100, 1)
            flag = '' if pct == 100 else ' ⚠️' if pct < 75 else ''
            print(f"  {name:<45} {total_lines:>8} {pct:>5.1f}%{flag}")

# Errors
errors = result.get('details', {}).get('componentFailures', [])
if errors:
    print(f"\n⛔ Component failures ({len(errors)}):")
    for e in errors[:10]:
        print(f"  [{e.get('componentType','?')}:{e.get('fullName','?')}] {e.get('problem','')[:100]}")

if success:
    print("\n✅ DEPLOY SUCCEEDED")
    print("")
    print("Next steps:")
    print("  1. Verificar en producción que las 3 pestañas nuevas (Paste Update,")
    print("     Regenerate ID y Clean Field) aparecen dentro de la app Bulk Data")
    print("     Editor, junto a las 2 que ya existían.")
    print("  2. Probar un mini flujo de cada una en vivo (con Undo donde aplique) —")
    print("     los usuarios que ya tienen el permission set asignado ya deberian")
    print("     ver las pestañas sin necesitar ninguna acción manual.")
else:
    print("\n❌ DEPLOY FAILED — Review errors above")
PYEOF
