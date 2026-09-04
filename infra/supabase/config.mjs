#!/usr/bin/env node
// infra/supabase/config.mjs — Supabase Auth config as code + read-only drift
// verification (issue #78).
//
// The canonical values live in infra/supabase/config.json (no secrets). This
// script talks to the Supabase Management API for ONE project:
//
//   check  (default, READ-ONLY) — GET /config/auth and assert every pinned
//          value plus the magic-link template invariant. Fails loudly
//          (exit 1) on any drift. This is the drift check a cron/CI or a
//          human may run; it never writes.
//   diff   (READ-ONLY) — same GET, prints intended vs live for drifted keys
//          (exit 0 when the read succeeds; informational).
//   apply  (MUTATING, HUMAN-GATED) — GET live config, overlay the pinned
//          canonical keys, PUT it back, then re-GET and re-run the check.
//          REQUIRES the literal --yes flag and a readable SMTP password:
//          env RESEND_API_KEY_MORSEL (the store name; value from the local
//          store) or an existing live smtp_pass to preserve.
//
// SAFETY CONTRACT
// - Secret values are consumed from the environment ONLY and are never
//   logged. Every error path prints a FIXED message (status code at most) —
//   raw response/request text that could embed a value is suppressed.
// - Environment names follow the repo convention (scripts/migration-*.mjs):
//   SUPABASE_PROJECT_REF and SUPABASE_ACCESS_TOKEN.
// - smtp_pass is never read from config.json (a guard rejects it) and is
//   never compared by drift checks; it is a secret.
// - apply refuses to run without --yes and refuses to PUT a config whose
//   smtp_pass would be blanked.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const API_BASE = "https://api.supabase.com/v1";
const SMTP_PASS_ENV = "RESEND_API_KEY_MORSEL";

export class UsageError extends Error {
  exitCode = 2;
}

export class SanitizedError extends Error {
  exitCode = 1;
}

export function loadCanonical(root = HERE) {
  return JSON.parse(readFileSync(join(root, "config.json"), "utf8"));
}

// Guard: the canonical file must never carry secret-bearing keys. This runs
// at startup and is unit-tested so a future edit cannot sneak smtp_pass (or
// any listed key) into the committed config.
export function validateCanonical(canonical) {
  const banned = canonical.neverInConfig ?? [];
  const errors = [];
  for (const key of banned) {
    if (key in (canonical.pinned ?? {})) {
      errors.push(`canonical config must not pin secret key "${key}"`);
    }
  }
  if (!canonical.pinned || typeof canonical.pinned !== "object") {
    errors.push("canonical config must declare a pinned object");
  }
  if (!canonical.templateInvariant?.field || !canonical.templateInvariant?.contains) {
    errors.push("canonical config must declare a templateInvariant {field, contains}");
  }
  return errors;
}

// Pure drift comparison over a live auth-config object. Returns an array of
// human-readable mismatch strings (empty = no drift). Pinned values are
// compared as strings so 6 vs "6" from the API never false-positives.
export function driftEntries(canonical, live) {
  const entries = [];
  const pinned = canonical.pinned ?? {};
  for (const [key, expected] of Object.entries(pinned)) {
    const actual = live?.[key];
    if (String(actual) !== String(expected)) {
      entries.push(`${key}: expected ${JSON.stringify(expected)}, live ${JSON.stringify(actual)}`);
    }
  }
  const field = canonical.templateInvariant?.field;
  const needle = canonical.templateInvariant?.contains;
  const content = live?.[field];
  if (typeof content !== "string" || !content.includes(needle)) {
    entries.push(`${field}: expected to contain ${JSON.stringify(needle)}`);
  }
  return entries;
}

// Pure overlay used by apply: live config + pinned canonical keys, with
// smtp_pass handled as a secret (env value wins, else the live value is
// preserved). Returns null when no SMTP password is available at all.
export function overlayForApply(canonical, live, smtpPass) {
  const overlay = { ...live };
  for (const [key, value] of Object.entries(canonical.pinned ?? {})) {
    overlay[key] = value;
  }
  if (smtpPass !== undefined && smtpPass !== null && smtpPass !== "") {
    overlay.smtp_pass = smtpPass;
  } else if (!overlay.smtp_pass) {
    return null; // would blank the SMTP password — caller must refuse
  }
  return overlay;
}

export function authConfigUrl(ref) {
  return `${API_BASE}/projects/${ref}/config/auth`;
}

async function readAuthConfig(ref, token) {
  const response = await fetch(authConfigUrl(ref), {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!response.ok) {
    throw new SanitizedError(
      `GET auth config failed with status ${response.status} (details suppressed)`,
    );
  }
  return response.json();
}

async function writeAuthConfig(ref, token, config) {
  const response = await fetch(authConfigUrl(ref), {
    method: "PUT",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(config),
  });
  if (!response.ok) {
    throw new SanitizedError(
      `PUT auth config failed with status ${response.status} (details suppressed)`,
    );
  }
  // The PUT response body is not consumed: it is not needed and must not be
  // logged. The postcondition re-GET in apply is the source of truth.
  return undefined;
}

function requireEnv() {
  const ref = process.env.SUPABASE_PROJECT_REF;
  const token = process.env.SUPABASE_ACCESS_TOKEN;
  if (!ref) throw new UsageError("SUPABASE_PROJECT_REF is required.");
  if (!token) throw new UsageError("SUPABASE_ACCESS_TOKEN is required.");
  return { ref, token };
}

function report(entries) {
  if (entries.length === 0) {
    console.log("OK: no drift — all pinned Supabase auth config values match (SMTP host/user, OTP length 6, template {{ .Token }}, rate limit 30).");
    return 0;
  }
  console.error("DRIFT (Supabase auth config):");
  for (const entry of entries) console.error(`  - ${entry}`);
  console.error("Re-apply with: node infra/supabase/config.mjs diff (read-only), then apply per docs/SUPABASE_OPERATIONS.md (human-gated).");
  return 1;
}

export async function main(argv = process.argv.slice(2)) {
  const command = argv[0] ?? "check";
  const rest = argv.slice(1);
  try {
    const canonical = loadCanonical();
    const canonicalErrors = validateCanonical(canonical);
    if (canonicalErrors.length > 0) {
      throw new UsageError(canonicalErrors.join("; "));
    }
    const { ref, token } = requireEnv();

    if (command === "check" || command === "diff") {
      if (rest.length > 0) {
        throw new UsageError(`"${command}" accepts no extra arguments.`);
      }
      const live = await readAuthConfig(ref, token);
      const entries = driftEntries(canonical, live);
      if (command === "diff") {
        if (entries.length === 0) {
          console.log("diff: no drift (live auth config matches infra/supabase/config.json)");
        } else {
          console.log("diff: intended vs live (from infra/supabase/config.json):");
          for (const entry of entries) console.log(`  - ${entry}`);
        }
        return 0; // informational; the read succeeded
      }
      return report(entries);
    }

    if (command === "apply") {
      if (!rest.includes("--yes")) {
        throw new UsageError(
          'apply is MUTATING and human-gated: re-run with the literal "--yes" flag after reviewing `diff`.',
        );
      }
      const live = await readAuthConfig(ref, token);
      const smtpPass = process.env[SMTP_PASS_ENV] ?? "";
      const overlay = overlayForApply(canonical, live, smtpPass);
      if (!overlay) {
        throw new UsageError(
          `No SMTP password available: set ${SMTP_PASS_ENV} (value from the local store, by name) or leave the live smtp_pass in place. Refusing to PUT a config without it.`,
        );
      }
      const changedKeys = Object.keys(canonical.pinned).filter(
        (key) => String(overlay[key]) !== String(live[key]),
      );
      console.log(`apply: PUT auth config for project ${ref} (changed keys: ${changedKeys.join(", ") || "none"})`);
      await writeAuthConfig(ref, token, overlay);
      const after = await readAuthConfig(ref, token);
      const entries = driftEntries(canonical, after);
      console.log("apply: postcondition re-check");
      return report(entries);
    }

    throw new UsageError('unknown command (expected "check", "diff", or "apply")');
  } catch (error) {
    if (error instanceof UsageError || error instanceof SanitizedError) {
      console.error(`✗ ${error.message}`);
    } else {
      console.error("✗ failed (error details suppressed)");
    }
    return error instanceof UsageError ? error.exitCode : 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(await main());
}
