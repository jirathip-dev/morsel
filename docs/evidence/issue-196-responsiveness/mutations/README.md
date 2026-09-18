# Mutation battery — the biting regression proof

`battery.sh` applies ONE mutation at a time to the audited mechanism, runs the
harness class named below, requires a behavioural RED (raw exit 65 with the
named assertion failing), then restores the file from a `cp` snapshot and
requires the sha256 to match the pre-mutation bytes before continuing.

Run it with the lane simulator:

```bash
export MORSEL_SIM_UDID=<lane UDID>
bash mutations/battery.sh 1     # … through 6
bash mutations/battery.sh green # restored tree, all three classes
```

`restore` aborts the battery (exit 9) if the restored bytes differ, so no
mutation can leak into the delivered tree.

## Mechanism → assertion map (all six RED, exit 65)

| # | mechanism mutated | file | harness assertion that fails | log |
| --- | --- | --- | --- | --- |
| 1 | mid-swing retargets ignored (`selectionChanged`'s retarget branch) | `JournalPageTurner.swift` | `one settled page on <tab>` — `baseTab` drifts from `pager.selection` | `excerpts/mutation-1-red.txt` |
| 2 | drag axis ownership removed (every drag horizontal) | `JournalPageTurner.swift` | `a scroll-owned gesture never turns a page` (vertical cycle) | `excerpts/mutation-2-red.txt` |
| 3 | page ownership removed (`.disabled(!owns(tab))` → `false`) | `MorselApp.swift` | `one settled page on <tab>` — every mounted page stays activatable | `excerpts/mutation-3-red.txt` |
| 4 | interruption settles nothing (`interrupt()` returns early) | `JournalPageTurner.swift` | `backgrounding must settle the in-flight turn at once` | `excerpts/mutation-4-red.txt` |
| 5 | freshness join dropped (`TodayRefreshOwner.start`) | `TodayRefreshOwner.swift` | `an activation during a parked read joins it` — recorded calls become 2 | `excerpts/mutation-5-red.txt` |
| 6 | cancellation dropped (`TodayRefreshOwner.cancel`) | `TodayRefreshOwner.swift` | `a cancelled read must not publish while the user is away` | `excerpts/mutation-6-red.txt` |

Restored-tree GREEN (same harness revision as the RED legs):

| class | excerpt | raw exit | tests | failures |
| --- | --- | --- | --- | --- |
| `ResponsivenessShellCycleTests` | `excerpts/green-shell-cycles.txt` | 0 | 2 | 0 |
| `ResponsivenessBudgetTests` | `excerpts/green-budget.txt` | 0 | 5 | 0 |
| `ResponsivenessIntervalsTests` | `excerpts/green-intervals.txt` | 0 | 4 | 0 |

Restore receipts (sha256 of the delivered head bytes, printed by the battery):

- `JournalPageTurner.swift` `c924b9e176c72b7d51cdeb1cf5df311f294192c3455c5ec10d900a50b01f8bb4`
- `MorselApp.swift` `c87e298c45b3827592f5d9d54046ead3177f3f2915cb784a747e5cd31d0098d9`
- `TodayRefreshOwner.swift` `176299f1f65849fba13de02bcf81b39b32c617ac6bf7cee5adba8a03ee8260ca`

`git status --short app/Sources/` is empty after the battery: the delivered tree
is byte-identical to the committed head, so no probe leaked.
