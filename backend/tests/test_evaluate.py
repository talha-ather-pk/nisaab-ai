"""Evaluation maths (RQ1/RQ2) and a regression guard on the labelled test set."""

from datetime import date

import pytest

from evaluate import (ForecastPoint, Interval, ReplayEntry, backtest_user, bootstrap_ci, classification_metrics,
                      evaluate_classifier, forecast_errors, mcnemar_exact_p, render_report, replay_personalization,
                      replay_user)


def test_classification_metrics():
    gold = ["Food", "Food", "Fuel", "Rent"]
    pred = ["Food", "Fuel", "Fuel", "Rent"]
    accuracy, macro_f1, rows = classification_metrics(gold, pred)
    assert accuracy == 0.75
    by = {r.label: r for r in rows}
    assert by["Food"].precision == 1.0 and by["Food"].recall == 0.5
    assert by["Fuel"].precision == 0.5 and by["Fuel"].recall == 1.0
    assert macro_f1 == pytest.approx((2 / 3 + 2 / 3 + 1.0) / 3)


def test_forecast_errors():
    pts = [ForecastPoint(1, date(2026, 8, 1), 110, 100), ForecastPoint(1, date(2026, 9, 1), 80, 100)]
    e = forecast_errors(pts)
    assert e.n == 2 and e.mae == 15 and e.rmse == pytest.approx((250) ** 0.5) and e.mape == pytest.approx(15)
    assert forecast_errors([]).mape is None


def test_backtest_steady_spender_is_exact():
    # Rs 100 every day: the day-15 projection should match the actual (within month-length effects).
    expenses = [(date(2026, m, d), "Groceries", 100.0)
                for m in (7, 8, 9) for d in range(1, 32) if (m, d) not in ((9, 31),)]
    points = backtest_user(expenses, before=date(2026, 10, 5))
    assert [p.month for p in points] == [date(2026, 7, 1), date(2026, 8, 1), date(2026, 9, 1)]
    assert all(p.projected == pytest.approx(p.actual, rel=0.02) for p in points)


def test_backtest_ignores_current_month():
    points = backtest_user([(date(2026, 10, 2), "Fuel", 500.0)], before=date(2026, 10, 20))
    assert points == []


def test_labelled_set_meets_rq1_target():
    report = evaluate_classifier(today=date(2026, 10, 19))
    assert report.n >= 100
    # Guards against regressions in nlp_engine; the set is held out, so never tune rules on it.
    assert report.accuracy >= 0.80 and report.macro_f1 >= 0.80
    assert "RQ1" in render_report(report, None, None, [])


# --- statistics -------------------------------------------------------------------------------

def test_mcnemar_exact_p():
    assert mcnemar_exact_p(10, 0) == pytest.approx(2 / 1024)
    assert mcnemar_exact_p(5, 5) == 1.0
    assert mcnemar_exact_p(0, 0) is None


def test_bootstrap_ci_is_reproducible_and_sane():
    mean = lambda xs: sum(xs) / len(xs)
    assert bootstrap_ci([1.0, 1.0, 1.0], mean) == Interval(1.0, 1.0)
    assert bootstrap_ci([1.0], mean) is None
    data = [1.0] * 80 + [0.0] * 20
    ci = bootstrap_ci(data, mean, seed=7)
    assert ci == bootstrap_ci(data, mean, seed=7)
    assert ci.low < 0.8 < ci.high and 0.65 < ci.low and ci.high < 0.95


def test_labelled_set_report_has_intervals():
    report = evaluate_classifier(today=date(2026, 10, 19), samples=200)
    assert report.accuracy_ci.low <= report.accuracy <= report.accuracy_ci.high
    assert report.macro_f1_ci is not None
    assert "95% CI" in render_report(report, None, None, [])


# --- date-order replay of personal learning ---------------------------------------------------

def entry(user, text, category, corrected=False, merchant=None, ai_parsed=True, type_="expense"):
    return ReplayEntry(user_id=user, text=text, merchant=merchant, type=type_, category=category,
                       corrected=corrected, ai_parsed=ai_parsed)


def test_replay_learns_only_from_earlier_entries():
    entries = [
        # The rules say Transport; this user files Careem under Fuel and corrects the first entry.
        entry(1, "Careem 650", "Fuel", corrected=True, merchant="Careem"),
        entry(1, "Careem 400", "Fuel", merchant="Careem"),
        entry(1, "Careem 900", "Fuel", merchant="Careem"),
        # Another user agrees with the rules and is unaffected.
        entry(2, "Careem 500", "Transport", merchant="Careem"),
    ]
    outcomes = replay_user(entries[:3], date(2026, 10, 19))
    # The first entry can't benefit from its own correction: no leakage from the future.
    assert [(o.rules_correct, o.personal_correct) for o in outcomes] == [(False, False), (False, True), (False, True)]

    report = replay_personalization(entries, date(2026, 10, 19), samples=200)
    assert (report.n, report.users) == (4, 2)
    assert report.rules_accuracy == 0.25 and report.personal_accuracy == 0.75
    assert (report.overrides, report.helped, report.hurt) == (2, 2, 0)
    assert report.p_value == pytest.approx(0.5)  # 2 vs 0 discordant pairs is not significant
    assert "wrong → right" in render_report(evaluate_classifier(today=date(2026, 10, 19), samples=50),
                                            (4, 1), None, [], report)


def test_replay_scores_only_parsed_entries_but_learns_from_all():
    entries = [
        entry(1, "committee payment", "Transfers", corrected=True),
        entry(1, "committee 5000 for march", "Transfers", corrected=True, ai_parsed=False),  # manual: history only
        entry(1, "committee installment 5000", "Transfers"),
    ]
    report = replay_personalization(entries, date(2026, 10, 19), samples=50)
    assert report.n == 2
    assert replay_personalization([entry(1, "rent 5000", "Rent", ai_parsed=False)]) is None
