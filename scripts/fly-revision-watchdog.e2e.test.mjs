// Morsel issue #261 — end-to-end revision-watchdog proof over REAL HTTP.
//
// The origin under test is the COMMITTED Fly entry point
// (server/fly-entrypoint.ts) served by a real node:http listener, and the
// detector is the committed CLI spawned as a subprocess (`node
// scripts/fly-revision-watchdog.mjs`) — the same invocation the scheduled
// workflow uses. Only the GitHub read API is stubbed, by a second local HTTP
// listener, so nothing here reaches the network.
//
// DETERMINISM CONTRACT (fix round 1). Every test owns its fixture: its own
// origin listener, its own GitHub stub, its own request recorder, and its own
// listener ports. Nothing is shared or mutated across tests, so no assertion can
// depend on test order or on a value observed mid-flight. Assertions are made
// on the SETTLED END STATE only — the finished run's exit code, its verdict
// lines, the machine-readable record it printed, and (for provenance) the
// requests its own recorder saw — never on a transient frontier of the run.
//
// This is the RED/GREEN proof the issue asks for: against a KNOWN-STALE
// revision the run reports BEHIND with the commits main is ahead by, against
// the same revision as main it reports IN_SYNC, and with no baked revision it
// reports UNKNOWN with a nonzero exit — never a green in-sync skip.
import { describe, expect, it } from 'vitest'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { createServer } from 'node:http'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createFlyEntrypointApp } from '../server/fly-entrypoint.ts'

const execFileAsync = promisify(execFile)
const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const WATCHDOG = join(repoRoot, 'scripts', 'fly-revision-watchdog.mjs')
const REPOSITORY = 'morsel-test/revision-watchdog'

const MAIN_SHA = '3333333333333333333333333333333333333333'
const STALE_SHA = '4444444444444444444444444444444444444444'
const AHEAD_SUBJECT = 'feat: the server work main is ahead by (issue #261)'
const IMAGE = 'registry.fly.io/morsel-mcp:deployment-01M2KRMKT3W7EX5SGVYRNPM66V'
const MACHINE_ID = '8a1b2c3d4e5f68'

// --- fixture plumbing ------------------------------------------------------

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
}

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve(server.address().port))
  })
}

function close(server) {
  if (server === undefined) {
    return Promise.resolve()
  }
  return new Promise((resolve) => {
    server.closeAllConnections()
    server.close(() => resolve())
  })
}

async function answer(nodeResponse, answered) {
  nodeResponse.writeHead(answered.status, Object.fromEntries(answered.headers.entries()))
  nodeResponse.end(Buffer.from(await answered.arrayBuffer()))
}

// The watchdog only issues GETs, so the fixture bridge forwards method, URL, and
// headers and carries no body.
function fetchRequestFor(server, request) {
  const headers = new Headers()
  for (const [name, value] of Object.entries(request.headers)) {
    if (typeof value === 'string') {
      headers.set(name, value)
    }
  }
  return new Request(`http://127.0.0.1:${String(server.address().port)}${request.url ?? '/'}`, {
    method: request.method,
    headers,
  })
}

function flyEnv(port, revision) {
  return {
    SUPABASE_URL: 'https://supabase.invalid',
    SUPABASE_ANON_KEY: 'test-anon-key',
    MORSEL_OAUTH_SIGNING_KEY: 'test-signing-key',
    MORSEL_PUBLIC_BASE_URL: `http://127.0.0.1:${String(port)}/mcp`,
    ...(revision === null ? {} : { MORSEL_BUILD_REVISION: revision }),
    FLY_IMAGE_REF: IMAGE,
    FLY_MACHINE_ID: MACHINE_ID,
    FLY_APP_NAME: 'morsel-mcp',
  }
}

function githubHandler(url, mainSha) {
  if (url.pathname.endsWith('/commits/main')) {
    return jsonResponse({ sha: mainSha })
  }
  if (url.pathname.includes('/compare/')) {
    return jsonResponse({
      status: 'ahead',
      ahead_by: 1,
      commits: [{ sha: mainSha, commit: { message: `${AHEAD_SUBJECT}\n\nbody` } }],
    })
  }
  return jsonResponse({}, 404)
}

/**
 * One isolated fixture: a real origin listener running the COMMITTED Fly entry
 * point with `revision` baked in, a GitHub stub listener answering `mainSha`,
 * and recorders that belong to THIS fixture alone.
 */
async function startFixture({ revision, mainSha = MAIN_SHA }) {
  const originRequests = []
  const githubRequests = []
  const originState = { app: undefined }
  const originServer = createServer(async (request, response) => {
    originRequests.push({ url: request.url ?? '/', method: request.method })
    await answer(response, await originState.app.fetch(fetchRequestFor(originServer, request)))
  })
  const originPort = await listen(originServer)
  originState.app = createFlyEntrypointApp({ env: flyEnv(originPort, revision) }).app

  const githubServer = createServer(async (request, response) => {
    const url = new URL(request.url ?? '/', 'http://127.0.0.1')
    githubRequests.push({ path: url.pathname, method: request.method })
    await answer(response, githubHandler(url, mainSha))
  })
  const githubPort = await listen(githubServer)

  return {
    origin: `http://127.0.0.1:${String(originPort)}`,
    githubBase: `http://127.0.0.1:${String(githubPort)}`,
    originRequests,
    githubRequests,
    compareRequests: () => githubRequests.filter((request) => request.path.includes('/compare/')),
    run: (overrides = {}) =>
      runCli({
        MORSEL_FLY_ORIGIN: `http://127.0.0.1:${String(originPort)}`,
        MORSEL_GITHUB_API_BASE: `http://127.0.0.1:${String(githubPort)}`,
        ...overrides,
      }),
    close: async () => {
      await close(originServer)
      await close(githubServer)
    },
  }
}

async function withFixture(options, body) {
  const fixture = await startFixture(options)
  try {
    return await body(fixture)
  } finally {
    await fixture.close()
  }
}

// The CLI runs ASYNCHRONOUSLY: the origin and GitHub stubs are served by THIS
// process, so a synchronous spawn would deadlock against its own fixtures.
async function runCli(env) {
  const options = {
    encoding: 'utf8',
    timeout: 30_000,
    env: { PATH: process.env.PATH ?? '', HOME: process.env.HOME ?? '', GITHUB_REPOSITORY: REPOSITORY, ...env },
  }
  try {
    const { stdout, stderr } = await execFileAsync(process.execPath, [WATCHDOG], options)
    return { status: 0, stdout, stderr }
  } catch (error) {
    // A nonzero exit is an expected result here (UNKNOWN), not a test failure.
    return {
      status: typeof error.code === 'number' ? error.code : 1,
      stdout: typeof error.stdout === 'string' ? error.stdout : '',
      stderr: typeof error.stderr === 'string' ? error.stderr : '',
    }
  }
}

// The settled machine-readable record the finished run printed: the last line
// starting with FLY_REVISION_JSON=.
function parsedRecord(stdout) {
  const line = stdout.split('\n').find((candidate) => candidate.startsWith('FLY_REVISION_JSON='))
  if (line === undefined) {
    throw new Error('the run printed no FLY_REVISION_JSON record')
  }
  return JSON.parse(line.slice('FLY_REVISION_JSON='.length))
}

describe('the committed Fly origin serves its build identity over real HTTP', () => {
  it('reports the baked revision, image, machine, and app on GET /version', async () => {
    await withFixture({ revision: MAIN_SHA }, async (fixture) => {
      const response = await fetch(`${fixture.origin}/version`)
      expect(response.status).toBe(200)
      expect(await response.json()).toEqual({
        revision: MAIN_SHA,
        image: IMAGE,
        machineId: MACHINE_ID,
        app: 'morsel-mcp',
      })
    })
  })

  it('health still answers the Fly check at the origin root', async () => {
    await withFixture({ revision: MAIN_SHA }, async (fixture) => {
      const response = await fetch(`${fixture.origin}/health`)
      expect(response.status).toBe(200)
      expect(await response.json()).toEqual({ ok: true })
    })
  })
})

describe('the watchdog reads the RUNNING revision and reports IN_SYNC / BEHIND / UNKNOWN', () => {
  it('IN_SYNC, silent, exit 0 when the deployed revision IS main', async () => {
    await withFixture({ revision: MAIN_SHA, mainSha: MAIN_SHA }, async (fixture) => {
      const run = await fixture.run()
      console.log(`[leg IN_SYNC] exit=${run.status}\n${run.stdout}`)
      expect(run.status).toBe(0)
      expect(run.stderr).toBe('')
      expect(run.stdout).toContain('VERDICT=IN_SYNC')
      expect(run.stdout).toContain('BEHIND=false')
      expect(run.stdout).toContain(`deployed: ${MAIN_SHA}`)
      expect(parsedRecord(run.stdout)).toMatchObject({
        verdict: 'IN_SYNC',
        main: { ok: true, sha: MAIN_SHA },
        deployed: { ok: true, revision: MAIN_SHA, image: IMAGE, machineId: MACHINE_ID, app: 'morsel-mcp' },
        commitsAhead: null,
      })
      // Settled provenance: in sync needs no "what is main ahead by" lookup.
      expect(fixture.compareRequests()).toHaveLength(0)
    })
  })

  it('BEHIND against a known-stale revision, with the commits main is ahead by', async () => {
    await withFixture({ revision: STALE_SHA, mainSha: MAIN_SHA }, async (fixture) => {
      const run = await fixture.run()
      console.log(`[leg BEHIND] exit=${run.status}\n${run.stdout}`)
      expect(run.status).toBe(0)
      expect(run.stdout).toContain('VERDICT=BEHIND')
      expect(run.stdout).toContain('BEHIND=true')
      expect(run.stdout).toContain(`deployed: ${STALE_SHA}`)
      expect(run.stdout).toContain(`main: ${MAIN_SHA}`)
      expect(run.stdout).toContain('main is 1 commit(s) ahead of the deployed revision')
      expect(run.stdout).toContain(AHEAD_SUBJECT)
      expect(run.stdout).toContain(IMAGE)
      // The settled record carries the compared evidence on both sides.
      expect(parsedRecord(run.stdout)).toMatchObject({
        verdict: 'BEHIND',
        main: { ok: true, sha: MAIN_SHA },
        deployed: { ok: true, revision: STALE_SHA, image: IMAGE, machineId: MACHINE_ID, app: 'morsel-mcp' },
        commitsAhead: [MAIN_SHA],
      })
      // Settled provenance: the compare really used the OBSERVED stale revision
      // as its base, and every request this fixture saw was a read.
      expect(fixture.compareRequests().map((request) => request.path)).toEqual([
        `/repos/${REPOSITORY}/compare/${STALE_SHA}...${MAIN_SHA}`,
      ])
      expect(fixture.githubRequests.every((request) => request.method === 'GET')).toBe(true)
    })
  })

  it('flips BEHIND -> IN_SYNC when ONLY the deployed revision input changes', async () => {
    const behind = await withFixture({ revision: STALE_SHA, mainSha: MAIN_SHA }, (fixture) => fixture.run())
    const inSync = await withFixture({ revision: MAIN_SHA, mainSha: MAIN_SHA }, (fixture) => fixture.run())
    expect(behind.stdout).toContain('VERDICT=BEHIND')
    expect(inSync.stdout).toContain('VERDICT=IN_SYNC')
    expect([behind.status, inSync.status]).toEqual([0, 0])
  })

  it('UNKNOWN with a nonzero exit when the running build has no baked revision', async () => {
    await withFixture({ revision: null, mainSha: MAIN_SHA }, async (fixture) => {
      const run = await fixture.run()
      console.log(`[leg UNKNOWN] exit=${run.status}\n${run.stdout}`)
      expect(run.status).not.toBe(0)
      expect(run.stdout).toContain('VERDICT=UNKNOWN')
      expect(run.stdout).not.toContain('VERDICT=IN_SYNC')
      expect(run.stdout).toContain('no baked revision')
      expect(parsedRecord(run.stdout)).toMatchObject({ verdict: 'UNKNOWN', deployed: { ok: true, revision: null } })
    })
  })

  it('UNKNOWN with a nonzero exit when the origin is unreachable', async () => {
    await withFixture({ revision: MAIN_SHA, mainSha: MAIN_SHA }, async (fixture) => {
      const run = await fixture.run({ MORSEL_FLY_ORIGIN: 'http://127.0.0.1:1' })
      expect(run.status).not.toBe(0)
      expect(run.stdout).toContain('VERDICT=UNKNOWN')
      expect(run.stdout).not.toContain('VERDICT=IN_SYNC')
    })
  })

  it('UNKNOWN with a nonzero exit when main cannot be read', async () => {
    await withFixture({ revision: MAIN_SHA, mainSha: MAIN_SHA }, async (fixture) => {
      const run = await fixture.run({ MORSEL_GITHUB_API_BASE: 'http://127.0.0.1:1' })
      expect(run.status).not.toBe(0)
      expect(run.stdout).toContain('VERDICT=UNKNOWN')
      expect(run.stdout).toContain('main: unavailable')
      expect(run.stdout).not.toContain('VERDICT=IN_SYNC')
    })
  })
})
