#!/bin/bash
# ============================================================
# SEMBEQ — Permission Sets Deploy Script
# ============================================================
# Deploys ONLY the SEMBEQ permission sets to production.
# Does NOT touch any other metadata.
#
# Permission Sets deployed:
#   - EDA_Staff_Access  (full EDA access for academic staff)
#   - Reception         (basic access for reception staff)
#
# Usage:
#   chmod +x manifest/deploy-permission-sets-production.sh
#   ./manifest/deploy-permission-sets-production.sh <prod-org-alias>
#
# Example:
#   ./manifest/deploy-permission-sets-production.sh production
# ============================================================

TARGET_ORG="${1:-}"
if [ -z "$TARGET_ORG" ]; then
  echo "Usage: $0 <prod-org-alias>"
  echo "Example: $0 production"
  exit 1
fi

BASE="$(cd "$(dirname "$0")/.." && pwd)"
PS_DIR="$BASE/force-app/main/default/permissionsets"

echo "================================================"
echo "  SEMBEQ Permission Sets — Deploy to: $TARGET_ORG"
echo "================================================"
echo ""
echo "Permission Sets to deploy:"
echo "  - EDA_Staff_Access  (full EDA access for academic staff)"
echo "  - Reception         (basic access for reception staff)"
echo ""
echo "NOT deploying:"
echo "  - Any Apex classes, LWC, objects, or other metadata"
echo ""

sf project deploy start \
  --source-dir "$PS_DIR/EDA_Staff_Access.permissionset-meta.xml" \
  --source-dir "$PS_DIR/Reception.permissionset-meta.xml" \
  --test-level RunSpecifiedTests \
  --tests MergeExecutionControllerTest \
  --target-org "$TARGET_ORG" \
  --verbose
