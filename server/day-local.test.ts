import { describe, expect, it } from 'vitest'
import type { Profile } from '../packages/schema/food-types.js'
import { InMemoryRepository } from './in-memory-repository.js'
import { MorselService } from './service.js'

// Issue #121 day-boundary contract: day-scoped tools bucket "days" in the
// user's local timezone. These tests pin the named RED/GREEN regression: a
// late-evening +07 meal must land on the LOCAL day (not on the adjacent UTC
// date), and no timezone anywhere keeps v0.1 UTC semantics.

const userId = '00000000-0000-4000-8000-000000000002'
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

describe('MorselService local-day bucketing (issue #121)', () => {
  it('buckets a late-evening +07 meal onto the LOCAL day, not onto its UTC date (Asia/Bangkok)', async () => {
    const service = createService()
    // 2026-08-31T23:30Z = Tuesday 2026-09-01 06:30 +07 (a late dinner that
    // UTC would wrongly pin to Monday Aug 31).
    await service.logMeal({
      meal_type: 'dinner',
      eaten_at: '2026-08-31T23:30:00.000Z',
      items: [{ name: 'rice', calories_kcal: 300 }],
    })

    const localDay = await service.getDay({ date: '2026-09-01', timezone: 'Asia/Bangkok' })
    expect(localDay.timezone).toBe('Asia/Bangkok')
    expect(localDay.date).toBe('2026-09-01')
    expect(localDay.meals).toHaveLength(1)
    expect(localDay.meals[0]?.meal_type).toBe('dinner')

    const previousLocalDay = await service.getDay({ date: '2026-08-31', timezone: 'Asia/Bangkok' })
    expect(previousLocalDay.meals).toHaveLength(0)
  })

  it('keeps UTC bucketing when no timezone is supplied anywhere (backward compatible)', async () => {
    const service = createService()
    await service.logMeal({
      meal_type: 'dinner',
      eaten_at: '2026-08-31T23:30:00.000Z',
      items: [{ name: 'rice', calories_kcal: 300 }],
    })

    // No timezone on the call, no profile: v0.1 UTC-grid days apply, so the
    // instant belongs to Aug 31.
    const utcDay = await service.getDay({ date: '2026-08-31' })
    expect(utcDay.timezone).toBe('UTC')
    expect(utcDay.meals).toHaveLength(1)
    const nextUtcDay = await service.getDay({ date: '2026-09-01' })
    expect(nextUtcDay.meals).toHaveLength(0)
  })

  it('applies profiles.timezone when the call passes no explicit timezone', async () => {
    const repository = new InMemoryRepository()
    repository.seedProfile(userId, { ...profile, timezone: 'Asia/Bangkok' })
    const service = createService(repository)

    await service.logMeal({
      meal_type: 'dinner',
      eaten_at: '2026-08-31T23:30:00.000Z',
      items: [{ name: 'rice', calories_kcal: 300 }],
    })

    const day = await service.getDay({ date: '2026-09-01' })
    expect(day.timezone).toBe('Asia/Bangkok')
    expect(day.meals).toHaveLength(1)
    expect(day.meals[0]?.meal_log_id).toBeDefined()

    const profileRead = await service.getProfile({})
    expect(profileRead.timezone).toBe('Asia/Bangkok')
  })

  it('anchors windowed tools on the LOCAL today (Pacific/Kiritimati, UTC+14)', async () => {
    const service = createService()
    // fixedNow is 2026-08-25T12:00Z = 2026-08-26 02:00 in UTC+14: "today"
    // there is Aug 26, one day past the UTC calendar date.
    const logged = await service.logMeal({
      meal_type: 'breakfast',
      timezone: 'Pacific/Kiritimati',
      items: [{ name: 'toast', calories_kcal: 200 }],
    })

    expect(logged.timezone).toBe('Pacific/Kiritimati')
    expect(logged.date).toBe('2026-08-26')

    const summary = await service.getDashboardSummary({ days: 1, timezone: 'Pacific/Kiritimati' })
    expect(summary.timezone).toBe('Pacific/Kiritimati')
    expect(summary.date).toBe('2026-08-26')
    expect(summary.streak_days).toBe(1)
    // The server-side "now" stamp lives in the local day window.
    expect(summary.avg_calories_kcal).toBe(200)

    // Without any timezone the anchor stays the UTC-grid day (v0.1): the same
    // instant belongs to UTC Aug 25 and its window still contains the meal.
    const utcSummary = await service.getDashboardSummary({ days: 1 })
    expect(utcSummary.timezone).toBe('UTC')
    expect(utcSummary.date).toBe('2026-08-25')
    expect(utcSummary.avg_calories_kcal).toBe(200)
    expect(utcSummary.streak_days).toBe(1)
  })

  it('reports the local date on day-window tools and keeps series dates local', async () => {
    const repository = new InMemoryRepository({ energyBurnedByUser: {
      [userId]: [
        { date: '2026-08-25', active_kcal: 420 },
      ],
    } })
    const service = createService(repository)

    const energy = await service.getEnergyBurned({ days: 30, timezone: 'Asia/Bangkok' })
    expect(energy.timezone).toBe('Asia/Bangkok')
    expect(energy.date).toBe('2026-08-25')
    expect(energy.series).toEqual([{ date: '2026-08-25', active_kcal: 420 }])

    const trend = await service.getWeightTrend({ days: 30, timezone: 'Asia/Bangkok' })
    expect(trend.timezone).toBe('Asia/Bangkok')
    expect(trend.date).toBe('2026-08-25')
    expect(trend.series).toEqual([])
  })
})
