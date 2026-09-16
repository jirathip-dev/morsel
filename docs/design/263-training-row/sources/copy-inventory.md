# Exact-source copy and constraint inventory — issue #263

Base: `2d87d61e73c6c3db7bd1420294ccf1551232405d`.
Repository: `/Users/jirathip/.herdr/worktrees/morsel/design-263-training-row`.
All line references below are to that immutable base, not to proposed prototype copy.
The `.swift.txt` references are byte-for-byte copies of the current checkout, verified equal to base and SHA-256 pinned in `source-hashes.json`.

**P1 is session-local, not durable/synced.** Preserve this explicitly in the redesigned sheet. A confirmed fixture must never imply a server save, Health write, or future/history target change.

## Authority and allowed redistribution of content

- `issue-263.json`: unmodified `gh issue view --json` output, including body and all comments; REST comment count independently checked in `issue-263-api.raw.json`.
- Owner decisions are final. The Today row opens a three-section sheet: **Today's answer → Readings → About this context**. Undo is sheet-only. No Movement/Workout figures, timestamps, caveats, toggle, or receipt remain in this Today surface.
- The row labels are exactly the owner-approved state vocabulary: `Usual day · 2,126 kcal`, `Training day · 2,426 kcal`, and `Usual target · unavailable`. The numeric examples are owner-provided illustrative states, **not** an amount suggestion, default input, or live record.
- New entry is blank. Editing may load the user's already-confirmed amount (the model already does this); never substitute a suggested amount.
- Half (a) goes to owner review first. This bundle is only the font/source prerequisite for half (b), **not** the deferred exhaustive app-wide numeric before/after gallery or permission to implement it.

## Every visible string in TrainingFuelViews.swift

`V` below means `app/Sources/Morsel/TrainingFuelViews.swift` / `TrainingFuelViews.swift.txt`. Adjacent Swift string literals are joined here exactly as displayed; interpolations remain explicit.

| Source | Current exact copy / dynamic source | Preserve or move in issue #263 |
|---|---|---|
| V:9,66–77 | `TrainingFuelReceipt` (date and three target statements, enumerated below) | Fully collapse Today receipt into the one row. Detailed provenance belongs inside the sheet, without implying three separate targets. |
| V:10 | `Food-target comparison, not a fuelling assessment.` | Sheet / About this context. Retain the explicit non-assessment constraint. |
| V:13–14 | `Movement`; `Workout` | Sheet / Readings, separately labelled. |
| V:15 | `Movement includes activity beyond workouts. It is context, not a calorie bonus.` | Sheet / About this context. Neither Workout nor Movement creates an automatic addition. |
| V:17 | `About this context` | Third sheet section, using the approved journal language rather than silently retaining the old system DisclosureGroup. |
| V:18–21 | `Health may be missing or not shared; that does not mean a rest day. Dates belong to the samples, and checked times describe these reads. Overlap with your usual target is unknown. For a personal fuelling plan, consult a sports dietitian.` | Sheet / About this context. All four clauses are independent honesty requirements; do not remove any. |
| V:23–25 | `Read Apple Health` | Sheet / About this context; keep explicit read action and ≥44 pt target. |
| V:27 | `I consider today a longer or harder training day` | Sheet / Today's answer. User-authored context, not inferred from Health. The settled concept name is “Training day.” |
| V:30–31 | `Today-only note confirmed`; `Longer session — review today's fuelling?`; `Usual target unchanged` | Old conditional status copy; replace Today presentation with the approved row states. Do not mistake longerDay alone for a confirmed addition. |
| V:33 | `No amount suggested.` | Sheet / Today's answer; keep this policy conspicuous. |
| V:34–37 | `Review today's plan`; `Edit today's note` | Today now opens the sheet via the row. Explicit confirmation/edit controls live within it. The old target-unavailable disablement is not the approved row behavior. |
| V:39–41 | `Undo adjustment` | Sheet only. Remove only the day-only addition. |
| V:48–49 | `This session only · not synced. Saved goals and macros stay unchanged.` | Sheet: preserve both session-local and unchanged-goals/macros claims. Do not upgrade the persistence claim. |
| V:57 | `\(title) · \(TrainingFuelContext.value(value))` | Sheet / Readings; value unavailable is independently possible for either type. |
| V:59 | `Apple Health · no readable data` | Sheet / Readings fallback. Missing/denied/errors cannot silently become zero or a rest day. |
| V:71–72 | `day.formatted(date: .abbreviated, time: .omitted)` | Date attribution remains available inside the sheet. Formatting is locale-dependent, not a fixed English date string. |
| V:74 | `Usual \(model.baseline?.source.rawValue ?? "unavailable") target` | Owner-approved Today wording is “Usual target” (or the exact “Usual day” row state). `computed` may occur only inside the sheet as actual provenance, never in the new Today label. |
| V:75 | `Confirmed for this day`; prefix `+`; absent `Not confirmed` | Sheet detail if needed. The addition is distinct from the effective target; do not present a second/third Today target statement. |
| V:76 | `Today's food target` | Effective target is what the one Today row carries. |
| V:81–87 | Default absent `Unavailable`; value `\(prefix)\($0.formatted()) kcal` | Preserve honest absence, unit, and distinction between addition and effective target. The baseline receipt uses `.morselData` (mono), not an already-migrated serif. |
| V:98 | `Today's fuelling note` | Existing editor heading only; settled redesign is the “Training day” concept with three ordered sections. |
| V:100–101 | `No amount suggested. Enter an addition from your own plan. This screen cannot assess adequate fuelling.` | Sheet / Today's answer, with non-assessment caveat also retained in About. Never supply a model-generated or Health-derived amount. |
| V:102 | `Add to this day's food target (kcal)` | Sheet amount label; explicit day-only and addition semantics. |
| V:103–109 | `Your amount` | New-entry placeholder, not numeric content. Existing decimal keyboard and pending disablement are constraints. |
| V:110–114 | `I choose a day-only change; keep my saved manual goal.` | Sheet / Today's answer; explicit manual-goal acknowledgement before confirmation, not a generic always-checked consent. |
| V:116–117 | `Applying local note… Target unchanged until confirmation completes.` | Pending state: retain the old effective target until successful completion. Do not say “Saved”/“Synced.” |
| V:119–120 | `model.error` | Exact errors are listed below. Keep failure visible and preserve unchanged-target semantics. |
| V:122–127 | `Confirm for this day`; `Retry confirmation` | Explicit submission/retry. Disabled unless current model validation and consent pass. |
| V:128–130 | `Cancel` | Dismiss/cancel without applying the draft; late completion must not apply it. |
| V:131–132 | `Local to this signed-in session, not saved to Health or synced. No meal, future goal or historical target changes.` | Sheet: preserve the full persistence/scope boundary. This is not redundant with simply “day-only.” |

## Model constraints and exact error copy

`M` = `TrainingFuelModel.swift` / `TrainingFuelModel.swift.txt`.

| Source | Verified behavior / exact copy | Prototype/spec constraint |
|---|---|---|
| M:4–6 | `P1 is a user-authored note, not an exercise-calorie calculation.` Session-local until a durable contract is approved; no repository, meal, Health, or saved-goal write capability. | Do not infer durable storage from the separate dated-target RPC/schema. |
| M:10–16,39–45 | Baseline and addition are read only for the current day; effective target = baseline kcal + confirmed addition. No current baseline → nil target. | Unavailable row never borrows today's/past/other target or substitutes a number. |
| M:19,24 | `draft = ""`; longerDay is explicit user context, never inferred from Health. | Blank unconfirmed amount; missing Health does not mean rest, and toggling longerDay alone does not confirm. |
| M:46–50 | Manual baseline requires acknowledgement; canConfirm also requires editing, not pending, current day, and valid amount. | Demonstrate manual-goal consent, pending disablement, blank and invalid states independently. The base model does **not** require longerDay to be true in canConfirm; do not silently describe such a new validation rule as existing behavior. |
| M:51–60 | Trim whitespace; respect current locale decimal separator; finite positive amount; baseline present; finite resulting sum. No clinical upper bound, preset, recommendation, negative/zero entry, or target reduction. | Invalid input must not change the target. Zero/removal uses Undo, not numeric entry. Base only disables invalid confirmation; any explanatory validation wording added to the prototype is **new design copy**, not an exact-source quote. |
| M:63–78 | Timezone change resets; day rollover resets; only today's dated snapshot can supply baseline. Today's baseline revision preserves confirmed addition. A nil goal observation does not erase an already-known baseline. | Do not simulate a nil-goal partial/queued-meal snapshot by deleting a previously valid same-day target. Loading/partial meals are not automatically target absence. |
| M:81–87 | beginReview refuses non-current day, absent baseline, or pending. New draft blank; edit preloads the confirmed addition as String; acknowledgement resets false. | The approved unavailable row must open a sheet even though this base entry point refuses it: a future presentation change is required. The sheet may show context but must not enable an unavailable-target write. |
| M:89–94 | Cancel changes the operation token and clears editing/pending/error. | No draft application after cancellation. |
| M:96–116 | Successful completion sets the confirmed addition only after accept returns and current-day/token guards pass. Failure does not assign it. | While pending or failed, prior target/addition remains. Confirmation is local, not a network save. |
| M:107 | `The day changed. Nothing applied; cancel and review the new day.` | Preserve rollover error and explicitly restart/review the new day. |
| M:116 | `Could not apply this local note. Nothing changed. Retry or cancel.` | Preserve honest failure, retry, and cancel. No invented success or background retry. |
| M:120–125 | Undo requires current day and not pending; clears confirmed addition, draft, acknowledgement, and editing/error via cancel. | Undo only the day-only addition; saved baseline/macros remain. `longerDay` itself is not reset by undo, so the approved row state must follow confirmed addition, not the longerDay flag. |
| M:128–135 | Reset clears baseline, addition, draft, consent, longerDay, and Health context. | No stale prior-day note/Health context should silently become today's data. |

## Readings, timestamps, and partial Health states

| Source | Exact copy / evidence | Constraint |
|---|---|---|
| `TrainingFuelContext.swift`:9–16 | Same-date prefix `Recorded`; otherwise `Last known · not today's total`; detail `\(freshness) · \(stamp(sampleDate))\n\(source) · checked \(stamp(checkedAt))`; date+time abbreviated/short | Show the **real sample date** when stale, and separate sample time from checked time. A fresh check does not freshen an old sample. |
| `TrainingFuelContext.swift`:20–24 | Independent movement/workout optionals; missing value `Unavailable` | Exercise neither/both/Movement-only/Workout-only states. No fabricated zero. |
| `TrainingFuelHealthReader.swift`:3–5,9–21 | Read-only; permission-prompt success does not prove readable data. Unsupported Health/permission request failure returns empty context. Each type queried independently with `try?`. | Base cannot distinguish absent data, denied sharing, unsupported device, and read errors from values alone. A distinct “Denied” UI cannot be claimed as detected by this model. Use honest missing/not-shared wording, or clearly label an illustrative external fixture rather than inventing a permission signal. |
| Reader:24–34,38–59 | Most recent sample; Movement is cumulative active energy over that sample's day. Source `Apple Health · active energy`; value `<formatted total> kcal`. Comment: do not sum workout into Movement or use body-mass upload stamp. | Do not add Movement + Workout calories, do not claim current-day total for stale sample, and do not tie training data freshness to weight import freshness. |
| Reader:62–75 | Most recent workout, not a daily aggregate. Activity strings `Run`, `Walk`, `Cycling`, `Swim`, `Strength training`, fallback `Workout`; value `<name> · <formatted minutes> min`; source `Apple Health · <sample source name>`. | Preserve workout type, duration, original sample date/source, and checked time. Do not infer all-day workout duration/count from one sample. |
| `TrainingFuelHost.swift`:14–20,26–45 | StateObject belongs outside transient journal pages; sheet bound to isEditing; refresh on task/active/significant-time-change; discard result if cancelled/day changed. | No changes to native flip/route/focus/gestures. Distinguish draft/editor presentation from durable data. |
| `Views.swift`:192–199 | Explicit button closure calls `read(requestPermission: true)` and checks day before publishing context. | Keep Read Apple Health in the third sheet section. No Health writes. |

## Source gaps / tensions to report, not silently substitute

1. **Unavailable sheet entry:** the issue requires the unavailable row to open the sheet; base `beginReview` refuses a missing baseline (M:81–82), and base review button is disabled (V:37). This is a deliberate redesign gap, not already-working behavior. Do not fake a target to make the editor reachable.
2. **P1 versus durable dated targets:** `DatedTargets.swift`:132–169 provides a separate persisted RPC seam and `docs/DATA_MODEL.md`:19–26 / `docs/MCP_TOOLS.md`:10–29 describe durable dated-target contracts. However, TrainingFuelModel has no repository capability and TrainingFuelHost constructs its default session-local model. Do not change the source's “not synced” copy on the strength of unrelated RPC existence.
3. **One Today target is wider than receipt removal:** base `Views.swift`:142–166 also shows `Eaten · Goal`, `/ <target> kcal`, a remaining/over value, and `source: <goal.source>`, outside TrainingFuelReceipt. Merely hiding the receipt does not literally leave one target statement or remove computed provenance from Today. Parent must explicitly account for this base surface against the settled issue acceptance wording; these proof artifacts make no substitute design decision.
4. **No separate Health read-status enum:** missing/denied/error are collapsed into unavailable optionals at this base. A mockup may exercise distinct externally-labelled scenarios, but it must not claim this production reader diagnoses denial or a read error separately.
5. **Numeric keep-mono wording:** the final decision says mono **only** for genuinely technical strings, while the issue's inventory bullet also names “settings rows, auth wordmark.” This evidence does not silently classify every settings value or an auth wordmark as technical. The deferred half-(b) surface inventory must disclose that wording tension and resolve exact scope under its owner gate; no app-wide change is made here.
6. **Existing tabular modifiers are not the surface inventory:** there are four `.monospacedDigit()` sites at base, and none is in TrainingFuelViews. The issue's “20 files” numeric inventory is not re-certified by this narrower modifier proof. Full before/after coverage remains deferred.
7. **Table capability is not rendered alignment:** the real font has all four features, and its digit advances are proven. Browser/CSS and CoreText/SwiftUI selection, fallback, kerning/GPOS, punctuation, and final column layout are not rendered or accepted by this task.

## Binding external constraints retained verbatim in intent

- Preserve approved Variant A visual language, ART-SPEC palette/tokens and bundled fonts; app-wide numeric voice remains behind its own owner-approval gate.
- P1: user-authored; day-only; blank new amount; no suggestion; explicit confirmation; manual-goal consent; undo only the addition.
- No adequate-fuelling claim. Movement is context, not a calorie bonus. Missing Health is not rest.
- All interaction targets ≥44 pt. No native flip/navigation/calendar behavior change.
- Rows remain illustrated (#223); photos are detail-only. Multi-meal/partial cases do not change target semantics or turn menus into meal boundaries.
- #226 stays open for P2/P3 and device-only HealthKit acceptance.
- This subtask does not implement, render, commit, push, open a PR, modify GitHub, or write to app/Swift/DB/product sources.
