import { z } from 'zod'
import {
  ComputeTargetsOutputSchema,
  DeleteMealLogInputSchema,
  EmptyInputSchema,
  GetDashboardSummaryInputSchema,
  GetDashboardSummaryOutputSchema,
  GetDayInputSchema,
  GetDayOutputSchema,
  GetGoalsOutputSchema,
  GetProfileOutputSchema,
  GetWeightTrendInputSchema,
  GetWeightTrendOutputSchema,
  GetEnergyBurnedInputSchema,
  GetEnergyBurnedOutputSchema,
  LogMealInputSchema,
  LogMealOutputSchema,
  ProfileSchema,
  ResetGoalsInputSchema,
  ResetGoalsOutputSchema,
  SearchFoodInputSchema,
  SearchFoodOutputSchema,
  SetGoalsInputSchema,
  SetProfileInputSchema,
  UpdateMealItemInputSchema,
  UpdateMealItemOutputSchema,
  DeleteMealLogOutputSchema,
  SetGoalsOutputSchema,
  SetProfileOutputSchema,
} from '../packages/schema/food-types.ts'
import type {
  ComputeTargetsOutput,
  DeleteMealLogOutput,
  EffectiveGoal,
  GetDashboardSummaryOutput,
  GetDayOutput,
  GetGoalsOutput,
  GetProfileOutput,
  GetWeightTrendOutput,
  EnergyBurnedPoint,
  GoalSummary,
  LogMealOutput,
  ParsedGetDashboardSummaryInput,
  ResetGoalsOutput,
  SearchFoodOutput,
  SetGoalsInput,
  SetGoalsOutput,
  SetProfileOutput,
  UpdateMealItemOutput,
} from '../packages/schema/food-types.ts'
import { MorselError } from './errors.ts'
import { LOW_CONFIDENCE_THRESHOLD, renderDashboardSummary, type DashboardRenderSummary } from './render.ts'
import type { MorselRepository, StoredGoals, StoredProfile } from './repository.ts'

function parseInput<T>(schema: z.ZodType<T>, value: unknown, name: string): T {
  const parsed = schema.safeParse(value)
  if (!parsed.success) {
    throw new MorselError('invalid_input', `invalid ${name} input`, parsed.error)
  }
  return parsed.data
}

function omittedInputAsObject(input: unknown): unknown {
  return input === undefined ? {} : input
}

function dayStart(date: string): string {
  return `${date}T00:00:00.000Z`
}

function nextDayStart(date: string): string {
  return new Date(Date.parse(dayStart(date)) + 86_400_000).toISOString()
}

function previousDate(date: string): string {
  return new Date(Date.parse(dayStart(date)) - 86_400_000).toISOString().slice(0, 10)
}

function addDays(date: string, amount: number): string {
  return new Date(Date.parse(dayStart(date)) + amount * 86_400_000).toISOString().slice(0, 10)
}

function sumMealTotals(meals: Awaited<ReturnType<MorselRepository['getMealsInRange']>>): {
  calories_kcal: number
  protein_g: number
  carbs_g: number
  fat_g: number
} {
  return meals.reduce((totals, meal) => {
    for (const item of meal.items) {
      totals.calories_kcal += item.calories_kcal ?? 0
      totals.protein_g += item.protein_g ?? 0
      totals.carbs_g += item.carbs_g ?? 0
      totals.fat_g += item.fat_g ?? 0
    }
    return totals
  }, { calories_kcal: 0, protein_g: 0, carbs_g: 0, fat_g: 0 })
}

function countStreak(
  meals: Awaited<ReturnType<MorselRepository['getMealsInRange']>>,
  endDate: string,
  maximumDays: number,
): number {
  const mealDates = new Set(meals.map((meal) => meal.eaten_at.slice(0, 10)))
  let streakDays = 0
  let streakDate = endDate
  while (streakDays < maximumDays && mealDates.has(streakDate)) {
    streakDays += 1
    streakDate = previousDate(streakDate)
  }
  return streakDays
}

function dailyCalories(
  meals: Awaited<ReturnType<MorselRepository['getMealsInRange']>>,
  startDate: string,
  days: number,
): { date: string; calories_kcal: number }[] {
  const totalsByDate = new Map<string, number>()
  for (let offset = 0; offset < days; offset += 1) {
    totalsByDate.set(addDays(startDate, offset), 0)
  }
  for (const meal of meals) {
    const date = meal.eaten_at.slice(0, 10)
    const mealCalories = meal.items.reduce((total, item) => total + (item.calories_kcal ?? 0), 0)
    if (totalsByDate.has(date)) {
      totalsByDate.set(date, (totalsByDate.get(date) ?? 0) + mealCalories)
    }
  }
  return [...totalsByDate.entries()].map(([date, calories_kcal]) => ({ date, calories_kcal }))
}

function lowConfidenceItemCount(meals: Awaited<ReturnType<MorselRepository['getMealsInRange']>>): number {
  return meals.reduce((count, meal) => count + meal.items.filter((item) => (
    item.confidence !== undefined && item.confidence < LOW_CONFIDENCE_THRESHOLD
  )).length, 0)
}

function createRenderSummary(
  meals: Awaited<ReturnType<MorselRepository['getMealsInRange']>>,
  startDate: string,
  endDate: string,
  days: number,
  goal: GoalSummary | undefined,
): DashboardRenderSummary {
  const totals = sumMealTotals(meals)
  return {
    startDate,
    endDate,
    days,
    totals,
    ...(goal === undefined ? {} : { goal }),
    streakDays: countStreak(meals, endDate, days),
    mealCount: meals.length,
    dailyCalories: dailyCalories(meals, startDate, days),
    lowConfidenceItemCount: lowConfidenceItemCount(meals),
  }
}

function toGoalSummary(computed: ComputeTargetsOutput, stored: StoredGoals | undefined): GoalSummary {
  if (stored?.source === 'manual') {
    return {
      calorie_target_kcal: stored.calorie_target_kcal ?? computed.calorie_target_kcal,
      protein_g: stored.protein_g ?? computed.protein_g,
      carbs_g: stored.carbs_g ?? computed.carbs_g,
      fat_g: stored.fat_g ?? computed.fat_g,
      source: 'manual',
    }
  }
  return {
    calorie_target_kcal: computed.calorie_target_kcal,
    protein_g: computed.protein_g,
    carbs_g: computed.carbs_g,
    fat_g: computed.fat_g,
    source: 'computed',
  }
}

function toCompleteManualGoal(stored: StoredGoals | undefined): GoalSummary | undefined {
  if (stored?.source !== 'manual'
    || stored.calorie_target_kcal === undefined
    || stored.protein_g === undefined
    || stored.carbs_g === undefined
    || stored.fat_g === undefined) {
    return undefined
  }
  return {
    calorie_target_kcal: stored.calorie_target_kcal,
    protein_g: stored.protein_g,
    carbs_g: stored.carbs_g,
    fat_g: stored.fat_g,
    source: 'manual',
  }
}

export interface MorselServiceOptions {
  repository: MorselRepository
  userId: string
  now?: () => Date
}

export class MorselService {
  private readonly repository: MorselRepository
  private readonly userId: string
  private readonly now: () => Date

  constructor(options: MorselServiceOptions) {
    this.repository = options.repository
    this.userId = options.userId
    this.now = options.now ?? (() => new Date())
  }

  async logMeal(input: unknown): Promise<LogMealOutput> {
    const parsed = parseInput(LogMealInputSchema, input, 'log_meal')
    const meal = await this.repository.createMealWithItems(this.userId, {
      eaten_at: parsed.eaten_at === undefined ? this.now().toISOString() : new Date(parsed.eaten_at).toISOString(),
      meal_type: parsed.meal_type,
      source: parsed.image_url !== undefined
        ? 'photo_vision'
        : parsed.items.some((item) => item.barcode !== undefined)
          ? 'barcode'
          : 'manual',
      image_path: parsed.image_url,
      notes: parsed.notes,
      items: parsed.items,
    })
    return parseInput(LogMealOutputSchema, {
      meal_log_id: meal.meal_log_id,
      recorded: true,
    }, 'log_meal output')
  }

  async getDay(input: unknown): Promise<GetDayOutput> {
    const parsed = parseInput(GetDayInputSchema, input, 'get_day')
    const meals = await this.repository.getMealsInRange(this.userId, dayStart(parsed.date), nextDayStart(parsed.date))

    const profile = await this.repository.getProfile(this.userId)
    const stored = await this.repository.getGoals(this.userId)
    const goal = profile === undefined
      ? toCompleteManualGoal(stored)
      : await this.resolveEffectiveGoalSummary(profile, stored)
    const summary = createRenderSummary(meals, parsed.date, parsed.date, 1, goal)
    return parseInput(GetDayOutputSchema, {
      date: parsed.date,
      meals,
      totals: summary.totals,
      ...(goal === undefined ? {} : { goal, remaining_kcal: goal.calorie_target_kcal - summary.totals.calories_kcal }),
      render: renderDashboardSummary(summary),
    }, 'get_day output')
  }

  async searchFood(input: unknown): Promise<SearchFoodOutput> {
    const parsed = parseInput(SearchFoodInputSchema, input, 'search_food')
    const results = await this.repository.searchFood(this.userId, parsed.query, parsed.limit)
    return parseInput(SearchFoodOutputSchema, { results }, 'search_food output')
  }

  async getProfile(input: unknown): Promise<GetProfileOutput> {
    parseInput(EmptyInputSchema, omittedInputAsObject(input), 'get_profile')
    const profile = await this.repository.getProfile(this.userId)
    if (profile === undefined) {
      throw new MorselError('not_found', 'profile is not set')
    }
    return parseInput(GetProfileOutputSchema, {
      sex: profile.sex,
      age_years: profile.age_years,
      height_cm: profile.height_cm,
      weight_kg: profile.weight_kg,
      activity_level: profile.activity_level,
      diet_goal: profile.diet_goal,
      ...(profile.goal_weight_kg === undefined ? {} : { goal_weight_kg: profile.goal_weight_kg }),
    }, 'get_profile output')
  }

  async setProfile(input: unknown): Promise<SetProfileOutput> {
    const profile = parseInput(SetProfileInputSchema, input, 'set_profile')
    const stored = await this.repository.getGoals(this.userId)
    const saved = await this.repository.setProfile(this.userId, profile)
    parseInput(ProfileSchema, saved, 'set_profile output')
    // The freshly saved profile is the newest user decision, so any complete
    // manual goal it replaces is reported as superseded and the computed
    // targets (from the saved profile + latest imported weight) are effective.
    const computed = await this.repository.computeTargets(this.userId, saved)
    const completeManual = toCompleteManualGoal(stored)
    const superseded = completeManual === undefined || stored?.updated_at === undefined
      ? undefined
      : {
          calorie_target_kcal: completeManual.calorie_target_kcal,
          protein_g: completeManual.protein_g,
          carbs_g: completeManual.carbs_g,
          fat_g: completeManual.fat_g,
          updated_at: stored.updated_at,
        }
    const effectiveGoal: EffectiveGoal = {
      calorie_target_kcal: computed.calorie_target_kcal,
      protein_g: computed.protein_g,
      carbs_g: computed.carbs_g,
      fat_g: computed.fat_g,
      source: 'computed',
      ...(superseded === undefined ? {} : { superseded_manual: superseded }),
    }
    return parseInput(SetProfileOutputSchema, { ok: true, saved: true, effective_goal: effectiveGoal }, 'set_profile output')
  }

  async computeTargets(input: unknown): Promise<ComputeTargetsOutput> {
    parseInput(EmptyInputSchema, omittedInputAsObject(input), 'compute_targets')
    const profile = await this.requireProfile()
    return parseInput(ComputeTargetsOutputSchema, await this.repository.computeTargets(this.userId, profile), 'compute_targets output')
  }

  async getGoals(input: unknown): Promise<GetGoalsOutput> {
    parseInput(EmptyInputSchema, omittedInputAsObject(input), 'get_goals')
    const stored = await this.repository.getGoals(this.userId)
    const profile = await this.repository.getProfile(this.userId)
    if (profile === undefined) {
      // Without a profile there is nothing computed to compare against: a
      // complete manual goal is effective as-is; otherwise targets need one.
      const manualGoal = toCompleteManualGoal(stored)
      if (manualGoal !== undefined) {
        return parseInput(GetGoalsOutputSchema, manualGoal, 'get_goals output')
      }
      throw new MorselError('profile_required', 'set a profile before computing targets')
    }
    return parseInput(GetGoalsOutputSchema, await this.resolveEffectiveGoal(profile, stored), 'get_goals output')
  }

  async resetGoals(input: unknown): Promise<ResetGoalsOutput> {
    parseInput(ResetGoalsInputSchema, omittedInputAsObject(input), 'reset_goals')
    await this.repository.resetGoals(this.userId)
    return parseInput(ResetGoalsOutputSchema, { ok: true, reset: true }, 'reset_goals output')
  }

  async setGoals(input: unknown): Promise<SetGoalsOutput> {
    const parsed = parseInput(SetGoalsInputSchema, input, 'set_goals')
    const profile = await this.repository.getProfile(this.userId)
    const stored = await this.repository.getGoals(this.userId)
    // Omitted values retain the CURRENT effective values, which follow the
    // same "latest update wins" rule as get_goals (a stale manual row no
    // longer seeds the next manual edit).
    const effective = profile === undefined
      ? undefined
      : await this.resolveEffectiveGoalSummary(profile, stored)
    const values: SetGoalsInput = {
      calorie_target_kcal: parsed.calorie_target_kcal ?? effective?.calorie_target_kcal ?? (profile === undefined && stored?.source === 'manual' ? stored.calorie_target_kcal : undefined),
      protein_g: parsed.protein_g ?? effective?.protein_g ?? (profile === undefined && stored?.source === 'manual' ? stored.protein_g : undefined),
      carbs_g: parsed.carbs_g ?? effective?.carbs_g ?? (profile === undefined && stored?.source === 'manual' ? stored.carbs_g : undefined),
      fat_g: parsed.fat_g ?? effective?.fat_g ?? (profile === undefined && stored?.source === 'manual' ? stored.fat_g : undefined),
    }
    if (values.calorie_target_kcal === undefined || values.protein_g === undefined || values.carbs_g === undefined || values.fat_g === undefined) {
      throw new MorselError('profile_required', 'set a profile or provide all four goal values')
    }
    await this.repository.setGoals(this.userId, { ...values, source: 'manual' })
    return parseInput(SetGoalsOutputSchema, { ok: true, source: 'manual' }, 'set_goals output')
  }

  async updateMealItem(input: unknown): Promise<UpdateMealItemOutput> {
    const parsed = parseInput(UpdateMealItemInputSchema, input, 'update_meal_item')
    const updated = await this.repository.updateMealItem(this.userId, parsed)
    if (!updated) {
      throw new MorselError('not_found', 'meal item was not found')
    }
    return parseInput(UpdateMealItemOutputSchema, { ok: true, updated: true }, 'update_meal_item output')
  }

  async deleteMealLog(input: unknown): Promise<DeleteMealLogOutput> {
    const parsed = parseInput(DeleteMealLogInputSchema, input, 'delete_meal_log')
    const deleted = await this.repository.deleteMealLog(this.userId, parsed.meal_log_id)
    if (!deleted) {
      throw new MorselError('not_found', 'meal log was not found')
    }
    return parseInput(DeleteMealLogOutputSchema, { ok: true, deleted: true }, 'delete_meal_log output')
  }

  async getWeightTrend(input: unknown): Promise<GetWeightTrendOutput> {
    const parsed = parseInput(GetWeightTrendInputSchema, omittedInputAsObject(input), 'get_weight_trend')
    const today = this.now().toISOString().slice(0, 10)
    const startDate = addDays(today, 1 - parsed.days)
    const series = await this.repository.getWeightTrend(this.userId, dayStart(startDate), nextDayStart(today))
    return parseInput(GetWeightTrendOutputSchema, {
      series,
      ...(series.at(-1) === undefined ? {} : { latest: series.at(-1) }),
    }, 'get_weight_trend output')
  }

  async getEnergyBurned(input: unknown): Promise<{ series: EnergyBurnedPoint[] }> {
    const parsed = parseInput(GetEnergyBurnedInputSchema, omittedInputAsObject(input), 'get_energy_burned')
    const today = this.now().toISOString().slice(0, 10)
    const startDate = addDays(today, 1 - parsed.days)
    const series = await this.repository.getEnergyBurned(this.userId, dayStart(startDate), nextDayStart(today))
    return parseInput(GetEnergyBurnedOutputSchema, { series }, 'get_energy_burned output')
  }

  async getDashboardSummary(input: unknown): Promise<GetDashboardSummaryOutput> {
    const parsed: ParsedGetDashboardSummaryInput = parseInput(GetDashboardSummaryInputSchema, omittedInputAsObject(input), 'get_dashboard_summary')
    const today = this.now().toISOString().slice(0, 10)
    const startDate = addDays(today, 1 - parsed.days)
    const meals = await this.repository.getMealsInRange(this.userId, dayStart(startDate), nextDayStart(today))
    const weightTrend = await this.repository.getWeightTrend(this.userId, dayStart(startDate), nextDayStart(today))
    const profile = await this.repository.getProfile(this.userId)
    const stored = await this.repository.getGoals(this.userId)
    const goal = profile === undefined
      ? toCompleteManualGoal(stored)
      : await this.resolveEffectiveGoalSummary(profile, stored)
    const summary = createRenderSummary(meals, startDate, today, parsed.days, goal)
    return parseInput(GetDashboardSummaryOutputSchema, {
      avg_calories_kcal: summary.totals.calories_kcal / parsed.days,
      streak_days: summary.streakDays,
      macro_split: {
        protein_g: summary.totals.protein_g,
        carbs_g: summary.totals.carbs_g,
        fat_g: summary.totals.fat_g,
      },
      weight_trend: weightTrend,
      render: renderDashboardSummary(summary),
    }, 'get_dashboard_summary output')
  }

  private async requireProfile() {
    const profile = await this.repository.getProfile(this.userId)
    if (profile === undefined) {
      throw new MorselError('profile_required', 'set a profile before computing targets')
    }
    return profile
  }

  /**
   * "Latest update wins": a stored manual goal is effective only when it is at
   * least as new as the profile. Otherwise the computed target is effective
   * and a complete stale manual goal rides along as superseded_manual.
   */
  private async resolveEffectiveGoal(profile: StoredProfile, stored?: StoredGoals): Promise<EffectiveGoal> {
    const computed = await this.repository.computeTargets(this.userId, profile)
    const manualIsCurrent = stored?.source === 'manual'
      && stored.updated_at !== undefined
      && (profile.updated_at === undefined || Date.parse(stored.updated_at) >= Date.parse(profile.updated_at))
    if (manualIsCurrent) {
      return toGoalSummary(computed, stored)
    }
    const goal: EffectiveGoal = {
      calorie_target_kcal: computed.calorie_target_kcal,
      protein_g: computed.protein_g,
      carbs_g: computed.carbs_g,
      fat_g: computed.fat_g,
      source: 'computed',
    }
    const completeManual = toCompleteManualGoal(stored)
    if (completeManual !== undefined && stored?.updated_at !== undefined) {
      return {
        ...goal,
        superseded_manual: {
          calorie_target_kcal: completeManual.calorie_target_kcal,
          protein_g: completeManual.protein_g,
          carbs_g: completeManual.carbs_g,
          fat_g: completeManual.fat_g,
          updated_at: stored.updated_at,
        },
      }
    }
    return goal
  }

  /** The effective values+source (no superseded payload) for day/dashboard reads. */
  private async resolveEffectiveGoalSummary(profile: StoredProfile, stored?: StoredGoals): Promise<GoalSummary> {
    const effective = await this.resolveEffectiveGoal(profile, stored)
    return {
      calorie_target_kcal: effective.calorie_target_kcal,
      protein_g: effective.protein_g,
      carbs_g: effective.carbs_g,
      fat_g: effective.fat_g,
      source: effective.source,
    }
  }
}
