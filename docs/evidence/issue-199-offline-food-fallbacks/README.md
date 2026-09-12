# Issue #199 — offline food-illustration fallbacks: native app evidence

Captured on the lane's dedicated simulator `Morsel199-iPhone16`
(UDID `89ED5DDA-A4E2-4621-9BA7-05EA57C9878E`, iOS 26.5), **unsigned Debug
build** (`xcodebuild build … CODE_SIGNING_ALLOWED=NO`, simulator — **not a
physical device**), 1179×2556 px device pixels (@3x). Both themes were driven
through the real appearance seam: `simctl ui … appearance light|dark`
(Paper / Night ink) plus the app's own `-morsel.appearance.theme
paper|nightInk` launch default.

## Fixture provenance (labelled fixture data, not production data)

The captures render the REAL production views over a fixture snapshot fed
through the existing `MockDashboardRepository` — the repo's temporary `@main`
capture-harness pattern (as used for `docs/evidence/issue-152-named-menus/`).
The harness file (`CaptureHarness199.swift`) and the `CAPTURE-HARNESS-ACTIVE`
suspension of the production `@main` were **removed before the commit**:
`shasum -a 256 app/Sources/Morsel/MorselApp.swift` equals the pristine value,
`cmp` against the pre-capture copy is clean, and no harness string remains
under `app/`.

Fixture meals (one fictional day; each capture is labelled *fixture* on
screen):

| Meals | Case under test |
|-------|-----------------|
| Breakfast “Fried egg / Toast” with `image_path` set | **photo-present** — the shipped `MealThumbnailView` pipeline |
| Lunch “Jasmine rice” | **photo-absent, resolvable** — approved `jasmine-rice` study |
| Snack “Pad thai from the corner stall” | **unknown food** — nothing is invented |
| Dinner “Jasmine rice + Wholegrain toast” | **composite meal, one category** — labelled `fallback-grains` |

The “meal photo” is a harness-generated JPEG (flat warm field + one dark
oval) — a stand-in fixture, never presented as approved artwork.
**No prototype screenshot is presented as app evidence**; the illustrations
shown are the real bundled #197 bytes and the surrounding UI is the shipped app.

## Captures

| File | Real production view rendered | Shows |
|------|------------------------------|-------|
| `today-paper.png`, `today-night.png` | `TodayView` | photo-present breakfast next to the `jasmine-rice` study for the photo-less lunch (Paper / Night ink) |
| `log-paper.png`, `log-night.png` | `TodayLogSection` (the real component behind Today's log) | all four cases in one screen: photo / food study / **unknown (no art)** / **category fallback (“Grains”)** |
| `history-fallback-paper.png`, `history-fallback-night.png` | real History day card (`DayDrillDown` fed through the real `HistoryViewModel` load/select path) | a photo-less day: the day card shows the illustration |
| `history-photo-paper.png`, `history-photo-night.png` | same History day card | a day whose first meal has a photo: the photo stays authoritative |
| `detail-paper.png`, `detail-night.png` | `MealItemEditSheet` (item/detail renderer) | photo-less item: 64px study + “Illustration · not a meal photo” |

Honest capture limitation: the lifted History day card renders inside a
`JournalPage` without the shell's tab chrome, so only the card itself should
be read as evidence. The Today captures top-crop the hero; the full-row view
is `log-*.png`.

## Mapping rules exercised

1. exact name, then alias, match (trimmed, lowercased, inner whitespace
   collapsed; catalog order) → that food's stable artwork ID;
2. catalog category aliases (`produce category`, …) → that category's labelled
   fallback;
3. a meal with two or more distinct foods: one shared category → that
   category's labelled fallback; mixed categories → **no illustration**;
4. any unmatched item → **no illustration** (the approved library has no
   “unknown” study, and guessing a category from free text would be an
   inference);
5. a stored meal photo always wins, so upload/loading/error and queued-row
   semantics are untouched.

## Offline proof

- **Byte identity of the copy:** every file in `app/Resources/FoodArt/`
  (34 PNGs + `catalog.json`) hashes equal to its
  `docs/art/food-library-v2/…` source (`shasum -a 256`, 35/35 pairs).
- **No fetch path:** `FoodArtwork.swift` / `FoodArtworkView.swift` contain no
  `URLSession`/`URLRequest`/network API; the illustration path is
  `Bundle.main.url(forResource:)` → `Data(contentsOf:)` → `UIImage(data:)`.
- **Runtime denial proof (native XCTest):**
  `testIllustrationRendersWhileEveryNetworkRequestIsDenied` renders the real
  shared slot while a denying `URLProtocol` rejects every request, and asserts
  **zero requests were attempted**; `testEveryApprovedAssetShipsBothThemesOfflineAt64px`
  decodes all 34 bundled studies at 64×64 from the app bundle alone.
- **Built-bundle packaging note:** Xcode's `CopyPNGFile` phase repackages
  loose app PNGs into Apple's CgBI variant (standard iOS packaging; it ignores
  `COMPRESS_PNG_FILES` in Xcode 26). Decoding each bundled copy with `sips`
  and comparing pixels shows **34/34 studies pixel-identical** to the approved
  exports (`all bundled studies decode pixel-identical to the approved exports`,
  raw exit 0). Only the committed `app/Resources/FoodArt/` copies are byte-for-byte
  the approved files.

## What these captures do NOT prove

- Not a physical-device capture; Dynamic Type extremes, VoiceOver, and real
  camera/photo-library flows were not exercised here.
- Illustration recognition quality is the design lane's evidence (#197); this
  lane proves placement, mapping, precedence and offline availability only.
