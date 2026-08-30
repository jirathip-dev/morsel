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
  LogMealInputSchema,
  LogMealOutputSchema,
  SearchFoodInputSchema,
  SearchFoodOutputSchema,
  RenderPayloadSchema,
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

  server.registerTool('log_meal', {
    description: 'Record one meal and all of its food items. An image URL is stored as the current image_path value; the server does not upload media.',
    inputSchema: LogMealInputSchema,
    outputSchema: LogMealOutputSchema,
  }, (input) => runTool(() => service.logMeal(input)))

  server.registerTool('get_day', {
    description: 'Read meals, nutrition totals, and the effective goal for one calendar day.',
    inputSchema: GetDayInputSchema,
    outputSchema: GetDayOutputSchema,
  }, (input) => runTool(() => service.getDay(input)))

  server.registerTool('search_food', {
    description: 'Find catalog foods by name or barcode before estimating macros.',
    inputSchema: SearchFoodInputSchema,
    outputSchema: SearchFoodOutputSchema,
  }, (input) => runTool(() => service.searchFood(input)))

  server.registerTool('get_profile', {
    description: 'Read the body metrics used to compute nutrition targets.',
    inputSchema: EmptyInputSchema,
    outputSchema: GetProfileOutputSchema,
  }, (input) => runTool(() => service.getProfile(input)))

  server.registerTool('set_profile', {
    description: 'Create or replace the body metrics used to compute nutrition targets.',
    inputSchema: SetProfileInputSchema,
    outputSchema: SetProfileOutputSchema,
  }, (input) => runTool(() => service.setProfile(input)))

  server.registerTool('compute_targets', {
    description: 'Compute BMR, TDEE, calories, and macros from the saved profile.',
    inputSchema: EmptyInputSchema,
    outputSchema: ComputeTargetsOutputSchema,
  }, (input) => runTool(() => service.computeTargets(input)))

  server.registerTool('get_goals', {
    description: 'Read the effective computed or manually overridden nutrition goal.',
    inputSchema: EmptyInputSchema,
    outputSchema: GetGoalsOutputSchema,
  }, (input) => runTool(() => service.getGoals(input)))

  server.registerTool('set_goals', {
    description: 'Set one or more manual nutrition goal values; omitted values retain the effective target.',
    inputSchema: SetGoalsInputSchema,
    outputSchema: SetGoalsOutputSchema,
  }, (input) => runTool(() => service.setGoals(input)))

  server.registerTool('update_meal_item', {
    description: 'Correct the name, quantity, or macros for one meal item owned by the caller. At least one field besides item_id is required.',
    inputSchema: UpdateMealItemInputSchema,
    outputSchema: UpdateMealItemOutputSchema,
  }, (input) => runTool(() => service.updateMealItem(input)))

  server.registerTool('delete_meal_log', {
    description: 'Delete one meal log and its items owned by the caller.',
    inputSchema: DeleteMealLogInputSchema,
    outputSchema: DeleteMealLogOutputSchema,
  }, (input) => runTool(() => service.deleteMealLog(input)))

  server.registerTool('get_weight_trend', {
    description: 'Read imported body-mass measurements and the latest weight.',
    inputSchema: GetWeightTrendInputSchema,
    outputSchema: GetWeightTrendOutputSchema,
  }, (input) => runTool(() => service.getWeightTrend(input)))

  server.registerTool('get_dashboard_summary', {
    description: 'Summarize average calories, streak, macros, and weight trend over the requested number of days.',
    inputSchema: GetDashboardSummaryInputSchema,
    outputSchema: GetDashboardSummaryOutputSchema,
  }, (input) => runTool(() => service.getDashboardSummary(input)))

  return server
}
