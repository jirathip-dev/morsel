# Contributing

> NOTE: this section was destined for CLAUDE.md (formerly AGENTS.md, now a
> symlink to CLAUDE.md; issue #1) but agent writes to
> that file are policy-blocked; a human should fold it in.

## Branch policy
Feature PRs target `staging`, the protected integration branch, gated by the
required checks `quality`, `swiftlint`, `bun-fly-entrypoint` and
`fastfile-contract`. `main` is release-only and is promoted from `staging` by a
human; production/CD (deploy + migration apply) remains human-dispatched:
deploys run only via explicit `workflow_dispatch`, and migration apply runs
only through an explicit human-enabled dispatch/flag, while the `main` push
trigger performs read-only classification only — the `classify` job in
`.github/workflows/migration-cd.yml`.

## Quality gates (mandatory)
- **Run `npm run typecheck && npm run lint && npm test` before any PR.** All
  three must be green; a PR that skips the gate is not reviewable.
- **Bare `as T` is banned** (including `as unknown as T` and non-null `!`).
  ESLint enforces this at error level. Types are not asserted into existence —
  add **runtime validation at the seams** instead (schema parse / type guard
  where external data enters: MCP tool inputs, DB rows, HTTP bodies), and let
  inference carry the type from there.
- Swift under `app/` is gated by SwiftLint (`.swiftlint.yml`): force
  unwrap/cast/try and implicitly-unwrapped optionals are errors — handle the
  optional or fail with a thrown error.
