import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { describe, expect, it } from 'vitest'
import type { Profile, SearchFoodItem } from '../packages/schema/food-types.js'
import { createMorselApp } from './app.js'
import type { Authenticate } from './auth.js'
import { InMemoryRepository } from './in-memory-repository.js'
import { MorselService } from './service.js'
import type { NutritionProvider } from './nutrition-provider.js'

// Behavioral proof that the advertised annotations match the real
// service/repository effects. Every tool call goes through the real MCP
// registration path (HTTP app -> MCP SDK -> MorselService -> repository) with
// isolated synthetic data only.

const userA = '00000000-0000-4000-8000-0000000000a1'
const userB = '00000000-0000-4000-8000-0000000000b2'
const fixedNow = () => new Date('2026-08-25T12:00:00.000Z')

const profile: Profile = {
  sex: 'male',
  age_years: 30,
  height_cm: 180,
  weight_kg: 80,
  activity_level: 'moderate',
  diet_goal: 'maintain',
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isRecordArray(value: unknown): value is Record<string, unknown>[] {
  return Array.isArray(value) && value.every((entry) => isRecord(entry))
}

function recordValue(value: unknown, key: string): unknown {
  return isRecord(value) ? value[key] : undefined
}

function errorText(result: unknown): string {
  const content = recordValue(result, 'content')
  if (!isRecordArray(content)) {
    return ''
  }
  for (const block of content) {
    if (block.type === 'text' && typeof block.text === 'string') {
      return block.text
    }
  }
  return ''
}

function mealLogIdOf(result: unknown): string | undefined {
  const structured = recordValue(result, 'structuredContent')
  const mealLogId = recordValue(structured, 'meal_log_id')
  return typeof mealLogId === 'string' ? mealLogId : undefined
}

function mealItemId(result: unknown): string | undefined {
  const structured = recordValue(result, 'structuredContent')
  const meals = recordValue(structured, 'meals')
  if (!isRecordArray(meals)) {
    return undefined
  }
  const items = recordValue(meals[0], 'items')
  if (!isRecordArray(items)) {
    return undefined
  }
  const itemId = recordValue(items[0], 'item_id')
  return typeof itemId === 'string' ? itemId : undefined
}

interface TestClients {
  a: Client
  b: Client
}

async function connectPair(repository: InMemoryRepository): Promise<TestClients> {
  const users: Record<string, { userId: string; email: string }> = {
    'token-a': { userId: userA, email: 'a@example.com' },
    'token-b': { userId: userB, email: 'b@example.com' },
  }
  const authenticate: Authenticate = (token) => {
    const user = users[token]
    if (user === undefined) {
      return Promise.reject(new Error(`unexpected test token: ${token}`))
    }
    return Promise.resolve({
      userId: user.userId,
      email: user.email,
      token,
      authInfo: { token, clientId: 'classification-test-client', scopes: [], extra: { userId: user.userId } },
    })
  }
  const app = createMorselApp({
    authenticate,
    repositoryFactory: () => repository,
    now: fixedNow,
    enableJsonResponse: true,
  })
  const fetchLike = async (url: string | URL, init?: RequestInit): Promise<Response> =>
    app.fetch(new Request(url.toString(), init))
  const connect = async (token: string): Promise<Client> => {
    const client = new Client({ name: 'morsel-classification-test', version: '1.0.0' })
    const transport = new StreamableHTTPClientTransport(new URL('https://morsel.test/mcp'), {
      fetch: fetchLike,
      requestInit: { headers: { Authorization: `Bearer ${token}` } },
    })
    await client.connect(transport)
    return client
  }
  const a = await connect('token-a')
  const b = await connect('token-b')
  return { a, b }
}

interface UserStateSnapshot {
  meals: unknown[]
  profile: unknown
  goals: unknown
  weights: unknown[]
  energy: unknown[]
}

async function snapshot(repository: InMemoryRepository, userId: string): Promise<UserStateSnapshot> {
  const start = '2026-01-01T00:00:00.000Z'
  const end = '2027-01-01T00:00:00.000Z'
  return {
    meals: await repository.getMealsInRange(userId, start, end),
    profile: await repository.getProfile(userId),
    goals: await repository.getGoals(userId),
    weights: await repository.getWeightTrend(userId, start, end),
    energy: await repository.getEnergyBurned(userId, start, end),
  }
}

describe('annotation classification vs real behavior', () => {
  it('read-only annotated tools never write: every read-only call leaves the full user state untouched', async () => {
    const repository = new InMemoryRepository({ energyBurnedByUser: {
      [userA]: [{ date: '2026-08-25', active_kcal: 300 }],
    } })
    repository.seedProfile(userA, profile)
    repository.seedGoals(userA, { source: 'computed' })
    repository.seedWeightTrend(userA, [{ date: '2026-08-25', kg: 80 }])
    const setupService = new MorselService({ repository, userId: userA, now: fixedNow })
    await setupService.logMeal({
      meal_type: 'lunch',
      eaten_at: '2026-08-25T12:30:00Z',
      items: [
        { name: 'rice', calories_kcal: 220, carbs_g: 48 },
        { name: 'chicken', quantity: 120, unit: 'g', calories_kcal: 200, protein_g: 38, fat_g: 5 },
      ],
    })

    const before = await snapshot(repository, userA)
    const clients = await connectPair(repository)
    try {
      const calls: Array<{ name: string; arguments: Record<string, unknown> }> = [
        { name: 'get_profile', arguments: {} },
        { name: 'get_day', arguments: { date: '2026-08-25' } },
        { name: 'compute_targets', arguments: {} },
        { name: 'get_goals', arguments: {} },
        { name: 'get_weight_trend', arguments: { days: 30 } },
        { name: 'get_energy_burned', arguments: { days: 30 } },
        { name: 'get_dashboard_summary', arguments: { days: 7 } },
      ]
      for (const call of calls) {
        const result = await clients.a.callTool(call)
        expect(result.isError, `${call.name} must succeed`).not.toBe(true)
      }
      const after = await snapshot(repository, userA)
      expect(after).toEqual(before)
    } finally {
      await clients.a.close()
      await clients.b.close()
    }
  })

  it('search_food is not advertised read-only because a provider miss persists shared-cache rows', async () => {
    const food: SearchFoodItem = {
      id: '00000000-0000-4000-8000-0000000000f1',
      name: 'Banana',
      calories_kcal: 105,
      carbs_g: 27,
    }
    let providerCalls = 0
    const provider: NutritionProvider = {
      search: () => {
        providerCalls += 1
        return Promise.resolve([{ ...food, fdc_id: 173944 }])
      },
    }
    const repository = new InMemoryRepository({ nutritionProvider: provider })
    const service = new MorselService({ repository, userId: userA, now: fixedNow })

    await expect(service.searchFood({ query: 'banana' })).resolves.toEqual({ results: [food] })
    await expect(service.searchFood({ query: 'banana' })).resolves.toEqual({ results: [food] })
    // The second identical search is served from the repository's own catalog,
    // proving the first call persisted provider rows (a write) instead of
    // calling the provider again. User state stays untouched.
    expect(providerCalls).toBe(1)
    await expect(snapshot(repository, userA)).resolves.toEqual({
      meals: [],
      profile: undefined,
      goals: undefined,
      weights: [],
      energy: [],
    })

    const clients = await connectPair(repository)
    try {
      const listed = await clients.a.listTools()
      const searchTool = listed.tools.find((tool) => tool.name === 'search_food')
      expect(searchTool?.annotations).toEqual({
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false,
      })
    } finally {
      await clients.a.close()
      await clients.b.close()
    }
  })

  it('write tools have their stated effects through the registration path', async () => {
    const repository = new InMemoryRepository()
    const clients = await connectPair(repository)
    try {
      const profileResult = await clients.a.callTool({
        name: 'set_profile',
        arguments: { ...profile },
      })
      expect(profileResult.isError).not.toBe(true)
      expect(profileResult.structuredContent).toMatchObject({ ok: true, saved: true })

      const logged = await clients.a.callTool({
        name: 'log_meal',
        arguments: {
          meal_type: 'lunch',
          eaten_at: '2026-08-25T12:30:00Z',
          items: [
            { name: 'rice', calories_kcal: 220, carbs_g: 48 },
            { name: 'chicken', quantity: 120, unit: 'g', calories_kcal: 200, protein_g: 38, fat_g: 5 },
          ],
        },
      })
      expect(logged.isError).not.toBe(true)
      expect(logged.structuredContent).toMatchObject({ recorded: true })

      const day = await clients.a.callTool({ name: 'get_day', arguments: { date: '2026-08-25' } })
      expect(day.isError).not.toBe(true)
      expect(day.structuredContent).toMatchObject({
        meals: [{ items: [{ name: 'rice' }, { name: 'chicken' }] }],
        totals: { calories_kcal: 420, protein_g: 38, carbs_g: 48, fat_g: 5 },
      })

      const readProfile = await clients.a.callTool({ name: 'get_profile', arguments: {} })
      expect(readProfile.structuredContent).toMatchObject({ sex: 'male', weight_kg: 80 })

      const goals = await clients.a.callTool({
        name: 'set_goals',
        arguments: { calorie_target_kcal: 2000 },
      })
      expect(goals.isError).not.toBe(true)
      expect(goals.structuredContent).toMatchObject({ ok: true, source: 'manual' })
      const readGoals = await clients.a.callTool({ name: 'get_goals', arguments: {} })
      expect(readGoals.structuredContent).toMatchObject({
        calorie_target_kcal: 2000,
        protein_g: 207,
        source: 'manual',
      })
    } finally {
      await clients.a.close()
      await clients.b.close()
    }
  })

  it('delete_meal_log irreversibly removes the owned record and its items', async () => {
    const repository = new InMemoryRepository()
    const clients = await connectPair(repository)
    try {
      const logged = await clients.a.callTool({
        name: 'log_meal',
        arguments: {
          meal_type: 'dinner',
          eaten_at: '2026-08-25T19:00:00Z',
          items: [{ name: 'soup', calories_kcal: 300 }],
        },
      })
      const mealLogId = mealLogIdOf(logged)
      if (typeof mealLogId !== 'string') {
        throw new Error('log_meal did not return a meal_log_id')
      }
      const day = await clients.a.callTool({ name: 'get_day', arguments: { date: '2026-08-25' } })
      const itemId = mealItemId(day)
      if (itemId === undefined) {
        throw new Error('get_day did not return the logged item')
      }

      const deleted = await clients.a.callTool({
        name: 'delete_meal_log',
        arguments: { meal_log_id: mealLogId },
      })
      expect(deleted.isError).not.toBe(true)
      expect(deleted.structuredContent).toMatchObject({ ok: true, deleted: true })

      const afterDelete = await clients.a.callTool({ name: 'get_day', arguments: { date: '2026-08-25' } })
      expect(afterDelete.structuredContent).toMatchObject({ meals: [] })

      // The items went with the log (cascade delete): correcting the old item
      // now fails, and a second delete of the same log errors instead of
      // succeeding against an archive/soft-delete row.
      const itemUpdate = await clients.a.callTool({
        name: 'update_meal_item',
        arguments: { item_id: itemId, calories_kcal: 1 },
      })
      expect(itemUpdate.isError).toBe(true)
      expect(errorText(itemUpdate)).toContain('not_found')

      const secondDelete = await clients.a.callTool({
        name: 'delete_meal_log',
        arguments: { meal_log_id: mealLogId },
      })
      expect(secondDelete.isError).toBe(true)
      expect(errorText(secondDelete)).toContain('not_found')
    } finally {
      await clients.a.close()
      await clients.b.close()
    }
  })

  it('cross-user operations stay rejected and annotations cannot widen access', async () => {
    const repository = new InMemoryRepository()
    const clients = await connectPair(repository)
    try {
      const logged = await clients.a.callTool({
        name: 'log_meal',
        arguments: {
          meal_type: 'breakfast',
          eaten_at: '2026-08-25T08:00:00Z',
          items: [{ name: 'eggs', calories_kcal: 250 }],
        },
      })
      const mealLogId = mealLogIdOf(logged)
      if (typeof mealLogId !== 'string') {
        throw new Error('log_meal did not return a meal_log_id')
      }
      const dayA = await clients.a.callTool({ name: 'get_day', arguments: { date: '2026-08-25' } })
      const itemId = mealItemId(dayA)
      if (itemId === undefined) {
        throw new Error('get_day did not return the logged item')
      }

      // User B cannot read A's day, correct A's item, or delete A's meal.
      const dayB = await clients.b.callTool({ name: 'get_day', arguments: { date: '2026-08-25' } })
      expect(dayB.isError).not.toBe(true)
      expect(dayB.structuredContent).toMatchObject({ meals: [] })

      const updateB = await clients.b.callTool({
        name: 'update_meal_item',
        arguments: { item_id: itemId, calories_kcal: 1 },
      })
      expect(updateB.isError).toBe(true)
      expect(errorText(updateB)).toContain('not_found')

      const deleteB = await clients.b.callTool({
        name: 'delete_meal_log',
        arguments: { meal_log_id: mealLogId },
      })
      expect(deleteB.isError).toBe(true)
      expect(errorText(deleteB)).toContain('not_found')

      // A's data is intact, and a re-list returns the same server-authored
      // metadata: no call path can alter the annotations contract.
      const dayAAgain = await clients.a.callTool({ name: 'get_day', arguments: { date: '2026-08-25' } })
      expect(dayAAgain.structuredContent).toMatchObject({ meals: [{ items: [{ name: 'eggs' }] }] })

      const listedAgain = await clients.b.listTools()
      const byName = new Map(listedAgain.tools.map((tool) => [tool.name, tool]))
      expect(byName.get('get_day')?.annotations?.readOnlyHint).toBe(true)
      expect(byName.get('delete_meal_log')?.annotations?.destructiveHint).toBe(true)
      expect(byName.get('log_meal')?.annotations?.readOnlyHint).toBe(false)
    } finally {
      await clients.a.close()
      await clients.b.close()
    }
  })

  it('annotations are advisory: a destructive-annotated delete of own data still executes', async () => {
    const repository = new InMemoryRepository()
    const clients = await connectPair(repository)
    try {
      const logged = await clients.a.callTool({
        name: 'log_meal',
        arguments: {
          meal_type: 'snack',
          eaten_at: '2026-08-25T15:00:00Z',
          items: [{ name: 'yogurt', calories_kcal: 150 }],
        },
      })
      const mealLogId = mealLogIdOf(logged)
      if (typeof mealLogId !== 'string') {
        throw new Error('log_meal did not return a meal_log_id')
      }
      // delete_meal_log advertises destructiveHint: true, yet the server does
      // not consult annotations at call time: the owner's delete is served.
      const deleted = await clients.a.callTool({
        name: 'delete_meal_log',
        arguments: { meal_log_id: mealLogId },
      })
      expect(deleted.isError).not.toBe(true)
      expect(deleted.structuredContent).toMatchObject({ deleted: true })
    } finally {
      await clients.a.close()
      await clients.b.close()
    }
  })
})
