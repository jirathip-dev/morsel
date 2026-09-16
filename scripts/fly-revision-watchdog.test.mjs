// Morsel issue #261 — deployed Fly revision watchdog unit + contract tests
// (no network, no Fly, no GitHub). The verdict is driven by two comparison
// inputs — main's HEAD and the revision the origin REPORTS IT IS RUNNING — so
// every test here mutates a comparison input and asserts the verdict follows,
// or asserts that an unobservable input can never produce IN_SYNC.
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  GIT_REVISION_PATTERN,
  readCommitsAhead,
  readDeployedIdentity,
  readMainHead,
  revisionVerdict,
  formatVerdict,
  main,
  run,
} from './fly-revision-watchdog.mjs'

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')

const MAIN_SHA = '1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d'
const DEPLOYED_SHA = '2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e'

const silent = { log() {}, error() {} }

function jsonResponse(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(body),
  }
}

function textResponse(status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.reject(new SyntaxError('Unexpected token')),
  }
}

function identityResponse(revision = DEPLOYED_SHA, overrides = {}) {
  return {
    revision,
    image: 'registry.fly.io/morsel-mcp:deployment-01M2KRMKT3W7EX5SGVYRNPM66V',
    machineId: '8a1b2c3d4e5f68',
    app: 'morsel-mcp',
    ...overrides,
  }
}

// A routing fetch stub: the origin's /version, the GitHub commit read, and the
// GitHub compare read are each answered (or failed) independently.
function routeFetch(handlers = {}) {
  const calls = []
  const fetchImpl = (url, init = {}) => {
    const href = String(url)
    calls.push({ href, method: init.method ?? 'GET', headers: init.headers ?? {} })
    if (href.endsWith('/version')) {
      const handler = handlers.deployed
      return Promise.resolve(handler === undefined ? jsonResponse(identityResponse()) : handler())
    }
    if (href.includes('/commits/main')) {
      const handler = handlers.main
      return Promise.resolve(handler === undefined ? jsonResponse({ sha: MAIN_SHA }) : handler())
    }
    if (href.includes('/compare/')) {
      const handler = handlers.compare
      return Promise.resolve(handler === undefined ? jsonResponse({ status: 'ahead', ahead_by: 1, commits: [] }) : handler())
    }
    return Promise.resolve(jsonResponse({}, 404))
  }
  fetchImpl.calls = calls
  return fetchImpl
}

describe('revisionVerdict — the deployed revision drives the verdict', () => {
  it('is IN_SYNC only on exact revision equality', () => {
    const result = revisionVerdict({ mainSha: MAIN_SHA, deployed: { ok: true, revision: MAIN_SHA } })
    expect(result.verdict).toBe('IN_SYNC')
  })

  it('is BEHIND when the deployed revision is a different commit', () => {
    const result = revisionVerdict({ mainSha: MAIN_SHA, deployed: { ok: true, revision: DEPLOYED_SHA } })
    expect(result.verdict).toBe('BEHIND')
    expect(result.reason).toContain(DEPLOYED_SHA)
    expect(result.reason).toContain(MAIN_SHA)
  })

  it('flips BEHIND -> IN_SYNC when only the deployed revision input changes', () => {
    const behind = revisionVerdict({ mainSha: MAIN_SHA, deployed: { ok: true, revision: DEPLOYED_SHA } })
    const inSync = revisionVerdict({ mainSha: MAIN_SHA, deployed: { ok: true, revision: MAIN_SHA } })
    expect([behind.verdict, inSync.verdict]).toEqual(['BEHIND', 'IN_SYNC'])
  })

  it('is BEHIND when a single trailing digit of the deployed revision differs', () => {
    const near = `${DEPLOYED_SHA.slice(0, -1)}3`
    expect(revisionVerdict({ mainSha: MAIN_SHA, deployed: { ok: true, revision: near } }).verdict).toBe('BEHIND')
  })

  it('is UNKNOWN (never IN_SYNC) when the deployed identity could not be read', () => {
    const result = revisionVerdict({
      mainSha: MAIN_SHA,
      deployed: { ok: false, reason: 'https://mcp.morselfood.app/version answered HTTP 404' },
    })
    expect(result.verdict).toBe('UNKNOWN')
    expect(result.reason).toContain('HTTP 404')
    expect(result.reason).toContain('NOT a green state')
  })

  it('is UNKNOWN when the running build reports no baked revision', () => {
    const result = revisionVerdict({ mainSha: MAIN_SHA, deployed: { ok: true, revision: null } })
    expect(result.verdict).toBe('UNKNOWN')
    expect(result.reason).toContain('no baked revision')
  })

  it('is UNKNOWN when main HEAD is unreadable, and never IN_SYNC', () => {
    for (const mainSha of [null, undefined, '', 'main', '5fd423e', MAIN_SHA.toUpperCase()]) {
      const result = revisionVerdict({ mainSha, deployed: { ok: true, revision: MAIN_SHA } })
      expect(result.verdict, String(mainSha)).toBe('UNKNOWN')
    }
  })

  it('never returns IN_SYNC for any unobservable comparison input', () => {
    const mainShas = [MAIN_SHA, null, undefined, 'nope']
    const deployeds = [
      { ok: false, reason: 'origin unreachable' },
      { ok: true, revision: null },
      { ok: true, revision: 'short' },
      { ok: true, revision: DEPLOYED_SHA },
      { ok: true, revision: MAIN_SHA },
      undefined,
      null,
    ]
    for (const mainSha of mainShas) {
      for (const deployed of deployeds) {
        const { verdict } = revisionVerdict({ mainSha, deployed })
        if (!GIT_REVISION_PATTERN.test(String(mainSha)) || deployed === null || deployed === undefined || deployed.ok !== true || deployed.revision !== mainSha) {
          expect(verdict, `${String(mainSha)} / ${JSON.stringify(deployed)}`).not.toBe('IN_SYNC')
        }
      }
    }
  })
})

describe('readDeployedIdentity — reads the revision the origin claims is running', () => {
  it('returns the reported revision and Fly identifiers', async () => {
    const fetchImpl = () => Promise.resolve(jsonResponse(identityResponse()))
    const deployed = await readDeployedIdentity({ origin: 'https://origin.test', fetchImpl })
    expect(deployed).toEqual({
      ok: true,
      revision: DEPLOYED_SHA,
      image: 'registry.fly.io/morsel-mcp:deployment-01M2KRMKT3W7EX5SGVYRNPM66V',
      machineId: '8a1b2c3d4e5f68',
      app: 'morsel-mcp',
    })
  })

  it('never invents identifiers the origin did not report', async () => {
    const fetchImpl = () => Promise.resolve(jsonResponse({ revision: DEPLOYED_SHA }))
    const deployed = await readDeployedIdentity({ origin: 'https://origin.test', fetchImpl })
    expect(deployed).toEqual({ ok: true, revision: DEPLOYED_SHA, image: null, machineId: null, app: null })
  })

  it('reports a null revision for a malformed revision value (no guessing)', async () => {
    for (const revision of ['main', '5fd423e', DEPLOYED_SHA.toUpperCase(), '', '   ', 42, null]) {
      const fetchImpl = () => Promise.resolve(jsonResponse({ revision }))
      const deployed = await readDeployedIdentity({ origin: 'https://origin.test', fetchImpl })
      expect(deployed.ok).toBe(true)
      expect(deployed.revision, String(revision)).toBeNull()
    }
  })

  it('fails closed on a non-200 answer', async () => {
    const fetchImpl = () => Promise.resolve(jsonResponse({}, 404))
    const deployed = await readDeployedIdentity({ origin: 'https://mcp.morselfood.app', fetchImpl })
    expect(deployed.ok).toBe(false)
    expect(deployed.reason).toContain('HTTP 404')
  })

  it('fails closed on a non-JSON body', async () => {
    const fetchImpl = () => Promise.resolve(textResponse(200))
    const deployed = await readDeployedIdentity({ origin: 'https://mcp.morselfood.app', fetchImpl })
    expect(deployed.ok).toBe(false)
    expect(deployed.reason).toContain('non-JSON')
  })

  it('fails closed without leaking raw error text when the request throws', async () => {
    const fetchImpl = () => Promise.reject(new Error('getaddrinfo ENOTFOUND secret-host internal'))
    const deployed = await readDeployedIdentity({ origin: 'https://mcp.morselfood.app', fetchImpl })
    expect(deployed.ok).toBe(false)
    expect(deployed.reason).toBe('the deployed revision could not be read from https://mcp.morselfood.app/version (request failed)')
  })

  it('requires HTTPS except for loopback probes', async () => {
    for (const origin of ['http://mcp.morselfood.app', 'ftp://origin.test', 'not a url']) {
      const deployed = await readDeployedIdentity({ origin, fetchImpl: () => Promise.reject(new Error('must not be called')) })
      expect(deployed.ok, origin).toBe(false)
    }
    const loopback = await readDeployedIdentity({
      origin: 'http://127.0.0.1:9',
      fetchImpl: () => Promise.resolve(jsonResponse(identityResponse())),
    })
    expect(loopback.ok).toBe(true)
  })

  it('issues a GET and never a mutating method', async () => {
    const fetchImpl = routeFetch()
    await readDeployedIdentity({ origin: 'https://origin.test', fetchImpl })
    expect(fetchImpl.calls).toHaveLength(1)
    expect(fetchImpl.calls[0].method).toBe('GET')
  })
})

describe('readMainHead — main is read, never assumed', () => {
  it('returns the reported sha', async () => {
    const fetchImpl = () => Promise.resolve(jsonResponse({ sha: MAIN_SHA }))
    expect(await readMainHead({ repository: 'o/r', fetchImpl })).toEqual({ ok: true, sha: MAIN_SHA })
  })

  it('fails closed on an error status or a missing/short sha', async () => {
    for (const [label, handler] of [
      ['status', () => Promise.resolve(jsonResponse({}, 403))],
      ['missing', () => Promise.resolve(jsonResponse({}))],
      ['short', () => Promise.resolve(jsonResponse({ sha: '5fd423e' }))],
    ]) {
      const head = await readMainHead({ repository: 'o/r', fetchImpl: handler })
      expect(head.ok, label).toBe(false)
      expect(head.sha).toBeNull()
    }
  })
})

describe('readCommitsAhead — the lag is listed, not summarised', () => {
  it('lists the commits main is ahead by, with their subjects', async () => {
    const fetchImpl = () => Promise.resolve(jsonResponse({
      status: 'ahead',
      ahead_by: 2,
      commits: [
        { sha: MAIN_SHA, commit: { message: 'feat: second\n\nbody' } },
        { sha: DEPLOYED_SHA, commit: { message: 'fix: first' } },
      ],
    }))
    const compare = await readCommitsAhead({
      repository: 'o/r',
      deployedRevision: DEPLOYED_SHA,
      mainSha: MAIN_SHA,
      fetchImpl,
    })
    expect(compare).toMatchObject({ ok: true, status: 'ahead', aheadBy: 2, omitted: 0 })
    expect(compare.commits).toEqual([
      { sha: MAIN_SHA, subject: 'feat: second' },
      { sha: DEPLOYED_SHA, subject: 'fix: first' },
    ])
  })

  it('preserves a diverged status and caps the listing', async () => {
    const commits = Array.from({ length: 25 }, (_, index) => ({
      sha: String(index).padStart(40, '0'),
      commit: { message: `commit ${index}` },
    }))
    const fetchImpl = () => Promise.resolve(jsonResponse({ status: 'diverged', ahead_by: 25, commits }))
    const compare = await readCommitsAhead({
      repository: 'o/r',
      deployedRevision: DEPLOYED_SHA,
      mainSha: MAIN_SHA,
      fetchImpl,
    })
    expect(compare.status).toBe('diverged')
    expect(compare.commits).toHaveLength(20)
    expect(compare.omitted).toBe(5)
  })

  it('fails closed when the compare payload has no commit list', async () => {
    const fetchImpl = () => Promise.resolve(jsonResponse({ status: 'ahead' }))
    const compare = await readCommitsAhead({
      repository: 'o/r',
      deployedRevision: DEPLOYED_SHA,
      mainSha: MAIN_SHA,
      fetchImpl,
    })
    expect(compare.ok).toBe(false)
  })
})

describe('run — the verdict follows the two comparison inputs', () => {
  it('is IN_SYNC, silent, and reads nothing beyond the two revision sources', async () => {
    const fetchImpl = routeFetch({
      deployed: () => jsonResponse(identityResponse(MAIN_SHA)),
      main: () => jsonResponse({ sha: MAIN_SHA }),
    })
    const result = await run({ origin: 'https://origin.test', repository: 'o/r', fetchImpl, log: silent })
    expect(result.verdict).toBe('IN_SYNC')
    expect(result.compare).toBeNull()
    expect(fetchImpl.calls.map((call) => call.href)).toEqual([
      'https://api.github.com/repos/o/r/commits/main',
      'https://origin.test/version',
    ])
  })

  it('flips to BEHIND when ONLY the deployed revision input changes', async () => {
    const fetchImpl = routeFetch({
      deployed: () => jsonResponse(identityResponse(DEPLOYED_SHA)),
      main: () => jsonResponse({ sha: MAIN_SHA }),
      compare: () => jsonResponse({
        status: 'ahead',
        ahead_by: 1,
        commits: [{ sha: MAIN_SHA, commit: { message: 'feat: the commit main is ahead by' } }],
      }),
    })
    const result = await run({ origin: 'https://origin.test', repository: 'o/r', fetchImpl, log: silent })
    expect(result.verdict).toBe('BEHIND')
    const report = formatVerdict(result)
    expect(report).toContain('VERDICT=BEHIND')
    expect(report).toContain('BEHIND=true')
    expect(report).toContain('main is 1 commit(s) ahead of the deployed revision')
    expect(report).toContain('feat: the commit main is ahead by')
    expect(report).toContain(DEPLOYED_SHA)
    expect(report).toContain(MAIN_SHA)
    expect(fetchImpl.calls.some((call) => call.href.includes(`/compare/${DEPLOYED_SHA}...${MAIN_SHA}`))).toBe(true)
  })

  it('is UNKNOWN and still machine-readable when the origin cannot be reached', async () => {
    const fetchImpl = routeFetch({
      deployed: () => Promise.reject(new Error('connect ECONNREFUSED 127.0.0.1:1 (internal detail)')),
      main: () => jsonResponse({ sha: MAIN_SHA }),
    })
    const result = await run({ origin: 'https://origin.test', repository: 'o/r', fetchImpl, log: silent })
    expect(result.verdict).toBe('UNKNOWN')
    const report = formatVerdict(result)
    expect(report).toContain('VERDICT=UNKNOWN')
    expect(report).toContain('BEHIND=false')
    expect(report).not.toContain('VERDICT=IN_SYNC')
    expect(report).not.toContain('ECONNREFUSED')
  })

  it('is UNKNOWN when the deployed build carries no revision, even though main is readable', async () => {
    const fetchImpl = routeFetch({
      deployed: () => jsonResponse({ revision: null }),
      main: () => jsonResponse({ sha: MAIN_SHA }),
    })
    const result = await run({ origin: 'https://origin.test', repository: 'o/r', fetchImpl, log: silent })
    expect(result.verdict).toBe('UNKNOWN')
    expect(result.reason).toContain('no baked revision')
  })

  it('keeps the verdict out of the compare read and never prints the token', async () => {
    const fetchImpl = routeFetch({
      deployed: () => jsonResponse(identityResponse(DEPLOYED_SHA)),
      main: () => jsonResponse({ sha: MAIN_SHA }),
      compare: () => Promise.resolve(jsonResponse({}, 404)),
    })
    const result = await run({
      origin: 'https://origin.test',
      repository: 'o/r',
      token: 'token-value-that-must-never-be-printed',
      fetchImpl,
      log: silent,
    })
    expect(result.verdict).toBe('BEHIND')
    const report = formatVerdict(result)
    expect(report).not.toContain('token-value-that-must-never-be-printed')
    expect(report).not.toContain('Bearer')
    expect(report).toContain('could NOT be listed')
    // The token is sent to the GitHub read API only.
    const githubCalls = fetchImpl.calls.filter((call) => call.href.startsWith('https://api.github.com'))
    expect(githubCalls.length).toBeGreaterThan(0)
    for (const call of githubCalls) {
      expect(call.headers.authorization).toBe('Bearer token-value-that-must-never-be-printed')
    }
    expect(fetchImpl.calls.find((call) => call.href.endsWith('/version')).headers.authorization).toBeUndefined()
  })
})

describe('formatVerdict — machine-readable verdict with the compared evidence', () => {
  it('emits VERDICT/BEHIND keys and one JSON object carrying both revision inputs', () => {
    const deployed = { ok: true, revision: DEPLOYED_SHA, image: 'img', machineId: 'machine', app: 'app' }
    const report = formatVerdict({
      ...revisionVerdict({ mainSha: MAIN_SHA, deployed }),
      origin: 'https://origin.test',
      main: { ok: true, sha: MAIN_SHA },
      deployed,
      compare: { ok: true, status: 'ahead', aheadBy: 1, commits: [{ sha: MAIN_SHA, subject: 's' }], omitted: 0 },
    })
    const lines = report.split('\n')
    expect(lines[0]).toContain('READ-ONLY')
    expect(lines).toContain('VERDICT=BEHIND')
    expect(lines).toContain('BEHIND=true')
    const json = JSON.parse(lines.find((line) => line.startsWith('FLY_REVISION_JSON=')).slice('FLY_REVISION_JSON='.length))
    expect(json).toMatchObject({
      verdict: 'BEHIND',
      main: { ok: true, sha: MAIN_SHA },
      deployed: { ok: true, revision: DEPLOYED_SHA, image: 'img', machineId: 'machine', app: 'app' },
    })
  })
})

describe('main — usage and fail-closed exit codes', () => {
  it('rejects arguments with the usage exit code', async () => {
    expect(await main(['--json'], {})).toBe(2)
  })

  it('rejects a malformed repository and whitespace-bearing env values', async () => {
    expect(await main([], { GITHUB_REPOSITORY: 'not-a-slug' })).toBe(2)
    expect(await main([], { MORSEL_FLY_ORIGIN: 'https://mcp.morselfood.app /x' })).toBe(2)
    expect(await main([], { MORSEL_GITHUB_API_BASE: 'https://api.github.com\n' })).toBe(2)
  })

  it('exits nonzero (never 0) when the deployed revision cannot be observed', async () => {
    // A closed loopback port: the read is real, the answer is unreachable.
    const code = await main([], {
      MORSEL_FLY_ORIGIN: 'http://127.0.0.1:1',
      MORSEL_GITHUB_API_BASE: 'http://127.0.0.1:1',
      GITHUB_REPOSITORY: 'o/r',
      GITHUB_TOKEN: 'unused-token',
    })
    expect(code).toBe(1)
  })
})

// ---------------------------------------------------------------------------
// Static contract: the revision source of truth has to stay wired end to end,
// or the watchdog silently loses its evidence.
// ---------------------------------------------------------------------------
function repoFile(relative) {
  return readFileSync(join(repoRoot, relative), 'utf8')
}

function onBlock(source, file) {
  const lines = source.split('\n')
  const start = lines.findIndex((line) => line === 'on:')
  expect(start, `${file} must declare a top-level on: trigger stanza`).toBeGreaterThanOrEqual(0)
  let end = lines.length
  for (let index = start + 1; index < lines.length; index += 1) {
    if (/^[a-zA-Z]/.test(lines[index])) {
      end = index
      break
    }
  }
  return lines.slice(start + 1, end).filter((line) => line.trim() !== '' && !line.trimStart().startsWith('#'))
}

function triggers(source, file) {
  return onBlock(source, file)
    .filter((line) => /^ {2}[a-zA-Z_][a-zA-Z0-9_-]*:(\s*\{\})?\s*$/.test(line))
    .map((line) => line.trim().split(':')[0])
}

describe('the revision source of truth is wired end to end (issue #261)', () => {
  const deployWorkflow = repoFile('.github/workflows/deploy-fly.yml')
  const watchdogWorkflow = repoFile('.github/workflows/fly-revision-watchdog.yml')
  const dockerfile = repoFile('Dockerfile')
  const app = repoFile('server/app.ts')
  const entrypoint = repoFile('server/fly-entrypoint.ts')

  it('the origin publishes /version from the build-time revision and Fly identity', () => {
    expect(app).toContain("app.get('/version', versionHandler)")
    expect(app).toContain('MORSEL_BUILD_REVISION')
    expect(app).toContain('FLY_MACHINE_ID')
    expect(app).toContain('FLY_IMAGE_REF')
    expect(app).toContain('FLY_APP_NAME')
    // The route is registered in the Fly-origin branch beside /health only.
    const originBranch = app.slice(app.indexOf("app.get('/health', healthHandler)"), app.indexOf("const mcpPreflight"))
    expect(originBranch).toContain("app.get('/version', versionHandler)")
    expect(entrypoint).toContain('identity: buildIdentity(env)')
  })

  it('the image bakes the revision as a build arg with an empty default', () => {
    expect(dockerfile).toContain('ARG MORSEL_BUILD_REVISION=""')
    expect(dockerfile).toContain('ENV MORSEL_BUILD_REVISION=${MORSEL_BUILD_REVISION}')
  })

  it('the deploy passes the resolved head revision as the build arg', () => {
    expect(deployWorkflow).toContain('git rev-parse HEAD')
    expect(deployWorkflow).toContain('--build-arg MORSEL_BUILD_REVISION="${{ steps.revision.outputs.sha }}"')
    // The revision is validated fail-closed before it is used.
    const resolveStep = deployWorkflow.slice(deployWorkflow.indexOf('Resolve the revision being deployed'))
    expect(resolveStep.slice(0, 500)).toContain('^[0-9a-f]{40}$')
    expect(resolveStep.slice(0, 500)).toContain('exit 1')
  })

  it('the deploy asserts BOTH origins report the revision it shipped', () => {
    const postcondition = deployWorkflow.slice(deployWorkflow.indexOf('Revision postcondition'))
    expect(postcondition).toContain('https://mcp.morselfood.app')
    expect(postcondition).toContain('https://morsel-mcp.fly.dev')
    expect(postcondition).toContain('/version')
    expect(postcondition).toContain('WANT="${{ steps.revision.outputs.sha }}"')
    expect(postcondition).toContain('[ "$ok" -eq 2 ] || exit 1')
  })

  it('the watchdog workflow is scheduled + dispatchable and never deploys', () => {
    expect(triggers(watchdogWorkflow, 'fly-revision-watchdog.yml')).toEqual(['schedule', 'workflow_dispatch'])
    expect(watchdogWorkflow).toContain('node scripts/fly-revision-watchdog.mjs')
    expect(watchdogWorkflow).toContain('issues: write')
    expect(watchdogWorkflow).toContain('contents: read')
    // Read-only by construction: no Fly CLI, no deploy/scaling/secret mutation,
    // no branch mutation. Comments are stripped so a prose mention of the Fly
    // CLI cannot satisfy or trip an invocation check.
    const executed = watchdogWorkflow
      .split('\n')
      .filter((line) => !line.trimStart().startsWith('#'))
      .join('\n')
    for (const forbidden of ['flyctl', 'fly deploy', 'fly scale', 'fly secrets', '--build-arg', 'git push', 'gh pr ']) {
      expect(executed, forbidden).not.toContain(forbidden)
    }
  })

  it('the read-only assertion above is not vacuous', () => {
    // The deploy workflow does contain the terms the watchdog must not: a
    // genuine absence, not a spelling the scanner could never match.
    expect(deployWorkflow).toContain('flyctl deploy')
    expect(deployWorkflow).toContain('--build-arg MORSEL_BUILD_REVISION=')
  })

  it('the watchdog workflow fails closed and files exactly one issue by title', () => {
    expect(watchdogWorkflow).toContain('exit "$status"')
    expect(watchdogWorkflow).toContain('FAILED CLOSED')
    expect(watchdogWorkflow).toContain('in:title')
    expect(watchdogWorkflow).toContain('gh issue comment')
    expect(watchdogWorkflow).toContain('gh issue create')
    expect(watchdogWorkflow).toContain('title="Morsel Fly revision drift: deployed morsel-mcp is behind main"')
    expect(watchdogWorkflow).toContain('^BEHIND=true')
  })

  it('the watchdog script performs GET requests only, with no subprocess or write', () => {
    const script = repoFile('scripts/fly-revision-watchdog.mjs')
    expect(script).not.toMatch(/method:\s*['"](POST|PUT|PATCH|DELETE)['"]/)
    expect(script).not.toContain('node:child_process')
    expect(script).not.toMatch(/\b(spawn|spawnSync|exec|execSync|execFile)\b/)
    expect(script).not.toMatch(/\b(writeFile|appendFile|createWriteStream|unlink)\b/)
    expect(script).toContain('read from the process that is serving')
  })
})
