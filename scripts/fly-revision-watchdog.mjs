#!/usr/bin/env node
// Morsel issue #261 — deployed Fly revision watchdog (READ-ONLY).
//
// Compares the revision that is ACTUALLY RUNNING on the Fly origin with main's
// HEAD and reports exactly one verdict:
//   IN_SYNC — the deployed revision IS main's HEAD;
//   BEHIND  — the deployed revision is a different commit, with the commits
//             main is ahead by;
//   UNKNOWN — the deployed revision could NOT be observed (unreachable origin,
//             non-200/malformed payload, or a build with no baked revision).
//
// REVISION SOURCE OF TRUTH (docs/FLY_DEPLOY.md §"Deployed revision"): the Fly
// origin's own `/version` route (server/app.ts `buildIdentity`) reports the git
// revision baked into the RUNNING image at build time (`MORSEL_BUILD_REVISION`,
// passed by deploy-fly.yml as `flyctl deploy --build-arg`) together with the
// identifiers Fly injects into that machine (`FLY_IMAGE_REF`, `FLY_MACHINE_ID`,
// `FLY_APP_NAME`). The deployed revision is therefore read from the process
// that is serving the traffic — never inferred from a workflow's last success,
// a cached value, an image tag, or an assumption.
//
// FAIL CLOSED: an unobservable or revision-less deployment is UNKNOWN with a
// nonzero exit — NEVER a green IN_SYNC. Only an exact revision equality is
// IN_SYNC; a different revision is BEHIND. IN_SYNC is silent for the scheduled
// workflow (exit 0, no issue); BEHIND is reported so the workflow opens or
// refreshes exactly one issue.
//
// READ-ONLY BY CONSTRUCTION: GET requests only — the origin's `/version` and
// the GitHub read API. No deploy, no flyctl, no write of any kind. Tokens are
// read from the environment and are never printed; the report carries only
// revisions, image/machine identifiers, and commit summaries.
//
// Environment (all optional; the scheduled workflow supplies the GitHub ones):
//   MORSEL_FLY_ORIGIN       origin to read /version from (default canonical)
//   MORSEL_GITHUB_API_BASE  GitHub API base for the read-only compare
//   GITHUB_REPOSITORY       owner/repo whose main is compared (Actions default)
//   GITHUB_TOKEN / GH_TOKEN token for the GitHub read API (public reads work
//                           without one)

import { pathToFileURL } from "node:url";

export const DEFAULT_ORIGIN = "https://mcp.morselfood.app";
export const DEFAULT_GITHUB_API_BASE = "https://api.github.com";
export const DEFAULT_REPOSITORY = "jirathip-dev/morsel";
export const MAIN_BRANCH = "main";
export const GIT_REVISION_PATTERN = /^[0-9a-f]{40}$/;
const REPOSITORY_PATTERN = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const MAX_LISTED_COMMITS = 20;
const DEFAULT_TIMEOUT_MS = 30_000;

export class UsageError extends Error {
  exitCode = 2;
}

function isRevision(value) {
  return typeof value === "string" && GIT_REVISION_PATTERN.test(value);
}

function nonBlankString(value) {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
}

/** Sanitized failure label: raw error/response text never reaches the report. */
function failureLabel(error) {
  const name = error instanceof Error ? error.name : "";
  if (name === "TimeoutError") {
    return "request timed out";
  }
  if (name === "AbortError") {
    return "request aborted";
  }
  return "request failed";
}

function isLoopbackHostname(hostname) {
  return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "[::1]";
}

/** GitHub read-API headers; the token is sent but never logged. */
function githubHeaders(token) {
  const headers = { "user-agent": "morsel-fly-revision-watchdog" };
  return token === undefined ? headers : { ...headers, authorization: `Bearer ${token}` };
}

/** Label for the report: the origin's scheme/host only, never a full URL. */
function originLabel(origin) {
  const resolved = readOrigin(origin);
  return resolved.error === undefined ? resolved.url.origin : origin;
}

function validateEnvValue(name, value) {
  if (/[\s\u0000-\u001f\u007f]/.test(value)) {
    throw new UsageError(`${name} must not contain whitespace or control characters.`);
  }
}

async function getJson(fetchImpl, url, init, timeoutMs) {
  const response = await fetchImpl(url, {
    ...init,
    headers: { accept: "application/json", ...init.headers },
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) {
    return { ok: false, status: response.status, body: null };
  }
  let body;
  try {
    body = await response.json();
  } catch {
    return { ok: false, status: response.status, body: null, malformed: true };
  }
  return { ok: true, status: response.status, body };
}

function readOrigin(origin) {
  let url;
  try {
    url = new URL("/version", origin);
  } catch {
    return { error: "the origin is not an absolute URL" };
  }
  if (url.protocol !== "https:" && !(url.protocol === "http:" && isLoopbackHostname(url.hostname))) {
    return { error: "the origin must be absolute HTTPS (http is allowed only for loopback probes)" };
  }
  return { url };
}

/**
 * Read the deployed build identity from the origin's `/version` route. Returns
 * `{ ok: true, revision, image, machineId, app }` (revision is null when the
 * running build carries none) or `{ ok: false, reason }`. Never throws; never
 * invents a revision.
 */
export async function readDeployedIdentity({ origin, fetchImpl = fetch, timeoutMs = DEFAULT_TIMEOUT_MS }) {
  const resolved = readOrigin(origin);
  if (resolved.error !== undefined) {
    return { ok: false, reason: resolved.error };
  }
  let response;
  try {
    response = await getJson(fetchImpl, resolved.url.href, { method: "GET" }, timeoutMs);
  } catch (error) {
    return {
      ok: false,
      reason: `the deployed revision could not be read from ${resolved.url.origin}/version (${failureLabel(error)})`,
    };
  }
  if (!response.ok) {
    const detail = response.malformed === true ? "returned a non-JSON body" : `answered HTTP ${response.status}`;
    return { ok: false, reason: `${resolved.url.origin}/version ${detail}` };
  }
  const body = response.body;
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    return { ok: false, reason: `${resolved.url.origin}/version did not return an object` };
  }
  return {
    ok: true,
    revision: isRevision(body.revision) ? body.revision : null,
    image: nonBlankString(body.image),
    machineId: nonBlankString(body.machineId),
    app: nonBlankString(body.app),
  };
}

/** Read main's HEAD from the GitHub read API. Never throws. */
export async function readMainHead({ repository, apiBase = DEFAULT_GITHUB_API_BASE, token, fetchImpl = fetch, timeoutMs = DEFAULT_TIMEOUT_MS }) {
  const url = `${apiBase}/repos/${repository}/commits/${MAIN_BRANCH}`;
  const label = `the GitHub read API (refs/heads/${MAIN_BRANCH})`;
  let response;
  try {
    response = await getJson(fetchImpl, url, { method: "GET", headers: githubHeaders(token) }, timeoutMs);
  } catch (error) {
    return { ok: false, sha: null, reason: `${label} could not be reached (${failureLabel(error)})` };
  }
  if (!response.ok) {
    return { ok: false, sha: null, reason: `${label} answered HTTP ${response.status}` };
  }
  const sha = response.body === null ? null : response.body.sha;
  if (!isRevision(sha)) {
    return { ok: false, sha: null, reason: `${label} did not report a full git revision` };
  }
  return { ok: true, sha };
}

/**
 * List the commits main is ahead of the deployed revision by (GitHub compare,
 * read-only). Returns `{ ok: true, status, aheadBy, commits, omitted }` or
 * `{ ok: false, reason }`; the verdict itself never depends on this read.
 */
export async function readCommitsAhead({ repository, apiBase = DEFAULT_GITHUB_API_BASE, token, deployedRevision, mainSha, fetchImpl = fetch, timeoutMs = DEFAULT_TIMEOUT_MS }) {
  const url = `${apiBase}/repos/${repository}/compare/${deployedRevision}...${mainSha}`;
  const label = "the GitHub compare API";
  let response;
  try {
    response = await getJson(fetchImpl, url, { method: "GET", headers: githubHeaders(token) }, timeoutMs);
  } catch (error) {
    return { ok: false, reason: `${label} could not be reached (${failureLabel(error)})` };
  }
  if (!response.ok) {
    return { ok: false, reason: `${label} answered HTTP ${response.status}` };
  }
  const body = response.body;
  if (body === null || typeof body !== "object" || !Array.isArray(body.commits)) {
    return { ok: false, reason: `${label} did not return a commit list` };
  }
  const commits = body.commits
    .filter((commit) => commit !== null && typeof commit === "object" && isRevision(commit.sha))
    .map((commit) => ({
      sha: commit.sha,
      subject: typeof commit.commit?.message === "string" ? commit.commit.message.split("\n")[0] : "(no subject)",
    }));
  return {
    ok: true,
    status: typeof body.status === "string" ? body.status : "unknown",
    aheadBy: typeof body.ahead_by === "number" ? body.ahead_by : commits.length,
    commits: commits.slice(0, MAX_LISTED_COMMITS),
    omitted: Math.max(0, commits.length - MAX_LISTED_COMMITS),
  };
}

/**
 * Pure verdict. `deployed` is the `readDeployedIdentity` result. Only an exact
 * equality of two full git revisions is IN_SYNC; anything unobservable is
 * UNKNOWN (never a guessed IN_SYNC); anything else is BEHIND.
 */
export function revisionVerdict({ mainSha, deployed }) {
  if (!isRevision(mainSha)) {
    return { verdict: "UNKNOWN", reason: `main's HEAD is unavailable, so the deployed revision cannot be compared.` };
  }
  if (deployed === null || deployed === undefined || deployed.ok !== true) {
    const detail = deployed === null || deployed === undefined ? "the deployed revision was not read" : deployed.reason;
    return { verdict: "UNKNOWN", reason: `${detail} — the running revision is UNOBSERVED, which is NOT a green state.` };
  }
  if (deployed.revision === null) {
    return {
      verdict: "UNKNOWN",
      reason:
        "the running build reports no baked revision (the image predates the revision bake, or MORSEL_BUILD_REVISION was missing at build time)",
    };
  }
  if (deployed.revision === mainSha) {
    return { verdict: "IN_SYNC", reason: `the revision running in production equals main's ${MAIN_BRANCH} HEAD.` };
  }
  return {
    verdict: "BEHIND",
    reason: `the revision running in production (${deployed.revision}) is not main's ${MAIN_BRANCH} HEAD (${mainSha}).`,
  };
}

export function formatVerdict(result) {
  const { verdict, main, deployed, compare } = result;
  const lines = [];
  lines.push("Morsel Fly revision watchdog — main vs the DEPLOYED Fly revision (READ-ONLY)");
  lines.push(`VERDICT=${verdict}`);
  lines.push(`BEHIND=${verdict === "BEHIND" ? "true" : "false"}`);
  lines.push(`origin: ${result.origin} (read from the process that is serving: GET /version)`);
  lines.push(`main: ${main.ok ? main.sha : "unavailable"} (refs/heads/${MAIN_BRANCH})`);
  if (deployed.ok) {
    lines.push(`deployed: ${deployed.revision ?? "(no baked revision)"}`);
    lines.push(`  image: ${deployed.image ?? "(not reported)"}`);
    lines.push(`  machine: ${deployed.machineId ?? "(not reported)"}  app: ${deployed.app ?? "(not reported)"}`);
  } else {
    lines.push("deployed: unavailable");
  }
  lines.push(`reason: ${result.reason}`);
  if (verdict === "BEHIND") {
    if (compare !== null && compare !== undefined && compare.ok) {
      if (compare.status === "diverged") {
        lines.push(`the deployed revision and main have DIVERGED (neither is an ancestor of the other).`);
      } else if (compare.status === "behind") {
        lines.push(`the deployed revision is AHEAD of main (main has no commits the deployed revision lacks).`);
      }
      lines.push(`main is ${compare.aheadBy} commit(s) ahead of the deployed revision:`);
      for (const commit of compare.commits) {
        lines.push(`  - ${commit.sha} ${commit.subject}`);
      }
      if (compare.omitted > 0) {
        lines.push(`  … and ${compare.omitted} more`);
      }
    } else {
      const detail = compare === null || compare === undefined ? "the compare was not attempted" : compare.reason;
      lines.push(`the commits main is ahead by could NOT be listed (${detail}); the two revisions differ and must not be assumed to be a fast-forward.`);
    }
    lines.push(
      'Action: redeploy morsel-mcp from main with the human-dispatched "Deploy Fly (morsel-mcp)" workflow, then re-run this watchdog (docs/FLY_DEPLOY.md §Deployed revision).',
    );
  } else if (verdict === "IN_SYNC") {
    lines.push("clean: the revision running in production equals main's head.");
  } else {
    lines.push("Action: the deployed revision could not be OBSERVED — this is NOT a green state. Check the origin and the revision bake (docs/FLY_DEPLOY.md §Deployed revision).");
  }
  lines.push(
    `FLY_REVISION_JSON=${JSON.stringify({
      verdict,
      origin: result.origin,
      main: { ok: main.ok, sha: main.ok ? main.sha : null },
      deployed: {
        ok: deployed.ok,
        revision: deployed.ok ? deployed.revision : null,
        image: deployed.ok ? deployed.image : null,
        machineId: deployed.ok ? deployed.machineId : null,
        app: deployed.ok ? deployed.app : null,
      },
      commitsAhead: compare !== null && compare !== undefined && compare.ok ? compare.commits.map((commit) => commit.sha) : null,
      reason: result.reason,
    })}`,
  );
  return lines.join("\n");
}

export async function run({
  origin = DEFAULT_ORIGIN,
  repository = DEFAULT_REPOSITORY,
  apiBase = DEFAULT_GITHUB_API_BASE,
  token,
  fetchImpl = fetch,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  log = console,
}) {
  const main = await readMainHead({ repository, apiBase, token, fetchImpl, timeoutMs });
  const deployed = await readDeployedIdentity({ origin, fetchImpl, timeoutMs });
  const evaluated = revisionVerdict({ mainSha: main.ok ? main.sha : null, deployed });
  const compare = evaluated.verdict === "BEHIND" && deployed.ok && deployed.revision !== null
    ? await readCommitsAhead({
        repository,
        apiBase,
        token,
        deployedRevision: deployed.revision,
        mainSha: main.sha,
        fetchImpl,
        timeoutMs,
      })
    : null;
  const result = { ...evaluated, origin: originLabel(origin), main, deployed, compare };
  log.log(formatVerdict(result));
  return result;
}

export async function main(argv = process.argv.slice(2), env = process.env) {
  try {
    if (argv.length > 0) {
      throw new UsageError("fly-revision-watchdog accepts no arguments.");
    }
    const origin = env.MORSEL_FLY_ORIGIN ?? DEFAULT_ORIGIN;
    const apiBase = env.MORSEL_GITHUB_API_BASE ?? DEFAULT_GITHUB_API_BASE;
    const repository = env.GITHUB_REPOSITORY ?? DEFAULT_REPOSITORY;
    validateEnvValue("MORSEL_FLY_ORIGIN", origin);
    validateEnvValue("MORSEL_GITHUB_API_BASE", apiBase);
    validateEnvValue("GITHUB_REPOSITORY", repository);
    if (!REPOSITORY_PATTERN.test(repository)) {
      throw new UsageError("GITHUB_REPOSITORY must be owner/repo.");
    }
    const token = nonBlankString(env.GITHUB_TOKEN) ?? nonBlankString(env.GH_TOKEN) ?? undefined;
    const result = await run({ origin, repository, apiBase, token });
    return result.verdict === "UNKNOWN" ? 1 : 0;
  } catch (error) {
    if (error instanceof UsageError) {
      console.error(`✗ ${error.message}`);
      return error.exitCode;
    }
    console.error("✗ fly revision watchdog failed (error details suppressed)");
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(await main());
}
