// infra/supabase/config.test.mjs — unit tests for the Supabase config-as-code
// payloads and the pure drift/overlay logic (issue #78). No network, no live
// project, no real secret values: everything here runs on the committed
// config.json / secrets.json and synthetic in-memory objects.
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  driftEntries,
  loadCanonical,
  overlayForApply,
  validateCanonical,
} from "./config.mjs";
import {
  loadMapping,
  parseStoreLines,
  resolveMapping,
  validateMapping,
} from "./secrets.mjs";

const CANONICAL = loadCanonical();
const MAPPING = loadMapping();

function liveLike() {
  return {
    smtp_host: "smtp.resend.com",
    smtp_port: 465,
    smtp_user: "resend",
    smtp_admin_email: "onboarding@resend.dev",
    smtp_sender_name: "Morsel",
    mailer_otp_length: 6,
    rate_limit_email_sent: 30,
    mailer_subjects_magic_link: "Your Morsel sign-in code",
    mailer_templates_magic_link_content:
      "<h2>Your Morsel sign-in code</h2><p>{{ .Token }}</p>",
    smtp_pass: "live-smtp-pass",
  };
}

describe("infra/supabase/config.json (canonical config-as-code)", () => {
  it("parses and pins the live-stack values from the issue inventory", () => {
    expect(CANONICAL.pinned.smtp_host).toBe("smtp.resend.com");
    expect(CANONICAL.pinned.smtp_port).toBe(465);
    expect(CANONICAL.pinned.smtp_user).toBe("resend");
    expect(CANONICAL.pinned.smtp_admin_email).toBe("onboarding@resend.dev");
    expect(CANONICAL.pinned.smtp_sender_name).toBe("Morsel");
    expect(CANONICAL.pinned.mailer_otp_length).toBe(6);
    expect(CANONICAL.pinned.rate_limit_email_sent).toBe(30);
    expect(CANONICAL.pinned.mailer_subjects_magic_link).toBe("Your Morsel sign-in code");
  });

  it("pins the magic-link template invariant to {{ .Token }}", () => {
    expect(CANONICAL.templateInvariant).toEqual({
      field: "mailer_templates_magic_link_content",
      contains: "{{ .Token }}",
    });
  });

  it("never carries secret-bearing keys (no smtp_pass anywhere)", () => {
    const text = readFileSync(new URL("./config.json", import.meta.url), "utf8");
    // The neverInConfig guard list names "smtp_pass" by design, so the
    // structural checks below (not raw text) are the real no-secret guard:
    // the key must never appear as a pinned/declared config property.
    expect(text).not.toMatch(/"value"\s*:/);
    const keys = new Set();
    const walk = (node) => {
      if (node && typeof node === "object") {
        for (const [key, value] of Object.entries(node)) {
          keys.add(key);
          walk(value);
        }
      }
    };
    walk(CANONICAL);
    expect(keys.has("smtp_pass")).toBe(false);
    expect(keys.has("value")).toBe(false);
    expect(validateCanonical(CANONICAL)).toEqual([]);
  });
});

describe("validateCanonical", () => {
  it("rejects a canonical file that pins a secret key", () => {
    const bad = {
      pinned: { smtp_pass: "hunter2" },
      templateInvariant: { field: "f", contains: "x" },
      neverInConfig: ["smtp_pass"],
    };
    expect(validateCanonical(bad)).toContain('canonical config must not pin secret key "smtp_pass"');
  });
});

describe("driftEntries (read-back asserts)", () => {
  it("returns no entries when the live config matches the canonical file", () => {
    expect(driftEntries(CANONICAL, liveLike())).toEqual([]);
  });

  it("flags every drifted pinned key and the template invariant", () => {
    const drifted = liveLike();
    drifted.smtp_host = "smtp.example.com";
    drifted.smtp_user = "other";
    drifted.mailer_otp_length = 4;
    drifted.rate_limit_email_sent = 10;
    drifted.mailer_templates_magic_link_content = "<p>no token here</p>";
    const entries = driftEntries(CANONICAL, drifted);
    expect(entries).toContain("smtp_host: expected \"smtp.resend.com\", live \"smtp.example.com\"");
    expect(entries).toContain("smtp_user: expected \"resend\", live \"other\"");
    expect(entries).toContain("mailer_otp_length: expected 6, live 4");
    expect(entries).toContain("rate_limit_email_sent: expected 30, live 10");
    expect(entries).toContain(
      "mailer_templates_magic_link_content: expected to contain \"{{ .Token }}\"",
    );
  });

  it("compares numerically-typed API values by string so 6 vs \"6\" never drifts", () => {
    const live = liveLike();
    live.mailer_otp_length = "6";
    live.rate_limit_email_sent = "30";
    live.smtp_port = "465";
    expect(driftEntries(CANONICAL, live)).toEqual([]);
  });

  it("never compares smtp_pass (secret values are not drift-checkable)", () => {
    const live = liveLike();
    live.smtp_pass = "rotated-secret";
    expect(driftEntries(CANONICAL, live)).toEqual([]);
  });
});

describe("overlayForApply", () => {
  it("overlays pinned keys onto live and preserves untouched keys", () => {
    const live = liveLike();
    live.external_extra = "kept";
    const overlay = overlayForApply(CANONICAL, live, "env-pass");
    expect(overlay.external_extra).toBe("kept");
    expect(overlay.smtp_host).toBe("smtp.resend.com");
    expect(overlay.mailer_otp_length).toBe(6);
    expect(overlay.smtp_pass).toBe("env-pass");
  });

  it("prefers the env password and never blanks it when env is absent", () => {
    const live = liveLike();
    const overlay = overlayForApply(CANONICAL, live, undefined);
    expect(overlay.smtp_pass).toBe("live-smtp-pass");
  });

  it("returns null when no SMTP password exists anywhere (refuse-to-blank)", () => {
    const live = liveLike();
    delete live.smtp_pass;
    expect(overlayForApply(CANONICAL, live, undefined)).toBeNull();
    expect(overlayForApply(CANONICAL, live, "")).toBeNull();
  });
});

describe("infra/supabase/secrets.json (name-only mapping)", () => {
  it("maps the canonical Supabase secret names to local-store names", () => {
    expect(validateMapping(MAPPING)).toEqual([]);
    const targets = MAPPING.secrets.map((entry) => entry.target);
    expect(targets).toEqual([
      "SUPABASE_URL",
      "SUPABASE_ANON_KEY",
      "MORSEL_OAUTH_SIGNING_KEY",
    ]);
  });

  it("never contains literal secret values", () => {
    const text = readFileSync(new URL("./secrets.json", import.meta.url), "utf8");
    expect(text).not.toMatch(/"value"\s*:/);
    expect(text).not.toMatch(/"pass"\s*:/i);
  });

  it("excludes the endpoint secret the repo policy never sets", () => {
    const targets = MAPPING.secrets.map((entry) => entry.target);
    expect(MAPPING.excludedByName).toContain("MORSEL_OAUTH_AUTHORIZATION_ENDPOINT");
    expect(targets).not.toContain("MORSEL_OAUTH_AUTHORIZATION_ENDPOINT");
  });
});

describe("secret store parsing + resolution", () => {
  it("parses export lines, stripping outer quotes", () => {
    const store = parseStoreLines(
      [
        'export SUPABASE_URL_MORSEL="https://abc.supabase.co"',
        "export SUPABASE_ANON_KEY_MORSEL=plain-value",
        "export MORSEL_OAUTH_SIGNING_KEY='quoted-value'",
        "export EMPTY_VAL=",
        "not-an-export",
        "",
      ].join("\n"),
    );
    expect(store.get("SUPABASE_URL_MORSEL")).toBe("https://abc.supabase.co");
    expect(store.get("SUPABASE_ANON_KEY_MORSEL")).toBe("plain-value");
    expect(store.get("MORSEL_OAUTH_SIGNING_KEY")).toBe("quoted-value");
    expect(store.has("EMPTY_VAL")).toBe(false);
    expect(store.has("not-an-export")).toBe(false);
  });

  it("resolves only names present in the store and lists the missing", () => {
    const store = new Map([
      ["SUPABASE_URL_MORSEL", "https://abc.supabase.co"],
      ["SUPABASE_ANON_KEY_MORSEL", "anon"],
    ]);
    const { payload, missing } = resolveMapping(MAPPING, store);
    expect(missing).toEqual(["MORSEL_OAUTH_SIGNING_KEY"]);
    expect(payload.map((entry) => entry.name)).toEqual(["SUPABASE_URL", "SUPABASE_ANON_KEY"]);
    expect(payload.every((entry) => typeof entry.value === "string")).toBe(true);
  });
});
