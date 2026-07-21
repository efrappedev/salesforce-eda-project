#!/bin/bash
# ============================================================
# Merge Manager Global V2 (non-EDA) — Cobertura (validate only)
# No hace deploy real — solo corre los 5 test classes propios
# y reporta el % de cobertura por clase.
#
# Org target: AEBEQ sandbox (e.frappe@aebeq.qc.ca.partialae)
#
# Uso:
#   chmod +x manifest/coverage-v2.sh
#   ./manifest/coverage-v2.sh
# ============================================================

BASE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$BASE/force-app/main/default/Merge Manager Salesforce Global V2"
ORG="e.frappe@aebeq.qc.ca.partialae"

echo ""
echo "========================================================"
echo "  Merge Manager V2 non-EDA — Coverage Check"
echo "  Org: $ORG"
echo "  Tests: 5 clases propias (no RunLocalTests)"
echo "========================================================"
echo ""

RAW=$(sf project deploy validate \
  --source-dir "$SRC/classes" \
  --source-dir "$SRC/lwc" \
  --source-dir "$SRC/objects" \
  --test-level RunSpecifiedTests \
  --tests MergeCoverageBoostTest \
  --tests MergeExecutionControllerTest \
  --tests MergeScanServiceTest \
  --tests MergeUtilityTest \
  --tests RelatedRecordsServiceTest \
  --target-org "$ORG" \
  --json 2>&1)

echo "$RAW" | python3 << 'PYEOF'
import json, sys

raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception as e:
    print("Error parseando JSON:", e)
    print(raw[:2000])
    sys.exit(1)

result = data.get('result', {})
status  = result.get('status', 'Unknown')
success = result.get('success', False)
dep_id  = result.get('id', 'N/A')

print(f"Deploy/Validate ID : {dep_id}")
print(f"Status             : {status}")
print()

details = result.get('details', {})
tests   = details.get('runTestResult', {})

# Failures
failures = tests.get('failures', [])
if failures:
    if isinstance(failures, dict):
        failures = [failures]
    print(f"⛔ Test failures ({len(failures)}):")
    for f in failures:
        print(f"  [{f.get('methodName','?')}] {f.get('message','')[:120]}")
    print()

# Coverage table
coverage = tests.get('codeCoverage', [])
if isinstance(coverage, dict):
    coverage = [coverage]

if not coverage:
    print("No coverage data returned.")
    sys.exit(0)

merge_classes = {
    'DataNormalizationUtil', 'MergeAuditService', 'MergeController',
    'MergeExecutionService', 'MergeScanBatch', 'MergeScanService',
    'MergeTicketService', 'MergeWrappers', 'RelatedRecordsService',
    'SnapshotService'
}

own   = [c for c in coverage if c.get('name','') in merge_classes]
other = [c for c in coverage if c.get('name','') not in merge_classes]

def print_table(rows):
    total_loc = 0
    total_cov = 0
    for c in sorted(rows, key=lambda x: x.get('name','')):
        name  = c.get('name','')
        locs  = int(c.get('numLocations', 0))
        uncov = int(c.get('numLocationsNotCovered', 0))
        cov   = locs - uncov
        total_loc += locs
        total_cov += cov
        if locs == 0:
            pct = 100.0
        else:
            pct = cov / locs * 100
        flag = '' if pct >= 99.9 else (' ⚠️  <75%' if pct < 75 else ' ◀')
        print(f"  {name:<45} {cov:>4}/{locs:<4}  {pct:>5.1f}%{flag}")
    if total_loc > 0:
        overall = total_cov / total_loc * 100
        print(f"  {'─'*55}")
        print(f"  {'TOTAL':<45} {total_cov:>4}/{total_loc:<4}  {overall:>5.1f}%")
    return total_loc, total_cov

print("📊 Clases del Merge Manager:")
print(f"  {'Clase':<45} {'Cov':>9}  {'%':>6}")
print(f"  {'─'*55}")
tl, tc = print_table(own)

if other:
    print()
    print("📊 Otras clases cubiertas (colateral):")
    print(f"  {'Clase':<45} {'Cov':>9}  {'%':>6}")
    print(f"  {'─'*55}")
    print_table(other)

print()
if tl > 0:
    overall = tc / tl * 100
    if overall >= 75:
        print(f"✅ Cobertura Merge Manager: {overall:.1f}% — listo para producción")
    else:
        print(f"❌ Cobertura Merge Manager: {overall:.1f}% — por debajo del mínimo (75%)")
PYEOF
