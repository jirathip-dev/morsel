import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Issue #110 — Settings theme immediacy (hosted source-level probe, so
// npm test bites Swift edits on ubuntu). AC2 regression: the appearance
// seam is re-asserted on EVERY presented cover root. A fullScreenCover is a
// separate UIKit presentation — it does not re-resolve the root
// .preferredColorScheme change while it is up (the #105 AC7 unit/wiring
// tests passed while the device stayed stale until Settings closed). The
// fix re-applies MorselAppearance.scheme(for:) — derived from the SAME
// @AppStorage key the root and Settings write — to each cover's own root
// content. Deleting either cover-site modifier fails its own anchored
// slice below.
//
// The hotfix-89 root-seam probe keeps pinning the WindowGroup root; this
// file pins the presented-cover extensions of that seam.

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const read = (path: string): string => readFileSync(join(repoRoot, path), 'utf8')

const morselApp = read('app/Sources/Morsel/MorselApp.swift')

const shellStart = morselApp.indexOf('private struct AuthenticatedDashboardView')
const shell = morselApp.slice(shellStart)

describe('issue #110 AC2: the appearance seam is pinned on every presented cover root', () => {
  it('re-reads the shared theme key at the shell so cover content re-resolves live', () => {
    expect(shell).toContain('@AppStorage(MorselAppearance.themePreferenceKey)')
    expect(shell).toContain('private var themePreferenceRaw = MorselAppearance.defaultThemePreference.rawValue')
    // The cover scheme must resolve through the canonical preference mapping
    // (Paper = light, Night ink = dark, Follow system = nil), never a hard
    // force-light/force-dark on a cover.
    expect(shell).toContain('MorselAppearance.scheme(for: MorselThemePreference(rawValue: themePreferenceRaw) ?? .paper)')
    expect(shell, 'no unconditional force-light on cover roots').not.toContain('.preferredColorScheme(.light)')
    expect(shell, 'no unconditional force-dark on cover roots').not.toContain('.preferredColorScheme(.dark)')
  })

  it('Settings cover root re-asserts the scheme inside its own fullScreenCover', () => {
    const settingsStart = shell.indexOf('.fullScreenCover(isPresented: $showingSettings)')
    expect(settingsStart, 'Settings must stay a fullScreenCover behind the cog').toBeGreaterThan(-1)
    const settingsEnd = shell.indexOf('.fullScreenCover(isPresented: $showingOnboarding)', settingsStart)
    expect(settingsEnd, 'Settings cover slice must have an end anchor').toBeGreaterThan(settingsStart)
    const settingsCover = shell.slice(settingsStart, settingsEnd)
    expect(settingsCover).toContain('SettingsJournalView(')
    // The modifier must sit on the Settings root content INSIDE the cover,
    // before the cover's own closing brace (slice is bounded by the next
    // cover declaration, so an onboarding-site-only modifier cannot satisfy
    // this assertion).
    expect(settingsCover).toMatch(
      /SettingsJournalView\([\s\S]*?\)\s*\.preferredColorScheme\(coverColorScheme\)/
    )
  })

  it('Onboarding cover root re-asserts the scheme inside its own fullScreenCover', () => {
    const onboardingStart = shell.indexOf('.fullScreenCover(isPresented: $showingOnboarding)')
    expect(onboardingStart, 'Onboarding must stay a fullScreenCover').toBeGreaterThan(-1)
    const onboardingEnd = shell.indexOf('.onChange(of: pager.selection)', onboardingStart)
    expect(onboardingEnd, 'Onboarding cover slice must have an end anchor').toBeGreaterThan(onboardingStart)
    const onboardingCover = shell.slice(onboardingStart, onboardingEnd)
    expect(onboardingCover).toContain('OnboardingView(')
    expect(onboardingCover).toMatch(
      /MorselActionTint \{[\s\S]*?OnboardingView\([\s\S]*?\)\s*\}\s*\.preferredColorScheme\(coverColorScheme\)/
    )
  })
})
