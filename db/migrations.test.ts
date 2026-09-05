import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

const migrationPath = resolve(process.cwd(), 'db/migrations/0003_atomic_meals_and_users_rls.sql')
const oauthMigrationPath = resolve(process.cwd(), 'db/migrations/0005_oauth_authorization_grants.sql')
const weightMigrationPath = resolve(process.cwd(), 'db/migrations/0007_weight_logs.sql')
const outboxMigrationPath = resolve(process.cwd(), 'db/migrations/0010_meal_outbox_client_ids.sql')
const timezoneMigrationPath = resolve(process.cwd(), 'db/migrations/0011_profiles_timezone.sql')

function migrationSql(): string {
  return readFileSync(migrationPath, 'utf8')
}

function oauthMigrationSql(): string {
  return readFileSync(oauthMigrationPath, 'utf8')
}

function weightMigrationSql(): string {
  return readFileSync(weightMigrationPath, 'utf8')
}

describe('migration 0011 profile timezone contract', () => {
  it('adds a nullable profiles.timezone column with an IANA-shape check', () => {
    const sql = readFileSync(timezoneMigrationPath, 'utf8')
    expect(sql).toContain('alter table public.profiles')
    expect(sql).toContain('add column if not exists timezone text')
    expect(sql).toMatch(/add constraint profiles_timezone_check/)
    // Null is the default state and means UTC (v0.1 backward compatible).
    expect(sql).toMatch(/timezone is null/)
    // Only IANA-shaped values pass: the fixed 'UTC' alias or Area/Location
    // names with at least one '/'.
    expect(sql).toMatch(/timezone = 'UTC'/)
    expect(sql).toMatch(/timezone ~ '\^\[A-Za-z0-9_\+-\]\+\(\/\[A-Za-z0-9_\+-\]\+\)\+\$'/)
  })
})

describe('migration 0007 weight log contract', () => {
  it('renames HealthKit timestamps, enforces positive values, and deduplicates measurements', () => {
    const sql = weightMigrationSql()
    expect(sql).toContain('rename column logged_at to measured_at')
    expect(sql).toContain('unique (user_id, measured_at)')
    expect(sql).toContain('check (kg > 0)')
    expect(sql).toContain("add column source text not null default 'manual'")
    expect(sql).toContain("source in ('manual', 'apple_health')")
    expect(sql).toContain('weight_logs_user_measured_idx')
  })
})

describe('migration 0003 security and transaction contract', () => {
  it('protects public.users from cross-user select, insert, and update access', () => {
    const sql = migrationSql()

    expect(sql).toContain('alter table public.users enable row level security;')
    expect(sql).toMatch(/create policy "users_select_own"[\s\S]*?using \(\(select auth\.uid\(\)\) = id\);/i)
    expect(sql).toMatch(/create policy "users_insert_own"[\s\S]*?with check \(\(select auth\.uid\(\)\) = id\);/i)
    expect(sql).toMatch(/create policy "users_update_own"[\s\S]*?using \(\(select auth\.uid\(\)\) = id\)[\s\S]*?with check \(\(select auth\.uid\(\)\) = id\);/i)
  })

  it('defines a security-invoker RPC that inserts both meal tables', () => {
    const sql = migrationSql()
    const functionStart = sql.indexOf('create or replace function public.log_meal_with_items')
    expect(functionStart).toBeGreaterThanOrEqual(0)
    const functionSql = sql.slice(functionStart)

    expect(functionSql).toMatch(/security invoker/i)
    expect(functionSql).not.toMatch(/security definer/i)
    expect(functionSql).toContain('auth.uid() is distinct from p_user_id')
    expect(functionSql).toContain('insert into public.meal_logs')
    expect(functionSql).toContain('insert into public.meal_items')
    expect(functionSql).toContain('jsonb_to_recordset(p_items)')
    expect(functionSql).toMatch(/grant execute on function public\.log_meal_with_items\([\s\S]*\) to authenticated;/i)
  })
})

describe('migration 0010 meal outbox idempotency contract', () => {
  it('adds a client-id meal RPC with the idempotency conflict guard', () => {
    const sql = readFileSync(outboxMigrationPath, 'utf8')

    expect(sql).toMatch(/create or replace function public\.log_meal_with_items_client\(/i)
    expect(sql).toMatch(
      /create or replace function public\.log_meal_with_items_client\([\s\S]*?p_client_meal_id uuid/i
    )
    expect(sql).toContain('security invoker')
    expect(sql).not.toMatch(/security definer/i)
    expect(sql).toContain('auth.uid() is distinct from p_user_id')
    // A retry after a server-side commit must find the existing row.
    expect(sql).toMatch(/insert into public\.meal_logs \([\s\S]*?on conflict \(id\) do nothing/i)
    expect(sql).toContain("v_inserted := found")
    // Items are only inserted when THIS client id was not already committed.
    expect(sql).toMatch(/if v_inserted then[\s\S]*?insert into public\.meal_items/i)
    // A foreign client id must never write through the authenticated path.
    expect(sql).toMatch(/raise exception 'meal id does not match authenticated user'[\s\S]*?errcode = '42501'/i)
    expect(sql).toMatch(/revoke execute on function public\.log_meal_with_items_client\([\s\S]*?jsonb, uuid\s*\) from public;/i)
    expect(sql).toMatch(/grant execute on function public\.log_meal_with_items_client\([\s\S]*?jsonb, uuid\s*\) to authenticated;/i)
    // The original server/MCP RPC is untouched (separate name).
    expect(sql).not.toMatch(/log_meal_with_items\(/i)
  })
})

describe('migration 0005 OAuth grant claim contract', () => {
  it('stores grants behind owner-scoped RLS policies', () => {
    const sql = oauthMigrationSql()

    expect(sql).toContain('create table public.oauth_authorization_grants')
    expect(sql).toContain('alter table public.oauth_authorization_grants enable row level security;')
    expect(sql).toMatch(/create policy "oauth authorization grants are readable by their owner"[\s\S]*?using \(\(select auth\.uid\(\)\) = user_id\);/i)
    expect(sql).toMatch(/create policy "oauth authorization grants are insertable by their owner"[\s\S]*?with check \(\(select auth\.uid\(\)\) = user_id\);/i)
    expect(sql).toContain('grant insert on table public.oauth_authorization_grants to authenticated;')
  })

  it('defines the public claim RPC as an atomic security-definer delete', () => {
    const sql = oauthMigrationSql()
    const functionStart = sql.indexOf('create or replace function public.claim_oauth_authorization_grant')
    expect(functionStart).toBeGreaterThanOrEqual(0)
    const functionSql = sql.slice(functionStart)

    expect(functionSql).toMatch(/\(\s*p_code_hash text,\s*p_client_id text\s*\)/i)
    expect(functionSql).toMatch(/returns table[\s\S]*?code_hash text[\s\S]*?refresh_token text/i)
    expect(functionSql).toMatch(/language sql\s+security definer\s+set search_path = public, pg_temp/i)
    expect(functionSql).toMatch(/delete from public\.oauth_authorization_grants[\s\S]*?expires_at > now\(\)[\s\S]*?returning/i)
    expect(functionSql).toMatch(/revoke execute on function public\.claim_oauth_authorization_grant\(text, text\) from public;/i)
    expect(functionSql).toMatch(/grant execute on function public\.claim_oauth_authorization_grant\(text, text\) to anon, authenticated;/i)
  })
})
