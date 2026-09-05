import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Regression probe for issue #32 (r2): future native-testflight archives must
// receive the public Supabase endpoint and anon key from repository secrets
// without committing values or printing them, and without leaking the Morsel
// Info.plist template into SPM resource bundles or putting values on
// xcodebuild/Fastlane command lines.
//
// Delivery contract asserted here (source-level; the built artifact is proven
// by fastlane/built-plist.test.rb and the runtime helpers by
// fastlane/supabase_xcargs.test.rb):
//   - app/project.yml scopes INFOPLIST_FILE to the Morsel app target only,
//     keeping the three Morsel runtime config defaults empty;
//   - fastlane/Morsel-Info.plist is the committed no-value template carrying
//     $(MORSEL_*) placeholders plus all project-level keys;
//   - the Fastfile populates that template FILE transiently
//     (with_morsel_supabase_plist) and restores it in an ensure block, so
//     values never appear in gym xcargs / xcodebuild command lines;
//   - MORSEL_MCP_URL defaults to the canonical Fly transport (issue #75).

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const workflowPath = join(repoRoot, '.github', 'workflows', 'native-testflight.yml')
const fastfilePath = join(repoRoot, 'fastlane', 'Fastfile')
const templatePath = join(repoRoot, 'fastlane', 'Morsel-Info.plist')
const projectYmlPath = join(repoRoot, 'app', 'project.yml')

describe('native-testflight Supabase configuration injection (issue #32, r2)', () => {
  const workflow = readFileSync(workflowPath, 'utf8')
  const fastfile = readFileSync(fastfilePath, 'utf8')
  const template = readFileSync(templatePath, 'utf8')
  const projectYml = readFileSync(projectYmlPath, 'utf8')
  const helperIndex = fastfile.indexOf('def morsel_supabase_values')
  const gymIndex = fastfile.indexOf('gym(')

  it('passes the repository SUPABASE secrets into the Fastlane step environment', () => {
    const stepIndex = workflow.indexOf('Build and upload native app to TestFlight')
    expect(stepIndex).toBeGreaterThan(-1)
    const step = workflow.slice(stepIndex)
    expect(step).toContain('SUPABASE_URL: ${{ secrets.SUPABASE_URL }}')
    expect(step).toContain('SUPABASE_ANON_KEY: ${{ secrets.SUPABASE_ANON_KEY }}')
  })

  it('scopes INFOPLIST_FILE to the Morsel app target and keeps config defaults empty', () => {
    // The Morsel target carries the explicit template; the three Morsel
    // runtime defaults stay empty (never committed values).
    expect(projectYml).toMatch(/INFOPLIST_FILE: \.\.\/fastlane\/Morsel-Info\.plist/)
    expect(projectYml).toMatch(/INFOPLIST_KEY_MorselSupabaseURL: ""/)
    expect(projectYml).toMatch(/INFOPLIST_KEY_MorselSupabaseAnonKey: ""/)
    expect(projectYml).toMatch(/INFOPLIST_KEY_MORSEL_MCP_URL: ""/)
    // No GENERATE_INFOPLIST_FILE on the app target (explicit template wins);
    // MorselTests keeps GENERATE for its own generated plist.
    const morselTarget = projectYml.slice(projectYml.indexOf('  Morsel:'), projectYml.indexOf('  MorselTests:'))
    const testsTarget = projectYml.slice(projectYml.indexOf('  MorselTests:'))
    expect(morselTarget).not.toMatch(/GENERATE_INFOPLIST_FILE/)
    expect(morselTarget).toMatch(/INFOPLIST_FILE:/)
    expect(testsTarget).toMatch(/GENERATE_INFOPLIST_FILE: YES/)
  })

  it('keeps the template a no-value superset of the generated plist contract', () => {
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
    // The three runtime keys are placeholders — no committed values.
    expect(template).toContain('<key>MorselSupabaseURL</key>')
    expect(template).toContain('$(MORSEL_SUPABASE_URL)')
    expect(template).toContain('<key>MorselSupabaseAnonKey</key>')
    expect(template).toContain('$(MORSEL_SUPABASE_ANON_KEY)')
    expect(template).toContain('<key>MORSEL_MCP_URL</key>')
    expect(template).toContain('$(MORSEL_MCP_URL)')
  })

  it('validates both SUPABASE values before gym with names-only diagnostics', () => {
    expect(helperIndex).toBeGreaterThan(-1)
    expect(gymIndex).toBeGreaterThan(helperIndex)
    expect(fastfile).toMatch(/ENV\.fetch\("SUPABASE_URL",\s*""\)/)
    expect(fastfile).toMatch(/ENV\.fetch\("SUPABASE_ANON_KEY",\s*""\)/)
    expect(fastfile).toContain('.empty?')
    const diagnostic = fastfile.slice(helperIndex, gymIndex)
    expect(diagnostic).toMatch(/UI\.user_error!\(/)
    expect(diagnostic).toContain('SUPABASE_URL')
    expect(diagnostic).toContain('SUPABASE_ANON_KEY')
    expect(diagnostic).not.toMatch(/#\{supabase_url\}/)
    expect(diagnostic).not.toMatch(/#\{anon_key\}/)
    expect(diagnostic).not.toMatch(/UI\.message|puts\s/)
  })

  it('defaults MORSEL_MCP_URL to the canonical Fly transport (issue #75)', () => {
    // Issue #75: the build configuration publishes the canonical Fly MCP URL
    // instead of deriving a SUPABASE_URL Edge Function URL. The Supabase Edge
    // transport is legacy/retained backend compatibility only and must not
    // reappear in the build pipeline.
    expect(fastfile).toContain('CANONICAL_MCP_URL = "https://mcp.morselfood.app/mcp"')
    expect(fastfile).toContain('mcp_url: CANONICAL_MCP_URL')
    expect(fastfile).not.toContain('/functions/v1/mcp')
  })

  it('never publishes the nested /mcp/mcp compatibility alias in the build pipeline', () => {
    expect(fastfile).not.toContain('/functions/v1/mcp/mcp')
  })

  it('populates the template file transiently and restores it in an ensure block', () => {
    expect(fastfile).toContain('def with_morsel_supabase_plist')
    expect(fastfile).toContain('File.binread(MORSEL_INFO_PLIST)')
    expect(fastfile).toContain('File.binwrite(MORSEL_INFO_PLIST, populated)')
    expect(fastfile).toContain('ensure')
    expect(fastfile).toContain('File.binwrite(MORSEL_INFO_PLIST, template) if template')
    expect(fastfile).toContain('.gsub("$(MORSEL_SUPABASE_URL)")')
    expect(fastfile).toContain('.gsub("$(MORSEL_SUPABASE_ANON_KEY)")')
    expect(fastfile).toContain('.gsub("$(MORSEL_MCP_URL)")')
  })

  it('never places Supabase values on the gym command line', () => {
    // gym receives only CURRENT_PROJECT_VERSION; the old INFOPLIST_FILE /
    // MORSEL_* command-line delivery is gone entirely.
    const gymCall = fastfile.slice(gymIndex)
    expect(gymCall).toMatch(/xcargs:\s*"CURRENT_PROJECT_VERSION=#\{build\}"/)
    expect(gymCall).not.toContain('INFOPLIST_FILE=')
    expect(gymCall).not.toContain('MORSEL_SUPABASE_URL')
    expect(gymCall).not.toContain('MORSEL_SUPABASE_ANON_KEY')
    expect(gymCall).not.toContain('MORSEL_MCP_URL')
    expect(gymCall).not.toContain('Shellwords')
    // The lane wraps gym in the ephemeral-plist helper (value delivery): the
    // wrapper opens before the gym call and closes after its argument list.
    const wrapper = fastfile.slice(Math.max(0, gymIndex - 120), gymIndex)
    expect(wrapper).toContain('with_morsel_supabase_plist do')
    const close = fastfile.slice(gymIndex + gymCall.indexOf(')'))
    expect(close).toMatch(/\n\s*end\n\s*end\n/)
  })
})
