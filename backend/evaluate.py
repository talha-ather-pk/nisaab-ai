"""
Model evaluation for the research questions. Prints a Markdown report.

    python evaluate.py                       # offline test set + database measurements
    python evaluate.py --out eval/report.md  # also save the report
    python evaluate.py --offline-only        # no database needed

RQ1 (classification):
  * Offline: the rule engine on eval/labelled_transactions.csv, a small set constructed for this project
    (not real user data) -> accuracy, per-class precision/recall/F1, macro F1, with bootstrap CIs.
  * Learning replay: every user's saved transactions are replayed in the order they were entered.
    Each entry is classified twice, by the rule engine alone and by rules + personal learning, where
    the personal model may only use transactions saved *before* that entry. Accuracy of both, the
    gain with a user-level bootstrap CI, and an exact McNemar test on the entries where they differ.
  * Correction rate: share of AI-parsed transactions saved without a correction. A usage measure,
    not accuracy: users don't always fix a wrong category.
RQ2 (forecasting):
  * Backtest: for every complete past month with data, project the month-end expense from the first
    PROJECTION_DAY days (the app's own projection) and compare with the actual -> MAE, RMSE, MAPE.

Confidence intervals are 95% percentile bootstraps. Where results come from real users (replay,
backtest), whole users are resampled, because one person's entries are not independent.
"""

from __future__ import annotations

import argparse
import csv
import math
import random
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import Callable, Iterable, Optional, Sequence, TypeVar

from forecasting import HISTORY_MONTHS, LUMPY_CATEGORIES, add_months, days_in_month, month_start, project_month_end
from nlp_engine import extract_entities
from personalization import TRAINING_LIMIT, Example, personal_override

LABELLED_SET = Path(__file__).parent / "eval" / "labelled_transactions.csv"
PROJECTION_DAY = 15
AI_SOURCES = ("text", "voice", "sms")
BOOTSTRAP_SAMPLES = 2000
CONFIDENCE = 0.95

T = TypeVar("T")


# =============================================================================
# Statistics
# =============================================================================

@dataclass
class Interval:
    low: float
    high: float


def bootstrap_ci(units: Sequence[T], statistic: Callable[[list[T]], Optional[float]],
                 samples: int = BOOTSTRAP_SAMPLES, seed: int = 0) -> Optional[Interval]:
    """
    Percentile bootstrap CI of `statistic`, resampling `units` with replacement. A unit is whatever
    is independent: one entry for the synthetic set, one user's list of entries for real data.
    Seeded, so a report is reproducible.
    """
    if len(units) < 2:
        return None
    rng = random.Random(seed)
    n = len(units)
    stats = sorted(s for s in (statistic([units[rng.randrange(n)] for _ in range(n)]) for _ in range(samples))
                   if s is not None)
    if not stats:
        return None
    alpha = 1 - CONFIDENCE
    low = stats[int(alpha / 2 * len(stats))]
    high = stats[min(len(stats) - 1, int((1 - alpha / 2) * len(stats)))]
    return Interval(low, high)


def mcnemar_exact_p(helped: int, hurt: int) -> Optional[float]:
    """Two-sided exact McNemar test: are discordant pairs split 50/50? None if there are none."""
    n = helped + hurt
    if n == 0:
        return None
    k = min(helped, hurt)
    tail = sum(math.comb(n, i) for i in range(k + 1)) / 2 ** n
    return min(1.0, 2 * tail)


def _flatten(groups: Iterable[list[T]]) -> list[T]:
    return [x for g in groups for x in g]


# =============================================================================
# RQ1: offline classification metrics
# =============================================================================

@dataclass
class ClassMetrics:
    label: str
    precision: float
    recall: float
    f1: float
    support: int


@dataclass
class ClassificationReport:
    n: int
    accuracy: float
    macro_f1: float
    type_accuracy: float
    per_class: list[ClassMetrics]
    errors: list[tuple[str, str, str]] = field(default_factory=list)  # (text, gold, predicted)
    accuracy_ci: Optional[Interval] = None
    macro_f1_ci: Optional[Interval] = None
    source: Path = LABELLED_SET
    sha256: Optional[str] = None  # set when the test set is a frozen gold set with a verified checksum


def classification_metrics(gold: list[str], predicted: list[str]) -> tuple[float, float, list[ClassMetrics]]:
    """(accuracy, macro F1, per-class metrics). Macro F1 averages over the gold labels."""
    if not gold:
        return 0.0, 0.0, []
    tp, fp, fn = Counter(), Counter(), Counter()
    for g, p in zip(gold, predicted):
        if g == p:
            tp[g] += 1
        else:
            fp[p] += 1
            fn[g] += 1
    support = Counter(gold)
    rows = []
    for label in sorted(support):
        precision = tp[label] / (tp[label] + fp[label]) if tp[label] + fp[label] else 0.0
        recall = tp[label] / (tp[label] + fn[label]) if tp[label] + fn[label] else 0.0
        f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
        rows.append(ClassMetrics(label, precision, recall, f1, support[label]))
    accuracy = sum(tp.values()) / len(gold)
    macro_f1 = sum(r.f1 for r in rows) / len(rows)
    return accuracy, macro_f1, rows


def evaluate_classifier(path: Path = LABELLED_SET, today: Optional[date] = None,
                        samples: int = BOOTSTRAP_SAMPLES, seed: int = 0) -> ClassificationReport:
    with path.open(encoding="utf-8", newline="") as fh:
        rows = list(csv.DictReader(fh))
    today = today or date.today()
    pairs: list[tuple[str, str]] = []
    type_hits, errors = 0, []
    for row in rows:
        result = extract_entities(row["text"], today=today)
        pairs.append((row["category"], result.category))
        type_hits += result.type == row["type"]
        if result.category != row["category"]:
            errors.append((row["text"], row["category"], result.category))
    gold, predicted = [g for g, _ in pairs], [p for _, p in pairs]
    accuracy, macro_f1, per_class = classification_metrics(gold, predicted)

    def stat(i: int) -> Callable[[list[tuple[str, str]]], float]:
        return lambda sample: classification_metrics([g for g, _ in sample], [p for _, p in sample])[i]

    return ClassificationReport(
        len(rows), accuracy, macro_f1, type_hits / len(rows) if rows else 0.0, per_class, errors,
        accuracy_ci=bootstrap_ci(pairs, stat(0), samples, seed),
        macro_f1_ci=bootstrap_ci(pairs, stat(1), samples, seed),
        source=path,
    )


# =============================================================================
# RQ1: date-order replay of personal learning
# =============================================================================

@dataclass
class ReplayEntry:
    """One saved transaction, in the order it was entered."""
    user_id: int
    text: str
    merchant: Optional[str]
    type: str
    category: str      # the final saved category: the user's label, after any correction
    corrected: bool
    ai_parsed: bool    # entered as text/voice/SMS, i.e. it went through the parser


@dataclass
class ReplayOutcome:
    rules_correct: bool
    personal_correct: bool
    overridden: bool  # the personal model replaced the rule engine's category


@dataclass
class ReplayReport:
    n: int
    users: int
    rules_accuracy: float
    personal_accuracy: float
    overrides: int   # entries where the personal model changed the rule engine's category
    helped: int      # ... from wrong to right
    hurt: int        # ... from right to wrong
    p_value: Optional[float]
    rules_ci: Optional[Interval] = None
    personal_ci: Optional[Interval] = None
    gain_ci: Optional[Interval] = None


def replay_user(entries: list[ReplayEntry], today: date) -> list[ReplayOutcome]:
    """
    Classify each AI-parsed entry with rules only and with rules + personal learning, using only
    the entries saved before it as training data, exactly like the live parser at the time.
    """
    history: list[Example] = []
    outcomes = []
    for e in entries:
        if e.ai_parsed and e.text:
            parsed = extract_entities(e.text, today=today)
            override = personal_override(history[-TRAINING_LIMIT:], parsed.normalized_text, parsed.merchant,
                                         parsed.type, parsed.category)
            personal = override.category if override else parsed.category
            outcomes.append(ReplayOutcome(parsed.category == e.category, personal == e.category, override is not None))
        if e.text or e.merchant:
            history.append(Example(text=e.text, merchant=e.merchant, type=e.type, category=e.category,
                                   corrected=e.corrected))
    return outcomes


def replay_personalization(entries: Iterable[ReplayEntry], today: Optional[date] = None,
                           samples: int = BOOTSTRAP_SAMPLES, seed: int = 0) -> Optional[ReplayReport]:
    """`entries` must be in entry order within each user. None when no AI-parsed entries exist."""
    today = today or date.today()
    per_user: dict[int, list[ReplayEntry]] = defaultdict(list)
    for e in entries:
        per_user[e.user_id].append(e)
    groups = [g for g in (replay_user(es, today) for es in per_user.values()) if g]
    outcomes = _flatten(groups)
    if not outcomes:
        return None

    def accuracy(key: str) -> Callable[[list[list[ReplayOutcome]]], Optional[float]]:
        def stat(sample: list[list[ReplayOutcome]]) -> Optional[float]:
            flat = _flatten(sample)
            return sum(getattr(o, key) for o in flat) / len(flat) if flat else None
        return stat

    def gain(sample: list[list[ReplayOutcome]]) -> Optional[float]:
        flat = _flatten(sample)
        return sum(o.personal_correct - o.rules_correct for o in flat) / len(flat) if flat else None

    helped = sum(o.personal_correct and not o.rules_correct for o in outcomes)
    hurt = sum(o.rules_correct and not o.personal_correct for o in outcomes)
    n = len(outcomes)
    return ReplayReport(
        n=n,
        users=len(groups),
        rules_accuracy=sum(o.rules_correct for o in outcomes) / n,
        personal_accuracy=sum(o.personal_correct for o in outcomes) / n,
        overrides=sum(o.overridden for o in outcomes),
        helped=helped,
        hurt=hurt,
        p_value=mcnemar_exact_p(helped, hurt),
        rules_ci=bootstrap_ci(groups, accuracy("rules_correct"), samples, seed),
        personal_ci=bootstrap_ci(groups, accuracy("personal_correct"), samples, seed),
        gain_ci=bootstrap_ci(groups, gain, samples, seed),
    )


# =============================================================================
# RQ2: forecast backtest
# =============================================================================

@dataclass
class ForecastPoint:
    user_id: int
    month: date
    projected: float
    actual: float


@dataclass
class ForecastErrors:
    n: int
    mae: float
    rmse: float
    mape: Optional[float]  # None when no month had a non-zero actual
    mape_ci: Optional[Interval] = None


def _mape(points: list[ForecastPoint]) -> Optional[float]:
    pct = [abs(p.projected - p.actual) / p.actual for p in points if p.actual > 0]
    return sum(pct) / len(pct) * 100 if pct else None


def forecast_errors(points: Iterable[ForecastPoint], samples: int = BOOTSTRAP_SAMPLES,
                    seed: int = 0) -> ForecastErrors:
    points = list(points)
    if not points:
        return ForecastErrors(0, 0.0, 0.0, None)
    errors = [p.projected - p.actual for p in points]
    mae = sum(abs(e) for e in errors) / len(errors)
    rmse = math.sqrt(sum(e * e for e in errors) / len(errors))
    by_user: dict[int, list[ForecastPoint]] = defaultdict(list)
    for p in points:
        by_user[p.user_id].append(p)
    mape_ci = bootstrap_ci(list(by_user.values()), lambda s: _mape(_flatten(s)), samples, seed)
    return ForecastErrors(len(points), mae, rmse, _mape(points), mape_ci)


def backtest_user(expenses: list[tuple[date, str, float]], before: date, user_id: int = 0) -> list[ForecastPoint]:
    """
    expenses: (transaction_date, category, amount) for one user.
    Replays the app's day-PROJECTION_DAY projection for every complete month before `before`.
    """
    by_month: dict[date, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    early: dict[date, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    for d, category, amount in expenses:
        m = month_start(d)
        by_month[m][category] += amount
        if d.day <= PROJECTION_DAY:
            early[m][category] += amount

    points = []
    for m in sorted(by_month):
        if m >= month_start(before):
            continue
        history = [add_months(m, -i) for i in range(HISTORY_MONTHS, 0, -1)]
        categories = set(by_month[m]) | {c for h in history for c in by_month.get(h, {})}
        projected = 0.0
        for cat in categories:
            past = [by_month[h][cat] for h in history if h in by_month and by_month[h].get(cat, 0) > 0]
            avg = sum(past) / len(past) if past else None
            projected += project_month_end(early[m].get(cat, 0.0), PROJECTION_DAY, days_in_month(m), avg,
                                           lumpy=cat in LUMPY_CATEGORIES)
        points.append(ForecastPoint(user_id, m, round(projected, 2), round(sum(by_month[m].values()), 2)))
    return points


# =============================================================================
# Database-backed measurements
# =============================================================================

def correction_rate(db) -> tuple[int, int]:
    """(AI-parsed transactions, of which corrected by the user)."""
    from sqlalchemy import case, func, select
    from models import Transaction

    total, corrected = db.execute(
        select(func.count(Transaction.id),
               func.coalesce(func.sum(case((Transaction.user_corrected, 1), else_=0)), 0))
        .where(Transaction.source.in_(AI_SOURCES), Transaction.raw_text.is_not(None))
    ).one()
    return int(total), int(corrected)


def load_replay_entries(db) -> list[ReplayEntry]:
    from sqlalchemy import select
    from models import Transaction

    rows = db.execute(
        select(Transaction.user_id, Transaction.raw_text, Transaction.description, Transaction.merchant,
               Transaction.type, Transaction.category, Transaction.user_corrected, Transaction.source)
        .order_by(Transaction.user_id, Transaction.created_at, Transaction.id)
    ).all()
    return [
        ReplayEntry(user_id=uid, text=raw or desc or "", merchant=merchant, type=type_, category=category,
                    corrected=corrected, ai_parsed=source in AI_SOURCES and bool(raw))
        for uid, raw, desc, merchant, type_, category, corrected, source in rows
    ]


def backtest_database(db, today: date) -> list[ForecastPoint]:
    from sqlalchemy import select
    from models import Transaction

    rows = db.execute(
        select(Transaction.user_id, Transaction.transaction_date, Transaction.category, Transaction.amount)
        .where(Transaction.type == "expense")
    ).all()
    per_user: dict[int, list[tuple[date, str, float]]] = defaultdict(list)
    for user_id, d, category, amount in rows:
        per_user[user_id].append((d, category, float(amount)))
    points = []
    for user_id, expenses in per_user.items():
        # Skip each user's first month: it is usually partial (they joined mid-month).
        user_points = backtest_user(expenses, today, user_id)
        points += user_points[1:]
    return points


# =============================================================================
# Report
# =============================================================================

def _pct(x: float) -> str:
    return f"{x * 100:.1f}%"


def _ci(ci: Optional[Interval], fmt: Callable[[float], str]) -> str:
    return "n/a (too few units)" if ci is None else f"{fmt(ci.low)} – {fmt(ci.high)}"


def _signed_pct(x: float) -> str:
    return f"{x * 100:+.1f} pp"


DB_CAVEAT = ("*Database figures describe whatever data is in the database. On the seeded demo database they "
             "are synthetic and only show that the measurement works; report them only after the pilot.*")


def render_report(clf: ClassificationReport, live: Optional[tuple[int, int]],
                  forecast: Optional[ForecastErrors], points: list[ForecastPoint],
                  replay: Optional[ReplayReport] = None) -> str:
    level = f"{CONFIDENCE:.0%}"
    lines = [
        "# Nisaab AI: model evaluation", "",
        f"*Generated {date.today().isoformat()} by `backend/evaluate.py`. "
        f"Intervals are {level} bootstrap confidence intervals.*", "",
        "## RQ1: transaction classification", "",
        "### Offline test set (rule engine)", "",
        (f"`eval/labelled_transactions.csv`: {clf.n} entries constructed and labelled for this project, not "
         "collected from users. It is held out (never used to tune the rules), but it is small and synthetic: "
         "treat it as a sanity check, and replace it with a double-labelled pilot sample for the final results.")
        if clf.sha256 is None else
        (f"`{clf.source.name}`: {clf.n} pilot entries, labelled independently by two annotators with "
         f"disagreements adjudicated, then frozen (sha256 `{clf.sha256[:12]}…`, verified before this run)."), "",
        f"| Metric | Value | {level} CI | Target |", "|---|---|---|---|",
        f"| Category accuracy | {_pct(clf.accuracy)} | {_ci(clf.accuracy_ci, _pct)} | ≥ 80% |",
        f"| Macro F1 | {clf.macro_f1:.3f} | {_ci(clf.macro_f1_ci, lambda v: f'{v:.3f}')} | ≥ 0.80 |",
        f"| Income/expense accuracy | {_pct(clf.type_accuracy)} | — | — |", "",
    ]
    if clf.accuracy_ci and clf.accuracy_ci.low < 0.80 <= clf.accuracy:
        lines += ["The point estimate meets the 80% target, but the interval includes values below it, so this "
                  "set alone cannot show that the target is met.", ""]
    lines += ["| Category | Precision | Recall | F1 | Support |", "|---|---|---|---|---|"]
    lines += [f"| {r.label} | {r.precision:.2f} | {r.recall:.2f} | {r.f1:.2f} | {r.support} |" for r in clf.per_class]
    if clf.errors:
        lines += ["", f"Misclassified ({len(clf.errors)}):", "", "| Text | Expected | Predicted |", "|---|---|---|"]
        lines += [f"| {t} | {g} | {p} |" for t, g, p in clf.errors]

    if replay is not None or live is not None:
        lines += ["", "### Learning from corrections (date-order replay)", "", DB_CAVEAT, ""]
    if replay is not None:
        p = "n/a" if replay.p_value is None else (f"{replay.p_value:.4f}" if replay.p_value >= 0.0001 else "< 0.0001")
        lines += [
            "Each user's AI-parsed transactions are replayed in the order they were entered. The personal model "
            "only sees transactions saved before the one being classified. The label is the category the user "
            "finally saved; entries the user never corrected keep the rule engine's original guess as their "
            "label, which favours the rules, so the measured gain is conservative.", "",
            f"| | Accuracy | {level} CI |", "|---|---|---|",
            f"| Rules only | {_pct(replay.rules_accuracy)} | {_ci(replay.rules_ci, _pct)} |",
            f"| Rules + personal learning | {_pct(replay.personal_accuracy)} | {_ci(replay.personal_ci, _pct)} |",
            f"| Gain | {_signed_pct(replay.personal_accuracy - replay.rules_accuracy)} | "
            f"{_ci(replay.gain_ci, _signed_pct)} |", "",
            f"{replay.n} entries from {replay.users} user(s). The personal model replaced the rule engine's "
            f"category on {replay.overrides}: **{replay.helped} wrong → right, {replay.hurt} right → wrong**, "
            f"{replay.overrides - replay.helped - replay.hurt} wrong → still wrong (exact McNemar p = {p}).",
        ]
    if live is not None:
        total, corrected = live
        accepted = (total - corrected) / total if total else 0.0
        lines += ["", f"**Correction rate (usage measure):** {total} AI-parsed transactions, {corrected} corrected: "
                  f"{_pct(accepted)} saved without a correction (target ≥ 80%). This is not accuracy: users "
                  "don't always fix a wrong category."]

    if forecast is not None:
        mape = "n/a" if forecast.mape is None else f"{forecast.mape:.1f}%"
        lines += ["", "## RQ2: expense forecasting", "", DB_CAVEAT, "",
                  f"Backtest: the month-end expense projected on day {PROJECTION_DAY} versus the actual total, "
                  f"for every complete past month (each user's first, partial month is skipped).", "",
                  f"| Metric | Value | {level} CI | Target |", "|---|---|---|---|",
                  f"| Months evaluated | {forecast.n} | — | — |",
                  f"| MAE | Rs {forecast.mae:,.0f} | — | — |",
                  f"| RMSE | Rs {forecast.rmse:,.0f} | — | — |",
                  f"| MAPE | {mape} | {_ci(forecast.mape_ci, lambda v: f'{v:.1f}%')} | ≤ 20% |"]
        if points:
            lines += ["", "| User | Month | Projected | Actual | Error |", "|---|---|---|---|---|"]
            lines += [f"| {p.user_id} | {p.month:%Y-%m} | {p.projected:,.0f} | {p.actual:,.0f} | "
                      f"{(p.projected - p.actual) / p.actual * 100 if p.actual else 0:+.1f}% |" for p in points[:24]]
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, help="also write the report to this file")
    parser.add_argument("--offline-only", action="store_true", help="skip the database measurements")
    parser.add_argument("--bootstrap", type=int, default=BOOTSTRAP_SAMPLES, help="bootstrap resamples")
    parser.add_argument("--seed", type=int, default=0, help="bootstrap random seed")
    parser.add_argument("--test-set", type=Path, default=LABELLED_SET,
                        help="labelled CSV (text,type,category); a frozen pilot set must have its .sha256 file")
    args = parser.parse_args()

    sha = None
    if args.test_set != LABELLED_SET:
        from labelling import verify_checksum
        sha = verify_checksum(args.test_set)
        if sha is None:
            raise SystemExit(f"{args.test_set} has no .sha256 file; freeze it with labelling.py first.")
    clf = evaluate_classifier(args.test_set, samples=args.bootstrap, seed=args.seed)
    clf.sha256 = sha
    live = forecast = replay = None
    points: list[ForecastPoint] = []
    if not args.offline_only:
        from config import get_settings
        from database import SessionLocal

        today = get_settings().today()
        with SessionLocal() as db:
            live = correction_rate(db)
            replay = replay_personalization(load_replay_entries(db), today, args.bootstrap, args.seed)
            points = backtest_database(db, today)
            forecast = forecast_errors(points, args.bootstrap, args.seed)

    report = render_report(clf, live, forecast, points, replay)
    print(report)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(report, encoding="utf-8")


if __name__ == "__main__":
    main()
