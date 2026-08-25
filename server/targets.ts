import type { ComputeTargetsOutput, Profile } from '../packages/schema/food-types.js'

const ACTIVITY_FACTORS: Record<Profile['activity_level'], number> = {
  sedentary: 1.2,
  light: 1.375,
  moderate: 1.55,
  active: 1.725,
  very_active: 1.9,
}

function round(value: number): number {
  return Math.round(value)
}

export function calculateTargets(profile: Profile): ComputeTargetsOutput {
  const sexOffset = profile.sex === 'male' ? 5 : -161
  const bmr = 10 * profile.weight_kg + 6.25 * profile.height_cm - 5 * profile.age_years + sexOffset
  const tdee = round(bmr * ACTIVITY_FACTORS[profile.activity_level])
  const calorieTarget = profile.diet_goal === 'lose'
    ? Math.max(1200, tdee - 500)
    : profile.diet_goal === 'gain'
      ? tdee + 300
      : tdee

  return {
    bmr_kcal: round(bmr),
    tdee_kcal: tdee,
    calorie_target_kcal: calorieTarget,
    protein_g: round(calorieTarget * 0.3 / 4),
    carbs_g: round(calorieTarget * 0.45 / 4),
    fat_g: round(calorieTarget * 0.25 / 9),
  }
}

