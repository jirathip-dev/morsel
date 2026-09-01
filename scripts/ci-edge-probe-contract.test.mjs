import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'

// Contract for the "Bundle and probe Supabase Edge Function" script in
// .github/workflows/ci.yml (introduced with the issue #55 response-header
// probes). Guards a real hosted-CI failure (r1): the authorize-form probe
// consumed $registration_file before the registration POST populated it, so
// hosted CI failed with "Could not extract client_id". These assertions make
// that ordering regression fail in CI before the workflow ever runs.

const root = join(fileURLToPath(import.meta.url), '..', '..')
const ciSource = readFileSync(join(root, '.github/workflows/ci.yml'), 'utf8')

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
      ['401 challenge CORS', 'mcp_challenge_status'],
      ['OPTIONS preflight CORS', 'preflight_headers_file'],
    ]) {
      expect(script.includes(marker), `probe present: ${label}`).toBe(true)
    }
    expect(script.split('assert_response_header "$authorize_headers_file" \'content-type\'')).toHaveLength(2)
  })
})
