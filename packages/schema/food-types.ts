// Canonical runtime schemas and types for the Morsel MCP tool contract.
// The server and the agent skill derive their shapes from this file. Update
// this file first when the contract changes.

import { z } from 'zod'
import { ArtworkCatalogVersion, ArtworkIdValues } from './artwork-ids.ts'

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

// IANA timezone name (e.g. "Asia/Bangkok", "America/New_York", "Etc/GMT+7").
// 'UTC' is the canonical default: when neither the tool input nor the stored
// profile carries a timezone, day-scoped tools bucket days as UTC exactly like
// v0.1 (backward compatible).
export const TimezoneSchema = z.string()
  .trim()
  .min(1)
  .refine((value) => {
    try {
      new Intl.DateTimeFormat('en-US', { timeZone: value })
      return true
    } catch {
      return false
    }
  }, 'must be an IANA timezone name')

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

// Explicit identity is an exact published ID, never a name or inferred nutrition.
// Reject unknown IDs (including case/whitespace variants) before any write.
export const ArtworkIdSchema = z.enum(ArtworkIdValues).describe(
  'Optional published illustration ID; select only an enum value, never invent one. Keep name verbatim. Omit when uncertain.',
)

// Issue #294 — the MCP tool contract revision. This constant is the single
// canonical source: the server advertises it as its MCP server version (the
// version a client records when the session connects) and serves it in the
// read-only `contract` stamp, so a client that holds a stale tools/list can
// compare the two and say so. Bump it whenever the agent-visible tool contract
// changes (tools, schemas, descriptions).
export const MCP_CONTRACT_VERSION = '0.2.0'

// Issue #294 — the canonical agent-visible instruction that the `log_meal` and
// `update_meal_item` descriptions carry. The server registers these strings
// verbatim; the agent skill and docs/MCP_TOOLS.md restate them for humans. It
// is phrased as an instruction, never as a description of a field.
export const ARTWORK_ID_INSTRUCTION = "When an item matches a published artwork identity, set artwork_id to that exact published ID from this tool's artwork_id enum — allowed IDs are the enum and the shipped catalog is the canonical set. Omit artwork_id only when genuinely uncertain; never invent an ID and never upload illustration files."

export const LOG_MEAL_DESCRIPTION = `Record one meal and all of its food items. Send the photo bytes with image_base64 when the client exposes the image; the server stores the photo and returns it on reads (image_error reports a photo that could not be stored). An omitted item artwork_id is resolved from the item name to a published identity; nothing is invented. ${ARTWORK_ID_INSTRUCTION}`

export const UPDATE_MEAL_ITEM_DESCRIPTION = `Correct the name, quantity, or macros for one meal item owned by the caller. At least one field besides item_id is required. When replacing an item's illustration identity, set artwork_id to that exact published ID from this tool's artwork_id enum; omitting artwork_id preserves the stored identity. Never invent an ID and never upload illustration files.`

const FoodNameSchema = z.string().min(1).refine((value) => value.trim().length > 0, 'name must not be blank')

// Accepted food-photo mime types. This set mirrors the `food-images` bucket
// allowlist (migration 0004) and the native app's FoodImageStore allowlist —
// the server stores bytes, so it can only accept what storage accepts.
export const MealImageMimeTypeValues = ['image/jpeg', 'image/png', 'image/webp'] as const
export const MealImageMimeTypeSchema = z.enum(MealImageMimeTypeValues)
export type MealImageMimeType = z.infer<typeof MealImageMimeTypeSchema>

// A food-photo payload sent through MCP as base64 text. The server stores the
// decoded bytes in the account's private `food-images` bucket, so the accepted
// mime set mirrors the bucket's allowed_mime_types (migration 0004) and the
// native app's FoodImageStore allowlist. JPEG is the canonical interchange
// format (the app re-encodes camera HEIC to JPEG before upload); PNG and WebP
// are stored byte-exact. The 7,000,000-character cap is a JSON-payload memory
// bound: the decoded byte budget (~5 MB) is enforced by the server after
// decode so an oversized photo reports image_error while the meal still logs.
export const MealImageBase64Schema = z.object({
  data: z.string().min(1).max(7_000_000),
  mime_type: MealImageMimeTypeSchema,
}).strict()

export const MealItemSchema = z.object({
  name: FoodNameSchema,
  artwork_id: ArtworkIdSchema.optional(),
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
  // Optional IANA zone for the response's local date when eaten_at is
  // omitted. Precedence: explicit input -> profiles.timezone -> UTC.
  timezone: TimezoneSchema.optional(),
  meal_type: MealTypeSchema,
  // Named-menu log (issue #152): when present the meal is logged as one
  // grouped set under this menu name (each item row snapshots the name plus
  // a fresh set/grouping id). When the user has no menu with that name the
  // menu is created from this log's items; an existing menu is never
  // modified by a log (copy semantics). items may be omitted only when the
  // menu already exists — the log then copies the menu's current items.
  menu_name: z.string().trim().min(1).optional(),
  // Required for plain logs (unchanged behavior); optional only when a
  // menu_name is given and that menu already exists (the log then reuses
  // the menu's stored items as its snapshot).
  items: z.array(MealItemSchema).min(1).optional(),
  notes: z.string().trim().min(1).optional(),
  // Preferred photo input: the real bytes, base64-encoded. When both photo
  // inputs are present image_base64 wins and image_url is ignored.
  image_base64: MealImageBase64Schema.optional(),
  // Legacy photo input: the server fetches the HTTPS URL once, validates the
  // bytes, and stores them like an image_base64 upload.
  image_url: z.string().trim().url().refine((value) => {
    try {
      return new URL(value).protocol === 'https:'
    } catch {
      return false
    }
  }, 'must use an https URL').optional(),
}).strict().refine((value) => value.items !== undefined || value.menu_name !== undefined, {
  message: 'provide items, or a menu_name of a menu that already exists',
})

export const LogMealOutputSchema = z.object({
  meal_log_id: z.uuid(),
  recorded: z.boolean(),
  // Present only when eaten_at was omitted: the server stamped now and
  // reports the local calendar date (and the timezone it used) so the agent
  // can echo the local day the meal was logged to.
  timezone: TimezoneSchema.optional(),
  date: CalendarDateSchema.optional(),
  // Present only when a photo was requested but could not be stored: the
  // meal is still logged (REJECT AND REPORT, never silently drop).
  image_error: z.string().optional(),
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
  name: FoodNameSchema.optional(),
  artwork_id: ArtworkIdSchema.optional(),
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

export const AttachMealImageInputSchema = z.object({
  meal_log_id: z.uuid(),
  // Preferred photo input: the real bytes (see LogMealInputSchema).
  image_base64: MealImageBase64Schema.optional(),
  // Legacy photo input: fetched once and stored like an image_base64 upload.
  image_url: z.string().trim().url().refine((value) => {
    try {
      return new URL(value).protocol === 'https:'
    } catch {
      return false
    }
  }, 'must use an https URL').optional(),
}).strict().refine((value) => value.image_base64 !== undefined || value.image_url !== undefined, {
  message: 'provide image_base64 or image_url',
})

export const AttachMealImageOutputSchema = z.object({
  ok: z.literal(true),
  attached: z.boolean(),
  // Present only when the photo could not be stored: the meal log is
  // unchanged and the caller can retry or report (never a silent accept).
  image_error: z.string().optional(),
}).strict()

export const MealItemRecordSchema = z.object({
  item_id: z.uuid(),
  name: z.string(),
  artwork_id: ArtworkIdSchema.optional(),
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
  // Named-menu snapshot grouping (issue #152): set items carry the menu
  // name copy and a shared group id per logged set instance; loose items
  // omit both. These are snapshots — never a live reference to a menu.
  menu_name: z.string().optional(),
  menu_group_id: z.uuid().optional(),
}).strict()

// One stored menu template item (menu_items row, issue #152).
export const MenuTemplateItemSchema = z.object({
  item_id: z.uuid(),
  name: z.string(),
  artwork_id: ArtworkIdSchema.optional(),
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
}).strict()

// A reusable named menu as returned by list_menus: template name + items
// (meal-type-free: it can be logged under any meal section).
export const MenuTemplateSchema = z.object({
  menu_id: z.uuid(),
  name: z.string(),
  items: z.array(MenuTemplateItemSchema).min(1),
}).strict()

export const ListMenusOutputSchema = z.object({
  menus: z.array(MenuTemplateSchema),
}).strict()

// A stored food photo as returned on reads. `path` is the bucket object path
// (`{user_id}/{meal_log_id}.jpg`) that the app's thumbnail pipeline downloads;
// `signed_url` is a short-lived URL minted per read and `expires_at` is the
// instant it stops working. Absent (key omitted) when the meal has no photo.
export const MealImageRecordSchema = z.object({
  path: z.string().min(1),
  signed_url: z.string().url(),
  expires_at: IsoDateTimeSchema,
}).strict()

// One entry of a day/dashboard read's COMPLETENESS, so a consumer can tell
// "nothing logged" from "read incomplete" (issue #258). `incomplete` means at
// least one item row of that meal (or of the read's window, for the summary)
// could not be read — the read degrades instead of aborting and never reports
// an unreadable day as `meals: []`. Absent keys on records whose item read
// completed keep older consumers and producers valid.
export const ItemsReadStateSchema = z.enum(['complete', 'incomplete'])

export const MealRecordSchema = z.object({
  meal_log_id: z.uuid(),
  meal_type: MealTypeSchema,
  eaten_at: IsoDateTimeSchema,
  items: z.array(MealItemRecordSchema),
  items_read: ItemsReadStateSchema.optional(),
  image: MealImageRecordSchema.optional(),
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

// A stored complete manual goal that a newer profile superseded: the old
// values ride along so clients can show what was replaced and when it was set.
export const SupersededManualSchema = z.object({
  calorie_target_kcal: nonNegativeNumber,
  protein_g: nonNegativeNumber,
  carbs_g: nonNegativeNumber,
  fat_g: nonNegativeNumber,
  updated_at: IsoDateTimeSchema,
}).strict()

// The effective goal ("latest update wins"): manual values apply only when the
// manual row is at least as new as the profile; otherwise the computed target
// is effective and the stale manual values are reported as superseded_manual.
export const EffectiveGoalSchema = GoalSummarySchema.extend({
  superseded_manual: SupersededManualSchema.optional(),
}).strict()

export const RenderPayloadSchema = z.object({
  markdown: z.string(),
  svg: z.string(),
}).strict()

export const GetDayInputSchema = z.object({
  date: CalendarDateSchema,
  // Optional IANA zone: the requested date is that zone's calendar day.
  // Precedence: explicit input -> profiles.timezone -> UTC.
  timezone: TimezoneSchema.optional(),
}).strict()

// Issue #253: observations are prospective, never current-goal backfills.
export const DatedBaselineSchema = z.object({
  revision_id: z.uuid(),
  recorded_at: IsoDateTimeSchema,
  effective_date: CalendarDateSchema,
  timezone: TimezoneSchema,
  source_version: z.literal('targets-v1'),
  goal: GoalSummarySchema,
  profile_updated_at: IsoDateTimeSchema.optional(),
  goals_updated_at: IsoDateTimeSchema.optional(),
  weight_measured_at: IsoDateTimeSchema.optional(),
}).strict()

export const DatedAdditionRevisionSchema = z.object({
  revision_id: z.uuid(),
  recorded_at: IsoDateTimeSchema,
  timezone: TimezoneSchema,
  previous_revision_id: z.uuid().optional(),
  historical_confirmation: z.boolean(),
  manual_goal_acknowledged: z.boolean(),
}).strict()

export const DatedTargetSchema = z.object({
  date: CalendarDateSchema,
  timezone: TimezoneSchema,
  baseline: DatedBaselineSchema.optional(),
  confirmed_addition_kcal: nonNegativeNumber,
  addition_revision: DatedAdditionRevisionSchema.optional(),
  total_target_kcal: nonNegativeNumber.optional(),
}).strict()

export const SetDatedTargetAdditionInputSchema = z.object({
  date: CalendarDateSchema,
  timezone: TimezoneSchema.optional(),
  addition_kcal: nonNegativeNumber.describe('User-confirmed addition only; zero removes it. Never infer an amount from exercise.'),
  mutation_id: z.uuid().describe('New UUID for this confirmed change; reuse only when retrying this exact change.'),
  expected_revision: z.uuid().optional().describe('Current addition revision from get_day; omit only if none exists.'),
  historical_confirmation: z.boolean().optional().default(false),
  manual_goal_acknowledged: z.boolean().optional().default(false),
}).strict()
export const SetDatedTargetAdditionOutputSchema = z.object({ dated_target: DatedTargetSchema }).strict()
export type DatedTarget = z.infer<typeof DatedTargetSchema>
export type SetDatedTargetAdditionInput = z.output<typeof SetDatedTargetAdditionInputSchema>
export type SetDatedTargetAdditionOutput = z.infer<typeof SetDatedTargetAdditionOutputSchema>

// Issue #294 — the read-only staleness stamp. A client holding an older
// tools/list compares `published_identity_count` with the size of the
// `artwork_id` enum it holds, and `contract_version` with the MCP server
// version it recorded at connect; both values are derived from their canonical
// source (the shipped catalog's generated snapshot, the published identity
// union) — never hand-typed literals that can drift.
export const ContractVersionSchema = z.object({
  contract_version: z.string().min(1),
  artwork_catalog_version: z.string().min(1),
  published_identity_count: z.number().int().positive(),
}).strict()

export type ContractVersion = z.infer<typeof ContractVersionSchema>

export function contractVersionStamp(): ContractVersion {
  return {
    contract_version: MCP_CONTRACT_VERSION,
    artwork_catalog_version: ArtworkCatalogVersion,
    published_identity_count: ArtworkIdValues.length,
  }
}

export const GetDayOutputSchema = z.object({
  date: CalendarDateSchema,
  timezone: TimezoneSchema,
  contract: ContractVersionSchema,
  meals: z.array(MealRecordSchema),
  totals: TotalsSchema,
  goal: GoalSummarySchema.optional(),
  remaining_kcal: finiteNumber.optional(),
  dated_target: DatedTargetSchema.optional(),
  render: RenderPayloadSchema,
}).strict()

export const GetDashboardSummaryInputSchema = z.object({
  days: z.number().int().positive().max(366).optional().default(7),
  // Optional IANA zone: window days, streak, and "today" are that zone's
  // local days. Precedence: explicit input -> profiles.timezone -> UTC.
  timezone: TimezoneSchema.optional(),
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
  date: CalendarDateSchema,
  timezone: TimezoneSchema,
  avg_calories_kcal: finiteNumber,
  streak_days: z.number().int().nonnegative(),
  macro_split: MacroSplitSchema,
  weight_trend: z.array(WeightTrendPointSchema),
  dated_targets: z.array(DatedTargetSchema).optional(),
  // Issue #258 — the window's item rows degraded: at least one meal could not
  // be read, so the aggregates above undercount. Omitted when complete.
  items_read: ItemsReadStateSchema.optional(),
  render: RenderPayloadSchema,
}).strict()

export const GetWeightTrendInputSchema = z.object({
  days: z.number().int().positive().max(366).optional().default(30),
  // Optional IANA zone: the series day labels and the "today" anchor are
  // that zone's local days. Precedence: explicit input -> profiles.timezone
  // -> UTC.
  timezone: TimezoneSchema.optional(),
}).strict()

export const GetWeightTrendOutputSchema = z.object({
  date: CalendarDateSchema,
  timezone: TimezoneSchema,
  series: z.array(WeightTrendPointSchema),
  latest: WeightTrendPointSchema.optional(),
}).strict()

export const EnergyBurnedPointSchema = z.object({
  date: CalendarDateSchema,
  active_kcal: positiveNumber,
}).strict()

export const GetEnergyBurnedInputSchema = GetWeightTrendInputSchema
export const GetEnergyBurnedOutputSchema = z.object({
  date: CalendarDateSchema,
  timezone: TimezoneSchema,
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
  // Stored IANA zone used for day bucketing when a day-scoped tool call does
  // not pass an explicit timezone. Absent = UTC (backward compatible).
  timezone: TimezoneSchema.optional(),
}).strict()

export const EmptyInputSchema = z.object({}).strict()

export const ListMenusInputSchema = EmptyInputSchema

export const SetProfileInputSchema = ProfileSchema
export const GetProfileOutputSchema = ProfileSchema
export const SetProfileOutputSchema = z.object({
  ok: z.literal(true),
  saved: z.literal(true),
  effective_goal: EffectiveGoalSchema,
}).strict()

// The weight the computed targets were actually derived from: the latest
// imported measurement when one exists (source "health", with its sample
// time), otherwise the typed profile value (source "profile").
export const WeightUsedSchema = z.object({
  kg: positiveNumber,
  measured_at: IsoDateTimeSchema.optional(),
  source: z.enum(['health', 'profile']),
}).strict()

export const ComputeTargetsOutputSchema = z.object({
  bmr_kcal: nonNegativeNumber,
  tdee_kcal: nonNegativeNumber,
  calorie_target_kcal: nonNegativeNumber,
  protein_g: nonNegativeNumber,
  carbs_g: nonNegativeNumber,
  fat_g: nonNegativeNumber,
  weight_used: WeightUsedSchema,
}).strict()

export const GetGoalsOutputSchema = EffectiveGoalSchema

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

export const ResetGoalsInputSchema = EmptyInputSchema
export const ResetGoalsOutputSchema = z.object({
  ok: z.literal(true),
  reset: z.literal(true),
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
export type MenuTemplateItem = z.infer<typeof MenuTemplateItemSchema>
export type MenuTemplate = z.infer<typeof MenuTemplateSchema>
export type ListMenusOutput = z.infer<typeof ListMenusOutputSchema>
export type SearchFoodInput = z.input<typeof SearchFoodInputSchema>
export type ParsedSearchFoodInput = z.output<typeof SearchFoodInputSchema>
export type SearchFoodItem = z.infer<typeof SearchFoodItemSchema>
export type SearchFoodOutput = z.infer<typeof SearchFoodOutputSchema>
export type UpdateMealItemInput = z.input<typeof UpdateMealItemInputSchema>
export type ParsedUpdateMealItemInput = z.output<typeof UpdateMealItemInputSchema>
export type UpdateMealItemOutput = z.infer<typeof UpdateMealItemOutputSchema>
export type DeleteMealLogInput = z.infer<typeof DeleteMealLogInputSchema>
export type DeleteMealLogOutput = z.infer<typeof DeleteMealLogOutputSchema>
export type AttachMealImageInput = z.infer<typeof AttachMealImageInputSchema>
export type AttachMealImageOutput = z.infer<typeof AttachMealImageOutputSchema>
export type MealImageRecord = z.infer<typeof MealImageRecordSchema>
export type MealItemRecord = z.infer<typeof MealItemRecordSchema>
export type ItemsReadState = z.infer<typeof ItemsReadStateSchema>
export type MealRecord = z.infer<typeof MealRecordSchema>
export type Totals = z.infer<typeof TotalsSchema>
export type GoalSummary = z.infer<typeof GoalSummarySchema>
export type SupersededManual = z.infer<typeof SupersededManualSchema>
export type EffectiveGoal = z.infer<typeof EffectiveGoalSchema>
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
export type GetEnergyBurnedOutput = z.infer<typeof GetEnergyBurnedOutputSchema>
export type Profile = z.infer<typeof ProfileSchema>
export type SetProfileInput = z.infer<typeof SetProfileInputSchema>
export type GetProfileOutput = z.infer<typeof GetProfileOutputSchema>
export type SetProfileOutput = z.infer<typeof SetProfileOutputSchema>
export type WeightUsed = z.infer<typeof WeightUsedSchema>
export type ComputeTargetsOutput = z.infer<typeof ComputeTargetsOutputSchema>
export type Targets = ComputeTargetsOutput & { source: z.infer<typeof GoalSummarySchema>['source'] }
export type GetGoalsOutput = z.infer<typeof GetGoalsOutputSchema>
export type SetGoalsInput = z.infer<typeof SetGoalsInputSchema>
export type SetGoalsOutput = z.infer<typeof SetGoalsOutputSchema>
export type ResetGoalsOutput = z.infer<typeof ResetGoalsOutputSchema>
export type LogWaterInput = z.infer<typeof LogWaterInputSchema>
export type LogWeightInput = z.infer<typeof LogWeightInputSchema>
