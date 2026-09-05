import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import type { Hono } from 'hono'
import { describe, expect, it } from 'vitest'
import { createMorselApp } from './app.js'
import type { Authenticate, AuthenticatedUser } from './auth.js'
import { MorselError } from './errors.js'
import { InMemoryRepository } from './in-memory-repository.js'

// Issue #96 regression: the OpenAI/ChatGPT per-tool OAuth contract. Every
// assertion runs against the REAL adapter (Hono app -> MCP SDK streamable
// HTTP transport -> MorselService), never against server source text.
//
// Contract source (retrieved 2026-09-04): developers.openai.com/plugins/build/auth
// — "Triggering authentication UI" requires BOTH per-tool `securitySchemes`
// metadata (`{type:'oauth2', scopes:[...]}`) and runtime tool errors that
// carry `_meta["mcp/www_authenticate"]` with a `Bearer resource_metadata=...,
// error=..., error_description=...` challenge. The field rides in each tool's
// `_meta` because the installed MCP SDK (1.30.0, latest on npm) emits
// tool-level `_meta` in tools/list but silently drops unknown top-level
// config keys such as a first-class `securitySchemes` (SEP-1488 draft).
// Scopes are derived from the existing OAuth contract: both the
// authorization-server and protected-resource metadata documents already
// advertise `scopes_supported: ['mcp']` — no second issuer or credential
// system is introduced.

const USER_ID = '00000000-0000-4000-8000-000000000096'
const VALID_TOKEN = 'issue-96-valid-token'
const EXPIRED_TOKEN = 'issue-96-expired-token'
// The deployed Fly origin's canonical base (mirrors fly-entrypoint tests).
const PUBLIC_BASE_URL = 'https://morsel-mcp.fly.dev/mcp'
const RESOURCE_METADATA_URL = `${PUBLIC_BASE_URL}/.well-known/oauth-protected-resource/mcp`
// The same fixed, backend-free text the HTTP 401 challenge never leaks and
// the structured tool error repeats; deliberately contains no stack, token,
// email, Supabase, or Postgres detail.
const AUTHENTICATION_REQUIRED_TEXT = 'Authentication required: reconnect the Morsel account to continue.'
const EXPECTED_CHALLENGE = `Bearer resource_metadata="${RESOURCE_METADATA_URL}", error="invalid_token", error_description="${AUTHENTICATION_REQUIRED_TEXT}"`
const EXPECTED_SECURITY_SCHEMES = [{ type: 'oauth2', scopes: ['mcp'] }]

const EXPECTED_TOOLS = [
  'attach_meal_image',
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

function recordValue(value: unknown, key: string): unknown {
  return isRecord(value) ? value[key] : undefined
}

function createTestApp(): Hono {
  const authenticate: Authenticate = (token: string): Promise<AuthenticatedUser> => {
    if (token !== VALID_TOKEN) {
      // Mirrors createSupabaseAuthenticator: expired/invalid bearers map to
      // MorselError authentication_failed before any tool can run.
      return Promise.reject(new MorselError('authentication_failed', 'bearer token could not be validated'))
    }
    return Promise.resolve({
      userId: USER_ID,
      email: 'test@example.com',
      token,
      authInfo: {
        token,
        clientId: 'issue-96-test-client',
        scopes: [],
        extra: { userId: USER_ID },
      },
    })
  }
  return createMorselApp({
    authenticate,
    repositoryFactory: () => new InMemoryRepository(),
    basePath: '/mcp',
    enableJsonResponse: true,
    oauth: { publicBaseUrl: PUBLIC_BASE_URL },
  })
}

async function mcpPost(
  app: Hono,
  body: Record<string, unknown>,
  options: { token?: string; sessionId?: string } = {},
): Promise<Response> {
  const headers: Record<string, string> = {
    accept: 'application/json, text/event-stream',
    'content-type': 'application/json',
  }
  if (options.token !== undefined) {
    headers.authorization = `Bearer ${options.token}`
  }
  if (options.sessionId !== undefined) {
    headers['mcp-session-id'] = options.sessionId
  }
  return app.fetch(new Request(`${PUBLIC_BASE_URL}/mcp`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  }))
}

async function initializeSession(app: Hono): Promise<string> {
  const initialize = await mcpPost(app, {
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: {
      protocolVersion: '2025-03-26',
      capabilities: {},
      clientInfo: { name: 'issue-96-regression', version: '1.0.0' },
    },
  }, { token: VALID_TOKEN })
  expect(initialize.status).toBe(200)
  const sessionId = initialize.headers.get('mcp-session-id') ?? ''
  expect(sessionId).not.toBe('')
  const notification = await mcpPost(app, {
    jsonrpc: '2.0',
    method: 'notifications/initialized',
  }, { token: VALID_TOKEN, sessionId })
  expect(notification.status).toBe(202)
  return sessionId
}

describe('ChatGPT per-tool OAuth metadata and auth-challenge compatibility (issue #96)', () => {
  it('emits the OpenAI oauth2 securitySchemes metadata for every protected tool on the tools/list wire', async () => {
    const app = createTestApp()
    const sessionId = await initializeSession(app)
    const toolsResponse = await mcpPost(app, {
      jsonrpc: '2.0',
      id: 2,
      method: 'tools/list',
    }, { token: VALID_TOKEN, sessionId })
    expect(toolsResponse.status).toBe(200)
    const document = parseResponseDocument(await toolsResponse.text())
    const result = recordValue(document, 'result')
    const tools = recordValue(result, 'tools')
    if (!isRecordArray(tools)) {
      throw new Error('tools/list result did not carry a tools array')
    }
    expect(tools.map((tool) => tool.name).sort()).toEqual(EXPECTED_TOOLS)
    for (const tool of tools) {
      const name = tool.name
      if (typeof name !== 'string') {
        throw new Error('tools/list returned a tool without a name')
      }
      // Every tool is protected by the server's single OAuth contract, so
      // each declares the same oauth2 scheme with the scope the existing
      // metadata advertises (scopes_supported: ['mcp']).
      expect(tool._meta, `${name} must carry tool _meta`).toEqual({
        securitySchemes: EXPECTED_SECURITY_SCHEMES,
      })
      // The existing safety annotation objects stay on the wire unchanged.
      const annotations = tool.annotations
      if (!isRecord(annotations)) {
        throw new Error(`${name} did not carry annotations`)
      }
      expect(annotations.readOnlyHint).toBeTypeOf('boolean')
      expect(annotations.destructiveHint).toBeTypeOf('boolean')
      expect(annotations.idempotentHint).toBeTypeOf('boolean')
      expect(annotations.openWorldHint).toBeTypeOf('boolean')
    }
  })

  it('surfaces the securitySchemes metadata to a real SDK client through listTools', async () => {
    const app = createTestApp()
    const client = new Client({ name: 'morsel-chatgpt-oauth-test', version: '1.0.0' })
    const transport = new StreamableHTTPClientTransport(new URL(PUBLIC_BASE_URL), {
      fetch: async (url: string | URL, init?: RequestInit): Promise<Response> =>
        app.fetch(new Request(url.toString(), init)),
      requestInit: { headers: { Authorization: `Bearer ${VALID_TOKEN}` } },
    })
    try {
      await client.connect(transport)
      const listed = await client.listTools()
      expect(listed.tools.map((tool) => tool.name).sort()).toEqual(EXPECTED_TOOLS)
      for (const tool of listed.tools) {
        expect(tool._meta, `${tool.name} must carry tool _meta`).toEqual({
          securitySchemes: EXPECTED_SECURITY_SCHEMES,
        })
      }
    } finally {
      await client.close()
    }
  })

  it('keeps the unauthenticated discovery challenge at the transport: /mcp 401 + WWW-Authenticate', async () => {
    const app = createTestApp()
    const response = await mcpPost(app, {
      jsonrpc: '2.0',
      id: 3,
      method: 'initialize',
      params: {},
    })
    expect(response.status).toBe(401)
    expect(response.headers.get('www-authenticate')).toBe(
      `Bearer resource_metadata="${RESOURCE_METADATA_URL}"`,
    )
    expect(response.headers.get('access-control-allow-origin')).toBe('*')
    expect(response.headers.get('access-control-expose-headers')).toBe('WWW-Authenticate')
    // The transport challenge body stays the safe JSON error, never a stack.
    const body = await response.text()
    expect(body).not.toContain('_meta')
    expect(body).not.toContain('www_authenticate')
    expect(body).toContain('a bearer token is required')
  })

  it('answers an auth-failing read-only tool call on an established session with the _meta["mcp/www_authenticate"] challenge result', async () => {
    const app = createTestApp()
    const sessionId = await initializeSession(app)

    const failing = await mcpPost(app, {
      jsonrpc: '2.0',
      id: 7,
      method: 'tools/call',
      params: { name: 'get_day', arguments: { date: '2026-08-25' } },
    }, { token: EXPIRED_TOKEN, sessionId })

    // ChatGPT re-auth contract: the failure is a JSON-RPC success response
    // (HTTP 200 result envelope), NOT a transport 401, so the client can
    // read the challenge and surface the account-linking UI.
    expect(failing.status).toBe(200)
    expect(failing.headers.get('access-control-allow-origin')).toBe('*')
    const failingBodyText = await failing.text()
    const document = parseResponseDocument(failingBodyText)
    expect(document.jsonrpc).toBe('2.0')
    expect(document.id).toBe(7)
    const result = recordValue(document, 'result')
    if (!isRecord(result)) {
      throw new Error('challenge response did not carry a result')
    }
    expect(result.isError).toBe(true)
    const content = recordValue(result, 'content')
    const text = isRecordArray(content) ? content[0]?.text : undefined
    if (typeof text !== 'string') {
      throw new Error('challenge result did not carry text content')
    }
    expect(text).toBe(AUTHENTICATION_REQUIRED_TEXT)
    const meta = recordValue(result, '_meta')
    if (!isRecord(meta)) {
      throw new Error('challenge result did not carry _meta')
    }
    expect(meta['mcp/www_authenticate']).toEqual([EXPECTED_CHALLENGE])

    // Hostile-proxy scan: the whole body must not leak backend/identity
    // details — no stack, provider, token value, email, or URL beyond the
    // canonical public metadata URL.
    for (const leaked of ['supabase', 'postgres', 'stack', 'test@example.com', EXPIRED_TOKEN, VALID_TOKEN]) {
      expect(failingBodyText.toLowerCase(), `body must not contain ${leaked}`).not.toContain(leaked)
    }

    // The session survives the challenge: the same session answers a normal
    // read-only call once a valid token is presented again.
    const recovered = await mcpPost(app, {
      jsonrpc: '2.0',
      id: 8,
      method: 'tools/call',
      params: { name: 'get_day', arguments: { date: '2026-08-25' } },
    }, { token: VALID_TOKEN, sessionId })
    expect(recovered.status).toBe(200)
    const recoveredDocument = parseResponseDocument(await recovered.text())
    const recoveredResult = recordValue(recoveredDocument, 'result')
    if (!isRecord(recoveredResult)) {
      throw new Error('recovered tool call did not carry a result')
    }
    expect(recoveredResult.isError).not.toBe(true)
    expect(recoveredResult._meta).toBeUndefined()
  })

  it('keeps fresh (session-less) auth-failing tool calls at the transport 401 challenge', async () => {
    const app = createTestApp()
    const failing = await mcpPost(app, {
      jsonrpc: '2.0',
      id: 9,
      method: 'tools/call',
      params: { name: 'get_day', arguments: { date: '2026-08-25' } },
    })
    expect(failing.status).toBe(401)
    expect(failing.headers.get('www-authenticate')).toBe(
      `Bearer resource_metadata="${RESOURCE_METADATA_URL}"`,
    )
    const body = await failing.text()
    expect(body).not.toContain('www_authenticate')
    expect(body).not.toContain(EXPIRED_TOKEN)
  })
})
