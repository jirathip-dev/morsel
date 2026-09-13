# Issue #229 — imported approved Variant A reference (read-only)

This directory preserves the **owner-approved Variant A artifact** inside this
checkout so the native port never depends on a mutable external gallery.

## Provenance

| | |
|---|---|
| Source repo/branch | `jirathip-dev/morsel` · `design-tactile-journal` |
| Pinned design commit | `68be41d1f3e3fdabcfe28efab79e7c4a2879377b` (the branch tip) |
| Imported path | `docs/design/tactile-journal/**` (read-only upstream; not modified here) |
| Archive record | `jirathip-dev/design-output/morsel/228-tactile-journal` @ `de331f193b391b1a8bb741cc3561adb257741489` |
| Imported by | issue #229 lane, `git show <commit>:<path>` byte-for-byte (see the manifest below) |

**Variant A only** — the comparison variant B (`b-*.svg`, `b.html`) was
deliberately not imported. Both themes (Paper + Night) are present for every A
study.

## Contents

| File | Why it is here |
|------|----------------|
| `a.html`, `style.css`, `index.html`, `fixture.json` | the approved prototype: the visual contract this lane ports (row grid, sheet composition, states, Reduce Motion block) |
| (not imported) `app.js`, `fixture.js` | the prototype's browser runtime scripts — not needed to reproduce the design or verify the port; they are NOT committed here because the repo lints all JavaScript and browser globals are not project code (sha256 of the pinned originals: `app.js` `851949e0bea7453cc69cf1b224647f899aee6d9e68f9ef0a8de985eb623346be`, `fixture.js` `b2c10401331e23719ec2c042f01730f698bb877b14750d16c0676534f28e6a8f`) |
| `assets/a-{paper,night}-{focaccia,mortadella,stracciatella,vegetables,unknown}.svg` | the approved original A food artwork (10 studies) — the rasterisation source for `app/Resources/JournalArt/*.png` |
| `evidence/a-{paper,night}-*.png` | the approved 390×844 A captures used for the side-by-side comparisons against the native build |

Fonts are **not** duplicated here: the design source's font files are
byte-identical to the ones already bundled in this repo (`app/Fonts/`), verified
by sha256 against the pinned commit:

- `Caveat[wght].ttf` `0bdb6b660482d31531b3945849fba5916b3ef8695da7024a9e6b9ee3c4157988`
- `EBGaramond[wght].ttf` `ef9512f92f6d579e5dc75af59a5a4b1b8b47d2eda89e00b954d44520e5369027`
- `EBGaramond-Italic[wght].ttf` `bba2c4499c93c9612b90b9825d32b07da52fce2fe57562a1eb6b833553f93c4e`
- `IBMPlexMono-Regular.ttf` `a7fdc993f9f0387caedba4e42521136fa97e4c0837ae6239bf0413ccf8af00c2`
- `IBMPlexMono-Medium.ttf` `4fc14a73ca53ba9d32fd759ae1ca1a3133326035d0dd337862b3ee1633cc156e`

## Imported-file manifest (sha256; the two prototype runtime scripts are listed as not imported)

```
83e58ceec5424784a91cc0b7037e899c159d91f6b353e5e104ccfe628c89daf6  a.html
633024e19e1f9205f683349158cf45c054042309becdbb0f8dbe343ad0eaf0d1  style.css
# not imported: 851949e0bea7453cc69cf1b224647f899aee6d9e68f9ef0a8de985eb623346be  app.js
# not imported: b2c10401331e23719ec2c042f01730f698bb877b14750d16c0676534f28e6a8f  fixture.js
fa77f88c692ca75028d5529672ee2344c4ab220f815336122255689ebfdc7350  fixture.json
ac33727c6e70b4719d1bcc787a8830d18115bfdbcc7a3b40227e3d45e681f38c  index.html
bf04e92a95bacd7797f8ec50dacc33821992918757bf1f9f66b8ab53e45b8c0f  assets/a-night-focaccia.svg
0d3930fe7ee1521dd5d35b63d3d15220bb6e62b6b4f1768dbcaea0f0d8653865  assets/a-night-mortadella.svg
fb429e17fcec93b480e9e522ebe2968bcaa74094f356a018ae92abecfaafcaf8  assets/a-night-stracciatella.svg
d860d05c03d0ba505bd6aa665716c2e5000e9fe984fd72569532c4215f1082b9  assets/a-night-unknown.svg
d1ff12b35d97fa530d9d7776d0b56f0b6763c726b4daeb4430c5ec4e650fd988  assets/a-night-vegetables.svg
c8c2b1fa454802b3639dc74cd072a82f7208b7e0fc7da9c536c90dd5e2019a4e  assets/a-paper-focaccia.svg
ee1fd11818237c29d56fa5e611946b6f138cf44a9f3d34458d69c3b20e3efabc  assets/a-paper-mortadella.svg
cb235d8b21a15b60f14b56728aed0ce4b8732c4be778ac205aec9334a7e27d6a  assets/a-paper-stracciatella.svg
74e38f7640c5b28f1cad592f156d78b52257e22ca9abf2164c18818198197111  assets/a-paper-unknown.svg
319cd988dcfcecb720833ee29f712ed06f86bb7a7a1c152859749c86e4936bb8  assets/a-paper-vegetables.svg
```

The A captures under `evidence/` are the approved state set (rows, detail,
open-failure, save-pending, save-failure, updated, reduce-motion, unknown) in
both themes; the review pairs native captures against them.

## Rasterisation (approved SVG → bundled PNG)

`app/Resources/JournalArt/a-{paper,night}-{study}.png` are produced from the
imported SVGs by `../tools/render-a-art.mjs` (the repo's own
`@resvg/resvg-js` dependency) at **224×224** — 4× the 56pt row placement and
≥3× the 64pt summary placement, so every bundled placement downsamples. The
script resolves the SVGs' root `style="--line:#…"` custom property before
rendering (resvg does not resolve `var()`), and re-running it reproduces
identical bytes. See the lane `.report.md` for the vector-vs-raster decision.
