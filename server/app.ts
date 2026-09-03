import { WebStandardStreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js'
import { Hono, type Context } from 'hono'
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
  type OAuthConfigValue,
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
  /** Serve `/health` on the raw origin root instead of below `basePath`.
   * Default false keeps the historical route (below basePath on prefixed
   * deployments such as the Edge Function). A Fly single-process origin has
   * no gateway prefix to strip, so its health check must live at `/health`;
   * when this option is set the basePath-relative health route is NOT
   * registered (no `/mcp/health` duplicate). No-op without a basePath. */
  originHealth?: boolean
  /** Register the pre-#57 nested `/mcp` transport compatibility alias
   * (basePath-relative `/mcp`, i.e. runtime `/mcp/mcp` on prefixed
   * deployments). Default true keeps Edge Function behavior unchanged; a new
   * Fly origin has no legacy clients, so its entry point disables the alias
   * and never exposes a doubled `/mcp/mcp` path. */
  legacyTransportAlias?: boolean
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

function httpError(error: unknown, request?: Request, basePath?: string, publicBaseUrl?: OAuthConfigValue): Response {
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
    headers.set('www-authenticate', `Bearer resource_metadata="${protectedResourceMetadataUrl(request, basePath, publicBaseUrl)}"`)
    // Browser-based MCP clients cannot read the challenge unless CORS exposes it.
    headers.set('access-control-allow-origin', '*')
    headers.set('access-control-expose-headers', 'WWW-Authenticate')
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
  const oauthPublicBaseUrl = oauthOptions.publicBaseUrl
  const oauthAuthorizationEndpoint = oauthOptions.authorizationEndpoint
  const oauthService = oauthOptions.service ?? createSupabaseOAuthService({ anonKey: oauthAnonKey, supabaseUrl: oauthSupabaseUrl })
  const oauthGrantStore = oauthOptions.grantStore ?? createSupabaseOAuthGrantStore({ anonKey: oauthAnonKey, supabaseUrl: oauthSupabaseUrl })
  registerOAuthRoutes(routes, {
    basePath: options.basePath,
    grantStore: oauthGrantStore,
    authorizationEndpoint: oauthAuthorizationEndpoint,
    publicBaseUrl: oauthPublicBaseUrl,
    service: oauthService,
    signingKey: oauthOptions.signingKey ?? (() => environmentValue(['MORSEL_OAUTH_SIGNING_KEY'])),
    emailCodeRequests: oauthOptions.emailCodeRequests,
    now: oauthOptions.now,
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

  const healthHandler = (context: Context) => context.json({ ok: true })
  if (options.originHealth === true && routes !== app) {
    // Fly single-process origin: no gateway strips a function prefix, so the
    // health check is served at the raw origin root and the basePath-relative
    // route is omitted (no /mcp/health duplication).
    app.get('/health', healthHandler)
  } else {
    routes.get('/health', healthHandler)
  }

  // Only the preflight handshake: real MCP requests still go through the same
  // bearer-token authentication as before.
  const mcpPreflight = () => new Response(null, {
    status: 204,
    headers: {
      'access-control-allow-headers': 'authorization, content-type, mcp-session-id',
      'access-control-allow-methods': 'GET,POST,DELETE,OPTIONS',
      'access-control-allow-origin': '*',
      'access-control-max-age': '86400',
    },
  })

  const handleMcpTransport = async (context: Context): Promise<Response> => {
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
      return httpError(error, context.req.raw, options.basePath, oauthPublicBaseUrl)
    }
  }

  // Canonical MCP Streamable HTTP transport: the Edge Function ROOT. With the
  // Edge basePath ("/mcp"; the hosted gateway strips /functions/v1) the root
  // IS the basePath itself, so the canonical route is registered on the raw
  // app at the runtime prefix. Without a basePath (local Bun entrypoint) the
  // canonical route is the server root "/".
  const normalizedPrefix = options.basePath === undefined || options.basePath === '' || options.basePath === '/'
    ? ''
    : `/${options.basePath.replace(/^\/+|\/+$/g, '')}`
  const canonicalTransportPath = normalizedPrefix === '' ? '/' : normalizedPrefix
  app.options(canonicalTransportPath, mcpPreflight)
  app.all(canonicalTransportPath, handleMcpTransport)

  // Compatibility alias for clients provisioned with the pre-#57 nested
  // transport path (.../functions/v1/mcp/mcp): the basePath-relative "/mcp"
  // route below resolves to runtime /mcp/mcp on the Edge (publicly
  // /functions/v1/mcp/mcp) and to /mcp on the local root server. It serves
  // the same transport state and never advertises metadata of its own;
  // nothing user-facing links to it. Retire once provisioned clients migrate.
  // A fresh Fly origin has no such clients: its entry point disables the
  // alias so a doubled /mcp/mcp path never exists there.
  if (options.legacyTransportAlias !== false) {
    routes.options('/mcp', mcpPreflight)
    routes.all('/mcp', handleMcpTransport)
  }

  return routes
}
