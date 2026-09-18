#!/bin/bash
# Issue #195 — bounded Time Profiler attempt against the simulator test host.
# Records the probe run's workload with `xctrace`; the raw outcome (including a
# refusal) is the evidence, and no frame-rate claim is derived from it.
set -u
UDID="${1:?usage: xctrace-attempt.sh <simulator-udid>}"
LANE=/Users/jirathip/.herdr/worktrees/morsel/issue-195-render-derived
cd "$LANE" || exit 1
rm -f /tmp/m195-baseline.trace
HERDR_XCODEBUILD_DIRECT=1 flock /tmp/n.lock xcodebuild test \
  -project app/Morsel.xcodeproj -scheme Morsel \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath /tmp/morsel-195-dd \
  -only-testing:MorselTests/RenderDerivedProbeTests > .lane-logs/195-xctrace-run.log 2>&1 &
RUNPID=$!
HOST=""
for _ in $(seq 1 300); do
  HOST=$(pgrep -f "Devices/$UDID/data/Containers/Bundle/Application/.*Morsel.app/Morsel" | head -1)
  [ -n "$HOST" ] && break
  sleep 1
done
echo "host pid: ${HOST:-none}"
if [ -n "$HOST" ]; then
  for attempt in 1 2 3 4 5; do
    if ! kill -0 "$HOST" 2>/dev/null; then
      echo "attempt $attempt: host pid exited before attach"
      break
    fi
    xcrun xctrace record --attach "$HOST" --template 'Time Profiler' --time-limit 15s \
      --output /tmp/m195-baseline.trace 2>&1 | tail -10
    echo "attempt $attempt XCTRACE_RECORD_EXIT=${PIPESTATUS[0]:-$?}"
    [ -f /tmp/m195-baseline.trace ] && break
    sleep 2
  done
  xcrun xctrace export --input /tmp/m195-baseline.trace --toc 2>&1 | head -20
  echo "XCTRACE_EXPORT_EXIT=$?"
else
  echo "XCTRACE_SKIPPED=no host process appeared"
fi
wait "$RUNPID"
echo "PROBE_RAW_EXIT=$?"
