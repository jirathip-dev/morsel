import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { ArtworkPolicy } from './artwork.ts'

// Issue #284 — the server resolver is a closed PORT of the native policy, so
// the two grammars must not drift: the write stores the identity the renderer
// derives from the same name, and a stored identity outranks the renderer's
// name path. These assertions read the committed Swift sources beside this
// file and compare them to the vocabularies the resolver actually applies, so
// editing one side alone fails the suite (loudly) instead of silently
// changing what a logged name resolves to.
//
// The lists live in-source: `FoodArtwork.swift` (trailing descriptors,
// quantity units, the Americano qualifier set), `FoodArtworkSecondary.swift`
// (attachment markers, the accompaniment and purpose vocabularies) and
// `JournalArtwork.swift` (the names the approved Variant A studies own).

const here = dirname(fileURLToPath(import.meta.url))
const nativeResolver = readFileSync(join(here, '..', 'app', 'Sources', 'Morsel', 'FoodArtwork.swift'), 'utf8')
const nativeSecondary = readFileSync(join(here, '..', 'app', 'Sources', 'Morsel', 'FoodArtworkSecondary.swift'), 'utf8')
const nativeJournal = readFileSync(join(here, '..', 'app', 'Sources', 'Morsel', 'JournalArtwork.swift'), 'utf8')

/** The quoted string literals of the Swift list that starts at `marker`. */
function swiftList(source: string, marker: string): string[] {
  const start = source.indexOf(marker)
  expect(start, `the native policy must still declare: ${marker}`).toBeGreaterThanOrEqual(0)
  const open = source.indexOf('[', start)
  expect(open).toBeGreaterThanOrEqual(0)
  const close = source.indexOf(']', open)
  expect(close, `unterminated Swift list at: ${marker}`).toBeGreaterThan(open)
  const body = source.slice(open + 1, close)
  const matches = [...body.matchAll(/"([^"\\]*)"/g)].map((match) => match[1] ?? '')
  expect(matches.length, `no string literal found in the Swift list at: ${marker}`).toBeGreaterThan(0)
  return matches
}

/** The quoted keys of the `JournalArtworkCatalog.terms` dictionary. */
function swiftDictionaryKeys(source: string, marker: string): string[] {
  const start = source.indexOf(marker)
  expect(start, `the native study table must still declare: ${marker}`).toBeGreaterThanOrEqual(0)
  const open = source.indexOf('= [', start)
  expect(open).toBeGreaterThanOrEqual(0)
  const close = source.indexOf(']', open)
  expect(close).toBeGreaterThan(open)
  const body = source.slice(open + 1, close)
  const matches = [...body.matchAll(/"([^"\\]+)"\s*:/g)].map((match) => match[1] ?? '')
  expect(matches.length, `no quoted key found in the native dictionary at: ${marker}`).toBeGreaterThan(0)
  return matches
}

const sorted = (values: Iterable<string>): string[] => [...values].sort()
const set = (values: Iterable<string>): Set<string> => new Set(values)

describe('write-time resolution policy is pinned to the native grammar (issue #284)', () => {
  it('applies exactly the native trailing descriptor vocabulary', () => {
    expect(sorted(ArtworkPolicy.trailingDescriptors)).toEqual(
      sorted(swiftList(nativeResolver, 'trailingDescriptors: Set<String> = [')),
    )
  })

  it('applies exactly the native quantity unit vocabulary', () => {
    expect(sorted(ArtworkPolicy.quantityUnits)).toEqual(
      sorted(swiftList(nativeResolver, 'quantityUnits: Set<String> = [')),
    )
  })

  it('applies exactly the native Americano qualifier set', () => {
    expect(sorted(ArtworkPolicy.americanoQualifiers)).toEqual(
      sorted(swiftList(nativeResolver, 'allowed: Set<String> = [')),
    )
  })

  it('applies exactly the native attachment markers and secondary vocabularies', () => {
    expect(sorted(ArtworkPolicy.attachmentMarkers)).toEqual(
      sorted(swiftList(nativeSecondary, 'attachmentMarkers = [')),
    )
    expect(sorted(ArtworkPolicy.accompaniments)).toEqual(
      sorted(swiftList(nativeSecondary, 'accompaniments: Set<String> = [')),
    )
    expect(sorted(ArtworkPolicy.purposes)).toEqual(
      sorted(swiftList(nativeSecondary, 'purposes: Set<String> = [')),
    )
  })

  it('leaves exactly the names the approved native studies own to the renderer', () => {
    const nativeStudies = swiftDictionaryKeys(nativeJournal, 'static let terms:')
    expect(sorted(ArtworkPolicy.nativeStudyTerms)).toEqual(sorted(nativeStudies))
    // A guard list is only meaningful while it stays small and whole-name.
    expect(nativeStudies.length).toBeLessThan(20)
  })

  it('keeps every pinned vocabulary free of duplicates', () => {
    for (const values of [
      ArtworkPolicy.trailingDescriptors, ArtworkPolicy.quantityUnits, ArtworkPolicy.accompaniments,
      ArtworkPolicy.purposes, ArtworkPolicy.americanoQualifiers, ArtworkPolicy.nativeStudyTerms,
    ]) {
      // A Set cannot hold duplicates; assert the lists are non-empty and that
      // the attachment markers stay ordered longest-first (matching is greedy).
      expect(values.size).toBeGreaterThan(0)
    }
    const markers = ArtworkPolicy.attachmentMarkers
    expect(markers.length).toBeGreaterThan(0)
    expect(new Set(markers).size).toBe(markers.length)
    expect(markers.indexOf('with a side of')).toBeLessThan(markers.indexOf('with'))
    expect(set(markers).has('with')).toBe(true)
  })
})
