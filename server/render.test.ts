import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import type { GoalSummary, Totals } from '../packages/schema/food-types.js'
import { renderDashboardSummary, type DashboardRenderSummary } from './render.js'

const goal: GoalSummary = {
  calorie_target_kcal: 2_000,
  protein_g: 150,
  carbs_g: 200,
  fat_g: 70,
  source: 'manual',
}

const totals: Totals = {
  calories_kcal: 700,
  protein_g: 45,
  carbs_g: 50,
  fat_g: 20,
}

const summary: DashboardRenderSummary = {
  startDate: '2026-08-24',
  endDate: '2026-08-25',
  days: 2,
  totals,
  goal,
  streakDays: 2,
  mealCount: 2,
  dailyCalories: [
    { date: '2026-08-24', calories_kcal: 400 },
    { date: '2026-08-25', calories_kcal: 300 },
  ],
  lowConfidenceItemCount: 1,
}

describe('in-chat dashboard renderer', () => {
  it('includes totals versus range goals, macro table, streak, and review marker', () => {
    const rendered = renderDashboardSummary(summary)

    expect(rendered.markdown).toContain('700 / 4,000 kcal')
    expect(rendered.markdown).toContain('| Protein | 45 g | 300 g |')
    expect(rendered.markdown).toContain('Streak: **2 days**')
    expect(rendered.markdown).toContain('needs-review')
    expect(rendered.svg).toContain('needs-review')
    expect(rendered.svg).toContain('Daily calories')
  })

  it('produces a well-formed SVG with only DESIGN.md palette colors', () => {
    const rendered = renderDashboardSummary(summary)
    expect(rendered.svg).toMatch(/^<svg\b[\s\S]*<\/svg>$/)
    expect(rendered.svg).not.toMatch(/&(?!amp;|lt;|gt;|quot;|apos;)/)

    const tags = [...rendered.svg.matchAll(/<\/?([A-Za-z][\w:.-]*)\b[^>]*>/g)]
    const stack: string[] = []
    for (const tag of tags) {
      const fullTag = tag[0]
      const name = tag[1]
      if (name === undefined) {
        throw new Error('SVG tag name was not captured')
      }
      if (fullTag.startsWith('</')) {
        expect(stack.pop()).toBe(name)
      } else if (!fullTag.endsWith('/>')) {
        stack.push(name)
      }
    }
    expect(stack).toEqual([])

    const design = readFileSync(new URL('../docs/DESIGN.md', import.meta.url), 'utf8')
    const colorsBlock = /^colors:\n([\s\S]*?)^typography:/m.exec(design)?.[1] ?? ''
    const palette = new Set(colorsBlock.match(/#[0-9A-Fa-f]{6}/g) ?? [])
    const svgColors = rendered.svg.match(/#[0-9A-Fa-f]{6}/g) ?? []
    expect(svgColors.length).toBeGreaterThan(0)
    expect(svgColors.every((color) => palette.has(color))).toBe(true)
  })

  it('renders an explicit empty state without invented values', () => {
    const empty: DashboardRenderSummary = {
      startDate: '2026-08-25',
      endDate: '2026-08-25',
      days: 1,
      totals: { calories_kcal: 0, protein_g: 0, carbs_g: 0, fat_g: 0 },
      streakDays: 0,
      mealCount: 0,
      dailyCalories: [{ date: '2026-08-25', calories_kcal: 0 }],
      lowConfidenceItemCount: 0,
    }
    const rendered = renderDashboardSummary(empty)

    expect(rendered.markdown).toContain('No meals logged')
    expect(rendered.markdown).toContain('Goal: not set')
    expect(rendered.svg).toContain('No meals logged')
    expect(rendered.markdown).not.toContain('undefined')
    expect(rendered.svg).not.toContain('NaN')
  })
})
