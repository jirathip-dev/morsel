import { afterEach, describe, expect, it, vi } from 'vitest'
import { createSupabaseRepository, type SupabaseRepository } from './supabase-repository.js'
import { MorselService } from './service.js'
import { InMemoryRepository } from './in-memory-repository.js'

// Issue #258 — a `meal_items` read failure used to ABORT the whole day: the
// items query was unwrapped (`requireData(... 'meal item read')` throws), so
// one unavailable item row hid every meal of the day as `store_error:
// meal item read failed` — the exact string in the reported live incident.
//
// These tests are the committed regression proof: at the pristine base the
// day/dashboard reads reject (case 1/2) and the degraded markers do not exist;
// with the fix they resolve, keep every meal, and state which meals are
// incomplete through `items_read: 'incomplete'`.
//
// Contract under test (schema-first, issue #258):
// - `meal_items` query failure  -> every meal of the read is returned flagged
//   `incomplete` (category `read_failed`); the read NEVER degrades to `meals: []`.
// - one unreadable item row     -> only the meal that owns it is flagged
//   (`invalid_row`); its readable rows and every other meal stay intact.
// - a healthy read              -> every meal carries `items_read: 'complete'`
//   and no drift line is logged (regression control).
// - #149 stays intact           -> an unreadable photo still degrades to no
//   photo without aborting, next to a degraded item read.
// - the drift signal is ONE structured console.error line per read with count,
//   meal ids and a category — never item names, nutrition values or payloads.

const userId = '00000000-0000-4000-8000-000000000001'
const lunchMealId = '00000000-0000-4000-8000-000000000006'
const dinnerMealId = '00000000-0000-4000-8000-000000000007'
const snackMealId = '00000000-0000-4000-8000-000000000008'
const MEAL_ITEMS_UNAVAILABLE_PREFIX = 'meal items unavailable '
const fixedNow = () => new Date('2026-08-25T12:00:00.000Z')

interface MealRow {
  id: string
  eaten_at: string
  meal_type: string
  image_path?: string
}

type SignMode = 'ok' | 'missing-object'

interface HarnessOptions {
  meals: MealRow[]
  /// Rows returned by the `meal_items` read, keyed by nothing: the read is one
  /// query for every meal of the day.
  items: (meals: MealRow[]) => Record<string, unknown>[]
  /// The `meal_items` request itself fails (PostgREST error, no data).
  itemsError?: boolean
  signModes?: Record<string, SignMode>
}

function jsonResponse(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

function itemRow(mealLogId: string, overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: '00000000-0000-4000-8000-000000000011',
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
    menu_group_id: null,
    menu_name: null,
    ...overrides,
  }
}

function threeMeals(): MealRow[] {
  return [
    { id: lunchMealId, eaten_at: '2026-08-25T05:00:00.000Z', meal_type: 'lunch' },
    { id: dinnerMealId, eaten_at: '2026-08-25T12:00:00.000Z', meal_type: 'dinner' },
    { id: snackMealId, eaten_at: '2026-08-25T14:30:00.000Z', meal_type: 'snack' },
  ]
}

function oneItemPerMeal(meals: MealRow[]): Record<string, unknown>[] {
  return meals.map((meal) => itemRow(meal.id))
}

interface Harness {
  repository: SupabaseRepository
  service: MorselService
}

function createHarness(options: HarnessOptions): Harness {
  const signModes = options.signModes ?? {}
  const fetchMock = (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const request = input instanceof Request
      ? new Request(input, init)
      : new Request(input.toString(), init)

    if (request.method === 'POST' && request.url.includes('/rest/v1/rpc/get_dated_targets')) {
      return Promise.resolve(jsonResponse([]))
    }
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
      return Promise.resolve(jsonResponse(options.meals))
    }
    if (request.method === 'GET' && request.url.includes('/rest/v1/meal_items')) {
      if (options.itemsError === true) {
        // PostgREST error: the SDK resolves { data: null, error }.
        return Promise.resolve(jsonResponse({ message: 'permission denied for table meal_items' }, 500))
      }
      return Promise.resolve(jsonResponse(options.items(options.meals)))
    }
    if (request.url.includes('/storage/v1/object/sign/food-images/')) {
      const objectPath = new URL(request.url).pathname.replace('/storage/v1/object/sign/food-images/', '')
      if ((signModes[objectPath] ?? 'ok') === 'missing-object') {
        return Promise.resolve(jsonResponse({ message: 'The resource was not found' }, 404))
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

function failLines(spy: ReturnType<typeof vi.spyOn>): string[] {
  return spy.mock.calls
    .map((call) => (typeof call[0] === 'string' ? call[0] : ''))
    .filter((line) => line.startsWith(MEAL_ITEMS_UNAVAILABLE_PREFIX))
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

function parsedLog(line: string): Record<string, unknown> {
  const payload: unknown = JSON.parse(line.slice(MEAL_ITEMS_UNAVAILABLE_PREFIX.length).trim())
  if (!isRecord(payload)) {
    throw new Error('log line payload is not an object')
  }
  return payload
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe('day read degrades on meal-item failure (issue #258)', () => {
  it('get_day returns every meal flagged incomplete when the item read fails', async () => {
    const errorSpy = vi.spyOn(console, 'error')
    const { repository, service } = createHarness({
      meals: threeMeals(),
      items: oneItemPerMeal,
      itemsError: true,
    })

    const day = await withToken(repository, () => service.getDay({ date: '2026-08-25' }))

    // Never `meals: []` for a read error (AC2): the day keeps its meals and
    // states the incompleteness on each one.
    expect(day.meals.map((meal) => meal.meal_log_id)).toEqual([lunchMealId, dinnerMealId, snackMealId])
    expect(day.meals.map((meal) => meal.items_read)).toEqual(['incomplete', 'incomplete', 'incomplete'])
    expect(day.meals.every((meal) => meal.items.length === 0)).toBe(true)

    // One structured drift line: count + meal ids + category, no payload.
    const lines = failLines(errorSpy)
    expect(lines).toHaveLength(1)
    expect(parsedLog(lines[0] ?? '')).toEqual({
      count: 3,
      meal_item_failures: [
        { meal_log_id: lunchMealId, category: 'read_failed' },
        { meal_log_id: dinnerMealId, category: 'read_failed' },
        { meal_log_id: snackMealId, category: 'read_failed' },
      ],
    })
    expect(lines[0] ?? '').not.toContain('rice')
    expect(lines[0] ?? '').not.toContain('220')
  })

  it('keeps the unaffected meals and rows intact when ONE item row is unreadable', async () => {
    const errorSpy = vi.spyOn(console, 'error')
    const { repository, service } = createHarness({
      meals: threeMeals(),
      items: (meals) => [
        ...oneItemPerMeal(meals),
        // One corrupt row of the dinner meal (unknown unit fails the row
        // contract) next to a readable one.
        itemRow(dinnerMealId, {
          id: '00000000-0000-4000-8000-000000000012',
          name: 'mystery stew',
          unit: 'furlongs',
        }),
        itemRow(dinnerMealId, { id: '00000000-0000-4000-8000-000000000013', name: 'salad', calories_kcal: 120 }),
      ],
    })

    const day = await withToken(repository, () => service.getDay({ date: '2026-08-25' }))

    expect(day.meals.map((meal) => meal.meal_log_id)).toEqual([lunchMealId, dinnerMealId, snackMealId])
    expect(day.meals.map((meal) => meal.items_read)).toEqual(['complete', 'incomplete', 'complete'])
    // The readable rows of the degraded meal survive; only the bad row is lost.
    expect(day.meals.find((meal) => meal.meal_log_id === dinnerMealId)?.items.map((item) => item.name))
      .toEqual(['rice', 'salad'])
    expect(day.meals.find((meal) => meal.meal_log_id === lunchMealId)?.items).toHaveLength(1)

    const lines = failLines(errorSpy)
    expect(lines).toHaveLength(1)
    expect(parsedLog(lines[0] ?? '')).toEqual({
      count: 1,
      meal_item_failures: [{ meal_log_id: dinnerMealId, category: 'invalid_row' }],
    })
    expect(lines[0] ?? '').not.toContain('mystery')
    expect(lines[0] ?? '').not.toContain('furlongs')
  })

  it('flags the whole read when an unreadable row cannot be attributed to a meal', async () => {
    const errorSpy = vi.spyOn(console, 'error')
    const { repository, service } = createHarness({
      meals: threeMeals(),
      items: (meals) => [...oneItemPerMeal(meals), { name: 'orphaned row', quantity: 1, unit: 'serving' }],
    })

    const day = await withToken(repository, () => service.getDay({ date: '2026-08-25' }))

    // An unattributable row can belong to any meal of the read: complete
    // cannot be claimed for the others, so the read says so instead of
    // dropping the row silently.
    expect(day.meals.map((meal) => meal.items_read)).toEqual(['incomplete', 'incomplete', 'incomplete'])
    expect(day.meals.every((meal) => meal.items.length === 1)).toBe(true)
    expect(parsedLog(failLines(errorSpy)[0] ?? '')).toEqual({
      count: 3,
      meal_item_failures: [
        { meal_log_id: lunchMealId, category: 'invalid_row' },
        { meal_log_id: dinnerMealId, category: 'invalid_row' },
        { meal_log_id: snackMealId, category: 'invalid_row' },
      ],
    })
  })

  it('marks in-memory day reads complete with and without a photo', async () => {
    const repository = new InMemoryRepository()
    const service = new MorselService({ repository, userId, now: fixedNow })
    const logged = await service.logMeal({
      meal_type: 'lunch', eaten_at: fixedNow().toISOString(),
      items: [{ name: 'rice', quantity: 1, unit: 'serving', calories_kcal: 220 }],
    })
    const plain = await service.getDay({ date: '2026-08-25' })
    expect(plain.meals.map((meal) => meal.items_read)).toEqual(['complete'])
    await repository.attachMealImage(userId, logged.meal_log_id, {
      bytes: Uint8Array.of(1, 2, 3), contentType: 'image/jpeg',
    })
    const pictured = await service.getDay({ date: '2026-08-25' })
    expect(pictured.meals.map((meal) => meal.items_read)).toEqual(['complete'])
    expect(pictured.meals[0]?.image).toBeDefined()
    expect(pictured.meals[0]?.items).toEqual(plain.meals[0]?.items)
  })

  it('marks every meal complete and logs nothing on a healthy read', async () => {
    const errorSpy = vi.spyOn(console, 'error')
    const { repository, service } = createHarness({ meals: threeMeals(), items: oneItemPerMeal })

    const day = await withToken(repository, () => service.getDay({ date: '2026-08-25' }))

    expect(day.meals.map((meal) => meal.items_read)).toEqual(['complete', 'complete', 'complete'])
    expect(day.meals.every((meal) => meal.items.length === 1)).toBe(true)
    expect(failLines(errorSpy)).toHaveLength(0)
  })

  it('degrades the item read and the photo together, without aborting the day (#149 preserved)', async () => {
    const errorSpy = vi.spyOn(console, 'error')
    const meals = threeMeals()
    const withPhoto = meals.map((meal, index) => (
      index === 0 ? { ...meal, image_path: `${userId}/${meal.id}.jpg` } : meal
    ))
    const { repository, service } = createHarness({
      meals: withPhoto,
      items: oneItemPerMeal,
      itemsError: true,
      signModes: { [`${userId}/${lunchMealId}.jpg`]: 'missing-object' },
    })

    const day = await withToken(repository, () => service.getDay({ date: '2026-08-25' }))

    expect(day.meals).toHaveLength(3)
    expect(day.meals.map((meal) => meal.items_read)).toEqual(['incomplete', 'incomplete', 'incomplete'])
    // #149: the unreadable photo still degrades to no photo, not an abort.
    expect(day.meals.every((meal) => meal.image === undefined)).toBe(true)
    const logged = errorSpy.mock.calls.map((call) => (typeof call[0] === 'string' ? call[0] : ''))
    expect(logged.filter((line) => line.startsWith('meal image signed URL unavailable '))).toHaveLength(1)
    expect(logged.filter((line) => line.startsWith(MEAL_ITEMS_UNAVAILABLE_PREFIX))).toHaveLength(1)
  })

  it('get_dashboard_summary resolves with items_read incomplete and an honest render', async () => {
    const errorSpy = vi.spyOn(console, 'error')
    const { repository, service } = createHarness({
      meals: threeMeals(),
      items: oneItemPerMeal,
      itemsError: true,
    })

    const summary = await withToken(repository, () => service.getDashboardSummary({ days: 7 }))

    expect(summary.date).toBe('2026-08-25')
    expect(summary.items_read).toBe('incomplete')
    // The degraded window is never presented as a complete read: the totals
    // are short and the render says why.
    expect(summary.render.markdown).toContain('Read incomplete')
    expect(summary.render.markdown).toContain('nothing was deleted')
    expect(summary.render.markdown).not.toContain('No meals logged')
    expect(failLines(errorSpy)).toHaveLength(1)
  })

  it('omits the summary marker and the render caveat on a healthy window', async () => {
    const { repository, service } = createHarness({ meals: threeMeals(), items: oneItemPerMeal })

    const summary = await withToken(repository, () => service.getDashboardSummary({ days: 7 }))

    expect(summary.items_read).toBeUndefined()
    expect(summary.render.markdown).not.toContain('Read incomplete')
    expect(summary.render.markdown).toContain('Streak:')
  })
})
