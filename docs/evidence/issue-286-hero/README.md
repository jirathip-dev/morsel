# Issue 286: dated targets in the selected-day hero

## Mechanism and scope

`SupabaseDashboardRepository.loadToday` now reads `get_dated_targets` for a
non-today date. The optional value travels in `DashboardSnapshot`, through the
local-first merge and SQLite cache, to the production `JournalHeroView`.
`DatedTarget.attributableGoal` uses the existing provenance validator (date,
timezone, observation cutoff, source version, revision identity and total),
then validates the saved macros. Calories include the persisted confirmed
addition; macros remain those of the saved baseline.

The hero never uses `snapshot.goal` or today's training-fuel baseline for a
past date. Missing, legacy, invalid or unreadable provenance displays
“Target unavailable for this day” alongside the unfilled ring/strips. A known
zero is not relabeled unavailable. Today's branches still use
`TrainingFuelModel.baseline` and `.target`; the latter includes the confirmed
day-only addition. No font, artwork, History-ledger, server or migration changes.

## Prospective capture: reuse, not a second writer

Migration 0014 already observes actual profile/goal/weight/meal-insert writes
and today's confirmed-addition RPC. Its read selects the latest observation
before the following local midnight, carrying an observed baseline forward
without inventing earlier observations. This lane does not add a write-on-read,
backfill, fabricated target row, periodic client write, or a second capture API.

The opt-in proof uses the existing native `saveGoals` and
`saveDatedTargetAddition` methods against a disposable PostgreSQL database:

1. There is no usable baseline before the native write.
2. At the September 16 clock, native saves 2,400 kcal / P140 / C280 / F90.
   The production trigger creates the baseline revision; native explicitly
   confirms a 120 kcal addition through the existing RPC.
3. At the September 17 clock, native saves a different 3,000 kcal goal.
4. A new native client reads September 16 back as 2,520, with the same baseline
   revision identity. September 15 remains unavailable. September 18 carries
   forward 3,000 without creating/backdating a history row.
5. Native renders the saved date in Paper and Night. The bridge records real
   SQL readbacks and the HTTP request inventory before destroying its cluster.

This is local integration proof, not production adoption. Migration 0014 must
be installed and a real qualifying write must occur before a user's historical
baseline is attributable. The unchanged P1 TrainingFuel UI still calls its
session-local acceptance seam: this proof does NOT claim that its local note
is automatically persisted by that UI. The explicit dated-addition repository
RPC is durable; a local P1 note and a persisted dated addition are not the same
write path. No production row was read or written.

## Before evidence

Pinned source: `6ae782e8a606111de26b1171d48c3a96115d4b85` in a disposable archive.
Only `tools/HeroBeforeTests.swift` and its generated test-target membership were
overlaid. Production sources were unchanged. The two `286-before-*.png`
attachments mount the real `TodayView`, Wednesday September 16, with the owner's
reported aggregate numbers reproduced as one explicitly synthetic meal:
1,953 kcal / P124 / C162 / F80. Today's independent goal is 3,000.

Both themes show the empty ring and three empty strips with no denominators.
The issue's “Goal unavailable” wording is NOT on this pinned base: that readout
had already been removed. The captures and OCR record its absence rather than
claiming a reproduction of text that is not rendered. This is an unsigned Debug
simulator equivalent, not the installed TestFlight build 14 binary.

## Reproduce

Ordinary regression: `HeroDatedTargetTests` in the Morsel native test target.
It mounts the production Today page, checks rendered saved denominators against
a different current goal, checks explicit unavailable copy, tests today's
confirmed 200 kcal addition and Undo, and round-trips the provenance through
the real local-first SQLite cache. Its live sibling skips explicitly when the
opt-in bridge is absent; it never substitutes mocked results for live proof.

Live proof, from the repo root (own simulator, serialized native admission):

    mkdir -p /tmp/morsel-286-pg
    TMPDIR=/tmp/morsel-286-pg npx vitest run --config db/hero-native.config.ts

Wait for `.lane-logs/hero-native/ready.json`, then run the native
`HeroNativeRoundTripTests` class on the admitted simulator. The bridge is
loopback-only, uses a synthetic account, requires the fixture bearer token,
executes owner-scoped SQL for each API request, and has a bounded deadline.
Only database clock expressions are changed in the disposable cluster; original
routine definitions are restored. `readback.json` contains actual stored rows.

Mutation proof, after committing the code under test:

    flock /tmp/n.lock hermes-sim-task --name Morsel286-mutation -- \
      python3 docs/evidence/issue-286-hero/tools/mutation.py

The driver creates its own `/tmp/morsel-286-mutation-*` git archive and replaces
only the hero's past-goal resolution with `trainingFuel.baseline`. It records
native RED, restores byte-exactly, touches the restored source for incremental
build invalidation, and records native GREEN. SHA-256 bookends pin both the
archive and original checkout. It never mutates this worktree.

## Capture interpretation

Images are XCTest attachments from scene-backed `UIHostingController` windows,
393 × 852 points at 3× (1179 × 2556 pixels), with actual Paper/Night device
appearance overrides. They are production-page renders, not physical tap or
full authenticated-shell evidence. The synthetic totals are reproduction inputs,
not newly retrieved owner meal data. Original attachment bytes are retained.
