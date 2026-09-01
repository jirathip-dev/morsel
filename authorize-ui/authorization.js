export const SUPABASE_AUTHORIZE_ENDPOINT = 'https://anuerofnnewbsumukhqq.supabase.co/functions/v1/mcp/authorize'

export function authorizationEntries(search) {
  return [...new URLSearchParams(search)].filter(([name]) => name !== 'email' && name !== 'password')
}

export function mountAuthorizationPage(document, search) {
  const form = document.querySelector('[data-authorization-form]')
  const fields = document.querySelector('[data-authorization-fields]')
  if (form === null || fields === null) throw new Error('Authorization form is missing')

  form.action = SUPABASE_AUTHORIZE_ENDPOINT
  fields.replaceChildren()
  for (const [name, value] of authorizationEntries(search)) {
    const input = document.createElement('input')
    input.type = 'hidden'
    input.name = name
    input.value = value
    fields.append(input)
  }
}

if ('document' in globalThis && 'window' in globalThis) {
  mountAuthorizationPage(globalThis.document, globalThis.window.location.search)
}
