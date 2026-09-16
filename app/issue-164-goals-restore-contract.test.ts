import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

const source = (file: string): string => readFileSync(new URL(`Sources/Morsel/${file}.swift`, import.meta.url), 'utf8')
const model = source('GoalsEditorModel')
const editor = source('GoalsEditor')
const mutations = source('SupabaseMealMutations')

// Hosted wiring guards complement the native real-repository round-trip tests.
describe('issue #164 restore previous manual goals', () => {
  it('wires the note-local shortcut to the model using existing button chrome', () => {
    const note = editor.slice(editor.indexOf('if let supersededNote'), editor.indexOf('GoalJournalField('))
    expect(note, 'superseded note must offer restore').toContain('Button("Restore previous manual goals")')
    expect(note).toContain('if viewModel.canRestorePreviousManualGoals')
    expect(note).toContain('Task { await viewModel.restorePreviousManualGoals() }')
    expect(note).toContain('.buttonStyle(MorselGhostButtonStyle())')
    expect(note).toContain('.disabled(viewModel.isLoading || viewModel.isSaving)')
  })

  it('fills exact stored values through edit and delegates to the ordinary save', () => {
    const start = model.indexOf('func restorePreviousManualGoals()')
    expect(start, 'restore action must exist').toBeGreaterThanOrEqual(0)
    const action = model.slice(start, model.indexOf('func save()', start))
    expect(action).toContain('guard canRestorePreviousManualGoals, !isLoading, !isSaving,')
    expect(action).toContain('let previous = supersededManual else { return false }')
    for (const [field, value] of [['calories', 'calorieTargetKcal'], ['protein', 'proteinG'], ['carbs', 'carbsG'], ['fat', 'fatG']]) {
      expect(action).toContain(`edit("${field}", value: Self.displayValue(previous.${value}))`)
    }
    expect(action).toContain('return await save()')
    expect(action).not.toContain('repository.saveGoals')
    expect(model).toContain('supersededManual = DashboardMath.supersededManual(stored: context.stored, profile: context.profile)')
    expect(model).toContain('supersededManual != nil && supersededNote != nil')
  })

  it('advances recency on the same native upsert route, including existing rows', () => {
    const payload = mutations.slice(mutations.indexOf('struct GoalPayload:'), mutations.indexOf('private struct MealItemReviewUpdate:'))
    expect(payload, 'native goal upsert must encode updated_at').toContain('case updatedAt = "updated_at"')
    expect(payload).toContain('Date().ISO8601Format(.init(includingFractionalSeconds: true))')
    const save = mutations.slice(mutations.indexOf('func saveGoals('), mutations.indexOf('// MARK: - One-decimal'))
    expect(save).toContain('.upsert(GoalPayload(userID: authenticatedUserID, goal: normalizedGoal))')
    expect(save).toContain('Self.savedGoalMatches(response, goal: normalizedGoal)')
  })
})
