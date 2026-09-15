import { describe, expect, it } from 'vitest'
import { existsSync, readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const read = (name: string): string => {
  const path = fileURLToPath(new URL(`Sources/Morsel/${name}.swift`, import.meta.url))
  return existsSync(path) ? readFileSync(path, 'utf8') : ''
}
const model = read('TrainingFuelModel')
const views = read('TrainingFuelViews')
const hero = read('Views').split('private struct JournalHeroView')[1]?.split('// MARK: - Issue #136')[0] ?? ''

describe('P1 native production wiring', () => {
  it('routes the Today denominator and ring through confirmed day-only state, never Movement', () => {
    expect(hero).toContain('private var target: Double? { trainingFuel.target }')
    expect(hero).toContain('goal: target,')
    expect(hero).toContain('viewModel.totals.caloriesKcal - target')
    expect(hero).toContain('MorselFormat.number(target)')
    expect(hero).toContain('TrainingFuelSection(model: trainingFuel)')
    expect(hero).not.toContain('activeEnergyBurned')
    expect(hero).not.toContain('lastHealthImportDate')
  })
  it('owns the note outside the transient pages and anchors the real editor there', () => {
    expect(read('MorselApp')).toContain('.trainingFuel(viewModel: viewModel)')
    expect(read('TrainingFuelHost')).toContain('@StateObject private var model = TrainingFuelModel()')
    expect(read('TrainingFuelHost')).toContain('TrainingFuelEditor(model: model)')
    expect(read('TrainingFuelHost')).toContain('model.synchronize($0, calendar: .autoupdatingCurrent)')
  })
  it('opens blank, binds user input, explicit confirm, unchecked consent and undo', () => {
    expect(model).toContain('draft = addition.map { String($0) } ?? ""')
    expect(model).toContain('acknowledgesDayOnly = false')
    expect(views).toContain('TextField("Your amount", text: $model.draft)')
    expect(views).toContain('isOn: $model.acknowledgesDayOnly')
    expect(views).toContain('Task { await model.confirm() }')
    expect(views).toContain('.disabled(!model.canConfirm)')
    expect(views).toContain('model.undo()')
    expect(views).toContain('model.cancel()')
    expect(views).toContain('No amount suggested.')
    expect(model + views).not.toMatch(/\b300\b|9999|duration\s*[><]|activeEnergyBurned/)
  })
  it('renders separate dated readings and never substitutes an upload stamp or missing zero', () => {
    expect(views).toContain('reading("Movement", model.context.movement)')
    expect(views).toContain('reading("Workout", model.context.workout)')
    expect(read('TrainingFuelContext')).toContain('reading?.value ?? "Unavailable"')
    expect(read('TrainingFuelContext')).toContain('stamp(sampleDate)')
    expect(read('TrainingFuelContext')).toContain('stamp(checkedAt)')
    expect(read('TrainingFuelHealthReader')).toContain('toShare: []')
    expect(read('TrainingFuelHealthReader')).toContain('options: .cumulativeSum')
  })
  it('commits only after acceptance and keeps all durable write capabilities out', () => {
    expect(model.indexOf('addition = amount')).toBeGreaterThan(model.indexOf('try await accept()'))
    expect(model).toContain('guard operation == token else { return }')
    expect(model).toContain('guard isCurrentDay else')
    expect(model).not.toMatch(/repository\.|saveGoals|deleteMeal|UserDefaults|HKHealthStore/)
  })
})
