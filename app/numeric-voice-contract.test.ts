import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

const read = (name: string): string => readFileSync(new URL(`Sources/Morsel/${name}.swift`, import.meta.url), 'utf8')

describe('owner-approved numeric voice', () => {
  it('keeps technical mono roles separate from explicit tabular lining serif', () => {
    const design = read('DesignSystem')
    expect(design).toContain('static let morselData = Font.morselMono(size: 11)')
    expect(design).toContain('static let morselDataMedium = Font.morselMonoMedium(size: 11)')
    const number = design.split('static func morselNumber(')[1]?.split('static let morselDisplay')[0] ?? ''
    for (const code of ['variableSerif(size: size, weight: weight)', 'kMonospacedNumbersSelector',
      'kUpperCaseNumbersSelector', 'scaledFont(for: number)',
      'static let morselValue = Font.morselNumber(size: 11)',
      'static let morselValueMedium = Font.morselNumber(size: 11, weight: 500)']) {
      expect(number).toContain(code)
    }
  })

  it('routes real number-bearing consumers through the new role at unchanged sizes', () => {
    expect(read('Views')).toContain('.font(.morselNumber(size: 32, weight: 500))')
    expect(read('HistoryLedgerViews')).toContain('.font(.morselNumber(size: 30, weight: 500))')
    for (const size of [10, 11, 12, 14]) {
      expect(read('JournalFoodRow')).toContain(`.font(.morselNumber(size: ${String(size)}))`)
    }
    expect(read('PaperFields')).toContain('Font.morselNumber(size: prominent ? 22 : 17, weight: 500)')
    expect(read('PaperFields')).toContain('Text(error)\n                    .font(.morselValue)')
    expect(read('JournalCalendarView')).toContain('Text(date.formatted(.dateTime.day())).font(.morselValue)')
    expect(read('AddMealPhotoSection')).toContain('Text("JPEG · \\(photo.data.count / 1_024) KB")\n'
      + '                            .font(.morselValue)')
  })

  it('has a reproducible, classified inventory with no unapproved mono consumers', () => {
    const script = new URL('../docs/evidence/issue-263-numeric-voice/inventory.py', import.meta.url)
    expect(execFileSync('python3', [script.pathname, '--check'], { encoding: 'utf8' }))
      .toContain('Remaining mono inventory matches')
  })

  it('leaves the separately approved training typography local', () => {
    const training = read('TrainingFuelViews')
    expect(training).toContain('enum TrainingDayType')
    expect(training).not.toMatch(/morselNumber|morselValue/)
    expect(read('EndpointCopyPill')).toContain('.font(.morselDataMedium)')
    expect(read('SettingsView').match(/\.font\(\.morselData\)/g)).toHaveLength(4)
  })
})
