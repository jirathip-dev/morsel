#!/usr/bin/env node
// Morsel migrations use 000N_name.sql: four-digit zero-padded versions sort lexicographically.
// Default mode refuses a missing/empty ledger. Blind --adopt was REMOVED (issue #76):
// historical migrations may only be recorded after scripts/migration-recovery.mjs
// verifies each migration's complete authoritative end-state contract under an
// explicit human confirmation.
//
// STRUCTURAL SAFETY (pre-review fix at issue #76)
// - The ledger is NEVER bootstrapped by this script: existence is probed with
//   a read-only SELECT and a missing or empty ledger fails with ZERO writes.
// - Each allowed future append runs as ONE Management API request wrapped in
//   BEGIN..COMMIT with the migration SQL and its ledger insert in the same
//   transaction, so a crash can never leave DDL applied without its ledger row.
// - Migration text containing transaction-control statements is rejected
//   before any write (it could escape the wrapper transaction).

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

export const LEDGER_EXISTS_SQL = "select to_regclass('public.migration_ledger')::text as name";
export const LEDGER_NAMES_SQL = "select name from public.migration_ledger order by name";

export class UsageError extends Error {
  exitCode = 2;
}

// Remove SQL comments, quoted literals/identifiers, and dollar-quoted bodies
// so transaction-control scanning only sees executable statements.
function stripSqlNoise(sql) {
  return String(sql)
    .replace(/\$[a-z_]*\$[\s\S]*?\$[a-z_]*\$/g, " ")
    .replace(/'(?:[^']|'')*'/g, " ")
    .replace(/"(?:[^"]|"")*"/g, " ")
    .replace(/--[^\n]*/g, " ")
    .replace(/\/\*[\s\S]*?\*\//g, " ");
}

// Transaction-control keywords that could nest/commit/rollback around the
// wrapper's own BEGIN/COMMIT. Statements are scanned after comment/string/
// dollar-quote stripping, so `begin`/`end` inside function bodies never trip
// it, while a real `begin;`/`commit;`/`rollback;`/`savepoint;` at statement
// level is rejected.
const TRANSACTION_CONTROL_RE =
  /\b(?:start\s+transaction|begin(?:\s+work|\s+transaction)?|commit(?:\s+work|\s+transaction)?|rollback(?:\s+work|\s+transaction)?|savepoint|release\s+savepoint|abort(?:\s+work|\s+transaction)?|end(?:\s+work|\s+transaction)?|prepare\s+transaction)\b/i;

export function hasTransactionControl(sql) {
  return TRANSACTION_CONTROL_RE.test(stripSqlNoise(sql));
}

const atomicApply = (sqlText, name) =>
  `begin;\n${sqlText}\ninsert into public.migration_ledger (name) values ('${name}');\ncommit;`;

export async function run({ ref, token, root, queryImpl = null, log = console }) {
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

  // Read-only ledger probe first: a missing ledger fails with ZERO writes.
  const existsRow = (await query(LEDGER_EXISTS_SQL, "ledger existence"))[0] ?? {};
  const ledgerExists = Boolean(existsRow.name);
  if (!ledgerExists) {
    throw new Error(
      "ledger public.migration_ledger does not exist — no migration was applied (zero writes). " +
        "Create the ledger with scripts/migration-recovery.mjs (human-gated apply with the issue #76 confirmation); " +
        "for a fresh empty database, apply db/migrations/0001..0009 through the recovery runner first.",
    );
  }
  const recordedNames = async () =>
    new Set((await query(LEDGER_NAMES_SQL, "ledger query")).map((row) => row.name));
  const recorded = await recordedNames();
  if (recorded.size === 0) {
    throw new Error(
      "ledger is empty — no migration was applied (zero writes); no migration may be recorded without contract verification " +
        "(blind --adopt was removed for issue #76). Run scripts/migration-recovery.mjs (human-gated apply) to record " +
        "verified migrations first.",
    );
  }

  const warning = formatLedgerOnlyWarning([{ label: "project", names: ledgerNamesWithoutLocalFiles(local, recorded) }]);
  if (warning) log.log(`${warning}\n`);
  const decision = appendOnlyDecision(local, recorded);
  if (!decision.pending.length) {
    log.log(localMigrationsRecordedMessage(local.length, ref));
    return { applied: [] };
  }
  if (!decision.allowed) throw new Error(`${decision.historical.length} unrecorded migration(s) are OLDER than the newest recorded one (${decision.newestApplied}); NEVER re-run these. Reconcile the ledger with scripts/migration-recovery.mjs instead.`);

  // Validate every pending migration text BEFORE the first write: any
  // transaction-control that could escape the wrapper fails the whole run
  // with zero writes.
  const pendingSql = new Map();
  for (const migration of decision.pending) {
    const sqlText = readFileSync(join(migrationsDir, migration.file), "utf8");
    if (hasTransactionControl(sqlText)) {
      throw new Error(
        `${migration.file} contains transaction-control statements and cannot be applied by this wrapper; ` +
          "no migration was applied (zero writes). Migrations must be plain DDL/DML — the wrapper provides the single BEGIN/COMMIT.",
      );
    }
    pendingSql.set(migration.name, sqlText);
  }

  for (const migration of decision.pending) {
    // One atomic request per migration: DDL + ledger insert in one
    // BEGIN..COMMIT transaction.
    await query(atomicApply(pendingSql.get(migration.name), migration.name), `apply ${migration.file}`);
    log.log(`✓ applied + recorded ${migration.file}`);
  }
  const after = await recordedNames();
  const stillMissing = local.filter((migration) => !after.has(migration.name));
  if (stillMissing.length) throw new Error(`post-apply verification failed — still unrecorded: ${stillMissing.map((migration) => migration.file).join(", ")}`);
  log.log(localMigrationsRecordedMessage(local.length, ref));
  return { applied: decision.pending.map((migration) => migration.file) };
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
    if (argv.length > 0) {
      throw new UsageError(
        "apply-migrations accepts no arguments; blind --adopt was removed for issue #76. " +
          "Use scripts/migration-recovery.mjs for verified ledger reconciliation.",
      );
    }
  } catch (error) {
    console.error(`✗ ${error.message}`);
    return error instanceof UsageError ? error.exitCode : 1;
  }
  const root = dirname(dirname(fileURLToPath(import.meta.url)));
  const freshness = checkoutFreshness(root);
  const checkoutExit = checkoutGuardExitCode(freshness, "migration verification/apply");
  if (checkoutExit) return checkoutExit;
  try {
    await run({ ref, token: accessToken(), root });
    return 0;
  } catch (error) {
    console.error(`✗ ${error.message}`);
    return error instanceof UsageError ? error.exitCode : 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) process.exit(await main());
