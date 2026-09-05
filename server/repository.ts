import type {
  ComputeTargetsOutput,
  GoalSummary,
  MealRecord,
  ParsedMealItem,
  Profile,
  SearchFoodItem,
  SetGoalsInput,
  Source,
  UpdateMealItemInput,
  WeightTrendPoint,
  EnergyBurnedPoint,
} from '../packages/schema/food-types.ts'
export interface MealWrite {
  eaten_at: string
  meal_type: MealRecord['meal_type']
  source: Source
  image_path?: string
  notes?: string
  items: ParsedMealItem[]
}

export interface StoredGoals {
  calorie_target_kcal?: number
  protein_g?: number
  carbs_g?: number
  fat_g?: number
  source: GoalSummary['source']
  /** Row write time when a stored goals row exists (recency resolution). */
  updated_at?: string
}

/** Profile values plus the row write time when a profile row exists. */
export type StoredProfile = Profile & { updated_at?: string }

export interface MorselRepository {
  /** Run one authenticated request with its own bearer credential context. */
  withAccessToken<T>(accessToken: string, action: () => Promise<T>): Promise<T>
  /** Ensure the authenticated account exists in the app's public user table. */
  ensureUser(userId: string, email: string): Promise<void>
  /**
   * The repository owns the meal write boundary. Implementations must either
   * commit the log and every item or leave no new rows behind.
   */
  createMealWithItems(userId: string, meal: MealWrite): Promise<MealRecord>
  getMealsInRange(userId: string, start: string, end: string): Promise<MealRecord[]>
  searchFood(userId: string, query: string, limit: number): Promise<SearchFoodItem[]>
  getProfile(userId: string): Promise<StoredProfile | undefined>
  computeTargets(userId: string, profile: Profile): Promise<ComputeTargetsOutput>
  setProfile(userId: string, profile: Profile): Promise<Profile>
  getGoals(userId: string): Promise<StoredGoals | undefined>
  setGoals(userId: string, goals: SetGoalsInput & { source: 'manual' }): Promise<StoredGoals>
  /** Clear the stored goal row back to computed (values dropped, source computed). */
  resetGoals(userId: string): Promise<void>
  updateMealItem(userId: string, input: UpdateMealItemInput): Promise<boolean>
  deleteMealLog(userId: string, mealLogId: string): Promise<boolean>
  /**
   * Weight/energy series over instants in [start, end). `timeZone` is the
   * IANA zone whose local calendar days the returned point dates are
   * bucketed into (issue #121).
   */
  getWeightTrend(userId: string, start: string, end: string, timeZone: string): Promise<WeightTrendPoint[]>
  getEnergyBurned(userId: string, start: string, end: string, timeZone: string): Promise<EnergyBurnedPoint[]>
}
