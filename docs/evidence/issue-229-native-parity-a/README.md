# Issue #229 — native port of the approved Variant A journal rows and detail

Captured on the lane's dedicated simulator **`Morsel229-iPhone14`**
(UDID `D58CB64E-CD86-4DC6-AFB2-C6292BCC36CF`, iOS 26.5) — the same **390×844 pt**
viewport as the approved A reference captures — unsigned Debug build
(`CODE_SIGNING_ALLOWED=NO`, simulator, **not a physical device**), @3x device
pixels (1170×2532).

The captures drive the **real production views** with real taps (a throwaway
UI-test target): `TodayView` → `TodayLogSection`/`MealGroupView`/`MealItemRow`
→ `JournalFoodRow` → `MealArtworkSlot`/`JournalArtworkImageView`, plus
`JournalTabBar` and `MealItemEditSheet` (with `MealPhotoEditorSection`) over the
approved Variant A fictional lunch through the production `DashboardViewModel` +
the shared `MockDashboardRepository` (the repo's temporary `@main` harness
pattern; the harness replaced `MorselApp.swift` during the captures only and the
file was restored **byte-identically** — see the lane `.report.md`).

The five rows are the design's own fictional subjects (Focaccia bread,
Mortadella, Stracciatella cheese, Grilled vegetables, Unidentified side) from
`fixture.json`, so the row order, names, portions, kcal and macros match the
reference line for line. The first four items carry a **generated** storage
fixture image (flat warm field + dark oval) — never the prototype's public demo
photo and never a real user meal — so the sheet's stored-photo path really
renders.

## Captures (native, this lane)

| File | State |
|------|-------|
| `captures/{paper,night}-rows-top.png` | journal top: hero + the first rows |
| `captures/{paper,night}-rows-lower.png` | scrolled: all five A rows (incl. the neutral sign) |
| `captures/{paper,night}-detail.png` | food sheet opened by a real row tap (stored photo renders) |
| `captures/{paper,night}-edit.png` | sheet scrolled to the save block |
| `captures/{paper,night}-save-pending.png` | Save tapped, save in flight ("Saving…") |
| `captures/{paper,night}-save-failure.png` | Save refused, edit kept, error state |
| `captures/{paper,night}-updated.png` | saved: the row carries the confirmation |
| `captures/{paper,night}-rows-ax3.png` | the page at Dynamic Type `.accessibility3` |

`side-by-side/` composes each native state next to the approved A reference of
the same state (`reference/evidence/a-*.png`, imported from the pinned design
commit `68be41d1`), scaled to a common height.

## Measured row geometry (from the captures, device pixels ÷ 3)

- Row pitch between hairlines: **87.0 pt** on every row (`paper-rows-lower`),
  matching the design's `min-height:87px`;
- The row's own fit at 390 pt width is **87.0 pt** (native suite
  `ISSUE229-MEASURE food row width=390.0 height=87.0`), and it **grows** at
  accessibility text sizes instead of clipping
  (`ISSUE229-MEASURE row ax3 … height≈` printed by the suite);
- Artwork: 56 pt A study (224 px export downsampled), paint compared against
  the bundled export in the suite (`meanDiff≈0.95`, identical ink bounds).

## Honest capture limitations

- The harness window is the real app on the simulator; it is **not** a
  physical-device photograph, and the system status bar/battery chrome is the
  simulator's.
- A's own "opening detail" pending/failure states have no native equivalent:
  the journal's data is local, so opening a row is immediate. The native
  pending/failure captures are the **save** states (the design's own
  save-pending/save-failure captures are the counterpart).
- Reduce Motion cannot be photographed (the row lift exists only while a finger
  is down and the unit bundle has no touch injection); the parity is the row's
  existing `accessibilityReduceMotion` plumbing mirroring the design's `.rm`
  block, and the lane's `a-*-reduce-motion.png` reference stays the web
  counterpart.
- At `.accessibility3` the **hero** readout (out of this lane's scope) wraps and
  truncates its macro labels; the food rows themselves grow and stay complete
  (pinned by the suite's Dynamic Type assertion).
