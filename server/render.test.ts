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

const designMd = readFileSync(new URL('../docs/DESIGN.md', import.meta.url), 'utf8')

function summaryWith(overrides: Partial<DashboardRenderSummary>): DashboardRenderSummary {
  return { ...summary, ...overrides }
}

// Goal set, ring ratio 90% (>= 85%, <= 100%): ring-near. Trend days cover
// near (1,900 = 95%), over (2,100) and on (700) in one render.
const nearSummary = summaryWith({
  totals: { ...totals, calories_kcal: 5_400 },
  days: 3,
  startDate: '2026-08-24',
  endDate: '2026-08-26',
  dailyCalories: [
    { date: '2026-08-24', calories_kcal: 1_900 },
    { date: '2026-08-25', calories_kcal: 2_100 },
    { date: '2026-08-26', calories_kcal: 700 },
  ],
})

// Goal set, ring ratio clamped to 1 and totals over goal: ring-over.
const overSummary = summaryWith({
  totals: { ...totals, calories_kcal: 6_300 },
  days: 3,
  startDate: '2026-08-24',
  endDate: '2026-08-26',
  dailyCalories: [
    { date: '2026-08-24', calories_kcal: 1_900 },
    { date: '2026-08-25', calories_kcal: 2_100 },
    { date: '2026-08-26', calories_kcal: 700 },
  ],
})

// No goal: trend bars fall back to trend-under and macro strips paint
// against the day maxima instead of targets.
const underSummary = summaryWith({ goal: undefined })

function luminance(hex: string): number {
  const value = hex.replace('#', '')
  const channel = (i: number): number => {
    const c = parseInt(value.slice(i, i + 2), 16) / 255
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
  }
  return 0.2126 * channel(0) + 0.7152 * channel(2) + 0.0722 * channel(4)
}

function contrastRatio(foreground: string, background: string): number {
  const l1 = luminance(foreground)
  const l2 = luminance(background)
  const [hi, lo] = l1 >= l2 ? [l1, l2] : [l2, l1]
  return (hi + 0.05) / (lo + 0.05)
}

/** Gradient id -> its two rendered stop hexes, parsed from the emitted SVG. */
function svgGradientStops(svg: string): Map<string, string[]> {
  const defs = new Map<string, string[]>()
  for (const m of svg.matchAll(/<linearGradient id="([^"]+)"[^>]*>((?:(?!<\/linearGradient>)[\s\S])*)<\/linearGradient>/g)) {
    const id = m[1]
    const body = m[2]
    if (id === undefined || body === undefined) {
      continue
    }
    const stops: string[] = []
    for (const stop of body.matchAll(/stop-color="#([0-9A-Fa-f]{6})"/g)) {
      const hex = stop[1]
      if (hex !== undefined) {
        stops.push(hex.toUpperCase())
      }
    }
    defs.set(id, stops)
  }
  return defs
}

function referencedGradientIds(...svgs: string[]): Set<string> {
  const referenced = new Set<string>()
  for (const svg of svgs) {
    for (const m of svg.matchAll(/(?:fill|stroke)="url\(#([^"]+)\)"/g)) {
      const id = m[1]
      if (id !== undefined) {
        referenced.add(id)
      }
    }
  }
  return referenced
}

/**
 * Resolve the actual track a gradient paints on, from the rendered geometry:
 * ring-near/on/over stroke the ring track circle; macro-* fills sit on the
 * same-coordinate surface2 track rect; trend-* bars paint on the page bg.
 */
function resolveTrackHexes(svg: string): { ring: string; trend: string; macros: Map<string, string> } {
  const bgMatch = /<svg\b[^>]*>[\s\S]*?<rect\b[^>]*fill="#([0-9A-Fa-f]{6})"/.exec(svg)
  const ringMatch = /<circle\b[^>]*stroke="#([0-9A-Fa-f]{6})"/.exec(svg)
  const rectTracks = new Map<string, string>()
  for (const m of svg.matchAll(/<rect x="([0-9.]+)" y="([0-9.]+)"[^>]*fill="#([0-9A-Fa-f]{6})"/g)) {
    const x = m[1]
    const y = m[2]
    const hex = m[3]
    if (x !== undefined && y !== undefined && hex !== undefined) {
      rectTracks.set(`${x}:${y}`, hex.toUpperCase())
    }
  }
  const macros = new Map<string, string>()
  for (const m of svg.matchAll(/<rect x="([0-9.]+)" y="([0-9.]+)"[^>]*fill="url\(#(macro-[^"]+)\)"/g)) {
    const x = m[1]
    const y = m[2]
    const id = m[3]
    if (x === undefined || y === undefined || id === undefined) {
      continue
    }
    const track = rectTracks.get(`${x}:${y}`)
    if (track !== undefined) {
      macros.set(id, track)
    }
  }
  const bgHex = bgMatch?.[1]
  const ringHex = ringMatch?.[1]
  if (bgHex === undefined || ringHex === undefined) {
    throw new Error('renderer track geometry (page bg rect / ring track circle) was not found')
  }
  return { ring: ringHex.toUpperCase(), trend: bgHex.toUpperCase(), macros }
}

/** The two hexes DESIGN.md documents for the measured amber --grad-carbs treatment. */
function documentedAmberStops(): string[] {
  const match = /--grad-carbs:\s*linear-gradient\([^)]*\)/.exec(designMd)
  if (match === null) {
    throw new Error('DESIGN.md must document the --grad-carbs measured stops')
  }
  const stops: string[] = []
  for (const m of match[0].matchAll(/#([0-9A-Fa-f]{6})/g)) {
    const hex = m[1]
    if (hex !== undefined) {
      stops.push(hex.toUpperCase())
    }
  }
  return stops
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

  it('produces a well-formed SVG using only DESIGN.md palette + documented measured-gradient colors', () => {
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

    // Colors-block scalars plus the measured data-gradient stops DESIGN.md
    // documents for renderer/SVG parity (Charts & washes section).
    const colorsBlock = /^colors:\n([\s\S]*?)^typography:/m.exec(designMd)?.[1] ?? ''
    const allowed = new Set((colorsBlock.match(/#[0-9A-Fa-f]{6}/g) ?? []).map((hex) => hex.toUpperCase()))
    for (const m of designMd.matchAll(/--grad-[a-z-]+:\s*linear-gradient\([^)]*\)/g)) {
      for (const hex of m[0].matchAll(/#[0-9A-Fa-f]{6}/g)) {
        allowed.add(hex[0].toUpperCase())
      }
    }
    const svgColors = rendered.svg.match(/#[0-9A-Fa-f]{6}/g) ?? []
    expect(svgColors.length).toBeGreaterThan(0)
    expect(svgColors.every((color) => allowed.has(color.toUpperCase()))).toBe(true)
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

describe('renderer data-gradient endpoints (Refs #53)', () => {
  const onSvg = renderDashboardSummary(summary).svg
  const nearSvg = renderDashboardSummary(nearSummary).svg
  const overSvg = renderDashboardSummary(overSummary).svg
  const underSvg = renderDashboardSummary(underSummary).svg

  it('holds every gradient endpoint at >=3:1 against its actual track', () => {
    // Defs are emitted unconditionally, so one render carries all ten ids.
    const defs = svgGradientStops(onSvg)
    expect(defs.size, 'the renderer must declare all ten state gradients').toBe(10)

    const tracks = resolveTrackHexes(onSvg)
    const referenced = referencedGradientIds(onSvg, nearSvg, overSvg, underSvg)
    for (const [id, stops] of defs) {
      expect(referenced.has(id), `#${id} must be reachable in at least one dashboard state`).toBe(true)
      expect(stops, `#${id} must declare a start and an end stop`).toHaveLength(2)

      const trackHex = id.startsWith('ring-')
        ? tracks.ring
        : id.startsWith('macro-')
          ? tracks.macros.get(id)
          : tracks.trend
      if (trackHex === undefined) {
        throw new Error(`no track resolved for #${id}`)
      }
      for (let i = 0; i < stops.length; i += 1) {
        const stopHex = stops[i]
        if (stopHex === undefined) {
          throw new Error(`#${id} stop ${String(i)} is missing`)
        }
        const ratio = contrastRatio(stopHex, trackHex)
        expect(
          ratio,
          `#${id} stop ${String(i)} (#${stopHex}) on its track #${trackHex} measures ${ratio.toFixed(2)}:1, below the 3:1 data-graphic gate`
        ).toBeGreaterThanOrEqual(3.0)
      }
    }
  })

  it('pins the amber carbs/near-goal/trend stops to the DESIGN.md measured treatment', () => {
    const defs = svgGradientStops(onSvg)
    const documented = documentedAmberStops()
    expect(documented.length, '--grad-carbs must declare a start and an end stop').toBe(2)
    for (const id of ['ring-near', 'macro-carbs', 'trend-under', 'trend-near']) {
      expect(defs.get(id), `#${id} must use the documented measured amber stops`).toEqual(documented)
    }
  })
})
