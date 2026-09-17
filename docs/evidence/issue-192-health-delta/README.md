# #192 — observer imports are incremental (durable per-type cursors + deltas)

Lane checkout: `/Users/jirathip/.herdr/worktrees/morsel/issue-192-health-delta`.
Base: `f712ce0ed73f2a75bbc2335769c92f53b37e728e` (`origin/staging`).
Head: see `.report.md` (the report pins the code/test head SHA).

## The audited mechanism (base pin)

`HealthKitWeightImporter`'s observer handlers called `importBodyMass()` /
`importActiveEnergy()` with the default `since: nil`, which built an
`HKSampleQuery` with a nil predicate — an unbounded full-history read on every
observer callback. The foreground pass in `ViewModel` already read and advanced
a per-type watermark, but the observer path bypassed that ownership entirely.

Reproduction (behavioral, not a source-string check): `base-probe/` carries a
base-compatible XCTest that drives the SHIPPED observer handler at the base pin
and records the query window it uses. Raw result — `excerpts/base-probe-red.txt`,
1 test executed, 2 failures, `RAW_EXIT=65`:

    ISSUE192-PROBE windows=["nil", "nil"] rows=[1, 1]

i.e. the no-change notification issues another unbounded (`nil`) query and
processes the full history again.

## What changed

- **One incremental read per type.** `WeightSampleReading` now exposes
  `bodyMassWindow(after: Data?)` / `activeEnergyWindow(after: Data?)`, backed by
  `HKAnchoredObjectQuery` in `HealthKitWeightReader`. A nil anchor is the
  one-time full-history read; every later read is bounded by the persisted
  anchor. HealthKit also reports removed sample identities and delivers
  backdated samples that a `since:`-window query can never see.
- **Durable cursor ownership, reused.** The cursor is the opaque `HKQueryAnchor`
  (base64) in the local store's `meta` (`health.anchor.bodyMass`,
  `health.anchor.activeEnergyBurned`). The foreground passes
  (`ViewModel.importBodyMassPass`/`importEnergyPass`) and the observer handlers
  now call the same `importBodyMassDelta()`/`importActiveEnergyDelta()` — one
  ownership, per-type single-flight preserved.
- **Window + cursor are one atomic local write.**
  `HealthDeltaStore.applyBodyMassWindow`/`applyEnergyWindow` apply the window and
  advance the cursor inside one SQLite transaction: a failure anywhere leaves
  the window unapplied and the cursor unchanged, so the next pass replays it.
- **Energy day totals are recomputed from a durable contribution ledger**
  (`energy_sample_ledger`), keyed by HealthKit's sample identity. A repeated
  delivery replaces its contribution instead of double-counting, a backdated
  sample lands on its own LOCAL day, a removal drops exactly one contribution,
  and a day's prior contributions — including pre-#192 totals, kept as a
  baseline row — are never overwritten by a delta total (no
  delta-total overwrite).
- **Sample identity on weight rows.** `weight_samples.sample_id` keeps each
  row's originating sample so a removed Health sample drops the local row.

## AC mapping (all five)

| AC | Where it is proved |
| --- | --- |
| 1. No-change notifications do not rescan/rewrite/reupload; windows/anchors + processed counts recorded | `HealthDeltaImportTests.testNoChangeObserverNotificationsDoNotRescanOrRewriteHistory` — `ISSUE192-TRACE ac1 bodyAnchors=["full","anchored","anchored"] bodyRows=[1,0,0] energyRows=[1,0]`; the uploaded weight row and the synced energy day stay clean (`unsyncedWeightSamples`/`dirtyEnergyDays` empty) |
| 2. Independent per-type advance, only after successful persistence; replay without loss or duplicates | `testBodyAndEnergyCursorsAdvanceIndependentlyAndOnlyAfterSuccess`, `testReplayedWindowLandsOnceWithoutLossOrDuplication`, `testCancelledPassLeavesResumableDurableCursorState` |
| 3. Late/backdated + repeated energy samples: correct local-day totals, prior contributions preserved | `HealthEnergyDeltaTests.testBackdatedAndRepeatedEnergySamplesPreservePriorDayContributions`, `testDistinctSamplesAtOneInstantStayTwoContributions` |
| 4. Coalesced callbacks never overlap per type or suppress the other; cancellation leaves resumable cursor state | `testCoalescedCallbacksNeverOverlapPerTypeOrSuppressTheOther`, `testCancelledPassLeavesResumableDurableCursorState` (plus the pre-existing `HealthReliabilityTests.testOverlappingObserverCallbacksCoalesceIntoOneImport`) |
| 5. Timezone/DST/day boundaries, warm restart, no-change and delayed samples; removal/correction recorded | `testLocalDayBucketingAcrossADSTFallBack` (fixed America/New_York calendar across the 2026-11-01 fall-back), `testWarmRestartKeepsCursorsAndContributionLedger`, `testRemovalAndCorrectionAdjustExactlyOneContribution`, `testRemovedWeightSampleDropsItsLocalRow`, AC1's no-change cases |

## Recorded limits (disclosed, not silently claimed)

- **Sample removal.** The anchored read reports removed identities and the delta
  path applies them locally: the energy contribution is dropped and the day
  total recomputed (a day whose contributions are all gone drops its outbox
  row), and the local weight row is deleted. The **already-uploaded remote row is
  NOT deleted** — `energy_burned_logs` / `weight_logs` are upsert-only and no
  remote-delete path exists in this lane. A removed sample therefore stays in
  server-side history; this is a recorded limitation, not a reconciliation claim.
- **Corrections.** HealthKit has no in-place edit; a corrected sample arrives as
  delete+add. Both halves are applied (the removal drops the old contribution,
  the new sample adds its own), which is covered by
  `testRemovalAndCorrectionAdjustExactlyOneContribution`.
- **Legacy upgrade.** A pre-#192 Date watermark does not decode as an anchor, so
  the first pass after the upgrade reads the full history once and rebuilds the
  ledger — idempotent for weight (`measured_at` key) and authoritative for
  energy (that window is the complete sample set for the days it covers).
- **Degraded path.** `SupabaseWeightLogStore` (constructed only when no local
  store could be opened) has nowhere durable to keep a cursor, so it reports
  none and keeps the previous full-history read, with day totals always
  recomputed from the complete sample set (never a delta overwrite).
- **Real HealthKit reader.** The `HKAnchoredObjectQuery` path is
  compile-verified and exercised through the scripted reader seam; no
  physical-device HealthKit run is claimed (#172 owns device acceptance).
- **Doc drift (out of fence).** `docs/NATIVE_JOURNAL_PROVENANCE.md` quotes the
  pre-#192 ViewModel comment text ("One independent body-mass pass
  (anchor-bounded re-import) …"). The doc is outside this lane's fence and was
  deliberately not edited; its pins (`app/native-journal-provenance.test.ts`)
  do not read that excerpt.

## Files

| File | Change |
| --- | --- |
| `app/Sources/Morsel/HealthKitWeightImporter.swift` | anchored reader seam + delta passes + observer handler |
| `app/Sources/Morsel/LocalHealthStore.swift` | `sample_id` column, ledger table, injectable calendar, schema split |
| `app/Sources/Morsel/LocalHealthStore+Delta.swift` | **new** — durable cursors + atomic window application (ledger) |
| `app/Sources/Morsel/HealthLogStores.swift` | window/delta protocol, sample identity, mock + Supabase conformance |
| `app/Sources/Morsel/ViewModel.swift` | foreground passes share the importer's cursor ownership |
| `app/Tests/MorselTests/HealthDeltaImportTests.swift` | **new** — the AC1–AC5 regressions |
| `app/Tests/MorselTests/HealthDeltaTestSupport.swift` | **new** — scripted anchored readers |
| `app/Tests/MorselTests/*.swift` (5 files) | reader mocks conform to the anchored seam; cursor assertions |
| `app/Morsel.xcodeproj/project.pbxproj` | xcodegen output for the three new files |
| `docs/evidence/issue-192-health-delta/` | this evidence |

Gate receipts: `GATES.md`. Machine-readable receipts: `native/run.json`.
