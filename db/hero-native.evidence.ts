import { createServer } from 'node:http'
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { once } from 'node:events'
import { setTimeout } from 'node:timers/promises'
import { expect, it } from 'vitest'
import { z } from 'zod'
import { findPostgresTools, startLocalPostgres, requireSuccess, supabaseBootstrap, migrationFiles } from './local-postgres-test-support.ts'
import { datedTargetSqlFetch, sqlLiteral, targetSql } from './dated-target-test-transport.ts'

// Opt-in native WRITE -> real trigger -> native dated READ proof. No hosted DB.
// Only the clock is controlled; all target values come from native goal/addition writes.
it('captures native writes prospectively and reads the real dated rows back', async () => {
  const tools = findPostgresTools()
  if (tools === undefined) throw new Error('initdb/pg_ctl/psql required; no mock fallback')
  const database = await startLocalPostgres(tools)
  const directory = '.lane-logs/hero-native'
  mkdirSync(directory, { recursive: true })
  const ready = `${directory}/ready.json`
  const done = `${directory}/done`
  rmSync(ready, { force: true })
  rmSync(done, { force: true })
  const userID = '00000000-0000-4000-8000-000000000286'
  const auth = `set role authenticated; set "request.jwt.claim.sub"='${userID}';`
  const transport = datedTargetSqlFetch(database, userID)
  const requests: string[] = []
  let definitions: { definition: string }[] = []
  const clock = (day: string) => {
    for (const { definition } of definitions) targetSql(database,
      definition.replaceAll('clock_timestamp()', `${sqlLiteral(`${day}T12:00:00Z`)}::timestamptz`)
        .replaceAll('now()', `${sqlLiteral(`${day}T12:00:00Z`)}::timestamptz`))
  }
  const readback = (): unknown => JSON.parse(targetSql(database, `${auth}
    select coalesce(jsonb_agg(value),'[]') from public.get_dated_targets(
      '${userID}','2026-09-15','2026-09-18','UTC') value;`))
  const server = createServer((request, response) => {
    void (async () => {
      try {
        const path = request.url ?? '/'
        if (request.headers.authorization !== 'Bearer stub-access-token') {
          response.writeHead(401); response.end(); return
        }
        const parts: Buffer[] = []
        for await (const chunk of request) parts.push(Buffer.from(chunk))
        const body = Buffer.concat(parts).toString('utf8')
        requests.push(`${request.method ?? 'GET'} ${path}`)
        response.setHeader('Content-Type', 'application/json')
        if (path === '/advance-day') {
          clock('2026-09-17'); response.end('{}'); return
        }
        if (path === '/finish') {
          writeFileSync(done, 'native assertions and captures passed\n')
          response.end('{}'); return
        }
        if (path.startsWith('/rest/v1/energy_burned_logs')) {
          response.end(targetSql(database, `${auth} select coalesce(jsonb_agg(to_jsonb(r)),'[]')
            from (select burned_at,active_kcal from public.energy_burned_logs where user_id='${userID}') r;`))
          return
        }
        const result = await transport(`http://local-db.test${path}`, {
          method: request.method ?? 'GET',
          headers: { 'Content-Type': 'application/json', accept: request.headers.accept ?? 'application/json' },
          ...(body === '' ? {} : { body }),
        })
        response.writeHead(result.status); response.end(await result.text())
      } catch (error) {
        response.writeHead(500)
        response.end(JSON.stringify({ message: error instanceof Error ? error.message : String(error) }))
      }
    })()
  })
  try {
    requireSuccess(database.execute(supabaseBootstrap), 'bootstrap')
    for (const migration of migrationFiles) requireSuccess(database.execute(readFileSync(migration, 'utf8')), migration)
    targetSql(database, `grant usage on schema public to authenticated;
      grant select, insert, update on public.users, public.profiles, public.goals to authenticated;
      grant select on public.weight_logs, public.energy_burned_logs, public.meal_logs, public.meal_items to authenticated;
      insert into public.users(id,email) values('${userID}','hero@example.invalid');`)
    definitions = z.array(z.object({ definition: z.string() })).parse(JSON.parse(targetSql(database, `
      select jsonb_agg(jsonb_build_object('definition',pg_get_functiondef(oid))) from pg_proc
      where oid in ('morsel_private.lock_target_account()'::regprocedure,
        'morsel_private.capture_target_baseline(uuid)'::regprocedure,
        'morsel_private.set_dated_target_addition(uuid,date,text,numeric,uuid,uuid,boolean,boolean)'::regprocedure,
        'public.get_dated_targets(uuid,date,date,text)'::regprocedure);`)))
    clock('2026-09-16')
    for (const day of ['15', '16', '17']) {
      const mealID = `00000000-0000-4000-8000-0000000028${day}`
      targetSql(database, `insert into public.meal_logs(id,user_id,eaten_at,meal_type,source)
        values('${mealID}','${userID}','2026-09-${day}T12:00:00Z','lunch','manual');
        insert into public.meal_items(meal_log_id,name,quantity,unit,calories_kcal,protein_g,carbs_g,fat_g)
        values('${mealID}','Repro meal',1,'serving',1953,124,162,80);`)
    }
    expect(z.array(z.object({ baseline: z.unknown().optional() })).parse(readback())
      .every((day) => day.baseline === undefined)).toBe(true)
    server.listen(0, '127.0.0.1')
    await once(server, 'listening')
    const address = server.address()
    if (address === null || typeof address === 'string') throw new Error('bridge address missing')
    writeFileSync(ready, JSON.stringify({ url: `http://127.0.0.1:${String(address.port)}`, userID }))
    console.log(`HERO-LIVE: ready port=${String(address.port)}; no baseline before native write`)
    // 45 min: the native peer must pass the contended shared simulator-admission
    // lock (/tmp/n.lock) before it can build, so an 18-minute window expired while
    // this lane legitimately waited in that queue.
    const deadline = Date.now() + 2_700_000
    while (!existsSync(done) && Date.now() < deadline) await setTimeout(250)
    expect(existsSync(done), 'native write/read/capture must acknowledge before deadline').toBe(true)
    clock('2026-09-18')
    const rows = readback()
    const days = z.array(z.object({ date: z.string(), total_target_kcal: z.number().optional() })).parse(rows)
    expect(days.map((day) => day.total_target_kcal)).toEqual([undefined, 2520, 3000, 3000])
    const revisions: unknown = JSON.parse(targetSql(database, `${auth}
      select coalesce(jsonb_agg(to_jsonb(r)),'[]') from public.target_baseline_revisions r;`))
    writeFileSync(`${directory}/readback.json`, JSON.stringify({
      provenance: 'native SupabaseDashboardRepository -> loopback SQL transport -> real PostgreSQL triggers/RPCs',
      clock_control: 'only database clock expressions; no target-history inserts or updates',
      days: rows, baseline_revisions: revisions, requests,
    }, null, 2) + '\n')
    expect(requests.filter((request) => request.startsWith('POST /rest/v1/goals'))).toHaveLength(2)
    expect(requests.some((request) => request.includes('/rpc/set_dated_target_addition'))).toBe(true)
    expect(requests.some((request) => request.includes('/rpc/get_dated_targets'))).toBe(true)
    console.log(`HERO-ROUNDTRIP: ${JSON.stringify(days)}; ${String(requests.length)} native HTTP requests`)
  } finally {
    server.closeAllConnections()
    if (server.listening) await new Promise<void>((resolve) => { server.close(() => { resolve() }) })
    for (const { definition } of definitions) targetSql(database, definition)
    database.stop()
    rmSync(ready, { force: true })
  }
})
