#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
#  Zeffy Connect — Test Webhook (interactive)
#  Simula un webhook de Zeffy firmado con HMAC-SHA256 y lo envía al endpoint
#  de Salesforce Site. Cero efecto en Zeffy — solo Salesforce lo recibe.
#
#  Uso:  chmod +x test_webhook.sh && ./test_webhook.sh
# ══════════════════════════════════════════════════════════════════════════════

# ── CONFIGURACIÓN (llenar antes de correr) ───────────────────────────────────
WEBHOOK_SECRET="PEGA_TU_WEBHOOK_SECRET_AQUI"
ENDPOINT_URL="PEGA_LA_URL_DEL_SITE_AQUI/zeffy-connect/webhook/receive"
# Ejemplo de ENDPOINT_URL:
#   https://CHANGE-ME-sembeq--partialdev.sandbox.my.site.com/zeffy-connect/webhook/receive
# ─────────────────────────────────────────────────────────────────────────────

# Colores
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

divider() { echo -e "${CYAN}────────────────────────────────────────${RESET}"; }

# Verificar dependencias
if ! command -v openssl &>/dev/null; then echo -e "${RED}Error: openssl no encontrado.${RESET}"; exit 1; fi
if ! command -v curl &>/dev/null;    then echo -e "${RED}Error: curl no encontrado.${RESET}"; exit 1; fi

# Verificar configuración
if [[ "$WEBHOOK_SECRET" == *"PEGA"* ]] || [[ "$ENDPOINT_URL" == *"PEGA"* ]]; then
  echo -e "${RED}⚠  Configura WEBHOOK_SECRET y ENDPOINT_URL al inicio del script antes de correr.${RESET}"
  exit 1
fi

clear
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   Zeffy Connect — Simulador de Webhook   ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""

# ── 1. Tipo de evento ────────────────────────────────────────────────────────
divider
echo -e "${BOLD}Tipo de evento Zeffy:${RESET}"
echo "  1) payment.completed  — donación confirmada por Stripe (siempre procesada)"
echo "  2) payment.created    — formulario enviado antes de confirmación"
echo "  3) payment.updated    — Zeffy actualiza campos (receipt URL, status, etc.)"
echo "  4) payment.deleted    — pago cancelado / rechazado"
echo ""
read -p "Elige [1-4]: " EVT_CHOICE

case "$EVT_CHOICE" in
  1) EVENT_TYPE="payment.completed";  TX_STATUS="succeeded" ;;
  2) EVENT_TYPE="payment.created";    TX_STATUS="pending"   ;;
  3) EVENT_TYPE="payment.updated"
     echo ""
     echo "  Status a enviar:"
     echo "    1) succeeded   — pago confirmado (gradúa Holding → Pending Review)"
     echo "    2) processing  — en proceso"
     echo "    3) refunded    — reembolsado"
     read -p "  Elige [1-3, default=1]: " ST_CHOICE
     case "$ST_CHOICE" in
       2) TX_STATUS="processing" ;;
       3) TX_STATUS="refunded"   ;;
       *) TX_STATUS="succeeded"  ;;
     esac ;;
  4) EVENT_TYPE="payment.deleted";    TX_STATUS="deleted"   ;;
  *) echo -e "${RED}Opción inválida.${RESET}"; exit 1 ;;
esac

# ── 2. Datos del donante ─────────────────────────────────────────────────────
divider
echo -e "${BOLD}Datos del donante ficticio:${RESET}"
echo "(Presiona Enter para aceptar el valor por defecto)"
echo ""
read -p "  Nombre      [John]:         " FIRST;  FIRST="${FIRST:-John}"
read -p "  Apellido    [Doe]:           " LAST;   LAST="${LAST:-Doe}"
read -p "  Email       [john.doe@test.com]: " EMAIL; EMAIL="${EMAIL:-john.doe@test.com}"
read -p "  Teléfono    []:             " PHONE
read -p "  Ciudad      [Montréal]:     " CITY;   CITY="${CITY:-Montréal}"
read -p "  Provincia   [QC]:           " PROV;   PROV="${PROV:-QC}"
read -p "  País        [CA]:           " COUNTRY; COUNTRY="${COUNTRY:-CA}"

# ── 3. Datos del pago ────────────────────────────────────────────────────────
divider
echo -e "${BOLD}Datos del pago:${RESET}"
echo ""
read -p "  Monto en \$ [10]:            " AMOUNT_DOLLARS; AMOUNT_DOLLARS="${AMOUNT_DOLLARS:-10}"
AMOUNT_CENTS=$(echo "$AMOUNT_DOLLARS * 100" | bc | cut -d. -f1)

read -p "  Moneda      [CAD]:           " CURRENCY; CURRENCY="${CURRENCY:-CAD}"
read -p "  Método pago [credit_card]:   " PAYMENT_METHOD; PAYMENT_METHOD="${PAYMENT_METHOD:-credit_card}"

read -p "  ¿Recurrente? [n/s, default=n]: " IS_REC_INPUT
if [[ "$IS_REC_INPUT" =~ ^[sS]$ ]]; then
  IS_RECURRING="true"
  read -p "  Frecuencia  [monthly]:       " SUB_FREQ; SUB_FREQ="${SUB_FREQ:-monthly}"
else
  IS_RECURRING="false"
  SUB_FREQ=""
fi

read -p "  Nombre del formulario [Test Form]: " FORM_NAME; FORM_NAME="${FORM_NAME:-Test Form}"

# ── 4. Transaction ID ────────────────────────────────────────────────────────
divider
echo -e "${BOLD}Transaction ID:${RESET}"
DEFAULT_TX="TEST-$(date +%Y%m%d-%H%M%S)"
read -p "  ID de transacción [$DEFAULT_TX]: " TX_ID; TX_ID="${TX_ID:-$DEFAULT_TX}"

# ── 5. Construir payload JSON ────────────────────────────────────────────────
TIMESTAMP=$(date +%s)
CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [[ -z "$SUB_FREQ" ]]; then
  SUB_FREQ_JSON="null"
else
  SUB_FREQ_JSON="\"$SUB_FREQ\""
fi

PAYLOAD=$(cat <<JSON
{
  "type": "$EVENT_TYPE",
  "data": {
    "id": "$TX_ID",
    "status": "$TX_STATUS",
    "amount": $AMOUNT_CENTS,
    "currency": "$CURRENCY",
    "payment_method": "$PAYMENT_METHOD",
    "receipt_url": "",
    "refund_status": null,
    "created_at": "$CREATED_AT",
    "buyer": {
      "first_name": "$FIRST",
      "last_name": "$LAST",
      "email": "$EMAIL",
      "phone": "$PHONE",
      "address": "",
      "city": "$CITY",
      "state": "$PROV",
      "zip_code": "",
      "country": "$COUNTRY",
      "language": "fr",
      "zeffy_contact_id": null
    },
    "items": [
      {
        "id": "ITEM-$TX_ID",
        "form_id": "FORM-TEST-001",
        "form_name": "$FORM_NAME",
        "amount": $AMOUNT_CENTS,
        "eligible_amount": $AMOUNT_CENTS,
        "is_recurring": $IS_RECURRING,
        "subscription_frequency": $SUB_FREQ_JSON,
        "fund_id": null,
        "fund_name": null,
        "fund_code": null,
        "campaign_category": null,
        "rate_title": null
      }
    ],
    "dispute": null,
    "refunds": []
  }
}
JSON
)

# ── 6. Firmar con HMAC-SHA256 ────────────────────────────────────────────────
SIGNED_CONTENT="${TIMESTAMP}.${PAYLOAD}"
SIGNATURE=$(echo -n "$SIGNED_CONTENT" | openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" | awk '{print $2}')
ZEFFY_HEADER="t=${TIMESTAMP},v1=${SIGNATURE}"

# ── 7. Resumen antes de enviar ───────────────────────────────────────────────
divider
echo ""
echo -e "${BOLD}Resumen del webhook a enviar:${RESET}"
echo ""
echo -e "  Evento:        ${YELLOW}${EVENT_TYPE}${RESET}"
echo -e "  Donante:       ${BOLD}${FIRST} ${LAST}${RESET} (${EMAIL})"
echo -e "  Monto:         ${GREEN}\$${AMOUNT_DOLLARS} ${CURRENCY}${RESET}"
echo -e "  Recurrente:    ${IS_RECURRING}  ${SUB_FREQ:+(${SUB_FREQ})}"
echo -e "  TX ID:         ${CYAN}${TX_ID}${RESET}"
echo -e "  Status Zeffy:  ${TX_STATUS}"
echo -e "  Endpoint:      ${ENDPOINT_URL}"
echo ""
read -p "¿Enviar? [s/N]: " CONFIRM

if [[ ! "$CONFIRM" =~ ^[sS]$ ]]; then
  echo "Cancelado."
  exit 0
fi

# ── 8. POST ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Enviando...${RESET}"
echo ""

HTTP_RESPONSE=$(curl -s -w "\n__HTTP_STATUS__%{http_code}" \
  -X POST "$ENDPOINT_URL" \
  -H "Content-Type: application/json" \
  -H "Zeffy-Signature: $ZEFFY_HEADER" \
  -d "$PAYLOAD")

HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -1 | sed 's/__HTTP_STATUS__//')

divider
echo -e "${BOLD}Respuesta:${RESET}"
echo ""
echo -e "  HTTP Status: ${BOLD}${HTTP_STATUS}${RESET}"
echo ""
echo "$HTTP_BODY" | python3 -m json.tool 2>/dev/null || echo "$HTTP_BODY"
echo ""

if [[ "$HTTP_STATUS" == "200" ]]; then
  echo -e "${GREEN}✓ Webhook procesado. Revisa Robot Health en Zeffy Connect para ver el log.${RESET}"
else
  echo -e "${RED}✗ Error HTTP ${HTTP_STATUS}${RESET}"
fi

echo ""
