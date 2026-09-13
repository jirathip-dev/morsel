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

const here = dirname(fileURLToPath(import.meta.url))
const skillPath = join(here, 'food-logging', 'SKILL.md')
const skill = readFileSync(skillPath, 'utf8')

// Double-counting forms: eaten calories minus active burn/energy must never be
// instructed. The noun class spans the natural-language vocabulary for active
// energy (activity, workout, exercise, burned, ...) and the shapes allow the
// interposed words people actually use ("the", "calories", fillers) — so an
// equivalent paraphrase ("subtract your activity calories from the goal",
// "calories eaten minus calories burned", ...) still trips. Bans use word
// boundaries; "eaten vs goal" / "eaten minus goal" prose is the CORRECT
// semantics and does not match any of these.
const NOUN = '(?:active|activity|burn|burned|burns|energy|exercise|workout)'
const STALE_DOUBLE_COUNTING = [
  /\bnet intake\b/i,
  new RegExp(`\\bminus\\s+(?:the\\s+)?(?:calories\\s+)?${NOUN}`, 'i'),
  new RegExp(`\\b(?:subtract|deduct)\\w*(?:\\s+\\w+){0,2}\\s+${NOUN}`, 'i'),
  new RegExp(`\\beaten\\s*[-−–]\\s*(?:the\\s+)?(?:calories\\s+)?${NOUN}`, 'i'),
  /double-?count/i,
]

describe('food-logging skill — TDEE eaten-vs-goal semantics (issue #93)', () => {
  it('bans the stale net intake = eaten − active burn instruction and equivalents', () => {
    for (const re of STALE_DOUBLE_COUNTING) {
      const hit = skill.match(re)
      expect(hit, `stale double-counting wording reintroduced: ${re}` + (hit ? `\n  matched excerpt: ${JSON.stringify(hit[0])}` : '')).toBeNull()
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

describe('food-logging skill — named menus contract (issue #152)', () => {
  it('registers list_menus and teaches one-call create/reuse flows', () => {
    expect(skill).toMatch(/exactly these tools:[\s\S]*?`list_menus`/i)
    expect(skill).toMatch(/read-only \(never write\):[\s\S]*?`list_menus`/i)
    expect(skill).toMatch(/### `list_menus`/)
    expect(skill).toMatch(/pass `menu_name` and omit `items`/i)
    expect(skill).toMatch(/creates the menu from those items AND logs the meal/i)
  })

  it('pins the log_meal menu contract: menu_name optional, items conditional, snapshot semantics', () => {
    expect(skill).toMatch(/menu_name\?: string\s*,\s*\/\/ named-menu log \(issue #152\)/)
    expect(skill).toMatch(/\(at least one item\) is required[\s\S]*?except when `menu_name` names a menu/i)
    expect(skill).toMatch(/menu log is a snapshot copy/i)
    expect(skill).toMatch(/menu_group_id/)
    expect(skill).toMatch(/Editing or[\s\S]*?deleting a menu[\s\S]*?NEVER changes past meals/i)
  })
})

// ---- Correction-flow guidance (issue #171), pinned by issue #206 ----
//
// #171 shipped guidance-only rules — the ordered "Wrong item" procedure
// (get_day -> meals[].items[].item_id -> update_meal_item), the "no separate
// 'list items' tool" rule, and the matching get_day note in docs/MCP_TOOLS.md
// — and no committed gate covered them: the adversarial review proved the
// suite stayed GREEN when the rule bullet was deleted from both mirrors or
// from the root mirror alone. These assertions read the sources beside this
// test (resolved from import.meta.url, never cwd) and are whitespace-flattened
// so a markdown re-wrap cannot break the contract, while deleting the
// procedure, the rule, or the get_day note fails the probe.
const mcpToolsSource = readFileSync(join(here, '..', 'docs', 'MCP_TOOLS.md'), 'utf8')
const pluginSkillBytes = readFileSync(
  join(here, '..', 'plugins', 'morsel', 'skills', 'food-logging', 'SKILL.md'),
)
const skillBytes = readFileSync(skillPath)

// Whitespace-flattened view: re-wrapping is tolerated, deletion is not.
const flatten = (text: string): string => text.replace(/\s+/g, ' ')

// The "Wrong item" correction bullet alone, so the ordered procedure is pinned
// where it lives rather than matched anywhere else in the skill.
function correctionBullet(source: string): string {
  const start = source.search(/^-\s*Wrong item\b/m)
  expect(start, 'the "Wrong item" correction bullet must exist').toBeGreaterThanOrEqual(0)
  const end = source.indexOf('\n- ', start + 1)
  return flatten(source.slice(start, end === -1 ? undefined : end))
}

describe('food-logging skill — correction-flow guidance (issue #171, pinned by #206)', () => {
  it('states the ordered correction procedure get_day -> items[].item_id -> update_meal_item', () => {
    const bullet = correctionBullet(skill)
    expect(bullet).toMatch(/correct an existing item in this order/i)
    const day = bullet.indexOf('`get_day`')
    const item = bullet.search(/items\[\][^;]{0,80}?item_id/)
    const update = bullet.indexOf('update_meal_item')
    expect(day, 'step (a) calls get_day first').toBeGreaterThanOrEqual(0)
    expect(item, 'get_day output carries meals[].items[].item_id').toBeGreaterThan(day)
    expect(update, 'update_meal_item is the last step').toBeGreaterThan(item)
    expect(bullet.slice(update), 'update_meal_item receives that item_id').toMatch(/item_id/)
  })

  it("states the \"no separate 'list items' tool\" rule and that get_day returns item_id", () => {
    const flat = flatten(skill)
    expect(flat).toMatch(/no\s+separate\s+['‘’]list\s+items['‘’]\s+tool/i)
    expect(flat).toMatch(/`get_day`[\s\S]{0,60}?returns\s+`item_id`/i)
  })

  it('docs/MCP_TOOLS.md get_day section carries the matching item-id / no-listing-tool note', () => {
    const start = mcpToolsSource.indexOf('### `get_day`')
    expect(start, 'docs/MCP_TOOLS.md must document get_day').toBeGreaterThanOrEqual(0)
    const next = mcpToolsSource.indexOf('\n### ', start + 1)
    const section = flatten(mcpToolsSource.slice(start, next === -1 ? undefined : next))
    expect(section).toMatch(/`get_day`\s+to\s+enumerate\s+item\s+IDs\s+before\s+`update_meal_item`/i)
    expect(section).toMatch(/no\s+standalone\s+item-listing\s+tool/i)
  })

  it('bundled plugin skill is byte-identical to the root skill', () => {
    expect(
      pluginSkillBytes.equals(skillBytes),
      `plugins/morsel/skills/food-logging/SKILL.md (${pluginSkillBytes.length} B) must be a byte copy of skills/food-logging/SKILL.md (${skillBytes.length} B)`,
    ).toBe(true)
  })
})
