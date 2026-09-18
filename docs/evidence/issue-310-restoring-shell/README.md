# Issue 310 — cold-launch restoring shell, native simulator evidence

These are simulator fixtures, not a physical-device or live-auth acceptance run. Every meal, item,
goal and account value is a fictional test input. No amount is a suggestion, preset or shipped
recommendation.

## What these captures test

The owner-reported defect: opening the app sometimes showed a **brief login page** before the
dashboard, and the flash lasted noticeably longer when the stored access token had to be refreshed.

Cause (verified in source at the base this lane started from, `f1d657b`): `MorselRootView` routed on
the session alone and `SessionStore` started *resolved-but-empty* (`session = nil`,
`pendingRoute = .initialSetup`). SwiftUI evaluates the shell's `body` before
`.task { await sessionStore.restore(using:) }` runs, so the **first frame** was onboarding — or
sign-in when the route had been deferred — while a valid stored session was about to be restored.
The window lasted exactly as long as the token refresh. `restore` also swallowed failure
(`session = try? await auth.restoreSession()`), so "the refresh failed" and "you are genuinely signed
out" were the same state.

Fix (this lane): `SessionStore` carries an explicit **phase** — `restoring` → `signedIn` /
`needsSetup` / `needsSignIn` — plus an explicit `RestoreFailure` record (`refreshFailed` /
`timedOut`) and a bounded restore window; `MorselRootView` decides the unresolved phase **first** and
renders the existing paper-skeleton language (`RestoringShellSkeleton` → `TodaySkeleton`), and only a
resolved phase may render the dashboard, onboarding or sign-in. There is **no** view-level timer and
no minimum-display delay: the skeleton lasts exactly as long as the phase is unresolved, and the
failure bound (10 s) lives in the state, not in the view.

## How these captures were minted

The **real shipped root view** (`MorselRootView`, mounted with a scene-backed `UIWindow` at
390×844 pt) is driven by a restore attempt the test owns (`DeferredRestoreAuth`): `restoreSession()`
parks until the test releases it with a stored session, with **no** session, or with a **thrown**
refresh failure — i.e. the deliberately slow / failing token refresh the issue is about. Each theme
is set both by the device appearance and by `preferredColorScheme` on the mount.

| case | how the attempt answers | what the shell must show |
|---|---|---|
| `stored-session` | releases a stored session after a parked (slow) window | skeleton → dashboard, **no** auth surface |
| `fresh-install` | releases *no* session | skeleton → onboarding |
| `expired-refresh` | throws (the stored refresh token no longer works) | skeleton → **sign-in**, with **no onboarding frame in between** |

`stored-session` mounts the production `SupabaseClient` over the shared `StubTransport` (no network)
with one fictional lunch (`jasmine rice`, 300 kcal, 1.5 serving) stamped at the running day, so the
settled frame is a populated journal rather than an error page.

## What each frame is, and what decided it

| file | surface | assertion that decided the capture |
|---|---|---|
| `310-<theme>-*-restoring.png` | paper/night skeleton | capture is **byte-equal** to a reference mount of `RestoringShellSkeleton` and **byte-different** from reference sign-in and onboarding mounts; `store.phase == .restoring` |
| `310-<theme>-stored-session-settled.png` | populated dashboard + tab bar | `phase == .signedIn`, published phase sequence `[.restoring, .signedIn]`, capture ≠ sign-in and ≠ onboarding |
| `310-<theme>-fresh-install-settled.png` | onboarding | `phase == .needsSetup`, sequence `[.restoring, .needsSetup]`, capture **equals** the onboarding reference |
| `310-<theme>-expired-refresh-settled.png` | sign-in | `phase == .needsSignIn` + `restoreFailure == .refreshFailed`, sequence `[.restoring, .needsSignIn]` (**no `.needsSetup`**), capture **equals** the sign-in reference |

The three `*-restoring.png` frames are byte-identical per theme (the restoring surface does not
depend on which session answer is coming) — visible in `captures/` as equal file sizes.

## Commands

```sh
cd app && xcodegen generate && swiftlint lint --strict
HERDR_XCODEBUILD_DIRECT=1 xcodebuild test \
  -project Morsel.xcodeproj -scheme Morsel \
  -destination 'platform=iOS Simulator,id=04F4ADE0-E1E8-4536-A16C-1D5D870C8EF4' \
  -derivedDataPath /tmp/morsel-310-dd CODE_SIGNING_ALLOWED=NO \
  -only-testing:MorselTests/RestoringShellRoutingTests \
  -only-testing:MorselTests/RestoringShellPhaseTests \
  -only-testing:MorselTests/RestoringShellRenderTests \
  -only-testing:MorselTests/RestoringShellSkeletonPaintTests \
  -only-testing:MorselTests/RestoringShellEvidenceTests
# 19 tests / 0 failures / raw exit 0  (.lane-logs/310-focused-r5.log)

HERDR_XCODEBUILD_DIRECT=1 xcodebuild test ... -resultBundlePath /tmp/morsel-310-evidence.xcresult \
  -only-testing:MorselTests/RestoringShellEvidenceTests
xcrun xcresulttool export attachments --path /tmp/morsel-310-evidence.xcresult \
  --output-path /tmp/morsel-310-attachments
# 1 test / 0 failures / raw exit 0; the committed PNGs are that run's exported attachments
```

All native legs ran under `flock /tmp/n.lock` (one heavy leg at a time — a sibling lane held the
lock for the first minutes of the focused leg) with `-derivedDataPath /tmp/morsel-310-dd`.

## Evidence receipts

`excerpts/` carries the exact command, the raw exit and the selected raw lines of every leg:

- `focused-family.txt` — the lane's classes at head (19 tests / 0 failures / exit 0).
- `evidence-run.txt` — the capture run (1 test / 0 failures / exit 0).
- `red-base-compile.txt` — base + the new tests: **exit 65, compile RED**
  (`'Phase' is not a member type of class 'Morsel.SessionStore'`) — the new state model does not
  exist at the pre-fix mechanism.
- `red-base-routing.txt` — base, routing contract only: **5 tests / 10 failures / exit 65**
  ("the shell must decide the restoring phase before anything else"; "a failed refresh must not
  collapse into the same nil as a genuine no-session"; no `RestoreFailure` state; no skeleton
  surface).
- `mutation-session-only.txt` — **the conductor's mutation proof**: the restoring branch removed
  (the shell routes on the session alone) → routing 1 failure + render 6 failures, **exit 65**; the
  parked window painted the *onboarding* surface (378 714 bytes) instead of the skeleton
  (225 701 bytes) — the reported flash, reproduced by the suite. The fixed file was restored
  **byte-identically** (`sha256 cd900bd48e2f8b8a1855382f0610656c93debeafcac520aa70434d9eebe23924`
  before and after; the mutated file was `aa3b5d30…`).
- `mutation-restored-green.txt` — the same classes after the restore: 8 tests / 0 failures / exit 0.
- `base-with-fix-absent.txt` — the three documented pre-existing reds at the base (fix absent):
  3 tests / 4 failures / exit 65.
- `native-full-head.txt` — the one complete unfiltered run at head: **643 tests / 3 skipped /
  5 failures / exit 65**; the four failing tests are `MealReliabilityTests
  .testOfflineAddMealCommitsLocallyAndPaintsPendingRow` (load-sensitive; focused rerun 13/0 exit 0 —
  `mealreliability-focused.txt`) plus the three pre-existing reds above. No `RestoringShell*` test
  fails in the full run.
- `hosted-probe.txt` — the retargeted `app/unauth-action-tint.test.ts` probe (eslint exit 0,
  vitest 7/7 exit 0) and the full `npm test` (701 tests, 2 failures, exit 1) with the load-timeout
  classification (`0` × `AssertionError`; both files pass 10/10 with `--testTimeout=60000`,
  diagnostic only).
- `gates.txt` — raw exits: `swiftlint lint --strict` 0, `xcodegen generate` 0 with a clean
  `git diff` afterwards, `npm run lint` 0, `npm run typecheck` 0, `git diff --check` 0.

## Explicitly unverified

- Physical devices (the issue keeps that in #172); no TestFlight dispatch, no PR, no merge.
- A real Supabase token refresh: the refresh is a test-owned async attempt that parks and then
  answers with a session, no session or a thrown failure. No production auth, session or data was
  touched, and no network request leaves the process.
- The 10-second restore bound is exercised at 150 ms through the injected `restoreBound`
  (the default value itself is asserted only as the initializer default).
- Health authorization: mounting the authenticated shell reaches the app's Health import, which in
  the simulator may leave a system permission sheet outside the captured window. The captures show
  the app's own window only; no Health state is asserted here.
- The dashboard case's day is a stub-transport fixture; the settled frame is a *rendered* dashboard,
  not a live read.
