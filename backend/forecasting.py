"""
Spending analytics & forecasting.

Pure functions (no DB) do the maths so they are easy to unit-test; `build_monthly_report`
and `build_forecast_report` gather the numbers with SQL aggregates and feed them in.

Method
------
* Month-end projection = spent so far + (remaining days × blended daily rate), where the
  blended rate weights the current month's run-rate by how far through the month we are
  and the trailing-3-month daily average by the rest. Early in the month history dominates;
  late in the month the actual run-rate does.
* "Lumpy" categories (rent, fees, utilities, charity) are usually paid once a month, so a
  run-rate would wildly over-project; for those projection = max(spent, historical average).
* Next-month forecast = linearly weighted moving average of the last N complete months.
* Risk: exceeded (spent > limit) · likely_over (projected > limit) ·
        at_risk (spent ≥ alert threshold or projected ≥ 90% of limit) · on_track.
"""

from __future__ import annotations

import calendar
import math
from dataclasses import asdict, dataclass, field
from datetime import date
from decimal import Decimal
from typing import Literal, Optional

from sqlalchemy import and_, case, func, literal_column, select
from sqlalchemy.orm import Session

from models import Budget, Transaction

RiskLevel = Literal["no_budget", "on_track", "at_risk", "likely_over", "exceeded"]

LUMPY_CATEGORIES = {"Rent", "Education", "Utilities", "Charity"}
HISTORY_MONTHS = 3


# =============================================================================
# Date helpers
# =============================================================================

def month_start(d: date) -> date:
    return d.replace(day=1)


def add_months(d: date, months: int) -> date:
    """First day of the month `months` away from d's month."""
    index = d.year * 12 + (d.month - 1) + months
    return date(index // 12, index % 12 + 1, 1)


def days_in_month(d: date) -> int:
    return calendar.monthrange(d.year, d.month)[1]


def month_bounds(year: int, month: int) -> tuple[date, date]:
    """[start, next_month_start) for range filters that use the date index."""
    start = date(year, month, 1)
    return start, add_months(start, 1)


# =============================================================================
# Pure calculations
# =============================================================================

def project_month_end(
    spent_to_date: float,
    days_elapsed: int,
    total_days: int,
    historical_monthly_avg: Optional[float],
    lumpy: bool = False,
) -> float:
    if days_elapsed >= total_days:
        return round(spent_to_date, 2)
    if lumpy:
        return round(max(spent_to_date, historical_monthly_avg or 0.0), 2)
    days_elapsed = max(days_elapsed, 1)
    current_daily = spent_to_date / days_elapsed
    if historical_monthly_avg is None:
        daily = current_daily
    else:
        weight = days_elapsed / total_days
        daily = weight * current_daily + (1 - weight) * (historical_monthly_avg / total_days)
    return round(spent_to_date + daily * (total_days - days_elapsed), 2)


def classify_risk(
    spent: float, projected: float, limit: Optional[float], alert_threshold: int = 80
) -> RiskLevel:
    if not limit:
        return "no_budget"
    if spent > limit:
        return "exceeded"
    if projected > limit:
        return "likely_over"
    if spent >= limit * alert_threshold / 100 or projected >= limit * 0.9:
        return "at_risk"
    return "on_track"


def weighted_moving_average(values: list[float]) -> Optional[float]:
    """Oldest -> newest; newest month weighs most (weights 1..n)."""
    if not values:
        return None
    weights = range(1, len(values) + 1)
    return round(sum(v * w for v, w in zip(values, weights)) / sum(weights), 2)


def trend_percent(values: list[float]) -> Optional[float]:
    """Change of the latest month vs. the average of the earlier ones."""
    if len(values) < 2:
        return None
    base = sum(values[:-1]) / (len(values) - 1)
    if base == 0:
        return None
    return round((values[-1] - base) / base * 100, 1)


def recommend_budget(values: list[float]) -> Optional[float]:
    """A realistic limit: 5% headroom over the weighted average, rounded up to Rs 500."""
    wma = weighted_moving_average([v for v in values if v > 0])
    if not wma:
        return None
    return float(math.ceil(wma * 1.05 / 500) * 500)


def goal_progress(target: float, saved: float, target_date: Optional[date], started: date,
                  today: date) -> tuple[float, float, Optional[float], str]:
    """
    (percent, remaining, monthly_needed, status) for a savings goal. A goal with a deadline is
    "on_track" while the saved amount keeps pace with a straight line from `started` to the deadline.
    """
    remaining = round(max(target - saved, 0.0), 2)
    percent = round(min(saved / target * 100, 100.0), 1)
    if remaining == 0:
        return percent, 0.0, None, "completed"
    if target_date is None:
        return percent, remaining, None, "no_deadline"
    if target_date < today:
        return percent, remaining, None, "overdue"
    months_left = max((target_date - today).days / 30.44, 1.0)
    monthly_needed = float(math.ceil(remaining / months_left))
    total_days = (target_date - started).days
    expected = target * (today - started).days / total_days if total_days > 0 else target
    return percent, remaining, monthly_needed, "on_track" if saved >= expected else "behind"


def budget_state(limit: float, spent: float, alert_threshold: int = 80) -> tuple[float, float, str]:
    """(remaining, percent_used, status) for a budget bar. status: ok | warning | exceeded."""
    pct = round(spent / limit * 100, 1) if limit else 0.0
    status = "exceeded" if spent > limit else "warning" if pct >= alert_threshold else "ok"
    return round(limit - spent, 2), pct, status


# =============================================================================
# Report structures
# =============================================================================

@dataclass
class CategoryForecast:
    category: str
    spent_to_date: float
    projected_month_end: float
    historical_avg: Optional[float]
    next_month_forecast: Optional[float]
    trend_pct: Optional[float]
    monthly_limit: Optional[float]
    recommended_budget: Optional[float]
    risk: RiskLevel
    projected_overrun: float
    message: str


@dataclass
class ForecastReport:
    as_of: date
    month: int
    year: int
    days_elapsed: int
    days_in_month: int
    projected_total_expense: float
    projected_total_income: float
    projected_savings: float
    next_month_total_forecast: Optional[float]
    categories: list[CategoryForecast] = field(default_factory=list)
    alerts: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return asdict(self)


def _risk_message(c: CategoryForecast) -> str:
    rs = lambda v: f"Rs {v:,.0f}"  # noqa: E731
    if c.risk == "exceeded":
        return f"{c.category}: already {rs(c.spent_to_date - (c.monthly_limit or 0))} over budget."
    if c.risk == "likely_over":
        return f"{c.category}: on pace for {rs(c.projected_month_end)}, about {rs(c.projected_overrun)} over budget."
    if c.risk == "at_risk":
        return f"{c.category}: close to the limit; projected {rs(c.projected_month_end)} of {rs(c.monthly_limit or 0)}."
    if c.risk == "on_track":
        return f"{c.category}: on track ({rs(c.projected_month_end)} projected of {rs(c.monthly_limit or 0)})."
    return f"{c.category}: projected {rs(c.projected_month_end)} this month."


def compute_forecast(
    today: date,
    spent_by_category: dict[str, float],
    history_by_category: dict[str, list[float]],
    budgets: dict[str, tuple[float, int]],
    income_to_date: float,
    income_history: list[float],
) -> ForecastReport:
    """
    spent_by_category:   current month-to-date expense per category
    history_by_category: last N complete months, oldest -> newest, per category
    budgets:             category -> (monthly_limit, alert_threshold) for the current month
    """
    total_days = days_in_month(today)
    elapsed = today.day
    categories = sorted(set(spent_by_category) | set(history_by_category) | set(budgets))

    rows: list[CategoryForecast] = []
    for cat in categories:
        spent = spent_by_category.get(cat, 0.0)
        hist = history_by_category.get(cat, [])
        hist_nonzero = [h for h in hist if h > 0]
        hist_avg = round(sum(hist_nonzero) / len(hist_nonzero), 2) if hist_nonzero else None
        projected = project_month_end(spent, elapsed, total_days, hist_avg, lumpy=cat in LUMPY_CATEGORIES)
        limit, threshold = budgets.get(cat, (None, 80))
        risk = classify_risk(spent, projected, limit, threshold)
        row = CategoryForecast(
            category=cat,
            spent_to_date=round(spent, 2),
            projected_month_end=projected,
            historical_avg=hist_avg,
            next_month_forecast=weighted_moving_average(hist + [projected]) if (hist or spent) else None,
            trend_pct=trend_percent(hist + [projected]) if hist else None,
            monthly_limit=limit,
            recommended_budget=recommend_budget(hist + [projected]),
            risk=risk,
            projected_overrun=round(max(projected - (limit or projected), 0.0), 2),
            message="",
        )
        row.message = _risk_message(row)
        rows.append(row)

    severity = {"exceeded": 0, "likely_over": 1, "at_risk": 2, "on_track": 3, "no_budget": 4}
    rows.sort(key=lambda r: (severity[r.risk], -r.projected_month_end))

    projected_expense = round(sum(r.projected_month_end for r in rows), 2)
    income_avg = (sum(income_history) / len(income_history)) if income_history else None
    projected_income = round(max(income_to_date, income_avg or 0.0), 2)
    next_month = [r.next_month_forecast for r in rows if r.next_month_forecast is not None]

    return ForecastReport(
        as_of=today,
        month=today.month,
        year=today.year,
        days_elapsed=elapsed,
        days_in_month=total_days,
        projected_total_expense=projected_expense,
        projected_total_income=projected_income,
        projected_savings=round(projected_income - projected_expense, 2),
        next_month_total_forecast=round(sum(next_month), 2) if next_month else None,
        categories=rows,
        alerts=[r.message for r in rows if r.risk in ("exceeded", "likely_over", "at_risk")],
    )


# =============================================================================
# DB aggregation
# =============================================================================

def _f(v: Optional[Decimal]) -> float:
    return float(v or 0)


def spend_by_category(db: Session, user_id: int, start: date, end: date) -> dict[str, float]:
    rows = db.execute(
        select(Transaction.category, func.sum(Transaction.amount))
        .where(
            Transaction.user_id == user_id,
            Transaction.type == "expense",
            Transaction.transaction_date >= start,
            Transaction.transaction_date < end,
        )
        .group_by(Transaction.category)
    ).all()
    return {cat: _f(total) for cat, total in rows}


def totals_for_period(db: Session, user_id: int, start: date, end: date) -> tuple[float, float, int]:
    income, expense, count = db.execute(
        select(
            func.sum(case((Transaction.type == "income", Transaction.amount), else_=0)),
            func.sum(case((Transaction.type == "expense", Transaction.amount), else_=0)),
            func.count(Transaction.id),
        ).where(
            Transaction.user_id == user_id,
            Transaction.transaction_date >= start,
            Transaction.transaction_date < end,
        )
    ).one()
    return _f(income), _f(expense), int(count or 0)


def budgets_with_spend(db: Session, user_id: int, period_start: date) -> list[dict]:
    period_end = add_months(period_start, 1)
    spent_sq = (
        select(
            Transaction.category.label("category"),
            func.sum(Transaction.amount).label("spent"),
        )
        .where(
            Transaction.user_id == user_id,
            Transaction.type == "expense",
            Transaction.transaction_date >= period_start,
            Transaction.transaction_date < period_end,
        )
        .group_by(Transaction.category)
        .subquery()
    )
    rows = db.execute(
        select(Budget, func.coalesce(spent_sq.c.spent, 0))
        .outerjoin(spent_sq, and_(spent_sq.c.category == Budget.category))
        .where(Budget.user_id == user_id, Budget.month_year == period_start)
        .order_by(Budget.category)
    ).all()
    result = []
    for budget, spent in rows:
        limit = _f(budget.monthly_limit)
        remaining, pct, status = budget_state(limit, _f(spent), budget.alert_threshold)
        result.append({
            "id": budget.id,
            "user_id": budget.user_id,
            "category": budget.category,
            "monthly_limit": limit,
            "currency": budget.currency,
            "month": budget.month_year.month,
            "year": budget.month_year.year,
            "month_year": budget.month_year,
            "alert_threshold": budget.alert_threshold,
            "spent": round(_f(spent), 2),
            "remaining": remaining,
            "percent_used": pct,
            "status": status,
        })
    return result


def build_forecast_report(db: Session, user_id: int, today: date) -> ForecastReport:
    current_start = month_start(today)
    current_end = add_months(current_start, 1)
    spent_now = spend_by_category(db, user_id, current_start, current_end)

    history_start = add_months(current_start, -HISTORY_MONTHS)
    # Format strings are inlined (not bound) so SELECT and GROUP BY are the identical expression.
    month_key = func.strftime(literal_column("'%Y-%m'"), Transaction.transaction_date) \
        if db.get_bind().dialect.name == "sqlite" \
        else func.to_char(Transaction.transaction_date, literal_column("'YYYY-MM'"))
    hist_rows = db.execute(
        select(Transaction.category, Transaction.type, month_key.label("ym"), func.sum(Transaction.amount))
        .where(
            Transaction.user_id == user_id,
            Transaction.transaction_date >= history_start,
            Transaction.transaction_date < current_start,
        )
        .group_by(Transaction.category, Transaction.type, month_key)
    ).all()

    month_keys = [add_months(history_start, i).strftime("%Y-%m") for i in range(HISTORY_MONTHS)]
    history: dict[str, dict[str, float]] = {}
    income_by_month: dict[str, float] = {k: 0.0 for k in month_keys}
    for category, txn_type, ym, total in hist_rows:
        if txn_type == "income":
            income_by_month[ym] = income_by_month.get(ym, 0.0) + _f(total)
        else:
            history.setdefault(category, {})[ym] = _f(total)

    # Only keep months the user was actually active in, so new users aren't diluted by zeros.
    first_active = next((k for k in month_keys if any(k in h for h in history.values())
                         or income_by_month.get(k)), None)
    active_keys = month_keys[month_keys.index(first_active):] if first_active else []
    history_lists = {cat: [h.get(k, 0.0) for k in active_keys] for cat, h in history.items()}
    income_history = [income_by_month[k] for k in active_keys if income_by_month[k] > 0]

    budgets = {
        b.category: (_f(b.monthly_limit), b.alert_threshold)
        for b in db.scalars(select(Budget).where(Budget.user_id == user_id, Budget.month_year == current_start))
    }
    income_now, _, _ = totals_for_period(db, user_id, current_start, current_end)

    return compute_forecast(today, spent_now, history_lists, budgets, income_now, income_history)
