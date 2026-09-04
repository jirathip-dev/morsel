// Morsel issue #83 — migration CD PR shape gate unit tests (no database).
import { describe, expect, it } from "vitest";
import { classifyPrShape, validateMigrationEntries } from "./migration-cd-pr-gate.mjs";

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

describe("classifyPrShape — clean forward-only appends pass", () => {
  it("passes a single new forward-only 0010 addition", () => {
    const result = classifyPrShape({
      baseFiles: CANONICAL_FILES,
      headFiles: [...CANONICAL_FILES, "0010_food_catalog_seed.sql"],
      changedFiles: ["db/migrations/0010_food_catalog_seed.sql"],
    });
    expect(result.ok).toBe(true);
    expect(result.additions).toEqual(["0010_food_catalog_seed.sql"]);
    expect(result.reasons).toEqual([]);
  });

  it("passes multiple strictly-newer additions in one PR", () => {
    const result = classifyPrShape({
      baseFiles: CANONICAL_FILES,
      headFiles: [...CANONICAL_FILES, "0010_food_catalog_seed.sql", "0011_meal_snacks.sql"],
      changedFiles: ["0010_food_catalog_seed.sql", "0011_meal_snacks.sql"],
    });
    expect(result.ok).toBe(true);
    expect(result.additions).toEqual(["0010_food_catalog_seed.sql", "0011_meal_snacks.sql"]);
  });

  it("passes when no db/migrations file changed (paths outside the folder are ignored)", () => {
    const result = classifyPrShape({
      baseFiles: CANONICAL_FILES,
      headFiles: CANONICAL_FILES,
      changedFiles: ["README.md"],
    });
    expect(result.ok).toBe(true);
    expect(result.additions).toEqual([]);
  });
});

describe("classifyPrShape — edits/deletes/backward additions are BLOCKED", () => {
  it("blocks an edit to an already-merged migration file", () => {
    const result = classifyPrShape({
      baseFiles: CANONICAL_FILES,
      headFiles: CANONICAL_FILES,
      changedFiles: ["db/migrations/0007_weight_logs.sql"],
    });
    expect(result.ok).toBe(false);
    expect(result.reasons.join(" ")).toContain("0007_weight_logs.sql");
    expect(result.reasons.join(" ")).toMatch(/edited/i);
  });

  it("blocks a delete of an already-merged migration file", () => {
    const result = classifyPrShape({
      baseFiles: CANONICAL_FILES,
      headFiles: CANONICAL_FILES.filter((file) => file !== "0006_food_catalog_provider_cache.sql"),
      changedFiles: ["db/migrations/0006_food_catalog_provider_cache.sql"],
    });
    expect(result.ok).toBe(false);
    expect(result.reasons.join(" ")).toMatch(/deleted or renamed/i);
  });

  it("blocks a rename (delete + add at an old version)", () => {
    const result = classifyPrShape({
      baseFiles: CANONICAL_FILES,
      headFiles: [
        ...CANONICAL_FILES.filter((file) => file !== "0008_energy_burned_logs.sql"),
        "0008_energy_burned_logs_retyped.sql",
      ],
      changedFiles: [
        "db/migrations/0008_energy_burned_logs.sql",
        "db/migrations/0008_energy_burned_logs_retyped.sql",
      ],
    });
    expect(result.ok).toBe(false);
  });

  it("blocks an addition at a version not strictly newer than the newest merged version", () => {
    const result = classifyPrShape({
      baseFiles: CANONICAL_FILES,
      headFiles: [...CANONICAL_FILES, "0009_goals_precision_repair.sql"],
      changedFiles: ["db/migrations/0009_goals_precision_repair.sql"],
    });
    expect(result.ok).toBe(false);
    expect(result.reasons.join(" ")).toMatch(/not strictly newer/i);
    expect(result.reasons.join(" ")).toContain("0009");
    expect(result.additions).toEqual([]);
  });

  it("blocks an old-version backfill addition far below the newest merged version", () => {
    const result = classifyPrShape({
      baseFiles: CANONICAL_FILES,
      headFiles: [...CANONICAL_FILES, "0003_users_timezone_fix.sql"],
      changedFiles: ["db/migrations/0003_users_timezone_fix.sql"],
    });
    expect(result.ok).toBe(false);
    expect(result.additions).toEqual([]);
  });

  it("blocks non-conforming migration file names", () => {
    const result = classifyPrShape({
      baseFiles: CANONICAL_FILES,
      headFiles: [...CANONICAL_FILES, "0010_not_conforming.sql.bak"],
      changedFiles: ["db/migrations/0010_not_conforming.sql.bak"],
    });
    expect(result.ok).toBe(false);
    expect(result.reasons.join(" ")).toContain("000N_name.sql");
  });

  it("blocks duplicate versions in the PR head manifest", () => {
    const result = classifyPrShape({
      baseFiles: CANONICAL_FILES,
      headFiles: [...CANONICAL_FILES, "0010_a.sql", "0010_b.sql"],
      changedFiles: ["0010_a.sql", "0010_b.sql"],
    });
    expect(result.ok).toBe(false);
    expect(result.reasons.join(" ")).toContain("duplicates version 0010");
  });
});

describe("validateMigrationEntries", () => {
  it("normalizes db/migrations-prefixed paths to basenames", () => {
    const { names, reasons } = validateMigrationEntries([
      "db/migrations/0001_init.sql",
      "0002_targets.sql",
      "db/migrations/README.md",
    ]);
    expect(reasons).toHaveLength(1);
    expect(names).toEqual(["0001_init.sql", "0002_targets.sql"]);
  });
});
