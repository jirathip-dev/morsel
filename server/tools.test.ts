import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import type { ToolAnnotations } from '@modelcontextprotocol/sdk/types.js'
import { describe, expect, it } from 'vitest'
import { createMorselApp } from './app.js'
import type { Authenticate } from './auth.js'
import { InMemoryRepository } from './in-memory-repository.js'
import { ArtworkIdSchema, ContractVersionSchema, contractVersionStamp, GetDayOutputSchema, ListMenusOutputSchema, ARTWORK_ID_INSTRUCTION, MCP_CONTRACT_VERSION } from '../packages/schema/food-types.ts'
import bundledCatalog from '../app/Resources/FoodArt/catalog.json'

// This file pins the client-visible tool contract as it is EMITTED by the real
// MCP registration/inspection path (server registerTool -> SDK -> tools/list
// over the Streamable HTTP transport). It never reads server/tools.ts source:
// every expectation is asserted against the protocol output a local SDK client
// receives, so a metadata regression is caught even if the registration source
// were rewritten.

const userId = '00000000-0000-4000-8000-000000000011'

interface ExpectedToolContract {
  name: string
  title: string
  description: string
  annotations: ToolAnnotations
  inputRequired?: string[]
  outputRequired: string[]
}

const READ_ONLY: ToolAnnotations = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: false,
  openWorldHint: false,
}
const DESTRUCTIVE: ToolAnnotations = {
  readOnlyHint: false,
  destructiveHint: true,
  idempotentHint: false,
  openWorldHint: false,
}
const UNCLAIMED: ToolAnnotations = {
  readOnlyHint: false,
  destructiveHint: false,
  idempotentHint: false,
  openWorldHint: false,
}
const OPEN_WORLD_SEARCH: ToolAnnotations = {
  readOnlyHint: false,
  destructiveHint: false,
  idempotentHint: false,
  openWorldHint: true,
}

const EXPECTED_TOOLS: ExpectedToolContract[] = [
  {
    name: 'log_meal',
    title: 'Log a meal',
    description: 'Record one meal and all of its food items. Send the photo bytes with image_base64 when the client exposes the image; the server stores the photo and returns it on reads (image_error reports a photo that could not be stored). An omitted item artwork_id is resolved from the item name to a published identity; nothing is invented. When an item matches a published artwork identity, set artwork_id to that exact published ID from this tool\'s artwork_id enum — allowed IDs are the enum and the shipped catalog is the canonical set. Omit artwork_id only when genuinely uncertain; never invent an ID and never upload illustration files.',
    annotations: UNCLAIMED,
    // Issue #152: items optional only when menu_name names an existing menu.
    inputRequired: ['meal_type'],
    outputRequired: ['meal_log_id', 'recorded'],
  },
  {
    name: 'attach_meal_image',
    title: 'Attach a photo to a logged meal',
    description: 'Attach a food photo to an existing meal log when the meal was logged without one (or its photo failed to store). Send the photo bytes with image_base64; image_error reports a photo that could not be attached.',
    annotations: UNCLAIMED,
    inputRequired: ['meal_log_id'],
    outputRequired: ['ok', 'attached'],
  },
  {
    name: 'get_day',
    title: 'Get a day of meals',
    description: 'Read meals, nutrition totals, and the effective goal for one calendar day.',
    annotations: READ_ONLY,
    inputRequired: ['date'],
    outputRequired: ['date', 'timezone', 'contract', 'meals', 'totals', 'render'],
  },
  {
    name: 'search_food',
    title: 'Search the food catalog',
    description: 'Find catalog foods by name or barcode before estimating macros.',
    annotations: OPEN_WORLD_SEARCH,
    inputRequired: ['query'],
    outputRequired: ['results'],
  },
  {
    name: 'list_menus',
    title: 'List named menus',
    description: 'List the caller\'s reusable named menus (issue #152). A menu is a meal-type-free bundle of items: log it under any meal section by passing its menu_name to log_meal, or seed a new one by logging items with a menu_name the user does not have yet.',
    annotations: READ_ONLY,
    outputRequired: ['menus'],
  },
  {
    name: 'get_profile',
    title: 'Get the body profile',
    description: 'Read the body metrics used to compute nutrition targets.',
    annotations: READ_ONLY,
    outputRequired: ['sex', 'age_years', 'height_cm', 'weight_kg', 'activity_level', 'diet_goal'],
  },
  {
    name: 'set_profile',
    title: 'Set the body profile',
    description: 'Create or replace the body metrics used to compute nutrition targets.',
    annotations: UNCLAIMED,
    inputRequired: ['sex', 'age_years', 'height_cm', 'weight_kg', 'activity_level', 'diet_goal'],
    outputRequired: ['ok', 'saved', 'effective_goal'],
  },
  {
    name: 'compute_targets',
    title: 'Compute nutrition targets',
    description: 'Compute BMR, TDEE, calories, and macros from the saved profile; uses the latest imported weight when available.',
    annotations: READ_ONLY,
    outputRequired: ['bmr_kcal', 'tdee_kcal', 'calorie_target_kcal', 'protein_g', 'carbs_g', 'fat_g', 'weight_used'],
  },
  {
    name: 'get_goals',
    title: 'Get the effective goal',
    description: 'Read the effective computed or manually overridden nutrition goal.',
    annotations: READ_ONLY,
    outputRequired: ['calorie_target_kcal', 'protein_g', 'carbs_g', 'fat_g', 'source'],
  },
  {
    name: 'set_goals',
    title: 'Set manual goals',
    description: 'Set one or more manual nutrition goal values; omitted values retain the effective target.',
    annotations: UNCLAIMED,
    outputRequired: ['ok', 'source'],
  },
  {
    name: 'set_dated_target_addition',
    title: 'Confirm a dated target addition',
    description: 'Persist an explicitly confirmed nonnegative addition for one diary date. Zero removes it. Read get_day first for revision; past corrections require historical confirmation and manual targets require acknowledgement. Never invent a baseline or exercise recommendation.',
    annotations: UNCLAIMED,
    inputRequired: ['date', 'addition_kcal', 'mutation_id'],
    outputRequired: ['dated_target'],
  },
  {
    name: 'reset_goals',
    title: 'Reset manual goals',
    description: 'Discard the stored manual goal override so the effective target returns to the computed values from the profile.',
    annotations: UNCLAIMED,
    outputRequired: ['ok', 'reset'],
  },
  {
    name: 'update_meal_item',
    title: 'Update one meal item',
    description: 'Correct the name, quantity, or macros for one meal item owned by the caller. At least one field besides item_id is required. When replacing an item\'s illustration identity, set artwork_id to that exact published ID from this tool\'s artwork_id enum; omitting artwork_id preserves the stored identity. Never invent an ID and never upload illustration files.',
    annotations: UNCLAIMED,
    inputRequired: ['item_id'],
    outputRequired: ['ok', 'updated'],
  },
  {
    name: 'delete_meal_log',
    title: 'Delete a meal log',
    description: 'Delete one meal log and its items owned by the caller.',
    annotations: DESTRUCTIVE,
    inputRequired: ['meal_log_id'],
    outputRequired: ['ok', 'deleted'],
  },
  {
    name: 'get_weight_trend',
    title: 'Get the weight trend',
    description: 'Read imported body-mass measurements and the latest weight.',
    annotations: READ_ONLY,
    outputRequired: ['date', 'timezone', 'series'],
  },
  {
    name: 'get_energy_burned',
    title: 'Get energy burned',
    description: 'Read daily active-energy burned measurements imported from Apple Health.',
    annotations: READ_ONLY,
    outputRequired: ['date', 'timezone', 'series'],
  },
  {
    name: 'get_dashboard_summary',
    title: 'Get the dashboard summary',
    description: 'Summarize average calories, streak, macros, and weight trend over the requested number of days.',
    annotations: READ_ONLY,
    outputRequired: ['date', 'timezone', 'avg_calories_kcal', 'streak_days', 'macro_split', 'weight_trend', 'render'],
  },
]

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isSchemaObject(value: unknown): value is { type?: string; required?: string[] } {
  return isRecord(value)
}

// Issue #294: the size of the artwork_id enum as the client holds it in its
// own tool list — the value a stale client compares against the served
// published_identity_count.
function listedArtworkEnumSize(tool: unknown): number | undefined {
  const inputSchema = isRecord(tool) ? tool.inputSchema : undefined
  const properties = isRecord(inputSchema) ? inputSchema.properties : undefined
  const arraySchema = isRecord(properties) ? properties.items : undefined
  const itemSchema = isRecord(arraySchema) ? arraySchema.items : undefined
  const itemProperties = isRecord(itemSchema) ? itemSchema.properties : undefined
  const artworkId = isRecord(itemProperties) ? itemProperties.artwork_id : undefined
  const values = isRecord(artworkId) ? artworkId.enum : undefined
  return Array.isArray(values) ? values.length : undefined
}

async function connectClient(repository: InMemoryRepository): Promise<Client> {
  const authenticate: Authenticate = (token) => Promise.resolve({
    userId,
    email: 'test@example.com',
    token,
    authInfo: { token, clientId: 'tools-test-client', scopes: [], extra: { userId } },
  })
  const app = createMorselApp({
    authenticate,
    repositoryFactory: () => repository,
    enableJsonResponse: true,
  })
  const fetchLike = async (url: string | URL, init?: RequestInit): Promise<Response> =>
    app.fetch(new Request(url.toString(), init))
  const client = new Client({ name: 'morsel-tools-test', version: '1.0.0' })
  const transport = new StreamableHTTPClientTransport(new URL('https://morsel.test/mcp'), {
    fetch: fetchLike,
    requestInit: { headers: { Authorization: `Bearer tools-test-token` } },
  })
  await client.connect(transport)
  return client
}

describe('MCP tool registration metadata (tools/list)', () => {
  it('registers the existing tools plus the dated addition writer', async () => {
    const client = await connectClient(new InMemoryRepository())
    try {
      const listed = await client.listTools()
      expect(listed.tools.map((tool) => tool.name).sort()).toEqual(
        EXPECTED_TOOLS.map((tool) => tool.name).sort(),
      )
    } finally {
      await client.close()
    }
  })

  it('emits title, existing description, explicit schemas, and the exact full annotation set for every tool', async () => {
    const client = await connectClient(new InMemoryRepository())
    try {
      const listed = await client.listTools()
      for (const expected of EXPECTED_TOOLS) {
        const tool = listed.tools.find((candidate) => candidate.name === expected.name)
        if (tool === undefined) {
          throw new Error(`registered tool ${expected.name} was not listed`)
        }
        expect(tool.title).toBe(expected.title)
        expect(tool.description).toBe(expected.description)
        // The full four-boolean annotation object must be present and exact:
        // true only where claimed, explicit false everywhere else.
        expect(tool.annotations).toEqual(expected.annotations)
        // Every tool advertises an explicit input schema object.
        expect(isSchemaObject(tool.inputSchema)).toBe(true)
        expect(tool.inputSchema.type).toBe('object')
        if (expected.inputRequired !== undefined) {
          expect(tool.inputSchema.required).toEqual(expected.inputRequired)
        }
        // Every tool advertises an explicit output schema object.
        expect(isSchemaObject(tool.outputSchema)).toBe(true)
        expect(tool.outputSchema?.type).toBe('object')
        expect(tool.outputSchema?.required).toEqual(expected.outputRequired)
      }
    } finally {
      await client.close()
    }
  })

  it('publishes artwork IDs and carries them through MCP calls without renaming food', async () => {
    const client = await connectClient(new InMemoryRepository())
    try {
      const listed = await client.listTools()
      const log = listed.tools.find((tool) => tool.name === 'log_meal')
      expect(log?.inputSchema.properties?.items).toMatchObject({ items: { properties: { artwork_id: { enum: ArtworkIdSchema.options } } } })
      const update = listed.tools.find((tool) => tool.name === 'update_meal_item')
      expect(update?.inputSchema.properties?.artwork_id).toMatchObject({ enum: ArtworkIdSchema.options })
      const name = '  Americano (black, no sugar, homemade)  '
      const logged = await client.callTool({ name: 'log_meal', arguments: {
        meal_type: 'breakfast', eaten_at: '2026-09-01T08:00:00Z', menu_name: 'Synthetic coffee set',
        items: [{ name, artwork_id: 'coffee', calories_kcal: 3 }],
      } })
      expect(logged.isError).not.toBe(true)
      const read = await client.callTool({ name: 'get_day', arguments: { date: '2026-09-01' } })
      const day = GetDayOutputSchema.parse(read.structuredContent)
      const item = day.meals[0]?.items[0]
      expect(item).toMatchObject({ name, artwork_id: 'coffee', calories_kcal: 3 })
      const corrected = await client.callTool({ name: 'update_meal_item', arguments: { item_id: item?.item_id, artwork_id: 'banana' } })
      expect(corrected.isError).not.toBe(true)
      const updated = await client.callTool({ name: 'get_day', arguments: { date: '2026-09-01' } })
      expect(GetDayOutputSchema.parse(updated.structuredContent).meals[0]?.items[0]).toMatchObject({ name, artwork_id: 'banana', calories_kcal: 3 })
      const menus = await client.callTool({ name: 'list_menus', arguments: {} })
      expect(ListMenusOutputSchema.parse(menus.structuredContent).menus[0]?.items[0]).toMatchObject({ name, artwork_id: 'coffee' })
      const invalid = await client.callTool({ name: 'log_meal', arguments: {
        meal_type: 'lunch', eaten_at: '2026-09-01T08:00:00Z', items: [{ name, artwork_id: 'invented' }],
      } })
      expect(invalid.isError).toBe(true)
      const after = await client.callTool({ name: 'get_day', arguments: { date: '2026-09-01' } })
      expect(GetDayOutputSchema.parse(after.structuredContent).meals).toHaveLength(1)
    } finally {
      await client.close()
    }
  }, 30_000)

  // Issue #284 — the normal agent path logs name-only items. The WRITE then
  // carries a validated identity resolved from the name, so rendering stops
  // depending on render-time name matching (and on the model remembering to
  // send an ID). Asserted through the real MCP surface: log_meal -> get_day.
  it('stores a validated artwork identity resolved from a name-only log (issue #284)', async () => {
    const client = await connectClient(new InMemoryRepository())
    try {
      const descriptive = 'Iced americano (black, no sugar)'
      const secondary = 'Satay skewers with peanut sauce'
      const unknown = 'Uncatalogued lunar stew'
      const explicit = '  Americano (black, no sugar, homemade)  '
      const logged = await client.callTool({ name: 'log_meal', arguments: {
        meal_type: 'breakfast', eaten_at: '2026-09-02T08:00:00Z',
        items: [
          { name: descriptive, calories_kcal: 3 },
          { name: secondary, calories_kcal: 120 },
          { name: unknown, calories_kcal: 200 },
          { name: explicit, artwork_id: 'banana', calories_kcal: 4 },
        ],
      } })
      expect(logged.isError).not.toBe(true)
      const read = await client.callTool({ name: 'get_day', arguments: { date: '2026-09-02' } })
      const items = GetDayOutputSchema.parse(read.structuredContent).meals[0]?.items ?? []
      expect(items[0]).toMatchObject({ name: descriptive, artwork_id: 'coffee' })
      expect(items[1]).toMatchObject({ name: secondary, artwork_id: 'satay' })
      // A name the published catalog cannot identify stays absent — never guessed.
      expect(items[2]?.name).toBe(unknown)
      expect(items[2]?.artwork_id).toBeUndefined()
      // An explicit published ID still wins, and the logged name is verbatim.
      expect(items[3]).toMatchObject({ name: explicit, artwork_id: 'banana' })
      for (const item of items) {
        if (item.artwork_id !== undefined) {
          expect(ArtworkIdSchema.options).toContain(item.artwork_id)
        }
      }
      // The named-menu path (issue #152) snapshots the same resolved identity
      // into both the meal and the menu template.
      const menuLog = await client.callTool({ name: 'log_meal', arguments: {
        meal_type: 'lunch', eaten_at: '2026-09-02T12:00:00Z', menu_name: 'Synthetic identity menu',
        items: [{ name: secondary, calories_kcal: 120 }, { name: unknown, calories_kcal: 10 }],
      } })
      expect(menuLog.isError).not.toBe(true)
      const menuRead = await client.callTool({ name: 'get_day', arguments: { date: '2026-09-02' } })
      const menuItems = GetDayOutputSchema.parse(menuRead.structuredContent).meals[1]?.items ?? []
      expect(menuItems[0]).toMatchObject({ name: secondary, artwork_id: 'satay' })
      expect(menuItems[1]?.artwork_id).toBeUndefined()
      const menus = await client.callTool({ name: 'list_menus', arguments: {} })
      const template = ListMenusOutputSchema.parse(menus.structuredContent).menus
        .find((menu) => menu.name === 'Synthetic identity menu')
      expect(template?.items[0]).toMatchObject({ name: secondary, artwork_id: 'satay' })
      expect(template?.items[1]?.artwork_id).toBeUndefined()
    } finally {
      await client.close()
    }
  }, 30_000)

  // Issue #294 part A — the agent-visible description must carry the explicit
  // instruction to set artwork_id, phrased as an instruction rather than as a
  // description of the field (asserted against the registered metadata).
  it('carries the explicit artwork_id instruction on the registered descriptions (issue #294)', async () => {
    const client = await connectClient(new InMemoryRepository())
    try {
      const listed = await client.listTools()
      const log = listed.tools.find((tool) => tool.name === 'log_meal')
      const update = listed.tools.find((tool) => tool.name === 'update_meal_item')
      expect(log?.description).toContain(ARTWORK_ID_INSTRUCTION)
      expect(log?.description).toMatch(/\bset artwork_id\b/i)
      expect(log?.description).toMatch(/never invent/i)
      expect(update?.description).toContain('set artwork_id')
      expect(update?.description).toMatch(/never invent/i)
    } finally {
      await client.close()
    }
  })

  // Issue #294 part B — the read-only staleness stamp. The values are asserted
  // against their canonical sources through the real MCP surface: the shipped
  // catalog.json, the enum the client holds in its own tool list, and the
  // server version the client records when it connects.
  it('serves the read-only contract stamp on get_day and it matches the enum the client holds (issue #294)', async () => {
    const client = await connectClient(new InMemoryRepository())
    try {
      const listed = await client.listTools()
      const day = await client.callTool({ name: 'get_day', arguments: { date: '2026-09-03' } })
      expect(day.isError).not.toBe(true)
      const parsed = GetDayOutputSchema.parse(day.structuredContent)
      const stamp = ContractVersionSchema.parse(parsed.contract)
      expect(stamp).toEqual(contractVersionStamp())
      expect(stamp.artwork_catalog_version).toBe(bundledCatalog.library_version)
      expect(stamp.published_identity_count).toBe(ArtworkIdSchema.options.length)
      expect(listedArtworkEnumSize(listed.tools.find((tool) => tool.name === 'log_meal')))
        .toBe(stamp.published_identity_count)
      expect(client.getServerVersion()?.version).toBe(stamp.contract_version)
      expect(MCP_CONTRACT_VERSION).toBe(stamp.contract_version)
      expect(listed.tools.find((tool) => tool.name === 'get_day')?.annotations?.readOnlyHint).toBe(true)
    } finally {
      await client.close()
    }
  })

  it('emits the metadata a local inspector receives (evidence dump)', async () => {
    const client = await connectClient(new InMemoryRepository())
    try {
      const listed = await client.listTools()
      expect(listed.tools).toHaveLength(EXPECTED_TOOLS.length)
      const rows = listed.tools.map((tool) => {
        const input = isSchemaObject(tool.inputSchema) ? tool.inputSchema : undefined
        const output = isSchemaObject(tool.outputSchema) ? tool.outputSchema : undefined
        return {
          name: tool.name,
          title: tool.title,
          description: tool.description,
          annotations: tool.annotations,
          inputRequired: input?.required,
          outputRequired: output?.required,
        }
      })
      console.log(`MCP_LIST_TOOLS_EVIDENCE ${JSON.stringify(rows)}`)
    } finally {
      await client.close()
    }
  })
})
