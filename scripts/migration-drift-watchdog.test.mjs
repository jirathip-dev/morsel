// Morsel issue #83 — migration drift watchdog unit tests (no database):
// RED probes fire on induced drift, GREEN probe stays silent on clean state.
import { describe, expect, it } from "vitest";
import { driftVerdict } from "./migration-drift-watchdog.mjs";
import { parseMigrationNames } from "./migration-safety.mjs";

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

describe("driftVerdict — GREEN: silent on clean state", () => {
  it("reports no drift when the ledger matches main's manifest exactly", () => {
    const result = driftVerdict({
      ledgerExists: true,
      ledgerNames: canonicalRecorded(),
      unknownLedgerCount: 0,
      local: canonicalLocal(),
    });
    expect(result.drift).toBe(false);
    expect(result.issues).toEqual([]);
  });

  it("reports no drift when the ledger matches and unknownLedgerCount is zero", () => {
    const result = driftVerdict({
      ledgerExists: true,
      ledgerNames: canonicalRecorded().slice(),
      unknownLedgerCount: 0,
      local: canonicalLocal(),
    });
    expect(result.drift).toBe(false);
  });
});

describe("driftVerdict — RED: induced drift fires", () => {
  it("fires when the ledger is missing", () => {
    const result = driftVerdict({
      ledgerExists: false,
      ledgerNames: [],
      unknownLedgerCount: 0,
      local: canonicalLocal(),
    });
    expect(result.drift).toBe(true);
    expect(result.issues.join(" ")).toContain("MISSING");
  });

  it("fires when the live project is BEHIND main (local migration not recorded)", () => {
    const result = driftVerdict({
      ledgerExists: true,
      ledgerNames: canonicalRecorded().filter((name) => name !== "weight_logs"),
      unknownLedgerCount: 0,
      local: canonicalLocal(),
    });
    expect(result.drift).toBe(true);
    expect(result.issues.join(" ")).toContain("0007_weight_logs.sql");
  });

  it("fires when main adds a pending migration the live project never applied", () => {
    const result = driftVerdict({
      ledgerExists: true,
      ledgerNames: canonicalRecorded(),
      unknownLedgerCount: 0,
      local: parseMigrationNames([...CANONICAL_FILES, "0010_food_catalog_seed.sql"]),
    });
    expect(result.drift).toBe(true);
    expect(result.issues.join(" ")).toContain("0010_food_catalog_seed.sql");
  });

  it("fires when the live project is AHEAD of main (unknown ledger entries)", () => {
    const result = driftVerdict({
      ledgerExists: true,
      ledgerNames: canonicalRecorded(),
      unknownLedgerCount: 1,
      local: canonicalLocal(),
    });
    expect(result.drift).toBe(true);
    expect(result.issues.join(" ")).toMatch(/no local migration file/);
  });

  it("aggregates every drift finding into issues", () => {
    const result = driftVerdict({
      ledgerExists: false,
      ledgerNames: [],
      unknownLedgerCount: 3,
      local: parseMigrationNames([...CANONICAL_FILES, "0010_food_catalog_seed.sql"]),
    });
    expect(result.drift).toBe(true);
    expect(result.issues.length).toBeGreaterThanOrEqual(2);
  });
});
