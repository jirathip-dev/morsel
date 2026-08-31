#!/usr/bin/env node
// Read-only reconciliation of the hosted Morsel Supabase schema against the
// local db/migrations/* sentinel objects (issue #12).
//
// This script NEVER writes to the live project: it does not bootstrap
// public.migration_ledger, does not --adopt, does not execute migration SQL,
// and does not insert ledger rows. Every statement it issues is a fixed
// SELECT against information_schema / pg_catalog; the assertReadOnly guard
// rejects anything else BEFORE it reaches the query implementation, so even a
// hostile or mutated query path cannot execute a write in reconcile mode.
//
// Secrets are consumed from the environment ONLY (SUPABASE_ACCESS_TOKEN,
// SUPABASE_PROJECT_REF) and are never logged; the report contains no row or
// user contents.

import { readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseMigrationNames } from "./migration-safety.mjs";

export const LEDGER_EXISTS_SQL =
  "select to_regclass('public.migration_ledger')::text as name";
export const LEDGER_NAMES_SQL =
  "select name from public.migration_ledger order by name";

export const INVENTORY_SQL = Object.freeze({
  tables:
    "select table_name from information_schema.tables where table_schema = 'public' order by table_name",
  columns:
    "select table_name, column_name, data_type, numeric_precision, numeric_scale from information_schema.columns where table_schema = 'public' order by table_name, column_name",
  routines:
    "select routine_name from information_schema.routines where routine_schema = 'public' order by routine_name",
  policies:
    "select schemaname, tablename, policyname from pg_policies where schemaname in ('public','storage') order by schemaname, tablename, policyname",
});

// Immutable exact-membership allowlist: reconcile mode only ever issues these
// fixed SELECT statements, and NOTHING else. Stacked statements, writable
// SELECT functions, transactions, comments/whitespace variants, migration SQL,
// and ledger DDL/inserts are all refused because the submitted string must be
// byte-for-byte identical to one of the entries below.
//
// The EXPORTED representation is a frozen ARRAY (Object.freeze(new Set(...))
// does not prevent Set#add/delete — see fix round 2); the membership Set used
// by the guard is PRIVATE and built once from that frozen array, so callers
// cannot widen it by mutating any exported value.
export const ALLOWED_QUERIES = Object.freeze([
  LEDGER_EXISTS_SQL,
  LEDGER_NAMES_SQL,
  ...Object.values(INVENTORY_SQL),
]);

const allowedQuerySet = new Set(ALLOWED_QUERIES);

// Hard read-only guard: the query wrapper rejects any non-allowlisted string
// before it reaches queryImpl/fetch.
export function assertReadOnly(sql) {
  if (!allowedQuerySet.has(sql)) {
    const preview = sql.replace(/\s+/g, " ").trim().slice(0, 80);
    throw new Error(`reconcile mode refuses non-allowlisted SQL: ${preview}`);
  }
}

const EMPTY_SENTINELS = { tables: [], columns: [], routines: [], policies: [] };

// Sentinel objects are structural evidence ONLY. Presence does not prove a
// migration ran (objects can pre-exist or match by name); the ledger row is
// the only applied claim. The report therefore lists per-object PRESENT/ABSENT
// and never asserts a migration is applied from sentinels alone.
export const EXPECTED_SENTINELS = {
  "0001_init.sql": {
    tables: [
      "users",
      "goals",
      "meal_logs",
      "meal_items",
      "water_logs",
      "weight_logs",
      "food_catalog",
    ],
    columns: ["users.timezone", "meal_logs.meal_type", "meal_items.confidence"],
    routines: [],
    policies: [
      "public.goals:goals_select_own",
      "public.meal_logs:meal_logs_select_own",
      "public.meal_items:meal_items_select_own",
      "public.water_logs:water_logs_all_own",
      "public.weight_logs:weight_logs_all_own",
    ],
  },
  "0002_targets.sql": {
    tables: ["profiles"],
    columns: ["profiles.activity_level", "goals.source"],
    routines: ["compute_targets"],
    policies: ["public.profiles:profiles_select_own"],
  },
  "0003_atomic_meals_and_users_rls.sql": {
    tables: [],
    columns: [],
    routines: ["log_meal_with_items"],
    policies: [
      "public.users:users_select_own",
      "public.users:users_insert_own",
      "public.users:users_update_own",
    ],
  },
  "0004_store_assets.sql": {
    tables: [],
    columns: [],
    routines: [],
    policies: [
      "storage.objects:food_images_insert_own",
      "storage.objects:food_images_select_own",
      "storage.objects:food_images_update_own",
      "storage.objects:food_images_delete_own",
      "public.food_catalog:food_catalog_select_authenticated",
    ],
  },
  "0005_oauth_authorization_grants.sql": {
    tables: ["oauth_authorization_grants"],
    columns: [
      "oauth_authorization_grants.code_hash",
      "oauth_authorization_grants.expires_at",
    ],
    routines: ["claim_oauth_authorization_grant"],
    policies: [
      "public.oauth_authorization_grants:oauth authorization grants are readable by their owner",
      "public.oauth_authorization_grants:oauth authorization grants are insertable by their owner",
    ],
  },
  "0006_food_catalog_provider_cache.sql": {
    tables: [],
    columns: [],
    routines: ["upsert_food_catalog"],
    policies: [],
  },
  "0007_weight_logs.sql": {
    tables: [],
    columns: ["weight_logs.measured_at", "weight_logs.source"],
    routines: [],
    policies: [],
  },
  "0008_energy_burned_logs.sql": {
    tables: ["energy_burned_logs"],
    columns: ["energy_burned_logs.active_kcal"],
    routines: [],
    policies: ["public.energy_burned_logs:energy_burned_logs_all_own"],
  },
  "0009_goals_fractional_calories.sql": {
    tables: [],
    // The column exists since 0001 as int; only the numeric(10,1) re-type is
    // the 0009 sentinel, so this entry matches data_type AND numeric_scale.
    columns: [
      { table: "goals", column: "calorie_target_kcal", dataType: "numeric", numericScale: 1 },
    ],
    routines: [],
    policies: [],
  },
};

export class UsageError extends Error {
  exitCode = 2;
}

function columnKey(table, column) {
  return `${table}.${column}`;
}

async function managementQuery(sql, label, ref, token) {
  const response = await fetch(
    `https://api.supabase.com/v1/projects/${ref}/database/query`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ query: sql }),
    },
  );
  if (!response.ok) {
    throw new Error(`${label} failed: HTTP ${response.status}`);
  }
  const body = await response.json();
  return Array.isArray(body) ? body : (body.result ?? body.rows ?? []);
}

export function formatReport({ local, ledgerExists, ledgerNames, inventory, checks }) {
  const lines = [];
  lines.push("Morsel migration ledger reconciliation — READ-ONLY");
  lines.push("==================================================");
  lines.push("project ref : [redacted]");
  lines.push("mode        : read-only — no --adopt, no migration SQL, no ledger writes");
  lines.push("");
  lines.push("ledger public.migration_ledger");
  if (ledgerExists) {
    lines.push("  exists : yes");
    lines.push(
      ledgerNames.length === 0
        ? "  names  : 0 recorded (empty)"
        : `  names  : ${ledgerNames.length} recorded (${ledgerNames.join(", ")})`,
    );
  } else {
    lines.push("  exists : no — MISSING (not bootstrapped; nothing was created or recorded)");
  }
  lines.push("");
  lines.push("schema inventory (information_schema / pg_catalog)");
  lines.push(`  tables   : ${inventory.tables.size}`);
  lines.push(`  columns  : ${inventory.columns.size}`);
  lines.push(`  routines : ${inventory.routines.size}`);
  lines.push(`  policies : ${inventory.policies.size}`);
  lines.push("");
  lines.push(`expected migration sentinels (${local.length} local migrations)`);
  let present = 0;
  let total = 0;
  for (const migration of local) {
    const entries = checks[migration.file] ?? [];
    lines.push(migration.file);
    if (entries.length === 0) {
      lines.push("  (no sentinels defined — add an entry to EXPECTED_SENTINELS)");
    }
    for (const entry of entries) {
      lines.push(
        `  ${entry.kind.padEnd(8)} ${entry.label.padEnd(58)} ${entry.present ? "PRESENT" : "ABSENT"}`,
      );
    }
    const presentHere = entries.filter((entry) => entry.present).length;
    present += presentHere;
    total += entries.length;
    lines.push(`  sentinels present: ${presentHere}/${entries.length}`);
  }
  const absent = total - present;
  lines.push("");
  lines.push(`coverage: ${present} of ${total} expected objects present (${absent} absent)`);
  lines.push("");
  lines.push("NOTE: Sentinel presence is structural evidence only. It does NOT prove");
  lines.push("a migration was applied: objects can pre-exist or match by name, and a");
  lines.push("migration must not be adopted (--adopt) from sentinel presence alone.");
  lines.push("A recorded ledger row is the only applied claim; inspect this report");
  lines.push("before any manual adoption decision.");
  return lines.join("\n");
}

export async function run({ ref, token, root, queryImpl = null, log = console }) {
  if (!ref) throw new UsageError("SUPABASE_PROJECT_REF is required.");
  if (!token) throw new UsageError("No Management API token found. Set SUPABASE_ACCESS_TOKEN.");

  // Every statement is guarded read-only before it reaches the query layer,
  // regardless of which query implementation is in use.
  const query = async (sql, label) => {
    assertReadOnly(sql);
    if (queryImpl) return queryImpl(sql, label);
    return managementQuery(sql, label, ref, token);
  };

  const ledgerRow = (await query(LEDGER_EXISTS_SQL, "ledger existence"))[0] ?? {};
  const ledgerExists = Boolean(ledgerRow.name);
  const ledgerNames = ledgerExists
    ? (await query(LEDGER_NAMES_SQL, "ledger names")).map((row) => row.name)
    : [];

  const [tableRows, columnRows, routineRows, policyRows] = await Promise.all([
    query(INVENTORY_SQL.tables, "table inventory"),
    query(INVENTORY_SQL.columns, "column inventory"),
    query(INVENTORY_SQL.routines, "routine inventory"),
    query(INVENTORY_SQL.policies, "policy inventory"),
  ]);

  const inventory = {
    tables: new Set(tableRows.map((row) => row.table_name)),
    columns: new Map(
      columnRows.map((row) => [columnKey(row.table_name, row.column_name), row]),
    ),
    routines: new Set(routineRows.map((row) => row.routine_name)),
    policies: new Set(
      policyRows.map((row) => `${row.schemaname}.${row.tablename}:${row.policyname}`),
    ),
  };

  const local = parseMigrationNames(
    readdirSync(join(root, "db", "migrations")).filter((file) => file.endsWith(".sql")),
  );

  const checks = {};
  for (const migration of local) {
    const sentinels = EXPECTED_SENTINELS[migration.file] ?? EMPTY_SENTINELS;
    const entries = [];
    for (const table of sentinels.tables) {
      entries.push({
        kind: "table",
        label: `public.${table}`,
        present: inventory.tables.has(table),
      });
    }
    for (const column of sentinels.columns) {
      if (typeof column === "string") {
        const [table, columnName] = column.split(".");
        entries.push({
          kind: "column",
          label: column,
          present: inventory.columns.has(columnKey(table, columnName)),
        });
      } else {
        const info = inventory.columns.get(columnKey(column.table, column.column));
        const present = Boolean(
          info && info.data_type === column.dataType && Number(info.numeric_scale) === column.numericScale,
        );
        entries.push({
          kind: "column",
          label: `${column.table}.${column.column} (${column.dataType}, scale ${column.numericScale})`,
          present,
        });
      }
    }
    for (const routine of sentinels.routines) {
      entries.push({
        kind: "routine",
        label: `public.${routine}`,
        present: inventory.routines.has(routine),
      });
    }
    for (const policy of sentinels.policies) {
      entries.push({ kind: "policy", label: policy, present: inventory.policies.has(policy) });
    }
    checks[migration.file] = entries;
  }

  const report = formatReport({
    local,
    ledgerExists,
    ledgerNames,
    inventory,
    checks,
  });
  log.log(report);
  return { ledgerExists, ledgerNames, local: local.map((migration) => migration.file), checks, report };
}

export async function main(argv = process.argv.slice(2)) {
  const ref = process.env.SUPABASE_PROJECT_REF?.trim();
  const token = process.env.SUPABASE_ACCESS_TOKEN?.trim();
  try {
    if (!ref) throw new UsageError("SUPABASE_PROJECT_REF is required.");
    if (!token) throw new UsageError("No Management API token found. Set SUPABASE_ACCESS_TOKEN.");
    if (argv.length > 0) {
      throw new UsageError(
        "migration-reconcile accepts no arguments (read-only; --adopt and migration apply are not supported here).",
      );
    }
    const root = dirname(dirname(fileURLToPath(import.meta.url)));
    await run({ ref, token, root });
    return 0;
  } catch (error) {
    console.error(`✗ ${error.message}`);
    return error instanceof UsageError ? error.exitCode : 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(await main());
}
