import { describe, expect, it } from 'vitest'
import {
  GetDashboardSummaryOutputSchema,
  GetDayOutputSchema,
  LogMealInputSchema,
  LogMealOutputSchema,
  RenderPayloadSchema,
  SearchFoodOutputSchema,
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
      meals: [],
      totals: { calories_kcal: 0, protein_g: 0, carbs_g: 0, fat_g: 0 },
      render,
    })).toMatchObject({ render })
    expect(GetDashboardSummaryOutputSchema.parse({
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

  it('requires v0.1 search result IDs to be UUIDs', () => {
    expect(SearchFoodOutputSchema.safeParse({
      results: [{ id: 'f0000000-0000-4000-8000-000000000001', name: 'rice' }],
    }).success).toBe(true)
    expect(SearchFoodOutputSchema.safeParse({
      results: [{ id: 'open-nutrition-123', name: 'rice' }],
    }).success).toBe(false)
  })
})
