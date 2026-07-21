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
# WHAT THIS DEPLOYS (first install in this org):
#   Apex (13 classes, incl. 5 test classes):
#     BulkEditBatch, BulkEditController, BulkEditException,
#     BulkEditService, BulkEditUndoBatch, BulkEditWrappers,
#     BulkRecordTypeChangeBatch, BulkRecordTypeController,
#     BulkRecordTypeService
#     + BulkEditBatchTest, BulkEditControllerTest,
#       BulkRecordTypeChangeBatchTest, BulkRecordTypeControllerTest
#   LWC (7 components):
#     bulkDataEditor, bulkEditConfirmModal, bulkEditHistory,
#     bulkEditProgress, bulkRecordTypeChange, bulkSearchableSelect,
#     bulkValueTable
#   Objects: Bulk_Edit_Log__c, Bulk_Edit_Snapshot__c
#   App/Tab/FlexiPage: Bulk_Data_Editor
#   PermissionSet: Bulk_Data_Editor_Access (class access only —
#     NO otorga el permission set a usuarios, eso se hace a mano)
#   Profile: Admin (visibilidad de la app/tab, class/field access)
#
# WHAT THIS DOES NOT DO:
#   - Asignar el permission set a usuarios (manual, como siempre)
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
echo "Este deploy instala Bulk Data Editor en AEBEQ producción por primera vez"
echo "(ya está instalado y verificado en SEMBEQ producción):"
echo "  - Crea Bulk_Edit_Log__c y Bulk_Edit_Snapshot__c (objetos nuevos)"
echo "  - Crea 9 clases Apex + 4 test classes"
echo "  - Crea 7 Lightning Web Components"
echo "  - Crea la app/tab/flexipage Bulk_Data_Editor"
echo "  - Crea el permission set Bulk_Data_Editor_Access (class access)"
echo "  - Actualiza el profile Admin (visibilidad app/tab, class/field access)"
echo ""
echo "NO asigna el permission set a ningún usuario — eso se hace a mano después."
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
    print("  1. Asignar el permission set Bulk_Data_Editor_Access a los usuarios que")
    print("     necesiten usar la app en AEBEQ (manual, como siempre).")
    print("  2. Verificar en producción que la app carga y un mini flujo funciona")
    print("     (search + bulk edit de prueba con Undo).")
else:
    print("\n❌ DEPLOY FAILED — Review errors above")
PYEOF
