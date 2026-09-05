import { describe, expect, it } from 'vitest'
import {
  AttachMealImageInputSchema,
  AttachMealImageOutputSchema,
  GetDashboardSummaryOutputSchema,
  GetDayInputSchema,
  GetDayOutputSchema,
  LogMealInputSchema,
  LogMealOutputSchema,
  MealImageRecordSchema,
  RenderPayloadSchema,
  SearchFoodOutputSchema,
  TimezoneSchema,
} from './food-types'

describe('Morsel tool schemas', () => {
  it('validates a minimal log_meal input and applies documented defaults', () => {
    const input = LogMealInputSchema.parse({
      meal_type: 'breakfast',
      items: [{ name: 'oatmeal', calories_kcal: 300 }],
    })
    expect(input.items).toHaveLength(1)
    expect(input.items[0]?.quantity).toBe(1)
    expect(input.items[0]?.unit).toBe('serving')
  })

  it('rejects unknown fields and validates UUID meal output', () => {
    expect(LogMealInputSchema.safeParse({
      meal_type: 'lunch',
      items: [{ name: 'rice' }],
      source: 'manual',
    }).success).toBe(false)
    expect(LogMealOutputSchema.safeParse({
      meal_log_id: '00000000-0000-4000-8000-000000000001',
      recorded: true,
    }).success).toBe(true)
  })

  it('requires food_ref_id to be a UUID at the meal input boundary', () => {
    expect(LogMealInputSchema.safeParse({
      meal_type: 'lunch',
      items: [{ name: 'rice', food_ref_id: 'not-a-uuid' }],
    }).success).toBe(false)
    expect(LogMealInputSchema.safeParse({
      meal_type: 'lunch',
      items: [{ name: 'rice', food_ref_id: '00000000-0000-4000-8000-000000000010' }],
    }).success).toBe(true)
  })

  it('requires render payloads on read tool outputs', () => {
    const render = { markdown: '# Today', svg: '<svg xmlns="http://www.w3.org/2000/svg" />' }
    expect(RenderPayloadSchema.parse(render)).toEqual(render)
    expect(GetDayOutputSchema.parse({
      date: '2026-08-25',
      timezone: 'UTC',
      meals: [],
      totals: { calories_kcal: 0, protein_g: 0, carbs_g: 0, fat_g: 0 },
      render,
    })).toMatchObject({ render })
    expect(GetDashboardSummaryOutputSchema.parse({
      date: '2026-08-25',
      timezone: 'UTC',
      avg_calories_kcal: 0,
      streak_days: 0,
      macro_split: { protein_g: 0, carbs_g: 0, fat_g: 0 },
      weight_trend: [],
      render,
    })).toMatchObject({ render })
    expect(GetDayOutputSchema.safeParse({
      date: '2026-08-25',
      meals: [],
      totals: { calories_kcal: 0, protein_g: 0, carbs_g: 0, fat_g: 0 },
    }).success).toBe(false)
    expect(GetDashboardSummaryOutputSchema.safeParse({
      avg_calories_kcal: 0,
      streak_days: 0,
      macro_split: { protein_g: 0, carbs_g: 0, fat_g: 0 },
      weight_trend: [],
    }).success).toBe(false)
  })

  it('accepts optional IANA timezones on day-scoped tool inputs and logs them in outputs', () => {
    // Day-tool inputs take the optional zone and the output carries the zone
    // and date the server used.
    expect(GetDayInputSchema.parse({ date: '2026-08-25', timezone: 'Asia/Bangkok' })).toEqual({
      date: '2026-08-25',
      timezone: 'Asia/Bangkok',
    })
    expect(GetDayInputSchema.parse({ date: '2026-08-25' })).toEqual({ date: '2026-08-25' })
    expect(LogMealInputSchema.safeParse({
      meal_type: 'dinner',
      timezone: 'Asia/Bangkok',
      items: [{ name: 'rice' }],
    }).success).toBe(true)
    // log_meal output date/timezone are only present when eaten_at was omitted.
    expect(LogMealOutputSchema.parse({
      meal_log_id: '00000000-0000-4000-8000-000000000002',
      recorded: true,
      timezone: 'Asia/Bangkok',
      date: '2026-09-01',
    })).toEqual({
      meal_log_id: '00000000-0000-4000-8000-000000000002',
      recorded: true,
      timezone: 'Asia/Bangkok',
      date: '2026-09-01',
    })
    expect(LogMealOutputSchema.safeParse({
      meal_log_id: '00000000-0000-4000-8000-000000000002',
      recorded: true,
    }).success).toBe(true)
  })

  it('validates IANA timezone names and rejects non-IANA strings', () => {
    for (const valid of ['UTC', 'Asia/Bangkok', 'America/New_York', 'Europe/Amsterdam', 'Etc/GMT+7']) {
      expect(TimezoneSchema.safeParse(valid).success, valid).toBe(true)
      expect(TimezoneSchema.parse(valid), valid).toBe(valid)
    }
    for (const invalid of ['', 'Bangkok', 'Not/AZone', 'UTC+7', 'Asia/Bangkok/Extra/Deep']) {
      expect(TimezoneSchema.safeParse(invalid).success, invalid).toBe(false)
    }
  })

  it('requires v0.1 search result IDs to be UUIDs', () => {
    expect(SearchFoodOutputSchema.safeParse({
      results: [{ id: 'f0000000-0000-4000-8000-000000000001', name: 'rice' }],
    }).success).toBe(true)
    expect(SearchFoodOutputSchema.safeParse({
      results: [{ id: 'open-nutrition-123', name: 'rice' }],
    }).success).toBe(false)
  })

  it('accepts image_base64 as the preferred log_meal photo input and keeps image_url HTTPS-only', () => {
    const base = { meal_type: 'lunch', items: [{ name: 'rice' }] }
    expect(LogMealInputSchema.parse({
      ...base,
      image_base64: { data: 'aGVsbG8=', mime_type: 'image/jpeg' },
    }).image_base64).toEqual({ data: 'aGVsbG8=', mime_type: 'image/jpeg' })
    // The accepted mime set mirrors the storage bucket allowlist: JPEG/PNG/WebP.
    expect(LogMealInputSchema.safeParse({
      ...base,
      image_base64: { data: 'aGVsbG8=', mime_type: 'image/heic' },
    }).success).toBe(false)
    expect(LogMealInputSchema.safeParse({
      ...base,
      image_base64: { data: '', mime_type: 'image/jpeg' },
    }).success).toBe(false)
    expect(LogMealInputSchema.safeParse({
      ...base,
      image_url: 'http://photos.example/meal.jpg',
    }).success).toBe(false)
    expect(LogMealInputSchema.parse({
      ...base,
      image_url: 'https://photos.example/meal.jpg',
    }).image_url).toBe('https://photos.example/meal.jpg')
    expect(LogMealInputSchema.safeParse({ ...base, image_base64: { data: 'aGVsbG8=', mime_type: 'image/jpeg' }, extra: 1 }).success).toBe(false)
  })

  it('log_meal output reports image_error when a photo could not be stored', () => {
    const output = { meal_log_id: '00000000-0000-4000-8000-000000000003', recorded: true }
    expect(LogMealOutputSchema.parse(output).image_error).toBeUndefined()
    expect(LogMealOutputSchema.parse({ ...output, image_error: 'the photo could not be stored' }).image_error).toBe(
      'the photo could not be stored',
    )
    expect(LogMealOutputSchema.safeParse({ ...output, image_error: 42 }).success).toBe(false)
  })

  it('meal records carry an optional signed image read model', () => {
    const meal = {
      meal_log_id: '00000000-0000-4000-8000-000000000004',
      meal_type: 'lunch',
      eaten_at: '2026-08-25T12:30:00.000Z',
      items: [],
    }
    expect(MealImageRecordSchema.parse({
      path: '00000000-0000-4000-8000-000000000001/00000000-0000-4000-8000-000000000004.jpg',
      signed_url: 'https://morsel.test/storage/v1/object/sign/food-images/00000000-0000-4000-8000-000000000001/00000000-0000-4000-8000-000000000004.jpg?token=t',
      expires_at: '2026-08-25T12:15:00.000Z',
    })).toMatchObject({ path: expect.stringContaining('.jpg') })
    expect(MealImageRecordSchema.safeParse({
      path: 'x',
      signed_url: 'not-a-url',
      expires_at: '2026-08-25T12:15:00.000Z',
    }).success).toBe(false)
    // A meal without a photo has no image key; one with an image must be valid.
    expect(GetDayOutputSchema.safeParse({
      date: '2026-08-25',
      timezone: 'UTC',
      meals: [meal, {
        ...meal,
        meal_log_id: '00000000-0000-4000-8000-000000000005',
        image: {
          path: '00000000-0000-4000-8000-000000000001/00000000-0000-4000-8000-000000000005.jpg',
          signed_url: 'https://morsel.test/storage/v1/object/sign/food-images/00000000-0000-4000-8000-000000000001/00000000-0000-4000-8000-000000000005.jpg?token=t',
          expires_at: '2026-08-25T12:15:00.000Z',
        },
      }],
      totals: { calories_kcal: 0, protein_g: 0, carbs_g: 0, fat_g: 0 },
      render: { markdown: '# Day', svg: '<svg xmlns="http://www.w3.org/2000/svg" />' },
    }).success).toBe(true)
  })

  it('attach_meal_image requires meal_log_id plus one photo source and reports attached with image_error', () => {
    const mealId = '00000000-0000-4000-8000-000000000006'
    expect(AttachMealImageInputSchema.parse({
      meal_log_id: mealId,
      image_base64: { data: 'aGVsbG8=', mime_type: 'image/jpeg' },
    })).toMatchObject({ meal_log_id: mealId })
    expect(AttachMealImageInputSchema.parse({
      meal_log_id: mealId,
      image_url: 'https://photos.example/meal.jpg',
    }).image_url).toBe('https://photos.example/meal.jpg')
    expect(AttachMealImageInputSchema.safeParse({ meal_log_id: mealId }).success).toBe(false)
    expect(AttachMealImageInputSchema.safeParse({
      meal_log_id: 'not-a-uuid',
      image_base64: { data: 'aGVsbG8=', mime_type: 'image/jpeg' },
    }).success).toBe(false)
    expect(AttachMealImageInputSchema.safeParse({
      meal_log_id: mealId,
      image_url: 'http://photos.example/meal.jpg',
    }).success).toBe(false)
    expect(AttachMealImageOutputSchema.safeParse({ ok: true, attached: true }).success).toBe(true)
    expect(AttachMealImageOutputSchema.safeParse({ ok: true, attached: false, image_error: 'the photo could not be stored' }).success).toBe(true)
    expect(AttachMealImageOutputSchema.safeParse({ ok: true, attached: 'yes' }).success).toBe(false)
  })
})
