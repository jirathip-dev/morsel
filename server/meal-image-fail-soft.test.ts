import { afterEach, describe, expect, it, vi } from 'vitest'
import { createSupabaseRepository, type SupabaseRepository } from './supabase-repository.js'
import { MorselService } from './service.js'

// Issue #149 — one meal with an unreadable photo (missing storage object or
// a storage request failure) used to abort the ENTIRE get_day /
// get_dashboard_summary read: signedMealImage() threw RepositoryError and the
// meal-mapping loop awaited it unguarded per meal. These tests are the
// RED/GREEN regression: they fail at the pristine base (read rejects with
// store_error) and pass when the read mints signed URLs fail-soft per meal.
//
// - A storage 404 for one meal's object -> get_day still returns the other
//   meals; the corrupt meal comes back WITHOUT image (MealImageRecordSchema
//   is strict and optional on MealRecordSchema, so an unreadable photo
//   degrades to no photo for this read).
// - The drift signal is one structured console.error line per read with the
//   failure count, meal_log_id + failure category per meal, and never the
//   object path or any signed-URL/token material.

const userId = '00000000-0000-4000-8000-000000000001'
const healthyMealId = '00000000-0000-4000-8000-000000000006'
const missingObjectMealId = '00000000-0000-4000-8000-000000000007'
const networkFailMealId = '00000000-0000-4000-8000-000000000008'
const healthyImagePath = `${userId}/${healthyMealId}.jpg`
const missingObjectPath = `${userId}/${missingObjectMealId}.jpg`
const networkFailPath = `${userId}/${networkFailMealId}.jpg`
const MEAL_IMAGE_UNAVAILABLE_PREFIX = 'meal image signed URL unavailable '
const fixedNow = () => new Date('2026-08-25T12:00:00.000Z')

interface MealRow {
  id: string
  eaten_at: string
  meal_type: string
  image_path?: string
}

type SignMode = 'ok' | 'missing-object' | 'network'

function jsonResponse(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

const itemId = '00000000-0000-4000-8000-000000000011'

function itemRow(mealLogId: string): Record<string, unknown> {
  return {
    id: itemId,
    meal_log_id: mealLogId,
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
  }
}

interface Harness {
  repository: SupabaseRepository
  service: MorselService
}

function createHarness(meals: MealRow[], signModes: Record<string, SignMode>): Harness {
  const fetchMock = (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const request = input instanceof Request
      ? new Request(input, init)
      : new Request(input.toString(), init)

    if (request.method === 'GET' && request.url.includes('/rest/v1/profiles')) {
      return Promise.resolve(jsonResponse([]))
    }
    if (request.method === 'GET' && request.url.includes('/rest/v1/goals')) {
      return Promise.resolve(jsonResponse([]))
    }
    if (request.method === 'GET' && request.url.includes('/rest/v1/weight_logs')) {
      return Promise.resolve(jsonResponse([]))
    }
    if (request.method === 'GET' && request.url.includes('/rest/v1/meal_logs?select=')) {
      return Promise.resolve(jsonResponse(meals))
    }
    if (request.method === 'GET' && request.url.includes('/rest/v1/meal_items')) {
      const rows: Record<string, unknown>[] = meals.map((meal) => itemRow(meal.id))
      return Promise.resolve(jsonResponse(rows))
    }
    if (request.url.includes('/storage/v1/object/sign/food-images/')) {
      const objectPath = new URL(request.url).pathname.replace('/storage/v1/object/sign/food-images/', '')
      const mode = signModes[objectPath] ?? 'ok'
      if (mode === 'missing-object') {
        // The storage object is gone (or the path never existed): a non-2xx
        // makes the storage SDK return { data: null, error }.
        return Promise.resolve(jsonResponse({ message: 'The resource was not found' }, 404))
      }
      if (mode === 'network') {
        // The storage request itself fails (SDK fetch rejection).
        return Promise.reject(new Error('storage network failure'))
      }
      return Promise.resolve(jsonResponse({ signedURL: `/object/sign/food-images/${objectPath}?token=read-token` }))
    }
    return Promise.resolve(jsonResponse({ message: 'unexpected test request' }, 500))
  }
  fetchMock.preconnect = (): void => undefined

  const repository = createSupabaseRepository('https://morsel.test', 'test-anon-key', { fetch: fetchMock })
  return {
    repository,
    service: new MorselService({ repository, userId, now: fixedNow }),
  }
}

function withToken<T>(repository: SupabaseRepository, action: () => Promise<T>): Promise<T> {
  return repository.withAccessToken('token-one', action)
}

function logCalls(spy: ReturnType<typeof vi.spyOn>, prefix: string): string[] {
  return spy.mock.calls
    .map((call) => (typeof call[0] === 'string' ? call[0] : ''))
    .filter((line) => line.startsWith(prefix))
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

function parsedLogPayload(line: string, prefix: string): Record<string, unknown> {
  const payload: unknown = JSON.parse(line.slice(prefix.length).trim())
  if (!isRecord(payload)) {
    throw new Error('log line payload is not an object')
  }
  return payload
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe('fail-soft signed-URL reads (issue #149)', () => {
  it('get_day returns the other meals and the corrupt meal without image when one object cannot be signed', async () => {
    const errorSpy = vi.spyOn(console, 'error')
    const { repository, service } = createHarness(
      [
        { id: healthyMealId, eaten_at: '2026-08-25T12:30:00.000Z', meal_type: 'lunch', image_path: healthyImagePath },
        { id: missingObjectMealId, eaten_at: '2026-08-25T18:00:00.000Z', meal_type: 'dinner', image_path: missingObjectPath },
      ],
      { [missingObjectPath]: 'missing-object' },
    )

    const day = await withToken(repository, () => service.getDay({ date: '2026-08-25' }))

    // Both meals come back (the corrupt one WITHOUT an image, per contract:
    // MealImageRecordSchema has no error variant, so an unreadable photo
    // degrades to no photo for this read).
    expect(day.meals.map((meal) => meal.meal_log_id)).toEqual([healthyMealId, missingObjectMealId])
    const healthy = day.meals.find((meal) => meal.meal_log_id === healthyMealId)
    const corrupt = day.meals.find((meal) => meal.meal_log_id === missingObjectMealId)
    expect(healthy?.image).toMatchObject({
      path: healthyImagePath,
      signed_url: `https://morsel.test/storage/v1/object/sign/food-images/${healthyImagePath}?token=read-token`,
    })
    expect(healthy?.image?.expires_at).toMatch(/^\d{4}-\d{2}-\d{2}T/)
    expect(corrupt?.image).toBeUndefined()
    expect(corrupt?.items).toHaveLength(1)

    // The failure is observable through ONE structured log line: count +
    // meal_log_id + category, never object paths or signed-URL material.
    const failureLogs = logCalls(errorSpy, MEAL_IMAGE_UNAVAILABLE_PREFIX)
    expect(failureLogs).toHaveLength(1)
    const payload = parsedLogPayload(failureLogs[0] ?? '', MEAL_IMAGE_UNAVAILABLE_PREFIX)
    expect(payload.count).toBe(1)
    expect(payload.meal_image_failures).toEqual([
      { meal_log_id: missingObjectMealId, category: 'storage_request_failed' },
    ])
    const logText = failureLogs[0] ?? ''
    expect(logText).not.toContain(missingObjectPath)
    expect(logText).not.toContain(healthyImagePath)
    expect(logText).not.toContain('read-token')
  })

  it('get_day degrades when the storage request itself fails for one meal', async () => {
    const errorSpy = vi.spyOn(console, 'error')
    const { repository, service } = createHarness(
      [
        { id: healthyMealId, eaten_at: '2026-08-25T12:30:00.000Z', meal_type: 'lunch', image_path: healthyImagePath },
        { id: networkFailMealId, eaten_at: '2026-08-25T19:00:00.000Z', meal_type: 'snack', image_path: networkFailPath },
      ],
      { [networkFailPath]: 'network' },
    )

    const day = await withToken(repository, () => service.getDay({ date: '2026-08-25' }))

    expect(day.meals.map((meal) => meal.meal_log_id)).toEqual([healthyMealId, networkFailMealId])
    expect(day.meals.find((meal) => meal.meal_log_id === healthyMealId)?.image?.path).toBe(healthyImagePath)
    expect(day.meals.find((meal) => meal.meal_log_id === networkFailMealId)?.image).toBeUndefined()

    const failureLogs = logCalls(errorSpy, MEAL_IMAGE_UNAVAILABLE_PREFIX)
    expect(failureLogs).toHaveLength(1)
    const payload = parsedLogPayload(failureLogs[0] ?? '', MEAL_IMAGE_UNAVAILABLE_PREFIX)
    expect(payload.count).toBe(1)
    expect(payload.meal_image_failures).toEqual([
      { meal_log_id: networkFailMealId, category: 'storage_request_failed' },
    ])
    expect(failureLogs[0] ?? '').not.toContain(networkFailPath)
    expect(failureLogs[0] ?? '').not.toContain('read-token')
  })

  it('get_dashboard_summary resolves across the same fail-soft read with both failure kinds', async () => {
    const errorSpy = vi.spyOn(console, 'error')
    const { repository, service } = createHarness(
      [
        { id: healthyMealId, eaten_at: '2026-08-25T12:30:00.000Z', meal_type: 'lunch', image_path: healthyImagePath },
        { id: missingObjectMealId, eaten_at: '2026-08-25T18:00:00.000Z', meal_type: 'dinner', image_path: missingObjectPath },
        { id: networkFailMealId, eaten_at: '2026-08-25T19:00:00.000Z', meal_type: 'snack', image_path: networkFailPath },
      ],
      { [missingObjectPath]: 'missing-object', [networkFailPath]: 'network' },
    )

    const summary = await withToken(repository, () => service.getDashboardSummary({ days: 7 }))

    // The summary itself no longer dies as store_error; healthy photos still
    // mint and the failing meals are counted in the structured log.
    expect(summary.date).toBe('2026-08-25')
    const failureLogs = logCalls(errorSpy, MEAL_IMAGE_UNAVAILABLE_PREFIX)
    expect(failureLogs).toHaveLength(1)
    const payload = parsedLogPayload(failureLogs[0] ?? '', MEAL_IMAGE_UNAVAILABLE_PREFIX)
    expect(payload.count).toBe(2)
    expect(payload.meal_image_failures).toEqual([
      { meal_log_id: missingObjectMealId, category: 'storage_request_failed' },
      { meal_log_id: networkFailMealId, category: 'storage_request_failed' },
    ])
    const logText = failureLogs[0] ?? ''
    expect(logText).not.toContain(missingObjectPath)
    expect(logText).not.toContain(networkFailPath)
    expect(logText).not.toContain('read-token')
  })
})
