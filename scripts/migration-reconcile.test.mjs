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
  main,
  run,
} from "./migration-reconcile.mjs";

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const scriptUrl = fileURLToPath(new URL("./migration-reconcile.mjs", import.meta.url));
const quiet = { log: () => {} };

// Valid-shaped synthetic inputs: 20-char lowercase alphanumeric project ref,
// token with >= 20 non-whitespace characters (passes shape validation so the
// request path, not the validation path, is exercised).
const REF = "abcdefghijklmnopqrst";
const TOKEN = "sbp_validtokenabcdefghijklmnopqrs";

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
      { table_name: "profiles", column_name: "timezone", data_type: "text" },
    ],
    routines: ["compute_targets", "log_meal_with_items", "log_meal_with_items_client", "claim_oauth_authorization_grant", "upsert_food_catalog"],
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
      ledgerNames: ["init", "targets", "atomic_meals_and_users_rls", "store_assets", "oauth_authorization_grants", "food_catalog_provider_cache", "weight_logs", "energy_burned_logs", "goals_fractional_calories", "meal_outbox_client_ids", "profiles_timezone"],
    });
    const result = await run({ ref: REF, token: TOKEN, root: repoRoot, queryImpl: db.query, log: quiet });

    expect(result.ledgerExists).toBe(true);
    expect(result.ledgerNames).toHaveLength(11);
    expect(result.report).toContain("ledger public.migration_ledger");
    expect(result.report).toContain("11 recorded");
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
    const result = await run({ ref: REF, token: TOKEN, root: repoRoot, queryImpl: db.query, log: quiet });

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
    const result = await run({ ref: REF, token: TOKEN, root: repoRoot, queryImpl: db.query, log: quiet });

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
    const result = spawnCli({ SUPABASE_PROJECT_REF: REF, SUPABASE_ACCESS_TOKEN: "" });
    expect(result.status).toBe(2);
    expect(result.stderr).toMatch(/SUPABASE_ACCESS_TOKEN/);
  });

  it("rejects --adopt and any other CLI argument", () => {
    const withArg = spawnSync(
      process.execPath,
      ["--input-type=module", "-e", `import(${JSON.stringify(scriptUrl)}).then(({ main }) => main(["--adopt"])).then((code) => process.exit(code))`],
      { cwd: repoRoot, encoding: "utf8", env: { ...process.env, SUPABASE_PROJECT_REF: REF, SUPABASE_ACCESS_TOKEN: TOKEN } },
    );
    expect(withArg.status).toBe(2);
    expect(withArg.stderr).toMatch(/accepts no arguments/);
  });

  it("rejects a malformed project ref before any request with a fixed message", async () => {
    const db = fakeDatabase({});
    await expect(
      run({ ref: "BAD REF!!!", token: TOKEN, root: repoRoot, queryImpl: db.query, log: quiet }),
    ).rejects.toThrow(/SUPABASE_PROJECT_REF is malformed/);
    expect(db.sql).toEqual([]); // no request reached the query layer
  });

  it("rejects a malformed access token (embedded newline) before any request", async () => {
    const db = fakeDatabase({});
    const badToken = "sbp_ok\nSECRETLEAK";
    await expect(
      run({ ref: REF, token: badToken, root: repoRoot, queryImpl: db.query, log: quiet }),
    ).rejects.toThrow(/SUPABASE_ACCESS_TOKEN is malformed/);
    expect(db.sql).toEqual([]);
  });

  it("CLI rejects malformed ref/token with fixed messages that omit the input", () => {
    const badRef = spawnCli({ SUPABASE_PROJECT_REF: "BAD REF!!!", SUPABASE_ACCESS_TOKEN: TOKEN });
    expect(badRef.status).toBe(2);
    expect(badRef.stderr).toMatch(/SUPABASE_PROJECT_REF is malformed/);
    expect(badRef.stderr).not.toContain("BAD REF!!!");

    const badToken = spawnCli({ SUPABASE_PROJECT_REF: REF, SUPABASE_ACCESS_TOKEN: "sbp_ok\nSECRETLEAK" });
    expect(badToken.status).toBe(2);
    expect(badToken.stderr).toMatch(/SUPABASE_ACCESS_TOKEN is malformed/);
    expect(badToken.stderr).not.toContain("SECRETLEAK");
  });

  it("CLI rejects raw env values with leading/trailing whitespace (exit 2, no input echo)", () => {
    const cases = [
      { SUPABASE_PROJECT_REF: `  ${REF}`, SUPABASE_ACCESS_TOKEN: TOKEN },
      { SUPABASE_PROJECT_REF: `${REF}\n`, SUPABASE_ACCESS_TOKEN: TOKEN },
      { SUPABASE_PROJECT_REF: `\t${REF}`, SUPABASE_ACCESS_TOKEN: TOKEN },
      { SUPABASE_PROJECT_REF: REF, SUPABASE_ACCESS_TOKEN: ` ${TOKEN}` },
      { SUPABASE_PROJECT_REF: REF, SUPABASE_ACCESS_TOKEN: `${TOKEN}\n` },
      { SUPABASE_PROJECT_REF: REF, SUPABASE_ACCESS_TOKEN: `${TOKEN}\t` },
    ];
    for (const env of cases) {
      const result = spawnCli(env);
      expect(result.status).toBe(2);
      expect(result.stderr).toMatch(/whitespace or control characters/);
      expect(result.stderr).not.toContain(REF);
      expect(result.stderr).not.toContain(TOKEN);
    }
  });
});

describe("credential sentinel redaction", () => {
  // Sentinel-shaped values are embedded in transport exceptions and must never
  // appear in any error message or stderr.
  const sentinelRef = REF;
  const sentinelToken = TOKEN;

  async function captureRunError(queryImpl = null, fetchImpl) {
    const originalFetch = globalThis.fetch;
    try {
      globalThis.fetch = fetchImpl;
      try {
        await run({ ref: sentinelRef, token: sentinelToken, root: repoRoot, queryImpl, log: quiet });
        return null;
      } catch (error) {
        return error;
      }
    } finally {
      globalThis.fetch = originalFetch;
    }
  }

  it("sanitizes transport exceptions that embed ref/token sentinels", async () => {
    const error = await captureRunError(null, async () => {
      throw new Error(`transport exploded token=${sentinelToken} ref=${sentinelRef}`);
    });
    expect(error.message).toMatch(/ledger existence failed: transport error/);
    expect(error.message).not.toContain(sentinelRef);
    expect(error.message).not.toContain(sentinelToken);
  });

  it("sanitizes HTTP errors to a fixed label + status", async () => {
    const error = await captureRunError(null, async () => ({ ok: false, status: 500 }));
    expect(error.message).toMatch(/ledger existence failed: HTTP 500/);
    expect(error.message).not.toContain(sentinelRef);
    expect(error.message).not.toContain(sentinelToken);
  });

  it("redacts a hostile string HTTP status containing ref/token/URL sentinels (run)", async () => {
    const hostile = `${sentinelToken} ${sentinelRef} https://evil.invalid/body`;
    const originalFetch = globalThis.fetch;
    try {
      globalThis.fetch = async () => ({ ok: false, status: hostile });
      let caught;
      try {
        await run({ ref: sentinelRef, token: sentinelToken, root: repoRoot, queryImpl: null, log: quiet });
      } catch (error) {
        caught = error;
      }
      expect(caught.message).toMatch(/ledger existence failed: HTTP error/);
      expect(caught.message).not.toContain(sentinelRef);
      expect(caught.message).not.toContain(sentinelToken);
      expect(caught.message).not.toContain("evil.invalid");
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("redacts a coercion-backed hostile HTTP status (toString/valueOf sentinels) without invoking it", async () => {
    const coercive = {
      toString() {
        return `${sentinelToken}`;
      },
      valueOf() {
        return `${sentinelRef}`;
      },
    };
    const originalFetch = globalThis.fetch;
    try {
      globalThis.fetch = async () => ({ ok: false, status: coercive });
      let caught;
      try {
        await run({ ref: sentinelRef, token: sentinelToken, root: repoRoot, queryImpl: null, log: quiet });
      } catch (error) {
        caught = error;
      }
      expect(caught.message).toMatch(/ledger existence failed: HTTP error/);
      expect(caught.message).not.toContain(sentinelRef);
      expect(caught.message).not.toContain(sentinelToken);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("main() stderr contains no sentinels for a hostile HTTP status", async () => {
    const originalFetch = globalThis.fetch;
    const originalRef = process.env.SUPABASE_PROJECT_REF;
    const originalToken = process.env.SUPABASE_ACCESS_TOKEN;
    const originalError = console.error;
    const stderr = [];
    try {
      process.env.SUPABASE_PROJECT_REF = sentinelRef;
      process.env.SUPABASE_ACCESS_TOKEN = sentinelToken;
      globalThis.fetch = async () => ({ ok: false, status: `${sentinelToken} ${sentinelRef} body` });
      console.error = (message) => stderr.push(String(message));
      const code = await main([]);
      expect(code).toBe(1);
      expect(stderr.join("\n")).not.toContain(sentinelRef);
      expect(stderr.join("\n")).not.toContain(sentinelToken);
      expect(stderr.join("\n")).toMatch(/HTTP error/);
    } finally {
      if (originalRef === undefined) delete process.env.SUPABASE_PROJECT_REF;
      else process.env.SUPABASE_PROJECT_REF = originalRef;
      if (originalToken === undefined) delete process.env.SUPABASE_ACCESS_TOKEN;
      else process.env.SUPABASE_ACCESS_TOKEN = originalToken;
      globalThis.fetch = originalFetch;
      console.error = originalError;
    }
  });

  it("sanitizes invalid response-body failures", async () => {
    const error = await captureRunError(null, async () => ({
      ok: true,
      json: async () => {
        throw new Error(`bad json token=${sentinelToken}`);
      },
    }));
    expect(error.message).toMatch(/ledger existence failed: invalid response body/);
    expect(error.message).not.toContain(sentinelRef);
    expect(error.message).not.toContain(sentinelToken);
  });

  it("main() prints only sanitized errors; ref/token sentinels never reach stderr", async () => {
    const originalFetch = globalThis.fetch;
    const originalRef = process.env.SUPABASE_PROJECT_REF;
    const originalToken = process.env.SUPABASE_ACCESS_TOKEN;
    const originalError = console.error;
    const stderr = [];
    try {
      process.env.SUPABASE_PROJECT_REF = sentinelRef;
      process.env.SUPABASE_ACCESS_TOKEN = sentinelToken;
      globalThis.fetch = async () => {
        throw new Error(`header token=${sentinelToken} ref=${sentinelRef}`);
      };
      console.error = (message) => stderr.push(String(message));
      const code = await main([]);
      expect(code).toBe(1);
    } finally {
      if (originalRef === undefined) delete process.env.SUPABASE_PROJECT_REF;
      else process.env.SUPABASE_PROJECT_REF = originalRef;
      if (originalToken === undefined) delete process.env.SUPABASE_ACCESS_TOKEN;
      else process.env.SUPABASE_ACCESS_TOKEN = originalToken;
      globalThis.fetch = originalFetch;
      console.error = originalError;
    }
    expect(stderr.join("\n")).not.toContain(sentinelRef);
    expect(stderr.join("\n")).not.toContain(sentinelToken);
    expect(stderr.join("\n")).toMatch(/failed/);
  });

  it("assertReadOnly never echoes query text", () => {
    const withSentinel = `select 1; -- ${TOKEN}`;
    let caught;
    try {
      assertReadOnly(withSentinel);
    } catch (error) {
      caught = error;
    }
    expect(caught.message).toBe("reconcile mode refuses non-allowlisted SQL");
    expect(caught.message).not.toContain(TOKEN);
  });

  it("sanitizes queryImpl exceptions so sentinels never escape run()", async () => {
    let caught;
    try {
      await run({
        ref: REF,
        token: TOKEN,
        root: repoRoot,
        queryImpl: async () => {
          throw new Error(`impl exploded token=${TOKEN} ref=${REF}`);
        },
        log: quiet,
      });
    } catch (error) {
      caught = error;
    }
    expect(caught.message).toMatch(/ledger existence failed: query error/);
    expect(caught.message).not.toContain(REF);
    expect(caught.message).not.toContain(TOKEN);
  });

  it("normalizes hostile accessor/proxy ledger rows so sentinels never escape run()", async () => {
    const hostileRow = new Proxy(
      {},
      {
        ownKeys() {
          throw new Error(`ownKeys token=${TOKEN} ref=${REF}`);
        },
        get() {
          throw new Error(`get token=${TOKEN} ref=${REF}`);
        },
      },
    );
    let caught;
    try {
      await run({
        ref: REF,
        token: TOKEN,
        root: repoRoot,
        queryImpl: async (sql) => {
          if (sql.includes("to_regclass")) return [{ name: "migration_ledger" }];
          if (sql.startsWith("select name from public.migration_ledger")) {
            return [{ name: "init" }, hostileRow];
          }
          return [];
        },
        log: quiet,
      });
    } catch (error) {
      caught = error;
    }
    expect(caught.message).toMatch(/ledger names failed: invalid response rows/);
    expect(caught.message).not.toContain(REF);
    expect(caught.message).not.toContain(TOKEN);
  });

  it("normalizes hostile accessor/proxy inventory rows so sentinels never escape run()", async () => {
    const hostileRow = new Proxy(
      {},
      {
        ownKeys() {
          throw new Error(`inv ownKeys token=${TOKEN}`);
        },
        get() {
          throw new Error(`inv get token=${REF}`);
        },
      },
    );
    let caught;
    try {
      await run({
        ref: REF,
        token: TOKEN,
        root: repoRoot,
        queryImpl: async (sql) => {
          if (sql.includes("to_regclass")) return [{ name: "migration_ledger" }];
          if (sql.startsWith("select name from public.migration_ledger")) return [];
          if (sql.includes("information_schema.tables")) return [hostileRow];
          return [];
        },
        log: quiet,
      });
    } catch (error) {
      caught = error;
    }
    expect(caught.message).toMatch(/table inventory failed: invalid response rows/);
    expect(caught.message).not.toContain(REF);
    expect(caught.message).not.toContain(TOKEN);
  });

  it("redacts hostile ledger rows containing ref/token/newline sentinels", async () => {
    const db = fakeDatabase({
      ledgerNames: ["init", "targets", `${TOKEN}`, `evil\n${REF}`, "  spaced  "],
    });
    const result = await run({ ref: REF, token: TOKEN, root: repoRoot, queryImpl: db.query, log: quiet });

    // Only safe local-manifest names are returned/reported; unknown rows are
    // counted, never echoed.
    expect(result.ledgerNames).toEqual(["init", "targets"]);
    expect(result.unknownLedgerCount).toBe(3);
    expect(result.report).toContain("2 recorded");
    expect(result.report).toContain("unknown: 3");
    expect(result.report).toContain("values redacted");
    expect(result.report).not.toContain(TOKEN);
    expect(result.report).not.toContain(REF);
    expect(result.report).not.toContain("evil");
    expect(result.report).not.toContain("spaced");
    expect(JSON.stringify(result.checks)).not.toContain(TOKEN);
  });

  it("redacts hostile inventory rows from report and returned fields", async () => {
    const db = fakeDatabase({
      tables: ["users", `evil-table\n${TOKEN}`],
      columns: [
        { table_name: "users", column_name: "timezone", data_type: "text" },
        { table_name: `evil-col\n${REF}`, column_name: "x", data_type: "text" },
      ],
      routines: [`evil-routine ${TOKEN}`],
      policies: [{ schemaname: "public", tablename: "evil", policyname: `p ${REF}` }],
    });
    const result = await run({ ref: REF, token: TOKEN, root: repoRoot, queryImpl: db.query, log: quiet });

    expect(result.report).not.toContain(TOKEN);
    expect(result.report).not.toContain(REF);
    expect(result.report).not.toContain("evil");
    expect(JSON.stringify(result.checks)).not.toContain(TOKEN);
    expect(JSON.stringify(result.checks)).not.toContain(REF);
  });

  it("main() output contains no sentinels when the database returns hostile rows", async () => {
    const originalFetch = globalThis.fetch;
    const originalRef = process.env.SUPABASE_PROJECT_REF;
    const originalToken = process.env.SUPABASE_ACCESS_TOKEN;
    const originalLog = console.log;
    const originalError = console.error;
    const out = [];
    try {
      process.env.SUPABASE_PROJECT_REF = REF;
      process.env.SUPABASE_ACCESS_TOKEN = TOKEN;
      const respond = (rows) => ({ ok: true, status: 200, json: async () => rows });
      globalThis.fetch = async (url, options) => {
        const { query } = JSON.parse(options.body);
        if (query.includes("to_regclass")) return respond([{ name: "migration_ledger" }]);
        if (query.startsWith("select name from public.migration_ledger")) {
          return respond([{ name: `${TOKEN}` }, { name: "init" }]);
        }
        if (query.includes("information_schema.tables")) return respond([{ table_name: `evil\n${REF}` }]);
        return respond([]);
      };
      console.log = (message) => out.push(String(message));
      console.error = (message) => out.push(String(message));
      const code = await main([]);
      expect(code).toBe(0);
    } finally {
      if (originalRef === undefined) delete process.env.SUPABASE_PROJECT_REF;
      else process.env.SUPABASE_PROJECT_REF = originalRef;
      if (originalToken === undefined) delete process.env.SUPABASE_ACCESS_TOKEN;
      else process.env.SUPABASE_ACCESS_TOKEN = originalToken;
      globalThis.fetch = originalFetch;
      console.log = originalLog;
      console.error = originalError;
    }
    const output = out.join("\n");
    expect(output).not.toContain(TOKEN);
    expect(output).not.toContain(REF);
    expect(output).not.toContain("evil");
    expect(output).toContain("unknown: 1");
  });

  it("main() rejects raw env whitespace before any fetch", async () => {
    const originalFetch = globalThis.fetch;
    const originalRef = process.env.SUPABASE_PROJECT_REF;
    const originalToken = process.env.SUPABASE_ACCESS_TOKEN;
    const originalError = console.error;
    let fetchCalls = 0;
    const stderr = [];
    try {
      process.env.SUPABASE_PROJECT_REF = ` ${REF}`;
      process.env.SUPABASE_ACCESS_TOKEN = TOKEN;
      globalThis.fetch = async () => {
        fetchCalls += 1;
        return { ok: true, json: async () => [] };
      };
      console.error = (message) => stderr.push(String(message));
      const code = await main([]);
      expect(code).toBe(2);
      expect(fetchCalls).toBe(0);
      expect(stderr.join("\n")).not.toContain(REF);
      expect(stderr.join("\n")).not.toContain(TOKEN);
    } finally {
      if (originalRef === undefined) delete process.env.SUPABASE_PROJECT_REF;
      else process.env.SUPABASE_PROJECT_REF = originalRef;
      if (originalToken === undefined) delete process.env.SUPABASE_ACCESS_TOKEN;
      else process.env.SUPABASE_ACCESS_TOKEN = originalToken;
      globalThis.fetch = originalFetch;
      console.error = originalError;
    }
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
    expect(ALLOWED_QUERIES.length).toBe(6);
    for (const sql of fixed) {
      expect(ALLOWED_QUERIES.includes(sql), sql).toBe(true);
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
    await run({ ref: REF, token: TOKEN, root: repoRoot, queryImpl: db.query, log: quiet });
    const issued = new Set(db.sql);
    expect(issued.size).toBe(6); // ledger existence + names + 4 inventory queries
    for (const statement of issued) {
      expect(ALLOWED_QUERIES.includes(statement), statement).toBe(true);
    }
    expect(db.sql.every((statement) => /^\s*select\b/i.test(statement))).toBe(true);
  });

  it("exported allowlist representation is immutable and cannot be widened", () => {
    const injected = "select set_config('app.reconciled', 'yes', false)";
    // A frozen ARRAY is the exported surface: mutation attempts throw in strict mode.
    expect(Object.isFrozen(ALLOWED_QUERIES)).toBe(true);
    expect(() => ALLOWED_QUERIES.push(injected)).toThrow();
    expect(() => ALLOWED_QUERIES.splice(0, 1)).toThrow();
    expect(() => ALLOWED_QUERIES.pop()).toThrow();
    expect(() => {
      ALLOWED_QUERIES[0] = injected;
    }).toThrow();
    // The exported surface is not a Set, so .add/.delete/.clear cannot widen it.
    expect(typeof ALLOWED_QUERIES.add).toBe("undefined");
    expect(typeof ALLOWED_QUERIES.delete).toBe("undefined");
    expect(typeof ALLOWED_QUERIES.clear).toBe("undefined");
    // The six fixed queries are still exactly the only accepted statements.
    expect(ALLOWED_QUERIES).toEqual([
      LEDGER_EXISTS_SQL,
      LEDGER_NAMES_SQL,
      ...Object.values(INVENTORY_SQL),
    ]);
    expect(() => assertReadOnly(injected)).toThrow(/non-allowlisted/);
  });

  it("exported INVENTORY_SQL is frozen and cannot redirect the internal queries", () => {
    const injected = "select set_config('app.reconciled', 'yes', false)";
    const tablesBefore = INVENTORY_SQL.tables;
    const policiesBefore = INVENTORY_SQL.policies;
    expect(Object.isFrozen(INVENTORY_SQL)).toBe(true);
    expect(() => {
      INVENTORY_SQL.tables = injected;
    }).toThrow();
    expect(() => {
      INVENTORY_SQL.policies = "select 1; drop table public.users";
    }).toThrow();
    // Values are unchanged after the attempted redirect.
    expect(INVENTORY_SQL.tables).toBe(tablesBefore);
    expect(INVENTORY_SQL.policies).toBe(policiesBefore);
    // The injected SELECT is still refused by the private membership set.
    expect(() => assertReadOnly(injected)).toThrow(/non-allowlisted/);
  });

  it("an injected writable SELECT can never reach the query layer (reviewer attack)", async () => {
    const injected = "select set_config('app.reconciled', 'yes', false)";
    // Step 1 of the round-2 reviewer attack: widen the allowlist — impossible.
    expect(() => ALLOWED_QUERIES.push(injected)).toThrow();
    // Step 2: redirect the exported inventory config — impossible.
    expect(() => {
      INVENTORY_SQL.tables = injected;
    }).toThrow();
    // The injected string is refused by the guard, and a full run still issues
    // exactly the six fixed queries with the ORIGINAL strings.
    expect(() => assertReadOnly(injected)).toThrow(/non-allowlisted/);
    const db = fakeDatabase({});
    await run({ ref: REF, token: TOKEN, root: repoRoot, queryImpl: db.query, log: quiet });
    expect(new Set(db.sql)).toEqual(
      new Set([LEDGER_EXISTS_SQL, LEDGER_NAMES_SQL, ...Object.values(INVENTORY_SQL)]),
    );
    expect(db.sql.every((statement) => ALLOWED_QUERIES.includes(statement))).toBe(true);
  });

  it("never prints the project ref or token in the report, stdout, or errors", async () => {
    const db = fakeDatabase({});
    const result = await run({ ref: REF, token: TOKEN, root: repoRoot, queryImpl: db.query, log: quiet });

    expect(result.report).toContain("project ref : [redacted]");
    expect(result.report).not.toContain(REF);
    expect(result.report).not.toContain(TOKEN);
    expect(JSON.stringify(result.checks)).not.toContain(REF);
    expect(JSON.stringify(result.checks)).not.toContain(TOKEN);

    // CLI arg rejection must not echo the supplied env values.
    const cli = spawnSync(
      process.execPath,
      ["--input-type=module", "-e", `import(${JSON.stringify(scriptUrl)}).then(({ main }) => main(["--adopt"])).then((code) => process.exit(code))`],
      { cwd: repoRoot, encoding: "utf8", env: { ...process.env, SUPABASE_PROJECT_REF: REF, SUPABASE_ACCESS_TOKEN: TOKEN } },
    );
    expect(cli.status).toBe(2);
    expect(cli.stderr).not.toContain(REF);
    expect(cli.stderr).not.toContain(TOKEN);

    // Missing-token error must not echo the supplied ref value.
    const missingToken = spawnSync(
      process.execPath,
      ["--input-type=module", "-e", `import(${JSON.stringify(scriptUrl)}).then(({ main }) => main()).then((code) => process.exit(code))`],
      { cwd: repoRoot, encoding: "utf8", env: { ...process.env, SUPABASE_PROJECT_REF: REF, SUPABASE_ACCESS_TOKEN: "" } },
    );
    expect(missingToken.status).toBe(2);
    expect(missingToken.stderr).not.toContain(REF);
    expect(missingToken.stderr).not.toContain(TOKEN);
  });
});
