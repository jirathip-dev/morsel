import { describe, expect, it } from 'vitest'
import { createSupabaseRepository, type SupabaseRepository } from './supabase-repository.js'
import { InMemoryRepository } from './in-memory-repository.js'
import { MorselService } from './service.js'
import {
  MEAL_IMAGE_MAX_DECODED_BYTES,
  MEAL_IMAGE_MAX_FETCH_BYTES,
  type MealImageFetcher,
} from './meal-image.js'

// Issue #122 — real photo attachment through MCP. These tests are the RED/GREEN
// storage contract: they fail at the pristine base (no image_base64 input, no
// attach_meal_image, no image read-back) and pass at the head.
//
// - log_meal with image_base64 -> bytes stored at {user_id}/{meal_log_id}.jpg
//   under the caller's bearer token; get_day returns image.path + signed_url.
// - image_url is fetched once with size/type/HTTPS limits; any failure reports
//   image_error while the meal is still logged (never a silent drop).
// - attach_meal_image attaches a photo to an existing meal.

const userId = '00000000-0000-4000-8000-000000000001'
const otherUserId = '00000000-0000-4000-8000-000000000002'
const fixedNow = () => new Date('2026-08-25T12:00:00.000Z')

const jpegBytes = new Uint8Array([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x02, 0x03])
const pngBytes = new Uint8Array([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])
const textBytes = new Uint8Array([0x3C, 0x68, 0x74, 0x6D, 0x6C, 0x3E])

function encodeBase64(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString('base64')
}

function sameBytes(actual: Uint8Array | undefined, expected: Uint8Array): boolean {
  return actual !== undefined && Buffer.from(actual).equals(Buffer.from(expected))
}

function jpegResponse(bytes: Uint8Array, contentType = 'image/jpeg'): Response {
  return new Response(bytes, { headers: { 'content-type': contentType } })
}

function mealInput(image: Record<string, unknown>): Record<string, unknown> {
  return {
    meal_type: 'lunch',
    eaten_at: '2026-08-25T12:30:00.000Z',
    items: [{ name: 'rice', calories_kcal: 220 }],
    ...image,
  }
}

function base64MealLogInput(bytes: Uint8Array, mimeType: 'image/jpeg' | 'image/png' | 'image/webp'): Record<string, unknown> {
  return mealInput({ image_base64: { data: encodeBase64(bytes), mime_type: mimeType } })
}

function createService(repository: InMemoryRepository, fetcher?: MealImageFetcher): MorselService {
  return new MorselService({ repository, userId, now: fixedNow, ...(fetcher === undefined ? {} : { imageFetcher: fetcher }) })
}

describe('MorselService meal photos (in-memory repository)', () => {
  it('log_meal with image_base64 stores the exact bytes and get_day returns image.path + signed_url', async () => {
    const repository = new InMemoryRepository()
    const service = createService(repository)

    const logged = await service.logMeal(base64MealLogInput(jpegBytes, 'image/jpeg'))

    expect(logged.recorded).toBe(true)
    expect(logged.image_error).toBeUndefined()
    const stored = repository.storedMealImage(userId, logged.meal_log_id)
    expect(sameBytes(stored?.bytes, jpegBytes)).toBe(true)
    expect(stored?.contentType).toBe('image/jpeg')

    const day = await service.getDay({ date: '2026-08-25' })
    expect(day.meals).toHaveLength(1)
    const image = day.meals[0]?.image
    expect(image?.path).toBe(`${userId}/${logged.meal_log_id}.jpg`)
    expect(image?.signed_url).toContain(`/object/sign/food-images/${userId}/${logged.meal_log_id}.jpg`)
    expect(image?.expires_at).toMatch(/^\d{4}-\d{2}-\d{2}T/)
  })

  it('image_url input is fetched exactly once and the fetched bytes are stored', async () => {
    const repository = new InMemoryRepository()
    const calls: string[] = []
    const fetcher: MealImageFetcher = (input) => {
      calls.push(input)
      return Promise.resolve(jpegResponse(jpegBytes))
    }
    const service = createService(repository, fetcher)

    const logged = await service.logMeal(mealInput({ image_url: 'https://photos.example/meal.jpg' }))

    expect(calls).toEqual(['https://photos.example/meal.jpg'])
    expect(logged.image_error).toBeUndefined()
    expect(sameBytes(repository.storedMealImage(userId, logged.meal_log_id)?.bytes, jpegBytes)).toBe(true)
  })

  it('image_base64 is preferred when both photo inputs are present (image_url is never fetched)', async () => {
    const repository = new InMemoryRepository()
    const fetcher: MealImageFetcher = () => Promise.reject(new Error('image_url must not be fetched when image_base64 is present'))
    const service = createService(repository, fetcher)

    const logged = await service.logMeal({
      ...base64MealLogInput(pngBytes, 'image/png'),
      image_url: 'https://photos.example/meal.jpg',
    })

    expect(logged.image_error).toBeUndefined()
    expect(sameBytes(repository.storedMealImage(userId, logged.meal_log_id)?.bytes, pngBytes)).toBe(true)
    expect(repository.storedMealImage(userId, logged.meal_log_id)?.contentType).toBe('image/png')
  })

  it('reports image_error and still logs the meal when storage rejects the upload', async () => {
    const repository = new InMemoryRepository()
    repository.setFailNextMealImageWrite()
    const service = createService(repository)

    const logged = await service.logMeal(base64MealLogInput(jpegBytes, 'image/jpeg'))

    expect(logged.recorded).toBe(true)
    expect(logged.image_error).toContain('could not be stored')
    const day = await service.getDay({ date: '2026-08-25' })
    expect(day.meals[0]?.image).toBeUndefined()
  })

  it('reports image_error for a base64 photo over the 5 MB budget while still logging the meal', async () => {
    const repository = new InMemoryRepository()
    const service = createService(repository)
    const oversized = new Uint8Array(MEAL_IMAGE_MAX_DECODED_BYTES + 1)
    oversized.set(jpegBytes)

    const logged = await service.logMeal(base64MealLogInput(oversized, 'image/jpeg'))

    expect(logged.recorded).toBe(true)
    expect(logged.image_error).toContain('too large')
    expect(repository.storedMealImage(userId, logged.meal_log_id)).toBeUndefined()
  })

  it('reports image_error when the bytes do not match the declared mime (no mislabeled bytes are stored)', async () => {
    const repository = new InMemoryRepository()
    const service = createService(repository)

    const logged = await service.logMeal(base64MealLogInput(jpegBytes, 'image/png'))

    expect(logged.recorded).toBe(true)
    expect(logged.image_error).toContain('do not match the declared format')
    expect(repository.storedMealImage(userId, logged.meal_log_id)).toBeUndefined()
  })

  it('reports image_error for a non-image URL response while still logging the meal', async () => {
    const repository = new InMemoryRepository()
    const fetcher: MealImageFetcher = () => Promise.resolve(jpegResponse(textBytes, 'text/html'))
    const service = createService(repository, fetcher)

    const logged = await service.logMeal(mealInput({ image_url: 'https://photos.example/not-an-image' }))

    expect(logged.recorded).toBe(true)
    expect(logged.image_error).toContain('not a supported image')
    expect(repository.storedMealImage(userId, logged.meal_log_id)).toBeUndefined()
  })

  it('reports image_error for a URL body over 10 MB while still logging the meal', async () => {
    const repository = new InMemoryRepository()
    const huge = new Uint8Array(MEAL_IMAGE_MAX_FETCH_BYTES + 1)
    huge.set(jpegBytes)
    const fetcher: MealImageFetcher = () => Promise.resolve(new Response(huge, {
      headers: { 'content-type': 'image/jpeg', 'content-length': String(huge.length) },
    }))
    const service = createService(repository, fetcher)

    const logged = await service.logMeal(mealInput({ image_url: 'https://photos.example/huge.jpg' }))

    expect(logged.recorded).toBe(true)
    expect(logged.image_error).toContain('too large')
  })

  it('reports image_error when the URL redirects to a non-HTTPS or private address (the fetch path stays HTTPS-only)', async () => {
    const repository = new InMemoryRepository()
    const service = createService(repository, () => Promise.resolve(new Response(null, {
      status: 302,
      headers: { location: 'http://photos.example/private.jpg' },
    })))

    const logged = await service.logMeal(mealInput({ image_url: 'https://photos.example/redirects-http' }))
    expect(logged.recorded).toBe(true)
    expect(logged.image_error).toContain('must use HTTPS')

    const privateService = createService(repository, () => Promise.resolve(new Response(null, {
      status: 302,
      headers: { location: 'https://127.0.0.1/internal.jpg' },
    })))
    const privateLogged = await privateService.logMeal(mealInput({ image_url: 'https://photos.example/redirects-private' }))
    expect(privateLogged.recorded).toBe(true)
    expect(privateLogged.image_error).toContain('private address')
  })

  it('rejects a non-HTTPS image_url at the contract boundary without logging a meal', async () => {
    const repository = new InMemoryRepository()
    const service = createService(repository, () => Promise.reject(new Error('an http image_url must never reach the fetcher')))

    await expect(service.logMeal(mealInput({ image_url: 'http://photos.example/meal.jpg' }))).rejects.toMatchObject({
      code: 'invalid_input',
    })
    await expect(repository.getMealsInRange(userId, '2026-08-25T00:00:00.000Z', '2026-08-26T00:00:00.000Z')).resolves.toEqual([])
  })

  it('reports image_error for fetch failures while still logging the meal', async () => {
    const repository = new InMemoryRepository()
    const service = createService(repository, () => Promise.reject(new TypeError('network down')))

    const logged = await service.logMeal(mealInput({ image_url: 'https://photos.example/unreachable.jpg' }))

    expect(logged.recorded).toBe(true)
    expect(logged.image_error).toContain('could not be fetched')
  })

  it('attach_meal_image attaches a photo to an existing meal and it shows up on read-back', async () => {
    const repository = new InMemoryRepository()
    const service = createService(repository)
    const logged = await service.logMeal(mealInput({}))

    const attached = await service.attachMealImage({
      meal_log_id: logged.meal_log_id,
      image_base64: { data: encodeBase64(jpegBytes), mime_type: 'image/jpeg' },
    })

    expect(attached).toEqual({ ok: true, attached: true })
    const day = await service.getDay({ date: '2026-08-25' })
    expect(day.meals[0]?.image?.path).toBe(`${userId}/${logged.meal_log_id}.jpg`)
  })

  it('attach_meal_image reports not_found for a meal the caller does not own', async () => {
    const service = createService(new InMemoryRepository(), () => Promise.resolve(jpegResponse(jpegBytes)))

    await expect(service.attachMealImage({
      meal_log_id: '00000000-0000-4000-8000-000000000099',
      image_url: 'https://photos.example/meal.jpg',
    })).rejects.toMatchObject({ code: 'not_found' })
  })

  it('attach_meal_image reports attached:false with image_error when storage rejects the upload', async () => {
    const repository = new InMemoryRepository()
    const service = createService(repository)
    const logged = await service.logMeal(mealInput({}))
    repository.setFailNextMealImageWrite()

    const attached = await service.attachMealImage({
      meal_log_id: logged.meal_log_id,
      image_base64: { data: encodeBase64(jpegBytes), mime_type: 'image/jpeg' },
    })

    expect(attached.ok).toBe(true)
    expect(attached.attached).toBe(false)
    expect(attached.image_error).toContain('could not be stored')
    expect(repository.storedMealImage(userId, logged.meal_log_id)).toBeUndefined()
  })

  it('attach_meal_image replaces the stored photo bytes when the meal already has one', async () => {
    const repository = new InMemoryRepository()
    const service = createService(repository)
    const logged = await service.logMeal(base64MealLogInput(jpegBytes, 'image/jpeg'))
    const replacement = new Uint8Array([...pngBytes, 0x01, 0x02])

    const attached = await service.attachMealImage({
      meal_log_id: logged.meal_log_id,
      image_base64: { data: encodeBase64(replacement), mime_type: 'image/png' },
    })

    expect(attached).toEqual({ ok: true, attached: true })
    expect(sameBytes(repository.storedMealImage(userId, logged.meal_log_id)?.bytes, replacement)).toBe(true)
  })

  it('attach_meal_image validates that exactly one photo source shape is required', async () => {
    const service = createService(new InMemoryRepository())

    await expect(service.attachMealImage({
      meal_log_id: '00000000-0000-4000-8000-000000000099',
    })).rejects.toMatchObject({ code: 'invalid_input' })
  })
})

describe('SupabaseRepository meal photo storage (HTTP fetch mock)', () => {
  const mealId = '00000000-0000-4000-8000-000000000004'
  const itemId = '00000000-0000-4000-8000-000000000005'

  interface RecordedRequest {
    url: string
    method: string
    authorization: string | null
    body: string | undefined
  }

  interface RecordedUpload {
    url: string
    authorization: string | null
    contentType: string | null
    upsertHeader: string | null
    bytes: Uint8Array
  }

  function jsonResponse(value: unknown, status = 200): Response {
    return new Response(JSON.stringify(value), {
      status,
      headers: { 'content-type': 'application/json' },
    })
  }

  function createRepository(options: { uploadStatus?: number; mealExists?: boolean } = {}): {
    repository: SupabaseRepository
    requests: RecordedRequest[]
    uploads: RecordedUpload[]
  } {
    const requests: RecordedRequest[] = []
    const uploads: RecordedUpload[] = []
    const fetchMock = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
      const request = input instanceof Request
        ? new Request(input, init)
        : new Request(input.toString(), init)
      const isObjectUpload = request.method === 'POST'
        && request.url.includes('/storage/v1/object/food-images/')
        && !request.url.includes('/sign/')
      let bodyText: string | undefined
      if (isObjectUpload) {
        uploads.push({
          url: request.url,
          authorization: request.headers.get('authorization'),
          contentType: request.headers.get('content-type'),
          upsertHeader: request.headers.get('x-upsert'),
          bytes: new Uint8Array(await request.arrayBuffer()),
        })
      } else if (request.method !== 'GET') {
        bodyText = await request.text()
      }
      requests.push({
        url: request.url,
        method: request.method,
        authorization: request.headers.get('authorization'),
        body: bodyText,
      })

      if (request.url.includes('/rest/v1/rpc/log_meal_with_items')) {
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
      if (request.method === 'GET' && request.url.includes('/rest/v1/profiles')) {
        return jsonResponse([])
      }
      if (request.method === 'GET' && request.url.includes('/rest/v1/goals')) {
        return jsonResponse([])
      }
      if (request.method === 'GET' && request.url.includes('/rest/v1/meal_logs?select=id&')) {
        return options.mealExists === false ? jsonResponse([]) : jsonResponse({ id: mealId })
      }
      if (request.method === 'GET' && request.url.includes('/rest/v1/meal_logs?select=')) {
        return jsonResponse([{
          id: mealId,
          eaten_at: '2026-08-25T12:30:00.000Z',
          meal_type: 'lunch',
          image_path: `${userId}/${mealId}.jpg`,
        }])
      }
      if (request.method === 'GET' && request.url.includes('/rest/v1/meal_items')) {
        return jsonResponse([itemRow])
      }
      if (request.method === 'PATCH' && request.url.includes('/rest/v1/meal_logs?id=eq.')) {
        return jsonResponse([{ id: mealId }])
      }
      if (request.method === 'DELETE' && request.url.includes('/storage/v1/object/food-images')) {
        return jsonResponse([{ name: `${userId}/${mealId}.jpg` }])
      }
      if (request.url.includes('/storage/v1/object/sign/food-images/')) {
        const objectPath = new URL(request.url).pathname.replace('/storage/v1/object/sign/food-images/', '')
        return jsonResponse({ signedURL: `/object/sign/food-images/${objectPath}?token=test-token` })
      }
      if (isObjectUpload) {
        if (options.uploadStatus === 400) {
          return jsonResponse({ message: 'new row violates row-level security policy' }, 400)
        }
        const objectPath = new URL(request.url).pathname.replace('/storage/v1/object/food-images/', '')
        return jsonResponse({ Id: 'object-id', Key: objectPath })
      }
      return jsonResponse({ message: 'unexpected test request' }, 500)
    }
    fetchMock.preconnect = (): void => undefined

    return {
      repository: createSupabaseRepository('https://morsel.test', 'test-anon-key', { fetch: fetchMock }),
      requests,
      uploads,
    }
  }

  const itemRow = {
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
  }

  function withToken<T>(repository: SupabaseRepository, action: () => Promise<T>): Promise<T> {
    return repository.withAccessToken('token-one', action)
  }

  it('log_meal with image_base64 uploads bytes to {user_id}/{meal_log_id}.jpg under the user token; get_day returns the signed image', async () => {
    const { repository, requests, uploads } = createRepository()
    const service = new MorselService({ repository, userId, now: fixedNow })

    const logged = await withToken(repository, () => service.logMeal(base64MealLogInput(jpegBytes, 'image/jpeg')))

    expect(logged.image_error).toBeUndefined()
    expect(uploads).toHaveLength(1)
    const upload = uploads[0]
    if (upload === undefined) {
      throw new Error('no storage upload was recorded')
    }
    expect(upload.url).toBe(`https://morsel.test/storage/v1/object/food-images/${userId}/${mealId}.jpg`)
    expect(upload.authorization).toBe('Bearer token-one')
    expect(upload.contentType).toBe('image/jpeg')
    expect(upload.upsertHeader).toBe('true')
    expect(Buffer.from(upload.bytes).equals(Buffer.from(jpegBytes))).toBe(true)

    const pathWrite = requests.find((request) => request.method === 'PATCH' && request.url.includes('/rest/v1/meal_logs?id=eq.'))
    expect(pathWrite?.url).toContain(`id=eq.${mealId}`)
    expect(pathWrite?.url).toContain(`user_id=eq.${userId}`)
    expect(pathWrite?.body).toContain(`"image_path":"${userId}/${mealId}.jpg"`)
    expect(pathWrite?.authorization).toBe('Bearer token-one')

    const day = await withToken(repository, () => service.getDay({ date: '2026-08-25' }))
    expect(day.meals[0]?.image).toMatchObject({
      path: `${userId}/${mealId}.jpg`,
      signed_url: `https://morsel.test/storage/v1/object/sign/food-images/${userId}/${mealId}.jpg?token=test-token`,
    })
    expect(day.meals[0]?.image?.expires_at).toMatch(/^\d{4}-\d{2}-\d{2}T/)
    const signRequest = requests.find((request) => request.url.includes('/storage/v1/object/sign/food-images/'))
    expect(signRequest?.authorization).toBe('Bearer token-one')
    expect(signRequest?.body).toContain('"expiresIn":900')
  })

  it('reports image_error and keeps the meal logged when storage rejects the upload (no row path write follows)', async () => {
    const { repository, requests, uploads } = createRepository({ uploadStatus: 400 })
    const service = new MorselService({ repository, userId, now: fixedNow })

    const logged = await withToken(repository, () => service.logMeal(base64MealLogInput(jpegBytes, 'image/jpeg')))

    expect(logged.recorded).toBe(true)
    expect(logged.image_error).toContain('could not be stored')
    expect(uploads).toHaveLength(1)
    expect(requests.some((request) => request.method === 'PATCH' && request.url.includes('/rest/v1/meal_logs'))).toBe(false)
    expect(requests.some((request) => request.method === 'DELETE' && request.url.includes('/storage/v1/object'))).toBe(false)
  })

  it('attach_meal_image never uploads for a meal the caller does not own (write boundary stays user-scoped)', async () => {
    const { repository, uploads } = createRepository({ mealExists: false })
    const service = new MorselService({ repository, userId, now: fixedNow })

    await expect(withToken(repository, () => service.attachMealImage({
      meal_log_id: mealId,
      image_base64: { data: encodeBase64(jpegBytes), mime_type: 'image/jpeg' },
    }))).rejects.toMatchObject({ code: 'not_found' })

    expect(uploads).toHaveLength(0)
  })

  it('another user logging with a photo cannot write into the first user object folder', async () => {
    const { repository, uploads } = createRepository({ mealExists: false })
    const service = new MorselService({ repository, userId: otherUserId, now: fixedNow })

    const logged = await withToken(repository, () => service.logMeal(base64MealLogInput(jpegBytes, 'image/jpeg')))

    expect(logged.recorded).toBe(true)
    expect(logged.image_error).toContain('could not be stored')
    expect(uploads).toHaveLength(0)
  })
})
