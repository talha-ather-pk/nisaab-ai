"""SQLAlchemy engine, connection pool and session dependency."""

from __future__ import annotations

from collections.abc import Iterator

from sqlalchemy import create_engine, event
from sqlalchemy.engine import Engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from config import get_settings


class Base(DeclarativeBase):
    """Declarative base for all ORM models."""


def build_engine(url: str | None = None) -> Engine:
    settings = get_settings()
    url = url or settings.database_url
    if url.startswith("sqlite"):
        # Used by the test-suite only; production runs on PostgreSQL.
        engine = create_engine(url, connect_args={"check_same_thread": False}, echo=settings.db_echo)

        @event.listens_for(engine, "connect")
        def _enable_sqlite_fk(dbapi_conn, _):  # pragma: no cover - trivial
            dbapi_conn.execute("PRAGMA foreign_keys=ON")

        return engine

    return create_engine(
        url,
        pool_size=settings.db_pool_size,
        max_overflow=settings.db_max_overflow,
        pool_pre_ping=True,      # transparently replaces connections dropped by the server
        pool_recycle=1800,       # avoid idle-timeout disconnects on managed Postgres
        pool_timeout=10,
        echo=settings.db_echo,
        connect_args={"connect_timeout": 5, "application_name": "nisaab-api"},
    )


engine: Engine = build_engine()
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


def get_db() -> Iterator[Session]:
    """FastAPI dependency: one session per request, rolled back on error."""
    db = SessionLocal()
    try:
        yield db
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()
