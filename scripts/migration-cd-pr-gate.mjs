#!/usr/bin/env node
// Morsel issue #83 — append-only PR shape gate for db/migrations (READ-ONLY).
//
// Runs on pull requests that touch db/migrations/**. It performs NO hosted
// query and uses NO secrets (safe on untrusted/fork PRs): with local git only
// it compares the PR's migration delta against the merge-base manifest and
// blocks the PR when the delta is not a clean forward-only append:
//   - edits, deletes, or renames of already-merged migration files,
//   - additions whose version is not strictly newer than the newest version
//     merged on main (a backward/repair edit),
//   - names that do not follow db/migrations/000N_name.sql.
// Those changes are repair/retro-edit material and can NEVER auto-apply; they
// must go through the manual recovery path (Deploy Migrations (Recovery
// Apply) workflow_dispatch) after a human reviews them.
//
// CLI: node scripts/migration-cd-pr-gate.mjs <base-sha>
// The checked-out HEAD is the PR head; the base manifest and the changed-file
// list come from `git ls-tree <base-sha>` and `git diff <base-sha>...HEAD`
// (read-only). Exit 0 = append-only delta OK; 1 = blocked; 2 = usage/error.

import { spawnSync } from "node:child_process";
import { dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { FILENAME_RE, parseMigrationNames } from "./migration-safety.mjs";

export class UsageError extends Error {
  exitCode = 2;
}

function runGit(args, cwd) {
  const result = spawnSync("git", args, {
    cwd,
    encoding: "utf8",
    env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.status !== 0) {
    const detail = (result.stderr ?? "").trim() || `git exited with status ${result.status}`;
    throw new UsageError(`git ${args[0]} failed: ${detail}`);
  }
  return (result.stdout ?? "").trim();
}

function normalizeEntry(entry) {
  return String(entry).split("/").pop();
}

function splitLines(text) {
  return text ? text.split("\n").filter(Boolean) : [];
}

// Validate every entry (base and head) and collect the violation reasons;
// entries are repo paths or bare basenames, normalized to basenames.
export function validateMigrationEntries(entries) {
  const reasons = [];
  const seen = new Map();
  for (const entry of entries) {
    const basename = normalizeEntry(entry);
    if (!FILENAME_RE.test(basename)) {
      reasons.push(`${entry} does not follow db/migrations/000N_name.sql`);
      continue;
    }
    if (seen.has(basename)) continue;
    seen.set(basename, entry);
  }
  return { names: [...seen.keys()], reasons };
}

// Pure PR shape classification. All inputs are db/migrations entries (repo
// paths or basenames): baseFiles (manifest on main), headFiles (manifest at
// the PR head), changedFiles (db/migrations files the PR changes).
export function classifyPrShape({ baseFiles = [], headFiles = [], changedFiles = [] }) {
  const reasons = [];
  const baseCheck = validateMigrationEntries(baseFiles);
  const headCheck = validateMigrationEntries(headFiles);
  reasons.push(...baseCheck.reasons, ...headCheck.reasons);
  if (reasons.length > 0) {
    return { ok: false, additions: [], reasons };
  }

  const base = parseMigrationNames(baseCheck.names);
  const head = parseMigrationNames(headCheck.names);
  const baseNames = new Set(base.map((migration) => migration.file));
  const headNames = new Set(head.map((migration) => migration.file));
  const headNameSet = new Set();
  for (const migration of head) {
    if (headNameSet.has(migration.name)) {
      reasons.push(`${migration.file} duplicates an existing migration name in the PR head manifest`);
    }
    headNameSet.add(migration.name);
  }

  const changedNames = new Set(changedFiles.map(normalizeEntry).filter((name) => FILENAME_RE.test(name)));
  for (const migration of base) {
    if (!headNames.has(migration.file)) {
      reasons.push(
        `${migration.file} is deleted or renamed by this PR — recorded migrations are byte-immutable; schema surgery goes through the manual recovery path and can never auto-apply`,
      );
    } else if (changedNames.has(migration.file)) {
      reasons.push(
        `${migration.file} is edited by this PR — an edit to an already-merged migration can never auto-apply (manual recovery path only)`,
      );
    }
  }
  if (reasons.length > 0) {
    return { ok: false, additions: [], reasons };
  }

  const maxBaseVersion = base.length ? base[base.length - 1].version : null;
  const additions = head.filter((migration) => !baseNames.has(migration.file));
  const backward = additions.filter(
    (migration) => maxBaseVersion !== null && migration.version <= maxBaseVersion,
  );
  if (backward.length > 0) {
    reasons.push(
      `${backward.map((migration) => migration.file).join(", ")} add(s) a version not strictly newer than the newest merged version (${maxBaseVersion}) — a backward/repair edit can never auto-apply (manual recovery path only)`,
    );
  }
  // Version collisions among the new additions themselves (versions beyond
  // the base range repeated in one PR) make the head manifest ambiguous.
  const additionVersionSet = new Set();
  for (const migration of additions) {
    if (maxBaseVersion === null || migration.version > maxBaseVersion) {
      if (additionVersionSet.has(migration.version)) {
        reasons.push(`${migration.file} duplicates version ${migration.version} among the PR's new additions`);
      }
      additionVersionSet.add(migration.version);
    }
  }
  if (reasons.length > 0) {
    return { ok: false, additions: [], reasons };
  }
  return { ok: true, additions: additions.map((migration) => migration.file), reasons: [] };
}

export function formatVerdict(result) {
  const lines = [];
  lines.push("Morsel migration CD PR shape gate — READ-ONLY (no hosted query, no secrets)");
  lines.push("==================================================");
  lines.push(result.ok ? "appendOnly=true" : "appendOnly=false");
  lines.push(
    result.additions.length === 0
      ? "additions: none (no db/migrations change)"
      : `additions: ${result.additions.join(", ")}`,
  );
  if (result.reasons.length === 0) {
    lines.push("decision: APPEND-ONLY OK — additions are forward-only; they may be merged and, once enabled, auto-applied.");
  } else {
    lines.push("decision: BLOCKED — this delta is not a clean forward-only append and can NEVER auto-apply.");
    for (const reason of result.reasons) {
      lines.push(`  reason: ${reason}`);
    }
    lines.push("Manual path: Deploy Migrations (Recovery Apply) workflow_dispatch (confirmation phrase required).");
  }
  return lines.join("\n");
}

export async function main(argv = process.argv.slice(2), root = dirname(dirname(fileURLToPath(import.meta.url)))) {
  try {
    if (argv.length !== 1 || !/^[0-9a-f]{40}$/.test(argv[0])) {
      throw new UsageError("usage: node scripts/migration-cd-pr-gate.mjs <base-sha> (40-hex)");
    }
    const baseSha = argv[0];
    const changed = splitLines(runGit(["diff", "--name-only", `${baseSha}...HEAD`, "--", "db/migrations"], root));
    const baseFiles = splitLines(runGit(["ls-tree", "-r", "--name-only", baseSha, "--", "db/migrations"], root));
    const headFiles = splitLines(runGit(["ls-tree", "-r", "--name-only", "HEAD", "--", "db/migrations"], root));
    const result = classifyPrShape({ baseFiles, headFiles, changedFiles: changed });
    console.log(formatVerdict(result));
    return result.ok ? 0 : 1;
  } catch (error) {
    if (error instanceof UsageError) {
      console.error(`✗ ${error.message}`);
      return error.exitCode;
    }
    console.error("✗ migration CD PR shape gate failed (error details suppressed)");
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(await main());
}
