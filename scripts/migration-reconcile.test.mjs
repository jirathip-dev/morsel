import { describe, expect, it } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import {
  ALLOWED_QUERIES,
  EXPECTED_SENTINELS,
  INVENTORY_SQL,
  LEDGER_EXISTS_SQL,
  LEDGER_NAMES_SQL,
  assertReadOnly,
  run,
} from "./migration-reconcile.mjs";

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const scriptUrl = fileURLToPath(new URL("./migration-reconcile.mjs", import.meta.url));
const quiet = { log: () => {} };

// A canned live-schema inventory that matches every 0001–0009 sentinel.
function fullSchema() {
  return {
    tables: [
      "users", "goals", "meal_logs", "meal_items", "water_logs", "weight_logs",
      "food_catalog", "profiles", "oauth_authorization_grants", "energy_burned_logs",
    ],
    columns: [
      { table_name: "users", column_name: "timezone", data_type: "text" },
      { table_name: "meal_logs", column_name: "meal_type", data_type: "text" },
      { table_name: "meal_items", column_name: "confidence", data_type: "numeric" },
      { table_name: "profiles", column_name: "activity_level", data_type: "text" },
      { table_name: "goals", column_name: "source", data_type: "text" },
      { table_name: "goals", column_name: "calorie_target_kcal", data_type: "numeric", numeric_scale: 1 },
      { table_name: "oauth_authorization_grants", column_name: "code_hash", data_type: "text" },
      { table_name: "oauth_authorization_grants", column_name: "expires_at", data_type: "timestamp with time zone" },
      { table_name: "weight_logs", column_name: "measured_at", data_type: "timestamp with time zone" },
      { table_name: "weight_logs", column_name: "source", data_type: "text" },
      { table_name: "energy_burned_logs", column_name: "active_kcal", data_type: "numeric" },
    ],
    routines: ["compute_targets", "log_meal_with_items", "claim_oauth_authorization_grant", "upsert_food_catalog"],
    policies: [
      { schemaname: "public", tablename: "goals", policyname: "goals_select_own" },
      { schemaname: "public", tablename: "meal_logs", policyname: "meal_logs_select_own" },
      { schemaname: "public", tablename: "meal_items", policyname: "meal_items_select_own" },
      { schemaname: "public", tablename: "water_logs", policyname: "water_logs_all_own" },
      { schemaname: "public", tablename: "weight_logs", policyname: "weight_logs_all_own" },
      { schemaname: "public", tablename: "profiles", policyname: "profiles_select_own" },
      { schemaname: "public", tablename: "users", policyname: "users_select_own" },
      { schemaname: "public", tablename: "users", policyname: "users_insert_own" },
      { schemaname: "public", tablename: "users", policyname: "users_update_own" },
      { schemaname: "storage", tablename: "objects", policyname: "food_images_insert_own" },
      { schemaname: "storage", tablename: "objects", policyname: "food_images_select_own" },
      { schemaname: "storage", tablename: "objects", policyname: "food_images_update_own" },
      { schemaname: "storage", tablename: "objects", policyname: "food_images_delete_own" },
      { schemaname: "public", tablename: "food_catalog", policyname: "food_catalog_select_authenticated" },
      { schemaname: "public", tablename: "oauth_authorization_grants", policyname: "oauth authorization grants are readable by their owner" },
      { schemaname: "public", tablename: "oauth_authorization_grants", policyname: "oauth authorization grants are insertable by their owner" },
      { schemaname: "public", tablename: "energy_burned_logs", policyname: "energy_burned_logs_all_own" },
    ],
  };
}

// A fake Management API query layer that records every statement it is asked
// to run; keyed on the fixed SELECT strings the reconcile script issues.
function fakeDatabase(overrides = {}) {
  const sql = [];
  const state = {
    ledgerExists: overrides.ledgerExists ?? true,
    ledgerNames: overrides.ledgerNames ?? [],
    ...fullSchema(),
    ...overrides,
  };
  const query = async (statement) => {
    sql.push(statement);
    if (statement === LEDGER_EXISTS_SQL) {
      return [{ name: state.ledgerExists ? "migration_ledger" : null }];
    }
    if (statement === LEDGER_NAMES_SQL) return state.ledgerNames.map((name) => ({ name }));
    if (statement === INVENTORY_SQL.tables) return state.tables.map((table_name) => ({ table_name }));
    if (statement === INVENTORY_SQL.columns) {
      return state.columns.map((row) => ({
        table_name: row.table_name,
        column_name: row.column_name,
        data_type: row.data_type,
        numeric_precision: row.numeric_precision ?? null,
        numeric_scale: row.numeric_scale ?? null,
      }));
    }
    if (statement === INVENTORY_SQL.routines) return state.routines.map((routine_name) => ({ routine_name }));
    if (statement === INVENTORY_SQL.policies) {
      return state.policies.map((row) => ({
        schemaname: row.schemaname,
        tablename: row.tablename,
        policyname: row.policyname,
      }));
    }
    return [];
  };
  return { sql, query, state };
}

const EXPECTED_TOTAL = Object.values(EXPECTED_SENTINELS).reduce(
  (sum, sentinels) => sum + sentinels.tables.length + sentinels.columns.length + sentinels.routines.length + sentinels.policies.length,
  0,
);

describe("migration reconciliation report", () => {
  it("covers every local migration file with a sentinel entry", () => {
    const files = readdirSync(join(repoRoot, "db", "migrations"))
      .filter((file) => file.endsWith(".sql"))
      .sort();
    expect(Object.keys(EXPECTED_SENTINELS).sort()).toEqual(files);
  });

  it("marks every expected sentinel PRESENT when the live inventory matches", async () => {
    const db = fakeDatabase({
      ledgerNames: ["init", "targets", "atomic_meals_and_users_rls", "store_assets", "oauth_authorization_grants", "food_catalog_provider_cache", "weight_logs", "energy_burned_logs", "goals_fractional_calories"],
    });
    const result = await run({ ref: "ref", token: "token", root: repoRoot, queryImpl: db.query, log: quiet });

    expect(result.ledgerExists).toBe(true);
    expect(result.ledgerNames).toHaveLength(9);
    expect(result.report).toContain("ledger public.migration_ledger");
    expect(result.report).toContain("9 recorded");
    expect(result.report).toContain("Morsel migration ledger reconciliation — READ-ONLY");
    expect(result.report).toContain("coverage:");
    expect(result.report).toContain("0009_goals_fractional_calories.sql");
    expect(result.report).toMatch(/column\s+goals\.calorie_target_kcal \(numeric, scale 1\)\s+PRESENT/);

    const entries = Object.values(result.checks).flat();
    expect(entries).toHaveLength(EXPECTED_TOTAL);
    expect(entries.every((entry) => entry.present)).toBe(true);
    expect(result.report).not.toMatch(/\bABSENT\b/);
  });

  it("reports ABSENT objects and never claims a migration is applied from sentinels", async () => {
    // Only 0001's users table exists in the live schema; the ledger is empty.
    const db = fakeDatabase({
      ledgerNames: [],
      tables: ["users"],
      columns: [{ table_name: "users", column_name: "timezone", data_type: "text" }],
      routines: [],
      policies: [],
    });
    const result = await run({ ref: "ref", token: "token", root: repoRoot, queryImpl: db.query, log: quiet });

    expect(result.report).toContain("names  : 0 recorded (empty)");
    expect(result.report).toMatch(/table\s+public\.users\s+PRESENT/);
    expect(result.report).toMatch(/table\s+public\.goals\s+ABSENT/);
    expect(result.report).toMatch(/routine\s+public\.log_meal_with_items\s+ABSENT/);

    const entries = Object.values(result.checks).flat();
    const present = entries.filter((entry) => entry.present).length;
    const absent = entries.filter((entry) => !entry.present).length;
    expect(present).toBe(2); // users table + users.timezone column
    expect(absent).toBe(EXPECTED_TOTAL - 2);

    // The report carries the structural-evidence disclaimer and no applied claim.
    expect(result.report).toContain("does NOT prove");
    expect(result.report).not.toMatch(/migration \d{4} (is )?applied/i);
  });

  it("reports ledger MISSING without querying ledger names and without any write", async () => {
    const db = fakeDatabase({ ledgerExists: false });
    const result = await run({ ref: "ref", token: "token", root: repoRoot, queryImpl: db.query, log: quiet });

    expect(result.ledgerExists).toBe(false);
    expect(result.ledgerNames).toEqual([]);
    expect(result.report).toContain("exists : no — MISSING");
    expect(db.sql).not.toContain(LEDGER_NAMES_SQL);
    // Every statement the script issues is a read-only SELECT.
    expect(db.sql.every((statement) => /^\s*select\b/i.test(statement))).toBe(true);
  });
});

describe("reconcile mode fail-closed behavior", () => {
  function spawnCli(env) {
    return spawnSync(
      process.execPath,
      ["--input-type=module", "-e", `import(${JSON.stringify(scriptUrl)}).then(({ main }) => main()).then((code) => process.exit(code))`],
      { cwd: repoRoot, encoding: "utf8", env: { ...process.env, ...env } },
    );
  }

  it("fails closed with exit 2 when SUPABASE_PROJECT_REF is missing", () => {
    const result = spawnCli({ SUPABASE_PROJECT_REF: "", SUPABASE_ACCESS_TOKEN: "" });
    expect(result.status).toBe(2);
    expect(result.stderr).toMatch(/SUPABASE_PROJECT_REF is required/);
  });

  it("fails closed with exit 2 when SUPABASE_ACCESS_TOKEN is missing", () => {
    const result = spawnCli({ SUPABASE_PROJECT_REF: "ref", SUPABASE_ACCESS_TOKEN: "" });
    expect(result.status).toBe(2);
    expect(result.stderr).toMatch(/SUPABASE_ACCESS_TOKEN/);
  });

  it("rejects --adopt and any other CLI argument", () => {
    const withArg = spawnSync(
      process.execPath,
      ["--input-type=module", "-e", `import(${JSON.stringify(scriptUrl)}).then(({ main }) => main(["--adopt"])).then((code) => process.exit(code))`],
      { cwd: repoRoot, encoding: "utf8", env: { ...process.env, SUPABASE_PROJECT_REF: "ref", SUPABASE_ACCESS_TOKEN: "token" } },
    );
    expect(withArg.status).toBe(2);
    expect(withArg.stderr).toMatch(/accepts no arguments/);
  });
});

describe("read-only mutation probes", () => {
  it("refuses every real migration SQL file", () => {
    const files = readdirSync(join(repoRoot, "db", "migrations")).filter((file) => file.endsWith(".sql"));
    expect(files.length).toBeGreaterThanOrEqual(9);
    for (const file of files) {
      const sql = readFileSync(join(repoRoot, "db", "migrations", file), "utf8");
      expect(() => assertReadOnly(sql), file).toThrow(/non-allowlisted/);
    }
  });

  it("refuses stacked statements, writable SELECTs, transactions, comments/whitespace variants, and every mutation category", () => {
    const rejected = [
      // Stacked statements smuggling writes after a SELECT.
      "select 1; insert into public.migration_ledger (name) values ('init')",
      "select name from public.migration_ledger order by name; delete from public.migration_ledger",
      "select 1; update public.goals set source = 'manual'",
      "select 1; drop table public.users",
      // Writable SELECT functions (fail-open regex would accept these).
      "select set_config('app.reconciled', 'yes', false)",
      "select pg_catalog.setval('public.some_seq', 1)",
      "select lo_unlink(1)",
      "select pg_terminate_backend(1)",
      "select dblink_exec('insert into public.migration_ledger (name) values (''x'')')",
      // Transactions around a SELECT.
      "begin; select 1; commit;",
      "select 1; commit;",
      "begin; select name from public.migration_ledger order by name; commit;",
      // Comments/whitespace/case variants of a real allowlisted query.
      "  select name from public.migration_ledger order by name",
      "select name from public.migration_ledger order by name;",
      "select name from public.migration_ledger order by name -- trail",
      "select name from public.migration_ledger order by name\n",
      "select/*x*/name from public.migration_ledger order by name",
      "SELECT name from public.migration_ledger order by name",
      // Every mutation category.
      "create table public.migration_ledger (name text)",
      "create index migration_ledger_idx on public.migration_ledger (name)",
      "create function public.f() returns void language sql as 'select 1'",
      "create policy p on public.users for select using (true)",
      "insert into public.migration_ledger (name) values ('init') on conflict (name) do nothing",
      "insert into public.migration_ledger (name) values ('init')",
      "update public.migration_ledger set name = 'x'",
      "delete from public.migration_ledger",
      "alter table public.weight_logs rename column logged_at to measured_at",
      "drop policy if exists food_images_insert_own on storage.objects",
      "drop table public.users",
      "grant insert on table public.food_catalog to service_role",
      "revoke execute on function public.upsert_food_catalog(jsonb) from public",
      "truncate table public.users",
      "comment on table public.users is 'x'",
      "copy public.users from stdin",
      "vacuum public.users",
      "analyze public.users",
      "merge into public.users using (select 1) as s on true when matched then update set email = 'x'",
      "call public.some_procedure()",
      "do $$ begin perform 1; end $$",
      "reindex table public.users",
      "refresh materialized view public.mv",
      // Ledger bootstrap DDL (the deploy lane's LEDGER_DDL).
      "create table if not exists public.migration_ledger (name text primary key, applied_at timestamptz not null default now())",
    ];
    for (const sql of rejected) {
      expect(() => assertReadOnly(sql), sql).toThrow(/non-allowlisted/);
    }
  });

  it("accepts exactly the six fixed queries and rejects every near-miss variant", () => {
    const fixed = [LEDGER_EXISTS_SQL, LEDGER_NAMES_SQL, ...Object.values(INVENTORY_SQL)];
    expect(fixed).toHaveLength(6);
    expect(ALLOWED_QUERIES.size).toBe(6);
    for (const sql of fixed) {
      expect(ALLOWED_QUERIES.has(sql), sql).toBe(true);
      expect(() => assertReadOnly(sql), sql).not.toThrow();
    }
    const nearMisses = [
      "select 1",
      "select name from public.migration_ledger", // missing order by
      `${LEDGER_NAMES_SQL} `, // trailing space
      `${LEDGER_NAMES_SQL};`, // trailing semicolon
      LEDGER_EXISTS_SQL.toUpperCase(),
      ` ${LEDGER_EXISTS_SQL}`,
    ];
    for (const sql of nearMisses) {
      expect(() => assertReadOnly(sql), sql).toThrow(/non-allowlisted/);
    }
  });

  it("only ever issues its fixed allowlisted queries through the query layer", async () => {
    // A hostile query layer that would run anything: the module guard still
    // ensures reconcile mode cannot smuggle migration SQL or ledger writes.
    const db = fakeDatabase({});
    await run({ ref: "ref", token: "token", root: repoRoot, queryImpl: db.query, log: quiet });
    const issued = new Set(db.sql);
    for (const statement of issued) {
      expect(ALLOWED_QUERIES.has(statement), statement).toBe(true);
    }
    expect(db.sql.every((statement) => /^\s*select\b/i.test(statement))).toBe(true);
  });

  it("never prints the project ref or token in the report, stdout, or errors", async () => {
    const ref = "supa-ref-abc123";
    const token = "supa-token-abc123";
    const db = fakeDatabase({});
    const result = await run({ ref, token, root: repoRoot, queryImpl: db.query, log: quiet });

    expect(result.report).toContain("project ref : [redacted]");
    expect(result.report).not.toContain(ref);
    expect(result.report).not.toContain(token);
    expect(JSON.stringify(result.checks)).not.toContain(ref);
    expect(JSON.stringify(result.checks)).not.toContain(token);

    // CLI arg rejection must not echo the supplied env values.
    const cli = spawnSync(
      process.execPath,
      ["--input-type=module", "-e", `import(${JSON.stringify(scriptUrl)}).then(({ main }) => main(["--adopt"])).then((code) => process.exit(code))`],
      { cwd: repoRoot, encoding: "utf8", env: { ...process.env, SUPABASE_PROJECT_REF: ref, SUPABASE_ACCESS_TOKEN: token } },
    );
    expect(cli.status).toBe(2);
    expect(cli.stderr).not.toContain(ref);
    expect(cli.stderr).not.toContain(token);

    // Missing-token error must not echo the supplied ref value.
    const missingToken = spawnSync(
      process.execPath,
      ["--input-type=module", "-e", `import(${JSON.stringify(scriptUrl)}).then(({ main }) => main()).then((code) => process.exit(code))`],
      { cwd: repoRoot, encoding: "utf8", env: { ...process.env, SUPABASE_PROJECT_REF: ref, SUPABASE_ACCESS_TOKEN: "" } },
    );
    expect(missingToken.status).toBe(2);
    expect(missingToken.stderr).not.toContain(ref);
    expect(missingToken.stderr).not.toContain("supa-token-abc123");
  });
});
