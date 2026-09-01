import { createAuthorizeHandler } from '../handler.js'

// Optional Cloudflare Workers adapter. UPSTREAM_AUTHORIZE_URL is non-secret
// configuration and remains fixed by the deployment environment; request data
// can never select an upstream.
export default {
  fetch(request, env) {
    return createAuthorizeHandler({
      upstreamAuthorizeUrl: env.UPSTREAM_AUTHORIZE_URL,
    })(request)
  },
}
