import { spawnSync } from 'node:child_process'
import { accessSync, constants, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { z } from 'zod'
import { ArtworkIdSchema } from '../packages/schema/food-types.ts'
import { createSupabaseRepository } from '../server/supabase-repository.ts'
import { MorselService } from '../server/service.ts'

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
  'db/migrations/0005_oauth_authorization_grants.sql',
  'db/migrations/0006_food_catalog_provider_cache.sql',
  'db/migrations/0007_weight_logs.sql',
  'db/migrations/0008_energy_burned_logs.sql',
  'db/migrations/0009_goals_fractional_calories.sql',
  'db/migrations/0010_meal_outbox_client_ids.sql',
  'db/migrations/0011_profiles_timezone.sql',
  'db/migrations/0012_named_menus.sql',
  'db/migrations/0013_artwork_identity.sql',
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

// Local transport adapter only: the production Supabase repository sends its
// real RPC payloads/projections; SQL runs as authenticated in the real cluster.
// No PostgREST daemon, network service, or canned meal rows are involved.
function artworkSqlFetch(postgres: LocalPostgres, userId: string): typeof fetch {
  const literal = (value: string) => `'${value.replaceAll("'", "''")}'`
  const identifier = (value: string) => z.string().regex(/^[a-z_]+$/).parse(value)
  const fetchSql = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const request = input instanceof Request ? new Request(input, init) : new Request(input.toString(), init)
    const url = new URL(request.url)
    let query: string
    if (url.pathname === '/rest/v1/rpc/log_meal_with_items') {
      const body = await request.text()
      query = `select result.* from jsonb_to_record(${literal(body)}::jsonb) as args(
        p_user_id uuid, p_eaten_at timestamptz, p_meal_type text, p_source text,
        p_image_path text, p_notes text, p_items jsonb
      ) cross join lateral public.log_meal_with_items(
        args.p_user_id, args.p_eaten_at, args.p_meal_type, args.p_source,
        args.p_image_path, args.p_notes, args.p_items
      ) as result`
    } else {
      const table = z.enum(['meal_logs', 'meal_items', 'meal_menus', 'menu_items', 'profiles', 'goals']).parse(url.pathname.split('/').pop())
      const columns = (url.searchParams.get('select') ?? 'id').split(',').map(identifier).join(',')
      const predicates: string[] = []
      for (const [key, value] of url.searchParams) {
        if (['select', 'order'].includes(key)) continue
        const column = identifier(key)
        if (value.startsWith('in.(') && value.endsWith(')')) {
          predicates.push(`${column} in (${value.slice(4, -1).split(',').map(literal).join(',')})`)
        } else {
          const [operator, ...parts] = value.split('.')
          const symbol = z.enum(['eq', 'gte', 'lt']).parse(operator)
          predicates.push(`${column} ${{ eq: '=', gte: '>=', lt: '<' }[symbol]} ${literal(parts.join('.'))}`)
        }
      }
      const where = predicates.length === 0 ? '' : ` where ${predicates.join(' and ')}`
      if (request.method === 'PATCH') {
        const patch = z.record(z.string(), z.union([z.string(), z.number()])).parse(await request.json())
        const assignments = Object.entries(patch).map(([key, value]) => `${identifier(key)} = ${literal(String(value))}`)
        query = `update public.${table} set ${assignments.join(',')} ${where} returning ${columns}`
      } else {
        expect(request.method).toBe('GET')
        query = `select ${columns} from public.${table}${where}`
      }
    }
    const result = requireSuccess(postgres.execute(`
      set role authenticated;
      set "request.jwt.claim.sub" = '${userId}';
      with rows as (${query}) select coalesce(jsonb_agg(to_jsonb(rows)), '[]'::jsonb) from rows;
    `), 'artwork repository SQL transport')
    const rows = z.array(z.unknown()).parse(JSON.parse(queryValues(result).join('')))
    const single = request.headers.get('accept')?.includes('vnd.pgrst.object') === true
    return new Response(JSON.stringify(single ? rows[0] ?? null : rows), { headers: { 'content-type': 'application/json' } })
  }
  fetchSql.preconnect = (): void => undefined
  return fetchSql
}

async function verifyArtworkRoundTrip(postgres: LocalPostgres, userId: string, otherUserId: string): Promise<void> {
  requireSuccess(postgres.execute(`
    grant select on public.profiles to authenticated;
    grant select, insert, update, delete on public.meal_menus, public.menu_items to authenticated;
    grant update on public.meal_items to authenticated;
  `), 'artwork API grants')
  const repository = createSupabaseRepository('https://local-postgres.invalid', 'fixture-key', { fetch: artworkSqlFetch(postgres, userId) })
  const service = new MorselService({ repository, userId })
  const names = ['Coffee', 'black coffee', 'กาแฟ', 'Americano', '  Americano (black, no sugar, homemade)  ']
  const items = names.map((name) => ({ name, artwork_id: 'coffee', quantity: 1, unit: 'cup', calories_kcal: 3, protein_g: 0, carbs_g: 0, fat_g: 0 }))
  const legacy = ['coffee cake', 'ambiguous mixed dish', 'unknown food'].map((name) => ({ name, quantity: 1, unit: 'serving' }))
  await repository.withAccessToken('local-fixture', async () => {
    const logged = await service.logMeal({ meal_type: 'breakfast', eaten_at: '2026-09-01T08:00:00Z', items: [...items, ...legacy] })
    const day = await service.getDay({ date: '2026-09-01' })
    const meal = day.meals.find((candidate) => candidate.meal_log_id === logged.meal_log_id)
    expect(meal?.items).toEqual(expect.arrayContaining(items.map((item) => expect.objectContaining(item))))
    for (const item of legacy) expect(meal?.items.find((candidate) => candidate.name === item.name)).toEqual({ ...item, item_id: expect.any(String) })
    const itemId = meal?.items.find((item) => item.name === names[0])?.item_id
    expect(itemId).toBeDefined()
    await service.updateMealItem({ item_id: itemId, artwork_id: 'banana' })
    await service.updateMealItem({ item_id: itemId, calories_kcal: 4 })
    const reread = await service.getDay({ date: '2026-09-01' })
    expect(reread.meals.flatMap((meal) => meal.items).find((item) => item.item_id === itemId)).toMatchObject({ name: names[0], artwork_id: 'banana', calories_kcal: 4, quantity: 1, unit: 'cup' })
    await expect(service.updateMealItem({ item_id: itemId, artwork_id: 'unpublished' })).rejects.toMatchObject({ code: 'invalid_input' })
    await service.logMeal({ meal_type: 'lunch', eaten_at: '2026-09-02T08:00:00Z', menu_name: 'Synthetic artwork menu', items })
    expect((await service.listMenus({})).menus[0]?.items).toEqual(expect.arrayContaining(items.map((item) => expect.objectContaining(item))))
    await service.logMeal({ meal_type: 'dinner', eaten_at: '2026-09-03T08:00:00Z', menu_name: 'Synthetic artwork menu' })
    expect((await service.getDay({ date: '2026-09-03' })).meals[0]?.items).toEqual(expect.arrayContaining(items.map((item) => expect.objectContaining(item))))
  })
  const foreignRepository = createSupabaseRepository('https://local-postgres.invalid', 'fixture-key', { fetch: artworkSqlFetch(postgres, otherUserId) })
  const foreign = new MorselService({ repository: foreignRepository, userId: otherUserId })
  await foreignRepository.withAccessToken('local-fixture', async () => {
    expect((await foreign.getDay({ date: '2026-09-01' })).meals).toEqual([])
  })
}

function verifyArtworkDatabaseRules(postgres: LocalPostgres, userId: string, otherUserId: string): void {
  const clientId = '00000000-0000-4000-8000-000000000241'
  const allItems = ArtworkIdSchema.options.map((artwork_id) => ({ name: 'Synthetic catalog item', artwork_id, quantity: 1, unit: 'serving' }))
  const allIds = requireSuccess(postgres.execute(`
    set role authenticated;
    set "request.jwt.claim.sub" = '${userId}';
    select items from public.log_meal_with_items(
      '${userId}', '2026-09-04T08:00:00Z', 'lunch', 'manual', null, null,
      '${JSON.stringify(allItems)}'::jsonb
    );
  `), 'all published IDs accepted by the database')
  const stored = z.array(z.object({ artwork_id: z.string() })).parse(JSON.parse(queryValues(allIds).join('')))
  expect(stored.map((item) => item.artwork_id).sort()).toEqual([...ArtworkIdSchema.options].sort())
  // Inspect the installed constraints, not migration text: extra DB-only IDs
  // are drift too, not just missing IDs caught by the insert above.
  for (const table of ['meal_items', 'menu_items']) {
    const constraint = requireSuccess(postgres.execute(`select pg_get_constraintdef(oid) from pg_constraint where conname = '${table}_artwork_id_published';`), 'installed artwork allowlist')
    expect([...constraint.matchAll(/'([^']+)'::text/g)].map((match) => match[1]).sort()).toEqual([...ArtworkIdSchema.options].sort())
  }
  const clientCall = `select items->0->>'artwork_id' from public.log_meal_with_items_client(
    '${userId}', '2026-09-05T08:00:00Z', 'breakfast', 'manual', 'synthetic/photo.jpg', null,
    '[{"name":"Synthetic Americano","quantity":1,"unit":"cup","artwork_id":"coffee","calories_kcal":3}]', '${clientId}'
  );`
  for (let attempt = 0; attempt < 2; attempt++) {
    expect(queryValues(requireSuccess(postgres.execute(`set role authenticated; set "request.jwt.claim.sub" = '${userId}'; ${clientCall}`), 'client RPC commit and retry'))).toEqual(['coffee'])
  }
  expect(queryValues(requireSuccess(postgres.execute(`
    select name || '|' || artwork_id || '|' || calories_kcal::text from public.meal_items where meal_log_id = '${clientId}';
    select image_path from public.meal_logs where id = '${clientId}';
    select artwork_id is null from public.meal_items where name = 'rice';
  `), 'separate connection durable item and photo readback'))).toEqual(['Synthetic Americano|coffee|3', 'synthetic/photo.jpg', 't'])
  const denied = postgres.execute(`set role authenticated; set "request.jwt.claim.sub" = '${otherUserId}'; ${clientCall}`)
  expect(denied.status).toBe(3)
  expect(denied.stderr).toContain('meal user does not match authenticated user')
  for (const artwork_id of ['unpublished', 'Coffee', ' coffee ', '']) {
    const invalid = postgres.execute(`
      set role authenticated; set "request.jwt.claim.sub" = '${userId}';
      select * from public.log_meal_with_items('${userId}', '2026-09-06T08:00:00Z', 'lunch', 'manual', null, null,
        '[{"name":"Synthetic invalid","quantity":1,"unit":"cup","artwork_id":"${artwork_id}","menu_name":"Rejected artwork menu"}]');
    `)
    expect(invalid.status).toBe(3)
    expect(invalid.stderr).toContain('artwork_id_published')
  }
  expect(queryValues(requireSuccess(postgres.execute(`
    select count(*) from public.meal_logs where eaten_at = '2026-09-06T08:00:00Z';
    select count(*) from public.meal_menus where name = 'Rejected artwork menu';
  `), 'invalid artwork rolls back logs and new templates'))).toEqual(['0', '0'])
  const invalidUpdate = postgres.execute(`update public.meal_items set artwork_id = 'unpublished' where meal_log_id = '${clientId}';`)
  expect(invalidUpdate.status).toBe(3)
  expect(invalidUpdate.stderr).toContain('meal_items_artwork_id_published')
  const menuSave = requireSuccess(postgres.execute(`
    set role authenticated; set "request.jwt.claim.sub" = '${userId}';
    select menu_id from public.upsert_menu('${userId}', null, 'Synthetic saved menu',
      '[{"name":"Synthetic menu drink","quantity":1,"unit":"cup","artwork_id":"coffee"}]');
  `), 'upsert_menu accepts artwork')
  const menuId = z.uuid().parse(queryValues(menuSave)[0])
  expect(queryValues(requireSuccess(postgres.execute(`select artwork_id from public.menu_items where menu_id = '${menuId}';`), 'saved template artwork readback'))).toEqual(['coffee'])
  requireSuccess(postgres.execute(`
    set role authenticated; set "request.jwt.claim.sub" = '${userId}';
    select menu_id from public.upsert_menu('${userId}', '${menuId}', 'Synthetic saved menu',
      '[{"name":"Synthetic edited menu","quantity":1,"unit":"piece","artwork_id":"banana"}]');
  `), 'template edit with artwork')
  expect(queryValues(requireSuccess(postgres.execute(`select artwork_id from public.menu_items where menu_id = '${menuId}'; select artwork_id from public.meal_items where meal_log_id = '${clientId}';`), 'template edits do not rewrite meal snapshots'))).toEqual(['banana', 'coffee'])
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
    const catalogInsertId = 'f0000000-0000-4000-8000-000000000009'
    const catalogExternalId = '49d29a54-14b9-4df0-8270-965aa64b9cc7'
    const catalogUpdateId = 'f0000000-0000-4000-8000-000000000001'
    const catalogDeleteId = 'f0000000-0000-4000-8000-000000000002'

    try {
      requireSuccess(postgres.execute(`
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
      `), 'Supabase-like bootstrap')

      for (const migration of migrationFiles) {
        if (migration.endsWith('0013_artwork_identity.sql')) {
          requireSuccess(postgres.execute(`
            insert into public.users (id, email) values ('00000000-0000-4000-8000-000000000240', 'legacy@example.invalid');
            insert into public.meal_logs (id, user_id, eaten_at, meal_type, source, image_path)
              values ('00000000-0000-4000-8000-000000000240', '00000000-0000-4000-8000-000000000240', '2026-08-01T08:00:00Z', 'breakfast', 'manual', 'synthetic/legacy.jpg');
            insert into public.meal_items (meal_log_id, name, quantity, unit, calories_kcal)
              values ('00000000-0000-4000-8000-000000000240', 'Synthetic legacy Americano', 1, 'cup', 3);
          `), 'pre-artwork migration row')
        }
        requireSuccess(postgres.execute(migrationSql(migration)), migration)
      }
      expect(queryValues(requireSuccess(postgres.execute(`
        select item.name || '|' || item.calories_kcal::text || '|' || log.image_path || '|' || (item.artwork_id is null)::text
        from public.meal_items item join public.meal_logs log on log.id = item.meal_log_id
        where log.id = '00000000-0000-4000-8000-000000000240';
      `), 'old row unchanged across migration'))).toEqual(['Synthetic legacy Americano|3|synthetic/legacy.jpg|true'])
      requireSuccess(postgres.execute(migrationSql('db/seed.sql')), 'food catalog seed')
      requireSuccess(postgres.execute(migrationSql('db/migrations/0004_store_assets.sql')), 'rerunnable store assets migration')
      requireSuccess(postgres.execute(migrationSql('db/seed.sql')), 'rerunnable food catalog seed')

      const goalsSourceContract = requireSuccess(postgres.execute(`
        select count(*) from information_schema.columns
        where table_schema = 'public' and table_name = 'goals' and column_name = 'source';
        select column_default from information_schema.columns
        where table_schema = 'public' and table_name = 'goals' and column_name = 'source';
        select pg_get_constraintdef(oid) from pg_constraint
        where conrelid = 'public.goals'::regclass
          and contype = 'c'
          and pg_get_constraintdef(oid) ilike '%source%';
      `), 'cumulative goals.source contract')
      expect(queryValues(goalsSourceContract)).toEqual(['1', "'computed'::text", 'CHECK ((source = ANY (ARRAY[\'computed\'::text, \'manual\'::text])))'])

      requireSuccess(postgres.execute(`
        grant usage on schema public to anon, authenticated;
        grant select, insert, update on public.users to authenticated;
        grant select, insert on public.meal_logs, public.meal_items to authenticated;
        grant select, insert on public.energy_burned_logs to authenticated;
        grant select, insert, update, delete on public.goals to authenticated;
        grant select, insert, update, delete on public.food_catalog to authenticated;
        grant select on storage.buckets to authenticated;
        grant select, insert, update, delete on storage.objects to authenticated;
      `), 'API role grants')

      const oauthRpcCatalog = requireSuccess(postgres.execute(`
        select count(*) from pg_proc
        where oid = to_regprocedure('public.claim_oauth_authorization_grant(text,text)');
        select prosecdef from pg_proc
        where oid = to_regprocedure('public.claim_oauth_authorization_grant(text,text)');
      `), 'OAuth claim RPC catalog contract')
      expect(queryValues(oauthRpcCatalog)).toEqual(['1', 't'])

      requireSuccess(postgres.execute(`
        begin;
        set role authenticated;
        set local "request.jwt.claim.sub" = '${userOne}';
        insert into public.oauth_authorization_grants (
          code_hash,
          client_id,
          redirect_uri,
          code_challenge,
          scopes,
          resource,
          user_id,
          refresh_token,
          expires_at
        ) values (
          'oauth-code-hash-one',
          'oauth-client-one',
          'https://client.example/callback',
          'oauth-code-challenge',
          array['mcp']::text[],
          'https://morsel.example/mcp',
          '${userOne}',
          'oauth-refresh-token',
          now() + interval '5 minutes'
        );
        commit;
      `), 'owner OAuth grant insert')

      const crossOAuthInsert = postgres.execute(`
        set role authenticated;
        set "request.jwt.claim.sub" = '${userTwo}';
        insert into public.oauth_authorization_grants (
          code_hash,
          client_id,
          redirect_uri,
          code_challenge,
          user_id,
          refresh_token,
          expires_at
        ) values (
          'oauth-code-hash-cross-user',
          'oauth-client-one',
          'https://client.example/callback',
          'oauth-code-challenge',
          '${userOne}',
          'oauth-refresh-token-cross-user',
          now() + interval '5 minutes'
        );
      `, false)
      expect(crossOAuthInsert.stderr).toMatch(/row-level security policy/i)

      const oauthClaim = requireSuccess(postgres.execute(`
        begin;
        set role anon;
        select code_hash || '|' || client_id || '|' || user_id::text || '|' || refresh_token
        from public.claim_oauth_authorization_grant(
          p_code_hash => 'oauth-code-hash-one',
          p_client_id => 'oauth-client-one'
        );
        select count(*) from public.claim_oauth_authorization_grant(
          p_code_hash => 'oauth-code-hash-one',
          p_client_id => 'oauth-client-one'
        );
        commit;
      `), 'atomic OAuth grant claim')
      expect(queryValues(oauthClaim)).toEqual([
        `oauth-code-hash-one|oauth-client-one|${userOne}|oauth-refresh-token`,
        '0',
      ])

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

      const catalogInsert = postgres.execute(`
        set role authenticated;
        set "request.jwt.claim.sub" = '${userOne}';
        with inserted as (
          insert into public.food_catalog (id, name, source)
          values ('${catalogInsertId}', 'Unauthorized catalog insert', 'curated')
          returning id
        )
        select count(*) from inserted;
      `, false)
      if (/row-level security policy/i.test(catalogInsert.stderr)) {
        expect(queryValues(catalogInsert.stdout)).toEqual([])
      } else {
        expect(catalogInsert.stderr).toBe('')
        expect(queryValues(catalogInsert.stdout)).toEqual(['0'])
      }
      const catalogInsertState = requireSuccess(postgres.execute(`
        select count(*) from public.food_catalog where id = '${catalogInsertId}';
      `), 'catalog insert state')
      expect(queryValues(catalogInsertState)).toEqual(['0'])

      const deniedRpc = postgres.execute(`
        set role authenticated;
        set "request.jwt.claim.sub" = '${userOne}';
        select public.upsert_food_catalog('[]'::jsonb);
      `, false)
      expect(deniedRpc.stderr).toMatch(/permission denied for function upsert_food_catalog/i)
      const poisoningRpc = postgres.execute(`
        set role service_role;
        select public.upsert_food_catalog('[{"id":"${catalogInsertId}","fdc_id":173944,"name":"Poisoned banana","serving_size":"1","serving_unit":"cup"}]'::jsonb);
      `, false)
      expect(poisoningRpc.stderr).toMatch(/invalid food catalog row/i)
      const missingExternalIdRpc = postgres.execute(`
        set role service_role;
        select public.upsert_food_catalog('[{"id":"${catalogInsertId}","name":"Missing id","serving_size":"100","serving_unit":"g","calories_kcal":99999}]'::jsonb);
      `, false)
      expect(missingExternalIdRpc.stderr).toMatch(/invalid food catalog row/i)
      const forgedContentRpc = postgres.execute(`
        set role service_role;
        select public.upsert_food_catalog('[{"id":"${catalogExternalId}","fdc_id":173944,"name":"Forged banana","serving_size":"100","serving_unit":"g","calories_kcal":99999}]'::jsonb);
      `, false)
      expect(forgedContentRpc.stderr).toMatch(/invalid food catalog row/i)
      const catalogRpc = requireSuccess(postgres.execute(`
        set role service_role;
        select public.upsert_food_catalog('[{"id":"${catalogExternalId}","fdc_id":173944,"name":"External banana","serving_size":"100","serving_unit":"g","calories_kcal":105,"protein_g":1.3,"carbs_g":27,"fat_g":0.4}]'::jsonb);
        set role authenticated;
        set "request.jwt.claim.sub" = '${userOne}';
        select count(*) from public.food_catalog where id = '${catalogExternalId}' and name = 'External banana' and source = 'usda';
      `), 'catalog cache RPC')
      expect(queryValues(catalogRpc)).toEqual(['1'])

      const catalogUpdate = postgres.execute(`
        set role authenticated;
        set "request.jwt.claim.sub" = '${userOne}';
        with updated as (
          update public.food_catalog
          set name = 'Unauthorized catalog update'
          where id = '${catalogUpdateId}'
          returning id
        )
        select count(*) from updated;
      `, false)
      if (/row-level security policy/i.test(catalogUpdate.stderr)) {
        expect(queryValues(catalogUpdate.stdout)).toEqual([])
      } else {
        expect(catalogUpdate.stderr).toBe('')
        expect(queryValues(catalogUpdate.stdout)).toEqual(['0'])
      }
      const catalogUpdateState = requireSuccess(postgres.execute(`
        select count(*) from public.food_catalog
        where id = '${catalogUpdateId}' and name = 'Jasmine rice, cooked';
      `), 'catalog update state')
      expect(queryValues(catalogUpdateState)).toEqual(['1'])

      const catalogDelete = postgres.execute(`
        set role authenticated;
        set "request.jwt.claim.sub" = '${userOne}';
        with deleted as (
          delete from public.food_catalog
          where id = '${catalogDeleteId}'
          returning id
        )
        select count(*) from deleted;
      `, false)
      if (/row-level security policy/i.test(catalogDelete.stderr)) {
        expect(queryValues(catalogDelete.stdout)).toEqual([])
      } else {
        expect(catalogDelete.stderr).toBe('')
        expect(queryValues(catalogDelete.stdout)).toEqual(['0'])
      }
      const catalogDeleteState = requireSuccess(postgres.execute(`
        select count(*) from public.food_catalog
        where id = '${catalogDeleteId}' and name = 'Chicken breast, roasted, skinless';
      `), 'catalog delete state')
      expect(queryValues(catalogDeleteState)).toEqual(['1'])

      const ownerStorageInsert = requireSuccess(postgres.execute(`
        set role authenticated;
        set "request.jwt.claim.sub" = '${userOne}';
        with inserted as (
          insert into storage.objects (bucket_id, name)
          values ('food-images', '${userOne}/new.jpg')
          returning id
        )
        select count(*) from inserted;
        select count(*) from storage.objects
        where bucket_id = 'food-images' and name = '${userOne}/new.jpg';
      `), 'owner storage insert')
      expect(queryValues(ownerStorageInsert)).toEqual(['1', '1'])

      const ownerStorageUpdate = requireSuccess(postgres.execute(`
        set role authenticated;
        set "request.jwt.claim.sub" = '${userOne}';
        with updated as (
          update storage.objects
          set name = '${userOne}/meal-renamed.jpg'
          where bucket_id = 'food-images' and name = '${userOne}/meal.jpg'
          returning id
        )
        select count(*) from updated;
        select count(*) from storage.objects
        where bucket_id = 'food-images' and name = '${userOne}/meal-renamed.jpg';
        select count(*) from storage.objects
        where bucket_id = 'food-images' and name = '${userOne}/meal.jpg';
      `), 'owner storage update')
      expect(queryValues(ownerStorageUpdate)).toEqual(['1', '1', '0'])

      const crossStorageInsert = postgres.execute(`
        set role authenticated;
        set "request.jwt.claim.sub" = '${userOne}';
        with inserted as (
          insert into storage.objects (bucket_id, name)
          values ('food-images', '${userTwo}/forbidden.jpg')
          returning id
        )
        select count(*) from inserted;
      `, false)
      if (/row-level security policy/i.test(crossStorageInsert.stderr)) {
        expect(queryValues(crossStorageInsert.stdout)).toEqual([])
      } else {
        expect(crossStorageInsert.stderr).toBe('')
        expect(queryValues(crossStorageInsert.stdout)).toEqual(['0'])
      }
      const crossStorageInsertState = requireSuccess(postgres.execute(`
        select count(*) from storage.objects
        where bucket_id = 'food-images' and name = '${userTwo}/forbidden.jpg';
      `), 'cross-user storage insert state')
      expect(queryValues(crossStorageInsertState)).toEqual(['0'])

      const crossStorageUpdate = postgres.execute(`
        set role authenticated;
        set "request.jwt.claim.sub" = '${userOne}';
        with updated as (
          update storage.objects
          set name = '${userTwo}/moved.jpg'
          where bucket_id = 'food-images' and name = '${userTwo}/meal.jpg'
          returning id
        )
        select count(*) from updated;
      `, false)
      if (/row-level security policy/i.test(crossStorageUpdate.stderr)) {
        expect(queryValues(crossStorageUpdate.stdout)).toEqual([])
      } else {
        expect(crossStorageUpdate.stderr).toBe('')
        expect(queryValues(crossStorageUpdate.stdout)).toEqual(['0'])
      }
      const crossStorageUpdateState = requireSuccess(postgres.execute(`
        select count(*) from storage.objects
        where bucket_id = 'food-images' and name = '${userTwo}/meal.jpg';
        select count(*) from storage.objects
        where bucket_id = 'food-images' and name = '${userTwo}/moved.jpg';
      `), 'cross-user storage update state')
      expect(queryValues(crossStorageUpdateState)).toEqual(['1', '0'])

      const crossStorageDelete = postgres.execute(`
        set role authenticated;
        set "request.jwt.claim.sub" = '${userOne}';
        with deleted as (
          delete from storage.objects
          where bucket_id = 'food-images' and name = '${userTwo}/meal.jpg'
          returning id
        )
        select count(*) from deleted;
      `, false)
      if (/row-level security policy/i.test(crossStorageDelete.stderr)) {
        expect(queryValues(crossStorageDelete.stdout)).toEqual([])
      } else {
        expect(crossStorageDelete.stderr).toBe('')
        expect(queryValues(crossStorageDelete.stdout)).toEqual(['0'])
      }
      const crossStorageDeleteState = requireSuccess(postgres.execute(`
        select count(*) from storage.objects
        where bucket_id = 'food-images' and name = '${userTwo}/meal.jpg';
      `), 'cross-user storage delete state')
      expect(queryValues(crossStorageDeleteState)).toEqual(['1'])

      const ownerStorageDelete = requireSuccess(postgres.execute(`
        set role authenticated;
        set "request.jwt.claim.sub" = '${userOne}';
        with deleted as (
          delete from storage.objects
          where bucket_id = 'food-images' and name = '${userOne}/meal-renamed.jpg'
          returning id
        )
        select count(*) from deleted;
        select count(*) from storage.objects
        where bucket_id = 'food-images' and name = '${userOne}/meal-renamed.jpg';
      `), 'owner storage delete')
      expect(queryValues(ownerStorageDelete)).toEqual(['1', '0'])

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

      const zeroEnergyInsert = postgres.execute(`
        set role authenticated;
        set "request.jwt.claim.sub" = '${userOne}';
        insert into public.energy_burned_logs (user_id, burned_at, active_kcal)
        values ('${userOne}', '2026-08-25T00:00:00Z', 0);
      `, false)
      expect(zeroEnergyInsert.stderr).toMatch(/energy_burned_logs_kcal_positive/i)

      const positiveEnergyInsert = requireSuccess(postgres.execute(`
        set role authenticated;
        set "request.jwt.claim.sub" = '${userOne}';
        insert into public.energy_burned_logs (user_id, burned_at, active_kcal)
        values ('${userOne}', '2026-08-25T00:00:00Z', 300);
        select count(*) from public.energy_burned_logs
        where user_id = '${userOne}' and active_kcal = 300;
      `), 'positive active-energy insert')
      expect(queryValues(positiveEnergyInsert)).toEqual(['INSERT 0 1', '1'])

      const fractionalGoal = postgres.execute(`
        set role authenticated;
        set "request.jwt.claim.sub" = '${userOne}';
        insert into public.goals (user_id, calorie_target_kcal, protein_g, carbs_g, fat_g, source)
        values ('${userOne}', 2000.5, 100, 200, 50, 'manual');
      `, false)
      expect(fractionalGoal.stderr).not.toMatch(/integer|invalid input|goals_calorie/i)
      const fractionalRoundTrip = requireSuccess(postgres.execute(`
        set role authenticated;
        set "request.jwt.claim.sub" = '${userOne}';
        select calorie_target_kcal from public.goals
        where user_id = '${userOne}' and calorie_target_kcal = 2000.5;
      `), 'fractional calorie goal survives persistence exactly')
      expect(queryValues(fractionalRoundTrip)).toEqual(['2000.5'])

      // Column scale and the app's one-decimal normalization agree: a 2000.55
      // write rounds to 2000.6 in Postgres's numeric(10,1) column, exactly the
      // value the editor normalizes to before sending.
      const scaledCalorieGoal = requireSuccess(postgres.execute(`
        set role authenticated;
        set "request.jwt.claim.sub" = '${userTwo}';
        insert into public.goals (user_id, calorie_target_kcal, protein_g, carbs_g, fat_g, source)
        values ('${userTwo}', 2000.55, 100, 200, 50, 'manual');
        select calorie_target_kcal from public.goals
        where user_id = '${userTwo}' and calorie_target_kcal = 2000.6;
      `), 'numeric(10,1) rounds 2000.55 to 2000.6 like the app normalizer')
      expect(queryValues(scaledCalorieGoal)).toEqual(['INSERT 0 1', '2000.6'])

      // The goals.source allowlist is exactly computed|manual: a forbidden
      // value is rejected by the check constraint (string-match assertions
      // alone did not discriminate).
      const forbiddenSourceGoal = postgres.execute(`
        set role authenticated;
        set "request.jwt.claim.sub" = '${userOne}';
        insert into public.goals (user_id, calorie_target_kcal, protein_g, carbs_g, fat_g, source)
        values ('${userOne}', 2000, 100, 200, 50, 'other');
      `, false)
      expect(forbiddenSourceGoal.stderr).toMatch(/violates check constraint/i)

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
      await verifyArtworkRoundTrip(postgres, userOne, userTwo)
      verifyArtworkDatabaseRules(postgres, userOne, userTwo)
    } finally {
      postgres.stop()
    }
  }, 30_000)
})
