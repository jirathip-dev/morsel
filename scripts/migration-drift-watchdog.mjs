#!/usr/bin/env node
// Morsel issue #83 — migration drift watchdog (READ-ONLY).
//
// Compares the LIVE project's public.migration_ledger end-state against
// main's migration manifest (db/migrations/**) after a read-only reconcile,
// and reports drift:
//   - the ledger is missing (bootstrap state),
//   - ledger entries have no local migration file on main (the live project
//     is ahead of or diverged from main),
//   - local migrations on main are not recorded (the live project is behind
//     main — pending migrations were never applied).
// A clean state stays SILENT (DRIFT=false, exit 0). The scheduled Migration
// Drift Watchdog workflow opens/refreshes an issue only when DRIFT=true.
//
// The live read goes through scripts/migration-reconcile.mjs (fixed-SELECT
// allowlist, read-only by construction); the ledger names returned there
// match the local manifest, and non-matching rows surface only as a count.
// This script never writes: no migration SQL, no ledger rows, no issues
// (issue creation is the workflow's gh step, which reads this script's
// summary only). Secrets are consumed from the environment only and are
// never logged.

import { readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseMigrationNames } from "./migration-safety.mjs";
import { run as reconcileRun, UsageError, validateRawEnvValue } from "./migration-reconcile.mjs";

// Pure drift evaluation. `local` is the parsed main manifest; `ledgerNames`
// are the ledger rows that match the local manifest (reconcile semantics);
// non-matching ledger rows are counted in unknownLedgerCount.
export function driftVerdict({ ledgerExists = true, ledgerNames = [], unknownLedgerCount = 0, local = [] }) {
  const issues = [];
  const recordedSet = new Set(ledgerNames);
  if (!ledgerExists) {
    issues.push("public.migration_ledger is MISSING on the live project — nothing is recorded and schema provenance is unknown.");
  }
  if (unknownLedgerCount > 0) {
    issues.push(
      `${unknownLedgerCount} recorded ledger ${unknownLedgerCount === 1 ? "entry has" : "entries have"} no local migration file on main — the live project is ahead of or diverged from main.`,
    );
  }
  const missing = local.filter((migration) => !recordedSet.has(migration.name));
  if (missing.length > 0) {
    issues.push(
      `${missing.length} local migration(s) on main are NOT recorded on the live project (the live project is behind main): ${missing.map((migration) => migration.file).join(", ")}.`,
    );
  }
  return { drift: issues.length > 0, issues };
}

export function formatVerdict(result) {
  const lines = [];
  lines.push("Morsel migration drift watchdog — main manifest vs live project ledger (READ-ONLY)");
  if (result.drift) {
    lines.push("DRIFT=true");
    lines.push(`drift findings: ${result.issues.length}`);
    for (const issue of result.issues) {
      lines.push(`  - ${issue}`);
    }
    lines.push("Action: reconcile the live project (Deploy Migrations (Recovery Apply), manual dispatch-only) or apply the pending forward-only tail once Migration CD is enabled; see docs/MIGRATION_RECOVERY.md.");
  } else {
    lines.push("DRIFT=false");
    lines.push("clean: the live project's migration ledger matches main's migration end-state.");
  }
  return lines.join("\n");
}

export async function run({ ref, token, root, queryImpl = null, log = console }) {
  const reconciled = await reconcileRun({ ref, token, root, queryImpl, log });
  const local = parseMigrationNames(
    readdirSync(join(root, "db", "migrations")).filter((file) => file.endsWith(".sql")),
  );
  const result = driftVerdict({
    ledgerExists: reconciled.ledgerExists,
    ledgerNames: reconciled.ledgerNames,
    unknownLedgerCount: reconciled.unknownLedgerCount,
    local,
  });
  const report = formatVerdict(result);
  log.log(report);
  return result;
}

export async function main(argv = process.argv.slice(2), env = process.env) {
  const root = dirname(dirname(fileURLToPath(import.meta.url)));
  try {
    if (argv.length > 0) {
      throw new UsageError("migration-drift-watchdog accepts no arguments.");
    }
    const rawRef = env.SUPABASE_PROJECT_REF;
    const rawToken = env.SUPABASE_ACCESS_TOKEN;
    if (!rawRef) throw new UsageError("SUPABASE_PROJECT_REF is required.");
    if (!rawToken) throw new UsageError("No Management API token found. Set SUPABASE_ACCESS_TOKEN.");
    validateRawEnvValue("SUPABASE_PROJECT_REF", rawRef);
    validateRawEnvValue("SUPABASE_ACCESS_TOKEN", rawToken);
    await run({ ref: rawRef, token: rawToken, root });
    return 0;
  } catch (error) {
    if (error instanceof UsageError) {
      console.error(`✗ ${error.message}`);
      return error.exitCode;
    }
    console.error("✗ migration drift watchdog failed (error details suppressed)");
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(await main());
}
