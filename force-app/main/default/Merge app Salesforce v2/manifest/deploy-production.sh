#!/bin/bash
# ============================================================
# Merge Manager — Production Deploy Script
# ============================================================
# Deploys ONLY the Merge Manager application.
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
SRC="$BASE/force-app/main/default"

echo "================================================"
echo "  Merge Manager — Deploy to: $TARGET_ORG"
echo "================================================"
echo ""
echo "Files to deploy:"
echo "  - 10 Apex classes + 5 test classes"
echo "  - 5 Lightning Web Components"
echo "  - 3 Custom Objects (Merge_Ticket__c, Merge_Candidate__c, Merge_Log__c)"
echo "  - 1 Lightning App + Tab + FlexiPage (Merge_Manager)"
echo ""
echo "NOT deploying:"
echo "  - Contact_Record_Page (untouched)"
echo "  - Account_Record_Page (untouched)"
echo "  - Any other existing production metadata"
echo ""

sf project deploy start \
  --source-dir "$SRC/classes/DataNormalizationUtil.cls" \
  --source-dir "$SRC/classes/DataNormalizationUtil.cls-meta.xml" \
  --source-dir "$SRC/classes/EDARelatedRecordsService.cls" \
  --source-dir "$SRC/classes/EDARelatedRecordsService.cls-meta.xml" \
  --source-dir "$SRC/classes/MergeAuditService.cls" \
  --source-dir "$SRC/classes/MergeAuditService.cls-meta.xml" \
  --source-dir "$SRC/classes/MergeController.cls" \
  --source-dir "$SRC/classes/MergeController.cls-meta.xml" \
  --source-dir "$SRC/classes/MergeExecutionService.cls" \
  --source-dir "$SRC/classes/MergeExecutionService.cls-meta.xml" \
  --source-dir "$SRC/classes/MergeScanBatch.cls" \
  --source-dir "$SRC/classes/MergeScanBatch.cls-meta.xml" \
  --source-dir "$SRC/classes/MergeScanService.cls" \
  --source-dir "$SRC/classes/MergeScanService.cls-meta.xml" \
  --source-dir "$SRC/classes/MergeTicketService.cls" \
  --source-dir "$SRC/classes/MergeTicketService.cls-meta.xml" \
  --source-dir "$SRC/classes/MergeWrappers.cls" \
  --source-dir "$SRC/classes/MergeWrappers.cls-meta.xml" \
  --source-dir "$SRC/classes/SnapshotService.cls" \
  --source-dir "$SRC/classes/SnapshotService.cls-meta.xml" \
  --source-dir "$SRC/classes/EDAServiceCoverageTest.cls" \
  --source-dir "$SRC/classes/EDAServiceCoverageTest.cls-meta.xml" \
  --source-dir "$SRC/classes/MergeCoverageBoostTest.cls" \
  --source-dir "$SRC/classes/MergeCoverageBoostTest.cls-meta.xml" \
  --source-dir "$SRC/classes/MergeExecutionControllerTest.cls" \
  --source-dir "$SRC/classes/MergeExecutionControllerTest.cls-meta.xml" \
  --source-dir "$SRC/classes/MergeScanServiceTest.cls" \
  --source-dir "$SRC/classes/MergeScanServiceTest.cls-meta.xml" \
  --source-dir "$SRC/classes/MergeUtilityTest.cls" \
  --source-dir "$SRC/classes/MergeUtilityTest.cls-meta.xml" \
  --source-dir "$SRC/lwc/mergeComparisonMatrix" \
  --source-dir "$SRC/lwc/mergeManager" \
  --source-dir "$SRC/lwc/mergeScanModal" \
  --source-dir "$SRC/lwc/mergeTicketList" \
  --source-dir "$SRC/lwc/mergeWizard" \
  --source-dir "$SRC/objects/Merge_Ticket__c" \
  --source-dir "$SRC/objects/Merge_Candidate__c" \
  --source-dir "$SRC/objects/Merge_Log__c" \
  --source-dir "$SRC/applications/Merge_Manager.app-meta.xml" \
  --source-dir "$SRC/tabs/Merge_Manager.tab-meta.xml" \
  --source-dir "$SRC/flexipages/Merge_Manager.flexipage-meta.xml" \
  --source-dir "$SRC/permissionsets/Merge_Manager_Access.permissionset-meta.xml" \
  --test-level RunSpecifiedTests \
  --tests EDAServiceCoverageTest \
  --tests MergeCoverageBoostTest \
  --tests MergeExecutionControllerTest \
  --tests MergeScanServiceTest \
  --tests MergeUtilityTest \
  --target-org "$TARGET_ORG"  \
  --verbose
