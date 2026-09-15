import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { expect } from 'vitest'
import { verifyDatedAgentWrite } from './dated-target-agent-proof.ts'
import { z } from 'zod'
import { createSupabaseRepository } from '../server/supabase-repository.ts'
import { MorselService } from '../server/service.ts'
import { DatedTargetSchema } from '../packages/schema/food-types.ts'
import { datedTargetSqlFetch, sqlLiteral, targetSql, type TargetTestDatabase } from './dated-target-test-transport.ts'

const userId = '00000000-0000-4000-8000-000000000253'
const otherId = '00000000-0000-4000-8000-000000002530'
const revision = (suffix: number) => `00000000-0000-4000-8000-${String(suffix).padStart(12, '0')}`
const manual = { calorie_target_kcal: 2000, protein_g: 100, carbs_g: 250, fat_g: 60 }

export async function verifyDatedTargetRoundTrip(database: TargetTestDatabase): Promise<void> {
  // Deterministic clock ONLY: replace clock expressions in installed routines
  // in this disposable cluster, never source code or snapshot values. Restore
  // original routine bodies in finally. All baseline numbers are real writes.
  const definitions = z.array(z.object({ definition: z.string() })).parse(JSON.parse(targetSql(database, `
    select jsonb_agg(jsonb_build_object('definition', pg_get_functiondef(oid))) from pg_proc
    where oid in ('morsel_private.lock_target_account()'::regprocedure,
      'morsel_private.capture_target_baseline(uuid)'::regprocedure,
      'morsel_private.set_dated_target_addition(uuid,date,text,numeric,uuid,uuid,boolean,boolean)'::regprocedure,
      'public.get_dated_targets(uuid,date,date,text)'::regprocedure);`)))
  const clock = (instant: string) => {
    for (const { definition } of definitions) targetSql(database,
      definition.replaceAll('clock_timestamp()', `${sqlLiteral(instant)}::timestamptz`)
        .replaceAll('now()', `${sqlLiteral(instant)}::timestamptz`))
  }
  const captured: Record<string, unknown> = {}
  const makeRepository = (id = userId) => createSupabaseRepository('https://local-postgres.invalid', 'fixture-key', {
    fetch: datedTargetSqlFetch(database, id, id === userId ? captured : {}),
  })
  const repository = makeRepository()
  const service = new MorselService({ repository, userId, now: () => new Date('2026-03-10T12:00:00Z') })
  const read = (start: string, end = start, zone = 'America/New_York') => repository.withAccessToken('local-fixture', () => repository.getDatedTargets(userId, start, end, zone))
  const auth = `set role authenticated; set "request.jwt.claim.sub" = '${userId}';`
  try {
    targetSql(database, `insert into public.users(id,email) values ('${userId}','dated@example.invalid'), ('${otherId}','other-dated@example.invalid');
      grant select, insert, update on public.profiles, public.weight_logs to authenticated;`)
    clock('2026-03-07T17:00:00Z')
    expect((await read('2026-03-06'))[0]?.baseline).toBeUndefined()
    await repository.withAccessToken('local-fixture', async () => {
      await service.setGoals(manual) // legacy signature; DB trigger captures actual manual state
      const first = (await read('2026-03-07'))[0]
      expect(first?.baseline?.goal.calorie_target_kcal).toBe(2000)
      expect(first?.baseline?.source_version).toBe('targets-v1')
      expect((await service.getDay({ date: '2026-03-06', timezone: 'America/New_York' })).goal).toBeUndefined()
      const input = { date: '2026-03-07', timezone: 'America/New_York', addition_kcal: 300, mutation_id: revision(2531) }
      await expect(service.setDatedTargetAddition(input)).rejects.toMatchObject({ cause: { message: expect.stringContaining('manual goal requires explicit acknowledgement') } })
      const added = await service.setDatedTargetAddition({ ...input, manual_goal_acknowledged: true })
      expect(added.dated_target.total_target_kcal).toBe(2300)
      // Lost response retry, same mutation, no duplicate append.
      expect((await service.setDatedTargetAddition({ ...input, manual_goal_acknowledged: true })).dated_target.addition_revision?.revision_id).toBe(revision(2531))
      clock('2026-03-07T18:00:00Z')
      await service.setGoals({ ...manual, calorie_target_kcal: 2200 })
      const revised = (await read('2026-03-07'))[0]
      expect(revised?.total_target_kcal).toBe(2500)
      expect(revised?.confirmed_addition_kcal).toBe(300)
      expect(revised?.baseline?.revision_id).not.toBe(first?.baseline?.revision_id)
      // DST spring boundary: 04:59Z still March 7, 05:00Z March 8.
      clock('2026-03-08T04:59:59Z')
      await service.setGoals({ ...manual, calorie_target_kcal: 2250 })
      clock('2026-03-08T05:00:00Z')
      await service.setGoals({ ...manual, calorie_target_kcal: 2300 })
      expect((await read('2026-03-07'))[0]?.total_target_kcal).toBe(2550)
      expect((await read('2026-03-08'))[0]?.total_target_kcal).toBe(2300)
      // Explicit past correction; zero removes but preserves revision chain.
      const correction = { ...input, addition_kcal: 0, mutation_id: revision(2532), expected_revision: revision(2531), manual_goal_acknowledged: false }
      await expect(service.setDatedTargetAddition(correction)).rejects.toMatchObject({ cause: { message: expect.stringContaining('historical confirmation') } })
      const removed = await service.setDatedTargetAddition({ ...correction, historical_confirmation: true })
      expect(removed.dated_target.total_target_kcal).toBe(2250)
      expect(removed.dated_target.addition_revision).toMatchObject({ previous_revision_id: revision(2531), historical_confirmation: true, manual_goal_acknowledged: false })
      await expect(service.setDatedTargetAddition({ ...correction, mutation_id: revision(2533), historical_confirmation: true })).rejects.toMatchObject({ cause: { message: expect.stringContaining('revision changed') } })
      await expect(service.setDatedTargetAddition({ ...input, date: '2026-03-09', mutation_id: revision(2534) })).rejects.toMatchObject({ cause: { message: expect.stringContaining('future dates') } })
      const unknown = await service.setDatedTargetAddition({ ...input, date: '2026-03-06', mutation_id: revision(2535), historical_confirmation: true })
      expect(unknown.dated_target.confirmed_addition_kcal).toBe(300)
      expect(unknown.dated_target.baseline).toBeUndefined()
      expect(unknown.dated_target.total_target_kcal).toBeUndefined()
      // Non-24-hour next midnight: March 9 starts 04:00Z after DST.
      clock('2026-03-09T03:59:59Z')
      await service.setGoals({ ...manual, calorie_target_kcal: 2400 })
      clock('2026-03-09T04:00:00Z')
      await service.setGoals({ ...manual, calorie_target_kcal: 2500 })
      expect((await read('2026-03-08'))[0]?.total_target_kcal).toBe(2400)
      expect((await read('2026-03-09'))[0]?.total_target_kcal).toBe(2500)
      // A newer profile supersedes manual; equal versions still manual-wins.
      clock('2026-03-09T12:00:00Z')
      await service.setProfile({ sex: 'male', age_years: 30, height_cm: 180, weight_kg: 80,
        activity_level: 'moderate', diet_goal: 'maintain', timezone: 'America/New_York' })
      expect((await read('2026-03-09'))[0]?.baseline?.goal.source).toBe('computed')
      await service.setGoals(manual)
      expect((await read('2026-03-09'))[0]?.baseline?.goal.source).toBe('manual')
      clock('2026-03-10T12:00:00Z')
      await service.resetGoals({})
      const computed = (await read('2026-03-10'))[0]
      expect(computed?.baseline?.goal.source).toBe('computed')
      targetSql(database, `${auth} insert into public.weight_logs(user_id,measured_at,kg,source)
        values('${userId}','2026-03-10T10:00:00Z',75,'apple_health');`)
      expect(Date.parse((await read('2026-03-10'))[0]?.baseline?.weight_measured_at ?? '')).toBe(Date.parse('2026-03-10T10:00:00Z'))
      expect((await read('2026-03-10'))[0]?.total_target_kcal).not.toBe(computed?.total_target_kcal)
      expect((await read('2026-03-07'))[0]?.total_target_kcal).toBe(2250)
      const todayAddition = await service.setDatedTargetAddition({ date: '2026-03-10', timezone: 'America/New_York',
        addition_kcal: 200, mutation_id: revision(2537) })
      expect(todayAddition.dated_target.confirmed_addition_kcal).toBe(200)
      for (const invalid of ['-1', "'NaN'::numeric", "'Infinity'::numeric"]) {
        const denied = database.execute(`${auth} select public.set_dated_target_addition('${userId}',
          '2026-03-10','America/New_York',${invalid},'${revision(2540)}');`)
        expect(denied.status).toBe(3)
        expect(denied.stderr).toContain('invalid target addition')
      }
      const beforeRollback = (await read('2026-03-10'))[0]
      const rolledBack = database.execute(`${auth} begin; update public.goals set source='manual',
        calorie_target_kcal=9999, protein_g=1, carbs_g=1, fat_g=1 where user_id='${userId}'; select 1/0;`)
      expect(rolledBack.status).toBe(3)
      expect((await read('2026-03-10'))[0]).toEqual(beforeRollback)
      // Real log writes: unknown history, logged zero, exact zero delta, gap, partial today.
      for (const [date, calories] of [['2026-03-06', 500], ['2026-03-07', 0], ['2026-03-08', 2400], ['2026-03-10', 1500]]) {
        await service.logMeal({ meal_type: 'lunch', eaten_at: `${String(date)}T12:00:00-04:00`, items: [{ name: 'Synthetic dated meal', calories_kcal: calories }] })
      }
      await verifyDatedAgentWrite(repository, userId)
      const days = await Promise.all(['2026-03-06', '2026-03-07', '2026-03-08', '2026-03-09', '2026-03-10'].map((date) => service.getDay({ date, timezone: 'America/New_York' })))
      expect(days[0]?.goal).toBeUndefined()
      expect(days[1]?.totals.calories_kcal).toBe(0)
      expect(days[1]?.remaining_kcal).toBe(2250)
      expect(days[2]?.remaining_kcal).toBe(0)
      expect(days[3]?.meals).toEqual([])
      // New connection / service instance reads durable additions, not model state.
      const restarted = makeRepository()
      expect((await restarted.withAccessToken('local-fixture', () => restarted.getDatedTargets(userId, '2026-03-07', '2026-03-07', 'Asia/Bangkok')))[0]?.addition_revision?.revision_id).toBe(revision(2532))
      const targets = await read('2026-03-06', '2026-03-10')
      await repository.getMealsInRange(userId, '2026-03-06T05:00:00Z', '2026-03-11T04:00:00Z')
      await repository.getGoals(userId)
      await repository.getProfile(userId)
      await repository.getWeightTrend(userId, '2026-02-09T05:00:00Z', '2026-03-11T04:00:00Z', 'America/New_York')
      // The native adapter selects meal_logs.source as well as the server's
      // projection, so record THAT projection of the same real rows.
      const nativeMealLogs: unknown = JSON.parse(targetSql(database, `${auth} select coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb)
        from (select id,eaten_at,meal_type,source,image_path from public.meal_logs
          where user_id=${sqlLiteral(userId)} order by eaten_at, id) r;`))
      const directory = process.env.MORSEL_DATED_EVIDENCE_DIR
      if (directory !== undefined) {
        mkdirSync(directory, { recursive: true })
        writeFileSync(join(directory, 'local-db-readback.json'), JSON.stringify({
          provenance: 'initdb cluster; production MorselService/SupabaseRepository; authenticated SQL transport; clock-only control',
          user_id: userId, timezone: 'America/New_York', today: '2026-03-10T12:00:00Z', days, targets,
          native: { ...captured, get_dated_targets: targets, meal_logs: nativeMealLogs },
        }, null, 2) + '\n')
      }
      expect(targets.map((target) => DatedTargetSchema.parse(target))).toHaveLength(5)
      console.log('DATED-ROUNDTRIP: real SQL -> SupabaseRepository -> MorselService; 5 dates; baseline unavailable/2250/2400/2000/computed; zero/unlogged/partial; persisted revisions')
    })
    const foreign = makeRepository(otherId)
    expect((await foreign.withAccessToken('local-fixture', () => foreign.getDatedTargets(otherId, '2026-03-07', '2026-03-07', 'UTC')))[0]?.baseline).toBeUndefined()
    await expect(foreign.withAccessToken('local-fixture', () => foreign.getDatedTargets(userId, '2026-03-07', '2026-03-07', 'UTC'))).rejects.toMatchObject({ cause: { message: expect.stringContaining('authenticated user') } })
    await expect(foreign.withAccessToken('local-fixture', () => foreign.setDatedTargetAddition(userId, { date: '2026-03-07', addition_kcal: 1,
      mutation_id: revision(2536), historical_confirmation: true, manual_goal_acknowledged: true }, 'UTC'))).rejects.toMatchObject({ cause: { message: expect.stringContaining('authenticated user') } })
    for (const table of ['target_baseline_revisions', 'target_addition_revisions']) {
      for (const command of [`update public.${table} set timezone='UTC'`, `delete from public.${table}`]) {
        const denied = database.execute(`${auth} ${command};`)
        expect(denied.status).toBe(3)
        expect(denied.stderr).toContain('permission denied')
      }
      const hidden = targetSql(database, `set role authenticated; set "request.jwt.claim.sub"='${otherId}';
        select jsonb_build_object('count',count(*)) from public.${table} where user_id='${userId}';`)
      expect(JSON.parse(hidden)).toEqual({ count: 0 })
    }
    const forged = database.execute(`${auth} insert into public.target_baseline_revisions(user_id,effective_date,timezone,source_inputs)
      values('${userId}','2020-01-01','UTC','{}');`)
    expect(forged.status).toBe(3)
    expect(forged.stderr).toContain('permission denied')
    const anonymous = database.execute(`set role anon; select * from public.get_dated_targets('${userId}','2026-03-07','2026-03-07','UTC');`)
    expect(anonymous.status).toBe(3)
    expect(anonymous.stderr).toContain('permission denied')
    console.log('DATED-RLS: foreign read/write, direct history modification/forgery, anonymous RPC all refused')
  } finally {
    for (const { definition } of definitions) targetSql(database, definition)
  }
}
