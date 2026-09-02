import "jsr:@supabase/functions-js/edge-runtime.d.ts";

import { createMorselApp } from "../../../server/app.ts";
import { createSupabaseAuthenticator } from "../../../server/auth.ts";
import { createSupabaseRepository } from "../../../server/supabase-repository.ts";

type SupabaseEnvironmentVariable = "SUPABASE_URL" | "SUPABASE_ANON_KEY" | "MORSEL_OAUTH_SIGNING_KEY";

function environmentValue(name: SupabaseEnvironmentVariable): string {
  const value = Deno.env.get(name);
  if (value === undefined || value.trim() === "") {
    throw new Error(`missing server configuration: ${name}`);
  }
  return value;
}

const app = createMorselApp({
  // The Edge Function keeps its /mcp runtime prefix (the hosted gateway strips
  // /functions/v1), so routes register relative to it: the canonical MCP
  // transport lives AT the function root — the public
  // https://<host>/functions/v1/mcp URL — and /mcp/mcp remains only as the
  // pre-#57 compatibility alias.
  basePath: "/mcp",
  authenticate: (token) =>
    createSupabaseAuthenticator({
      supabaseUrl: environmentValue("SUPABASE_URL"),
      anonKey: environmentValue("SUPABASE_ANON_KEY"),
    })(token),
  repositoryFactory: () =>
    createSupabaseRepository(
      environmentValue("SUPABASE_URL"),
      environmentValue("SUPABASE_ANON_KEY"),
    ),
  oauth: {
    anonKey: () => environmentValue("SUPABASE_ANON_KEY"),
    // Issue #66: no external authorization page is configured. Both email-OTP
    // stages are served by this function origin — the legacy Vercel page could
    // not proxy POST /authorize, so the server-rendered /authorize route is
    // the repository-supported consent path.
    // The gateway strips /functions/v1 and supplies no forwarded prefix, so
    // derive the public base from the project URL for metadata/challenge URLs.
    publicBaseUrl: () =>
      `${environmentValue("SUPABASE_URL").replace(/\/+$/, "")}/functions/v1/mcp`,
    signingKey: () => environmentValue("MORSEL_OAUTH_SIGNING_KEY"),
    supabaseUrl: () => environmentValue("SUPABASE_URL"),
  },
});

Deno.serve((request) => app.fetch(request));
