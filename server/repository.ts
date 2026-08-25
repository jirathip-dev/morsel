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
} from '../packages/schema/food-types.js'

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
}

export interface MorselRepository {
  /**
   * The repository owns the meal write boundary. Implementations must either
   * commit the log and every item or leave no new rows behind.
   */
  createMealWithItems(userId: string, meal: MealWrite): Promise<MealRecord>
  getMealsInRange(userId: string, start: string, end: string): Promise<MealRecord[]>
  searchFood(userId: string, query: string, limit: number): Promise<SearchFoodItem[]>
  getProfile(userId: string): Promise<Profile | undefined>
  computeTargets(userId: string, profile: Profile): Promise<ComputeTargetsOutput>
  setProfile(userId: string, profile: Profile): Promise<Profile>
  getGoals(userId: string): Promise<StoredGoals | undefined>
  setGoals(userId: string, goals: SetGoalsInput & { source: 'manual' }): Promise<StoredGoals>
  updateMealItem(userId: string, input: UpdateMealItemInput): Promise<boolean>
  deleteMealLog(userId: string, mealLogId: string): Promise<boolean>
  getWeightTrend(userId: string, start: string, end: string): Promise<WeightTrendPoint[]>
}
