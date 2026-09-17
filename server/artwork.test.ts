import { describe, expect, it } from 'vitest'
import { ArtworkIdValues } from '../packages/schema/artwork-ids.ts'
import { ArtworkCatalog, type ArtworkCatalogAsset } from '../packages/schema/artwork-catalog.ts'
import { normalizeArtworkTerm, resolveArtworkIdentity } from './artwork.ts'

// Issue #284 — the write-time resolution contract.
//
// Every positive expectation below is a case the committed native resolver
// already asserts (app/Tests/MorselTests/FoodArtworkMatcherClosureTests.swift,
// including its #288 secondary-phrase class, plus the #260/#288 evidence
// tables). The server port must reach the SAME identity the renderer derives
// from that name, because a stored identity outranks the renderer's name path
// (`JournalRowArtwork.resolve`): agreement is what keeps a write from
// shadowing better art, and a name this module cannot identify is left
// unwritten (null) rather than forced onto a fallback identity.
//
// These are behavioural checks of the resolver, not of a source string.

const descriptorPositives: Array<[string, string]> = [
  // The owner's own row (issue #284) and the descriptive forms agents write.
  ['Iced americano (black, no sugar)', 'coffee'],
  ['Americano (black, no sugar, homemade)', 'coffee'],
  ['white rice', 'jasmine-rice'],
  ['black coffee', 'coffee'],
  ['linguine', 'pasta'],
  ['White rice, cooked (half portion)', 'jasmine-rice'],
  ['white rice, cooked', 'jasmine-rice'],
  ['Jasmine rice (steamed)', 'jasmine-rice'],
  ['Steamed broccoli, 120 g', 'broccoli'],
  ['black coffee, large', 'coffee'],
  ['half-portion white rice', 'jasmine-rice'],
  ['Pasta (linguine), cooked', 'pasta'],
  ['linguine (pasta), cooked', 'pasta'],
  ['pasta, cooked (spaghetti)', 'pasta'],
  ['pasta (fettuccine) cooked', 'pasta'],
  ['half-portion pasta (tagliatelle), cooked', 'pasta'],
  ['pork with brown gravy', 'braised-pork'],
  ['pork with brown gravy (moo ob)', 'braised-pork'],
  ['braised pork, cooked (moo ob)', 'braised-pork'],
  ['Chinese kale, cooked (kana)', 'stir-fried-greens'],
  // Issue #288 — one case per tolerated secondary class.
  ['Satay skewers with peanut sauce', 'satay'],
  ['satay skewers', 'satay'],
  ['half-portion satay', 'satay'],
  ['Olive oil / butter for cooking', 'cooking-oil'],
  ['Olive oil for cooking', 'cooking-oil'],
  ['Mashed potato with gravy', 'mashed-potato'],
  ['Mixed salad with dressing', 'green-salad'],
  ['Chili oil drizzle', 'chili-oil'],
  ['Chili flakes & herbs', 'chili-oil'],
  ['Greek yogurt with honey', 'yogurt'],
  // Whole published identities stay whole (no substring attribution).
  ['coffee cake', 'cake'],
  ['milk tea', 'milk-tea'],
  ['pad thai', 'pad-thai'],
  ['banana', 'banana'],
]

// Names no published identity explains: compound false friends, malformed
// parentheticals, unbounded tails, composite plates (the native suite's
// required negatives). These must stay unwritten, never guessed.
const unresolvedNames = [
  'Coffee with rice and chicken',
  'Coffee with rice and chicken only',
  'Cake with coffee',
  'Americano (black) with toast',
  'Som tum with peanuts',
  'chicken skewers',
  'butter for cooking',
  'skewers with peanut sauce',
  'coffee / tea',
  'Egg salad / creamy egg spread',
  'Fish balls / fish tofu / dumpling assortment',
  'pasta (coffee), cooked',
  'pasta (linguine cake), cooked',
  'pasta (linguine) with chicken',
  'pasta ((linguine)), cooked',
  'pasta (linguine',
  'pasta (linguine))',
  'pasta ()',
  'pasta (linguine, chicken)',
  'pasta (linguine) (cake)',
  'rice cake (half-portion)',
  'half-portion coffee cake with rice',
  'half-portion white rice and pork',
  'milk tea (boba tea)',
  'pad thai (stir-fried noodles)',
  'composite/shared restaurant plate',
  'half-portion white riceish',
  'Uncatalogued lunar stew',
  'Grandma\'s birthday noodles with three sauces',
  'chicken with rice and nam jim',
]

describe('write-time artwork identity resolution (issue #284)', () => {
  it('resolves the realistic name-only agent case to a published identity', () => {
    for (const [name, identity] of descriptorPositives) {
      expect(resolveArtworkIdentity(name), name).toBe(identity)
    }
  })

  it('keeps the food name untouched — resolution is identity only', () => {
    const name = '  Iced americano (black, no sugar)  '
    // The resolver never rewrites, trims or renames what the owner wrote; the
    // logged name stays verbatim (the write path stores it unchanged).
    expect(resolveArtworkIdentity(name)).toBe('coffee')
    expect(name).toBe('  Iced americano (black, no sugar)  ')
  })

  it('leaves compound, malformed and composite names without an identity', () => {
    for (const name of unresolvedNames) {
      expect(resolveArtworkIdentity(name), name).toBeNull()
    }
  })

  it('normalizes case and inner whitespace but never substrings', () => {
    expect(normalizeArtworkTerm('  Iced   Americano ')).toBe('iced americano')
    expect(resolveArtworkIdentity('ICED AMERICANO (BLACK, NO SUGAR)')).toBe('coffee')
    expect(resolveArtworkIdentity('iced  americano   (black, no sugar)')).toBe('coffee')
    expect(resolveArtworkIdentity('americano')).toBe('coffee')
    expect(resolveArtworkIdentity('americano (cake)')).toBeNull()
    expect(resolveArtworkIdentity('   ')).toBeNull()
    expect(resolveArtworkIdentity('')).toBeNull()
  })

  it('prefers a complete cooking identity over a weaker descriptor reading', () => {
    const fried: ArtworkCatalogAsset = { id: 'fried-egg', category: 'protein', kind: 'food', terms: ['fried egg'] }
    const other: ArtworkCatalogAsset = { id: 'egg', category: 'protein', kind: 'food', terms: ['egg'] }
    expect(resolveArtworkIdentity('fried egg', [fried, other])).toBe('fried-egg')
    expect(resolveArtworkIdentity('egg', [fried, other])).toBe('egg')
  })

  it('accepts every recognized leading qualifier on a synthetic catalog', () => {
    const study: ArtworkCatalogAsset = { id: 'oatmeal', category: 'prepared', kind: 'food', terms: ['test dish'] }
    const descriptors = [
      'iced', 'hot', 'cooked', 'boiled', 'steamed', 'grilled', 'fried', 'raw', 'half portion', 'half-portion',
      'stir-fried', 'stir fried', 'roasted', 'baked', 'toasted', 'sauteed', 'sautéed', 'poached',
      'scrambled', 'mashed', 'fresh', 'homemade', 'smoked', 'marinated', 'reheated', 'warm', 'cold', 'decaf',
      'unsweetened', 'unsalted', 'no sugar', 'sugar-free', 'low-fat', 'sliced', 'diced', 'chopped',
      'shredded', 'grated', 'peeled', 'drained', 'rinsed', 'frozen', 'half', 'portion', 'small', 'medium',
      'large', 'regular', 'single', 'double', 'triple', 'side', 'serving', 'servings', 'slice', 'slices',
      'piece', 'pieces', 'bowl', 'plate', 'cup', 'cups', 'glass', 'mug', 'shot', 'helping', 'extra', '120 g',
    ]
    for (const descriptor of descriptors) {
      for (const separator of [' ', ', ']) {
        const name = `${descriptor}${separator}test dish, cooked`
        expect(resolveArtworkIdentity(name, [study]), name).toBe('oatmeal')
      }
    }
  })

  it('fails closed on an ambiguous whole term or an ambiguous parenthetical', () => {
    const shared: ArtworkCatalogAsset = { id: 'oatmeal', category: 'prepared', kind: 'food', terms: ['test dish'] }
    const alsoShared: ArtworkCatalogAsset = { id: 'tofu', category: 'prepared', kind: 'food', terms: ['test dish'] }
    expect(resolveArtworkIdentity('test dish', [shared])).toBe('oatmeal')
    // Two assets claiming the same whole term: no arbitrary winner.
    expect(resolveArtworkIdentity('test dish', [shared, alsoShared])).toBeNull()
    const study: ArtworkCatalogAsset = { id: 'oatmeal', category: 'prepared', kind: 'food', terms: ['test dish', 'test synonym'] }
    expect(resolveArtworkIdentity('test dish (test synonym), cooked', [study])).toBe('oatmeal')
    const collision: ArtworkCatalogAsset = { id: 'tofu', category: 'prepared', kind: 'food', terms: ['test dish', 'test synonym'] }
    expect(resolveArtworkIdentity('test dish (test synonym), cooked', [study, collision])).toBeNull()
  })

  it('vetoes a tolerated tail that names a second published identity', () => {
    const dish: ArtworkCatalogAsset = { id: 'oatmeal', category: 'prepared', kind: 'food', terms: ['test dish'] }
    const fat: ArtworkCatalogAsset = { id: 'yogurt', category: 'dairy', kind: 'food', terms: ['butter'] }
    expect(resolveArtworkIdentity('test dish with butter', [dish])).toBe('oatmeal')
    expect(resolveArtworkIdentity('test dish with butter', [dish, fat])).toBeNull()
    expect(resolveArtworkIdentity('test dish with lard and eggs', [dish])).toBeNull()
  })

  it('reaches the catalog category fallback, and refuses an ambiguous category', () => {
    // "produce" is a category name, not a published term: only the category
    // step explains it.
    expect(resolveArtworkIdentity('produce')).toBe('fallback-produce')
    const one: ArtworkCatalogAsset = { id: 'fallback-produce', category: 'produce', kind: 'fallback', terms: ['produce category'] }
    const two: ArtworkCatalogAsset = { id: 'fallback-grains', category: 'produce', kind: 'fallback', terms: ['grain category'] }
    expect(resolveArtworkIdentity('produce', [one])).toBe('fallback-produce')
    expect(resolveArtworkIdentity('produce', [one, two])).toBeNull()
  })

  it('fails closed on a synthetic catalog id outside the published union', () => {
    // The write path can never receive an identity the MCP enum and the
    // database allowlist would reject, even from a drifted catalog.
    const drifted: ArtworkCatalogAsset = { id: 'invented-asset', category: 'prepared', kind: 'food', terms: ['test dish'] }
    expect(resolveArtworkIdentity('test dish', [drifted])).toBeNull()
  })

  it('never writes an identity outside the published union', () => {
    const published = new Set<string>(ArtworkIdValues)
    const vocabularies: string[] = []
    for (const asset of ArtworkCatalog) vocabularies.push(...asset.terms)
    const inputs = [
      ...vocabularies,
      ...descriptorPositives.map(([name]) => name),
      ...unresolvedNames,
      'unknown food', 'mixed meal', 'mixed meal, large', 'Food · fallback', 'focaccia bread', 'mortadella',
      'กล้วย', 'ข้าวสวย', 'กาแฟเย็น', 'ไม่รู้จักอาหาร',
    ]
    for (const input of inputs) {
      const resolved = resolveArtworkIdentity(input)
      expect(resolved === null || published.has(resolved), input).toBe(true)
    }
  })

  it('leaves the names the approved native studies already own unwritten', () => {
    // JournalArtworkCatalog.terms: a stored identity would outrank those
    // approved studies (#241 precedence), so the write declines them.
    for (const name of ['Focaccia bread', 'Mortadella', 'Stracciatella cheese', 'grilled vegetables', 'mixed meal']) {
      expect(resolveArtworkIdentity(name), name).toBeNull()
    }
    // The guard is a whole-name guard: the same food inside a longer name is
    // still resolved whenever the native path does not claim it.
    expect(resolveArtworkIdentity('focaccia sandwich')).toBe('sandwich')
    expect(resolveArtworkIdentity('mortadella, cooked')).toBe('cold-cuts')
  })
})
