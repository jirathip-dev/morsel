# Calendar diary — native simulator evidence (#168)

This is **unsigned iOS Simulator evidence**, not physical-device or live-account acceptance. The implementation follows the approved V1 frameless, hand-tab month grid (`design/168-calendar-diary`, `3d78638`) and the shipped Variant A components. Reference artwork, tokens, fonts and the existing History ledger were not replaced.

## Surfaces

| State | Paper | Night |
| --- | --- | --- |
| Month grid, presence dots | [Paper](screenshots/paper-month-grid.png) | [Night](screenshots/night-month-grid.png) |
| Past day in the existing Today layout | [Paper](screenshots/paper-past-day.png) | [Night](screenshots/night-past-day.png) |
| Empty day before the first log; previous disabled | [Paper](screenshots/paper-empty-boundary.png) | [Night](screenshots/night-empty-boundary.png) |
| Past-date Add Meal, **existing in-flow route** | [Paper](screenshots/paper-past-date-add-route.png) | [Night](screenshots/night-past-date-add-route.png) |
| Paused native hinge preview | [Paper](screenshots/paper-mid-flip.png) | [Night](screenshots/night-mid-flip.png) |

The calendar may be scrolled to expose the entire month and its legend. The ordinary History 7/30-day ledger and weight trend remain available. The two hand-tabs are a window over all available months; explicit month arrows avoid a nested horizontal scroller competing with the existing tab flip.

The Add Meal routing follows the scope amendment: no second Add Meal sheet was introduced. Its draft starts on the selected diary date. The dated title is on a separate line from Cancel/Save so those labels cannot collide.

## Production seams

- `DashboardViewModel` owns the selected date. Existing snapshot/cache and mutation paths use it; date-changing reads have publication-generation guards. There is one retained Today page, not a second Today implementation.
- `JournalCalendarRepository` reads an account-scoped, paginated date index independently of the bounded ledger query. Its local-first adapter caches that index and incorporates queued local meals without changing the photo/cache modules.
- History's Calendar mode and Today's calendar sheet use the same `JournalCalendarView` and model. Month totals supply dot colours; the full date index supplies presence and the earliest boundary.
- `JournalTurnState<Page>` is the existing tab state machine generalized over the page key. The `JournalTurnMachine` alias preserves its tab API. Date changes reuse its phases, cancellation tokens, hinge pose and animation driver.
- Vertical day gestures begin in the labelled date rail. Food-content vertical gestures remain scrolling. Horizontal navigation remains the existing shell's flip. Previous/next buttons provide non-gesture access; VoiceOver disables the rail drag, and Reduce Motion uses the existing reduced-motion path.

## Reproduction

Run `python3 docs/evidence/issue-168-calendar-diary/tools/prepare-capture.py` from this checkout. It creates an owned disposable checkout and prints its path after XcodeGen's output. The delivered checkout is never overwritten by a capture harness.

On an admitted lane-owned simulator, from that printed directory's `app/`:

```sh
HERDR_XCODEBUILD_DIRECT=1 xcodebuild test \
  -project Morsel.xcodeproj -scheme DiaryCapture \
  -destination 'platform=iOS Simulator,id=<your-owned-UDID>' \
  -derivedDataPath /tmp/xc-dd-168-capture CODE_SIGNING_ALLOWED=NO
```

Before a native run, check `pgrep -x xcodebuild` and `pgrep -fl 'xcodebuild|xctest'`; wait in bounded 60-second cycles, up to 30 minutes, if another native run is live. Do not run the full npm suite concurrently. Record the actual raw exit before inspecting output.

Export the resulting attachments with:

```sh
xcrun xcresulttool export attachments --path <result.xcresult> --output-path <output-directory>
```

Map the named attachments through the exported `manifest.json`, not file order. `capture-manifest.json` records the delivered images and hashes; `source-manifest.json` records the original app-source input bytes. The test fixture and preparation script are committed alongside the evidence.

### Fixture boundaries

The temporary build replaces only the entry point, supplies a synthetic repository/account to the real authenticated shell, suppresses onboarding, and fixes the diary's clock to 7 September 2026. The selected meal day is 14 August; the first logged day is 5 August; the empty boundary is 4 August. Locale is explicitly English/Gregorian. Add Meal still uses its normal current-time-of-day draft default.

No credentials, service responses or production data are used. The fixture is outside the shipped app target. `DiaryCaptureUITests` drives real simulator taps/drags and obtains `XCUIScreen.main.screenshot()` attachments. It also checks the shared sheet, month navigation, dated-title/button non-overlap, food scrolling, horizontal navigation/retention and vertical day navigation.

The mid-flip pictures are **paused previews**, not lucky timed captures of a moving finger: the disposable harness feeds the actual shared state machine a drag delta of 72 for an extent of 120, then leaves that preview visible. These images show the native renderer's preview state; they do not prove timing, subjective feel, or physical-device animation quality.

## Verification and limitations

`verification.txt` contains selected raw output and exit statuses from the actual runs. The lane report contains the complete command/log inventory, including failed attempts and admission waits. The base RED regression is assertion-level, not a missing-API compile failure. The mutation preparer reverses adjacency and removes the extra empty boundary in a separate owned checkout; the delivered source is never mutated.

Physical-device feel, live Supabase history/edit traffic, and a human VoiceOver session were not verified. The complete native suite exercises the existing cancellation, page-identity, ownership and Reduce Motion contracts; screenshots are not substitutes for those tests.

NOT MERGED; not opened as PR; no deploy; no production writes.
