#!/usr/bin/env bash
# Publishes the Data Update Center Experience sites ONE AT A TIME and checks that each one really
# serves the new build.
#
# Why: `sf community publish` on two LWR sites seconds apart sometimes leaves the second one on the
# previous build (same view hash → old LWC code), and it only shows up when someone opens the page.
# This script publishes a site, waits until its view hash changes, republishes once if it does not,
# and only then moves on to the next site.
#
# Usage:  ./publish-sites.sh [org-alias]          (default: aebeq3--partialae)
# Sandbox only: it refuses a production org.

set -uo pipefail

ORG="${1:-aebeq3--partialae}"
WAIT_SECS=180     # how long to wait for the new build after each publish
POLL_SECS=15

# "Network name|URL path" — one line per site, published in this order.
if [[ "$ORG" == *sembeq* ]]; then
  SITES=(
    "Mise à jour de compte SEMBEQ|majcompte"
  )
else
  SITES=(
    "Mise à jour de compte AEBEQ|majcompte"
    "Mise à jour de compte Églises AEBEQ|majeglise"
  )
fi

info=$(sf org display -o "$ORG" --json 2>/dev/null) || { echo "✗ Cannot read org $ORG"; exit 1; }
read -r INSTANCE IS_SANDBOX < <(python3 -I -c '
import json, sys
r = json.load(sys.stdin)["result"]
print(r.get("instanceUrl", ""), "sandbox" in r.get("instanceUrl", ""))' <<<"$info")

if [[ "$IS_SANDBOX" != "True" ]]; then
  echo "✗ $ORG ($INSTANCE) is not a sandbox — this script never publishes production sites."
  exit 1
fi
SITE_BASE="${INSTANCE/my.salesforce.com/my.site.com}"

view_hash() {
  curl -s --max-time 30 "$SITE_BASE/$1/?cb=$RANDOM$RANDOM" \
    | grep -oE 'view/[a-f0-9]+/prod/[^/]+/home_view' | head -1 | cut -d/ -f2
}

# Waits until the hash differs from $2; prints the new hash, or nothing on timeout.
wait_new_hash() {
  local path=$1 old=$2 waited=0 now
  while (( waited < WAIT_SECS )); do
    sleep "$POLL_SECS"; waited=$((waited + POLL_SECS))
    now=$(view_hash "$path")
    if [[ -n "$now" && "$now" != "$old" ]]; then echo "$now"; return 0; fi
  done
  return 1
}

status=0
for entry in "${SITES[@]}"; do
  name=${entry%%|*}; path=${entry##*|}
  before=$(view_hash "$path")
  echo "── $name  ($SITE_BASE/$path)"
  echo "   current build: ${before:-unknown}"

  for attempt in 1 2; do
    sf community publish -n "$name" -o "$ORG" >/dev/null 2>&1 \
      || { echo "   ✗ publish command failed (attempt $attempt)"; continue; }
    echo "   publish $attempt sent, waiting for the new build…"
    if after=$(wait_new_hash "$path" "$before"); then
      echo "   ✓ new build: $after"
      continue 2
    fi
  done

  echo "   ⚠ build did not change after 2 publishes."
  echo "     Expected only if no LWC/site code changed since the last publish; otherwise check by hand."
  status=2
done
exit $status
