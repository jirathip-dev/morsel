# Morsel MCP server on Fly.io (issue #72) — single Bun process.
#
# The portable Hono app (server/app.ts) runs as ONE long-lived Bun process so
# the in-memory MCP session map survives across requests (Supabase Edge
# Function isolates cannot hold sessions, issue #71). Supabase stays the
# Auth/Postgres/RLS store; this image only serves the MCP/OAuth HTTP surface.
#
# Deterministic install: package-lock.json is the canonical lockfile (the
# repo has no bun.lock and the image ships no npm; bun installs from
# package-lock.json when bun.lock is absent). No secret values live in this
# file or any layer: every configuration value arrives at runtime through
# `fly secrets set` (see docs/FLY_DEPLOY.md). Environment NAMES only.
FROM oven/bun:1.2.23-debian

WORKDIR /app

COPY package.json package-lock.json ./
RUN bun install --no-progress

# Minimal runtime source: the shared Hono server (entry point included) and
# the schema package it imports. Test files under server/ ride along so the
# committed real-HTTP session regression can run inside this image.
COPY server ./server
COPY packages ./packages

# fly.toml [http_service].internal_port; the entry point also defaults to it.
ENV PORT=8080
EXPOSE 8080

# One process owns the session map; the image user is non-root.
USER bun

CMD ["bun", "server/fly-entrypoint.ts"]
