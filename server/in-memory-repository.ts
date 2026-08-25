import { InvalidStoredDataError, TransactionError } from './errors.js'
import { calculateTargets } from './targets.js'
import type {
  ComputeTargetsOutput,
  GoalSummary,
  MealRecord,
  ParsedMealItem,
  Profile,
  SearchFoodItem,
  SetGoalsInput,
  UpdateMealItemInput,
  WeightTrendPoint,
} from '../packages/schema/food-types.js'
import type { MealWrite, MorselRepository, StoredGoals } from './repository.js'

export interface InMemoryRepositoryOptions {
  foods?: SearchFoodItem[]
  weights?: WeightTrendPoint[]
  weightsByUser?: Record<string, WeightTrendPoint[]>
  failNextMealItemWrite?: boolean
}

function cloneItem(item: MealRecord['items'][number]): MealRecord['items'][number] {
  return { ...item }
}

function cloneMeal(meal: MealRecord): MealRecord {
  return { ...meal, items: meal.items.map(cloneItem) }
}

function cloneGoals(goals: StoredGoals): StoredGoals {
  return { ...goals }
}

function inRange(value: string, start: string, end: string): boolean {
  const timestamp = Date.parse(value)
  return timestamp >= Date.parse(start) && timestamp < Date.parse(end)
}

export class InMemoryRepository implements MorselRepository {
  private readonly meals = new Map<string, Map<string, MealRecord>>()
  private readonly profiles = new Map<string, Profile>()
  private readonly goals = new Map<string, StoredGoals>()
  private readonly foods: SearchFoodItem[]
  private readonly weightsByUser = new Map<string, WeightTrendPoint[]>()
  private failNextMealItemWrite: boolean

  constructor(options: InMemoryRepositoryOptions = {}) {
    this.foods = options.foods?.map((food) => ({ ...food })) ?? []
    if (options.weights !== undefined) {
      this.weightsByUser.set('default-user', options.weights.map((weight) => ({ ...weight })))
    }
    for (const [userId, weights] of Object.entries(options.weightsByUser ?? {})) {
      this.weightsByUser.set(userId, weights.map((weight) => ({ ...weight })))
    }
    this.failNextMealItemWrite = options.failNextMealItemWrite ?? false
  }

  setFailNextMealItemWrite(): void {
    this.failNextMealItemWrite = true
  }

  async ensureUser(userId: string, email: string): Promise<void> {
    void userId
    void email
    await Promise.resolve()
  }

  setAccessToken(accessToken: string): void {
    // The in-memory adapter has no external credential to refresh.
    void accessToken
  }

  seedProfile(userId: string, profile: Profile): void {
    this.profiles.set(userId, { ...profile })
  }

  seedGoals(userId: string, goals: StoredGoals): void {
    this.goals.set(userId, cloneGoals(goals))
  }

  seedWeightTrend(userId: string, weights: WeightTrendPoint[]): void {
    this.weightsByUser.set(userId, weights.map((weight) => ({ ...weight })))
  }

  async createMealWithItems(userId: string, meal: MealWrite): Promise<MealRecord> {
    await Promise.resolve()
    const mealLogId = crypto.randomUUID()
    const items: MealRecord['items'] = meal.items.map((item: ParsedMealItem) => ({
      ...item,
      item_id: crypto.randomUUID(),
    }))

    const record: MealRecord = {
      meal_log_id: mealLogId,
      meal_type: meal.meal_type,
      eaten_at: meal.eaten_at,
      items,
    }
    const userMeals = this.meals.get(userId) ?? new Map<string, MealRecord>()
    userMeals.set(mealLogId, cloneMeal({ ...record, items: [] }))
    this.meals.set(userId, userMeals)
    try {
      if (this.failNextMealItemWrite) {
        this.failNextMealItemWrite = false
        throw new TransactionError('meal and item rows were not written')
      }
      userMeals.set(mealLogId, cloneMeal(record))
      return cloneMeal(record)
    } catch (error) {
      userMeals.delete(mealLogId)
      throw error
    }
  }

  async getMealsInRange(userId: string, start: string, end: string): Promise<MealRecord[]> {
    await Promise.resolve()
    const userMeals = this.meals.get(userId)
    if (userMeals === undefined) {
      return []
    }
    return [...userMeals.values()]
      .filter((meal) => inRange(meal.eaten_at, start, end))
      .sort((left, right) => left.eaten_at.localeCompare(right.eaten_at))
      .map(cloneMeal)
  }

  async searchFood(_userId: string, query: string, limit: number): Promise<SearchFoodItem[]> {
    await Promise.resolve()
    const normalizedQuery = query.toLocaleLowerCase()
    return this.foods
      .filter((food) => {
        const nameMatches = food.name.toLocaleLowerCase().includes(normalizedQuery)
        const barcodeMatches = food.barcode?.toLocaleLowerCase() === normalizedQuery
        return nameMatches || barcodeMatches
      })
      .slice(0, limit)
      .map((food) => ({ ...food }))
  }

  async getProfile(userId: string): Promise<Profile | undefined> {
    await Promise.resolve()
    const profile = this.profiles.get(userId)
    return profile === undefined ? undefined : { ...profile }
  }

  async computeTargets(_userId: string, profile: Profile): Promise<ComputeTargetsOutput> {
    await Promise.resolve()
    return calculateTargets(profile)
  }

  async setProfile(userId: string, profile: Profile): Promise<Profile> {
    await Promise.resolve()
    const savedProfile = { ...profile }
    this.profiles.set(userId, savedProfile)
    return { ...savedProfile }
  }

  async getGoals(userId: string): Promise<StoredGoals | undefined> {
    await Promise.resolve()
    const goals = this.goals.get(userId)
    return goals === undefined ? undefined : cloneGoals(goals)
  }

  async setGoals(userId: string, goals: SetGoalsInput & { source: GoalSummary['source'] }): Promise<StoredGoals> {
    await Promise.resolve()
    const savedGoals: StoredGoals = {
      source: goals.source,
      ...(goals.calorie_target_kcal === undefined ? {} : { calorie_target_kcal: goals.calorie_target_kcal }),
      ...(goals.protein_g === undefined ? {} : { protein_g: goals.protein_g }),
      ...(goals.carbs_g === undefined ? {} : { carbs_g: goals.carbs_g }),
      ...(goals.fat_g === undefined ? {} : { fat_g: goals.fat_g }),
    }
    this.goals.set(userId, savedGoals)
    return cloneGoals(savedGoals)
  }

  async updateMealItem(userId: string, input: UpdateMealItemInput): Promise<boolean> {
    await Promise.resolve()
    const userMeals = this.meals.get(userId)
    if (userMeals === undefined) {
      return false
    }

    for (const [mealId, meal] of userMeals.entries()) {
      const itemIndex = meal.items.findIndex((item) => item.item_id === input.item_id)
      if (itemIndex < 0) {
        continue
      }
      const item = meal.items[itemIndex]
      if (item === undefined) {
        throw new InvalidStoredDataError('meal item row was missing during update')
      }
      const updatedItem: MealRecord['items'][number] = {
        ...item,
        ...(input.name === undefined ? {} : { name: input.name }),
        ...(input.quantity === undefined ? {} : { quantity: input.quantity }),
        ...(input.calories_kcal === undefined ? {} : { calories_kcal: input.calories_kcal }),
        ...(input.protein_g === undefined ? {} : { protein_g: input.protein_g }),
        ...(input.carbs_g === undefined ? {} : { carbs_g: input.carbs_g }),
        ...(input.fat_g === undefined ? {} : { fat_g: input.fat_g }),
      }
      const updatedMeal: MealRecord = {
        ...meal,
        items: meal.items.map((candidate, index) => index === itemIndex ? updatedItem : candidate),
      }
      userMeals.set(mealId, updatedMeal)
      return true
    }
    return false
  }

  async deleteMealLog(userId: string, mealLogId: string): Promise<boolean> {
    await Promise.resolve()
    const userMeals = this.meals.get(userId)
    return userMeals?.delete(mealLogId) ?? false
  }

  async getWeightTrend(userId: string, start: string, end: string): Promise<WeightTrendPoint[]> {
    await Promise.resolve()
    return (this.weightsByUser.get(userId) ?? [])
      .filter((weight) => inRange(`${weight.date}T00:00:00.000Z`, start, end))
      .sort((left, right) => left.date.localeCompare(right.date))
      .map((weight) => ({ ...weight }))
  }
}
