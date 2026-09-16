# Issue 260 native qualifier-tolerant artwork evidence

Base: `2d87d61e73c6c3db7bd1420294ccf1551232405d` (`origin/staging`).
Branch: `issue/260-artwork-qualifier-match`.

## What this lane changed

One resolver file: `app/Sources/Morsel/FoodArtwork.swift`. Issue #241's
precedence is unchanged (explicit valid `artwork_id` → unambiguous whole-term
name/alias → closed Americano descriptor grammar → unambiguous category →
approved neutral sign). Issue #260 adds exactly one bounded tolerance: before
each step, a recognized **trailing** qualifier may be dropped, one at a time.

The closed grammar is a list of NON-food words — cooking/preparation descriptors
(`cooked`, `steamed`, `grilled`, …), portion/size tokens (`half portion`,
`large`, `serving`, …) and metric/imperial quantities (`120 g`, `1.5 cups`) —
plus a trailing parenthetical whose contents are a comma-separated list of those
same tokens. Nothing inside a name is ever inspected, so a distinct compound
food keeps its whole meaning:

| Logged name | Resolution after #260 | Why |
| --- | --- | --- |
| `White rice, cooked (half portion)` | `jasmine-rice` (alias `white rice`) | parenthetical + `cooked` are recognized qualifiers |
| `white rice, cooked` | `jasmine-rice` | trailing comma descriptor |
| `Jasmine rice (steamed)` | `jasmine-rice` | trailing parenthetical |
| `Steamed broccoli, 120 g` | `broccoli` (alias `steamed broccoli`) | trailing quantity |
| `black coffee, large` | `coffee` (alias `black coffee`) | trailing size token |
| `Americano (black, no sugar, homemade)` | `coffee` | the #241 grammar, unchanged |
| `coffee cake` | neutral | `cake` is not a qualifier |
| `Coffee cake, large` | neutral | after dropping `large` the whole term `coffee cake` still matches nothing |
| `Rice cake`, `orange juice`, `banana bread`, `coffee ice cream` | neutral | the trailing word is a food noun, never a qualifier |
| `Coffee with rice and chicken` | neutral | no trailing qualifier; nothing inside the name is matched |
| `Pasta (linguine), cooked`, `Chinese kale, cooked (kana)` | neutral | the head term has no catalog entry (a #262 catalog gap, recorded in the lane's `.report.md`) |

Ambiguity is still refused: if the stripped term and the original term match two
different assets, the item resolves to the approved neutral sign, never to one
of them.

## Committed tests (the bite proof)

The durable assertions live in the existing native test target — as a second
class in `app/Tests/MorselTests/FoodArtworkFallbackTests.swift`
(`FoodArtworkQualifierTests`) so that no generated `project.pbxproj` churn
enters the diff. The capture class is a second class in
`app/Tests/MorselTests/ArtworkIdentitySurfaceTests.swift`
(`FoodArtworkQualifierSurfaceTests`).

Focused invocation (own simulator, own scratch derived data):

```
HERDR_XCODEBUILD_DIRECT=1 xcodebuild test -project app/Morsel.xcodeproj -scheme Morsel \
  -destination "platform=iOS Simulator,id=DCA51B93-588F-4E40-9298-4BF479C03BE7" \
  -derivedDataPath /tmp/morsel-260-dd -only-testing:MorselTests/FoodArtworkQualifierTests
```

| Leg | Source under test | Raw exit | Result |
| --- | --- | --- | --- |
| head | fixed `FoodArtwork.swift`, sha256 `33e0c0becd544aec4f7dbb1871687672bc5606c245b82ce1c85de22e9e88742a` | 0 | 6 tests, 0 failures |
| base | the same source reverted to `origin/staging` (`git stash push -- app/Sources/Morsel/FoodArtwork.swift`, test bytes untouched) | 65 | 6 tests, 12 failures — every qualifier positive and both Paper/Night paint comparisons |
| mutation m1 | closed grammar admits the food nouns `cake`/`juice` | 65 | 6 tests, 15 failures — the compound false friends become coffee/orange |
| mutation m2 | the trailing-qualifier step removed | 65 | 6 tests, 12 failures — the qualifier positives stop resolving |
| mutation m3 | any trailing word is dropped (bare substring behaviour) | 65 | 6 tests, 25 failures — `Coffee with rice and chicken` becomes coffee |

The base leg was reverted and restored with `git stash`; the fixed source was
verified byte-identical by SHA-256 after every mutation. Raw exits and full
outputs are in the lane's `.lane-logs/`.

## Rendered row/detail captures

The dedicated device is Morsel260-iPhone16, iPhone 16, iOS 26.5, UDID
`DCA51B93-588F-4E40-9298-4BF479C03BE7`. `captures.json` is the inventory:
paths, fixture names, identities, dimensions, raw screenshot exits and
independently recomputed SHA-256 values.

The capture class mounts the REAL production surfaces in an app-hosted
`UIWindow` on that simulator — `JournalPage` + `JournalPageHeader` +
`SectionHeading` + `MealItemRow` for the row frame, and the real
`MealItemEditSheet` (scrolled to the art block) for the detail frames — then
asserts the resolved `JournalRowArtwork` for each fixture before capturing. No
production view was replaced, no screenshot-only renderer was written, and no
app entry point was swapped. `capture.py` acknowledges a frame only after
`xcrun simctl io <udid> screenshot` returns zero, so a frame can never be
attributed to a later UI state.

| Fixture key | Logged name | Row / detail result | Frames |
| --- | --- | --- | --- |
| `rice-qualified` | `White rice, cooked (half portion)` | jasmine-rice study | 6 |
| `black-coffee-large` | `black coffee, large` | coffee study | 6 |
| `descriptive-americano` | `Americano (black, no sugar, homemade)` | coffee study (no #241 regression) | 6 |
| `coffee-cake` | `coffee cake` | neutral eating sign | 6 |
| `rice-cake` | `Rice cake` | neutral eating sign | 6 |
| `pasta-gap` | `Pasta (linguine), cooked` | neutral (no catalog entry yet) | 6 |
| `kale-gap` | `Chinese kale, cooked (kana)` | neutral (no catalog entry yet) | 6 |

Each key has `paper-<key>-row.png`, `paper-<key>-detail-top.png`,
`paper-<key>-detail-art.png` and the three equivalent `night-` files in
[`captures/`](captures/), i.e. 42 frames = 7 fixtures × 2 themes × 3 frame
positions.

## Scope and limits

- No catalog entry was added: `app/Resources/FoodArt` and
  `packages/schema/artwork-ids.ts` are untouched, and the shipped library stays
  the approved 18 assets / 13 food / 5 fallback. Catalog/alias expansion is
  issue #262's surface; the alias additions this lane would need are recorded in
  `.report.md` for the orchestrator to sequence.
- No schema, migration, server, MCP tool or agent-skill change; no change to the
  write path, and no name/nutrition/photo mutation (asserted in the tests).
- The captures are mounted-window frames on a simulator, not a user tap against
  an authenticated live dashboard, a physical device, or a live MCP round trip.
  Detail frames are two scroll positions of the same real sheet.
- The hosted `quality` job remains the authority for the `server/**` 5000 ms
  timeout class; this lane does not raise budgets or skip tests.
