import { afterEach, describe, expect, it } from "vitest";
import { cpSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { execFileSync, spawnSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { run } from "./apply-migrations.mjs";

const files = [
  "0001_init.sql", "0002_targets.sql", "0003_atomic_meals_and_users_rls.sql",
  "0004_store_assets.sql", "0005_oauth_authorization_grants.sql", "0006_food_catalog_provider_cache.sql",
];
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

function database() {
  const ledger = new Set();
  const sql = [];
  const query = async (statement) => {
    sql.push(statement);
    if (statement.startsWith("select name")) return [...ledger].map((name) => ({ name }));
    const adoption = statement.match(/insert into public\.migration_ledger \(name\) values \('([^']+)'\)(?: on conflict.*)?/);
    if (adoption) ledger.add(adoption[1]);
    return [];
  };
  return { ledger, sql, query };
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

describe("migration deployment safety", () => {
  it("returns usage exit 2 for missing ref before stale-checkout exit 1", () => {
    const { root, checkout } = staleCliCheckout();
    dirs.push(root);
    const script = join(checkout, "scripts/apply-migrations.mjs");
    const result = spawnSync(process.execPath, ["--input-type=module", "-e", `import(${JSON.stringify(script)}).then(({ main }) => main()).then((code) => process.exit(code))`], {
      cwd: checkout,
      encoding: "utf8",
      env: { ...process.env, HOME: root, SUPABASE_PROJECT_REF: "", SUPABASE_ACCESS_TOKEN: "" },
    });
    expect(result.status).toBe(2);
    expect(result.stderr).toMatch(/SUPABASE_PROJECT_REF is required/);
    expect(result.stderr).not.toMatch(/STALE CHECKOUT/);
  });

  it("refuses an empty ledger in default mode", async () => {
    const root = await fixture();
    const db = database();
    await expect(run({ ref: "ref", token: "token", root, queryImpl: db.query, log: quiet })).rejects.toThrow(/ledger is empty.*--adopt/);
    expect(db.sql).toHaveLength(2);
  });

  it("adopts all local names without executing migration SQL", async () => {
    const root = await fixture();
    const db = database();
    const result = await run({ ref: "ref", token: "token", root, adopt: true, queryImpl: db.query, log: quiet });
    expect(result.adopted).toBe(6);
    expect([...db.ledger]).toEqual(files.map((file) => file.slice(5, -4)));
    expect(db.sql.every((statement) => statement.includes("migration_ledger") || statement.startsWith("select name"))).toBe(true);
  });

  it("makes adoption idempotent", async () => {
    const root = await fixture();
    const db = database();
    await run({ ref: "ref", token: "token", root, adopt: true, queryImpl: db.query, log: quiet });
    await expect(run({ ref: "ref", token: "token", root, adopt: true, queryImpl: db.query, log: quiet })).resolves.toMatchObject({ adopted: 6 });
    expect(db.ledger.size).toBe(6);
  });

  it("applies only a new append and rejects an older unrecorded file", async () => {
    const root = await fixture();
    const db = database();
    await run({ ref: "ref", token: "token", root, adopt: true, queryImpl: db.query, log: quiet });
    await writeFile(join(root, "db", "migrations", "0007_new_feature.sql"), "-- 0007_new_feature.sql");
    await expect(run({ ref: "ref", token: "token", root, queryImpl: db.query, log: quiet })).resolves.toMatchObject({ applied: ["0007_new_feature.sql"] });
    expect(db.sql.some((statement) => statement === "-- 0007_new_feature.sql")).toBe(true);

    const older = database();
    older.ledger.add("init");
    older.ledger.add("atomic_meals_and_users_rls");
    await expect(run({ ref: "ref", token: "token", root, queryImpl: older.query, log: quiet })).rejects.toThrow(/OLDER/);
    expect(older.sql.some((statement) => statement.includes("0002_targets"))).toBe(false);
  });
});
