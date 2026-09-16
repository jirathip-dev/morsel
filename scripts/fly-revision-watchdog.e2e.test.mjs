// Morsel issue #261 — end-to-end revision-watchdog proof over REAL HTTP.
//
// The origin under test is the COMMITTED Fly entry point
// (server/fly-entrypoint.ts) served by a real node:http listener, and the
// detector is the committed CLI spawned as a subprocess (`node
// scripts/fly-revision-watchdog.mjs`) — the same invocation the scheduled
// workflow uses. Only the GitHub read API is stubbed, by a second local HTTP
// listener, so nothing here reaches the network.
//
// This is the RED/GREEN proof the issue asks for: against a KNOWN-STALE
// revision the run reports BEHIND with the commits main is ahead by, against
// the same revision as main it reports IN_SYNC, and with no baked revision it
// reports UNKNOWN with a nonzero exit — never a green in-sync skip.
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
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

// --- test doubles ----------------------------------------------------------

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
}

// A real HTTP listener whose handler is swapped per leg, so one port serves the
// committed app with different baked revisions.
function bridgeServer(getHandler) {
  const server = createServer(async (request, response) => {
    const chunks = []
    for await (const chunk of request) {
      chunks.push(chunk)
    }
    const headers = new Headers()
    for (const [name, value] of Object.entries(request.headers)) {
      if (typeof value === 'string') {
        headers.set(name, value)
      }
    }
    const init = { method: request.method, headers }
    if (chunks.length > 0) {
      init.body = Buffer.concat(chunks)
    }
    const url = `http://127.0.0.1:${String(server.address().port)}${request.url ?? '/'}`
    const answered = await getHandler()(new Request(url, init))
    response.writeHead(answered.status, Object.fromEntries(answered.headers.entries()))
    response.end(Buffer.from(await answered.arrayBuffer()))
  })
  return server
}

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve(server.address().port))
  })
}

function close(server) {
  return new Promise((resolve) => {
    server.closeAllConnections()
    server.close(() => resolve())
  })
}

// --- fixture wiring -------------------------------------------------------

let originPort
let githubPort
let originServer
let githubServer
let currentApp
const githubCalls = []

function setOriginRevision(revision) {
  currentApp = createFlyEntrypointApp({
    env: {
      SUPABASE_URL: 'https://supabase.invalid',
      SUPABASE_ANON_KEY: 'test-anon-key',
      MORSEL_OAUTH_SIGNING_KEY: 'test-signing-key',
      MORSEL_PUBLIC_BASE_URL: `http://127.0.0.1:${String(originPort)}/mcp`,
      ...(revision === null ? {} : { MORSEL_BUILD_REVISION: revision }),
      FLY_IMAGE_REF: 'registry.fly.io/morsel-mcp:deployment-01M2KRMKT3W7EX5SGVYRNPM66V',
      FLY_MACHINE_ID: '8a1b2c3d4e5f68',
      FLY_APP_NAME: 'morsel-mcp',
    },
  }).app
}

let githubState = { mainSha: MAIN_SHA }

function githubHandler(request) {
  const url = new URL(request.url)
  githubCalls.push({ path: url.pathname, method: request.method })
  if (url.pathname.endsWith('/commits/main')) {
    return jsonResponse({ sha: githubState.mainSha })
  }
  if (url.pathname.includes('/compare/')) {
    return jsonResponse({
      status: 'ahead',
      ahead_by: 1,
      commits: [{ sha: MAIN_SHA, commit: { message: `${AHEAD_SUBJECT}\n\nbody` } }],
    })
  }
  return jsonResponse({}, 404)
}

beforeAll(async () => {
  originServer = bridgeServer(() => (request) => currentApp.fetch(request))
  githubServer = bridgeServer(() => (request) => githubHandler(request))
  originPort = await listen(originServer)
  githubPort = await listen(githubServer)
})

afterAll(async () => {
  await close(originServer)
  await close(githubServer)
})

// The CLI runs ASYNCHRONOUSLY: the origin and GitHub stubs are served by THIS
// process, so a synchronous spawn would deadlock against its own fixtures.
async function runWatchdog(overrides = {}) {
  const options = {
    encoding: 'utf8',
    timeout: 30_000,
    env: {
      PATH: process.env.PATH ?? '',
      HOME: process.env.HOME ?? '',
      MORSEL_FLY_ORIGIN: `http://127.0.0.1:${String(originPort)}`,
      MORSEL_GITHUB_API_BASE: `http://127.0.0.1:${String(githubPort)}`,
      GITHUB_REPOSITORY: REPOSITORY,
      ...overrides,
    },
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

describe('the committed Fly origin serves its build identity over real HTTP', () => {
  it('reports the baked revision, image, machine, and app on GET /version', async () => {
    setOriginRevision(MAIN_SHA)
    const response = await fetch(`http://127.0.0.1:${String(originPort)}/version`)
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({
      revision: MAIN_SHA,
      image: 'registry.fly.io/morsel-mcp:deployment-01M2KRMKT3W7EX5SGVYRNPM66V',
      machineId: '8a1b2c3d4e5f68',
      app: 'morsel-mcp',
    })
  })

  it('health still answers the Fly check at the origin root', async () => {
    const response = await fetch(`http://127.0.0.1:${String(originPort)}/health`)
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ ok: true })
  })
})

describe('the watchdog reads the RUNNING revision and reports IN_SYNC / BEHIND / UNKNOWN', () => {
  it('IN_SYNC, silent, exit 0 when the deployed revision IS main', async () => {
    setOriginRevision(MAIN_SHA)
    githubState = { mainSha: MAIN_SHA }
    githubCalls.length = 0
    const run = await runWatchdog()
    console.log(`[leg IN_SYNC] exit=${run.status}\n${run.stdout}`)
    expect(run.stderr).toBe('')
    expect(run.status).toBe(0)
    expect(run.stdout).toContain('VERDICT=IN_SYNC')
    expect(run.stdout).toContain('BEHIND=false')
    expect(run.stdout).toContain(`deployed: ${MAIN_SHA}`)
    // In sync is determined without asking GitHub what main is ahead by.
    expect(githubCalls.filter((call) => call.path.includes('/compare/'))).toHaveLength(0)
  })

  it('BEHIND against a known-stale revision, with the commits main is ahead by', async () => {
    setOriginRevision(STALE_SHA)
    githubState = { mainSha: MAIN_SHA }
    githubCalls.length = 0
    const run = await runWatchdog()
    console.log(`[leg BEHIND] exit=${run.status}\n${run.stdout}`)
    expect(run.status).toBe(0)
    expect(run.stdout).toContain('VERDICT=BEHIND')
    expect(run.stdout).toContain('BEHIND=true')
    expect(run.stdout).toContain(`deployed: ${STALE_SHA}`)
    expect(run.stdout).toContain(`main: ${MAIN_SHA}`)
    expect(run.stdout).toContain('main is 1 commit(s) ahead of the deployed revision')
    expect(run.stdout).toContain(AHEAD_SUBJECT)
    expect(run.stdout).toContain('registry.fly.io/morsel-mcp:deployment-01M2KRMKT3W7EX5SGVYRNPM66V')
    // The compare really used the observed (stale) revision as its base.
    expect(githubCalls.some((call) => call.path.includes(`/compare/${STALE_SHA}...${MAIN_SHA}`))).toBe(true)
  })

  it('flips BEHIND -> IN_SYNC when ONLY the deployed revision input changes', async () => {
    githubState = { mainSha: MAIN_SHA }
    setOriginRevision(STALE_SHA)
    const behind = await runWatchdog()
    setOriginRevision(MAIN_SHA)
    const inSync = await runWatchdog()
    expect(behind.stdout).toContain('VERDICT=BEHIND')
    expect(inSync.stdout).toContain('VERDICT=IN_SYNC')
    expect([behind.status, inSync.status]).toEqual([0, 0])
  })

  it('UNKNOWN with a nonzero exit when the running build has no baked revision', async () => {
    setOriginRevision(null)
    githubState = { mainSha: MAIN_SHA }
    const run = await runWatchdog()
    console.log(`[leg UNKNOWN] exit=${run.status}\n${run.stdout}`)
    expect(run.status).not.toBe(0)
    expect(run.stdout).toContain('VERDICT=UNKNOWN')
    expect(run.stdout).not.toContain('VERDICT=IN_SYNC')
    expect(run.stdout).toContain('no baked revision')
  })

  it('UNKNOWN with a nonzero exit when the origin is unreachable', async () => {
    setOriginRevision(MAIN_SHA)
    const run = await runWatchdog({ MORSEL_FLY_ORIGIN: 'http://127.0.0.1:1' })
    expect(run.status).not.toBe(0)
    expect(run.stdout).toContain('VERDICT=UNKNOWN')
    expect(run.stdout).not.toContain('VERDICT=IN_SYNC')
  })

  it('UNKNOWN with a nonzero exit when main cannot be read', async () => {
    setOriginRevision(MAIN_SHA)
    const run = await runWatchdog({ MORSEL_GITHUB_API_BASE: 'http://127.0.0.1:1' })
    expect(run.status).not.toBe(0)
    expect(run.stdout).toContain('VERDICT=UNKNOWN')
    expect(run.stdout).toContain('main: unavailable')
  })
})
