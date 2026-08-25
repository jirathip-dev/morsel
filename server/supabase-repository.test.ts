import { createClient } from '@supabase/supabase-js'
import { describe, expect, it } from 'vitest'
import type { Profile } from '../packages/schema/food-types.js'
import { SupabaseRepository } from './supabase-repository.js'
import type { Database } from './supabase-types.js'

const userId = '00000000-0000-4000-8000-000000000003'

interface RecordedRequest {
  url: string
  method: string
  body: string | undefined
}

function jsonResponse(value: unknown): Response {
  return new Response(JSON.stringify(value), {
    status: 200,
    headers: { 'content-type': 'application/json' },
  })
}

function createRepository(): { repository: SupabaseRepository; requests: RecordedRequest[] } {
  const requests: RecordedRequest[] = []
  const fetchMock = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const request = input instanceof Request
      ? new Request(input, init)
      : new Request(input.toString(), init)
    const body = request.method === 'GET' ? undefined : await request.text()
    requests.push({ url: request.url, method: request.method, body })

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
    return new Response(JSON.stringify({ message: 'unexpected test request' }), {
      status: 500,
      headers: { 'content-type': 'application/json' },
    })
  }
  fetchMock.preconnect = (): void => undefined
  const client = createClient<Database>('https://morsel.test', 'test-anon-key', {
    auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
    global: { fetch: fetchMock },
  })
  return { repository: new SupabaseRepository({ client }), requests }
}

describe('SupabaseRepository', () => {
  it('bootstraps the authenticated account before user-scoped writes', async () => {
    const { repository, requests } = createRepository()

    await repository.ensureUser(userId, 'test@example.com')

    const request = requests.find((candidate) => candidate.url.includes('/rest/v1/users'))
    expect(request?.method).toBe('POST')
    expect(request?.body).toContain(`"id":"${userId}"`)
    expect(request?.body).toContain('"email":"test@example.com"')
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

    await expect(repository.computeTargets(userId, profile)).resolves.toEqual({
      bmr_kcal: 1_234,
      tdee_kcal: 2_345,
      calorie_target_kcal: 2_222,
      protein_g: 111,
      carbs_g: 222,
      fat_g: 55,
    })

    const request = requests.find((candidate) => candidate.url.includes('/rest/v1/rpc/compute_targets'))
    expect(request?.method).toBe('POST')
    expect(request?.body).toContain(`"user_id":"${userId}"`)
  })
})
