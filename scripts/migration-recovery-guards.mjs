// Morsel issue #76 — complete in-transaction SQL guards.
//
// Each migration (0001..0009) gets one fixed, static SQL guard that re-checks
// EVERY contract dimension the runner's JS classification claims for that
// migration — table/column shape (types, nullability, defaults, udt,
// precision/scale where owned), absent columns, constraint kind/columns/
// FK targets/CHECK bodies, plain and superseded indexes, RLS state, named
// policies (command, roles, qual/with_check bodies), routine identity
// (signature, language, security, search_path config, byte-exact body),
// table/routine grants, and the storage bucket. Guards run INSIDE the same
// transaction that records a ledger row (both the verified-present record
// path and the converge path), so drift between preflight and write aborts
// with NO ledger row.
//
// Expression bodies are compared with recovery_norm(), the SQL mirror of the
// JS normalizeExpr() (see migration-recovery-contracts.mjs): a conservative,
// quote-aware normalizer that preserves semantic grouping and literal
// contents. A pg_temp helper function is created inside the guard transaction
// (temp schema = session-scoped, never persists, never touches public).
//
// The guards are assembled once at module load from the static canonical
// contract data: the resulting FULL_GUARD_SQL strings are fixed members of
// the runner's write-transaction allowlist (never interpolated with runtime
// values), so no response/query/credential value can leak into them.

import {
  ABSENT_COLUMNS,
  CANONICAL_COLUMNS,
  CANONICAL_CONSTRAINTS,
  CANONICAL_FILES,
  CANONICAL_INDEXES,
  CANONICAL_INDEX_COLUMNS,
  CANONICAL_INDEX_TABLE,
  CANONICAL_POLICIES,
  CANONICAL_RLS,
  CANONICAL_ROUTINES,
  CONVERGE_STATEMENTS,
  EXACT_UNIQUE_TABLES,
  FOOD_IMAGES_BUCKET,
  FUNCTION_DEFINITIONS,
  ROUTINE_GRANTS,
  SUPERSEDED_INDEXES,
  TABLE_GRANTS,
} from "./migration-recovery-contracts.mjs";

// Table -> file that owns table creation (mirror of the runner's TABLE_OWNER).
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

const TABLE_GRANT_OWNER = {
  oauth_authorization_grants: "0005_oauth_authorization_grants.sql",
  food_catalog: "0006_food_catalog_provider_cache.sql",
};

const GRANTEE_LOWER = (grantee) => grantee.toLowerCase();

// plpgsql body of pg_temp.recovery_norm — the SQL mirror of normalizeExpr().
// Cross-pinned by the suites against JS normalizeExpr on real PostgreSQL
// renderings (see migration-recovery-integration.test.mjs).
export const RECOVERY_NORM_BODY = `
declare
  s text := coalesce(p, '');
  out text := '';
  c char;
  word text;
  n int;
  i int := 1;
  j int;
  k int;
  changed boolean := true;
  passes int := 0;
  d int;
  qq boolean;
  hasComp boolean;
  hasBool boolean;
  depth int;
  m int;
  pos int;
begin
  s := trim(s);
  -- strip leading constraint-kind marker from pg_get_constraintdef
  if length(s) > 0 then
    n := 1;
    while n <= length(s) and substr(s, n, 1) ~ '[a-zA-Z_]' loop n := n + 1; end loop;
    word := lower(substr(s, 1, n - 1));
    if word in ('check', 'unique') then
      s := trim(substr(s, n));
    elsif word in ('primary', 'foreign') then
      s := trim(substr(s, n));
      n := 1;
      while n <= length(s) and substr(s, n, 1) ~ '[a-zA-Z_]' loop n := n + 1; end loop;
      if lower(substr(s, 1, n - 1)) = 'key' then
        s := trim(substr(s, n));
      end if;
    end if;
  end if;
  -- pass A: strip parens around plain comparisons (deparse grouping noise);
  -- and/or/not grouping parens are preserved. Runs BEFORE whitespace collapse
  -- so boolean keywords keep real word boundaries.
  while changed and passes < 8 loop
    changed := false;
    passes := passes + 1;
    i := 1;
    while i <= length(s) loop
      if substr(s, i, 1) <> '(' then
        i := i + 1;
        continue;
      end if;
      depth := 1;
      qq := false;
      m := i + 1;
      while m <= length(s) and depth > 0 loop
        c := substr(s, m, 1);
        if not qq and c = '''' then
          qq := true;
        elsif qq then
          if c = '''' then
            if m < length(s) and substr(s, m + 1, 1) = '''' then
              m := m + 1;
            else
              qq := false;
            end if;
          end if;
        elsif c = '(' then
          depth := depth + 1;
        elsif c = ')' then
          depth := depth - 1;
        end if;
        m := m + 1;
      end loop;
      if depth <> 0 then
        exit;
      end if;
      j := m - 1;
      hasComp := false;
      hasBool := false;
      depth := 0;
      qq := false;
      pos := i + 1;
      while pos <= j - 1 loop
        c := substr(s, pos, 1);
        if not qq and c = '''' then
          qq := true;
        elsif qq then
          if c = '''' then
            if pos < length(s) and substr(s, pos + 1, 1) = '''' then
              pos := pos + 1;
            else
              qq := false;
            end if;
          end if;
        elsif c = '(' then
          depth := depth + 1;
        elsif c = ')' then
          depth := depth - 1;
        elsif depth = 0 and not hasComp and c in ('=', '>', '<', '~', '!') then
          hasComp := true;
        elsif depth = 0 and not hasBool and c ~ '[a-zA-Z]' then
          n := pos;
          while n <= j - 1 and substr(s, n, 1) ~ '[a-zA-Z0-9_]' loop n := n + 1; end loop;
          word := lower(substr(s, pos, n - pos));
          if word in ('and', 'or', 'not') then
            hasBool := true;
          end if;
          pos := n - 1;
        end if;
        pos := pos + 1;
      end loop;
      if hasComp and not hasBool and j > i + 1 then
        s := substr(s, 1, i - 1) || substr(s, i + 1, j - i - 1) || substr(s, j + 1);
        changed := true;
        exit;
      end if;
      i := i + 1;
    end loop;
  end loop;
  -- pass 1: character scan (quote-aware; literal contents verbatim)
  i := 1;
  while i <= length(s) loop
    c := substr(s, i, 1);
    if c = '''' then
      j := i;
      i := i + 1;
      loop
        if i > length(s) then exit; end if;
        if substr(s, i, 1) = '''' then
          if i < length(s) and substr(s, i + 1, 1) = '''' then
            i := i + 1;
          else
            exit;
          end if;
        end if;
        i := i + 1;
      end loop;
      out := out || substr(s, j, i - j + 1);
      i := i + 1;
      if i <= length(s) - 1 and substr(s, i, 2) = '::' then
        n := i + 2;
        while n <= length(s) and substr(s, n, 1) ~ '[a-zA-Z]' loop n := n + 1; end loop;
        if lower(substr(s, i + 2, n - i - 2)) in ('text','numeric','integer','bigint','smallint','boolean') then
          i := n;
        end if;
      end if;
    elsif c ~ '\\s' then
      i := i + 1;
    elsif lower(c) = 'a' and (i = 1 or substr(s, i - 1, 1) ~ '[^a-zA-Z0-9_]') then
      n := i;
      while n <= length(s) and substr(s, n, 1) ~ '[a-zA-Z0-9_]' loop n := n + 1; end loop;
      if lower(substr(s, i, n - i)) = 'as' and n <= length(s) and substr(s, n, 1) ~ '\\s' then
        while n <= length(s) and substr(s, n, 1) ~ '\\s' loop n := n + 1; end loop;
        while n <= length(s) and substr(s, n, 1) ~ '[a-zA-Z0-9_]' loop n := n + 1; end loop;
        i := n;
      else
        out := out || lower(c);
        i := i + 1;
      end if;
    elsif c = '(' and i < length(s) and substr(s, i + 1, 1) ~ '[0-9]' then
      n := i + 1;
      while n <= length(s) and substr(s, n, 1) ~ '[0-9]' loop n := n + 1; end loop;
      if n <= length(s) and substr(s, n, 1) = ')' and n <= length(s) - 2 and substr(s, n + 1, 2) = '::' then
        j := n + 3;
        while j <= length(s) and substr(s, j, 1) ~ '[a-zA-Z]' loop j := j + 1; end loop;
        if lower(substr(s, n + 3, j - n - 3)) in ('numeric','integer','bigint','smallint') then
          out := out || substr(s, i + 1, n - i - 1);
          i := j;
          continue;
        end if;
      end if;
      out := out || c;
      i := i + 1;
    elsif c = '(' then
      -- parens around a no-arg function call: (auth.uid()) -> auth.uid()
      n := i + 1;
      while n <= length(s) and substr(s, n, 1) ~ '[a-zA-Z0-9_.]' loop n := n + 1; end loop;
      if n >= i + 2 and n <= length(s) - 2 and substr(s, n, 1) = '(' and substr(s, n + 1, 1) = ')' and substr(s, n + 2, 1) = ')' then
        out := out || lower(substr(s, i + 1, n - i - 1)) || '()';
        i := n + 3;
      else
        out := out || c;
        i := i + 1;
      end if;
    else
      out := out || lower(c);
      i := i + 1;
    end if;
  end loop;
  s := out;
  -- pass 3: balanced redundant outer-wrap strip
  for k in 1..3 loop
    if length(s) < 2 or left(s, 1) <> '(' or right(s, 1) <> ')' then
      exit;
    end if;
    d := 0;
    qq := false;
    m := 2;
    while m <= length(s) - 1 loop
      c := substr(s, m, 1);
      if not qq and c = '''' then
        qq := true;
      elsif qq then
        if c = '''' then
          if m < length(s) and substr(s, m + 1, 1) = '''' then
            m := m + 1;
          else
            qq := false;
          end if;
        end if;
      elsif c = '(' then
        d := d + 1;
      elsif c = ')' then
        d := d - 1;
        if d < 0 then
          exit;
        end if;
      end if;
      m := m + 1;
    end loop;
    if d <> 0 then
      exit;
    end if;
    s := substr(s, 2, length(s) - 2);
  end loop;
  -- pass 4: deparse IN-list rendering: x = any(array['a'..]) => x in('a'..)
  out := '';
  i := 1;
  qq := false;
  while i <= length(s) loop
    c := substr(s, i, 1);
    if not qq and c = '''' then
      qq := true;
      out := out || c;
      i := i + 1;
    elsif qq then
      out := out || c;
      if c = '''' then
        if i < length(s) and substr(s, i + 1, 1) = '''' then
          out := out || '''';
          i := i + 2;
          continue;
        end if;
        qq := false;
      end if;
      i := i + 1;
    elsif i <= length(s) - 10 and substr(s, i, 11) = '=any(array[' then
      out := out || 'in(';
      i := i + 11;
    elsif c = ']' and i < length(s) and substr(s, i + 1, 1) = ')' then
      out := out || ')';
      i := i + 2;
    else
      out := out || c;
      i := i + 1;
    end if;
  end loop;
  return out;
end
`;

// Dollar-quote wrapper for a literal inside generated SQL; tag starts with a
// letter and a per-call counter keeps tags unique within one guard.
let literalCounter = 0;
const literal = (text) => {
  const tag = `g${literalCounter}`;
  literalCounter += 1;
  return `$${tag}$${text}$${tag}$`;
};

const q = (text) => `'${text.replaceAll("'", "''")}'`;

// ---- violation-condition builders -----------------------------------------
// Every builder returns a boolean SQL expression that is TRUE when the
// contract is violated (guard must then fail the transaction).

const columnViolation = (table, col) => {
  const parts = [];
  if (col.laterOwned) {
    // Existence + nullability only: the type is owned by a later migration.
    parts.push(
      `not exists (select 1 from information_schema.columns c where c.table_schema='public' and c.table_name=${q(table)} and c.column_name=${q(col.name)} and c.is_nullable=${q(col.nullable ? "YES" : "NO")})`,
    );
    return parts.join(" or ");
  }
  const checks = [
    `c.data_type = ${q(col.dataType)}`,
    `c.is_nullable = ${q(col.nullable ? "YES" : "NO")}`,
  ];
  if (col.udt) checks.push(`c.udt_name = ${q(col.udt)}`);
  if (col.precision !== undefined) checks.push(`c.numeric_precision = ${col.precision}`);
  if (col.scale !== undefined) checks.push(`c.numeric_scale = ${col.scale}`);
  const defaults = Array.isArray(col.default) ? col.default : [];
  if (defaults.length === 0) {
    checks.push(`c.column_default is null`);
  } else {
    checks.push(`c.column_default is not null and c.column_default in (${defaults.map((d) => literal(d)).join(", ")})`);
  }
  return `not exists (select 1 from information_schema.columns c where c.table_schema='public' and c.table_name=${q(table)} and c.column_name=${q(col.name)} and ${checks.join(" and ")})`;
};

const absentColumnViolation = (qualifiedName) => {
  const [table, column] = qualifiedName.split(".");
  return `exists (select 1 from information_schema.columns c where c.table_schema='public' and c.table_name=${q(table)} and c.column_name=${q(column)})`;
};

const constraintColumnsSql = `(select array_agg(a.attname order by u.ord) from unnest(c.conkey) with ordinality u(attnum, ord) join pg_attribute a on a.attrelid = c.conrelid and a.attnum = u.attnum)::text[]`;

const constraintViolation = (constraint, table) => {
  const base = `c.conrelid = 'public.${table}'::regclass and c.conname = ${q(constraint.name)} and c.contype = ${q(constraint.kind)}`;
  const extras = [];
  if (constraint.kind === "c") {
    extras.push(`pg_temp.recovery_norm(pg_get_constraintdef(c.oid)) = pg_temp.recovery_norm(${literal(constraint.def ?? "")})`);
  } else {
    extras.push(`${constraintColumnsSql} = ARRAY[${constraint.columns.map((c) => literal(c)).join(", ")}]::text[]`);
  }
  if (constraint.kind === "f") {
    extras.push(`c.confrelid = 'public.${constraint.refTable}'::regclass and c.confdeltype = ${q(constraint.onDelete)}`);
  }
  return `not exists (select 1 from pg_constraint c where ${base} and ${extras.join(" and ")})`;
};

const indexViolation = (table, indexName) => {
  const canonicalColumns = (CANONICAL_INDEX_COLUMNS[indexName] ?? "").toLowerCase().replaceAll(" ", "");
  return `not exists (select 1 from pg_indexes i where i.schemaname='public' and i.tablename=${q(table)} and i.indexname=${q(indexName)} and regexp_replace(regexp_replace(regexp_replace(lower(i.indexdef), '.*using btree \\(', '', 'g'), '\\)\\s*$', '', 'g'), '\\s+', '', 'g') = ${q(canonicalColumns)})`;
};

const policyViolation = (policy) => {
  const roleLiteral = policy.roles === null || policy.roles === undefined ? "ARRAY['public']::text[]" : `ARRAY[${policy.roles.map((r) => literal(r)).join(", ")}]::text[]`;
  const parts = [
    `p.schemaname = ${q(policy.schema)}`,
    `p.tablename = ${q(policy.table)}`,
    `p.policyname = ${q(policy.name)}`,
    `p.cmd = ${q(policy.cmd)}`,
    `p.roles::text[] = ${roleLiteral}`,
  ];
  if (policy.qual !== undefined) {
    parts.push(`pg_temp.recovery_norm(coalesce(p.qual, '')) = pg_temp.recovery_norm(${literal(policy.qual)})`);
  } else {
    parts.push(`p.qual is null`);
  }
  if (policy.withCheck !== undefined) {
    parts.push(`pg_temp.recovery_norm(coalesce(p.with_check, '')) = pg_temp.recovery_norm(${literal(policy.withCheck)})`);
  } else {
    parts.push(`p.with_check is null`);
  }
  return `not exists (select 1 from pg_policies p where ${parts.join(" and ")})`;
};

const routineViolation = (routine) => {
  const config = Array.isArray(routine.config) ? routine.config : [];
  const configSql = config.length === 0 ? "p.proconfig is null" : `p.proconfig = ARRAY[${config.map((c) => literal(c)).join(", ")}]::text[]`;
  const body = /as \$[a-z_]*\$([\s\S]*?)\$[a-z_]*\$;?\s*$/m.exec(FUNCTION_DEFINITIONS[routine.name])?.[1] ?? "";
  return `not exists (select 1 from pg_proc p join pg_language l on l.oid = p.prolang where p.pronamespace = 'public'::regnamespace and p.proname = ${q(routine.name)} and pg_get_function_identity_arguments(p.oid) = ${literal(routine.identityArguments)} and l.lanname = ${q(routine.language)} and p.prosecdef = ${routine.securityDefiner ? "true" : "false"} and ${configSql} and p.prosrc = ${literal(body)})`;
};

const tableGrantViolation = (tableName, expectations) => {
  const rows = (grantee, privilegeFilter) =>
    `select 1 from information_schema.role_table_grants g where g.table_schema='public' and g.table_name=${q(tableName)} and g.grantee = ${q(grantee)} and ${privilegeFilter}`;
  const violations = [];
  for (const [grantee, spec] of Object.entries(expectations)) {
    const granted = spec.privilegeTypes ?? [];
    if (spec.exact) {
      for (const privilege of granted) {
        violations.push(`not exists (${rows(grantee, `g.privilege_type = ${q(privilege)}`)})`);
      }
      violations.push(`exists (${rows(grantee, `g.privilege_type <> ALL (ARRAY[${granted.map((p) => literal(p)).join(", ")}]::text[])`)})`);
    } else {
      for (const privilege of granted) {
        violations.push(`not exists (${rows(grantee, `g.privilege_type = ${q(privilege)}`)})`);
      }
    }
  }
  return violations;
};

const routineGrantViolation = (routineName, expectations) => {
  const rows = (grantee) =>
    `select 1 from information_schema.routine_privileges rp where rp.routine_schema='public' and rp.routine_name=${q(routineName)} and lower(rp.grantee) = ${q(GRANTEE_LOWER(grantee))} and rp.privilege_type = 'EXECUTE'`;
  const violations = [];
  for (const [grantee, spec] of Object.entries(expectations)) {
    if (spec.execute) violations.push(`not exists (${rows(grantee)})`);
    if (spec.absent) violations.push(`exists (${rows(grantee)})`);
  }
  return violations;
};

const bucketViolation = () =>
  `not exists (select 1 from storage.buckets b where b.id = ${q(FOOD_IMAGES_BUCKET.id)} and b.name = ${q(FOOD_IMAGES_BUCKET.name)} and b.public = false and b.file_size_limit = ${FOOD_IMAGES_BUCKET.fileSizeLimit} and b.allowed_mime_types = ARRAY[${FOOD_IMAGES_BUCKET.allowedMimeTypes.map((m) => literal(m)).join(", ")}]::text[])`;

const exactUniqueIndexViolation = (table) => {
  const excluded = new Set();
  for (const tables of Object.values(CANONICAL_CONSTRAINTS)) {
    for (const [t, constraints] of Object.entries(tables)) {
      if (t !== table) continue;
      for (const c of constraints) excluded.add(c.name);
    }
  }
  for (const indexName of Object.keys(CANONICAL_INDEX_TABLE)) {
    if (CANONICAL_INDEX_TABLE[indexName] === table) excluded.add(indexName);
  }
  const excludedSql = excluded.size === 0 ? "false" : `i.indexname not in (${[...excluded].map((x) => literal(x)).join(", ")})`;
  return `exists (select 1 from pg_indexes i where i.schemaname='public' and i.tablename = ${q(table)} and ${excludedSql} and i.indexdef ilike 'create unique index%')`;
};

// ---- guard assembly --------------------------------------------------------

function guardConditionsFor(file) {
  const violations = [];

  // Tables owned by this migration must exist.
  for (const [table, ownerFile] of Object.entries(TABLE_OWNER)) {
    if (ownerFile !== file) continue;
    violations.push(
      `not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname='public' and c.relname = ${q(table)} and c.relkind = 'r')`,
    );
  }

  // Columns owned by this migration (exact data_type/null/default/udt,
  // precision/scale when owned).
  for (const [table, columns] of Object.entries(CANONICAL_COLUMNS[file] ?? {})) {
    for (const column of columns) violations.push(columnViolation(table, column));
  }
  for (const absent of ABSENT_COLUMNS[file] ?? []) {
    violations.push(absentColumnViolation(absent));
  }

  // Constraints owned by this migration.
  for (const [table, constraints] of Object.entries(CANONICAL_CONSTRAINTS[file] ?? {})) {
    for (const constraint of constraints) violations.push(constraintViolation(constraint, table));
  }

  // RLS owned by this migration.
  for (const table of CANONICAL_RLS[file] ?? []) {
    violations.push(
      `not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname='public' and c.relname = ${q(table)} and c.relkind='r' and c.relrowsecurity)`,
    );
  }

  // Policies owned by this migration (command, roles, qual/with_check).
  for (const policy of CANONICAL_POLICIES[file] ?? []) {
    violations.push(policyViolation(policy));
  }

  // Plain indexes owned by this migration + superseded-index absence.
  for (const indexName of CANONICAL_INDEXES[file] ?? []) {
    const table = CANONICAL_INDEX_TABLE[indexName];
    if (table === undefined) throw new Error(`cannot derive index table for ${indexName}`);
    violations.push(indexViolation(table, indexName));
  }
  for (const indexName of SUPERSEDED_INDEXES) {
    if (file !== "0007_weight_logs.sql") continue;
    violations.push(
      `exists (select 1 from pg_indexes i where i.schemaname='public' and i.tablename='weight_logs' and i.indexname = ${q(indexName)})`,
    );
  }

  // Exact-unique tables (extra unique index on these tables is drift).
  if (file === "0007_weight_logs.sql" || file === "0008_energy_burned_logs.sql") {
    for (const table of EXACT_UNIQUE_TABLES) {
      if ((table === "weight_logs" && file === "0007_weight_logs.sql") || (table === "energy_burned_logs" && file === "0008_energy_burned_logs.sql")) {
        violations.push(exactUniqueIndexViolation(table));
      }
    }
  }

  // Routines owned by this migration.
  for (const routine of CANONICAL_ROUTINES[file] ?? []) {
    violations.push(routineViolation(routine));
  }

  // Table grants owned by this migration.
  for (const [tableName, expectations] of Object.entries(TABLE_GRANTS)) {
    if (TABLE_GRANT_OWNER[tableName] !== file) continue;
    violations.push(...tableGrantViolation(tableName, expectations));
  }

  // Routine grants owned by this migration.
  for (const [routineName, expectations] of Object.entries(ROUTINE_GRANTS)) {
    if (ROUTINE_OWNER[routineName] !== file) continue;
    violations.push(...routineGrantViolation(routineName, expectations));
  }

  // Storage bucket owned by 0004.
  if (file === "0004_store_assets.sql") {
    violations.push(bucketViolation());
  }

  return violations;
}

function buildGuard(file) {
  const conditions = guardConditionsFor(file);
  if (conditions.length === 0) {
    throw new Error(`no guard conditions generated for ${file}`);
  }
  // Indent conditions onto their own lines, joining with " or ".
  const body = conditions.map((c, index) => (index === 0 ? `  if ${c}` : `     or ${c}`)).join("\n");
  return `do $recovery$
declare bad integer := 0;
begin
  execute $normfn$
create or replace function pg_temp.recovery_norm(p text) returns text
language plpgsql immutable as $norm$
${RECOVERY_NORM_BODY}
$norm$;
$normfn$;
${body} then
    bad := 1;
  end if;
  if bad <> 0 then
    raise exception 'recovery postcondition failed';
  end if;
end
$recovery$`;
}

// Fixed, static guards per migration (assembled once at module load).
export const FULL_GUARD_SQL = Object.freeze(
  Object.fromEntries(CANONICAL_FILES.map((file) => [file, buildGuard(file)])),
);
