import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Regression probe for issue #32: future native-testflight archives must
// receive the public Supabase endpoint and anon key from repository secrets
// without committing values or printing them. The archived app currently
// fails closed because the generated Info.plist carries empty configuration
// values.
//
// Xcode silently drops arbitrary INFOPLIST_KEY_<custom> build settings under
// GENERATE_INFOPLIST_FILE=YES, so the lane delivers the three runtime keys via
// an explicit Info.plist template (fastlane/Morsel-Info.plist) whose
// $(MORSEL_*) placeholders are substituted from plain build settings passed
// through gym xcargs. This parses the workflow, the Fastfile, and the template
// (the repo's existing Fastfile contract probe, app/version-metadata.test.ts,
// does the same for the generated Xcode project) and asserts the wiring,
// fail-fast validation, MCP URL derivation, shell-safe escaping, names-only
// diagnostics, and the template delivery route.
//
// The Fastfile's runtime behavior (raising on missing/empty values, escaping
// shell metacharacters, never leaking the anon key) is additionally proven by
// executable Ruby tests at fastlane/supabase_xcargs.test.rb, and the built
// product is asserted against a real unsigned Xcode build by
// fastlane/built-plist.test.rb.

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const workflowPath = join(repoRoot, '.github', 'workflows', 'native-testflight.yml')
const fastfilePath = join(repoRoot, 'fastlane', 'Fastfile')
const templatePath = join(repoRoot, 'fastlane', 'Morsel-Info.plist')

describe('native-testflight Supabase configuration injection (issue #32)', () => {
  const workflow = readFileSync(workflowPath, 'utf8')
  const fastfile = readFileSync(fastfilePath, 'utf8')
  const template = readFileSync(templatePath, 'utf8')
  const helperIndex = fastfile.indexOf('def morsel_supabase_xcargs')
  const gymIndex = fastfile.indexOf('gym(')

  it('passes the repository SUPABASE secrets into the Fastlane step environment', () => {
    const stepIndex = workflow.indexOf('Build and upload native app to TestFlight')
    expect(stepIndex).toBeGreaterThan(-1)
    const step = workflow.slice(stepIndex)
    expect(step).toContain('SUPABASE_URL: ${{ secrets.SUPABASE_URL }}')
    expect(step).toContain('SUPABASE_ANON_KEY: ${{ secrets.SUPABASE_ANON_KEY }}')
  })

  it('validates both SUPABASE values before gym and fails with names-only diagnostics', () => {
    // The helper must be defined before the lane and the lane must compute the
    // xcargs string (which validates) before the gym( call.
    expect(helperIndex).toBeGreaterThan(-1)
    expect(gymIndex).toBeGreaterThan(helperIndex)
    // The validation reads both env vars, treating missing/empty as failure.
    expect(fastfile).toMatch(/ENV\.fetch\("SUPABASE_URL",\s*""\)/)
    expect(fastfile).toMatch(/ENV\.fetch\("SUPABASE_ANON_KEY",\s*""\)/)
    expect(fastfile).toContain('.empty?')
    // Diagnostics mention only the names; the secret values are never
    // interpolated or echoed.
    const diagnostic = fastfile.slice(helperIndex, gymIndex)
    expect(diagnostic).toMatch(/UI\.user_error!\(/)
    expect(diagnostic).toContain('SUPABASE_URL')
    expect(diagnostic).toContain('SUPABASE_ANON_KEY')
    expect(diagnostic).not.toMatch(/#\{supabase_url\}/)
    expect(diagnostic).not.toMatch(/#\{anon_key\}/)
    expect(diagnostic).not.toMatch(/UI\.message|puts\s/)
  })

  it('derives MORSEL_MCP_URL from SUPABASE_URL with a single slash separator', () => {
    expect(fastfile).toContain('/functions/v1/mcp')
    // Trailing-slash normalization avoids an accidental double slash.
    expect(fastfile).toContain('/+\\z')
  })

  it('delivers all three runtime keys through the Info.plist template and gym xcargs', () => {
    const helper = fastfile.slice(helperIndex, gymIndex)
    // The lane must pass the committed template as INFOPLIST_FILE and the
    // three plain MORSEL_* build settings (not INFOPLIST_KEY_<custom>, which
    // Xcode silently drops under GENERATE_INFOPLIST_FILE=YES).
    expect(helper).toContain('"INFOPLIST_FILE"')
    expect(helper).toContain('Morsel-Info.plist')
    expect(helper).toContain('"MORSEL_SUPABASE_URL"')
    expect(helper).toContain('"MORSEL_SUPABASE_ANON_KEY"')
    expect(helper).toContain('"MORSEL_MCP_URL"')
    expect(helper).not.toContain('INFOPLIST_KEY_MorselSupabaseURL')
    expect(helper).not.toContain('INFOPLIST_KEY_MorselSupabaseAnonKey')
    expect(helper).not.toContain('INFOPLIST_KEY_MORSEL_MCP_URL')
    // CURRENT_PROJECT_VERSION is preserved and the full string reaches gym.
    expect(helper).toContain('CURRENT_PROJECT_VERSION=#{build}')
    expect(fastfile.slice(gymIndex)).toMatch(/xcargs:\s*morsel_supabase_xcargs\(build\)/)
  })

  it('keeps the template a strict superset of the generated plist contract', () => {
    // All project-level keys that previously reached the built plist through
    // allowlisted INFOPLIST_KEY_* settings must still be present in the
    // template, with build-setting references preserved.
    expect(template).toContain('$(INFOPLIST_KEY_CFBundleDisplayName)')
    expect(template).toContain('$(INFOPLIST_KEY_NSCameraUsageDescription)')
    expect(template).toContain('$(INFOPLIST_KEY_NSHealthShareUsageDescription)')
    expect(template).toContain('$(INFOPLIST_KEY_NSHealthUpdateUsageDescription)')
    expect(template).toContain('$(INFOPLIST_KEY_NSPhotoLibraryUsageDescription)')
    expect(template).toContain('$(MARKETING_VERSION)')
    expect(template).toContain('$(CURRENT_PROJECT_VERSION)')
    expect(template).toContain('$(PRODUCT_BUNDLE_IDENTIFIER)')
    expect(template).toContain('<key>ITSAppUsesNonExemptEncryption</key>')
    expect(template).toContain('<key>UIApplicationSceneManifest</key>')
    // The three runtime keys are carried as $(MORSEL_*) placeholders — no
    // committed values, matching app/project.yml's checked-in empty defaults.
    expect(template).toContain('<key>MorselSupabaseURL</key>')
    expect(template).toContain('$(MORSEL_SUPABASE_URL)')
    expect(template).toContain('<key>MorselSupabaseAnonKey</key>')
    expect(template).toContain('$(MORSEL_SUPABASE_ANON_KEY)')
    expect(template).toContain('<key>MORSEL_MCP_URL</key>')
    expect(template).toContain('$(MORSEL_MCP_URL)')
  })

  it('shell-escapes values with Shellwords.escape before concatenation', () => {
    expect(fastfile).toContain('require "shellwords"')
    expect(fastfile).toContain('Shellwords.escape(')
  })
})
