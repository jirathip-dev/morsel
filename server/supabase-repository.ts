import { AsyncLocalStorage } from 'node:async_hooks'
import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { z } from 'zod'
import {
  ActivityLevelSchema,
  CalendarDateSchema,
  ComputeTargetsOutputSchema,
  DietGoalSchema,
  FoodRefIdSchema,
  IsoDateTimeSchema,
  MealItemRecordSchema,
  MealTypeSchema,
  MealRecordSchema,
  ProfileSchema,
  SearchFoodItemSchema,
  SexSchema,
  UnitSchema,
} from '../packages/schema/food-types.ts'
import { InvalidStoredDataError, ProviderUnavailableError, RepositoryError, TransactionError } from './errors.ts'
import type {
  ComputeTargetsOutput,
  GoalSummary,
  MealItemRecord,
  MealRecord,
  Profile,
  SearchFoodItem,
  SetGoalsInput,
  UpdateMealItemInput,
  WeightTrendPoint,
  EnergyBurnedPoint,
} from '../packages/schema/food-types.ts'
import type { MealWrite, MorselRepository, StoredGoals, StoredProfile } from './repository.ts'
import type { NutritionProvider, ProviderFood } from './nutrition-provider.ts'
import { UsdaFoodDataCentralProvider } from './nutrition-provider.ts'
import type { ComputeTargetsFunctionInput, Database, LogMealFunctionItem } from './supabase-types.ts'

const databaseNumber = z.union([
  z.number(),
  z.string().trim().min(1).refine((value) => Number.isFinite(Number(value)), {
    message: 'must be numeric',
  }).transform(Number),
])

const mealLogRowSchema = z.object({
  id: z.uuid(),
  eaten_at: IsoDateTimeSchema,
  meal_type: MealTypeSchema,
}).strict()

const mealItemRowSchema = z.object({
  id: z.uuid(),
  meal_log_id: z.uuid(),
  name: z.string(),
  quantity: databaseNumber,
  unit: UnitSchema,
  calories_kcal: databaseNumber.nullable(),
  protein_g: databaseNumber.nullable(),
  carbs_g: databaseNumber.nullable(),
  fat_g: databaseNumber.nullable(),
  fiber_g: databaseNumber.nullable(),
  sugar_g: databaseNumber.nullable(),
  barcode: z.string().nullable(),
  food_ref_id: FoodRefIdSchema.nullable(),
  confidence: databaseNumber.nullable(),
  source_notes: z.string().nullable(),
}).strict()

const profileRowSchema = z.object({
  sex: SexSchema,
  age_years: databaseNumber,
  height_cm: databaseNumber,
  weight_kg: databaseNumber,
  activity_level: ActivityLevelSchema,
  diet_goal: DietGoalSchema,
  goal_weight_kg: databaseNumber.nullable(),
}).strict()

const profileRpcRowSchema = profileRowSchema.extend({
  user_id: z.uuid(),
  updated_at: IsoDateTimeSchema,
}).strict()

const targetRowSchema = z.object({
  bmr_kcal: databaseNumber,
  tdee_kcal: databaseNumber,
  calorie_target_kcal: databaseNumber,
  protein_g: databaseNumber,
  carbs_g: databaseNumber,
  fat_g: databaseNumber,
}).strict()

const mealRpcItemSchema = z.object({
  item_id: z.uuid(),
  name: z.string(),
  quantity: databaseNumber,
  unit: UnitSchema,
  calories_kcal: databaseNumber.nullable(),
  protein_g: databaseNumber.nullable(),
  carbs_g: databaseNumber.nullable(),
  fat_g: databaseNumber.nullable(),
  fiber_g: databaseNumber.nullable(),
  sugar_g: databaseNumber.nullable(),
  barcode: z.string().nullable(),
  food_ref_id: FoodRefIdSchema.nullable(),
  confidence: databaseNumber.nullable(),
  notes: z.string().nullable(),
}).strict()

const mealRpcRowSchema = z.object({
  meal_log_id: z.uuid(),
  eaten_at: IsoDateTimeSchema,
  meal_type: MealTypeSchema,
  items: z.array(mealRpcItemSchema).min(1),
}).strict()

const goalsRowSchema = z.object({
  calorie_target_kcal: databaseNumber.nullable(),
  protein_g: databaseNumber.nullable(),
  carbs_g: databaseNumber.nullable(),
  fat_g: databaseNumber.nullable(),
  source: z.enum(['computed', 'manual']),
  updated_at: IsoDateTimeSchema,
}).strict()

const foodRowSchema = z.object({
  id: z.uuid(),
  name: z.string(),
  brand: z.string().nullable(),
  barcode: z.string().nullable(),
  serving_size: z.string().nullable(),
  serving_unit: z.string().nullable(),
  calories_kcal: databaseNumber.nullable(),
  protein_g: databaseNumber.nullable(),
  carbs_g: databaseNumber.nullable(),
  fat_g: databaseNumber.nullable(),
}).strict()

const userRowSchema = z.object({
  id: z.uuid(),
}).strict()

const weightRowSchema = z.object({
  measured_at: IsoDateTimeSchema,
  kg: databaseNumber.refine((value) => value > 0, 'must be positive'),
}).strict()
const energyBurnedRowSchema = z.object({
  burned_at: IsoDateTimeSchema,
  active_kcal: databaseNumber.refine((value) => value >= 0, 'must be non-negative'),
}).strict()

const mealLogColumns = 'id,eaten_at,meal_type'
const mealItemColumns = 'id,meal_log_id,name,quantity,unit,calories_kcal,protein_g,carbs_g,fat_g,fiber_g,sugar_g,barcode,food_ref_id,confidence,source_notes'
const foodColumns = 'id,name,brand,barcode,serving_size,serving_unit,calories_kcal,protein_g,carbs_g,fat_g'

function parseStored<T>(schema: z.ZodType<T>, value: unknown, context: string): T {
  const parsed = schema.safeParse(value)
  if (!parsed.success) {
    throw new InvalidStoredDataError(`${context} returned invalid data`, parsed.error)
  }
  return parsed.data
}

function requireData<T>(data: T | null, error: { message: string } | null, operation: string): T {
  if (error !== null) {
    throw new RepositoryError(`${operation} failed`, error)
  }
  if (data === null) {
    throw new RepositoryError(`${operation} returned no data`)
  }
  return data
}

function escapeIlikePattern(value: string): string {
  return value.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_').replaceAll('*', '\\*')
}

function toMealItem(value: unknown): MealItemRecord {
  const item = parseStored(mealItemRowSchema, value, 'meal item')
  return parseStored(MealItemRecordSchema, {
    item_id: item.id,
    name: item.name,
    quantity: item.quantity,
    unit: item.unit,
    ...(item.calories_kcal === null ? {} : { calories_kcal: item.calories_kcal }),
    ...(item.protein_g === null ? {} : { protein_g: item.protein_g }),
    ...(item.carbs_g === null ? {} : { carbs_g: item.carbs_g }),
    ...(item.fat_g === null ? {} : { fat_g: item.fat_g }),
    ...(item.fiber_g === null ? {} : { fiber_g: item.fiber_g }),
    ...(item.sugar_g === null ? {} : { sugar_g: item.sugar_g }),
    ...(item.barcode === null ? {} : { barcode: item.barcode }),
    ...(item.food_ref_id === null ? {} : { food_ref_id: item.food_ref_id }),
    ...(item.confidence === null ? {} : { confidence: item.confidence }),
    ...(item.source_notes === null ? {} : { notes: item.source_notes }),
  }, 'meal item')
}

function toMealRecord(value: unknown, items: MealItemRecord[]): MealRecord {
  const log = parseStored(mealLogRowSchema, value, 'meal log')
  return parseStored(MealRecordSchema, {
    meal_log_id: log.id,
    meal_type: log.meal_type,
    eaten_at: log.eaten_at,
    items,
  }, 'meal log')
}

function toRpcMealRecord(value: unknown): MealRecord {
  const row = parseStored(mealRpcRowSchema, value, 'meal write')
  const items = row.items.map((item) => parseStored(MealItemRecordSchema, {
    item_id: item.item_id,
    name: item.name,
    quantity: item.quantity,
    unit: item.unit,
    ...(item.calories_kcal === null ? {} : { calories_kcal: item.calories_kcal }),
    ...(item.protein_g === null ? {} : { protein_g: item.protein_g }),
    ...(item.carbs_g === null ? {} : { carbs_g: item.carbs_g }),
    ...(item.fat_g === null ? {} : { fat_g: item.fat_g }),
    ...(item.fiber_g === null ? {} : { fiber_g: item.fiber_g }),
    ...(item.sugar_g === null ? {} : { sugar_g: item.sugar_g }),
    ...(item.barcode === null ? {} : { barcode: item.barcode }),
    ...(item.food_ref_id === null ? {} : { food_ref_id: item.food_ref_id }),
    ...(item.confidence === null ? {} : { confidence: item.confidence }),
    ...(item.notes === null ? {} : { notes: item.notes }),
  }, 'meal item'))
  return parseStored(MealRecordSchema, {
    meal_log_id: row.meal_log_id,
    meal_type: row.meal_type,
    eaten_at: row.eaten_at,
    items,
  }, 'meal write')
}

function toProfile(value: unknown): Profile {
  const profile = parseStored(profileRowSchema, value, 'profile')
  return parseStored(ProfileSchema, {
    sex: profile.sex,
    age_years: profile.age_years,
    height_cm: profile.height_cm,
    weight_kg: profile.weight_kg,
    activity_level: profile.activity_level,
    diet_goal: profile.diet_goal,
    ...(profile.goal_weight_kg === null ? {} : { goal_weight_kg: profile.goal_weight_kg }),
  }, 'profile')
}

function toGoals(value: unknown): StoredGoals {
  const goals = parseStored(goalsRowSchema, value, 'goals')
  return {
    source: goals.source,
    updated_at: goals.updated_at,
    ...(goals.calorie_target_kcal === null ? {} : { calorie_target_kcal: goals.calorie_target_kcal }),
    ...(goals.protein_g === null ? {} : { protein_g: goals.protein_g }),
    ...(goals.carbs_g === null ? {} : { carbs_g: goals.carbs_g }),
    ...(goals.fat_g === null ? {} : { fat_g: goals.fat_g }),
  }
}

function toFood(value: unknown): SearchFoodItem {
  const food = parseStored(foodRowSchema, value, 'food catalog')
  return parseStored(SearchFoodItemSchema, {
    id: food.id,
    name: food.name,
    ...(food.brand === null ? {} : { brand: food.brand }),
    ...(food.barcode === null ? {} : { barcode: food.barcode }),
    ...(food.serving_size === null ? {} : { serving_size: food.serving_size }),
    ...(food.serving_unit === null ? {} : { serving_unit: food.serving_unit }),
    ...(food.calories_kcal === null ? {} : { calories_kcal: food.calories_kcal }),
    ...(food.protein_g === null ? {} : { protein_g: food.protein_g }),
    ...(food.carbs_g === null ? {} : { carbs_g: food.carbs_g }),
    ...(food.fat_g === null ? {} : { fat_g: food.fat_g }),
  }, 'food catalog')
}

export interface SupabaseRepositoryOptions {
  client: SupabaseClient<Database>
  accessTokenContext: AsyncLocalStorage<string>
  nutritionProvider?: NutritionProvider
  cacheClientFactory?: () => SupabaseClient<Database> | undefined
}

export class SupabaseRepository implements MorselRepository {
  private readonly client: SupabaseClient<Database>
  private readonly accessTokenContext: AsyncLocalStorage<string>
  private readonly nutritionProvider: NutritionProvider
  private readonly cacheClientFactory: () => SupabaseClient<Database> | undefined

  constructor(options: SupabaseRepositoryOptions) {
    this.client = options.client
    this.accessTokenContext = options.accessTokenContext
    this.nutritionProvider = options.nutritionProvider ?? new UsdaFoodDataCentralProvider()
    this.cacheClientFactory = options.cacheClientFactory ?? (() => undefined)
  }

  withAccessToken<T>(accessToken: string, action: () => Promise<T>): Promise<T> {
    return this.accessTokenContext.run(accessToken, action)
  }

  async ensureUser(userId: string, email: string): Promise<void> {
    const response = await this.client
      .from('users')
      .upsert({ id: userId, email }, { onConflict: 'id' })
      .select('id')
      .single()
    const row = parseStored(userRowSchema, requireData(response.data, response.error, 'user bootstrap'), 'user bootstrap')
    if (row.id !== userId) {
      throw new RepositoryError('user bootstrap returned an unexpected user')
    }
  }

  async createMealWithItems(userId: string, meal: MealWrite): Promise<MealRecord> {
    const items: LogMealFunctionItem[] = meal.items.map((item) => ({
      name: item.name,
      quantity: item.quantity,
      unit: item.unit,
      calories_kcal: item.calories_kcal ?? null,
      protein_g: item.protein_g ?? null,
      carbs_g: item.carbs_g ?? null,
      fat_g: item.fat_g ?? null,
      fiber_g: item.fiber_g ?? null,
      sugar_g: item.sugar_g ?? null,
      barcode: item.barcode ?? null,
      food_ref_id: item.food_ref_id ?? null,
      confidence: item.confidence ?? null,
      source_notes: item.notes ?? null,
    }))

    const response = await this.client.rpc('log_meal_with_items', {
      p_user_id: userId,
      p_eaten_at: meal.eaten_at,
      p_meal_type: meal.meal_type,
      p_source: meal.source,
      p_image_path: meal.image_path ?? null,
      p_notes: meal.notes ?? null,
      p_items: items,
    })
    if (response.error !== null) {
      throw new TransactionError('meal and item rows were not written', response.error)
    }
    const rows = parseStored(z.array(mealRpcRowSchema), response.data, 'meal write')
    if (rows.length !== 1) {
      throw new RepositoryError('meal write returned an unexpected number of rows')
    }
    const row = rows[0]
    if (row === undefined) {
      throw new RepositoryError('meal write returned no row')
    }
    return toRpcMealRecord(row)
  }

  async getMealsInRange(userId: string, start: string, end: string): Promise<MealRecord[]> {
    const logsResponse = await this.client
      .from('meal_logs')
      .select(mealLogColumns)
      .eq('user_id', userId)
      .gte('eaten_at', start)
      .lt('eaten_at', end)
      .order('eaten_at', { ascending: true })
    const logs = parseStored(z.array(mealLogRowSchema), requireData(logsResponse.data, logsResponse.error, 'meal log read'), 'meal logs')
    if (logs.length === 0) {
      return []
    }

    const mealIds = logs.map((log) => log.id)
    const itemsResponse = await this.client
      .from('meal_items')
      .select(mealItemColumns)
      .in('meal_log_id', mealIds)
    const itemRows = parseStored(z.array(mealItemRowSchema), requireData(itemsResponse.data, itemsResponse.error, 'meal item read'), 'meal items')
    const itemsByMeal = new Map<string, MealItemRecord[]>()
    for (const row of itemRows) {
      const item = toMealItem(row)
      const mealItems = itemsByMeal.get(row.meal_log_id) ?? []
      mealItems.push(item)
      itemsByMeal.set(row.meal_log_id, mealItems)
    }

    return logs.map((log) => toMealRecord(log, itemsByMeal.get(log.id) ?? []))
  }

  async searchFood(userId: string, query: string, limit: number): Promise<SearchFoodItem[]> {
    void userId
    const pattern = `%${escapeIlikePattern(query)}%`
    const nameResponse = await this.client
      .from('food_catalog')
      .select(foodColumns)
      .or('source.eq.curated,source.eq.usda')
      .ilike('name', pattern)
      .limit(limit)
    const nameRows = parseStored(z.array(foodRowSchema), requireData(nameResponse.data, nameResponse.error, 'food search'), 'food catalog')

    const barcodeResponse = await this.client
      .from('food_catalog')
      .select(foodColumns)
      .or('source.eq.curated,source.eq.usda')
      .eq('barcode', query)
      .limit(limit)
    const barcodeRows = parseStored(z.array(foodRowSchema), requireData(barcodeResponse.data, barcodeResponse.error, 'barcode search'), 'food catalog')

    const foods = [...nameRows, ...barcodeRows]
    const seen = new Set<string>()
    const results: SearchFoodItem[] = []
    for (const row of foods) {
      if (seen.has(row.id)) {
        continue
      }
      seen.add(row.id)
      results.push(toFood(row))
      if (results.length >= limit) {
        break
      }
    }
    if (results.length > 0) {
      return results
    }
    let external: ProviderFood[]
    try {
      external = await this.nutritionProvider.search(query, limit)
    } catch (error) {
      if (error instanceof ProviderUnavailableError) {
        throw error
      }
      return []
    }
    const unique = external.filter((food: ProviderFood, index) => external.findIndex((candidate: ProviderFood) => candidate.id === food.id) === index)
    try {
      const cacheClient = this.cacheClientFactory()
      const cacheable = unique.filter((food) => Number.isFinite(food.fdc_id)
        && food.serving_size === '100' && food.serving_unit === 'g')
      if (cacheClient !== undefined && cacheable.length > 0) {
        const rows: Record<string, unknown>[] = cacheable.map((food) => ({
          id: food.id,
          fdc_id: food.fdc_id,
          name: food.name,
          brand: food.brand ?? null,
          barcode: food.barcode ?? null,
          serving_size: food.serving_size ?? null,
          serving_unit: food.serving_unit ?? null,
          calories_kcal: food.calories_kcal ?? null,
          protein_g: food.protein_g ?? null,
          carbs_g: food.carbs_g ?? null,
          fat_g: food.fat_g ?? null,
        }))
        const response = await cacheClient.rpc('upsert_food_catalog', { p_rows: rows })
        if (response.error !== null) {
          throw new RepositoryError('food catalog cache write failed', response.error)
        }
      }
    } catch {
      // The lookup remains useful even when cache persistence is unavailable.
    }
    return unique.slice(0, limit).map((food) => {
      void food.fdc_id
      const { fdc_id, ...publicFood } = food
      void fdc_id
      return publicFood
    })
  }

  async getProfile(userId: string): Promise<StoredProfile | undefined> {
    const response = await this.client
      .from('profiles')
      .select('user_id,sex,age_years,height_cm,weight_kg,activity_level,diet_goal,goal_weight_kg,updated_at')
      .eq('user_id', userId)
      .maybeSingle()
    if (response.error !== null) {
      throw new RepositoryError('profile read failed', response.error)
    }
    if (response.data === null) {
      return undefined
    }
    const profile = parseStored(profileRpcRowSchema, response.data, 'profile')
    return {
      sex: profile.sex,
      age_years: profile.age_years,
      height_cm: profile.height_cm,
      weight_kg: profile.weight_kg,
      activity_level: profile.activity_level,
      diet_goal: profile.diet_goal,
      ...(profile.goal_weight_kg === null ? {} : { goal_weight_kg: profile.goal_weight_kg }),
      updated_at: profile.updated_at,
    }
  }

  async computeTargets(userId: string, _profile: Profile): Promise<ComputeTargetsOutput> {
    void _profile
    const profileResponse = await this.client
      .from('profiles')
      .select('user_id,sex,age_years,height_cm,weight_kg,activity_level,diet_goal,goal_weight_kg,updated_at')
      .eq('user_id', userId)
      .maybeSingle()
    if (profileResponse.error !== null) {
      throw new RepositoryError('profile read failed', profileResponse.error)
    }
    if (profileResponse.data === null) {
      throw new RepositoryError('profile is not set')
    }
    const profile = parseStored(profileRpcRowSchema, profileResponse.data, 'profile')
    const latestWeightResponse = await this.client
      .from('weight_logs')
      .select('measured_at,kg')
      .eq('user_id', userId)
      .order('measured_at', { ascending: false })
      .limit(1)
    const latestWeights = parseStored(z.array(weightRowSchema), requireData(latestWeightResponse.data, latestWeightResponse.error, 'latest weight read'), 'latest weight')
    const latestWeight = latestWeights[0]
    const functionInput: ComputeTargetsFunctionInput = {
      user_id: profile.user_id,
      sex: profile.sex,
      age_years: profile.age_years,
      height_cm: profile.height_cm,
      weight_kg: latestWeight?.kg ?? profile.weight_kg,
      activity_level: profile.activity_level,
      diet_goal: profile.diet_goal,
      goal_weight_kg: profile.goal_weight_kg,
      updated_at: profile.updated_at,
    }
    const response = await this.client.rpc('compute_targets', { p: functionInput })
    const rows = parseStored(z.array(targetRowSchema), requireData(response.data, response.error, 'target computation'), 'computed targets')
    if (rows.length !== 1) {
      throw new RepositoryError('target computation returned an unexpected number of rows')
    }
    const row = rows[0]
    if (row === undefined) {
      throw new RepositoryError('target computation returned no row')
    }
    return parseStored(ComputeTargetsOutputSchema, {
      ...row,
      weight_used: latestWeight === undefined
        ? { kg: profile.weight_kg, source: 'profile' }
        : { kg: latestWeight.kg, measured_at: latestWeight.measured_at, source: 'health' },
    }, 'computed targets')
  }

  async setProfile(userId: string, profile: Profile): Promise<Profile> {
    const response = await this.client
      .from('profiles')
      .upsert({
        user_id: userId,
        ...profile,
        goal_weight_kg: profile.goal_weight_kg ?? null,
      })
      .select('sex,age_years,height_cm,weight_kg,activity_level,diet_goal,goal_weight_kg')
      .single()
    return toProfile(requireData(response.data, response.error, 'profile save'))
  }

  async getGoals(userId: string): Promise<StoredGoals | undefined> {
    const response = await this.client
      .from('goals')
      .select('calorie_target_kcal,protein_g,carbs_g,fat_g,source,updated_at')
      .eq('user_id', userId)
      .maybeSingle()
    if (response.error !== null) {
      throw new RepositoryError('goals read failed', response.error)
    }
    return response.data === null ? undefined : toGoals(response.data)
  }

  async setGoals(userId: string, goals: SetGoalsInput & { source: GoalSummary['source'] }): Promise<StoredGoals> {
    const response = await this.client
      .from('goals')
      .upsert({
        user_id: userId,
        calorie_target_kcal: goals.calorie_target_kcal ?? null,
        protein_g: goals.protein_g ?? null,
        carbs_g: goals.carbs_g ?? null,
        fat_g: goals.fat_g ?? null,
        source: goals.source,
      })
      .select('calorie_target_kcal,protein_g,carbs_g,fat_g,source,updated_at')
      .single()
    return toGoals(requireData(response.data, response.error, 'goals save'))
  }

  async resetGoals(userId: string): Promise<void> {
    const response = await this.client
      .from('goals')
      .upsert({
        user_id: userId,
        calorie_target_kcal: null,
        protein_g: null,
        carbs_g: null,
        fat_g: null,
        source: 'computed',
      })
      .select('user_id')
      .single()
    if (response.error !== null) {
      throw new RepositoryError('goals reset failed', response.error)
    }
  }

  async updateMealItem(userId: string, input: UpdateMealItemInput): Promise<boolean> {
    const patch: Database['public']['Tables']['meal_items']['Update'] = {
      ...(input.name === undefined ? {} : { name: input.name }),
      ...(input.quantity === undefined ? {} : { quantity: input.quantity }),
      ...(input.calories_kcal === undefined ? {} : { calories_kcal: input.calories_kcal }),
      ...(input.protein_g === undefined ? {} : { protein_g: input.protein_g }),
      ...(input.carbs_g === undefined ? {} : { carbs_g: input.carbs_g }),
      ...(input.fat_g === undefined ? {} : { fat_g: input.fat_g }),
    }
    const ownershipResponse = await this.client
      .from('meal_items')
      .select('meal_log_id')
      .eq('id', input.item_id)
      .maybeSingle()
    if (ownershipResponse.error !== null) {
      throw new RepositoryError('meal item ownership check failed', ownershipResponse.error)
    }
    if (ownershipResponse.data === null) {
      return false
    }
    const parentResponse = await this.client
      .from('meal_logs')
      .select('id')
      .eq('id', ownershipResponse.data.meal_log_id)
      .eq('user_id', userId)
      .maybeSingle()
    if (parentResponse.error !== null) {
      throw new RepositoryError('meal item ownership check failed', parentResponse.error)
    }
    if (parentResponse.data === null) {
      return false
    }
    const response = await this.client
      .from('meal_items')
      .update(patch)
      .eq('id', input.item_id)
      .eq('meal_log_id', ownershipResponse.data.meal_log_id)
      .select('id')
    if (response.error !== null) {
      throw new RepositoryError('meal item update failed', response.error)
    }
    return response.data.length > 0
  }

  async deleteMealLog(userId: string, mealLogId: string): Promise<boolean> {
    const response = await this.client
      .from('meal_logs')
      .delete()
      .eq('id', mealLogId)
      .eq('user_id', userId)
      .select('id')
    if (response.error !== null) {
      throw new RepositoryError('meal delete failed', response.error)
    }
    return response.data.length > 0
  }

  async getWeightTrend(userId: string, start: string, end: string): Promise<WeightTrendPoint[]> {
    const response = await this.client
      .from('weight_logs')
      .select('measured_at,kg')
      .eq('user_id', userId)
      .gte('measured_at', start)
      .lt('measured_at', end)
      .order('measured_at', { ascending: true })
    const rows = parseStored(z.array(weightRowSchema), requireData(response.data, response.error, 'weight trend read'), 'weight logs')
    return rows.map((row) => {
      const date = parseStored(CalendarDateSchema, row.measured_at.slice(0, 10), 'weight trend date')
      return {
        date,
      kg: row.kg,
      }
    })
  }
  async getEnergyBurned(userId: string, start: string, end: string): Promise<EnergyBurnedPoint[]> {
    const response = await this.client
      .from('energy_burned_logs')
      .select('burned_at,active_kcal')
      .eq('user_id', userId)
      .gte('burned_at', start)
      .lt('burned_at', end)
      .order('burned_at', { ascending: true })
    const rows = parseStored(z.array(energyBurnedRowSchema), requireData(response.data, response.error, 'energy burned read'), 'energy burned logs')
    const totals = new Map<string, number>()
    for (const row of rows) {
      const date = parseStored(CalendarDateSchema, row.burned_at.slice(0, 10), 'energy burned date')
      totals.set(date, (totals.get(date) ?? 0) + row.active_kcal)
    }
    return [...totals.entries()].map(([date, active_kcal]) => ({ date, active_kcal }))
  }
}

export interface SupabaseRepositoryFactoryOptions {
  fetch?: typeof fetch
  nutritionProvider?: NutritionProvider
  cacheClientFactory?: () => SupabaseClient<Database> | undefined
}

export function createSupabaseRepository(
  supabaseUrl: string,
  anonKey: string,
  options: SupabaseRepositoryFactoryOptions = {},
): SupabaseRepository {
  const accessTokenContext = new AsyncLocalStorage<string>()
  const downstreamFetch = options.fetch ?? fetch
  const authenticatedFetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const accessToken = accessTokenContext.getStore()
    if (accessToken === undefined) {
      throw new RepositoryError('Supabase request bearer credential is missing')
    }
    const headers = new Headers(input instanceof Request ? input.headers : undefined)
    const initHeaders = new Headers(init?.headers)
    initHeaders.forEach((value, name) => {
      headers.set(name, value)
    })
    headers.set('authorization', `Bearer ${accessToken}`)
    const requestInit = { ...init, headers }
    return input instanceof Request
      ? downstreamFetch(input, requestInit)
      : downstreamFetch(input.toString(), requestInit)
  }
  authenticatedFetch.preconnect = (): void => undefined
  const client = createClient<Database>(supabaseUrl, anonKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
      detectSessionInUrl: false,
    },
    global: { fetch: authenticatedFetch },
  })
  const cacheClientFactory = options.cacheClientFactory ?? (() => {
    const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY?.trim()
    return serviceKey === undefined || serviceKey === ''
      ? undefined
      : createClient<Database>(supabaseUrl, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } })
  })
  return new SupabaseRepository({ client, accessTokenContext, nutritionProvider: options.nutritionProvider, cacheClientFactory })
}
