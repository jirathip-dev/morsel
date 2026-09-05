import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'

// Issue #109 — the Migration CD classify job wrote verdict/autoApply/applyPlan
// to $GITHUB_OUTPUT but never lifted them to a job-level `outputs:` block, so
// `needs.classify.outputs.autoApply` in the apply job was always empty and
// apply was unconditionally skipped (Refs #83). This shape regression parses
// .github/workflows/migration-cd.yml and pins the wiring: the classify job
// must export exactly those three outputs from the classify step, and the
// apply job must gate on the exported autoApply.

const root = join(fileURLToPath(import.meta.url), '..', '..')
const source = readFileSync(join(root, '.github/workflows/migration-cd.yml'), 'utf8')

// Job headers are the only 2-space-indented keys in the jobs: section; all
// job content is indented >= 4 spaces, so a header line bounds each block.
function jobBlock(name) {
  const lines = source.split('\n')
  const header = lines.findIndex((line) => line === `  ${name}:`)
  expect(header, `jobs.${name} must exist`).toBeGreaterThanOrEqual(0)
  let end = lines.length
  for (let i = header + 1; i < lines.length; i += 1) {
    if (/^  [a-zA-Z_][a-zA-Z0-9_-]*:$/.test(lines[i])) {
      end = i
      break
    }
  }
  return lines.slice(header, end)
}

describe('migration-cd.yml classify job exports job-level outputs (issue #109)', () => {
  it('declares outputs: above steps: mapping exactly verdict/autoApply/applyPlan from the classify step', () => {
    const block = jobBlock('classify')
    const outputsAt = block.findIndex((line) => line === '    outputs:')
    const stepsAt = block.findIndex((line) => line === '    steps:')
    expect(outputsAt, 'classify job must declare a job-level outputs: key').toBeGreaterThanOrEqual(0)
    expect(stepsAt, 'classify job must declare steps:').toBeGreaterThan(outputsAt)

    // Parse the 6-space-indented stanza that follows outputs:. Every entry
    // must map a key to steps.classify.outputs.<same key>.
    const mappings = {}
    let i = outputsAt + 1
    while (i < block.length && block[i].startsWith('      ')) {
      const match = block[i].match(/^\s{6}([a-zA-Z0-9_-]+): \$\{\{ steps\.classify\.outputs\.([a-zA-Z0-9_-]+) \}\}\s*$/)
      expect(match, `outputs entry must map to steps.classify.outputs.* (got: "${block[i]}")`).not.toBeNull()
      mappings[match[1]] = match[2]
      i += 1
    }
    expect(block[i], 'outputs stanza must terminate at the next job-level key').toBe('    steps:')
    expect(mappings).toEqual({ applyPlan: 'applyPlan', autoApply: 'autoApply', verdict: 'verdict' })
  })

  it('gates the apply job on needs.classify.outputs.autoApply (issue #109)', () => {
    const block = jobBlock('apply')
    const ifAt = block.findIndex((line) => line === '    if: >-')
    expect(ifAt, 'apply job must declare an if: condition').toBeGreaterThanOrEqual(0)
    const stepsAt = ifAt + block.slice(ifAt).findIndex((line) => line === '    steps:')
    expect(stepsAt, 'apply job must declare steps: below if:').toBeGreaterThan(ifAt)
    const condition = block.slice(ifAt, stepsAt).join('\n')
    expect(condition, 'apply gate must reference the exported autoApply output').toContain(
      "needs.classify.outputs.autoApply == 'true'",
    )
  })
})
