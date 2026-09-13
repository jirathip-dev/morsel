# Timing · measured work, separated

| Observed phase/window | Seconds |
|---|---:|
| six source initial window | 370.000 |
| seven source initial window | 419.785 |
| chicken initial authoring window | 118.081 |
| chicken export review correction window | 172.443 |
| session through final visual review window | 2560.394 |
| final full build | 13.634 |
| renderer subprocesses within build | 13.312 |
| proof composition | 0.361 |
| browser captures and dom checks | 4.521 |
| workflow fixture suite | 21.751 |
| no op build | 0.050 |
| single source mutation build | 1.149 |
| synthetic single addition build | 1.435 |

- Two source-batch windows overlap; do not sum as project duration.
- Initial source windows include prerequisite reads and tool waits, not final parent correction or review.
- Chicken correction window includes initial render/review and subsequent edits; not pure drawing.
- Session window includes tooling, reads, waits, review and corrections but ends before final documentation/packaging/Git handoff.
- Compiler and synthetic addition timings are machine work only, not creating finished art.

Not separately instrumented: active uninterrupted drawing time, fallback corrective drawing alone, skill/tooling authoring alone, final documentation and Git handoff. No retroactive estimate is substituted.

The source-batch JSONs preserve initial-stage timestamps/structural reports. Their Grains/Protein hashes predate parent corrections; final bytes are pinned by SHA256SUMS.json. Gate wrappers also record elapsed process time, which includes interpreter overhead and may exceed the inner phase timing. Host conditions varied between runs; this is evidence of this execution, not a throughput benchmark.
