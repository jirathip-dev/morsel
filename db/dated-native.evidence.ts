import { createServer } from 'node:http'
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { once } from 'node:events'
import { setTimeout } from 'node:timers/promises'
import { expect, it } from 'vitest'
import { findPostgresTools, startLocalPostgres, requireSuccess, supabaseBootstrap, migrationFiles } from './local-postgres-test-support.ts'
import { verifyDatedTargetRoundTrip } from './dated-target-roundtrip.ts'
import { datedTargetSqlFetch } from './dated-target-test-transport.ts'
import { createSupabaseRepository } from '../server/supabase-repository.ts'
import { MorselService } from '../server/service.ts'

// A bounded, loopback-only bridge to the LIVE disposable PostgreSQL cluster.
// Native loadHistory uses real SQL for every request, not saved JSON responses.
it('serves a real local database until the native render acknowledges completion', async () => {
  const tools = findPostgresTools()
  expect(tools, 'initdb/pg_ctl/psql required; no fake or skip fallback').toBeDefined()
  if (tools === undefined) throw new Error('PostgreSQL tooling missing')
  const database = await startLocalPostgres(tools)
  const directory = '.lane-logs/dated-native'
  const ready = `${directory}/ready.json`
  const done = `${directory}/done`
  mkdirSync(directory, { recursive: true })
  rmSync(done, { force: true })
  rmSync(ready, { force: true })
  const account = '00000000-0000-4000-8000-000000000253'
  const transport = datedTargetSqlFetch(database, account)
  const repository = createSupabaseRepository('https://local-db.test', 'local-fixture', { fetch: transport })
  const service = new MorselService({ repository, userId: account, now: () => new Date('2026-03-10T12:00:00Z') })
  const requests: string[] = []
  const server = createServer((request, response) => {
    void (async () => {
      try {
        const path = request.url ?? '/'
        if (path === '/health') { response.end('ready'); return }
        if (request.headers.authorization !== 'Bearer stub-access-token') {
          response.writeHead(401); response.end('unauthorized'); return
        }
        const parts: Buffer[] = []
        for await (const chunk of request) parts.push(Buffer.from(chunk))
        const body = Buffer.concat(parts).toString('utf8')
        requests.push(`${request.method ?? 'GET'} ${path}`)
        response.setHeader('Content-Type', 'application/json')
        if (path === '/server-readback') {
          const result = await repository.withAccessToken('local-fixture', async () => {
            const days = []
            for (const date of ['2026-03-06', '2026-03-07', '2026-03-08', '2026-03-09', '2026-03-10']) {
              days.push(await service.getDay({ date, timezone: 'America/New_York' }))
            }
            return days
          })
          response.end(JSON.stringify(result)); return
        }
        const result = await transport(`https://local-db.test${path}`, {
          method: request.method ?? 'GET', headers: { 'Content-Type': 'application/json' },
          ...(body === '' ? {} : { body }),
        })
        response.writeHead(result.status)
        response.end(await result.text())
      } catch (error) {
        response.writeHead(500)
        response.end(JSON.stringify({ message: error instanceof Error ? error.message : String(error) }))
      }
    })()
  })
  try {
    requireSuccess(database.execute(supabaseBootstrap), 'bootstrap')
    for (const migration of migrationFiles) requireSuccess(database.execute(readFileSync(migration, 'utf8')), migration)
    requireSuccess(database.execute(`
      grant usage on schema public to authenticated;
      grant select, insert, update on public.users, public.profiles, public.goals, public.weight_logs to authenticated;
      grant select, insert on public.meal_logs, public.meal_items to authenticated;
    `), 'API grants')
    await verifyDatedTargetRoundTrip(database)
    server.listen(0, '127.0.0.1')
    await once(server, 'listening')
    const address = server.address()
    if (address === null || typeof address === 'string') throw new Error('bridge address missing')
    writeFileSync(ready, JSON.stringify({ url: `http://127.0.0.1:${String(address.port)}`, user_id: account }))
    console.log(`DATED-LIVE: ready on port ${String(address.port)}; real database remains running`)
    const deadline = Date.now() + 1_500_000
    while (!existsSync(done) && Date.now() < deadline) await setTimeout(500)
    expect(existsSync(done), 'native render must finish before deadline').toBe(true)
    expect(requests.some((request) => request.includes('/server-readback'))).toBe(true)
    expect(requests.some((request) => request.includes('/rpc/get_dated_targets'))).toBe(true)
    writeFileSync(`${directory}/requests.json`, JSON.stringify(requests, null, 2))
    console.log(`DATED-LIVE: native read/render completed; ${String(requests.length)} real requests`)
  } finally {
    server.closeAllConnections()
    if (server.listening) await new Promise<void>((resolve) => { server.close(() => { resolve() }) })
    database.stop()
    rmSync(ready, { force: true })
  }
})
