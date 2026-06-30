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
  --test-level RunSpecifiedTests \
  --tests MergeCoverageBoostTest \
  --tests MergeExecutionControllerTest \
  --tests MergeScanServiceTest \
  --tests MergeUtilityTest \
  --tests RelatedRecordsServiceTest \
  --target-org "$TARGET_ORG"  \
  --verbose
