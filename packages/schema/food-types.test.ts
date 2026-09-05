import { describe, expect, it } from 'vitest'
import {
  GetDashboardSummaryOutputSchema,
  GetDayInputSchema,
  GetDayOutputSchema,
  LogMealInputSchema,
  LogMealOutputSchema,
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
})
