import { spawnSync } from "node:child_process";

function defaultRunGit(args, cwd) {
  const result = spawnSync("git", args, {
    cwd,
    encoding: "utf8",
    env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  return { status: result.status, stdout: result.stdout ?? "", stderr: result.stderr ?? result.error?.message ?? "" };
}

function commandError(result) {
  return result.stderr.trim() || `git exited with status ${result.status ?? "unknown"}`;
}

export function checkoutFreshness(cwd, runGit = defaultRunGit) {
  const worktree = runGit(["rev-parse", "--is-inside-work-tree"], cwd);
  if (worktree.status !== 0 || worktree.stdout.trim() !== "true") return { kind: "error", detail: commandError(worktree) };
  const branch = runGit(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd);
  if (branch.status !== 0) return { kind: "unchecked" };
  const branchName = branch.stdout.trim();
  const upstreamResult = runGit(["for-each-ref", "--format=%(upstream:short)", `refs/heads/${branchName}`], cwd);
  if (upstreamResult.status !== 0) return { kind: "error", detail: commandError(upstreamResult) };
  const upstream = upstreamResult.stdout.trim();
  if (!upstream) return { kind: "unchecked" };
  const fetchResult = runGit(["fetch", "--quiet", "--no-tags"], cwd);
  if (fetchResult.status !== 0) return { kind: "error", upstream, detail: commandError(fetchResult) };
  const countResult = runGit(["rev-list", "--count", `HEAD..${upstream}`], cwd);
  const behind = Number.parseInt(countResult.stdout.trim(), 10);
  if (countResult.status !== 0 || !Number.isSafeInteger(behind) || behind < 0) return { kind: "error", upstream, detail: commandError(countResult) };
  return behind > 0 ? { kind: "behind", upstream, behind } : { kind: "current", upstream };
}

export function checkoutGuardExitCode(freshness, operation, writeError = (message) => console.error(message)) {
  if (freshness.kind === "behind") {
    const noun = freshness.behind === 1 ? "commit" : "commits";
    writeError(`✗ STALE CHECKOUT: HEAD is ${freshness.behind} ${noun} behind ${freshness.upstream}.\n  Unpulled migrations cannot be seen from this checkout, so ${operation} was not run.\n  Pull or rebase onto the upstream branch, then retry.`);
    return 1;
  }
  if (freshness.kind === "error") {
    const upstream = freshness.upstream ? ` ${freshness.upstream}` : "";
    writeError(`✗ Could not verify checkout freshness against${upstream}; ${operation} was not run.\n  ${freshness.detail}`);
    return 1;
  }
  return 0;
}

export const FILENAME_RE = /^(\d{4})_([a-z0-9_]+)\.sql$/;

export function parseMigrationNames(files) {
  return files.slice().sort().map((file) => {
    const match = FILENAME_RE.exec(file);
    if (!match) throw new Error(`${file} doesn't match 000N_name.sql`);
    return { version: match[1], name: match[2], file };
  });
}

export function appendOnlyDecision(local, recorded) {
  const pending = local.filter((migration) => !recorded.has(migration.name));
  const applied = local.filter((migration) => recorded.has(migration.name));
  const newestApplied = applied.length ? applied[applied.length - 1].version : "0";
  const historical = pending.filter((migration) => migration.version <= newestApplied);
  return { pending, newestApplied, historical, allowed: historical.length === 0 };
}

export function ledgerNamesWithoutLocalFiles(local, ledgerNames) {
  const localNames = new Set(local.map((migration) => migration.name));
  return [...ledgerNames].filter((name) => !localNames.has(name)).sort();
}

export function formatLedgerOnlyWarning(entries) {
  const present = entries.filter(({ names }) => names.length > 0);
  if (present.length === 0) return null;
  const count = present.reduce((sum, { names }) => sum + names.length, 0);
  const lines = [`⚠ WARNING: ${count} ledger ${count === 1 ? "entry has" : "entries have"} no local migration file.`];
  for (const { label, names } of present) {
    lines.push(`  ${label} (${names.length}):`, ...names.map((name) => `    ${name}`));
  }
  lines.push("  This checkout cannot verify those migrations; ledger rows only report what was recorded as applied.");
  return lines.join("\n");
}

export function localMigrationsRecordedMessage(count, destination) {
  return `✓ all ${count} local ${count === 1 ? "migration is" : "migrations are"} recorded on ${destination}.`;
}
