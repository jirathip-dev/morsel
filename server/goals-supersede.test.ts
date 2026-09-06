import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createSupabaseRepository, type SupabaseRepository } from './supabase-repository.js'
import { MorselService } from './service.js'
import type { Profile } from '../packages/schema/food-types.js'

// Issue #154 — a manual set_goals never superseded computed goals through the
// REAL Supabase path. Postgres `updated_at timestamptz not null default now()`
// applies ONLY on INSERT: an upsert that updates an existing goals row leaves
// updated_at at its original value unless the payload carries one. The
// in-memory repository stamps updated_at on every write, so service-level
// tests against it pass while the Supabase path keeps comparing a stale
// goals.updated_at against a newer profiles.updated_at and reports the manual
// write as forever-superseded with the row's ORIGINAL timestamp.
//
// These tests drive MorselService over a real SupabaseRepository with a
// stateful fetch mock that models Postgres upsert semantics: an upsert
// payload without `updated_at` preserves the row's existing timestamp (the
// update-no-bump hole); a payload WITH `updated_at` stores it. The rows are
// seeded in the exact #154 state: a manual goals row older than the profile
// row (stale 4 Sep goals vs 5 Sep profile).

const userId = '00000000-0000-4000-8000-000000000001'
const GOALS_SEED_TS = '2026-09-04T00:00:00.000Z'
const PROFILE_SEED_TS = '2026-09-05T00:00:00.000Z'

interface GoalsRow {
  calorie_target_kcal: number | null
  protein_g: number | null
  carbs_g: number | null
  fat_g: number | null
  source: string
  updated_at: string
}

interface ProfileRow {
  user_id: string
  sex: string
  age_years: number
  height_cm: number
  weight_kg: number
  activity_level: string
  diet_goal: string
  goal_weight_kg: number | null
  timezone: string | null
  updated_at: string
}

function jsonResponse(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

function parseBody(body: string | undefined): Record<string, unknown> {
  if (body === undefined) {
    return {}
  }
  const parsed: unknown = JSON.parse(body)
  return isRecord(parsed) ? parsed : {}
}

function numberOrNull(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function stringOrUndefined(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined
}

function profileRow(updatedAt: string): ProfileRow {
  return {
    user_id: userId,
    sex: 'male',
    age_years: 30,
    height_cm: 180,
    weight_kg: 80,
    activity_level: 'moderate',
    diet_goal: 'maintain',
    goal_weight_kg: null,
    timezone: null,
    updated_at: updatedAt,
  }
}

interface Harness {
  repository: SupabaseRepository
  service: MorselService
}

function createGoalsHarness(): Harness {
  let goals: GoalsRow = {
    calorie_target_kcal: 1_800,
    protein_g: 100,
    carbs_g: 200,
    fat_g: 60,
    source: 'manual',
    updated_at: GOALS_SEED_TS,
  }
  let profile: ProfileRow = profileRow(PROFILE_SEED_TS)

  const fetchMock = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const request = input instanceof Request
      ? new Request(input, init)
      : new Request(input.toString(), init)
    const body = request.method === 'GET' ? undefined : await request.text()

    if (request.method === 'GET' && request.url.includes('/rest/v1/profiles')) {
      return jsonResponse(profile)
    }
    if (request.method === 'POST' && request.url.includes('/rest/v1/profiles')) {
      const payload = parseBody(body)
      const updatedAt = stringOrUndefined(payload['updated_at'])
      if (updatedAt !== undefined) {
        // The upsert payload carried an explicit write timestamp.
        profile = { ...profile, updated_at: updatedAt }
      }
      // set_profile's .select() projection; profileRowSchema is strict, so the
      // save response carries exactly the projected columns (no user_id).
      return jsonResponse({
        sex: profile.sex,
        age_years: profile.age_years,
        height_cm: profile.height_cm,
        weight_kg: profile.weight_kg,
        activity_level: profile.activity_level,
        diet_goal: profile.diet_goal,
        goal_weight_kg: profile.goal_weight_kg,
        timezone: profile.timezone,
      })
    }
    if (request.method === 'GET' && request.url.includes('/rest/v1/goals')) {
      return jsonResponse(goals)
    }
    if (request.method === 'POST' && request.url.includes('/rest/v1/goals')) {
      const payload = parseBody(body)
      const updatedAt = stringOrUndefined(payload['updated_at'])
      goals = {
        calorie_target_kcal: numberOrNull(payload['calorie_target_kcal']),
        protein_g: numberOrNull(payload['protein_g']),
        carbs_g: numberOrNull(payload['carbs_g']),
        fat_g: numberOrNull(payload['fat_g']),
        source: stringOrUndefined(payload['source']) ?? 'manual',
        // Postgres upsert semantics: an UPDATE that does not carry updated_at
        // keeps the row's existing timestamp (default now() is INSERT-only).
        updated_at: updatedAt ?? goals.updated_at,
      }
      return jsonResponse(goals)
    }
    if (request.method === 'GET' && request.url.includes('/rest/v1/weight_logs')) {
      return jsonResponse([])
    }
    if (request.url.includes('/rest/v1/rpc/compute_targets')) {
      return jsonResponse([{
        bmr_kcal: 1_780,
        tdee_kcal: 2_759,
        calorie_target_kcal: 2_126,
        protein_g: 159,
        carbs_g: 239,
        fat_g: 59,
      }])
    }
    return jsonResponse({ message: 'unexpected test request' }, 500)
  }
  fetchMock.preconnect = (): void => undefined

  const repository = createSupabaseRepository('https://morsel.test', 'test-anon-key', { fetch: fetchMock })
  return {
    repository,
    service: new MorselService({ repository, userId }),
  }
}

function withToken<T>(repository: SupabaseRepository, action: () => Promise<T>): Promise<T> {
  return repository.withAccessToken('token-one', action)
}

const profile: Profile = {
  sex: 'male',
  age_years: 30,
  height_cm: 180,
  weight_kg: 80,
  activity_level: 'moderate',
  diet_goal: 'maintain',
}

beforeEach(() => {
  // Deterministic wall clock for the repository's explicit updated_at stamps:
  // the seeded rows and every write timestamp are then fully ordered.
  vi.useFakeTimers({ toFake: ['Date'] })
})

afterEach(() => {
  vi.useRealTimers()
})

describe('manual goals supersede computed through the Supabase path (issue #154)', () => {
  it('set_profile then set_goals: the fresh manual write is effective and no stale superseded payload rides along', async () => {
    vi.setSystemTime(new Date('2026-09-06T09:00:00.000Z'))
    const { repository, service } = createGoalsHarness()

    await withToken(repository, async () => {
      // Seeded #154 state: manual goals row (4 Sep) OLDER than the profile
      // row (5 Sep). The profile save happens first (contract repro T0).
      await service.setProfile(profile)

      // Guy's manual attempt (T1): 2,000 kcal / P 105 / C 255 / F 60.
      vi.setSystemTime(new Date('2026-09-06T09:01:00.000Z'))
      await expect(service.setGoals({
        calorie_target_kcal: 2_000,
        protein_g: 105,
        carbs_g: 255,
        fat_g: 60,
      })).resolves.toEqual({ ok: true, source: 'manual' })

      await expect(service.getGoals({})).resolves.toEqual({
        calorie_target_kcal: 2_000,
        protein_g: 105,
        carbs_g: 255,
        fat_g: 60,
        source: 'manual',
      })
    })
  })

  it('a later profile change supersedes the manual write and reports its CURRENT timestamp, not the stale row one', async () => {
    const { repository, service } = createGoalsHarness()

    await withToken(repository, async () => {
      // Manual write at T1 lands with an explicit write timestamp.
      vi.setSystemTime(new Date('2026-09-06T10:00:00.000Z'))
      await service.setGoals({
        calorie_target_kcal: 2_000,
        protein_g: 105,
        carbs_g: 255,
        fat_g: 60,
      })

      // Profile save at T2 > T1 (#116 direction: the profile is now the
      // newest user decision).
      vi.setSystemTime(new Date('2026-09-06T10:01:00.000Z'))
      await service.setProfile(profile)

      await expect(service.getGoals({})).resolves.toEqual({
        calorie_target_kcal: 2_126,
        protein_g: 159,
        carbs_g: 239,
        fat_g: 59,
        source: 'computed',
        superseded_manual: {
          calorie_target_kcal: 2_000,
          protein_g: 105,
          carbs_g: 255,
          fat_g: 60,
          // The displaced manual write's OWN timestamp (T1), never the
          // row's stale 4 Sep creation time.
          updated_at: '2026-09-06T10:00:00.000Z',
        },
      })
    })
  })
})
