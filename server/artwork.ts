// Issue #284 — write-time artwork identity resolution (the server half).
//
// The defect: the agent path stores an item name and (rarely) an `artwork_id`,
// so rendering has to re-derive identity from the name at read time and foods
// whose studies exist fall through to a neutral plate. The fix is at the
// SOURCE: `log_meal` resolves an omitted `artwork_id` from the logged name
// while it writes, using the PUBLISHED catalog vocabulary
// (`packages/schema/artwork-catalog.ts`, generated from
// `app/Resources/FoodArt/catalog.json`) — never a hand-kept alias table, and
// never a model-side instruction to remember an ID.
//
// This module is a deliberate, closed port of the native resolver's
// documented precedence chain (`app/Sources/Morsel/FoodArtwork.swift`,
// `FoodArtworkSecondary.swift`), so a stored identity is exactly the identity
// the renderer would have derived from that name:
//   1. exact, case-sensitive explicit ID membership (the schema already
//      validates it; an explicit ID always wins and is never re-resolved here);
//   2. unambiguous normalized whole name/alias, including the closed
//      Americano descriptor grammar and noun parentheticals;
//   3. the same whole-term rule after dropping recognized qualifiers (#260),
//      then a closed trailing accompaniment/purpose/alternation phrase (#288);
//   4. unambiguous catalog category fallback;
//   5. otherwise NO identity is written at all.
//
// Step 5 is the honest boundary: `null` means the published catalog cannot
// identify the item from its name, so the field stays absent (SQL NULL) and
// the renderer keeps its documented name path — the approved Variant A
// studies included (`JournalArtworkCatalog`), which an explicit ID outranks.
// Nothing is invented: a name that names no published identity is never
// forced onto a fallback identity, and ambiguity still fails closed.
//
// The vocabulary is pinned to the committed Swift policy by
// `server/artwork-policy-pin.test.ts`: a grammar change on either side fails
// the suite instead of silently drifting.

import { ArtworkIdValues } from '../packages/schema/artwork-ids.ts'
import { ArtworkCatalog, type ArtworkCatalogAsset } from '../packages/schema/artwork-catalog.ts'

/**
 * A published identity: a member of the generated union (`artwork-ids.ts`),
 * which is also the MCP enum and the database allowlist.
 */
export type PublishedArtworkId = (typeof ArtworkIdValues)[number]

const PUBLISHED_ARTWORK_IDS: ReadonlySet<string> = new Set(ArtworkIdValues)

function isPublishedArtworkId(value: string): value is PublishedArtworkId {
  return PUBLISHED_ARTWORK_IDS.has(value)
}

/**
 * Matching key: trimmed, lowercased, inner whitespace collapsed — the same
 * normalization the generator applies to the published terms (locale
 * independent, so the same food always maps to the same identity).
 */
export function normalizeArtworkTerm(text: string): string {
  return text.toLowerCase().split(/\s+/).filter((part) => part.length > 0).join(' ')
}

// FoodArtwork.swift `trailingDescriptors` — cooking/preparation descriptors,
// serving formats and portion/size tokens a logging agent may append to an
// otherwise whole food name. Deliberately a closed list of NON-food words: a
// distinct compound food keeps its whole meaning (`coffee cake` is never a
// coffee) because every dish noun is absent from it.
const TRAILING_DESCRIPTORS: ReadonlySet<string> = new Set([
  'cooked', 'steamed', 'grilled', 'fried', 'stir-fried', 'stir fried', 'boiled', 'roasted',
  'baked', 'toasted', 'sauteed', 'sautéed', 'poached', 'scrambled', 'mashed', 'raw', 'fresh',
  'homemade', 'smoked', 'marinated', 'reheated', 'warm', 'hot', 'iced', 'cold', 'decaf',
  'unsweetened', 'unsalted', 'no sugar', 'sugar free', 'low fat', 'sliced', 'diced', 'chopped',
  'shredded', 'grated', 'peeled', 'drained', 'rinsed', 'frozen', 'half', 'half portion',
  'portion', 'small', 'medium', 'large', 'regular', 'single', 'double', 'triple', 'side',
  'serving', 'servings', 'slice', 'slices', 'piece', 'pieces', 'bowl', 'plate', 'cup', 'cups',
  'glass', 'mug', 'shot', 'helping', 'extra', 'skewer', 'skewers', 'drizzle', 'drizzled',
])

// FoodArtwork.swift `quantityUnits` — metric/imperial measures for a quantity
// qualifier ("120 g", "1.5 cups").
const QUANTITY_UNITS: ReadonlySet<string> = new Set([
  'g', 'gram', 'grams', 'kg', 'ml', 'l', 'oz', 'lb', 'lbs', 'kcal', 'cal', 'tbsp', 'tsp',
  'cup', 'cups',
])

// FoodArtworkSecondary.swift `attachmentMarkers` — longest first, so
// `with a side of` is matched before `with`.
const ATTACHMENT_MARKERS: readonly string[] = [
  'with a side of', 'topped with', 'served with', 'on the side', 'with', 'plus', 'and', '&', '+',
]

// FoodArtworkSecondary.swift `accompaniments` — the closed accompaniment
// vocabulary: condiments, sauces, cooking fats, seasonings and garnishes a
// name may carry without changing what the item is.
const ACCOMPANIMENTS: ReadonlySet<string> = new Set([
  // sauces, gravies and dressings
  'sauce', 'sauces', 'gravy', 'brown gravy', 'pan gravy', 'dressing', 'salad dressing',
  'vinaigrette', 'vinegar', 'mayo', 'mayonnaise', 'ketchup', 'mustard', 'sriracha',
  'hot sauce', 'soy sauce', 'fish sauce', 'oyster sauce', 'chili sauce', 'sweet chili sauce',
  'tomato sauce', 'peanut sauce', 'satay sauce', 'dipping sauce', 'nam jim', 'nam jim jaew',
  'jaew', 'salsa', 'pesto', 'chutney', 'tahini', 'harissa', 'sambal', 'gochujang', 'wasabi',
  'horseradish', 'soy', 'tamari', 'mirin', 'dashi',
  // cooking fats
  'oil', 'olive oil', 'sesame oil', 'chili oil', 'cooking oil', 'ghee', 'butter', 'margarine', 'lard',
  // seasonings and garnishes
  'salt', 'pepper', 'peppercorn', 'peppercorns', 'chili', 'chili flakes', 'chili crisp',
  'chili powder', 'sesame', 'sesame seeds', 'garlic', 'ginger', 'herbs', 'cilantro',
  'coriander', 'parsley', 'mint', 'basil', 'dill', 'chives', 'scallions', 'shallots',
  'lime', 'lemon', 'sugar', 'honey', 'tobiko',
])

// FoodArtworkSecondary.swift `purposes` — the closed purpose grammar
// (`for <use>`); non-food uses only, so the phrase can state a role but can
// never smuggle in a second ingredient.
const PURPOSES: ReadonlySet<string> = new Set([
  'for cooking', 'for frying', 'for stir frying', 'for deep frying', 'for grilling',
  'for roasting', 'for baking', 'for steaming', 'for boiling', 'for sauteing',
  'for dipping', 'for dressing', 'for garnish', 'for topping', 'for seasoning', 'for basting',
])

// FoodArtwork.swift `isAmericano` allowed descriptors — only an entire
// Americano name, optionally followed by this closed list, is a drink
// identification.
const AMERICANO_QUALIFIERS: ReadonlySet<string> = new Set([
  'black', 'no sugar', 'homemade', 'unsweetened', 'iced', 'hot', 'decaf',
])

// JournalArtwork.swift `JournalArtworkCatalog.terms` — the names claimed by
// the approved native Variant A studies. A stored explicit ID outranks those
// studies, so writing an identity here would shadow an approved native design
// decision for a name the renderer already depicts. The write leaves them
// alone; pinned to the Swift source by the policy pin test.
const NATIVE_STUDY_TERMS: ReadonlySet<string> = new Set([
  'focaccia', 'focaccia bread', 'mortadella', 'stracciatella', 'stracciatella cheese',
  'vegetables', 'grilled vegetables', 'grilled vegetable topping', 'unknown', 'unknown food',
  'mixed meal',
])

const NEUTRAL_CATEGORY = 'neutral'
const CONDIMENT_CATEGORY = 'condiments'
const AMERICANO_IDENTITY = 'coffee'

function isCategoryFallback(asset: ArtworkCatalogAsset): boolean {
  return asset.kind === 'fallback' && asset.category !== NEUTRAL_CATEGORY
}

function isDecimalNumber(text: string): boolean {
  return /^\d+(?:\.\d*)?$/.test(text) || /^\.\d+$/.test(text)
}

/**
 * "120 g", "1.5 cups": a number plus a measure. A bare number or a bare unit
 * is not a qualifier.
 */
function isQuantity(token: string): boolean {
  const parts = token.split(' ')
  if (parts.length === 2) {
    const [amount, unit] = parts
    return amount !== undefined && unit !== undefined && isDecimalNumber(amount) && QUANTITY_UNITS.has(unit)
  }
  if (parts.length !== 1) return false
  const [single] = parts
  if (single === undefined || single.length <= 1) return false
  return isDecimalNumber(single.slice(0, -1)) && QUANTITY_UNITS.has(single.slice(-1))
}

/**
 * One recognized qualifier phrase: a comma-separated list of known
 * descriptors or quantities. Empty components, unknown words ("cake") and
 * unknown units fail closed, so nothing is dropped from a name that does not
 * end in the closed grammar.
 */
function isQualifierPhrase(text: string): boolean {
  return text.split(',').every((part) => {
    const token = normalizeArtworkTerm(part.replaceAll('-', ' '))
    if (token.length === 0) return false
    if (TRAILING_DESCRIPTORS.has(token)) return true
    if (token.split(' ').every((word) => TRAILING_DESCRIPTORS.has(word))) return true
    return isQuantity(token)
  })
}

/**
 * Drops the longest recognized descriptor suffix of a comma-free name —
 * never the whole name, so the head term always survives.
 */
function droppingTrailingDescriptor(text: string): string | null {
  const words = text.split(' ')
  if (words.length < 2) return null
  for (let length = Math.min(2, words.length - 1); length >= 1; length -= 1) {
    if (isQualifierPhrase(words.slice(words.length - length).join(' '))) {
      return normalizeArtworkTerm(words.slice(0, words.length - length).join(' '))
    }
  }
  return null
}

/** A closed accompaniment, optionally stating its use (`butter for cooking`). */
function isSecondary(phrase: string, assets: readonly ArtworkCatalogAsset[]): boolean {
  const key = normalizeArtworkTerm(phrase).replaceAll('-', ' ')
  if (key.length === 0) return false
  if (PURPOSES.has(key)) return true
  const accompaniment = droppingPurpose(key)
  if (accompaniment === null || !ACCOMPANIMENTS.has(accompaniment)) return false
  return !namesSecondIdentity(accompaniment, assets)
}

/**
 * `butter for cooking` -> `butter`; `butter` -> `butter`; a `for …` that is
 * not a closed purpose -> null (fails closed).
 */
function droppingPurpose(key: string): string | null {
  const range = key.indexOf(' for ')
  if (range === -1) return key.length === 0 ? null : key
  if (!PURPOSES.has(`for ${key.slice(range + ' for '.length)}`)) return null
  const head = key.slice(0, range)
  return head.length === 0 ? null : head
}

/**
 * The veto: a tolerated phrase may name a condiment (the class it comes from),
 * never a second catalog identity — a dairy, protein, grains, drinks, produce,
 * soup, sweets or prepared identity in the tail means the name lists a second
 * dish, not a description of the first one.
 */
function namesSecondIdentity(phrase: string, assets: readonly ArtworkCatalogAsset[]): boolean {
  return assets.some((asset) =>
    asset.category !== CONDIMENT_CATEGORY && asset.terms.includes(phrase))
}

function matchesMarker(words: readonly string[], at: number, marker: string): boolean {
  const parts = marker.split(' ')
  if (at + parts.length >= words.length) return false
  return parts.every((part, offset) => words[at + offset] === part)
}

function nonEmpty(key: string): string | null {
  return key.length === 0 ? null : key
}

/**
 * `olive oil / butter for cooking`: the first component names the item, every
 * remaining component must be a closed accompaniment or purpose.
 */
function alternationHead(key: string, assets: readonly ArtworkCatalogAsset[]): string | null {
  const parts = key.split(' / ')
  if (parts.length < 2) return null
  const [first] = parts
  if (first === undefined) return null
  const head = nonEmpty(first)
  if (head === null) return null
  return parts.slice(1).every((part) => isSecondary(part, assets)) ? head : null
}

/**
 * `satay skewers with peanut sauce`: an attachment marker plus a closed
 * accompaniment. The longest head wins, so the tail stays the shortest phrase
 * the vocabulary can explain.
 */
function attachmentHead(key: string, assets: readonly ArtworkCatalogAsset[]): string | null {
  const words = key.split(' ')
  if (words.length < 3) return null
  for (let start = 1; start < words.length; start += 1) {
    for (const marker of ATTACHMENT_MARKERS) {
      if (!matchesMarker(words, start, marker)) continue
      const tail = words.slice(start + marker.split(' ').length).join(' ')
      if (isSecondary(tail, assets)) return nonEmpty(words.slice(0, start).join(' '))
    }
  }
  return null
}

/** `olive oil for cooking`: the same closed purpose grammar at the tail. */
function purposeHead(key: string): string | null {
  const range = key.indexOf(' for ')
  if (range === -1) return null
  if (!PURPOSES.has(`for ${key.slice(range + ' for '.length)}`)) return null
  return nonEmpty(key.slice(0, range))
}

/** The head of a name whose trailing secondary phrase is tolerated (issue #288). */
function secondaryHead(key: string, assets: readonly ArtworkCatalogAsset[]): string | null {
  return alternationHead(key, assets) ?? attachmentHead(key, assets) ?? purposeHead(key)
}

/**
 * The same name with ONE trailing qualifier removed: a trailing parenthetical
 * group, a trailing comma-separated descriptor, a closed secondary phrase
 * (issue #288), or a bare trailing descriptor. null when the name ends in no
 * recognized qualifier.
 */
function strippingTrailingQualifier(key: string, assets: readonly ArtworkCatalogAsset[]): string | null {
  if (key.endsWith(')')) {
    const open = key.lastIndexOf('(')
    if (open > 0) {
      const head = normalizeArtworkTerm(key.slice(0, open))
      const inner = key.slice(open + 1, key.length - 1)
      if (head.length === 0 || head.includes('(') || head.includes(')')
        || inner.includes('(') || inner.includes(')') || !isQualifierPhrase(inner)) {
        return null
      }
      return head
    }
  }
  if (key.includes(',')) {
    const comma = key.lastIndexOf(',')
    const tail = normalizeArtworkTerm(key.slice(comma + 1))
    if (!isQualifierPhrase(tail)) return null
    const head = normalizeArtworkTerm(key.slice(0, comma))
    return head.length === 0 ? null : head
  }
  const secondary = secondaryHead(key, assets)
  if (secondary !== null) return secondary
  return droppingTrailingDescriptor(key)
}

/** The same closed preparation/size/quantity grammar at the leading edge. */
function strippingLeadingQualifier(key: string): string | null {
  const words = key.split(' ')
  if (words.length < 2) return null
  for (let length = Math.min(2, words.length - 1); length >= 1; length -= 1) {
    const prefix = words.slice(0, length).join(' ')
    const descriptor = prefix.endsWith(',') ? prefix.slice(0, -1) : prefix
    if (isQualifierPhrase(descriptor)) return words.slice(length).join(' ')
  }
  return null
}

/**
 * Successive qualifier removals, longest first, bounded: a name can carry at
 * most a handful of trailing descriptors.
 */
function qualifiedTerms(key: string, assets: readonly ArtworkCatalogAsset[]): string[] {
  const terms: string[] = []
  let current = key
  while (terms.length < 4) {
    const stripped = strippingLeadingQualifier(current) ?? strippingTrailingQualifier(current, assets)
    if (stripped === null || stripped === current) break
    if (!terms.includes(stripped)) terms.push(stripped)
    current = stripped
  }
  return terms
}

/**
 * Only an entire Americano name, optionally followed by a closed list of
 * preparation descriptors. Unknown tokens, nested/trailing text and empty
 * components fail closed: "Americano (cake)" is not a drink identification.
 */
function isAmericano(key: string): boolean {
  if (key === 'americano') return true
  const prefix = 'americano ('
  if (!key.startsWith(prefix) || !key.endsWith(')')) return false
  const descriptors = key.slice(prefix.length, key.length - 1).split(',')
  if (descriptors.length === 0) return false
  return descriptors.every((descriptor) => AMERICANO_QUALIFIERS.has(normalizeArtworkTerm(descriptor)))
}

/**
 * Whole terms only. Colliding names/aliases cannot select an arbitrary dish;
 * issue #260's recognized qualifiers are dropped one at a time and every
 * remaining whole term is tried in the same precedence, so a descriptive name
 * reaches the entry it describes without ever matching a substring.
 */
function matchesWholeTerm(
  asset: ArtworkCatalogAsset, term: string, assets: readonly ArtworkCatalogAsset[],
): boolean {
  if (asset.terms.includes(term)) return true
  // A noun parenthetical is not a disposable qualifier. Both complete terms
  // must independently name THIS same asset (pasta + linguine).
  if (!term.endsWith(')')) return false
  const open = term.indexOf('(')
  if (open <= 0) return false
  const head = normalizeArtworkTerm(term.slice(0, open))
  const inner = normalizeArtworkTerm(term.slice(open + 1, term.length - 1))
  if (head.length === 0 || head.includes(')') || inner.includes('(') || inner.includes(')')) return false
  if (!asset.terms.includes(inner)) return false
  return [head, ...qualifiedTerms(head, assets)].some((candidate) => asset.terms.includes(candidate))
}

/** First occurrence per stable ID — catalog order stays the tiebreaker. */
function uniqueById(assets: readonly ArtworkCatalogAsset[]): ArtworkCatalogAsset[] {
  const seen = new Set<string>()
  return assets.filter((asset) => {
    if (seen.has(asset.id)) return false
    seen.add(asset.id)
    return true
  })
}

/** The single labeled category fallback for a category name, when unambiguous. */
function categoryFallback(term: string, assets: readonly ArtworkCatalogAsset[]): ArtworkCatalogAsset | null {
  const matches = assets.filter((asset) => isCategoryFallback(asset) && asset.category === term)
  if (matches.length !== 1) return null
  return matches[0] ?? null
}

/**
 * The native matcher's whole-name match (precedence steps 2–4). Returns null
 * when the name reaches no published identity, or when it is ambiguous.
 */
function matchArtwork(name: string, assets: readonly ArtworkCatalogAsset[]): ArtworkCatalogAsset | null {
  const key = normalizeArtworkTerm(name)
  if (key.length === 0) return null
  // A complete catalog name outranks a weaker qualifier interpretation:
  // fried egg must keep its own study even when egg names another study.
  const whole = uniqueById(assets.filter((asset) => matchesWholeTerm(asset, key, assets)))
  if (whole.length > 1) return null
  const wholeMatch = whole[0]
  if (wholeMatch !== undefined) return wholeMatch
  const terms = qualifiedTerms(key, assets)
  const matches = uniqueById(terms.flatMap((term) => assets.filter((asset) => matchesWholeTerm(asset, term, assets))))
  if (matches.length > 1) return null
  const qualifiedMatch = matches[0]
  if (qualifiedMatch !== undefined) return qualifiedMatch
  if ([key, ...terms].some(isAmericano)) {
    return assets.find((asset) => asset.id === AMERICANO_IDENTITY) ?? null
  }
  for (const term of [key, ...terms]) {
    const fallback = categoryFallback(term, assets)
    if (fallback !== null) return fallback
  }
  return null
}

/**
 * The closed policy vocabularies this resolver applies, exported so the pin
 * test can hold them against the committed native sources
 * (`app/Sources/Morsel/FoodArtwork.swift`, `FoodArtworkSecondary.swift`,
 * `JournalArtwork.swift`). A grammar change on either side must fail
 * `server/artwork-policy-pin.test.ts` instead of drifting silently.
 */
export const ArtworkPolicy: {
  readonly trailingDescriptors: ReadonlySet<string>
  readonly quantityUnits: ReadonlySet<string>
  readonly attachmentMarkers: readonly string[]
  readonly accompaniments: ReadonlySet<string>
  readonly purposes: ReadonlySet<string>
  readonly americanoQualifiers: ReadonlySet<string>
  readonly nativeStudyTerms: ReadonlySet<string>
} = {
  trailingDescriptors: TRAILING_DESCRIPTORS,
  quantityUnits: QUANTITY_UNITS,
  attachmentMarkers: ATTACHMENT_MARKERS,
  accompaniments: ACCOMPANIMENTS,
  purposes: PURPOSES,
  americanoQualifiers: AMERICANO_QUALIFIERS,
  nativeStudyTerms: NATIVE_STUDY_TERMS,
}

/**
 * Issue #284 — the identity to STORE for a logged name, or null when the
 * published catalog cannot identify it (the caller then omits the field and
 * the renderer keeps its documented name path).
 *
 * The returned value is validated against the generated union before it leaves
 * this module, so the schema enum and the database constraint accept it by
 * construction — and a catalog/union drift fails closed here instead of at the
 * write.
 */
export function resolveArtworkIdentity(
  name: string, assets: readonly ArtworkCatalogAsset[] = ArtworkCatalog,
): PublishedArtworkId | null {
  if (NATIVE_STUDY_TERMS.has(normalizeArtworkTerm(name))) return null
  const matched = matchArtwork(name, assets)
  if (matched === null) return null
  return isPublishedArtworkId(matched.id) ? matched.id : null
}
