"""
Dual labelling of the pilot sample and inter-annotator agreement (RQ1 gold standard).

    # 1. Blind sheets for both annotators (text only: no model or user category)
    python labelling.py sheets eval/pilot/calibration.csv --round calibration
    python labelling.py sheets eval/pilot/sample.csv --round main

    # 2. Each annotator fills the `category` column of their own sheet, independently.

    # 3. Agreement: Cohen's kappa with a bootstrap CI, per-category agreement, and a
    #    disagreements file for adjudication
    python labelling.py agreement eval/pilot/annotator_A_main.csv eval/pilot/annotator_B_main.csv

    # 4. After filling final_category for every disagreement: freeze the gold set + checksum
    python labelling.py freeze eval/pilot/annotator_A_main.csv eval/pilot/annotator_B_main.csv \\
        --adjudicated eval/pilot/disagreements_main.csv --sample eval/pilot/sample.csv

The calibration round is for agreeing on the guidelines (LABELLING_GUIDE.md): discuss its
disagreements, refine the guide, and never put calibration items in the test set.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import random
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from evaluate import Interval, bootstrap_ci
from nlp_engine import CATEGORIES, EXPENSE_CATEGORIES, INCOME_CATEGORIES

KAPPA_TARGET = 0.80
SHEET_FIELDS = ["item_id", "text", "category", "notes"]
DISAGREEMENT_FIELDS = ["item_id", "text", "label_a", "label_b", "notes_a", "notes_b", "final_category", "reason"]
_BY_LOWER = {c.lower(): c for c in CATEGORIES}

GUIDE = """# Nisaab AI labelling guide

Label each entry with the **one** category that best describes what the money was for, from the
person's point of view. Work alone, and don't look at the other annotator's sheet or any model output.

## Categories

{categories}

## Decision rules (draft: refine these after the calibration round)

1. **Purpose over payment channel.** "Paid electricity bill via JazzCash" is Utilities, not Transfers.
   Use Transfers only when money moves to a person or account and the purpose is unknown, or the purpose
   is the transfer itself (family support, committee, moving money to savings).
2. **Merchant decides when the text is otherwise empty.** "Careem 400" is Transport; "Imtiaz 2500" is Groceries.
3. **Eating out vs. food shopping.** Prepared food (restaurant, delivery, chai, snacks) is Food & Dining;
   ingredients and household supplies are Groceries.
4. **Income:** Salary for employment pay (including bonus and stipend); Freelance for client or platform
   payments; Transfers for money from family or friends; Other for anything else.
5. **Paying someone's wages** (maid, driver, guard) is Other, not Salary.
6. **Gym and fitness** are Health. **Courses and subscriptions for learning** are Education;
   **entertainment subscriptions** (Netflix, Spotify, YouTube Premium) are Entertainment.
7. **Use Other only** when no category fits. Don't use it for "not sure": write the doubt in `notes`.
8. **[PHONE], [NAME], [ACCOUNT] and similar** replace removed personal details. Ignore them.

Record every rule you add after calibration here, with the date, so the gold set is reproducible.
"""


# =============================================================================
# Agreement statistics
# =============================================================================

def cohen_kappa(a: list[str], b: list[str]) -> float:
    """Cohen's kappa for two annotators over the same items. 1.0 when both use one identical label."""
    n = len(a)
    if n == 0:
        raise ValueError("no items")
    po = sum(x == y for x, y in zip(a, b)) / n
    ca, cb = Counter(a), Counter(b)
    pe = sum(ca[k] * cb[k] for k in ca) / (n * n)
    if pe == 1:
        return 1.0
    return (po - pe) / (1 - pe)


def interpret_kappa(k: float) -> str:
    """Landis & Koch (1977) bands."""
    for limit, label in ((0.0, "poor"), (0.20, "slight"), (0.40, "fair"), (0.60, "moderate"),
                         (0.80, "substantial")):
        if k <= limit:
            return label
    return "almost perfect"


@dataclass
class CategoryAgreement:
    category: str
    count_a: int
    count_b: int
    both: int
    specific_agreement: Optional[float]  # 2·both / (count_a + count_b)
    kappa: Optional[float]               # this category vs. all others


@dataclass
class AgreementReport:
    n: int
    observed: float
    expected: float
    kappa: float
    kappa_ci: Optional[Interval]
    per_category: list[CategoryAgreement]
    confusions: list[tuple[str, str, int]]  # (label, label, count), unordered pairs


def agreement_report(a: list[str], b: list[str], samples: int = 2000, seed: int = 0) -> AgreementReport:
    n = len(a)
    ca, cb = Counter(a), Counter(b)
    observed = sum(x == y for x, y in zip(a, b)) / n
    expected = sum(ca[k] * cb[k] for k in ca) / (n * n)
    pairs = list(zip(a, b))
    ci = bootstrap_ci(pairs, lambda s: cohen_kappa([x for x, _ in s], [y for _, y in s]), samples, seed)

    per_category = []
    for cat in sorted(set(a) | set(b)):
        both = sum(x == y == cat for x, y in pairs)
        binary_a = [x == cat for x in a]
        binary_b = [y == cat for y in b]
        varies = len(set(binary_a) | set(binary_b)) > 1
        per_category.append(CategoryAgreement(
            cat, ca[cat], cb[cat], both,
            2 * both / (ca[cat] + cb[cat]) if ca[cat] + cb[cat] else None,
            cohen_kappa([str(x) for x in binary_a], [str(y) for y in binary_b]) if varies else None,
        ))
    confusions = Counter(tuple(sorted((x, y))) for x, y in pairs if x != y)
    return AgreementReport(n, observed, expected, cohen_kappa(a, b), ci, per_category,
                           [(x, y, c) for (x, y), c in confusions.most_common()])


# =============================================================================
# Files
# =============================================================================

def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8-sig", newline="") as fh:  # -sig: sheets saved from Excel carry a BOM
        return list(csv.DictReader(fh))


def write_csv(path: Path, fields: list[str], rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def normalise_label(value: str) -> Optional[str]:
    return _BY_LOWER.get((value or "").strip().lower())


def read_labels(path: Path) -> dict[str, dict[str, str]]:
    """item_id -> row, with a validated category. Exits listing every problem at once."""
    rows = read_csv(path)
    problems, out = [], {}
    for r in rows:
        label = normalise_label(r.get("category", ""))
        if label is None:
            problems.append(f"  {r.get('item_id')}: {r.get('category')!r}")
        else:
            out[r["item_id"]] = {**r, "category": label}
    if problems:
        raise SystemExit(f"{path}: {len(problems)} missing or invalid categories (valid: {', '.join(CATEGORIES)}):\n"
                         + "\n".join(problems[:30]))
    return out


def aligned(path_a: Path, path_b: Path) -> tuple[list[str], dict, dict]:
    a, b = read_labels(path_a), read_labels(path_b)
    if set(a) != set(b):
        only_a, only_b = sorted(set(a) - set(b)), sorted(set(b) - set(a))
        raise SystemExit(f"The sheets cover different items. Only in A: {only_a[:10]} Only in B: {only_b[:10]}")
    return sorted(a), a, b


def sha256_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


# =============================================================================
# Commands
# =============================================================================

def make_sheets(sample_path: Path, round_name: str, out_dir: Path, seed: int = 0) -> list[Path]:
    rows = read_csv(sample_path)
    unreviewed = [r["item_id"] for r in rows if r.get("reviewed", "").strip().lower() not in ("yes", "n/a")]
    if unreviewed:
        raise SystemExit(f"{len(unreviewed)} row(s) in {sample_path} may contain a personal name and are not "
                         f"reviewed yet: {unreviewed[:15]}. Replace names with [NAME] and set reviewed=yes.")
    paths = []
    for annotator, offset in (("A", 1), ("B", 2)):
        order = rows[:]
        random.Random(seed * 10 + offset).shuffle(order)  # each annotator sees a different order
        path = out_dir / f"annotator_{annotator}_{round_name}.csv"
        if path.exists():
            raise SystemExit(f"{path} already exists; it may hold labels. Move it away first.")
        write_csv(path, SHEET_FIELDS, [{"item_id": r["item_id"], "text": r["masked_text"], "category": "",
                                         "notes": ""} for r in order])
        paths.append(path)
    guide = out_dir / "LABELLING_GUIDE.md"
    if not guide.exists():
        guide.write_text(GUIDE.format(categories="\n".join(f"- {c}" for c in CATEGORIES)), encoding="utf-8")
    return paths


def render_agreement(report: AgreementReport, round_name: str, target: float = KAPPA_TARGET) -> str:
    ci = "n/a" if report.kappa_ci is None else f"{report.kappa_ci.low:.3f} – {report.kappa_ci.high:.3f}"
    if report.kappa < target:
        verdict = (f"**Below the {target:.2f} target.** Discuss the disagreements below, refine "
                   "LABELLING_GUIDE.md, and re-label (on new items if this was the main round).")
    elif report.kappa_ci and report.kappa_ci.low < target:
        verdict = (f"**Meets the {target:.2f} target**, but the interval's lower end is below it; report the "
                   "interval alongside κ.")
    else:
        verdict = f"**Meets the {target:.2f} target**, including the whole confidence interval."
    lines = [
        f"# Inter-annotator agreement: {round_name} round", "",
        f"*{report.n} items, generated {datetime.now(timezone.utc):%Y-%m-%d %H:%M} UTC.*", "",
        "| Measure | Value |", "|---|---|",
        f"| Observed agreement | {report.observed:.1%} |",
        f"| Chance agreement | {report.expected:.1%} |",
        f"| Cohen's κ | **{report.kappa:.3f}** ({interpret_kappa(report.kappa)}) |",
        f"| 95% bootstrap CI | {ci} |", "",
        verdict, "",
        "| Category | A | B | Both | Specific agreement | κ (vs. rest) |", "|---|---|---|---|---|---|",
    ]
    for c in report.per_category:
        sa = "—" if c.specific_agreement is None else f"{c.specific_agreement:.2f}"
        k = "—" if c.kappa is None else f"{c.kappa:.2f}"
        lines.append(f"| {c.category} | {c.count_a} | {c.count_b} | {c.both} | {sa} | {k} |")
    if report.confusions:
        lines += ["", "Most frequent disagreements:", "", "| Labels | Items |", "|---|---|"]
        lines += [f"| {x} ↔ {y} | {n} |" for x, y, n in report.confusions[:10]]
    return "\n".join(lines) + "\n"


def run_agreement(path_a: Path, path_b: Path, round_name: str, out_dir: Path,
                  samples: int = 2000, seed: int = 0) -> AgreementReport:
    ids, a, b = aligned(path_a, path_b)
    report = agreement_report([a[i]["category"] for i in ids], [b[i]["category"] for i in ids], samples, seed)
    text = render_agreement(report, round_name)
    (out_dir / f"agreement_{round_name}.md").write_text(text, encoding="utf-8")
    disagreements = [
        {"item_id": i, "text": a[i].get("text", ""), "label_a": a[i]["category"], "label_b": b[i]["category"],
         "notes_a": a[i].get("notes", ""), "notes_b": b[i].get("notes", ""), "final_category": "", "reason": ""}
        for i in ids if a[i]["category"] != b[i]["category"]
    ]
    dis_path = out_dir / f"disagreements_{round_name}.csv"
    if dis_path.exists():
        raise SystemExit(f"{dis_path} already exists and may hold adjudications. Move it away first.")
    write_csv(dis_path, DISAGREEMENT_FIELDS, disagreements)
    print(text)
    print(f"{len(disagreements)} disagreement(s) written to {dis_path} for adjudication.")
    return report


def gold_type(category: str, saved_type: str) -> str:
    """Salary/Freelance are income, spending categories are expenses; Transfers/Other keep the saved type."""
    if category in INCOME_CATEGORIES and category not in EXPENSE_CATEGORIES:
        return "income"
    if category in EXPENSE_CATEGORIES and category not in INCOME_CATEGORIES:
        return "expense"
    return saved_type if saved_type in ("income", "expense") else "expense"


def freeze(path_a: Path, path_b: Path, adjudicated: Path, sample: Path, out: Path,
           samples: int = 2000, seed: int = 0) -> dict:
    if out.exists():
        raise SystemExit(f"{out} is frozen already. A new gold set needs a new version (e.g. pilot_test_v2.csv).")
    ids, a, b = aligned(path_a, path_b)
    sample_rows = {r["item_id"]: r for r in read_csv(sample)}
    calibration = [i for i in ids if i.startswith("C") or i not in sample_rows]
    if calibration:
        raise SystemExit(f"Items not in {sample.name} (calibration items can't enter the test set): {calibration[:10]}")

    final = {r["item_id"]: normalise_label(r.get("final_category", "")) for r in read_csv(adjudicated)}
    pending = [i for i in ids if a[i]["category"] != b[i]["category"] and not final.get(i)]
    if pending:
        raise SystemExit(f"{len(pending)} disagreement(s) have no valid final_category yet: {pending[:15]}")

    gold_rows = []
    for i in ids:
        label = a[i]["category"] if a[i]["category"] == b[i]["category"] else final[i]
        s = sample_rows[i]
        gold_rows.append({"item_id": i, "text": s["masked_text"], "type": gold_type(label, s.get("type", "")),
                          "category": label})
    write_csv(out, ["item_id", "text", "type", "category"], gold_rows)

    report = agreement_report([a[i]["category"] for i in ids], [b[i]["category"] for i in ids], samples, seed)
    digest = sha256_of(out)
    out.with_name(out.name + ".sha256").write_text(f"{digest}  {out.name}\n", encoding="utf-8")
    manifest = {
        "file": out.name, "sha256": digest, "items": len(ids),
        "agreed": sum(a[i]["category"] == b[i]["category"] for i in ids),
        "adjudicated": sum(a[i]["category"] != b[i]["category"] for i in ids),
        "kappa": round(report.kappa, 4),
        "kappa_ci": None if report.kappa_ci is None else [round(report.kappa_ci.low, 4), round(report.kappa_ci.high, 4)],
        "by_category": dict(Counter(r["category"] for r in gold_rows).most_common()),
        "frozen_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    out.with_suffix(".json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return manifest


def verify_checksum(path: Path) -> Optional[str]:
    """The recorded digest if the file is intact, None if there is no checksum file; exits on mismatch."""
    checksum = path.with_name(path.name + ".sha256")
    if not checksum.exists():
        return None
    expected = checksum.read_text(encoding="utf-8").split()[0]
    actual = sha256_of(path)
    if actual != expected:
        raise SystemExit(f"{path} has changed since it was frozen (sha256 {actual[:12]}… ≠ {expected[:12]}…). "
                         "A frozen test set must not be edited; freeze a new version instead.")
    return expected


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("sheets", help="make blind annotation sheets for annotators A and B")
    p.add_argument("sample", type=Path)
    p.add_argument("--round", default="main", choices=["calibration", "main"])
    p.add_argument("--out-dir", type=Path)
    p.add_argument("--seed", type=int, default=0)

    p = sub.add_parser("agreement", help="Cohen's kappa + disagreements file")
    p.add_argument("sheet_a", type=Path)
    p.add_argument("sheet_b", type=Path)
    p.add_argument("--round", default="main", choices=["calibration", "main"])
    p.add_argument("--out-dir", type=Path)
    p.add_argument("--bootstrap", type=int, default=2000)
    p.add_argument("--seed", type=int, default=0)

    p = sub.add_parser("freeze", help="write the frozen gold set with a checksum")
    p.add_argument("sheet_a", type=Path)
    p.add_argument("sheet_b", type=Path)
    p.add_argument("--adjudicated", type=Path, required=True)
    p.add_argument("--sample", type=Path, required=True)
    p.add_argument("--out", type=Path, default=Path(__file__).parent / "eval" / "pilot" / "pilot_test_v1.csv")
    args = parser.parse_args()

    if args.command == "sheets":
        for path in make_sheets(args.sample, args.round, args.out_dir or args.sample.parent, args.seed):
            print(f"wrote {path}")
    elif args.command == "agreement":
        run_agreement(args.sheet_a, args.sheet_b, args.round, args.out_dir or args.sheet_a.parent,
                      args.bootstrap, args.seed)
    else:
        manifest = freeze(args.sheet_a, args.sheet_b, args.adjudicated, args.sample, args.out)
        print(json.dumps(manifest, indent=2))
        print(f"\nFrozen. Evaluate with: python evaluate.py --test-set {args.out}")


if __name__ == "__main__":
    main()
