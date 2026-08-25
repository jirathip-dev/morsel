// Canonical types for the Morsel MCP tool contract.
// Mirrors docs/MCP_TOOLS.md. The Bun server validates against these; the agent
// skill describes the same shapes to the LLM. Edit here FIRST, then the server.

export type MealType = "breakfast" | "lunch" | "dinner" | "snack";
export type Source = "manual" | "photo_vision" | "barcode" | "import" | "voice";
export type Unit = "g" | "ml" | "serving" | "piece" | "cup";

export type ActivityLevel = "sedentary" | "light" | "moderate" | "active" | "very_active";
export type DietGoal = "lose" | "maintain" | "gain";

export interface Profile {
  sex: "male" | "female";
  age_years: number;
  height_cm: number;
  weight_kg: number;
  activity_level: ActivityLevel;
  diet_goal: DietGoal;
  goal_weight_kg?: number;
}

export interface Targets {
  bmr_kcal: number;
  tdee_kcal: number;
  calorie_target_kcal: number;
  protein_g: number;
  carbs_g: number;
  fat_g: number;
  source: "computed" | "manual";
}

export interface MealItem {
  name: string;
  quantity?: number;
  unit?: Unit;
  calories_kcal?: number;
  protein_g?: number;
  carbs_g?: number;
  fat_g?: number;
  fiber_g?: number;
  sugar_g?: number;
  barcode?: string;
  food_ref_id?: string;
  confidence?: number; // 0..1
  notes?: string;      // agent reasoning
}

export interface LogMealInput {
  meal_type: MealType;
  eaten_at?: string;       // ISO date-time
  items: MealItem[];
  notes?: string;
  image_url?: string;      // public photo URL
}

export interface LogMealOutput {
  meal_log_id: string;
  recorded: boolean;
}

export interface SearchFoodInput {
  query: string;
  limit?: number;
}
export interface SearchFoodItem {
  id: string;
  name: string;
  brand?: string;
  barcode?: string;
  serving_size?: string;
  serving_unit?: string;
  calories_kcal?: number;
  protein_g?: number;
  carbs_g?: number;
  fat_g?: number;
}
export interface SearchFoodOutput {
  results: SearchFoodItem[];
}

export interface UpdateMealItemInput {
  item_id: string;
  name?: string;
  quantity?: number;
  calories_kcal?: number;
  protein_g?: number;
  carbs_g?: number;
  fat_g?: number;
}

export interface GetDayInput {
  date: string; // YYYY-MM-DD
}
export interface GetDayOutput {
  date: string;
  meals: Array<{
    meal_log_id: string;
    meal_type: MealType;
    eaten_at: string;
    items: MealItem[];
  }>;
  totals: { calories_kcal: number; protein_g: number; carbs_g: number; fat_g: number };
  goal?: { calorie_target_kcal?: number };
  remaining_kcal?: number;
}

export interface GetDashboardSummaryInput {
  days?: number;
}

export interface SetGoalsInput {
  calorie_target_kcal?: number;
  protein_g?: number;
  carbs_g?: number;
  fat_g?: number;
}

export interface LogWaterInput {
  ml: number;
  logged_at?: string;
}
export interface LogWeightInput {
  kg: number;
  logged_at?: string;
}
