#!/bin/bash
# ============================================================
# ReleveDesNotes Cleanup — Delete from Org
# ============================================================
# Deletes 3 components created by c3c software:
#
#   ReleveDesNotes.cls       — Apex controller (83% coverage)
#   ReleveDesNotesTest.cls   — Apex test class
#   GenererReleveDesNotes    — Aura component (AuraDefinitionBundle)
#
# NOTE: Uses RunLocalTests — all remaining org tests must pass.
#       Overall org coverage will improve since the 83% class is gone.
#
# Usage:
#   chmod +x manifest/deploy-delete-releve.sh
#   ./manifest/deploy-delete-releve.sh production
# ============================================================

TARGET_ORG="${1:-}"
if [ -z "$TARGET_ORG" ]; then
  echo "Usage: $0 <org-alias>"
  echo "Example: $0 production"
  exit 1
fi

BASE="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$BASE/manifest"
VERBOSE_LOG="/tmp/releve-delete-$$.log"

echo "================================================"
echo "  ReleveDesNotes Cleanup — Target: $TARGET_ORG"
echo "================================================"
echo ""
echo "  DELETE (post-deploy):"
echo "    ReleveDesNotes.cls"
echo "    ReleveDesNotesTest.cls"
echo "    GenererReleveDesNotes (Aura)"
echo ""

sf project deploy start \
  --manifest "$MANIFEST/package-releve-empty.xml" \
  --post-destructive-changes "$MANIFEST/destructiveChanges-releve.xml" \
  --test-level RunLocalTests \
  --ignore-warnings \
  --target-org "$TARGET_ORG" \
  --verbose 2>&1 | tee "$VERBOSE_LOG"

DEPLOY_EXIT=${PIPESTATUS[0]}

DEPLOY_ID=$(grep -oE "0Af[A-Za-z0-9]+" "$VERBOSE_LOG" 2>/dev/null | head -1)
rm -f "$VERBOSE_LOG" 2>/dev/null

if [ -n "$DEPLOY_ID" ] && command -v python3 &>/dev/null; then
    echo ""
    echo "  Fetching coverage report for deploy $DEPLOY_ID..."
    COVERAGE_FILE="/tmp/releve-cov-$$.json"
    sf project deploy report \
      -i "$DEPLOY_ID" \
      --target-org "$TARGET_ORG" \
      --json > "$COVERAGE_FILE" 2>/dev/null

    python3 - "$COVERAGE_FILE" <<'PYEOF'
import json, sys

try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception as e:
    print(f"  Could not parse coverage report: {e}")
    sys.exit(0)

result       = data.get('result', data)
details      = result.get('details', {})
run_test     = details.get('runTestResult', {})
cov          = run_test.get('codeCoverage', [])
tests_ran    = run_test.get('numTestsRan', 0)
tests_failed = run_test.get('numFailures', 0)

failures = run_test.get('failures', [])
if failures:
    print()
    print('  FAILED TESTS:')
    for f in failures:
        print(f'    [{f.get("methodName","?")}] {f.get("message","")}')
        st = f.get('stackTrace', '')
        for line in (st.split('\n'))[:2]:
            if line.strip():
                print(f'      {line.strip()}')

if not cov:
    print('  (no coverage data in report)')
    sys.exit(0)

print()
print('  ================================================')
print('  CODE COVERAGE')
print('  ------------------------------------------------')
print(f'  {"Component":<42} {"Coverage":>8}  Lines')
print('  ------------------------------------------------')
org_covered = 0
org_total   = 0
for c in sorted(cov, key=lambda x: x.get('name', '')):
    name    = c.get('name', '?')
    covered = int(c.get('numLocations', 0))
    not_cov = int(c.get('numLocationsNotCovered', 0))
    total   = covered + not_cov
    pct     = (100.0 * covered / total) if total else 0.0
    org_covered += covered
    org_total   += total
    icon   = '✅' if pct >= 75 else ('⚠  ' if pct >= 50 else '❌')
    filled = int(pct / 5)
    bar    = '█' * filled + '░' * (20 - filled)
    print(f'  {icon} {name:<40} {bar} {pct:5.1f}%  ({covered}/{total})')
org_pct = (100.0 * org_covered / org_total) if org_total else 0.0
print('  ------------------------------------------------')
print(f'  {"TOTAL":<42}         {org_pct:5.1f}%  ({org_covered}/{org_total})')
print('  ================================================')
print(f'  Tests: {tests_ran} ran  |  {tests_failed} failed')
print()
PYEOF

    rm -f "$COVERAGE_FILE" 2>/dev/null
fi

exit $DEPLOY_EXIT
