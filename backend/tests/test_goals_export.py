"""Savings goals (US-26) and CSV export (US-22)."""

import csv
import io
from datetime import date, timedelta

from config import get_settings
from conftest import register
from forecasting import goal_progress

TODAY = get_settings().today()


def test_goal_progress_maths():
    start = date(2026, 1, 1)
    # Half way through the period with half saved: on track; Rs 50k left over ~6 months.
    pct, remaining, monthly, status = goal_progress(120_000, 60_000, date(2026, 12, 31), start, date(2026, 7, 2))
    assert (pct, remaining, status) == (50.0, 60_000, "on_track")
    assert 9_000 < monthly < 11_000
    assert goal_progress(120_000, 10_000, date(2026, 12, 31), start, date(2026, 7, 2))[3] == "behind"
    assert goal_progress(100, 150, None, start, start)[:2] == (100.0, 0.0)
    assert goal_progress(100, 150, None, start, start)[3] == "completed"
    assert goal_progress(100, 10, None, start, start)[3] == "no_deadline"
    assert goal_progress(100, 10, date(2026, 2, 1), start, date(2026, 3, 1))[3] == "overdue"


def test_goal_crud_and_contributions(client, auth):
    h = auth["headers"]
    target_date = (TODAY + timedelta(days=180)).isoformat()
    res = client.post("/api/v1/goals", headers=h,
                      json={"name": " Laptop ", "target_amount": 150000, "target_date": target_date})
    assert res.status_code == 201, res.text
    goal = res.json()
    assert goal["name"] == "Laptop" and goal["saved_amount"] == 0 and goal["status"] == "on_track"
    assert goal["monthly_needed"] > 0

    goal = client.post(f"/api/v1/goals/{goal['id']}/contribute", json={"amount": 30000}, headers=h).json()
    assert goal["saved_amount"] == 30000 and goal["percent"] == 20.0 and goal["remaining"] == 120000

    res = client.post(f"/api/v1/goals/{goal['id']}/contribute", json={"amount": -50000}, headers=h)
    assert res.status_code == 422
    assert client.post(f"/api/v1/goals/{goal['id']}/contribute", json={"amount": 0}, headers=h).status_code == 422

    goal = client.patch(f"/api/v1/goals/{goal['id']}", json={"target_amount": 30000}, headers=h).json()
    assert goal["status"] == "completed"

    listed = client.get(f"/api/v1/goals/{auth['user']['id']}", headers=h).json()
    assert [g["id"] for g in listed] == [goal["id"]]

    assert client.delete(f"/api/v1/goals/{goal['id']}", headers=h).status_code == 204
    assert client.get(f"/api/v1/goals/{auth['user']['id']}", headers=h).json() == []


def test_goal_validation_and_ownership(client, auth):
    h = auth["headers"]
    past = (TODAY - timedelta(days=1)).isoformat()
    assert client.post("/api/v1/goals", headers=h,
                       json={"name": "Trip", "target_amount": 1000, "target_date": past}).status_code == 422
    assert client.post("/api/v1/goals", headers=h, json={"name": "", "target_amount": 1000}).status_code == 422
    goal = client.post("/api/v1/goals", headers=h, json={"name": "Trip", "target_amount": 1000}).json()
    assert goal["status"] == "no_deadline" and goal["monthly_needed"] is None

    other = register(client, email="sara@example.com")
    assert client.get(f"/api/v1/goals/{auth['user']['id']}", headers=other["headers"]).status_code == 403
    assert client.patch(f"/api/v1/goals/{goal['id']}", json={"name": "x"},
                        headers=other["headers"]).status_code == 404
    assert client.delete(f"/api/v1/goals/{goal['id']}", headers=other["headers"]).status_code == 404


def test_csv_export(client, auth):
    h = auth["headers"]
    for amount, text, day in ((1200, "Spent 1,200 at Carrefour, \"weekly\"", TODAY),
                              (500, "chai 500", TODAY - timedelta(days=40))):
        client.post("/api/v1/transactions", headers=h, json={
            "amount": amount, "category": "Groceries", "raw_text": text, "source": "text",
            "transaction_date": day.isoformat()})

    res = client.get(f"/api/v1/transactions/{auth['user']['id']}/export", headers=h)
    assert res.status_code == 200
    assert res.headers["content-type"].startswith("text/csv")
    assert "attachment" in res.headers["content-disposition"]
    rows = list(csv.DictReader(io.StringIO(res.content.decode("utf-8-sig"))))
    assert len(rows) == 2
    assert rows[0]["amount"] == "1200.00" and rows[0]["original_text"] == 'Spent 1,200 at Carrefour, "weekly"'

    since = (TODAY - timedelta(days=7)).isoformat()
    res = client.get(f"/api/v1/transactions/{auth['user']['id']}/export?date_from={since}", headers=h)
    assert len(list(csv.DictReader(io.StringIO(res.content.decode("utf-8-sig"))))) == 1

    other = register(client, email="sara@example.com")
    assert client.get(f"/api/v1/transactions/{auth['user']['id']}/export",
                      headers=other["headers"]).status_code == 403
