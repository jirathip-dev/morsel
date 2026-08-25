import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

const migrationPath = resolve(process.cwd(), 'db/migrations/0003_atomic_meals_and_users_rls.sql')

function migrationSql(): string {
  return readFileSync(migrationPath, 'utf8')
}

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
