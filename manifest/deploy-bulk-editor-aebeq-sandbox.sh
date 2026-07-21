#!/bin/bash
# =============================================================
# Deploy Bulk Data Editor a sandbox AEBEQ
# Org: e.frappe@aebeq.qc.ca.partialae
# App genérica: mass field-value replacement con undo + audit trail
# Compatible con SEMBEQ y AEBEQ (sin dependencias EDA)
# =============================================================

set -e

TARGET_ORG="e.frappe@aebeq.qc.ca.partialae"
SOURCE_DIR="force-app/main/default/Bulk Data Editor"

echo ""
echo "========================================"
echo "  Bulk Data Editor — SANDBOX DEPLOY"
echo "  Target: $TARGET_ORG"
echo "========================================"
echo ""

sf project deploy start \
  --source-dir "$SOURCE_DIR" \
  --target-org "$TARGET_ORG" \
  --test-level NoTestRun \
  --wait 15

echo ""
echo "Deploy to sandbox completed."
echo "Run tests next:"
echo ""
echo "  sf apex run test --target-org \"$TARGET_ORG\" \\"
echo "    --class-names BulkEditControllerTest \\"
echo "    --class-names BulkEditBatchTest \\"
echo "    --code-coverage --result-format human --wait 15"
echo ""
