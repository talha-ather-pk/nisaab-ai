"""Research consent at registration and permanent account deletion."""

from datetime import date, datetime, timedelta, timezone

from sqlalchemy import func, select

from config import get_settings
from conftest import CONSENT, register
from database import SessionLocal
from models import AIFinancialLog, Budget, SavingsGoal, Transaction, User
from seed import DEMO_EMAIL, DEMO_PASSWORD, seed

VERSION = get_settings().terms_version
NEW_USER = {"full_name": "Sara Malik", "email": "sara@example.com", "password": "Secret123"}


def test_registration_requires_consent(client):
    res = client.post("/api/v1/auth/register", json=NEW_USER)
    assert res.status_code == 422
    assert "accept the terms" in str(res.json()["detail"])
    res = client.post("/api/v1/auth/register", json={**NEW_USER, "accept_terms": False, "terms_version": VERSION})
    assert res.status_code == 422


def test_registration_rejects_outdated_terms(client):
    res = client.post("/api/v1/auth/register", json={**NEW_USER, "accept_terms": True, "terms_version": "2020.01"})
    assert res.status_code == 409 and "updated" in res.json()["detail"]


def test_registration_records_server_side_consent(client):
    before = datetime.now(timezone.utc)
    res = client.post("/api/v1/auth/register", json={**NEW_USER, **CONSENT})
    assert res.status_code == 201, res.text
    user = res.json()["user"]
    assert user["terms_version"] == VERSION and user["terms_required"] is False
    accepted = datetime.fromisoformat(user["terms_accepted_at"])
    if accepted.tzinfo is None:  # SQLite drops the offset
        accepted = accepted.replace(tzinfo=timezone.utc)
    assert before - timedelta(seconds=5) <= accepted <= datetime.now(timezone.utc) + timedelta(seconds=5)


def test_existing_account_without_consent_is_asked_and_can_accept(client, auth):
    with SessionLocal() as db:  # simulate an account created before consent existed
        db.get(User, auth["user"]["id"]).terms_accepted_at = None
        db.commit()
    me = client.get("/api/v1/auth/me", headers=auth["headers"]).json()
    assert me["terms_required"] is True

    res = client.post("/api/v1/auth/me/accept-terms", json={"terms_version": "old"}, headers=auth["headers"])
    assert res.status_code == 409
    res = client.post("/api/v1/auth/me/accept-terms", json={"terms_version": VERSION}, headers=auth["headers"])
    assert res.status_code == 200 and res.json()["terms_required"] is False and res.json()["terms_accepted_at"]


def _count(db, model, user_id):
    return db.scalar(select(func.count()).select_from(model).where(model.user_id == user_id))


def test_delete_account_removes_everything(client, auth):
    h, uid = auth["headers"], auth["user"]["id"]
    client.post("/api/v1/transactions/parse", json={"text": "Careem 400"}, headers=h)  # creates an AI log
    client.post("/api/v1/transactions", headers=h, json={"amount": 400, "category": "Transport", "raw_text": "Careem 400"})
    client.post("/api/v1/budgets", headers=h, json={"category": "Transport", "monthly_limit": 5000})
    client.post("/api/v1/goals", headers=h, json={"name": "Laptop", "target_amount": 100000})
    other = register(client, email="other@example.com")
    client.post("/api/v1/transactions", headers=other["headers"],
                json={"amount": 100, "category": "Groceries", "raw_text": "milk 100"})

    assert client.request("DELETE", "/api/v1/auth/me", json={"password": "wrong-pass1"}, headers=h).status_code == 403
    res = client.request("DELETE", "/api/v1/auth/me", json={"password": "Secret123"}, headers=h)
    assert res.status_code == 204

    with SessionLocal() as db:
        assert db.get(User, uid) is None
        for model in (Transaction, Budget, SavingsGoal, AIFinancialLog):
            assert _count(db, model, uid) == 0, model.__name__
        assert _count(db, Transaction, other["user"]["id"]) == 1  # nobody else is touched

    # The old session no longer works, and the email can be registered again.
    assert client.get("/api/v1/auth/me", headers=h).status_code == 401
    assert client.post("/api/v1/auth/login", json={"email": "ali@example.com", "password": "Secret123"}).status_code == 401
    register(client)


def test_delete_requires_login_and_password(client, auth):
    assert client.request("DELETE", "/api/v1/auth/me", json={"password": "Secret123"}).status_code == 401
    assert client.request("DELETE", "/api/v1/auth/me", json={}, headers=auth["headers"]).status_code == 422


def test_shared_demo_account_cannot_be_deleted_or_consented(client):
    seed()
    token = client.post("/api/v1/auth/login", json={"email": DEMO_EMAIL, "password": DEMO_PASSWORD}).json()
    h = {"Authorization": f"Bearer {token['access_token']}"}
    assert token["user"]["terms_version"] == "demo" and token["user"]["terms_required"] is False
    res = client.request("DELETE", "/api/v1/auth/me", json={"password": DEMO_PASSWORD}, headers=h)
    assert res.status_code == 403
    # Accepting the terms on the shared account must not turn it into a research participant.
    res = client.post("/api/v1/auth/me/accept-terms", json={"terms_version": VERSION}, headers=h)
    assert res.json()["terms_version"] == "demo"
