"""End-to-end API tests (SQLite-backed, see conftest.py)."""

from datetime import date, timedelta
from unittest.mock import patch

import pytest

import assistant
from config import get_settings
from conftest import CONSENT, register
from database import SessionLocal
from models import AIFinancialLog
from seed import DEMO_EMAIL, DEMO_PASSWORD, seed

TODAY = get_settings().today()


def add_txn(client, auth, **overrides):
    body = {"amount": 1200, "type": "expense", "category": "Groceries", "merchant": "Carrefour",
            "source": "text", "raw_text": "Spent 1,200 on groceries at Carrefour"}
    body.update(overrides)
    res = client.post("/api/v1/transactions", json=body, headers=auth["headers"])
    assert res.status_code == 201, res.text
    return res.json()


# ---- System & auth -----------------------------------------------------------------

def test_health_and_request_id(client):
    res = client.get("/health")
    assert res.status_code == 200
    assert res.json()["database"] == "up"
    assert res.json()["assistant_provider"] == "rules"
    assert res.headers["X-Request-ID"]


def test_register_login_me(client):
    reg = register(client, "sara@example.com", "Passw0rd!")
    assert reg["user"]["email"] == "sara@example.com"

    res = client.post("/api/v1/auth/login", json={"email": "SARA@example.com", "password": "Passw0rd!"})
    assert res.status_code == 200
    token = res.json()["access_token"]

    me = client.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert me.status_code == 200 and me.json()["full_name"] == "Ali Raza"


def test_register_rejects_duplicates_and_weak_passwords(client):
    register(client, "dup@example.com")
    dup = client.post("/api/v1/auth/register", json={"full_name": "X Y", "email": "dup@example.com", "password": "Secret123", **CONSENT})
    assert dup.status_code == 409
    weak = client.post("/api/v1/auth/register", json={"full_name": "X Y", "email": "w@example.com", "password": "password"})
    assert weak.status_code == 422
    assert "request_id" in weak.json()


def test_login_wrong_password(client):
    register(client, "z@example.com")
    res = client.post("/api/v1/auth/login", json={"email": "z@example.com", "password": "nope12345"})
    assert res.status_code == 401
    assert res.json()["detail"] == "Incorrect email or password"


def test_protected_routes_require_token(client):
    assert client.get("/api/v1/auth/me").status_code == 401
    bad = client.get("/api/v1/auth/me", headers={"Authorization": "Bearer not.a.jwt"})
    assert bad.status_code == 401
    assert bad.headers["WWW-Authenticate"] == "Bearer"


def test_users_cannot_read_each_others_data(client, auth):
    other = register(client, "other@example.com")
    add_txn(client, other)
    res = client.get(f"/api/v1/transactions/{other['user']['id']}", headers=auth["headers"])
    assert res.status_code == 403
    txn_id = add_txn(client, other)["id"]
    assert client.delete(f"/api/v1/transactions/{txn_id}", headers=auth["headers"]).status_code == 404


# ---- Parsing ---------------------------------------------------------------------

def test_parse_endpoint_logs_interaction(client, auth):
    res = client.post("/api/v1/transactions/parse", headers=auth["headers"],
                      json={"text": "spent twelve hundred rupees on groceries at Carrefour", "source": "voice"})
    assert res.status_code == 200, res.text
    body = res.json()
    assert (body["amount"], body["category"], body["merchant"], body["source"]) == (1200, "Groceries", "Carrefour", "voice")
    assert body["normalized_text"].startswith("spent 1200")
    with SessionLocal() as db:
        log = db.query(AIFinancialLog).one()
        assert log.interaction_type == "parse" and float(log.confidence) == body["confidence"]


# ---- Transactions CRUD -----------------------------------------------------------

def test_transaction_crud_and_correction_flag(client, auth):
    txn = add_txn(client, auth)
    assert txn["transaction_date"] == TODAY.isoformat()
    assert txn["user_corrected"] is False

    res = client.patch(f"/api/v1/transactions/{txn['id']}", headers=auth["headers"],
                       json={"category": "Food & Dining", "amount": 1500})
    assert res.status_code == 200
    assert res.json()["category"] == "Food & Dining"
    assert res.json()["amount"] == 1500
    assert res.json()["user_corrected"] is True

    bad = client.patch(f"/api/v1/transactions/{txn['id']}", headers=auth["headers"], json={"category": "Salary"})
    assert bad.status_code == 422

    assert client.delete(f"/api/v1/transactions/{txn['id']}", headers=auth["headers"]).status_code == 204
    page = client.get(f"/api/v1/transactions/{auth['user']['id']}", headers=auth["headers"]).json()
    assert page["total"] == 0


def test_create_validation(client, auth):
    h = auth["headers"]
    assert client.post("/api/v1/transactions", headers=h, json={"amount": -5}).status_code == 422
    assert client.post("/api/v1/transactions", headers=h,
                       json={"amount": 100, "type": "income", "category": "Groceries"}).status_code == 422
    future = (TODAY + timedelta(days=10)).isoformat()
    assert client.post("/api/v1/transactions", headers=h,
                       json={"amount": 100, "transaction_date": future}).status_code == 422


def test_history_filters_search_and_pagination(client, auth):
    uid, h = auth["user"]["id"], auth["headers"]
    for i in range(25):
        add_txn(client, auth, amount=100 + i, merchant="Careem" if i % 2 else "Carrefour",
                category="Transport" if i % 2 else "Groceries")
    add_txn(client, auth, amount=150000, type="income", category="Salary", merchant=None, raw_text="salary")

    page1 = client.get(f"/api/v1/transactions/{uid}?page=1&page_size=10", headers=h).json()
    assert page1["total"] == 26 and page1["pages"] == 3 and len(page1["items"]) == 10
    assert page1["total_income"] == 150000

    careem = client.get(f"/api/v1/transactions/{uid}?search=careem", headers=h).json()
    assert careem["total"] == 12 and all(t["merchant"] == "Careem" for t in careem["items"])

    groceries = client.get(f"/api/v1/transactions/{uid}?category=Groceries&sort=amount_desc", headers=h).json()
    amounts = [t["amount"] for t in groceries["items"]]
    assert amounts == sorted(amounts, reverse=True)

    income = client.get(f"/api/v1/transactions/{uid}?type=income", headers=h).json()
    assert income["total"] == 1

    ranged = client.get(f"/api/v1/transactions/{uid}?min_amount=120&max_amount=124", headers=h).json()
    assert ranged["total"] == 5

    assert client.get(f"/api/v1/transactions/{uid}?month=1", headers=h).status_code == 422


# ---- Budgets ---------------------------------------------------------------------

def test_budget_upsert_and_status(client, auth):
    uid, h = auth["user"]["id"], auth["headers"]
    add_txn(client, auth, amount=9000)

    created = client.post("/api/v1/budgets", headers=h, json={"category": "Groceries", "monthly_limit": 10000})
    assert created.status_code == 201
    assert created.json()["status"] == "warning" and created.json()["percent_used"] == 90.0

    updated = client.post("/api/v1/budgets", headers=h, json={"category": "Groceries", "monthly_limit": 8000})
    assert updated.status_code == 200
    assert updated.json()["id"] == created.json()["id"]
    assert updated.json()["status"] == "exceeded" and updated.json()["remaining"] == -1000

    assert client.post("/api/v1/budgets", headers=h, json={"category": "Salary", "monthly_limit": 1}).status_code == 422

    listed = client.get(f"/api/v1/budgets/{uid}", headers=h).json()
    assert len(listed) == 1 and listed[0]["month_year"] == TODAY.replace(day=1).isoformat()

    assert client.delete(f"/api/v1/budgets/{listed[0]['id']}", headers=h).status_code == 204
    assert client.get(f"/api/v1/budgets/{uid}", headers=h).json() == []


# ---- Analytics, forecast, assistant on seeded history ----------------------------

@pytest.fixture
def demo(client):
    seed(reset=True)
    res = client.post("/api/v1/auth/login", json={"email": DEMO_EMAIL, "password": DEMO_PASSWORD})
    assert res.status_code == 200
    body = res.json()
    return {"user": body["user"], "headers": {"Authorization": f"Bearer {body['access_token']}"}}


def test_summary_on_seeded_data(client, demo):
    s = client.get(f"/api/v1/analytics/summary/{demo['user']['id']}", headers=demo["headers"]).json()
    assert s["total_income"] >= 150000
    assert s["total_expense"] > 0
    assert len(s["daily"]) == TODAY.day
    assert abs(sum(c["share"] for c in s["by_category"]) - 100) < 1
    assert len(s["budgets"]) == 6
    assert s["previous_month_expense"] > 0


def test_forecast_on_seeded_data(client, demo):
    f = client.get(f"/api/v1/analytics/forecast/{demo['user']['id']}", headers=demo["headers"]).json()
    assert f["projected_total_expense"] > 0
    assert f["next_month_total_forecast"] > 0
    cats = {c["category"]: c for c in f["categories"]}
    assert cats["Rent"]["projected_month_end"] == pytest.approx(35000)
    assert cats["Groceries"]["historical_avg"] > 0
    assert cats["Groceries"]["recommended_budget"] % 500 == 0


@pytest.mark.parametrize(
    "message, intent",
    [
        ("Assalam o alaikum", "greeting"),
        ("How much did I spend on food this month?", "spend_query"),
        ("Where does most of my money go?", "top_categories"),
        ("Am I within my budgets?", "budget_status"),
        ("Forecast my month", "forecast"),
        ("Can I afford Rs 20,000 for a new phone?", "affordability"),
        ("Give me some tips to save money", "advice"),
        ("show my recent transactions", "recent"),
        ("Am I on track for my savings goals?", "goals"),
    ],
)
def test_assistant_rules_engine(client, demo, message, intent):
    res = client.post("/api/v1/ai/assistant", headers=demo["headers"], json={"message": message})
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["intent"] == intent
    assert body["provider"] == "rules"
    assert len(body["reply"]) > 20 and body["suggestions"]


def test_assistant_history(client, demo):
    for m in ("hi", "forecast my month"):
        client.post("/api/v1/ai/assistant", headers=demo["headers"], json={"message": m})
    hist = client.get("/api/v1/ai/assistant/history", headers=demo["headers"]).json()
    assert [h["message"] for h in hist] == ["hi", "forecast my month"]


def test_assistant_uses_claude_when_configured_and_falls_back(client, demo, monkeypatch):
    settings = get_settings()
    monkeypatch.setattr(settings, "assistant_provider", "claude")

    ok = assistant.ClaudeResult(text="You spent Rs 12,000 on food.", model="claude-opus-5-5",
                                input_tokens=900, output_tokens=20)
    with patch.object(assistant, "claude_reply", return_value=ok) as mocked:
        res = client.post("/api/v1/ai/assistant", headers=demo["headers"],
                          json={"message": "food spend?", "history": [{"role": "assistant", "content": "Hi!"}]})
    assert res.json()["provider"] == "claude" and res.json()["reply"] == ok.text
    _, message, history, ctx = mocked.call_args.args
    assert message == "food spend?" and ctx["this_month"]["expense"] > 0

    with patch.object(assistant, "claude_reply", side_effect=assistant.ClaudeUnavailable("down")):
        res = client.post("/api/v1/ai/assistant", headers=demo["headers"], json={"message": "forecast my month"})
    assert res.json()["provider"] == "rules"
    assert res.json()["intent"] == "forecast"


def test_category_list(client):
    body = client.get("/api/v1/categories").json()
    assert "Groceries" in body["expense"] and "Salary" in body["income"]


def test_old_dates_in_previous_month_do_not_leak_into_summary(client, auth):
    prev = (TODAY.replace(day=1) - timedelta(days=1))
    add_txn(client, auth, amount=5000, transaction_date=prev.isoformat())
    add_txn(client, auth, amount=700)
    s = client.get(f"/api/v1/analytics/summary/{auth['user']['id']}", headers=auth["headers"]).json()
    assert s["total_expense"] == 700
    assert s["previous_month_expense"] == 5000
    assert date.fromisoformat(s["daily"][0]["date"]) == TODAY.replace(day=1)
