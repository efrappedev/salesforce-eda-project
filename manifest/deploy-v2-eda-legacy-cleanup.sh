#!/bin/bash
# ============================================================
# Merge Manager V2 EDA — Legacy Cleanup (Phase 2)
# ============================================================
# Removes legacy Apex classes replaced by V2 for EDA:
#   - EDARelatedRecordsService  → replaced by RelatedRecordsService
#   - EDAServiceCoverageTest    → replaced by RelatedRecordsServiceTest
#
# RUN THIS ONLY AFTER:
#   ./manifest/deploy-v2-eda-production.sh production
#   AND after validating the app works correctly.
#
# Usage:
#   chmod +x manifest/deploy-v2-eda-legacy-cleanup.sh
#   ./manifest/deploy-v2-eda-legacy-cleanup.sh production
# ============================================================

TARGET_ORG="${1:-}"
if [ -z "$TARGET_ORG" ]; then
  echo "Usage: $0 <prod-org-alias>"
  echo "Example: $0 production"
  exit 1
fi

if [ "$TARGET_ORG" = "production" ] || [ "$TARGET_ORG" = "e.frappe@sembeq.qc.ca" ]; then
  echo ""
  echo "⚠️  DESTINO: PRODUCCIÓN ($TARGET_ORG)"
  echo ""
  echo "Este script elimina 2 clases Apex legacy:"
  echo "  - EDARelatedRecordsService  (reemplazada por RelatedRecordsService)"
  echo "  - EDAServiceCoverageTest    (reemplazada por RelatedRecordsServiceTest)"
  echo ""
  echo "Solo ejecutar después de validar que el deploy Phase 1 funciona correctamente."
  echo ""
  echo "¿Continuar? Escribe CONFIRMAR para proceder:"
  read -r CONFIRM
  if [ "$CONFIRM" != "CONFIRMAR" ]; then
    echo "Cancelado."
    exit 0
  fi
fi

BASE="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST_DIR="$BASE/manifest"

echo ""
echo "========================================================"
echo "  Merge Manager V2 EDA — Phase 2 Legacy Cleanup"
echo "  Target: $TARGET_ORG"
echo "========================================================"
echo ""

# Write destructive package inline
cat > /tmp/package-v2eda-cleanup-empty.xml << 'XML'
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <version>64.0</version>
</Package>
XML

cat > /tmp/destructiveChanges-v2eda-cleanup.xml << 'XML'
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types>
        <members>EDARelatedRecordsService</members>
        <members>EDAServiceCoverageTest</members>
        <name>ApexClass</name>
    </types>
    <version>64.0</version>
</Package>
XML

echo "Deleting: EDARelatedRecordsService, EDAServiceCoverageTest"
echo ""

DEPLOY_OUTPUT=$(sf project deploy start \
  --manifest /tmp/package-v2eda-cleanup-empty.xml \
  --post-destructive-changes /tmp/destructiveChanges-v2eda-cleanup.xml \
  --test-level RunLocalTests \
  --target-org "$TARGET_ORG" \
  --json 2>&1)

echo "$DEPLOY_OUTPUT" | python3 - << 'PYEOF'
import json, sys

raw = sys.stdin.read()
try:
    data = json.loads(raw)
except:
    print(raw)
    sys.exit(1)

result = data.get('result', {})
status = result.get('status', 'Unknown')
deploy_id = result.get('id', 'N/A')
success = result.get('success', False)

print(f"\n{'='*55}")
print(f"  Deploy ID : {deploy_id}")
print(f"  Status    : {status}")
print(f"  Success   : {success}")
print(f"{'='*55}\n")

details = result.get('details', {})
tests = details.get('runTestResult', result.get('runTestResult', {}))
total = result.get('numberTestsCompleted', tests.get('numTestsRun', 0))
failures = tests.get('failures', [])

if total:
    print(f"Tests: {total} run | {len(failures)} failures")

if failures:
    print("\n⛔ Test failures:")
    for f in failures[:5]:
        print(f"  [{f.get('methodName','?')}] {f.get('message','')[:120]}")

coverage = tests.get('codeCoverage', [])
if coverage:
    merge_classes = [c for c in coverage if 'Merge' in c.get('name','') or 'Related' in c.get('name','')]
    print("\n📊 Merge Manager coverage post-cleanup:")
    print(f"  {'Class':<45} {'%':>6}")
    print(f"  {'-'*45} {'-'*6}")
    for c in sorted(merge_classes, key=lambda x: x.get('name','')):
        name = c.get('name','')
        total_lines = int(c.get('numLocations', 0))
        not_covered = int(c.get('numLocationsNotCovered', 0))
        if total_lines > 0:
            pct = round((total_lines - not_covered) / total_lines * 100, 1)
            flag = '' if pct == 100 else ' ⚠️' if pct < 75 else ''
            print(f"  {name:<45} {pct:>5.1f}%{flag}")

errors = result.get('details', {}).get('componentFailures', [])
if errors:
    print(f"\n⛔ Failures:")
    for e in errors[:10]:
        print(f"  [{e.get('componentType','?')}] {e.get('problem','')[:100]}")

if success:
    print("\n✅ CLEANUP SUCCEEDED")
    print("   EDARelatedRecordsService and EDAServiceCoverageTest removed.")
    print("   Production is now fully on Global V2 for EDA.")
else:
    print("\n❌ CLEANUP FAILED — Review errors above")
PYEOF