# Verifier audit and evidence-only correction

A separate read-only audit found three concrete validation gaps in the previously delivered helper scripts:

1. `verify()` validated sources/exports but did not require every new asset and its paths/metadata in `catalog.json`.
2. Empty browser/rebuild arrays and missing browser input pins could pass vacuous loops; the same problem affected the aggregate index.
3. Package checking validated raw paths/hashes but did not validate declared file/byte totals.

These were verifier defects, not evidence of missing or altered art in the delivered batches. The corrected gates now require the exact catalog, each expected viewport/page/identity matrix, complete input pins, exact clean-rebuild output sets, matching image dimensions/hashes, and measured manifest counts/bytes. `package()` and the post-publication verifier both call those gates.

## Discriminating regression evidence

- Retained baseline: `references/verifier-before-audit.py.txt`, read from Morsel commit `e10ae4f` (before the fixes).
- Test driver: `scripts/test_evidence_contract.py`.
- RED: 10 tests ran against that baseline, with eight intended assertion failures and zero harness errors. Both valid controls passed.
- GREEN: all 10 tests passed against the corrected implementation.
- Raw logs and machine results: `evidence/verifier-audit/`.
- Test mutations intercept reads or use owned temporary fixtures; no source, product file or published mirror is mutated by the probes.

Reproduce from the bundle root (set `ART_CONTRACT_FIXTURE` to a completed bundle if not using the author's product mirror):

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_evidence_contract.py --baseline  # expected exit 1 / eight assertion failures
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_evidence_contract.py             # expected exit 0 / ten tests
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_contract.py                      # expected exit 0 / thirteen tests
```

## Batch 1 input-binding upgrade

Batch 1 preceded browser input-pinning. It was freshly recaptured under the same native/render admission predicate, with HTML/CSS/font/image pins checked before and after capture. All 16 screenshot files remained SHA-256 identical to the pre-recapture files. No art, layout, palette or pixels were changed. The earlier input-less record and manifest are retained in `evidence/batch-1-repin-before.json` and `references/batch-1-manifest-before-input-repin.json`; the measured comparison is `evidence/batch-1-input-repin.json`. The batch manifest was refreshed to bind the new browser evidence/logs. Earlier visual judgments remain applicable to the identical images.

This correction does not turn the independent npm-test exit 1 into a pass and does not grant owner pixel approval or production integration.
