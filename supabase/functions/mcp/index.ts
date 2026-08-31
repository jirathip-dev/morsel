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
    // The gateway strips /functions/v1 and supplies no forwarded prefix, so
    // derive the public base from the project URL for metadata/challenge URLs.
    publicBaseUrl: () =>
      `${environmentValue("SUPABASE_URL").replace(/\/+$/, "")}/functions/v1/mcp`,
    signingKey: () => environmentValue("MORSEL_OAUTH_SIGNING_KEY"),
    supabaseUrl: () => environmentValue("SUPABASE_URL"),
  },
});

Deno.serve((request) => app.fetch(request));
