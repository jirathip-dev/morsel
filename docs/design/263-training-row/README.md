# Morsel #263 — Today row + Training day sheet

PROTOTYPE — half (a), awaiting owner review. Issue decisions are final. No implementation or app-wide numeric migration is authorized by this package.

## Review

- [Live phone gallery](https://jirathips-macbook-air.tail8c3301.ts.net:8444/morsel/263-training-row/index.html)
- [GitHub archive](https://github.com/jirathip-dev/design-output/tree/main/morsel/263-training-row)
- Local entry: `index.html` (all assets local).
- Recommendation: **A — Open journal**. A gives the deliberately blank field a generous writing line, pairs Confirm with Cancel, and separates provenance without nested cards. B — Ruled form uses a paired field, stacked actions and denser reading columns. Both retain the approved A journal palette, typography and illustrations.

## Artifact map

| Path | Purpose |
|---|---|
| `index.html` | Comparison gallery; A/B, Paper/Night, links to every state |
| `a.html`, `b.html` | Interactive candidates; `?theme=night&state=…` selects specimens |
| `alignment.html` | Actual-font tabular/proportional comparison; enabler, NOT gate (b) |
| `SPEC.md` | Implementation-ready layout, copy, policy, accessibility and explicit limits |
| `STATE-MATRIX.md` | Complete state inventory, decisions and exact screenshot links |
| `REPRODUCE.md` | Saved generation, verification, sealing and mirror commands |
| `src/prototype.html`, `prototype.js`, `style.css` | Editable prototype source |
| `states.json`, `fixture.json` | Named state routes and approved fictional journal records |
| `scripts/` | Deterministic build, source/font proof, admission, CDP verification, contact sheets and independent audit |
| `assets/` | Byte-exact approved illustrations and bundled fonts/licenses |
| `baseline/` | Retained immutable approved Variant A controls |
| `references/asset-lock.json` | Reference provenance and SHA-256 pins |
| `sources/copy-inventory.md` | Exact current copy, constraints, reconciliation |
| `sources/font-proof.raw.txt` | Bundled-font GSUB tables and digit advance measurements |
| `sources/monospaced-digit-sites.raw.txt` | Repo-wide immutable-base `.monospacedDigit()` enumeration |
| `evidence/` | Browser PNGs/reports, contact sheets, admission log and regression proof |
| `ARTIFACTS.md` | Exhaustive path index for every artifact under both delivery roots |
| `capture-verification.md` | Review ledger, slop audit, measured findings and limitations |
| `manifest.json` | Exhaustive bundle paths, sizes and SHA-256s, excluding itself |

## State coverage

The source inventory is `states.json`. It includes usual/confirmed/unavailable rows; first-entry blank; invalid/valid draft; pending/failure/retry; confirmed/edit/undo; missing/denied/stale/zero/partial/workout-only/loading/error Health; unavailable target; manual consent unchecked/granted; empty/loading/cached/error diary; multi-meal/partial nutrition; rollover. Each is instantiated for both candidates and both themes.

Seeded screens prove presentation, not transitions. The browser driver separately uses real pointer clicks and text insertion to exercise confirmation, replacement edit, sheet-only undo, failure/retry, cancel during pending, consent renewal, unavailable access, Health retry, Escape/focus and narrow layouts. Date rollover alone uses an explicitly named fixture seam.

## Evidence status

Final recorded gates: **PASS** — 30 named states, 204 captures, 17 contact sheets; 2,106 full-pass checks (including resume integrity checks), 2,215 independent-rerender checks. All 204 PNGs reproduced byte-for-byte. Minimum measured important-text contrast: 4.63:1. Browser console/runtime and prototype HTTP-request checks are clean. All contact-sheet specimen pixels are independently checked against their original PNGs.

Consult `evidence/verification.json` and `evidence/rerender.json` for the real browser verdicts, exact check/capture counts, observed state and renderer build. Absence of these PASS reports means rendering is not yet verified. `sources/verification.json` is a separate source/font-table proof and cannot stand in for browser evidence.

`evidence/admission.jsonl` retains every admission sample. Corral native gates and Morsel #262 renders are never interrupted. The render driver waits in bounded 60-second windows and re-checks between specimens.

## Enabler proof

Bundled EB Garamond has GSUB `tnum`, `onum`, `lnum`, `pnum`; raw output includes glyph substitutions and equal tabular advances. The base has four `.monospacedDigit()` call sites, recorded with source line references. `alignment.html` plus browser width measurements prove the loaded font's tabular behavior at 14, 22 and 32px in both themes. That does not prove SwiftUI rendering or replace the exhaustive before/after numeric gallery.

## Honesty and approval boundary

The owner’s sample totals and approved meal fixture are fictional design data, not a real dietary record. New entry has no prefilled kcal amount or suggestion. Health reads are simulations; no data permission request or real write occurs. Existing hero/meal/macro mono roles are retained pending the separate app-wide gate. Current P1 local-session scope is not silently upgraded to durable sync. Physical-device HealthKit, VoiceOver, Dynamic Type and native gestures still require later acceptance.

Half (a) stops for owner selection. Half (b) must subsequently show EVERY affected surface and retained technical mono role, before/after in both themes, and receive owner approval before implementation can be opened.

DESIGN ARTIFACTS ONLY; no app/DB edits; not merged; not opened as PR; no deploy.
