import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'

// Contract for the "Bundle and probe Supabase Edge Function" script in
// .github/workflows/ci.yml (introduced with the issue #55 response-header
// probes). Guards a real hosted-CI failure (r1): the authorize-form probe
// consumed $registration_file before the registration POST populated it, so
// hosted CI failed with "Could not extract client_id". These assertions make
// that ordering regression fail in CI before the workflow ever runs. Issue
// #69 adds the configured-mode pins: the CI run sets the synthetic
// MORSEL_OAUTH_AUTHORIZATION_ENDPOINT to exercise the Vercel-skin mode
// (metadata split + bodyless stage-1 302), and the deploy workflow may only
// VERIFY the expected endpoint — it never creates/overwrites the
// human-gated production secret.

const root = join(fileURLToPath(import.meta.url), '..', '..')
const ciSource = readFileSync(join(root, '.github/workflows/ci.yml'), 'utf8')
const deploySource = readFileSync(join(root, '.github/workflows/deploy-edge-function.yml'), 'utf8')
const edgeSource = readFileSync(join(root, 'supabase/functions/mcp/index.ts'), 'utf8')

function bundleProbeScript() {
  const start = ciSource.indexOf('name: Bundle and probe Supabase Edge Function')
  expect(start, 'bundle/probe step must exist in ci.yml').toBeGreaterThanOrEqual(0)
  const end = ciSource.indexOf('\n      - uses:', start)
  expect(end, 'bundle/probe step must be terminated by the next step').toBeGreaterThan(start)
  return ciSource.slice(start, end)
}

describe('CI Edge bundle probe script contract', () => {
  it('references $registration_file only after the registration POST has populated it', () => {
    const script = bundleProbeScript()
    const declaration = script.indexOf('registration_file="$(mktemp)"')
    const postWrite = script.indexOf('--output "$registration_file"')
    expect(declaration, 'registration_file must be initialized with mktemp').toBeGreaterThan(-1)
    expect(postWrite, 'registration POST must write $registration_file').toBeGreaterThan(declaration)
    // Before the POST writes the file, only its declaration and the cleanup
    // trap's rm may mention it — no content reads (the hosted r1 regression
    // consumed an empty file for client_id extraction). The rm spans multiple
    // shell continuation lines, so state is tracked across ALL lines between
    // declaration and the POST write, not just the mentioning ones.
    let inCleanupRemoval = false
    const preWriteViolations = []
    for (const line of script.slice(declaration, postWrite).split('\n')) {
      const endsWithContinuation = line.trim().endsWith('\\')
      const allowed = line.includes('mktemp') || line.includes('rm -f') || inCleanupRemoval
      if (line.includes('$registration_file') && !allowed) {
        preWriteViolations.push(line.trim())
      }
      if (line.includes('rm -f')) {
        inCleanupRemoval = endsWithContinuation
      } else if (!endsWithContinuation) {
        inCleanupRemoval = false
      }
    }
    expect(preWriteViolations, 'no $registration_file consumption before the registration POST').toEqual([])
    expect(script.indexOf('cat "$registration_file"'), 'status cat must follow the POST').toBeGreaterThan(postWrite)
  })

  it('extracts client_id only after the registration POST succeeded with 201', () => {
    const script = bundleProbeScript()
    const post = script.indexOf('registration_status="$(curl')
    const successCheck = script.indexOf('if [ "$registration_status" != 201 ]')
    const extraction = script.indexOf('authorize_client_id=')
    expect(post).toBeGreaterThan(-1)
    expect(successCheck).toBeGreaterThan(post)
    expect(extraction).toBeGreaterThan(successCheck)
  })

  it('performs exactly one registration and keeps every response-header probe', () => {
    const script = bundleProbeScript()
    expect(script.match(/functions\/v1\/mcp\/register/g)).toHaveLength(1)
    for (const [label, marker] of [
      ['discovery CORS (authorization-server)', 'oauth-authorization-server'],
      ['discovery CORS (protected-resource)', 'oauth-protected-resource/mcp'],
      ['authorize-form content type', 'authorize_headers_file'],
      ['configured-mode stage redirect', 'authorize_stage_headers_file'],
      ['401 challenge CORS', 'mcp_challenge_status'],
      ['OPTIONS preflight CORS', 'preflight_headers_file'],
    ]) {
      expect(script.includes(marker), `probe present: ${label}`).toBe(true)
    }
    expect(script.split('assert_response_header "$authorize_headers_file" \'content-type\'')).toHaveLength(2)
  })

  it('probes the external Vercel authorization endpoint and the bodyless stage-1 302 (issue #69)', () => {
    const script = bundleProbeScript()
    // The CI run exercises the configured mode with a synthetic public
    // endpoint: authorization_endpoint must be the external static page while
    // issuer/token/register stay on the Supabase base.
    expect(script).toContain('MORSEL_OAUTH_AUTHORIZATION_ENDPOINT=https://morsel-authorize-ui.vercel.app/authorize')
    expect(script).toContain("expected_authorization_endpoint = 'https://morsel-authorize-ui.vercel.app/authorize'")
    expect(script).not.toContain("expected_authorization_endpoint = supabase_base.rstrip('/') + '/authorize'")
    expect(script).toContain("metadata.get('authorization_endpoint') != expected_authorization_endpoint")
    expect(script).toContain('urlparse(supabase_base).netloc == urlparse(expected_authorization_endpoint).netloc')
    expect(script).toContain("supabase_base = metadata.get('issuer')")
    expect(script).toContain("'token_endpoint': '/token'")
    expect(script).toContain("'registration_endpoint': '/register'")
    expect(script).toContain("protected.get('resource') != supabase_base")
    expect(script).toContain("protected.get('authorization_servers') != [supabase_base]")
    // The stage-1 email POST from the Vercel skin must be a bodyless 302 back
    // to the external page carrying the transaction envelope and fragment —
    // never HTML from the function origin.
    expect(script).toContain("--data-urlencode 'email=ci-probe@example.com'")
    expect(script).toContain("'^location: https://morsel-authorize-ui\\.vercel\\.app/authorize?'")
    expect(script).toContain("'^location: .*transaction='")
    expect(script).toContain("'^location: .*#code-entry$'")
    expect(script).toContain('Configured-mode stage-1 response must have an empty body')
    // The direct-visit GET fallback still pins the server-rendered email form.
    expect(script).toContain("assert_response_header \"$authorize_headers_file\" 'content-type' 'text/html; charset=utf-8'")
  })

  it('wires the optional public authorization endpoint through the Edge entrypoint (issue #69)', () => {
    expect(edgeSource).toContain('authorizationEndpoint: Deno.env.get("MORSEL_OAUTH_AUTHORIZATION_ENDPOINT"),')
    const oauthStart = edgeSource.indexOf('  oauth: {')
    const oauthEnd = edgeSource.indexOf('\n  },', oauthStart)
    expect(oauthStart, 'Edge OAuth options must exist').toBeGreaterThanOrEqual(0)
    expect(oauthEnd, 'Edge OAuth options must be bounded').toBeGreaterThan(oauthStart)
    const oauthSource = edgeSource.slice(oauthStart, oauthEnd)
    expect(oauthSource).toContain('publicBaseUrl:')
    expect(oauthSource).toContain('SUPABASE_URL')
    expect(oauthSource).toContain('authorizationEndpoint:')
    expect(oauthSource).toContain('Deno.env.get("MORSEL_OAUTH_AUTHORIZATION_ENDPOINT")')
  })

  it('stages only the signing key and verifies — never sets — the external authorization endpoint', () => {
    expect(deploySource).toContain("printf 'MORSEL_OAUTH_SIGNING_KEY=%s\\n'")
    expect(deploySource).not.toContain('MORSEL_OAUTH_AUTHORIZATION_ENDPOINT:')
    expect(deploySource).not.toMatch(/(?:printf|supabase|functions deploy)[^\n]*MORSEL_OAUTH_AUTHORIZATION_ENDPOINT/)
    expect(deploySource).toMatch(/MORSEL_OAUTH_AUTHORIZATION_ENDPOINT[^\n]*human-gated/i)
    expect(deploySource).toContain("'token_endpoint': base + '/token'")
    expect(deploySource).toContain("'registration_endpoint': base + '/register'")
    expect(deploySource).toContain("expected_authorization_endpoint = 'https://morsel-authorize-ui.vercel.app/authorize'")
    expect(deploySource).not.toContain("expected_authorization_endpoint = base + '/authorize'")
    expect(deploySource).toContain("metadata.get('authorization_endpoint') != expected_authorization_endpoint")
    expect(deploySource).not.toMatch(/(?:supabase|functions deploy)[^\n]*MORSEL_OAUTH_SIGNING_KEY/)
  })
})
