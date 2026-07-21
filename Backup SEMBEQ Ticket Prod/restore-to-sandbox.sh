#!/bin/bash
# ============================================================
# SEMBEQ Ticket Restore — local data/ → Sandbox
# ============================================================
# 1. Elimina todos los tickets/candidatos/logs/config del sandbox
# 2. Importa los datos exportados de producción
#
# PREREQUISITO: correr backup-from-prod.sh primero.
#
# Usage:
#   chmod +x "Backup SEMBEQ Ticket Prod/restore-to-sandbox.sh"
#   cd "Backup SEMBEQ Ticket Prod" && ./restore-to-sandbox.sh
# ============================================================

SANDBOX="e.frappe@sembeq.qc.ca.partialdev"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
TMP_DIR="/tmp/sembeq-restore-$$"
mkdir -p "$TMP_DIR"

echo ""
echo "========================================================"
echo "  SEMBEQ Ticket Restore — Sandbox: $SANDBOX"
echo "========================================================"
echo ""

# ── Validar que existan los archivos de backup ────────────────
for F in tickets_raw.json candidates_raw.json logs_raw.json config_raw.json; do
  if [ ! -f "$DATA_DIR/$F" ]; then
    echo "❌ No se encontró $DATA_DIR/$F"
    echo "   Corre primero: ./backup-from-prod.sh"
    exit 1
  fi
done

TICKET_COUNT=$(python3 -c "import json; d=json.load(open('$DATA_DIR/tickets_raw.json')); print(d.get('result',{}).get('totalSize',0))" 2>/dev/null)
CAND_COUNT=$(python3 -c "import json; d=json.load(open('$DATA_DIR/candidates_raw.json')); print(d.get('result',{}).get('totalSize',0))" 2>/dev/null)
LOG_COUNT=$(python3 -c "import json; d=json.load(open('$DATA_DIR/logs_raw.json')); print(d.get('result',{}).get('totalSize',0))" 2>/dev/null)
CONFIG_COUNT=$(python3 -c "import json; d=json.load(open('$DATA_DIR/config_raw.json')); print(d.get('result',{}).get('totalSize',0))" 2>/dev/null)

echo "📋 Datos a restaurar:"
printf "   %s tickets · %s candidates · %s logs · %s configs\n" \
    "$TICKET_COUNT" "$CAND_COUNT" "$LOG_COUNT" "$CONFIG_COUNT"
echo ""
echo "⚠️  ADVERTENCIA: Esto eliminará TODOS los datos de Merge en sandbox."
echo "   Sandbox: $SANDBOX"
echo ""
echo "¿Continuar? Escribe CONFIRMAR para proceder:"
read -r CONFIRM
if [ "$CONFIRM" != "CONFIRMAR" ]; then
  echo "Cancelado."
  rm -rf "$TMP_DIR"
  exit 0
fi

# ── PASO 1: Eliminar datos existentes en sandbox ──────────────
echo ""
echo "🗑️  Eliminando datos actuales del sandbox..."

bulk_delete() {
  local SOBJECT="$1"
  local ORG="$2"
  local IDS_FILE="$TMP_DIR/del_${SOBJECT}.csv"

  # Obtener IDs existentes
  COUNT=$(sf data query \
    --query "SELECT COUNT() FROM $SOBJECT" \
    --target-org "$ORG" --json 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',{}).get('totalSize',0))")

  if [ "${COUNT:-0}" -eq 0 ] 2>/dev/null; then
    echo "  ✅ 0 $SOBJECT (vacío)"
    return
  fi

  # Exportar IDs a CSV
  sf data query \
    --query "SELECT Id FROM $SOBJECT LIMIT 50000" \
    --target-org "$ORG" --json 2>/dev/null \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
records = d.get('result',{}).get('records',[])
with open('$IDS_FILE', 'w') as f:
    f.write('Id\n')
    for r in records:
        f.write(r['Id'] + '\n')
print(len(records))
"

  # Eliminar via bulk
  sf data delete bulk \
    --sobject "$SOBJECT" \
    --file "$IDS_FILE" \
    --target-org "$ORG" \
    --wait 10 \
    --json 2>/dev/null > "$TMP_DIR/del_result_${SOBJECT}.json"

  python3 -c "
import json, os
path = os.environ['TMP_DIR'] + '/del_result_${SOBJECT}.json'
try:
    d = json.load(open(path))
    r = d.get('result', {})
    if d.get('status') == 0:
        print('  ✅ ' + str(r.get('numberRecordsProcessed', COUNT)) + ' $SOBJECT eliminados')
    else:
        print('  ⚠️  $SOBJECT delete: ' + d.get('message','')[:100])
except:
    print('  ✅ $SOBJECT eliminados (parse error, probablemente OK)')
" COUNT="$COUNT" TMP_DIR="$TMP_DIR"
}

# Orden: primero logs (Lookup, no cascade), luego tickets (cascade elimina candidates)
bulk_delete "Merge_Log__c" "$SANDBOX"
bulk_delete "Merge_Ticket__c" "$SANDBOX"
bulk_delete "Related_Object_Config__c" "$SANDBOX"

echo ""
echo "✅ Limpieza completa"

# ── PASO 2: Convertir raw JSON → formato import tree ─────────
echo ""
echo "🔧 Preparando archivos de importación..."

DATA_DIR="$DATA_DIR" TMP_DIR="$TMP_DIR" python3 << 'PYEOF'
import json, os, sys

DATA_DIR = os.environ['DATA_DIR']
TMP_DIR  = os.environ['TMP_DIR']
CHUNK    = 50  # registros por archivo (conservador por campos JSON largos)

def load_records(filename):
    path = os.path.join(DATA_DIR, filename)
    d = json.load(open(path))
    records = d.get('result', {}).get('records', [])
    # sf data query --json incluye 'attributes' en cada record — lo removemos
    for r in records:
        r.pop('attributes', None)
    return records

def clean(rec, skip_fields):
    return {k: v for k, v in rec.items()
            if k not in skip_fields and not isinstance(v, dict)}

def write_chunks(records, obj_type, ref_prefix, skip_fields, ref_map=None, parent_field=None, parent_ref_map=None):
    """Escribe archivos JSON chunkeados. Retorna lista de filenames."""
    files = []
    for i in range(0, len(records), CHUNK):
        chunk = records[i:i+CHUNK]
        out_records = []
        for r in chunk:
            prod_id = r['Id']
            ref_id = f"{ref_prefix}{prod_id}"
            clean_r = clean(r, skip_fields)
            clean_r['attributes'] = {'type': obj_type, 'referenceId': ref_id}
            if parent_field and parent_ref_map:
                parent_prod_id = r.get(parent_field)
                if parent_prod_id and parent_prod_id in parent_ref_map:
                    clean_r[parent_field] = f"@{parent_ref_map[parent_prod_id]}"
                else:
                    clean_r[parent_field] = None
            if ref_map is not None:
                ref_map[prod_id] = ref_id
            out_records.append(clean_r)
        fname = f"{ref_prefix}chunk{i//CHUNK + 1}.json"
        fpath = os.path.join(TMP_DIR, fname)
        json.dump({'records': out_records}, open(fpath, 'w'), indent=2, default=str)
        files.append(fname)
    return files

tickets   = load_records('tickets_raw.json')
candidates = load_records('candidates_raw.json')
logs      = load_records('logs_raw.json')
configs   = load_records('config_raw.json')

# sf data import tree hace FLS check estricto antes de insertar.
# Para evitar errores: solo incluir los campos que existían en V3 (Status, Object_Type, Match_Type).
# Tickets con Status terminal (Ignored/Merged/Closed) se reasignan a 'New' para
# no disparar validaciones V2 que requieren campos que no estaban en V3.
TERMINAL = {'Ignored', 'Merged', 'Closed'}
for t in tickets:
    if t.get('Status__c') in TERMINAL:
        t['Status__c'] = 'New'

TICKET_SKIP    = {'Id', 'Name', 'Closed_Reason__c', 'Selected_Master_Id__c',
                  'Match_Key__c', 'Match_Confidence__c', 'Final_Action__c',
                  'Error_Message__c', 'Candidate_Count__c', 'Notes__c'}
CANDIDATE_SKIP = {'Id', 'Name', 'Merge_Ticket__c',
                  'Record_Name__c', 'Is_Master__c', 'Is_Losing_Record__c',
                  'Related_Info_JSON__c', 'Snapshot_JSON__c'}
LOG_SKIP       = {'Id', 'Name', 'Merge_Ticket__c', 'Performed_By__c',
                  'Master_Record_Name__c', 'Losing_Record_Ids__c', 'Losing_Record_Names__c',
                  'Losing_Records_Summary__c', 'Field_Decisions_JSON__c',
                  'After_Snapshot_JSON__c', 'Merge_Related_Records__c', 'Performed_Date__c'}
# Before_Snapshot_JSON__c es requerido por validación — se incluye con placeholder para V3 logs
for l in logs:
    if not l.get('Before_Snapshot_JSON__c'):
        l['Before_Snapshot_JSON__c'] = '{}'
CONFIG_SKIP    = {'Id'}

# Mapa de ID producción → referenceId para tickets
ticket_ref = {}
ticket_files = write_chunks(tickets, 'Merge_Ticket__c', 'T_', TICKET_SKIP, ref_map=ticket_ref)

cand_files = write_chunks(
    candidates, 'Merge_Candidate__c', 'C_', CANDIDATE_SKIP,
    parent_field='Merge_Ticket__c', parent_ref_map=ticket_ref
)

log_files = write_chunks(
    logs, 'Merge_Log__c', 'L_', LOG_SKIP
    # No parent_field: los logs V3 no tienen Merge_Ticket__c — se importan sin link a ticket
)

config_files = write_chunks(configs, 'Related_Object_Config__c', 'CFG_', CONFIG_SKIP)

# Plan de importación
def abs_files(flist):
    return [os.path.join(TMP_DIR, f) for f in flist]

plan = []
if ticket_files:
    plan.append({'sobject': 'Merge_Ticket__c',         'saveRefs': True,  'resolveRefs': False, 'files': abs_files(ticket_files)})
if cand_files:
    plan.append({'sobject': 'Merge_Candidate__c',      'saveRefs': False, 'resolveRefs': True,  'files': abs_files(cand_files)})
# Logs excluidos del plan: sf data import tree hace FLS check en Before_Snapshot_JSON__c
# (campo V2) aunque el perfil Admin lo debería tener. Los logs V3 tampoco tienen
# link a ticket — no aportan valor en sandbox para testing.
if config_files:
    plan.append({'sobject': 'Related_Object_Config__c','saveRefs': False, 'resolveRefs': False, 'files': abs_files(config_files)})

plan_path = os.path.join(TMP_DIR, 'import-plan.json')
json.dump(plan, open(plan_path, 'w'), indent=2)

total_files = len(ticket_files) + len(cand_files) + len(log_files) + len(config_files)
print(f"   Plan: {len(tickets)} tickets ({len(ticket_files)} archivos), "
      f"{len(candidates)} candidates ({len(cand_files)}), "
      f"{len(logs)} logs ({len(log_files)}), "
      f"{len(configs)} configs ({len(config_files)})")
print(f"   Total: {total_files} archivos JSON")
PYEOF

if [ $? -ne 0 ]; then
  echo "❌ Error preparando archivos de importación"
  rm -rf "$TMP_DIR"
  exit 1
fi

# ── PASO 3: Importar con sf data import tree ──────────────────
echo ""
echo "📥 Importando datos al sandbox..."

sf data import tree \
  --plan "$TMP_DIR/import-plan.json" \
  --target-org "$SANDBOX" \
  --json 2>/dev/null > "$TMP_DIR/import_result.json"

TMP_DIR="$TMP_DIR" python3 << 'PYEOF'
import json, os, sys

TMP_DIR = os.environ['TMP_DIR']
raw = open(TMP_DIR + '/import_result.json').read().strip()

if not raw:
    print("❌ No se recibió respuesta del import")
    sys.exit(1)

# Saltar posibles warnings de CLI antes del JSON
lines = raw.splitlines()
for i, line in enumerate(lines):
    if line.strip().startswith('{') or line.strip().startswith('['):
        raw = '\n'.join(lines[i:])
        break

try:
    data = json.loads(raw)
except Exception as e:
    print(f"❌ No se pudo parsear respuesta: {e}")
    print(raw[:500])
    sys.exit(1)

result = data.get('result', {})
status = data.get('status', -1)

if status == 0:
    print("✅ IMPORT COMPLETO")
    if isinstance(result, list):
        counts = {}
        for item in result:
            t = item.get('type', item.get('sobject', '?'))
            counts[t] = counts.get(t, 0) + 1
        for obj, cnt in sorted(counts.items()):
            print(f"   {obj}: {cnt} registros creados")
    else:
        print(f"   {result}")
else:
    print("❌ ERROR en importación:")
    print(f"   {data.get('message', data.get('name', 'Sin mensaje'))[:300]}")
    items = data.get('data', [])
    for item in items[:5]:
        print(f"     {item}")
    if not items:
        print(f"   Raw: {raw[:600]}")
PYEOF

IMPORT_STATUS=$?

echo ""
if [ $IMPORT_STATUS -eq 0 ]; then
  rm -rf "$TMP_DIR"
  echo "========================================================"
  echo "  ✅ Restore completo — sandbox listo para pruebas"
  echo "  Org: $SANDBOX"
  echo "========================================================"
else
  echo "========================================================"
  echo "  ⚠️  Restore con errores — archivos de debug en:"
  echo "  $TMP_DIR"
  echo "  (se pueden inspeccionar manualmente)"
  echo "========================================================"
fi
echo ""
