# Retained probe history

Earlier attempts are preserved here as superseded evidence, not final gate outcomes.

- `smoke-failure.json`: first smoke failure.
- `smoke.json`: earlier smoke success, before the full final set.
- `verification-failure.json`: earlier full probe failure, before stable pointer-driven theme controls.

Initial native-select/keyboard probing was replaced by explicit Paper/Night buttons and actual CDP pointer input. Readiness and bounded admission handling were corrected. Final reports are `evidence/verification.json` and `evidence/rerender.json`; the latter exited 0 with 1647 checks and 154 byte-identical captures.

Competing #262/Xcode workloads caused bounded admission deferrals; no sibling process was killed. Admission records are retained in `evidence/admission.jsonl`. The unresolved native SwiftUI evidence requirement is not an iteration success: see LIMITS.md.
