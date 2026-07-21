#!/bin/bash
# ============================================================
# Merge Manager Global V2 (non-EDA) — Sandbox Deploy
# Org: e.frappe@aebeq.qc.ca.partialae
# ============================================================

TARGET_ORG="${1:-e.frappe@aebeq.qc.ca.partialae}"

BASE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$BASE/force-app/main/default/Merge Manager Salesforce Global V2"

echo "================================================"
echo "  Merge Manager V2 — SANDBOX DEPLOY"
echo "  Target: $TARGET_ORG"
echo "================================================"

sf project deploy start \
  --source-dir "$SRC/classes" \
  --source-dir "$SRC/lwc" \
  --source-dir "$SRC/objects" \
  --source-dir "$SRC/applications/Merge_Manager.app-meta.xml" \
  --source-dir "$SRC/tabs/Merge_Manager.tab-meta.xml" \
  --source-dir "$SRC/flexipages/Merge_Manager.flexipage-meta.xml" \
  --source-dir "$SRC/permissionsets/Merge_Manager_Access.permissionset-meta.xml" \
  --source-dir "$SRC/profiles" \
  --test-level NoTestRun \
  --target-org "$TARGET_ORG" \
  --verbose
