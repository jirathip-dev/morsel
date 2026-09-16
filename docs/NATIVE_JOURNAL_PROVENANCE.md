# Native journal provenance (#249)

## Decision

Keep the short in-source comments introduced by #168 / PR #246, but retain
all removed comment lines here rather than letting the 400-line file budget
silently erase their rationale. No further provenance is removed from
`MorselApp.swift` or `ViewModel.swift` for this fix; only pointers to this note
are added there, without changing behavior or exceeding the line budget.
This note is the repository entry point for #110, #112, #121, #153, #173,
#175 and #176. The excerpts below are historical rationale, not a claim that
every original UI placement remains current (for example, row artwork now
uses illustrations rather than the older thumbnail presentation).

The source is commit `6f87585d2a8c1bac49237a7a4ac6654297619dbb` (PR #246).
To recover each block in its original method context:

```sh
git show 6f87585d2a8c1bac49237a7a4ac6654297619dbb^:app/Sources/Morsel/MorselApp.swift
git show 6f87585d2a8c1bac49237a7a4ac6654297619dbb^:app/Sources/Morsel/ViewModel.swift
git show 6f87585d2a8c1bac49237a7a4ac6654297619dbb -- app/Sources/Morsel/MorselApp.swift app/Sources/Morsel/ViewModel.swift
```

## Where to look for the why

- #110: `coverColorScheme` reasserts the chosen theme on presented covers,
  not just the root window.
- #112 and #173: `updateCalmStatus` and `syncedKinds` must not confuse an
  unanswered read-permission prompt with permission granted or denied.
  HealthKit share status cannot prove read permission. Only matching per-type
  upload timestamps can name the kinds that actually synced; async checks
  keep the MainActor responsive. See also the import-pass excerpts below.
- #121: `timezoneSync` mirrors the device zone on launch/foreground so app
  and server bucket the same local days. Calendar arithmetic, not fixed
  86,400-second offsets, remains authoritative. See
  [local days](DATA_MODEL.md#local-days-and-timezones-issue-121).
- #153: the edit sheet inherits the view model from the shell and attaches
  photos through the existing outbox/image path; queued rows remain pending
  until authoritative readback.
- #175: `JournalPageStage` retains each visited page/model/scroll for the
  session; accepted navigation, not a transient turn, changes activation.
- #176: pager selection owns interaction; previews/outgoing pages own none.
  Overlays supersede page interaction. Shell-owned presentations survive
  turns and inherit the model because the environment wraps their anchor.

## Archived comment lines

These are the removed comment lines, in original order per file, including
related local-first and #113/#111 rationale. Gaps between original source
blocks are omitted; the commands above recover their placement.

### `MorselApp.swift` (28 removed comment lines)

```swift
/// Issue #175 — the journal page area: one page per visited tab, created by
/// its first accepted navigation and kept for the signed-in session, so no
/// settle, retarget or revisit replaces a page, its model or its scroll. The
/// stage owns the page set, so an accepted navigation invalidates the stage
/// and the retained page sees its new activation; the shell starts on Today.
    /// Issue #176 — true while the shell's overlay (Add Meal / Menus) covers
    /// the pages: the overlay owns interaction then, so no page may.
    /// Issue #176 — the declared active page is the pager's selection: a
    /// committed swing declares its destination at once, a drag preview or
    /// rollback leaves the settled page in charge, and a presented overlay
    /// owns interaction instead of any page. Offscreen, outgoing and preview
    /// layers own nothing on any channel: touch, control activation or
    /// accessibility.
    /// Issue #176 — Today's presentations live here, outside the pages: a
    /// turn cannot dismiss, duplicate or orphan them.
    /// Issue #110 — the presented cover re-asserts the preference-derived
    /// scheme (a Paper/Night switch re-inks the cover, not only the window).
    /// Per-account local-first stack; remote-only fallback when unavailable.
    /// Issue #121 — mirrors the device zone to profiles.timezone on launch and
    /// foreground (server day math uses the same zone).
        // Issue #153 — the Edit-item sheet loads its photo through the view model.
        // Issue #176 — the shell anchors the Today presentations it owns (the
        // environment object wraps the anchor whose sheets inherit it).
            // Issue #175 — the page stage records the accepted navigation; only
            // Today's shared model refresh is left here.
    /// Three primary journal pages: plain fade under Reduce Motion, hinge otherwise (#111).
    /// Issue #175 — `tab` is this path's settled page; the stage owns the page.
    /// Issue #176 — the route overlay owns interaction while it covers them.
```

### `ViewModel.swift` (45 removed comment lines)

```swift
    /// Issue #113 amendment C — the SAME #112 calm-status stamp that feeds
    /// `healthStatus` drives the margin note's time (never a second clock).
    /// Nil when no Apple Health upload has ever succeeded locally.
    /// User-invokable Health retry/reconnect (Settings): re-request
    /// authorization, re-import BOTH types independently, and queue the
    /// durable upload pass.
    /// Imports body mass and active energy INDEPENDENTLY (one type's
    /// denial/query failure never suppresses the other), registers both
    /// observers immediately (independent of any remote result), and queues
    /// the durable background upload of locally stored rows.
        // Local-first paint: show the last cached snapshot immediately, then
        // converge with the authoritative remote state in the background.
    /// Saves a meal. At the final head the repository durably commits the
    /// meal (meal + items + photo in one local transaction) BEFORE returning,
    /// so this succeeds without waiting for a second full remote loadToday —
    /// the Add-Meal page closes and the journal shows the row with an honest
    /// `pending sync` marker until the authoritative server result is read
    /// back and reconciled.
    /// Optimistic journal row for a locally committed (queued) meal — the UI
    /// must not wait for a reload to show what the user just saved.
    /// Issue #153 — attach/replace the photo of an item's parent meal
    /// through the same outbox/image pipeline as Add Meal. The journal
    /// reloads so the row (and its thumbnail) reflects the photo; a queued
    /// row stays honest with its `pending sync` marker until the server
    /// result is read back.
    /// One independent body-mass pass (anchor-bounded re-import); returns
    /// the number of samples durably stored. Throws so the caller can keep
    /// the two types' cancellation semantics independent.
    /// Observer callback failure: map through the human copy table and
    /// re-derive the calm status as if both imports failed with zero rows.
    /// Calm status derivation (issue #112 — truthful per type). Read-side
    /// truth comes from the typed reader seam (getRequestStatusForAuthorization
    /// — never share status, which stays false for the toShare: [] request):
    /// a still-pending read prompt means the app cannot make ANY claim for
    /// that type, so the status is `permissionRequired` — never a green
    /// "synced". `synced` names only kinds whose per-type upload mark matches
    /// the last successful pass stamp; a decided read with zero body-mass
    /// rows anywhere is the calm `noWeightData` state.
    /// Issue #173: the two per-type status reads are AWAITED async — the
    /// MainActor stays responsive while HealthKit answers; an unanswered or
    /// errored query (`false`) is "cannot claim", never denied and never
    /// treated as proof that read access was granted.
    /// Kinds that uploaded ≥1 row in the pass stamped `stamp`. The sync
    /// engine writes each per-type mark with the SAME time as the last
    /// successful upload, so equality identifies the pass (issue #112).
```

## Month-span read contract (#249)

The calendar requests one overview for day 1 through the selected month's
last elapsed local day. `HistoryRepository.loadHistory` admits 1–31 days,
so a completed 31-day month no longer needs a second first-day overview.
That second read previously failed before publishing *any* of the loaded
colours, even though the independent presence index had already published.

This is one overview operation and one bounded meal-log query, not one HTTP
request for the entire calendar: the index and the overview's existing
logs/items/goals/profile/weight/dated-target reads remain separate. No read
batching, cache policy, target comparison or timezone contract is redesigned.
`LocalFirstDashboardRepository` forwards the requested day count and keys the
cache by end date plus count, so 30- and 31-day overviews do not collide.
The History ledger's explicit 7/30-day presets and its fixed 30-day weight
trend are independent contracts and remain unchanged.

`JournalMonthSpanTests` drives the model through the real Supabase history
adapter with controlled transport, then makes any second overview's goal
read fail. Both edge days retain their over-target comparison inputs.
It also checks short/leap months, partial months and local range boundaries
across US daylight-saving transitions. Existing calendar/diary tests cover
presence, navigation, cached-day publication and superseded reads.
