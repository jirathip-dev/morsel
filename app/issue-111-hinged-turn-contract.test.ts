import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Issue #111 — hinged journal page-turn contract probe (source-level, hosted
// so npm test bites Swift edits on ubuntu). Pins the rotation seam native
// XCTest cannot observe from an unhosted bundle: the incoming page swings in
// through a real 3D rotation around the hinge edge (leading for forward,
// trailing for backward, ±70° → 0° with the 0.2 → 1 fade over the approved
// ~0.55s cubic-bezier(.2,.7,.2,1)), driven by JournalPagerModel selection
// changes and interactive drags that respect the no-wrap boundaries. The
// mutation contract: replacing the 3D effect with a plain offset must FAIL
// the first assertion block here.

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const read = (path: string): string => readFileSync(join(repoRoot, path), 'utf8')

const turner = read('app/Sources/Morsel/JournalPageTurner.swift')
const morselApp = read('app/Sources/Morsel/MorselApp.swift')
const diary = read('app/Sources/Morsel/JournalDiaryPage.swift')

function section(source: string, start: string, end: string): string {
  const from = source.indexOf(start)
  const to = source.indexOf(end, from + start.length)
  expect(from, start).toBeGreaterThan(-1)
  expect(to, end).toBeGreaterThan(from)
  return source.slice(from, to).replace(/\s+/g, ' ')
}

describe('issue #111 AC1: the journal pager turns pages on the V1 hinge', () => {
  it('renders the incoming page through a 3D rotation seam, not a plain offset', () => {
    // Mutation target: replacing rotation3DEffect with .offset must fail.
    expect(turner).toContain('.rotation3DEffect(')
    expect(turner).toContain('var vertical = false')
    expect(turner).toContain('axis: vertical ? (x: 1, y: 0, z: 0) : (x: 0, y: 1, z: 0)')
    expect(turner).toContain('perspective: JournalTurnSeam.perspective')
    expect(turner).toContain(': JournalTurnSeam.anchor(for: direction)')
  })

  it('hinges forward turns on the leading edge and backward turns on the trailing edge', () => {
    expect(turner).toMatch(/case \.forward: return \.leading/)
    expect(turner).toMatch(/case \.backward: return \.trailing/)
  })

  it('swings from the signed ±70° start pose with the 0.2 → 1 fade', () => {
    expect(turner).toMatch(/case \.forward: return -70/)
    expect(turner).toMatch(/case \.backward: return 70/)
    expect(turner).toMatch(/static let startOpacity: Double = 0\.2/)
    expect(turner).toMatch(
      /JournalTurnSeam\.startOpacity \+ \(1 - JournalTurnSeam\.startOpacity\) \* progress/
    )
  })

  it('animates the swing over ~0.55 s with the cubic-bezier(.2,.7,.2,1) curve', () => {
    expect(turner).toMatch(/static let richDuration: Double = 0\.55/)
    expect(turner).toMatch(/\.timingCurve\(0\.2, 0\.7, 0\.2, 1, duration: richDuration\)/)
    expect(turner).toMatch(/static let reducedDuration: Double = 0\.28/)
  })

  it('drives the preview from an interactive drag that respects no-wrap boundaries', () => {
    expect(turner).toContain('DragGesture(minimumDistance: 15')
    expect(turner).toContain('adjacent(baseTab, direction)')
    expect(diary).toContain('typealias JournalTurnMachine = JournalTurnState<JournalTab>')
    expect(diary).toContain('JournalTabNavigation.adjacent(to: $0, turning: $1)')
    expect(turner).toContain('pager.swipe(active.direction)')
    expect(turner).toContain('abs(deltaX) > abs(deltaY)')
  })
})

describe('issue #247: the diary honors Reduce Motion independently of the shell', () => {
  it('zeros the incoming hinge rotation under Reduce Motion', () => {
    const pose = section(turner, 'struct HingeTurnPose:', '// MARK: - Turn state machine')
    expect(pose).toContain(
      '.degrees(JournalTurnSeam.startAngle(for: direction) * (1 - progress)'
      + ' * (isIncoming && !reduceMotion ? 1 : 0))'
    )
  })

  it('passes the accessibility preference to both the committed and preview date poses', () => {
    expect(diary).toContain('@Environment(\\.accessibilityReduceMotion) private var reduceMotion')
    const body = section(diary, 'var body: some View', 'private var dateRail:')
    expect(body).toContain(
      'content.modifier(HingeTurnPose(direction: machine.turn?.direction ?? .forward,'
      + ' progress: machine.turn?.progress ?? 1, isIncoming: machine.phase == .committing,'
      + ' vertical: true, reduceMotion: reduceMotion))'
    )
    expect(body).toContain(
      '.modifier(HingeTurnPose(direction: turn.direction, progress: turn.progress,'
      + ' vertical: true, reduceMotion: reduceMotion))'
    )
  })

  it('passes Reduce Motion through both the selection and drag animation paths', () => {
    const body = section(diary, 'var body: some View', 'private var dateRail:')
    const gesture = section(diary, 'private var dayGesture:', 'private func dayButton(')
    for (const path of [body, gesture]) {
      expect(path).toContain('animateJournalTurn(machine, effect: effect, reduceMotion: reduceMotion)')
    }
  })

  it('wires a Reduce Motion change to interrupt the diary turn', () => {
    // Source-level wiring pin, not a simulated accessibility-setting change.
    // This hook lives in JournalDiaryPage.swift, not JournalPageTurner.swift.
    const body = section(diary, 'var body: some View', 'private var dateRail:')
    expect(body).toContain('.onChange(of: reduceMotion) { _, _ in machine.interrupt() }')
  })
})

describe('issue #111 AC2: the shell swaps the pager for the Reduce Motion fade', () => {
  it('mounts the hinged pager only in the rich path — the flat .page slide is gone', () => {
    const shellStart = morselApp.indexOf('private struct AuthenticatedDashboardView')
    expect(shellStart, 'shell must exist').toBeGreaterThan(-1)
    const shell = morselApp.slice(shellStart)
    expect(shell).toContain('JournalPageTurner(pager: pager)')
    expect(shell, 'the page-style TabView slide is gone').not.toContain('.tabViewStyle(')
    expect(shell, 'the selection binding TabView is gone').not.toContain('TabView(selection:')
  })

  it('keeps the Reduce Motion path a non-3D fade driven by the same seam', () => {
    const shellStart = morselApp.indexOf('private struct AuthenticatedDashboardView')
    expect(shellStart).toBeGreaterThan(-1)
    const shell = morselApp.slice(shellStart)
    const pageContent = shell.slice(shell.indexOf('private var pageContent'))
    expect(pageContent).toMatch(
      /if reduceMotion\s*\{[\s\S]*?journalPage\(for: pager\.selection\)[\s\S]*?\.transition\(\.opacity\)/
    )
    // The fade is animated at the page container with the seam's reduced
    // duration (never a 3D effect under Reduce Motion).
    expect(shell).toContain('JournalTurnSeam.reducedDuration')
    expect(shell).toContain('.easeOut(duration: JournalTurnSeam.reducedDuration)')
    expect(shell, 'no rotation seam may drive the Reduce Motion swap').not.toMatch(
      /reduceMotion[\s\S]{0,400}?rotation3DEffect/
    )
  })
})
