import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'
import {
  ComputeTargetsOutputSchema,
  DeleteMealLogInputSchema,
  DeleteMealLogOutputSchema,
  EmptyInputSchema,
  GetDashboardSummaryInputSchema,
  GetDashboardSummaryOutputSchema,
  GetDayInputSchema,
  GetDayOutputSchema,
  GetGoalsOutputSchema,
  GetProfileOutputSchema,
  GetWeightTrendInputSchema,
  GetWeightTrendOutputSchema,
  GetEnergyBurnedInputSchema,
  GetEnergyBurnedOutputSchema,
  LogMealInputSchema,
  LogMealOutputSchema,
  SearchFoodInputSchema,
  SearchFoodOutputSchema,
  RenderPayloadSchema,
  ResetGoalsInputSchema,
  ResetGoalsOutputSchema,
  SetGoalsInputSchema,
  SetGoalsOutputSchema,
  SetProfileInputSchema,
  SetProfileOutputSchema,
  UpdateMealItemInputSchema,
  UpdateMealItemOutputSchema,
} from '../packages/schema/food-types.ts'
import { MorselError } from './errors.ts'
import type { MorselService } from './service.ts'

type ToolContent =
  | { type: 'text'; text: string }
  | { type: 'image'; data: string; mimeType: 'image/svg+xml' }

function encodeBase64(value: string): string {
  const bytes = new TextEncoder().encode(value)
  let binary = ''
  for (const byte of bytes) {
    binary += String.fromCharCode(byte)
  }
  return btoa(binary)
}

function success(output: Record<string, unknown>): {
  structuredContent: Record<string, unknown>
  content: ToolContent[]
} {
  const render = RenderPayloadSchema.safeParse(output.render)
  return {
    structuredContent: output,
    content: render.success
      ? [
          { type: 'text', text: render.data.markdown },
          { type: 'image', data: encodeBase64(render.data.svg), mimeType: 'image/svg+xml' },
        ]
      : [{ type: 'text', text: JSON.stringify(output) }],
  }
}

function failure(error: unknown): {
  isError: true
  content: Array<{ type: 'text'; text: string }>
} {
  const morselError = error instanceof MorselError
    ? error
    : new MorselError('internal_error', 'request failed')
  return {
    isError: true,
    content: [{ type: 'text', text: `${morselError.code}: ${morselError.publicMessage}` }],
  }
}

async function runTool<T extends Record<string, unknown>>(
  action: () => Promise<T>,
): Promise<ReturnType<typeof success> | ReturnType<typeof failure>> {
  try {
    return success(await action())
  } catch (error) {
    return failure(error)
  }
}

export function createMcpServer(service: MorselService): McpServer {
  const server = new McpServer(
    { name: 'morsel', version: '0.1.0' },
    {
      instructions: 'Morsel stores structured food logs. Use search_food for known foods, then log one meal with one or more items.',
    },
  )

  // Every registered tool advertises the full SDK annotation set as explicit
  // booleans so the emitted tools/list contract is unambiguous: clients never
  // have to infer meaning from an absent field. `true` is claimed only where
  // the implementation provably qualifies (see docs/MCP_TOOLS.md).
  const READ_ONLY_ANNOTATIONS = {
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: false,
    openWorldHint: false,
  }
  const DESTRUCTIVE_ANNOTATIONS = {
    readOnlyHint: false,
    destructiveHint: true,
    idempotentHint: false,
    openWorldHint: false,
  }
  const UNCLAIMED_ANNOTATIONS = {
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: false,
    openWorldHint: false,
  }
  // search_food is the only open-world tool: its configured catalog-miss path
  // calls the live USDA FoodData Central web-search API (SDK openWorldHint
  // semantics: the domain of a web search tool is open), and it may persist
  // matched rows into the shared catalog, so it also claims no read-only hint.
  const OPEN_WORLD_SEARCH_ANNOTATIONS = {
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: false,
    openWorldHint: true,
  }

  // OpenAI/ChatGPT per-tool OAuth metadata (issue #96): every Morsel tool is
  // protected by the server's SINGLE OAuth contract, so each tool declares
  // the same oauth2 scheme with the scope the existing authorization-server
  // and protected-resource metadata advertise (scopes_supported: ['mcp']) —
  // no second issuer or credential system. The array rides in tool `_meta`
  // because the installed MCP SDK (1.30.0) emits tool-level `_meta` in
  // tools/list but silently drops unknown top-level config keys such as a
  // first-class `securitySchemes` (OpenAI SEP-1488 draft, unshipped).
  const OAUTH2_SECURITY_SCHEMES: Array<{ type: 'oauth2'; scopes: string[] }> = [
    { type: 'oauth2', scopes: ['mcp'] },
  ]

  server.registerTool('log_meal', {
    title: 'Log a meal',
    description: 'Record one meal and all of its food items. An image URL is stored as the current image_path value; the server does not upload media.',
    inputSchema: LogMealInputSchema,
    outputSchema: LogMealOutputSchema,
    annotations: UNCLAIMED_ANNOTATIONS,
    _meta: { securitySchemes: OAUTH2_SECURITY_SCHEMES },
  }, (input) => runTool(() => service.logMeal(input)))

  server.registerTool('get_day', {
    title: 'Get a day of meals',
    description: 'Read meals, nutrition totals, and the effective goal for one calendar day.',
    inputSchema: GetDayInputSchema,
    outputSchema: GetDayOutputSchema,
    annotations: READ_ONLY_ANNOTATIONS,
    _meta: { securitySchemes: OAUTH2_SECURITY_SCHEMES },
  }, (input) => runTool(() => service.getDay(input)))

  server.registerTool('search_food', {
    title: 'Search the food catalog',
    description: 'Find catalog foods by name or barcode before estimating macros.',
    inputSchema: SearchFoodInputSchema,
    outputSchema: SearchFoodOutputSchema,
    annotations: OPEN_WORLD_SEARCH_ANNOTATIONS,
    _meta: { securitySchemes: OAUTH2_SECURITY_SCHEMES },
  }, (input) => runTool(() => service.searchFood(input)))

  server.registerTool('get_profile', {
    title: 'Get the body profile',
    description: 'Read the body metrics used to compute nutrition targets.',
    inputSchema: EmptyInputSchema,
    outputSchema: GetProfileOutputSchema,
    annotations: READ_ONLY_ANNOTATIONS,
    _meta: { securitySchemes: OAUTH2_SECURITY_SCHEMES },
  }, (input) => runTool(() => service.getProfile(input)))

  server.registerTool('set_profile', {
    title: 'Set the body profile',
    description: 'Create or replace the body metrics used to compute nutrition targets.',
    inputSchema: SetProfileInputSchema,
    outputSchema: SetProfileOutputSchema,
    annotations: UNCLAIMED_ANNOTATIONS,
    _meta: { securitySchemes: OAUTH2_SECURITY_SCHEMES },
  }, (input) => runTool(() => service.setProfile(input)))

  server.registerTool('compute_targets', {
    title: 'Compute nutrition targets',
    description: 'Compute BMR, TDEE, calories, and macros from the saved profile; uses the latest imported weight when available.',
    inputSchema: EmptyInputSchema,
    outputSchema: ComputeTargetsOutputSchema,
    annotations: READ_ONLY_ANNOTATIONS,
    _meta: { securitySchemes: OAUTH2_SECURITY_SCHEMES },
  }, (input) => runTool(() => service.computeTargets(input)))

  server.registerTool('get_goals', {
    title: 'Get the effective goal',
    description: 'Read the effective computed or manually overridden nutrition goal.',
    inputSchema: EmptyInputSchema,
    outputSchema: GetGoalsOutputSchema,
    annotations: READ_ONLY_ANNOTATIONS,
    _meta: { securitySchemes: OAUTH2_SECURITY_SCHEMES },
  }, (input) => runTool(() => service.getGoals(input)))

  server.registerTool('set_goals', {
    title: 'Set manual goals',
    description: 'Set one or more manual nutrition goal values; omitted values retain the effective target.',
    inputSchema: SetGoalsInputSchema,
    outputSchema: SetGoalsOutputSchema,
    annotations: UNCLAIMED_ANNOTATIONS,
    _meta: { securitySchemes: OAUTH2_SECURITY_SCHEMES },
  }, (input) => runTool(() => service.setGoals(input)))

  server.registerTool('reset_goals', {
    title: 'Reset manual goals',
    description: 'Discard the stored manual goal override so the effective target returns to the computed values from the profile.',
    inputSchema: ResetGoalsInputSchema,
    outputSchema: ResetGoalsOutputSchema,
    annotations: UNCLAIMED_ANNOTATIONS,
    _meta: { securitySchemes: OAUTH2_SECURITY_SCHEMES },
  }, (input) => runTool(() => service.resetGoals(input)))

  server.registerTool('update_meal_item', {
    title: 'Update one meal item',
    description: 'Correct the name, quantity, or macros for one meal item owned by the caller. At least one field besides item_id is required.',
    inputSchema: UpdateMealItemInputSchema,
    outputSchema: UpdateMealItemOutputSchema,
    annotations: UNCLAIMED_ANNOTATIONS,
    _meta: { securitySchemes: OAUTH2_SECURITY_SCHEMES },
  }, (input) => runTool(() => service.updateMealItem(input)))

  server.registerTool('delete_meal_log', {
    title: 'Delete a meal log',
    description: 'Delete one meal log and its items owned by the caller.',
    inputSchema: DeleteMealLogInputSchema,
    outputSchema: DeleteMealLogOutputSchema,
    annotations: DESTRUCTIVE_ANNOTATIONS,
    _meta: { securitySchemes: OAUTH2_SECURITY_SCHEMES },
  }, (input) => runTool(() => service.deleteMealLog(input)))

  server.registerTool('get_weight_trend', {
    title: 'Get the weight trend',
    description: 'Read imported body-mass measurements and the latest weight.',
    inputSchema: GetWeightTrendInputSchema,
    outputSchema: GetWeightTrendOutputSchema,
    annotations: READ_ONLY_ANNOTATIONS,
    _meta: { securitySchemes: OAUTH2_SECURITY_SCHEMES },
  }, (input) => runTool(() => service.getWeightTrend(input)))

  server.registerTool('get_energy_burned', {
    title: 'Get energy burned',
    description: 'Read daily active-energy burned measurements imported from Apple Health.',
    inputSchema: GetEnergyBurnedInputSchema,
    outputSchema: GetEnergyBurnedOutputSchema,
    annotations: READ_ONLY_ANNOTATIONS,
    _meta: { securitySchemes: OAUTH2_SECURITY_SCHEMES },
  }, (input) => runTool(() => service.getEnergyBurned(input)))

  server.registerTool('get_dashboard_summary', {
    title: 'Get the dashboard summary',
    description: 'Summarize average calories, streak, macros, and weight trend over the requested number of days.',
    inputSchema: GetDashboardSummaryInputSchema,
    outputSchema: GetDashboardSummaryOutputSchema,
    annotations: READ_ONLY_ANNOTATIONS,
    _meta: { securitySchemes: OAUTH2_SECURITY_SCHEMES },
  }, (input) => runTool(() => service.getDashboardSummary(input)))

  return server
}
