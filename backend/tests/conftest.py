"""
Test configuration. Runs the full API against a throw-away SQLite database so the suite
needs no PostgreSQL. Must set env vars *before* the app modules are imported.

Set TEST_DATABASE_URL to run the same suite against PostgreSQL instead. Every table in that
database is dropped and recreated per test, so point it at a dedicated test database.
"""

import os
import sys
import tempfile
from pathlib import Path

_DB_FILE = Path(tempfile.gettempdir()) / f"nisaab_test_{os.getpid()}.db"
os.environ["DATABASE_URL"] = os.environ.get("TEST_DATABASE_URL") or f"sqlite:///{_DB_FILE.as_posix()}"
os.environ["ASSISTANT_PROVIDER"] = "rules"
os.environ["JWT_SECRET"] = "test-secret-key-that-is-long-enough-for-hs256-signing"
os.environ["ENVIRONMENT"] = "test"
os.environ.pop("ANTHROPIC_API_KEY", None)

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from config import get_settings  # noqa: E402
from database import Base, engine  # noqa: E402
from main import app  # noqa: E402


@pytest.fixture(autouse=True)
def fresh_db():
    Base.metadata.drop_all(engine)
    Base.metadata.create_all(engine)
    yield


@pytest.fixture
def client():
    with TestClient(app) as c:
        yield c


CONSENT = {"accept_terms": True, "terms_version": get_settings().terms_version}


def register(client: TestClient, email: str = "ali@example.com", password: str = "Secret123") -> dict:
    res = client.post("/api/v1/auth/register", json={
        "full_name": "Ali Raza", "email": email, "password": password, "monthly_income": 120000,
        **CONSENT,
    })
    assert res.status_code == 201, res.text
    body = res.json()
    return {"user": body["user"], "headers": {"Authorization": f"Bearer {body['access_token']}"}}


@pytest.fixture
def auth(client):
    return register(client)


def pytest_sessionfinish(session, exitstatus):
    engine.dispose()
    _DB_FILE.unlink(missing_ok=True)
