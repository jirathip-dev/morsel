export interface ComputeTargetsFunctionInput {
  user_id: string
  sex: string
  age_years: number
  height_cm: number
  weight_kg: number
  activity_level: string
  diet_goal: string
  goal_weight_kg: number | null
  updated_at: string
}

export interface ComputeTargetsFunctionRow {
  bmr_kcal: number
  tdee_kcal: number
  calorie_target_kcal: number
  protein_g: number
  carbs_g: number
  fat_g: number
}

export interface LogMealFunctionItem {
  name: string
  quantity: number
  unit: string
  calories_kcal: number | null
  protein_g: number | null
  carbs_g: number | null
  fat_g: number | null
  fiber_g: number | null
  sugar_g: number | null
  barcode: string | null
  food_ref_id: string | null
  confidence: number | null
  source_notes: string | null
  // Issue #152 — optional named-menu snapshot keys stamped by the service
  // when the log references a menu; absent for plain (loose) logs.
  menu_name?: string | null
  menu_group_id?: string | null
}

export interface LogMealFunctionRow {
  meal_log_id: string
  eaten_at: string
  meal_type: string
  items: LogMealFunctionItem[]
}

// Issue #152 — the app-facing atomic menu save payloads (upsert_menu).
export interface UpsertMenuFunctionItem {
  name: string
  quantity: number
  unit: string
  calories_kcal: number | null
  protein_g: number | null
  carbs_g: number | null
  fat_g: number | null
  fiber_g: number | null
  sugar_g: number | null
  barcode: string | null
  food_ref_id: string | null
}

export interface UpsertMenuFunctionRow {
  menu_id: string
}

export interface ClaimOAuthAuthorizationGrantFunctionRow {
  code_hash: string
  client_id: string
  redirect_uri: string
  code_challenge: string
  scopes: string[]
  resource: string | null
  user_id: string
  refresh_token: string
  expires_at: string
}

export interface Database {
  public: {
    Tables: {
      users: {
        Row: {
          id: string
          email: string
          display_name: string | null
          timezone: string
          created_at: string
        }
        Insert: {
          id: string
          email: string
          display_name?: string | null
          timezone?: string
        }
        Update: {
          id?: string
          email?: string
          display_name?: string | null
          timezone?: string
        }
        Relationships: []
      }
      oauth_authorization_grants: {
        Row: {
          code_hash: string
          client_id: string
          redirect_uri: string
          code_challenge: string
          scopes: string[]
          resource: string | null
          user_id: string
          refresh_token: string
          expires_at: string
          created_at: string
        }
        Insert: {
          code_hash: string
          client_id: string
          redirect_uri: string
          code_challenge: string
          scopes?: string[]
          resource?: string | null
          user_id: string
          refresh_token: string
          expires_at: string
          created_at?: string
        }
        Update: {
          code_hash?: string
          client_id?: string
          redirect_uri?: string
          code_challenge?: string
          scopes?: string[]
          resource?: string | null
          user_id?: string
          refresh_token?: string
          expires_at?: string
          created_at?: string
        }
        Relationships: []
      }
      meal_logs: {
        Row: {
          id: string
          user_id: string
          eaten_at: string
          meal_type: string
          source: string
          image_path: string | null
          notes: string | null
        }
        Insert: {
          user_id: string
          eaten_at?: string
          meal_type: string
          source: string
          image_path?: string | null
          notes?: string | null
        }
        Update: {
          user_id?: string
          eaten_at?: string
          meal_type?: string
          source?: string
          image_path?: string | null
          notes?: string | null
        }
        Relationships: []
      }
      meal_items: {
        Row: {
          id: string
          meal_log_id: string
          name: string
          quantity: number
          unit: string
          calories_kcal: number | null
          protein_g: number | null
          carbs_g: number | null
          fat_g: number | null
          fiber_g: number | null
          sugar_g: number | null
          barcode: string | null
          food_ref_id: string | null
          confidence: number | null
          source_notes: string | null
          menu_group_id: string | null
          menu_name: string | null
        }
        Insert: {
          meal_log_id: string
          name: string
          quantity: number
          unit: string
          calories_kcal?: number | null
          protein_g?: number | null
          carbs_g?: number | null
          fat_g?: number | null
          fiber_g?: number | null
          sugar_g?: number | null
          barcode?: string | null
          food_ref_id?: string | null
          confidence?: number | null
          source_notes?: string | null
          menu_group_id?: string | null
          menu_name?: string | null
        }
        Update: {
          name?: string
          quantity?: number
          calories_kcal?: number | null
          protein_g?: number | null
          carbs_g?: number | null
          fat_g?: number | null
          menu_group_id?: string | null
          menu_name?: string | null
        }
        Relationships: []
      }
      meal_menus: {
        Row: {
          id: string
          user_id: string
          name: string
          created_at: string
          updated_at: string
        }
        Insert: {
          id?: string
          user_id: string
          name: string
          created_at?: string
          updated_at?: string
        }
        Update: {
          id?: string
          user_id?: string
          name?: string
          created_at?: string
          updated_at?: string
        }
        Relationships: []
      }
      menu_items: {
        Row: {
          id: string
          menu_id: string
          name: string
          quantity: number
          unit: string
          calories_kcal: number | null
          protein_g: number | null
          carbs_g: number | null
          fat_g: number | null
          fiber_g: number | null
          sugar_g: number | null
          barcode: string | null
          food_ref_id: string | null
          created_at: string
        }
        Insert: {
          id?: string
          menu_id: string
          name: string
          quantity?: number
          unit?: string
          calories_kcal?: number | null
          protein_g?: number | null
          carbs_g?: number | null
          fat_g?: number | null
          fiber_g?: number | null
          sugar_g?: number | null
          barcode?: string | null
          food_ref_id?: string | null
          created_at?: string
        }
        Update: {
          id?: string
          menu_id?: string
          name?: string
          quantity?: number
          unit?: string
          calories_kcal?: number | null
          protein_g?: number | null
          carbs_g?: number | null
          fat_g?: number | null
          fiber_g?: number | null
          sugar_g?: number | null
          barcode?: string | null
          food_ref_id?: string | null
          created_at?: string
        }
        Relationships: []
      }
      profiles: {
        Row: {
          user_id: string
          sex: string
          age_years: number
          height_cm: number
          weight_kg: number
          activity_level: string
          diet_goal: string
          goal_weight_kg: number | null
          timezone: string | null
          updated_at: string
        }
        Insert: {
          user_id: string
          sex: string
          age_years: number
          height_cm: number
          weight_kg: number
          activity_level: string
          diet_goal: string
          goal_weight_kg?: number | null
          timezone?: string | null
          updated_at?: string
        }
        Update: {
          user_id?: string
          sex?: string
          age_years?: number
          height_cm?: number
          weight_kg?: number
          activity_level?: string
          diet_goal?: string
          goal_weight_kg?: number | null
          timezone?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      goals: {
        Row: {
          user_id: string
          calorie_target_kcal: number | null
          protein_g: number | null
          carbs_g: number | null
          fat_g: number | null
          source: string
          updated_at: string
        }
        Insert: {
          user_id: string
          calorie_target_kcal?: number | null
          protein_g?: number | null
          carbs_g?: number | null
          fat_g?: number | null
          source?: string
          updated_at?: string
        }
        Update: {
          user_id?: string
          calorie_target_kcal?: number | null
          protein_g?: number | null
          carbs_g?: number | null
          fat_g?: number | null
          source?: string
          updated_at?: string
        }
        Relationships: []
      }
      food_catalog: {
        Row: {
          id: string
          name: string
          brand: string | null
          barcode: string | null
          serving_size: string | null
          serving_unit: string | null
          calories_kcal: number | null
          protein_g: number | null
          carbs_g: number | null
          fat_g: number | null
        }
        Insert: {
          id?: string
          name: string
          brand?: string | null
          barcode?: string | null
          serving_size?: string | null
          serving_unit?: string | null
          calories_kcal?: number | null
          protein_g?: number | null
          carbs_g?: number | null
          fat_g?: number | null
        }
        Update: {
          id?: string
          name?: string
          brand?: string | null
          barcode?: string | null
          serving_size?: string | null
          serving_unit?: string | null
          calories_kcal?: number | null
          protein_g?: number | null
          carbs_g?: number | null
          fat_g?: number | null
        }
        Relationships: []
      }
      weight_logs: {
        Row: {
          id: string
          user_id: string
          measured_at: string
          kg: number
          source: string
        }
        Insert: {
          user_id: string
          measured_at?: string
          kg: number
          source?: string
        }
        Update: {
          user_id?: string
          measured_at?: string
          kg?: number
          source?: string
        }
        Relationships: []
      }
      energy_burned_logs: {
        Row: { id: string; user_id: string; burned_at: string; active_kcal: number; source: string }
        Insert: { user_id: string; burned_at?: string; active_kcal: number; source?: string }
        Update: { user_id?: string; burned_at?: string; active_kcal?: number; source?: string }
        Relationships: []
      }
    }
    Views: Record<string, never>
    Functions: {
      compute_targets: {
        Args: { p: ComputeTargetsFunctionInput }
        Returns: ComputeTargetsFunctionRow[]
      }
      log_meal_with_items: {
        Args: {
          p_user_id: string
          p_eaten_at: string
          p_meal_type: string
          p_source: string
          p_image_path: string | null
          p_notes: string | null
          p_items: LogMealFunctionItem[]
        }
        Returns: LogMealFunctionRow[]
      }
      upsert_menu: {
        Args: {
          p_user_id: string
          p_menu_id: string | null
          p_name: string
          p_items: UpsertMenuFunctionItem[]
        }
        Returns: UpsertMenuFunctionRow[]
      }
      upsert_food_catalog: {
        Args: { p_rows: Record<string, unknown>[] }
        Returns: null
      }
      claim_oauth_authorization_grant: {
        Args: {
          p_code_hash: string
          p_client_id: string
        }
        Returns: ClaimOAuthAuthorizationGrantFunctionRow[]
      }
    }
  }
}
