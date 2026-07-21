#!/bin/bash
# =============================================================
# Deploy AEBEQ ID Generator a PRODUCCIÓN
# Org: e.frappe@aebeq.qc.ca
# Person Accounts — Account + Contact triggers, config via CMT
# =============================================================

set -e

TARGET_ORG="e.frappe@aebeq.qc.ca"

echo ""
echo "=========================================="
echo "  AEBEQ ID Generator — PRODUCCIÓN DEPLOY"
echo "  Target: $TARGET_ORG"
echo "=========================================="
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
  --tests AccountIdGeneratorTest \
  --tests ContactIdGeneratorTest \
  --test-level RunSpecifiedTests \
  --wait 15

echo ""
echo "Deploy to AEBEQ production completed."
echo ""
