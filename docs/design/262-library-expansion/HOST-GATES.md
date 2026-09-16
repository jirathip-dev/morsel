# Repository gates and render admission

## Executed repository gates

`npm ci --no-audit --no-fund`, `npm run typecheck`, `npm run lint`, and `git diff --check`: raw exit 0.

The owner/orchestrator explicitly authorized `npm test` outside the render window. It was run once: **raw exit 1**, 583 passed / 2 failed (585 tests); 50 passed / 2 failed files (52 files); two worker `onTaskUpdate` timeout errors.

The failed tests are 5000ms timeouts in unchanged files:

- `server/http.test.ts`: registers all tools and routes log_meal through the repository without Supabase.
- `server/tool-classification.test.ts`: read-only annotated tools never write.

The brief explicitly identifies this unchanged-server timeout class as host-side and makes hosted quality authoritative. The aggregate is still reported **FAIL**, not waived to PASS. No timeout increases, test skipping, retry sweeps or claim of hosted CI success. Raw output and exits are in `evidence/repo-gates/`.

No native gate was launched: there are no application/Swift/DB/schema changes in this lane.

## Renderer coordination

Owner coordination ruling: no shared render lock exists; do not invent one. Issue 262 has the next Morsel render window, and issue 263 yields to its live render. The admission predicate is no actual `xcodebuild`/`xctest` and no active sibling renderer, not a globally idle host.

The pipeline starts with the prescribed `pgrep -fl "chrome|blender|render|xcodebuild"`, correlates actual process executables/ancestry to avoid counting Rust `diagnostic-rendered` flags or queued wrapper prose as renders, and records real blocking PIDs and UTC times. An idle persistent browser daemon is distinguished from a live render. Failure to discover processes is not permission to render.

Each observation window is bounded to 60 seconds, with tighter checks inside that window to catch short gaps between native probes. Deferred windows append to each batch's `admission.jsonl`. Render work is serial, admitted in groups of at most four studies/captures. Completed export identities are checkpointed before another admission window. No sibling process is signalled, killed, suspended, restarted or reprioritized by these scripts.

The original, over-broad hold was corrected following owner coordination: TypeScript tests now run independently. A multiline `pgrep` parsing failure was also corrected; regression probes cover that case, actual native-process denial and actual sibling-render denial. These fixes do not weaken the native/render predicate.

## Reproducibility boundary

Artwork master/export SHA-256 equality is deterministic. Admission timestamps, executed gate logs and the resulting whole-package manifest are run evidence, not a claim that an entire evidence directory is timestamp-free. A new run regenerates its manifest after all evidence is final.
