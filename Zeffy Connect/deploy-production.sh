#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
#  deploy-production.sh — Zeffy Connect → AEBEQ Production
#
#  USAGE:  ./deploy-production.sh [aebeq-prod]
#          (alias por defecto: e.frappe@aebeq.qc.ca)
#
#  PREREQUISITE: autenticado en producción AEBEQ
#    sf org login web --alias aebeq-prod --instance-url https://login.salesforce.com
#
#  NOTA: Los objetos custom deben existir en producción ANTES de correr este
#        script (Zeffy_Review_Ticket__c, Zeffy_Identity__c, Zeffy_Config__c,
#        Zeffy_Connect_Audit_Log__c, Zeffy_Webhook_Log__c, Zeffy_Fund__c).
# ═══════════════════════════════════════════════════════════════════════════════

set -e

TARGET_ORG="${1:-e.frappe@aebeq.qc.ca}"
SOURCE_DIR="Zeffy Connect"
# Solo la metadata: backups/, scripts/, manual/ y DEMO AEBEQ/ nunca se mandan al org
META_DIR="$SOURCE_DIR/main"

TEST_CLASSES=(ZeffyConnectWebhookReceiverTest ZeffyConnectConfigServiceTest ZeffyConnectLapsedDonorBatchTest
              ZeffyConnectDonationServiceTest ZeffyConnectFundServiceTest ZeffyHoldingExpireBatchTest ZeffyConnectSchedulerTest)
# One --tests flag per class: a comma-separated list runs 0 tests (seen 2026-10-19 → 0% coverage)
TEST_ARGS=()
for t in "${TEST_CLASSES[@]}"; do TEST_ARGS+=(--tests "$t"); done

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Zeffy Connect — Deploy a Producción AEBEQ           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Target org  : $TARGET_ORG"
echo "  Source dir  : $META_DIR"
echo "  Test classes: 7 clases"
echo ""
echo "  Componentes:"
echo "    • Apex: ZeffyConnectConfigService, ZeffyConnectDonationService,"
echo "            ZeffyConnectWebhookReceiver, ZeffyConnectLapsedDonorBatch,"
echo "            ZeffyHoldingExpireBatch, ZeffyConnectScheduler,"
echo "            ZeffyConnectFundService"
echo "    • LWC: zeffyConnectReviewManager, zeffyConnect"
echo "    • Objetos custom: Zeffy_Review_Ticket__c, Zeffy_Identity__c,"
echo "                      Zeffy_Config__c, Zeffy_Connect_Audit_Log__c,"
echo "                      Zeffy_Webhook_Log__c, Zeffy_Fund__c"
echo "    • Extensiones estándar: Account, Campaign, GiftTransaction, GiftCommitment"
echo "    • Permission Sets: Zeffy_Connect_Access, Zeffy_Connect_Admin_Access,"
echo "                       Fundraising_All_Records_Access"
echo "    • Custom Permission, App, FlexiPage, Tab"
echo ""

read -p "⚠️  Deploy a PRODUCCIÓN? Escribe YES para confirmar: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
  echo "Cancelado."
  exit 0
fi

# ── Jobs programados ─────────────────────────────────────────────────────────
# Mientras un job programado apunte directo a un batch, Salesforce bloquea el deploy
# ("schedulable class has jobs pending"). Desde 2026-10-01 los jobs pasan por
# ZeffyConnectScheduler (Type.forName) y ya no bloquean nada; esta pausa solo es
# necesaria la PRIMERA vez para migrar los jobs viejos. Es inofensiva después.
# Al salir (éxito, cancelación o error) se reprograman según los toggles de Settings.
SCRIPT_DIR="$SOURCE_DIR/scripts"
resume_jobs() {
  echo ""
  echo "▶ Reprogramando jobs Zeffy según Settings..."
  sf apex run --target-org "$TARGET_ORG" --file "$SCRIPT_DIR/zeffy-jobs-resume.apex" 2>&1 \
    | grep -E "ZEFFY_JOBS_RESUMED|Error" \
    || echo "  ⚠️  No se pudo reprogramar — revisar Settings → Event Processing / Lapsed Donors"
}
echo ""
echo "▶ Pausando jobs programados de Zeffy (temporal)..."
sf apex run --target-org "$TARGET_ORG" --file "$SCRIPT_DIR/zeffy-jobs-pause.apex" 2>&1 | grep -E "ZEFFY_JOBS_PAUSED|Error" || true
trap resume_jobs EXIT

echo ""
echo "▶ Corriendo dry-run (validación con tests)..."
sf project deploy start \
  --source-dir "$META_DIR" \
  --target-org "$TARGET_ORG" \
  --test-level RunSpecifiedTests \
  "${TEST_ARGS[@]}" \
  --dry-run \
  --wait 30

echo ""
read -p "✅ Dry-run exitoso. ¿Proceder con deploy real? Escribe YES: " CONFIRM2
if [ "$CONFIRM2" != "YES" ]; then
  echo "Cancelado. El dry-run ya validó la cobertura."
  exit 0
fi

echo ""
echo "▶ Deployando a producción..."
sf project deploy start \
  --source-dir "$META_DIR" \
  --target-org "$TARGET_ORG" \
  --test-level RunSpecifiedTests \
  "${TEST_ARGS[@]}" \
  --wait 30

echo ""
echo "✅  Deploy completo!"
echo ""
echo "Checklist post-deploy:"
echo "  1. Abrir la app 'Zeffy Connect' en Salesforce"
echo "  2. Verificar que Zeffy Connect Review Manager carga correctamente"
echo "  3. Asignar 'Zeffy Connect Admin Access' a los administradores"
echo "  4. Asignar 'Zeffy Connect Access' (Zeffy_Connect_Access) al personal de fundraising"
echo "  4b. Asignar 'Fundraising All Records Access' al staff de fundraising NO admin"
echo "      (ve y edita TODOS los Gift* de la org; sin él cada quien ve solo los suyos)"
echo "  5. En Settings → ingresar API Key y Webhook Secret de Zeffy"
echo "  6. Verificar URL del webhook en el dashboard de Zeffy:"
echo "     https://<tu-site>.my.salesforce-sites.com/ZeffyConnect/services/apexrest/zeffy-connect/webhook/receive"
echo ""
