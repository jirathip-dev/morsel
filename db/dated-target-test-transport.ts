import { z } from 'zod'

export interface TargetTestDatabase {
  execute(sql: string): { status: number | null; stdout: string; stderr: string }
}
export const sqlLiteral = (value: string): string => `'${value.replaceAll("'", "''")}'`
const identifier = (value: string): string => z.string().regex(/^[a-z_]+$/).parse(value)

export function targetSql(database: TargetTestDatabase, sql: string): string {
  const result = database.execute(sql)
  if (result.status !== 0) throw new Error(`local target SQL failed (${String(result.status)}): ${result.stderr}`)
  return result.stdout.split(/\r?\n/).filter((line) => line.startsWith('{') || line.startsWith('[')).join('')
}

// Transport only: every returned value is a real SQL result under the caller's
// authenticated role. No fabricated profile/goal/meal/target responses.
export function datedTargetSqlFetch(database: TargetTestDatabase, userId: string,
  captured: Record<string, unknown> = {}): typeof fetch {
  const implementation = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const request = input instanceof Request ? new Request(input, init) : new Request(input.toString(), init)
    const url = new URL(request.url)
    const name = identifier(url.pathname.split('/').pop() ?? '')
    let query: string
    let scalar = false
    if (url.pathname.includes('/rpc/')) {
      const args = z.record(z.string(), z.unknown()).parse(await request.json())
      const signatures: Record<string, Record<string, string>> = {
        get_dated_targets: { p_user_id: 'uuid', p_start_date: 'date', p_end_date: 'date', p_timezone: 'text' },
        set_dated_target_addition: { p_user_id: 'uuid', p_date: 'date', p_timezone: 'text', p_addition_kcal: 'numeric',
          p_mutation_id: 'uuid', p_expected_revision: 'uuid', p_historical_confirmation: 'boolean', p_manual_goal_acknowledged: 'boolean' },
        compute_targets: { p: 'public.profiles' },
        log_meal_with_items: { p_user_id: 'uuid', p_eaten_at: 'timestamptz', p_meal_type: 'text', p_source: 'text',
          p_image_path: 'text', p_notes: 'text', p_items: 'jsonb' },
      }
      const signature = signatures[name]
      if (signature === undefined) throw new Error(`unsupported local RPC ${name}`)
      const params = Object.entries(signature).map(([key, type]) => {
        const value = args[key]
        if (value === undefined || value === null) return `${key} => null::${type}`
        if (type === 'public.profiles') return `${key} => jsonb_populate_record(null::public.profiles, ${sqlLiteral(JSON.stringify(value))}::jsonb)`
        return `${key} => ${sqlLiteral(type === 'jsonb' ? JSON.stringify(value) : String(value))}::${type}`
      }).join(',')
      const call = `public.${name}(${params})`
      scalar = name === 'set_dated_target_addition'
      query = name === 'get_dated_targets' ? `select coalesce(jsonb_agg(value), '[]'::jsonb) from ${call} value`
        : scalar ? `select ${call}` : `select coalesce(jsonb_agg(to_jsonb(value)), '[]'::jsonb) from ${call} value`
    } else {
      const table = z.enum(['users', 'profiles', 'goals', 'weight_logs', 'meal_logs', 'meal_items']).parse(name)
      const columns = (url.searchParams.get('select') ?? '*').split(',').map(identifier).join(',')
      let statement: string
      if (request.method === 'POST') {
        const body = z.record(z.string(), z.union([z.string(), z.number(), z.null()])).parse(await request.json())
        const keys = Object.keys(body).map(identifier)
        const values = Object.values(body).map((value) => value === null ? 'null' : sqlLiteral(String(value)))
        const conflictKey = table === 'users' ? 'id' : 'user_id'
        statement = `insert into public.${table} (${keys.join(',')}) values (${values.join(',')})
          on conflict(${conflictKey}) do update set ${keys.filter((key) => key !== conflictKey).map((key) => `${key}=excluded.${key}`).join(',')}
          returning ${columns}`
      } else {
        if (request.method !== 'GET') throw new Error(`unsupported local method ${request.method}`)
        const predicates: string[] = []
        for (const [key, value] of url.searchParams) {
          if (['select', 'order', 'limit'].includes(key)) continue
          if (value.startsWith('in.(') && value.endsWith(')')) {
            predicates.push(`${identifier(key)} in (${value.slice(4, -1).split(',').map(sqlLiteral).join(',')})`)
          } else {
            const [operator, ...parts] = value.split('.')
            const comparison = z.enum(['eq', 'gte', 'lt', 'lte']).parse(operator)
            predicates.push(`${identifier(key)} ${{ eq: '=', gte: '>=', lt: '<', lte: '<=' }[comparison]} ${sqlLiteral(parts.join('.'))}`)
          }
        }
        const order = url.searchParams.get('order')?.split(',').map((part) => {
          const [column, direction] = part.split('.')
          return `${identifier(column ?? '')} ${z.enum(['asc', 'desc']).parse(direction)}`
        }).join(',')
        statement = `select ${columns} from public.${table}${predicates.length ? ` where ${predicates.join(' and ')}` : ''}
          ${order === undefined ? '' : `order by ${order}`}`
        const limit = url.searchParams.get('limit')
        if (limit !== null) statement += ` limit ${z.string().regex(/^\d+$/).parse(limit)}`
      }
      query = `with rows as (${statement}) select coalesce(jsonb_agg(to_jsonb(rows)), '[]'::jsonb) from rows`
    }
    const result = database.execute(`set role authenticated; set "request.jwt.claim.sub" = ${sqlLiteral(userId)}; ${query};`)
    if (result.status !== 0) return Response.json({ message: result.stderr }, { status: 400 })
    let data: unknown = JSON.parse(result.stdout.split(/\r?\n/).filter((line) => line.startsWith('{') || line.startsWith('[')).join(''))
    if (!scalar && request.headers.get('accept')?.includes('vnd.pgrst.object') === true) data = z.array(z.unknown()).parse(data)[0] ?? null
    captured[name] = data
    return Response.json(data)
  }
  implementation.preconnect = (): void => undefined
  return implementation
}
