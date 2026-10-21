#!/bin/bash

# ============================================================
# Admissions SEMBEQ — Deploy SANDBOX (Camino A: Extend EDA)
# ============================================================
# Deploya el módulo de Admissions (Camino A) al sandbox SEMBEQ.
# Extiende hed__Application__c (EDA nativo) con 5 campos custom
# y agrega 3 objetos custom de proceso.
#
# Objetos nuevos (3):
#   Admissions_Review__c   — revisores asignados (AR-XXXX)
#   Admissions_Decision__c — decisión formal de admisión (AD-XXXX)
#   Admissions_Document__c — documentos requeridos/recibidos
#
# Campos custom en hed__Application__c:
#   Program__c             — Lookup a hed__Program_Plan__c
#   Previous_Institution__c — institución anterior
#   Previous_GPA__c        — promedio anterior (0-4.0)
#   Interview_Required__c  — flag para entrevista
#   Financial_Aid_Requested__c — flag de beca
#
# Permission Set: Admissions_Access (SEMBEQ)
# Manifest: manifest/package-admissions-sembeq.xml
#
# Reglas del proyecto: solo metadata (sin Apex/Triggers) —
# este script puede ser ejecutado directamente por el asistente.

TARGET_ORG="${1:-e.frappe@sembeq.qc.ca.partialdev}"

BASE="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$BASE/manifest/package-admissions-sembeq.xml"

echo "=================================================="
echo "  DEPLOY ADMISSIONS SEMBEQ -> $TARGET_ORG"
echo "=================================================="
echo ""
echo "Manifest: $MANIFEST"
echo ""
echo "Componentes:"
echo "  Objetos:  Admissions_Review__c, Admissions_Decision__c, Admissions_Document__c"
echo "  Campos:   5 campos custom en hed__Application__c"
echo "  Tabs:     3 tabs (Admissions_Review__c, _Decision__c, _Document__c)"
echo "  PS:       Admissions_Access (SEMBEQ)"
echo ""

DEPLOY_JSON=$(sf project deploy start \
    --manifest "$MANIFEST" \
    --target-org "$TARGET_ORG" \
    --test-level NoTestRun \
    --json 2>&1)

echo "$DEPLOY_JSON" > /tmp/admissions_sembeq_sandbox_deploy.json

python3 <<'PYEOF'
import json

with open('/tmp/admissions_sembeq_sandbox_deploy.json') as f:
    raw = f.read()

if '{' in raw:
    raw = raw[raw.index('{'):]

data = json.loads(raw)
result = data.get('result', {})

print("")
print("==================== RESULTADO ====================")
print(f"Deploy ID:   {result.get('id', 'N/A')}")
print(f"Status:      {result.get('status', 'N/A')}")
print(f"Success:     {result.get('success', 'N/A')}")
print(f"Componentes: {result.get('numberComponentsDeployed', 'N/A')} deployados")
print(f"Errores:     {result.get('numberComponentErrors', 'N/A')}")

details = result.get('details', {})
component_failures = details.get('componentFailures', [])
if isinstance(component_failures, dict):
    component_failures = [component_failures]
if component_failures:
    print("")
    print("---- FALLOS ----")
    for cf in component_failures:
        print(f"  {cf.get('componentType', '?')} {cf.get('fullName', '?')}: {cf.get('problem', '?')}")

print("")
print("==================== SIGUIENTES PASOS ====================")
print("1. Verificar Success=true, 0 errores.")
print("2. Asignar Permission Set 'Admissions Access (SEMBEQ)' al usuario en Setup.")
print("3. Abrir sandbox > App Launcher > EDA > buscar 'Applications'.")
print("4. Crear una hed__Application__c de prueba y verificar los 5 campos nuevos.")
print("5. Crear un Admissions_Review__c, _Decision__c y _Document__c de prueba.")
PYEOF
