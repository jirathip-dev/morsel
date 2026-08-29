import { createHash } from 'node:crypto'
import { z } from 'zod'
import { ProviderUnavailableError } from './errors.ts'
import type { SearchFoodItem } from '../packages/schema/food-types.ts'

export interface NutritionProvider {
  search(query: string, limit: number): Promise<ProviderFood[]>
}

export const NUTRITION_PROVIDER_TIMEOUT_MS = 5_000

export interface ProviderFood extends SearchFoodItem {
  fdc_id: number
}

export type NutritionFetcher = (input: string | URL | Request, init?: RequestInit) => Promise<Response>

interface UsdaFood {
  fdcId?: number
  description?: string
  brandOwner?: string
  gtinUpc?: string
  servingSize?: number
  servingSizeUnit?: string
  foodNutrients?: Array<{ nutrientName?: string; value?: number }>
}

interface UsdaResponse {
  foods?: UsdaFood[]
}

function isUsdaResponse(value: unknown): value is UsdaResponse {
  return z.object({ foods: z.array(z.unknown()).optional() }).safeParse(value).success
}

function nutrient(food: UsdaFood, name: string): number | undefined {
  const value = food.foodNutrients?.find((item) => item.nutrientName?.toLowerCase() === name.toLowerCase())?.value
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

function idFor(fdcId: number): string {
  const hash = createHash('sha256').update(`usda:${String(fdcId)}`).digest('hex')
  return `${hash.slice(0, 8)}-${hash.slice(8, 12)}-4${hash.slice(13, 16)}-8${hash.slice(17, 20)}-${hash.slice(20, 32)}`
}

function toFood(food: UsdaFood): ProviderFood | undefined {
  if (typeof food.fdcId !== 'number' || typeof food.description !== 'string' || food.description.trim() === '') {
    return undefined
  }
  return {
    id: idFor(food.fdcId),
    fdc_id: food.fdcId,
    name: food.description,
    ...(food.brandOwner === undefined ? {} : { brand: food.brandOwner }),
    ...(food.gtinUpc === undefined ? {} : { barcode: food.gtinUpc }),
    serving_size: '100',
    serving_unit: 'g',
    ...(nutrient(food, 'Energy') === undefined ? {} : { calories_kcal: nutrient(food, 'Energy') }),
    ...(nutrient(food, 'Protein') === undefined ? {} : { protein_g: nutrient(food, 'Protein') }),
    ...(nutrient(food, 'Carbohydrate, by difference') === undefined ? {} : { carbs_g: nutrient(food, 'Carbohydrate, by difference') }),
    ...(nutrient(food, 'Total lipid (fat)') === undefined ? {} : { fat_g: nutrient(food, 'Total lipid (fat)') }),
  }
}

export class UsdaFoodDataCentralProvider implements NutritionProvider {
  constructor(private readonly fetcher: NutritionFetcher = fetch) {}

  async search(query: string, limit: number): Promise<ProviderFood[]> {
    const apiKey = process.env.USDA_API_KEY?.trim()
    if (apiKey === undefined || apiKey === '') {
      return []
    }
    const url = new URL('https://api.nal.usda.gov/fdc/v1/foods/search')
    url.searchParams.set('api_key', apiKey)
    url.searchParams.set('query', query)
    url.searchParams.set('pageSize', String(limit))
    let response: Response
    try {
      response = await this.fetcher(url, { signal: AbortSignal.timeout(NUTRITION_PROVIDER_TIMEOUT_MS) })
    } catch (error) {
      throw new ProviderUnavailableError(error)
    }
    if (!response.ok) {
      throw new ProviderUnavailableError()
    }
    const payload: unknown = await response.json()
    if (!isUsdaResponse(payload)) {
      return []
    }
    return (payload.foods ?? []).map(toFood).filter((food): food is ProviderFood => food !== undefined)
  }
}
