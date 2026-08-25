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
  GoalSummarySchema,
  LogMealInputSchema,
  LogMealOutputSchema,
  ProfileSchema,
  SearchFoodInputSchema,
  SearchFoodOutputSchema,
  SetGoalsInputSchema,
  SetProfileInputSchema,
  UpdateMealItemInputSchema,
  UpdateMealItemOutputSchema,
  DeleteMealLogOutputSchema,
  SetGoalsOutputSchema,
  SetProfileOutputSchema,
} from '../packages/schema/food-types.js'
import type {
  ComputeTargetsOutput,
  DeleteMealLogOutput,
  GetDashboardSummaryOutput,
  GetDayOutput,
  GetGoalsOutput,
  GetProfileOutput,
  GoalSummary,
  LogMealOutput,
  ParsedGetDashboardSummaryInput,
  Profile,
  SearchFoodOutput,
  SetGoalsInput,
  SetGoalsOutput,
  SetProfileOutput,
  UpdateMealItemOutput,
} from '../packages/schema/food-types.js'
import { MorselError } from './errors.js'
import { calculateTargets } from './targets.js'
import type { MorselRepository, StoredGoals } from './repository.js'

function parseInput<T>(schema: z.ZodType<T>, value: unknown, name: string): T {
  const parsed = schema.safeParse(value)
  if (!parsed.success) {
    throw new MorselError('invalid_input', `invalid ${name} input`, parsed.error)
  }
  return parsed.data
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

function sumMealCalories(meals: Awaited<ReturnType<MorselRepository['getMealsInRange']>>): number {
  return meals.reduce((total, meal) => total + meal.items.reduce((mealTotal, item) => mealTotal + (item.calories_kcal ?? 0), 0), 0)
}

function sumMealMacros(meals: Awaited<ReturnType<MorselRepository['getMealsInRange']>>): {
  protein_g: number
  carbs_g: number
  fat_g: number
} {
  return meals.reduce((totals, meal) => {
    for (const item of meal.items) {
      totals.protein_g += item.protein_g ?? 0
      totals.carbs_g += item.carbs_g ?? 0
      totals.fat_g += item.fat_g ?? 0
    }
    return totals
  }, { protein_g: 0, carbs_g: 0, fat_g: 0 })
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
    const totals = meals.reduce((result, meal) => {
      for (const item of meal.items) {
        result.calories_kcal += item.calories_kcal ?? 0
        result.protein_g += item.protein_g ?? 0
        result.carbs_g += item.carbs_g ?? 0
        result.fat_g += item.fat_g ?? 0
      }
      return result
    }, { calories_kcal: 0, protein_g: 0, carbs_g: 0, fat_g: 0 })

    const profile = await this.repository.getProfile(this.userId)
    const goal = profile === undefined ? undefined : await this.getEffectiveGoals(profile)
    return parseInput(GetDayOutputSchema, {
      date: parsed.date,
      meals,
      totals,
      ...(goal === undefined ? {} : { goal, remaining_kcal: goal.calorie_target_kcal - totals.calories_kcal }),
    }, 'get_day output')
  }

  async searchFood(input: unknown): Promise<SearchFoodOutput> {
    const parsed = parseInput(SearchFoodInputSchema, input, 'search_food')
    const results = await this.repository.searchFood(this.userId, parsed.query, parsed.limit)
    return parseInput(SearchFoodOutputSchema, { results }, 'search_food output')
  }

  async getProfile(input: unknown): Promise<GetProfileOutput> {
    parseInput(EmptyInputSchema, input, 'get_profile')
    const profile = await this.repository.getProfile(this.userId)
    if (profile === undefined) {
      throw new MorselError('not_found', 'profile is not set')
    }
    return parseInput(GetProfileOutputSchema, profile, 'get_profile output')
  }

  async setProfile(input: unknown): Promise<SetProfileOutput> {
    const profile = parseInput(SetProfileInputSchema, input, 'set_profile')
    const saved = await this.repository.setProfile(this.userId, profile)
    parseInput(ProfileSchema, saved, 'set_profile output')
    return parseInput(SetProfileOutputSchema, { ok: true, saved: true }, 'set_profile output')
  }

  async computeTargets(input: unknown): Promise<ComputeTargetsOutput> {
    parseInput(EmptyInputSchema, input, 'compute_targets')
    const profile = await this.requireProfile()
    return parseInput(ComputeTargetsOutputSchema, calculateTargets(profile), 'compute_targets output')
  }

  async getGoals(input: unknown): Promise<GetGoalsOutput> {
    parseInput(EmptyInputSchema, input, 'get_goals')
    const profile = await this.requireProfile()
    return parseInput(GetGoalsOutputSchema, await this.getEffectiveGoals(profile), 'get_goals output')
  }

  async setGoals(input: unknown): Promise<SetGoalsOutput> {
    const parsed = parseInput(SetGoalsInputSchema, input, 'set_goals')
    const profile = await this.repository.getProfile(this.userId)
    const stored = await this.repository.getGoals(this.userId)
    const computed = profile === undefined ? undefined : calculateTargets(profile)
    const values: SetGoalsInput = {
      calorie_target_kcal: parsed.calorie_target_kcal ?? stored?.calorie_target_kcal ?? computed?.calorie_target_kcal,
      protein_g: parsed.protein_g ?? stored?.protein_g ?? computed?.protein_g,
      carbs_g: parsed.carbs_g ?? stored?.carbs_g ?? computed?.carbs_g,
      fat_g: parsed.fat_g ?? stored?.fat_g ?? computed?.fat_g,
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

  async getDashboardSummary(input: unknown): Promise<GetDashboardSummaryOutput> {
    const parsed: ParsedGetDashboardSummaryInput = parseInput(GetDashboardSummaryInputSchema, input, 'get_dashboard_summary')
    const today = this.now().toISOString().slice(0, 10)
    const startDate = addDays(today, 1 - parsed.days)
    const meals = await this.repository.getMealsInRange(this.userId, dayStart(startDate), nextDayStart(today))
    const weightTrend = await this.repository.getWeightTrend(this.userId, dayStart(startDate), nextDayStart(today))
    const macroSplit = sumMealMacros(meals)
    const mealDates = new Set(meals.map((meal) => meal.eaten_at.slice(0, 10)))
    let streakDays = 0
    let streakDate = today
    while (mealDates.has(streakDate)) {
      streakDays += 1
      streakDate = previousDate(streakDate)
    }
    return parseInput(GetDashboardSummaryOutputSchema, {
      avg_calories_kcal: sumMealCalories(meals) / parsed.days,
      streak_days: streakDays,
      macro_split: macroSplit,
      weight_trend: weightTrend,
    }, 'get_dashboard_summary output')
  }

  private async requireProfile() {
    const profile = await this.repository.getProfile(this.userId)
    if (profile === undefined) {
      throw new MorselError('profile_required', 'set a profile before computing targets')
    }
    return profile
  }

  private async getEffectiveGoals(profile: Profile): Promise<GoalSummary> {
    const computed = calculateTargets(profile)
    const stored = await this.repository.getGoals(this.userId)
    return parseInput(GoalSummarySchema, toGoalSummary(computed, stored), 'goal')
  }
}
