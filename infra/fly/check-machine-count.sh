#!/usr/bin/env bash
# infra/fly/check-machine-count.sh — READ-ONLY Fly machine-count drift check
# (issue #78). The Morsel MCP origin MUST run as exactly ONE started machine:
# `fly deploy` has auto-created a second HA machine before (see
# docs/FLY_DEPLOY.md), and machine count is operational state pinned with
# `fly scale count 1`, not toml state.
#
# SAFETY CONTRACT
# - Issues only `fly machine list --json` (read-only). It never deploys,
#   scales, restarts, or writes anything to Fly.
# - Fails loudly (exit 1) on drift: zero machines, more than one machine, or
#   the single machine not started. Exit 2 on usage/CLI errors.
# - No secret values are read or printed.
set -euo pipefail

APP_NAME="${1:-morsel-mcp}"

if ! command -v fly >/dev/null 2>&1; then
  echo "✗ 'fly' CLI not found" >&2
  exit 2
fi

FLY_ERR="$(mktemp)"
trap 'rm -f "$FLY_ERR"' EXIT

# stderr is captured separately: flyctl prints warnings (e.g. metrics token
# notices) that must never be parsed as JSON. stdout is the JSON payload.
if ! OUTPUT="$(fly machine list -a "$APP_NAME" --json 2>"$FLY_ERR")"; then
  echo "✗ could not read machine list for '$APP_NAME' (read-only check failed; is 'fly auth' current?)" >&2
  head -3 "$FLY_ERR" >&2
  exit 2
fi

# node parses the JSON and reports machine/started counts; the JSON itself
# never reaches the terminal. The first '[' to the last ']' is used so stray
# flyctl banner lines around the payload cannot break the parse.
COUNTS="$(printf '%s' "$OUTPUT" | node -e '
  let raw = "";
  process.stdin.on("data", (d) => { raw += d; });
  process.stdin.on("end", () => {
    let machines;
    try {
      const start = raw.indexOf("[");
      const end = raw.lastIndexOf("]");
      machines = JSON.parse(raw.slice(start, end + 1));
    } catch {
      console.error("not-json");
      process.exit(2);
    }
    if (!Array.isArray(machines)) {
      console.error("unexpected-shape");
      process.exit(2);
    }
    const states = machines.map((m) => String(m.state || "unknown"));
    const started = states.filter((s) => s === "started").length;
    console.log(JSON.stringify({ machines: machines.length, started, states }));
  });
')" || {
  echo "✗ fly machine list did not return the expected JSON for '$APP_NAME'" >&2
  exit 2
}

echo "app=$APP_NAME $COUNTS"

STATES="$(printf '%s' "$COUNTS" | node -e 'let r="";process.stdin.on("data",d=>r+=d);process.stdin.on("end",()=>{const j=JSON.parse(r);console.log(`${j.machines} ${j.started}`)})')"
TOTAL="${STATES%% *}"
STARTED="${STATES##* }"

if [ "$TOTAL" = "1" ] && [ "$STARTED" = "1" ]; then
  echo "OK: exactly one started machine (no drift)"
  exit 0
fi

echo "DRIFT: expected exactly 1 started machine, found $TOTAL machine(s), $STARTED started." >&2
echo "Fix is a HUMAN action: 'fly scale count 1 -a $APP_NAME' (see docs/FLY_DEPLOY.md), then re-run this check." >&2
exit 1
