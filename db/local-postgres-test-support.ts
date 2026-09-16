import { spawnSync } from 'node:child_process'
import { accessSync, constants, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

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

export interface LocalPostgres {
  execute(sql: string, stopOnError?: boolean): CommandResult
  stop(): void
}

export const supabaseBootstrap = `
        create extension if not exists pgcrypto;
        create schema auth;
        create role anon nologin;
        create role authenticated nologin;
        create role service_role nologin;
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
      `

export const migrationFiles = [
  'db/migrations/0001_init.sql',
  'db/migrations/0002_targets.sql',
  'db/migrations/0003_atomic_meals_and_users_rls.sql',
  'db/migrations/0004_store_assets.sql',
  'db/migrations/0005_oauth_authorization_grants.sql',
  'db/migrations/0006_food_catalog_provider_cache.sql',
  'db/migrations/0007_weight_logs.sql',
  'db/migrations/0008_energy_burned_logs.sql',
  'db/migrations/0009_goals_fractional_calories.sql',
  'db/migrations/0010_meal_outbox_client_ids.sql',
  'db/migrations/0011_profiles_timezone.sql',
  'db/migrations/0012_named_menus.sql',
  'db/migrations/0013_artwork_identity.sql',
  'db/migrations/0014_dated_targets.sql',
  'db/migrations/0015_artwork_identity_expansion.sql',
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

export function findPostgresTools(): PostgresTools | undefined {
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

export function requireSuccess(result: CommandResult, description: string, diagnosticLogPath?: string): string {
  if (result.error !== undefined || result.status !== 0) {
    const diagnosticLog = diagnosticLogPath === undefined
      ? ''
      : `\npostgres.log:\n${readDiagnosticLog(diagnosticLogPath)}`
    throw new Error(`${description} failed\n${result.stderr}\n${result.error?.message ?? ''}${diagnosticLog}`)
  }
  return result.stdout
}

export async function startLocalPostgres(tools: PostgresTools): Promise<LocalPostgres> {
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
