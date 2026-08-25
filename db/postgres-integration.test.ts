import { spawnSync } from 'node:child_process'
import { accessSync, constants, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

interface CommandResult {
  status: number | null
  stdout: string
  stderr: string
  error: Error | undefined
}

interface PostgresTools {
  initdb: string
  pgCtl: string
  psql: string
}

interface LocalPostgres {
  execute(sql: string, stopOnError?: boolean): CommandResult
  stop(): void
}

const migrationFiles = [
  'db/migrations/0001_init.sql',
  'db/migrations/0002_targets.sql',
  'db/migrations/0003_atomic_meals_and_users_rls.sql',
  'db/migrations/0004_store_assets.sql',
]

function runCommand(command: string, args: string[], input?: string): CommandResult {
  const result = spawnSync(command, args, {
    encoding: 'utf8',
    input,
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  return {
    status: result.status,
    stdout: result.stdout?.toString() ?? '',
    stderr: result.stderr?.toString() ?? '',
    error: result.error,
  }
}

function firstLine(value: string): string | undefined {
  const line = value.trim().split(/\r?\n/)[0]
  return line === undefined || line === '' ? undefined : line
}

function executableOnPath(name: string): string | undefined {
  const result = runCommand('sh', ['-c', `command -v ${name}`])
  return result.status === 0 ? firstLine(result.stdout) : undefined
}

function executableAt(path: string | undefined): string | undefined {
  if (path === undefined || !existsSync(path)) {
    return undefined
  }
  try {
    accessSync(path, constants.X_OK)
    return path
  } catch {
    return undefined
  }
}

function findPostgresTools(): PostgresTools | undefined {
  const pgConfig = executableOnPath('pg_config')
  const bindir = pgConfig === undefined ? undefined : firstLine(runCommand(pgConfig, ['--bindir']).stdout)
  const binary = (name: string): string | undefined => executableOnPath(name) ?? executableAt(bindir === undefined ? undefined : join(bindir, name))
  const initdb = binary('initdb')
  const pgCtl = binary('pg_ctl')
  const psql = binary('psql')
  return initdb === undefined || pgCtl === undefined || psql === undefined
    ? undefined
    : { initdb, pgCtl, psql }
}

async function freePort(): Promise<number> {
  return new Promise((resolvePort, reject) => {
    const server = createServer()
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      const address = server.address()
      if (address === null || typeof address === 'string') {
        server.close()
        reject(new Error('could not determine a free PostgreSQL port'))
        return
      }
      server.close((error) => {
        if (error !== undefined) {
          reject(error)
          return
        }
        resolvePort(address.port)
      })
    })
  })
}

function readDiagnosticLog(path: string): string {
  try {
    return readFileSync(path, 'utf8')
  } catch (error) {
    return `could not read postgres.log: ${error instanceof Error ? error.message : String(error)}`
  }
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`
}

function requireSuccess(result: CommandResult, description: string, diagnosticLogPath?: string): string {
  if (result.error !== undefined || result.status !== 0) {
    const diagnosticLog = diagnosticLogPath === undefined
      ? ''
      : `\npostgres.log:\n${readDiagnosticLog(diagnosticLogPath)}`
    throw new Error(`${description} failed\n${result.stderr}\n${result.error?.message ?? ''}${diagnosticLog}`)
  }
  return result.stdout
}

async function startLocalPostgres(tools: PostgresTools): Promise<LocalPostgres> {
  const root = mkdtempSync(join(tmpdir(), 'morsel-pg-'))
  const dataDirectory = join(root, 'data')
  const socketDirectory = join(root, 'socket')
  const logPath = join(root, 'postgres.log')
  let started = false

  try {
    mkdirSync(socketDirectory)
    const port = await freePort()
    requireSuccess(runCommand(tools.initdb, [
      '--no-locale',
      '--encoding=UTF8',
      '--username=postgres',
      '--auth=trust',
      dataDirectory,
    ]), 'initdb')
    requireSuccess(runCommand(tools.pgCtl, [
      '-D', dataDirectory,
      '-o', `-p ${port} -h 127.0.0.1 -k ${shellQuote(socketDirectory)}`,
      '-l', logPath,
      '-w',
      'start',
    ]), 'pg_ctl start', logPath)
    started = true

    const execute = (sql: string, stopOnError = true): CommandResult => {
      const args = [
        '-X',
        '-h', '127.0.0.1',
        '-p', String(port),
        '-U', 'postgres',
        '-d', 'postgres',
        '-A',
        '-t',
        '-F', '|',
      ]
      if (stopOnError) {
        args.push('-v', 'ON_ERROR_STOP=1')
      }
      args.push('-f', '-')
      return runCommand(tools.psql, args, sql)
    }
    const stop = (): void => {
      if (started) {
        runCommand(tools.pgCtl, ['-D', dataDirectory, '-m', 'immediate', '-w', 'stop'])
        started = false
      }
      rmSync(root, { recursive: true, force: true })
    }
    return { execute, stop }
  } catch (error) {
    if (started) {
      runCommand(tools.pgCtl, ['-D', dataDirectory, '-m', 'immediate', '-w', 'stop'])
    }
    rmSync(root, { recursive: true, force: true })
    throw error
  }
}

function outputLines(value: string): string[] {
  return value.split(/\r?\n/).map((line) => line.trim()).filter((line) => line !== '')
}

function queryValues(value: string): string[] {
  return outputLines(value).filter((line) => !/^(BEGIN|COMMIT|DO|ROLLBACK|SAVEPOINT|SET|(?:INSERT|UPDATE|DELETE) \d+)$/.test(line))
}

function migrationSql(relativePath: string): string {
  return readFileSync(resolve(process.cwd(), relativePath), 'utf8')
}

const postgresTools = findPostgresTools()
const postgresDescribe = postgresTools === undefined ? describe.skip : describe

postgresDescribe('local PostgreSQL migrations and RLS', () => {
  it('applies migrations and enforces Supabase-like auth, RPC, and rollback behavior', async () => {
    if (postgresTools === undefined) {
      return
    }
    const postgres = await startLocalPostgres(postgresTools)
    const userOne = '00000000-0000-4000-8000-000000000101'
    const userTwo = '00000000-0000-4000-8000-000000000102'
    const userThree = '00000000-0000-4000-8000-000000000103'

    try {
      requireSuccess(postgres.execute(`
        create extension if not exists pgcrypto;
        create schema auth;
        create role anon nologin;
        create role authenticated nologin;
        create or replace function auth.uid()
        returns uuid
        language sql
        stable
        as $function$
          select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
        $function$;
        grant usage on schema auth to public;
        grant execute on function auth.uid() to public;
        create schema storage;
        create table storage.buckets (
          id text primary key,
          name text not null unique,
          public boolean not null default false,
          file_size_limit bigint,
          allowed_mime_types text[]
        );
        create table storage.objects (
          id uuid primary key default gen_random_uuid(),
          bucket_id text not null,
          name text not null
        );
        alter table storage.objects enable row level security;
        create function storage.foldername(object_name text)
        returns text[]
        language sql
        immutable
        as $function$
          select case
            when object_name is null or strpos(object_name, '/') = 0 then array[]::text[]
            else (string_to_array(object_name, '/'))[1:cardinality(string_to_array(object_name, '/')) - 1]
          end;
        $function$;
        grant usage on schema storage to authenticated;
        grant execute on function storage.foldername(text) to authenticated;
      `), 'Supabase-like bootstrap')

      for (const migration of migrationFiles) {
        requireSuccess(postgres.execute(migrationSql(migration)), migration)
      }
      requireSuccess(postgres.execute(migrationSql('db/seed.sql')), 'food catalog seed')
      requireSuccess(postgres.execute(migrationSql('db/migrations/0004_store_assets.sql')), 'rerunnable store assets migration')
      requireSuccess(postgres.execute(migrationSql('db/seed.sql')), 'rerunnable food catalog seed')

      requireSuccess(postgres.execute(`
        grant usage on schema public to anon, authenticated;
        grant select, insert, update on public.users to authenticated;
        grant select, insert on public.meal_logs, public.meal_items to authenticated;
        grant select, insert, update, delete on public.food_catalog to authenticated;
        grant select on storage.buckets to authenticated;
        grant select, insert, update, delete on storage.objects to authenticated;
      `), 'API role grants')

      requireSuccess(postgres.execute(`
        insert into storage.objects (bucket_id, name) values
          ('food-images', '${userOne}/meal.jpg'),
          ('food-images', '${userTwo}/meal.jpg'),
          ('other-bucket', '${userOne}/other.jpg');
      `), 'storage fixture')

      const assetRead = requireSuccess(postgres.execute(`
        begin;
        set role authenticated;
        set local "request.jwt.claim.sub" = '${userOne}';
        select count(*) from public.food_catalog;
        select count(*) from storage.buckets
          where id = 'food-images' and public = false
            and file_size_limit = 10485760
            and allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']::text[];
        select count(*) from storage.objects;
        commit;
      `), 'catalog and storage reads')
      expect(queryValues(assetRead)).toEqual(['8', '1', '1'])

      const catalogWrite = requireSuccess(postgres.execute(`
        begin;
        set role authenticated;
        set local "request.jwt.claim.sub" = '${userOne}';
        savepoint before_catalog_write;
        update public.food_catalog set name = 'cross-user-write'
          where id = 'f0000000-0000-4000-8000-000000000001';
        rollback to savepoint before_catalog_write;
        select count(*) from public.food_catalog where name = 'cross-user-write';
        commit;
      `), 'catalog write isolation')
      expect(queryValues(catalogWrite)).toEqual(['0'])

      requireSuccess(postgres.execute(`
        begin;
        set role authenticated;
        set local "request.jwt.claim.sub" = '${userOne}';
        insert into storage.objects (bucket_id, name)
          values ('food-images', '${userOne}/new.jpg');
        commit;
      `), 'owner storage insert')

      const crossStorageInsert = postgres.execute(`
        begin;
        set role authenticated;
        set local "request.jwt.claim.sub" = '${userOne}';
        savepoint before_cross_storage_insert;
        insert into storage.objects (bucket_id, name)
          values ('food-images', '${userTwo}/forbidden.jpg');
        rollback to savepoint before_cross_storage_insert;
        commit;
      `, false)
      expect(crossStorageInsert.stderr).toMatch(/row-level security policy/i)

      const crossStorageRename = postgres.execute(`
        begin;
        set role authenticated;
        set local "request.jwt.claim.sub" = '${userOne}';
        savepoint before_cross_storage_rename;
        update storage.objects set name = '${userTwo}/moved.jpg'
          where bucket_id = 'food-images' and name = '${userOne}/meal.jpg';
        rollback to savepoint before_cross_storage_rename;
        commit;
      `, false)
      expect(crossStorageRename.stderr).toMatch(/row-level security policy/i)

      requireSuccess(postgres.execute(`
        begin;
        set role authenticated;
        set local "request.jwt.claim.sub" = '${userOne}';
        insert into public.users (id, email) values ('${userOne}', 'one@example.com');
        commit;
        begin;
        set role authenticated;
        set local "request.jwt.claim.sub" = '${userTwo}';
        insert into public.users (id, email) values ('${userTwo}', 'two@example.com');
        commit;
      `), 'owner user inserts')

      const ownerRead = requireSuccess(postgres.execute(`
        begin;
        set role authenticated;
        set local "request.jwt.claim.sub" = '${userOne}';
        select count(*) from public.users;
        select email from public.users where id = '${userOne}';
        update public.users set display_name = 'owner-one' where id = '${userOne}';
        select display_name from public.users where id = '${userOne}';
        commit;
      `), 'owner user select/update')
      expect(queryValues(ownerRead)).toEqual(['1', 'one@example.com', 'owner-one'])

      const crossUserInsert = postgres.execute(`
        begin;
        set role authenticated;
        set local "request.jwt.claim.sub" = '${userTwo}';
        savepoint before_cross_user_insert;
        insert into public.users (id, email) values ('${userThree}', 'three@example.com');
        rollback to savepoint before_cross_user_insert;
        select count(*) from public.users where id = '${userThree}';
        commit;
      `, false)
      expect(crossUserInsert.stderr).toMatch(/row-level security policy/i)
      expect(queryValues(crossUserInsert.stdout)).toEqual(['0'])

      const crossUserRead = requireSuccess(postgres.execute(`
        begin;
        set role authenticated;
        set local "request.jwt.claim.sub" = '${userTwo}';
        select count(*) from public.users;
        select count(*) from public.users where id = '${userOne}';
        update public.users set display_name = 'cross-user-write' where id = '${userOne}';
        select count(*) from public.users where id = '${userOne}' and display_name = 'cross-user-write';
        commit;
      `), 'cross-user users policy')
      expect(queryValues(crossUserRead)).toEqual(['1', '0', '0'])

      const validRpc = requireSuccess(postgres.execute(`
        begin;
        set role authenticated;
        set local "request.jwt.claim.sub" = '${userOne}';
        do $block$
        begin
          perform public.log_meal_with_items(
            '${userOne}'::uuid,
            '2026-08-25T12:30:00Z'::timestamptz,
            'lunch',
            'manual',
            null,
            null,
            '[{"name":"rice","quantity":1,"unit":"serving","calories_kcal":220}]'::jsonb
          );
        end
        $block$;
        select count(*) from public.meal_logs where user_id = '${userOne}';
        select count(*) from public.meal_items
          where meal_log_id in (select id from public.meal_logs where user_id = '${userOne}');
        commit;
      `), 'authenticated meal RPC')
      expect(queryValues(validRpc)).toEqual(['1', '1'])

      const anonymousRpc = postgres.execute(`
        set role anon;
        select * from public.log_meal_with_items(
          '${userOne}'::uuid,
          '2026-08-25T12:31:00Z'::timestamptz,
          'lunch',
          'manual',
          null,
          null,
          '[{"name":"anonymous","quantity":1,"unit":"serving"}]'::jsonb
        );
      `)
      expect(anonymousRpc.status).not.toBe(0)
      expect(anonymousRpc.stderr).toMatch(/permission denied for function log_meal_with_items/i)

      const failedRpc = postgres.execute(`
        set role authenticated;
        set "request.jwt.claim.sub" = '${userTwo}';
        select * from public.log_meal_with_items(
          '${userTwo}'::uuid,
          '2026-08-25T12:32:00Z'::timestamptz,
          'lunch',
          'manual',
          null,
          null,
          '[{"name":"invalid","quantity":1,"unit":"not-a-real-unit"}]'::jsonb
        );
        select count(*) from public.meal_logs where user_id = '${userTwo}';
        select count(*) from public.meal_items
          where meal_log_id in (select id from public.meal_logs where user_id = '${userTwo}');
      `, false)
      expect(failedRpc.stderr).toMatch(/violates check constraint|invalid.*unit/i)
      expect(queryValues(failedRpc.stdout)).toEqual(['0', '0'])
    } finally {
      postgres.stop()
    }
  })
})
