import { createClient } from '@supabase/supabase-js'
import type { Hono } from 'hono'
import type { Database } from './supabase-types.ts'

export type OAuthConfigValue = string | (() => string)

export interface OAuthUserSession {
  userId: string
  email: string
  accessToken: string
  refreshToken?: string
  expiresIn: number
}

export interface OAuthIdentityService {
  /** Request an email one-time code for an existing account; never creates users. */
  requestCode(email: string): Promise<void>
  /** Verify a single-use email one-time code and return the account session. */
  verifyCode(email: string, code: string): Promise<OAuthUserSession>
  refresh(refreshToken: string): Promise<OAuthUserSession>
}

export interface EmailCodeRequestPolicy {
  /** Maximum code requests allowed per email per window. */
  maxRequests: number
  /** Fixed window length in seconds. */
  windowSeconds: number
}

export interface OAuthAuthorizationGrant {
  codeHash: string
  clientId: string
  redirectUri: string
  codeChallenge: string
  userId: string
  refreshToken: string
  scopes: string[]
  resource?: string
  expiresAt: number
}

export interface OAuthGrantStore {
  create(grant: OAuthAuthorizationGrant, accessToken: string): Promise<void>
  claim(codeHash: string, clientId: string): Promise<OAuthAuthorizationGrant | undefined>
}

export interface MorselOAuthOptions {
  signingKey?: OAuthConfigValue
  service?: OAuthIdentityService
  grantStore?: OAuthGrantStore
  supabaseUrl?: OAuthConfigValue
  anonKey?: OAuthConfigValue
  publicBaseUrl?: OAuthConfigValue
  authorizationEndpoint?: OAuthConfigValue
  /** Per-email code-request rate limit (default: 5 per 10 minutes). */
  emailCodeRequests?: EmailCodeRequestPolicy
  /** Injectable clock (milliseconds since the epoch) for tests. */
  now?: () => number
}

interface OAuthRouteOptions {
  basePath?: string
  grantStore: OAuthGrantStore
  signingKey: OAuthConfigValue
  service: OAuthIdentityService
  publicBaseUrl?: OAuthConfigValue
  authorizationEndpoint?: OAuthConfigValue
  emailCodeRequests?: EmailCodeRequestPolicy
  now?: () => number
}

interface OAuthAuthorizationRouteOptions extends OAuthRouteOptions {
  /** Resolved external static authorization page URL, when configured. */
  authorizationPage?: string
  limiter: EmailCodeRateLimiter
  now: () => number
}

/** Rate limiter keyed on a confidential digest of the email address. */
interface EmailCodeRateLimiter {
  /** Record one code request; returns false when the window is exhausted. */
  allow(key: string): boolean
}

type HeaderValues = Record<string, string>

interface ClientRegistrationPayload {
  typ: 'client'
  redirectUris: string[]
  clientName?: string
  issuedAt: number
}

interface AuthorizationCodePayload {
  typ: 'authorization_code'
  clientId: string
  expiresAt: number
}

interface RefreshTokenPayload {
  typ: 'refresh_token'
  clientId: string
  userId: string
  refreshToken: string
  scopes: string[]
  resource?: string
  expiresAt: number
}

interface OtpTransactionPayload {
  typ: 'otp_transaction'
  email: string
  clientId: string
  redirectUri: string
  codeChallenge: string
  scope: string
  resource?: string
  expiresAt: number
}

// Email one-time codes are exactly six digits. The sealed transaction
// envelope carries the request between the two steps; its ten-minute lifetime
// bounds the code-entry window and keeps failed attempts short-lived.
const OTP_CODE_SHAPE = /^[0-9]{6}$/
const OTP_TRANSACTION_TTL_SECONDS = 10 * 60
const DEFAULT_EMAIL_CODE_REQUEST_POLICY: EmailCodeRequestPolicy = { maxRequests: 5, windowSeconds: 600 }

class OAuthProtocolError extends Error {
  readonly errorCode: string
  readonly status: number

  constructor(errorCode: string, message: string, status = 400) {
    super(message)
    this.name = 'OAuthProtocolError'
    this.errorCode = errorCode
    this.status = status
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((entry) => typeof entry === 'string')
}

function resolveConfigValue(value: OAuthConfigValue, name: string): string {
  const resolved = typeof value === 'function' ? value() : value
  if (resolved.trim() === '') {
    throw new OAuthProtocolError('server_error', `${name} is not configured`, 500)
  }
  return resolved
}

function encodeBase64Url(value: Uint8Array): string {
  let binary = ''
  for (const byte of value) {
    binary += String.fromCharCode(byte)
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '')
}

function decodeBase64Url(value: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new Error('invalid base64url value')
  }
  const padded = value.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - value.length % 4) % 4)
  const binary = atob(padded)
  return Uint8Array.from(binary, (character) => character.charCodeAt(0))
}

function arrayBuffer(value: Uint8Array): ArrayBuffer {
  const buffer = new ArrayBuffer(value.byteLength)
  new Uint8Array(buffer).set(value)
  return buffer
}

async function hmac(secret: string, value: string, usage: 'sign' | 'verify'): Promise<Uint8Array | boolean> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    [usage],
  )
  if (usage === 'sign') {
    return new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(value)))
  }
  const separator = value.lastIndexOf('.')
  if (separator < 1) {
    return false
  }
  const signedValue = value.slice(0, separator)
  let signature: Uint8Array
  try {
    signature = decodeBase64Url(value.slice(separator + 1))
  } catch {
    return false
  }
  return crypto.subtle.verify('HMAC', key, arrayBuffer(signature), new TextEncoder().encode(signedValue))
}

async function signPayload(secret: string, payload: Record<string, unknown>): Promise<string> {
  const encoded = encodeBase64Url(new TextEncoder().encode(JSON.stringify(payload)))
  const signature = await hmac(secret, encoded, 'sign')
  if (typeof signature === 'boolean') {
    throw new Error('HMAC signing failed')
  }
  return `${encoded}.${encodeBase64Url(signature)}`
}

async function hashValue(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))
  return encodeBase64Url(new Uint8Array(digest))
}

async function verifyPayload(secret: string, value: string): Promise<Record<string, unknown>> {
  const separator = value.lastIndexOf('.')
  if (separator < 1 || !(await hmac(secret, value, 'verify'))) {
    throw new OAuthProtocolError('invalid_grant', 'token is invalid')
  }
  let decoded: unknown
  try {
    decoded = JSON.parse(new TextDecoder().decode(decodeBase64Url(value.slice(0, separator))))
  } catch {
    throw new OAuthProtocolError('invalid_grant', 'token is invalid')
  }
  if (!isRecord(decoded)) {
    throw new OAuthProtocolError('invalid_grant', 'token is invalid')
  }
  return decoded
}

async function encryptionKey(secret: string): Promise<CryptoKey> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(secret))
  return crypto.subtle.importKey('raw', digest, 'AES-GCM', false, ['encrypt', 'decrypt'])
}

async function sealPayload(secret: string, payload: Record<string, unknown>): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv },
    await encryptionKey(secret),
    new TextEncoder().encode(JSON.stringify(payload)),
  ))
  const body = new Uint8Array(iv.length + ciphertext.length)
  body.set(iv)
  body.set(ciphertext, iv.length)
  const encodedBody = encodeBase64Url(body)
  const signature = await hmac(secret, encodedBody, 'sign')
  if (typeof signature === 'boolean') {
    throw new Error('HMAC signing failed')
  }
  return `${encodedBody}.${encodeBase64Url(signature)}`
}

async function openPayload(secret: string, value: string): Promise<Record<string, unknown>> {
  const separator = value.lastIndexOf('.')
  if (separator < 1 || !(await hmac(secret, value, 'verify'))) {
    throw new OAuthProtocolError('invalid_grant', 'token is invalid')
  }
  let decoded: Uint8Array
  try {
    decoded = decodeBase64Url(value.slice(0, separator))
  } catch {
    throw new OAuthProtocolError('invalid_grant', 'token is invalid')
  }
  if (decoded.length <= 12) {
    throw new OAuthProtocolError('invalid_grant', 'token is invalid')
  }
  try {
    const plaintext = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: decoded.slice(0, 12) },
      await encryptionKey(secret),
      decoded.slice(12),
    )
    const parsed: unknown = JSON.parse(new TextDecoder().decode(plaintext))
    if (!isRecord(parsed)) {
      throw new Error('payload is not an object')
    }
    return parsed
  } catch {
    throw new OAuthProtocolError('invalid_grant', 'token is invalid')
  }
}

function oauthResponse(body: Record<string, unknown>, status = 200, headers?: HeaderValues): Response {
  const responseHeaders = new Headers({
    'cache-control': 'no-store',
    'content-type': 'application/json',
    ...headers,
  })
  return new Response(JSON.stringify(body), { status, headers: responseHeaders })
}

function oauthErrorResponse(error: unknown): Response {
  const protocolError = error instanceof OAuthProtocolError
    ? error
    : new OAuthProtocolError('server_error', 'authorization server error', 500)
  const headers: HeaderValues = {
    ...corsHeaders(),
    ...(protocolError.errorCode === 'invalid_client' ? { 'www-authenticate': 'Basic realm="oauth"' } : {}),
  }
  return oauthResponse({ error: protocolError.errorCode, error_description: protocolError.message }, protocolError.status, headers)
}

// Browser-facing OAuth responses (Claude's connector flow fetches these from
// web contexts) must stay CORS-readable, and the MCP 401 challenge carried on
// www-authenticate must not be filtered out by browser CORS response rules.
function corsHeaders(): HeaderValues {
  return {
    'access-control-allow-headers': 'content-type',
    'access-control-allow-methods': 'GET,POST,OPTIONS',
    'access-control-allow-origin': '*',
    'access-control-expose-headers': 'WWW-Authenticate',
  }
}

function normalizedBasePath(basePath?: string): string {
  if (basePath === undefined || basePath === '' || basePath === '/') {
    return ''
  }
  return `/${basePath.replace(/^\/+|\/+$/g, '')}`
}

// An explicit public base URL is authoritative for metadata and challenge URLs
// so the Edge entry point can advertise callable paths even when the gateway
// strips /functions/v1 and forwards no prefix. It is optional: when unset the
// request/forwarded-header derivation below is unchanged.
function resolvePublicBaseUrl(publicBaseUrl: OAuthConfigValue | undefined): URL | undefined {
  if (publicBaseUrl === undefined) {
    return undefined
  }
  const raw = typeof publicBaseUrl === 'function' ? publicBaseUrl() : publicBaseUrl
  if (raw.trim() === '') {
    throw new OAuthProtocolError('server_error', 'public base URL is not configured', 500)
  }
  let url: URL
  try {
    url = new URL(raw)
  } catch {
    throw new OAuthProtocolError('server_error', 'public base URL is not a valid URL', 500)
  }
  if ((url.protocol !== 'http:' && url.protocol !== 'https:') || url.hostname === '' || url.hash !== '') {
    throw new OAuthProtocolError('server_error', 'public base URL must be an absolute http(s) URL without a fragment', 500)
  }
  url.search = ''
  url.hash = ''
  url.pathname = url.pathname.replace(/\/+$/g, '')
  return url
}

function resolveAuthorizationEndpoint(authorizationEndpoint: OAuthConfigValue | undefined): string | undefined {
  if (authorizationEndpoint === undefined) {
    return undefined
  }
  const raw = typeof authorizationEndpoint === 'function' ? authorizationEndpoint() : authorizationEndpoint
  let hasAsciiControlOrWhitespace = false
  for (const character of raw) {
    const codePoint = character.codePointAt(0) ?? 0
    if (codePoint <= 0x20 || codePoint === 0x7f) {
      hasAsciiControlOrWhitespace = true
      break
    }
  }
  if (
    raw.trim() === '' ||
    raw !== raw.trim() ||
    hasAsciiControlOrWhitespace ||
    raw.includes('\\') ||
    raw.includes('?') ||
    raw.includes('#')
  ) {
    throw new OAuthProtocolError('server_error', 'authorization endpoint must be an absolute HTTPS URL with a stable path', 500)
  }
  let url: URL
  try {
    url = new URL(raw)
  } catch {
    throw new OAuthProtocolError('server_error', 'authorization endpoint must be an absolute HTTPS URL with a stable path', 500)
  }
  const authorityStart = raw.indexOf('://') + 3
  const authorityEnd = raw.indexOf('/', authorityStart)
  const authority = raw.slice(authorityStart, authorityEnd === -1 ? raw.length : authorityEnd)
  if (url.href !== raw || url.protocol !== 'https:' || url.hostname === '' || authority.includes('@') || url.username !== '' || url.password !== '' || url.pathname === '/') {
    throw new OAuthProtocolError('server_error', 'authorization endpoint must be an absolute HTTPS URL with a stable path', 500)
  }
  return url.href
}

function firstHeaderValue(request: Request, name: string): string | undefined {
  const value = request.headers.get(name)?.split(',')[0]?.trim()
  return value === undefined || value === '' ? undefined : value
}

function applyForwardedOrigin(request: Request, url: URL): void {
  const forwardedProtocol = firstHeaderValue(request, 'x-forwarded-proto')
  if (forwardedProtocol === 'http' || forwardedProtocol === 'https') {
    url.protocol = `${forwardedProtocol}:`
  }
  const forwardedHost = firstHeaderValue(request, 'x-forwarded-host')
  if (forwardedHost === undefined) {
    return
  }
  try {
    const hostUrl = new URL(`${url.protocol}//${forwardedHost}`)
    url.hostname = hostUrl.hostname
    const forwardedPort = firstHeaderValue(request, 'x-forwarded-port')
    url.port = hostUrl.port
    if (url.port === '' && forwardedPort !== undefined && /^\d{1,5}$/.test(forwardedPort)) {
      const port = Number(forwardedPort)
      if (port <= 65_535 && !((url.protocol === 'http:' && port === 80) || (url.protocol === 'https:' && port === 443))) {
        url.port = forwardedPort
      }
    }
  } catch {
    return
  }
}

function applyForwardedPathPrefix(request: Request, url: URL): void {
  const forwardedPrefix = firstHeaderValue(request, 'x-forwarded-prefix')
  if (forwardedPrefix === undefined) {
    return
  }
  const prefix = `/${forwardedPrefix.replace(/^\/+|\/+$/g, '')}`
  if (prefix === '/' || url.pathname === prefix || url.pathname.startsWith(`${prefix}/`)) {
    return
  }
  url.pathname = `${prefix}${url.pathname.startsWith('/') ? '' : '/'}${url.pathname}`
}

export function oauthBaseUrl(request: Request, basePath?: string, publicBaseUrl?: OAuthConfigValue): URL {
  const publicUrl = resolvePublicBaseUrl(publicBaseUrl)
  if (publicUrl !== undefined) {
    return publicUrl
  }
  const url = new URL(request.url)
  applyForwardedOrigin(request, url)
  const configuredPath = normalizedBasePath(basePath)
  if (configuredPath === '') {
    url.pathname = '/'
    url.search = ''
    url.hash = ''
    applyForwardedPathPrefix(request, url)
    return url
  }
  const index = url.pathname.indexOf(configuredPath)
  url.pathname = index >= 0
    ? url.pathname.slice(0, index + configuredPath.length)
    : configuredPath
  url.search = ''
  url.hash = ''
  applyForwardedPathPrefix(request, url)
  return url
}

function appendPath(baseUrl: URL, path: string): URL {
  const url = new URL(baseUrl.href)
  const basePath = url.pathname.replace(/\/+$/g, '')
  url.pathname = `${basePath}/${path}`
  url.search = ''
  url.hash = ''
  return url
}

function baseUrlString(baseUrl: URL): string {
  return baseUrl.pathname === '/' ? baseUrl.origin : baseUrl.href.replace(/\/+$/g, '')
}

export function protectedResourceMetadataUrl(request: Request, basePath?: string, publicBaseUrl?: OAuthConfigValue): string {
  return appendPath(oauthBaseUrl(request, basePath, publicBaseUrl), '.well-known/oauth-protected-resource/mcp').href
}

function authorizationServerMetadata(
  request: Request,
  basePath: string | undefined,
  publicBaseUrl: OAuthConfigValue | undefined,
  authorizationEndpoint: string | undefined,
): Record<string, unknown> {
  const baseUrl = oauthBaseUrl(request, basePath, publicBaseUrl)
  return {
    issuer: baseUrlString(baseUrl),
    authorization_endpoint: authorizationEndpoint ?? appendPath(baseUrl, 'authorize').href,
    token_endpoint: appendPath(baseUrl, 'token').href,
    registration_endpoint: appendPath(baseUrl, 'register').href,
    response_types_supported: ['code'],
    code_challenge_methods_supported: ['S256'],
    token_endpoint_auth_methods_supported: ['none'],
    grant_types_supported: ['authorization_code', 'refresh_token'],
    scopes_supported: ['mcp'],
  }
}

function protectedResourceMetadata(request: Request, basePath?: string, publicBaseUrl?: OAuthConfigValue): Record<string, unknown> {
  const baseUrl = oauthBaseUrl(request, basePath, publicBaseUrl)
  return {
    // The canonical MCP resource is the transport URL itself: the function
    // root (…/functions/v1/mcp), not the legacy nested /mcp/mcp path.
    resource: baseUrlString(baseUrl),
    authorization_servers: [baseUrlString(baseUrl)],
    scopes_supported: ['mcp'],
    resource_name: 'Morsel MCP',
  }
}

function redirectUriMatches(requested: string, registered: string): boolean {
  if (requested === registered) {
    return true
  }
  let requestedUrl: URL
  let registeredUrl: URL
  try {
    requestedUrl = new URL(requested)
    registeredUrl = new URL(registered)
  } catch {
    return false
  }
  const loopbackHosts = new Set(['localhost', '127.0.0.1', '[::1]'])
  return loopbackHosts.has(requestedUrl.hostname)
    && requestedUrl.hostname === registeredUrl.hostname
    && loopbackHosts.has(registeredUrl.hostname)
    && requestedUrl.protocol === registeredUrl.protocol
    && requestedUrl.pathname === registeredUrl.pathname
    && requestedUrl.search === registeredUrl.search
    && requestedUrl.hash === ''
    && registeredUrl.hash === ''
}

function validRedirectUri(value: string): boolean {
  try {
    const url = new URL(value)
    if (url.hash !== '') {
      return false
    }
    return url.protocol === 'https:'
      || (url.protocol === 'http:' && new Set(['localhost', '127.0.0.1', '[::1]']).has(url.hostname))
  } catch {
    return false
  }
}

async function clientFromId(secret: string, clientId: string): Promise<ClientRegistrationPayload> {
  let payload: Record<string, unknown>
  try {
    payload = await verifyPayload(secret, clientId)
  } catch {
    throw new OAuthProtocolError('invalid_client', 'client_id is invalid', 401)
  }
  const redirectUris = payload.redirectUris
  if (payload.typ !== 'client' || !isStringArray(redirectUris) || redirectUris.length === 0
    || redirectUris.some((uri) => !validRedirectUri(uri))) {
    throw new OAuthProtocolError('invalid_client', 'client_id is invalid', 401)
  }
  return {
    typ: 'client',
    redirectUris,
    clientName: typeof payload.clientName === 'string' ? payload.clientName : undefined,
    issuedAt: typeof payload.issuedAt === 'number' ? payload.issuedAt : 0,
  }
}

async function requestParameters(request: Request): Promise<URLSearchParams> {
  const params = new URLSearchParams(new URL(request.url).search)
  if (request.method === 'GET') {
    return params
  }
  const body = await request.text()
  if (body.trim() === '') {
    return params
  }
  const contentType = (request.headers.get('content-type') ?? '').toLowerCase()
  if (contentType.includes('application/json')) {
    let parsed: unknown
    try {
      parsed = JSON.parse(body)
    } catch {
      throw new OAuthProtocolError('invalid_request', 'request body is not valid JSON')
    }
    if (!isRecord(parsed)) {
      throw new OAuthProtocolError('invalid_request', 'request body must be an object')
    }
    for (const [name, value] of Object.entries(parsed)) {
      if (typeof value === 'string') {
        params.set(name, value)
      }
    }
    return params
  }
  const form = new URLSearchParams(body)
  for (const [name, value] of form.entries()) {
    params.set(name, value)
  }
  return params
}

// Fields that must never be echoed back into a rendered form or carried
// through a page redirect: the email lives only inside the sealed transaction
// envelope, the one-time code is typed per request, and passwords no longer
// exist. Everything else in the OAuth request survives both steps untouched.
const CARRY_EXCLUDED_FIELDS = new Set(['code', 'email', 'password', 'transaction'])

function formActionUrl(request: Request, publicBaseUrl: OAuthConfigValue | undefined): string {
  // When an explicit public base is configured the form must post to the
  // callable public authorization URL (the gateway strips /functions/v1 from
  // the raw request pathname). Local/default behavior stays on the request
  // pathname so the browser posts back to the same route it was served from.
  const publicUrl = resolvePublicBaseUrl(publicBaseUrl)
  return publicUrl === undefined
    ? new URL(request.url).pathname
    : appendPath(publicUrl, 'authorize').href
}

function formPage(body: string): Response {
  return new Response(body, {
    status: 200,
    headers: {
      'access-control-allow-origin': '*',
      'cache-control': 'no-store',
      'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'",
      'content-type': 'text/html; charset=utf-8',
    },
  })
}

function carriedFieldInputs(params: URLSearchParams): string {
  return Array.from(params.entries())
    .filter(([name]) => !CARRY_EXCLUDED_FIELDS.has(name))
    .map(([name, value]) => `<input type="hidden" name="${htmlEscape(name)}" value="${htmlEscape(value)}">`)
    .join('')
}

// Step 1: accept the email on the Morsel account only. The OAuth request was
// fully validated before this page is reachable, and every non-credential
// parameter is preserved as a hidden field for the code step.
function authorizationForm(request: Request, params: URLSearchParams, message?: string, publicBaseUrl?: OAuthConfigValue): Response {
  const notice = message === undefined ? '' : `<p role="alert">${htmlEscape(message)}</p>`
  const body = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Connect to Morsel</title></head><body><main><h1>Connect to Morsel</h1><p>An MCP client is requesting access to your Morsel account. Enter the email on your Morsel account and a one-time code will be emailed to you.</p>${notice}<form method="post" action="${htmlEscape(formActionUrl(request, publicBaseUrl))}"><label>Email <input name="email" type="email" autocomplete="username" required></label><button type="submit">Send code</button>${carriedFieldInputs(params)}</form></main></body></html>`
  return formPage(body)
}

// Step 2: accept exactly the six-digit code plus the protected transaction
// envelope. Every OAuth parameter remains intact as a hidden field so a
// failed attempt can be retried without losing the request.
function codeEntryForm(request: Request, params: URLSearchParams, transaction: string, message?: string, publicBaseUrl?: OAuthConfigValue): Response {
  const notice = message === undefined ? '' : `<p role="alert">${htmlEscape(message)}</p>`
  const body = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Connect to Morsel</title></head><body><main><h1>Connect to Morsel</h1><p>Enter the 6-digit code that was emailed to you. The code is single-use and expires.</p>${notice}<form method="post" action="${htmlEscape(formActionUrl(request, publicBaseUrl))}"><label>Code <input name="code" type="text" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" autocomplete="one-time-code" required></label><button type="submit">Verify and continue</button><input type="hidden" name="transaction" value="${htmlEscape(transaction)}">${carriedFieldInputs(params)}</form></main></body></html>`
  return formPage(body)
}

// When an external static page is the configured authorization endpoint every
// /authorize form response is a 302 back to that page: the static no-JS skin
// renders both stages from URL state. Without it (local server-rendered
// fallback) the stages are HTML form pages on this route. The chosen response
// is identical for existing and unknown accounts so existence is not revealed.
function externalPageRedirect(authorizationPage: string, params: URLSearchParams, transaction?: string, fragment?: string): Response {
  const url = new URL(authorizationPage)
  for (const [name, value] of params.entries()) {
    if (!CARRY_EXCLUDED_FIELDS.has(name)) {
      url.searchParams.append(name, value)
    }
  }
  if (transaction !== undefined) {
    url.searchParams.set('transaction', transaction)
  }
  if (fragment !== undefined) {
    url.hash = fragment
  }
  return new Response(null, {
    status: 302,
    headers: { 'cache-control': 'no-store', location: url.href },
  })
}

function emailStageResponse(request: Request, params: URLSearchParams, message: string | undefined, options: OAuthAuthorizationRouteOptions): Response {
  if (options.authorizationPage !== undefined) {
    return externalPageRedirect(options.authorizationPage, params)
  }
  return authorizationForm(request, params, message, options.publicBaseUrl)
}

function codeStageResponse(request: Request, params: URLSearchParams, transaction: string, message: string | undefined, options: OAuthAuthorizationRouteOptions): Response {
  if (options.authorizationPage !== undefined) {
    return externalPageRedirect(options.authorizationPage, params, transaction, 'code-entry')
  }
  return codeEntryForm(request, params, transaction, message, options.publicBaseUrl)
}

function createEmailCodeRateLimiter(policy: EmailCodeRequestPolicy, now: () => number): EmailCodeRateLimiter {
  if (!Number.isInteger(policy.maxRequests) || policy.maxRequests < 1
    || !Number.isInteger(policy.windowSeconds) || policy.windowSeconds < 1) {
    throw new OAuthProtocolError('server_error', 'email code request policy is invalid', 500)
  }
  const windowMs = policy.windowSeconds * 1_000
  const buckets = new Map<string, { windowStart: number; count: number }>()
  const sweep = (current: number): void => {
    if (buckets.size <= 10_000) {
      return
    }
    for (const [key, bucket] of buckets) {
      if (current - bucket.windowStart >= windowMs) {
        buckets.delete(key)
      }
    }
  }
  return {
    allow(key) {
      const current = now()
      const bucket = buckets.get(key)
      if (bucket === undefined || current - bucket.windowStart >= windowMs) {
        sweep(current)
        buckets.set(key, { windowStart: current, count: 1 })
        return true
      }
      if (bucket.count >= policy.maxRequests) {
        return false
      }
      bucket.count += 1
      return true
    },
  }
}

function htmlEscape(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;')
}

function redirectResponse(redirectUri: string, values: Record<string, string>): Response {
  const url = new URL(redirectUri)
  for (const [name, value] of Object.entries(values)) {
    url.searchParams.set(name, value)
  }
  return new Response(null, {
    status: 302,
    headers: { 'cache-control': 'no-store', location: url.href },
  })
}

function sessionFields(session: OAuthUserSession): { accessToken: string; refreshToken?: string; expiresIn: number; userId: string } {
  if (session.accessToken.trim() === '' || session.userId.trim() === '' || !Number.isFinite(session.expiresIn) || session.expiresIn <= 0) {
    throw new OAuthProtocolError('server_error', 'identity provider returned an invalid session', 500)
  }
  return {
    accessToken: session.accessToken,
    refreshToken: session.refreshToken,
    expiresIn: Math.floor(session.expiresIn),
    userId: session.userId,
  }
}

function stringPayloadField(payload: Record<string, unknown>, name: string): string {
  const value = payload[name]
  if (typeof value !== 'string' || value.trim() === '') {
    throw new OAuthProtocolError('invalid_grant', 'token is invalid')
  }
  return value
}

function stringArrayPayloadField(payload: Record<string, unknown>, name: string): string[] {
  const value = payload[name]
  if (!isStringArray(value)) {
    throw new OAuthProtocolError('invalid_grant', 'token is invalid')
  }
  return value
}

function ensureUnexpired(payload: Record<string, unknown>): void {
  const expiresAt = payload.expiresAt
  if (typeof expiresAt !== 'number' || !Number.isFinite(expiresAt) || expiresAt <= Math.floor(Date.now() / 1000)) {
    throw new OAuthProtocolError('invalid_grant', 'token has expired')
  }
}

function resourceMatches(requested: string | undefined, original: string | undefined): boolean {
  if (requested === undefined || original === undefined) {
    return requested === original
  }
  try {
    return new URL(requested).href === new URL(original).href
  } catch {
    return false
  }
}

async function tokenResponse(
  secret: string,
  session: OAuthUserSession,
  clientId: string,
  scopes: string[],
  resource: string | undefined,
): Promise<Response> {
  const fields = sessionFields(session)
  const response: Record<string, unknown> = {
    access_token: fields.accessToken,
    expires_in: fields.expiresIn,
    token_type: 'Bearer',
  }
  if (fields.refreshToken !== undefined && fields.refreshToken.trim() !== '') {
    response.refresh_token = await sealPayload(secret, {
      typ: 'refresh_token',
      clientId,
      userId: fields.userId,
      refreshToken: fields.refreshToken,
      scopes,
      resource,
      expiresAt: Math.floor(Date.now() / 1000) + 30 * 24 * 60 * 60,
    } satisfies RefreshTokenPayload)
  }
  if (scopes.length > 0) {
    response.scope = scopes.join(' ')
  }
  return oauthResponse(response, 200, corsHeaders())
}

interface ValidatedAuthorizationRequest {
  clientId: string
  redirectUri: string
  codeChallenge: string
  resource: string | undefined
  params: URLSearchParams
}

async function openOtpTransaction(secret: string, value: string, nowSeconds: number): Promise<OtpTransactionPayload | undefined> {
  let payload: Record<string, unknown>
  try {
    payload = await openPayload(secret, value)
  } catch {
    return undefined
  }
  if (payload.typ !== 'otp_transaction'
    || typeof payload.email !== 'string' || payload.email.trim() === ''
    || typeof payload.clientId !== 'string' || payload.clientId === ''
    || typeof payload.redirectUri !== 'string' || payload.redirectUri === ''
    || typeof payload.codeChallenge !== 'string' || payload.codeChallenge === ''
    || typeof payload.scope !== 'string'
    || (payload.resource !== undefined && typeof payload.resource !== 'string')
    || typeof payload.expiresAt !== 'number' || !Number.isFinite(payload.expiresAt)
    || payload.expiresAt <= nowSeconds) {
    return undefined
  }
  return {
    typ: 'otp_transaction',
    email: payload.email,
    clientId: payload.clientId,
    redirectUri: payload.redirectUri,
    codeChallenge: payload.codeChallenge,
    scope: payload.scope,
    ...(payload.resource === undefined ? {} : { resource: payload.resource }),
    expiresAt: payload.expiresAt,
  }
}

// Step 1: accept the email only, validate the full OAuth request first (done
// by the caller), request a Supabase Auth email one-time code for an existing
// account without user creation, apply the per-email request rate limit, and
// hand the transaction to the code stage inside a confidential, integrity-
// protected, expiring envelope. Existing and unknown accounts receive the
// same code-stage response so existence is never disclosed.
async function handleEmailCodeRequest(
  request: Request,
  authorization: ValidatedAuthorizationRequest,
  secret: string,
  options: OAuthAuthorizationRouteOptions,
): Promise<Response> {
  const email = authorization.params.get('email')
  if (email === null || email.trim() === '') {
    return emailStageResponse(request, authorization.params, 'Enter the email on your Morsel account to request a code.', options)
  }
  const normalizedEmail = email.trim()
  if (!options.limiter.allow(await hashValue(normalizedEmail))) {
    // Defer without revealing anything: the response never names the email.
    return emailStageResponse(request, authorization.params, 'Too many code requests for this email. Wait a few minutes and try again.', options)
  }
  try {
    await options.service.requestCode(normalizedEmail)
  } catch {
    // Uniform response for unknown accounts and provider refusals alike.
  }
  const transaction = await sealPayload(secret, {
    typ: 'otp_transaction',
    email: normalizedEmail,
    clientId: authorization.clientId,
    redirectUri: authorization.redirectUri,
    codeChallenge: authorization.codeChallenge,
    scope: authorization.params.get('scope') ?? '',
    ...(authorization.resource === undefined ? {} : { resource: authorization.resource }),
    expiresAt: Math.floor(options.now() / 1000) + OTP_TRANSACTION_TTL_SECONDS,
  } satisfies OtpTransactionPayload)
  return codeStageResponse(request, authorization.params, transaction, undefined, options)
}

// Step 2: accept exactly the six-digit code shape plus the protected
// transaction envelope, verify the code with Supabase Auth, and only then
// continue the existing stored-grant + authorization-code redirect path.
// Wrong, expired, reused, malformed, or cross-transaction codes fail closed
// and keep every OAuth parameter intact for the retry.
async function handleCodeVerification(
  request: Request,
  authorization: ValidatedAuthorizationRequest,
  secret: string,
  options: OAuthAuthorizationRouteOptions,
): Promise<Response> {
  const params = authorization.params
  const transaction = params.get('transaction')
  if (transaction === null) {
    return emailStageResponse(request, params, 'Your code request expired or is no longer valid. Request a new code.', options)
  }
  const payload = await openOtpTransaction(secret, transaction, Math.floor(options.now() / 1000))
  const scope = params.get('scope') ?? ''
  if (payload === undefined
    || payload.clientId !== authorization.clientId
    || payload.redirectUri !== authorization.redirectUri
    || payload.codeChallenge !== authorization.codeChallenge
    || payload.scope !== scope
    || !resourceMatches(authorization.resource, payload.resource)) {
    // Missing, expired, tampered, or cross-transaction envelope: fail closed
    // at the request stage with all OAuth fields intact.
    return emailStageResponse(request, params, 'Your code request expired or is no longer valid. Request a new code.', options)
  }
  const code = params.get('code') ?? ''
  if (!OTP_CODE_SHAPE.test(code)) {
    return codeStageResponse(request, params, transaction, 'Enter the 6-digit code from the email.', options)
  }
  let session: OAuthUserSession
  try {
    session = await options.service.verifyCode(payload.email, code)
  } catch {
    return codeStageResponse(request, params, transaction, 'That code is invalid or has expired. Check your email and try again.', options)
  }
  const fields = sessionFields(session)
  if (fields.refreshToken === undefined || fields.refreshToken.trim() === '') {
    throw new OAuthProtocolError('server_error', 'identity provider did not return a refresh token', 500)
  }
  const scopes = payload.scope.split(' ').filter((entry) => entry !== '')
  const expiresAt = Math.floor(options.now() / 1000) + 5 * 60
  const codeValue = await sealPayload(secret, {
    typ: 'authorization_code',
    clientId: payload.clientId,
    expiresAt,
  } satisfies AuthorizationCodePayload)
  await options.grantStore.create({
    codeHash: await hashValue(codeValue),
    clientId: payload.clientId,
    redirectUri: payload.redirectUri,
    codeChallenge: payload.codeChallenge,
    userId: fields.userId,
    refreshToken: fields.refreshToken,
    scopes,
    ...(payload.resource === undefined ? {} : { resource: payload.resource }),
    expiresAt,
  }, fields.accessToken)
  return redirectResponse(payload.redirectUri, {
    code: codeValue,
    ...(params.get('state') === null ? {} : { state: params.get('state') ?? '' }),
  })
}

async function handleAuthorization(request: Request, options: OAuthAuthorizationRouteOptions): Promise<Response> {
  const params = await requestParameters(request)
  const secret = resolveConfigValue(options.signingKey, 'MORSEL_OAUTH_SIGNING_KEY')
  const clientId = params.get('client_id')
  if (clientId === null) {
    return oauthErrorResponse(new OAuthProtocolError('invalid_request', 'client_id is required'))
  }
  let client: ClientRegistrationPayload
  try {
    client = await clientFromId(secret, clientId)
  } catch (error) {
    return oauthErrorResponse(error)
  }
  const redirectUri = params.get('redirect_uri')
  if (redirectUri === null || !client.redirectUris.some((registered) => redirectUriMatches(redirectUri, registered))) {
    return oauthErrorResponse(new OAuthProtocolError('invalid_request', 'redirect_uri is not registered'))
  }
  if (params.get('response_type') !== 'code') {
    return oauthErrorResponse(new OAuthProtocolError('unsupported_response_type', 'response_type must be code'))
  }
  const codeChallenge = params.get('code_challenge')
  if (codeChallenge === null || codeChallenge.trim() === '') {
    return oauthErrorResponse(new OAuthProtocolError('invalid_request', 'code_challenge is required'))
  }
  if (params.get('code_challenge_method') !== 'S256') {
    return oauthErrorResponse(new OAuthProtocolError('invalid_request', 'only S256 PKCE is supported'))
  }
  const resource = params.get('resource') ?? undefined
  if (resource !== undefined && !URL.canParse(resource)) {
    return oauthErrorResponse(new OAuthProtocolError('invalid_request', 'resource must be a valid URL'))
  }
  if (request.method === 'GET') {
    // The first visit is always the email step (a GET cannot carry a code).
    return authorizationForm(request, params, undefined, options.publicBaseUrl)
  }
  const authorization: ValidatedAuthorizationRequest = { clientId, redirectUri, codeChallenge, resource, params }
  if (!params.has('code')) {
    return await handleEmailCodeRequest(request, authorization, secret, options)
  }
  return await handleCodeVerification(request, authorization, secret, options)
}

async function handleToken(request: Request, options: OAuthRouteOptions): Promise<Response> {
  const secret = resolveConfigValue(options.signingKey, 'MORSEL_OAUTH_SIGNING_KEY')
  const params = await requestParameters(request)
  const clientId = params.get('client_id')
  if (clientId === null) {
    return oauthErrorResponse(new OAuthProtocolError('invalid_client', 'client_id is required', 401))
  }
  try {
    await clientFromId(secret, clientId)
  } catch (error) {
    return oauthErrorResponse(error)
  }
  const grantType = params.get('grant_type')
  if (grantType === 'authorization_code') {
    const code = params.get('code')
    const verifier = params.get('code_verifier')
    if (code === null || verifier === null || verifier === '') {
      return oauthErrorResponse(new OAuthProtocolError('invalid_request', 'code and code_verifier are required'))
    }
    let payload: Record<string, unknown>
    try {
      payload = await openPayload(secret, code)
      ensureUnexpired(payload)
      if (payload.typ !== 'authorization_code' || payload.clientId !== clientId) {
        throw new OAuthProtocolError('invalid_grant', 'authorization code is invalid')
      }
      const grant = await options.grantStore.claim(await hashValue(code), clientId)
      if (grant === undefined) {
        throw new OAuthProtocolError('invalid_grant', 'authorization code is invalid or already used')
      }
      const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))
      if (encodeBase64Url(new Uint8Array(digest)) !== grant.codeChallenge) {
        throw new OAuthProtocolError('invalid_grant', 'code_verifier does not match code_challenge')
      }
      const redirectUri = params.get('redirect_uri')
      if (redirectUri === null || redirectUri !== grant.redirectUri) {
        throw new OAuthProtocolError('invalid_grant', 'redirect_uri does not match authorization request')
      }
      const resource = params.get('resource') ?? undefined
      if (!resourceMatches(resource, grant.resource)) {
        throw new OAuthProtocolError('invalid_grant', 'resource does not match authorization request')
      }
      const session = await options.service.refresh(grant.refreshToken)
      if (session.userId !== grant.userId) {
        throw new OAuthProtocolError('invalid_grant', 'authorization code user does not match')
      }
      return await tokenResponse(secret, session, clientId, grant.scopes, resource)
    } catch (error) {
      return oauthErrorResponse(error)
    }
  }
  if (grantType === 'refresh_token') {
    const refreshToken = params.get('refresh_token')
    if (refreshToken === null || refreshToken === '') {
      return oauthErrorResponse(new OAuthProtocolError('invalid_request', 'refresh_token is required'))
    }
    try {
      const payload = await openPayload(secret, refreshToken)
      ensureUnexpired(payload)
      if (payload.typ !== 'refresh_token' || payload.clientId !== clientId) {
        throw new OAuthProtocolError('invalid_grant', 'refresh token is invalid')
      }
      const resource = params.get('resource') ?? undefined
      if (!resourceMatches(resource, typeof payload.resource === 'string' ? payload.resource : undefined)) {
        throw new OAuthProtocolError('invalid_grant', 'resource does not match authorization request')
      }
      const session = await options.service.refresh(stringPayloadField(payload, 'refreshToken'))
      if (session.userId !== stringPayloadField(payload, 'userId')) {
        throw new OAuthProtocolError('invalid_grant', 'refresh token user does not match')
      }
      const requestedScopes = params.get('scope')
      const scopes = requestedScopes === null
        ? stringArrayPayloadField(payload, 'scopes')
        : requestedScopes.split(' ').filter((scope) => scope !== '')
      return await tokenResponse(secret, session, clientId, scopes, resource)
    } catch (error) {
      return oauthErrorResponse(error)
    }
  }
  return oauthErrorResponse(new OAuthProtocolError('unsupported_grant_type', 'grant_type is not supported'))
}

async function handleRegistration(request: Request, options: OAuthRouteOptions): Promise<Response> {
  let body: unknown
  try {
    body = JSON.parse(await request.text())
  } catch {
    return oauthErrorResponse(new OAuthProtocolError('invalid_client_metadata', 'registration body must be valid JSON'))
  }
  if (!isRecord(body)) {
    return oauthErrorResponse(new OAuthProtocolError('invalid_client_metadata', 'registration body must be an object'))
  }
  const redirectUris = body.redirect_uris
  if (!isStringArray(redirectUris) || redirectUris.length === 0 || redirectUris.some((uri) => !validRedirectUri(uri))) {
    return oauthErrorResponse(new OAuthProtocolError('invalid_client_metadata', 'redirect_uris must contain HTTPS or loopback URLs'))
  }
  const grantTypes = body.grant_types
  if (grantTypes !== undefined && (!Array.isArray(grantTypes) || grantTypes.some((grant) => grant !== 'authorization_code' && grant !== 'refresh_token'))) {
    return oauthErrorResponse(new OAuthProtocolError('invalid_client_metadata', 'only authorization_code and refresh_token grants are supported'))
  }
  const responseTypes = body.response_types
  if (responseTypes !== undefined && (!Array.isArray(responseTypes) || !responseTypes.includes('code'))) {
    return oauthErrorResponse(new OAuthProtocolError('invalid_client_metadata', 'only the code response type is supported'))
  }
  const authMethod = body.token_endpoint_auth_method
  if (authMethod !== undefined && authMethod !== 'none') {
    return oauthErrorResponse(new OAuthProtocolError('invalid_client_metadata', 'public PKCE clients must use token_endpoint_auth_method none'))
  }
  const secret = resolveConfigValue(options.signingKey, 'MORSEL_OAUTH_SIGNING_KEY')
  const issuedAt = Math.floor(Date.now() / 1000)
  const clientName = typeof body.client_name === 'string' && body.client_name.trim() !== '' ? body.client_name : undefined
  const clientId = await signPayload(secret, {
    typ: 'client',
    redirectUris,
    clientName,
    issuedAt,
  } satisfies ClientRegistrationPayload)
  return oauthResponse({
    client_id: clientId,
    client_id_issued_at: issuedAt,
    client_name: clientName,
    grant_types: grantTypes ?? ['authorization_code', 'refresh_token'],
    redirect_uris: redirectUris,
    response_types: responseTypes ?? ['code'],
    token_endpoint_auth_method: 'none',
  }, 201, corsHeaders())
}

interface SupabaseOAuthGrantStoreOptions {
  supabaseUrl: OAuthConfigValue
  anonKey: OAuthConfigValue
  fetch?: typeof fetch
}

function parsedOAuthGrant(value: unknown): OAuthAuthorizationGrant | undefined {
  if (!isRecord(value)
    || typeof value.code_hash !== 'string'
    || typeof value.client_id !== 'string'
    || typeof value.redirect_uri !== 'string'
    || typeof value.code_challenge !== 'string'
    || typeof value.user_id !== 'string'
    || typeof value.refresh_token !== 'string'
    || !isStringArray(value.scopes)) {
    return undefined
  }
  const expiresAt = typeof value.expires_at === 'string'
    ? Date.parse(value.expires_at) / 1_000
    : typeof value.expires_at === 'number'
      ? value.expires_at
      : Number.NaN
  if (value.code_hash === '' || value.client_id === '' || value.redirect_uri === ''
    || value.code_challenge === '' || value.user_id === '' || value.refresh_token === ''
    || !Number.isFinite(expiresAt)) {
    return undefined
  }
  return {
    codeHash: value.code_hash,
    clientId: value.client_id,
    redirectUri: value.redirect_uri,
    codeChallenge: value.code_challenge,
    userId: value.user_id,
    refreshToken: value.refresh_token,
    scopes: value.scopes,
    ...(typeof value.resource === 'string' ? { resource: value.resource } : {}),
    expiresAt,
  }
}

export function createSupabaseOAuthGrantStore(options: SupabaseOAuthGrantStoreOptions): OAuthGrantStore {
  function client(accessToken?: string) {
    const headers = accessToken === undefined ? {} : { headers: { Authorization: `Bearer ${accessToken}` } }
    return createClient<Database>(
      resolveConfigValue(options.supabaseUrl, 'SUPABASE_URL'),
      resolveConfigValue(options.anonKey, 'SUPABASE_ANON_KEY'),
      {
        auth: { autoRefreshToken: false, detectSessionInUrl: false, persistSession: false },
        global: { ...headers, fetch: options.fetch },
      },
    )
  }

  return {
    async create(grant: OAuthAuthorizationGrant, accessToken: string): Promise<void> {
      const result = await client(accessToken).from('oauth_authorization_grants').insert({
        code_hash: grant.codeHash,
        client_id: grant.clientId,
        redirect_uri: grant.redirectUri,
        code_challenge: grant.codeChallenge,
        scopes: grant.scopes,
        resource: grant.resource ?? null,
        user_id: grant.userId,
        refresh_token: grant.refreshToken,
        expires_at: new Date(grant.expiresAt * 1_000).toISOString(),
      })
      if (result.error !== null) {
        throw new OAuthProtocolError('server_error', 'could not store authorization grant', 500)
      }
    },
    async claim(codeHash: string, clientId: string): Promise<OAuthAuthorizationGrant | undefined> {
      const result = await client().rpc('claim_oauth_authorization_grant', {
        p_code_hash: codeHash,
        p_client_id: clientId,
      })
      if (result.error !== null) {
        throw new OAuthProtocolError('server_error', 'could not claim authorization grant', 500)
      }
      const row = result.data[0]
      if (row === undefined) {
        return undefined
      }
      const grant = parsedOAuthGrant(row)
      if (grant === undefined) {
        throw new OAuthProtocolError('server_error', 'authorization grant is invalid', 500)
      }
      return grant
    },
  }
}

export function createSupabaseOAuthService(options: {
  supabaseUrl: OAuthConfigValue
  anonKey: OAuthConfigValue
  fetch?: typeof fetch
}): OAuthIdentityService {
  interface SupabaseSession {
    access_token: string
    refresh_token?: string
    expires_in?: number
  }

  function isSupabaseSession(value: unknown): value is SupabaseSession {
    return isRecord(value)
      && typeof value.access_token === 'string'
      && (value.refresh_token === undefined || typeof value.refresh_token === 'string')
      && (value.expires_in === undefined || typeof value.expires_in === 'number')
  }

  function client() {
    return createClient(
      resolveConfigValue(options.supabaseUrl, 'SUPABASE_URL'),
      resolveConfigValue(options.anonKey, 'SUPABASE_ANON_KEY'),
      {
        auth: { autoRefreshToken: false, detectSessionInUrl: false, persistSession: false },
        global: { fetch: options.fetch },
      },
    )
  }

  async function verifiedSession(session: SupabaseSession, email?: string): Promise<OAuthUserSession> {
    const supabase = client()
    const result = await supabase.auth.getUser(session.access_token)
    if (result.error !== null) {
      throw new OAuthProtocolError('access_denied', 'Supabase Auth did not validate the session')
    }
    const userEmail = result.data.user.email ?? email
    if (typeof userEmail !== 'string' || userEmail.trim() === '') {
      throw new OAuthProtocolError('access_denied', 'Supabase Auth user has no email')
    }
    return {
      userId: result.data.user.id,
      email: userEmail.trim(),
      accessToken: session.access_token,
      refreshToken: session.refresh_token,
      expiresIn: session.expires_in ?? 3600,
    }
  }

  return {
    async requestCode(email: string): Promise<void> {
      // Existing accounts only: user creation is explicitly disabled so the
      // consent page can never sign a new account up.
      const result = await client().auth.signInWithOtp({
        email,
        options: { shouldCreateUser: false },
      })
      if (result.error !== null) {
        // The route answers uniformly for unknown accounts and provider
        // refusals; this error is never exposed to the caller.
        throw new OAuthProtocolError('access_denied', 'Supabase Auth could not send an email code')
      }
    },
    async verifyCode(email: string, code: string): Promise<OAuthUserSession> {
      const result = await client().auth.verifyOtp({ email, token: code, type: 'email' })
      const session: unknown = result.data.session
      if (result.error !== null || !isSupabaseSession(session)) {
        throw new OAuthProtocolError('access_denied', 'Supabase Auth did not validate the code')
      }
      return await verifiedSession(session, email)
    },
    async refresh(refreshToken: string): Promise<OAuthUserSession> {
      const result = await client().auth.refreshSession({ refresh_token: refreshToken })
      const session: unknown = result.data.session
      if (result.error !== null || !isSupabaseSession(session)) {
        throw new OAuthProtocolError('invalid_grant', 'Supabase Auth returned an invalid session')
      }
      return await verifiedSession(session)
    },
  }
}

export function registerOAuthRoutes(app: Hono, options: OAuthRouteOptions): void {
  // Fail closed at startup when an explicit public base URL or authorization
  // endpoint is malformed.
  resolvePublicBaseUrl(options.publicBaseUrl)
  const authorizationEndpoint = resolveAuthorizationEndpoint(options.authorizationEndpoint)
  const now = options.now ?? Date.now
  const authorizationOptions: OAuthAuthorizationRouteOptions = {
    ...options,
    authorizationPage: authorizationEndpoint,
    limiter: createEmailCodeRateLimiter(options.emailCodeRequests ?? DEFAULT_EMAIL_CODE_REQUEST_POLICY, now),
    now,
  }
  app.get('/.well-known/oauth-authorization-server', (context) => {
    try {
      return oauthResponse(authorizationServerMetadata(context.req.raw, options.basePath, options.publicBaseUrl, authorizationEndpoint), 200, corsHeaders())
    } catch (error) {
      return oauthErrorResponse(error)
    }
  })
  // Issue #59: spec-compliant MCP clients build discovery URLs by appending to
  // the issuer. With Morsel's path issuer (/functions/v1/mcp), the third spec
  // attempt - <issuer>/.well-known/openid-configuration - reaches the Edge
  // Function, so the authorization-server document is also served there.
  // Same document, same CORS/cache/content-type behavior; no OIDC claims the
  // provider cannot back (no jwks_uri / subject_types_supported).
  app.get('/.well-known/openid-configuration', (context) => {
    try {
      return oauthResponse(authorizationServerMetadata(context.req.raw, options.basePath, options.publicBaseUrl, authorizationEndpoint), 200, corsHeaders())
    } catch (error) {
      return oauthErrorResponse(error)
    }
  })
  app.get('/.well-known/oauth-protected-resource', (context) => {
    try {
      return oauthResponse(protectedResourceMetadata(context.req.raw, options.basePath, options.publicBaseUrl), 200, corsHeaders())
    } catch (error) {
      return oauthErrorResponse(error)
    }
  })
  app.get('/.well-known/oauth-protected-resource/mcp', (context) => {
    try {
      return oauthResponse(protectedResourceMetadata(context.req.raw, options.basePath, options.publicBaseUrl), 200, corsHeaders())
    } catch (error) {
      return oauthErrorResponse(error)
    }
  })
  app.options('/register', () => new Response(null, { status: 204, headers: corsHeaders() }))
  app.post('/register', async (context) => {
    try {
      return await handleRegistration(context.req.raw, options)
    } catch (error) {
      return oauthErrorResponse(error)
    }
  })
  app.on(['GET', 'POST'], '/authorize', async (context) => {
    try {
      return await handleAuthorization(context.req.raw, authorizationOptions)
    } catch (error) {
      return oauthErrorResponse(error)
    }
  })
  app.options('/token', () => new Response(null, { status: 204, headers: corsHeaders() }))
  app.post('/token', async (context) => {
    try {
      return await handleToken(context.req.raw, options)
    } catch (error) {
      return oauthErrorResponse(error)
    }
  })
}
