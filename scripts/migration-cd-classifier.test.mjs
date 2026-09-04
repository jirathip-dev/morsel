// Morsel issue #83 — migration CD classifier unit tests (no database).
import { describe, expect, it } from "vitest";
import { classifyCdDelta, VERDICTS } from "./migration-cd-classifier.mjs";
import { parseMigrationNames } from "./migration-safety.mjs";

// Byte-exact fixture of the current canonical chain (db/migrations on main).
const CANONICAL_FILES = [
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

const canonicalLocal = () => parseMigrationNames(CANONICAL_FILES);
const canonicalRecorded = () =>
  CANONICAL_FILES.map((file) => parseMigrationNames([file])[0].name);
const cleanLedger = () => ({
  ledgerExists: true,
  recorded: canonicalRecorded(),
  unknownLedgerCount: 0,
});
const withLocal = (extraFiles) => parseMigrationNames([...CANONICAL_FILES, ...extraFiles]);

describe("classifyCdDelta — clean forward-only plans auto-apply", () => {
  it("plans auto-apply for a single new forward-only 0010 migration", () => {
    const decision = classifyCdDelta({
      ...cleanLedger(),
      local: withLocal(["0010_food_catalog_seed.sql"]),
    });
    expect(decision.verdict).toBe(VERDICTS.CLEAN);
    expect(decision.autoApply).toBe(true);
    expect(decision.plan).toEqual(["0010_food_catalog_seed.sql"]);
    expect(decision.newestRecorded).toBe("0009");
    expect(decision.reasons).toEqual([]);
  });

  it("plans auto-apply for multiple new forward-only versions in order", () => {
    const decision = classifyCdDelta({
      ...cleanLedger(),
      local: withLocal(["0010_food_catalog_seed.sql", "0011_meal_snacks.sql"]),
    });
    expect(decision.verdict).toBe(VERDICTS.CLEAN);
    expect(decision.autoApply).toBe(true);
    expect(decision.plan).toEqual(["0010_food_catalog_seed.sql", "0011_meal_snacks.sql"]);
  });

  it("ignores non-migration changed files and the newly added file itself", () => {
    const decision = classifyCdDelta({
      ...cleanLedger(),
      local: withLocal(["0010_food_catalog_seed.sql"]),
      changedFiles: ["docs/MIGRATION_RECOVERY.md", "db/migrations/0010_food_catalog_seed.sql", "scripts/x.mjs"],
    });
    expect(decision.verdict).toBe(VERDICTS.CLEAN);
    expect(decision.autoApply).toBe(true);
  });

  it("reports up-to-date (nothing pending) without auto-apply", () => {
    const decision = classifyCdDelta({ ...cleanLedger(), local: canonicalLocal() });
    expect(decision.verdict).toBe(VERDICTS.UP_TO_DATE);
    expect(decision.autoApply).toBe(false);
    expect(decision.pending).toEqual([]);
    expect(decision.reasons).toEqual([]);
  });
});

describe("classifyCdDelta — backward/repair edits NEVER auto-apply", () => {
  it("blocks a pending migration at the newest recorded version (repair edit)", () => {
    const decision = classifyCdDelta({
      ...cleanLedger(),
      local: withLocal(["0009_goals_calorie_precision_repair.sql"]),
    });
    expect(decision.verdict).toBe(VERDICTS.REPAIR);
    expect(decision.autoApply).toBe(false);
    expect(decision.plan).toEqual([]);
    expect(decision.pending).toContain("0009_goals_calorie_precision_repair.sql");
    expect(decision.reasons.join(" ")).toContain("backward/repair edit");
    expect(decision.reasons.join(" ")).toContain("0009");
  });

  it("blocks a pending migration older than the newest recorded version", () => {
    const decision = classifyCdDelta({
      ...cleanLedger(),
      local: withLocal(["0005_food_catalog_backfill_fix.sql"]),
    });
    expect(decision.verdict).toBe(VERDICTS.REPAIR);
    expect(decision.autoApply).toBe(false);
    expect(decision.plan).toEqual([]);
  });

  it("blocks a repair edit even when a new forward-only migration is also pending", () => {
    const decision = classifyCdDelta({
      ...cleanLedger(),
      local: withLocal(["0007_weight_logs_sync_fix.sql", "0010_food_catalog_seed.sql"]),
    });
    expect(decision.verdict).toBe(VERDICTS.REPAIR);
    expect(decision.autoApply).toBe(false);
    expect(decision.plan).toEqual([]);
    // Both files are unrecorded, but the backward one forces the whole delta
    // onto the manual path — the forward-only file must not be auto-applied.
    expect(decision.pending).toEqual([
      "0007_weight_logs_sync_fix.sql",
      "0010_food_catalog_seed.sql",
    ]);
  });
});

describe("classifyCdDelta — retro-edits (merge changed a recorded file) NEVER auto-apply", () => {
  it("blocks an edit to an already-recorded migration file", () => {
    const decision = classifyCdDelta({
      ...cleanLedger(),
      local: canonicalLocal(),
      changedFiles: ["db/migrations/0007_weight_logs.sql"],
    });
    expect(decision.verdict).toBe(VERDICTS.RETRO_EDIT);
    expect(decision.autoApply).toBe(false);
    expect(decision.plan).toEqual([]);
    expect(decision.reasons.join(" ")).toContain("0007_weight_logs.sql");
  });

  it("blocks a new migration when the merge ALSO edited a recorded file", () => {
    const decision = classifyCdDelta({
      ...cleanLedger(),
      local: withLocal(["0010_food_catalog_seed.sql"]),
      changedFiles: ["db/migrations/0009_goals_fractional_calories.sql"],
    });
    expect(decision.verdict).toBe(VERDICTS.RETRO_EDIT);
    expect(decision.autoApply).toBe(false);
    expect(decision.plan).toEqual([]);
  });

  it("blocks a changed migration file whose version is not newer than the newest recorded", () => {
    const decision = classifyCdDelta({
      ...cleanLedger(),
      local: withLocal(["0010_food_catalog_seed.sql"]),
      changedFiles: ["db/migrations/0008_retyped_energy.sql"],
    });
    expect(decision.verdict).toBe(VERDICTS.RETRO_EDIT);
    expect(decision.autoApply).toBe(false);
  });
});

describe("classifyCdDelta — ambiguous ledger states NEVER auto-apply", () => {
  it("blocks when the ledger is missing", () => {
    const decision = classifyCdDelta({
      ledgerExists: false,
      recorded: [],
      unknownLedgerCount: 0,
      local: withLocal(["0010_food_catalog_seed.sql"]),
    });
    expect(decision.verdict).toBe(VERDICTS.AMBIGUOUS);
    expect(decision.autoApply).toBe(false);
    expect(decision.reasons.join(" ")).toContain("missing");
  });

  it("blocks when the ledger exists but is empty", () => {
    const decision = classifyCdDelta({
      ledgerExists: true,
      recorded: [],
      unknownLedgerCount: 0,
      local: canonicalLocal(),
    });
    expect(decision.verdict).toBe(VERDICTS.AMBIGUOUS);
    expect(decision.autoApply).toBe(false);
    expect(decision.reasons.join(" ")).toContain("empty");
  });

  it("blocks when the live project has unknown ledger entries", () => {
    const decision = classifyCdDelta({
      ...cleanLedger(),
      unknownLedgerCount: 2,
      local: withLocal(["0010_food_catalog_seed.sql"]),
    });
    expect(decision.verdict).toBe(VERDICTS.AMBIGUOUS);
    expect(decision.autoApply).toBe(false);
    expect(decision.plan).toEqual([]);
  });

  it("blocks when recorded entries match no local migration", () => {
    const decision = classifyCdDelta({
      ledgerExists: true,
      recorded: ["ghost_migration"],
      unknownLedgerCount: 0,
      local: canonicalLocal(),
    });
    expect(decision.verdict).toBe(VERDICTS.AMBIGUOUS);
    expect(decision.autoApply).toBe(false);
  });
});
