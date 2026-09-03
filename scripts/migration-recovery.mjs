#!/usr/bin/env node
// Morsel issue #76 — production schema recovery runner.
//
// Classifies the live schema for db/migrations/0001..0009 against their
// complete canonical end-state contracts and, ONLY under an explicit human
// confirmation, converges missing/partial end states and records the
// migration ledger inside per-step atomic transactions.
//
// SAFETY MODEL
// - Default (no flags) mode is plan/read-only: every statement is a fixed
//   allowlisted SELECT; no converge SQL and no ledger write can reach the
//   query layer.
// - Write mode requires --apply AND --confirm <byte-exact phrase tied to
//   issue #76>, a current-main checkout guard, and a non-ambiguous plan.
//   Every write-capable statement is a member of a fixed set of assembled
//   transaction strings whose fragments are static module constants. Nothing
//   (SQL text, migration filename, project URL, query text) is accepted from
//   CLI input.
// - Apply + ledger recording is atomic per migration step (one BEGIN..COMMIT
//   transaction). A ledger row is inserted only inside the same transaction
//   as that step's converge work and only after the step's in-transaction
//   postcondition guard passes, so a crash can never leave DDL applied with
//   its ledger row absent.
// - Secrets and response contents are never logged: only fixed
//   labels/statuses escape, and raw env values are validated before use.
//
// This script was NOT run against the live production project during its
// implementation lane; production apply is a separate human-gated step.

import { readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { checkoutFreshness, checkoutGuardExitCode, parseMigrationNames } from "./migration-safety.mjs";
import {
  ABSENT_COLUMNS,
  CANONICAL_COLUMNS,
  CANONICAL_CONSTRAINTS,
  CANONICAL_FILES,
  CANONICAL_INDEX_COLUMNS,
  CANONICAL_INDEXES,
  CANONICAL_NAMES,
  CANONICAL_POLICIES,
  CANONICAL_RLS,
  CANONICAL_ROUTINES,
  CANONICAL_TABLES,
  CONVERGE_STATEMENTS,
  EXACT_POLICY_TABLES,
  EXACT_UNIQUE_TABLES,
  FOOD_IMAGES_BUCKET,
  FUNCTION_DEFINITIONS,
  LEDGER_DDL,
  normalizeExpr,
  normalizeIndexColumns,
  ROUTINE_GRANTS,
  ROUTINE_NAMES,
  SUPERSEDED_INDEXES,
  TABLE_GRANTS,
} from "./migration-recovery-contracts.mjs";

export const CONFIRMATION_PHRASE = "morsel-issue-76-prod-schema-reconcile-apply";

export class UsageError extends Error {
  exitCode = 2;
}

class SanitizedError extends Error {}

class PlanBlockedError extends Error {}

class StepFailedError extends Error {}

export const PROJECT_REF_RE = /^[a-z0-9]{20}$/;
const TOKEN_RE = /^[^\s\u0000-\u001f\u007f]{20,}$/;

export function validateInputShape(ref, token) {
  if (!PROJECT_REF_RE.test(ref)) {
    throw new UsageError("SUPABASE_PROJECT_REF is malformed (expected 20 lowercase alphanumeric characters).");
  }
  if (!TOKEN_RE.test(token)) {
    throw new UsageError("SUPABASE_ACCESS_TOKEN is malformed (expected a non-empty token with no whitespace).");
  }
}

export function validateRawEnvValue(name, value) {
  if (/^[\s\u0000-\u001f\u007f]|[\s\u0000-\u001f\u007f]$/.test(value)) {
    throw new UsageError(`${name} must not have leading or trailing whitespace or control characters.`);
  }
}

// ---- fixed read-only inventory queries ------------------------------------
// Every query returns exactly one row/column (`result`) holding a JSON
// document: an array of plain objects. These exact strings are the only
// statements ever admitted in ANY mode.

const TABLE_LIST = `array[${CANONICAL_TABLES.map((t) => `'${t}'`).join(", ")}]`;
const PUBLIC_TABLES_FILTER = `table_schema = 'public' and table_name = any(${TABLE_LIST})`;

export const RECOVERY_QUERIES = Object.freeze({
  ledgerExists:
    "select coalesce(json_agg(json_build_object('name', to_regclass('public.migration_ledger')::text)), '[]'::json) as result",
  ledgerNames:
    "select coalesce(json_agg(json_build_object('name', name) order by name), '[]'::json) as result from public.migration_ledger",
  tables:
    "select coalesce(json_agg(json_build_object('table_name', table_name) order by table_name), '[]'::json) as result from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE'",
  columns:
    `select coalesce(json_agg(json_build_object('table_name', table_name, 'column_name', column_name, 'data_type', data_type, 'udt_name', udt_name, 'is_nullable', is_nullable, 'column_default', column_default, 'numeric_precision', numeric_precision, 'numeric_scale', numeric_scale) order by table_name, column_name), '[]'::json) as result from information_schema.columns where ${PUBLIC_TABLES_FILTER}`,
  constraints:
    `select coalesce(json_agg(json_build_object('table_name', t.relname, 'conname', c.conname, 'contype', c.contype, 'definition', pg_get_constraintdef(c.oid), 'columns', (select coalesce(json_agg(a.attname order by u.ordinality), '[]'::json) from unnest(c.conkey) with ordinality as u(attnum, ordinality) join pg_attribute a on a.attrelid = c.conrelid and a.attnum = u.attnum), 'ref_table', (select r.relname from pg_class r where r.oid = c.confrelid), 'confdeltype', c.confdeltype) order by t.relname, c.conname), '[]'::json) as result from pg_constraint c join pg_class t on t.oid = c.conrelid join pg_namespace n on n.oid = t.relnamespace where n.nspname = 'public' and t.relname = any(${TABLE_LIST}) and c.contype in ('p','u','c','f')`,
  indexes:
    `select coalesce(json_agg(json_build_object('table_name', tablename, 'index_name', indexname, 'indexdef', indexdef) order by tablename, indexname), '[]'::json) as result from pg_indexes where schemaname = 'public' and tablename = any(${TABLE_LIST})`,
  routines:
    `select coalesce(json_agg(json_build_object('routine_name', p.proname, 'identity_arguments', pg_get_function_identity_arguments(p.oid), 'language', l.lanname, 'security_definer', p.prosecdef, 'config', p.proconfig, 'body', p.prosrc) order by p.proname), '[]'::json) as result from pg_proc p join pg_namespace n on n.oid = p.pronamespace join pg_language l on l.oid = p.prolang where n.nspname = 'public' and p.proname = any(array['compute_targets', 'log_meal_with_items', 'claim_oauth_authorization_grant', 'upsert_food_catalog'])`,
  policies:
    "select coalesce(json_agg(json_build_object('schema', schemaname, 'table_name', tablename, 'policy_name', policyname, 'command', cmd::text, 'roles', roles, 'qual', qual, 'with_check', with_check) order by schemaname, tablename, policyname), '[]'::json) as result from pg_policies where schemaname in ('public', 'storage')",
  rls:
    `select coalesce(json_agg(json_build_object('table_name', c.relname, 'rls_enabled', c.relrowsecurity, 'rls_forced', c.relforcerowsecurity) order by c.relname), '[]'::json) as result from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname = any(${TABLE_LIST}) and c.relkind = 'r'`,
  tableGrants:
    `select coalesce(json_agg(json_build_object('table_name', table_name, 'grantee', grantee, 'privilege_type', privilege_type) order by table_name, grantee, privilege_type), '[]'::json) as result from information_schema.role_table_grants where table_schema = 'public' and table_name in ('oauth_authorization_grants', 'food_catalog') and grantee in ('anon', 'authenticated', 'service_role')`,
  routinePrivileges:
    `select coalesce(json_agg(json_build_object('routine_name', routine_name, 'grantee', grantee, 'privilege_type', privilege_type) order by routine_name, grantee, privilege_type), '[]'::json) as result from information_schema.routine_privileges where routine_schema = 'public' and routine_name in ('compute_targets', 'log_meal_with_items', 'claim_oauth_authorization_grant', 'upsert_food_catalog') and grantee in ('anon', 'authenticated', 'service_role', 'PUBLIC')`,
  storageBucketsExists:
    "select coalesce(json_agg(json_build_object('name', to_regclass('storage.buckets')::text)), '[]'::json) as result",
  bucketRow:
    "select coalesce(json_agg(json_build_object('id', id, 'name', name, 'public', public, 'file_size_limit', file_size_limit, 'allowed_mime_types', allowed_mime_types)), '[]'::json) as result from storage.buckets where id = 'food-images'",
  rowCount: (table) =>
    `select coalesce(json_agg(json_build_object('n', n)), '[]'::json) as result from (select count(*) as n from public.${table}) s`,
  duplicateRows: (table, column) =>
    `select coalesce(json_agg(json_build_object('dup', dup)), '[]'::json) as result from (select 1 as dup from public.${table} group by user_id, ${column} having count(*) > 1 limit 1) s`,
  nonPositiveKg:
    "select coalesce(json_agg(json_build_object('found', found)), '[]'::json) as result from (select 1 as found from public.weight_logs where kg <= 0 limit 1) s",
});

export const ALLOWED_READ_QUERIES = Object.freeze([
  RECOVERY_QUERIES.ledgerExists,
  RECOVERY_QUERIES.ledgerNames,
  RECOVERY_QUERIES.tables,
  RECOVERY_QUERIES.columns,
  RECOVERY_QUERIES.constraints,
  RECOVERY_QUERIES.indexes,
  RECOVERY_QUERIES.routines,
  RECOVERY_QUERIES.policies,
  RECOVERY_QUERIES.rls,
  RECOVERY_QUERIES.tableGrants,
  RECOVERY_QUERIES.routinePrivileges,
  RECOVERY_QUERIES.storageBucketsExists,
  RECOVERY_QUERIES.bucketRow,
  RECOVERY_QUERIES.rowCount("weight_logs"),
  RECOVERY_QUERIES.rowCount("energy_burned_logs"),
  RECOVERY_QUERIES.duplicateRows("weight_logs", "measured_at"),
  RECOVERY_QUERIES.duplicateRows("weight_logs", "logged_at"),
  RECOVERY_QUERIES.duplicateRows("energy_burned_logs", "burned_at"),
  RECOVERY_QUERIES.nonPositiveKg,
]);

const readQuerySet = new Set(ALLOWED_READ_QUERIES);

export function assertKnownRead(sql) {
  if (!readQuerySet.has(sql)) {
    throw new Error("recovery mode refuses non-allowlisted SQL");
  }
}

// ---- per-step transaction assembly (static pieces only) --------------------

const GUARD_SQL = Object.freeze({
  "0001_init.sql": `do $recovery$
begin
  if (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname in ('users','goals','meal_logs','meal_items','water_logs','weight_logs','food_catalog') and c.relkind = 'r') < 7 then
    raise exception 'recovery postcondition failed';
  end if;
end
$recovery$`,
  "0002_targets.sql": `do $recovery$
begin
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname = 'profiles' and c.relkind = 'r')
     or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'goals' and column_name = 'source') then
    raise exception 'recovery postcondition failed';
  end if;
end
$recovery$`,
  "0003_atomic_meals_and_users_rls.sql": `do $recovery$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'users' and policyname = 'users_select_own')
     or not exists (select 1 from pg_proc where oid = to_regprocedure('public.log_meal_with_items(uuid, timestamptz, text, text, text, text, jsonb)')) then
    raise exception 'recovery postcondition failed';
  end if;
end
$recovery$`,
  "0004_store_assets.sql": `do $recovery$
begin
  if not exists (select 1 from storage.buckets where id = 'food-images' and public = false)
     or not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname in ('food_images_insert_own','food_images_select_own','food_images_update_own','food_images_delete_own'))
     or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'food_catalog' and policyname = 'food_catalog_select_authenticated') then
    raise exception 'recovery postcondition failed';
  end if;
end
$recovery$`,
  "0005_oauth_authorization_grants.sql": `do $recovery$
begin
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname = 'oauth_authorization_grants' and c.relkind = 'r')
     or not exists (select 1 from pg_proc where oid = to_regprocedure('public.claim_oauth_authorization_grant(text, text)'))
     or not exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'oauth_authorization_grants' and indexname = 'oauth_authorization_grants_expires_at_idx') then
    raise exception 'recovery postcondition failed';
  end if;
end
$recovery$`,
  "0006_food_catalog_provider_cache.sql": `do $recovery$
begin
  if not exists (select 1 from pg_proc where oid = to_regprocedure('public.upsert_food_catalog(jsonb)')) then
    raise exception 'recovery postcondition failed';
  end if;
end
$recovery$`,
  "0007_weight_logs.sql": `do $recovery$
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'weight_logs' and column_name = 'logged_at')
     or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'weight_logs' and column_name = 'measured_at')
     or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'weight_logs' and column_name = 'source')
     or not exists (select 1 from pg_constraint where conrelid = 'public.weight_logs'::regclass and conname = 'weight_logs_source_check' and contype = 'c')
     or not exists (select 1 from pg_constraint where conrelid = 'public.weight_logs'::regclass and conname = 'weight_logs_kg_positive' and contype = 'c')
     or not exists (select 1 from pg_constraint where conrelid = 'public.weight_logs'::regclass and conname = 'weight_logs_user_measured_unique' and contype = 'u')
     or not exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'weight_logs' and indexname = 'weight_logs_user_measured_idx')
     or exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'weight_logs' and indexname = 'weight_logs_user_idx') then
    raise exception 'recovery postcondition failed';
  end if;
end
$recovery$`,
  "0008_energy_burned_logs.sql": `do $recovery$
begin
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname = 'energy_burned_logs' and c.relkind = 'r')
     or not exists (select 1 from pg_constraint where conrelid = 'public.energy_burned_logs'::regclass and conname = 'energy_burned_logs_kcal_positive' and contype = 'c')
     or not exists (select 1 from pg_constraint where conrelid = 'public.energy_burned_logs'::regclass and conname = 'energy_burned_logs_source_check' and contype = 'c')
     or not exists (select 1 from pg_constraint where conrelid = 'public.energy_burned_logs'::regclass and conname = 'energy_burned_logs_user_burned_unique' and contype = 'u')
     or not exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'energy_burned_logs' and indexname = 'energy_burned_logs_user_burned_idx')
     or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'energy_burned_logs' and policyname = 'energy_burned_logs_all_own') then
    raise exception 'recovery postcondition failed';
  end if;
end
$recovery$`,
  "0009_goals_fractional_calories.sql": `do $recovery$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'goals' and column_name = 'calorie_target_kcal' and data_type = 'numeric' and numeric_scale = 1) then
    raise exception 'recovery postcondition failed';
  end if;
end
$recovery$`,
});

const ledgerBootstrapTx = `begin;
${LEDGER_DDL};
commit;`;
const ledgerRecordTx = (name) => `begin;
insert into public.migration_ledger (name) values ('${name}') on conflict (name) do nothing;
commit;`;
const convergeTx = (file, name) => `begin;
${CONVERGE_STATEMENTS[file].join(";\n")};
${GUARD_SQL[file]};
insert into public.migration_ledger (name) values ('${name}') on conflict (name) do nothing;
commit;`;

const writeTxSet = new Set([
  ledgerBootstrapTx,
  ...CANONICAL_NAMES.map((name) => ledgerRecordTx(name)),
  ...CANONICAL_FILES.map((file, index) => convergeTx(file, CANONICAL_NAMES[index])),
]);

export function assertKnownWrite(sql) {
  if (!writeTxSet.has(sql)) {
    throw new Error("recovery mode refuses non-allowlisted write transaction");
  }
}

// ---- helpers ---------------------------------------------------------------

function bodyOf(functionText) {
  const match = /as \$[a-z_]*\$([\s\S]*?)\$[a-z_]*\$;?\s*$/.exec(functionText);
  return match ? match[1] : null;
}

function sortedRoles(roles) {
  if (roles === null || roles === undefined) return "public";
  const list = Array.isArray(roles) ? roles : [];
  return [...list].sort().join(",");
}

function canonicalPolicyFor(policy) {
  const byTable = new Map();
  for (const file of CANONICAL_FILES) {
    for (const p of CANONICAL_POLICIES[file] ?? []) {
      const key = `${p.schema}.${p.table}`;
      if (!byTable.has(key)) byTable.set(key, []);
      byTable.get(key).push(p);
    }
  }
  return byTable.get(`${policy.schema}.${policy.table}`) ?? [];
}

function canonicalConstraintFor(table) {
  const out = [];
  for (const file of CANONICAL_FILES) {
    for (const [t, constraints] of Object.entries(CANONICAL_CONSTRAINTS[file] ?? {})) {
      if (t === table) out.push(...constraints);
    }
  }
  return out;
}

function canonicalRoutineFor(name) {
  for (const file of CANONICAL_FILES) {
    for (const routine of CANONICAL_ROUTINES[file] ?? []) {
      if (routine.name === name) return routine;
    }
  }
  return null;
}

function columnMatches(expected, observed) {
  if (observed === null || observed === undefined) return false;
  if (expected.laterOwned) {
    // Type owned by a later migration (0009 retype): existence + nullability
    // only.
    return (observed.is_nullable === "YES") === expected.nullable;
  }
  if (observed.data_type !== expected.dataType) return false;
  if (expected.udt && observed.udt_name !== expected.udt) return false;
  if (expected.precision !== undefined && Number(observed.numeric_precision) !== expected.precision) return false;
  if (expected.scale !== undefined && Number(observed.numeric_scale) !== expected.scale) return false;
  if ((observed.is_nullable === "YES") !== expected.nullable) return false;
  const rawDefault = observed.column_default === null || observed.column_default === undefined ? "" : String(observed.column_default);
  if (expected.default.length === 0) return rawDefault === "";
  return expected.default.includes(rawDefault);
}

const TABLE_OWNER = {
  users: "0001_init.sql",
  goals: "0001_init.sql",
  meal_logs: "0001_init.sql",
  meal_items: "0001_init.sql",
  water_logs: "0001_init.sql",
  weight_logs: "0001_init.sql",
  food_catalog: "0001_init.sql",
  profiles: "0002_targets.sql",
  oauth_authorization_grants: "0005_oauth_authorization_grants.sql",
  energy_burned_logs: "0008_energy_burned_logs.sql",
};

const ROUTINE_OWNER = {
  compute_targets: "0002_targets.sql",
  log_meal_with_items: "0003_atomic_meals_and_users_rls.sql",
  claim_oauth_authorization_grant: "0005_oauth_authorization_grants.sql",
  upsert_food_catalog: "0006_food_catalog_provider_cache.sql",
};

// ---- verification ----------------------------------------------------------

// Verify one migration against the observed snapshot. Returns
// { state, entries, reasons } where entries carry per-object findings.
export function verifyMigration(file, snapshots) {
  const entries = [];
  const findings = [];
  const bad = (kind, label, reason) => {
    entries.push({ kind, label, ok: false, reason });
    findings.push(reason);
  };

  // Columns owned by this migration (canonical end state).
  for (const [table, expectedColumns] of Object.entries(CANONICAL_COLUMNS[file] ?? {})) {
    const observedColumns = snapshots.columnsByTable.get(table);
    for (const expected of expectedColumns) {
      const label = `${table}.${expected.name}`;
      const observed = observedColumns?.get(expected.name);
      if (!observed) {
        bad("column", label, "missing");
        continue;
      }
      if (!columnMatches(expected, observed)) {
        const mismatch = [];
        if (observed.data_type !== expected.dataType) mismatch.push(`data_type ${observed.data_type}`);
        if (expected.udt && observed.udt_name !== expected.udt) mismatch.push(`udt ${observed.udt_name}`);
        if (expected.precision !== undefined && Number(observed.numeric_precision) !== expected.precision) mismatch.push(`precision ${observed.numeric_precision}`);
        if (expected.scale !== undefined && Number(observed.numeric_scale) !== expected.scale) mismatch.push(`scale ${observed.numeric_scale}`);
        if ((observed.is_nullable === "YES") !== expected.nullable) mismatch.push(expected.nullable ? "expected nullable" : "expected not null");
        if (mismatch.length === 0) mismatch.push("default/definition mismatch");
        bad("column", label, `mismatch: ${mismatch.join(", ")}`);
      }
    }
    for (const absent of ABSENT_COLUMNS[file] ?? []) {
      const [absentTable, absentColumn] = absent.split(".");
      if (absentTable !== table) continue;
      // The absent requirement belongs to the POST-rename end state: an
      // old-only state (rename target missing) is a modeled repair, not an
      // ambiguity.
      if (file === "0007_weight_logs.sql" && !observedColumns?.has("measured_at")) continue;
      if (observedColumns?.has(absentColumn)) {
        bad("column", absent, "present, but the canonical end state requires this column to be absent (renamed away by this migration)");
      }
    }
  }

  // Tables owned by this migration must exist.
  for (const table of CANONICAL_TABLES) {
    if (TABLE_OWNER[table] !== file) continue;
    if (!snapshots.tables.has(table)) {
      bad("table", `public.${table}`, "missing");
    }
  }

  // Constraints owned by this migration.
  for (const [table, expectedConstraints] of Object.entries(CANONICAL_CONSTRAINTS[file] ?? {})) {
    const observedList = snapshots.constraintsByTable.get(table) ?? [];
    for (const expected of expectedConstraints) {
      const label = `${table}.${expected.name}`;
      const observed = observedList.find((c) => c.conname === expected.name);
      if (!observed) {
        bad("constraint", label, "missing");
        continue;
      }
      let ok = observed.contype === expected.kind;
      if (ok && expected.kind === "c") {
        ok = normalizeExpr(observed.definition) === normalizeExpr(expected.def ?? "");
      }
      if (ok && (expected.kind === "p" || expected.kind === "u" || expected.kind === "f")) {
        const columns = Array.isArray(observed.columns) ? observed.columns : [];
        ok = JSON.stringify(columns) === JSON.stringify(expected.columns);
      }
      if (ok && expected.kind === "f") {
        ok = observed.ref_table === expected.refTable && observed.confdeltype === expected.onDelete;
      }
      if (!ok) {
        bad("constraint", label, "exists but does not match the canonical contract");
      }
    }
  }

  // RLS owned by this migration.
  for (const table of CANONICAL_RLS[file] ?? []) {
    const rls = snapshots.rls.get(table);
    if (!rls) {
      bad("rls", `rls ${table}`, "table missing from RLS inventory");
    } else if (!rls.rls_enabled) {
      bad("rls", `rls ${table}`, "row level security not enabled");
    }
  }

  // Policies owned by this migration.
  for (const expected of CANONICAL_POLICIES[file] ?? []) {
    const label = `${expected.schema}.${expected.table}:${expected.name}`;
    const observed = snapshots.policies.find(
      (p) => p.schema === expected.schema && p.table_name === expected.table && p.policy_name === expected.name,
    );
    if (!observed) {
      bad("policy", label, "missing");
      continue;
    }
    let ok = observed.command === expected.cmd && sortedRoles(observed.roles) === sortedRoles(expected.roles ?? null);
    if (ok && expected.qual !== undefined) ok = normalizeExpr(observed.qual) === normalizeExpr(expected.qual);
    if (ok && expected.withCheck !== undefined) ok = normalizeExpr(observed.with_check) === normalizeExpr(expected.withCheck);
    if (!ok) {
      bad("policy", label, "exists but does not match the canonical contract");
    }
  }

  // Extra policies on canonical public tables owned by this migration.
  for (const table of EXACT_POLICY_TABLES) {
    const ownerFile = Object.keys(CANONICAL_POLICIES).find((f) => (CANONICAL_POLICIES[f] ?? []).some((p) => p.table === table && p.schema === "public"));
    if (ownerFile !== file) continue;
    const canonicalNames = canonicalPolicyFor({ schema: "public", table }).map((p) => p.name);
    for (const observed of snapshots.policies.filter((p) => p.schema === "public" && p.table_name === table)) {
      if (!canonicalNames.includes(observed.policy_name)) {
        bad("policy", `public.${table}:${observed.policy_name}`, "non-canonical policy present");
      }
    }
  }

  // Indexes owned by this migration + superseded absence + unique extras.
  for (const indexName of CANONICAL_INDEXES[file] ?? []) {
    const observed = snapshots.indexes.find((i) => i.index_name === indexName);
    if (!observed) {
      bad("index", indexName, "missing");
      continue;
    }
    if (normalizeIndexColumns(observed.indexdef) !== CANONICAL_INDEX_COLUMNS[indexName]) {
      bad("index", indexName, "exists but its definition does not match the canonical contract");
    }
  }
  if (file === "0007_weight_logs.sql") {
    for (const indexName of SUPERSEDED_INDEXES) {
      if (snapshots.indexes.some((i) => i.index_name === indexName)) {
        bad("index", indexName, "superseded index still present (the canonical end state drops it)");
      }
    }
  }
  for (const table of EXACT_UNIQUE_TABLES) {
    if (!((table === "weight_logs" && file === "0007_weight_logs.sql") || (table === "energy_burned_logs" && file === "0008_energy_burned_logs.sql"))) continue;
    const constraintNames = new Set(canonicalConstraintFor(table).map((c) => c.name));
    for (const index of snapshots.indexes.filter((i) => i.table_name === table)) {
      if (constraintNames.has(index.index_name)) continue; // constraint-backed
      if (/^create unique index/i.test(index.indexdef ?? "")) {
        bad("index", `${table}.${index.index_name}`, "non-canonical unique index present");
      }
    }
  }

  // Routines owned by this migration.
  for (const expected of CANONICAL_ROUTINES[file] ?? []) {
    const label = `${expected.name}(${expected.identityArguments})`;
    const observed = snapshots.routines.find(
      (r) => r.routine_name === expected.name && r.identity_arguments === expected.identityArguments,
    );
    if (!observed) {
      bad("routine", label, "missing");
      continue;
    }
    const config = Array.isArray(observed.config) ? observed.config : [];
    const canonicalBody = bodyOf(FUNCTION_DEFINITIONS[expected.name]);
    const ok =
      observed.language === expected.language &&
      Boolean(observed.security_definer) === expected.securityDefiner &&
      JSON.stringify(config) === JSON.stringify(expected.config) &&
      canonicalBody !== null &&
      observed.body === canonicalBody;
    if (!ok) {
      bad("routine", label, "exists but does not match the canonical definition");
    }
  }
  for (const routine of snapshots.routines) {
    if (!ROUTINE_NAMES.has(routine.routine_name)) continue;
    if (ROUTINE_OWNER[routine.routine_name] !== file) continue;
    const canonical = canonicalRoutineFor(routine.routine_name);
    if (!canonical || canonical.identityArguments !== routine.identity_arguments) {
      bad("routine", `${routine.routine_name}(${routine.identity_arguments})`, "non-canonical signature present");
    }
  }

  // Table grant boundaries owned by this migration.
  const tableGrantOwners = {
    oauth_authorization_grants: "0005_oauth_authorization_grants.sql",
    food_catalog: "0006_food_catalog_provider_cache.sql",
  };
  for (const [tableName, expectations] of Object.entries(TABLE_GRANTS)) {
    if (tableGrantOwners[tableName] !== file) continue;
    for (const [grantee, spec] of Object.entries(expectations)) {
      const granted = new Set(
        snapshots.tableGrants.filter((g) => g.table_name === tableName && g.grantee === grantee).map((g) => g.privilege_type),
      );
      const label = `table grant ${tableName}.${grantee}`;
      if (spec.exact) {
        const want = new Set(spec.privilegeTypes);
        const same = granted.size === want.size && [...want].every((p) => granted.has(p));
        if (!same) {
          bad("grant", label, granted.size === 0 ? "missing (no privileges granted)" : `exists but grants ${[...granted].sort().join(",")}`);
        }
      } else {
        for (const privilege of spec.privilegeTypes) {
          if (!granted.has(privilege)) bad("grant", `${label}.${privilege}`, "missing");
        }
      }
    }
  }
  for (const [routineName, expectations] of Object.entries(ROUTINE_GRANTS)) {
    if (ROUTINE_OWNER[routineName] !== file) continue;
    for (const [grantee, spec] of Object.entries(expectations)) {
      const granted = snapshots.routinePrivileges.some(
        (g) => g.routine_name === routineName && g.grantee.toLowerCase() === grantee.toLowerCase() && g.privilege_type === "EXECUTE",
      );
      const label = `routine grant ${routineName}.${grantee}`;
      if (spec.execute && !granted) bad("grant", label, "missing EXECUTE");
      if (spec.absent && granted) bad("grant", label, "EXECUTE granted, but the canonical boundary revokes it");
    }
  }

  // Storage bucket owned by 0004.
  if (file === "0004_store_assets.sql") {
    const label = "storage bucket food-images";
    const row = snapshots.bucketRow;
    if (row === null) {
      bad("bucket", label, "missing");
    } else if (
      row.name !== FOOD_IMAGES_BUCKET.name ||
      row.public !== FOOD_IMAGES_BUCKET.public ||
      Number(row.file_size_limit) !== FOOD_IMAGES_BUCKET.fileSizeLimit ||
      JSON.stringify(row.allowed_mime_types) !== JSON.stringify(FOOD_IMAGES_BUCKET.allowedMimeTypes)
    ) {
      bad("bucket", label, "exists but its configuration does not match the canonical contract");
    }
  }

  return { entries, findings };
}

// Is every non-ok finding something the idempotent converge SQL covers?
function convergeCovers(file, entries, snapshots) {
  return entries.every((entry) => {
    if (entry.ok) return true;
    if (entry.kind === "table") {
      // Missing base table: converge creates it (IF NOT EXISTS).
      return entry.reason === "missing";
    }
    if (entry.kind === "column") {
      if (entry.reason !== "missing") {
        // 0009 retypes calorie_target_kcal; int-family mismatches converge.
        if (file === "0009_goals_fractional_calories.sql" && entry.label === "goals.calorie_target_kcal") return true;
        return false;
      }
      const [table, column] = entry.label.split(".");
      // Column missing on an ABSENT table is created with the table.
      if (!snapshots.tables.has(table)) return true;
      // Modeled add-if-not-exists columns only:
      if (file === "0002_targets.sql" && table === "goals" && column === "source") return true;
      if (file === "0007_weight_logs.sql" && table === "weight_logs" && (column === "source" || column === "measured_at")) return true;
      return false;
    }
    if (entry.kind === "constraint") return entry.reason === "missing";
    if (entry.kind === "rls") return entry.reason === "row level security not enabled" || entry.reason.startsWith("table missing");
    if (entry.kind === "index") return entry.reason === "missing" || entry.reason.startsWith("superseded index still present");
    if (entry.kind === "policy") return entry.reason !== "non-canonical policy present";
    if (entry.kind === "routine") return entry.reason !== "non-canonical signature present";
    if (entry.kind === "grant") return true; // converge revoke/grant restores the boundary
    if (entry.kind === "bucket") return true; // converge upserts the canonical config
    return false;
  });
}

export function classifyMigration(file, snapshots, recorded, dataDependency) {
  const { entries } = verifyMigration(file, snapshots);
  const name = CANONICAL_NAMES[CANONICAL_FILES.indexOf(file)];
  let state = "VERIFIED_PRESENT";
  if (entries.some((e) => !e.ok)) state = "REPAIR_REQUIRED";
  if (dataDependency) state = "BLOCKED_AMBIGUOUS";
  if (state === "REPAIR_REQUIRED" && !convergeCovers(file, entries, snapshots)) state = "BLOCKED_AMBIGUOUS";
  if (recorded.has(name)) {
    state = state === "VERIFIED_PRESENT" ? "VERIFIED_PRESENT" : "BLOCKED_AMBIGUOUS";
  }
  return { state, entries, name };
}

// Global (plan-level) conflict detection.
export function globalConflicts(snapshots, ledger) {
  const blockers = [];
  const weightColumns = snapshots.columnsByTable.get("weight_logs");
  if (weightColumns) {
    const hasLogged = weightColumns.has("logged_at");
    const hasMeasured = weightColumns.has("measured_at");
    if (hasLogged && hasMeasured) {
      blockers.push({ label: "weight_logs timestamp columns", reason: "both logged_at and measured_at exist; the rename target is ambiguous" });
    } else if (!hasLogged && !hasMeasured) {
      blockers.push({ label: "weight_logs timestamp columns", reason: "neither logged_at nor measured_at exists; the table shape is not modeled" });
    }
  }
  if (ledger.unknownLedgerCount > 0) {
    blockers.push({ label: "migration ledger", reason: `${ledger.unknownLedgerCount} ledger entries do not match the canonical migration manifest (values redacted)` });
  }
  if (ledger.ledgerExists && ledger.recorded.size > 0) {
    // Recorded rows must be an exact prefix of the canonical chain.
    let prefixEnd = 0;
    for (let i = 0; i < CANONICAL_NAMES.length; i += 1) {
      if (ledger.recorded.has(CANONICAL_NAMES[i])) {
        if (i !== prefixEnd) {
          blockers.push({ label: "migration ledger", reason: "recorded migrations contain a gap before the newest entry; the ledger state is not a canonical prefix" });
          break;
        }
        prefixEnd += 1;
      }
    }
  }
  return blockers;
}

// ---- report ----------------------------------------------------------------

export function formatPlan({ statuses, blockers, ledger, counts, apply, recordedAll }) {
  const lines = [];
  lines.push("Morsel schema recovery plan — issue #76");
  lines.push("===========================================");
  lines.push("project ref : [redacted]");
  lines.push(`mode        : ${apply ? "APPLY (human-confirmed)" : "plan (read-only — no writes possible)"}`);
  lines.push("");
  lines.push("ledger public.migration_ledger");
  if (ledger.ledgerExists) {
    lines.push(
      ledger.ledgerNames.length === 0
        ? "  exists : yes — 0 recorded (empty)"
        : `  exists : yes — ${ledger.ledgerNames.length} recorded (${ledger.ledgerNames.join(", ")})`,
    );
  } else {
    lines.push("  exists : no — MISSING (would be created inside the confirmed write transaction)");
  }
  lines.push("");
  lines.push(`row counts: weight_logs ${counts.weightLogs ?? "n/a (table absent)"}; energy_burned_logs ${counts.energyBurned ?? "n/a (table absent)"}`);
  lines.push("");
  lines.push("per-migration classification (0001..0009)");
  for (const file of CANONICAL_FILES) {
    const status = statuses[file];
    lines.push(`${file}  ${status.state}`);
    for (const entry of status.entries) {
      if (!entry.ok) {
        lines.push(`    ${entry.kind.padEnd(10)} ${entry.label}: ${entry.reason}`);
      }
    }
  }
  if (blockers.length > 0) {
    lines.push("");
    lines.push("conflicting drift (plan-level):");
    for (const blocker of blockers) {
      lines.push(`  - ${blocker.label}: ${blocker.reason}`);
    }
  }
  lines.push("");
  const verified = CANONICAL_FILES.filter((f) => statuses[f].state === "VERIFIED_PRESENT").length;
  const repairs = CANONICAL_FILES.filter((f) => statuses[f].state === "REPAIR_REQUIRED").length;
  const blocked = CANONICAL_FILES.filter((f) => statuses[f].state === "BLOCKED_AMBIGUOUS").length;
  lines.push(`summary: ${verified} verified present, ${repairs} repair required, ${blocked} blocked ambiguous`);
  if (blockers.length > 0 || blocked > 0) {
    lines.push("result: BLOCKED — no write statement can run until the ambiguous drift is resolved.");
  } else if (recordedAll) {
    lines.push("result: nothing to do — every migration is verified and recorded.");
  } else if (apply) {
    lines.push(`result: approved apply plan — ${repairs === 0 ? "ledger recording" : "idempotent convergence + ledger recording"} in per-step transactions.`);
  } else {
    lines.push("result: repair required — apply is gated behind --apply --confirm (human only).");
  }
  return lines.join("\n");
}

// ---- sanitized query boundary ----------------------------------------------

function parseResultRows(rows, label) {
  const snapshotValue = (value) => {
    if (value === null || typeof value !== "object") return value;
    if (Array.isArray(value)) return value.map(snapshotValue);
    const snapshot = {};
    for (const key of Object.keys(value)) {
      snapshot[key] = snapshotValue(value[key]);
    }
    return snapshot;
  };
  try {
    if (!Array.isArray(rows) || rows.length === 0) return [];
    const first = rows[0];
    if (first === null || typeof first !== "object") return [];
    const value = first.result;
    if (Array.isArray(value)) return value.map(snapshotValue);
    if (typeof value === "string") {
      const parsed = JSON.parse(value);
      return Array.isArray(parsed) ? parsed.map(snapshotValue) : [];
    }
    return [];
  } catch {
    throw new SanitizedError(`${label} failed: invalid response rows`);
  }
}

function safeHttpStatus(status) {
  if (typeof status === "number" && Number.isInteger(status) && status >= 100 && status <= 599) return status;
  return null;
}

async function managementQuery(sql, label, ref, token) {
  let response;
  try {
    response = await fetch(`https://api.supabase.com/v1/projects/${ref}/database/query`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ query: sql }),
    });
  } catch {
    throw new SanitizedError(`${label} failed: transport error`);
  }
  if (!response.ok) {
    const status = safeHttpStatus(response.status);
    throw new SanitizedError(status === null ? `${label} failed: HTTP error` : `${label} failed: HTTP ${status}`);
  }
  try {
    return await response.json();
  } catch {
    throw new SanitizedError(`${label} failed: invalid response body`);
  }
}

// ---- orchestration ---------------------------------------------------------

export async function inspect({ root, query }) {
  const localFiles = readdirSync(join(root, "db", "migrations")).filter((f) => f.endsWith(".sql"));
  parseMigrationNames(localFiles);
  const localSet = new Set(localFiles);
  if (localSet.size !== CANONICAL_FILES.length || !CANONICAL_FILES.every((f) => localSet.has(f))) {
    throw new SanitizedError("manifest mismatch: this checkout does not contain exactly db/migrations/0001..0009");
  }

  const ledgerRow = (await query(RECOVERY_QUERIES.ledgerExists, "ledger existence"))[0] ?? {};
  const ledgerExists = Boolean(ledgerRow.name);
  const rawLedgerNames = ledgerExists ? (await query(RECOVERY_QUERIES.ledgerNames, "ledger names")).map((r) => r.name) : [];
  const ledgerNames = rawLedgerNames.filter((name) => CANONICAL_NAMES.includes(name));
  const unknownLedgerCount = rawLedgerNames.length - ledgerNames.length;
  const recorded = new Set(ledgerNames);

  const [tables, columns, constraints, indexes, routines, policies, rls, tableGrants, routinePrivileges, storageBuckets] = await Promise.all([
    query(RECOVERY_QUERIES.tables, "table inventory"),
    query(RECOVERY_QUERIES.columns, "column inventory"),
    query(RECOVERY_QUERIES.constraints, "constraint inventory"),
    query(RECOVERY_QUERIES.indexes, "index inventory"),
    query(RECOVERY_QUERIES.routines, "routine inventory"),
    query(RECOVERY_QUERIES.policies, "policy inventory"),
    query(RECOVERY_QUERIES.rls, "rls inventory"),
    query(RECOVERY_QUERIES.tableGrants, "table grant inventory"),
    query(RECOVERY_QUERIES.routinePrivileges, "routine privilege inventory"),
    query(RECOVERY_QUERIES.storageBucketsExists, "storage bucket schema existence"),
  ]);

  const bucketRow = storageBuckets[0]?.name ? (await query(RECOVERY_QUERIES.bucketRow, "bucket inventory"))[0] ?? null : null;

  const snapshots = {
    tables: new Set(tables.map((r) => r.table_name)),
    columnsByTable: new Map(),
    constraintsByTable: new Map(),
    indexes: indexes.map((r) => ({ table_name: r.table_name, index_name: r.index_name, indexdef: String(r.indexdef ?? "") })),
    routines: routines.map((r) => ({
      routine_name: r.routine_name,
      identity_arguments: r.identity_arguments,
      language: r.language,
      security_definer: r.security_definer,
      config: r.config,
      body: r.body,
    })),
    policies: policies.map((r) => ({
      schema: r.schema,
      table_name: r.table_name,
      policy_name: r.policy_name,
      command: r.command,
      roles: r.roles,
      qual: r.qual,
      with_check: r.with_check,
    })),
    rls: new Map(rls.map((r) => [r.table_name, { rls_enabled: Boolean(r.rls_enabled), rls_forced: Boolean(r.rls_forced) }])),
    tableGrants: tableGrants.map((r) => ({ table_name: r.table_name, grantee: r.grantee, privilege_type: r.privilege_type })),
    routinePrivileges: routinePrivileges.map((r) => ({ routine_name: r.routine_name, grantee: r.grantee, privilege_type: r.privilege_type })),
    bucketRow,
  };
  for (const row of columns) {
    if (!snapshots.columnsByTable.has(row.table_name)) snapshots.columnsByTable.set(row.table_name, new Map());
    snapshots.columnsByTable.get(row.table_name).set(row.column_name, row);
  }
  for (const row of constraints) {
    if (!snapshots.constraintsByTable.has(row.table_name)) snapshots.constraintsByTable.set(row.table_name, []);
    snapshots.constraintsByTable.get(row.table_name).push(row);
  }

  const counts = {};
  if (snapshots.tables.has("weight_logs")) {
    const row = (await query(RECOVERY_QUERIES.rowCount("weight_logs"), "weight_logs count"))[0];
    counts.weightLogs = row ? Number(row.n) : 0;
  }
  if (snapshots.tables.has("energy_burned_logs")) {
    const row = (await query(RECOVERY_QUERIES.rowCount("energy_burned_logs"), "energy_burned_logs count"))[0];
    counts.energyBurned = row ? Number(row.n) : 0;
  }

  return { snapshots, counts, ledger: { ledgerExists, ledgerNames, unknownLedgerCount, recorded } };
}

// Data-dependency preflight: only runs when the table exists and the
// canonical constraint that would be added is absent.
export async function dataDependencies({ snapshots, counts, query }) {
  const deps = [];
  const constraintMissing = (table, name) => !(snapshots.constraintsByTable.get(table) ?? []).some((c) => c.conname === name);
  if (snapshots.tables.has("weight_logs") && counts.weightLogs > 0 && constraintMissing("weight_logs", "weight_logs_user_measured_unique")) {
    const weightColumns = snapshots.columnsByTable.get("weight_logs");
    const column = weightColumns?.has("measured_at") ? "measured_at" : weightColumns?.has("logged_at") ? "logged_at" : null;
    if (column) {
      const dup = (await query(RECOVERY_QUERIES.duplicateRows("weight_logs", column), "weight_logs duplicate check"))[0];
      if (dup && Number(dup.dup) === 1) {
        deps.push({ label: "weight_logs data", reason: "duplicate (user_id, timestamp) rows exist; the canonical unique constraint cannot be added without deleting data", migration: "0007_weight_logs.sql" });
      }
    }
  }
  if (snapshots.tables.has("weight_logs") && counts.weightLogs > 0 && constraintMissing("weight_logs", "weight_logs_kg_positive")) {
    const bad = (await query(RECOVERY_QUERIES.nonPositiveKg, "weight_logs kg preflight"))[0];
    if (bad && Number(bad.found) === 1) {
      deps.push({ label: "weight_logs data", reason: "rows with kg <= 0 exist; the canonical kg > 0 check cannot be added without changing data", migration: "0007_weight_logs.sql" });
    }
  }
  if (snapshots.tables.has("energy_burned_logs") && counts.energyBurned > 0 && constraintMissing("energy_burned_logs", "energy_burned_logs_user_burned_unique")) {
    const dup = (await query(RECOVERY_QUERIES.duplicateRows("energy_burned_logs", "burned_at"), "energy duplicate preflight"))[0];
    if (dup && Number(dup.dup) === 1) {
      deps.push({ label: "energy_burned_logs data", reason: "duplicate (user_id, burned_at) rows exist; the canonical unique constraint cannot be added without deleting data", migration: "0008_energy_burned_logs.sql" });
    }
  }
  return deps;
}

export function planStatuses(snapshots, ledger, dataDeps) {
  const statuses = {};
  for (const file of CANONICAL_FILES) {
    const dataDependency = dataDeps.find((dep) => dep.migration === file);
    statuses[file] = classifyMigration(file, snapshots, ledger.recorded, Boolean(dataDependency));
  }
  const blockers = globalConflicts(snapshots, ledger);
  for (const dep of dataDeps) blockers.push(dep);
  return { statuses, blockers };
}

export async function run({ ref, token, root, apply = false, confirm = null, queryImpl = null, log = console }) {
  if (!ref) throw new UsageError("SUPABASE_PROJECT_REF is required.");
  if (!token) throw new UsageError("No Management API token found. Set SUPABASE_ACCESS_TOKEN.");
  validateInputShape(ref, token);
  if (apply) {
    if (confirm === null) {
      throw new UsageError("--apply requires --confirm with the exact issue #76 confirmation phrase.");
    }
    if (typeof confirm !== "string" || confirm !== CONFIRMATION_PHRASE) {
      throw new UsageError("confirmation phrase does not match the issue #76 production apply token.");
    }
  }

  const query = async (sql, label) => {
    assertKnownRead(sql);
    let rows;
    try {
      if (queryImpl) rows = await queryImpl(sql, label);
      else rows = await managementQuery(sql, label, ref, token);
    } catch (error) {
      if (error instanceof SanitizedError) throw error;
      throw new SanitizedError(`${label} failed: query error`);
    }
    return parseResultRows(rows, label);
  };
  const write = async (sql, label) => {
    assertKnownWrite(sql);
    try {
      if (queryImpl) return await queryImpl(sql, label);
      return await managementQuery(sql, label, ref, token);
    } catch (error) {
      if (error instanceof SanitizedError) throw error;
      throw new SanitizedError(`${label} failed: query error`);
    }
  };

  const inventory = await inspect({ root, query });
  const { snapshots, counts, ledger } = inventory;
  const deps = await dataDependencies({ snapshots, counts, query });
  const { statuses, blockers } = planStatuses(snapshots, ledger, deps);
  const planBlocked = blockers.length > 0 || CANONICAL_FILES.some((f) => statuses[f].state === "BLOCKED_AMBIGUOUS");
  const recordedAll = ledger.ledgerExists && ledger.ledgerNames.length === CANONICAL_NAMES.length;

  const report = formatPlan({ statuses, blockers, ledger, counts, apply, recordedAll });
  log.log(report);

  if (!apply) {
    return { mode: "plan", planBlocked, statuses, blockers, counts, report };
  }
  if (planBlocked) {
    throw new PlanBlockedError("plan is blocked (ambiguous or conflicting drift); no write statement was executed.");
  }

  // Execute: ledger bootstrap then one atomic transaction per migration step.
  if (!ledger.ledgerExists) {
    await write(ledgerBootstrapTx, "ledger bootstrap");
    log.log("✓ ledger public.migration_ledger created");
  }
  const applied = [];
  for (let i = 0; i < CANONICAL_FILES.length; i += 1) {
    const file = CANONICAL_FILES[i];
    const name = CANONICAL_NAMES[i];
    if (ledger.recorded.has(name)) continue;
    const status = statuses[file];
    if (status.state === "REPAIR_REQUIRED") {
      const tx = convergeTx(file, name);
      await write(tx, `converge ${file}`);
      applied.push(file);
      log.log(`✓ converged + recorded ${file}`);
    } else if (status.state === "VERIFIED_PRESENT") {
      await write(ledgerRecordTx(name), `ledger record ${file}`);
      log.log(`✓ recorded ${file} (verified present, no converge needed)`);
    }
  }

  // Post-apply re-inventory: every contract must verify and counts must hold.
  const after = await inspect({ root, query });
  const afterDeps = await dataDependencies({ snapshots: after.snapshots, counts: after.counts, query });
  const afterStatuses = {};
  for (const file of CANONICAL_FILES) {
    afterStatuses[file] = classifyMigration(file, after.snapshots, new Set(after.ledger.ledgerNames), false);
  }
  const afterBlockers = globalConflicts(after.snapshots, after.ledger).concat(afterDeps.map((d) => ({ label: d.label, reason: d.reason })));
  const allVerified = CANONICAL_FILES.every((f) => afterStatuses[f].state === "VERIFIED_PRESENT");
  const countsHeld =
    (counts.weightLogs === undefined || after.counts.weightLogs === counts.weightLogs) &&
    (counts.energyBurned === undefined || after.counts.energyBurned === counts.energyBurned);
  if (!allVerified || afterBlockers.length > 0 || !countsHeld) {
    throw new StepFailedError("post-apply re-verification failed; no success claim. Inspect the schema before retrying.");
  }
  log.log(`✓ post-apply re-verification passed: every 0001..0009 contract verified; weight_logs ${after.counts.weightLogs ?? 0} rows, energy_burned_logs ${after.counts.energyBurned ?? 0} rows (counts preserved)`);
  return {
    mode: "apply",
    applied,
    recordedAll: after.ledger.ledgerNames.length === CANONICAL_NAMES.length,
    statuses: afterStatuses,
    report,
    counts: after.counts,
  };
}

// ---- CLI -------------------------------------------------------------------

function currentBranch(root) {
  const result = spawnSync("git", ["-C", root, "symbolic-ref", "--quiet", "--short", "HEAD"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.status !== 0) return null; // detached (CI checkout)
  return result.stdout.trim();
}

export function parseArgs(argv) {
  const flags = { apply: false, confirm: null };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--apply") {
      flags.apply = true;
    } else if (arg === "--confirm") {
      if (i + 1 >= argv.length) throw new UsageError("--confirm requires the issue #76 confirmation phrase as its value.");
      flags.confirm = argv[i + 1];
      i += 1;
    } else {
      throw new UsageError("recovery accepts only --apply and --confirm.");
    }
  }
  if (flags.confirm !== null && !flags.apply) {
    throw new UsageError("--confirm is only valid together with --apply.");
  }
  return flags;
}

export async function main(argv = process.argv.slice(2)) {
  const rawRef = process.env.SUPABASE_PROJECT_REF;
  const rawToken = process.env.SUPABASE_ACCESS_TOKEN;
  try {
    if (!rawRef) throw new UsageError("SUPABASE_PROJECT_REF is required.");
    if (!rawToken) throw new UsageError("No Management API token found. Set SUPABASE_ACCESS_TOKEN.");
    validateRawEnvValue("SUPABASE_PROJECT_REF", rawRef);
    validateRawEnvValue("SUPABASE_ACCESS_TOKEN", rawToken);
    validateInputShape(rawRef, rawToken);
    const flags = parseArgs(argv);
    const root = dirname(dirname(fileURLToPath(import.meta.url)));
    if (flags.apply) {
      // Usage errors (missing/malformed confirmation) win over operational
      // guards (stale checkout, non-main branch): exit 2 precedes exit 1.
      if (flags.confirm === null) {
        throw new UsageError("--apply requires --confirm with the exact issue #76 confirmation phrase.");
      }
      if (flags.confirm !== CONFIRMATION_PHRASE) {
        throw new UsageError("confirmation phrase does not match the issue #76 production apply token.");
      }
      const freshness = checkoutFreshness(root);
      const exitCode = checkoutGuardExitCode(freshness, "schema recovery apply");
      if (exitCode) return exitCode;
      const branch = currentBranch(root);
      if (branch !== null && branch !== "main") {
        console.error("✗ RECOVERY APPLY requires a main (or CI detached) checkout; refusing to run from a non-main branch.");
        return 1;
      }
    }
    const outcome = await run({ ref: rawRef, token: rawToken, root, apply: flags.apply, confirm: flags.confirm });
    return outcome.mode === "apply" ? 0 : (outcome.planBlocked ? 1 : 0);
  } catch (error) {
    if (error instanceof UsageError) {
      console.error(`✗ ${error.message}`);
      return error.exitCode;
    }
    if (error instanceof PlanBlockedError || error instanceof StepFailedError || error instanceof SanitizedError) {
      console.error(`✗ ${error.message}`);
      return 1;
    }
    console.error("✗ recovery failed (error details suppressed)");
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) process.exit(await main());
