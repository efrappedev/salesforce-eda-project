#!/bin/bash
# ============================================================
# Merge Manager Global V2 for EDA — Sandbox Deploy Script
# ============================================================
# Deploys the EDA-specific version of Global V2 to sandbox.
# Includes the relationship wizard (hed__Relationship__c).
# Does NOT touch Global V2 (marketplace) or any other feature.
#
# Usage:
#   chmod +x manifest/deploy-v2-eda-sandbox.sh
#   ./manifest/deploy-v2-eda-sandbox.sh
# ============================================================

TARGET_ORG="${1:-e.frappe@sembeq.qc.ca.partialdev}"

BASE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$BASE/force-app/main/default/Merge Manager Salesforce Global V2 for EDA"

echo "================================================"
echo "  Merge Manager Global V2 for EDA"
echo "  Deploy to: $TARGET_ORG"
echo "  Source: Merge Manager Salesforce Global V2 for EDA/"
echo "================================================"
echo ""
echo "Files to deploy:"
echo "  - 10 Apex classes + 5 test classes (incl. 3 new relationship tests)"
echo "  - 11 Lightning Web Components (incl. mergeWizard with relationship wizard)"
echo "  - 4 Custom Objects"
echo "  - 1 Lightning App + Tab + FlexiPage + PermissionSet"
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
  --test-level NoTestRun \
  --target-org "$TARGET_ORG" \
  --verbose
