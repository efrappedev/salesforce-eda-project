#!/bin/bash
# ============================================================
# Merge Manager Global V2 for EDA — PRODUCTION Deploy (Phase 1)
# ============================================================
# Upgrades production from the legacy V3 to Global V2 for EDA.
#
# WHAT THIS DEPLOYS:
#   Apex (15 classes):
#     - 13 updated: DataNormalizationUtil, MergeAuditService, MergeController,
#       MergeCoverageBoostTest, MergeExecutionControllerTest,
#       MergeExecutionService, MergeScanBatch, MergeScanService,
#       MergeScanServiceTest, MergeTicketService, MergeUtilityTest,
#       MergeWrappers, SnapshotService
#     - 2 NEW: RelatedRecordsService, RelatedRecordsServiceTest
#   LWC (11 components):
#     - 5 updated: mergeComparisonMatrix, mergeManager, mergeScanModal,
#       mergeTicketList, mergeWizard
#     - 6 NEW: i18n, mergeDashboard, mergeObjectConfig, mergeObjectConfigRow,
#       mergeRelatedCarousel, (mergeWizard includes EDA relationship wizard)
#   Objects:
#     - Merge_Ticket__c: +8 new fields + 3 validation rules
#     - Merge_Log__c: +11 new fields
#     - Merge_Candidate__c: +5 new fields
#     - Related_Object_Config__c: BRAND NEW object (7 fields)
#   App/Tab/FlexiPage/PermissionSet: updated to V2 EDA
#
# WHAT STAYS AFTER THIS DEPLOY (cleaned in Phase 2):
#   - EDARelatedRecordsService (now orphaned, safe to delete)
#   - EDAServiceCoverageTest   (now orphaned, safe to delete)
#
# NEXT STEP AFTER VALIDATING:
#   ./manifest/deploy-v2-eda-legacy-cleanup.sh production
#
# Usage:
#   chmod +x manifest/deploy-v2-eda-production.sh
#   ./manifest/deploy-v2-eda-production.sh production
# ============================================================

TARGET_ORG="${1:-}"
if [ -z "$TARGET_ORG" ]; then
  echo "Usage: $0 <prod-org-alias>"
  echo "Example: $0 production"
  exit 1
fi

# Safety gate — never run blindly against production
if [ "$TARGET_ORG" = "production" ] || [ "$TARGET_ORG" = "e.frappe@sembeq.qc.ca" ]; then
  echo ""
  echo "⚠️  DESTINO: PRODUCCIÓN ($TARGET_ORG)"
  echo ""
  echo "Este deploy es un UPGRADE MAYOR de la versión legacy al Global V2 for EDA."
  echo "Cambios incluidos:"
  echo "  - Crea Related_Object_Config__c (nuevo objeto completo)"
  echo "  - Agrega 24 campos nuevos a Merge_Ticket__c, Merge_Log__c, Merge_Candidate__c"
  echo "  - Instala 3 validation rules en Merge_Ticket__c"
  echo "  - Reemplaza 5 LWC legacy + agrega 6 nuevos componentes"
  echo "  - Actualiza todas las clases Apex al stack V2 EDA"
  echo ""
  echo "¿Continuar? Escribe CONFIRMAR para proceder:"
  read -r CONFIRM
  if [ "$CONFIRM" != "CONFIRMAR" ]; then
    echo "Cancelado."
    exit 0
  fi
fi

BASE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$BASE/force-app/main/default/Merge Manager Salesforce Global V2 for EDA"

echo ""
echo "========================================================"
echo "  Merge Manager Global V2 for EDA — Phase 1 DEPLOY"
echo "  Target: $TARGET_ORG"
echo "========================================================"
echo ""

sf project deploy start \
  --source-dir "$SRC/classes" \
  --source-dir "$SRC/lwc" \
  --source-dir "$SRC/objects" \
  --source-dir "$SRC/applications/Merge_Manager.app-meta.xml" \
  --source-dir "$SRC/tabs/Merge_Manager.tab-meta.xml" \
  --source-dir "$SRC/flexipages/Merge_Manager.flexipage-meta.xml" \
  --source-dir "$SRC/permissionsets/Merge_Manager_Access.permissionset-meta.xml" \
  --source-dir "$SRC/profiles" \
  --test-level RunSpecifiedTests \
  --tests MergeCoverageBoostTest \
  --tests MergeExecutionControllerTest \
  --tests MergeScanServiceTest \
  --tests MergeUtilityTest \
  --tests RelatedRecordsServiceTest \
  --target-org "$TARGET_ORG" \
  --verbose

echo ""
echo "========================================================"
echo "  Coverage Report"
echo "========================================================"
sf project deploy report --use-most-recent --target-org "$TARGET_ORG" --json 2>/dev/null | python3 << 'PYEOF'
import json, sys
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except:
    sys.exit(0)
result = data.get('result', {})
tests  = result.get('details', {}).get('runTestResult', {})
coverage = tests.get('codeCoverage', [])
if isinstance(coverage, dict):
    coverage = [coverage]
if not coverage:
    sys.exit(0)
merge_classes = {
    'DataNormalizationUtil','MergeAuditService','MergeController',
    'MergeExecutionService','MergeScanBatch','MergeScanService',
    'MergeTicketService','MergeWrappers','RelatedRecordsService','SnapshotService'
}
own = [c for c in coverage if c.get('name','') in merge_classes]
print(f"  {'Clase':<45} {'Cov':>9}  {'%':>6}")
print(f"  {'─'*58}")
tl = tc = 0
for c in sorted(own, key=lambda x: x.get('name','')):
    name  = c.get('name','')
    locs  = int(c.get('numLocations', 0))
    uncov = int(c.get('numLocationsNotCovered', 0))
    cov   = locs - uncov
    tl += locs; tc += cov
    pct  = cov / locs * 100 if locs else 100.0
    flag = '' if pct >= 99.9 else (' ⚠️  <75%' if pct < 75 else ' ◀')
    print(f"  {name:<45} {cov:>4}/{locs:<4}  {pct:>5.1f}%{flag}")
if tl:
    overall = tc / tl * 100
    print(f"  {'─'*58}")
    print(f"  {'TOTAL':<45} {tc:>4}/{tl:<4}  {overall:>5.1f}%")
    print()
    print(f"  {'✅' if overall >= 75 else '❌'} Cobertura: {overall:.1f}%")
    print()
    print("  Próximos pasos:")
    print("    1. Validar que la app carga en producción")
    print("    2. Probar un scan y merge en producción")
    print("    3. Limpiar clases legacy (Phase 2):")
    print("       ./manifest/deploy-v2-eda-legacy-cleanup.sh production")
PYEOF