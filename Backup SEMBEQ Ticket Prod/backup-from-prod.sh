#!/bin/bash
# ============================================================
# SEMBEQ Ticket Backup — Production → local data/
# ============================================================
# Exports Merge_Ticket__c, Merge_Candidate__c, Merge_Log__c,
# and Related_Object_Config__c from SEMBEQ production to JSON
# files that restore-to-sandbox.sh can import.
#
# Usage:
#   chmod +x "Backup SEMBEQ Ticket Prod/backup-from-prod.sh"
#   cd "Backup SEMBEQ Ticket Prod" && ./backup-from-prod.sh
# ============================================================

PROD="production"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
mkdir -p "$DATA_DIR"

echo ""
echo "========================================================"
echo "  SEMBEQ Ticket Backup — Producción → $DATA_DIR"
echo "========================================================"
echo ""

# Nota: producción tiene esquema V3 legacy (campos V2 se agregan con el deploy).
# Solo se exportan los campos que realmente existen en producción hoy.

# ── Merge_Ticket__c (V3: Status__c, Object_Type__c, Match_Type__c) ───────────
echo "📦 Exportando Merge_Ticket__c..."
sf data query \
  --query "SELECT Id, Status__c, Object_Type__c, Match_Type__c FROM Merge_Ticket__c ORDER BY CreatedDate ASC" \
  --target-org "$PROD" \
  --json 2>/dev/null > "$DATA_DIR/tickets_raw.json"

TICKET_COUNT=$(python3 -c "
import json
try:
    d = json.load(open('$DATA_DIR/tickets_raw.json'))
    print(d.get('result', {}).get('totalSize', 0))
except:
    print('ERROR')
")
echo "   ✅ $TICKET_COUNT tickets"

# ── Merge_Candidate__c (V3: Merge_Ticket__c, Record_Id__c) ───────────────────
echo "📦 Exportando Merge_Candidate__c..."
sf data query \
  --query "SELECT Id, Merge_Ticket__c, Record_Id__c FROM Merge_Candidate__c ORDER BY Merge_Ticket__c, CreatedDate ASC" \
  --target-org "$PROD" \
  --json 2>/dev/null > "$DATA_DIR/candidates_raw.json"

CAND_COUNT=$(python3 -c "
import json
try:
    d = json.load(open('$DATA_DIR/candidates_raw.json'))
    print(d.get('result', {}).get('totalSize', 0))
except:
    print('ERROR')
")
echo "   ✅ $CAND_COUNT candidates"

# ── Merge_Log__c (V3: Action_Type__c, Object_Type__c, Master_Record_Id__c) ───
# Nota: V3 no tiene Merge_Ticket__c en Merge_Log__c — se restauran sin link a ticket.
echo "📦 Exportando Merge_Log__c..."
sf data query \
  --query "SELECT Id, Action_Type__c, Object_Type__c, Master_Record_Id__c FROM Merge_Log__c ORDER BY CreatedDate ASC" \
  --target-org "$PROD" \
  --json 2>/dev/null > "$DATA_DIR/logs_raw.json"

LOG_COUNT=$(python3 -c "
import json
try:
    d = json.load(open('$DATA_DIR/logs_raw.json'))
    print(d.get('result', {}).get('totalSize', 0))
except:
    print('ERROR')
")
echo "   ✅ $LOG_COUNT logs"

# ── Related_Object_Config__c — no existe en V3, se omite ─────────────────────
echo "📦 Related_Object_Config__c — no existe en producción V3, se omite"
echo '{"status":0,"result":{"totalSize":0,"done":true,"records":[]}}' > "$DATA_DIR/config_raw.json"
CONFIG_COUNT=0

echo ""
echo "========================================================"
printf "  Backup completo — %s tickets  %s candidates  %s logs  %s configs\n" \
    "$TICKET_COUNT" "$CAND_COUNT" "$LOG_COUNT" "$CONFIG_COUNT"
echo "  Archivos en: $DATA_DIR"
echo ""
echo "  Próximo paso:"
echo "    ./restore-to-sandbox.sh"
echo "========================================================"
echo ""
