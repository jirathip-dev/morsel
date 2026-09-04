#!/usr/bin/env node
// Morsel issue #83 — migration CD classifier (READ-ONLY).
//
// Decides whether the migration delta pending against the live project's
// public.migration_ledger is a CLEAN FORWARD-ONLY tail that MAY be
// auto-applied by the Migration CD workflow after a merge to main, or must
// stay on the manual dispatch-only path. This script NEVER writes: it
// executes no migration SQL, inserts no ledger rows, and opens no
// transaction.
//
// Verdicts (autoApply is true ONLY for clean-forward-only):
//   clean-forward-only — every unrecorded local migration is a NEW version
//       strictly newer than the newest recorded one, and the triggering merge
//       changed no already-recorded migration file (no retro-edit).
//   repair-required    — an unrecorded migration is NOT newer than the newest
//       recorded one (a backward/repair edit). Never auto-applied.
//   retro-edit         — the triggering merge edited a db/migrations file
//       that is already recorded, or a file not newer than the newest
//       recorded version. Never auto-applied.
//   ambiguous          — ledger missing/empty, unknown ledger entries, or
//       recorded entries matching no local migration. Never auto-applied.
//   up-to-date         — nothing is pending; nothing to apply.
//
// Inputs
// - local manifest: db/migrations/** (db/migrations/000N_name.sql) at the
//   checkout root.
// - live ledger end-state: read ONLY through scripts/migration-reconcile.mjs
//   (fixed-SELECT allowlist guards every hosted query; reconcile is
//   read-only by construction).
// - MIGRATION_CD_CHANGED_FILES (optional): newline/comma-separated paths of
//   db/migrations files changed by the merge that triggered this run.
//
// Merge mode (no argv) requires SUPABASE_PROJECT_REF and
// SUPABASE_ACCESS_TOKEN and reconciles the live ledger. Local test/dry-run
// mode (exactly `--ledger-fixture <path>`) classifies against a local JSON
// fixture ({"ledgerExists":true,"recorded":["init",...],
// "unknownLedgerCount":0}) and never touches the network or secrets;
// MIGRATION_CD_ROOT optionally points the manifest read at another checkout.
// Workflows never pass those.

import { readFileSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { FILENAME_RE, parseMigrationNames } from "./migration-safety.mjs";
import { run as reconcileRun, UsageError, validateRawEnvValue } from "./migration-reconcile.mjs";

export const VERDICTS = Object.freeze({
  CLEAN: "clean-forward-only",
  REPAIR: "repair-required",
  RETRO_EDIT: "retro-edit",
  AMBIGUOUS: "ambiguous",
  UP_TO_DATE: "up-to-date",
});

const MIGRATION_NAME_RE = /^[a-z0-9_]+$/;

// Parse a changed-file entry (repo path like "db/migrations/0007_x.sql" or a
// bare basename) into { version, name, file }; null when it is not a
// migration file, so unrelated merge changes never affect classification.
export function parseChangedMigrationFile(entry) {
  const basename = String(entry ?? "").split("/").pop();
  const match = FILENAME_RE.exec(basename);
  if (!match) return null;
  return { version: match[1], name: match[2], file: basename };
}

// Pure classification. `local` is the parsed local manifest
// (parseMigrationNames output: [{ version, name, file }]); `recorded` is the
// list of ledger `name` values that match the local manifest (reconcile
// semantics — non-matching rows are counted in unknownLedgerCount).
export function classifyCdDelta({
  ledgerExists = true,
  recorded = [],
  unknownLedgerCount = 0,
  local = [],
  changedFiles = [],
}) {
  const recordedSet = new Set(recorded);
  const localByName = new Map(local.map((migration) => [migration.name, migration]));
  const recordedWithoutLocal = [...recordedSet].filter((name) => !localByName.has(name));
  const pending = local.filter((migration) => !recordedSet.has(migration.name));
  const recordedLocal = local.filter((migration) => recordedSet.has(migration.name));
  const newestRecorded = recordedLocal.reduce(
    (newest, migration) => (newest === null || migration.version > newest ? migration.version : newest),
    null,
  );
  const historical = pending.filter(
    (migration) => newestRecorded !== null && migration.version <= newestRecorded,
  );

  const retro = [];
  for (const entry of changedFiles ?? []) {
    const parsed = parseChangedMigrationFile(entry);
    if (!parsed) continue;
    if (recordedSet.has(parsed.name) || (newestRecorded !== null && parsed.version <= newestRecorded)) {
      retro.push(parsed.file);
    }
  }

  const pendingFiles = pending.map((migration) => migration.file);
  const base = { pending: pendingFiles, newestRecorded };

  if (!ledgerExists) {
    return {
      ...base,
      verdict: VERDICTS.AMBIGUOUS,
      autoApply: false,
      plan: [],
      reasons: [
        "public.migration_ledger is missing on the live project — the bootstrap state must be reconciled by a human first (manual dispatch-only path).",
      ],
    };
  }
  if (recorded.length === 0) {
    return {
      ...base,
      verdict: VERDICTS.AMBIGUOUS,
      autoApply: false,
      plan: [],
      reasons: [
        "public.migration_ledger exists but is empty — no migration may be recorded without contract verification (manual dispatch-only path).",
      ],
    };
  }
  if (unknownLedgerCount > 0) {
    return {
      ...base,
      verdict: VERDICTS.AMBIGUOUS,
      autoApply: false,
      plan: [],
      reasons: [
        `${unknownLedgerCount} ledger ${unknownLedgerCount === 1 ? "entry has" : "entries have"} no local migration file on main — the live project diverged from this repository's manifest; reconcile by hand before any apply (manual dispatch-only path).`,
      ],
    };
  }
  if (recordedWithoutLocal.length > 0) {
    return {
      ...base,
      verdict: VERDICTS.AMBIGUOUS,
      autoApply: false,
      plan: [],
      reasons: [
        "recorded ledger entries match no local migration file (the recorded set and the manifest cannot be joined); reconcile by hand before any apply (manual dispatch-only path).",
      ],
    };
  }
  if (retro.length > 0) {
    return {
      ...base,
      verdict: VERDICTS.RETRO_EDIT,
      autoApply: false,
      plan: [],
      reasons: [
        `the triggering merge changed already-applied migration file(s): ${retro.join(", ")} — an edit to a recorded migration can never auto-apply (manual dispatch-only path).`,
      ],
    };
  }
  if (historical.length > 0) {
    return {
      ...base,
      verdict: VERDICTS.REPAIR,
      autoApply: false,
      plan: [],
      reasons: [
        `${historical.length} pending migration(s) are not newer than the newest recorded version (${newestRecorded}): ${historical.map((migration) => migration.file).join(", ")} — a backward/repair edit can never auto-apply (manual dispatch-only path).`,
      ],
    };
  }
  if (pending.length === 0) {
    return {
      ...base,
      verdict: VERDICTS.UP_TO_DATE,
      autoApply: false,
      plan: [],
      reasons: [],
    };
  }
  return {
    ...base,
    verdict: VERDICTS.CLEAN,
    autoApply: true,
    plan: pendingFiles,
    reasons: [],
  };
}

export function readLedgerFixture(path) {
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    throw new UsageError("ledger fixture is not readable JSON.");
  }
  if (typeof parsed?.ledgerExists !== "boolean") {
    throw new UsageError("ledger fixture must set a boolean ledgerExists.");
  }
  if (!Array.isArray(parsed.recorded) || parsed.recorded.some((name) => !MIGRATION_NAME_RE.test(String(name)))) {
    throw new UsageError("ledger fixture recorded must be an array of migration names (000N_name part).");
  }
  if (!Number.isInteger(parsed.unknownLedgerCount) || parsed.unknownLedgerCount < 0) {
    throw new UsageError("ledger fixture unknownLedgerCount must be a non-negative integer.");
  }
  return {
    ledgerExists: parsed.ledgerExists,
    recorded: parsed.recorded.map(String),
    unknownLedgerCount: parsed.unknownLedgerCount,
  };
}

function formatDecision(decision, changedCount) {
  const lines = [];
  lines.push("Morsel migration CD classification — READ-ONLY (no SQL executed, no ledger writes)");
  lines.push("==================================================");
  lines.push("project ref : [redacted]");
  lines.push(`changed     : ${changedCount} db/migrations file(s) changed by the triggering merge`);
  lines.push(`ledger      : ${decision.newestRecorded === null ? "no recorded version" : `newest recorded version ${decision.newestRecorded}`}`);
  lines.push(`pending     : ${decision.pending.length === 0 ? "none" : decision.pending.join(", ")}`);
  lines.push(`verdict=${decision.verdict}`);
  lines.push(`autoApply=${decision.autoApply}`);
  lines.push(`applyPlan=${decision.plan.join(",")}`);
  lines.push(`newestRecorded=${decision.newestRecorded ?? ""}`);
  lines.push("decision: " + summaryFor(decision));
  for (const reason of decision.reasons) {
    lines.push(`  reason: ${reason}`);
  }
  return lines.join("\n");
}

function summaryFor(decision) {
  switch (decision.verdict) {
    case VERDICTS.CLEAN:
      return "CLEAN FORWARD-ONLY — eligible for auto-apply, but the apply step is DISABLED by default (flag OFF); this run writes NOTHING to production.";
    case VERDICTS.REPAIR:
    case VERDICTS.RETRO_EDIT:
      return "MANUAL PATH ONLY — repairs/retro-edits never auto-apply. Use the Deploy Migrations (Recovery Apply) workflow_dispatch (confirmation phrase required).";
    case VERDICTS.AMBIGUOUS:
      return "MANUAL PATH ONLY — ambiguous ledger state never auto-applies. Reconcile by hand (Recovery Apply workflow_dispatch) before any apply.";
    case VERDICTS.UP_TO_DATE:
      return "UP TO DATE — no pending migration; nothing to apply.";
    default:
      return "unknown verdict";
  }
}

export async function runMerge({ ref, token, root, queryImpl = null, changedFiles = [], ledgerFixture = null, log = console }) {
  let ledger;
  if (ledgerFixture) {
    ledger = {
      ledgerExists: ledgerFixture.ledgerExists,
      recorded: ledgerFixture.recorded,
      unknownLedgerCount: ledgerFixture.unknownLedgerCount,
    };
  } else {
    if (!ref) throw new UsageError("SUPABASE_PROJECT_REF is required.");
    if (!token) throw new UsageError("No Management API token found. Set SUPABASE_ACCESS_TOKEN.");
    validateRawEnvValue("SUPABASE_PROJECT_REF", ref);
    validateRawEnvValue("SUPABASE_ACCESS_TOKEN", token);
    const reconciled = await reconcileRun({ ref, token, root, queryImpl });
    ledger = {
      ledgerExists: reconciled.ledgerExists,
      recorded: reconciled.ledgerNames,
      unknownLedgerCount: reconciled.unknownLedgerCount,
    };
  }
  const migrationsDir = join(root, "db", "migrations");
  const local = parseMigrationNames(readdirSync(migrationsDir).filter((file) => file.endsWith(".sql")));
  const decision = classifyCdDelta({ ...ledger, local, changedFiles });
  const report = formatDecision(decision, changedFiles.length);
  log.log(report);
  return decision;
}

export async function main(argv = process.argv.slice(2), env = process.env) {
  let ledgerFixture = null;
  let root;
  try {
    if (argv.length === 2 && argv[0] === "--ledger-fixture") {
      ledgerFixture = readLedgerFixture(argv[1]);
      root = env.MIGRATION_CD_ROOT || dirname(dirname(fileURLToPath(import.meta.url)));
    } else if (argv.length > 0) {
      throw new UsageError(
        "migration-cd-classifier accepts no arguments (live-ledger merge mode) or exactly --ledger-fixture <path> (local test/dry-run mode).",
      );
    } else {
      root = env.MIGRATION_CD_ROOT || dirname(dirname(fileURLToPath(import.meta.url)));
    }
    const changedFiles = String(env.MIGRATION_CD_CHANGED_FILES ?? "")
      .split(/[\n,]/)
      .map((entry) => entry.trim())
      .filter(Boolean);
    await runMerge({
      ref: env.SUPABASE_PROJECT_REF,
      token: env.SUPABASE_ACCESS_TOKEN,
      root,
      changedFiles,
      ledgerFixture,
    });
    return 0;
  } catch (error) {
    if (error instanceof UsageError) {
      console.error(`✗ ${error.message}`);
      return error.exitCode;
    }
    console.error("✗ migration CD classification failed (error details suppressed)");
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(await main());
}
