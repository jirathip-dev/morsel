import { InvalidStoredDataError, ProviderUnavailableError, TransactionError } from './errors.js'
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
  EnergyBurnedPoint,
} from '../packages/schema/food-types.js'
import type { MealWrite, MorselRepository, StoredGoals, StoredProfile } from './repository.js'
import type { NutritionProvider } from './nutrition-provider.js'
import { zonedDateLabel } from './zone-time.ts'

export interface InMemoryRepositoryOptions {
  foods?: SearchFoodItem[]
  weights?: WeightTrendPoint[]
  weightsByUser?: Record<string, WeightTrendPoint[]>
  energyBurnedByUser?: Record<string, EnergyBurnedPoint[]>
  failNextMealItemWrite?: boolean
  nutritionProvider?: NutritionProvider
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
  private readonly profiles = new Map<string, StoredProfile>()
  private readonly goals = new Map<string, StoredGoals>()
  private readonly foods: SearchFoodItem[]
  private readonly weightsByUser = new Map<string, WeightTrendPoint[]>()
  private readonly energyBurnedByUser = new Map<string, EnergyBurnedPoint[]>()
  private failNextMealItemWrite: boolean
  private readonly nutritionProvider?: NutritionProvider
  // Monotonic write clock: every row write (or explicit seed time) advances it,
  // so "latest write wins" comparisons stay deterministic within a repository.
  private clockMs = 0

  constructor(options: InMemoryRepositoryOptions = {}) {
    this.foods = options.foods?.map((food) => ({ ...food })) ?? []
    if (options.weights !== undefined) {
      this.weightsByUser.set('default-user', options.weights.map((weight) => ({ ...weight })))
    }
    for (const [userId, weights] of Object.entries(options.weightsByUser ?? {})) {
      this.weightsByUser.set(userId, weights.map((weight) => ({ ...weight })))
    }
    for (const [userId, rows] of Object.entries(options.energyBurnedByUser ?? {})) {
      this.energyBurnedByUser.set(userId, rows.map((row) => ({ ...row })))
    }
    this.failNextMealItemWrite = options.failNextMealItemWrite ?? false
    this.nutritionProvider = options.nutritionProvider
  }

  private stampIso(): string {
    this.clockMs = Math.max(Date.now(), this.clockMs + 1)
    return new Date(this.clockMs).toISOString()
  }

  private noteTimestamp(timestamp: string): void {
    this.clockMs = Math.max(this.clockMs, Date.parse(timestamp))
  }

  setFailNextMealItemWrite(): void {
    this.failNextMealItemWrite = true
  }

  async ensureUser(userId: string, email: string): Promise<void> {
    void userId
    void email
    await Promise.resolve()
  }

  withAccessToken<T>(_accessToken: string, action: () => Promise<T>): Promise<T> {
    // The in-memory adapter has no external credential to bind.
    return action()
  }

  seedProfile(userId: string, profile: Profile, updatedAt?: string): void {
    const timestamp = updatedAt ?? this.stampIso()
    this.noteTimestamp(timestamp)
    this.profiles.set(userId, { ...profile, updated_at: timestamp })
  }

  seedGoals(userId: string, goals: StoredGoals, updatedAt?: string): void {
    const timestamp = updatedAt ?? this.stampIso()
    this.noteTimestamp(timestamp)
    this.goals.set(userId, cloneGoals({ ...goals, updated_at: timestamp }))
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
    const cached = this.foods
      .filter((food) => {
        const nameMatches = food.name.toLocaleLowerCase().includes(normalizedQuery)
        const barcodeMatches = food.barcode?.toLocaleLowerCase() === normalizedQuery
        return nameMatches || barcodeMatches
      })
      .slice(0, limit)
      .map((food) => ({ ...food }))
    if (cached.length > 0 || this.nutritionProvider === undefined) {
      return cached
    }
    try {
      const external = await this.nutritionProvider.search(query, limit)
      const unique = external.filter((food, index) => external.findIndex((candidate) => candidate.id === food.id) === index)
      this.foods.push(...unique.map(({ fdc_id, ...food }) => {
        void fdc_id
        return food
      }))
      return unique.slice(0, limit).map((food) => {
        void food.fdc_id
        const { fdc_id, ...publicFood } = food
        void fdc_id
        return { ...publicFood }
      })
    } catch (error) {
      if (error instanceof ProviderUnavailableError) {
        throw error
      }
      return []
    }
  }

  async getProfile(userId: string): Promise<StoredProfile | undefined> {
    await Promise.resolve()
    const profile = this.profiles.get(userId)
    return profile === undefined ? undefined : { ...profile }
  }

  async computeTargets(userId: string, profile: Profile): Promise<ComputeTargetsOutput> {
    await Promise.resolve()
    const latest = [...(this.weightsByUser.get(userId) ?? [])].sort((left, right) => right.date.localeCompare(left.date))[0]
    const targets = calculateTargets(latest === undefined ? profile : { ...profile, weight_kg: latest.kg })
    return {
      ...targets,
      weight_used: latest === undefined
        ? { kg: profile.weight_kg, source: 'profile' }
        : { kg: latest.kg, measured_at: `${latest.date}T00:00:00.000Z`, source: 'health' },
    }
  }

  async setProfile(userId: string, profile: Profile): Promise<Profile> {
    await Promise.resolve()
    const savedProfile = { ...profile }
    this.profiles.set(userId, { ...savedProfile, updated_at: this.stampIso() })
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
      updated_at: this.stampIso(),
      ...(goals.calorie_target_kcal === undefined ? {} : { calorie_target_kcal: goals.calorie_target_kcal }),
      ...(goals.protein_g === undefined ? {} : { protein_g: goals.protein_g }),
      ...(goals.carbs_g === undefined ? {} : { carbs_g: goals.carbs_g }),
      ...(goals.fat_g === undefined ? {} : { fat_g: goals.fat_g }),
    }
    this.goals.set(userId, savedGoals)
    return cloneGoals(savedGoals)
  }

  async resetGoals(userId: string): Promise<void> {
    await Promise.resolve()
    this.goals.set(userId, { source: 'computed', updated_at: this.stampIso() })
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

  async getWeightTrend(userId: string, start: string, end: string, timeZone: string): Promise<WeightTrendPoint[]> {
    await Promise.resolve()
    return (this.weightsByUser.get(userId) ?? [])
      .filter((weight) => inRange(`${weight.date}T00:00:00.000Z`, start, end))
      .map((weight) => ({
        // Seeded points are date-only; their stored instant is the UTC
        // midnight of the label, bucketed into the requested zone.
        date: zonedDateLabel(Date.parse(`${weight.date}T00:00:00.000Z`), timeZone),
        kg: weight.kg,
      }))
      .sort((left, right) => left.date.localeCompare(right.date))
  }

  async getEnergyBurned(userId: string, start: string, end: string, timeZone: string): Promise<EnergyBurnedPoint[]> {
    await Promise.resolve()
    return (this.energyBurnedByUser.get(userId) ?? [])
      .filter((row) => inRange(`${row.date}T00:00:00.000Z`, start, end))
      .map((row) => ({
        // Seeded points are date-only; their stored instant is the UTC
        // midnight of the label, bucketed into the requested zone.
        date: zonedDateLabel(Date.parse(`${row.date}T00:00:00.000Z`), timeZone),
        active_kcal: row.active_kcal,
      }))
      .sort((left, right) => left.date.localeCompare(right.date))
  }
}
