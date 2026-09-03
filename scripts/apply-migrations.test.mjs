import { afterEach, describe, expect, it } from "vitest";
import { cpSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { execFileSync, spawnSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { hasTransactionControl, run, LEDGER_EXISTS_SQL } from "./apply-migrations.mjs";

const files = [
  "0001_init.sql", "0002_targets.sql", "0003_atomic_meals_and_users_rls.sql",
  "0004_store_assets.sql", "0005_oauth_authorization_grants.sql", "0006_food_catalog_provider_cache.sql",
];
const fileNames = files.map((file) => file.slice(5, -4));
const dirs = [];

afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

async function fixture(extra = []) {
  const root = await mkdtemp(join(tmpdir(), "morsel-migrations-"));
  dirs.push(root);
  await mkdir(join(root, "db", "migrations"), { recursive: true });
  for (const file of [...files, ...extra]) await writeFile(join(root, "db", "migrations", file), `-- ${file}`);
  return root;
}

// Fake Management API: ledger existence/rows are READ-ONLY state; every other
// statement must be the one atomic BEGIN..COMMIT request, which is applied
// atomically (or fails as a whole, leaving no ledger row).
function database({ ledgerExists = true, initialLedger = fileNames, failContent = null } = {}) {
  const ledger = new Set(initialLedger);
  const sql = [];
  let failures = 0;
  const query = async (statement) => {
    sql.push(statement);
    if (statement === LEDGER_EXISTS_SQL) {
      return [{ name: ledgerExists ? "public.migration_ledger" : null }];
    }
    if (statement.startsWith("select name from public.migration_ledger")) {
      return [...ledger].sort().map((name) => ({ name }));
    }
    // Anything else must be an atomic apply request.
    expect(statement).toMatch(/^begin;\n/);
    expect(statement).toMatch(/\ninsert into public\.migration_ledger \(name\) values \('[^']+'\);\ncommit;$/);
    const insert = /insert into public\.migration_ledger \(name\) values \('([^']+)'\)/.exec(statement);
    const name = insert ? insert[1] : null;
    if (failContent !== null && statement.includes(failContent)) {
      failures += 1;
      throw new Error("simulated migration failure (atomic request aborted)");
    }
    if (name) ledger.add(name);
    return [];
  };
  return { ledger, sql, query, failures: () => failures };
}

const quiet = { log: () => {} };

function git(cwd, ...args) {
  return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8" });
}

function staleCliCheckout() {
  const root = mkdtempSync(join(tmpdir(), "morsel-stale-cli-"));
  const remote = join(root, "remote.git");
  const writer = join(root, "writer");
  const checkout = join(root, "checkout");
  execFileSync("git", ["init", "--bare", remote], { encoding: "utf8" });
  git(remote, "symbolic-ref", "HEAD", "refs/heads/main");
  execFileSync("git", ["clone", remote, checkout], { encoding: "utf8" });
  git(checkout, "config", "user.email", "test@example.com");
  git(checkout, "config", "user.name", "Test");
  git(checkout, "checkout", "-b", "main");
  writeFileSync(join(checkout, "marker"), "initial");
  git(checkout, "add", "marker");
  git(checkout, "commit", "-m", "initial");
  git(checkout, "push", "-u", "origin", "main");
  execFileSync("git", ["clone", remote, writer], { encoding: "utf8" });
  git(writer, "config", "user.email", "test@example.com");
  git(writer, "config", "user.name", "Test");
  writeFileSync(join(writer, "marker"), "remote");
  git(writer, "add", "marker");
  git(writer, "commit", "-m", "remote advance");
  git(writer, "push", "origin", "main");
  mkdirSync(join(checkout, "scripts"), { recursive: true });
  cpSync(fileURLToPath(new URL("./apply-migrations.mjs", import.meta.url)), join(checkout, "scripts/apply-migrations.mjs"));
  cpSync(fileURLToPath(new URL("./migration-safety.mjs", import.meta.url)), join(checkout, "scripts/migration-safety.mjs"));
  return { root, checkout };
}

function invokeMain(scriptPath, args, { cwd, env }) {
  return spawnSync(process.execPath, ["--input-type=module", "-e", `import(${JSON.stringify(scriptPath)}).then(({ main }) => main(${JSON.stringify(args)})).then((code) => process.exit(code))`], {
    cwd,
    encoding: "utf8",
    env,
  });
}

describe("migration deployment safety (issue #76: no blind adoption, atomic appends)", () => {
  it("returns usage exit 2 for missing ref before stale-checkout exit 1", () => {
    const { root, checkout } = staleCliCheckout();
    dirs.push(root);
    const script = join(checkout, "scripts/apply-migrations.mjs");
    const result = invokeMain(script, [], {
      cwd: checkout,
      env: { ...process.env, HOME: root, SUPABASE_PROJECT_REF: "", SUPABASE_ACCESS_TOKEN: "" },
    });
    expect(result.status).toBe(2);
    expect(result.stderr).toMatch(/SUPABASE_PROJECT_REF is required/);
    expect(result.stderr).not.toMatch(/STALE CHECKOUT/);
  }, 20_000);

  it("rejects --adopt (exit 2) and issues zero write statements", () => {
    const { root, checkout } = staleCliCheckout();
    dirs.push(root);
    const script = join(checkout, "scripts/apply-migrations.mjs");
    const result = invokeMain(script, ["--adopt"], {
      cwd: checkout,
      env: { ...process.env, HOME: root, SUPABASE_PROJECT_REF: "abcdefghijklmnopqrst", SUPABASE_ACCESS_TOKEN: "sbp_test0123456789abcdef" },
    });
    expect(result.status).toBe(2);
    expect(result.stderr).toMatch(/--adopt was removed for issue #76/);
    expect(result.stderr).toMatch(/migration-recovery\.mjs/);
  }, 20_000);

  it("fails with ZERO writes when the ledger does not exist (no bootstrap write)", async () => {
    const root = await fixture();
    const db = database({ ledgerExists: false });
    await expect(run({ ref: "ref", token: "token", root, queryImpl: db.query, log: quiet })).rejects.toThrow(/ledger public\.migration_ledger does not exist/);
    expect(db.sql.length).toBeGreaterThan(0);
    for (const statement of db.sql) {
      expect(statement).toMatch(/^select /);
    }
    expect(db.sql.some((s) => /create table if not exists public\.migration_ledger/.test(s))).toBe(false);
  });

  it("fails with ZERO writes when the ledger is empty", async () => {
    const root = await fixture();
    const db = database({ initialLedger: [] });
    await expect(run({ ref: "ref", token: "token", root, queryImpl: db.query, log: quiet })).rejects.toThrow(/ledger is empty/);
    for (const statement of db.sql) {
      expect(statement).toMatch(/^select /);
    }
  });

  it("applies one allowed append atomically: single BEGIN..COMMIT request carries the migration SQL and its ledger insert", async () => {
    const root = await fixture(["0007_new_feature.sql"]);
    const migrationSql = await (await import("node:fs/promises")).readFile(join(root, "db", "migrations", "0007_new_feature.sql"), "utf8");
    const db = database();
    const result = await run({ ref: "ref", token: "token", root, queryImpl: db.query, log: quiet });
    expect(result.applied).toEqual(["0007_new_feature.sql"]);
    expect(db.ledger.has("new_feature")).toBe(true);
    const writes = db.sql.filter((s) => !/^select /.test(s));
    expect(writes).toHaveLength(1);
    expect(writes[0]).toBe(`begin;\n${migrationSql}\ninsert into public.migration_ledger (name) values ('new_feature');\ncommit;`);
    // The healthy path never issues the old bootstrap DDL.
    expect(db.sql.some((s) => /create table if not exists public\.migration_ledger/.test(s))).toBe(false);
  });

  it("a failing migration leaves NO ledger row (atomic request) and a retry after the fix succeeds", async () => {
    const root = await fixture(["0007_new_feature.sql", "0008_second_feature.sql"]);
    // 0007 content is failing; 0008 is plain and must NOT be attempted after
    // the failure (sequential stop), so the ledger keeps no 0007 row.
    await writeFile(join(root, "db", "migrations", "0007_new_feature.sql"), "create table public.boom (id int);\ninsert into public.no_such_table values (1);\n");
    const db = database({ failContent: "no_such_table" });
    await expect(run({ ref: "ref", token: "token", root, queryImpl: db.query, log: quiet })).rejects.toThrow(/simulated migration failure/);
    expect(db.ledger.has("new_feature")).toBe(false);
    expect(db.ledger.has("second_feature")).toBe(false);
    expect(db.failures()).toBe(1);
    // Retry: the same failing content still fails, then a fixed file succeeds.
    await expect(run({ ref: "ref", token: "token", root, queryImpl: db.query, log: quiet })).rejects.toThrow(/simulated migration failure/);
    await writeFile(join(root, "db", "migrations", "0007_new_feature.sql"), "create table if not exists public.boom (id int);\n");
    const retried = await run({ ref: "ref", token: "token", root, queryImpl: db.query, log: quiet });
    expect(retried.applied).toEqual(["0007_new_feature.sql", "0008_second_feature.sql"]);
    expect(db.ledger.has("new_feature")).toBe(true);
    expect(db.ledger.has("second_feature")).toBe(true);
  });

  it("rejects pending migration text with transaction control BEFORE any write (zero writes)", async () => {
    const root = await fixture(["0007_sneaky.sql"]);
    await writeFile(join(root, "db", "migrations", "0007_sneaky.sql"), "-- sneaky\nbegin;\nselect 1;\ncommit;\n");
    const db = database();
    await expect(run({ ref: "ref", token: "token", root, queryImpl: db.query, log: quiet })).rejects.toThrow(/transaction-control/);
    expect(db.sql.every((s) => /^select /.test(s))).toBe(true);
    expect(db.ledger.has("sneaky")).toBe(false);
  });

  it("allows dollar-quoted bodies that contain begin/end and rejects statement-level control forms", () => {
    expect(hasTransactionControl("do $f$ begin perform 1; end $f$;")).toBe(false);
    expect(hasTransactionControl("create function public.f() returns void as $function$ begin null; end; $function$ language plpgsql;")).toBe(false);
    expect(hasTransactionControl("-- commit is just a comment\nselect 1;")).toBe(false);
    expect(hasTransactionControl("/* rollback in a block comment */ select 1;")).toBe(false);
    expect(hasTransactionControl("insert into t values ('a literal with begin inside');")).toBe(false);
    expect(hasTransactionControl("begin; select 1; commit;")).toBe(true);
    expect(hasTransactionControl("select 1;\nrollback;")).toBe(true);
    expect(hasTransactionControl("savepoint sp1;")).toBe(true);
    expect(hasTransactionControl("start transaction;")).toBe(true);
    expect(hasTransactionControl("select 1;\nabort;")).toBe(true);
    expect(hasTransactionControl("select 1;\nend;")).toBe(true);
  });

  it("applies a pending migration whose only transaction-like words live in a DO body", async () => {
    const root = await fixture(["0007_do_feature.sql"]);
    await writeFile(join(root, "db", "migrations", "0007_do_feature.sql"), "do $recovery$ begin perform 1; end $recovery$;");
    const db = database();
    const result = await run({ ref: "ref", token: "token", root, queryImpl: db.query, log: quiet });
    expect(result.applied).toEqual(["0007_do_feature.sql"]);
    expect(db.ledger.has("do_feature")).toBe(true);
    expect(db.sql.filter((s) => !/^select /.test(s))).toHaveLength(1);
  });

  it("rejects an older unrecorded migration and never replays it", async () => {
    const root = await fixture();
    const db = database({ initialLedger: ["init", "atomic_meals_and_users_rls"] });
    await expect(run({ ref: "ref", token: "token", root, queryImpl: db.query, log: quiet })).rejects.toThrow(/OLDER/);
    expect(db.sql.filter((s) => !/^select /.test(s))).toHaveLength(0);
  });

  it("reports when every local migration is already recorded with no writes", async () => {
    const root = await fixture();
    const db = database();
    const result = await run({ ref: "ref", token: "token", root, queryImpl: db.query, log: quiet });
    expect(result.applied).toEqual([]);
    expect(db.sql.filter((s) => !/^select /.test(s))).toHaveLength(0);
  });
});
