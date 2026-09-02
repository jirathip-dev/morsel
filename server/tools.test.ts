import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import type { ToolAnnotations } from '@modelcontextprotocol/sdk/types.js'
import { describe, expect, it } from 'vitest'
import { createMorselApp } from './app.js'
import type { Authenticate } from './auth.js'
import { InMemoryRepository } from './in-memory-repository.js'

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

const EXPECTED_TOOLS: ExpectedToolContract[] = [
  {
    name: 'log_meal',
    title: 'Log a meal',
    description: 'Record one meal and all of its food items. An image URL is stored as the current image_path value; the server does not upload media.',
    annotations: UNCLAIMED,
    inputRequired: ['meal_type', 'items'],
    outputRequired: ['meal_log_id', 'recorded'],
  },
  {
    name: 'get_day',
    title: 'Get a day of meals',
    description: 'Read meals, nutrition totals, and the effective goal for one calendar day.',
    annotations: READ_ONLY,
    inputRequired: ['date'],
    outputRequired: ['date', 'meals', 'totals', 'render'],
  },
  {
    name: 'search_food',
    title: 'Search the food catalog',
    description: 'Find catalog foods by name or barcode before estimating macros.',
    annotations: UNCLAIMED,
    inputRequired: ['query'],
    outputRequired: ['results'],
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
    outputRequired: ['ok', 'saved'],
  },
  {
    name: 'compute_targets',
    title: 'Compute nutrition targets',
    description: 'Compute BMR, TDEE, calories, and macros from the saved profile; uses the latest imported weight when available.',
    annotations: READ_ONLY,
    outputRequired: ['bmr_kcal', 'tdee_kcal', 'calorie_target_kcal', 'protein_g', 'carbs_g', 'fat_g'],
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
    name: 'update_meal_item',
    title: 'Update one meal item',
    description: 'Correct the name, quantity, or macros for one meal item owned by the caller. At least one field besides item_id is required.',
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
    outputRequired: ['series'],
  },
  {
    name: 'get_energy_burned',
    title: 'Get energy burned',
    description: 'Read daily active-energy burned measurements imported from Apple Health.',
    annotations: READ_ONLY,
    outputRequired: ['series'],
  },
  {
    name: 'get_dashboard_summary',
    title: 'Get the dashboard summary',
    description: 'Summarize average calories, streak, macros, and weight trend over the requested number of days.',
    annotations: READ_ONLY,
    outputRequired: ['avg_calories_kcal', 'streak_days', 'macro_split', 'weight_trend', 'render'],
  },
]

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isSchemaObject(value: unknown): value is { type?: string; required?: string[] } {
  return isRecord(value)
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
  it('registers exactly the 13 contract tools with unchanged names', async () => {
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
