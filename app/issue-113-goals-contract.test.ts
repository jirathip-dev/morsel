import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Issue #113 — Goals app-parts source contract probe (hosted so npm test
// bites Swift edits on ubuntu, mirroring warm-palette/issue-111 style).
// Pins the pieces native XCTest cannot see from an unhosted bundle:
// 1. the recency mirror (manual effective iff goals.updated_at >=
//    profiles.updated_at, server resolveEffectiveGoal twin) in GoalsMath,
// 2. the superseded-manual calm note + amendment B read-only profile line
//    copy in GoalsEditorModel,
// 3. the amendment C Today margin note (Apple Health · last-import time
//    from the SAME #112 stamp, no second clock) in MorselStamp/Views, and
// 4. the Goals page/ViewModel wiring that renders both notes.
// Mutation contract: deleting the note copy, reverting the margin to
// "kcal today", or loosening the >= recency comparison must FAIL here.

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const read = (path: string): string => readFileSync(join(repoRoot, path), 'utf8')

const goalsMath = read('app/Sources/Morsel/GoalsMath.swift')
const goalsModel = read('app/Sources/Morsel/GoalsEditorModel.swift')
const goalsEditor = read('app/Sources/Morsel/GoalsEditor.swift')
const stamp = read('app/Sources/Morsel/MorselStamp.swift')
const views = read('app/Sources/Morsel/Views.swift')
const viewModel = read('app/Sources/Morsel/ViewModel.swift')
const repository = read('app/Sources/Morsel/Repository.swift')

describe('issue #113 AC2: DashboardMath mirrors the server recency rule', () => {
  it('keeps a manual goal effective only when its write time is >= the profile write time', () => {
    expect(goalsMath).toMatch(/storedUpdatedAt >= profileUpdatedAt/)
    // Manual loses when its write time is missing but the profile has one.
    expect(goalsMath).toMatch(/guard let storedUpdatedAt = stored\.updatedAt else \{ return false \}/)
  })

  it('emits the superseded payload only for COMPLETE stale manual rows', () => {
    expect(goalsMath).toMatch(/let updatedAt = stored\.updatedAt,/)
    expect(goalsMath).toContain('guard let stored, stored.source == .manual,')
    expect(goalsMath).toContain('!manualIsCurrent(stored: stored, profile: profile)')
  })

  it('computes the effective goal from the newest synced weight with profile fallback', () => {
    // Amendment A signature both on effectiveGoal and computedGoal.
    expect(goalsMath.match(/latestWeightKg: Double\? = nil/g)?.length).toBeGreaterThanOrEqual(2)
    expect(goalsMath).toMatch(/let weightTerm = 10 \* \(latestWeightKg \?\? profile\.weightKg\)/)
    // The dashboard read feeds the newest weight_logs point into the goal.
    expect(repository).toContain('latestWeightKg: weightRows.compactMap(parseWeight).last?.kilograms')
  })
})

describe('issue #113 body item 4 + amendment B: Goals page notes', () => {
  it('renders the calm superseded note under YOUR TARGET with the old manual numbers', () => {
    expect(goalsModel).toContain('your profile changed on')
    expect(goalsModel).toContain('these are the new computed targets')
    expect(goalsModel).toContain('your earlier manual numbers were')
    expect(goalsEditor).toContain('viewModel.supersededNote')
  })

  it('renders the read-only profile line driven by profile + weight_used analog', () => {
    expect(goalsModel).toContain('computed from ')
    expect(goalsModel).toContain('(Health · ')
    expect(goalsModel).toContain('set via your agent')
    expect(goalsModel).toContain('no profile yet — tell your agent your height, weight, age and activity')
    expect(goalsEditor).toContain('viewModel.profileLine')
  })

  it('loads the full Goals-page context (stored + profile + newest weight)', () => {
    expect(goalsModel).toContain('repository.loadGoalsContext(userID: userID)')
    expect(goalsModel).toContain('latestWeightKg: context.latestWeight?.kilograms')
  })
})

describe('issue #113 amendment C: Today margin note source + freshness', () => {
  it('shows "moved X kcal · Apple Health · HH:mm" using the SAME #112 stamp', () => {
    expect(stamp).toContain('moved ')
    expect(stamp).toContain('· Apple Health ·')
    expect(stamp).toMatch(/dateFormat = "HH:mm"/)
    expect(views).toContain('ActiveEnergyMarginNote.line(')
    expect(views, 'the old bare "kcal today" hero literal is gone').not.toContain('kcal today')
  })

  it('derives the note time from lastSuccessfulUpload — no second clock', () => {
    expect(viewModel).toContain('lastHealthImportDate')
    expect(viewModel).toContain('healthStore.lastSuccessfulUpload()')
    expect(stamp).toContain('lastSuccessfulUpload')
  })
})
