# Shipped-resolver coverage — issues #262 AC6 / #260 AC6

Tested code commit: `c63b37fc75180a27a2c02106f67d66b6634be3a5`.
This is a measured name-only fallback result, not the design estimator's 10.4% → 92% claim.

## Aggregate result

N = **250 distinct names**, deduplicated by exact string from the supplied
frequency-derived corpus. Each distinct name has equal weight; frequency is not used.
This is a supplied historical snapshot, not a fresh production query or a claim about
chronologically latest rows.

| Resolution | Count | Percentage of N |
|---|---:|---:|
| Specific food | 58 | 23.2% |
| Labelled category | 1 | 0.4% |
| Neutral | 191 | 76.4% |
| No artwork resolution | 0 | 0.0% |
| Total | 250 | 100.0% |

Raw app-hosted XCTest output (aggregate only):

```text
ISSUE260_COVERAGE {"counts":{"category":1,"neutral":191,"none":0,"specific":58},"distinct_names":250}
```

## Method and exact invocation

From `/Users/jirathip/.herdr/worktrees/morsel/issue-260-matcher`:

```sh
python3 docs/evidence/issue-260-matcher-closure/run-native.py --label native-closure --corpus /Users/jirathip/.herdr/worktrees/morsel/design-262-library-expansion/.lane-logs/logged-names.json --mutation
```

The runner acquired `/tmp/n.lock`, then used `hermes-sim-task` with its own iPhone 16
simulator. `FoodArtworkPrivateCoverageTests.testShippedResolverCoverage` decodes only
`name`, deduplicates using `Set<String>`, and calls the actual
`FoodArtworkResolver.resolve(name:in:)` with `FoodArtworkCatalog.bundled` for each name.
It counts the returned `.food`, `.category`, `.neutral`, and `.none` enum cases.
There is no JavaScript/Python estimator, per-name rewrite, fuzzy match, supplied
`artwork_id`, or alternate catalog in this measurement.
A failed name match normally becomes `.neutral` via the shipped fallback asset;
it is not counted as `.none`. Category classification includes the honest cooked-greens class.

The focused native invocation exited **0**, with **50 tests / 0 failures**, including
one private-coverage test. The complete wrapper, two expected RED probes, and restored
GREEN completed with wrapper exit **0**. Exact expanded xcodebuild argv and timings:
`coverage-aggregate.json` and `gates.json`. Raw run: `.lane-logs/native-closure.log`;
raw receipt: `.lane-logs/native-closure.json`.

## Provenance

- Corpus path: `/Users/jirathip/.herdr/worktrees/morsel/design-262-library-expansion/.lane-logs/logged-names.json`
- Corpus rows: 250; distinct exact names: 250.
- mtime (Unix nanoseconds): `1789518769900771338`.
- mtime (UTC, microsecond display): `2026-09-16T00:32:49.900771+00:00`.
- Corpus SHA-256: `76bf28f6ef33a07b6b436ec67f23b40775d136418a5c3c2be478f2f31f5bb09c`.
- Shipped resolver SHA-256: `1e3517b4c588ad0c2196e168f98986040caced4efffe760c5eb82a7ec5481639`.
- Bundled catalog SHA-256: `996177e2d8b52f1b4ebfdb6ef890c98a04011ef29dceb71f9faf9f20e938893b`.
- Bundled catalog: 130 assets; its approved bytes and all art PNGs are unchanged.

## Privacy and limits

**No raw corpus names, private per-name mappings, partial private name lists, or corpus
bytes are committed.** Coverage artifacts contain aggregates and provenance only.
The corpus stays at its original private path; the path marker was removed after the run.
Raw local run/provenance files remain in ignored `.lane-logs/`. The runner prints no
private names. A local name-overlap diagnostic also remains only in `.lane-logs/`;
no per-name coverage mapping is published. Separate named-case screenshots
and `named-results.json` use only the already-public issue/test fixtures, not a dump of
this corpus.

The remaining 191 neutral results are real limitations, not converted into category or
specific successes. This does not prove every descriptive name resolves, and it does
not verify the live agent-write/server-readback/native-render chain in #260 AC5.
That live production criterion remains unverified; no production writes were made.
