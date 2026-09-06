import { describe, expect, it } from 'vitest'
import { InMemoryRepository } from './in-memory-repository.js'
import { MorselService } from './service.js'

// Issue #152 — agent-path named-menu contract: ONE log_meal call creates a
// reusable named menu from its items; later calls re-log the bundle through
// list_menus + menu_name. Logs are SNAPSHOT copies (menu edits never change
// past meals) and a menu is meal-type-free (any meal section).

const userId = '00000000-0000-4000-8000-000000000152'
const fixedNow = () => new Date('2026-08-25T12:00:00.000Z')

function createService(repository = new InMemoryRepository()): MorselService {
  return new MorselService({ repository, userId, now: fixedNow })
}

const eggsOnToastItems = [
  { name: 'toast', quantity: 1, unit: 'piece', calories_kcal: 90, carbs_g: 17 },
  { name: 'eggs', quantity: 2, unit: 'piece', calories_kcal: 140, protein_g: 12 },
  { name: 'hot sauce', quantity: 1, unit: 'serving', calories_kcal: 5 },
]

describe('named menus (issue #152) agent path', () => {
  it('one log_meal call with a new menu_name creates the reusable menu AND logs a grouped snapshot', async () => {
    const repository = new InMemoryRepository()
    const service = createService(repository)

    const logged = await service.logMeal({
      meal_type: 'breakfast',
      eaten_at: '2026-08-25T07:30:00.000Z',
      menu_name: 'Eggs on toast',
      items: eggsOnToastItems,
    })
    expect(logged.recorded).toBe(true)

    // The menu template now exists with the log's items (list_menus proof).
    const menus = await service.listMenus(undefined)
    expect(menus.menus).toHaveLength(1)
    expect(menus.menus[0]).toMatchObject({
      name: 'Eggs on toast',
    })
    expect(menus.menus[0]?.items.map((item) => item.name)).toEqual(['toast', 'eggs', 'hot sauce'])

    // The logged meal carries snapshot grouping: same group id + name copy on
    // every item (DB rows have no live reference to the menu template).
    const day = await service.getDay({ date: '2026-08-25' })
    expect(day.meals).toHaveLength(1)
    const items = day.meals[0]?.items ?? []
    expect(items.map((item) => item.menu_name)).toEqual(['Eggs on toast', 'Eggs on toast', 'Eggs on toast'])
    const groupIDs = new Set(items.map((item) => item.menu_group_id))
    expect(groupIDs.size).toBe(1)
    expect(groupIDs.has(undefined)).toBe(false)
  })

  it('list_menus + menu_name re-logs the bundle with ONE call (items omitted) and a fresh snapshot group', async () => {
    const repository = new InMemoryRepository()
    const service = createService(repository)
    await service.logMeal({
      meal_type: 'breakfast',
      eaten_at: '2026-08-25T07:30:00.000Z',
      menu_name: 'Eggs on toast',
      items: eggsOnToastItems,
    })
    const firstDay = await service.getDay({ date: '2026-08-25' })
    const firstGroup = firstDay.meals[0]?.items[0]?.menu_group_id

    // Re-log under DINNER with no items: the server copies the menu's
    // current items (A9: any meal section works).
    const logged = await service.logMeal({
      meal_type: 'dinner',
      eaten_at: '2026-08-25T19:00:00.000Z',
      menu_name: 'Eggs on toast',
    })
    expect(logged.recorded).toBe(true)

    const day = await service.getDay({ date: '2026-08-25' })
    const dinner = day.meals.find((meal) => meal.meal_type === 'dinner')
    expect(dinner).toBeDefined()
    expect(dinner?.items.map((item) => item.name)).toEqual(['toast', 'eggs', 'hot sauce'])
    expect(dinner?.items.map((item) => item.menu_name)).toEqual(['Eggs on toast', 'Eggs on toast', 'Eggs on toast'])
    // A fresh set instance gets its own group id (never merged with the
    // earlier log's snapshot group).
    const dinnerGroup = dinner?.items[0]?.menu_group_id
    expect(dinnerGroup).toBeDefined()
    expect(dinnerGroup).not.toBe(firstGroup)
  })

  it('menu_name of a menu that does not exist yet requires items (actionable not_found)', async () => {
    const service = createService()
    await expect(service.logMeal({
      meal_type: 'lunch',
      menu_name: 'No such menu',
    })).rejects.toMatchObject({ code: 'not_found' })
    const menus = await service.listMenus(undefined)
    expect(menus.menus).toEqual([])
  })

  it('snapshot proof: editing a menu NEVER changes past meals (A2)', async () => {
    const repository = new InMemoryRepository()
    const service = createService(repository)
    await service.logMeal({
      meal_type: 'breakfast',
      eaten_at: '2026-08-25T07:30:00.000Z',
      menu_name: 'Eggs on toast',
      items: eggsOnToastItems,
    })

    // The app edits the template (rename + different items + different
    // macros) AFTER the meal was logged.
    const menusBefore = await service.listMenus(undefined)
    const menuID = menusBefore.menus[0]?.menu_id
    expect(menuID).toBeDefined()
    repository.upsertMenuForTest(userId, {
      menu_id: menuID ?? '00000000-0000-4000-8000-000000000999',
      name: 'Brunch plate',
      items: [
        { item_id: '00000000-0000-4000-8000-000000000151', name: 'pancakes', quantity: 3, unit: 'piece', calories_kcal: 350 },
        { item_id: '00000000-0000-4000-8000-000000000152', name: 'bacon', quantity: 2, unit: 'piece', calories_kcal: 90 },
      ],
    })

    // The template changed...
    const after = await service.listMenus(undefined)
    expect(after.menus[0]?.name).toBe('Brunch plate')
    expect(after.menus[0]?.items.map((item) => item.name)).toEqual(['pancakes', 'bacon'])

    // ...but the PAST meal log rows are byte-identical snapshots: original
    // name, original items/macros, original group id.
    const day = await service.getDay({ date: '2026-08-25' })
    const breakfast = day.meals.find((meal) => meal.meal_type === 'breakfast')
    expect(breakfast?.items.map((item) => item.menu_name)).toEqual(['Eggs on toast', 'Eggs on toast', 'Eggs on toast'])
    expect(breakfast?.items.map((item) => item.name)).toEqual(['toast', 'eggs', 'hot sauce'])
    expect(breakfast?.items[1]?.protein_g).toBe(12)
    expect(breakfast?.items[0]?.menu_group_id).toBe(breakfast?.items[2]?.menu_group_id)
  })

  it('a menu log groups under the log meal_type while meal_type sections stay unchanged (A4/A9 regression)', async () => {
    const service = createService()
    await service.logMeal({
      meal_type: 'breakfast',
      eaten_at: '2026-08-25T07:00:00.000Z',
      menu_name: 'Eggs on toast',
      items: eggsOnToastItems,
    })
    await service.logMeal({
      meal_type: 'dinner',
      eaten_at: '2026-08-25T19:30:00.000Z',
      menu_name: 'Eggs on toast',
    })

    const day = await service.getDay({ date: '2026-08-25' })
    expect(day.meals.map((meal) => meal.meal_type)).toEqual(['breakfast', 'dinner'])
    expect(day.meals[0]?.items).toHaveLength(3)
    expect(day.meals[1]?.items).toHaveLength(3)
    expect(day.totals.calories_kcal).toBe(470) // 235 + 235 — no double counting
  })

  it('loose logs stay loose: items without menu_name carry no snapshot fields', async () => {
    const repository = new InMemoryRepository()
    const service = createService(repository)
    await service.logMeal({
      meal_type: 'snack',
      eaten_at: '2026-08-25T16:00:00.000Z',
      items: [{ name: 'coffee', calories_kcal: 2 }],
    })
    const menus = await service.listMenus(undefined)
    expect(menus.menus).toEqual([])
    const day = await service.getDay({ date: '2026-08-25' })
    expect(day.meals[0]?.items[0]).toMatchObject({ name: 'coffee' })
    expect(day.meals[0]?.items[0]?.menu_name).toBeUndefined()
    expect(day.meals[0]?.items[0]?.menu_group_id).toBeUndefined()
  })
})
