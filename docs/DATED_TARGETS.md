# Dated food targets (issue #253)

Owner-confirmed contract: eaten − (dated baseline + confirmed addition). This
is a food-target comparison, not an energy-deficit estimate or an explanation
of weight change. No automatic exercise recommendation is implemented.

## Shared database interface

Migration: `db/migrations/0014_dated_targets.sql`. No historical backfill is run.

`get_dated_targets(p_user_id uuid, p_start_date date, p_end_date date,
p_timezone text)` is an authenticated, security-invoker read. It returns one
JSON object per inclusive calendar date (up to 366 dates), in ascending order:

- `date`, `timezone`: the requested diary date and IANA timezone.
- `baseline` (absent when unavailable): `revision_id`, `recorded_at`,
  `effective_date`, `timezone`, `source_version: "targets-v1"`, `goal` (the
  existing calorie/macronutrient fields and manual/computed source), and
  available `profile_updated_at`, `goals_updated_at`, `weight_measured_at`.
- `confirmed_addition_kcal`: persisted nonnegative addition, otherwise zero.
- `addition_revision` (absent before any addition write): `revision_id`,
  `recorded_at`, `timezone`, optional `previous_revision_id`,
  `historical_confirmation`, `manual_goal_acknowledged`.
- `total_target_kcal` (absent without baseline): baseline calories + addition.
  The addition changes calories only; the snapshot's macro values are unchanged.

`set_dated_target_addition(p_user_id uuid, p_date date, p_timezone text,
p_addition_kcal numeric, p_mutation_id uuid, p_expected_revision uuid = null,
p_historical_confirmation boolean = false,
p_manual_goal_acknowledged boolean = false)` returns that date's same read
object. It never accepts a baseline value, effective time or revision source.

Read first and pass the latest `addition_revision.revision_id` as
`p_expected_revision` (null if none). Use a fresh mutation UUID for new intent.
A stale expected revision fails rather than silently overwriting another
client. Retrying a committed UUID with identical parameters does not append a
second revision; the response is the current date readback, which may include
later edits. Reusing that UUID for different parameters fails.

Today can be adjusted; past corrections require explicit historical
confirmation. Future writes are not supported. A positive addition to a manual baseline requires
explicit manual-goal acknowledgement. As with the existing Undo, removal does
not require a new manual-goal acknowledgement. Zero explicitly removes the addition
by appending a zero-valued revision; it does not erase the previous record.
These are account/date values shared across processes, devices and authenticated
agents, not device-local state or a separate value per timezone. The confirmation
timezone is preserved on each revision.

## Baseline observation and time

The database observes actual state on profile, goal, weight and meal-insert
writes, including unchanged legacy RPCs and direct authenticated native writes.
A confirmed addition for today also observes today's baseline. Read RPCs do
not create snapshots. Existing users without an observation therefore have
unavailable history; today keeps the shipped effective-goal read (claiming no
dated provenance) until a real write observes it.

Profile/goal write timestamps are server-owned. Writes serialize on the account
row. A baseline revision contains the actual input rows, their versions,
the resulting goal, algorithm version, database observation instant, and that
instant's date in the profile timezone (UTC if none). A newer profile supersedes
a manual goal; equal versions favor a complete manual goal. Computed targets use
the latest imported weight with the existing profile fallback. A loss of a
usable baseline is recorded as unavailable, not a continued old target.

Same-day edits append revisions; the newest observation for that diary day
wins. Additions are in a separate append-only history and survive baseline
edits. A date's baseline is the latest observation strictly before its following
local midnight, never a later/current goal. The first observation is never
extended to earlier dates. Persisted source date/timezone describe the original
observation; applicability uses the requested diary timezone, as existing meal
reads do. Calendar-midnight arithmetic handles 23/25-hour DST days. Future
baseline reads are unavailable.

Changing a baseline today cannot change a completed past date's baseline.
Explicit past addition correction can change that date's total and retains its
revision/confirmation provenance. It cannot make an unavailable baseline known.

## Read consumers and rollout

`get_day` adds optional `dated_target`. When attributable, `goal` uses its total
calorie target, and `remaining_kcal` is total minus eaten. Without dated
provenance a historical `goal`/`remaining_kcal` is omitted, never borrowed from
`get_goals`. Today is not history: when no observation exists yet, today (and a
single-day summary) keeps the shipped effective-goal read and claims no dated
provenance, while a multi-day range never compares itself against today's
target. The compatibility fallback for an older repository is today-only.
`get_dashboard_summary` adds optional `dated_targets`; a multi-day render no
longer compares its range against today's target. Read-only annotations stay
read-only. Current goal/profile tools otherwise retain their signatures.

Native `HistoryRepository` reads the same RPC into optional
`HistoryDay.datedTarget`; old cached records still decode. `WeightDeltaDay`
requires attributable values, otherwise keeps its unavailable state. The
selected-day receipt exposes dated baseline, confirmed addition, total and
signed difference. Logged zero, no log and partial today remain distinct;
weight deduplication and the calendar/flip mechanics are unchanged.

The shared native write seam for #254 is
`SupabaseDashboardRepository.saveDatedTargetAddition(DatedTargetAdditionParams)`;
its read seam is `loadDatedTargets`. The sibling owns lifecycle/UI integration,
not a second persistence or baseline implementation. No training UI is changed
by this lane.

Tables `target_baseline_revisions` and `target_addition_revisions` permit only
owner SELECT through RLS. Authenticated direct history insert/update/delete is
revoked. Capture routines are private; the private privileged addition writer
checks `auth.uid()`, date, consent and expected revision. Public RPC wrappers
are security invoker and have no PUBLIC/anonymous execution grant.

Deploy this forward migration before the new server/native consumers in a
separately authorized release. Existing clients may omit new fields and keep
using old write signatures. Unmigrated databases are not silently supported.
The older recovery tool owns only 0001–0013: it tolerates the pending 0014 file
but never converges/stamps it, and refuses a database whose ledger already
contains newer history. Forward apply remains the path for 0014. This lane
performs no deployment or remote database changes.

## Reproducible proof

`npm run test:postgres` uses a real disposable initdb/pg_ctl cluster. Tests
control only the database clock expressions, never baseline values; all values
are produced by actual authenticated writes and the production server/read
contract. Routine bodies are restored and the cluster is removed on completion.

To regenerate the SQL readback used by the ordinary native regression:

    MORSEL_DATED_EVIDENCE_DIR=docs/evidence/issue-253 npm run test:postgres

The optional live bridge, not a replacement for either gate:

    npx vitest run --config db/dated-native.config.ts

It creates another disposable cluster, exercises the same persisted sequence,
then publishes a loopback URL in `.lane-logs/dated-native/ready.json`. Run the
native test suite while it is ready. `DatedTargetReadRenderTests` then reads
LIVE SQL through the production native repository, compares the production
server readback and paints the real Paper/Night chart. After both captures
pass it acknowledges completion; the bridge verifies requests, exits and
removes its cluster. It has a bounded deadline and no remote connection path.
Without the live marker the durable native test explicitly reports SQL-readback
replay, not live end-to-end proof.
