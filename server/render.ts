import type { GoalSummary, RenderPayload, Totals } from '../packages/schema/food-types.ts'

const palette = {
  ink: '#20231E',
  inkTwo: '#666A60',
  inkThree: '#9BA095',
  bg: '#FBFAF6',
  surface: '#FFFFFF',
  surfaceTwo: '#F3F1EA',
  line: '#E7E3D8',
  accent: '#F08A2E',
  accentSoft: '#F6E8D8',
  energy: '#F08A2E',
  energySoft: '#F6E8D8',
  over: '#C0483F',
  low: '#8A5514',
  protein: '#C0483F',
  carbs: '#F0A63C',
  fat: '#D46A2E',
}

const monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
]

export const LOW_CONFIDENCE_THRESHOLD = 0.8

export interface DailyCalories {
  date: string
  calories_kcal: number
}

export interface DashboardRenderSummary {
  startDate: string
  endDate: string
  days: number
  totals: Totals
  goal?: GoalSummary
  streakDays: number
  mealCount: number
  dailyCalories: DailyCalories[]
  lowConfidenceItemCount: number
}

interface RangeGoal {
  calories_kcal: number
  protein_g: number
  carbs_g: number
  fat_g: number
}

interface MacroRow {
  label: string
  value: number
  target?: number
  gradient: string
}

function formatNumber(value: number): string {
  const rounded = Math.round(value * 10) / 10
  return rounded.toLocaleString('en-US', { maximumFractionDigits: 1 })
}

function svgNumber(value: number): string {
  return String(value)
}

function formatDate(date: string): string {
  const month = Number(date.slice(5, 7))
  const day = Number(date.slice(8, 10))
  return `${monthNames[month - 1] ?? date} ${String(day)}, ${date.slice(0, 4)}`
}

function dateLabel(summary: DashboardRenderSummary): string {
  return summary.startDate === summary.endDate
    ? formatDate(summary.startDate)
    : `${formatDate(summary.startDate)} - ${formatDate(summary.endDate)}`
}

function escapeXml(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;')
}

function rangeGoal(goal: GoalSummary | undefined, days: number): RangeGoal | undefined {
  if (goal === undefined) {
    return undefined
  }
  return {
    calories_kcal: goal.calorie_target_kcal * days,
    protein_g: goal.protein_g * days,
    carbs_g: goal.carbs_g * days,
    fat_g: goal.fat_g * days,
  }
}

function plural(value: number, singular: string, pluralValue = `${singular}s`): string {
  return value === 1 ? singular : pluralValue
}

function renderMarkdown(summary: DashboardRenderSummary, goal: RangeGoal | undefined): string {
  const totalCalories = summary.totals.calories_kcal
  const averageCalories = totalCalories / summary.days
  const lines = [`# Morsel - ${dateLabel(summary)}`]

  if (summary.mealCount === 0) {
    lines.push(summary.days === 1 ? 'No meals logged for this day.' : 'No meals logged in this range.')
  }

  if (goal === undefined) {
    lines.push(`Calories: **${formatNumber(totalCalories)} kcal** - ${formatNumber(averageCalories)} kcal/day average`)
    lines.push('Goal: not set')
  } else {
    lines.push(`Calories: **${formatNumber(totalCalories)} / ${formatNumber(goal.calories_kcal)} kcal** - ${formatNumber(averageCalories)} kcal/day average`)
    lines.push(`Goal: ${formatNumber(goal.calories_kcal / summary.days)} kcal/day (${summary.goal?.source ?? 'unknown'})`)
    const balance = goal.calories_kcal - totalCalories
    lines.push(balance >= 0
      ? `Remaining: **${formatNumber(balance)} kcal** in range`
      : `Over goal: **${formatNumber(-balance)} kcal** in range`)
  }

  lines.push(
    '',
    '| Macro | Eaten | Goal |',
    '| --- | ---: | ---: |',
    `| Protein | ${formatNumber(summary.totals.protein_g)} g | ${goal === undefined ? '—' : `${formatNumber(goal.protein_g)} g`} |`,
    `| Carbs | ${formatNumber(summary.totals.carbs_g)} g | ${goal === undefined ? '—' : `${formatNumber(goal.carbs_g)} g`} |`,
    `| Fat | ${formatNumber(summary.totals.fat_g)} g | ${goal === undefined ? '—' : `${formatNumber(goal.fat_g)} g`} |`,
  )

  if (summary.lowConfidenceItemCount > 0) {
    lines.push(
      '',
      `Review: **needs-review** - ${formatNumber(summary.lowConfidenceItemCount)} low-confidence ${plural(summary.lowConfidenceItemCount, 'item')}.`,
    )
  }
  lines.push('', `Streak: **${formatNumber(summary.streakDays)} ${plural(summary.streakDays, 'day')}**`)
  return lines.join('\n')
}

function clamp(value: number): number {
  return Math.min(1, Math.max(0, value))
}

function renderSvg(summary: DashboardRenderSummary, goal: RangeGoal | undefined): string {
  const showTrend = summary.days > 1
  const trendEntries = summary.dailyCalories.slice(-7)
  const height = showTrend ? 470 : 300
  const totalCalories = summary.totals.calories_kcal
  const goalPerDay = summary.goal?.calorie_target_kcal
  const goalCalories = goal?.calories_kcal
  const ringRatio = goalCalories === undefined || goalCalories <= 0 ? 0 : clamp(totalCalories / goalCalories)
  const circumference = 2 * Math.PI * 60
  const ringDash = circumference * ringRatio
  const ringGradient = goalCalories !== undefined && totalCalories > goalCalories
    ? 'ring-over'
    : goalCalories !== undefined && totalCalories >= goalCalories * 0.85
      ? 'ring-near'
      : 'ring-on'
  const macroRows: MacroRow[] = [
    { label: 'Protein', value: summary.totals.protein_g, target: goal?.protein_g, gradient: 'macro-protein' },
    { label: 'Carbs', value: summary.totals.carbs_g, target: goal?.carbs_g, gradient: 'macro-carbs' },
    { label: 'Fat', value: summary.totals.fat_g, target: goal?.fat_g, gradient: 'macro-fat' },
  ]
  const macroMaximum = Math.max(
    ...macroRows.map((row) => row.value),
    ...macroRows.map((row) => row.target ?? 0),
    1,
  )
  const parts = [
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 720 ${svgNumber(height)}" role="img" aria-label="Morsel nutrition summary for ${escapeXml(dateLabel(summary))}">`,
    '<defs>',
    `<linearGradient id="ring-on" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="${palette.accent}"/><stop offset="100%" stop-color="${palette.fat}"/></linearGradient>`,
    `<linearGradient id="ring-near" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="${palette.energy}"/><stop offset="100%" stop-color="${palette.accent}"/></linearGradient>`,
    `<linearGradient id="ring-over" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="${palette.energy}"/><stop offset="100%" stop-color="${palette.over}"/></linearGradient>`,
    `<linearGradient id="macro-protein" x1="0" y1="0" x2="1" y2="0"><stop offset="0%" stop-color="${palette.protein}"/><stop offset="100%" stop-color="${palette.accent}"/></linearGradient>`,
    `<linearGradient id="macro-carbs" x1="0" y1="0" x2="1" y2="0"><stop offset="0%" stop-color="${palette.carbs}"/><stop offset="100%" stop-color="${palette.energy}"/></linearGradient>`,
    `<linearGradient id="macro-fat" x1="0" y1="0" x2="1" y2="0"><stop offset="0%" stop-color="${palette.fat}"/><stop offset="100%" stop-color="${palette.accent}"/></linearGradient>`,
    `<linearGradient id="trend-under" x1="0" y1="0" x2="1" y2="0"><stop offset="0%" stop-color="${palette.fat}"/><stop offset="100%" stop-color="${palette.accent}"/></linearGradient>`,
    `<linearGradient id="trend-on" x1="0" y1="0" x2="1" y2="0"><stop offset="0%" stop-color="${palette.accent}"/><stop offset="100%" stop-color="${palette.fat}"/></linearGradient>`,
    `<linearGradient id="trend-near" x1="0" y1="0" x2="1" y2="0"><stop offset="0%" stop-color="${palette.energy}"/><stop offset="100%" stop-color="${palette.carbs}"/></linearGradient>`,
    `<linearGradient id="trend-over" x1="0" y1="0" x2="1" y2="0"><stop offset="0%" stop-color="${palette.energy}"/><stop offset="100%" stop-color="${palette.over}"/></linearGradient>`,
    '</defs>',
    `<rect width="720" height="${svgNumber(height)}" fill="${palette.bg}"/>`,
    `<text x="24" y="32" fill="${palette.ink}" font-family="system-ui, sans-serif" font-size="20" font-weight="700">Morsel</text>`,
    `<text x="696" y="31" text-anchor="end" fill="${palette.inkTwo}" font-family="ui-monospace, SFMono-Regular, monospace" font-size="12">${escapeXml(dateLabel(summary))}</text>`,
    `<rect x="24" y="54" width="672" height="218" rx="12" fill="${palette.surface}" stroke="${palette.line}"/>`,
    `<circle cx="116" cy="154" r="60" fill="none" stroke="${palette.surfaceTwo}" stroke-width="12"/>`,
    `<circle cx="116" cy="154" r="60" fill="none" stroke="url(#${ringGradient})" stroke-width="12" stroke-linecap="round" stroke-dasharray="${svgNumber(ringDash)} ${svgNumber(circumference)}" transform="rotate(-90 116 154)"/>`,
    `<text x="116" y="151" text-anchor="middle" fill="${palette.ink}" font-family="ui-monospace, SFMono-Regular, monospace" font-size="22" font-weight="700">${formatNumber(totalCalories)}</text>`,
    `<text x="116" y="172" text-anchor="middle" fill="${palette.inkTwo}" font-family="system-ui, sans-serif" font-size="11">kcal eaten</text>`,
    `<text x="116" y="194" text-anchor="middle" fill="${palette.inkThree}" font-family="ui-monospace, SFMono-Regular, monospace" font-size="10">${goalCalories === undefined ? 'goal not set' : `${formatNumber(goalCalories)} kcal goal`}</text>`,
    `<text x="330" y="86" fill="${palette.inkThree}" font-family="system-ui, sans-serif" font-size="11" font-weight="700">CALORIES</text>`,
    `<text x="330" y="108" fill="${palette.ink}" font-family="ui-monospace, SFMono-Regular, monospace" font-size="17" font-weight="700">${formatNumber(totalCalories)} / ${goalCalories === undefined ? '-' : formatNumber(goalCalories)} kcal</text>`,
  ]

  if (goalCalories !== undefined) {
    const balance = goalCalories - totalCalories
    parts.push(`<text x="330" y="126" fill="${balance >= 0 ? palette.inkTwo : palette.over}" font-family="ui-monospace, SFMono-Regular, monospace" font-size="11">${balance >= 0 ? `${formatNumber(balance)} kcal left` : `${formatNumber(-balance)} kcal over`}</text>`)
  } else {
    parts.push(`<text x="330" y="126" fill="${palette.inkTwo}" font-family="system-ui, sans-serif" font-size="11">Set a goal to compare progress</text>`)
  }

  parts.push(`<text x="330" y="148" fill="${palette.inkThree}" font-family="system-ui, sans-serif" font-size="11" font-weight="700">MACROS</text>`)
  macroRows.forEach((row, index) => {
    const y = 164 + index * 26
    const fraction = row.target === undefined
      ? row.value / macroMaximum
      : clamp(row.value / Math.max(row.target, 1))
    const valueText = row.target === undefined
      ? `${formatNumber(row.value)} g`
      : `${formatNumber(row.value)} / ${formatNumber(row.target)} g`
    parts.push(
      `<text x="330" y="${svgNumber(y)}" fill="${palette.inkTwo}" font-family="ui-monospace, SFMono-Regular, monospace" font-size="10">${row.label}</text>`,
      `<rect x="390" y="${svgNumber(y - 9)}" width="178" height="6" rx="3" fill="${palette.surfaceTwo}"/>`,
      `<rect x="390" y="${svgNumber(y - 9)}" width="${svgNumber(178 * fraction)}" height="6" rx="3" fill="url(#${row.gradient})"/>`,
      `<text x="680" y="${svgNumber(y)}" text-anchor="end" fill="${palette.ink}" font-family="ui-monospace, SFMono-Regular, monospace" font-size="10">${valueText}</text>`,
    )
  })

  if (summary.mealCount === 0) {
    parts.push(`<text x="330" y="250" fill="${palette.inkTwo}" font-family="system-ui, sans-serif" font-size="11">No meals logged</text>`)
  }
  if (summary.lowConfidenceItemCount > 0) {
    parts.push(
      `<rect x="330" y="235" width="336" height="24" rx="6" fill="${palette.energySoft}"/>`,
      `<text x="342" y="251" fill="${palette.low}" font-family="ui-monospace, SFMono-Regular, monospace" font-size="10">needs-review - ${formatNumber(summary.lowConfidenceItemCount)} low-confidence ${plural(summary.lowConfidenceItemCount, 'item')}</text>`,
    )
  }

  if (showTrend) {
    const chartX = 54
    const chartY = 336
    const chartWidth = 612
    const chartHeight = 96
    const dailyGoal = goalPerDay
    const chartMaximum = Math.max(...trendEntries.map((entry) => entry.calories_kcal), dailyGoal ?? 0, 1)
    parts.push(
      `<text x="24" y="305" fill="${palette.ink}" font-family="system-ui, sans-serif" font-size="14" font-weight="700">Daily calories (last 7 days)</text>`,
      `<line x1="${svgNumber(chartX)}" y1="${svgNumber(chartY + chartHeight)}" x2="${svgNumber(chartX + chartWidth)}" y2="${svgNumber(chartY + chartHeight)}" stroke="${palette.line}"/>`,
    )
    if (dailyGoal !== undefined) {
      const goalY = chartY + chartHeight - (dailyGoal / chartMaximum) * chartHeight
      parts.push(
        `<line x1="${svgNumber(chartX)}" y1="${svgNumber(goalY)}" x2="${svgNumber(chartX + chartWidth)}" y2="${svgNumber(goalY)}" stroke="${palette.inkThree}" stroke-dasharray="4 4"/>`,
        `<text x="${svgNumber(chartX + chartWidth)}" y="${svgNumber(goalY - 5)}" text-anchor="end" fill="${palette.inkThree}" font-family="ui-monospace, SFMono-Regular, monospace" font-size="9">${formatNumber(dailyGoal)} goal</text>`,
      )
    }
    if (trendEntries.length === 0) {
      parts.push(`<text x="${svgNumber(chartX)}" y="${svgNumber(chartY + 42)}" fill="${palette.inkTwo}" font-family="system-ui, sans-serif" font-size="11">No daily data</text>`)
    } else {
      const slotWidth = chartWidth / trendEntries.length
      trendEntries.forEach((entry, index) => {
        const barWidth = Math.max(8, slotWidth - 12)
        const barHeight = (entry.calories_kcal / chartMaximum) * chartHeight
        const barX = chartX + index * slotWidth + (slotWidth - barWidth) / 2
        const barY = chartY + chartHeight - barHeight
        const gradient = dailyGoal === undefined
          ? 'trend-under'
          : entry.calories_kcal > dailyGoal
            ? 'trend-over'
            : entry.calories_kcal >= dailyGoal * 0.85
              ? 'trend-near'
              : 'trend-on'
        parts.push(
          `<rect x="${svgNumber(barX)}" y="${svgNumber(barY)}" width="${svgNumber(barWidth)}" height="${svgNumber(barHeight)}" rx="4" fill="url(#${gradient})"/>`,
          `<text x="${svgNumber(barX + barWidth / 2)}" y="${svgNumber(chartY + chartHeight + 16)}" text-anchor="middle" fill="${palette.inkTwo}" font-family="ui-monospace, SFMono-Regular, monospace" font-size="9">${escapeXml(entry.date.slice(5))}</text>`,
        )
      })
    }
  }

  parts.push('</svg>')
  return parts.join('')
}

export function renderDashboardSummary(summary: DashboardRenderSummary): RenderPayload {
  const goal = rangeGoal(summary.goal, summary.days)
  return {
    markdown: renderMarkdown(summary, goal),
    svg: renderSvg(summary, goal),
  }
}
