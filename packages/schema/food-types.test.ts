import { describe, expect, it } from 'vitest'
import {
  LogMealInputSchema,
  LogMealOutputSchema,
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

  it('requires v0.1 search result IDs to be UUIDs', () => {
    expect(SearchFoodOutputSchema.safeParse({
      results: [{ id: 'f0000000-0000-4000-8000-000000000001', name: 'rice' }],
    }).success).toBe(true)
    expect(SearchFoodOutputSchema.safeParse({
      results: [{ id: 'open-nutrition-123', name: 'rice' }],
    }).success).toBe(false)
  })
})
