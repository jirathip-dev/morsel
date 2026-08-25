# Contributing

> NOTE: this section was destined for AGENTS.md (issue #1) but agent writes to
> that file are policy-blocked; a human should fold it in.

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
