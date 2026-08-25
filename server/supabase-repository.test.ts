import { describe, expect, it } from 'vitest'
import type { MealWrite } from './repository.js'
import type { Profile } from '../packages/schema/food-types.js'
import { createSupabaseRepository, type SupabaseRepository } from './supabase-repository.js'

const userId = '00000000-0000-4000-8000-000000000003'
const mealId = '00000000-0000-4000-8000-000000000004'
const itemId = '00000000-0000-4000-8000-000000000005'

type MealRpcMode = 'success' | 'failure'

interface RecordedRequest {
  url: string
  method: string
  authorization: string | null
  body: string | undefined
}

function jsonResponse(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

function mealWrite(): MealWrite {
  return {
    eaten_at: '2026-08-25T12:30:00.000Z',
    meal_type: 'lunch',
    source: 'manual',
    items: [{ name: 'rice', quantity: 1, unit: 'serving', calories_kcal: 220 }],
  }
}

function createRepository(mode: MealRpcMode = 'success'): { repository: SupabaseRepository; requests: RecordedRequest[] } {
  const requests: RecordedRequest[] = []
  const fetchMock = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const request = input instanceof Request
      ? new Request(input, init)
      : new Request(input.toString(), init)
    const body = request.method === 'GET' ? undefined : await request.text()
    requests.push({
      url: request.url,
      method: request.method,
      authorization: request.headers.get('authorization'),
      body,
    })

    if (request.url.includes('/rest/v1/users')) {
      return jsonResponse({ id: userId })
    }
    if (request.url.includes('/rest/v1/profiles?')) {
      return jsonResponse({
        user_id: userId,
        sex: 'male',
        age_years: 30,
        height_cm: 180,
        weight_kg: 80,
        activity_level: 'moderate',
        diet_goal: 'maintain',
        goal_weight_kg: null,
        updated_at: '2026-08-25T12:00:00.000Z',
      })
    }
    if (request.url.includes('/rest/v1/rpc/compute_targets')) {
      return jsonResponse([{
        bmr_kcal: 1_234,
        tdee_kcal: 2_345,
        calorie_target_kcal: 2_222,
        protein_g: 111,
        carbs_g: 222,
        fat_g: 55,
      }])
    }
    if (request.url.includes('/rest/v1/rpc/log_meal_with_items')) {
      if (mode === 'failure') {
        return jsonResponse({ code: '23514', message: 'meal item constraint failed' }, 400)
      }
      return jsonResponse([{
        meal_log_id: mealId,
        eaten_at: '2026-08-25T12:30:00.000Z',
        meal_type: 'lunch',
        items: [{
          item_id: itemId,
          name: 'rice',
          quantity: 1,
          unit: 'serving',
          calories_kcal: 220,
          protein_g: null,
          carbs_g: null,
          fat_g: null,
          fiber_g: null,
          sugar_g: null,
          barcode: null,
          food_ref_id: null,
          confidence: null,
          notes: null,
        }],
      }])
    }
    if (request.url.includes('/rest/v1/meal_logs?select=id%2Ceaten_at%2Cmeal_type')) {
      return jsonResponse([{ id: mealId, eaten_at: '2026-08-25T12:30:00.000Z', meal_type: 'lunch' }])
    }
    if (request.url.includes('/rest/v1/meal_items?select=id%2Cmeal_log_id')) {
      return jsonResponse([{
        id: itemId,
        meal_log_id: mealId,
        name: 'rice',
        quantity: 1,
        unit: 'serving',
        calories_kcal: 220,
        protein_g: null,
        carbs_g: null,
        fat_g: null,
        fiber_g: null,
        sugar_g: null,
        barcode: null,
        food_ref_id: null,
        confidence: null,
        source_notes: null,
      }])
    }
    if (request.url.includes('/rest/v1/meal_items?select=meal_log_id')) {
      return jsonResponse({ meal_log_id: mealId })
    }
    if (request.method === 'GET' && request.url.includes('/rest/v1/meal_logs?select=id&id=eq.')) {
      return jsonResponse({ id: mealId })
    }
    if (request.url.includes('/rest/v1/meal_items?id=eq.')) {
      return jsonResponse([{ id: itemId }])
    }
    if (request.method === 'DELETE' && request.url.includes('/rest/v1/meal_logs')) {
      return jsonResponse([{ id: mealId }])
    }
    if (request.url.includes('/rest/v1/weight_logs?')) {
      return jsonResponse([])
    }
    return jsonResponse({ message: 'unexpected test request' }, 500)
  }
  fetchMock.preconnect = (): void => undefined

  return {
    repository: createSupabaseRepository('https://morsel.test', 'test-anon-key', { fetch: fetchMock }),
    requests,
  }
}

function withTestToken<T>(repository: SupabaseRepository, action: () => Promise<T>): Promise<T> {
  return repository.withAccessToken('token-one', action)
}

describe('SupabaseRepository', () => {
  it('binds each repository operation to its request bearer token', async () => {
    const { repository, requests } = createRepository()

    await repository.withAccessToken('token-one', () => repository.ensureUser(userId, 'test@example.com'))
    await repository.withAccessToken('token-two', () => repository.ensureUser(userId, 'test@example.com'))

    const userRequests = requests.filter((request) => request.url.includes('/rest/v1/users'))
    expect(userRequests.map((request) => request.authorization)).toEqual([
      'Bearer token-one',
      'Bearer token-two',
    ])
  })

  it('uses the SQL target RPC response instead of recomputing targets in the service', async () => {
    const { repository, requests } = createRepository()
    const profile: Profile = {
      sex: 'male',
      age_years: 30,
      height_cm: 180,
      weight_kg: 80,
      activity_level: 'moderate',
      diet_goal: 'maintain',
    }

    await withTestToken(repository, async () => {
      await expect(repository.computeTargets(userId, profile)).resolves.toEqual({
        bmr_kcal: 1_234,
        tdee_kcal: 2_345,
        calorie_target_kcal: 2_222,
        protein_g: 111,
        carbs_g: 222,
        fat_g: 55,
      })
    })

    const request = requests.find((candidate) => candidate.url.includes('/rest/v1/rpc/compute_targets'))
    expect(request?.method).toBe('POST')
    expect(request?.body).toContain(`"user_id":"${userId}"`)
  })

  it('creates the meal and items through one atomic RPC', async () => {
    const { repository, requests } = createRepository()

    await withTestToken(repository, async () => {
      await expect(repository.createMealWithItems(userId, mealWrite())).resolves.toMatchObject({
        meal_log_id: mealId,
        items: [{ item_id: itemId, name: 'rice' }],
      })
    })

    const rpcRequests = requests.filter((request) => request.url.includes('/rest/v1/rpc/log_meal_with_items'))
    expect(rpcRequests).toHaveLength(1)
    expect(rpcRequests[0]?.method).toBe('POST')
    expect(rpcRequests[0]?.authorization).toBe('Bearer token-one')
    expect(rpcRequests[0]?.body).toContain(`"p_user_id":"${userId}"`)
    expect(requests.some((request) => request.url.includes('/rest/v1/meal_logs') && request.method === 'POST')).toBe(false)
    expect(requests.some((request) => request.url.includes('/rest/v1/meal_items') && request.method === 'POST')).toBe(false)
  })

  it('surfaces an RPC failure without attempting a partial-row rollback', async () => {
    const { repository, requests } = createRepository('failure')

    await withTestToken(repository, async () => {
      await expect(repository.createMealWithItems(userId, mealWrite())).rejects.toMatchObject({
        code: 'transaction_failed',
      })
    })
    expect(requests.filter((request) => request.url.includes('/rest/v1/rpc/log_meal_with_items'))).toHaveLength(1)
    expect(requests.some((request) => request.url.includes('/rest/v1/meal_logs') || request.url.includes('/rest/v1/meal_items'))).toBe(false)
  })

  it('keeps user scoping on reads, ownership checks, and deletes', async () => {
    const { repository, requests } = createRepository()

    await withTestToken(repository, async () => {
      await repository.getMealsInRange(userId, '2026-08-25T00:00:00.000Z', '2026-08-26T00:00:00.000Z')
      await repository.updateMealItem(userId, { item_id: itemId, calories_kcal: 300 })
      await repository.deleteMealLog(userId, mealId)
    })

    const mealRead = requests.find((request) => request.url.includes('/rest/v1/meal_logs?select=id%2Ceaten_at%2Cmeal_type'))
    expect(mealRead?.url).toContain(`user_id=eq.${userId}`)
    const parentCheck = requests.find((request) => request.url.includes('/rest/v1/meal_logs?select=id&id=eq.'))
    expect(parentCheck?.url).toContain(`user_id=eq.${userId}`)
    const mealDelete = requests.find((request) => request.method === 'DELETE' && request.url.includes('/rest/v1/meal_logs'))
    expect(mealDelete?.url).toContain(`user_id=eq.${userId}`)
  })
})
