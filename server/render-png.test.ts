import { inflateSync } from 'node:zlib'
import { describe, expect, it } from 'vitest'
import type { GoalSummary, Totals } from '../packages/schema/food-types.ts'
import { renderDashboardSummary, type DashboardRenderSummary } from './render.ts'
import { rasterizeDashboardSvg } from './render-png.ts'

// This suite pins the SVG->PNG rasterizer (issue #158): the dashboard SVG is
// the source of truth and the PNG must render the SAME dashboard at 2x the
// 720-wide viewBox. All assertions are pixel-level against a tiny dependency-
// free PNG decoder (node:zlib only), never text pixels (font availability
// differs per host) and never exact cross-host pixels (font rasterization
// varies) — flat palette fills and gradient-family regions only.

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

const daySummary: DashboardRenderSummary = {
  startDate: '2026-08-25',
  endDate: '2026-08-25',
  days: 1,
  totals,
  goal,
  streakDays: 1,
  mealCount: 1,
  dailyCalories: [{ date: '2026-08-25', calories_kcal: 700 }],
  lowConfidenceItemCount: 0,
}

// Goal unset: ring is not painted and trend bars fall back to trend-under
// (mustard gradient #B07A13 -> #875A02), which is what the band scan looks
// for below.
const weekSummary: DashboardRenderSummary = {
  startDate: '2026-08-19',
  endDate: '2026-08-25',
  days: 7,
  totals,
  goal: undefined,
  streakDays: 3,
  mealCount: 7,
  dailyCalories: [
    { date: '2026-08-19', calories_kcal: 1_600 },
    { date: '2026-08-20', calories_kcal: 2_000 },
    { date: '2026-08-21', calories_kcal: 1_200 },
    { date: '2026-08-22', calories_kcal: 1_900 },
    { date: '2026-08-23', calories_kcal: 700 },
    { date: '2026-08-24', calories_kcal: 1_500 },
    { date: '2026-08-25', calories_kcal: 1_400 },
  ],
  lowConfidenceItemCount: 0,
}

const PNG_SIGNATURE = Uint8Array.of(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)

interface DecodedPng {
  width: number
  height: number
  rgba: Uint8Array
}

function byteAt(view: DataView, index: number): number {
  return view.getUint8(index)
}

function asciiAt(bytes: Uint8Array, offset: number, length: number): string {
  let text = ''
  for (let index = 0; index < length; index += 1) {
    text += String.fromCharCode(byteAt(new DataView(bytes.buffer, bytes.byteOffset), offset + index))
  }
  return text
}

/** Minimal PNG decoder: 8-bit, non-interlaced, color types 0/2/6. */
function decodePng(bytes: Uint8Array): DecodedPng {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  if (bytes.length < 33) {
    throw new Error('png too short')
  }
  if (bytes.slice(0, 8).some((value, index) => value !== PNG_SIGNATURE[index])) {
    throw new Error('png signature missing')
  }
  const width = view.getUint32(16)
  const height = view.getUint32(20)
  const bitDepth = byteAt(view, 24)
  const colorType = byteAt(view, 25)
  const interlace = byteAt(view, 28)
  if (bitDepth !== 8 || interlace !== 0) {
    throw new Error(`unsupported png format: bit depth ${String(bitDepth)}, interlace ${String(interlace)}`)
  }
  const channels = colorType === 6 ? 4 : colorType === 2 ? 3 : colorType === 0 ? 1 : 0
  if (channels === 0) {
    throw new Error(`unsupported png color type ${String(colorType)}`)
  }
  let offset = 8
  const idat: number[] = []
  for (;;) {
    if (offset + 12 > bytes.length) {
      throw new Error('png chunk table malformed')
    }
    const length = view.getUint32(offset)
    const type = asciiAt(bytes, offset + 4, 4)
    if (type === 'IEND') {
      break
    }
    if (offset + 12 + length > bytes.length) {
      throw new Error('png chunk overruns file')
    }
    if (type === 'IDAT') {
      for (let index = 0; index < length; index += 1) {
        idat.push(byteAt(view, offset + 8 + index))
      }
    }
    offset += 12 + length
  }
  const stride = width * channels
  const filtered = inflateSync(Uint8Array.from(idat))
  const rgba = new Uint8Array(height * stride)
  let input = 0
  for (let row = 0; row < height; row += 1) {
    const filter = filtered[input] ?? 0
    input += 1
    const rowStart = row * stride
    for (let column = 0; column < stride; column += 1) {
      const raw = filtered[input] ?? 0
      input += 1
      const left = column >= channels ? rgba[rowStart + column - channels] ?? 0 : 0
      const above = row > 0 ? rgba[rowStart - stride + column] ?? 0 : 0
      const aboveLeft = row > 0 && column >= channels ? rgba[rowStart - stride + column - channels] ?? 0 : 0
      let value = raw
      if (filter === 1) {
        value += left
      } else if (filter === 2) {
        value += above
      } else if (filter === 3) {
        value += Math.floor((left + above) / 2)
      } else if (filter === 4) {
        const predicted = left + above - aboveLeft
        const leftDistance = Math.abs(predicted - left)
        const aboveDistance = Math.abs(predicted - above)
        const aboveLeftDistance = Math.abs(predicted - aboveLeft)
        const nearest = leftDistance <= aboveDistance && leftDistance <= aboveLeftDistance
          ? left
          : aboveDistance <= aboveLeftDistance
            ? above
            : aboveLeft
        value += nearest
      }
      rgba[rowStart + column] = value & 0xff
    }
  }
  return { width, height, rgba }
}

function pixel(decoded: DecodedPng, x: number, y: number): [number, number, number, number] {
  const index = (y * decoded.width + x) * 4
  const { rgba } = decoded
  return [rgba[index] ?? 0, rgba[index + 1] ?? 0, rgba[index + 2] ?? 0, rgba[index + 3] ?? 0]
}

function countPixels(
  decoded: DecodedPng,
  region: { x0: number; y0: number; x1: number; y1: number },
  matches: (red: number, green: number, blue: number) => boolean,
): number {
  let count = 0
  for (let y = region.y0; y < region.y1; y += 1) {
    for (let x = region.x0; x < region.x1; x += 1) {
      const [red, green, blue] = pixel(decoded, x, y)
      if (matches(red, green, blue)) {
        count += 1
      }
    }
  }
  return count
}

function expectPngRaster(decoded: DecodedPng): void {
  expect(decoded.rgba.length).toBe(decoded.width * decoded.height * 4)
}

describe('render-png rasterizer', () => {
  it('rasterizes the single-day dashboard SVG at 2x to a deterministic PNG with the paper palette and ring', async () => {
    const svg = renderDashboardSummary(daySummary).svg
    const first = await rasterizeDashboardSvg(svg)
    const second = await rasterizeDashboardSvg(svg)
    expect(first.slice(0, 8)).toEqual(PNG_SIGNATURE)
    const decoded = decodePng(first)
    expectPngRaster(decoded)
    // Same input -> same bytes (no timestamps or randomness in the raster).
    expect(second).toEqual(first)
    // 2x the 720x300 single-day viewBox.
    expect(decoded.width).toBe(1440)
    expect(decoded.height).toBe(600)
    // Paper background at the bottom-right (nothing draws at 700,295 in 1x).
    expect(pixel(decoded, 1_400, 590).slice(0, 3)).toEqual([255, 247, 232])
    // Card surface at 1x (40,60) sits inside the rounded card, outside the ring.
    expect(pixel(decoded, 80, 120).slice(0, 3)).toEqual([255, 252, 245])
    // Ring band (1x x 50..182, y 88..220) holds leaf->forest gradient pixels:
    // totals 700 vs 2000 goal paints a ring-on arc.
    const ringPixels = countPixels(
      decoded,
      { x0: 100, y0: 176, x1: 364, y1: 440 },
      (red, green, blue) => green > 90 && green >= red + 5 && green >= blue + 5 && blue < 120,
    )
    expect(ringPixels).toBeGreaterThan(800)
    // Protein macro bar (1x x 390..443, y 155..161) holds coral->over pixels.
    const proteinBarPixels = countPixels(
      decoded,
      { x0: 780, y0: 305, x1: 900, y1: 330 },
      (red, green, blue) => red > 140 && green < 100 && blue < 80 && red >= green + 50,
    )
    expect(proteinBarPixels).toBeGreaterThan(150)
  })

  it('rasterizes the week dashboard SVG with the trend at 1440x940 deterministically', async () => {
    const svg = renderDashboardSummary(weekSummary).svg
    const first = await rasterizeDashboardSvg(svg)
    const second = await rasterizeDashboardSvg(svg)
    expect(second).toEqual(first)
    const decoded = decodePng(first)
    expectPngRaster(decoded)
    expect(decoded.width).toBe(1440)
    expect(decoded.height).toBe(940)
    // Trend band (1x x 54..666, y 336..432) holds mustard gradient bars
    // (trend-under #B07A13 -> #875A02) when no goal is set.
    const trendPixels = countPixels(
      decoded,
      { x0: 120, y0: 664, x1: 1_320, y1: 860 },
      (red, green, blue) => red > 120 && green >= 60 && green <= 150 && blue < 60 && red >= green + 30,
    )
    expect(trendPixels).toBeGreaterThan(300)
  })
})
