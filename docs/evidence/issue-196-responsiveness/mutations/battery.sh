#!/usr/bin/env bash
# Issue #196 — per-mechanism mutation battery.
#
# Each mutation targets ONE audited mechanism; the named harness assertion must
# FAIL on it (RED: raw exit 65, non-zero failure count). Every restore is
# sha256-proven byte-identical to the committed head, and the restored tree
# must pass (GREEN). Committed excerpts land in mutations/excerpts/; the full
# raw xcodebuild logs stay in /tmp/morsel-196-raw-*.txt.
#
# Usage:  MORSEL_SIM_UDID=<udid> bash mutations/battery.sh <green|1..6>
set -u
REPO="$(cd "$(dirname "$0")/../../../.." && pwd)"
SIM="${MORSEL_SIM_UDID:?set MORSEL_SIM_UDID to the lane simulator}"
DD="${MORSEL_DD:-/tmp/morsel-196-dd}"
OUT="$REPO/docs/evidence/issue-196-responsiveness/mutations/excerpts"
mkdir -p "$OUT"
cd "$REPO/app" || exit 1

TURNER="Sources/Morsel/JournalPageTurner.swift"
OWNER="Sources/Morsel/TodayRefreshOwner.swift"
SHELL="Sources/Morsel/MorselApp.swift"

run_class() { # $1 class, $2 excerpt path
  local class="$1" log="$2" raw="/tmp/morsel-196-raw-$1.txt"
  HERDR_XCODEBUILD_DIRECT=1 flock /tmp/n.lock xcodebuild test \
    -project Morsel.xcodeproj -scheme Morsel \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO -only-testing:"MorselTests/$class" > "$raw" 2>&1
  local code=$?
  {
    echo "# command: xcodebuild test -only-testing:MorselTests/$class -derivedDataPath $DD"
    grep -E "Test Case .*(passed|failed)|Executed [0-9]+ tests|ISSUE196-|error:" "$raw" \
      | sed -e 's/[[:space:]]*$//'
    echo "RAW_EXIT=$code"
    echo "# full log: $raw"
  } > "$log"
  echo "$class RAW_EXIT=$code -> $log"
  return $code
}

snapshot() { # $1 file, $2 backup
  cp "$1" "$2"
  shasum -a 256 "$1" | awk '{print $1}' > "$2.sha"
}

restore() { # $1 file, $2 backup — byte-identical or the battery aborts
  cp "$2" "$1"
  touch "$1"
  local now want
  now=$(shasum -a 256 "$1" | awk '{print $1}')
  want=$(cat "$2.sha")
  if [ "$now" != "$want" ]; then
    echo "RESTORE MISMATCH for $1: $now != $want" >&2
    exit 9
  fi
  echo "restored $1 sha256=$now"
}

m1() { python3 - "$REPO" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "app/Sources/Morsel/JournalPageTurner.swift"
s = p.read_text()
old = """            if newTab == active.incoming {
                return // our own drag-commit echo; the settle is running
            }
            // Retarget mid-swing"""
new = """            if newTab == active.incoming {
                return // our own drag-commit echo; the settle is running
            }
            return // MUTATION 1 — retargets mid-swing are ignored
            // Retarget mid-swing"""
assert old in s, "anchor m1 missing"
p.write_text(s.replace(old, new, 1))
print("m1 applied")
PY
}

m2() { python3 - "$REPO" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "app/Sources/Morsel/JournalPageTurner.swift"
s = p.read_text()
old = """        if abs(deltaX) > abs(deltaY) {
            axis = .horizontal"""
new = """        if true { // MUTATION 2 — vertical intent no longer owns the gesture
            axis = .horizontal"""
assert old in s, "anchor m2 missing"
p.write_text(s.replace(old, new, 1))
print("m2 applied")
PY
}

m3() { python3 - "$REPO" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "app/Sources/Morsel/MorselApp.swift"
s = p.read_text()
old = """            .allowsHitTesting(owns(tab))
            .disabled(!owns(tab))
            .accessibilityHidden(!owns(tab))"""
new = """            .allowsHitTesting(owns(tab))
            .disabled(false) // MUTATION 3 — every mounted page stays activatable
            .accessibilityHidden(!owns(tab))"""
assert old in s, "anchor m3 missing"
p.write_text(s.replace(old, new, 1))
print("m3 applied")
PY
}

m4() { python3 - "$REPO" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "app/Sources/Morsel/JournalPageTurner.swift"
s = p.read_text()
old = """    func interrupt() {
        axis = nil"""
new = """    func interrupt() {
        axis = nil
        if true { return } // MUTATION 4 — interruptions settle nothing"""
assert old in s, "anchor m4 missing"
p.write_text(s.replace(old, new, 1))
print("m4 applied")
PY
}

m5() { python3 - "$REPO" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "app/Sources/Morsel/TodayRefreshOwner.swift"
s = p.read_text()
old = """            active.keepsAlive = active.keepsAlive || keepsAlive
            return active
        }"""
new = """            active.keepsAlive = active.keepsAlive || keepsAlive
            // MUTATION 5 — the in-flight pass is no longer joined
        }"""
assert old in s, "anchor m5 missing"
p.write_text(s.replace(old, new, 1))
print("m5 applied")
PY
}

m6() { python3 - "$REPO" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "app/Sources/Morsel/TodayRefreshOwner.swift"
s = p.read_text()
old = """        guard let flight = active else { return }
        active = nil"""
new = """        guard let flight = active else { return }
        if true { return } // MUTATION 6 — cancellation is dropped
        active = nil"""
assert old in s, "anchor m6 missing"
p.write_text(s.replace(old, new, 1))
print("m6 applied")
PY
}

one() { # $1 number, $2 file, $3 class
  local backup="/tmp/morsel-196-mut-$1.bak"
  snapshot "$2" "$backup"
  "m$1"
  run_class "$3" "$OUT/mutation-$1-red.txt"
  restore "$2" "$backup"
}

case "${1:-all}" in
  green)
    run_class ResponsivenessShellCycleTests "$OUT/green-shell-cycles.txt"
    run_class ResponsivenessBudgetTests "$OUT/green-budget.txt"
    run_class ResponsivenessIntervalsTests "$OUT/green-intervals.txt" ;;
  1) one 1 "$TURNER" ResponsivenessShellCycleTests ;;
  2) one 2 "$TURNER" ResponsivenessShellCycleTests ;;
  3) one 3 "$SHELL" ResponsivenessShellCycleTests ;;
  4) one 4 "$TURNER" ResponsivenessShellCycleTests ;;
  5) one 5 "$OWNER" ResponsivenessBudgetTests ;;
  6) one 6 "$OWNER" ResponsivenessBudgetTests ;;
  *) echo "usage: battery.sh <green|1..6>" >&2; exit 2 ;;
esac
