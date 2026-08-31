import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Regression probe for issue #32: future native-testflight archives must
// receive the public Supabase endpoint and anon key from repository secrets
// without committing values or printing them. The archived app currently
// fails closed because the generated Info.plist carries empty configuration
// values. This parses the workflow and the Fastfile source (the repo's
// existing Fastfile contract probe, app/version-metadata.test.ts, does the
// same for the generated Xcode project) and asserts the wiring, fail-fast
// validation, MCP URL derivation, shell-safe escaping, and names-only
// diagnostics that keep secrets out of logs.
//
// The Fastfile's runtime behavior (raising on missing/empty values, escaping
// shell metacharacters, never leaking the anon key) is additionally proven by
// an executable Ruby test at fastlane/supabase_xcargs.test.rb.

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const workflowPath = join(repoRoot, '.github', 'workflows', 'native-testflight.yml')
const fastfilePath = join(repoRoot, 'fastlane', 'Fastfile')

describe('native-testflight Supabase configuration injection (issue #32)', () => {
  const workflow = readFileSync(workflowPath, 'utf8')
  const fastfile = readFileSync(fastfilePath, 'utf8')
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

  it('builds all three INFOPLIST overrides plus the build number into the gym xcargs', () => {
    const helper = fastfile.slice(helperIndex, gymIndex)
    expect(helper).toContain('INFOPLIST_KEY_MorselSupabaseURL')
    expect(helper).toContain('INFOPLIST_KEY_MorselSupabaseAnonKey')
    expect(helper).toContain('INFOPLIST_KEY_MORSEL_MCP_URL')
    expect(helper).toContain('CURRENT_PROJECT_VERSION=#{build}')
    expect(fastfile.slice(gymIndex)).toMatch(/xcargs:\s*morsel_supabase_xcargs\(build\)/)
  })

  it('shell-escapes values with Shellwords.escape before concatenation', () => {
    expect(fastfile).toContain('require "shellwords"')
    expect(fastfile).toContain('Shellwords.escape(')
  })
})
