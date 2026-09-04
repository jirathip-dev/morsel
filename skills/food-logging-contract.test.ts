import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Regression contract for issue #93 — food-logging skill TDEE semantics.
//
// The authoritative Morsel target model (server/targets.ts, docs/TARGETS.md,
// docs/DESIGN.md, docs/MCP_TOOLS.md) already folds activity into the goal:
// BMR -> activity factor -> diet goal. The skill must therefore compare eaten
// calories against the effective (TDEE-based, activity-inclusive) goal and
// must never instruct subtracting active energy (burn) from eaten calories —
// that double-counts activity. `get_energy_burned` is context only.
//
// This probe is a source-level read of skills/food-logging/SKILL.md: it bans
// the stale net-intake wording and equivalent double-counting forms (with
// word-boundary care so the required "eaten vs goal" prose cannot trip), and
// pins the replacement semantics that must be present.

const skillPath = join(dirname(fileURLToPath(import.meta.url)), 'food-logging', 'SKILL.md')
const skill = readFileSync(skillPath, 'utf8')

// Double-counting forms: eaten calories minus active burn/energy must never be
// instructed. Bans use word boundaries; "eaten vs goal" / "eaten minus goal"
// prose is the CORRECT semantics and does not match any of these.
const STALE_DOUBLE_COUNTING = [
  /\bnet intake\b/i,
  /minus\s+active/i,
  /\bminus\s+(?:burned?|energy)\b/i,
  /\b(?:subtract|deduct)\w*\s+(?:active|burned?|energy)\b/i,
  /\beaten\s*[-−–]\s*(?:active|burned?|energy)\b/i,
  /double-?count/i,
]

describe('food-logging skill — TDEE eaten-vs-goal semantics (issue #93)', () => {
  it('bans the stale net intake = eaten − active burn instruction and equivalents', () => {
    for (const re of STALE_DOUBLE_COUNTING) {
      expect(skill, `stale double-counting wording reintroduced: ${re}`).not.toMatch(re)
    }
  })

  it('states the effective goal is TDEE-based / activity-inclusive and progress is eaten vs goal', () => {
    expect(skill).toMatch(/\bTDEE-based\b/i)
    expect(skill).toMatch(/\bactivity-inclusive\b/i)
    expect(skill).toMatch(/\beaten\s+vs\.?\s+goal\b/i)
  })

  it('explains active energy is context only and is never subtracted from the goal', () => {
    expect(skill).toMatch(/context only/i)
    expect(skill).toMatch(/never subtracted from the goal/i)
  })

  it('"how am I doing?" and example guidance use the signed eaten-minus-goal difference with under / on target / over', () => {
    expect(skill).toMatch(/signed difference/i)
    expect(skill).toMatch(/eaten minus goal/i)
    expect(skill).toMatch(/under, on target, or over/i)
  })
})
