# Morsel #263 — source and font-enabler proofs

**Artifact-only prerequisites, not rendered alignment or design approval.**

- Base: `2d87d61e73c6c3db7bd1420294ccf1551232405d`.
- Read-only checkout: `/Users/jirathip/.herdr/worktrees/morsel/design-263-training-row`.
- Requested output: `/Users/jirathip/design-output/morsel/263-training-row` (resolves to `/Users/jirathip/Projects/design-output/morsel/263-training-row`; these are one physical tree).
- Reproducer: `../scripts/prove_fonts.py`.
- This subtask writes only `sources/**` and `scripts/prove_fonts.py`; no rendering, browser, app edits, commits, pushes, or GitHub writes. The parent owns any `assets/fonts` copies.

## Verified font result

The **actual bundled** `app/Fonts/EBGaramond[wght].ttf` contains GSUB features `tnum`, `onum`, `lnum`, and `pnum`, available in the default Latin language system.

- Font SHA-256: `ef9512f92f6d579e5dc75af59a5a4b1b8b47d2eda89e00b954d44520e5369027`.
- Bytes: 851176. Units per em: 1000. Weight axis: 400–800, default 400.
- Feature lookups: `lnum` 17; `pnum` 18; `tnum` 19; `onum` 20. Each is a real type-1 single-substitution lookup; all mappings are retained raw.
- At weight 400, all ten default/lining tabular digits have advance **480** font units. `tnum`+`onum` selects oldstyle tabular glyphs, also **480** each.
- At weight 400, `pnum` lining digits `0…9` have advances **506, 382, 505, 480, 500, 480, 484, 484, 472, 484**: a discriminating proportional control, not ten copied equal values.
- At weight 800, all ten tabular lining and oldstyle digits have advance **540** each.
- Weight instances **400, 500, 600, 700, 800** were independently evaluated in memory. Tabular equality and proportional inequality assertions passed at every tested weight. This is a discrete-weight test, not an assertion about every possible continuous weight.
- Important nuance: this font's default cmap digits are already tabular lining. Therefore `tnum` alone does not need to replace the default digit glyphs. Its real mapping converts `.lf` proportional lining glyphs to the base tabular glyphs and `.osf` proportional oldstyle glyphs to `.tosf`. `onum` changes figure style without inherently making figures proportional. `lnum` maps proportional `.osf` back to `.lf`. Do not equate “oldstyle” with “proportional.”

### Raw font evidence

| Artifact | Contents |
|---|---|
| `font-features.raw.json` | SHA/size, complete name records, fvar axis, all GSUB feature records, script/language availability, exact required-feature mappings. |
| `EBGaramond-GSUB-fvar.ttx` | Unabridged fontTools XML dump of the actual GSUB and fvar tables. |
| `font-proof.raw.txt` | Human-readable raw feature/mapping output and all tested digit variant/weight summaries. |
| `digit-advances.raw.json` | Individual digit glyphs, hmtx advances/bearings, y bounds, variant summaries, and direct mapping probes. |
| `digit-advances.raw.tsv` | Per-digit/per-weight metrics for default, individual features, and tabular/proportional × lining/oldstyle combinations. |
| `feature-mapping-advances.raw.tsv` | Every mapping's real input/output advances, including lnum conversion from oldstyle inputs. |

**Limit:** fontTools table evaluation is not a complete text shaper. The probe applies only these real single-substitution GSUB lookups in lookup-list order and reads hmtx; it does not execute GPOS/kerning, CSS, CoreText, SwiftUI, fallback selection, or rasterization. No browser/native rendering occurred. ASCII `0…9` are tested, not other numeral systems or punctuation. Native weight/feature application and full row/column alignment still require rendered proof in the separately gated numeric gallery. No replacement font or synthetic metrics were used.

## Exhaustive existing modifier result

Unfiltered immutable-tree search considered **1381 git-tracked paths**. It found **4 identifier mentions, all 4 actual `.monospacedDigit()` calls in 4 Swift files**:

1. `app/Sources/Morsel/HistoryLedgerViews.swift:213` — History gauge value, `.morselGauge`.
2. `app/Sources/Morsel/JournalFoodRow.swift:101` — food energy figure, `.morselMono(size: 14)`.
3. `app/Sources/Morsel/MealItemEditSheet.swift:350` — confidence figure, `.morselMono(size: 12)`.
4. `app/Sources/Morsel/Views.swift:148` — Today eaten hero, `.morselHero`.

Each has line-numbered surrounding context in `monospaced-digit-sites.md` and raw `git grep` output in `monospaced-digit-sites.raw.txt`; structured identities, counts, and source hashes are in `monospaced-digit-sites.json`. `tracked-tree.json` records the complete searched git tree. Neither a guessed count nor a worktree-only filesystem glob is used. The scanner considers identifier candidates even in binary blobs and fails on unexpected non-call mentions rather than quietly excluding them.

This modifier inventory **does not establish** the issue's separate “20 files” numeric-family inventory. The full app-wide before/after gallery is deferred. In particular, neither TrainingFuelViews nor a Goals-specific source appears among these four modifier calls.

## Exact source copies, copy inventory, and licenses

- `TrainingFuelViews.swift.txt` and `TrainingFuelModel.swift.txt`: requested exact reference copies.
- Supplemental exact references: `TrainingFuelContext.swift.txt`, `TrainingFuelHealthReader.swift.txt`, `TrainingFuelHost.swift.txt`, `DesignSystem.swift.txt`, `Views.swift.txt`, `DatedTargets.swift.txt`, `DATA_MODEL.md.txt`, `MCP_TOOLS.md.txt`, and `DATED_TARGETS.md.txt`.
- `source-hashes.json`: **22** source files hashed, including every bundled font/license and every modifier-bearing source; **14** byte-identical reference/license copies verified against both git base and working checkout. Fonts are hashed but **not copied** here.
- `copy-inventory.md`: complete TrainingFuelViews visible-copy map; exact model errors; source-line constraints for P1 session locality, blank/manual amount, consent, pending/retry/cancel/undo, dates, stale/partial Health, and unavailable target. Read its **source gaps / tensions** section before assembling the prototype.
- `OFL-EBGaramond.txt`, `OFL-Caveat.txt`, `OFL-IBMPlexMono.txt`: complete bundled license notices, unchanged and source-hashed. The EB Garamond notice covers regular and italic files; IBM Plex Mono covers regular and medium. Preserve corresponding full notices when the parent redistributes font files.

### Critical source findings for the parent

1. P1 says **“This session only · not synced”** and **“Local to this signed-in session, not saved to Health or synced.”** The existing separate dated-target RPC must not be used to silently upgrade this UI's persistence claim.
2. Base `beginReview()` refuses absent baseline; the new unavailable row must open a sheet without fabricating a target or enabling invalid confirmation.
3. Outside the receipt, the Today hero still renders a target and provenance (`Views.swift:142–166`). Receipt removal alone does not literally satisfy “exactly one target statement” / no computed provenance on Today. This source-vs-brief surface must be explicitly addressed by the parent, not silently ignored.
4. Base Health reads collapse missing/denied/read-error into unavailable optionals; they do not expose a reliable “denied” status. Preserve source and real sample/checked times.
5. The final technical-only mono rule and the issue inventory's “settings rows, auth wordmark” keep-list are not automatically equivalent. Scope tension is recorded rather than silently resolved in this prerequisite task.

## Raw GitHub capture

`issue-263.json` is unmodified stdout from:

```sh
gh issue view 263 --repo jirathip-dev/morsel --json number,title,url,body,comments,updatedAt
```

`issue-263-api.raw.json` is unmodified stdout from the read-only call:

```sh
gh api repos/jirathip-dev/morsel/issues/263
```

The GraphQL view contains **1 comment**, matching REST `comments = 1`; body and update timestamp also match. No truncation or inferred comments. Authentication was preflighted with `gh auth status`; credentials are not included in these artifacts. Raw JSON whitespace is preserved. The snapshot is retained rather than re-fetched during the deterministic font/source reproduction, so later issue edits cannot silently rewrite the authority snapshot.

## Reproduce (all temporary writes remain inside the assigned sources directory)

Run from `/Users/jirathip`; no system pip or app/build tool is required:

```sh
python3 -c 'from pathlib import Path; Path("/Users/jirathip/design-output/morsel/263-training-row/sources/.tmp").mkdir(exist_ok=True)'
UV_CACHE_DIR=/Users/jirathip/design-output/morsel/263-training-row/sources/.uv-cache \
TMPDIR=/Users/jirathip/design-output/morsel/263-training-row/sources/.tmp \
PYTHONDONTWRITEBYTECODE=1 UV_PYTHON_DOWNLOADS=never \
uv run --no-project --no-config --with fonttools==4.65.0 \
python /Users/jirathip/design-output/morsel/263-training-row/scripts/prove_fonts.py
```

This regenerates font evidence, tracked-tree/modifier inventory, source hashes, and exact copies. It hard-fails if the base is not an ancestor of checkout HEAD, product-source bytes differ from base (only this lane's `docs/design/263-training-row/**` evidence commits are allowed), any required feature is absent, a required lookup is unsupported, digit metrics fail equality/inequality checks, or GitHub body/comment-count/update snapshots disagree. It never writes a font back to disk. The parent widened the original HEAD-equals-base guard only for its authorized evidence commit, so reproduction still works after delivery; source scans remain pinned to the immutable base.

Remove **only the two temporary directories owned by this reproducer**, then seal the finished source bundle using stdlib Python:

```sh
python3 -c 'from pathlib import Path; import shutil; p=Path("/Users/jirathip/design-output/morsel/263-training-row/sources"); [shutil.rmtree(p/n) for n in (".uv-cache", ".tmp") if (p/n).exists()]'
PYTHONDONTWRITEBYTECODE=1 python3 /Users/jirathip/design-output/morsel/263-training-row/scripts/prove_fonts.py --seal
```

`verification.json` records the source-copy/hash/base/issue checks. `artifact-manifest.json` seals **this subtask only** (`sources/**` plus `scripts/prove_fonts.py`), explicitly excluding itself. The seal re-reads all listed files, compares the exact path set, rejects transient cache/bytecode artifacts, and checks SHA-256 values. It is not the manifest of the parent's gallery/prototypes/assets. After any edit, rerun the appropriate proof and seal. `--verify-only` is dependency-free source/issue verification; it does not regenerate or re-execute the font-table probe.

DESIGN ARTIFACTS ONLY; no app/DB edits; not merged; not opened as PR; no deploy.
