import { AsyncLocalStorage } from 'node:async_hooks'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { describe, expect, it } from 'vitest'
import { createMorselApp } from './app.js'
import type { Authenticate } from './auth.js'
import { InMemoryRepository } from './in-memory-repository.js'

const userId = '00000000-0000-4000-8000-000000000002'
const token = 'test-bearer-token'

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isRecordArray(value: unknown): value is Record<string, unknown>[] {
  return Array.isArray(value) && value.every(isRecord)
}

function decodeBase64(value: string): string {
  const binary = atob(value)
  return new TextDecoder().decode(Uint8Array.from(binary, (character) => character.charCodeAt(0)))
}

class TokenTrackingRepository extends InMemoryRepository {
  readonly accessTokens: string[] = []
  readonly operationTokens: string[] = []
  private readonly accessTokenContext = new AsyncLocalStorage<string>()

  override withAccessToken<T>(accessToken: string, action: () => Promise<T>): Promise<T> {
    this.accessTokens.push(accessToken)
    return this.accessTokenContext.run(accessToken, action)
  }

  protected requestAccessToken(): string {
    return this.accessTokenContext.getStore() ?? 'missing-token-context'
  }

  override async getMealsInRange(userId: string, start: string, end: string) {
    this.operationTokens.push(this.requestAccessToken())
    return super.getMealsInRange(userId, start, end)
  }
}

interface TokenObservation {
  start: string
  end: string
}

class OverlappingTokenRepository extends TokenTrackingRepository {
  readonly firstOperationStarted: Promise<void>
  readonly observations: TokenObservation[] = []
  private readonly releaseFirstOperationSignal: Promise<void>
  private resolveFirstOperationStarted: (() => void) | undefined
  private resolveReleaseFirstOperation: (() => void) | undefined
  private blockFirstOperation = true

  constructor() {
    super()
    this.firstOperationStarted = new Promise((resolve) => {
      this.resolveFirstOperationStarted = resolve
    })
    this.releaseFirstOperationSignal = new Promise((resolve) => {
      this.resolveReleaseFirstOperation = resolve
    })
  }

  releaseFirstOperation(): void {
    this.resolveReleaseFirstOperation?.()
  }

  override async getMealsInRange(userId: string, start: string, end: string) {
    const startToken = this.requestAccessToken()
    if (this.blockFirstOperation) {
      this.blockFirstOperation = false
      this.resolveFirstOperationStarted?.()
      await this.releaseFirstOperationSignal
    }
    this.observations.push({ start: startToken, end: this.requestAccessToken() })
    return super.getMealsInRange(userId, start, end)
  }
}

describe('MCP HTTP server', () => {
  it('registers all tools and routes log_meal through the repository without Supabase', async () => {
    const repository = new InMemoryRepository()
    const authenticate: Authenticate = (receivedToken) => Promise.resolve({
      userId,
      email: 'test@example.com',
      token: receivedToken,
      authInfo: {
        token: receivedToken,
        clientId: 'test-client',
        scopes: [],
        extra: { userId },
      },
    })
    const app = createMorselApp({
      authenticate,
      repositoryFactory: () => repository,
      now: () => new Date('2026-08-25T12:00:00.000Z'),
      enableJsonResponse: true,
    })
    const fetchLike = async (url: string | URL, init?: RequestInit): Promise<Response> => {
      const request = new Request(url.toString(), init)
      if (request.method !== 'POST') {
        return app.fetch(request)
      }
      const body = await request.clone().text()
      let parsed: unknown
      try {
        parsed = JSON.parse(body)
      } catch {
        return app.fetch(request)
      }
      if (!isRecord(parsed) || parsed.method !== 'tools/call' || !isRecord(parsed.params) || parsed.params.name !== 'get_dashboard_summary') {
        return app.fetch(request)
      }
      const params = { ...parsed.params }
      delete params.arguments
      return app.fetch(new Request(request, { body: JSON.stringify({ ...parsed, params }) }))
    }
    const client = new Client({ name: 'morsel-test-client', version: '1.0.0' })
    const transport = new StreamableHTTPClientTransport(new URL('https://morsel.test/mcp'), {
      fetch: fetchLike,
      requestInit: { headers: { Authorization: `Bearer ${token}` } },
    })

    await client.connect(transport)
    const listed = await client.listTools()
    expect(listed.tools.map((tool) => tool.name).sort()).toEqual([
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
    ])
    const dashboardTool = listed.tools.find((tool) => tool.name === 'get_dashboard_summary')
    expect(dashboardTool?.inputSchema).toMatchObject({
      properties: { days: { type: 'integer' } },
    })

    const defaultSummary = await client.callTool({ name: 'get_dashboard_summary' })
    expect(defaultSummary.isError).not.toBe(true)
    expect(defaultSummary.structuredContent).toMatchObject({ avg_calories_kcal: 0 })
    expect(defaultSummary.content).toHaveLength(2)
    expect(defaultSummary.content).toMatchObject([
      { type: 'text' },
      { type: 'image', mimeType: 'image/svg+xml' },
    ])
    if (!isRecordArray(defaultSummary.content)) {
      throw new Error('dashboard content was not an array')
    }
    const image = defaultSummary.content[1]
    if (!isRecord(image) || typeof image.data !== 'string') {
      throw new Error('dashboard image content was malformed')
    }
    expect(decodeBase64(image.data)).toMatch(/^<svg\b/)

    const result = await client.callTool({
      name: 'log_meal',
      arguments: {
        meal_type: 'lunch',
        eaten_at: '2026-08-25T12:30:00Z',
        items: [{ name: 'rice', calories_kcal: 220 }],
      },
    })
    expect(result.isError).not.toBe(true)
    expect(result.structuredContent).toMatchObject({ recorded: true })

    const meals = await repository.getMealsInRange(userId, '2026-08-25T00:00:00.000Z', '2026-08-26T00:00:00.000Z')
    expect(meals).toHaveLength(1)
    expect(meals[0]?.items[0]?.name).toBe('rice')
    await client.close()
  })

  it('serves health and MCP routes below the configured function prefix', async () => {
    const app = createMorselApp({
      basePath: '/mcp',
      authenticate: () => Promise.reject(new Error('authentication should not be reached')),
      repositoryFactory: () => new InMemoryRepository(),
      enableJsonResponse: true,
    })

    const healthResponse = await app.fetch(new Request('https://morsel.test/mcp/health'))
    expect(healthResponse.status).toBe(200)
    expect(await healthResponse.json()).toEqual({ ok: true })

    // The canonical MCP transport is the Edge Function ROOT (runtime /mcp; the
    // hosted gateway strips /functions/v1): an unauthenticated initialize gets
    // the 401 challenge, not the plain-404 that motivated issue #57.
    const mcpResponse = await app.fetch(new Request('https://morsel.test/mcp', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }),
    }))
    expect(mcpResponse.status).toBe(401)

    // The pre-#57 nested path stays reachable only as a compatibility alias.
    const aliasResponse = await app.fetch(new Request('https://morsel.test/mcp/mcp', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }),
    }))
    expect(aliasResponse.status).toBe(401)
  })

  it('refreshes the session repository token before a post-rotation tool call', async () => {
    const repository = new TokenTrackingRepository()
    const authenticatedTokens: string[] = []
    const authenticate: Authenticate = (receivedToken) => {
      authenticatedTokens.push(receivedToken)
      return Promise.resolve({
        userId,
        email: 'test@example.com',
        token: receivedToken,
        authInfo: {
          token: receivedToken,
          clientId: 'test-client',
          scopes: [],
          extra: { userId },
        },
      })
    }
    const app = createMorselApp({
      authenticate,
      repositoryFactory: () => repository,
      now: () => new Date('2026-08-25T12:00:00.000Z'),
      enableJsonResponse: true,
    })
    let requestNumber = 0
    const fetchLike = async (url: string | URL, init?: RequestInit): Promise<Response> => {
      const request = new Request(url.toString(), init)
      const headers = new Headers(request.headers)
      headers.set('authorization', `Bearer ${requestNumber++ === 0 ? 'token-one' : 'token-two'}`)
      return app.fetch(new Request(request, { headers }))
    }
    const client = new Client({ name: 'morsel-rotation-test-client', version: '1.0.0' })
    const transport = new StreamableHTTPClientTransport(new URL('https://morsel.test/mcp'), {
      fetch: fetchLike,
      requestInit: { headers: { Authorization: 'Bearer token-one' } },
    })

    await client.connect(transport)
    const result = await client.callTool({
      name: 'get_dashboard_summary',
      arguments: { days: 1 },
    })

    expect(result.isError).not.toBe(true)
    expect(authenticatedTokens).toContain('token-one')
    expect(authenticatedTokens).toContain('token-two')
    expect(repository.accessTokens).toContain('token-one')
    expect(repository.accessTokens).toContain('token-two')
    expect(repository.operationTokens[repository.operationTokens.length - 1]).toBe('token-two')
    await client.close()
  })

  it('keeps overlapping requests in one session on their own bearer contexts', async () => {
    const repository = new OverlappingTokenRepository()
    const authenticatedTokens: string[] = []
    let resolveTokenB: (() => void) | undefined
    const tokenBSeen = new Promise<void>((resolve) => {
      resolveTokenB = resolve
    })
    const authenticate: Authenticate = (receivedToken) => {
      authenticatedTokens.push(receivedToken)
      if (receivedToken === 'token-b') {
        resolveTokenB?.()
      }
      return Promise.resolve({
        userId,
        email: 'test@example.com',
        token: receivedToken,
        authInfo: {
          token: receivedToken,
          clientId: 'test-client',
          scopes: [],
          extra: { userId },
        },
      })
    }
    const app = createMorselApp({
      authenticate,
      repositoryFactory: () => repository,
      now: () => new Date('2026-08-25T12:00:00.000Z'),
      enableJsonResponse: true,
    })
    let toolRequestNumber = 0
    const fetchLike = async (url: string | URL, init?: RequestInit): Promise<Response> => {
      const request = new Request(url.toString(), init)
      const body = request.method === 'POST' ? await request.clone().text() : ''
      const isToolCall = body.includes('"method":"tools/call"')
      const tokenForRequest = isToolCall
        ? toolRequestNumber++ === 0 ? 'token-a' : 'token-b'
        : 'token-initial'
      const headers = new Headers(request.headers)
      headers.set('authorization', `Bearer ${tokenForRequest}`)
      return app.fetch(new Request(request, { headers }))
    }
    const client = new Client({ name: 'morsel-overlap-test-client', version: '1.0.0' })
    const transport = new StreamableHTTPClientTransport(new URL('https://morsel.test/mcp'), {
      fetch: fetchLike,
      requestInit: { headers: { Authorization: 'Bearer token-initial' } },
    })

    await client.connect(transport)
    const firstCall = client.callTool({ name: 'get_dashboard_summary', arguments: { days: 1 } })
    await repository.firstOperationStarted
    const secondCall = client.callTool({ name: 'get_dashboard_summary', arguments: { days: 1 } })
    await tokenBSeen
    repository.releaseFirstOperation()
    const [firstResult, secondResult] = await Promise.all([firstCall, secondCall])

    expect(firstResult.isError).not.toBe(true)
    expect(secondResult.isError).not.toBe(true)
    expect(authenticatedTokens[0]).toBe('token-initial')
    expect(authenticatedTokens.filter((receivedToken) => receivedToken === 'token-a')).toHaveLength(1)
    expect(authenticatedTokens.filter((receivedToken) => receivedToken === 'token-b')).toHaveLength(1)
    expect(repository.observations).toEqual([
      { start: 'token-a', end: 'token-a' },
      { start: 'token-b', end: 'token-b' },
    ])
    await client.close()
  })
})
