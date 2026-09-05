// Morsel issue #76 — local disposable PostgreSQL integration for the schema
// recovery runner and the atomic apply-migrations append path. Never touches a
// remote project: each scenario runs in its own scratch database on an
// ephemeral cluster.
import { spawnSync } from 'node:child_process'
import { accessSync, constants, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { run, CONFIRMATION_PHRASE } from '../scripts/migration-recovery.mjs'
import { run as applyMigrationsRun } from '../scripts/apply-migrations.mjs'
import { CANONICAL_CONSTRAINTS, CANONICAL_POLICIES, normalizeExpr } from '../scripts/migration-recovery-contracts.mjs'
import { RECOVERY_NORM_BODY } from '../scripts/migration-recovery-guards.mjs'

const ROOT = resolve(process.cwd())
const MIGRATIONS = join(ROOT, 'db', 'migrations')
const CANONICAL_FILES = [
  '0001_init.sql', '0002_targets.sql', '0003_atomic_meals_and_users_rls.sql',
  '0004_store_assets.sql', '0005_oauth_authorization_grants.sql',
  '0006_food_catalog_provider_cache.sql', '0007_weight_logs.sql',
  '0008_energy_burned_logs.sql', '0009_goals_fractional_calories.sql',
  '0010_meal_outbox_client_ids.sql', '0011_profiles_timezone.sql',
]

const BOOTSTRAP = `
create extension if not exists pgcrypto;
create schema auth;
create or replace function auth.uid()
returns uuid language sql stable
as $function$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid; $function$;
grant usage on schema auth to public;
grant execute on function auth.uid() to public;
create schema storage;
create table storage.buckets (
  id text primary key, name text not null unique,
  public boolean not null default false, file_size_limit bigint, allowed_mime_types text[]
);
create table storage.objects (
  id uuid primary key default gen_random_uuid(), bucket_id text not null, name text not null
);
alter table storage.objects enable row level security;
create function storage.foldername(object_name text) returns text[] language sql immutable as $function$
  select case
    when object_name is null or strpos(object_name, '/') = 0 then array[]::text[]
    else (string_to_array(object_name, '/'))[1:cardinality(string_to_array(object_name, '/')) - 1]
  end;
$function$;
grant usage on schema storage to authenticated;
grant execute on function storage.foldername(text) to authenticated;
`

let cluster = null

async function freePort() {
  return new Promise((resolvePort, reject) => {
    const server = createServer()
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      const address = server.address()
      if (address === null || typeof address === 'string') {
        server.close()
        reject(new Error('no free port'))
        return
      }
      server.close((error) => (error ? reject(error) : resolvePort(address.port)))
    })
  })
}

function runCommand(command, args, input) {
  const result = spawnSync(command, args, { encoding: 'utf8', input, stdio: ['pipe', 'pipe', 'pipe'] })
  return { status: result.status, stdout: result.stdout ?? '', stderr: result.stderr ?? '' }
}

function executableOnPath(name) {
  const result = runCommand('sh', ['-c', `command -v ${name}`])
  return result.status === 0 ? result.stdout.trim().split(/\r?\n/)[0] : undefined
}

function executableAt(path) {
  if (path === undefined || !existsSync(path)) return undefined
  try {
    accessSync(path, constants.X_OK)
    return path
  } catch {
    return undefined
  }
}

function findPostgresTools() {
  const pgConfig = executableOnPath('pg_config')
  const bindir = pgConfig === undefined ? undefined : runCommand(pgConfig, ['--bindir']).stdout.trim().split(/\r?\n/)[0]
  const binary = (name) => executableOnPath(name) ?? executableAt(bindir === undefined ? undefined : join(bindir, name))
  const initdb = binary('initdb')
  const pgCtl = binary('pg_ctl')
  const psql = binary('psql')
  return initdb === undefined || pgCtl === undefined || psql === undefined ? undefined : { initdb, pgCtl, psql }
}

function shellQuote(value) {
  return `'${value.replaceAll("'", "'\\''")}'`
}

async function startCluster(tools) {
  const root = mkdtempSync(join(tmpdir(), 'morsel-recovery-pg-'))
  const dataDirectory = join(root, 'data')
  const socketDirectory = join(root, 'socket')
  const logPath = join(root, 'postgres.log')
  mkdirSync(socketDirectory)
  const port = await freePort()
  const exec = (args, input) => {
    const result = spawnSync(tools.psql, args, { encoding: 'utf8', input, stdio: ['pipe', 'pipe', 'pipe'] })
    if (result.status !== 0) throw new Error(result.stderr)
    return result.stdout
  }
  const init = runCommand(tools.initdb, ['--no-locale', '--encoding=UTF8', '--username=postgres', '--auth=trust', dataDirectory])
  if (init.status !== 0) throw new Error(init.stderr)
  const start = runCommand(tools.pgCtl, ['-D', dataDirectory, '-o', `-p ${port} -h 127.0.0.1 -k ${shellQuote(socketDirectory)}`, '-l', logPath, '-w', 'start'])
  if (start.status !== 0) throw new Error(start.stderr)
  const baseArgs = ['-X', '-h', '127.0.0.1', '-p', String(port), '-U', 'postgres', '-d', 'postgres', '-A', '-t', '-v', 'ON_ERROR_STOP=1']
  // Roles are cluster-wide: create them once on the maintenance database.
  const roles = runCommand(tools.psql, baseArgs.concat('-f', '-'), 'create role anon nologin;\ncreate role authenticated nologin;\ncreate role service_role nologin;')
  if (roles.status !== 0) throw new Error(roles.stderr)
  const stop = () => {
    runCommand(tools.pgCtl, ['-D', dataDirectory, '-m', 'immediate', '-w', 'stop'])
    rmSync(root, { recursive: true, force: true })
  }
  const dbArgs = (name) => ['-X', '-h', '127.0.0.1', '-p', String(port), '-U', 'postgres', '-d', name, '-A', '-t', '-v', 'ON_ERROR_STOP=1']
  return {
    port,
    exec,
    stop,
    createDatabase: (name) => {
      exec(baseArgs, `drop database if exists ${name}; create database ${name};`)
      exec(dbArgs(name), BOOTSTRAP)
      return name
    },
    execIn: (name, sql) => exec(dbArgs(name), sql),
    queryImplFor: (name) => async (sql) => {
      const out = exec(dbArgs(name), sql).trim()
      if (out === '') return [{ result: [] }]
      try {
        return [{ result: JSON.parse(out) }]
      } catch {
        return [{ result: [] }] // write transactions emit command tags, not rows
      }
    },
  }
}

const quiet = { log: () => {} }
const ref = 'abcdefghijklmnopqrst'
const token = 'sbp_secretmanagementtoken012345'

function migrationSql(relativePath) {
  return readFileSync(resolve(ROOT, relativePath), 'utf8')
}

function applyFiles(db, files) {
  for (const file of files) db.execIn(db.name, migrationSql(`db/migrations/${file}`))
}

function seedRows(db) {
  db.execIn(db.name, `
    insert into public.users (id, email) values
      ('00000000-0000-4000-8000-000000000101', 'one@example.com'),
      ('00000000-0000-4000-8000-000000000102', 'two@example.com');
    insert into public.weight_logs (user_id, logged_at, kg) values
      ('00000000-0000-4000-8000-000000000101', '2026-09-01T08:00:00Z', 71.5),
      ('00000000-0000-4000-8000-000000000101', '2026-09-02T08:00:00Z', 71.2),
      ('00000000-0000-4000-8000-000000000102', '2026-09-01T08:00:00Z', 60.1);
  `)
}

const tools = findPostgresTools()
const postgresDescribe = tools === undefined ? describe.skip : describe

postgresDescribe('schema recovery runner against a disposable PostgreSQL', () => {
  beforeAll(async () => {
    if (tools !== undefined) cluster = await startCluster(tools)
  }, 30_000)

  afterAll(() => {
    if (cluster !== undefined) cluster.stop()
  }, 30_000)

  it('classifies the full canonical end state VERIFIED_PRESENT', async () => {
    const name = cluster.createDatabase('rec_canonical')
    const db = { name, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name) }
    applyFiles(db, CANONICAL_FILES)
    const outcome = await run({ ref, token, root: ROOT, apply: false, queryImpl: db.queryImpl, log: quiet })
    expect(outcome.mode).toBe('plan')
    expect(outcome.planBlocked).toBe(false)
    for (const file of CANONICAL_FILES) {
      expect(outcome.statuses[file].state, file).toBe('VERIFIED_PRESENT')
    }
  }, 60_000)

  it('prod-like partial schema: precise plan, apply to canonical end state with row-count preservation, idempotent second run', async () => {
    const name = cluster.createDatabase('rec_prodlike')
    const db = { name, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name) }
    // Issue #76 live evidence: 0001/0002/0003/0005 objects present out of
    // band; 0004 assets, 0006 cache routine, 0007 weight end state, 0008
    // energy table, 0009 fractional calories, and 0011 profile timezone
    // never applied; no ledger.
    applyFiles(db, ['0001_init.sql', '0002_targets.sql', '0003_atomic_meals_and_users_rls.sql', '0005_oauth_authorization_grants.sql', '0010_meal_outbox_client_ids.sql'])
    seedRows(db)
    db.execIn(name, `insert into public.goals (user_id, calorie_target_kcal, source) values ('00000000-0000-4000-8000-000000000101', 2200, 'computed');`)

    const before = await run({ ref, token, root: ROOT, apply: false, queryImpl: db.queryImpl, log: quiet })
    expect(before.planBlocked).toBe(false)
    const expected = {
      '0001_init.sql': 'VERIFIED_PRESENT',
      '0002_targets.sql': 'VERIFIED_PRESENT',
      '0003_atomic_meals_and_users_rls.sql': 'VERIFIED_PRESENT',
      '0004_store_assets.sql': 'REPAIR_REQUIRED',
      '0005_oauth_authorization_grants.sql': 'VERIFIED_PRESENT',
      '0006_food_catalog_provider_cache.sql': 'REPAIR_REQUIRED',
      '0007_weight_logs.sql': 'REPAIR_REQUIRED',
      '0008_energy_burned_logs.sql': 'REPAIR_REQUIRED',
      '0009_goals_fractional_calories.sql': 'REPAIR_REQUIRED',
      '0010_meal_outbox_client_ids.sql': 'VERIFIED_PRESENT',
      '0011_profiles_timezone.sql': 'REPAIR_REQUIRED',
    }
    for (const file of CANONICAL_FILES) {
      expect(before.statuses[file].state, file).toBe(expected[file])
    }
    // The 0005 objects must NEVER be replayed: plan only repairs 0004/0006/0007/0008/0009.
    const repairLabels = Object.values(before.statuses)
      .flatMap((s) => s.entries)
      .filter((e) => !e.ok)
      .map((e) => e.label)
    expect(repairLabels.some((label) => label.includes('oauth_authorization_grants'))).toBe(false)

    const executed = []
    const recording = async (sql) => {
      executed.push(String(sql))
      const impl = db.queryImpl
      return impl(sql)
    }
    const applied = await run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: recording, log: quiet })
    expect(applied.applied.length).toBe(6)
    // No 0005 replay: no converge transaction touching oauth_authorization_grants DDL.
    const writeTxs = executed.filter((sql) => /^begin;/.test(sql))
    expect(writeTxs.some((sql) => /create table if not exists public\.oauth_authorization_grants/.test(sql))).toBe(false)

    const weightShape = db.execIn(name, `select count(*) from information_schema.columns where table_schema='public' and table_name='weight_logs' and column_name in ('measured_at','source')`).trim()
    const weightConstraints = db.execIn(name, `select count(*) from pg_constraint where conrelid = 'public.weight_logs'::regclass and conname in ('weight_logs_source_check','weight_logs_kg_positive','weight_logs_user_measured_unique')`).trim()
    const oldIndex = db.execIn(name, `select count(*) from pg_indexes where schemaname='public' and tablename='weight_logs' and indexname='weight_logs_user_idx'`).trim()
    const weightCount = db.execIn(name, `select count(*) from public.weight_logs`).trim()
    const calorieType = db.execIn(name, `select data_type || ':' || numeric_scale from information_schema.columns where table_schema='public' and table_name='goals' and column_name='calorie_target_kcal'`).trim()
    expect({ weightShape, weightConstraints, oldIndex, weightCount, calorieType }).toEqual({
      weightShape: '2',
      weightConstraints: '3',
      oldIndex: '0',
      weightCount: '3',
      calorieType: 'numeric:1',
    })

    // Second run: everything verified and recorded -> zero write statements.
    const secondExecuted = []
    const secondRecording = async (sql) => {
      secondExecuted.push(String(sql))
      const impl = db.queryImpl
      return impl(sql)
    }
    const second = await run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: secondRecording, log: quiet })
    expect(second.applied).toEqual([])
    expect(secondExecuted.every((sql) => /^select /.test(sql.trim()))).toBe(true)
  }, 90_000)

  it('0003 converge revokes an explicit anon EXECUTE grant (issue #84 drift class) and records the ledger row', async () => {
    const name = cluster.createDatabase('rec_anonrevoke')
    const db = { name, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name) }
    // Issue #84 prod evidence: canonical 0001..0009 objects present, but
    // out-of-band provisioning left an EXPLICIT `grant execute ... to anon`
    // on log_meal_with_items. The #76 0003 converge set only revoked from
    // public, so the same-transaction guard aborted the converge (HTTP 400
    // class) with no ledger row. The converge must revoke the explicit anon
    // grant too and keep the authenticated grant.
    applyFiles(db, CANONICAL_FILES)
    db.execIn(name, `grant execute on function public.log_meal_with_items(uuid, timestamptz, text, text, text, text, jsonb) to anon;`)
    // Ledger prefix init/targets recorded (prod state before the 0003
    // re-dispatch): apply must converge EXACTLY 0003 next.
    const { LEDGER_DDL } = await import('../scripts/migration-recovery-contracts.mjs')
    db.execIn(name, LEDGER_DDL)
    db.execIn(name, `insert into public.migration_ledger (name) values ('init'), ('targets')`)

    const plan = await run({ ref, token, root: ROOT, apply: false, queryImpl: db.queryImpl, log: quiet })
    expect(plan.planBlocked).toBe(false)
    expect(plan.statuses['0003_atomic_meals_and_users_rls.sql'].state).toBe('REPAIR_REQUIRED')

    const executed = []
    const recording = async (sql) => {
      executed.push(String(sql))
      return db.queryImpl(sql)
    }
    const applied = await run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: recording, log: quiet })
    expect(applied.applied).toEqual(['0003_atomic_meals_and_users_rls.sql'])
    const anonExec = db.execIn(name, `select count(*) from information_schema.routine_privileges where routine_schema='public' and routine_name='log_meal_with_items' and grantee='anon' and privilege_type='EXECUTE'`).trim()
    const authExec = db.execIn(name, `select count(*) from information_schema.routine_privileges where routine_schema='public' and routine_name='log_meal_with_items' and grantee='authenticated' and privilege_type='EXECUTE'`).trim()
    const ledgerRow = db.execIn(name, `select count(*) from public.migration_ledger where name = 'atomic_meals_and_users_rls'`).trim()
    expect({ anonExec, authExec, ledgerRow }).toEqual({ anonExec: '0', authExec: '1', ledgerRow: '1' })
    // Canonical boundary restored: the post state must verify against every
    // contract (the runner's own post-apply re-verification also passed).
    const verify = await run({ ref, token, root: ROOT, apply: false, queryImpl: db.queryImpl, log: quiet })
    for (const file of CANONICAL_FILES) {
      expect(verify.statuses[file].state, file).toBe('VERIFIED_PRESENT')
    }
    // Second run is a no-op: the converge set is idempotent (revoking an
    // already-revoked grant is a no-op) and every migration is recorded.
    const secondExecuted = []
    const secondRecording = async (sql) => {
      secondExecuted.push(String(sql))
      return db.queryImpl(sql)
    }
    const second = await run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: secondRecording, log: quiet })
    expect(second.applied).toEqual([])
    expect(secondExecuted.every((sql) => /^select /.test(sql.trim()))).toBe(true)
  }, 90_000)

  it('converges an empty database to the full canonical end state', async () => {
    const name = cluster.createDatabase('rec_empty')
    const db = { name, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name) }
    const outcome = await run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: db.queryImpl, log: quiet })
    expect(outcome.applied.length).toBe(11)
    const tables = db.execIn(name, `select count(*) from information_schema.tables where table_schema = 'public'`).trim()
    const ledger = db.execIn(name, `select count(*) from public.migration_ledger`).trim()
    expect(tables).toBe('11') // 10 canonical tables + migration_ledger
    expect(ledger).toBe('11')
    const verify = await run({ ref, token, root: ROOT, apply: false, queryImpl: db.queryImpl, log: quiet })
    for (const file of CANONICAL_FILES) {
      expect(verify.statuses[file].state, file).toBe('VERIFIED_PRESENT')
    }
  }, 90_000)

  it('fails closed (zero writes) when both logged_at and measured_at exist', async () => {
    const name = cluster.createDatabase('rec_ambiguous')
    const db = { name, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name) }
    applyFiles(db, ['0001_init.sql'])
    // Old-only state plus a fully canonical measured_at: the ONLY blocker is
    // the both-columns ambiguity contract.
    db.execIn(name, `alter table public.weight_logs add column measured_at timestamptz not null default now();`)
    const executed = []
    const recording = async (sql) => {
      executed.push(String(sql))
      const impl = db.queryImpl
      return impl(sql)
    }
    await expect(run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: recording, log: quiet })).rejects.toThrow(/blocked/)
    expect(executed.filter((sql) => !/^select /.test(sql.trim()))).toHaveLength(0)
  }, 60_000)

  it('0009 lossy numeric conversion is a read-only data dependency: blocks BEFORE any write and resumes losslessly after a human fix', async () => {
    const name = cluster.createDatabase('rec_goaldep')
    const db = { name, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name) }
    // Full canonical end state except 0009: calorie_target_kcal is bigint
    // with a value beyond numeric(10,1) capacity -> overflow would abort the
    // alter, so the data dependency must block BEFORE any write.
    applyFiles(db, CANONICAL_FILES.filter((file) => file !== '0009_goals_fractional_calories.sql'))
    db.execIn(name, `
      alter table public.goals alter column calorie_target_kcal type bigint;
      insert into public.users (id, email) values ('00000000-0000-4000-8000-000000000101', 'one@example.com');
      insert into public.goals (user_id, calorie_target_kcal, source) values ('00000000-0000-4000-8000-000000000101', 100000000000000000, 'computed');
    `)
    const plan = await run({ ref, token, root: ROOT, apply: false, queryImpl: db.queryImpl, log: quiet })
    expect(plan.planBlocked).toBe(true)
    expect(plan.blockers.some((b) => b.label === 'goals data')).toBe(true)
    expect(plan.statuses['0009_goals_fractional_calories.sql'].state).toBe('BLOCKED_AMBIGUOUS')
    const executed = []
    const recording = async (sql) => {
      executed.push(String(sql))
      return db.queryImpl(sql)
    }
    await expect(run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: recording, log: quiet })).rejects.toThrow(/blocked/)
    expect(executed.filter((sql) => !/^select /.test(sql.trim()))).toHaveLength(0) // zero writes
    expect(db.execIn(name, `select count(*) from pg_class where relname = 'migration_ledger'`).trim()).toBe('0')
    const preserved = db.execIn(name, `select calorie_target_kcal::text from public.goals`).trim()
    expect(preserved).toBe('100000000000000000') // original value untouched

    // Lossless fix: delete the overflowing row; the conversion then succeeds
    // and every migration converges exactly once.
    db.execIn(name, `delete from public.goals; alter table public.goals alter column calorie_target_kcal type integer;`)
    db.execIn(name, `insert into public.goals (user_id, calorie_target_kcal, source) values ('00000000-0000-4000-8000-000000000101', 2200, 'computed');`)
    const retried = await run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: db.queryImpl, log: quiet })
    expect(retried.applied).toEqual(['0009_goals_fractional_calories.sql']) // only 0009 needed converge
    const finalLedger = db.execIn(name, `select count(*) from public.migration_ledger`).trim()
    expect(finalLedger).toBe('11')
    const finalValue = db.execIn(name, `select calorie_target_kcal::text from public.goals`).trim()
    expect(finalValue).toBe('2200.0') // integer -> numeric(10,1) is lossless (scale rendering only)
  }, 90_000)

  it('0009 higher-precision values (100.05) block with zero writes and are preserved; one-decimal values convert losslessly', async () => {
    const name = cluster.createDatabase('rec_goalprecision')
    const db = { name, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name) }
    applyFiles(db, CANONICAL_FILES.filter((file) => file !== '0009_goals_fractional_calories.sql'))
    db.execIn(name, `
      alter table public.goals alter column calorie_target_kcal type numeric(10,2);
      insert into public.users (id, email) values ('00000000-0000-4000-8000-000000000101', 'one@example.com');
      insert into public.goals (user_id, calorie_target_kcal, source) values ('00000000-0000-4000-8000-000000000101', 100.05, 'computed');
    `)
    const plan = await run({ ref, token, root: ROOT, apply: false, queryImpl: db.queryImpl, log: quiet })
    expect(plan.planBlocked).toBe(true)
    expect(plan.blockers.some((b) => b.label === 'goals data')).toBe(true)
    const executed = []
    const recording = async (sql) => {
      executed.push(String(sql))
      return db.queryImpl(sql)
    }
    await expect(run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: recording, log: quiet })).rejects.toThrow(/blocked/)
    expect(executed.filter((sql) => !/^select /.test(sql.trim()))).toHaveLength(0)
    expect(db.execIn(name, `select calorie_target_kcal::text from public.goals`).trim()).toBe('100.05') // never rounded

    // One-decimal value is lossless under numeric(10,1): apply proceeds.
    db.execIn(name, `update public.goals set calorie_target_kcal = 100.1;`)
    const ok = await run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: db.queryImpl, log: quiet })
    expect(ok.applied).toEqual(['0009_goals_fractional_calories.sql'])
    const value = db.execIn(name, `select calorie_target_kcal::text from public.goals`).trim()
    const scale = db.execIn(name, `select numeric_scale from information_schema.columns where table_schema='public' and table_name='goals' and column_name='calorie_target_kcal'`).trim()
    expect(value).toBe('100.1')
    expect(scale).toBe('1')
  }, 90_000)

  it('ledger-only race: an extra nullable column added between preflight and the owner record aborts with NO ledger row', async () => {
    const name = cluster.createDatabase('rec_raceextracol')
    const db = { name, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name) }
    applyFiles(db, CANONICAL_FILES)
    let drifted = false
    const racing = async (sql) => {
      const text = String(sql)
      if (!drifted && /^begin;/.test(text.trim()) && text.includes("migration_ledger (name) values ('init')")) {
        drifted = true
        db.execIn(name, 'alter table public.users add column race_extra boolean;')
      }
      return db.queryImpl(sql)
    }
    await expect(run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: racing, log: quiet })).rejects.toThrow()
    expect(drifted).toBe(true)
    expect(db.execIn(name, `select count(*) from public.migration_ledger`).trim()).toBe('0')
  }, 90_000)

  it('ledger-only race: an extra CHECK and an extra UNIQUE index added between preflight and the owner record abort with NO ledger row', async () => {
    const name = cluster.createDatabase('rec_raceextracon')
    const db = { name, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name) }
    applyFiles(db, CANONICAL_FILES)
    let drifted = false
    const racing = async (sql) => {
      const text = String(sql)
      if (!drifted && /^begin;/.test(text.trim()) && text.includes("migration_ledger (name) values ('init')")) {
        drifted = true
        db.execIn(name, `alter table public.users add constraint users_email_lower_check check (email = lower(email));`)
      }
      return db.queryImpl(sql)
    }
    await expect(run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: racing, log: quiet })).rejects.toThrow()
    expect(drifted).toBe(true)
    expect(db.execIn(name, `select count(*) from public.migration_ledger`).trim()).toBe('0')
    // Separate race on the unique-index clause.
    const name2 = cluster.createDatabase('rec_raceextraidx')
    const db2 = { name: name2, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name2) }
    applyFiles(db2, CANONICAL_FILES)
    let drifted2 = false
    const racing2 = async (sql) => {
      const text = String(sql)
      if (!drifted2 && /^begin;/.test(text.trim()) && text.includes("migration_ledger (name) values ('init')")) {
        drifted2 = true
        db2.execIn(name2, 'create unique index users_email_lower_uq on public.users (lower(email));')
      }
      return db2.queryImpl(sql)
    }
    await expect(run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: racing2, log: quiet })).rejects.toThrow()
    expect(drifted2).toBe(true)
    expect(db2.execIn(name2, `select count(*) from public.migration_ledger`).trim()).toBe('0')
  }, 90_000)

  it('ledger-only race: a permissive extra policy added between preflight and the owner record aborts with NO ledger row', async () => {
    const name = cluster.createDatabase('rec_raceextrapolicy')
    const db = { name, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name) }
    applyFiles(db, CANONICAL_FILES)
    const { LEDGER_DDL } = await import('../scripts/migration-recovery-contracts.mjs')
    db.execIn(name, LEDGER_DDL)
    db.execIn(name, `insert into public.migration_ledger (name) values ('init')`)
    db.execIn(name, `insert into public.migration_ledger (name) values ('targets')`)
    let drifted = false
    const racing = async (sql) => {
      const text = String(sql)
      if (!drifted && /^begin;/.test(text.trim()) && text.includes("values ('atomic_meals_and_users_rls')")) {
        drifted = true
        db.execIn(name, `create policy "users_select_any_public" on public.users for select using (true);`)
      }
      return db.queryImpl(sql)
    }
    await expect(run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: racing, log: quiet })).rejects.toThrow()
    expect(drifted).toBe(true)
    const ledger = db.execIn(name, `select count(*) from public.migration_ledger`).trim()
    const driftedRow = db.execIn(name, `select count(*) from public.migration_ledger where name = 'atomic_meals_and_users_rls'`).trim()
    expect(ledger).toBe('2')
    expect(driftedRow).toBe('0')
  }, 90_000)

  it('ledger-only race: an extra overload of a canonical routine added between preflight and the owner record aborts with NO ledger row', async () => {
    const name = cluster.createDatabase('rec_raceoverload')
    const db = { name, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name) }
    applyFiles(db, CANONICAL_FILES)
    const { LEDGER_DDL } = await import('../scripts/migration-recovery-contracts.mjs')
    db.execIn(name, LEDGER_DDL)
    const prefix = ['init', 'targets', 'atomic_meals_and_users_rls', 'store_assets', 'oauth_authorization_grants']
    for (const n of prefix) db.execIn(name, `insert into public.migration_ledger (name) values ('${n}')`)
    let drifted = false
    const racing = async (sql) => {
      const text = String(sql)
      if (!drifted && /^begin;/.test(text.trim()) && text.includes("values ('food_catalog_provider_cache')")) {
        drifted = true
        // Overload with its default PUBLIC execute revoked: only the extra
        // signature itself is drift (no other guard clause can see it).
        db.execIn(name, `create function public.upsert_food_catalog(p_name text) returns void language sql as $fn$ select 1 $fn$;
revoke execute on function public.upsert_food_catalog(text) from public;`)
      }
      return db.queryImpl(sql)
    }
    await expect(run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: racing, log: quiet })).rejects.toThrow()
    expect(drifted).toBe(true)
    const ledger = db.execIn(name, `select count(*) from public.migration_ledger`).trim()
    const driftedRow = db.execIn(name, `select count(*) from public.migration_ledger where name = 'food_catalog_provider_cache'`).trim()
    expect(ledger).toBe('5')
    expect(driftedRow).toBe('0')
  }, 90_000)

  it('blocks apply when weight rows would violate the canonical unique constraint (data dependency)', async () => {
    const name = cluster.createDatabase('rec_duprows')
    const db = { name, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name) }
    applyFiles(db, ['0001_init.sql'])
    db.execIn(name, `
      insert into public.users (id, email) values ('00000000-0000-4000-8000-000000000101', 'one@example.com');
      insert into public.weight_logs (user_id, logged_at, kg) values
        ('00000000-0000-4000-8000-000000000101', '2026-09-01T08:00:00Z', 71.5),
        ('00000000-0000-4000-8000-000000000101', '2026-09-01T08:00:00Z', 71.5);
    `)
    const plan = await run({ ref, token, root: ROOT, apply: false, queryImpl: db.queryImpl, log: quiet })
    expect(plan.planBlocked).toBe(true)
    expect(plan.blockers.some((b) => b.label === 'weight_logs data')).toBe(true)
    await expect(run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: db.queryImpl, log: quiet })).rejects.toThrow(/blocked/)
  }, 60_000)

  it('blocks when a recorded migration drifts from its contract', async () => {
    const name = cluster.createDatabase('rec_drift')
    const db = { name, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name) }
    applyFiles(db, CANONICAL_FILES)
    // Simulate a complete-schema-with-ledger database...
    const { LEDGER_DDL } = await import('../scripts/migration-recovery-contracts.mjs')
    db.execIn(name, LEDGER_DDL)
    for (const f of CANONICAL_FILES) {
      const fileBody = /^(\d{4})_([a-z0-9_]+)\.sql$/.exec(f)
      db.execIn(name, `insert into public.migration_ledger (name) values ('${fileBody[2]}')`)
    }
    // ...then drop a policy that 0003 owns: recorded-but-drifted must block.
    db.execIn(name, `drop policy "users_select_own" on public.users`)
    const plan = await run({ ref, token, root: ROOT, apply: false, queryImpl: db.queryImpl, log: quiet })
    expect(plan.planBlocked).toBe(true)
    expect(plan.statuses['0003_atomic_meals_and_users_rls.sql'].state).toBe('BLOCKED_AMBIGUOUS')
  }, 60_000)

  it('complete schema + ledger is a verified no-op for apply', async () => {
    const name = cluster.createDatabase('rec_complete')
    const db = { name, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name) }
    applyFiles(db, CANONICAL_FILES)
    const { LEDGER_DDL } = await import('../scripts/migration-recovery-contracts.mjs')
    db.execIn(name, LEDGER_DDL)
    for (const f of CANONICAL_FILES) {
      const fileBody = /^(\d{4})_([a-z0-9_]+)\.sql$/.exec(f)
      db.execIn(name, `insert into public.migration_ledger (name) values ('${fileBody[2]}')`)
    }
    const executed = []
    const recording = async (sql) => {
      executed.push(String(sql))
      const impl = db.queryImpl
      return impl(sql)
    }
    const outcome = await run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: recording, log: quiet })
    expect(outcome.applied).toEqual([])
    expect(executed.filter((sql) => !/^select /.test(sql.trim()))).toHaveLength(0)
  }, 60_000)

  it('apply-migrations appends atomically on real Postgres: single request, failure leaves no ledger row, retry succeeds', async () => {
    const name = cluster.createDatabase('rec_applyappend')
    const db = { name, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name) }
    // apply-migrations talks to the Management API's plain row objects: its
    // ledger probe/name queries are plain SELECTs (no JSON document wrapper).
    const applyImpl = async (sql) => {
      const text = cluster.execIn(name, sql).trim()
      const statement = String(sql).trim()
      if (statement.startsWith('select to_regclass')) {
        return text === '' ? [] : [{ name: text }]
      }
      if (statement.startsWith('select name from public.migration_ledger')) {
        return text === '' ? [] : text.split(/\r?\n/).map((line) => ({ name: line }))
      }
      return [] // atomic BEGIN..COMMIT writes return command tags only
    }
    // Temp checkout-shaped root with a tiny append-only migration set.
    const tempRoot = await mkdtemp(join(tmpdir(), 'morsel-apply-append-'))
    try {
      await mkdir(join(tempRoot, 'db', 'migrations'), { recursive: true })
      await writeFile(join(tempRoot, 'db', 'migrations', '0001_first.sql'), 'create table if not exists public.t_first (id int);')
      // Seed the ledger out of band: ledger exists with only 'first' recorded,
      // mirroring a healthy post-recovery database awaiting future migrations.
      db.execIn(name, `
        create table if not exists public.migration_ledger (name text primary key, applied_at timestamptz not null default now());
        insert into public.migration_ledger (name) values ('first');
      `)
      db.execIn(name, 'create table if not exists public.t_first (id int);')

      // (1) success: 0002_second appends in ONE request carrying SQL + insert.
      await writeFile(join(tempRoot, 'db', 'migrations', '0002_second.sql'), 'create table if not exists public.t_second (id int);')
      const executed = []
      const recording = async (sql) => {
        executed.push(String(sql))
        return applyImpl(sql)
      }
      const applied = await applyMigrationsRun({ ref, token, root: tempRoot, queryImpl: recording, log: quiet })
      expect(applied.applied).toEqual(['0002_second.sql'])
      const writes = executed.filter((sql) => !/^select /.test(sql.trim()))
      expect(writes).toHaveLength(1)
      expect(writes[0]).toMatch(/^begin;\n/)
      expect(writes[0]).toContain('create table if not exists public.t_second (id int);')
      expect(writes[0]).toMatch(/insert into public\.migration_ledger \(name\) values \('second'\);\ncommit;$/)
      expect(db.execIn(name, `select count(*) from pg_class where relname = 't_second'`).trim()).toBe('1')
      expect(db.execIn(name, `select count(*) from public.migration_ledger where name = 'second'`).trim()).toBe('1')

      // (2) failure: 0003_bad fails inside its transaction -> NO ledger row.
      await writeFile(join(tempRoot, 'db', 'migrations', '0003_bad.sql'), 'create table if not exists public.t_bad (id int);\ninsert into public.no_such_relation values (1);\n')
      await expect(applyMigrationsRun({ ref, token, root: tempRoot, queryImpl: applyImpl, log: quiet })).rejects.toThrow()
      expect(db.execIn(name, `select count(*) from public.migration_ledger where name = 'bad'`).trim()).toBe('0')
      expect(db.execIn(name, `select count(*) from pg_class where relname = 't_bad'`).trim()).toBe('0')

      // (3) retry after the fix: same runner instance, file repaired -> row lands.
      await writeFile(join(tempRoot, 'db', 'migrations', '0003_bad.sql'), 'create table if not exists public.t_bad (id int);')
      const retried = await applyMigrationsRun({ ref, token, root: tempRoot, queryImpl: applyImpl, log: quiet })
      expect(retried.applied).toEqual(['0003_bad.sql'])
      expect(db.execIn(name, `select count(*) from public.migration_ledger where name = 'bad'`).trim()).toBe('1')

      // (4) missing ledger -> zero writes on real Postgres.
      const emptyName = cluster.createDatabase('rec_applymissing')
      const emptyDb = { name: emptyName, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(emptyName) }
      const emptyApplyImpl = async (sql) => {
        const text = cluster.execIn(emptyName, sql).trim()
        const statement = String(sql).trim()
        if (statement.startsWith('select to_regclass')) return text === '' ? [] : [{ name: text }]
        if (statement.startsWith('select name from public.migration_ledger')) {
          return text === '' ? [] : text.split(/\r?\n/).map((line) => ({ name: line }))
        }
        return []
      }
      const executedEmpty = []
      const recordingEmpty = async (sql) => {
        executedEmpty.push(String(sql))
        return emptyApplyImpl(sql)
      }
      await expect(applyMigrationsRun({ ref, token, root: tempRoot, queryImpl: recordingEmpty, log: quiet })).rejects.toThrow(/ledger public\.migration_ledger does not exist/)
      expect(executedEmpty.filter((sql) => !/^select /.test(sql.trim()))).toHaveLength(0)
    } finally {
      await rm(tempRoot, { recursive: true, force: true })
    }
  }, 60_000)

  it('ledger-only race: schema drift between preflight and the record transaction aborts with NO ledger row', async () => {
    const name = cluster.createDatabase('rec_raceschema')
    const db = { name, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name) }
    applyFiles(db, CANONICAL_FILES)
    let drifted = false
    const racing = async (sql) => {
      const text = String(sql)
      // Interfere only between preflight and the FIRST record transaction
      // (0001 init): drop a load-bearing nullable column mid-flight.
      if (!drifted && /^begin;/.test(text.trim()) && text.includes("migration_ledger (name) values ('init')")) {
        drifted = true
        db.execIn(name, 'alter table public.users drop column display_name;')
      }
      return db.queryImpl(sql)
    }
    await expect(run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: racing, log: quiet })).rejects.toThrow()
    expect(drifted).toBe(true)
    // The in-transaction guard fired: NO ledger row was recorded and the
    // failed transaction rolled back completely.
    const ledger = db.execIn(name, `select count(*) from public.migration_ledger`).trim()
    const ledgerTableStillThere = db.execIn(name, `select count(*) from pg_class where relname = 'migration_ledger'`).trim()
    expect(ledger).toBe('0')
    expect(ledgerTableStillThere).toBe('1')
  }, 90_000)

  it('ledger-only race: security/function drift between preflight and the record transaction aborts with NO ledger row', async () => {
    const name = cluster.createDatabase('rec_racefunc')
    const db = { name, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name) }
    applyFiles(db, CANONICAL_FILES)
    const { LEDGER_DDL } = await import('../scripts/migration-recovery-contracts.mjs')
    db.execIn(name, LEDGER_DDL)
    const prefix = ['init', 'targets', 'atomic_meals_and_users_rls', 'store_assets', 'oauth_authorization_grants']
    for (const n of prefix) db.execIn(name, `insert into public.migration_ledger (name) values ('${n}')`)
    let drifted = false
    const racing = async (sql) => {
      const text = String(sql)
      // The next record is 0006 (food_catalog_provider_cache): replace the
      // canonical SECURITY DEFINER body right before its ledger transaction.
      if (!drifted && /^begin;/.test(text.trim()) && text.includes("values ('food_catalog_provider_cache')")) {
        drifted = true
        db.execIn(name, `create or replace function public.upsert_food_catalog(p_rows jsonb)
returns void language sql security definer as $fn$ select 1 $fn$;`)
      }
      return db.queryImpl(sql)
    }
    await expect(run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: racing, log: quiet })).rejects.toThrow()
    expect(drifted).toBe(true)
    const ledger = db.execIn(name, `select count(*) from public.migration_ledger`).trim()
    const driftedRow = db.execIn(name, `select count(*) from public.migration_ledger where name = 'food_catalog_provider_cache'`).trim()
    expect(ledger).toBe('5') // prefix rows only; the raced record never landed
    expect(driftedRow).toBe('0')
  }, 90_000)

  it('ledger-only race: policy qual drift between preflight and the record transaction aborts with NO ledger row', async () => {
    const name = cluster.createDatabase('rec_racepolicy')
    const db = { name, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name) }
    applyFiles(db, CANONICAL_FILES)
    const { LEDGER_DDL } = await import('../scripts/migration-recovery-contracts.mjs')
    db.execIn(name, LEDGER_DDL)
    db.execIn(name, `insert into public.migration_ledger (name) values ('init')`)
    db.execIn(name, `insert into public.migration_ledger (name) values ('targets')`)
    let drifted = false
    const racing = async (sql) => {
      const text = String(sql)
      // Right before the 0003 record transaction, replace the canonical
      // SELECT policy with a permissive one of the same name/cmd/roles.
      if (!drifted && /^begin;/.test(text.trim()) && text.includes("values ('atomic_meals_and_users_rls')")) {
        drifted = true
        db.execIn(name, `drop policy "users_select_own" on public.users; create policy "users_select_own" on public.users for select using (true);`)
      }
      return db.queryImpl(sql)
    }
    await expect(run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: racing, log: quiet })).rejects.toThrow()
    expect(drifted).toBe(true)
    const driftedRow = db.execIn(name, `select count(*) from public.migration_ledger where name = 'atomic_meals_and_users_rls'`).trim()
    expect(driftedRow).toBe('0')
  }, 90_000)

  it('converge-path race: mid-flight drift makes the guard abort the whole converge transaction (no ledger row)', async () => {
    const name = cluster.createDatabase('rec_raceconverge')
    const db = { name, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name) }
    applyFiles(db, ['0001_init.sql', '0002_targets.sql', '0003_atomic_meals_and_users_rls.sql', '0004_store_assets.sql', '0005_oauth_authorization_grants.sql', '0006_food_catalog_provider_cache.sql'])
    // Old-only weight_logs (0001 shape, 0007 not applied) = modeled 0007 repair.
    let drifted = false
    const racing = async (sql) => {
      const text = String(sql)
      // Between preflight (old-only REPAIR) and the 0007 converge transaction,
      // a concurrent actor creates measured_at: the converge rename becomes a
      // no-op and the end state would keep logged_at -> the guard must abort.
      if (!drifted && /^begin;/.test(text.trim()) && text.includes("values ('weight_logs')")) {
        drifted = true
        db.execIn(name, 'alter table public.weight_logs add column measured_at timestamptz not null default now();')
      }
      return db.queryImpl(sql)
    }
    await expect(run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: racing, log: quiet })).rejects.toThrow()
    expect(drifted).toBe(true)
    const ledger = db.execIn(name, `select count(*) from public.migration_ledger where name = 'weight_logs'`).trim()
    expect(ledger).toBe('0')
    const sourceCol = db.execIn(name, `select count(*) from information_schema.columns where table_schema='public' and table_name='weight_logs' and column_name='source'`).trim()
    expect(sourceCol).toBe('0') // the aborted converge rolled back its own statements
  }, 90_000)

  it('plan blocks an extra nullable column / extra CHECK / extra FK on a canonical table (never ledger-recorded)', async () => {
    const name = cluster.createDatabase('rec_extras')
    const db = { name, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name) }
    applyFiles(db, ['0001_init.sql'])
    db.execIn(name, `
      alter table public.users add column notify_prefs jsonb;
      alter table public.goals add constraint goals_calorie_max_check check (calorie_target_kcal <= 10000);
      alter table public.meal_logs add constraint meal_logs_extra_fkey foreign key (user_id) references public.users(id);
    `)
    const plan = await run({ ref, token, root: ROOT, apply: false, queryImpl: db.queryImpl, log: quiet })
    expect(plan.planBlocked).toBe(true)
    expect(plan.statuses['0001_init.sql'].state).toBe('BLOCKED_AMBIGUOUS')
    const labels = plan.statuses['0001_init.sql'].entries.filter((e) => !e.ok).map((e) => e.label)
    expect(labels.some((l) => l.includes('users.notify_prefs'))).toBe(true)
    expect(labels.some((l) => l.includes('goals_calorie_max_check'))).toBe(true)
    expect(labels.some((l) => l.includes('meal_logs_extra_fkey'))).toBe(true)
    const executed = []
    const recording = async (sql) => {
      executed.push(String(sql))
      return db.queryImpl(sql)
    }
    await expect(run({ ref, token, root: ROOT, apply: true, confirm: CONFIRMATION_PHRASE, queryImpl: recording, log: quiet })).rejects.toThrow(/blocked/)
    expect(executed.filter((sql) => !/^select /.test(sql.trim()))).toHaveLength(0)
    expect(db.execIn(name, `select count(*) from pg_class where relname = 'migration_ledger'`).trim()).toBe('0')
  }, 60_000)

  it('JS normalizeExpr and the SQL recovery_norm guard normalizer agree on the canonical corpus and live renderings', async () => {
    const name = cluster.createDatabase('rec_normpin')
    const db = { name, execIn: cluster.execIn, queryImpl: cluster.queryImplFor(name) }
    applyFiles(db, CANONICAL_FILES)
    // Public copy in the disposable scratch DB so each psql session can use
    // it (pg_temp is per-session; the guard creates its own inside the tx).
    db.execIn(name, `create or replace function public.recovery_norm_sql(p text) returns text
language plpgsql immutable as $norm$
${RECOVERY_NORM_BODY}
$norm$;`)
    const sqlNorm = (text) => db.execIn(name, `select public.recovery_norm_sql($qt$${text}$qt$)`).trim()
    const corpus = []
    for (const policies of Object.values(CANONICAL_POLICIES)) {
      for (const policy of policies) {
        if (policy.qual !== undefined) corpus.push(policy.qual)
        if (policy.withCheck !== undefined) corpus.push(policy.withCheck)
      }
    }
    for (const tables of Object.values(CANONICAL_CONSTRAINTS)) {
      for (const constraints of Object.values(tables)) {
        for (const constraint of constraints) {
          if (constraint.kind === 'c') corpus.push(constraint.def)
        }
      }
    }
    expect(corpus.length).toBeGreaterThan(30)
    for (const text of corpus) {
      expect(sqlNorm(text), `SQL norm diverges for [${text}]`).toBe(normalizeExpr(text))
    }
    // Live deparse renderings must normalize identically in SQL and JS and to
    // the canonical authored forms.
    const renderings = [
      '(( SELECT auth.uid() AS uid) = user_id)',
      '(( SELECT auth.uid() AS uid) = ( SELECT meal_logs.user_id\n  FROM meal_logs\n WHERE (meal_logs.id = meal_items.meal_log_id)))',
      "((bucket_id = 'food-images'::text) AND ((storage.foldername(name))[1] = ( SELECT (auth.uid())::text AS uid)))",
      "CHECK ((source = ANY (ARRAY['manual'::text, 'apple_health'::text])))",
      'CHECK (((height_cm >= (100)::numeric) AND (height_cm <= (250)::numeric)))',
    ]
    for (const rendering of renderings) {
      expect(sqlNorm(rendering)).toBe(normalizeExpr(rendering))
    }
    // And a discriminating pair that must NEVER collapse in SQL either.
    const sqlDistinct = sqlNorm('a = 1 and (b = 2 or c = 3)')
    expect(sqlDistinct).not.toBe(sqlNorm('(a = 1 and b = 2) or c = 3'))
    expect(sqlDistinct).not.toBe(normalizeExpr('(a = 1 and b = 2) or c = 3'))
  }, 90_000)
})
