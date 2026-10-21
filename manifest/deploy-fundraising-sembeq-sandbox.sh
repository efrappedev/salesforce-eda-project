#!/bin/bash

# ============================================================
# Fundraising SEMBEQ — Deploy SANDBOX
# ============================================================
# Deploya el modulo completo de Fundraising (13 objetos custom,
# campos en Contact/Campaign, Apex services, triggers, flows,
# permission set, tabs, app) al sandbox de SEMBEQ.
#
# Objetos incluidos (Fase 1 + extensiones 2026-09-01):
#   Originales (11): Gift_Transaction__c, Gift_Commitment__c,
#     Gift_Designation__c, Gift_Split__c, Gift_Refund__c,
#     Gift_Soft_Credit__c, Gift_Tribute__c, Payment_Instrument__c,
#     Scholarship__c, Scholarship_Allocation__c, Scholarship_Payment__c
#   Nuevos (2): Gift_Commitment_Schedule__c, Outreach_Source_Code__c
#   Campos adicionales: Gift_Transaction__c.Outreach_Source_Code__c
#
# Apex deployado: FundraisingRollupService, FundraisingScholarshipService,
#   FundraisingLYBUNTBatch + 4 test classes
# Triggers deployados: los del folder triggers/
#
# Reglas del proyecto (CLAUDE.md): cambios con Apex los corre
# siempre el usuario — este script NO es ejecutado por el asistente.

TARGET_ORG="${1:-}"
if [ -z "$TARGET_ORG" ]; then
    echo "Uso: $0 <org-alias-o-username>"
    echo "  Ejemplo: $0 partialdev"
    exit 1
fi

BASE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$BASE/force-app-sembeq/main/default"

echo "=================================================="
echo "  DEPLOY FUNDRAISING SEMBEQ -> $TARGET_ORG"
echo "=================================================="
echo ""
echo "Este deploy incluye (force-app-sembeq/main/default/):"
echo "  Objetos: 13 objetos custom + campos Contact/Campaign (incluyendo"
echo "           Gift_Commitment_Schedule__c y Outreach_Source_Code__c nuevos)"
echo "  Apex:    FundraisingRollupService, FundraisingScholarshipService,"
echo "           FundraisingLYBUNTBatch + tests"
echo "  Triggers: todos los de force-app-sembeq/main/default/triggers/"
echo "  Flows:   todos los de force-app-sembeq/main/default/flows/"
echo "  PS:      Fundraising_Access (con los 2 objetos nuevos agregados)"
echo "  App + Tabs + Profile Admin"
echo ""

DEPLOY_JSON=$(sf project deploy start \
    --source-dir "$SRC/objects" \
    --source-dir "$SRC/classes" \
    --source-dir "$SRC/triggers" \
    --source-dir "$SRC/flows" \
    --source-dir "$SRC/permissionsets" \
    --source-dir "$SRC/tabs" \
    --source-dir "$SRC/applications" \
    --source-dir "$SRC/profiles" \
    --target-org "$TARGET_ORG" \
    --test-level RunLocalTests \
    --json)

echo "$DEPLOY_JSON" > /tmp/fundraising_sembeq_sandbox_deploy.json

python3 <<'PYEOF'
import json

with open('/tmp/fundraising_sembeq_sandbox_deploy.json') as f:
    raw = f.read()

if '{' in raw:
    raw = raw[raw.index('{'):]

data = json.loads(raw)
result = data.get('result', {})

print("")
print("==================== RESULTADO ====================")
print(f"Deploy ID: {result.get('id', 'N/A')}")
print(f"Status: {result.get('status', 'N/A')}")
print(f"Success: {result.get('success', 'N/A')}")
print(f"Componentes deployados: {result.get('numberComponentsDeployed', 'N/A')}")
print(f"Errores de componentes: {result.get('numberComponentErrors', 'N/A')}")

details = result.get('details', {})
component_failures = details.get('componentFailures', [])
if isinstance(component_failures, dict):
    component_failures = [component_failures]
if component_failures:
    print("")
    print("---- FALLOS DE COMPONENTES ----")
    for cf in component_failures:
        print(f"  {cf.get('componentType', '?')} {cf.get('fullName', '?')}: {cf.get('problem', '?')}")

run_test_result = result.get('details', {}).get('runTestResult', {})
num_tests_run = run_test_result.get('numTestsRun')
num_failures = run_test_result.get('numFailures')
if num_tests_run is not None:
    print("")
    print(f"---- TESTS: {num_tests_run} corridos, {num_failures} fallos ----")

    failures = run_test_result.get('failures', [])
    if isinstance(failures, dict):
        failures = [failures]
    for fail in failures:
        print(f"  FALLO: {fail.get('name', '?')}.{fail.get('methodName', '?')}: {fail.get('message', '?')}")

    coverage = run_test_result.get('codeCoverage', [])
    if isinstance(coverage, dict):
        coverage = [coverage]
    if coverage:
        print("")
        print("---- COBERTURA POR CLASE ----")
        for cov in sorted(coverage, key=lambda c: c.get('name', '')):
            name = cov.get('name', '?')
            covered = int(cov.get('numLocations', 0)) - int(cov.get('numLocationsNotCovered', 0))
            total = int(cov.get('numLocations', 0))
            pct = (covered / total * 100) if total > 0 else 100
            flag = ""
            if pct < 75:
                flag = "  <-- BAJO 75%"
            elif pct < 100:
                flag = "  <-- no 100%"
            print(f"  {name}: {covered}/{total} ({pct:.1f}%){flag}")

print("")
print("==================== SIGUIENTES PASOS ====================")
print("1. Verificar Success=true, 0 errores, 0 fallos de tests.")
print("2. En sandbox: abrir App Launcher > Fundraising > confirmar los 13 tabs.")
print("3. Crear un registro de prueba en Gift_Commitment_Schedule__c y Outreach_Source_Code__c.")
print("4. Confirmar que Gift Transaction tiene el campo Outreach Source Code disponible.")
PYEOF
