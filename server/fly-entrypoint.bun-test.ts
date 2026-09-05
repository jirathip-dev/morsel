// Real-HTTP session regression for the Fly single-process entry point
// (issue #72). Runs ONLY under Bun (`bun test server/fly-entrypoint.bun-test.ts`);
// vitest under Node skips this file because its name is *.bun-test.ts.
//
// Why real HTTP: the Supabase Edge Function bug this hosting change fixes is
// session CONTINUITY — each request landing on a fresh isolate lost the
// in-memory session map (issue #71). An in-process app.fetch test cannot tell
// a single long-lived app from an app rebuilt per request, so this suite
// starts the real Bun server adapter over a real localhost listener and makes
// THREE separate HTTP requests against one process: initialize (200 + session
// header) -> notifications/initialized (202) -> tools/list (200 + 13 tools).
// The wire format is the SDK's default SSE; the test parses `data:` frames
// and stays agnostic of the chosen format.
import { afterAll, beforeAll, describe, expect, it } from 'bun:test'
import { startFlyServer } from './fly-entrypoint.js'
import type { Authenticate, AuthenticatedUser } from './auth.js'
import { MorselError } from './errors.js'
import { InMemoryRepository } from './in-memory-repository.js'
import type { MorselRepository } from './repository.js'
import type { FlyEntrypointEnv } from './fly-entrypoint.js'

const TEST_USER_ID = '00000000-0000-4000-8000-000000000002'
const BEARER_TOKEN = 'fly-session-regression-token'
// Issue #96: a token that was valid at initialize and is expired by the time
// the next in-session tools/call arrives (the seam rejects it like Supabase
// Auth rejects an expired JWT).
const EXPIRED_TOKEN = 'fly-session-expired-token'

// The canonical 14-tool contract (same list pinned by http.test.ts).
const EXPECTED_TOOLS = [
  'compute_targets',
  'delete_meal_log',
  'get_dashboard_summary',
  'get_day',
  'get_energy_burned',
  'get_goals',
  'get_profile',
  'get_weight_trend',
  'log_meal',
  'reset_goals',
  'search_food',
  'set_goals',
  'set_profile',
  'update_meal_item',
].sort()

function testEnv(): FlyEntrypointEnv {
  return {
    SUPABASE_URL: 'https://supabase.invalid',
    SUPABASE_ANON_KEY: 'test-anon-key',
    MORSEL_OAUTH_SIGNING_KEY: 'test-signing-key',
    MORSEL_PUBLIC_BASE_URL: 'https://mcp.morselfood.app/mcp',
  }
}

// Narrow injection seam: the fixed test account for the session regression
// token and every request re-validates the bearer (issue #96: the expired
// token is rejected exactly where Supabase Auth would reject it). Every
// session is backed by the in-memory repository (no Supabase, no network).
const authenticate: Authenticate = (token: string): Promise<AuthenticatedUser> => {
  if (token !== BEARER_TOKEN) {
    return Promise.reject(new MorselError('authentication_failed', 'bearer token could not be validated'))
  }
  return Promise.resolve({
    userId: TEST_USER_ID,
    email: 'test@example.com',
    token,
    authInfo: {
      token,
      clientId: 'morsel-fly-test',
      scopes: [],
      extra: { userId: TEST_USER_ID },
    },
  })
}

const repositoryFactory = (): MorselRepository => new InMemoryRepository()

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isRecordArray(value: unknown): value is Record<string, unknown>[] {
  return Array.isArray(value) && value.every(isRecord)
}

function parseResponseDocument(text: string): Record<string, unknown> {
  // SDK default mode streams text/event-stream `data:` frames; JSON mode
  // (enableJsonResponse) returns one JSON body. Accept both honestly.
  if (text.trim().startsWith('{')) {
    const parsed: unknown = JSON.parse(text)
    if (!isRecord(parsed)) {
      throw new Error('response body was not a JSON-RPC object')
    }
    return parsed
  }
  const frames: unknown[] = []
  for (const line of text.split('\n')) {
    if (line.startsWith('data:')) {
      frames.push(JSON.parse(line.slice(5).trim()))
    }
  }
  const last = frames[frames.length - 1]
  if (!isRecord(last)) {
    throw new Error(`no parseable SSE data frame in response: ${text.slice(0, 200)}`)
  }
  return last
}

let server: ReturnType<typeof Bun.serve> | undefined
let baseUrl = ''

beforeAll(() => {
  // Boot through the entry point's OWN server starter (startFlyServer) so the
  // regression guards the production wiring, not a re-implementation: one
  // process, one app instance, one in-memory session map.
  server = startFlyServer({
    env: testEnv(),
    deps: { authenticate, repositoryFactory },
    hostname: '127.0.0.1',
    port: 0,
  })
  const boundPort = server.port
  if (boundPort === undefined) {
    throw new Error('Bun.serve did not report a bound port')
  }
  baseUrl = 'http://127.0.0.1:' + boundPort.toString()
})

afterAll(() => {
  if (server !== undefined) {
    void server.stop(true)
  }
})

function mcpRequest(path: string, body: Record<string, unknown>, sessionId?: string, token: string = BEARER_TOKEN): Promise<Response> {
  return fetch(`${baseUrl}${path}`, {
    method: 'POST',
    headers: {
      accept: 'application/json, text/event-stream',
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
      ...(sessionId === undefined ? {} : { 'mcp-session-id': sessionId }),
    },
    body: JSON.stringify(body),
  })
}

const INITIALIZE: Record<string, unknown> = {
  jsonrpc: '2.0',
  id: 1,
  method: 'initialize',
  params: {
    protocolVersion: '2025-03-26',
    capabilities: {},
    clientInfo: { name: 'morsel-fly-session-regression', version: '1.0.0' },
  },
}

describe('Fly entry point over a real HTTP listener (single process, one session map)', () => {
  it('keeps one initialized MCP session across three separate HTTP requests', async () => {
    // 1. initialize without a session id -> 200 and a session header.
    const initializeResponse = await mcpRequest('/mcp', INITIALIZE)
    expect(initializeResponse.status).toBe(200)
    const sessionId = initializeResponse.headers.get('mcp-session-id') ?? ''
    expect(sessionId).not.toBe('')
    const initializeDocument = parseResponseDocument(await initializeResponse.text())
    const initializeResult = initializeDocument.result
    if (!isRecord(initializeResult)) {
      throw new Error('initialize response did not carry a result')
    }
    expect(initializeResult.protocolVersion).toBe('2025-03-26')
    expect(isRecord(initializeResult.serverInfo)).toBe(true)

    // 2. notifications/initialized with the returned id -> 202 (the SDK's
    // correct notification status; issue shorthand says 200/200/200 but the
    // protocol answers 202 for notifications).
    const notificationResponse = await mcpRequest('/mcp', {
      jsonrpc: '2.0',
      method: 'notifications/initialized',
    }, sessionId)
    expect(notificationResponse.status).toBe(202)

    // 3. tools/list with the same id -> 200 and the full canonical tool set.
    // A fresh app instance (or a lost session map) would answer 404 here.
    const toolsResponse = await mcpRequest('/mcp', {
      jsonrpc: '2.0',
      id: 3,
      method: 'tools/list',
    }, sessionId)
    expect(toolsResponse.status).toBe(200)
    const toolsDocument = parseResponseDocument(await toolsResponse.text())
    const result = toolsDocument.result
    if (!isRecord(result) || !Array.isArray(result.tools)) {
      throw new Error('tools/list result did not carry a tools array')
    }
    const names = result.tools.map((tool: unknown) => {
      if (!isRecord(tool) || typeof tool.name !== 'string') {
        throw new Error('tool entry without a name')
      }
      return tool.name
    }).sort()
    expect(names).toEqual(EXPECTED_TOOLS)
  })

  it('answers unknown and missing sessions with the transport error contract', async () => {
    // Unknown session id -> 404 (the app-level sessions map is authoritative
    // over the real HTTP boundary).
    const unknown = await mcpRequest('/mcp', {
      jsonrpc: '2.0',
      id: 4,
      method: 'tools/list',
    }, '00000000-0000-4000-8000-000000000000')
    expect(unknown.status).toBe(404)

    // tools/list without any session id is not an initialize -> 400.
    const missing = await mcpRequest('/mcp', {
      jsonrpc: '2.0',
      id: 5,
      method: 'tools/list',
    })
    expect(missing.status).toBe(400)
  })

  it('exposes per-tool oauth2 securitySchemes and answers an expired-auth read-only call with the _meta re-auth challenge (issue #96)', async () => {
    const resourceMetadataUrl = 'https://mcp.morselfood.app/mcp/.well-known/oauth-protected-resource/mcp'
    const requiredText = 'Authentication required: reconnect the Morsel account to continue.'
    const expectedChallenge = `Bearer resource_metadata="${resourceMetadataUrl}", error="invalid_token", error_description="${requiredText}"`

    // 1. initialize with the still-valid token -> a real session id.
    const initializeResponse = await mcpRequest('/mcp', INITIALIZE)
    expect(initializeResponse.status).toBe(200)
    const sessionId = initializeResponse.headers.get('mcp-session-id') ?? ''
    expect(sessionId).not.toBe('')

    // 2. tools/list on the same session: every one of the 14 tools carries
    // the OpenAI oauth2 securitySchemes metadata in its tool-level _meta,
    // and the safety annotations are still on the wire.
    const toolsResponse = await mcpRequest('/mcp', {
      jsonrpc: '2.0',
      id: 30,
      method: 'tools/list',
    }, sessionId)
    expect(toolsResponse.status).toBe(200)
    const toolsDocument = parseResponseDocument(await toolsResponse.text())
    const listResult = toolsDocument.result
    const tools = isRecord(listResult) ? listResult.tools : undefined
    if (!isRecordArray(tools)) {
      throw new Error('tools/list result did not carry a tools array')
    }
    expect(tools.map((tool) => tool.name).sort()).toEqual(EXPECTED_TOOLS)
    for (const tool of tools) {
      const name = tool.name
      if (typeof name !== 'string') {
        throw new Error('tools/list returned a tool without a name')
      }
      expect(tool._meta, `${name} must carry tool _meta`).toEqual({
        securitySchemes: [{ type: 'oauth2', scopes: ['mcp'] }],
      })
      const annotations = tool.annotations
      if (!isRecord(annotations)) {
        throw new Error(`${name} did not carry annotations`)
      }
      expect(annotations.readOnlyHint).toBeTypeOf('boolean')
      expect(annotations.destructiveHint).toBeTypeOf('boolean')
      expect(annotations.idempotentHint).toBeTypeOf('boolean')
      expect(annotations.openWorldHint).toBeTypeOf('boolean')
    }

    // 3. the same session's read-only tool call with the now-expired token:
    // ChatGPT's re-auth contract wants a structured JSON-RPC result carrying
    // _meta["mcp/www_authenticate"], not a bare transport 401.
    const failing = await mcpRequest('/mcp', {
      jsonrpc: '2.0',
      id: 31,
      method: 'tools/call',
      params: { name: 'get_day', arguments: { date: '2026-08-25' } },
    }, sessionId, EXPIRED_TOKEN)
    expect(failing.status).toBe(200)
    const failingDocument = parseResponseDocument(await failing.text())
    expect(failingDocument.jsonrpc).toBe('2.0')
    expect(failingDocument.id).toBe(31)
    const failingResult = failingDocument.result
    if (!isRecord(failingResult)) {
      throw new Error('challenge response did not carry a result')
    }
    expect(failingResult.isError).toBe(true)
    const failingContent = failingResult.content
    const failingText = isRecordArray(failingContent) ? failingContent[0]?.text : undefined
    if (typeof failingText !== 'string') {
      throw new Error('challenge result did not carry text content')
    }
    expect(failingText).toBe(requiredText)
    const failingMeta = failingResult._meta
    if (!isRecord(failingMeta)) {
      throw new Error('challenge result did not carry _meta')
    }
    expect(failingMeta['mcp/www_authenticate']).toEqual([expectedChallenge])
    const rawFailingBody = JSON.stringify(failingDocument)
    for (const leaked of ['supabase', 'postgres', 'stack', 'test@example.com', EXPIRED_TOKEN, BEARER_TOKEN]) {
      expect(rawFailingBody.toLowerCase(), `challenge body must not contain ${leaked}`).not.toContain(leaked)
    }

    // 4. the session survives: a valid token on the same session id is served
    // normally again (the challenge never corrupted or closed the session).
    const recovered = await mcpRequest('/mcp', {
      jsonrpc: '2.0',
      id: 32,
      method: 'tools/call',
      params: { name: 'get_day', arguments: { date: '2026-08-25' } },
    }, sessionId)
    expect(recovered.status).toBe(200)
    const recoveredDocument = parseResponseDocument(await recovered.text())
    const recoveredResult = recoveredDocument.result
    if (!isRecord(recoveredResult)) {
      throw new Error('recovered tool call did not carry a result')
    }
    expect(recoveredResult.isError).not.toBe(true)
    expect(recoveredResult._meta).toBeUndefined()
  })
})
