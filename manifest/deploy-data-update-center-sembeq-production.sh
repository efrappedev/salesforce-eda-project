#!/bin/bash

# ============================================================
# Data Update Center — Deploy PRODUCCION SEMBEQ
# ============================================================
# Deploya la carpeta "Data Update Center SEMBEQ/main/default" (copia adaptada a
# SEMBEQ de la app de AEBEQ: Contact + Account sin Person Accounts) — Apex, LWC,
# objetos, permission sets, tab, flexipage, app, profile Admin, cola
# "Data Update Requests", remote sites (reCAPTCHA + Metadata API SEMBEQ),
# static resource DataUpdateRecaptchaFrame y el candado en Contact
# (Data_Update_Locked__c / Data_Update_Locked_Date__c + FLS).
#
# NO incluye:
#   - Formularios: en SEMBEQ se crean desde el Form Builder (DUC_Form_Config__c).
#   - Attendance_History__c / Baptism_History__c (decision del usuario 2026-10-20:
#     no se crean en SEMBEQ; la app los detecta solos si algun dia se crean).
#   - Sitio Experience Cloud: requiere Digital Experiences activado y se crea a mano.
#
# Reemplaza al viejo "Ticket Update App" (ya retirado de ambos sandboxes
# 2026-08-24). NO toca el framework legacy Case-based ni Merge Manager.
#
# Reglas del proyecto (CLAUDE.md): cambios Apex a produccion SIEMPRE los
# corre el usuario. Este script se crea pero NO se ejecuta por el asistente.

TARGET_ORG="${1:-}"
if [ -z "$TARGET_ORG" ]; then
    echo "Uso: $0 <org-alias-o-username>"
    echo "  Ejemplo: $0 production"
    exit 1
fi

if [ "$TARGET_ORG" = "production" ] || [ "$TARGET_ORG" = "e.frappe@sembeq.qc.ca" ]; then
    echo "=================================================="
    echo "  DEPLOY DATA UPDATE CENTER -> PRODUCCION SEMBEQ"
    echo "  Org destino: $TARGET_ORG"
    echo "=================================================="
    echo ""
    echo "Este deploy incluye:"
    echo "  - Apex: toda la carpeta classes de Data Update Center (incluye DataUpdateMultiTicketReviewController)"
    echo "  - Objetos: Data_Update_Request__c, Data_Update_Log__c,"
    echo "             Data_Update_Form__mdt, Data_Update_Form_Field__mdt (sin registros CMDT activos)"
    echo "  - LWC: toda la carpeta lwc de Data Update Center (incluye dataUpdateMultiTicketReview)"
    echo "  - Permission sets: Data_Update_Center_Access, Form_Admin, Delete_Access, Multi_Ticket_Review"
    echo "  - Custom permissions: Data_Update_Manage_Forms, Data_Update_Delete_Forms, Data_Update_Multi_Ticket_Review"
    echo "  - App + Tab + FlexiPage: Data_Update_Center"
    echo "  - Profile: Admin (applicationVisibilities + tabVisibilities de Data_Update_Center)"
    echo ""
    echo "  - Visualforce pages + cache partition + static resources (DataUpdateRecaptchaFrame, DucTestFormFixtures)"
    echo "  - Cola Data Update Requests + remote sites (reCAPTCHA, Metadata API SEMBEQ)"
    echo "  - Campos Contact.Data_Update_Locked__c / Data_Update_Locked_Date__c (candado) + FLS"
    echo ""
    echo "Tests que se van a correr (RunSpecifiedTests, las 11 de Data Update Center):"
    echo "  DataUpdateAuditServiceTest, DataUpdateFormAdminControllerTest, DataUpdateFormAdminDeployCallbackTest,"
    echo "  DataUpdateMetadataDeleteServiceTest, DataUpdateFormConfigServiceTest, DataUpdateFormDeleteVfControllerTest,"
    echo "  DataUpdatePortalControllerTest, DataUpdateReCaptchaServiceTest, DataUpdateReviewControllerTest,"
    echo "  DataUpdateMultiTicketReviewTest, DucFormConfigStoreTest"
    echo ""
    echo "¿Continuar? Escribe CONFIRMAR para proceder:"
    read -r CONFIRM
    if [ "$CONFIRM" != "CONFIRMAR" ]; then
        echo "Cancelado."
        exit 1
    fi
else
    echo "Target: $TARGET_ORG (no es producción, sin gate de confirmación)"
fi

BASE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$BASE/Data Update Center SEMBEQ/main/default"

echo ""
echo "Iniciando deploy..."

DEPLOY_JSON=$(sf project deploy start \
    --source-dir "$SRC/classes" \
    --source-dir "$SRC/lwc" \
    --source-dir "$SRC/objects" \
    --source-dir "$SRC/permissionsets" \
    --source-dir "$SRC/tabs" \
    --source-dir "$SRC/flexipages" \
    --source-dir "$SRC/applications" \
    --source-dir "$SRC/profiles" \
    --source-dir "$SRC/cspTrustedSites" \
    --source-dir "$SRC/customPermissions" \
    --source-dir "$SRC/staticresources" \
    --source-dir "$SRC/pages" \
    --source-dir "$SRC/cachePartitions" \
    --source-dir "$SRC/queues" \
    --source-dir "$SRC/remoteSiteSettings" \
    --target-org "$TARGET_ORG" \
    --test-level RunSpecifiedTests \
    --tests DataUpdateAuditServiceTest \
    --tests DataUpdateFormAdminControllerTest \
    --tests DataUpdateFormAdminDeployCallbackTest \
    --tests DataUpdateMetadataDeleteServiceTest \
    --tests DataUpdateFormConfigServiceTest \
    --tests DataUpdateFormDeleteVfControllerTest \
    --tests DataUpdatePortalControllerTest \
    --tests DataUpdateReCaptchaServiceTest \
    --tests DataUpdateReviewControllerTest \
    --tests DataUpdateMultiTicketReviewTest \
    --tests DucFormConfigStoreTest \
    --json)

echo "$DEPLOY_JSON" > /tmp/data_update_center_sembeq_deploy_result.json

python3 <<'PYEOF'
import json

with open('/tmp/data_update_center_sembeq_deploy_result.json') as f:
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
print("1. Revisar el resultado arriba: Success debe ser true, 0 errores de componentes, 0 fallos de tests.")
print("2. Verificar cobertura: las clases de Data Update Center deben salir 100%.")
print("3. Confirmar visibilidad: sf sobject describe / SOQL contra Data_Update_Request__c en produccion.")
print("4. Asignar el permission set Data_Update_Center_Access a los usuarios de staff que revisaran solicitudes.")
print("5. Confirmar que el perfil System Administrator ve la app 'Data Update Center' (tabVisibilities).")
print("6. Activar Digital Experiences (si falta), crear el sitio publico y publicarlo.")
print("7. Crear los 3 formularios en el Form Builder: Contacts (Contact), Eglises (Account, RT Eglise),")
print("   Organismes/Entreprises (Account, RT 'Organisme, Business_Organization').")
print("8. Poner las llaves de reCAPTCHA en DataUpdateReCaptcha_Setting__c (Setup > Custom Settings).")
PYEOF
