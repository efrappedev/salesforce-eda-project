#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
#  deploy-production.sh — Zeffy Connect SEMBEQ → SEMBEQ Production
#
#  USO:    ./"Zeffy Connect SEMBEQ"/deploy-production.sh [alias]
#          (alias por defecto: production = e.frappe@sembeq.qc.ca)
#          Correr desde la raíz del repo.
#
#  PRERREQUISITOS (en este orden):
#    1. Fundraising SEMBEQ (force-app-sembeq) ya en producción:
#       Gift_Transaction__c, Gift_Commitment__c, Gift_Designation__c, etc.,
#       incluyendo los campos Annotation__c, Language__c, Note__c, Rate_Title__c,
#       Receipt_URL__c, Eligible_Amount__c, Payment_Type__c en Gift_Transaction__c.
#    2. Campos Account: Email_Address__c, Email_Personal__c, Alternative_Phone__c.
#    3. Campo Campaign: Gift_Designation__c.
#
#  SEMBEQ (EDA, sin Person Accounts):
#    • Donante individual = Contact + su Administrative Account (EDA)
#    • Iglesia (Eglise) / Organisme / Business_Organization = Account sin Contact
#    • Gifts → Gift_Transaction__c / Gift_Commitment__c (custom, no NPC)
# ═══════════════════════════════════════════════════════════════════════════════

set -e

TARGET_ORG="${1:-production}"
SOURCE_DIR="Zeffy Connect SEMBEQ"

TEST_CLASSES="ZeffyConnectWebhookReceiverTest,ZeffyConnectConfigServiceTest,ZeffyConnectLapsedDonorBatchTest,ZeffyConnectDonationServiceTest,ZeffyConnectFundServiceTest,ZeffyHoldingExpireBatchTest,ZeffyConnectSchedulerTest"

ORG_USER=$(sf org display --target-org "$TARGET_ORG" --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['result'].get('username',''))" || true)

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║      Zeffy Connect SEMBEQ — Deploy a Producción SEMBEQ       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Target org  : $TARGET_ORG  ($ORG_USER)"
echo "  Source dir  : $SOURCE_DIR"
echo "  Test classes: 7 clases"
echo ""

if [[ "$ORG_USER" != *"@sembeq.qc.ca" ]]; then
  echo "❌ El alias '$TARGET_ORG' no apunta a producción SEMBEQ ($ORG_USER). Abortando."
  exit 1
fi

echo "▶ Verificando prerrequisitos (Fundraising SEMBEQ)..."
MISSING=$(sf data query --target-org "$TARGET_ORG" --use-tooling-api --json \
  -q "SELECT QualifiedApiName FROM FieldDefinition WHERE EntityDefinition.QualifiedApiName = 'Gift_Transaction__c' AND QualifiedApiName IN ('Annotation__c','Language__c','Note__c','Rate_Title__c','Receipt_URL__c','Eligible_Amount__c','Payment_Type__c','Donor_Account__c')" 2>/dev/null \
  | python3 -c "
import sys,json
try:
    got={r['QualifiedApiName'] for r in json.load(sys.stdin)['result']['records']}
except Exception:
    got=set()
need={'Annotation__c','Language__c','Note__c','Rate_Title__c','Receipt_URL__c','Eligible_Amount__c','Payment_Type__c','Donor_Account__c'}
print(' '.join(sorted(need-got)))")
if [ -n "$MISSING" ]; then
  echo "❌ Faltan en Gift_Transaction__c: $MISSING"
  echo "   Deployar primero Fundraising SEMBEQ (force-app-sembeq)."
  exit 1
fi
echo "   OK"
echo ""

read -p "⚠️  Deploy a PRODUCCIÓN SEMBEQ? Escribe YES para confirmar: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
  echo "Cancelado."
  exit 0
fi

echo ""
echo "▶ Dry-run (validación con tests)..."
sf project deploy start \
  --source-dir "$SOURCE_DIR" \
  --target-org "$TARGET_ORG" \
  --test-level RunSpecifiedTests \
  --tests "$TEST_CLASSES" \
  --coverage-formatters json-summary \
  --results-dir "/tmp/zeffy-sembeq-coverage" \
  --dry-run \
  --wait 30

echo ""
echo "▶ Cobertura por clase:"
python3 - <<'PY'
import json, glob
files = glob.glob('/tmp/zeffy-sembeq-coverage/coverage/coverage-summary.json')
if not files:
    print("   (no se encontró el resumen de cobertura)")
else:
    data = json.load(open(files[0]))
    for k, v in sorted(data.items()):
        if k == 'total':
            continue
        name = k.split('/')[-1]
        if name.startswith('Zeffy'):
            print(f"   {name:45s} {v['lines']['pct']:6.1f}%")
PY

echo ""
read -p "✅ Dry-run exitoso. ¿Proceder con deploy real? Escribe YES: " CONFIRM2
if [ "$CONFIRM2" != "YES" ]; then
  echo "Cancelado. El dry-run ya validó la cobertura."
  exit 0
fi

echo ""
echo "▶ Deployando a producción SEMBEQ..."
sf project deploy start \
  --source-dir "$SOURCE_DIR" \
  --target-org "$TARGET_ORG" \
  --test-level RunSpecifiedTests \
  --tests "$TEST_CLASSES" \
  --wait 30

echo ""
echo "✅  Deploy completo!"
echo ""
echo "Checklist post-deploy (pasos manuales):"
echo "  1. Custom Notification Type para alertas de Zeffy"
echo "  2. Crear/activar el Site 'zeffy-connect' y dar acceso Apex al Guest User"
echo "     (ZeffyConnectWebhookReceiver)"
echo "  3. Asignar 'Zeffy Connect Access' al personal y 'Zeffy Connect Admin Access' a admins"
echo "  4. Abrir la app 'Zeffy Connect' → Settings → API Key y Webhook Secret de Zeffy"
echo "  5. Configurar el webhook en el dashboard de Zeffy (SEMBEQ):"
echo "     https://<site-sembeq>.my.salesforce-sites.com/zeffy-connect/webhook/receive"
echo ""
