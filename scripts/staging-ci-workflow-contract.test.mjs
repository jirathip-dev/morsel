import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'

// Issue #198 — hosted CI must run for the protected integration branch
// `staging` (its ruleset requires the checks quality, swiftlint,
// bun-fly-entrypoint and fastfile-contract) while every production/CD
// boundary stays exactly as it was: deploy jobs and the migration apply path
// remain human-dispatched, and `main` stays the only push target of
// migration-cd.yml.
//
// The checks below parse the workflow TRIGGER STRUCTURE (top-level `on:`
// stanza → 2-space trigger keys → `branches:` list) instead of doing loose
// substring matching over whole files, so a comment or an unrelated step
// name can never satisfy a pin.

const root = join(fileURLToPath(import.meta.url), '..', '..')

function workflow(name) {
  return readFileSync(join(root, '.github/workflows', name), 'utf8')
}

// Lines of the top-level `on:` stanza, bounded by the next column-0 key.
function onBlock(source, file) {
  const lines = source.split('\n')
  const start = lines.findIndex((line) => line === 'on:')
  expect(start, `${file} must declare a top-level on: trigger stanza`).toBeGreaterThanOrEqual(0)
  let end = lines.length
  for (let i = start + 1; i < lines.length; i += 1) {
    if (/^[a-zA-Z]/.test(lines[i])) {
      end = i
      break
    }
  }
  return lines.slice(start + 1, end).filter((line) => line.trim() !== '' && !line.trimStart().startsWith('#'))
}

// Trigger names declared at 2-space indentation directly under `on:`.
function triggers(source, file) {
  return onBlock(source, file)
    .filter((line) => /^ {2}[a-zA-Z_][a-zA-Z0-9_-]*:\s*$/.test(line))
    .map((line) => line.trim().slice(0, -1))
}

// Lines of one 2-space trigger stanza, bounded by the next sibling or
// top-level key.
function triggerBlock(source, file, key) {
  const block = onBlock(source, file)
  const start = block.findIndex((line) => line === `  ${key}:`)
  expect(start, `${file} must declare on.${key}`).toBeGreaterThanOrEqual(0)
  let end = block.length
  for (let i = start + 1; i < block.length; i += 1) {
    if (/^ {2}[a-zA-Z_][a-zA-Z0-9_-]*:/.test(block[i]) || /^[a-zA-Z_]/.test(block[i])) {
      end = i
      break
    }
  }
  return block.slice(start + 1, end)
}

// Branch names of a trigger's `branches:` entry — inline flow list and/or
// block sequence.
function branches(source, file, key) {
  const block = triggerBlock(source, file, key)
  const names = []
  const unquote = (entry) => entry.replace(/^['"]|['"]$/g, '')
  for (let i = 0; i < block.length; i += 1) {
    const inline = block[i].match(/^ {4}branches:\s*\[(.*)\]\s*$/)
    if (inline) {
      names.push(...inline[1].split(',').map((entry) => unquote(entry.trim())).filter(Boolean))
      continue
    }
    if (/^ {4}branches:\s*$/.test(block[i])) {
      for (let j = i + 1; j < block.length; j += 1) {
        const item = block[j].match(/^ {6}- ([^\s#]+)\s*(?:#.*)?$/)
        if (!item) break
        names.push(unquote(item[1]))
      }
    }
  }
  expect(names.length, `${file} on.${key} must declare a branches: list`).toBeGreaterThan(0)
  return names
}

describe('ci.yml runs hosted CI on main and the protected staging branch (issue #198)', () => {
  const source = workflow('ci.yml')

  it('triggers on push to main and staging', () => {
    expect(branches(source, 'ci.yml', 'push')).toEqual(expect.arrayContaining(['main', 'staging']))
  })

  it('triggers on pull_request targeting main and staging', () => {
    expect(branches(source, 'ci.yml', 'pull_request')).toEqual(expect.arrayContaining(['main', 'staging']))
  })
})

describe('migration-cd-pr-shape.yml gates staging pull requests (issue #198)', () => {
  const source = workflow('migration-cd-pr-shape.yml')

  it('triggers on pull_request targeting main and staging', () => {
    expect(branches(source, 'migration-cd-pr-shape.yml', 'pull_request')).toEqual(
      expect.arrayContaining(['main', 'staging']),
    )
  })
})

describe('migration-cd.yml stays main-only (production apply path, issue #198)', () => {
  const source = workflow('migration-cd.yml')

  it('pushes to main only', () => {
    expect(branches(source, 'migration-cd.yml', 'push')).toEqual(['main'])
  })

  it('never pushes to staging', () => {
    expect(branches(source, 'migration-cd.yml', 'push')).not.toContain('staging')
  })
})

// Deploy/TestFlight workflows are human-dispatched only: no push and no
// pull_request trigger may ever appear on them.
const dispatchOnly = [
  'deploy-fly.yml',
  'deploy-edge-function.yml',
  'deploy-migrations.yml',
  'native-testflight.yml',
]

describe.each(dispatchOnly)('%s stays workflow_dispatch-only (issue #198)', (file) => {
  const source = workflow(file)

  it('declares no push: trigger', () => {
    expect(triggers(source, file)).not.toContain('push')
  })

  it('declares no pull_request: trigger', () => {
    expect(triggers(source, file)).not.toContain('pull_request')
  })

  it('declares workflow_dispatch and nothing beyond it', () => {
    expect(triggers(source, file)).toEqual(['workflow_dispatch'])
  })
})
