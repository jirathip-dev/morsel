#!/usr/bin/env bash
# infra/fly/app-create.sh — one-time Fly app creation for a NEW Morsel stack
# (issue #78). Part of the from-scratch recreation path; NEVER used against
# the live app.
#
# SAFETY CONTRACT
# - DRY-RUN BY DEFAULT: without --apply this script only prints the exact
#   commands an operator would run. It never talks to Fly.
# - The live app name "morsel-mcp" is refused UNCONDITIONALLY (even with
#   --apply) so this script can never re-create or touch the production app.
# - With --apply the script runs exactly one command: `fly apps create`.
#   Deploying, setting secrets, and scaling belong to the runbook
#   (docs/FLY_DEPLOY.md) and stay human-driven, step by step.
# - No secret values are read, printed, or passed by this script.
set -euo pipefail

LIVE_APP="morsel-mcp"

usage() {
  cat <<'EOF'
Usage: infra/fly/app-create.sh <new-app-name> --org <fly-org> [--apply]

Creates a NEW Fly app for a fresh Morsel stack (dry run by default).

  <new-app-name>  app name for the new stack (must not be the live app)
  --org <org>     Fly org to create the app in (required)
  --apply         actually run `fly apps create` (default: print only)

The new app's fly.toml deploy, secret import, and `fly scale count 1` guard
are runbook steps in docs/FLY_DEPLOY.md — this script does not deploy.
EOF
}

if [ "$#" -lt 1 ]; then
  usage
  exit 2
fi

APP_NAME="$1"
shift
ORG=""
APPLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --org)
      ORG="${2:-}"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "✗ unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ -z "$ORG" ]; then
  echo "✗ --org <fly-org> is required" >&2
  exit 2
fi

if [ "$APP_NAME" = "$LIVE_APP" ]; then
  echo "✗ refusing the live app name '$LIVE_APP': fresh-project recreation must use a different app name" >&2
  exit 3
fi

if ! printf '%s' "$APP_NAME" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
  echo "✗ invalid Fly app name '$APP_NAME' (lowercase letters, digits, hyphens)" >&2
  exit 2
fi

echo "# DRY RUN — would run against Fly org '$ORG' for new app '$APP_NAME':"
echo "fly auth login"
echo "fly apps create \"$APP_NAME\" --org \"$ORG\""
echo "# then follow docs/FLY_DEPLOY.md: set secrets, fly deploy, and the"
echo "# machine-count guard 'fly scale count 1' — plus infra/fly/check-machine-count.sh."

if [ "$APPLY" -eq 1 ]; then
  command -v fly >/dev/null 2>&1 || { echo "✗ 'fly' CLI not found" >&2; exit 2; }
  echo "# APPLY — creating app '$APP_NAME' in org '$ORG'..."
  fly apps create "$APP_NAME" --org "$ORG"
  echo "# created '$APP_NAME'. Next: docs/FLY_DEPLOY.md (secrets, deploy, scale guard)."
fi
