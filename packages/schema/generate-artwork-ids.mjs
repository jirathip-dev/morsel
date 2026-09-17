// Run: node packages/schema/generate-artwork-ids.mjs
// --check verifies both snapshots; --sql prints constraints for a NEW migration.
// Never regenerate/rewrite an applied migration when the catalog grows.
//
// Issue #284: the same pass also emits `artwork-catalog.ts` — the published
// catalog projected for write-time matching (id, category, kind and the
// normalized name/alias terms). The server resolves an omitted artwork_id
// from these terms, so the vocabulary stays generated from the shipped
// catalog: adding a name here is never a hand edit.
import { readFileSync, writeFileSync } from 'node:fs'
import assert from 'node:assert/strict'

const catalog = JSON.parse(readFileSync(new URL('../../app/Resources/FoodArt/catalog.json', import.meta.url), 'utf8'))
const ids = catalog.assets.map((asset) => asset.id).sort()
assert(ids.length > 0 && new Set(ids).size === ids.length)
assert(ids.every((id) => /^[a-z][a-z0-9-]*$/.test(id)))
const output = `// Generated from app/Resources/FoodArt/catalog.json; do not edit by hand.\n// Regenerate: node packages/schema/generate-artwork-ids.mjs\nexport const ArtworkIdValues = [\n${ids.map((id) => `  '${id}',`).join('\n')}\n] as const\n`
const target = new URL('./artwork-ids.ts', import.meta.url)

// Matching key: trimmed, lowercased, inner whitespace collapsed. Locale
// independent, and byte-identical to the server resolver's normalization so a
// generated term is directly comparable to a normalized logged name.
const normalize = (text) => text.toLowerCase().split(/\s+/).filter(Boolean).join(' ')
assert(normalize('  Iced   Americano ') === 'iced americano')

const termRows = catalog.assets.map((asset) => {
  const terms = []
  for (const term of [asset.name, ...(asset.aliases ?? [])]) {
    const normalized = normalize(term)
    assert(normalized.length > 0, `empty artwork term on ${asset.id}`)
    if (!terms.includes(normalized)) terms.push(normalized)
  }
  assert(terms.length > 0)
  assert(['food', 'fallback'].includes(asset.kind), `unknown artwork kind on ${asset.id}`)
  return `  { id: '${asset.id}', category: '${asset.category}', kind: '${asset.kind}', terms: [${terms.map((term) => JSON.stringify(term)).join(', ')}] },`
}).join('\n')
const catalogOutput = [
  '// Generated from app/Resources/FoodArt/catalog.json; do not edit by hand.',
  '// Regenerate: node packages/schema/generate-artwork-ids.mjs',
  '//',
  '// Issue #284 — the published catalog projected for write-time identity',
  '// resolution: every asset ID, its category, its kind, and the normalized',
  '// published name/alias terms the resolver matches a logged name against.',
  'export type ArtworkCatalogAsset = {',
  '  readonly id: string',
  '  readonly category: string',
  "  readonly kind: 'food' | 'fallback'",
  '  readonly terms: readonly string[]',
  '}',
  '',
  'export const ArtworkCatalog: readonly ArtworkCatalogAsset[] = [',
  termRows,
  ']',
  '',
].join('\n')
const catalogTarget = new URL('./artwork-catalog.ts', import.meta.url)

if (process.argv.includes('--sql')) {
  for (const table of ['meal_items', 'menu_items']) {
    console.log(`alter table public.${table} add constraint ${table}_artwork_id_published\n  check (artwork_id in (${ids.map((id) => `'${id}'`).join(', ')}));`)
  }
} else if (process.argv.includes('--check')) {
  assert.equal(readFileSync(target, 'utf8'), output, 'artwork ID snapshot drift; regenerate it')
  assert.equal(readFileSync(catalogTarget, 'utf8'), catalogOutput, 'artwork catalog snapshot drift; regenerate it')
} else {
  writeFileSync(target, output)
  writeFileSync(catalogTarget, catalogOutput)
}
