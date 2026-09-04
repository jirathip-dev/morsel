#!/usr/bin/env node
// infra/supabase/secrets.mjs — bootstrap Supabase project secrets BY NAME
// (issue #78). Reads VALUES from the local secret store at run time; the
// committed mapping (infra/supabase/secrets.json) contains NAMES only.
//
// The retained legacy Supabase Edge Function reads SUPABASE_URL,
// SUPABASE_ANON_KEY and MORSEL_OAUTH_SIGNING_KEY from its environment
// (docs/SUPABASE_OPERATIONS.md). This script pushes those values to the
// project via the Management API secrets endpoint:
//   POST /v1/projects/{ref}/secrets  body: [{ "name": ..., "value": ... }]
//
// SAFETY CONTRACT
// - DRY-RUN BY DEFAULT: without --apply only target/store NAMES are printed.
// - Values are held in memory and sent in the request body; they are never
//   printed, logged, or written to disk. Error paths print fixed messages.
// - Missing store names FAIL LOUDLY (exit 2) and nothing is applied — a
//   partial secret set must never be written.
// - MORSEL_OAUTH_AUTHORIZATION_ENDPOINT is deliberately NOT in the mapping:
//   per authorize-ui/README.md the repository never sets that live secret
//   (human-gated config step, issue #74).

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const API_BASE = "https://api.supabase.com/v1";
const DEFAULT_STORE = "~/.config/zsh/secrets.zsh";

export class UsageError extends Error {
  exitCode = 2;
}

export class SanitizedError extends Error {
  exitCode = 1;
}

export function loadMapping(root = HERE) {
  return JSON.parse(readFileSync(join(root, "secrets.json"), "utf8"));
}

// Guard: mapping targets must never overlap the documented exclusions and
// each entry must declare target + storeName (never a value).
export function validateMapping(mapping) {
  const errors = [];
  const excluded = new Set(mapping.excludedByName ?? []);
  const seen = new Set();
  for (const entry of mapping.secrets ?? []) {
    if (!entry.target || !entry.storeName) {
      errors.push("every secrets entry needs target and storeName (values never belong here)");
      continue;
    }
    if ("value" in entry) {
      errors.push(`entry ${entry.target} must not carry a literal value`);
    }
    if (excluded.has(entry.target)) {
      errors.push(`entry ${entry.target} is in excludedByName and must not be bootstrapped`);
    }
    if (seen.has(entry.target)) {
      errors.push(`duplicate target ${entry.target}`);
    }
    seen.add(entry.target);
  }
  if (mapping.secrets?.length !== seen.size) {
    errors.push("secrets mapping must not be empty");
  }
  return errors;
}

// Parse `export NAME=value` lines from the store text. Only the outer
// single/double quotes are stripped; values are otherwise opaque and are
// never echoed by callers.
export function parseStoreLines(text) {
  const map = new Map();
  for (const rawLine of String(text).split("\n")) {
    const line = rawLine.trim();
    if (!line.startsWith("export ")) continue;
    const eq = line.indexOf("=");
    if (eq <= 7) continue; // "export " is 7 chars; no empty names
    const name = line.slice(7, eq).trim();
    let value = line.slice(eq + 1);
    if (value.length >= 2) {
      const quote = value[0];
      if ((quote === "'" || quote === '"') && value.endsWith(quote)) {
        value = value.slice(1, -1);
      }
    }
    if (name && value !== "") map.set(name, value);
  }
  return map;
}

export function storePath() {
  const raw = process.env.SUPABASE_SECRET_STORE || DEFAULT_STORE;
  return raw.startsWith("~/") ? join(homedir(), raw.slice(2)) : raw;
}

// Resolve the committed name mapping against parsed store values. Returns
// { payload, missing } where payload is the Management API body and missing
// lists the store names that are absent (values themselves never returned).
export function resolveMapping(mapping, store) {
  const missing = [];
  const payload = [];
  for (const entry of mapping.secrets ?? []) {
    const value = store.get(entry.storeName);
    if (value === undefined) {
      missing.push(entry.storeName);
      continue;
    }
    payload.push({ name: entry.target, value });
  }
  return { payload, missing };
}

export function secretsUrl(ref) {
  return `${API_BASE}/projects/${ref}/secrets`;
}

export async function main(argv = process.argv.slice(2)) {
  try {
    const mapping = loadMapping();
    const mappingErrors = validateMapping(mapping);
    if (mappingErrors.length > 0) throw new UsageError(mappingErrors.join("; "));
    const apply = argv.includes("--apply");
    const ref = process.env.SUPABASE_PROJECT_REF;
    const token = process.env.SUPABASE_ACCESS_TOKEN;
    if (!ref) throw new UsageError("SUPABASE_PROJECT_REF is required.");
    if (!token) throw new UsageError("SUPABASE_ACCESS_TOKEN is required.");

    let text;
    try {
      text = readFileSync(storePath(), "utf8");
    } catch {
      throw new UsageError(
        `could not read the secret store at ${storePath()} (set SUPABASE_SECRET_STORE to override). Nothing was applied.`,
      );
    }
    const store = parseStoreLines(text);
    const { payload, missing } = resolveMapping(mapping, store);

    if (missing.length > 0) {
      throw new UsageError(
        `Local store (${storePath()}) is missing secret name(s): ${missing.join(", ")}. Nothing was applied.`,
      );
    }

    const names = payload.map((entry) => entry.name).join(", ");
    if (!apply) {
      console.log(`DRY RUN: would set Supabase project secrets for ${ref}: ${names} (values read from ${storePath()} by name; not printed)`);
      console.log("Re-run with --apply to write (human-gated).");
      return 0;
    }

    const response = await fetch(secretsUrl(ref), {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });
    if (!response.ok) {
      throw new SanitizedError(
        `POST secrets failed with status ${response.status} (details suppressed)`,
      );
    }
    console.log(`APPLIED Supabase project secrets for ${ref}: ${names} (names only; values came from the local store)`);
    return 0;
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
