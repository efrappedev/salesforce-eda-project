#!/bin/bash
# ============================================================
# Merge Manager Global V2 (non-EDA) — PRODUCTION Deploy
# Org: e.frappe@aebeq.qc.ca
# ============================================================
# Deploys the complete V2 non-EDA package to AEBEQ production:
#   - Apex: MergeExecutionService (fix SOQL 101) + todas las clases
#   - LWC: mergeWizard, mergeTicketList, mergeScanModal, etc.
#   - Objetos, App, Tab, FlexiPage, PermissionSet, Profile
#
# Usage:
#   chmod +x manifest/deploy-v2-production.sh
#   ./manifest/deploy-v2-production.sh
# ============================================================

set -e

TARGET_ORG="e.frappe@aebeq.qc.ca"
BASE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$BASE/force-app/main/default/Merge Manager Salesforce Global V2"

echo ""
echo "============================================================"
echo "  Merge Manager V2 (non-EDA) — PRODUCCIÓN DEPLOY"
echo "  Target: $TARGET_ORG"
echo "============================================================"
echo ""
echo "  Incluye:"
echo "    - Email rescue: guardar el correo del duplicado en un campo email vacío del principal"
echo "      (MergeWrappers, MergeController, MergeExecutionService + tests)"
echo "    - Carrusel de registros relacionados adaptable al ancho (mergeRelatedCarousel)"
echo "    - LWC actualizados (mergeComparisonMatrix, mergeWizard, i18n, etc.)"
echo "    - Objetos, App, Tab, FlexiPage, PermissionSet, Profile"
echo ""
echo "  ⚠️  Apex incluido → se corren tests especificados"
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
  --target-org "$TARGET_ORG" \
  --test-level RunSpecifiedTests \
  --tests MergeCoverageBoostTest \
  --tests MergeExecutionControllerTest \
  --tests MergeScanServiceTest \
  --tests MergeUtilityTest \
  --tests RelatedRecordsServiceTest \
  --wait 20

echo ""
echo "Deploy a AEBEQ producción completado."
echo ""
