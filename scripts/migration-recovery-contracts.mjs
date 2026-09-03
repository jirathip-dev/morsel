// Morsel issue #76 — canonical schema recovery contracts.
//
// Authoritative end-state expectations for db/migrations/0001..0009 plus the
// idempotent convergence SQL the recovery runner may execute (only after an
// explicit apply confirmation). Nothing here is a migration file: 0001–0009
// stay byte-immutable and are never executed by the recovery runner.
//
// SQL expression expectations are authored in file form and compared with
// normalizeExpr(), a CONSERVATIVE normalizer that preserves semantic grouping
// (it never deletes parentheses wholesale and never rewrites string-literal
// contents). It absorbs only proven parser/deparser noise: whitespace/case,
// deparse subquery aliases ("AS uid"), literal type casts introduced by the
// deparser, parentheses deparse adds around no-arg function calls, plain
// comparison operands and whole expressions, and the = ANY (ARRAY[...]) IN
// rendering. Everything else — grouping parens, operators, identifiers,
// literals — survives byte-for-byte, so expressions whose grouping changes
// authorization/constraint semantics (a AND (b OR c) vs (a AND b) OR c) or
// whose literals differ can never compare equal. The same pass structure is
// implemented in SQL (RECOVERY_NORM in migration-recovery-guards.mjs) for the
// in-transaction guards; the suites cross-pin both implementations against
// real PostgreSQL renderings.

export const CANONICAL_NAMES = [
  "init",
  "targets",
  "atomic_meals_and_users_rls",
  "store_assets",
  "oauth_authorization_grants",
  "food_catalog_provider_cache",
  "weight_logs",
  "energy_burned_logs",
  "goals_fractional_calories",
];

export const CANONICAL_FILES = [
  "0001_init.sql",
  "0002_targets.sql",
  "0003_atomic_meals_and_users_rls.sql",
  "0004_store_assets.sql",
  "0005_oauth_authorization_grants.sql",
  "0006_food_catalog_provider_cache.sql",
  "0007_weight_logs.sql",
  "0008_energy_burned_logs.sql",
  "0009_goals_fractional_calories.sql",
];

export const LEDGER_DDL =
  "create table if not exists public.migration_ledger (name text primary key, applied_at timestamptz not null default now())";

// ---- normalization ---------------------------------------------------------

// Conservative expression normalization shared by classification, the
// in-transaction SQL guards (mirror implementation RECOVERY_NORM), and the
// unit/integration suites. Rules (quote-aware; string-literal contents are
// never rewritten):
//   1. drop a leading constraint-kind marker (CHECK/UNIQUE/PRIMARY KEY/...)
//   2. lowercase outside literals; drop whitespace
//   3. drop deparse subquery aliases: "as <ident>"
//   4. drop deparser literal casts ('x'::text, (0)::numeric)
//   5. drop parentheses deparse adds around no-arg calls: (auth.uid())
//   6. drop parentheses around plain comparisons (no boolean keyword inside)
//   7. drop balanced whole-expression wraps (<= 3)
//   8. rewrite deparse IN rendering: x = any(array['a','b']) => x in('a','b')
const WORD = /^[a-zA-Z0-9_]+$/;
const NORM_CAST_TYPES = new Set(["text", "numeric", "integer", "bigint", "smallint", "boolean"]);
const NUM_CAST_TYPES = new Set(["numeric", "integer", "bigint", "smallint"]);

function isWordBoundaryBefore(original, index) {
  if (index <= 0) return true;
  return !/^[a-zA-Z0-9_]$/.test(original[index - 1]);
}

// Quote-aware helpers shared by the passes below.
function scanQuotedLiteral(original, start) {
  // original[start] === "'": return index just past the closing quote.
  let i = start + 1;
  while (i < original.length) {
    if (original[i] === "'") {
      if (i + 1 < original.length && original[i + 1] === "'") {
        i += 1;
      } else {
        return i + 1;
      }
    }
    i += 1;
  }
  return original.length;
}

function findMatchingParen(original, open) {
  // original[open] === "(": quote-aware depth walk; returns close index or -1.
  let depth = 1;
  let i = open + 1;
  let inLiteral = false;
  while (i < original.length) {
    const c = original[i];
    if (!inLiteral && c === "'") {
      i = scanQuotedLiteral(original, i);
      continue;
    }
    if (c === "(") depth += 1;
    else if (c === ")") {
      depth -= 1;
      if (depth === 0) return i;
    }
    i += 1;
  }
  return -1;
}

function parenContentInfo(original, open, close) {
  // Inspect content original[open+1 .. close-1]: does it contain a
  // top-level comparison operator and/or a top-level boolean keyword?
  // Runs on whitespace-preserving text so keyword boundaries are real.
  let hasComparison = false;
  let hasBoolWord = false;
  let depth = 0;
  let i = open + 1;
  while (i < close) {
    const c = original[i];
    if (c === "'") {
      i = scanQuotedLiteral(original, i);
      continue;
    }
    if (c === "(") depth += 1;
    else if (c === ")") depth -= 1;
    else if (depth === 0 && !hasComparison && c === "=") hasComparison = true;
    else if (depth === 0 && !hasComparison && c === ">") hasComparison = true;
    else if (depth === 0 && !hasComparison && c === "<") hasComparison = true;
    else if (depth === 0 && !hasComparison && c === "!") hasComparison = true;
    else if (depth === 0 && !hasComparison && c === "~") hasComparison = true;
    else if (depth === 0 && !hasBoolWord && /^[a-zA-Z]$/.test(c)) {
      const wordMatch = /^[a-zA-Z0-9_]+/.exec(original.slice(i, close));
      const word = wordMatch ? wordMatch[0] : c;
      const lower = word.toLowerCase();
      if (lower === "and" || lower === "or" || lower === "not") hasBoolWord = true;
      i += Math.max(word.length - 1, 0);
    }
    i += 1;
  }
  return { hasComparison, hasBoolWord };
}

// Drop parentheses deparse adds around plain comparisons. Parentheses whose
// content groups with and/or/not are preserved (semantic grouping survives).
function stripComparisonParens(input) {
  let s = input;
  let changed = true;
  let passes = 0;
  while (changed && passes < 8) {
    changed = false;
    passes += 1;
    for (let i = 0; i < s.length; i += 1) {
      if (s[i] !== "(") continue;
      const close = findMatchingParen(s, i);
      if (close < 0) break;
      if (close <= i + 1) {
        i = close;
        continue;
      }
      const { hasComparison, hasBoolWord } = parenContentInfo(s, i, close);
      if (hasComparison && !hasBoolWord) {
        s = s.slice(0, i) + s.slice(i + 1, close) + s.slice(close + 1);
        changed = true;
        break;
      }
    }
  }
  return s;
}

export function normalizeExpr(text) {
  if (text === null || text === undefined) return null;
  let s = String(text).trim();

  // 1. leading constraint-kind marker (observed pg_get_constraintdef output)
  const kindMatch = /^([a-z_]+)(?:\s+|$)/i.exec(s);
  if (kindMatch) {
    const kind = kindMatch[1].toLowerCase();
    if (kind === "check" || kind === "unique") {
      s = s.slice(kindMatch[0].length).trim();
    } else if (kind === "primary" || kind === "foreign") {
      const rest = s.slice(kindMatch[0].length).trim();
      const keyMatch = /^([a-z_]+)(?:\s+|$)/i.exec(rest);
      if (keyMatch && keyMatch[1].toLowerCase() === "key") {
        s = rest.slice(keyMatch[0].length).trim();
      }
    }
  }

  // 6. drop parentheses around plain comparisons (deparse grouping noise).
  // Runs BEFORE whitespace collapse so boolean keywords keep word
  // boundaries; and/or/not grouping parens are preserved.
  s = stripComparisonParens(s);

  // 2/3/4/5. single character scan (quote-aware)
  let out = "";
  let i = 0;
  while (i < s.length) {
    const c = s[i];
    if (c === "'") {
      const end = scanQuotedLiteral(s, i);
      out += s.slice(i, end);
      i = end;
      // literal cast introduced by deparse: 'x'::text / 'x'::numeric ...
      const cast = /^::([a-z]+)/i.exec(s.slice(i));
      if (cast && NORM_CAST_TYPES.has(cast[1].toLowerCase())) {
        i += cast[0].length;
      }
      continue;
    }
    if (/\s/.test(c)) {
      i += 1;
      continue;
    }
    if (c.toLowerCase() === "a" && isWordBoundaryBefore(s, i)) {
      const wordMatch = /^[a-zA-Z0-9_]+/.exec(s.slice(i));
      const word = wordMatch ? wordMatch[0] : c;
      const afterWord = s.slice(i + word.length);
      if (word.toLowerCase() === "as" && /^\s+[a-zA-Z0-9_]+/.test(afterWord)) {
        const aliasMatch = /^\s+([a-zA-Z0-9_]+)/.exec(afterWord);
        i += word.length + aliasMatch[0].length;
        continue;
      }
      out += c.toLowerCase();
      i += 1;
      continue;
    }
    if (c === "(" && i + 1 < s.length && /^[0-9]$/.test(s[i + 1])) {
      const digits = /^[0-9]+/.exec(s.slice(i + 1));
      const afterDigits = s.slice(i + 1 + digits[0].length);
      if (afterDigits.startsWith(")") && /^::([a-z]+)/i.test(afterDigits.slice(1))) {
        const cast = /^::([a-z]+)/i.exec(afterDigits.slice(1));
        if (NUM_CAST_TYPES.has(cast[1].toLowerCase())) {
          out += digits[0];
          i += 1 + digits[0].length + 1 + cast[0].length;
          continue;
        }
      }
      out += c;
      i += 1;
      continue;
    }
    if (c === "(") {
      // parentheses deparse adds around a no-arg function call: (auth.uid())
      const identMatch = /^[a-zA-Z0-9_.]+/.exec(s.slice(i + 1));
      if (identMatch && s[i + 1 + identMatch[0].length] === "(" && s[i + 2 + identMatch[0].length] === ")") {
        const close = i + 2 + identMatch[0].length;
        if (s[close + 1] === ")") {
          out += identMatch[0].toLowerCase() + "()";
          i = close + 2;
          continue;
        }
      }
      out += c;
      i += 1;
      continue;
    }
    out += c.toLowerCase();
    i += 1;
  }
  s = out;

  // 7. balanced whole-expression wraps (deparse wraps BoolExprs)
  for (let k = 0; k < 3; k += 1) {
    if (s.length < 2 || s[0] !== "(" || s[s.length - 1] !== ")") break;
    let depth = 0;
    let balanced = true;
    for (i = 1; i < s.length - 1; i += 1) {
      const c = s[i];
      if (c === "'") {
        i = scanQuotedLiteral(s, i) - 1;
        continue;
      }
      if (c === "(") depth += 1;
      else if (c === ")") {
        depth -= 1;
        if (depth < 0) {
          balanced = false;
          break;
        }
      }
    }
    if (!balanced || depth !== 0) break;
    s = s.slice(1, -1);
  }

  // 8. deparse IN-list rendering: x = any(array['a','b']) => x in('a','b')
  out = "";
  i = 0;
  while (i < s.length) {
    const c = s[i];
    if (c === "'") {
      out += s.slice(i, scanQuotedLiteral(s, i));
      i = scanQuotedLiteral(s, i);
      continue;
    }
    if (s.startsWith("=any(array[", i)) {
      out += "in(";
      i += "=any(array[".length;
      continue;
    }
    if (c === "]" && s[i + 1] === ")") {
      out += ")";
      i += 2;
      continue;
    }
    out += c;
    i += 1;
  }
  return out;
}

// Normalize a pg_indexes.indexdef into its trailing column list form, e.g.
// "create index x on public.t using btree (user_id, eaten_at desc)" =>
// "user_id,eaten_at desc".
export function normalizeIndexColumns(indexdef) {
  const match = /\(([^()]*)\)\s*$/.exec(String(indexdef ?? ""));
  if (!match) return null;
  return match[1]
    .toLowerCase()
    .replace(/\s+/g, " ")
    .replace(/,\s*/g, ",")
    .trim();
}

// Canonical expected column-list (with desc markers) per plain index.
export const CANONICAL_INDEX_COLUMNS = {
  meal_logs_user_eaten_idx: "user_id,eaten_at desc",
  meal_items_log_idx: "meal_log_id",
  water_logs_user_idx: "user_id,logged_at desc",
  oauth_authorization_grants_expires_at_idx: "expires_at",
  weight_logs_user_measured_idx: "user_id,measured_at desc",
  energy_burned_logs_user_burned_idx: "user_id,burned_at desc",
};

// Plain (non-constraint) canonical indexes, keyed by migration file.
export const CANONICAL_INDEXES = {
  "0001_init.sql": ["meal_logs_user_eaten_idx", "meal_items_log_idx", "water_logs_user_idx"],
  "0005_oauth_authorization_grants.sql": ["oauth_authorization_grants_expires_at_idx"],
  "0007_weight_logs.sql": ["weight_logs_user_measured_idx"],
  "0008_energy_burned_logs.sql": ["energy_burned_logs_user_burned_idx"],
};

// Canonical plain index -> owning table (fixed manifest mapping).
export const CANONICAL_INDEX_TABLE = {
  meal_logs_user_eaten_idx: "meal_logs",
  meal_items_log_idx: "meal_items",
  water_logs_user_idx: "water_logs",
  oauth_authorization_grants_expires_at_idx: "oauth_authorization_grants",
  weight_logs_user_measured_idx: "weight_logs",
  energy_burned_logs_user_burned_idx: "energy_burned_logs",
};

// Indexes that the canonical end state requires to be ABSENT.
export const SUPERSEDED_INDEXES = ["weight_logs_user_idx"];

// Tables whose canonical index set must contain no other UNIQUE index
// (conflicting uniqueness semantics fail closed).
export const EXACT_UNIQUE_TABLES = ["weight_logs", "energy_burned_logs", "oauth_authorization_grants"];

// ---- canonical columns -----------------------------------------------------
// dataType: information_schema.data_type; udt only for arrays.
// nullable: true when the canonical column is nullable.
// default: null = no default allowed; [] = no default (absent);
// otherwise accepted column_default renderings ("" = null default required).
// Column expectations are keyed by owning migration file.

export const CANONICAL_COLUMNS = {
  "0001_init.sql": {
    users: [
      { name: "id", dataType: "uuid", nullable: false, default: ["gen_random_uuid()"] },
      { name: "email", dataType: "text", nullable: false, default: [] },
      { name: "display_name", dataType: "text", nullable: true, default: [] },
      { name: "timezone", dataType: "text", nullable: false, default: ["'Asia/Bangkok'::text", "'Asia/Bangkok'"] },
      { name: "created_at", dataType: "timestamp with time zone", nullable: false, default: ["now()"] },
    ],
    goals: [
      { name: "user_id", dataType: "uuid", nullable: false, default: [] },
      // Existence owned by 0001; the numeric(10,1) type is owned by 0009.
      { name: "calorie_target_kcal", dataType: "numeric", nullable: true, default: [], laterOwned: true },
      { name: "protein_g", dataType: "numeric", nullable: true, default: [] },
      { name: "carbs_g", dataType: "numeric", nullable: true, default: [] },
      { name: "fat_g", dataType: "numeric", nullable: true, default: [] },
      { name: "updated_at", dataType: "timestamp with time zone", nullable: false, default: ["now()"] },
    ],
    meal_logs: [
      { name: "id", dataType: "uuid", nullable: false, default: ["gen_random_uuid()"] },
      { name: "user_id", dataType: "uuid", nullable: false, default: [] },
      { name: "eaten_at", dataType: "timestamp with time zone", nullable: false, default: ["now()"] },
      { name: "meal_type", dataType: "text", nullable: false, default: [] },
      { name: "source", dataType: "text", nullable: false, default: ["'manual'::text", "'manual'"] },
      { name: "image_path", dataType: "text", nullable: true, default: [] },
      { name: "notes", dataType: "text", nullable: true, default: [] },
      { name: "created_at", dataType: "timestamp with time zone", nullable: false, default: ["now()"] },
      { name: "updated_at", dataType: "timestamp with time zone", nullable: false, default: ["now()"] },
    ],
    meal_items: [
      { name: "id", dataType: "uuid", nullable: false, default: ["gen_random_uuid()"] },
      { name: "meal_log_id", dataType: "uuid", nullable: false, default: [] },
      { name: "name", dataType: "text", nullable: false, default: [] },
      { name: "quantity", dataType: "numeric", nullable: false, default: ["1"] },
      { name: "unit", dataType: "text", nullable: false, default: ["'serving'::text", "'serving'"] },
      { name: "calories_kcal", dataType: "numeric", nullable: true, default: [] },
      { name: "protein_g", dataType: "numeric", nullable: true, default: [] },
      { name: "carbs_g", dataType: "numeric", nullable: true, default: [] },
      { name: "fat_g", dataType: "numeric", nullable: true, default: [] },
      { name: "fiber_g", dataType: "numeric", nullable: true, default: [] },
      { name: "sugar_g", dataType: "numeric", nullable: true, default: [] },
      { name: "barcode", dataType: "text", nullable: true, default: [] },
      { name: "food_ref_id", dataType: "uuid", nullable: true, default: [] },
      { name: "confidence", dataType: "numeric", nullable: true, default: [] },
      { name: "source_notes", dataType: "text", nullable: true, default: [] },
      { name: "created_at", dataType: "timestamp with time zone", nullable: false, default: ["now()"] },
    ],
    water_logs: [
      { name: "id", dataType: "uuid", nullable: false, default: ["gen_random_uuid()"] },
      { name: "user_id", dataType: "uuid", nullable: false, default: [] },
      { name: "logged_at", dataType: "timestamp with time zone", nullable: false, default: ["now()"] },
      { name: "ml", dataType: "numeric", nullable: false, default: [] },
    ],
    weight_logs: [
      { name: "id", dataType: "uuid", nullable: false, default: ["gen_random_uuid()"] },
      { name: "user_id", dataType: "uuid", nullable: false, default: [] },
      { name: "kg", dataType: "numeric", nullable: false, default: [] },
      // logged_at/measured_at ownership moved to 0007 (rename target column
      // expectations live there); 0001 only owns the base columns.
    ],
    food_catalog: [
      { name: "id", dataType: "uuid", nullable: false, default: ["gen_random_uuid()"] },
      { name: "name", dataType: "text", nullable: false, default: [] },
      { name: "brand", dataType: "text", nullable: true, default: [] },
      { name: "barcode", dataType: "text", nullable: true, default: [] },
      { name: "serving_size", dataType: "text", nullable: true, default: [] },
      { name: "serving_unit", dataType: "text", nullable: true, default: [] },
      { name: "calories_kcal", dataType: "numeric", nullable: true, default: [] },
      { name: "protein_g", dataType: "numeric", nullable: true, default: [] },
      { name: "carbs_g", dataType: "numeric", nullable: true, default: [] },
      { name: "fat_g", dataType: "numeric", nullable: true, default: [] },
      { name: "fiber_g", dataType: "numeric", nullable: true, default: [] },
      { name: "sugar_g", dataType: "numeric", nullable: true, default: [] },
      { name: "source", dataType: "text", nullable: false, default: ["'curated'::text", "'curated'"] },
      { name: "created_at", dataType: "timestamp with time zone", nullable: false, default: ["now()"] },
    ],
  },
  "0002_targets.sql": {
    profiles: [
      { name: "user_id", dataType: "uuid", nullable: false, default: [] },
      { name: "sex", dataType: "text", nullable: false, default: [] },
      { name: "age_years", dataType: "integer", nullable: false, default: [] },
      { name: "height_cm", dataType: "numeric", nullable: false, default: [] },
      { name: "weight_kg", dataType: "numeric", nullable: false, default: [] },
      { name: "activity_level", dataType: "text", nullable: false, default: ["'moderate'::text", "'moderate'"] },
      { name: "diet_goal", dataType: "text", nullable: false, default: ["'maintain'::text", "'maintain'"] },
      { name: "goal_weight_kg", dataType: "numeric", nullable: true, default: [] },
      { name: "updated_at", dataType: "timestamp with time zone", nullable: false, default: ["now()"] },
    ],
    goals: [{ name: "source", dataType: "text", nullable: false, default: ["'computed'::text", "'computed'"] }],
  },
  "0005_oauth_authorization_grants.sql": {
    oauth_authorization_grants: [
      { name: "code_hash", dataType: "text", nullable: false, default: [] },
      { name: "client_id", dataType: "text", nullable: false, default: [] },
      { name: "redirect_uri", dataType: "text", nullable: false, default: [] },
      { name: "code_challenge", dataType: "text", nullable: false, default: [] },
      { name: "scopes", dataType: "ARRAY", udt: "_text", nullable: false, default: ["'{}'::text[]", "'{}'"] },
      { name: "resource", dataType: "text", nullable: true, default: [] },
      { name: "user_id", dataType: "uuid", nullable: false, default: [] },
      { name: "refresh_token", dataType: "text", nullable: false, default: [] },
      { name: "expires_at", dataType: "timestamp with time zone", nullable: false, default: [] },
      { name: "created_at", dataType: "timestamp with time zone", nullable: false, default: ["now()"] },
    ],
  },
  "0007_weight_logs.sql": {
    weight_logs: [
      { name: "measured_at", dataType: "timestamp with time zone", nullable: false, default: ["now()"] },
      { name: "source", dataType: "text", nullable: false, default: ["'manual'::text", "'manual'"] },
      // logged_at must be ABSENT in the canonical end state (renamed away).
    ],
  },
  "0008_energy_burned_logs.sql": {
    energy_burned_logs: [
      { name: "id", dataType: "uuid", nullable: false, default: ["gen_random_uuid()"] },
      { name: "user_id", dataType: "uuid", nullable: false, default: [] },
      { name: "burned_at", dataType: "timestamp with time zone", nullable: false, default: [] },
      { name: "active_kcal", dataType: "numeric", nullable: false, default: [] },
      { name: "source", dataType: "text", nullable: false, default: ["'manual'::text", "'manual'"] },
    ],
  },
  "0009_goals_fractional_calories.sql": {
    goals: [{ name: "calorie_target_kcal", dataType: "numeric", precision: 10, scale: 1, nullable: true, default: [] }],
  },
};

// Columns that must be ABSENT in the canonical end state, keyed by the
// migration that removes them.
export const ABSENT_COLUMNS = {
  "0007_weight_logs.sql": ["weight_logs.logged_at"],
};

// ---- canonical constraints ------------------------------------------------
// name: constraint name (canonical; auto-generated names are deterministic
// because the DDL is fixed). kind: p/u/c/f. columns: expected order.
// def: canonical authored CHECK expression (normalized before compare).
// refTable/onDelete: foreign-key expectations.

export const CANONICAL_CONSTRAINTS = {
  "0001_init.sql": {
    users: [
      { name: "users_pkey", kind: "p", columns: ["id"] },
      { name: "users_email_key", kind: "u", columns: ["email"] },
    ],
    goals: [
      { name: "goals_pkey", kind: "p", columns: ["user_id"] },
      { name: "goals_user_id_fkey", kind: "f", columns: ["user_id"], refTable: "users", onDelete: "c" },
    ],
    meal_logs: [
      { name: "meal_logs_pkey", kind: "p", columns: ["id"] },
      { name: "meal_logs_user_id_fkey", kind: "f", columns: ["user_id"], refTable: "users", onDelete: "c" },
      { name: "meal_logs_meal_type_check", kind: "c", columns: ["meal_type"], def: "meal_type in ('breakfast', 'lunch', 'dinner', 'snack')" },
      { name: "meal_logs_source_check", kind: "c", columns: ["source"], def: "source in ('manual', 'photo_vision', 'barcode', 'import', 'voice')" },
    ],
    meal_items: [
      { name: "meal_items_pkey", kind: "p", columns: ["id"] },
      { name: "meal_items_meal_log_id_fkey", kind: "f", columns: ["meal_log_id"], refTable: "meal_logs", onDelete: "c" },
      { name: "meal_items_unit_check", kind: "c", columns: ["unit"], def: "unit in ('g', 'ml', 'serving', 'piece', 'cup')" },
    ],
    water_logs: [
      { name: "water_logs_pkey", kind: "p", columns: ["id"] },
      { name: "water_logs_user_id_fkey", kind: "f", columns: ["user_id"], refTable: "users", onDelete: "c" },
    ],
    weight_logs: [
      { name: "weight_logs_pkey", kind: "p", columns: ["id"] },
      { name: "weight_logs_user_id_fkey", kind: "f", columns: ["user_id"], refTable: "users", onDelete: "c" },
    ],
    food_catalog: [
      { name: "food_catalog_pkey", kind: "p", columns: ["id"] },
      { name: "food_catalog_barcode_key", kind: "u", columns: ["barcode"] },
    ],
  },
  "0002_targets.sql": {
    profiles: [
      { name: "profiles_pkey", kind: "p", columns: ["user_id"] },
      { name: "profiles_user_id_fkey", kind: "f", columns: ["user_id"], refTable: "users", onDelete: "c" },
      { name: "profiles_sex_check", kind: "c", columns: ["sex"], def: "sex in ('male', 'female')" },
      { name: "profiles_age_years_check", kind: "c", columns: ["age_years"], def: "age_years >= 10 and age_years <= 100" },
      { name: "profiles_height_cm_check", kind: "c", columns: ["height_cm"], def: "height_cm >= 100 and height_cm <= 250" },
      { name: "profiles_weight_kg_check", kind: "c", columns: ["weight_kg"], def: "weight_kg >= 30 and weight_kg <= 300" },
      { name: "profiles_activity_level_check", kind: "c", columns: ["activity_level"], def: "activity_level in ('sedentary', 'light', 'moderate', 'active', 'very_active')" },
      { name: "profiles_diet_goal_check", kind: "c", columns: ["diet_goal"], def: "diet_goal in ('lose', 'maintain', 'gain')" },
    ],
    goals: [{ name: "goals_source_check", kind: "c", columns: ["source"], def: "source in ('computed', 'manual')" }],
  },
  "0005_oauth_authorization_grants.sql": {
    oauth_authorization_grants: [
      { name: "oauth_authorization_grants_pkey", kind: "p", columns: ["code_hash"] },
    ],
  },
  "0007_weight_logs.sql": {
    weight_logs: [
      { name: "weight_logs_source_check", kind: "c", columns: ["source"], def: "source in ('manual', 'apple_health')" },
      { name: "weight_logs_kg_positive", kind: "c", columns: ["kg"], def: "kg > 0" },
      { name: "weight_logs_user_measured_unique", kind: "u", columns: ["user_id", "measured_at"] },
    ],
  },
  "0008_energy_burned_logs.sql": {
    energy_burned_logs: [
      { name: "energy_burned_logs_pkey", kind: "p", columns: ["id"] },
      { name: "energy_burned_logs_user_id_fkey", kind: "f", columns: ["user_id"], refTable: "users", onDelete: "c" },
      { name: "energy_burned_logs_kcal_positive", kind: "c", columns: ["active_kcal"], def: "active_kcal > 0" },
      { name: "energy_burned_logs_source_check", kind: "c", columns: ["source"], def: "source in ('manual', 'apple_health')" },
      { name: "energy_burned_logs_user_burned_unique", kind: "u", columns: ["user_id", "burned_at"] },
    ],
  },
};

// ---- canonical RLS ---------------------------------------------------------
// Tables that must have row-level security ENABLED in the canonical end
// state, keyed by the migration that enables them.
export const CANONICAL_RLS = {
  "0001_init.sql": ["goals", "meal_logs", "meal_items", "water_logs", "weight_logs"],
  "0003_atomic_meals_and_users_rls.sql": ["users"],
  "0004_store_assets.sql": ["food_catalog"],
  "0005_oauth_authorization_grants.sql": ["oauth_authorization_grants"],
  "0008_energy_burned_logs.sql": ["energy_burned_logs"],
};

// ---- canonical policies ----------------------------------------------------
// Expression expectations are authored in file form; normalizeExpr absorbs
// deparse artifacts (subquery aliases, casts, parens, whitespace).
// roles: null means no TO clause (applies to public); otherwise role list.

export const CANONICAL_POLICIES = {
  "0001_init.sql": [
    { schema: "public", table: "goals", name: "goals_select_own", cmd: "SELECT", roles: null, qual: "(select auth.uid()) = user_id" },
    { schema: "public", table: "goals", name: "goals_insert_own", cmd: "INSERT", roles: null, withCheck: "(select auth.uid()) = user_id" },
    { schema: "public", table: "goals", name: "goals_update_own", cmd: "UPDATE", roles: null, qual: "(select auth.uid()) = user_id" },
    { schema: "public", table: "meal_logs", name: "meal_logs_select_own", cmd: "SELECT", roles: null, qual: "(select auth.uid()) = user_id" },
    { schema: "public", table: "meal_logs", name: "meal_logs_insert_own", cmd: "INSERT", roles: null, withCheck: "(select auth.uid()) = user_id" },
    { schema: "public", table: "meal_logs", name: "meal_logs_update_own", cmd: "UPDATE", roles: null, qual: "(select auth.uid()) = user_id" },
    { schema: "public", table: "meal_logs", name: "meal_logs_delete_own", cmd: "DELETE", roles: null, qual: "(select auth.uid()) = user_id" },
    { schema: "public", table: "meal_items", name: "meal_items_select_own", cmd: "SELECT", roles: null, qual: "(select auth.uid()) = (select meal_logs.user_id from meal_logs where meal_logs.id = meal_items.meal_log_id)" },
    { schema: "public", table: "meal_items", name: "meal_items_insert_own", cmd: "INSERT", roles: null, withCheck: "(select auth.uid()) = (select meal_logs.user_id from meal_logs where meal_logs.id = meal_items.meal_log_id)" },
    { schema: "public", table: "meal_items", name: "meal_items_update_own", cmd: "UPDATE", roles: null, qual: "(select auth.uid()) = (select meal_logs.user_id from meal_logs where meal_logs.id = meal_items.meal_log_id)" },
    { schema: "public", table: "meal_items", name: "meal_items_delete_own", cmd: "DELETE", roles: null, qual: "(select auth.uid()) = (select meal_logs.user_id from meal_logs where meal_logs.id = meal_items.meal_log_id)" },
    { schema: "public", table: "water_logs", name: "water_logs_all_own", cmd: "ALL", roles: null, qual: "(select auth.uid()) = user_id", withCheck: "(select auth.uid()) = user_id" },
    { schema: "public", table: "weight_logs", name: "weight_logs_all_own", cmd: "ALL", roles: null, qual: "(select auth.uid()) = user_id", withCheck: "(select auth.uid()) = user_id" },
  ],
  "0002_targets.sql": [
    { schema: "public", table: "profiles", name: "profiles_select_own", cmd: "SELECT", roles: null, qual: "(select auth.uid()) = user_id" },
    { schema: "public", table: "profiles", name: "profiles_insert_own", cmd: "INSERT", roles: null, withCheck: "(select auth.uid()) = user_id" },
    { schema: "public", table: "profiles", name: "profiles_update_own", cmd: "UPDATE", roles: null, qual: "(select auth.uid()) = user_id" },
  ],
  "0003_atomic_meals_and_users_rls.sql": [
    { schema: "public", table: "users", name: "users_select_own", cmd: "SELECT", roles: null, qual: "(select auth.uid()) = id" },
    { schema: "public", table: "users", name: "users_insert_own", cmd: "INSERT", roles: null, withCheck: "(select auth.uid()) = id" },
    { schema: "public", table: "users", name: "users_update_own", cmd: "UPDATE", roles: null, qual: "(select auth.uid()) = id", withCheck: "(select auth.uid()) = id" },
  ],
  "0004_store_assets.sql": [
    { schema: "storage", table: "objects", name: "food_images_insert_own", cmd: "INSERT", roles: ["authenticated"], withCheck: "bucket_id = 'food-images' and (storage.foldername(name))[1] = (select auth.uid()::text)" },
    { schema: "storage", table: "objects", name: "food_images_select_own", cmd: "SELECT", roles: ["authenticated"], qual: "bucket_id = 'food-images' and (storage.foldername(name))[1] = (select auth.uid()::text)" },
    { schema: "storage", table: "objects", name: "food_images_update_own", cmd: "UPDATE", roles: ["authenticated"], qual: "bucket_id = 'food-images' and (storage.foldername(name))[1] = (select auth.uid()::text)", withCheck: "bucket_id = 'food-images' and (storage.foldername(name))[1] = (select auth.uid()::text)" },
    { schema: "storage", table: "objects", name: "food_images_delete_own", cmd: "DELETE", roles: ["authenticated"], qual: "bucket_id = 'food-images' and (storage.foldername(name))[1] = (select auth.uid()::text)" },
    { schema: "public", table: "food_catalog", name: "food_catalog_select_authenticated", cmd: "SELECT", roles: ["authenticated"], qual: "true" },
  ],
  "0005_oauth_authorization_grants.sql": [
    { schema: "public", table: "oauth_authorization_grants", name: "oauth authorization grants are readable by their owner", cmd: "SELECT", roles: ["authenticated"], qual: "(select auth.uid()) = user_id" },
    { schema: "public", table: "oauth_authorization_grants", name: "oauth authorization grants are insertable by their owner", cmd: "INSERT", roles: ["authenticated"], withCheck: "(select auth.uid()) = user_id" },
  ],
  "0008_energy_burned_logs.sql": [
    { schema: "public", table: "energy_burned_logs", name: "energy_burned_logs_all_own", cmd: "ALL", roles: null, qual: "auth.uid() = user_id", withCheck: "auth.uid() = user_id" },
  ],
};

// Tables whose canonical policy set must be exact (an extra policy on one of
// these public tables is conflicting drift -> BLOCKED_AMBIGUOUS). Storage
// policies are additionally checked for food-images scope.
export const EXACT_POLICY_TABLES = [
  "users", "goals", "meal_logs", "meal_items", "water_logs", "weight_logs",
  "profiles", "oauth_authorization_grants", "food_catalog", "energy_burned_logs",
];

// ---- canonical routines ----------------------------------------------------
// identityArguments: pg_get_function_identity_arguments rendering (includes
// declared argument names). bodyFile: migration file that defines the body.

export const CANONICAL_ROUTINES = {
  "0002_targets.sql": [{
    name: "compute_targets",
    identityArguments: "p profiles",
    language: "plpgsql",
    securityDefiner: false,
    config: [],
    bodyFile: "0002_targets.sql",
  }],
  "0003_atomic_meals_and_users_rls.sql": [{
    name: "log_meal_with_items",
    identityArguments: "p_user_id uuid, p_eaten_at timestamp with time zone, p_meal_type text, p_source text, p_image_path text, p_notes text, p_items jsonb",
    language: "plpgsql",
    securityDefiner: false,
    config: ["search_path=public"],
    bodyFile: "0003_atomic_meals_and_users_rls.sql",
  }],
  "0005_oauth_authorization_grants.sql": [{
    name: "claim_oauth_authorization_grant",
    identityArguments: "p_code_hash text, p_client_id text",
    language: "sql",
    securityDefiner: true,
    config: ["search_path=public, pg_temp"],
    bodyFile: "0005_oauth_authorization_grants.sql",
  }],
  "0006_food_catalog_provider_cache.sql": [{
    name: "upsert_food_catalog",
    identityArguments: "p_rows jsonb",
    language: "plpgsql",
    securityDefiner: true,
    config: ["search_path=public, pg_temp"],
    bodyFile: "0006_food_catalog_provider_cache.sql",
  }],
};

// Non-canonical signatures under a canonical routine name block (the recovery
// runner refuses to drop or ignore them).
export const ROUTINE_NAMES = new Set(["compute_targets", "log_meal_with_items", "claim_oauth_authorization_grant", "upsert_food_catalog"]);

// ---- canonical grants ------------------------------------------------------
// Table grant boundaries: expected privilege sets per (table, grantee).
// presence: true = grantee must have these privilege_types (may have more via
// Supabase default privileges); exact: true = grantee's privileges on the
// table must be exactly this set (migrations revoked defaults explicitly).

export const TABLE_GRANTS = {
  oauth_authorization_grants: {
    authenticated: { privilegeTypes: ["INSERT"], exact: true },
    anon: { privilegeTypes: [], exact: true },
  },
  food_catalog: {
    service_role: { privilegeTypes: ["INSERT", "SELECT"], exact: false },
  },
};

// Routine execute boundaries: presence of EXECUTE per (routine, grantee).
// absent: true = grantee must NOT have EXECUTE (revoked from public chain).
export const ROUTINE_GRANTS = {
  compute_targets: {
    public: { execute: true, absent: false },
  },
  log_meal_with_items: {
    authenticated: { execute: true },
    public: { execute: false, absent: true },
    anon: { execute: false, absent: true },
  },
  claim_oauth_authorization_grant: {
    anon: { execute: true },
    authenticated: { execute: true },
    public: { execute: false, absent: true },
  },
  upsert_food_catalog: {
    service_role: { execute: true },
    public: { execute: false, absent: true },
    authenticated: { execute: false, absent: true },
  },
};

// ---- canonical storage bucket ---------------------------------------------

export const FOOD_IMAGES_BUCKET = {
  id: "food-images",
  name: "food-images",
  public: false,
  fileSizeLimit: 10485760,
  allowedMimeTypes: ["image/jpeg", "image/png", "image/webp"],
};

// ---- canonical table set (for inventory scoping) --------------------------

export const CANONICAL_TABLES = [
  "users", "goals", "meal_logs", "meal_items", "water_logs", "weight_logs",
  "food_catalog", "profiles", "oauth_authorization_grants", "energy_burned_logs",
];

// ---- convergence builders --------------------------------------------------
// Each converge step is fully idempotent: it only creates objects that are
// missing (or, for replaceable drift objects such as policies, re-creates the
// canonical definition). Steps never drop or alter pre-existing canonical
// objects whose semantics are not proven; the runner classifies anything else
// BLOCKED_AMBIGUOUS before any write is assembled.

export const POLICY_CREATE_TEXT = (policy) => {
  const roles = policy.roles ? ` to ${policy.roles.join(", ")}` : "";
  const qual = policy.qual ? ` using (${policy.qual})` : "";
  const withCheck = policy.withCheck ? ` with check (${policy.withCheck})` : "";
  const cmd = policy.cmd === "ALL" ? "all" : policy.cmd.toLowerCase();
  return `create policy "${policy.name}" on ${policy.schema}.${policy.table} for ${cmd}${roles}${qual}${withCheck}`;
};

// One idempotent converge statement per canonical policy: the canonical
// definition replaces any same-named drift (mirrors migration 0004's own
// drop-if-exists + create pattern).
export const CONVERGE_POLICY = (policy) =>
  `drop policy if exists "${policy.name}" on ${policy.schema}.${policy.table};\n${POLICY_CREATE_TEXT(policy)};`;

// Canonical CREATE TABLE text per table (identical DDL to the migration
// files, with IF NOT EXISTS so re-convergence is a no-op).
export const CANONICAL_TABLE_DDL = {
  users: `create table if not exists public.users (
  id uuid primary key default gen_random_uuid(),
  email text unique not null,
  display_name text,
  timezone text not null default 'Asia/Bangkok',
  created_at timestamptz not null default now()
)`,
  goals: `create table if not exists public.goals (
  user_id uuid primary key references public.users(id) on delete cascade,
  calorie_target_kcal int,
  protein_g numeric,
  carbs_g numeric,
  fat_g numeric,
  updated_at timestamptz not null default now()
)`,
  meal_logs: `create table if not exists public.meal_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  eaten_at timestamptz not null default now(),
  meal_type text not null check (meal_type in ('breakfast','lunch','dinner','snack')),
  source text not null default 'manual'
    check (source in ('manual','photo_vision','barcode','import','voice')),
  image_path text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
)`,
  meal_items: `create table if not exists public.meal_items (
  id uuid primary key default gen_random_uuid(),
  meal_log_id uuid not null references public.meal_logs(id) on delete cascade,
  name text not null,
  quantity numeric not null default 1,
  unit text not null default 'serving'
    check (unit in ('g','ml','serving','piece','cup')),
  calories_kcal numeric,
  protein_g numeric,
  carbs_g numeric,
  fat_g numeric,
  fiber_g numeric,
  sugar_g numeric,
  barcode text,
  food_ref_id uuid,
  confidence numeric,
  source_notes text,
  created_at timestamptz not null default now()
)`,
  water_logs: `create table if not exists public.water_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  logged_at timestamptz not null default now(),
  ml numeric not null
)`,
  weight_logs: `create table if not exists public.weight_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  logged_at timestamptz not null default now(),
  kg numeric not null
)`,
  food_catalog: `create table if not exists public.food_catalog (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  brand text,
  barcode text unique,
  serving_size text,
  serving_unit text,
  calories_kcal numeric,
  protein_g numeric,
  carbs_g numeric,
  fat_g numeric,
  fiber_g numeric,
  sugar_g numeric,
  source text not null default 'curated',
  created_at timestamptz not null default now()
)`,
  profiles: `create table if not exists public.profiles (
  user_id uuid primary key references public.users(id) on delete cascade,
  sex text not null check (sex in ('male','female')),
  age_years int not null check (age_years between 10 and 100),
  height_cm numeric not null check (height_cm between 100 and 250),
  weight_kg numeric not null check (weight_kg between 30 and 300),
  activity_level text not null default 'moderate'
    check (activity_level in ('sedentary','light','moderate','active','very_active')),
  diet_goal text not null default 'maintain'
    check (diet_goal in ('lose','maintain','gain')),
  goal_weight_kg numeric,
  updated_at timestamptz not null default now()
)`,
  oauth_authorization_grants: `create table if not exists public.oauth_authorization_grants (
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
)`,
  energy_burned_logs: `create table if not exists public.energy_burned_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  burned_at timestamptz not null,
  active_kcal numeric not null,
  source text not null default 'manual',
  constraint energy_burned_logs_kcal_positive check (active_kcal > 0),
  constraint energy_burned_logs_source_check check (source in ('manual', 'apple_health')),
  constraint energy_burned_logs_user_burned_unique unique (user_id, burned_at)
)`,
};

// Canonical constraint add statements (missing constraints only; the DO
// wrapper makes each add conditional so re-convergence is a no-op).
function constraintAddSql(constraint, table) {
  const base = `alter table public.${table} add constraint ${constraint.name} `;
  if (constraint.kind === "p") return `${base}primary key (${constraint.columns.join(", ")})`;
  if (constraint.kind === "u") return `${base}unique (${constraint.columns.join(", ")})`;
  if (constraint.kind === "f") {
    return `${base}foreign key (${constraint.columns.join(", ")}) references public.${constraint.refTable}(id) on delete cascade`;
  }
  return `${base}check (${constraint.def})`;
}

export const CONVERGE_CONSTRAINT = (constraint, table) =>
  `do $recovery$\nbegin\n  if not exists (select 1 from pg_constraint where conrelid = 'public.${table}'::regclass and conname = '${constraint.name}') then\n    ${constraintAddSql(constraint, table).replaceAll("\n", "\n    ") + ";"}\n  end if;\nend\n$recovery$`;

// Canonical function definitions (bodies byte-identical to the migration
// files; a unit test pins each constant to its file body).
export const FUNCTION_DEFINITIONS = {
  compute_targets: `create or replace function public.compute_targets(p public.profiles)
returns table (
  bmr_kcal numeric, tdee_kcal numeric, calorie_target_kcal numeric,
  protein_g numeric, carbs_g numeric, fat_g numeric
) language plpgsql immutable as $$
declare
  bmr numeric; tdee numeric; kcal numeric; af numeric;
begin
  select case
    when p.sex = 'male'   then 10*p.weight_kg + 6.25*p.height_cm - 5*p.age_years + 5
    else                       10*p.weight_kg + 6.25*p.height_cm - 5*p.age_years - 161
  end into bmr;
  af := case p.activity_level
    when 'sedentary' then 1.2 when 'light' then 1.375
    when 'moderate'  then 1.55 when 'active' then 1.725
    else 1.9 end;
  tdee := round(bmr * af);
  kcal := case p.diet_goal
    when 'lose' then greatest(1200, tdee - 500)
    when 'gain' then tdee + 300
    else tdee end;
  -- default macro split: 30% protein / 45% carbs / 25% fat (kcal-derived)
  return query select round(bmr), round(tdee), round(kcal),
    round(kcal*0.30/4), round(kcal*0.45/4), round(kcal*0.25/9);
end $$`,
  log_meal_with_items: `create or replace function public.log_meal_with_items(
  p_user_id uuid,
  p_eaten_at timestamptz,
  p_meal_type text,
  p_source text,
  p_image_path text,
  p_notes text,
  p_items jsonb
)
returns table (
  meal_log_id uuid,
  eaten_at timestamptz,
  meal_type text,
  items jsonb
)
language plpgsql
security invoker
set search_path = public
as $function$
declare
  v_meal_log_id uuid;
begin
  if auth.uid() is distinct from p_user_id then
    raise exception 'meal user does not match authenticated user'
      using errcode = '42501';
  end if;

  if p_items is null
     or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) < 1 then
    raise exception 'a meal must contain at least one item'
      using errcode = '22023';
  end if;

  insert into public.meal_logs (
    user_id, eaten_at, meal_type, source, image_path, notes
  ) values (
    p_user_id, p_eaten_at, p_meal_type, p_source, p_image_path, p_notes
  ) returning id into v_meal_log_id;

  insert into public.meal_items (
    meal_log_id, name, quantity, unit, calories_kcal, protein_g, carbs_g,
    fat_g, fiber_g, sugar_g, barcode, food_ref_id, confidence, source_notes
  )
  select
    v_meal_log_id, item.name, item.quantity, item.unit, item.calories_kcal,
    item.protein_g, item.carbs_g, item.fat_g, item.fiber_g, item.sugar_g,
    item.barcode, item.food_ref_id, item.confidence, item.source_notes
  from jsonb_to_recordset(p_items) as item(
    name text,
    quantity numeric,
    unit text,
    calories_kcal numeric,
    protein_g numeric,
    carbs_g numeric,
    fat_g numeric,
    fiber_g numeric,
    sugar_g numeric,
    barcode text,
    food_ref_id uuid,
    confidence numeric,
    source_notes text
  );

  return query
  select
    log.id,
    log.eaten_at,
    log.meal_type,
    jsonb_agg(
      jsonb_build_object(
        'item_id', item.id,
        'name', item.name,
        'quantity', item.quantity,
        'unit', item.unit,
        'calories_kcal', item.calories_kcal,
        'protein_g', item.protein_g,
        'carbs_g', item.carbs_g,
        'fat_g', item.fat_g,
        'fiber_g', item.fiber_g,
        'sugar_g', item.sugar_g,
        'barcode', item.barcode,
        'food_ref_id', item.food_ref_id,
        'confidence', item.confidence,
        'notes', item.source_notes
      ) order by item.created_at, item.id
    )
  from public.meal_logs as log
  join public.meal_items as item on item.meal_log_id = log.id
  where log.id = v_meal_log_id
    and log.user_id = p_user_id
  group by log.id, log.eaten_at, log.meal_type;
end;
$function$`,
  claim_oauth_authorization_grant: `create or replace function public.claim_oauth_authorization_grant(
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
$function$`,
  upsert_food_catalog: `create or replace function public.upsert_food_catalog(p_rows jsonb)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  row jsonb;
begin
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'food catalog rows must be an array';
  end if;
  for row in select value from jsonb_array_elements(p_rows) loop
    if row->>'fdc_id' is null or row->>'fdc_id' = ''
      or row->>'fdc_id' !~ '^[0-9]+$'
      or row->>'id' <> (
        substr(encode(digest('usda:' || (row->>'fdc_id'), 'sha256'), 'hex'), 1, 8) || '-' ||
        substr(encode(digest('usda:' || (row->>'fdc_id'), 'sha256'), 'hex'), 9, 4) || '-4' ||
        substr(encode(digest('usda:' || (row->>'fdc_id'), 'sha256'), 'hex'), 14, 3) || '-8' ||
        substr(encode(digest('usda:' || (row->>'fdc_id'), 'sha256'), 'hex'), 18, 3) || '-' ||
        substr(encode(digest('usda:' || (row->>'fdc_id'), 'sha256'), 'hex'), 21, 12)
      )
      or coalesce(length(trim(row->>'name')), 0) = 0
      or row->>'serving_size' <> '100'
      or lower(row->>'serving_unit') <> 'g'
      or row ? 'calories_kcal' and (row->>'calories_kcal')::numeric not between 0 and 10000
      or row ? 'protein_g' and (row->>'protein_g')::numeric not between 0 and 10000
      or row ? 'carbs_g' and (row->>'carbs_g')::numeric not between 0 and 10000
      or (row ? 'fat_g' and (row->>'fat_g')::numeric not between 0 and 10000) then
      raise exception 'invalid food catalog row';
    end if;
  end loop;

  insert into public.food_catalog (id, name, brand, barcode, serving_size, serving_unit, calories_kcal, protein_g, carbs_g, fat_g, source)
  select id, name, brand, barcode, serving_size, serving_unit, calories_kcal, protein_g, carbs_g, fat_g, 'usda'
  from jsonb_to_recordset(p_rows) as rows(
    id uuid, fdc_id bigint, name text, brand text, barcode text, serving_size text, serving_unit text,
    calories_kcal numeric, protein_g numeric, carbs_g numeric, fat_g numeric)
  on conflict (id) do nothing;
end;
$$`,
};

// Static converge statement fragments per migration file, in execution
// order. Only these strings (plus ledger bootstrap/insert wrappers) may ever
// reach the query layer in apply mode.
export const CONVERGE_STATEMENTS = Object.freeze({
  "0001_init.sql": [
    CANONICAL_TABLE_DDL.users + ";",
    CANONICAL_TABLE_DDL.goals + ";",
    CANONICAL_TABLE_DDL.meal_logs + ";",
    CANONICAL_TABLE_DDL.meal_items + ";",
    CANONICAL_TABLE_DDL.water_logs + ";",
    CANONICAL_TABLE_DDL.weight_logs + ";",
    CANONICAL_TABLE_DDL.food_catalog + ";",
    "create index if not exists meal_logs_user_eaten_idx on public.meal_logs (user_id, eaten_at desc)",
    "create index if not exists meal_items_log_idx on public.meal_items (meal_log_id)",
    "create index if not exists water_logs_user_idx on public.water_logs (user_id, logged_at desc)",
    "alter table public.goals enable row level security",
    "alter table public.meal_logs enable row level security",
    "alter table public.meal_items enable row level security",
    "alter table public.water_logs enable row level security",
    "alter table public.weight_logs enable row level security",
    ...CANONICAL_POLICIES["0001_init.sql"].map((policy) => CONVERGE_POLICY(policy)),
    ...Object.keys(CANONICAL_CONSTRAINTS["0001_init.sql"]).flatMap((table) =>
      CANONICAL_CONSTRAINTS["0001_init.sql"][table].map((constraint) => CONVERGE_CONSTRAINT(constraint, table)),
    ),
  ],
  "0002_targets.sql": [
    CANONICAL_TABLE_DDL.profiles + ";",
    "alter table public.profiles enable row level security",
    ...CANONICAL_POLICIES["0002_targets.sql"].map((policy) => CONVERGE_POLICY(policy)),
    ...CANONICAL_CONSTRAINTS["0002_targets.sql"].profiles.map((constraint) => CONVERGE_CONSTRAINT(constraint, "profiles")),
    "alter table public.goals add column if not exists source text not null default 'computed' check (source in ('computed','manual'))",
    CONVERGE_CONSTRAINT(CANONICAL_CONSTRAINTS["0002_targets.sql"].goals[0], "goals"),
    `${FUNCTION_DEFINITIONS.compute_targets};`,
    "grant execute on function public.compute_targets(public.profiles) to public",
  ],
  "0003_atomic_meals_and_users_rls.sql": [
    "alter table public.users enable row level security",
    ...CANONICAL_POLICIES["0003_atomic_meals_and_users_rls.sql"].map((policy) => CONVERGE_POLICY(policy)),
    `${FUNCTION_DEFINITIONS.log_meal_with_items};`,
    "revoke execute on function public.log_meal_with_items(uuid, timestamptz, text, text, text, text, jsonb) from public",
    "grant execute on function public.log_meal_with_items(uuid, timestamptz, text, text, text, text, jsonb) to authenticated",
  ],
  "0004_store_assets.sql": [
    `insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('food-images', 'food-images', false, 10 * 1024 * 1024, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types`,
    ...CANONICAL_POLICIES["0004_store_assets.sql"].map((policy) => CONVERGE_POLICY(policy)),
    "alter table public.food_catalog enable row level security",
  ],
  "0005_oauth_authorization_grants.sql": [
    CANONICAL_TABLE_DDL.oauth_authorization_grants + ";",
    "create index if not exists oauth_authorization_grants_expires_at_idx on public.oauth_authorization_grants (expires_at)",
    ...CANONICAL_POLICIES["0005_oauth_authorization_grants.sql"].map((policy) => CONVERGE_POLICY(policy)),
    ...CANONICAL_CONSTRAINTS["0005_oauth_authorization_grants.sql"].oauth_authorization_grants.map((constraint) => CONVERGE_CONSTRAINT(constraint, "oauth_authorization_grants")),
    "alter table public.oauth_authorization_grants enable row level security",
    "revoke all on table public.oauth_authorization_grants from anon, authenticated",
    "grant insert on table public.oauth_authorization_grants to authenticated",
    `${FUNCTION_DEFINITIONS.claim_oauth_authorization_grant};`,
    "revoke execute on function public.claim_oauth_authorization_grant(text, text) from public",
    "grant execute on function public.claim_oauth_authorization_grant(text, text) to anon, authenticated",
  ],
  "0006_food_catalog_provider_cache.sql": [
    `${FUNCTION_DEFINITIONS.upsert_food_catalog};`,
    "revoke execute on function public.upsert_food_catalog(jsonb) from public, authenticated",
    "grant execute on function public.upsert_food_catalog(jsonb) to service_role",
    "grant insert, select on public.food_catalog to service_role",
  ],
  "0007_weight_logs.sql": [
    `do $recovery$
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'weight_logs' and column_name = 'logged_at')
     and not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'weight_logs' and column_name = 'measured_at') then
    alter table public.weight_logs rename column logged_at to measured_at;
  end if;
end
$recovery$`,
    "alter table public.weight_logs add column if not exists source text not null default 'manual'",
    CONVERGE_CONSTRAINT(CANONICAL_CONSTRAINTS["0007_weight_logs.sql"].weight_logs.find((c) => c.name === "weight_logs_source_check"), "weight_logs"),
    CONVERGE_CONSTRAINT(CANONICAL_CONSTRAINTS["0007_weight_logs.sql"].weight_logs.find((c) => c.name === "weight_logs_kg_positive"), "weight_logs"),
    CONVERGE_CONSTRAINT(CANONICAL_CONSTRAINTS["0007_weight_logs.sql"].weight_logs.find((c) => c.name === "weight_logs_user_measured_unique"), "weight_logs"),
    "drop index if exists public.weight_logs_user_idx",
    "create index if not exists weight_logs_user_measured_idx on public.weight_logs (user_id, measured_at desc)",
  ],
  "0008_energy_burned_logs.sql": [
    CANONICAL_TABLE_DDL.energy_burned_logs + ";",
    ...Object.keys(CANONICAL_CONSTRAINTS["0008_energy_burned_logs.sql"]).flatMap((table) =>
      CANONICAL_CONSTRAINTS["0008_energy_burned_logs.sql"][table].map((constraint) => CONVERGE_CONSTRAINT(constraint, table)),
    ),
    "alter table public.energy_burned_logs enable row level security",
    ...CANONICAL_POLICIES["0008_energy_burned_logs.sql"].map((policy) => CONVERGE_POLICY(policy)),
    "create index if not exists energy_burned_logs_user_burned_idx on public.energy_burned_logs (user_id, burned_at desc)",
  ],
  "0009_goals_fractional_calories.sql": [
    `do $recovery$
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'goals' and column_name = 'calorie_target_kcal') then
    alter table public.goals alter column calorie_target_kcal type numeric(10,1) using calorie_target_kcal::numeric(10,1);
  end if;
end
$recovery$`,
  ],
});
