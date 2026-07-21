#!/bin/bash
# =============================================================
# Deploy AEBEQ ID Generator a sandbox partialae
# Org: e.frappe@aebeq.qc.ca.partialae
# Person Accounts — Account + Contact triggers, config via CMT
# =============================================================

set -e

TARGET_ORG="e.frappe@aebeq.qc.ca.partialae"

echo ""
echo "========================================"
echo "  AEBEQ ID Generator — SANDBOX DEPLOY"
echo "  Target: $TARGET_ORG"
echo "========================================"
echo ""

sf project deploy start \
  --source-dir "force-app-aebeq/main/default/labels/CustomLabels.labels-meta.xml" \
  --source-dir "force-app-aebeq/main/default/objects/Account/fields/ID_Account__c.field-meta.xml" \
  --source-dir "force-app-aebeq/main/default/objects/Contact/fields/ID_Contact__c.field-meta.xml" \
  --source-dir "force-app-aebeq/main/default/objects/AccountIdGenConfig__mdt" \
  --source-dir "force-app-aebeq/main/default/triggers/Account_GenerateID.trigger" \
  --source-dir "force-app-aebeq/main/default/triggers/Contact_GenerateID.trigger" \
  --source-dir "force-app-aebeq/main/default/classes/AccountIdGeneratorTest.cls" \
  --source-dir "force-app-aebeq/main/default/classes/ContactIdGeneratorTest.cls" \
  --target-org "$TARGET_ORG" \
  --test-level NoTestRun \
  --wait 10

echo ""
echo "Deploy to sandbox completed."
echo "Run tests next:"
echo ""
echo "  sf apex run test --target-org \"$TARGET_ORG\" \\"
echo "    --tests AccountIdGeneratorTest \\"
echo "    --tests ContactIdGeneratorTest \\"
echo "    --code-coverage --result-format human --wait 10"
echo ""
