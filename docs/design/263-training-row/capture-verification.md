# Verification / review ledger

This is prototype evidence, not native app acceptance. Final authoritative browser results are `evidence/verification.json` and `evidence/rerender.json`; source and font-table evidence lives separately under `sources/`.

## Admission and chronology

- Initial bounded attempts deferred while Corral native probes were running; raw process samples are in `evidence/admission.jsonl`.
- The owner assigned #262 the next window. The lane stopped its own waiting/capture runner and closed only its own CDP target. Initial Paper smoke captures had started before the priority ruling; they were not presented as a complete pass.
- A priority hold then prevented #263 from taking a briefly empty slot before #262 could start. The hold was released only after reading #262 batch 1's `browser.json` with PASS; its path and release observation are retained in `evidence/priority-262.json`.
- The complete smoke pass subsequently returned 94 checks and 12 captures. It is preliminary, not a substitute for the final matrix.
- A later native gate appeared during full capture. The driver deferred, closed its own tab, and did not interrupt it. Checkpointed resume was added: source/art/font digest, renderer identity and saved PNG hashes must agree before completed states are reused. Independent rerender has its own checkpoint. This changes efficiency, not admission.
- No sibling process was killed, paused or restarted. No GitHub issue/PR write was performed.

## Static adversarial findings and disposition

1. Ambiguous comma parsing: the original prototype accepted `1,000` as 1. Fixed by rejecting comma input in this English specimen with an explicit decimal-point message. Production locale formatting remains native-owned. The actual parser is executed in `scripts/check_amounts.mjs`; restoring the old comma parser reproduces the bad result.
2. Fractional addition silently rounded away: original two-decimal display could show a positive `0.004` as zero. Fixed with significant-digit formatting. The source-level check covers `0.004`, `300.005`, `300.001`; the browser flow confirms a small authored fraction and checks the visible note.
3. Strengthened caveat coverage: `No amount suggested` and the inability to assess adequate fuelling also remain in confirmed mode; browser assertions no longer exempt that state.

## Preliminary visual inspection and adjudication

Real A/Paper Today and blank-sheet/context PNGs and B/Night blank-sheet/context PNGs were inspected. They show one Today target statement, illustrated rows, clear empty entry, differentiated Movement/Workout, honest sample/checked dates and wrapped caveats without horizontal clipping.

An image review guessed that Cancel had a small hit region and that the pale Confirm button lacked emphasis. Those claims are not accepted from pixels: Cancel is a full button measured by the DOM gate; Confirm is intentionally disabled when the field is blank. Resolved token contrast is measured independently in `evidence/contrast.json`. Background text obscured by the modal is normal backdrop occlusion; bottom-edge content is scrollable, not removed. Three-section order is asserted from the actual DOM rather than inferred from a cropped screenshot.

## Ten-tell composition audit

1. Default palette: no — approved Paper/Night colors, independently checked against the retained A stylesheet.
2. Generic typography: no — bundled Caveat/Garamond, existing Plex roles intentionally retained until gate (b).
3. Hero plus three feature cards: no — Today is Monitor; sheet is Configure, separated by journal rules.
4. Decorative gradients/glass: no — no ornamental gradient or glass panels.
5. Decorative icon clutter: no — a subordinate row chevron, close control and preserved contextual chrome only.
6. Fake metrics/testimonials: no — no marketing claims; approved fictional meal fixture and owner example totals are explicitly labeled.
7. Color-only state: no — Usual/Training/unavailable are literal labels; errors, stale samples and pending state have text.
8. Symmetric card-grid composition: no — continuous journal with task-specific section order; the four-column image grid belongs only to review tooling.
9. Uniform hierarchy/spacing: no — clear title, authorship field, actions, readings and smaller provenance levels.
10. Recolor-only variants: no — A has a full writing line and horizontal actions; B pairs the field and provenance columns and stacks actions. Both use the same locked themes.

## Reproducibility correction and final visual coverage

The first independent rerender failed correctly on a scrolled PNG. `scripts/retain_repro_failure.py` proves the mismatch: 2,492 changed pixels restricted to x=386…389, with identical content outside that browser-scrollbar strip. Rejected expected/actual/difference images remain in `evidence/repro-failure-scrollbar/`. Target-scoped CDP scrollbar hiding normalizes only browser chrome; it changes no shipped HTML/CSS or scrolling behavior. The normalization proof includes the antialiased edge (rightmost five pixels); all pixels outside that edge remain identical. The full normalized matrix and independent rerender both passed before the final label correction.

All 17 normalized contact sheets were individually inspected: `contact-states-01.png` through `contact-states-10.png`, and `contact-context-01.png` through `contact-context-07.png`. These cover all 200 phone captures. Desktop and phone gallery captures were also inspected. No horizontal overlap was found; B's tighter reading columns are a documented tradeoff supporting recommendation A. Scrolling below each 390×844 viewport is intentional, and separate context captures expose the readings and caveats.

Image-review claims were checked rather than accepted automatically:
- Claimed macro-bar drift in unavailable state was false: exact pixel comparison shows macro/food content unchanged. `scripts/verify_visual_dispositions.py` repeats the comparison for all four candidate/theme combinations.
- Blank-state Confirm was guessed to be enabled from its fill. The actual disabled property and blank input are asserted by the browser gate; do not infer semantics from color.
- Claimed bottom-edge clipping is the intentional viewport fold, not horizontal overflow or unreachable content. Real scrolling/context and pointer gates pass.
- Confirmed and edit context shots intentionally share unchanged readings; their distinct answer/action states are visible in the corresponding top captures.

The alignment specimen said Left/Right although its samples are stacked. The generator now says First row/Second row. `pre-label-fix-captures.json` retains the prior screenshot hashes; the disposition gate requires that only the two alignment PNGs change and that all 202 app/gallery captures remain byte-identical. The corrected Paper paragraph was also read at crop resolution (First row/Second row confirmed), its lower specimens and back link were checked, and the full Night specimen was inspected. Both are legible without horizontal clipping. Final reports and the root audit, not this chronology, determine completion.

A fresh delegated read-only static review (`deleg_bcff84f7`) found no concrete blocking contract defect or false completion claim. It traced source behavior and state wiring; it did not certify browser output, native behavior or owner approval. Its findings were independently checked against the source and real browser gates.

Final authoritative recorded results: 2,106 full-pass checks (including resumed-capture integrity checks), 2,215 independent-rerender checks, 204/204 byte-identical captures, 30 states, 17 contact sheets. The audit additionally verifies derived state/fixture JS against pinned JSON, every contact-sheet cell against its original pixels, and important-text contrast (minimum 4.631084618819596:1). The latest owner-announced open window was independently checked and logged as ADMIT with the shared daemon only; no redundant third capture pass was launched.

## Native boundaries

No SwiftUI, HealthKit permission, Dynamic Type, VoiceOver, page-flip or calendar behavior is certified here. No persistence/DB/live-server effect is simulated as an actual write. Half (b)'s exhaustive numeric before/after gallery is still a separate owner gate.
