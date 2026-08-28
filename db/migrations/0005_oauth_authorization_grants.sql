begin;

-- Authorization grants are short-lived and user-owned. The refresh credential is
-- kept server-side so the client-facing authorization code contains no Supabase
-- access or refresh token.
create table public.oauth_authorization_grants (
  code_hash text primary key,
  client_id text not null,
  redirect_uri text not null,
  code_challenge text not null,
  scopes text[] not null default '{}'::text[],
  resource text,
  user_id uuid not null,
  refresh_token text not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index oauth_authorization_grants_expires_at_idx
  on public.oauth_authorization_grants (expires_at);

alter table public.oauth_authorization_grants enable row level security;

create policy "oauth authorization grants are readable by their owner"
  on public.oauth_authorization_grants
  for select
  to authenticated
  using ((select auth.uid()) = user_id);

create policy "oauth authorization grants are insertable by their owner"
  on public.oauth_authorization_grants
  for insert
  to authenticated
  with check ((select auth.uid()) = user_id);

revoke all on table public.oauth_authorization_grants from anon, authenticated;
grant insert on table public.oauth_authorization_grants to authenticated;

-- DELETE ... RETURNING is the claim operation. A concurrent caller waits for
-- the first delete, then sees no matching row and cannot mint another token.
create or replace function public.claim_oauth_authorization_grant(
  p_code_hash text,
  p_client_id text
)
returns table (
  code_hash text,
  client_id text,
  redirect_uri text,
  code_challenge text,
  scopes text[],
  resource text,
  user_id uuid,
  refresh_token text,
  expires_at timestamptz
)
language sql
security definer
set search_path = public, pg_temp
as $function$
  delete from public.oauth_authorization_grants
  where code_hash = p_code_hash
    and client_id = p_client_id
    and expires_at > now()
  returning
    code_hash,
    client_id,
    redirect_uri,
    code_challenge,
    scopes,
    resource,
    user_id,
    refresh_token,
    expires_at;
$function$;

revoke execute on function public.claim_oauth_authorization_grant(text, text) from public;
grant execute on function public.claim_oauth_authorization_grant(text, text) to anon, authenticated;

commit;
