// Issue #229 — rasterise the approved Variant A SVG studies into the bundled
// app PNGs. Run from the repository root:
//
//   node docs/evidence/issue-229-native-parity-a/tools/render-a-art.mjs
//
// Inputs : docs/evidence/issue-229-native-parity-a/reference/assets/a-*.svg
//          (the pinned design source, imported byte-for-byte — see ../README.md)
// Outputs: app/Resources/JournalArt/a-*.png at 224×224 (4× the 56pt row
//          placement and ≥3× the 64pt summary placement, so every bundled
//          placement downsamples)
//
// The repo's own @resvg/resvg-js dependency renders deterministically (no
// timestamps): re-running reproduces identical bytes.
import { Resvg } from '@resvg/resvg-js'
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { join } from 'node:path'

const SRC_DIR = 'docs/evidence/issue-229-native-parity-a/reference/assets'
const OUT_DIR = 'app/Resources/JournalArt'
const THEMES = ['paper', 'night']
const STUDIES = ['focaccia', 'mortadella', 'stracciatella', 'vegetables', 'unknown']
const SIZE = 224

/// The A studies carry a CSS custom property on the root element
/// (`style="--line:#…"`) consumed as `var(--line)`. resvg does not resolve
/// custom properties, so SUBSTITUTE the declared value first — exactly the
/// computed value the browser used (the declaration is literal in the source,
/// not inherited or cascaded from anywhere else).
function resolveVars(svg) {
  const declared = new Map()
  for (const match of svg.matchAll(/--([\w-]+)\s*:\s*([^;"]+)/g)) {
    declared.set(match[1], match[2].trim())
  }
  let out = svg
  for (const [name, value] of declared) {
    out = out.replaceAll(`var(--${name})`, value)
  }
  const unresolved = out.match(/var\(--[\w-]+\)/)
  if (unresolved) throw new Error(`unresolved CSS variable ${unresolved[0]}`)
  return out
}

if (!existsSync(SRC_DIR) || !existsSync('app/Resources')) {
  throw new Error('run this from the repository root')
}
mkdirSync(OUT_DIR, { recursive: true })
for (const theme of THEMES) {
  for (const study of STUDIES) {
    const name = `a-${theme}-${study}`
    const svg = resolveVars(readFileSync(join(SRC_DIR, `${name}.svg`), 'utf8'))
    const png = new Resvg(svg, { fitTo: { mode: 'width', value: SIZE } }).render().asPng()
    writeFileSync(join(OUT_DIR, `${name}.png`), png)
    console.log(`${name}.png ${png.length} bytes`)
  }
}
