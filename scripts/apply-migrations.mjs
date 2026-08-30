#!/usr/bin/env node
// Morsel migrations use 000N_name.sql: four-digit zero-padded versions sort lexicographically.
// Default mode refuses an empty ledger: after manual setup, run --adopt once.

import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  checkoutFreshness,
  checkoutGuardExitCode,
  formatLedgerOnlyWarning,
  ledgerNamesWithoutLocalFiles,
  localMigrationsRecordedMessage,
  parseMigrationNames,
  appendOnlyDecision,
} from "./migration-safety.mjs";

const LEDGER_DDL = "create table if not exists public.migration_ledger (name text primary key, applied_at timestamptz not null default now())";

export class UsageError extends Error {
  exitCode = 2;
}

export async function run({ ref, token, root, adopt = false, queryImpl = null, log = console }) {
  if (!ref) throw new UsageError("SUPABASE_PROJECT_REF is required.");
  if (!token) throw new UsageError("No Management API token found. Set SUPABASE_ACCESS_TOKEN.");
  const migrationsDir = join(root, "db", "migrations");
  const query = queryImpl ?? (async (sql, label) => {
    const response = await fetch(`https://api.supabase.com/v1/projects/${ref}/database/query`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ query: sql }),
    });
    if (!response.ok) throw new Error(`${label} failed: HTTP ${response.status} ${await response.text()}`);
    const body = await response.json();
    return Array.isArray(body) ? body : (body.result ?? body.rows ?? []);
  });
  const local = parseMigrationNames(readdirSync(migrationsDir).filter((file) => file.endsWith(".sql")));
  await query(LEDGER_DDL, "ledger bootstrap");
  const recordedNames = async () => new Set((await query("select name from public.migration_ledger", "ledger query")).map((row) => row.name));
  let recorded = await recordedNames();

  if (adopt) {
    for (const migration of local) {
      await query(`insert into public.migration_ledger (name) values ('${migration.name}') on conflict (name) do nothing`, `ledger adoption for ${migration.file}`);
    }
    recorded = await recordedNames();
    const missing = local.filter((migration) => !recorded.has(migration.name));
    if (missing.length) throw new Error(`adoption verification failed: ${missing.map((migration) => migration.file).join(", ")}`);
    log.log(`✓ adopted ${local.length} local migrations on ${ref}; no migration SQL was executed.`);
    return { adopted: local.length, applied: [] };
  }

  const warning = formatLedgerOnlyWarning([{ label: "project", names: ledgerNamesWithoutLocalFiles(local, recorded) }]);
  if (warning) log.log(`${warning}\n`);
  if (recorded.size === 0) {
    throw new Error("ledger is empty — if the schema was provisioned manually (issue #9), run --adopt once; if this is a fresh empty database, apply migrations 0001… in order before running this deploy lane.");
  }
  const decision = appendOnlyDecision(local, recorded);
  if (!decision.pending.length) {
    log.log(localMigrationsRecordedMessage(local.length, ref));
    return { adopted: 0, applied: [] };
  }
  if (!decision.allowed) throw new Error(`${decision.historical.length} unrecorded migration(s) are OLDER than the newest recorded one (${decision.newestApplied}); NEVER re-run these. Backfill the ledger row instead.`);
  for (const migration of decision.pending) {
    await query(readFileSync(join(migrationsDir, migration.file), "utf8"), `apply ${migration.file}`);
    await query(`insert into public.migration_ledger (name) values ('${migration.name}')`, `ledger insert for ${migration.file}`);
    log.log(`✓ applied + recorded ${migration.file}`);
  }
  const after = await recordedNames();
  const stillMissing = local.filter((migration) => !after.has(migration.name));
  if (stillMissing.length) throw new Error(`post-apply verification failed — still unrecorded: ${stillMissing.map((migration) => migration.file).join(", ")}`);
  log.log(localMigrationsRecordedMessage(local.length, ref));
  return { adopted: 0, applied: decision.pending.map((migration) => migration.file) };
}

function accessToken() {
  if (process.env.SUPABASE_ACCESS_TOKEN?.trim()) return process.env.SUPABASE_ACCESS_TOKEN.trim();
  const tokenFile = join(homedir(), ".supabase", "access-token");
  if (existsSync(tokenFile)) return readFileSync(tokenFile, "utf8").trim();
  return null;
}

export async function main(argv = process.argv.slice(2)) {
  const ref = process.env.SUPABASE_PROJECT_REF?.trim();
  try {
    if (!ref) throw new UsageError("SUPABASE_PROJECT_REF is required.");
  } catch (error) {
    console.error(`✗ ${error.message}`);
    return error instanceof UsageError ? error.exitCode : 1;
  }
  const root = dirname(dirname(fileURLToPath(import.meta.url)));
  const freshness = checkoutFreshness(root);
  const checkoutExit = checkoutGuardExitCode(freshness, "migration verification/apply");
  if (checkoutExit) return checkoutExit;
  try {
    await run({ ref, token: accessToken(), root, adopt: argv.includes("--adopt") });
    return 0;
  } catch (error) {
    console.error(`✗ ${error.message}`);
    return error instanceof UsageError ? error.exitCode : 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) process.exit(await main());
