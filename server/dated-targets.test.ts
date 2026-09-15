import { describe, expect, it } from 'vitest'
import { InMemoryRepository } from './in-memory-repository.ts'
import { MorselService } from './service.ts'
import { DatedTargetSchema, SetDatedTargetAdditionInputSchema } from '../packages/schema/food-types.ts'

const userId = '00000000-0000-4000-8000-000000000253'
const now = () => new Date('2026-09-15T12:00:00Z')
const manual = { calorie_target_kcal: 2100, protein_g: 100, carbs_g: 250, fat_g: 60 }

describe('dated target attribution', () => {
  it('never uses the current target as past truth, including a legacy reader', async () => {
    const repository = new InMemoryRepository()
    const service = new MorselService({ repository, userId, now })
    await service.setGoals(manual)
    const day = await service.getDay({ date: '2026-09-14' })
    expect(day.goal).toBeUndefined()
    expect(day.remaining_kcal).toBeUndefined()
    expect(day.dated_target?.baseline).toBeUndefined()
  })

  it('accepts legacy missing fields, but rejects negative, nonfinite or invented baseline input', () => {
    const input = { date: '2026-09-15', addition_kcal: 0, mutation_id: userId }
    expect(SetDatedTargetAdditionInputSchema.parse(input).historical_confirmation).toBe(false)
    for (const addition_kcal of [-1, Infinity, NaN]) {
      expect(SetDatedTargetAdditionInputSchema.safeParse({ ...input, addition_kcal }).success).toBe(false)
    }
    expect(SetDatedTargetAdditionInputSchema.safeParse({ ...input, baseline: manual }).success).toBe(false)
    expect(DatedTargetSchema.parse({ date: input.date, timezone: 'UTC', confirmed_addition_kcal: 0 }).baseline).toBeUndefined()
  })

  it('keeps the shipped today read, without claiming provenance or borrowing it for a range', async () => {
    const repository = new InMemoryRepository()
    const service = new MorselService({ repository, userId, now })
    await service.setGoals(manual)
    const today = await service.getDay({ date: '2026-09-15' })
    expect(today.goal?.calorie_target_kcal).toBe(2100)
    expect(today.dated_target).toBeUndefined()
    const range = await service.getDashboardSummary({ days: 3, timezone: 'UTC' })
    expect(range.dated_targets).toBeUndefined()
    expect(range.render.markdown).not.toContain('2,100')
  })
})
