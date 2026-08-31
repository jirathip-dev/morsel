import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Regression probe for issue #32: altool rejected the TestFlight upload with
// "The main Info.plist did not contain 'CFBundleShortVersionString'. (19)"
// because the XcodeGen-generated app target defined no MARKETING_VERSION.
// This parses the generated project (not a source-text grep) and asserts the
// Morsel *application* target carries a non-empty marketing version and build
// number in both Debug and Release configurations, so the generated Info.plist
// always contains CFBundleShortVersionString and CFBundleVersion.

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const projectPath = join(repoRoot, 'app', 'Morsel.xcodeproj', 'project.pbxproj')

function section(text: string, name: string): string {
  const start = text.indexOf(`/* Begin ${name} section */`)
  const stop = text.indexOf(`/* End ${name} section */`, start)
  if (start === -1 || stop === -1) throw new Error(`missing ${name} section in project.pbxproj`)
  return text.slice(start, stop)
}

function blockId(sectionText: string, headerComment: string): string {
  // Matches "<id> /* <headerComment> */ = {" at the two-tab indentation used
  // for top-level objects. The exact comment token keeps "Morsel" distinct
  // from "MorselTests".
  const match = new RegExp(`\\n\\t{2}([A-F0-9]{24}) /\\* ${headerComment} \\*/ = \\{`).exec(sectionText)
  if (!match) throw new Error(`block "/* ${headerComment} */" not found`)
  return match[1]
}

function bracedContent(text: string, from: number): { content: string; end: number } {
  const open = text.indexOf('{', from)
  if (open === -1) throw new Error('no opening brace')
  let depth = 0
  for (let i = open; i < text.length; i += 1) {
    if (text[i] === '{') depth += 1
    else if (text[i] === '}') {
      depth -= 1
      if (depth === 0) return { content: text.slice(open + 1, i), end: i }
    }
  }
  throw new Error('unbalanced braces')
}

function buildConfigIds(targetsSection: string, configsSection: string, targetName: string): string[] {
  const targetId = blockId(targetsSection, targetName)
  const targetBlock = bracedContent(targetsSection, targetsSection.indexOf(targetId)).content
  const listMatch = /buildConfigurationList = ([A-F0-9]{24})(?: \/\* .*? \*\/)?;/.exec(targetBlock)
  if (!listMatch) throw new Error(`no buildConfigurationList for target ${targetName}`)
  const listBlock = bracedContent(configsSection, configsSection.indexOf(listMatch[1])).content
  const ids = [...listBlock.matchAll(/\b([A-F0-9]{24}) \/\* (Debug|Release) \*\//g)].map((m) => m[1])
  if (ids.length !== 2) throw new Error(`expected 2 build configurations for ${targetName}, got ${ids.length}`)
  return ids
}

function buildSetting(configsSection: string, configId: string, key: string): string | undefined {
  const configBlock = bracedContent(configsSection, configsSection.indexOf(configId)).content
  const settings = bracedContent(configBlock, configBlock.indexOf('buildSettings =')).content
  const match = new RegExp(`^\\s*${key}\\s*=\\s*"?([^";]+)"?;\\s*$`, 'm').exec(settings)
  return match?.[1]
}

describe('generated Morsel app version metadata (issue #32)', () => {
  const pbxproj = readFileSync(projectPath, 'utf8')
  const targetsSection = section(pbxproj, 'PBXNativeTarget')
  const configsSection = section(pbxproj, 'XCConfigurationList')
  const buildConfigsSection = section(pbxproj, 'XCBuildConfiguration')
  const appConfigIds = buildConfigIds(targetsSection, configsSection, 'Morsel')

  it('keeps the TestFlight build-number increment contract intact', () => {
    // The fastlane lane passes CURRENT_PROJECT_VERSION via xcargs to bump the
    // build number; the generated project must keep a non-empty default so the
    // generated Info.plist always carries CFBundleVersion.
    for (const configId of appConfigIds) {
      const version = buildSetting(buildConfigsSection, configId, 'CURRENT_PROJECT_VERSION')
      expect(version, `CURRENT_PROJECT_VERSION missing in ${configId}`).toBeTruthy()
    }
  })

  it('gives the generated application target the intended marketing version 1.0.0', () => {
    for (const configId of appConfigIds) {
      const version = buildSetting(buildConfigsSection, configId, 'MARKETING_VERSION')
      expect(version, `MARKETING_VERSION missing in ${configId}`).toBe('1.0.0')
    }
  })
})
