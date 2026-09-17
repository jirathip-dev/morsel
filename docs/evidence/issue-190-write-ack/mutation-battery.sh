#!/bin/bash
# Issue #190 mutation battery — one mutation per defended mechanism, one focused
# invocation each, raw exit + failing count recorded immediately, every file
# restored byte-identically (sha256 before AND after).
#
# Run from the lane checkout root:  bash docs/evidence/issue-190-write-ack/mutation-battery.sh
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
APP="$ROOT/app"
LOGS="$ROOT/.lane-logs"
OUT="$LOGS/mutation-battery.log"
VM="$ROOT/app/Sources/Morsel/ViewModel.swift"
WA="$ROOT/app/Sources/Morsel/WriteAcknowledgement.swift"
GE="$ROOT/app/Sources/Morsel/GoalsEditorModel.swift"
MA="$ROOT/app/Sources/Morsel/MorselApp.swift"

mkdir -p "$LOGS"
: > "$OUT"

mutate() { # file, python-replacement-expr(old,new)
  python3 - "$1" "$2" "$3" <<'PY'
import sys, pathlib
path, old, new = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
assert text.count(old) == 1, f"mutate: {old!r} appears {text.count(old)}x"
path.write_text(text.replace(old, new))
PY
}

run_suite() { # name, class
  local name="$1" cls="$2"
  ( cd "$APP" && flock /tmp/n.lock xcodebuild test -project Morsel.xcodeproj -scheme Morsel \
      -derivedDataPath /tmp/morsel-190-dd -resultBundlePath "/tmp/morsel-190-$name.xcresult" \
      -parallel-testing-enabled NO -jobs 2 -test-timeouts-enabled YES \
      -maximum-test-execution-time-allowance 60 CODE_SIGNING_ALLOWED=NO \
      "-only-testing:MorselTests/$cls" > "$LOGS/mutation-$name.log" 2>&1 )
  local raw=$?
  local failed
  failed=$(rg -c "error: -\[MorselTests" "$LOGS/mutation-$name.log" 2>/dev/null || echo 0)
  local executed
  executed=$(rg -o "Executed [0-9]+ tests" "$LOGS/mutation-$name.log" | tail -1)
  echo "MUTATION $name raw_exit=$raw failing_tests=$failed $executed" | tee -a "$OUT"
  rg -n "error: -\[MorselTests" "$LOGS/mutation-$name.log" | sed 's/^/    /' | sort -u | head -8 | tee -a "$OUT"
}

restore() { # file, pristine-copy
  cp "$2" "$1"
  local got want
  got=$(shasum -a 256 "$1" | cut -d' ' -f1)
  want=$(shasum -a 256 "$2" | cut -d' ' -f1)
  echo "  restored $1 sha256=$got match=$([ "$got" = "$want" ] && echo yes || echo NO)" | tee -a "$OUT"
  [ "$got" = "$want" ] || { echo "RESTORE FAILED — halting" | tee -a "$OUT"; exit 1; }
}

cp "$VM" /tmp/m190-VM.pristine; cp "$WA" /tmp/m190-WA.pristine
cp "$GE" /tmp/m190-GE.pristine; cp "$MA" /tmp/m190-MA.pristine

echo "== pristine hashes" | tee -a "$OUT"
shasum -a 256 "$VM" "$WA" "$GE" "$MA" | tee -a "$OUT"

# M1 — the invalidated pass stops superseding the pre-mutation one (#182 revision).
mutate "$VM" "        _ = startRefresh(invalidating: true, keepsAlive: true)
        guard let day else { return }" \
            "        _ = startRefresh(invalidating: false, keepsAlive: true)
        guard let day else { return }"
run_suite "m1-no-invalidation" WriteAckConfirmTests
restore "$VM" /tmp/m190-VM.pristine

# M2 — a repeated tap no longer joins the write in flight.
mutate "$WA" "        writesInFlight[key] = task" "        _ = task"
run_suite "m2-no-join" WriteAckConfirmTests
restore "$WA" /tmp/m190-WA.pristine

# M3 — the confirmed write invalidates but projects no acknowledged record.
mutate "$VM" "        self.snapshot = acknowledged(day)" "        _ = acknowledged(day)"
run_suite "m3-no-projection" WriteAckConfirmTests
restore "$VM" /tmp/m190-VM.pristine

# M4 — the acknowledged item fabricates a confident row.
mutate "$WA" "                 confidence: confidence ?? item.confidence," \
             "                 confidence: confidence ?? 1.0,"
run_suite "m4-fabricated-confidence" WriteAckConfirmTests
restore "$WA" /tmp/m190-WA.pristine

# M5 — the acknowledged delete drops every meal, not just the acknowledged one.
mutate "$VM" "            confirmedWrite { confirmingMeals(\$0) { \$0.mealLogID == mealLogID ? nil : \$0 } }" \
             "            confirmedWrite { confirmingMeals(\$0) { _ in nil } }"
run_suite "m5-delete-all-meals" WriteAckConfirmTests
restore "$VM" /tmp/m190-VM.pristine

# M6 — the shipped Goals wiring awaits a full reload again.
mutate "$MA" "onSaved: { viewModel.invalidateDayAfterConfirmedGoals() }" \
             "onSaved: { await viewModel.invalidateDay() }"
run_suite "m6-goals-awaiting-wiring" WriteAckGoalsTests
restore "$MA" /tmp/m190-MA.pristine

# M7 — the Goals save accepts a second concurrent submission.
mutate "$GE" "guard pendingDirection == nil, !isSaving else { return false }" \
             "guard pendingDirection == nil else { return false }"
run_suite "m7-goals-double-tap" WriteAckGoalsTests
restore "$GE" /tmp/m190-GE.pristine

echo "== final hashes" | tee -a "$OUT"
shasum -a 256 "$VM" "$WA" "$GE" "$MA" | tee -a "$OUT"
echo "BATTERY DONE" | tee -a "$OUT"
