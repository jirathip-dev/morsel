import { describe, expect, it } from 'vitest'
import type { Profile, SearchFoodItem } from '../packages/schema/food-types.js'
import { InMemoryRepository } from './in-memory-repository.js'
import { MorselError } from './errors.js'
import { MorselService } from './service.js'

const userId = '00000000-0000-4000-8000-000000000001'
const fixedNow = () => new Date('2026-08-25T12:00:00.000Z')

const profile: Profile = {
  sex: 'male',
  age_years: 30,
  height_cm: 180,
  weight_kg: 80,
  activity_level: 'moderate',
  diet_goal: 'maintain',
}

function createService(repository = new InMemoryRepository()): MorselService {
  return new MorselService({ repository, userId, now: fixedNow })
}

describe('MorselService', () => {
  it('atomically creates one meal and its items, then totals them for a day', async () => {
    const repository = new InMemoryRepository()
    const service = createService(repository)
    await service.setProfile(profile)

    const logged = await service.logMeal({
      meal_type: 'lunch',
      eaten_at: '2026-08-25T12:30:00+00:00',
      items: [
        { name: 'rice', calories_kcal: 220, carbs_g: 48 },
        { name: 'chicken', quantity: 120, unit: 'g', calories_kcal: 200, protein_g: 38, fat_g: 5 },
      ],
    })
    const day = await service.getDay({ date: '2026-08-25' })

    expect(logged.recorded).toBe(true)
    expect(day.meals).toHaveLength(1)
    expect(day.meals[0]?.meal_log_id).toBe(logged.meal_log_id)
    expect(day.meals[0]?.items).toHaveLength(2)
    expect(day.totals).toEqual({ calories_kcal: 420, protein_g: 38, carbs_g: 48, fat_g: 5 })
    expect(day.goal?.source).toBe('computed')
    expect(day.remaining_kcal).toBe(2339)
  })

  it('leaves no partial rows when the item side of the meal write fails', async () => {
    const repository = new InMemoryRepository()
    repository.setFailNextMealItemWrite()
    const service = createService(repository)

    await expect(service.logMeal({
      meal_type: 'breakfast',
      items: [{ name: 'toast', calories_kcal: 100 }],
    })).rejects.toMatchObject({ code: 'transaction_failed' })

    const day = await service.getDay({ date: '2026-08-25' })
    expect(day.meals).toHaveLength(0)
  })

  it('rejects an invalid food reference before reaching the meal transaction', async () => {
    const repository = new InMemoryRepository()
    const service = createService(repository)

    await expect(service.logMeal({
      meal_type: 'lunch',
      items: [{ name: 'rice', food_ref_id: 'not-a-uuid' }],
    })).rejects.toMatchObject({ code: 'invalid_input' })
    await expect(repository.getMealsInRange(userId, '2026-08-25T00:00:00.000Z', '2026-08-26T00:00:00.000Z')).resolves.toEqual([])
  })

  it('computes targets and preserves manual goal overrides', async () => {
    const service = createService()
    await service.setProfile(profile)

    await expect(service.computeTargets({})).resolves.toEqual({
      bmr_kcal: 1780,
      tdee_kcal: 2759,
      calorie_target_kcal: 2759,
      protein_g: 207,
      carbs_g: 310,
      fat_g: 77,
    })
    await expect(service.getGoals({})).resolves.toMatchObject({
      calorie_target_kcal: 2759,
      source: 'computed',
    })

    await expect(service.setGoals({ calorie_target_kcal: 2000 })).resolves.toEqual({ ok: true, source: 'manual' })
    await expect(service.getGoals({})).resolves.toMatchObject({
      calorie_target_kcal: 2000,
      protein_g: 207,
      source: 'manual',
    })
  })

  it('uses a complete manual goal without requiring a profile', async () => {
    const service = createService()

    await expect(service.setGoals({
      calorie_target_kcal: 2_000,
      protein_g: 150,
      carbs_g: 200,
      fat_g: 70,
    })).resolves.toEqual({ ok: true, source: 'manual' })

    await expect(service.getGoals({})).resolves.toEqual({
      calorie_target_kcal: 2_000,
      protein_g: 150,
      carbs_g: 200,
      fat_g: 70,
      source: 'manual',
    })

    await service.logMeal({
      meal_type: 'lunch',
      eaten_at: '2026-08-25T12:30:00Z',
      items: [{ name: 'rice', calories_kcal: 220 }],
    })
    await expect(service.getDay({ date: '2026-08-25' })).resolves.toMatchObject({
      goal: {
        calorie_target_kcal: 2_000,
        source: 'manual',
      },
      remaining_kcal: 1_780,
    })
  })

  it('retains the current computed target when a stale computed goal row is partially overridden', async () => {
    const repository = new InMemoryRepository()
    repository.seedProfile(userId, profile)
    repository.seedGoals(userId, {
      source: 'computed',
      calorie_target_kcal: 2000,
      protein_g: 100,
      carbs_g: 100,
      fat_g: 100,
    })
    const service = createService(repository)

    await service.setGoals({ protein_g: 180 })

    await expect(service.getGoals({})).resolves.toMatchObject({
      calorie_target_kcal: 2759,
      protein_g: 180,
      carbs_g: 310,
      fat_g: 77,
      source: 'manual',
    })
  })

  it('supports search, correction, and deletion through the repository boundary', async () => {
    const food: SearchFoodItem = {
      id: '00000000-0000-4000-8000-000000000010',
      name: 'Jasmine rice',
      brand: 'Morsel pantry',
      calories_kcal: 220,
      carbs_g: 48,
    }
    const repository = new InMemoryRepository({ foods: [food] })
    const service = createService(repository)

    await expect(service.searchFood({ query: 'rice' })).resolves.toEqual({ results: [food] })
    const logged = await service.logMeal({ meal_type: 'dinner', items: [{ name: 'rice', calories_kcal: 220 }] })
    const beforeUpdate = await service.getDay({ date: '2026-08-25' })
    const itemId = beforeUpdate.meals[0]?.items[0]?.item_id
    if (itemId === undefined) {
      throw new Error('test meal item was not created')
    }

    await expect(service.updateMealItem({ item_id: itemId, calories_kcal: 300 })).resolves.toEqual({ ok: true, updated: true })
    await expect(service.getDay({ date: '2026-08-25' })).resolves.toMatchObject({ totals: { calories_kcal: 300 } })
    await expect(service.deleteMealLog({ meal_log_id: logged.meal_log_id })).resolves.toEqual({ ok: true, deleted: true })
    await expect(service.getDay({ date: '2026-08-25' })).resolves.toMatchObject({ meals: [] })
  })

  it('returns a dashboard range summary with a current streak and scoped weight trend', async () => {
    const repository = new InMemoryRepository()
    repository.seedWeightTrend(userId, [
      { date: '2026-08-24', kg: 80.5 },
      { date: '2026-08-25', kg: 80.2 },
    ])
    const service = createService(repository)
    await service.logMeal({ meal_type: 'dinner', eaten_at: '2026-08-24T18:00:00Z', items: [{ name: 'soup', calories_kcal: 400, protein_g: 20 }] })
    await service.logMeal({ meal_type: 'breakfast', eaten_at: '2026-08-25T08:00:00Z', items: [{ name: 'eggs', calories_kcal: 300, protein_g: 25 }] })

    await expect(service.getDashboardSummary({ days: 2 })).resolves.toEqual({
      avg_calories_kcal: 350,
      streak_days: 2,
      macro_split: { protein_g: 45, carbs_g: 0, fat_g: 0 },
      weight_trend: [
        { date: '2026-08-24', kg: 80.5 },
        { date: '2026-08-25', kg: 80.2 },
      ],
    })
  })

  it('reports missing profiles as a clear domain error', async () => {
    const service = createService()
    await expect(service.computeTargets({})).rejects.toBeInstanceOf(MorselError)
    await expect(service.getProfile({})).rejects.toMatchObject({ code: 'not_found' })
  })
})
