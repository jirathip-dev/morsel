#!/bin/bash
# Issue #195 — base legs in a scratch worktree at the base commit.
# Leg 1: the durable reuse suite at base (no `derivedScanCount`): compile RED.
# Leg 2: the measurement probe at base: reproducible baseline numbers.
set -u
UDID="${1:?usage: base-legs.sh <simulator-udid>}"
BASE=1cf9ecc26b56037b53b34cc611425043bf21a36d
LANE=/Users/jirathip/.herdr/worktrees/morsel/issue-195-render-derived
SCRATCH=/tmp/m195-base-leg
rm -rf "$SCRATCH"
cd "$LANE" || exit 1
git worktree add --detach "$SCRATCH" "$BASE" || exit 1

cp app/Tests/MorselTests/RenderDerivedReuseTests.swift \
   app/Tests/MorselTests/RenderDerivedTestSupport.swift "$SCRATCH/app/Tests/MorselTests/"
(cd "$SCRATCH/app" && xcodegen generate >/dev/null)
HERDR_XCODEBUILD_DIRECT=1 flock /tmp/n.lock xcodebuild test \
  -project "$SCRATCH/app/Morsel.xcodeproj" -scheme Morsel \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath /tmp/morsel-195-base-dd \
  -only-testing:MorselTests/RenderDerivedReuseTests > "$LANE/.lane-logs/195-base-durable.log" 2>&1
echo "BASE_DURABLE_RAW_EXIT=$?"

cp app/Tests/MorselTests/RenderDerivedProbeTests.swift "$SCRATCH/app/Tests/MorselTests/"
rm -f "$SCRATCH/app/Tests/MorselTests/RenderDerivedReuseTests.swift"
(cd "$SCRATCH/app" && xcodegen generate >/dev/null)
HERDR_XCODEBUILD_DIRECT=1 flock /tmp/n.lock xcodebuild test \
  -project "$SCRATCH/app/Morsel.xcodeproj" -scheme Morsel \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath /tmp/morsel-195-base-dd \
  -only-testing:MorselTests/RenderDerivedProbeTests > "$LANE/.lane-logs/195-base-probe.log" 2>&1
echo "BASE_PROBE_RAW_EXIT=$?"
echo "base legs complete"
