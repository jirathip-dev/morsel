import { readFileSync, statSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

const repoRoot = new URL('../', import.meta.url)
const runbook = 'docs/FLY_DEPLOY.md'

// Scope: concrete file tokens in this runbook's inline code, including commands.
// Qualify by its source roots (plus the two root-level deploy files), not by
// existing/tracked filenames: filtering those would hide a stale reference.
// URLs/routes, directories, globs, placeholders, generated/local outputs (e.g.
// fly-morsel.env), and ambiguous bare names (e.g. Fastfile) are out of scope.
// Other docs and Markdown link destinations need a separate, broader policy.
const repositoryFile = /^(?:(?:\.github|authorize-ui|docs|infra|scripts|server)\/(?:[\w-]+\/)*[\w.-]+\.[a-z\d]+|Dockerfile|fly\.toml)$/

function referencedFiles(markdown: string) {
  return markdown.split('\n').flatMap((line, index) =>
    [...line.matchAll(/`([^`\n]+)`/g)].flatMap((match) =>
      (match[1] ?? '').split(/\s+/)
        .map((token) => token.replace(/^\.\//, ''))
        .filter((path) => repositoryFile.test(path))
        .map((path) => ({ path, line: index + 1 })),
    ),
  )
}

describe('Fly runbook repository file references', () => {
  it('resolves every qualified reference to a file in the checkout', () => {
    const references = referencedFiles(readFileSync(new URL(runbook, repoRoot), 'utf8'))
    expect(references.length, 'runbook path extraction must not be empty').toBeGreaterThan(0)
    for (const { path, line } of references) {
      expect.soft(
        statSync(new URL(path, repoRoot), { throwIfNoEntry: false })?.isFile(),
        `${runbook}:${String(line)} references missing repository file: ${path}`,
      ).toBe(true)
    }
  })

  it('extracts paths from prose and commands without requiring them to exist', () => {
    expect(referencedFiles([
      'See `server/fly-entrypoint.bun-test.ts`.',
      '`bun test ./server/not-yet-created.test.ts`',
      '`npx vitest run scripts/first.test.mjs scripts/second.test.mjs`',
      '`infra/fly/app-create.sh <new-app-name> --org <fly-org> [--apply]`',
      '`Dockerfile`, `fly.toml`, `.github/workflows/deploy-fly.yml`',
      '`docs/DRIFT.md` and `authorize-ui/params.js`',
    ].join('\n'))).toEqual([
      { path: 'server/fly-entrypoint.bun-test.ts', line: 1 },
      { path: 'server/not-yet-created.test.ts', line: 2 },
      { path: 'scripts/first.test.mjs', line: 3 },
      { path: 'scripts/second.test.mjs', line: 3 },
      { path: 'infra/fly/app-create.sh', line: 4 },
      { path: 'Dockerfile', line: 5 },
      { path: 'fly.toml', line: 5 },
      { path: '.github/workflows/deploy-fly.yml', line: 5 },
      { path: 'docs/DRIFT.md', line: 6 },
      { path: 'authorize-ui/params.js', line: 6 },
    ])
  })

  it('excludes external, illustrative, generated and unqualified paths', () => {
    expect(referencedFiles([
      '`https://example.com/server/missing.ts` and `/mcp/token`',
      '`registry.fly.io/morsel-mcp:deployment-<sha>` and `tools/list`',
      '`infra/` + `docs/` and `bun test ./server/...`',
      '`server/*.ts` and `server/<example>.ts`',
      '`fly secrets import -a morsel-mcp < fly-morsel.env`',
      '`dist/server.js` and `/tmp/probe.json`',
      '`Fastfile` and `deploy-fly.yml`',
      'server/not-inline.ts and [other doc](docs/elsewhere.md)',
    ].join('\n'))).toEqual([])
  })
})
