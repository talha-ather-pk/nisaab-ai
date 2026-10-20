from datetime import date

import pytest

from forecasting import (
    add_months,
    budget_state,
    classify_risk,
    compute_forecast,
    project_month_end,
    recommend_budget,
    trend_percent,
    weighted_moving_average,
)


def test_add_months_wraps_years():
    assert add_months(date(2026, 11, 18), 2) == date(2027, 1, 1)
    assert add_months(date(2026, 1, 31), -1) == date(2025, 12, 1)


def test_projection_without_history_is_run_rate():
    assert project_month_end(1000, 10, 30, None) == 3000


def test_projection_blends_towards_history_early_in_month():
    # Day 3 of 30: big early spend, but history says 9,000/month.
    projected = project_month_end(3000, 3, 30, 9000)
    assert 9000 < projected < 30000
    # Day 27: run-rate dominates.
    late = project_month_end(27000, 27, 30, 9000)
    assert late == pytest.approx(27000 + 3 * (0.9 * 1000 + 0.1 * 300), abs=0.01)


def test_lumpy_categories_do_not_extrapolate():
    assert project_month_end(35000, 5, 30, 35000, lumpy=True) == 35000


def test_projection_complete_month_returns_actual():
    assert project_month_end(12345, 31, 31, 99999) == 12345


@pytest.mark.parametrize(
    "spent, projected, limit, expected",
    [
        (100, 200, None, "no_budget"),
        (1100, 1200, 1000, "exceeded"),
        (600, 1100, 1000, "likely_over"),
        (850, 880, 1000, "at_risk"),
        (300, 920, 1000, "at_risk"),
        (300, 600, 1000, "on_track"),
    ],
)
def test_classify_risk(spent, projected, limit, expected):
    assert classify_risk(spent, projected, limit) == expected


def test_weighted_moving_average_favours_recent():
    assert weighted_moving_average([100, 200, 300]) == pytest.approx((100 + 400 + 900) / 6, abs=0.01)
    assert weighted_moving_average([]) is None


def test_trend_and_recommendation():
    assert trend_percent([100, 100, 150]) == 50.0
    assert recommend_budget([9000, 10000, 11000]) == 11000.0  # 10,333 × 1.05 -> 11,000


def test_budget_state():
    assert budget_state(1000, 500) == (500, 50.0, "ok")
    assert budget_state(1000, 850) == (150, 85.0, "warning")
    assert budget_state(1000, 1200) == (-200, 120.0, "exceeded")


def test_compute_forecast_orders_by_risk_and_flags_alerts():
    report = compute_forecast(
        today=date(2026, 10, 15),
        spent_by_category={"Groceries": 15000, "Transport": 2000, "Rent": 35000},
        history_by_category={"Groceries": [20000, 21000, 22000], "Transport": [6000, 6500, 7000],
                             "Rent": [35000, 35000, 35000]},
        budgets={"Groceries": (25000, 80), "Transport": (9000, 80)},
        income_to_date=150000,
        income_history=[150000, 150000, 150000],
    )
    risks = {c.category: c.risk for c in report.categories}
    assert risks["Groceries"] == "likely_over"
    assert risks["Transport"] == "on_track"
    assert risks["Rent"] == "no_budget"
    assert report.categories[0].category == "Groceries"
    assert any("Groceries" in a for a in report.alerts)
    rent = next(c for c in report.categories if c.category == "Rent")
    assert rent.projected_month_end == 35000
    assert report.projected_savings == pytest.approx(150000 - report.projected_total_expense)
