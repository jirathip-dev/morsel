export interface Database {
  public: {
    Tables: {
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
        }
        Update: {
          name?: string
          quantity?: number
          calories_kcal?: number | null
          protein_g?: number | null
          carbs_g?: number | null
          fat_g?: number | null
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
        }
        Insert: {
          user_id: string
          calorie_target_kcal?: number | null
          protein_g?: number | null
          carbs_g?: number | null
          fat_g?: number | null
          source?: string
        }
        Update: {
          user_id?: string
          calorie_target_kcal?: number | null
          protein_g?: number | null
          carbs_g?: number | null
          fat_g?: number | null
          source?: string
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
          logged_at: string
          kg: number
        }
        Insert: {
          user_id: string
          logged_at?: string
          kg: number
        }
        Update: {
          user_id?: string
          logged_at?: string
          kg?: number
        }
        Relationships: []
      }
    }
    Views: Record<string, never>
    Functions: Record<string, never>
  }
}

