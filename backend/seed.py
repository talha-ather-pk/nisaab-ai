"""
Create a demo account with ~3 months of realistic Pakistani spending history.

    python seed.py            # create demo user if missing
    python seed.py --reset    # delete and recreate the demo user's data

Login: demo@nisaab.app / Demo@1234
"""

from __future__ import annotations

import argparse
import random
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal

from sqlalchemy import select

from config import get_settings
from database import SessionLocal
from forecasting import add_months, days_in_month, month_start
from models import Budget, SavingsGoal, Transaction, User
from security import hash_password

DEMO_EMAIL = "demo@nisaab.app"
DEMO_PASSWORD = "Demo@1234"
HISTORY_MONTHS = 3


def _txn(user_id: int, day: date, amount: float, type_: str, category: str, merchant: str | None,
         raw: str, source: str = "text") -> Transaction:
    return Transaction(
        user_id=user_id,
        amount=Decimal(str(round(amount, -1) if amount >= 100 else round(amount))),
        currency="PKR",
        type=type_,
        category=category,
        merchant=merchant,
        description=raw.split(" at ")[0][:255],
        raw_text=raw,
        source=source,
        ai_confidence=Decimal("0.950") if merchant else Decimal("0.800"),
        user_corrected=False,
        transaction_date=day,
    )


def generate_month(user_id: int, first: date, until: date, rng: random.Random) -> list[Transaction]:
    """All transactions for one month, up to and including `until`."""
    out: list[Transaction] = []
    last = min(date(first.year, first.month, days_in_month(first)), until)

    def on(day: int) -> date | None:
        d = first.replace(day=min(day, days_in_month(first)))
        return d if d <= last else None

    if d := on(1):
        out.append(_txn(user_id, d, 150000, "income", "Salary", None, "Received salary 150,000"))
    if rng.random() < 0.6 and (d := on(rng.randint(8, 25))):
        amt = rng.choice([18000, 25000, 32000])
        out.append(_txn(user_id, d, amt, "income", "Freelance", "Upwork", f"Got {amt:,} from Upwork"))
    if d := on(5):
        out.append(_txn(user_id, d, 35000, "expense", "Rent", None, "Paid rent 35,000"))
    if d := on(10):
        amt = rng.randint(4200, 7800)
        out.append(_txn(user_id, d, amt, "expense", "Utilities", "K-Electric", f"Paid K-Electric bill Rs {amt:,}"))
    if d := on(12):
        amt = rng.randint(1200, 2600)
        out.append(_txn(user_id, d, amt, "expense", "Utilities", "SSGC", f"SSGC gas bill {amt}"))
    if d := on(7):
        out.append(_txn(user_id, d, 3500, "expense", "Mobile & Internet", "StormFiber", "StormFiber internet 3500"))
    for day in (3, 18):
        if d := on(day):
            out.append(_txn(user_id, d, 1000, "expense", "Mobile & Internet", "Jazz", "Jazz load 1000", "sms"))
    if d := on(15):
        out.append(_txn(user_id, d, 1100, "expense", "Entertainment", "Netflix", "Netflix subscription 1100"))
    if d := on(20):
        out.append(_txn(user_id, d, 2000, "expense", "Charity", "Edhi Foundation", "Donation to Edhi 2000"))

    for week_day in (2, 9, 16, 23, 29):
        if d := on(week_day):
            shop = rng.choice(["Carrefour", "Imtiaz", "Naheed"])
            amt = rng.randint(3500, 7500)
            out.append(_txn(user_id, d, amt, "expense", "Groceries", shop, f"Spent {amt:,} rupees on groceries at {shop}"))

    for _ in range(rng.randint(8, 12)):
        if d := on(rng.randint(1, 28)):
            where, what = rng.choice([("Foodpanda", "dinner"), ("KFC", "lunch"), (None, "chai"),
                                      ("Savour Foods", "lunch"), (None, "biryani")])
            amt = rng.randint(250, 900) if what in ("chai", "biryani") else rng.randint(900, 2800)
            raw = f"{what} at {where} {amt}" if where else f"{what} {amt}"
            out.append(_txn(user_id, d, amt, "expense", "Food & Dining", where, raw, rng.choice(["text", "voice"])))

    for _ in range(rng.randint(12, 18)):
        if d := on(rng.randint(1, 28)):
            app = rng.choice(["Careem", "Bykea", "inDrive"])
            amt = rng.randint(250, 950)
            out.append(_txn(user_id, d, amt, "expense", "Transport", app, f"{app} ride to office {amt}", "voice"))

    for day in (4, 14, 24):
        if d := on(day):
            pump = rng.choice(["PSO", "Shell"])
            amt = rng.randint(4500, 7000)
            out.append(_txn(user_id, d, amt, "expense", "Fuel", pump, f"Petrol {amt} at {pump}"))

    for _ in range(rng.randint(1, 3)):
        if d := on(rng.randint(5, 27)):
            store = rng.choice(["Daraz", "Khaadi", "Outfitters"])
            amt = rng.randint(2000, 9000)
            out.append(_txn(user_id, d, amt, "expense", "Shopping", store, f"Bought clothes for {amt} at {store}"))

    if rng.random() < 0.5 and (d := on(rng.randint(5, 25))):
        amt = rng.randint(800, 3500)
        out.append(_txn(user_id, d, amt, "expense", "Health", "Pharmacy", f"Medicine {amt} at Dvago"))
    return out


def seed(reset: bool = False) -> None:
    settings = get_settings()
    today = settings.today()
    rng = random.Random(42)

    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.email == DEMO_EMAIL))
        if user and not reset:
            print(f"Demo user already exists (id={user.id}). Use --reset to regenerate its data.")
            return
        if user:
            db.delete(user)
            db.commit()

        user = User(
            full_name="Ayesha Khan",
            email=DEMO_EMAIL,
            phone="+923001234567",
            password_hash=hash_password(DEMO_PASSWORD),
            preferred_currency="PKR",
            monthly_income=Decimal("150000"),
            # Shared demo account: marked so it is never treated as a research participant or deleted.
            terms_accepted_at=datetime.now(timezone.utc),
            terms_version="demo",
        )
        db.add(user)
        db.flush()

        current = month_start(today)
        transactions: list[Transaction] = []
        for offset in range(HISTORY_MONTHS, -1, -1):
            first = add_months(current, -offset)
            transactions += generate_month(user.id, first, today, rng)
        db.add_all(transactions)

        for category, limit in {
            "Groceries": 25000, "Food & Dining": 12000, "Transport": 9000,
            "Fuel": 16000, "Shopping": 8000, "Utilities": 10000,
        }.items():
            db.add(Budget(user_id=user.id, category=category, monthly_limit=Decimal(limit), month_year=current))

        db.add_all([
            SavingsGoal(user_id=user.id, name="New laptop", target_amount=Decimal(180000),
                        saved_amount=Decimal(45000), target_date=add_months(current, 6)),
            SavingsGoal(user_id=user.id, name="Emergency fund", target_amount=Decimal(300000),
                        saved_amount=Decimal(120000)),
        ])

        db.commit()
        print(f"Seeded demo user id={user.id}: {len(transactions)} transactions, 6 budgets, 2 savings goals.")
        print(f"Login with {DEMO_EMAIL} / {DEMO_PASSWORD}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--reset", action="store_true", help="delete and recreate the demo user's data")
    seed(reset=parser.parse_args().reset)
