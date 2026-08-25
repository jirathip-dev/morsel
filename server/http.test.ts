import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { describe, expect, it } from 'vitest'
import { createMorselApp } from './app.js'
import type { Authenticate } from './auth.js'
import { InMemoryRepository } from './in-memory-repository.js'

const userId = '00000000-0000-4000-8000-000000000002'
const token = 'test-bearer-token'

describe('MCP HTTP server', () => {
  it('registers all tools and routes log_meal through the repository without Supabase', async () => {
    const repository = new InMemoryRepository()
    const authenticate: Authenticate = (receivedToken) => Promise.resolve({
      userId,
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
    const fetchLike = async (url: string | URL, init?: RequestInit): Promise<Response> => app.fetch(new Request(url.toString(), init))
    const client = new Client({ name: 'morsel-test-client', version: '1.0.0' })
    const transport = new StreamableHTTPClientTransport(new URL('https://morsel.test/mcp'), {
      fetch: fetchLike,
      requestInit: { headers: { Authorization: `Bearer ${token}` } },
    })

    await client.connect(transport)
    const listed = await client.listTools()
    expect(listed.tools.map((tool) => tool.name).sort()).toEqual([
      'compute_targets',
      'delete_meal_log',
      'get_dashboard_summary',
      'get_day',
      'get_goals',
      'get_profile',
      'log_meal',
      'search_food',
      'set_goals',
      'set_profile',
      'update_meal_item',
    ])

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
})
