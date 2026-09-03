import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Hosted static contract probe for issue #75: native onboarding must offer
// EXACTLY three client choices — Claude / ChatGPT / Others — with unified
// per-client guidance, every endpoint occurrence derived from the configured
// build value through {{MCP_URL}} substitution, and no retired duplicate
// platform labels anywhere in the onboarding source.
//
// The native runtime contract is asserted exactly in
// app/Tests/MorselTests/OnboardingTests.swift; this probe keeps the same
// three-case Swift contract detectable in hosted `npm test` (ubuntu runner,
// no xcodebuild), parsing the real Onboarding.swift source like the other
// app-level probes (warm-palette.test.ts, version-metadata.test.ts).

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const onboardingSource = readFileSync(
  join(repoRoot, 'app', 'Sources', 'Morsel', 'Onboarding.swift'),
  'utf8'
)

const RETIRED_LABELS = ['Custom MCP', 'Claude.ai', 'Claude Desktop', 'Claude Code']

function topLevelDeclaration(source: string, name: string): string {
  const start = source.indexOf(`enum ${name}`)
  expect(start, `enum ${name} must exist`).toBeGreaterThan(-1)
  const bodyOpen = source.indexOf('{', start)
  const bodyClose = source.indexOf('\n}', bodyOpen)
  expect(bodyClose, `enum ${name} body must close at column 0`).toBeGreaterThan(bodyOpen)
  return source.slice(start, bodyClose + 2)
}

describe('onboarding three-choice + canonical-endpoint contract (issue #75)', () => {
  const platformEnum = topLevelDeclaration(onboardingSource, 'OnboardingPlatform')

  it('declares exactly Claude / ChatGPT / Others platform cases', () => {
    const caseLines = platformEnum
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line.startsWith('case '))
    expect(caseLines).toEqual([
      'case claude = "Claude"',
      'case chatGPT = "ChatGPT"',
      'case others = "Others"',
    ])
  })

  it('never re-introduces the retired duplicate platform labels', () => {
    for (const label of RETIRED_LABELS) {
      expect(onboardingSource, `retired label ${label}`).not.toContain(label)
    }
  })

  it('keeps the optional Claude CLI snippet inside the unified Claude prompt', () => {
    // The exact CLI command stays one optional line of the single Claude
    // guidance/prompt — never a separate platform tab or duplicate prompt.
    const claudePromptIndex = onboardingSource.indexOf('static let claudePrompt')
    expect(claudePromptIndex).toBeGreaterThan(-1)
    const claudePrompt = onboardingSource.slice(claudePromptIndex)
    expect(claudePrompt).toContain('claude mcp add --transport http morsel {{MCP_URL}}')
    expect(claudePrompt).toContain('Customize → Connectors')
    expect(claudePrompt).not.toContain('static let claudeCodePrompt')
    expect(claudePrompt).not.toContain('static let claudeDesktopPrompt')
  })

  it('derives every displayed endpoint from {{MCP_URL}}, never a Swift literal', () => {
    // No host may be hardcoded in Swift: both prompt templates carry the
    // {{MCP_URL}} placeholder that OnboardingContent.prompt substitutes with
    // the supplied configured value.
    expect(onboardingSource).not.toContain('https://')
    expect(onboardingSource).toContain(
      'template.replacingOccurrences(of: "{{MCP_URL}}", with: endpoint)'
    )
    expect(onboardingSource).toContain('{{MCP_URL}}')
  })

  it('routes every platform to a shared endpoint-substituted template', () => {
    // The single template-selection point must route Claude to the unified
    // Claude prompt and ChatGPT/Others to the neutral chat prompt.
    expect(onboardingSource).toContain(
      'case .claude: template = OnboardingContent.claudePrompt'
    )
    expect(onboardingSource).toContain(
      'case .chatGPT, .others: template = OnboardingContent.chatPrompt'
    )
    const assignments = onboardingSource.match(/template = OnboardingContent\.\w+/g) ?? []
    expect(assignments).toEqual([
      'template = OnboardingContent.claudePrompt',
      'template = OnboardingContent.chatPrompt',
    ])
  })

  it('wires the rendered Picker to the live enum and defaults the selection to Claude', () => {
    // Review r1: the exact three-case enum must stay WIRED to the production
    // UI. The connect step's segmented Picker must enumerate
    // OnboardingPlatform.allCases (rendering rawValue labels and tagging the
    // case itself) and the initial selection must be .claude — so an enum
    // left exact but detached from the UI (or a hardcoded/retired picker
    // list) cannot false-green.
    const connectStart = onboardingSource.indexOf('private var connectContent')
    const coachStart = onboardingSource.indexOf('private var coachContent')
    expect(connectStart).toBeGreaterThan(-1)
    expect(coachStart).toBeGreaterThan(connectStart)
    const connectContent = onboardingSource.slice(connectStart, coachStart)

    expect(connectContent).toContain('Picker("Platform", selection: $platform) {')
    expect(connectContent).toContain(
      'ForEach(OnboardingPlatform.allCases, id: \\.self) { Text($0.rawValue).tag($0) }'
    )
    expect(connectContent).toContain('.pickerStyle(.segmented)')
    expect(onboardingSource).toContain('@State private var platform = OnboardingPlatform.claude')
  })
})
