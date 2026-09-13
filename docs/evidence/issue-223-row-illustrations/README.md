# Issue #223 — rows always illustrated; real photos stay inside detail

Captured on the lane's dedicated simulator `Morsel223-iPhone16`
(UDID `BF6BF5F9-4CF2-464E-8B02-B9DA2424DA7B`, iOS 26.5), **unsigned Debug
build** (`CODE_SIGNING_ALLOWED=NO`, simulator — **not a physical device**),
@3x device pixels (1179 px wide). Both themes were driven through the real
appearance seam: `xcrun simctl ui … appearance light|dark` plus the harness
root's `preferredColorScheme` (Paper = light, Night ink = dark).

## Fixture provenance (labelled fixture data, not production data)

The captures render the REAL production views — `TodayView`, `TodayLogSection`,
`DayDrillDown` (fed through the production `HistoryViewModel` load/select path)
and `MealItemEditSheet` (through the production `DashboardViewModel` and the
shared `MockDashboardRepository`) — the repo's temporary `@main` capture-harness
pattern (as used for `docs/evidence/issue-152-named-menus/` and
`docs/evidence/issue-199-offline-food-fallbacks/`). The harness file replaced
`app/Sources/Morsel/MorselApp.swift` while the captures were taken only; the
committed file was restored byte-identically (`sha256
dcd8ecebdf9cd15d4eb5d1274fc2dbdc44622f32b061310f951f31cbcfb93432`, before ==
after) and every harness string was removed before the commit.

Fixture meals (one fictional day, each capture labelled *fixture* on screen):

| Meal | Case under test |
|------|-----------------|
| Breakfast “Fried egg” **with a stored photo** | **photo-present** — the row shows the approved fried-egg study, never the photo; the stored photo itself stays inside detail/edit |
| Lunch “Focaccia bread / Mortadella / Stracciatella cheese / Grilled vegetable topping” | **the owner's four off-catalog foods** — every item row and the meal summary show the neutral eating sign (empty plate + spoon); one unmatched item suppresses nothing |
| Snack “Jasmine rice + Wholegrain toast” | **within-category composite** — the meal summary shows the labelled *Grains* fallback; each item row keeps its own study |
| Dinner “Jasmine rice + Grilled chicken” | **mixed categories** — the meal summary shows the neutral sign; each item row still keeps its own approved study |

The “meal photo” is a harness-generated JPEG (flat warm field + one dark oval) —
a stand-in fixture, never presented as approved artwork or an owner photo.

## Captures

| File | Real production view rendered | Shows |
|------|------------------------------|-------|
| `today-paper.png`, `today-nightInk.png` | `TodayView` (the real tab page) | the photo-present breakfast next to the illustrated log rows |
| `log-paper.png`, `log-nightInk.png` | `TodayLogSection` (the real component behind Today's log), all four cases in one frame | **unknown** owner foods → neutral sign, **mixed** meal → neutral summary, **photo-present** meal → illustration, **category** fallback (“Grains”) |
| `history-paper.png`, `history-nightInk.png` | real History day detail (`DayDrillDown` through the production `HistoryViewModel` load/select path) | day card + expanded day rows all illustrated — **never a real photo** |
| `detail-paper.png`, `detail-nightInk.png` | `MealItemEditSheet` for the photo-present item | the stored meal photo stays accessible in detail/edit (attach/replace row) |
| `detail-unknown-paper.png`, `detail-unknown-nightInk.png` | `MealItemEditSheet` for a photo-less off-catalog item | the neutral sign stands in, labelled “Food · fallback / Neutral sign · not identified food” |

Honest capture limitations: the lifted History day card renders without the
shell's tab chrome (the #199 precedent); the `today`/`history`/`detail*` frames
are the harness window's real on-device pixels, while the `log` frames are
rendered off-screen by the harness at device width and 3× scale so all four
cases fit one frame (same production component, same bundled bytes) — these are
production SwiftUI pixels, not device photographs.

## Red/green proof (behavioural, not source-string)

A base-compatible probe (`RowArtworkREDProbe`, kept out of the repo — run in a
scratch `/tmp` worktree at the pristine base `a937e9f`) carried the same four
behavioural assertions as the durable suite and **failed on the old
blank/photo-first behaviour**: raw exit `redprobe=65`, *Executed 4 tests, with 4
failures* —

- `testUnknownFoodItemRowRendersVisibleApprovedArtwork` — the old slot rendered
  **0** non-white pixels for “Focaccia bread” (`XCTAssertGreaterThan failed:
  ("0") is not greater than ("64")`);
- `testPhotoPresentRowRendersTheApprovedIllustrationNotThePhoto` — the old slot
  rendered the thumbnail placeholder instead of the approved study;
- `testMixedMealNeverResolvesBlank` — a mixed meal resolved to `.none`;
- `testOneUnmatchedItemCannotSuppressItsSiblings` — the unmatched item blanked
  its own row.

At the lane head the same assertions (durable, in `FoodArtworkFallbackTests` /
`RowArtworkRendererTests`) pass: full native suite **317 tests, 0 failures**,
raw exit `xcodebuild=0` (`.lane-logs/xcodebuild.log`), plus the captures above.

## Offline proof

The illustration path stays a bundled-asset read: `Bundle.main.url(forResource:)`
→ `Data(contentsOf:)` → `UIImage(data:)`. No fetch, no generation service and no
new dependency ships in this lane; `testIllustrationRendersWhileEveryNetworkRequestIsDenied`
renders the real row slot with a denying `URLProtocol` and asserts **zero**
requests were attempted, and `testEveryApprovedAssetShipsBothThemesOfflineAt64px`
decodes all 18 catalog studies (13 food + 5 fallback) at 64×64 from the bundle.
No logged food, portion, nutrition or photo value is read or written by the
resolver; `MealPhotoEditorSection` keeps the shipped attach/replace behaviour.

## Mapping rules exercised

1. exact name, then alias, match (trimmed, lowercased, inner whitespace
   collapsed; catalog order) → that food's stable artwork ID;
2. a food the library cannot identify → the approved **neutral** study
   (`fallback-neutral`: empty plate + spoon — never an identified food);
3. catalog category aliases (`produce category`, …) and composite meals whose
   foods share ONE category → that category's **labelled** fallback;
4. a meal spanning categories, or carrying any unidentified item → the neutral
   sign: never nothing, and never one arbitrary ingredient;
5. **rows never show a stored meal photo** (a photo path is not an input to the
   row decision); detail/edit keeps the photo authoritative;
6. an empty item list has no food to depict and resolves to nothing.
