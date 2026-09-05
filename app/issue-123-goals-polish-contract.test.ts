import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Issue #123 — Goals page polish source contract probe (hosted so npm test
// bites Swift edits on ubuntu, mirroring warm-palette/issue-111 style).
// Pins the two app-side fixes native XCTest runs locally:
// 1. local-first first paint: the editor paints the cached stored goal row
//    BEFORE the remote round-trip (cachedGoals precedes loadToday), so the
//    page never opens as empty fields with red validation; pristine empty
//    fields stay calm until the user edits them (editedFields guard);
//    while the very first load is in flight with no cache the view shows
//    the calm loading state (isAwaitingFirstGoal).
// 2. the direction chip is derived, not tap-only: a computed effective
//    goal fills the chip matching the profile diet goal (lose→cut /
//    maintain→maintain / gain→bulk); a manual goal fills nothing and the
//    profile phase renders as the lighter profileDirection hint chip.
// Mutation contract: removing the cachedGoals paint, dropping the empty-
// field guard, or deleting the profile-derived chip must FAIL here.

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const read = (path: string): string => readFileSync(join(repoRoot, path), 'utf8')

const goalsModel = read('app/Sources/Morsel/GoalsEditorModel.swift')
const goalsEditor = read('app/Sources/Morsel/GoalsEditor.swift')
const localFirst = read('app/Sources/Morsel/LocalFirstRepository.swift')
const repository = read('app/Sources/Morsel/Repository.swift')
const pageContext = read('app/Sources/Morsel/GoalPageContext.swift')

describe('issue #123 defect 1: cached goal paints first, pristine fields calm', () => {
  it('paints the cached goals row before the remote refresh in load()', () => {
    const paint = goalsModel.indexOf('repository.cachedGoals(userID: userID)')
    expect(paint, 'load() must consult the goals cache').toBeGreaterThan(-1)
    const remoteToday = goalsModel.indexOf('repository.loadToday(userID: userID, date: Date())')
    const remoteContext = goalsModel.indexOf('repository.loadGoalsContext(userID: userID)')
    expect(remoteToday).toBeGreaterThan(paint)
    expect(remoteContext).toBeGreaterThan(paint)
    // The #113 full-context read stays (cache paints, remote reconciles).
    expect(goalsModel).toContain('apply(context)')
  })

  it('keeps pristine empty fields calm until the user edits them', () => {
    expect(goalsModel).toMatch(/value\.isEmpty && !editedFields\.contains\(field\)/)
    expect(goalsModel).toContain('editedFields.insert(field)')
    expect(goalsModel).toContain('editedFields: Set<String> = []')
  })

  it('shows a calm loading state while the first load is in flight without a goal', () => {
    expect(goalsModel).toContain('var isAwaitingFirstGoal')
    expect(goalsModel).toContain('isLoading && goal == nil')
    expect(goalsEditor).toContain('viewModel.isAwaitingFirstGoal')
    expect(goalsEditor).toContain('ProgressView()')
    expect(goalsEditor).toContain('Opening your goals')
  })

  it('serves the cached goals row from the local-first facade', () => {
    expect(localFirst).toContain('func cachedGoals(userID: UUID) async throws -> StoredDashboardGoal?')
    expect(localFirst).toContain('snapshotCache.loadGoalsCache(userKey: userID.uuidString)')
  })

  it('declares cachedGoals on the protocol with a nil default for plain remotes', () => {
    expect(repository).toContain('func cachedGoals(userID: UUID) async throws -> StoredDashboardGoal?')
    expect(pageContext).toContain('func cachedGoals(userID: UUID) async throws -> StoredDashboardGoal? { nil }')
  })
})

describe('issue #123 defect 2: direction chip derived from the profile diet goal', () => {
  it('maps profile diet goals onto directions in GoalDirection', () => {
    expect(goalsEditor).toContain('init(profileDietGoal: ProfileDietGoal)')
    expect(goalsEditor).toContain('case .lose: self = .cut')
    expect(goalsEditor).toContain('case .maintain: self = .maintain')
    expect(goalsEditor).toContain('case .gain: self = .bulk')
  })

  it('fills the derived chip only for a computed effective goal, with profileDirection as the manual hint', () => {
    expect(goalsModel).toContain('@Published private(set) var profileDirection: GoalDirection?')
    expect(goalsModel).toContain('profileDirection = context.profile.map { GoalDirection(profileDietGoal: $0.dietGoal) }')
    expect(goalsModel).toContain('selectedDirection = GoalDirection(profileDietGoal: profile.dietGoal)')
    expect(goalsModel).toMatch(/if effective\.source == \.manual \{\s*\n\s*selectedDirection = nil/)
  })

  it('renders the filled chip and the lighter profile hint distinctly', () => {
    expect(goalsEditor).toContain('viewModel.selectedDirection == nil')
    expect(goalsEditor).toContain('viewModel.profileDirection == direction')
    expect(goalsEditor).toContain('isFilled ? Color.morselForest')
    expect(goalsEditor).toContain('Color.morselForest.opacity(0.45)')
    expect(goalsEditor).toContain('accessibilityAddTraits(isFilled ? .isSelected : [])')
  })
})
