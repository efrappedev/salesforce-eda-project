#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
#  deploy-dmc-production.sh
#  Deploys the full Donation Management Center (DMC) package to AEBEQ production.
#
#  USAGE: ./manifest/deploy-dmc-production.sh
#
#  PREREQUISITE: You must be authenticated to production.
#    sf org login web --alias aebeq-prod --instance-url https://login.salesforce.com
#
#  IMPORTANT: Run Apex tests against production BEFORE using this script:
#    sf apex run test --target-org aebeq-prod --test-level RunSpecifiedTests \
#      --class-names DmcWebhookReceiverTest --result-format human --wait 10
# ═══════════════════════════════════════════════════════════════════════════════

set -e

TARGET_ORG="e.frappe@aebeq.qc.ca"
SOURCE_DIR="Donation Management Center"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          DMC Production Deploy — AEBEQ                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Target org : $TARGET_ORG"
echo "  Source dir : $SOURCE_DIR"
echo ""
echo "  Components:"
echo "    • Apex classes (DmcConfigService, DmcDonationService, DmcWebhookReceiver)"
echo "    • LWC (dmcReviewManager, dmcConnect)"
echo "    • Custom objects (DMC_Audit_Log__c, Zeffy_Review_Ticket__c,"
echo "                      Zeffy_Config__c, Zeffy_Identity__c)"
echo "    • Standard object extensions (Account, Campaign, GiftTransaction,"
echo "                                  GiftCommitment)"
echo "    • Permission Sets (Fundraising_Access, DMC_Admin_Access)"
echo "    • Custom Permission (DMC_Settings_Access)"
echo "    • App, FlexiPage, Tab"
echo ""

read -p "⚠️  Deploy to PRODUCTION? Type YES to confirm: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "▶ Deploying..."
sf project deploy start \
  --source-dir "$SOURCE_DIR" \
  --target-org "$TARGET_ORG" \
  --test-level RunSpecifiedTests \
  --tests DmcWebhookReceiverTest \
  --wait 20

echo ""
echo "✅  Deploy complete!"
echo ""
echo "Post-deploy checklist:"
echo "  1. Open the Donation Management Center app in Salesforce"
echo "  2. Verify DMC Review Manager loads correctly"
echo "  3. Assign 'Fundraising_Access' permission set to fundraising staff"
echo "  4. Assign 'DMC Admin Access' permission set to administrators"
echo "  5. Log in as admin, open DMC → Settings tab → enter Zeffy credentials"
echo "  6. Verify webhook URL in Zeffy dashboard: /dmc/webhook/receive"
