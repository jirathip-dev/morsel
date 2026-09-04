# Issue #106 evidence — native data reliability

Implementation lane: `impl-106-data` (branch `issue/106-data-reliability`, base
`376fb79` = #105 final reviewed head). See `docs/APP_DATA_RELIABILITY.md` for
the design and `docs/DATA_MODEL.md` for the server contract delta.

## Scope delivered

- Account-scoped SQLite local store (system SQLite3; no new package) + meal
  outbox + snapshot caches + local-first Apple Health rows.
- Local-first repository: durable single-transaction meal commit with a
  client-generated idempotency key, honest `pending sync` / `needs attention`
  journal markers, cache-first paint, cache preservation on remote failure.
- Single-flight per-account sync engine with server-side conflict guard
  (migration 0010 adds `log_meal_with_items_client`; the original server/MCP
  RPC is untouched).
- HealthKit reliability: per-type independent import (bodyMass +
  activeEnergyBurned ONLY), watermark-advanced bounded re-import, per-kind
  observers registered independent of remote results, single-flight
  coalescing, durable local-first upload drain, calm status copy + retry.
- Migration ledger/recovery contracts updated for 0010 (canonical files,
  names, routine owner/grants, converge statements, reconcile sentinels).

## Gates (final head)

| Gate | Command (from repo root) | Result |
| --- | --- | --- |
| XcodeGen byte-stability | `cd app && xcodegen generate && git diff --exit-code -- Morsel.xcodeproj/project.pbxproj` | exit 0 at the committed head (`XG-STABLE=0`) |
| Native test | `/usr/bin/xcodebuild test -project app/Morsel.xcodeproj -scheme Morsel -destination 'platform=iOS Simulator,id=59DDC0C5-891E-4EC0-91AF-4F50DF68D793' CODE_SIGNING_ALLOWED=NO -derivedDataPath .agent-runs/dd-final3` | **TEST SUCCEEDED — 143 tests, 0 failures** (log: `native-test.log`) |
| SwiftLint | `swiftlint lint --strict` (repo-root `.swiftlint.yml`) | exit 0, 0 violations (log: `swiftlint.log`) |
| Repo vitest | `LC_ALL=en_US.UTF-8 npm test` | 34 files / **413 tests pass**; full-suite exit code is 1 due to a pre-existing vitest worker-teardown RPC timeout (`Timeout calling "onTaskUpdate"`) — reproduced identically at pristine base `376fb79` (412/412 pass, same exit 1). Per-file runs exit 0 (logs: `npm-test.log`, `npm-test-integration.log`; pristine-base parity run: `logs/npm-test-base-parity.log` — 412/412 pass at `376fb79`, identical exit-1 timeout) |
| Typecheck / eslint / tsc build | `npm run typecheck` / `lint` / `build` | all exit 0 |
| Migration recovery integration | `npx vitest run db/migration-recovery-integration.test.mjs` | 21/21 pass on disposable PostgreSQL |
| `git diff --check` (whole tree) | at final head | exit 0 |

## RED → GREEN (AC3 “Add meal does not save”)

- RED at base (network-first): `AddMealReliabilityRegressionTests` failed with
  2 assertion failures — a committed write followed by a failing reload was
  reported as “not saved” (log: `red-regression.log`, 1 test / 2 failures).
- GREEN at head: same test passes (native-test.log); save succeeds without a
  second blocking `loadToday`, the journal shows the queued row with
  `pending sync`, and duplicates are impossible via the client id + server
  conflict guard.
- Covered regression scenarios (native suites): offline durable save +
  relaunch recovery, timeout-after-server-commit retry (single insert),
  repeated transient failures then success, double `syncNow` never
  duplicates, photo upload failure retry (deterministic object, no meal
  missing its photo, no orphan on permanent refusal), RLS/auth refusal →
  preserved `needs attention` row, pending delete cancels the outbox, cache
  preserved on remote failure, cached first paint, cross-account isolation.

## Honest limitations

- HealthKit on-device background delivery and TestFlight acceptance are
  HUMAN-GATED: this lane reports simulator test evidence only (XCTest mocks
  through the production seams) and never claims device behavior.
- Simulator screenshots: not captured — the pending/needs-attention markers
  are plain `Text` rows whose copy + wiring are asserted by the native suites
  (e.g. `MealSyncState.rowCopy` pins and snapshot-state tests); pixel capture
  would not add contract coverage and the lane has no device claim.
- Raw gate logs were whitespace-sanitized and then force-committed past the
  repo `logs` ignore rule (git diff --check clean at the final head).
