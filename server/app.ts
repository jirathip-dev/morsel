import { WebStandardStreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js'
import { Hono } from 'hono'
import { MorselError } from './errors.js'
import { bearerToken, createSupabaseAuthenticator, type Authenticate, type AuthenticatedUser } from './auth.js'
import { MorselService } from './service.js'
import { createMcpServer } from './tools.js'
import type { MorselRepository } from './repository.js'
import { createSupabaseRepository } from './supabase-repository.js'

interface McpSession {
  userId: string
  transport: WebStandardStreamableHTTPServerTransport
}

export interface MorselAppOptions {
  authenticate?: Authenticate
  repositoryFactory?: (user: AuthenticatedUser) => MorselRepository | Promise<MorselRepository>
  now?: () => Date
  enableJsonResponse?: boolean
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

function httpError(error: unknown): Response {
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
  return new Response(JSON.stringify({ error: morselError.publicMessage }), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

function defaultOptions(): Required<Pick<MorselAppOptions, 'authenticate' | 'repositoryFactory'>> {
  const supabaseUrl = environmentValue(['SUPABASE_URL', 'NEXT_PUBLIC_SUPABASE_URL'])
  const anonKey = environmentValue(['SUPABASE_ANON_KEY', 'SUPABASE_PUBLISHABLE_KEY', 'NEXT_PUBLIC_SUPABASE_ANON_KEY'])
  return {
    authenticate: createSupabaseAuthenticator({ supabaseUrl, anonKey }),
    repositoryFactory: (user) => createSupabaseRepository(supabaseUrl, user.token, anonKey),
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

  app.get('/health', (context) => context.json({ ok: true }))

  app.all('/mcp', async (context) => {
    try {
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
        return await session.transport.handleRequest(context.req.raw, { authInfo: user.authInfo })
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
          sessions.set(initializedSessionId, session)
        },
        onsessionclosed: (closedSessionId) => {
          sessions.delete(closedSessionId)
        },
      })
      const session: McpSession = { userId: user.userId, transport }
      await server.connect(transport)
      return await transport.handleRequest(context.req.raw, { authInfo: user.authInfo })
    } catch (error) {
      return httpError(error)
    }
  })

  return app
}
