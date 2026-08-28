import { createClient } from '@supabase/supabase-js'
import type { Hono } from 'hono'

export type OAuthConfigValue = string | (() => string)

export interface OAuthUserSession {
  userId: string
  email: string
  accessToken: string
  refreshToken?: string
  expiresIn: number
}

export interface OAuthIdentityService {
  authenticate(email: string, password: string): Promise<OAuthUserSession>
  refresh(refreshToken: string): Promise<OAuthUserSession>
}

export interface MorselOAuthOptions {
  signingKey?: OAuthConfigValue
  service?: OAuthIdentityService
  supabaseUrl?: OAuthConfigValue
  anonKey?: OAuthConfigValue
}

interface OAuthRouteOptions {
  basePath?: string
  signingKey: OAuthConfigValue
  service: OAuthIdentityService
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
  redirectUri: string
  codeChallenge: string
  userId: string
  accessToken: string
  refreshToken?: string
  expiresIn: number
  scopes: string[]
  resource?: string
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

function corsHeaders(): HeaderValues {
  return {
    'access-control-allow-headers': 'content-type',
    'access-control-allow-methods': 'GET,POST,OPTIONS',
    'access-control-allow-origin': '*',
  }
}

function normalizedBasePath(basePath?: string): string {
  if (basePath === undefined || basePath === '' || basePath === '/') {
    return ''
  }
  return `/${basePath.replace(/^\/+|\/+$/g, '')}`
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

export function oauthBaseUrl(request: Request, basePath?: string): URL {
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

export function protectedResourceMetadataUrl(request: Request, basePath?: string): string {
  return appendPath(oauthBaseUrl(request, basePath), '.well-known/oauth-protected-resource/mcp').href
}

function authorizationServerMetadata(request: Request, basePath?: string): Record<string, unknown> {
  const baseUrl = oauthBaseUrl(request, basePath)
  return {
    issuer: baseUrlString(baseUrl),
    authorization_endpoint: appendPath(baseUrl, 'authorize').href,
    token_endpoint: appendPath(baseUrl, 'token').href,
    registration_endpoint: appendPath(baseUrl, 'register').href,
    response_types_supported: ['code'],
    code_challenge_methods_supported: ['S256'],
    token_endpoint_auth_methods_supported: ['none'],
    grant_types_supported: ['authorization_code', 'refresh_token'],
    scopes_supported: ['mcp'],
  }
}

function protectedResourceMetadata(request: Request, basePath?: string): Record<string, unknown> {
  const baseUrl = oauthBaseUrl(request, basePath)
  return {
    resource: appendPath(baseUrl, 'mcp').href,
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

function authorizationForm(request: Request, params: URLSearchParams, message?: string): Response {
  const hiddenFields = Array.from(params.entries())
    .filter(([name]) => name !== 'email' && name !== 'password')
    .map(([name, value]) => `<input type="hidden" name="${htmlEscape(name)}" value="${htmlEscape(value)}">`)
    .join('')
  const notice = message === undefined ? '' : `<p role="alert">${htmlEscape(message)}</p>`
  const body = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Connect Morsel</title></head><body><main><h1>Connect Morsel</h1>${notice}<form method="post" action="${htmlEscape(new URL(request.url).pathname)}"><label>Email <input name="email" type="email" autocomplete="username" required></label><label>Password <input name="password" type="password" autocomplete="current-password" required></label><button type="submit">Authorize</button>${hiddenFields}</form></main></body></html>`
  return new Response(body, {
    status: 200,
    headers: {
      'cache-control': 'no-store',
      'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'",
      'content-type': 'text/html; charset=utf-8',
    },
  })
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
  if (typeof expiresAt !== 'number' || expiresAt <= Math.floor(Date.now() / 1000)) {
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

async function handleAuthorization(
  request: Request,
  options: OAuthRouteOptions,
): Promise<Response> {
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
    return authorizationForm(request, params)
  }
  const email = params.get('email')
  const password = params.get('password')
  if (email === null || password === null || email.trim() === '' || password === '') {
    return authorizationForm(request, params, 'Email and password are required.')
  }
  let session: OAuthUserSession
  try {
    session = await options.service.authenticate(email.trim(), password)
  } catch {
    return redirectResponse(redirectUri, {
      error: 'access_denied',
      ...(params.get('state') === null ? {} : { state: params.get('state') ?? '' }),
    })
  }
  const fields = sessionFields(session)
  const scopes = (params.get('scope') ?? '').split(' ').filter((scope) => scope !== '')
  const code = await sealPayload(secret, {
    typ: 'authorization_code',
    clientId,
    redirectUri,
    codeChallenge,
    userId: fields.userId,
    accessToken: fields.accessToken,
    refreshToken: fields.refreshToken,
    expiresIn: fields.expiresIn,
    scopes,
    resource,
    expiresAt: Math.floor(Date.now() / 1000) + 5 * 60,
  } satisfies AuthorizationCodePayload)
  return redirectResponse(redirectUri, {
    code,
    ...(params.get('state') === null ? {} : { state: params.get('state') ?? '' }),
  })
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
      const challenge = stringPayloadField(payload, 'codeChallenge')
      const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))
      if (encodeBase64Url(new Uint8Array(digest)) !== challenge) {
        throw new OAuthProtocolError('invalid_grant', 'code_verifier does not match code_challenge')
      }
      const redirectUri = params.get('redirect_uri') ?? undefined
      if (redirectUri !== undefined && redirectUri !== payload.redirectUri) {
        throw new OAuthProtocolError('invalid_grant', 'redirect_uri does not match authorization request')
      }
      const resource = params.get('resource') ?? undefined
      if (!resourceMatches(resource, typeof payload.resource === 'string' ? payload.resource : undefined)) {
        throw new OAuthProtocolError('invalid_grant', 'resource does not match authorization request')
      }
      const session: OAuthUserSession = {
        userId: stringPayloadField(payload, 'userId'),
        email: '',
        accessToken: stringPayloadField(payload, 'accessToken'),
        refreshToken: typeof payload.refreshToken === 'string' ? payload.refreshToken : undefined,
        expiresIn: typeof payload.expiresIn === 'number' ? payload.expiresIn : 0,
      }
      return await tokenResponse(secret, session, clientId, stringArrayPayloadField(payload, 'scopes'), resource)
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
    async authenticate(email: string, password: string): Promise<OAuthUserSession> {
      const result = await client().auth.signInWithPassword({ email, password })
      const session: unknown = result.data.session
      if (result.error !== null || !isSupabaseSession(session)) {
        throw new OAuthProtocolError('access_denied', 'Supabase Auth returned an invalid session')
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
  app.get('/.well-known/oauth-authorization-server', (context) => oauthResponse(authorizationServerMetadata(context.req.raw, options.basePath)))
  app.get('/.well-known/oauth-protected-resource', (context) => oauthResponse(protectedResourceMetadata(context.req.raw, options.basePath)))
  app.get('/.well-known/oauth-protected-resource/mcp', (context) => oauthResponse(protectedResourceMetadata(context.req.raw, options.basePath)))
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
      return await handleAuthorization(context.req.raw, options)
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
