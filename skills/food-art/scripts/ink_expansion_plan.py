#!/usr/bin/env python3
"""Issue 262 subject-list round: deterministic proposal renderer + coverage estimate.

Reads `docs/art/food-library-v2/expansion-262/subjects-proposed.json` (editable
proposal metadata) and, when available, a LOCAL untracked frequency dump of real
logged item names (`.lane-logs/logged-names.json`, produced read-only from
`public.meal_items`). Raw logged names are NEVER written into tracked outputs:
the repository is public, so only aggregate counts and the five names already
published in issue #262/#260 appear in the rendered report.

Commands (repository root):

    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_expansion_plan.py render
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_expansion_plan.py check

`render` writes SUBJECT-LIST.md, coverage.json, alias-proposals-260.json and
SHA256SUMS.json under the expansion directory plus the full row-level mapping
under `.lane-logs/` (untracked). `check` re-renders into a temp dir and fails
(exit 1) on any byte difference or on a proposal that breaks the invariants
(duplicate/colliding IDs, missing fields, alias collisions with the shipped
catalog, non-256 palette claims are not applicable here). Raw exit status is
the only PASS/FAIL signal.
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
import tempfile
from collections import Counter, OrderedDict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LIB = ROOT / "docs" / "art" / "food-library-v2"
EXP = LIB / "expansion-262"
PROPOSAL = EXP / "subjects-proposed.json"
SUBJECTS = LIB / "subjects.json"
CATALOG = LIB / "catalog.json"
LOCAL_NAMES = ROOT / ".lane-logs" / "logged-names.json"
LOCAL_MAPPING = ROOT / ".lane-logs" / "coverage-mapping-full.json"

PUBLISHED_NAMES = [  # already public in issue #262 / #260 — safe to print
    "Americano (black, no sugar, homemade)",
    "Pork with brown gravy (moo ob style)",
    "White rice, cooked (half portion)",
    "Chinese kale, cooked (kana)",
    "Pasta (linguine), cooked",
]
TRACKED = ["SUBJECT-LIST.md", "coverage.json", "alias-proposals-260.json"]
ID_RE = re.compile(r"^[a-z][a-z0-9-]*$")
REQUIRED = ("id", "batch", "category", "name", "aliases", "description", "evidence", "match")


def load(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate(proposal: dict, shipped: dict) -> list[str]:
    errors: list[str] = []
    shipped_ids = {a["id"] for a in shipped["assets"]}
    shipped_aliases = {}
    for a in shipped["assets"]:
        for alias in [a["name"].lower()] + [x.lower() for x in a["aliases"]]:
            shipped_aliases[alias] = a["id"]
    seen_ids: set[str] = set()
    seen_alias: dict[str, str] = {}
    cats = set(proposal["categories"]["existing"]) | set(proposal["categories"]["proposed_new"])
    for ident in proposal["identities"]:
        for key in REQUIRED:
            if key not in ident:
                errors.append(f"{ident.get('id', '?')}: missing {key}")
        iid = ident["id"]
        if not ID_RE.match(iid):
            errors.append(f"{iid}: id must match {ID_RE.pattern}")
        if iid in shipped_ids:
            errors.append(f"{iid}: collides with a shipped catalog ID")
        if iid in seen_ids:
            errors.append(f"{iid}: duplicate id")
        seen_ids.add(iid)
        if ident["category"] not in cats:
            errors.append(f"{iid}: unknown category {ident['category']}")
        if ident["batch"] not in (1, 2, 3, 4, 5):
            errors.append(f"{iid}: batch must be 1..5")
        if not ident["description"].rstrip().endswith("."):
            errors.append(f"{iid}: description must be a sentence")
        for alias in [ident["name"].lower()] + [x.lower() for x in ident["aliases"]]:
            if alias in shipped_aliases:
                errors.append(f"{iid}: alias '{alias}' already belongs to shipped {shipped_aliases[alias]}")
            if alias in seen_alias and seen_alias[alias] != iid:
                errors.append(f"{iid}: alias '{alias}' also proposed on {seen_alias[alias]}")
            seen_alias[alias] = iid
    for fb in proposal["fallbacks_proposed"]:
        if fb["id"] in shipped_ids or fb["category"] not in cats:
            errors.append(f"{fb['id']}: bad fallback")
    return errors


PAREN_RE = re.compile(r"\([^)]*\)")


def compile_rules(proposal: dict):
    """Estimator stages (see `resolver_note` in the proposal):
    composite → head identities (outside parentheses) → earliest-position identity/shipped rule → category → neutral."""
    composite = [re.compile(p, re.I) for p in proposal.get("composite_patterns", [])]
    heads, body = [], []
    for ident in proposal["identities"]:
        for pat in ident["match"]:
            entry = (re.compile(pat, re.I), ident["id"], "specific", ident["batch"])
            (heads if ident.get("head") else body).append(entry)
    for iid, pats in proposal["existing_identity_estimates"].items():
        if iid == "note":
            continue
        for pat in pats:
            body.append((re.compile(pat, re.I), iid, "existing", 0))
    cats = []
    for cat, pats in proposal["category_fallback_estimates"].items():
        if cat == "note":
            continue
        for pat in pats:
            cats.append((re.compile(pat, re.I), f"fallback-{cat}", "category", 0))
    return {"composite": composite, "heads": heads, "body": body, "cats": cats}


def _earliest(name: str, rules):
    best = None
    for order, (rx, target, tier, batch) in enumerate(rules):
        m = rx.search(name)
        if m and (best is None or (m.start(), order) < best[0]):
            best = ((m.start(), order), (target, tier, batch))
    return best[1] if best else None


def resolve(name: str, rules):
    if any(rx.search(name) for rx in rules["composite"]):
        return "fallback-prepared", "category", 0
    hit = _earliest(PAREN_RE.sub(" ", name), rules["heads"])
    if hit:
        return hit
    hit = _earliest(name, rules["body"])
    if hit:
        return hit
    hit = _earliest(name, rules["cats"])
    if hit:
        return hit
    return "fallback-neutral", "neutral", 0


def coverage(proposal: dict, rows: list[dict] | None):
    rules = compile_rules(proposal)
    result: dict = {
        "source": "public.meal_items read-only aggregate; raw names kept local/untracked (public repository)",
        "available": rows is not None,
    }
    if rows is None:
        result["note"] = "no local logged-names dump; coverage not computed"
        return result, []
    mapping = []
    for r in rows:
        target, tier, batch = resolve(r["name"], rules)
        mapping.append({"name": r["name"], "n": r["n"], "target": target, "tier": tier, "batch": batch})
    distinct = len(rows)
    total = sum(r["n"] for r in rows)
    result["distinct_names"] = distinct
    result["total_rows"] = total

    def tally(pred):
        d = sum(1 for m in mapping if pred(m))
        n = sum(m["n"] for m in mapping if pred(m))
        return {"distinct": d, "rows": n, "distinct_pct": round(100 * d / distinct, 1), "rows_pct": round(100 * n / total, 1)}

    result["today_shipped_catalog"] = {
        "specific": tally(lambda m: m["tier"] == "existing"),
        "category_fallback": tally(lambda m: m["tier"] == "category" and m["target"] in {"fallback-produce", "fallback-grains", "fallback-protein", "fallback-drinks"}),
        "neutral_or_missing": tally(lambda m: not (m["tier"] == "existing" or (m["tier"] == "category" and m["target"] in {"fallback-produce", "fallback-grains", "fallback-protein", "fallback-drinks"}))),
    }
    cumulative = OrderedDict()
    for b in (1, 2, 3, 4, 5):
        ok = lambda m, b=b: m["tier"] == "existing" or (m["tier"] == "specific" and m["batch"] <= b)
        cumulative[f"through_batch_{b}"] = {
            "specific": tally(ok),
            "category_fallback": tally(lambda m: m["tier"] == "category"),
            "neutral": tally(lambda m: m["tier"] == "neutral"),
            "specific_pending_later_batch": tally(lambda m, b=b: m["tier"] == "specific" and m["batch"] > b),
        }
    result["cumulative"] = cumulative
    hits = Counter()
    for m in mapping:
        if m["tier"] == "specific":
            hits[m["target"]] += m["n"]
    result["rows_per_proposed_identity"] = OrderedDict(sorted(hits.items(), key=lambda kv: (-kv[1], kv[0])))
    result["neutral_distinct_count"] = sum(1 for m in mapping if m["tier"] == "neutral")
    result["published_names"] = [
        {"name": n, **dict(zip(("target", "tier", "batch"), resolve(n, rules)))} for n in PUBLISHED_NAMES
    ]
    return result, mapping


def render_md(proposal: dict, shipped: dict, cov: dict) -> str:
    ids = proposal["identities"]
    by_batch: dict[int, list] = {b: [] for b in (1, 2, 3, 4, 5)}
    for i in ids:
        by_batch[i["batch"]].append(i)
    L: list[str] = []
    L.append("# Issue 262 · proposed subject list (round 1 — STOP for owner review)")
    L.append("")
    L.append(f"Status: **{proposal['status']}**  ")
    L.append(f"Base: {proposal['base_library']}  ")
    L.append(f"Evidence: {proposal['evidence_window']}")
    L.append("")
    L.append("Nothing in this document is artwork. No source, master, export, catalog or bundled file was created or")
    L.append("modified. The shipped 18 assets are untouched (see `SHA256SUMS.json` → `shipped_catalog_sha256`).")
    L.append("")
    L.append("Grouping: the batch tables below are ordered by production batch (the review unit, ~20–25 identities each);")
    L.append("`category` is a column, and a category-sorted view is derivable from `subjects-proposed.json`. Batch 1")
    L.append("front-loads the rows real logs actually miss; later batches close the ≥100 target with staples.")
    L.append("")
    n_ids = len(ids)
    L.append("## Totals")
    L.append("")
    L.append("| Scope | Count |")
    L.append("|---|---|")
    L.append(f"| Shipped food identities (untouched) | {sum(1 for a in shipped['assets'] if a['kind']=='food')} |")
    for b in (1, 2, 3, 4, 5):
        L.append(f"| Proposed batch {b} — {proposal['batches'][str(b)]} | {len(by_batch[b])} |")
    core = sum(len(by_batch[b]) for b in (1, 2, 3, 4))
    L.append(f"| Proposed identities, batches 1–4 (required for ≥100) | {core} |")
    L.append(f"| Proposed identities incl. batch 5 reserve | {n_ids} |")
    L.append(f"| End state, batches 1–4 + shipped 13 | **{core + 13}** food identities |")
    L.append(f"| Proposed labeled category fallbacks (not counted) | {len(proposal['fallbacks_proposed'])} |")
    L.append("")
    L.append("## Coverage estimate against real logged names")
    L.append("")
    if not cov.get("available"):
        L.append("_Coverage not computed in this render (no local logged-names dump)._")
    else:
        L.append(f"Window: {cov['distinct_names']} distinct names / {cov['total_rows']} rows. The estimate applies a")
        L.append("qualifier-tolerant keyword resolver over the proposal (an approximation of #260 part A, not its contract);")
        L.append("percentages are of distinct names (rows in parentheses). Raw names stay local — the repository is public.")
        L.append("")
        t = cov["today_shipped_catalog"]
        L.append("| State | Specific art | Labeled category | Neutral / missing |")
        L.append("|---|---|---|---|")
        L.append(f"| Today, shipped 18 (qualifier-tolerant) | {t['specific']['distinct_pct']}% ({t['specific']['rows_pct']}%) | {t['category_fallback']['distinct_pct']}% ({t['category_fallback']['rows_pct']}%) | {t['neutral_or_missing']['distinct_pct']}% ({t['neutral_or_missing']['rows_pct']}%) |")
        for b in (1, 2, 3, 4, 5):
            c = cov["cumulative"][f"through_batch_{b}"]
            L.append(f"| After batch {b} (+ proposed fallbacks) | {c['specific']['distinct_pct']}% ({c['specific']['rows_pct']}%) | {c['category_fallback']['distinct_pct']}% ({c['category_fallback']['rows_pct']}%) | {c['neutral']['distinct_pct']}% ({c['neutral']['rows_pct']}%) |")
        L.append("")
        L.append("Named rows from the issue (already public):")
        L.append("")
        L.append("| Logged name | Resolves to | Tier | Batch |")
        L.append("|---|---|---|---|")
        for p in cov["published_names"]:
            L.append(f"| `{p['name']}` | `{p['target']}` | {p['tier']} | {p['batch'] or '—'} |")
        L.append("")
        L.append("Rows per proposed identity (top 15, observed rows in window):")
        L.append("")
        top = list(cov["rows_per_proposed_identity"].items())[:15]
        L.append(", ".join(f"`{k}` {v}" for k, v in top))
    L.append("")
    L.append("## Categories")
    L.append("")
    L.append("Existing: " + ", ".join(f"`{c}`" for c in proposal["categories"]["existing"]) + ".  ")
    L.append("Proposed new: " + "; ".join(f"`{k}` — {v}" for k, v in proposal["categories"]["proposed_new"].items()) + ".  ")
    L.append(proposal["categories"]["note"])
    L.append("")
    L.append("Proposed labeled fallbacks (owner decision, not counted toward 100): " + ", ".join(f"`{f['id']}` ({f['reason']})" for f in proposal["fallbacks_proposed"]) + ".")
    L.append("")
    for b in (1, 2, 3, 4, 5):
        L.append(f"## Batch {b} — {proposal['batches'][str(b)]} ({len(by_batch[b])})")
        L.append("")
        L.append("| # | id | category | name | aliases (incl. Thai) | visual (one line) | evidence |")
        L.append("|---|---|---|---|---|---|---|")
        for k, i in enumerate(by_batch[b], 1):
            aliases = ", ".join(i["aliases"])
            L.append(f"| {k} | `{i['id']}` | {i['category']} | {i['name']} | {aliases} | {i['description']} | {i['evidence']} |")
        L.append("")
    L.append("## Intentionally not illustrated (category fallback or neutral by design)")
    L.append("")
    L.append("| Class | Examples (public/generic) | Resolves to | Why |")
    L.append("|---|---|---|---|")
    for x in proposal["intentionally_not_illustrated"]:
        ex = "; ".join(x["examples"]) or "—"
        L.append(f"| {x['class']} | {ex} | {x['resolves_to']} | {x['why']} |")
    L.append("")
    L.append("## Coordination with #260 (alias vocabulary)")
    L.append("")
    L.append("`alias-proposals-260.json` lists, per proposed identity, the aliases the catalog would carry and the")
    L.append("descriptive-name fragments the matcher must tolerate. Two shipped-asset alias additions are proposed and")
    L.append("recorded there for the orchestrator to sequence (the impl lane must not edit the catalog):")
    L.append("")
    for a in alias_additions_for_shipped():
        L.append(f"- `{a['id']}` + {', '.join('`'+x+'`' for x in a['add_aliases'])} — {a['why']}")
    L.append("")
    L.append("Negative cases preserved: `coffee cake` → proposed `cake` (never `coffee`); mixed/shared plates → `fallback-prepared` or neutral.")
    L.append("")
    L.append("## Production plan (after owner approval of this list)")
    L.append("")
    L.append("Per batch (~20–25 identities): tokenized source SVG per identity (256×256, `<!-- WASH_DEFS -->`, locked palette);")
    L.append("Paper + Night masters; 64/192/512 RGBA exports per theme; `subjects.json` + `catalog.json` entries via")
    L.append("`ink_add.py`; `SHA256SUMS.json` / `build-cache.json` updated; clean rebuild hash proof; shipped-18 byte-identity")
    L.append("proof by hash; Paper/Night contact sheets, labeled phone proofs and the 64 px placement check; then **STOP**")
    L.append("for owner review. Release-gate acceptance set, proof cohorts and library version are re-pinned per batch")
    L.append("(the current gate rejects a 19th entry by design; the batch amends its acceptance set explicitly).")
    L.append("")
    L.append("## Owner decisions requested")
    L.append("")
    L.append("1. Approve / cut / rename identities per batch (batch 5 is reserve).")
    L.append("2. Accept the four new categories (`dairy`, `sweets`, `prepared`, `condiments`) and the five labeled fallbacks.")
    L.append("3. Confirm the `egg` (whole shell) vs `boiled-egg` split and `pasta` as one long-strand study.")
    L.append("4. Confirm batch 1 as the first production batch.")
    L.append("")
    L.append("Reproduce: `PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_expansion_plan.py render` then `check`.")
    L.append("")
    return "\n".join(L)


def alias_additions_for_shipped():
    return [
        {"id": "toast", "add_aliases": ["thick toast", "sourdough-style toast"], "why": "observed thick sourdough-style toast rows; the study depicts a toasted slice"},
        {"id": "vegetable-soup", "add_aliases": ["radish soup", "clear vegetable soup"], "why": "observed 'Radish soup' row; the study is a clear vegetable broth"},
    ]


def alias_proposals(proposal: dict) -> dict:
    return {
        "issue": "#262 → #260 coordination; catalog is owned by the design lane, matcher by the impl lane",
        "principle": "Aliases are whole-term generic names the logging agent actually writes; the matcher strips qualifiers (parentheticals, cooked/steamed/grilled prefixes where the identity already implies them, portions, grams). Never substring-match a longer distinct food.",
        "shipped_alias_additions": alias_additions_for_shipped(),
        "proposed_identities": [
            {"id": i["id"], "category": i["category"], "name": i["name"], "aliases": i["aliases"], "tolerated_fragments": i["match"], "batch": i["batch"]}
            for i in proposal["identities"]
        ],
        "new_category_labels": {k: k.capitalize() for k in proposal["categories"]["proposed_new"]},
        "negative_cases": [
            {"name": "coffee cake", "must_not": "coffee", "expected": "cake (batch 3) else fallback-sweets"},
            {"name": "Isaan shared dishes (1/4 share ...)", "must_not": "any single identity", "expected": "fallback-prepared else fallback-neutral"},
            {"name": "unknown food", "must_not": "any identity", "expected": "fallback-neutral"},
        ],
    }


def render(out: Path) -> dict:
    proposal = load(PROPOSAL)
    shipped = load(SUBJECTS)
    errors = validate(proposal, shipped)
    if errors:
        for e in errors:
            print("INVALID:", e)
        raise SystemExit(1)
    rows = load(LOCAL_NAMES) if LOCAL_NAMES.exists() else None
    cov, mapping = coverage(proposal, rows)
    out.mkdir(parents=True, exist_ok=True)
    (out / "coverage.json").write_text(json.dumps(cov, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (out / "alias-proposals-260.json").write_text(json.dumps(alias_proposals(proposal), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (out / "SUBJECT-LIST.md").write_text(render_md(proposal, shipped, cov) + "\n", encoding="utf-8")
    manifest = OrderedDict()
    manifest["subjects-proposed.json"] = sha(PROPOSAL)
    for name in TRACKED:
        manifest[name] = sha(out / name)
    manifest["shipped_catalog_sha256"] = {"subjects.json": sha(SUBJECTS), "catalog.json": sha(CATALOG), "SHA256SUMS.json": sha(LIB / "SHA256SUMS.json")}
    (out / "SHA256SUMS.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    if mapping and out == EXP:
        LOCAL_MAPPING.parent.mkdir(exist_ok=True)
        LOCAL_MAPPING.write_text(json.dumps(mapping, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    return manifest


def check() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        fresh = render(Path(tmp))
    committed = load(EXP / "SHA256SUMS.json")
    have_local = LOCAL_NAMES.exists()
    # Without the private local dump the coverage-bearing files cannot be regenerated; they are then
    # verified against the committed manifest only (tamper detection), never re-derived.
    regenerable = set(fresh) if have_local else {"subjects-proposed.json", "alias-proposals-260.json", "shipped_catalog_sha256"}
    bad = [k for k in regenerable if fresh[k] != committed.get(k)]
    for k in bad:
        print("DRIFT:", k)
    for name in TRACKED:
        if not (EXP / name).exists():
            print("MISSING:", name)
            bad.append(name)
        elif sha(EXP / name) != committed.get(name):
            print("TAMPERED:", name)
            bad.append(name)
    if not have_local:
        print("NOTE: no local logged-names dump; coverage.json/SUBJECT-LIST.md verified against manifest only")
    # tracked outputs must not leak raw logged names beyond the published five or plain generic names
    if LOCAL_NAMES.exists():
        proposal = load(PROPOSAL)
        generic = {i["name"].lower() for i in proposal["identities"]} | {a.lower() for i in proposal["identities"] for a in i["aliases"]}
        published = set(PUBLISHED_NAMES)
        text = "\n".join((EXP / n).read_text(encoding="utf-8") for n in TRACKED)
        leaked = [
            r["name"] for r in load(LOCAL_NAMES)
            if r["name"] not in published and r["name"].lower() not in generic and len(r["name"]) > 12
            and not any(r["name"] in p for p in published) and r["name"] in text
        ]
        for name in leaked:
            print("LEAK: raw logged name in tracked output")
            bad.append(name)
    print("PASS" if not bad else "FAIL", "expansion-262 subject list")
    return 1 if bad else 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "render"
    if cmd == "render":
        m = render(EXP)
        print(json.dumps(m, indent=2))
    elif cmd == "check":
        raise SystemExit(check())
    else:
        print(__doc__)
        raise SystemExit(2)
