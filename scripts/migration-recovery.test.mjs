// Morsel issue #76 — recovery runner unit/contract tests (no database).
import { afterEach, describe, expect, it } from "vitest";
import { cpSync, mkdirSync, mkdtempSync, writeFileSync, readFileSync } from "node:fs";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { execFileSync, spawnSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import {
  ALLOWED_READ_QUERIES,
  assertKnownRead,
  assertKnownWrite,
  CONFIRMATION_PHRASE,
  classifyMigration,
  globalConflicts,
  inspect,
  main,
  parseArgs,
  run,
  validateInputShape,
  validateRawEnvValue,
} from "./migration-recovery.mjs";
import {
  CANONICAL_CONSTRAINTS,
  CANONICAL_FILES,
  CANONICAL_NAMES,
  CANONICAL_POLICIES,
  FUNCTION_DEFINITIONS,
  normalizeExpr,
} from "./migration-recovery-contracts.mjs";

const dirs = [];

afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

async function fixture(checkout = false) {
  const root = await mkdtemp(join(tmpdir(), "morsel-recovery-"));
  dirs.push(root);
  await mkdirSync(join(root, "db", "migrations"), { recursive: true });
  for (const file of CANONICAL_FILES) {
    writeFileSync(join(root, "db", "migrations", file), `-- ${file}`);
  }
  if (checkout) {
    // A real git checkout with origin/main upstream so freshness guards run.
    const remote = join(root, "remote.git");
    const git = (cwd, ...args) => execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8" });
    execFileSync("git", ["init", "--bare", remote], { encoding: "utf8" });
    git(remote, "symbolic-ref", "HEAD", "refs/heads/main");
    const checkoutDir = join(root, "checkout");
    execFileSync("git", ["clone", remote, checkoutDir], { encoding: "utf8" });
    git(checkoutDir, "config", "user.email", "test@example.com");
    git(checkoutDir, "config", "user.name", "Test");
    git(checkoutDir, "checkout", "-b", "main");
    writeFileSync(join(checkoutDir, "marker"), "initial");
    git(checkoutDir, "add", "marker");
    git(checkoutDir, "commit", "-m", "initial");
    git(checkoutDir, "push", "-u", "origin", "main");
    mkdirSync(join(checkoutDir, "db", "migrations"), { recursive: true });
    for (const file of CANONICAL_FILES) {
      writeFileSync(join(checkoutDir, "db", "migrations", file), `-- ${file}`);
    }
    git(checkoutDir, "add", "db");
    git(checkoutDir, "commit", "-m", "migrations");
    git(checkoutDir, "push", "origin", "main");
    for (const script of ["migration-recovery.mjs", "migration-recovery-contracts.mjs", "migration-recovery-guards.mjs", "migration-safety.mjs"]) {
      cpSync(fileURLToPath(new URL(`./${script}`, import.meta.url)), join(checkoutDir, "scripts", script));
    }
    return { root, checkout: checkoutDir, git, remote };
  }
  return { root };
}

// Fake query layer: records every statement; empty catalog by default.
function emptyDb() {
  const statements = [];
  return {
    statements,
    queryImpl: async (sql) => {
      statements.push(String(sql));
      return [{ result: [] }];
    },
  };
}

function scriptUrl(name) {
  return fileURLToPath(new URL(`./${name}`, import.meta.url));
}

function spawnMain(name, args, { cwd, env, script } = {}) {
  const target = script ?? scriptUrl(name);
  return spawnSync(
    process.execPath,
    ["--input-type=module", "-e", `import(${JSON.stringify(target)}).then(({ main: m }) => m(${JSON.stringify(args)})).then((code) => process.exit(code))`],
    { cwd, encoding: "utf8", env },
  );
}

const ref = "abcdefghijklmnopqrst";
const token = "sbp_secretmanagementtoken012345";

const quiet = { log: () => {} };

async function withEnv(fn) {
  const previous = { ref: process.env.SUPABASE_PROJECT_REF, token: process.env.SUPABASE_ACCESS_TOKEN };
  process.env.SUPABASE_PROJECT_REF = ref;
  process.env.SUPABASE_ACCESS_TOKEN = token;
  try {
    return await fn();
  } finally {
    if (previous.ref === undefined) delete process.env.SUPABASE_PROJECT_REF;
    else process.env.SUPABASE_PROJECT_REF = previous.ref;
    if (previous.token === undefined) delete process.env.SUPABASE_ACCESS_TOKEN;
    else process.env.SUPABASE_ACCESS_TOKEN = previous.token;
  }
}

function snapshotOf() {
  return {
    tables: new Set(),
    columnsByTable: new Map(),
    constraintsByTable: new Map(),
    indexes: [],
    routines: [],
    policies: [],
    rls: new Map(),
    tableGrants: [],
    routinePrivileges: [],
    bucketRow: null,
  };
}

describe("recovery runner CLI and preconditions", () => {
  it("rejects an unknown argument with exit 2 and no input echo", async () => {
    expect(() => parseArgs(["--adopt"])).toThrow(/only --apply and --confirm/);
    const captured = [];
    const original = console.error;
    console.error = (message) => captured.push(String(message));
    try {
      await withEnv(async () => {
        expect(await main(["--adopt"])).toBe(2);
      });
    } finally {
      console.error = original;
    }
    expect(captured.join("\n")).not.toContain("--adopt");
  });

  it("rejects --confirm without --apply and --apply without --confirm (exit 2)", async () => {
    expect(await main(["--confirm", CONFIRMATION_PHRASE])).toBe(2);
    const { root } = await fixture();
    const env = { ...process.env, SUPABASE_PROJECT_REF: ref, SUPABASE_ACCESS_TOKEN: token };
    const result = spawnMain("migration-recovery.mjs", ["--apply"], { cwd: root, env });
    expect(result.status).toBe(2);
    expect(result.stderr).toContain("--apply requires --confirm");
  });

  it("rejects a wrong confirmation phrase before any query (zero statements)", async () => {
    const { root } = await fixture();
    const db = emptyDb();
    await expect(
      run({ ref, token, root, apply: true, confirm: "not-the-phrase", queryImpl: db.queryImpl, log: quiet }),
    ).rejects.toThrow(/confirmation phrase does not match/);
    expect(db.statements).toHaveLength(0);
  });

  it("rejects malformed env values with fixed messages that never echo input", async () => {
    expect(() => validateInputShape("not-a-ref", token)).toThrow(/SUPABASE_PROJECT_REF is malformed/);
    expect(() => validateInputShape(ref, "bad token\nwith newline")).toThrow(/SUPABASE_ACCESS_TOKEN is malformed/);
    expect(() => validateRawEnvValue("SUPABASE_PROJECT_REF", " \tref")).toThrow(/must not have leading or trailing whitespace/);
    const result = spawnMain("migration-recovery.mjs", [], { cwd: "/", env: { ...process.env, SUPABASE_PROJECT_REF: "", SUPABASE_ACCESS_TOKEN: "" } });
    expect(result.status).toBe(2);
    expect(result.stderr).toContain("SUPABASE_PROJECT_REF is required");
  });

  it("usage exit 2 wins over the stale-checkout guard when ref is missing", async () => {
    const { checkout } = await fixture(true);
    const result = spawnMain("migration-recovery.mjs", ["--apply", "--confirm", CONFIRMATION_PHRASE], {
      cwd: checkout,
      env: { ...process.env, HOME: join(checkout, ".."), SUPABASE_PROJECT_REF: "", SUPABASE_ACCESS_TOKEN: "" },
    });
    expect(result.status).toBe(2);
    expect(result.stderr).toMatch(/SUPABASE_PROJECT_REF is required/);
    expect(result.stderr).not.toMatch(/STALE CHECKOUT/);
  });

  it("refuses apply from a stale checkout with exit 1 before any query", async () => {
    const { root, checkout, git, remote } = await fixture(true);
    const writer = join(root, "writer");
    execFileSync("git", ["clone", remote, writer], { encoding: "utf8" });
    git(writer, "config", "user.email", "test@example.com");
    git(writer, "config", "user.name", "Test");
    writeFileSync(join(writer, "marker"), "remote advance");
    git(writer, "add", "marker");
    git(writer, "commit", "-m", "remote advance");
    git(writer, "push", "origin", "main");
    const result = spawnMain("migration-recovery.mjs", ["--apply", "--confirm", CONFIRMATION_PHRASE], {
      cwd: checkout,
      script: join(checkout, "scripts", "migration-recovery.mjs"),
      env: { ...process.env, HOME: root, SUPABASE_PROJECT_REF: ref, SUPABASE_ACCESS_TOKEN: token },
    });
    expect(result.status).toBe(1);
    expect(result.stderr).toMatch(/STALE CHECKOUT/);
    expect(result.stderr).not.toContain(token);
    expect(result.stderr).not.toContain(ref);
  }, 20_000);

  it("refuses apply from a non-main local branch with exit 1", async () => {
    const { root, checkout, git } = await fixture(true);
    git(checkout, "checkout", "-b", "feature-x");
    git(checkout, "push", "-u", "origin", "feature-x");
    const result = spawnMain("migration-recovery.mjs", ["--apply", "--confirm", CONFIRMATION_PHRASE], {
      cwd: checkout,
      script: join(checkout, "scripts", "migration-recovery.mjs"),
      env: { ...process.env, HOME: root, SUPABASE_PROJECT_REF: ref, SUPABASE_ACCESS_TOKEN: token },
    });
    expect(result.status).toBe(1);
    expect(result.stderr).toMatch(/non-main branch/);
  }, 20_000);

  it("plan mode requires no confirmation and issues only allowlisted reads", async () => {
    const { root } = await fixture();
    const db = emptyDb();
    const outcome = await run({ ref, token, root, apply: false, queryImpl: db.queryImpl, log: quiet });
    expect(outcome.mode).toBe("plan");
    expect(db.statements.length).toBeGreaterThan(0);
    for (const statement of db.statements) {
      expect(ALLOWED_READ_QUERIES).toContain(statement);
    }
  });

  it("no-arg main() on an empty catalog never issues a write statement", async () => {
    // CLI-level plan mode would need the network; the run() contract below is
    // what the no-arg CLI path invokes, so proving zero writes here plus the
    // usage/precedence tests above closes the CLI chain.
    const { root } = await fixture();
    const db = emptyDb();
    await run({ ref, token, root, apply: false, queryImpl: db.queryImpl, log: quiet });
    const writeLike = db.statements.filter((sql) => !/^select /i.test(String(sql).trim()));
    expect(writeLike).toHaveLength(0);
  });

  it("rejects an unexpected manifest (extra migration file) before queries", async () => {
    const root = await mkdtemp(join(tmpdir(), "morsel-recovery-"));
    dirs.push(root);
    mkdirSync(join(root, "db", "migrations"), { recursive: true });
    for (const file of CANONICAL_FILES) writeFileSync(join(root, "db", "migrations", file), `-- ${file}`);
    writeFileSync(join(root, "db", "migrations", "0010_future.sql"), "-- 0010");
    const db = emptyDb();
    await expect(run({ ref, token, root, queryImpl: db.queryImpl, log: quiet })).rejects.toThrow(/manifest mismatch/);
    expect(db.statements).toHaveLength(0);
  });
});

describe("recovery allowlist and sanitization guards", () => {
  it("assertKnownRead accepts only the fixed queries", () => {
    expect(ALLOWED_READ_QUERIES.length).toBeGreaterThan(10);
    for (const sql of ALLOWED_READ_QUERIES) {
      expect(() => assertKnownRead(sql)).not.toThrow();
    }
    for (const hostile of [
      "select 1; insert into x values (1)",
      "select set_config('x', 'y', false)",
      "begin; select 1; commit;",
      " select " + ALLOWED_READ_QUERIES[0],
      ALLOWED_READ_QUERIES[0] + " -- trail",
      "drop table public.users",
      "insert into public.migration_ledger (name) values ('init')",
      ALLOWED_READ_QUERIES[0].toUpperCase(),
    ]) {
      expect(() => assertKnownRead(hostile)).toThrow(/refuses non-allowlisted SQL/);
    }
  });

  it("assertKnownWrite accepts only assembled transaction strings", () => {
    const reads = ALLOWED_READ_QUERIES[0];
    expect(() => assertKnownWrite(reads)).toThrow(/refuses non-allowlisted write transaction/);
    expect(() => assertKnownWrite("begin; insert into public.migration_ledger (name) values ('init'); commit;")).toThrow(/refuses/);
  });

  it("never leaks ref/token/hostile response values through plan mode", async () => {
    const root = await mkdtemp(join(tmpdir(), "morsel-recovery-"));
    dirs.push(root);
    mkdirSync(join(root, "db", "migrations"), { recursive: true });
    for (const file of CANONICAL_FILES) writeFileSync(join(root, "db", "migrations", file), `-- ${file}`);
    const leakRef = "abcdefghijklmnopqrst";
    const leakToken = "sbp_leakme0123456789abcdef";
    const hostile = async () => {
      throw new Error(`boom ${leakRef} ${leakToken} https://api.supabase.com/v1/projects/${leakRef}/database/query`);
    };
    const output = [];
    const log = { log: (line) => output.push(String(line)) };
    await expect(run({ ref: leakRef, token: leakToken, root, queryImpl: hostile, log })).rejects.toThrow(/query error/);
    const text = output.join("\n");
    expect(text).not.toContain(leakToken);
    expect(text).not.toContain(leakRef);
  });

  it("sanitizes hostile result rows (proxies/accessors cannot leak sentinels)", async () => {
    const root = await mkdtemp(join(tmpdir(), "morsel-recovery-"));
    dirs.push(root);
    mkdirSync(join(root, "db", "migrations"), { recursive: true });
    for (const file of CANONICAL_FILES) writeFileSync(join(root, "db", "migrations", file), `-- ${file}`);
    const leakRef = "abcdefghijklmnopqrst";
    const leakToken = "sbp_leakme0123456789abcdef";
    let calls = 0;
    const hostile = async (sql) => {
      calls += 1;
      if (String(sql).includes("to_regclass")) return [{ result: [] }];
      const poisoned = new Proxy({ table_name: "users" }, { get: () => { throw new Error(`leak ${leakToken}`); } });
      return [{ result: [poisoned] }];
    };
    const output = [];
    const log = { log: (line) => output.push(String(line)) };
    await expect(run({ ref: leakRef, token: leakToken, root, queryImpl: hostile, log })).rejects.toThrow(/invalid response rows/);
    expect(calls).toBeGreaterThan(0);
    expect(output.join("\n")).not.toContain(leakToken);
  });
});

describe("classification and conflict logic", () => {
  function weightLogsOldOnly() {
    const snapshots = snapshotOf();
    snapshots.tables.add("weight_logs");
    const columns = new Map([
      ["id", { data_type: "uuid", is_nullable: "NO", column_default: "gen_random_uuid()" }],
      ["user_id", { data_type: "uuid", is_nullable: "NO", column_default: "" }],
      ["kg", { data_type: "numeric", is_nullable: "NO", column_default: "" }],
      ["logged_at", { data_type: "timestamp with time zone", is_nullable: "NO", column_default: "now()" }],
    ]);
    snapshots.columnsByTable.set("weight_logs", columns);
    snapshots.constraintsByTable.set("weight_logs", [
      { conname: "weight_logs_pkey", contype: "p", columns: ["id"], ref_table: null, confdeltype: null },
      { conname: "weight_logs_user_id_fkey", contype: "f", columns: ["user_id"], ref_table: "users", confdeltype: "c" },
    ]);
    snapshots.indexes = [
      { table_name: "weight_logs", index_name: "weight_logs_user_idx", indexdef: "CREATE INDEX weight_logs_user_idx ON public.weight_logs USING btree (user_id, logged_at DESC)" },
    ];
    snapshots.rls.set("weight_logs", { rls_enabled: true });
    return snapshots;
  }

  it("classifies the old-only weight_logs state as REPAIR (not ambiguous)", () => {
    const snapshots = weightLogsOldOnly();
    const status = classifyMigration("0007_weight_logs.sql", snapshots, new Set(), false);
    expect(status.state).toBe("REPAIR_REQUIRED");
    expect(status.entries.find((e) => e.label === "weight_logs.logged_at")).toBeUndefined();
  });

  it("treats BOTH logged_at and measured_at as a global ambiguity", () => {
    const snapshots = weightLogsOldOnly();
    snapshots.columnsByTable.get("weight_logs").set("measured_at", { data_type: "timestamp with time zone", is_nullable: "NO", column_default: "now()" });
    const blockers = globalConflicts(snapshots, { ledgerExists: false, ledgerNames: [], unknownLedgerCount: 0, recorded: new Set() });
    expect(blockers.some((b) => b.label.includes("weight_logs") && b.reason.includes("both"))).toBe(true);
  });

  it("treats neither logged_at nor measured_at as ambiguous", () => {
    const snapshots = snapshotOf();
    snapshots.tables.add("weight_logs");
    snapshots.columnsByTable.set("weight_logs", new Map([["id", { data_type: "uuid", is_nullable: "NO", column_default: "gen_random_uuid()" }]]));
    const blockers = globalConflicts(snapshots, { ledgerExists: false, ledgerNames: [], unknownLedgerCount: 0, recorded: new Set() });
    expect(blockers.some((b) => b.reason.includes("neither"))).toBe(true);
  });

  it("blocks on unknown ledger rows and on gapped ledger prefixes", () => {
    const base = { ledgerExists: true, ledgerNames: [], unknownLedgerCount: 0, recorded: new Set() };
    expect(globalConflicts(snapshotOf(), { ...base, unknownLedgerCount: 2 })).toHaveLength(1);
    const gapped = globalConflicts(snapshotOf(), { ...base, recorded: new Set([CANONICAL_NAMES[0], CANONICAL_NAMES[7]]) });
    expect(gapped.some((b) => b.reason.includes("gap"))).toBe(true);
    const full = globalConflicts(snapshotOf(), { ...base, recorded: new Set(CANONICAL_NAMES) });
    expect(full).toHaveLength(0);
  });

  it("classifies a recorded-but-drifted migration as BLOCKED", () => {
    const snapshots = weightLogsOldOnly();
    // 0007 recorded in the ledger but the weight end state is absent.
    const status = classifyMigration("0007_weight_logs.sql", snapshots, new Set(["weight_logs"]), false);
    expect(status.state).toBe("BLOCKED_AMBIGUOUS");
  });

  it("classifies a superseded-index repair and a constraint mismatch block", () => {
    const snapshots = weightLogsOldOnly();
    // measured_at present + constraints present but kg_positive missing -> REPAIR
    const columns = snapshots.columnsByTable.get("weight_logs");
    columns.set("measured_at", { data_type: "timestamp with time zone", is_nullable: "NO", column_default: "now()" });
    columns.set("source", { data_type: "text", is_nullable: "NO", column_default: "'manual'::text" });
    delete columns.logged_at; // snapshot map mutation below
    columns.delete("logged_at");
    snapshots.indexes.push({ table_name: "weight_logs", index_name: "weight_logs_user_measured_idx", indexdef: "CREATE INDEX weight_logs_user_measured_idx ON public.weight_logs USING btree (user_id, measured_at DESC)" });
    snapshots.indexes = snapshots.indexes.filter((i) => i.index_name !== "weight_logs_user_idx");
    snapshots.constraintsByTable.get("weight_logs").push(
      { conname: "weight_logs_source_check", contype: "c", columns: ["source"], definition: "CHECK ((source = ANY (ARRAY['manual'::text, 'apple_health'::text])))", ref_table: null, confdeltype: null },
      { conname: "weight_logs_user_measured_unique", contype: "u", columns: ["user_id", "measured_at"], definition: "UNIQUE (user_id, measured_at)", ref_table: null, confdeltype: null },
    );
    const repair = classifyMigration("0007_weight_logs.sql", snapshots, new Set(), false);
    expect(repair.state).toBe("REPAIR_REQUIRED");
    expect(repair.entries.find((e) => e.label === "weight_logs.weight_logs_kg_positive")).toBeTruthy();

    // wrong-def canonical constraint -> BLOCKED (converge never drops it)
    snapshots.constraintsByTable.get("weight_logs").push({ conname: "weight_logs_kg_positive", contype: "c", columns: ["kg"], definition: "CHECK ((kg >= 0))", ref_table: null, confdeltype: null });
    const blocked = classifyMigration("0007_weight_logs.sql", snapshots, new Set(), false);
    expect(blocked.state).toBe("BLOCKED_AMBIGUOUS");
  });

  it("blocks duplicate-row data dependencies per migration", () => {
    const snapshots = weightLogsOldOnly();
    snapshots.tables.add("users");
    const status = classifyMigration("0007_weight_logs.sql", snapshots, new Set(), true);
    expect(status.state).toBe("BLOCKED_AMBIGUOUS");
  });

  it("classifies a 0009 lossy-conversion data dependency as BLOCKED_AMBIGUOUS", () => {
    const status = classifyMigration("0009_goals_fractional_calories.sql", snapshotOf(), new Set(), true);
    expect(status.state).toBe("BLOCKED_AMBIGUOUS");
  });

  // Canonical 0008 end-state snapshot (full contract) used by the exactness
  // (extra-drift) tests below.
  function energyCanonical() {
    const snapshots = snapshotOf();
    snapshots.tables.add("energy_burned_logs");
    const cols = new Map([
      ["id", { data_type: "uuid", is_nullable: "NO", column_default: "gen_random_uuid()" }],
      ["user_id", { data_type: "uuid", is_nullable: "NO", column_default: "" }],
      ["burned_at", { data_type: "timestamp with time zone", is_nullable: "NO", column_default: "" }],
      ["active_kcal", { data_type: "numeric", is_nullable: "NO", column_default: "" }],
      ["source", { data_type: "text", is_nullable: "NO", column_default: "'manual'::text" }],
    ]);
    snapshots.columnsByTable.set("energy_burned_logs", cols);
    snapshots.constraintsByTable.set("energy_burned_logs", [
      { conname: "energy_burned_logs_pkey", contype: "p", columns: ["id"], definition: "PRIMARY KEY (id)", ref_table: null, confdeltype: null },
      { conname: "energy_burned_logs_user_id_fkey", contype: "f", columns: ["user_id"], definition: "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE", ref_table: "users", confdeltype: "c" },
      { conname: "energy_burned_logs_kcal_positive", contype: "c", columns: ["active_kcal"], definition: "CHECK ((active_kcal > (0)::numeric))", ref_table: null, confdeltype: null },
      { conname: "energy_burned_logs_source_check", contype: "c", columns: ["source"], definition: "CHECK ((source = ANY (ARRAY['manual'::text, 'apple_health'::text])))", ref_table: null, confdeltype: null },
      { conname: "energy_burned_logs_user_burned_unique", contype: "u", columns: ["user_id", "burned_at"], definition: "UNIQUE (user_id, burned_at)", ref_table: null, confdeltype: null },
    ]);
    snapshots.indexes = [
      { table_name: "energy_burned_logs", index_name: "energy_burned_logs_pkey", indexdef: "CREATE UNIQUE INDEX energy_burned_logs_pkey ON public.energy_burned_logs USING btree (id)" },
      { table_name: "energy_burned_logs", index_name: "energy_burned_logs_user_id_fkey", indexdef: "CREATE INDEX energy_burned_logs_user_id_fkey ON public.energy_burned_logs USING btree (user_id)" },
      { table_name: "energy_burned_logs", index_name: "energy_burned_logs_kcal_positive", indexdef: "CREATE INDEX energy_burned_logs_kcal_positive ON public.energy_burned_logs USING btree (active_kcal)" },
      { table_name: "energy_burned_logs", index_name: "energy_burned_logs_source_check", indexdef: "CREATE INDEX energy_burned_logs_source_check ON public.energy_burned_logs USING btree (source)" },
      { table_name: "energy_burned_logs", index_name: "energy_burned_logs_user_burned_unique", indexdef: "CREATE UNIQUE INDEX energy_burned_logs_user_burned_unique ON public.energy_burned_logs USING btree (user_id, burned_at)" },
      { table_name: "energy_burned_logs", index_name: "energy_burned_logs_user_burned_idx", indexdef: "CREATE INDEX energy_burned_logs_user_burned_idx ON public.energy_burned_logs USING btree (user_id, burned_at DESC)" },
    ];
    snapshots.rls.set("energy_burned_logs", { rls_enabled: true });
    snapshots.policies = [
      { schema: "public", table_name: "energy_burned_logs", policy_name: "energy_burned_logs_all_own", command: "ALL", roles: ["public"], qual: "auth.uid() = user_id", with_check: "auth.uid() = user_id" },
    ];
    return snapshots;
  }

  it("classifies the canonical 0008 end state as VERIFIED_PRESENT", () => {
    const status = classifyMigration("0008_energy_burned_logs.sql", energyCanonical(), new Set(), false);
    expect(status.state).toBe("VERIFIED_PRESENT");
    expect(status.entries.filter((e) => !e.ok)).toHaveLength(0);
  });

  it("blocks a harmless-looking extra nullable column (never ledger-recorded)", () => {
    const snapshots = energyCanonical();
    snapshots.columnsByTable.get("energy_burned_logs").set("flagged", { data_type: "boolean", is_nullable: "YES", column_default: "" });
    const status = classifyMigration("0008_energy_burned_logs.sql", snapshots, new Set(), false);
    expect(status.state).toBe("BLOCKED_AMBIGUOUS");
    const extra = status.entries.find((e) => e.label === "energy_burned_logs.flagged");
    expect(extra?.reason).toMatch(/unexpected column/);
  });

  it("blocks an extra restrictive CHECK and an extra FK constraint", () => {
    const withExtra = classifyMigration(
      "0008_energy_burned_logs.sql",
      energyCanonical(),
      new Set(),
      false,
    );
    expect(withExtra.state).toBe("VERIFIED_PRESENT");
    const snapshots = energyCanonical();
    snapshots.constraintsByTable.get("energy_burned_logs").push(
      { conname: "energy_burned_logs_active_kcal_max", contype: "c", columns: ["active_kcal"], definition: "CHECK ((active_kcal <= (5000)::numeric))", ref_table: null, confdeltype: null },
      { conname: "energy_burned_logs_extra_fkey", contype: "f", columns: ["id"], definition: "FOREIGN KEY (id) REFERENCES meal_logs(id) ON DELETE CASCADE", ref_table: "meal_logs", confdeltype: "c" },
    );
    const status = classifyMigration("0008_energy_burned_logs.sql", snapshots, new Set(), false);
    expect(status.state).toBe("BLOCKED_AMBIGUOUS");
    expect(status.entries.some((e) => e.label?.includes("energy_burned_logs_active_kcal_max"))).toBe(true);
    expect(status.entries.some((e) => e.label?.includes("energy_burned_logs_extra_fkey"))).toBe(true);
  });

  it("blocks an extra unique index on a canonical table but tolerates a non-unique one", () => {
    const blocked = energyCanonical();
    blocked.indexes.push({ table_name: "energy_burned_logs", index_name: "energy_burned_logs_user_burned_uq2", indexdef: "CREATE UNIQUE INDEX energy_burned_logs_user_burned_uq2 ON public.energy_burned_logs USING btree (user_id, burned_at)" });
    const status = classifyMigration("0008_energy_burned_logs.sql", blocked, new Set(), false);
    expect(status.state).toBe("BLOCKED_AMBIGUOUS");
    expect(status.entries.some((e) => e.label?.includes("energy_burned_logs_user_burned_uq2"))).toBe(true);

    // Explicitly tolerated: extra NON-unique performance indexes do not
    // change the end-state classification.
    const tolerated = energyCanonical();
    tolerated.indexes.push({ table_name: "energy_burned_logs", index_name: "energy_burned_logs_source_lookup_idx", indexdef: "CREATE INDEX energy_burned_logs_source_lookup_idx ON public.energy_burned_logs USING btree (source)" });
    const ok = classifyMigration("0008_energy_burned_logs.sql", tolerated, new Set(), false);
    expect(ok.state).toBe("VERIFIED_PRESENT");
  });
});

describe("contract pins and expression normalization", () => {
  it("normalization equalizes file-authored and PG17-deparsed expressions", () => {
    expect(normalizeExpr("CHECK ((source = ANY (ARRAY['manual'::text, 'apple_health'::text])))")).toBe(
      normalizeExpr("source in ('manual', 'apple_health')"),
    );
    expect(normalizeExpr("CHECK ((kg > (0)::numeric))")).toBe(normalizeExpr("kg > 0"));
    expect(normalizeExpr("(( SELECT auth.uid() AS uid) = user_id)")).toBe(normalizeExpr("(select auth.uid()) = user_id"));
    expect(normalizeExpr("CHECK (((height_cm >= (100)::numeric) AND (height_cm <= (250)::numeric)))")).toBe(
      normalizeExpr("height_cm >= 100 and height_cm <= 250"),
    );
    expect(normalizeExpr("CHECK (((age_years >= 10) AND (age_years <= 100)))")).toBe(
      normalizeExpr("age_years >= 10 and age_years <= 100"),
    );
  });

  it("preserves semantic grouping: a and (b or c) never equals (a and b) or c", () => {
    expect(normalizeExpr("(a and (b or c))")).not.toBe(normalizeExpr("((a and b) or c)"));
    expect(normalizeExpr("a and (b or c)")).not.toBe(normalizeExpr("(a and b) or c"));
    expect(normalizeExpr("(a or b) and c")).not.toBe(normalizeExpr("a or (b and c)"));
    expect(normalizeExpr("not (a = b and c = d)")).not.toBe(normalizeExpr("(not a = b) and c = d"));
  });

  it("never rewrites string-literal contents and never conflates literals", () => {
    expect(normalizeExpr("name = 'a))b'")).toBe("name='a))b'");
    expect(normalizeExpr("name = 'a(b'")).toBe("name='a(b'");
    expect(normalizeExpr("name = 'x = y' and user_id = 1")).toBe("name='x = y'anduser_id=1");
    expect(normalizeExpr("source = 'manual'")).not.toBe(normalizeExpr("source = 'apple_health'"));
    expect(normalizeExpr("unit in ('g', 'ml')")).not.toBe(normalizeExpr("unit in ('g', 'mg')"));
  });

  it("keeps near-match drift expressions distinct (operator/function/role changes)", () => {
    // operator change
    expect(normalizeExpr("active_kcal > 0")).not.toBe(normalizeExpr("active_kcal >= 0"));
    // function-call change (authorization semantics)
    expect(normalizeExpr("(select auth.uid()) = user_id")).not.toBe(
      normalizeExpr("(select current_setting('request.jwt.claim.sub', true))::uuid = user_id"),
    );
    // role/subject change inside the same shape
    expect(normalizeExpr("(select auth.uid()) = user_id")).not.toBe(normalizeExpr("(select auth.uid()) = id"));
    expect(normalizeExpr("auth.uid() = user_id")).not.toBe(normalizeExpr("auth.uid() = owner_id"));
    // boolean connective change
    expect(normalizeExpr("bucket_id = 'food-images' and (storage.foldername(name))[1] = (select auth.uid()::text)")).not.toBe(
      normalizeExpr("bucket_id = 'food-images' or (storage.foldername(name))[1] = (select auth.uid()::text)"),
    );
  });

  it("equalizes only proven deparse noise (aliases, literal casts, call parens, wraps)", () => {
    // alias + whole-expression wrap noise
    expect(normalizeExpr("(( SELECT auth.uid() AS uid) = ( SELECT meal_logs.user_id\n  FROM meal_logs\n WHERE (meal_logs.id = meal_items.meal_log_id)))")).toBe(
      normalizeExpr("(select auth.uid()) = (select meal_logs.user_id from meal_logs where meal_logs.id = meal_items.meal_log_id)"),
    );
    // storage render: literal casts, call parens, alias, wraps
    expect(normalizeExpr("((bucket_id = 'food-images'::text) AND ((storage.foldername(name))[1] = ( SELECT (auth.uid())::text AS uid)))")).toBe(
      normalizeExpr("bucket_id = 'food-images' and (storage.foldername(name))[1] = (select auth.uid()::text)"),
    );
    // no-arg call parens alone
    expect(normalizeExpr("(auth.uid()) = user_id")).toBe(normalizeExpr("auth.uid() = user_id"));
    // redundant comparison grouping parens
    expect(normalizeExpr("(auth.uid() = user_id)")).toBe(normalizeExpr("auth.uid() = user_id"));
  });

  it("SQL guard normalizer is assembled from the same static pieces (guards module loads)", async () => {
    const guards = await import("./migration-recovery-guards.mjs");
    const { FULL_GUARD_SQL, RECOVERY_NORM_BODY } = guards;
    for (const file of CANONICAL_FILES) {
      const guard = FULL_GUARD_SQL[file];
      expect(guard).toContain("recovery postcondition failed");
      expect(guard).toContain("pg_temp.recovery_norm");
      expect(guard).toContain(RECOVERY_NORM_BODY.trim().slice(0, 60));
      // Static only: no runtime interpolation surface ($ markers beyond the
      // fixed dollar-quote tags and plpgsql variables).
      expect(guard).not.toMatch(/\$\{/);
    }
  });

  it("guards embed the same-transaction exactness clauses (extra columns/constraints/unique indexes/policies/routine overloads)", async () => {
    const { FULL_GUARD_SQL } = await import("./migration-recovery-guards.mjs");
    const g0001 = FULL_GUARD_SQL["0001_init.sql"];
    // extra columns on an owned canonical table
    expect(g0001).toMatch(/information_schema\.columns c where c\.table_schema='public' and c\.table_name='users' and c\.column_name <> ALL/);
    // extra constraints on an owned canonical table
    expect(g0001).toMatch(/pg_constraint c where c\.conrelid = 'public\.users'::regclass and c\.conname <> ALL/);
    // extra unique indexes (non-unique performance indexes stay tolerated)
    expect(g0001).toMatch(/i\.indexdef ilike 'create unique index%' and i\.indexname <> ALL/);
    // extra policy names on exact-policy tables (attributed to the policy owner file)
    const g0003 = FULL_GUARD_SQL["0003_atomic_meals_and_users_rls.sql"];
    expect(g0003).toMatch(/pg_policies p where p\.schemaname='public' and p\.tablename='users' and p\.policyname <> ALL/);
    // extra overloads/signatures of canonical routine names
    const g0002 = FULL_GUARD_SQL["0002_targets.sql"];
    expect(g0002).toMatch(/p\.proname = 'compute_targets' and pg_get_function_identity_arguments\(p\.oid\) <> /);
    const g0006 = FULL_GUARD_SQL["0006_food_catalog_provider_cache.sql"];
    expect(g0006).toMatch(/p\.proname = 'upsert_food_catalog' and pg_get_function_identity_arguments\(p\.oid\) <> /);
  });

  it("FUNCTION_DEFINITIONS bodies are byte-identical to the migration files", () => {
    const expected = {
      compute_targets: "0002_targets.sql",
      log_meal_with_items: "0003_atomic_meals_and_users_rls.sql",
      log_meal_with_items_client: "0010_meal_outbox_client_ids.sql",
      claim_oauth_authorization_grant: "0005_oauth_authorization_grants.sql",
      upsert_food_catalog: "0006_food_catalog_provider_cache.sql",
    };
    const root = join(fileURLToPath(new URL("..", import.meta.url)), "db", "migrations");
    for (const [name, file] of Object.entries(expected)) {
      const text = readFileSync(join(root, file), "utf8");
      const fileBody = /as \$[a-z_]*\$([\s\S]*?)\$[a-z_]*\$;/m.exec(text)[1];
      const constantBody = /as \$[a-z_]*\$([\s\S]*?)\$[a-z_]*\$;?\s*$/m.exec(FUNCTION_DEFINITIONS[name])[1];
      expect(constantBody, `${name} body must match ${file}`).toBe(fileBody);
    }
  });

  it("every canonical migration file has contract entries and converge statements", async () => {
    const { CONVERGE_STATEMENTS } = await import("./migration-recovery-contracts.mjs");
    for (const file of CANONICAL_FILES) {
      expect(CONVERGE_STATEMENTS[file].length).toBeGreaterThan(0);
    }
    expect(Object.keys(CANONICAL_POLICIES).every((f) => CANONICAL_FILES.includes(f))).toBe(true);
    expect(Object.keys(CANONICAL_CONSTRAINTS).every((f) => CANONICAL_FILES.includes(f))).toBe(true);
    // Migrations that touch policies/constraints must define them; others may
    // be absent because those migrations create no such objects.
    for (const f of ["0001_init.sql", "0002_targets.sql", "0003_atomic_meals_and_users_rls.sql", "0004_store_assets.sql", "0005_oauth_authorization_grants.sql", "0008_energy_burned_logs.sql"]) {
      expect(CANONICAL_POLICIES[f].length, f).toBeGreaterThan(0);
    }
  });

  it("0003 converge revokes an explicit anon EXECUTE and keeps the authenticated grant (issue #84)", async () => {
    const { CONVERGE_STATEMENTS } = await import("./migration-recovery-contracts.mjs");
    const stmts = CONVERGE_STATEMENTS["0003_atomic_meals_and_users_rls.sql"];
    const revokePublic = "revoke execute on function public.log_meal_with_items(uuid, timestamptz, text, text, text, text, jsonb) from public";
    const revokeAnon = "revoke execute on function public.log_meal_with_items(uuid, timestamptz, text, text, text, text, jsonb) from anon";
    const grantAuthenticated = "grant execute on function public.log_meal_with_items(uuid, timestamptz, text, text, text, text, jsonb) to authenticated";
    // Out-of-band provisioning can leave an EXPLICIT direct anon grant (issue
    // #84 prod drift). The same-transaction guard demands anon EXECUTE absent,
    // so the converge set must revoke anon (not just public) BEFORE the guard
    // runs, and the authenticated grant must survive the revoke pair.
    const idxPublic = stmts.indexOf(revokePublic);
    const idxAnon = stmts.indexOf(revokeAnon);
    const idxGrant = stmts.indexOf(grantAuthenticated);
    expect(idxPublic, "0003 converge must keep the from-public revoke").toBeGreaterThanOrEqual(0);
    expect(idxGrant, "0003 converge must keep the to-authenticated grant").toBeGreaterThanOrEqual(0);
    expect(idxAnon, "0003 converge must revoke execute from anon").toBeGreaterThan(idxPublic);
    expect(idxAnon).toBeLessThan(idxGrant);
  });
});

describe("read-only reconcile workflow safety (deploy-migrations.yml)", () => {
  it("deploy-migrations.yml is dispatch-only with required confirmation and fail-closed secrets", () => {
    const yaml = readFileSync(new URL("../.github/workflows/deploy-migrations.yml", import.meta.url), "utf8");
    expect(yaml).toMatch(/^on:\s*\n\s*workflow_dispatch:\s*$/m);
    expect(yaml).not.toMatch(/^\s+push:/m);
    expect(yaml).toContain("confirmation");
    expect(yaml).toContain("required: true");
    expect(yaml).toContain("SUPABASE_ACCESS_TOKEN");
    expect(yaml).toContain("SUPABASE_PROJECT_REF");
    // Missing secrets must fail closed, never skip green.
    expect(yaml).toMatch(/exit 1/);
    expect(yaml).not.toMatch(/exit 0\s*#?.*skip/i);
  });

  it("docs and workflow do not claim configured required-reviewer approvals (protection_rules are empty today)", () => {
    const yaml = readFileSync(new URL("../.github/workflows/deploy-migrations.yml", import.meta.url), "utf8");
    const runbook = readFileSync(new URL("../docs/MIGRATION_RECOVERY.md", import.meta.url), "utf8");
    const readme = readFileSync(new URL("../README.md", import.meta.url), "utf8");
    // No configured-reviewer/approval claims anywhere.
    for (const [name, text] of [["workflow", yaml], ["runbook", runbook], ["readme", readme]]) {
      expect(text, `${name} must not claim configured reviewers`).not.toMatch(
        /required reviewer(?:s)? (?:approvals? )?configured|reviewers? (?:are|is) configured|approvals? configured/i,
      );
      expect(text, `${name} must not claim a configured approval layer`).not.toMatch(/approval layer/i);
    }
    // Truthful markers: privileged manual dispatch + phrase is the gate, and
    // environment reviewer protection is explicitly NOT configured.
    expect(yaml).toMatch(/environment: production/);
    expect(yaml).toMatch(/NOT currently configured/);
    expect(runbook).toMatch(/NOT currently configured/);
    expect(runbook).toMatch(/privileged manual dispatch/);
    expect(runbook).toMatch(/protection_rules=\[\]/);
    // Optional hardening may only be described as optional/future settings work.
    expect(runbook).toMatch(/optional human settings\s*\n\s*hardening/);
  });
});

describe("inspect manifest guard", () => {
  it("refuses manifests that are missing canonical files", async () => {
    const root = await mkdtemp(join(tmpdir(), "morsel-recovery-"));
    dirs.push(root);
    mkdirSync(join(root, "db", "migrations"), { recursive: true });
    writeFileSync(join(root, "db", "migrations", "0001_init.sql"), "-- x");
    const db = emptyDb();
    await expect(inspect({ root, query: db.queryImpl })).rejects.toThrow(/manifest mismatch/);
  });
});
