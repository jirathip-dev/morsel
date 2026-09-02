// Morsel static authorization page — OAuth query-parameter bridge (issue #69).
//
// Supabase's free shared domain rewrites text/html Edge Function responses to
// text/plain, so the consent HTML lives on this Vercel static skin while the
// OAuth backend stays on the Supabase Edge Function. This same-origin script
// is the only JavaScript on the page: it copies the allowlisted OAuth query
// fields into hidden inputs on the stage forms and points every form at the
// Supabase /authorize route. The browser then performs a direct cross-origin
// form POST — no fetch/XHR, no CORS, no proxy, no storage, no analytics, no
// logging, and no credential handling.
//
// Stage identity is per form (not per fragment): #email-form is the stage-1
// submission and #code-form the stage-2 submission; the #code-entry fragment
// only selects which stage the CSS shows. Each form therefore carries exactly
// the state the server expects for its stage:
//   - stage 1 (#email-form): every allowlisted non-credential OAuth field;
//   - stage 2 (#code-form): the same fields plus the sealed `transaction`
//     envelope the server minted on the stage-1 response.
// The server merges form bodies with URLSearchParams.set (last occurrence
// wins), so a repeated query key is bridged once, with its last value.
(function () {
  'use strict'

  var AUTHORIZE_URL = 'https://anuerofnnewbsumukhqq.supabase.co/functions/v1/mcp/authorize'

  // Closed allowlist of OAuth fields the server actually supports. Query
  // fields outside this list, fragment data, and credentials (email, code,
  // password) are never bridged into a form body.
  var BRIDGE_FIELDS = [
    'client_id',
    'redirect_uri',
    'response_type',
    'code_challenge',
    'code_challenge_method',
    'scope',
    'resource',
    'state',
    'transaction',
  ]

  // The sealed transaction envelope belongs to the code stage only: the
  // server excludes it from carried fields until it mints a fresh one on the
  // stage-1 response, so a stale envelope never rides a stage-1 submission.
  var CODE_STAGE_ONLY_FIELDS = ['transaction']

  // Browser globals are read through globalThis so the same file runs in a
  // page (window) and in the node:vm DOM harness used by the vitest contract.
  var emailForm = globalThis.document.getElementById('email-form')
  var codeForm = globalThis.document.getElementById('code-form')

  // Once the bridge runs, no stage form may submit to the static host: both
  // forms post straight to the Supabase authorize route.
  emailForm.action = AUTHORIZE_URL
  codeForm.action = AUTHORIZE_URL

  // Deterministic duplicate handling: iterate every query entry in order and
  // keep the last value per allowlisted key (first-seen order), matching the
  // server's requestParameters merge of a form body.
  var names = []
  var values = {}
  if (globalThis.location.search !== '') {
    var query = new URLSearchParams(globalThis.location.search)
    for (var pair of query.entries()) {
      var name = pair[0]
      if (BRIDGE_FIELDS.indexOf(name) === -1) {
        continue
      }
      if (!(name in values)) {
        names.push(name)
      }
      values[name] = pair[1]
    }
  }

  if (names.length === 0) {
    return
  }

  var stage1 = []
  var stage2 = []
  for (var i = 0; i < names.length; i += 1) {
    var field = names[i]
    stage2.push([field, values[field]])
    if (CODE_STAGE_ONLY_FIELDS.indexOf(field) === -1) {
      stage1.push([field, values[field]])
    }
  }

  appendHiddenInputs(emailForm, stage1)
  appendHiddenInputs(codeForm, stage2)

  function appendHiddenInputs(form, fields) {
    for (var index = 0; index < fields.length; index += 1) {
      var input = globalThis.document.createElement('input')
      input.type = 'hidden'
      input.name = fields[index][0]
      input.value = fields[index][1]
      form.appendChild(input)
    }
  }
})()
