import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Issue #54 — unauthenticated sign-in/onboarding surfaces must carry the V1
// orange action tint (the no-cool-product-accent rule). Before this probe the
// initial no-session route and the setupDeferred ("Set up later") re-entry
// presented SignInView / OnboardingView with NO tint, so tint-dependent
// controls (focused text fields, segmented pickers, spinners, default-style
// buttons) fell back to iOS system blue. The authenticated journal keeps its
// forest active-navigation treatment untouched — this probe only pins the
// UNAUTHENTICATED sites and the shared wrapper mechanism.
//
// Structural discriminator: each site assertion is a bounded, unique-anchor
// slice of the real MorselApp.swift shell, so removing the wrapper at ONE
// site fails alone (whole-file occurrence counts cannot catch single-site
// deletion). Mutation-proven: unwrap initial-onboarding → RED; unwrap
// setupDeferred sign-in → RED; unwrap the authenticated cover → RED; retint
// the wrapper away from Color.morselAccent → RED.

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const read = (path: string): string => readFileSync(join(repoRoot, path), 'utf8')

const morselApp = read('app/Sources/Morsel/MorselApp.swift')
const designSystem = read('app/Sources/Morsel/DesignSystem.swift')

function countMatches(text: string, pattern: string): number {
  return [...text.matchAll(new RegExp(pattern, 'g'))].length
}

function mustSlice(text: string, anchorStart: string, anchorEnd?: string): string {
  const start = text.indexOf(anchorStart)
  if (start < 0) throw new Error(`anchor not found: ${JSON.stringify(anchorStart)}`)
  if (anchorEnd === undefined) return text.slice(start)
  const end = text.indexOf(anchorEnd, start)
  if (end < 0) throw new Error(`end anchor not found after ${JSON.stringify(anchorStart)}: ${JSON.stringify(anchorEnd)}`)
  return text.slice(start, end)
}

/** Parse the MorselPalette pair table `static let x: Pair = ("#…", "#…")`. */
function palettePairs(): Map<string, string> {
  const map = new Map<string, string>()
  for (const m of designSystem.matchAll(
    /static let (\w+): Pair = \("#([0-9A-F]{6})", "#([0-9A-F]{6})"\)/g
  )) {
    map.set(m[1], `#${m[2]}`)
  }
  return map
}

function channel(hex: string, i: number): number {
  return parseInt(hex.replace('#', '').slice(i * 2, i * 2 + 2), 16)
}

// Bounded slices of the real shell.
const root = mustSlice(morselApp, 'private struct MorselRootView: View', 'private struct AuthenticatedDashboardView: View')
const sessionBranch = mustSlice(root, 'if let session = sessionStore.session {', '} else if sessionStore.isSetupDeferred {')
const deferredSite = mustSlice(root, '} else if sessionStore.isSetupDeferred {', '} else {')
const initialSite = mustSlice(root, '} else {', '.task {')
// pageContent (tab wrappers) follows the covers in the shell; end the cover
// slice at its declaration so only the cover wrapper sits inside.
const coverSite = mustSlice(
  morselApp,
  '.fullScreenCover(isPresented: $showingOnboarding) {',
  'private var pageContent: some View'
)
const wrapperDef = mustSlice(morselApp, '/// Scoped orange action tint', 'private struct JournalTabBar')

describe('issue #54: unauthenticated sign-in/onboarding surfaces carry the V1 orange action tint', () => {
  it('declares one scoped action-tint wrapper that applies Color.morselAccent', () => {
    expect(wrapperDef, 'MorselActionTint wrapper must be declared').toContain(
      'private struct MorselActionTint<Content: View>: View'
    )
    expect(wrapperDef, 'the wrapper must re-apply the accent tint over its content').toContain(
      '.tint(Color.morselAccent)'
    )
    // The wrapper is the ONLY tint applied in the shell (the journal tab bar
    // colors its own active word explicitly in forest; no other .tint site).
    expect(countMatches(morselApp, '\\.tint\\('), 'shell must have exactly one .tint site').toBe(1)
  })

  it('resolves the wrapper tint to the warm V1 accent, never a cool/system default', () => {
    const pairs = palettePairs()
    const accent = pairs.get('accent')
    expect(accent, 'MorselPalette.accent must be declared').toBe('#E66A2C')
    const decl = designSystem.match(
      /static let morselAccent = Color\.morselJournal\(paper: MorselPalette\.(\w+)\.paper, night: MorselPalette\.\1\.night\)/
    )
    expect(decl?.[1], 'morselAccent must read its pair from MorselPalette.accent').toBe('accent')
    // Warm orange: red dominates and exceeds both green and blue.
    const r = channel(accent!, 0)
    const g = channel(accent!, 1)
    const b = channel(accent!, 2)
    expect(r, `accent ${accent} must be a warm hue, not system blue`).toBeGreaterThan(g)
    expect(g, `accent ${accent} must be a warm hue, not system blue`).toBeGreaterThan(b)
  })

  it('wraps the initial no-session onboarding site in MorselActionTint', () => {
    expect(initialSite, 'initial onboarding branch must carry MorselActionTint').toMatch(
      /MorselActionTint\s*\{\s*OnboardingView\(/
    )
    expect(countMatches(initialSite, 'MorselActionTint\\s*\\{')).toBe(1)
  })

  it('wraps the setupDeferred ("Set up later") sign-in site in MorselActionTint', () => {
    expect(deferredSite, 'setupDeferred sign-in branch must carry MorselActionTint').toMatch(
      /MorselActionTint\s*\{\s*SignInView\(auth: auth\)/
    )
    expect(countMatches(deferredSite, 'MorselActionTint\\s*\\{')).toBe(1)
  })

  it('keeps the wrapper scoped: the authenticated branch is not accent-tinted at the root', () => {
    expect(countMatches(sessionBranch, 'MorselActionTint\\s*\\{'), 'session branch must not be wrapped').toBe(0)
    expect(sessionBranch).toContain('AuthenticatedDashboardView(')
  })

  it('keeps the authenticated onboarding re-entry cover wrapped', () => {
    expect(coverSite).toMatch(/MorselActionTint\s*\{\s*OnboardingView\(/)
    expect(countMatches(coverSite, 'MorselActionTint\\s*\\{'), 'cover slice must hold exactly one wrapper').toBe(1)
  })

  it('keeps the forest active-navigation shell intact beside the action-tint sites', () => {
    // The tab bar draws its active word in forest (v1-journal + warm-palette
    // probes own the full nav contract; here we pin that the wrapper change
    // did not displace the bar or its forest word from the shell).
    const bar = mustSlice(morselApp, 'private struct JournalTabBar')
    expect(bar).toContain('Color.morselForest')
    expect(morselApp).toContain('JournalTabBar(pager: pager)')
  })
})
