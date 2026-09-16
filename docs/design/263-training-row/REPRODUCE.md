# Reproduce #263 half (a)

Canonical root: `/Users/jirathip/design-output/morsel/263-training-row/`.
Review mirror: `/Users/jirathip/.herdr/worktrees/morsel/design-263-training-row/docs/design/263-training-row/`.
Both are self-contained bundles of local HTML/CSS/JS/fonts/art. No npm install, app build, simulator, account login or production writes are needed. Opening `index.html` locally works; the Tailscale gallery serves the same bytes.

## Requirements

- Python 3, Pillow (the host's `python3` already has it), Node with global WebSocket/fetch.
- The existing headless Chrome CDP service at `http://127.0.0.1:9333`. `CDP_URL` may target another local authorized CDP renderer, but matching Chrome build/font rasterizer is necessary for byte-identical PNG reproduction.
- The product checkout with immutable base `2d87d61e73c6c3db7bd1420294ccf1551232405d` and approved design commit `68be41d1f3e3fdabcfe28efab79e7c4a2879377b`, for source provenance regeneration only. Product HEAD may add this lane's evidence commit but no other tracked product changes.
- `uv` for the pinned `fonttools==4.65.0` table proof. No system `pip` and no replacement font download.

## Build, source proof, full browser capture

Run from the canonical root (or the byte-identical mirror):

```sh
python3 scripts/setup.py
python3 scripts/build.py
PYTHONDONTWRITEBYTECODE=1 UV_PYTHON_DOWNLOADS=never \
  uv run --no-project --no-config --with fonttools==4.65.0 python scripts/prove_fonts.py
python3 scripts/prove_fonts.py --seal
node scripts/check_amounts.mjs
node --check prototype.js
node --check scripts/verify.mjs
node scripts/verify.mjs
node scripts/verify.mjs --check-captures
python3 scripts/admit.py
python3 scripts/package_views.py
python3 scripts/retain_repro_failure.py --verify-normalized
python3 scripts/verify_visual_dispositions.py --seal
python3 scripts/inventory.py
python3 scripts/audit.py --seal
python3 scripts/audit.py
python3 scripts/mirror.py
python3 scripts/mirror.py --apply
python3 scripts/mirror.py --verify
```

`setup.py` verifies retained bytes before copying; it never modifies a product source or overwrites a differing baseline. `build.py` is the sole generator for candidate HTML, embedded fixture/state JS, the review index and alignment lab. Editable source inputs are `src/prototype.html`, `style.css`, `prototype.js`, `states.json`, and `fixture.json`. Artwork is byte-exact approved A, not regenerated/reinterpreted.

`verify.mjs` performs admission BEFORE creating its one owned CDP tab. `scripts/admit.py` executes the updated coordination predicate `pgrep -fl 'chrome|blender|render|xcodebuild|xctest'`, records its raw output and a PID-classified decision, and waits at most 60 seconds. It refuses competing Xcode/Blender/render/capture processes and low disk headroom. The existing persistent :9333 browser is the renderer, not a competing batch. Siblings are never signalled or killed. A DEFER exit 75 is not a test failure. Initial admission refusal creates no render target; mid-pass refusal preserves completed checkpoints and closes only the owned tab. `python3 scripts/run_admitted.py [--smoke|--check-captures]` can retry only admission DEFER, up to ten bounded windows; every actual verifier failure stops immediately. No gate bypass. The owner gave #262 the next window; `evidence/priority-262.json` retained that hold until the first #262 browser batch recorded PASS. The released record is retained. `--resume` (automatically used by the bounded wrapper) checkpoints each complete specimen/interaction group. Resume requires the same combined source/font/art digest and renderer version and revalidates saved PNG hashes; an incomplete state is rerun. Full and independent-rerender checkpoints are separate. A fresh `node scripts/verify.mjs` without `--resume` always starts fresh.

The verifier operates serially, no workers. Each PNG has a route/state observation recorded beside its SHA in `evidence/verification.json`; top and scrolled context shots are actual viewport captures, not full-page images resized into a phone. CSS viewport is 390×844 at DPR 1. Alignment lab uses 390×1000; gallery has phone and desktop captures. Primary flows use CDP pointer clicks and text insertion, not direct assignment to the state model. Only the date-rollover event is an explicitly named fixture seam.

Capture normalization hides only Chrome’s transient browser scrollbars via target-scoped `Emulation.setScrollbarsHidden`. It does not alter shipped HTML/CSS, application layout, scroll offsets or interactions; pixels previously covered by browser scrollbar chrome are revealed. The earlier mismatch was isolated to the rightmost four pixels; rejected expected/actual/diff images and measurements are retained under `evidence/repro-failure-scrollbar/`. Recheck with `python3 scripts/retain_repro_failure.py` (read-only).

The independent second run navigates/reloads every state, exercises the full interaction battery again, and compares every screenshot byte-for-byte with the first run. It writes `evidence/rerender.json` without replacing the original PNGs. Actual Chrome version is in both reports. Different renderer/platform versions may require a separately reviewed fresh capture; do not relabel a mismatch as reproduced.

`package_views.py` generates the state matrix from the same exhaustive state list and verified shot inventory. Contact sheets paste original phone pixels without scale changes and add external labels; they do not reconstruct UI. `audit.py` independently checks PNG IHDR dimensions, exact capture set, hashes, both rerender sets, local links, approved asset hashes, palette membership, contrast, and absence of transient files. Its root manifest includes all bundle files except itself. Nested font-proofs retain their own separately scoped seal.

## Evidence interpretation

- Source/font table checks: real bundled binary and immutable git tree; not a native renderer test.
- Browser font widths: actual Garamond tabular vs proportional digit widths at 14, 22 and 32px, both themes; not the full numeric migration gallery.
- Browser interaction/visual checks: design prototype only; no SwiftUI, HealthKit permission, physical keyboard, account sync or deployment claim.
- Gallery: half (a) awaits owner review; half (b) cannot authorize an implementation lane without its separate exhaustive gallery and owner approval.

## Final sealing and mirror

After any doc/script/capture changes, regenerate the affected proof, reseal `sources/` if it changed, then `python3 scripts/audit.py --seal`. Copy only this project tree to its owned product evidence directory. Compare exact relative-path sets and every SHA-256; do not delete or sweep unrelated files. Stage only `docs/design/263-training-row` in the product branch and only `morsel/263-training-row` in design-output. No issue/PR comments are posted by this lane.

Live reviewer entry:
`https://jirathips-macbook-air.tail8c3301.ts.net:8444/morsel/263-training-row/index.html`

Archive:
`https://github.com/jirathip-dev/design-output/tree/main/morsel/263-training-row`
