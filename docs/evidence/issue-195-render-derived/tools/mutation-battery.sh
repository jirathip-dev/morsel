#!/bin/bash
# Issue #195 — mutation battery for the derived-work reuse.
# Each mutation reverts one mechanism of the fix; the durable suite must FAIL
# for every one of them (the count regression must bite on the un-reused path).
# Usage: bash docs/evidence/issue-195-render-derived/tools/mutation-battery.sh <lane-sim-udid>
set -u
UDID="${1:?usage: mutation-battery.sh <simulator-udid>}"
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$ROOT" || exit 1
VM="app/Sources/Morsel/ViewModel.swift"
JI="app/Sources/Morsel/JournalUI.swift"
OUT=".lane-logs/195-mutation-battery"
mkdir -p "$OUT"
cp -p "$VM" /tmp/m195-vm-pristine.swift
cp -p "$JI" /tmp/m195-ji-pristine.swift
echo "pristine sha256:"
shasum -a 256 "$VM" "$JI"

run_leg() {  # $1 = label
  local label="$1"
  HERDR_XCODEBUILD_DIRECT=1 flock /tmp/n.lock xcodebuild test \
    -project app/Morsel.xcodeproj -scheme Morsel \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath /tmp/morsel-195-dd \
    -only-testing:MorselTests/RenderDerivedReuseTests > "$OUT/$label.log" 2>&1
  local status=$?
  echo "MUTATION $label RAW_EXIT=$status"
  grep -E "error: -\[|Executed [0-9]+ tests" "$OUT/$label.log" | tail -6
  return 0
}

mutate() {  # $1 = file, $2 = old, $3 = new, $4 = label
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
assert src.count(old) == 1, ("match", src.count(old), old[:60])
open(path, "w").write(src.replace(old, new))
print("mutated", path)
PY
  run_leg "$4"
  cp -p /tmp/m195-vm-pristine.swift "$VM"
  cp -p /tmp/m195-ji-pristine.swift "$JI"
  echo "restored sha256:"
  shasum -a 256 "$VM" "$JI"
}

mutate "$VM" 'if let derivedCache, derivedCache.revision == derivedRevision { return derivedCache.value }' \
  'if let derivedCache, derivedCache.revision != derivedRevision { return derivedCache.value }' m1-cache-check-inverted

mutate "$VM" 'var totals: DashboardTotals { derived().totals }' \
  'var totals: DashboardTotals { DashboardMath.totals(for: snapshot?.meals ?? []) }' m2-totals-bypasses-cache

mutate "$VM" 'didSet { if snapshot?.meals != oldValue?.meals { derivedRevision &+= 1 } }' \
  'didSet { _ = oldValue }' m3-invalidation-removed

mutate "$JI" '        formatter.dateFormat = "dd.MMM.yyyy"
        return formatter' \
  '        formatter.dateFormat = "dd.MMM.yyyy"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter' m4-formatter-zone-pinned

echo "battery complete"
