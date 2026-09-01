const HTML_CONTENT_TYPE = 'text/html; charset=utf-8'
const CSP = "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
const ALLOWED_METHODS = 'GET,HEAD,POST,OPTIONS'

function validatedUpstream(value) {
  let url
  try {
    url = new URL(value)
  } catch {
    throw new Error('UPSTREAM_AUTHORIZE_URL must be a valid HTTPS URL')
  }
  if (url.protocol !== 'https:' || url.username !== '' || url.password !== '' || url.search !== '' || url.hash !== '' || !url.pathname.endsWith('/authorize')) {
    throw new Error('UPSTREAM_AUTHORIZE_URL must be a fixed HTTPS /authorize URL without credentials, query, or fragment')
  }
  return url.href
}

function rawQuery(url) {
  const question = url.indexOf('?')
  return question < 0 ? '' : url.slice(question)
}

function securityHeaders(contentType = HTML_CONTENT_TYPE) {
  return {
    'cache-control': 'no-store',
    'content-security-policy': CSP,
    'content-type': contentType,
    'x-content-type-options': 'nosniff',
  }
}

function rejected(message = 'upstream response rejected') {
  return new Response(message, {
    status: 502,
    headers: { 'cache-control': 'no-store', 'content-type': 'text/plain; charset=utf-8', 'x-content-type-options': 'nosniff' },
  })
}

function jsonResponse(upstream, body) {
  return new Response(body, {
    status: upstream.status,
    headers: {
      'cache-control': 'no-store',
      'content-type': upstream.headers.get('content-type') ?? 'application/json',
      'x-content-type-options': 'nosniff',
    },
  })
}

function validRedirectLocation(value) {
  if (value === null) return false
  let url
  try {
    url = new URL(value)
  } catch {
    return false
  }
  if (url.protocol === 'https:') return true
  return url.protocol === 'http:' && new Set(['localhost', '127.0.0.1', '[::1]']).has(url.hostname)
}

function redirectResponse(upstream) {
  const location = upstream.headers.get('location')
  if (!validRedirectLocation(location)) return rejected()
  return new Response(null, {
    status: upstream.status,
    headers: { 'cache-control': 'no-store', location, 'x-content-type-options': 'nosniff' },
  })
}

async function getResponse(upstreamResponse, upstreamUrl, head) {
  const contentType = upstreamResponse.headers.get('content-type')?.toLowerCase() ?? ''
  if (contentType.startsWith('application/json')) {
    return jsonResponse(upstreamResponse, head ? null : await upstreamResponse.arrayBuffer())
  }
  if (!contentType.startsWith('text/plain') && !contentType.startsWith('text/html')) return rejected()
  if (head) return new Response(null, { status: upstreamResponse.status, headers: securityHeaders() })
  const body = await upstreamResponse.text()
  const action = `action="${upstreamUrl}"`
  if (body.split(action).length !== 2) return rejected()
  return new Response(body.replace(action, 'action="/authorize"'), {
    status: upstreamResponse.status,
    headers: securityHeaders(),
  })
}

async function postResponse(upstreamResponse) {
  if (upstreamResponse.status >= 300 && upstreamResponse.status < 400) return redirectResponse(upstreamResponse)
  const contentType = upstreamResponse.headers.get('content-type')
  const body = await upstreamResponse.arrayBuffer()
  return new Response(body, {
    status: upstreamResponse.status,
    headers: {
      'cache-control': 'no-store',
      ...(contentType === null ? {} : { 'content-type': contentType }),
      'x-content-type-options': 'nosniff',
    },
  })
}

export function createAuthorizeHandler(options) {
  const upstream = validatedUpstream(options?.upstreamAuthorizeUrl)
  const fetchUpstream = options?.fetch ?? fetch

  return async function handleAuthorize(request) {
    const requestUrl = new URL(request.url)
    if (requestUrl.pathname !== '/authorize') return new Response('not found', { status: 404 })
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        status: 204,
        headers: {
          'access-control-allow-headers': 'content-type',
          'access-control-allow-methods': ALLOWED_METHODS,
          'access-control-allow-origin': '*',
          'cache-control': 'no-store',
        },
      })
    }
    if (!['GET', 'HEAD', 'POST'].includes(request.method)) {
      return new Response('method not allowed', { status: 405, headers: { allow: ALLOWED_METHODS } })
    }

    try {
      const query = rawQuery(request.url)
      if (request.method === 'POST') {
        const contentType = request.headers.get('content-type')
        const upstreamResponse = await fetchUpstream(`${upstream}${query}`, {
          method: 'POST',
          redirect: 'manual',
          headers: contentType === null ? undefined : { 'content-type': contentType },
          body: new Uint8Array(await request.arrayBuffer()),
        })
        return postResponse(upstreamResponse)
      }
      const upstreamResponse = await fetchUpstream(`${upstream}${query}`, {
        method: request.method,
        redirect: 'manual',
      })
      return getResponse(upstreamResponse, upstream, request.method === 'HEAD')
    } catch {
      return rejected('upstream request failed')
    }
  }
}
