# Reproduce #263 numeric-voice gallery

Canonical bundle: `/Users/jirathip/design-output/morsel/263-numeric-voice/` (resolves under `/Users/jirathip/Projects/design-output/`).
Product evidence mirror: `/Users/jirathip/.herdr/worktrees/morsel/design-263-numeric-voice/docs/design/263-numeric-voice/`.

This is a self-contained HTML typography comparison. No app build, Swift script, database, account sign-in, API/clipboard write or deployment.

## Requirements

- Python 3 with Pillow (captured environment: Python toolchain on this host, Pillow 12.3.0).
- Node with built-in fetch/WebSocket (captured Node v26.7.0).
- Existing authorized local CDP browser at `http://127.0.0.1:9333`; `CDP_URL` can select another already-authorized renderer. Evidence records the actual browser version (HeadlessChrome/151.0.7922.34). Same browser/platform/font binaries are needed for byte-exact PNGs.
- `git` and immutable Morsel source commits for optional source regeneration. `gh` is needed only if regenerating the absent issue snapshot, read-only.

## Rebuild and reverify

Run from the bundle root:

```sh
python3 scripts/build.py
python3 scripts/run.py
python3 scripts/package.py
python3 scripts/run.py --check-captures
python3 scripts/check-generation.py
python3 scripts/audit.py --seal
python3 scripts/audit.py
```

`build.py` is the single deterministic generator for all specimen HTML, alignment pages, review gallery and coverage.json. It uses only retained source text and font/art assets. Edit its specimen definitions or the shared CSS/JS, regenerate, then recapture every page. Do not patch emitted HTML individually.

`run.py` calls the retained CDP `verify.mjs` driver. Admission always runs `pgrep -fl 'chrome|blender|render|xcodebuild|xctest'` plus PID-classified process inspection. Each admission window waits at most 60 seconds; competing render/Xcode jobs or low disk headroom cause DEFER 75 without starting a browser target. The wrapper retries only DEFER, at most ten bounded windows with ten seconds between them. A real test failure stops immediately. The already-running :9333 daemon is the shared renderer, not a competing batch. No sibling process is killed or bypassed. Initial #262 batch-5 and later unrelated Xcode deferrals are retained in evidence/admission.jsonl.

One owned CDP target is created and closed by the verifier. Rendering is serial. Target-scoped scrollbar hiding removes transient browser scrollbar chrome only; all app excerpt geometry stays unchanged. Document/font/image readiness is awaited before screenshots. Page/theme/version are read back and included in each capture record. Every mapped glyph must be within the phone viewport; fonts must match actual downloaded custom faces, not a silent fallback. Text content, point-size equivalents, weights and colors must stay identical across each before/after pair.

The independent second pass navigates and captures all states again. It compares PNG bytes rather than replacing the originals. Its source digest must match the full run. Any mismatch fails; no tolerance or synthetic screenshot substitution. Contact sheets and review plates paste unscaled original PNGs with external labels; rerunning package.py should reproduce those PNGs.

`audit.py` checks raw/manifest path-set equality, all SHA-256 values, exact capture sets and dimensions, both render reports, independent source-audit coverage, locked source/font/art bytes, actual measured digit widths, proportional negative controls, byte-identical kept-mono excerpt pixels, local links, important-text contrast and transient-file absence. The manifest excludes only itself; its final SHA can be obtained with `shasum -a 256 manifest.json`. Admission timestamps and verification logs are real run evidence; they are not claimed byte-reproducible. Determinism claims concern generated HTML and PNGs under the pinned rendering environment.

## Optional immutable-source regeneration

```sh
python3 scripts/setup.py
python3 scripts/build.py
```

setup.py reads `git show 2d87d61e73c6c3db7bd1420294ccf1551232405d:<path>` for product source/font bytes and `git show 68be41d1f3e3fdabcfe28efab79e7c4a2879377b:docs/design/tactile-journal/...` for approved A art and baseline images. It never edits the checkout. `sources/independent-audit.json` is a retained, independently performed source audit; its source hashes are recorded. It is not a generated or native-runtime verdict.

## Mirror and publishing

```sh
python3 scripts/mirror.py
python3 scripts/mirror.py --apply
python3 scripts/mirror.py --verify
```

Default is a dry run. Only this bundle's artifact directory is copied; no deletion or untracked sweep. Exact relative-path sets and every file hash, including manifest.json, are compared.

In the product checkout, stage only `docs/design/263-numeric-voice` and push only `design/263-numeric-voice`. In the design-output repo, stage only `morsel/263-numeric-voice` and push its project-specific archive commit under the standing archive permission. Scope-audit staged names and both source trees. Do not post issues/comments, open a PR, merge, build a release or deploy. The worktree `.brief.md`/`.report.md` remain untracked/ignored orchestration files.

## Interpretation

Read LIMITS.md before claiming completion. The package verifies the browser gallery; actual SwiftUI EB Garamond tabular rendering remains UNVERIFIED because the strict no-Swift fence was preserved. A font-feature table, browser Range or CoreText-only width proof cannot close that native criterion.
