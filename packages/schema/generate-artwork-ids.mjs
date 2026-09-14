// Run: node packages/schema/generate-artwork-ids.mjs
// --check verifies the snapshot; --sql prints constraints for a NEW migration.
// Never regenerate/rewrite an applied migration when the catalog grows.
import { readFileSync, writeFileSync } from 'node:fs'
import assert from 'node:assert/strict'

const catalog = JSON.parse(readFileSync(new URL('../../app/Resources/FoodArt/catalog.json', import.meta.url), 'utf8'))
const ids = catalog.assets.map((asset) => asset.id).sort()
assert(ids.length > 0 && new Set(ids).size === ids.length)
assert(ids.every((id) => /^[a-z][a-z0-9-]*$/.test(id)))
const output = `// Generated from app/Resources/FoodArt/catalog.json; do not edit by hand.\n// Regenerate: node packages/schema/generate-artwork-ids.mjs\nexport const ArtworkIdValues = [\n${ids.map((id) => `  '${id}',`).join('\n')}\n] as const\n`
const target = new URL('./artwork-ids.ts', import.meta.url)
if (process.argv.includes('--sql')) {
  for (const table of ['meal_items', 'menu_items']) {
    console.log(`alter table public.${table} add constraint ${table}_artwork_id_published\n  check (artwork_id in (${ids.map((id) => `'${id}'`).join(', ')}));`)
  }
} else if (process.argv.includes('--check')) {
  assert.equal(readFileSync(target, 'utf8'), output, 'artwork ID snapshot drift; regenerate it')
} else {
  writeFileSync(target, output)
}
