#!/bin/bash
# ============================================================
# Merge Manager — Production Deploy Script
# ============================================================
# Deploys ONLY the Merge Manager application, from the canonical
# source: "Merge Manager Salesforce Global V2/".
# Does NOT touch Contact pages, Account pages, other LWC,
# other Apex classes, or any other existing production feature.
#
# Usage:
#   chmod +x manifest/deploy-production.sh
#   ./manifest/deploy-production.sh <prod-org-alias>
#
# Example:
#   ./manifest/deploy-production.sh production
# ============================================================

TARGET_ORG="${1:-}"
if [ -z "$TARGET_ORG" ]; then
  echo "Usage: $0 <prod-org-alias>"
  echo "Example: $0 production"
  exit 1
fi

BASE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$BASE/force-app/main/default/Merge Manager Salesforce Global V2"

echo "================================================"
echo "  Merge Manager — Deploy to: $TARGET_ORG"
echo "  Source: Merge Manager Salesforce Global V2/"
echo "================================================"
echo ""
echo "Files to deploy:"
echo "  - 10 Apex classes + 5 test classes"
echo "  - 10 Lightning Web Components (incl. mergeDashboard, i18n,"
echo "    mergeObjectConfig/Row, mergeRelatedCarousel)"
echo "  - 4 Custom Objects (Merge_Ticket__c, Merge_Candidate__c,"
echo "    Merge_Log__c, Related_Object_Config__c)"
echo "  - 1 Lightning App + Tab + FlexiPage (Merge_Manager)"
echo ""
echo "NOT deploying:"
echo "  - Contact_Record_Page (untouched)"
echo "  - Account_Record_Page (untouched)"
echo "  - Any other existing production metadata"
echo "  - Legacy copies (force-app/main/default/classes|lwc, V1)"
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
PYEOF
