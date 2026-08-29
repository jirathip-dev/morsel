import { afterEach, describe, expect, it } from 'vitest'
import { ProviderUnavailableError } from './errors.js'
import { UsdaFoodDataCentralProvider, type NutritionFetcher } from './nutrition-provider.js'

const previousKey = process.env.USDA_API_KEY

afterEach(() => {
  if (previousKey === undefined) delete process.env.USDA_API_KEY
  else process.env.USDA_API_KEY = previousKey
})

describe('UsdaFoodDataCentralProvider', () => {
  it('maps USDA nutrients and keeps the external id stable', async () => {
    process.env.USDA_API_KEY = 'test-key'
    let signal: AbortSignal | null | undefined
    const fetcher: NutritionFetcher = (_input, init) => {
      signal = init?.signal
      return Promise.resolve(new Response(JSON.stringify({ foods: [{
        fdcId:  bananaId,
        description: 'Banana, raw',
        brandOwner: 'Example',
        servingSize: 118,
        servingSizeUnit: 'g',
        foodNutrients: [
          { nutrientName: 'Energy', value: 105 },
          { nutrientName: 'Protein', value: 1.3 },
          { nutrientName: 'Carbohydrate, by difference', value: 27 },
          { nutrientName: 'Total lipid (fat)', value: 0.4 },
        ],
      }] })))
    }
    const provider = new UsdaFoodDataCentralProvider(fetcher)
    const first = await provider.search('banana', 1)
    const second = await provider.search('banana', 1)

    expect(first[0]).toMatchObject({ name: 'Banana, raw', calories_kcal: 105, protein_g: 1.3, carbs_g: 27, fat_g: 0.4 })
    expect(first[0]?.id).toBe(second[0]?.id)
    expect(signal).toBeInstanceOf(AbortSignal)
  })

  it('does not fetch without a key and reports upstream failures as typed errors', async () => {
    delete process.env.USDA_API_KEY
    let calls = 0
    const fetcher: NutritionFetcher = () => {
      calls += 1
      return Promise.resolve(new Response('{}'))
    }
    await expect(new UsdaFoodDataCentralProvider(fetcher).search('banana', 1)).resolves.toEqual([])
    expect(calls).toBe(0)

    process.env.USDA_API_KEY = 'test-key'
    const failing: NutritionFetcher = () => Promise.resolve(new Response('', { status: 503 }))
    await expect(new UsdaFoodDataCentralProvider(failing).search('banana', 1)).rejects.toBeInstanceOf(ProviderUnavailableError)
  })

  it('treats malformed successful payloads as honest empty results', async () => {
    process.env.USDA_API_KEY = 'test-key'
    const fetcher: NutritionFetcher = () => Promise.resolve(new Response(JSON.stringify({ foods: 'not-an-array' })))
    await expect(new UsdaFoodDataCentralProvider(fetcher).search('banana', 1)).resolves.toEqual([])
  })
})

const bananaId = 173944
