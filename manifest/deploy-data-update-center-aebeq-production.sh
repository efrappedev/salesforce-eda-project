#!/bin/bash
set -e

# Deploy Data Update Center a PRODUCCION AEBEQ (e.frappe@aebeq.qc.ca)
#
# Uso:
#   ./manifest/deploy-data-update-center-aebeq-production.sh            -> deploy real
#   ./manifest/deploy-data-update-center-aebeq-production.sh --dry-run  -> solo validar (check-only)
#
# UN solo deploy. Los tests ya NO leen la CMDT del org: usan la copia fija del static resource
# DucTestFormFixtures (formularios Account + Eglise completos), asi que la base de produccion
# puede ser minima: Account = nombre, apellido, courriel, 2 telefonos; Eglise = telefono +
# Alternative_Email_1__c. Todo lo demas lo crea el staff en el Form Builder de produccion
# (se guarda en DUC_Form_Config__c, no en CMDT).
#
# NO incluye (a proposito):
#   - Data_Update_Metric_History__c: retirado 2026-09-09, no se sube a produccion.
#   - Profile Guest "Mise a jour de compte AEBEQ Profile": los sitios Experience Cloud
#     (majcompte / eglises) todavia no existen en produccion; ese profile se sube despues de
#     crear los sitios, junto con "sf community publish".
#
# Reglas del proyecto (CLAUDE.md): cambios Apex a producción SIEMPRE los corre el usuario.
# Este script se crea pero NO se ejecuta por el asistente (salvo --dry-run si el usuario lo pide).

TARGET_ORG="e.frappe@aebeq.qc.ca"
DRY_RUN_FLAG=""
if [ "$1" == "--dry-run" ]; then
    DRY_RUN_FLAG="--dry-run"
fi

BASE="$(cd "$(dirname "$0")/.." && pwd)"

SOURCES=(
    "$BASE/force-app/main/default/Data Update Center/objects/Attendance_History__c"
    "$BASE/force-app/main/default/Data Update Center/objects/Baptism_History__c"
    "$BASE/force-app/main/default/Data Update Center/objects/DataUpdateReCaptcha_Setting__c"
    "$BASE/force-app/main/default/Data Update Center/objects/Data_Update_Form_Deploy_Job__c"
    "$BASE/force-app/main/default/Data Update Center/objects/Data_Update_Form_Field__mdt"
    "$BASE/force-app/main/default/Data Update Center/objects/Data_Update_Form__mdt"
    "$BASE/force-app/main/default/Data Update Center/objects/Data_Update_Appearance_Template__mdt"
    "$BASE/force-app/main/default/Data Update Center/objects/Data_Update_Presence__c"
    "$BASE/force-app/main/default/Data Update Center/objects/Data_Update_Log__c"
    "$BASE/force-app/main/default/Data Update Center/objects/Data_Update_Request__c"
    "$BASE/force-app/main/default/Data Update Center/objects/DUC_Form_Config__c"
    "$BASE/force-app/main/default/Data Update Center/classes"
    "$BASE/force-app/main/default/Data Update Center/lwc"
    "$BASE/force-app/main/default/Data Update Center/permissionsets"
    "$BASE/force-app/main/default/Data Update Center/tabs"
    "$BASE/force-app/main/default/Data Update Center/flexipages"
    "$BASE/force-app/main/default/Data Update Center/applications"
    "$BASE/force-app/main/default/Data Update Center/profiles"
    "$BASE/force-app/main/default/Data Update Center/cachePartitions"
    "$BASE/force-app/main/default/Data Update Center/customPermissions"
    "$BASE/force-app/main/default/Data Update Center/pages"
    "$BASE/force-app/main/default/Data Update Center/cspTrustedSites"
    "$BASE/force-app-aebeq/main/default/objects/Account/fields/Data_Update_Locked__c.field-meta.xml"
    "$BASE/force-app-aebeq/main/default/objects/Account/fields/Data_Update_Locked_Date__c.field-meta.xml"
    "$BASE/force-app-aebeq/main/default/objects/Account/fields/Eglise_Attendance__c.field-meta.xml"
    "$BASE/force-app-aebeq/main/default/objects/Account/fields/Eglise_Baptisms__c.field-meta.xml"
    "$BASE/force-app-aebeq/main/default/objects/Account/fields/Eglise_Attendance_Date__c.field-meta.xml"
    "$BASE/force-app-aebeq/main/default/objects/Account/fields/Eglise_Baptisms_Date__c.field-meta.xml"
    "$BASE/force-app-aebeq/main/default/objects/Account/fields/Enregistrement_provincial_etatique__c.field-meta.xml"
    "$BASE/force-app-aebeq/main/default/queues/Data_Update_Requests.queue-meta.xml"
    "$BASE/force-app/main/default/customMetadata/Data_Update_Form.AEBEQ_Account_Update.md-meta.xml"
    "$BASE/force-app/main/default/customMetadata/Data_Update_Form.AEBEQ_Eglise_Update.md-meta.xml"
    # Formularios base MINIMOS (decision del usuario 2026-10-15): el staff agrega el resto con el
    # Form Builder en produccion. Las demas preguntas siguen en el repo/sandbox pero NO suben.
    "$BASE/force-app/main/default/customMetadata/Data_Update_Form_Field.AEBEQ_Account_Update_FirstName.md-meta.xml"
    "$BASE/force-app/main/default/customMetadata/Data_Update_Form_Field.AEBEQ_Account_Update_LastName.md-meta.xml"
    "$BASE/force-app/main/default/customMetadata/Data_Update_Form_Field.AEBEQ_Account_Update_Email.md-meta.xml"
    "$BASE/force-app/main/default/customMetadata/Data_Update_Form_Field.AEBEQ_Account_Update_MobilePhone.md-meta.xml"
    "$BASE/force-app/main/default/customMetadata/Data_Update_Form_Field.AEBEQ_Account_Update_HomePhone.md-meta.xml"
    "$BASE/force-app/main/default/customMetadata/Data_Update_Form_Field.AEBEQ_Eglise_Update_Phone.md-meta.xml"
    "$BASE/force-app/main/default/customMetadata/Data_Update_Form_Field.AEBEQ_Eglise_Update_Alt_Email_1.md-meta.xml"
    "$BASE/force-app/main/default/Data Update Center/staticresources"
    "$BASE/force-app/main/default/staticresources/DataUpdateRecaptchaFrame.html"
    "$BASE/force-app/main/default/remoteSiteSettings/DataUpdate_ReCaptcha_Google.remoteSite-meta.xml"
    "$BASE/force-app/main/default/remoteSiteSettings/DataUpdate_MetadataApi_Production.remoteSite-meta.xml"
)

TESTS=(
    DataUpdateAuditServiceTest
    DataUpdateFormAdminControllerTest
    DataUpdateFormAdminDeployCallbackTest
    DataUpdateMetadataDeleteServiceTest
    DataUpdateFormConfigServiceTest
    DataUpdateFormDeleteVfControllerTest
    DataUpdatePortalControllerTest
    DataUpdateReCaptchaServiceTest
    DataUpdateReviewControllerTest
    DataUpdateMultiTicketReviewTest
    DucFormConfigStoreTest
)

echo "=================================================="
if [ -n "$DRY_RUN_FLAG" ]; then
echo "  DRY-RUN (check-only) DATA UPDATE CENTER -> PRODUCCION AEBEQ"
else
echo "  DEPLOY DATA UPDATE CENTER -> PRODUCCION AEBEQ"
fi
echo "  Org destino: $TARGET_ORG"
echo "=================================================="
echo ""
echo "Este deploy incluye:"
echo "  - Apex: toda la carpeta classes de Data Update Center (incluye DataUpdateMultiTicketReviewController)"
echo "  - Objetos: Data_Update_Request__c, Data_Update_Log__c, Data_Update_Form_Deploy_Job__c,"
echo "    Attendance_History__c, Baptism_History__c, DataUpdateReCaptcha_Setting__c, DUC_Form_Config__c"
echo "    (lo que publica el Form Builder, sin permisos de metadata), 3 tipos CMDT"
echo "  - Campos Account: candado (Data_Update_Locked__c/_Date__c) + Eglise_* + Enregistrement_provincial_etatique__c"
echo "  - CMDT base MINIMA: AEBEQ_Account_Update (nombre, apellido, courriel, telefono casa y mobile)"
echo "    + AEBEQ_Eglise_Update (telefono + Alternative_Email_1__c); el resto se arma en el Form Builder"
echo "  - Static resource DucTestFormFixtures (copia fija de formularios, solo la leen los tests)"
echo "  - LWC, permission sets (Access + Form_Admin + Delete_Access + Multi_Ticket_Review), 3 custom permissions, app/tab/flexipage,"
echo "    profile Admin, cache partition, pagina VF DataUpdateFormDelete, static resource reCAPTCHA,"
echo "    remote sites (reCAPTCHA + Metadata API), Queue Data Update Requests"
echo ""
echo "Tests (RunSpecifiedTests): ${TESTS[*]}"
echo ""
if [ -z "$DRY_RUN_FLAG" ]; then
    read -r -p "Escribe CONFIRMAR para continuar con el deploy a PRODUCCION AEBEQ: " CONFIRM
    if [ "$CONFIRM" != "CONFIRMAR" ]; then
        echo "Cancelado."
        exit 1
    fi
fi

ARGS=()
for s in "${SOURCES[@]}"; do ARGS+=(--source-dir "$s"); done
for t in "${TESTS[@]}"; do ARGS+=(--tests "$t"); done

echo ""
echo "Iniciando deploy (puede tardar varios minutos por los tests)..."

set +e
sf project deploy start \
    "${ARGS[@]}" \
    $DRY_RUN_FLAG \
    --target-org "$TARGET_ORG" \
    --test-level RunSpecifiedTests \
    --wait 60 \
    --json > /tmp/data_update_center_aebeq_deploy_result.json
set -e

python3 <<'PYEOF'
import json

with open('/tmp/data_update_center_aebeq_deploy_result.json') as f:
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
        print(f"         {(fail.get('stackTrace') or '')[:300]}")

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
            if pct < 100:
                missing = cov.get('locationsNotCovered', [])
                if isinstance(missing, dict):
                    missing = [missing]
                print(f"      lineas sin cubrir: {', '.join(str(m.get('line')) for m in missing)}")

print("")
print("==================== SIGUIENTES PASOS ====================")
print("1. Revisar el resultado arriba: Success debe ser true, 0 errores de componentes, 0 fallos de tests.")
print("2. Verificar cobertura: las clases de Data Update Center deben salir 100%.")
print("3. Confirmar visibilidad: sf sobject describe / SOQL contra Data_Update_Request__c en produccion.")
print("4. Asignar Data_Update_Center_Access a staff Y a los admins (el perfil Admin NO tiene FLS de candado/Eglise en prod).")
print("   Data_Update_Center_Form_Admin solo a lider del staff y sistemas (abre el Form Builder).")
print("   Data_Update_Center_Delete_Access solo a quien pueda borrar formularios.")
print("5. Verificar en el Queue 'Data Update Requests' que Data_Update_Request__c quedo asociado.")
print("6. Confirmar que el perfil System Administrator ve la app 'Data Update Center' (tabVisibilities).")
print("7. Probar el flujo end-to-end en produccion: submit publico -> dataUpdateCenter -> review -> apply.")
PYEOF
