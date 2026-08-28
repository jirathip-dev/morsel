import "jsr:@supabase/functions-js/edge-runtime.d.ts";

import { createMorselApp } from "../../../server/app.ts";
import { createSupabaseAuthenticator } from "../../../server/auth.ts";
import { createSupabaseRepository } from "../../../server/supabase-repository.ts";

type SupabaseEnvironmentVariable = "SUPABASE_URL" | "SUPABASE_ANON_KEY";

function environmentValue(name: SupabaseEnvironmentVariable): string {
  const value = Deno.env.get(name);
  if (value === undefined || value.trim() === "") {
    throw new Error(`missing server configuration: ${name}`);
  }
  return value;
}

const app = createMorselApp({
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
});

Deno.serve((request) => app.fetch(request));
