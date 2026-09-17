import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'

const read = (name: string): string => readFileSync(new URL(`Sources/Morsel/${name}.swift`, import.meta.url), 'utf8')
const views = read('TrainingFuelViews')
const today = read('Views')
const row = views.split('struct TrainingFuelSection: View')[1]?.split('struct TrainingFuelEditor')[0] ?? ''

describe('approved training-day variant A only', () => {
  it('makes the single target row an always-enabled full-row sheet entry', () => {
    expect(row).toContain('model.openSheet()')
    expect(row).toContain('model.rowText')
    expect(row).toContain('minHeight: 44')
    expect(row).toContain('.contentShape(Rectangle())')
    expect(row).not.toMatch(/disabled|Undo|Movement|Workout|DisclosureGroup|Toggle|Receipt/)
    expect(today.match(/TrainingFuelSection\(model: trainingFuel\)/g)).toHaveLength(2)
    expect(today.match(/if viewModel.selectedDate == viewModel.today \{ TrainingDayUnavailableRow\(\) \}/g)).toHaveLength(2)
    expect(today).not.toMatch(/Eaten · Goal|Goal unavailable/)
    expect(today).not.toContain('source: \\(goal')
    expect(today).not.toContain('Text("/ ')
    expect(views).not.toContain('TrainingFuelReceipt')
  })
  it('keeps the three open-journal sections, blank writing field and sheet-only actions', () => {
    expect(views.indexOf('Text("Today\'s answer")')).toBeLessThan(views.indexOf('Text("Readings")'))
    expect(views.indexOf('Text("Readings")')).toBeLessThan(views.indexOf('Text("About this context")'))
    for (const text of ['Add for this day', 'Your amount', 'Edit amount', 'Undo adjustment', 'Read Apple Health',
      'No amount suggested.', 'not a calorie bonus', 'does not mean a rest day', 'sports dietitian',
      'Overlap with your usual target is unknown.', 'not saved to Health or synced.',
      'No meal, future goal or historical target changes.']) expect(views).toContain(text)
    expect(views).not.toContain('DisclosureGroup')
    expect(read('TrainingFuelHost')).toContain('model.isPresented')
    expect(views).toContain('model.validationMessage')
  })
  it('uses the separately approved numeric hero role without changing local training typography', () => {
    expect(today).toContain('.font(.morselNumber(size: 32, weight: 500))')
    expect(read('DesignSystem')).toContain('static let morselHero = Font.morselMonoMedium(size: 32)')
    expect(views + read('TrainingFuelModel')).not.toMatch(/\b300\b|\b2126\b|\b2426\b/)
  })
})
