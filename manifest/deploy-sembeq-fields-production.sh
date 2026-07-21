#!/bin/bash
# ============================================================
# SEMBEQ Custom Fields — Deploy to Production
# ============================================================
# Deploys SEMBEQ-specific custom fields on standard objects.
#
# Usage:
#   chmod +x manifest/deploy-sembeq-fields-production.sh
#   ./manifest/deploy-sembeq-fields-production.sh production
# ============================================================

TARGET_ORG="${1:-production}"

BASE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$BASE/force-app-sembeq/main/default"

echo "================================================"
echo "  SEMBEQ Custom Fields — Deploy to Production"
echo "  Target: $TARGET_ORG"
echo "================================================"
echo ""
echo "Fields to deploy (Account):"
ls "$SRC/objects/Account/fields/" | sed 's/^/  - /'
echo ""

if [ "$TARGET_ORG" = "production" ]; then
    echo "⚠️  Deploying to PRODUCTION. Type CONFIRMAR to proceed:"
    read -r CONFIRM
    if [ "$CONFIRM" != "CONFIRMAR" ]; then
        echo "Cancelled."
        exit 0
    fi
fi

sf project deploy start \
  --source-dir "$SRC/objects" \
  --source-dir "$SRC/profiles" \
  --test-level RunSpecifiedTests \
  --tests MergeExecutionControllerTest \
  --target-org "$TARGET_ORG" \
  --verbose
