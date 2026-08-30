// Canonical runtime schemas and types for the Morsel MCP tool contract.
// The server and the agent skill derive their shapes from this file. Update
// this file first when the contract changes.

import { z } from 'zod'

const finiteNumber = z.number()
const nonNegativeNumber = finiteNumber.nonnegative()
const positiveNumber = finiteNumber.positive()

export const IsoDateTimeSchema = z.iso.datetime({ offset: true })

export const CalendarDateSchema = z.string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, 'must use YYYY-MM-DD format')
  .refine((value) => {
    const parsed = new Date(`${value}T00:00:00.000Z`)
    return !Number.isNaN(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value
  }, 'must be a valid calendar date')

export const MealTypeSchema = z.enum(['breakfast', 'lunch', 'dinner', 'snack'])
export const SourceSchema = z.enum(['manual', 'photo_vision', 'barcode', 'import', 'voice'])
export const UnitSchema = z.enum(['g', 'ml', 'serving', 'piece', 'cup'])
export const ActivityLevelSchema = z.enum([
  'sedentary',
  'light',
  'moderate',
  'active',
  'very_active',
])
export const DietGoalSchema = z.enum(['lose', 'maintain', 'gain'])
export const SexSchema = z.enum(['male', 'female'])
export const FoodRefIdSchema = z.uuid()

export const MealItemSchema = z.object({
  name: z.string().trim().min(1),
  quantity: positiveNumber.optional().default(1),
  unit: UnitSchema.optional().default('serving'),
  calories_kcal: nonNegativeNumber.optional(),
  protein_g: nonNegativeNumber.optional(),
  carbs_g: nonNegativeNumber.optional(),
  fat_g: nonNegativeNumber.optional(),
  fiber_g: nonNegativeNumber.optional(),
  sugar_g: nonNegativeNumber.optional(),
  barcode: z.string().trim().min(1).optional(),
  food_ref_id: FoodRefIdSchema.optional(),
  confidence: finiteNumber.min(0).max(1).optional(),
  notes: z.string().trim().min(1).optional(),
}).strict()

export const LogMealInputSchema = z.object({
  eaten_at: IsoDateTimeSchema.optional(),
  meal_type: MealTypeSchema,
  items: z.array(MealItemSchema).min(1),
  notes: z.string().trim().min(1).optional(),
  image_url: z.string().trim().url().refine((value) => {
    try {
      return new URL(value).protocol === 'https:'
    } catch {
      return false
    }
  }, 'must use an https URL').optional(),
}).strict()

export const LogMealOutputSchema = z.object({
  meal_log_id: z.uuid(),
  recorded: z.boolean(),
}).strict()

export const SearchFoodInputSchema = z.object({
  query: z.string().trim().min(1),
  limit: z.number().int().positive().max(100).optional().default(8),
}).strict()

export const SearchFoodItemSchema = z.object({
  id: z.uuid(),
  name: z.string(),
  brand: z.string().optional(),
  barcode: z.string().optional(),
  serving_size: z.string().optional(),
  serving_unit: z.string().optional(),
  calories_kcal: finiteNumber.optional(),
  protein_g: finiteNumber.optional(),
  carbs_g: finiteNumber.optional(),
  fat_g: finiteNumber.optional(),
}).strict()

export const SearchFoodOutputSchema = z.object({
  results: z.array(SearchFoodItemSchema),
}).strict()

export const UpdateMealItemInputSchema = z.object({
  item_id: z.uuid(),
  name: z.string().trim().min(1).optional(),
  quantity: positiveNumber.optional(),
  calories_kcal: nonNegativeNumber.optional(),
  protein_g: nonNegativeNumber.optional(),
  carbs_g: nonNegativeNumber.optional(),
  fat_g: nonNegativeNumber.optional(),
}).strict().refine((value) => Object.keys(value).some((key) => key !== 'item_id'), {
  message: 'at least one meal item field must be provided',
})

export const UpdateMealItemOutputSchema = z.object({
  ok: z.literal(true),
  updated: z.literal(true),
}).strict()

export const DeleteMealLogInputSchema = z.object({
  meal_log_id: z.uuid(),
}).strict()

export const DeleteMealLogOutputSchema = z.object({
  ok: z.literal(true),
  deleted: z.literal(true),
}).strict()

export const MealItemRecordSchema = z.object({
  item_id: z.uuid(),
  name: z.string(),
  quantity: finiteNumber,
  unit: UnitSchema,
  calories_kcal: finiteNumber.optional(),
  protein_g: finiteNumber.optional(),
  carbs_g: finiteNumber.optional(),
  fat_g: finiteNumber.optional(),
  fiber_g: finiteNumber.optional(),
  sugar_g: finiteNumber.optional(),
  barcode: z.string().optional(),
  food_ref_id: FoodRefIdSchema.optional(),
  confidence: finiteNumber.optional(),
  notes: z.string().optional(),
}).strict()

export const MealRecordSchema = z.object({
  meal_log_id: z.uuid(),
  meal_type: MealTypeSchema,
  eaten_at: IsoDateTimeSchema,
  items: z.array(MealItemRecordSchema),
}).strict()

export const TotalsSchema = z.object({
  calories_kcal: finiteNumber,
  protein_g: finiteNumber,
  carbs_g: finiteNumber,
  fat_g: finiteNumber,
}).strict()

export const GoalSummarySchema = z.object({
  calorie_target_kcal: finiteNumber,
  protein_g: finiteNumber,
  carbs_g: finiteNumber,
  fat_g: finiteNumber,
  source: z.enum(['computed', 'manual']),
}).strict()

export const RenderPayloadSchema = z.object({
  markdown: z.string(),
  svg: z.string(),
}).strict()

export const GetDayInputSchema = z.object({
  date: CalendarDateSchema,
}).strict()

export const GetDayOutputSchema = z.object({
  date: CalendarDateSchema,
  meals: z.array(MealRecordSchema),
  totals: TotalsSchema,
  goal: GoalSummarySchema.optional(),
  remaining_kcal: finiteNumber.optional(),
  render: RenderPayloadSchema,
}).strict()

export const GetDashboardSummaryInputSchema = z.object({
  days: z.number().int().positive().max(366).optional().default(7),
}).strict()

export const WeightTrendPointSchema = z.object({
  date: CalendarDateSchema,
  kg: finiteNumber,
}).strict()

export const MacroSplitSchema = z.object({
  protein_g: finiteNumber,
  carbs_g: finiteNumber,
  fat_g: finiteNumber,
}).strict()

export const GetDashboardSummaryOutputSchema = z.object({
  avg_calories_kcal: finiteNumber,
  streak_days: z.number().int().nonnegative(),
  macro_split: MacroSplitSchema,
  weight_trend: z.array(WeightTrendPointSchema),
  render: RenderPayloadSchema,
}).strict()

export const GetWeightTrendInputSchema = z.object({
  days: z.number().int().positive().max(366).optional().default(30),
}).strict()

export const GetWeightTrendOutputSchema = z.object({
  series: z.array(WeightTrendPointSchema),
  latest: WeightTrendPointSchema.optional(),
}).strict()

export const EnergyBurnedPointSchema = z.object({
  date: CalendarDateSchema,
  active_kcal: nonNegativeNumber,
}).strict()

export const GetEnergyBurnedInputSchema = GetWeightTrendInputSchema
export const GetEnergyBurnedOutputSchema = z.object({
  series: z.array(EnergyBurnedPointSchema),
}).strict()

export const ProfileSchema = z.object({
  sex: SexSchema,
  age_years: z.number().int().min(10).max(100),
  height_cm: positiveNumber.min(100).max(250),
  weight_kg: positiveNumber.min(30).max(300),
  activity_level: ActivityLevelSchema,
  diet_goal: DietGoalSchema,
  goal_weight_kg: positiveNumber.optional(),
}).strict()

export const EmptyInputSchema = z.object({}).strict()

export const SetProfileInputSchema = ProfileSchema
export const GetProfileOutputSchema = ProfileSchema
export const SetProfileOutputSchema = z.object({
  ok: z.literal(true),
  saved: z.literal(true),
}).strict()

export const ComputeTargetsOutputSchema = z.object({
  bmr_kcal: nonNegativeNumber,
  tdee_kcal: nonNegativeNumber,
  calorie_target_kcal: nonNegativeNumber,
  protein_g: nonNegativeNumber,
  carbs_g: nonNegativeNumber,
  fat_g: nonNegativeNumber,
}).strict()

export const GetGoalsOutputSchema = GoalSummarySchema

export const SetGoalsInputSchema = z.object({
  calorie_target_kcal: nonNegativeNumber.optional(),
  protein_g: nonNegativeNumber.optional(),
  carbs_g: nonNegativeNumber.optional(),
  fat_g: nonNegativeNumber.optional(),
}).strict()

export const SetGoalsOutputSchema = z.object({
  ok: z.literal(true),
  source: z.literal('manual'),
}).strict()

export const LogWaterInputSchema = z.object({
  ml: positiveNumber,
  logged_at: IsoDateTimeSchema.optional(),
}).strict()

export const LogWeightInputSchema = z.object({
  kg: positiveNumber,
  logged_at: IsoDateTimeSchema.optional(),
}).strict()

export type EnergyBurnedPoint = z.infer<typeof EnergyBurnedPointSchema>
export type MealType = z.infer<typeof MealTypeSchema>
export type Source = z.infer<typeof SourceSchema>
export type Unit = z.infer<typeof UnitSchema>
export type ActivityLevel = z.infer<typeof ActivityLevelSchema>
export type DietGoal = z.infer<typeof DietGoalSchema>
export type Sex = z.infer<typeof SexSchema>

export type MealItem = z.input<typeof MealItemSchema>
export type ParsedMealItem = z.output<typeof MealItemSchema>
export type LogMealInput = z.input<typeof LogMealInputSchema>
export type ParsedLogMealInput = z.output<typeof LogMealInputSchema>
export type LogMealOutput = z.infer<typeof LogMealOutputSchema>
export type SearchFoodInput = z.input<typeof SearchFoodInputSchema>
export type ParsedSearchFoodInput = z.output<typeof SearchFoodInputSchema>
export type SearchFoodItem = z.infer<typeof SearchFoodItemSchema>
export type SearchFoodOutput = z.infer<typeof SearchFoodOutputSchema>
export type UpdateMealItemInput = z.input<typeof UpdateMealItemInputSchema>
export type ParsedUpdateMealItemInput = z.output<typeof UpdateMealItemInputSchema>
export type UpdateMealItemOutput = z.infer<typeof UpdateMealItemOutputSchema>
export type DeleteMealLogInput = z.infer<typeof DeleteMealLogInputSchema>
export type DeleteMealLogOutput = z.infer<typeof DeleteMealLogOutputSchema>
export type MealItemRecord = z.infer<typeof MealItemRecordSchema>
export type MealRecord = z.infer<typeof MealRecordSchema>
export type Totals = z.infer<typeof TotalsSchema>
export type GoalSummary = z.infer<typeof GoalSummarySchema>
export type RenderPayload = z.infer<typeof RenderPayloadSchema>
export type GetDayInput = z.infer<typeof GetDayInputSchema>
export type GetDayOutput = z.infer<typeof GetDayOutputSchema>
export type GetDashboardSummaryInput = z.input<typeof GetDashboardSummaryInputSchema>
export type ParsedGetDashboardSummaryInput = z.output<typeof GetDashboardSummaryInputSchema>
export type WeightTrendPoint = z.infer<typeof WeightTrendPointSchema>
export type MacroSplit = z.infer<typeof MacroSplitSchema>
export type GetDashboardSummaryOutput = z.infer<typeof GetDashboardSummaryOutputSchema>
export type GetWeightTrendInput = z.input<typeof GetWeightTrendInputSchema>
export type ParsedGetWeightTrendInput = z.output<typeof GetWeightTrendInputSchema>
export type GetWeightTrendOutput = z.infer<typeof GetWeightTrendOutputSchema>
export type Profile = z.infer<typeof ProfileSchema>
export type SetProfileInput = z.infer<typeof SetProfileInputSchema>
export type GetProfileOutput = z.infer<typeof GetProfileOutputSchema>
export type SetProfileOutput = z.infer<typeof SetProfileOutputSchema>
export type ComputeTargetsOutput = z.infer<typeof ComputeTargetsOutputSchema>
export type Targets = ComputeTargetsOutput & { source: z.infer<typeof GoalSummarySchema>['source'] }
export type GetGoalsOutput = z.infer<typeof GetGoalsOutputSchema>
export type SetGoalsInput = z.infer<typeof SetGoalsInputSchema>
export type SetGoalsOutput = z.infer<typeof SetGoalsOutputSchema>
export type LogWaterInput = z.infer<typeof LogWaterInputSchema>
export type LogWeightInput = z.infer<typeof LogWeightInputSchema>
