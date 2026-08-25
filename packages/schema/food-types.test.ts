// Placeholder suite so the vitest gate has ≥1 test from day one. Replace with
// real contract tests (runtime validators for the MCP tool schemas) when the
// server lands.
import { describe, expect, it } from 'vitest'
import type { LogMealInput, MealType } from './food-types'

describe('schema scaffold', () => {
  it('accepts a minimal valid log_meal input', () => {
    const mealType: MealType = 'breakfast'
    const input: LogMealInput = {
      meal_type: mealType,
      items: [{ name: 'oatmeal', calories_kcal: 300 }],
    }
    expect(input.items).toHaveLength(1)
    expect(input.meal_type).toBe('breakfast')
  })
})
