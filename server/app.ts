import { WebStandardStreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js'
import { Hono } from 'hono'
import { MorselError } from './errors.ts'
import { bearerToken, createSupabaseAuthenticator, type Authenticate, type AuthenticatedUser } from './auth.ts'
import { MorselService } from './service.ts'
import { createMcpServer } from './tools.ts'
import type { MorselRepository } from './repository.ts'
import { createSupabaseRepository } from './supabase-repository.ts'
import {
  createSupabaseOAuthGrantStore,
  createSupabaseOAuthService,
  protectedResourceMetadataUrl,
  registerOAuthRoutes,
  type MorselOAuthOptions,
} from './oauth.ts'

interface McpSession {
  userId: string
  repository: MorselRepository
  transport: WebStandardStreamableHTTPServerTransport
  lastUsedAt: number
}

const MAX_MCP_SESSIONS = 1_000
const MCP_SESSION_IDLE_TTL_MS = 24 * 60 * 60 * 1_000

export interface MorselAppOptions {
  authenticate?: Authenticate
  repositoryFactory?: (user: AuthenticatedUser) => MorselRepository | Promise<MorselRepository>
  now?: () => Date
  enableJsonResponse?: boolean
  basePath?: string
  oauth?: MorselOAuthOptions
}

function environmentValue(names: string[]): string {
  for (const name of names) {
    const value = process.env[name]
    if (value !== undefined && value.trim() !== '') {
      return value
    }
  }
  throw new MorselError('internal_error', `missing server configuration: ${names[0] ?? 'environment variable'}`)
}

function httpError(error: unknown, request?: Request, basePath?: string): Response {
  const morselError = error instanceof MorselError
    ? error
    : new MorselError('internal_error', 'request failed')
  const status = morselError.code === 'authentication_failed'
    ? 401
    : morselError.code === 'not_found'
      ? 404
      : morselError.code === 'invalid_input'
        ? 400
        : 500
  const headers = new Headers({ 'content-type': 'application/json' })
  if (morselError.code === 'authentication_failed' && request !== undefined) {
    headers.set('www-authenticate', `Bearer resource_metadata="${protectedResourceMetadataUrl(request, basePath)}"`)
  }
  return new Response(JSON.stringify({ error: morselError.publicMessage }), {
    status,
    headers,
  })
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

interface NormalizedMessage {
  value: unknown
  changed: boolean
}

function normalizeToolCallArguments(value: unknown): NormalizedMessage {
  if (Array.isArray(value)) {
    let changed = false
    const normalized = value.map((entry) => {
      const result = normalizeToolCallArguments(entry)
      changed = changed || result.changed
      return result.value
    })
    return { value: normalized, changed }
  }
  if (!isRecord(value) || value.method !== 'tools/call' || !isRecord(value.params) || Object.hasOwn(value.params, 'arguments')) {
    return { value, changed: false }
  }
  return {
    value: { ...value, params: { ...value.params, arguments: {} } },
    changed: true,
  }
}

async function requestWithDefaultToolArguments(request: Request): Promise<Request> {
  // The SDK validates object schemas before invoking tool callbacks. MCP makes
  // `arguments` optional, so fill the protocol default at this HTTP boundary.
  if (request.method !== 'POST' || !(request.headers.get('content-type') ?? '').toLowerCase().includes('application/json')) {
    return request
  }
  const body = await request.clone().text()
  if (body.trim() === '') {
    return request
  }
  let parsed: unknown
  try {
    parsed = JSON.parse(body)
  } catch {
    return request
  }
  const normalized = normalizeToolCallArguments(parsed)
  if (!normalized.changed) {
    return request
  }
  const normalizedBody = JSON.stringify(normalized.value)
  const headers = new Headers(request.headers)
  headers.delete('content-length')
  return new Request(request, { body: normalizedBody, headers })
}

function defaultOptions(): Required<Pick<MorselAppOptions, 'authenticate' | 'repositoryFactory'>> {
  const supabaseUrl = environmentValue(['SUPABASE_URL', 'NEXT_PUBLIC_SUPABASE_URL'])
  const anonKey = environmentValue(['SUPABASE_ANON_KEY', 'SUPABASE_PUBLISHABLE_KEY', 'NEXT_PUBLIC_SUPABASE_ANON_KEY'])
  return {
    authenticate: createSupabaseAuthenticator({ supabaseUrl, anonKey }),
    repositoryFactory: () => createSupabaseRepository(supabaseUrl, anonKey),
  }
}

export function createMorselApp(options: MorselAppOptions = {}): Hono {
  const defaults = options.authenticate === undefined || options.repositoryFactory === undefined ? defaultOptions() : undefined
  const authenticate = options.authenticate ?? defaults?.authenticate
  const repositoryFactory = options.repositoryFactory ?? defaults?.repositoryFactory
  if (authenticate === undefined || repositoryFactory === undefined) {
    throw new MorselError('internal_error', 'server authentication and repository are not configured')
  }

  const sessions = new Map<string, McpSession>()
  const app = new Hono()
  const routes = options.basePath === undefined ? app : app.basePath(options.basePath)
  const oauthOptions = options.oauth ?? {}
  const oauthAnonKey = oauthOptions.anonKey ?? (() => environmentValue(['SUPABASE_ANON_KEY', 'SUPABASE_PUBLISHABLE_KEY', 'NEXT_PUBLIC_SUPABASE_ANON_KEY']))
  const oauthSupabaseUrl = oauthOptions.supabaseUrl ?? (() => environmentValue(['SUPABASE_URL', 'NEXT_PUBLIC_SUPABASE_URL']))
  const oauthService = oauthOptions.service ?? createSupabaseOAuthService({ anonKey: oauthAnonKey, supabaseUrl: oauthSupabaseUrl })
  const oauthGrantStore = oauthOptions.grantStore ?? createSupabaseOAuthGrantStore({ anonKey: oauthAnonKey, supabaseUrl: oauthSupabaseUrl })
  registerOAuthRoutes(routes, {
    basePath: options.basePath,
    grantStore: oauthGrantStore,
    service: oauthService,
    signingKey: oauthOptions.signingKey ?? (() => environmentValue(['MORSEL_OAUTH_SIGNING_KEY'])),
  })

  const closeSession = (sessionId: string): void => {
    const session = sessions.get(sessionId)
    sessions.delete(sessionId)
    if (session !== undefined) {
      void session.transport.close().catch(() => undefined)
    }
  }

  const pruneSessions = (now: number): void => {
    for (const [sessionId, session] of sessions.entries()) {
      if (now - session.lastUsedAt > MCP_SESSION_IDLE_TTL_MS) {
        closeSession(sessionId)
      }
    }
    while (sessions.size >= MAX_MCP_SESSIONS) {
      let oldestId: string | undefined
      let oldestTimestamp = Number.POSITIVE_INFINITY
      for (const [sessionId, session] of sessions.entries()) {
        if (session.lastUsedAt < oldestTimestamp) {
          oldestId = sessionId
          oldestTimestamp = session.lastUsedAt
        }
      }
      if (oldestId === undefined) {
        return
      }
      closeSession(oldestId)
    }
  }

  routes.get('/health', (context) => context.json({ ok: true }))

  routes.all('/mcp', async (context) => {
    try {
      pruneSessions(Date.now())
      const token = bearerToken(context.req.header('authorization'))
      const user = await authenticate(token)
      const sessionId = context.req.header('mcp-session-id')
      if (sessionId !== undefined) {
        const session = sessions.get(sessionId)
        if (session === undefined) {
          return new Response(JSON.stringify({ error: 'MCP session not found' }), {
            status: 404,
            headers: { 'content-type': 'application/json' },
          })
        }
        if (session.userId !== user.userId) {
          return new Response(JSON.stringify({ error: 'MCP session belongs to another user' }), {
            status: 403,
            headers: { 'content-type': 'application/json' },
          })
        }
        return await session.repository.withAccessToken(user.token, async () => {
          await session.repository.ensureUser(user.userId, user.email)
          session.lastUsedAt = Date.now()
          return session.transport.handleRequest(await requestWithDefaultToolArguments(context.req.raw), { authInfo: user.authInfo })
        })
      }

      if (context.req.method !== 'POST') {
        return new Response(JSON.stringify({ error: 'an MCP session is required' }), {
          status: 400,
          headers: { 'content-type': 'application/json' },
        })
      }

      const repository = await repositoryFactory(user)
      const service = new MorselService({ repository, userId: user.userId, now: options.now })
      const server = createMcpServer(service)
      const transport = new WebStandardStreamableHTTPServerTransport({
        sessionIdGenerator: () => crypto.randomUUID(),
        enableJsonResponse: options.enableJsonResponse ?? false,
        onsessioninitialized: (initializedSessionId) => {
          pruneSessions(Date.now())
          session.lastUsedAt = Date.now()
          sessions.set(initializedSessionId, session)
        },
        onsessionclosed: (closedSessionId) => {
          sessions.delete(closedSessionId)
        },
      })
      const session: McpSession = { userId: user.userId, repository, transport, lastUsedAt: Date.now() }
      await server.connect(transport)
      return await repository.withAccessToken(user.token, async () => {
        await repository.ensureUser(user.userId, user.email)
        return transport.handleRequest(await requestWithDefaultToolArguments(context.req.raw), { authInfo: user.authInfo })
      })
    } catch (error) {
      return httpError(error, context.req.raw, options.basePath)
    }
  })

  return routes
}
