import { createMorselApp, type MorselAppOptions } from './app.ts'
import { createSupabaseAuthenticator, type Authenticate, type AuthenticatedUser } from './auth.ts'
import type { Hono } from 'hono'
import type { MorselOAuthOptions } from './oauth.ts'
import type { MorselRepository } from './repository.ts'
import { createSupabaseRepository } from './supabase-repository.ts'

/**
 * Fly.io single-process entry point (issue #72).
 *
 * Supabase Edge Function isolates cannot hold the in-memory MCP session map
 * (issue #71), so the same portable Hono app runs as ONE long-lived Bun
 * process on Fly. Supabase stays the Auth/Postgres/RLS store, Resend/email
 * and all OAuth/OTP/PKCE/tool behavior stay unchanged, and the Vercel static
 * page stays the browser consent surface.
 *
 * Route shape: on Fly there is no `/functions/v1` gateway prefix to strip, so
 * the app is mounted with `basePath: '/mcp'` — exactly the public route shape
 * the Edge Function exposes after its gateway prefix — and the canonical MCP
 * transport is the origin's `/mcp` path. Unlike the Edge deployment there are
 * no pre-#57 clients, so the legacy nested `/mcp/mcp` compatibility alias is
 * disabled and the health check is served at the raw origin root (`/health`)
 * rather than below the prefix.
 *
 * Importing this module starts NO server; running it directly with Bun
 * (`import.meta.main`) serves on 0.0.0.0:PORT. Tests import the factory and
 * drive a real HTTP listener themselves, injecting only narrow stubs.
 */

/** The Fly entry point reads its configuration exclusively from these names. */
export const FLY_ENTRYPOINT_ENV = {
  supabaseUrl: 'SUPABASE_URL',
  anonKey: 'SUPABASE_ANON_KEY',
  signingKey: 'MORSEL_OAUTH_SIGNING_KEY',
  publicBaseUrl: 'MORSEL_PUBLIC_BASE_URL',
  authorizationEndpoint: 'MORSEL_OAUTH_AUTHORIZATION_ENDPOINT',
} as const

export type FlyEntrypointEnv = Record<string, string | undefined>

/** Narrow injection seams for tests; production wiring uses the Supabase factories. */
export interface FlyEntrypointDependencies {
  authenticate?: Authenticate
  repositoryFactory?: (user: AuthenticatedUser) => MorselRepository | Promise<MorselRepository>
  oauth?: Pick<MorselOAuthOptions, 'service' | 'grantStore'>
}

export interface FlyEntrypointOptions {
  /** Environment source; defaults to `process.env`. */
  env?: FlyEntrypointEnv
  deps?: FlyEntrypointDependencies
}

export interface FlyServerOptions extends FlyEntrypointOptions {
  /** Listen hostname; defaults to `0.0.0.0`. */
  hostname?: string
  /** Listen port; defaults to the resolved `PORT` (8080 when unset). */
  port?: number
}

/** The canonical client-facing MCP transport path on the Fly origin. */
export const FLY_BASE_PATH = '/mcp'

export interface FlyEntrypointConfig {
  basePath: typeof FLY_BASE_PATH
  publicBaseUrl: string
  authorizationEndpoint?: string
  port: number
}

function missing(name: string): Error {
  return new Error(`missing server configuration: ${name}`)
}

function invalid(name: string, detail: string): Error {
  return new Error(`${name} ${detail}`)
}

/** Required env value: nonblank and free of surrounding whitespace. */
function requiredEnvironmentValue(env: FlyEntrypointEnv, name: string): string {
  const raw = env[name]
  if (raw === undefined || raw.trim() === '') {
    throw missing(name)
  }
  if (raw !== raw.trim()) {
    throw invalid(name, 'must not contain surrounding whitespace')
  }
  return raw
}

function isLoopbackHostname(hostname: string): boolean {
  return hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '[::1]'
}

function hasControlOrWhitespace(value: string): boolean {
  for (const character of value) {
    const codePoint = character.codePointAt(0) ?? 0
    if (codePoint <= 0x20 || codePoint === 0x7f) {
      return true
    }
  }
  return false
}

/**
 * Fail-closed validation of the canonical public base URL
 * (`MORSEL_PUBLIC_BASE_URL`, e.g. `https://mcp.morselfood.app/mcp`; the
 * legacy `https://morsel-mcp.fly.dev/mcp` origin remains a valid value
 * during the transition).
 *
 * Metadata issuer/resource/endpoints derive from this URL on Fly (never from
 * the incoming Host header), so it must be an absolute URL whose path is
 * exactly the canonical transport path — no userinfo, query, fragment,
 * whitespace, trailing slash, or doubled/nested prefix such as `/mcp/mcp`.
 * Non-loopback hosts must use HTTPS.
 */
function normalizePublicBaseUrl(raw: string): string {
  if (raw !== raw.trim() || hasControlOrWhitespace(raw)) {
    throw invalid('MORSEL_PUBLIC_BASE_URL', 'must not contain whitespace or control characters')
  }
  let url: URL
  try {
    url = new URL(raw)
  } catch {
    throw invalid('MORSEL_PUBLIC_BASE_URL', 'must be an absolute http(s) URL')
  }
  if (url.username !== '' || url.password !== '') {
    throw invalid('MORSEL_PUBLIC_BASE_URL', 'must not include userinfo')
  }
  if (url.search !== '' || url.hash !== '') {
    throw invalid('MORSEL_PUBLIC_BASE_URL', 'must not include a query string or fragment')
  }
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && isLoopbackHostname(url.hostname))) {
    throw invalid('MORSEL_PUBLIC_BASE_URL', 'must be absolute HTTPS (http is allowed only for loopback hosts)')
  }
  if (url.pathname !== FLY_BASE_PATH) {
    throw invalid('MORSEL_PUBLIC_BASE_URL', 'path must be exactly /mcp (no trailing slash, no doubled prefix)')
  }
  return url.href
}

function validatePort(raw: string | undefined): number {
  const port = raw === undefined || raw.trim() === '' ? 8080 : Number(raw)
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error(`PORT must be an integer between 1 and 65535, got: ${raw ?? '(default)'}`)
  }
  return port
}

/** Resolve and validate the entry point environment into its app options. */
export function createFlyEntrypointApp(options: FlyEntrypointOptions = {}): { app: Hono; config: FlyEntrypointConfig } {
  const env = options.env ?? process.env
  const supabaseUrl = requiredEnvironmentValue(env, FLY_ENTRYPOINT_ENV.supabaseUrl)
  const anonKey = requiredEnvironmentValue(env, FLY_ENTRYPOINT_ENV.anonKey)
  const signingKey = requiredEnvironmentValue(env, FLY_ENTRYPOINT_ENV.signingKey)
  const publicBaseUrl = normalizePublicBaseUrl(requiredEnvironmentValue(env, FLY_ENTRYPOINT_ENV.publicBaseUrl))
  const rawAuthorizationEndpoint = env[FLY_ENTRYPOINT_ENV.authorizationEndpoint]
  // Optional: unset keeps the server-rendered consent fallback; when set it
  // names the Vercel consent page and registerOAuthRoutes validates it
  // fail-closed at app construction (startup) before anything is served.
  const authorizationEndpoint = rawAuthorizationEndpoint === undefined || rawAuthorizationEndpoint.trim() === ''
    ? undefined
    : rawAuthorizationEndpoint

  const dependencies = options.deps ?? {}
  const appOptions: MorselAppOptions = {
    // Mirror of the Edge Function wiring (supabase/functions/mcp/index.ts):
    // the Supabase authenticator and per-session repository validate the
    // caller's bearer token so RLS sees the caller on every request.
    authenticate: dependencies.authenticate ?? createSupabaseAuthenticator({ supabaseUrl, anonKey }),
    repositoryFactory: dependencies.repositoryFactory ?? (() => createSupabaseRepository(supabaseUrl, anonKey)),
    basePath: FLY_BASE_PATH,
    originHealth: true,
    legacyTransportAlias: false,
    oauth: {
      anonKey,
      supabaseUrl,
      publicBaseUrl,
      signingKey,
      ...(authorizationEndpoint === undefined ? {} : { authorizationEndpoint }),
      service: dependencies.oauth?.service,
      grantStore: dependencies.oauth?.grantStore,
    },
  }
  const app = createMorselApp(appOptions)
  return {
    app,
    config: {
      basePath: FLY_BASE_PATH,
      publicBaseUrl,
      ...(authorizationEndpoint === undefined ? {} : { authorizationEndpoint }),
      port: validatePort(env.PORT),
    },
  }
}

/**
 * Start the Bun HTTP server for the Fly entry point (one process, one
 * session map). Exported so the real-HTTP session regression can start the
 * SAME server wiring the entry point uses; `import.meta.main` boots it for
 * production (`bun server/fly-entrypoint.ts`).
 */
export function startFlyServer(options: FlyServerOptions = {}): ReturnType<typeof Bun.serve> {
  const { app, config } = createFlyEntrypointApp(options)
  const server = Bun.serve({
    hostname: options.hostname ?? '0.0.0.0',
    port: options.port ?? config.port,
    fetch: (request) => app.fetch(request),
  })
  return server
}

// Never log env values, credentials, or tokens: only the listen address.
if (import.meta.main) {
  const server = startFlyServer()
  const shutdown = (): void => {
    server.stop(true)
      .then(() => process.exit(0))
      .catch(() => process.exit(1))
  }
  process.once('SIGTERM', shutdown)
  process.once('SIGINT', shutdown)
}
