"""
Apply database/schema.sql to the configured database (DATABASE_URL), without needing psql.

    python init_db.py            # safe to re-run: the schema is idempotent
    python init_db.py --seed     # also create the demo account (see seed.py)
"""

from __future__ import annotations

import argparse
from pathlib import Path

import psycopg

from config import get_settings

SCHEMA = Path(__file__).resolve().parents[1] / "database" / "schema.sql"


def apply_schema(url: str) -> list[str]:
    # psycopg wants a plain libpq URL, not SQLAlchemy's "postgresql+psycopg://".
    conninfo = url.replace("postgresql+psycopg://", "postgresql://", 1)
    with psycopg.connect(conninfo, autocommit=True) as conn:
        conn.execute(SCHEMA.read_text(encoding="utf-8"))  # the file manages its own BEGIN/COMMIT
        return [r[0] for r in conn.execute("SELECT version FROM schema_migrations ORDER BY version")]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seed", action="store_true", help="also create the demo account")
    args = parser.parse_args()

    url = get_settings().database_url
    if url.startswith("sqlite"):
        raise SystemExit("DATABASE_URL points at SQLite; init_db.py is for PostgreSQL.")
    print("Applied migrations:", ", ".join(apply_schema(url)))
    if args.seed:
        from seed import seed
        seed()


if __name__ == "__main__":
    main()
