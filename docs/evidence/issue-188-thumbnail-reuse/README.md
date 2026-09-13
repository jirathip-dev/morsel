# Issue #188 — bounded revision-aware downsampled thumbnail reuse

Base `0db1cb5` (`issue/188-thumbnail-reuse`, cut from `origin/staging`); head =
this lane's single commit (exact sha in the lane `.report.md`).

Evidence captured on the lane's dedicated simulator **`Morsel188-iPhone16`**
(iOS 26.5), unsigned Debug build (`CODE_SIGNING_ALLOWED=NO`, simulator — **not
a physical device**). The lane's evidence runs used UDID
`40D8CFB4-2345-409C-B971-463CF846BEA0` (that simulator instance was reclaimed in
the lane cleanup); the **final gate run** in this README ran on the recreated
lane simulator with the same name, UDID
`E5EF858B-050B-4866-8EC3-E836ABE5EFC5`. Raw lines below are lifted verbatim
from `.lane-logs/` (untracked): `counts.txt` holds the counted
cold/warm/replacement/decode/memory evidence and the RED/GREEN exits.

## What changed

**New modules** (all under `app/Sources/Morsel/`):

- `MealThumbnailKey.swift` — the prepared thumbnail's identity
  (**account × object path × revision × target pixel size**), the revision
  value (`.queued(fingerprint:)` / `.remote(epoch:)`), the request type and the
  declared display boxes. A path, a signed URL or a screen position alone is
  never a key.
- `MealThumbnailPreparer.swift` — the off-body preparation: `CGImageSource`
  decodes straight at the target size (no full-size intermediate ever exists),
  `kCGImageSourceCreateThumbnailWithTransform` applies the EXIF orientation, the
  target is the source fitted into the display box × the display scale (exactly
  what `.scaledToFit()` will paint), and the whole synchronous body runs on this
  actor's executor. Also the FNV-1a content fingerprint and the pixel-byte cost
  the cache bounds itself by.
- `MealThumbnailCache.swift` — the cache: in-flight coalescing (identical
  concurrent requests share ONE fetch + ONE preparation), a lock-guarded LRU
  store with a declared entry capacity and pixel-byte budget, counters
  (fetches / preparations / reuses / hits / misses / coalesced / evictions /
  failures), account generations (logout/account switch retire in-flight work),
  and `removeAll(accountID:)`. Source bytes are never retained.
- `MealPhotoRevisions.swift` — this device's revalidation epochs per
  (account, object): a same-path replacement bumps the object, an attach whose
  canonical path is derived server-side bumps the account, logout forgets that
  account only. Bounded (256 objects, LRU) and forgetting is safe — a forgotten
  object re-observes at epoch 0, a NEW revision, never a stale serve.
- `LocalFirstRepository+ThumbnailRevision.swift` — the read seam's revision
  identity (`MealPhotoRevisionProviding`): the local outbox payload's own
  fingerprint while the meal is queued, otherwise the remote epoch — answered
  **before** any fetch, which is what makes a warm revisit a pure memory hit.

**Wired in** (fence item 3, disclosed additions):

- `LocalFirstRepository.swift` — the `revisions` seam, the shared `MealPhotoRevisions`
  instance, `store` made internal for the across-file extension (same precedent
  as `remote`/`snapshotCache`), and the two write-seam bumps in
  `attachMealPhoto` (queued → path-scoped, synced → account-scoped).
- `MealPhotoEditorSection.swift` — the shipped small photo surface now reads
  through the cache (`MealPhotoSource(repository:)` + `thumbnailCache.thumbnail`),
  and its loader is `@MainActor`: the base loader wrote `@State` from whichever
  executor resumed it, which does not invalidate the view.
- `app/photo-edit-contract.test.ts` / `app/photo-pipeline-contract.test.ts` —
  two pinned source literals retargeted to the new call shapes (`queuedPhoto`
  payload accessor, the section's cache read instead of `UIImage(data:)`),
  disclosed as out-of-fence probe edits.

## Seam corrections against the brief (re-derived at this base)

- **The row slot does not consume photo bytes.** `JournalFoodRow.swift:85`
  renders `MealArtworkSlot`, which resolves *bundled illustration PNGs*
  (#199/#223/#229); the photo path is deliberately not an input to a row. There
  is no account/object/revision semantics to key there, so no row wiring was
  added (the approved A geometry is untouched, and no `JournalFoodRow.swift` /
  `FoodArtworkView.swift` edit was needed).
- **The live small photo consumer is the detail/edit figure**
  (`MealPhotoEditorSection.existingPhotoRow`, 145pt × sheet width) — the same
  surface the brief lists as a verified live seam. That is where the cache is
  wired; it is an out-of-fence file and is disclosed.
- **There is no full-size/zoom viewer in this app**, so "keep the full-size path
  separate" holds by construction: `loadMealImage` still returns the object's
  own bytes and no downsampled surrogate is ever handed to it (asserted).

## Counts and bounds

See `counts.txt` for the raw `ISSUE-188-*` lines. Summary of the counted
claims: cold = 1 fetch / 1 preparation / 1 513 800 resident pixel bytes for the
870×435@3x figure photo (no original bytes); warm = +0 fetches, +0 decodes, 1
hit; six identical concurrent reads = 1 fetch / 1 preparation / 5 coalesced;
3x vs 2x = two identities (870×435 vs 580×290) and two preparations; same-path
replacement = 1 refetch / 1 decode, the replaced entry dropped (1 resident) and
the replacement served; queued→remote = 1 refetch / 0 decodes (prepared pixels
re-filed); external change with no signal = 0 extra fetches (never polled), the
app's signal = exactly 1 refetch; logout/account switch = that account's
entries dropped, the other account stays warm (no pixels cross accounts).
Memory: capacity 2 → 2 residents / 5 evictions (LRU); an 8 000-byte budget with
3 200-byte thumbnails settles at 6 400 bytes; one over-budget entry is kept and
served instead of thrashed. The preparation is one-at-a-time
(`peakConcurrentPreparations == 1`).

## Gates (raw exits in `.report.md`)

`npm ci` (256 packages), `npm run typecheck` = 0, `npm run lint` = 0, `npm test`
= **1** on this host, `xcodegen generate` (project byte-stable on re-run:
`59442cb6d74011b24409ce0cf31a558ca32763559993537da5a64c0552fff457` both runs),
`swiftlint --strict` = 0 (125 files), `git diff --check` = 0, and the native
suite.

`npm test` raw exit 1 is the documented host load-skew class, not an assertion
failure: 5/556 failed, ALL of them `server/**` (http, render-png ×2,
tool-classification ×2) with "Test timed out in 5000ms" and ZERO
`AssertionError`; host load 18–29 during the run. The diagnostic rerun (never
gate evidence) `npx vitest run --testTimeout=60000 <those three files>` passes
12/12 (each previously-timed-out test completes in 2.8–9s). The two contract
probes this lane retargeted pass in the same suite (`app/photo-*.test.ts`,
17/17). See `.report.md` for both raw exits.

The native gate is **ONE complete full-suite invocation** at the delivered
head, no skip/only flags, on the lane simulator
(`UDID E5EF858B-050B-4866-8EC3-E836ABE5EFC5`, iOS 26.5):

```
cd app && HERDR_XCODEBUILD_DIRECT=1 xcodebuild test -project Morsel.xcodeproj -scheme Morsel \
  -destination "platform=iOS Simulator,id=E5EF858B-050B-4866-8EC3-E836ABE5EFC5" \
  CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/xc-dd-188
  → "Executed 373 tests, with 0 failures (0 unexpected) in 33.986 (34.428) seconds"   (63 suites)
  → ** TEST SUCCEEDED ** ; xcodebuild=0
```

The documented fresh-process `GoalsPolishTests` wedge did occur on the first
full invocation (frozen at its first case with xcodebuild at 0.0% CPU after 167
cases; killed → `xcodebuild=143`), and the single warm rerun on the SAME
simulator completed the whole suite: **373 tests / 0 failures, raw exit 0**
(`.lane-logs/xcodebuild-fullrun1.log` = wedged first attempt,
`.lane-logs/xcodebuild-fullrun2.log` = the complete run). The earlier split
legs (`-skip-testing` / `-only-testing`) are superseded by that single-run
truth and are only kept as context for the recovery.

## Honest scope (what this lane did NOT verify)

- The shipped figure's own *painted pixels* could not be read back through
  `drawHierarchy` in the unit bundle: the section's `.task` loader runs deferred
  under the test pump and the capture kept the previous frame. The shipped
  surface is therefore proven by its COUNTED read (one fetch + one preparation
  cold, zero extra warm, through the injected repository), by the contract
  probe pinning that the body no longer constructs `UIImage(data:)`, and the
  paint path by a mounted SwiftUI body awaiting the same cache seam (pixels
  probed, display-exact 870×435). Disclosed rather than papered over.
- External (another-device) same-path replacements are **not polled**: the
  declared bound is zero extra fetches while warm, revalidation only on an app
  signal. A stale window therefore exists until the next signal — stated, not
  hidden.
- No physical-device behaviour, no production writes, no deploy, no PR: the
  branch is pushed only.
