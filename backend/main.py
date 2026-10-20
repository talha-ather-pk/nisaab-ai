"""
Nisaab AI — FastAPI application.

Run:   uvicorn main:app --reload
Docs:  http://127.0.0.1:8000/docs
"""

from __future__ import annotations

import csv
import io
import logging
import math
import time
import uuid
from datetime import date, datetime, timedelta, timezone
from typing import Literal, Optional

from fastapi import Depends, FastAPI, HTTPException, Query, Request, Response, status
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from sqlalchemy import case, func, or_, select, text
from sqlalchemy.exc import IntegrityError, OperationalError, SQLAlchemyError
from sqlalchemy.orm import Session

import assistant as ai_assistant
import schemas
from config import Settings, get_settings
from database import get_db
from forecasting import (
    add_months,
    budgets_with_spend,
    build_forecast_report,
    goal_progress,
    month_bounds,
    totals_for_period,
)
from models import AIFinancialLog, Budget, SavingsGoal, Transaction, User
from nlp_engine import CATEGORIES, EXPENSE_CATEGORIES, INCOME_CATEGORIES, extract_entities
from personalization import MODEL_NAME as PERSONAL_MODEL, personalize
from security import create_access_token, ensure_owner, get_current_user, hash_password, verify_password

API_VERSION = "1.0.0"
settings = get_settings()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("nisaab.api")

app = FastAPI(
    title=settings.app_name,
    version=API_VERSION,
    description="Personal finance management & expense tracking for Pakistan. Track · Understand · Grow.",
)

# =============================================================================
# Middleware & error handling
# =============================================================================

_origins = settings.cors_origin_list
app.add_middleware(
    CORSMiddleware,
    allow_origins=_origins,
    allow_credentials=_origins != ["*"],
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["X-Request-ID"],
)


@app.middleware("http")
async def request_context(request: Request, call_next):
    request_id = request.headers.get("X-Request-ID") or uuid.uuid4().hex[:16]
    request.state.request_id = request_id
    started = time.perf_counter()
    response: Response = await call_next(request)
    elapsed_ms = (time.perf_counter() - started) * 1000
    response.headers["X-Request-ID"] = request_id
    log.info("%s %s -> %s (%.0f ms) rid=%s", request.method, request.url.path,
             response.status_code, elapsed_ms, request_id)
    return response


def _error(request: Request, status_code: int, detail) -> JSONResponse:
    return JSONResponse(
        status_code=status_code,
        content={"detail": detail, "request_id": getattr(request.state, "request_id", None)},
    )


@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    response = _error(request, exc.status_code, exc.detail)
    if exc.headers:
        response.headers.update(exc.headers)
    return response


@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    errors = [
        {"loc": list(e.get("loc", [])), "msg": str(e.get("msg", "")), "type": e.get("type")}
        for e in exc.errors()
    ]
    return _error(request, status.HTTP_422_UNPROCESSABLE_CONTENT, errors)


@app.exception_handler(OperationalError)
async def db_unavailable_handler(request: Request, exc: OperationalError):
    log.error("Database unavailable: %s", exc.orig)
    return _error(request, status.HTTP_503_SERVICE_UNAVAILABLE,
                  "Database unavailable. Check that PostgreSQL is running and DATABASE_URL is correct.")


@app.exception_handler(IntegrityError)
async def integrity_handler(request: Request, exc: IntegrityError):
    log.warning("Integrity error: %s", exc.orig)
    return _error(request, status.HTTP_409_CONFLICT, "This change conflicts with existing data.")


@app.exception_handler(SQLAlchemyError)
async def db_error_handler(request: Request, exc: SQLAlchemyError):
    log.exception("Database error")
    return _error(request, status.HTTP_500_INTERNAL_SERVER_ERROR, "A database error occurred.")


@app.exception_handler(Exception)
async def unhandled_handler(request: Request, exc: Exception):
    log.exception("Unhandled error rid=%s", getattr(request.state, "request_id", None))
    return _error(request, status.HTTP_500_INTERNAL_SERVER_ERROR, "Something went wrong. Please try again.")


# =============================================================================
# Helpers
# =============================================================================

def _period(month: Optional[int], year: Optional[int], cfg: Settings) -> tuple[int, int]:
    today = cfg.today()
    return month or today.month, year or today.year


DEMO_TERMS_VERSION = "demo"  # the shared demo account: never a research participant, never deletable


def _user_out(user: User) -> schemas.UserOut:
    out = schemas.UserOut.model_validate(user)
    out.terms_required = user.terms_accepted_at is None or         user.terms_version not in (settings.terms_version, DEMO_TERMS_VERSION)
    return out


def _token_response(user: User) -> schemas.TokenResponse:
    token, expires_in = create_access_token(user.id)
    return schemas.TokenResponse(access_token=token, expires_in=expires_in, user=_user_out(user))


def _check_terms_version(version: Optional[str]) -> None:
    # The app must have shown the current text; an outdated client gets a clear message instead.
    if version != settings.terms_version:
        raise HTTPException(status.HTTP_409_CONFLICT,
                            "The terms have been updated. Please update the app and review them again.")


def _get_owned_transaction(db: Session, transaction_id: int, user: User) -> Transaction:
    txn = db.get(Transaction, transaction_id)
    if txn is None or txn.user_id != user.id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Transaction not found")
    return txn


# =============================================================================
# System
# =============================================================================

@app.get("/health", response_model=schemas.HealthOut, tags=["system"])
def health(db: Session = Depends(get_db)) -> schemas.HealthOut:
    try:
        db.execute(text("SELECT 1"))
        database = "up"
    except SQLAlchemyError:
        database = "down"
    return schemas.HealthOut(
        status="ok",
        database=database,
        assistant_provider="claude" if settings.use_claude else "rules",
        version=API_VERSION,
    )


@app.get("/api/v1/categories", tags=["meta"])
def list_categories() -> dict[str, list[str]]:
    return {"all": CATEGORIES, "expense": EXPENSE_CATEGORIES, "income": INCOME_CATEGORIES}


# =============================================================================
# Auth
# =============================================================================

@app.post("/api/v1/auth/register", response_model=schemas.TokenResponse,
          status_code=status.HTTP_201_CREATED, tags=["auth"])
def register(payload: schemas.RegisterRequest, db: Session = Depends(get_db)) -> schemas.TokenResponse:
    email = payload.email.lower()
    if db.scalar(select(User.id).where(User.email == email)) is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, "An account with this email already exists")
    _check_terms_version(payload.terms_version)
    now = datetime.now(timezone.utc)
    user = User(
        full_name=payload.full_name.strip(),
        email=email,
        phone=payload.phone,
        password_hash=hash_password(payload.password),
        preferred_currency=payload.preferred_currency,
        monthly_income=payload.monthly_income,
        last_login_at=now,
        terms_accepted_at=now,  # server time, not the client's
        terms_version=payload.terms_version,
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    return _token_response(user)


@app.post("/api/v1/auth/login", response_model=schemas.TokenResponse, tags=["auth"])
def login(payload: schemas.LoginRequest, db: Session = Depends(get_db)) -> schemas.TokenResponse:
    user = db.scalar(select(User).where(User.email == payload.email.lower()))
    # Same message for unknown email and wrong password, so accounts can't be enumerated.
    if user is None or not verify_password(payload.password, user.password_hash):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Incorrect email or password")
    if not user.is_active:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "This account has been disabled")
    user.last_login_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(user)
    return _token_response(user)


@app.get("/api/v1/auth/me", response_model=schemas.UserOut, tags=["auth"])
def me(user: User = Depends(get_current_user)) -> schemas.UserOut:
    return _user_out(user)


@app.patch("/api/v1/auth/me", response_model=schemas.UserOut, tags=["auth"])
def update_me(payload: schemas.UserUpdate, user: User = Depends(get_current_user),
              db: Session = Depends(get_db)) -> schemas.UserOut:
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(user, field, value)
    db.commit()
    db.refresh(user)
    return _user_out(user)


@app.post("/api/v1/auth/me/accept-terms", response_model=schemas.UserOut, tags=["auth"])
def accept_terms(payload: schemas.AcceptTermsRequest, user: User = Depends(get_current_user),
                 db: Session = Depends(get_db)) -> schemas.UserOut:
    """Record consent for an existing account (created before consent existed, or after the terms changed)."""
    _check_terms_version(payload.terms_version)
    if user.terms_version != DEMO_TERMS_VERSION:
        user.terms_accepted_at = datetime.now(timezone.utc)
        user.terms_version = payload.terms_version
        db.commit()
        db.refresh(user)
    return _user_out(user)


@app.delete("/api/v1/auth/me", status_code=status.HTTP_204_NO_CONTENT, tags=["auth"])
def delete_account(payload: schemas.DeleteAccountRequest, user: User = Depends(get_current_user),
                   db: Session = Depends(get_db)) -> Response:
    """
    Permanently delete the account and all of its data: transactions, budgets, goals and AI logs
    (ON DELETE CASCADE). The password is required again so a stolen session can't wipe an account.
    Withdrawing from the study is done this way, so nothing about the user remains for exports.
    """
    if user.terms_version == DEMO_TERMS_VERSION:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "The shared demo account can't be deleted")
    if not verify_password(payload.password, user.password_hash):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Incorrect password")
    user_id = user.id
    db.delete(user)
    db.commit()
    log.info("Account deleted user_id=%s", user_id)  # no personal data in the log
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# =============================================================================
# Transactions
# =============================================================================

@app.post("/api/v1/transactions/parse", response_model=schemas.ParsedTransaction, tags=["transactions"])
def parse_transaction(payload: schemas.ParseRequest, user: User = Depends(get_current_user),
                      db: Session = Depends(get_db)) -> schemas.ParsedTransaction:
    """NLP pipeline: free text / voice transcript / SMS -> structured transaction preview. Nothing is saved."""
    started = time.perf_counter()
    result = extract_entities(payload.text, today=settings.today(), default_currency=user.preferred_currency)
    rule_category = result.category
    learned = personalize(db, user.id, result.normalized_text, result.merchant, result.type, rule_category)
    if learned:
        result.category, result.confidence = learned.category, learned.confidence
    category_source = "personal" if learned else "rules"
    db.add(AIFinancialLog(
        user_id=user.id,
        interaction_type="parse",
        input_text=payload.text,
        output_text=f"{result.type} {result.amount} {result.currency} {result.category} {result.merchant or ''}".strip(),
        intent=result.category,
        provider="rules",
        model=f"nisaab-nlp-rules-v1+{PERSONAL_MODEL}" if learned else "nisaab-nlp-rules-v1",
        confidence=result.confidence,
        context={**result.to_dict(), "transaction_date": result.transaction_date.isoformat(), "source": payload.source,
                 "rule_category": rule_category, "category_source": category_source,
                 "personal_reason": learned.reason if learned else None},
        latency_ms=int((time.perf_counter() - started) * 1000),
    ))
    db.commit()
    return schemas.ParsedTransaction(**result.to_dict(), source=payload.source, category_source=category_source)


@app.post("/api/v1/transactions", response_model=schemas.TransactionOut,
          status_code=status.HTTP_201_CREATED, tags=["transactions"])
def create_transaction(payload: schemas.TransactionCreate, user: User = Depends(get_current_user),
                       db: Session = Depends(get_db)) -> Transaction:
    data = payload.model_dump()
    data["transaction_date"] = data["transaction_date"] or settings.today()
    if data["transaction_date"] > settings.today() + timedelta(days=1):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Transaction date cannot be in the future")
    txn = Transaction(user_id=user.id, **data)
    db.add(txn)
    db.commit()
    db.refresh(txn)
    return txn


@app.get("/api/v1/transactions/{user_id}", response_model=schemas.TransactionPage, tags=["transactions"])
def list_transactions(
    user_id: int,
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    search: Optional[str] = Query(None, max_length=100, description="Matches merchant, description or original text"),
    category: Optional[str] = None,
    type: Optional[schemas.TransactionType] = None,
    source: Optional[schemas.TransactionSource] = None,
    date_from: Optional[date] = None,
    date_to: Optional[date] = None,
    month: Optional[int] = Query(None, ge=1, le=12),
    year: Optional[int] = Query(None, ge=2000, le=2100),
    min_amount: Optional[float] = Query(None, ge=0),
    max_amount: Optional[float] = Query(None, ge=0),
    sort: Literal["date_desc", "date_asc", "amount_desc", "amount_asc"] = "date_desc",
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> schemas.TransactionPage:
    ensure_owner(user_id, user)

    filters = [Transaction.user_id == user_id]
    if search:
        pattern = f"%{search.strip()}%"
        filters.append(or_(Transaction.merchant.ilike(pattern), Transaction.description.ilike(pattern),
                           Transaction.raw_text.ilike(pattern), Transaction.category.ilike(pattern)))
    if category:
        filters.append(Transaction.category == category)
    if type:
        filters.append(Transaction.type == type)
    if source:
        filters.append(Transaction.source == source)
    if month or year:
        if not (month and year):
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Provide both month and year")
        start, end = month_bounds(year, month)
        filters += [Transaction.transaction_date >= start, Transaction.transaction_date < end]
    if date_from:
        filters.append(Transaction.transaction_date >= date_from)
    if date_to:
        filters.append(Transaction.transaction_date <= date_to)
    if min_amount is not None:
        filters.append(Transaction.amount >= min_amount)
    if max_amount is not None:
        filters.append(Transaction.amount <= max_amount)

    total, income, expense = db.execute(
        select(
            func.count(Transaction.id),
            func.coalesce(func.sum(case((Transaction.type == "income", Transaction.amount), else_=0)), 0),
            func.coalesce(func.sum(case((Transaction.type == "expense", Transaction.amount), else_=0)), 0),
        ).where(*filters)
    ).one()

    order = {
        "date_desc": (Transaction.transaction_date.desc(), Transaction.id.desc()),
        "date_asc": (Transaction.transaction_date.asc(), Transaction.id.asc()),
        "amount_desc": (Transaction.amount.desc(), Transaction.id.desc()),
        "amount_asc": (Transaction.amount.asc(), Transaction.id.asc()),
    }[sort]
    items = db.scalars(
        select(Transaction).where(*filters).order_by(*order)
        .limit(page_size).offset((page - 1) * page_size)
    ).all()

    return schemas.TransactionPage(
        items=[schemas.TransactionOut.model_validate(t) for t in items],
        total=total,
        page=page,
        page_size=page_size,
        pages=max(1, math.ceil(total / page_size)),
        total_income=float(income),
        total_expense=float(expense),
    )


@app.get("/api/v1/transactions/{user_id}/export", tags=["transactions"],
         response_class=Response, responses={200: {"content": {"text/csv": {}}}})
def export_transactions(
    user_id: int,
    date_from: Optional[date] = None,
    date_to: Optional[date] = None,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Response:
    """All of the user's transactions (optionally within a date range) as a CSV file."""
    ensure_owner(user_id, user)
    filters = [Transaction.user_id == user_id]
    if date_from:
        filters.append(Transaction.transaction_date >= date_from)
    if date_to:
        filters.append(Transaction.transaction_date <= date_to)
    rows = db.scalars(select(Transaction).where(*filters)
                      .order_by(Transaction.transaction_date.desc(), Transaction.id.desc())).all()

    buf = io.StringIO()
    buf.write("﻿")  # BOM so Excel opens the file as UTF-8
    writer = csv.writer(buf)
    writer.writerow(["date", "type", "category", "amount", "currency", "merchant", "description",
                     "source", "original_text"])
    for t in rows:
        writer.writerow([t.transaction_date.isoformat(), t.type, t.category, f"{t.amount:.2f}", t.currency,
                         t.merchant or "", t.description or "", t.source, t.raw_text or ""])
    filename = f"nisaab-transactions-{settings.today().isoformat()}.csv"
    return Response(buf.getvalue(), media_type="text/csv; charset=utf-8",
                    headers={"Content-Disposition": f'attachment; filename="{filename}"'})


@app.patch("/api/v1/transactions/{transaction_id}", response_model=schemas.TransactionOut, tags=["transactions"])
def update_transaction(transaction_id: int, payload: schemas.TransactionUpdate,
                       user: User = Depends(get_current_user), db: Session = Depends(get_db)) -> Transaction:
    txn = _get_owned_transaction(db, transaction_id, user)
    changes = payload.model_dump(exclude_unset=True)
    for field in ("type", "category", "amount", "currency", "transaction_date"):
        if field in changes and changes[field] is None:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, f"{field} cannot be empty")

    new_type = changes.get("type", txn.type)
    new_category = changes.get("category", txn.category)
    allowed = INCOME_CATEGORIES if new_type == "income" else EXPENSE_CATEGORIES
    if new_category not in allowed:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT,
                            f"category '{new_category}' is not valid for {new_type}")
    if "transaction_date" in changes and changes["transaction_date"] > settings.today() + timedelta(days=1):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Transaction date cannot be in the future")

    # Editing what the AI extracted is a correction signal for classifier training.
    if txn.raw_text and any(k in changes and changes[k] != getattr(txn, k) for k in ("category", "type", "amount")):
        txn.user_corrected = True
    for field, value in changes.items():
        setattr(txn, field, value)
    db.commit()
    db.refresh(txn)
    return txn


@app.delete("/api/v1/transactions/{transaction_id}", status_code=status.HTTP_204_NO_CONTENT, tags=["transactions"])
def delete_transaction(transaction_id: int, user: User = Depends(get_current_user),
                       db: Session = Depends(get_db)) -> Response:
    txn = _get_owned_transaction(db, transaction_id, user)
    db.delete(txn)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# =============================================================================
# Budgets
# =============================================================================

@app.post("/api/v1/budgets", response_model=schemas.BudgetOut, tags=["budgets"])
def upsert_budget(payload: schemas.BudgetUpsert, response: Response, user: User = Depends(get_current_user),
                  db: Session = Depends(get_db)) -> dict:
    """Create the limit for a category/month, or update it if one already exists."""
    month, year = _period(payload.month, payload.year, settings)
    period = date(year, month, 1)
    budget = db.scalar(select(Budget).where(
        Budget.user_id == user.id, Budget.category == payload.category, Budget.month_year == period))
    if budget is None:
        budget = Budget(user_id=user.id, category=payload.category, month_year=period)
        db.add(budget)
        response.status_code = status.HTTP_201_CREATED
    budget.monthly_limit = payload.monthly_limit
    budget.currency = payload.currency
    budget.alert_threshold = payload.alert_threshold
    db.commit()
    return next(b for b in budgets_with_spend(db, user.id, period) if b["category"] == payload.category)


@app.get("/api/v1/budgets/{user_id}", response_model=list[schemas.BudgetOut], tags=["budgets"])
def list_budgets(
    user_id: int,
    month: Optional[int] = Query(None, ge=1, le=12, description="Defaults to the current month"),
    year: Optional[int] = Query(None, ge=2000, le=2100, description="Defaults to the current year"),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    ensure_owner(user_id, user)
    month, year = _period(month, year, settings)
    return budgets_with_spend(db, user_id, date(year, month, 1))


@app.delete("/api/v1/budgets/{budget_id}", status_code=status.HTTP_204_NO_CONTENT, tags=["budgets"])
def delete_budget(budget_id: int, user: User = Depends(get_current_user), db: Session = Depends(get_db)) -> Response:
    budget = db.get(Budget, budget_id)
    if budget is None or budget.user_id != user.id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Budget not found")
    db.delete(budget)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# =============================================================================
# Savings goals
# =============================================================================

def _goal_out(goal: SavingsGoal) -> schemas.GoalOut:
    started = goal.created_at.astimezone(settings.tz).date() if goal.created_at else settings.today()
    percent, remaining, monthly_needed, goal_status = goal_progress(
        float(goal.target_amount), float(goal.saved_amount), goal.target_date, started, settings.today())
    return schemas.GoalOut(
        id=goal.id, user_id=goal.user_id, name=goal.name, target_amount=float(goal.target_amount),
        saved_amount=float(goal.saved_amount), currency=goal.currency, target_date=goal.target_date,
        percent=percent, remaining=remaining, monthly_needed=monthly_needed, status=goal_status,
        created_at=goal.created_at,
    )


def _get_owned_goal(db: Session, goal_id: int, user: User) -> SavingsGoal:
    goal = db.get(SavingsGoal, goal_id)
    if goal is None or goal.user_id != user.id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Goal not found")
    return goal


@app.post("/api/v1/goals", response_model=schemas.GoalOut, status_code=status.HTTP_201_CREATED, tags=["goals"])
def create_goal(payload: schemas.GoalCreate, user: User = Depends(get_current_user),
                db: Session = Depends(get_db)) -> schemas.GoalOut:
    if payload.target_date and payload.target_date < settings.today():
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Target date cannot be in the past")
    goal = SavingsGoal(user_id=user.id, **payload.model_dump())
    goal.name = goal.name.strip()
    db.add(goal)
    db.commit()
    db.refresh(goal)
    return _goal_out(goal)


@app.get("/api/v1/goals/{user_id}", response_model=list[schemas.GoalOut], tags=["goals"])
def list_goals(user_id: int, user: User = Depends(get_current_user),
               db: Session = Depends(get_db)) -> list[schemas.GoalOut]:
    ensure_owner(user_id, user)
    goals = db.scalars(select(SavingsGoal).where(SavingsGoal.user_id == user_id)
                       .order_by(SavingsGoal.created_at, SavingsGoal.id)).all()
    return [_goal_out(g) for g in goals]


@app.patch("/api/v1/goals/{goal_id}", response_model=schemas.GoalOut, tags=["goals"])
def update_goal(goal_id: int, payload: schemas.GoalUpdate, user: User = Depends(get_current_user),
                db: Session = Depends(get_db)) -> schemas.GoalOut:
    goal = _get_owned_goal(db, goal_id, user)
    changes = payload.model_dump(exclude_unset=True)
    for field in ("name", "target_amount", "saved_amount"):
        if field in changes and changes[field] is None:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, f"{field} cannot be empty")
    for field, value in changes.items():
        setattr(goal, field, value.strip() if field == "name" else value)
    db.commit()
    db.refresh(goal)
    return _goal_out(goal)


@app.post("/api/v1/goals/{goal_id}/contribute", response_model=schemas.GoalOut, tags=["goals"])
def contribute_to_goal(goal_id: int, payload: schemas.GoalContribution, user: User = Depends(get_current_user),
                       db: Session = Depends(get_db)) -> schemas.GoalOut:
    goal = _get_owned_goal(db, goal_id, user)
    new_amount = goal.saved_amount + payload.amount
    if new_amount < 0:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "You can't withdraw more than you've saved")
    goal.saved_amount = new_amount
    db.commit()
    db.refresh(goal)
    return _goal_out(goal)


@app.delete("/api/v1/goals/{goal_id}", status_code=status.HTTP_204_NO_CONTENT, tags=["goals"])
def delete_goal(goal_id: int, user: User = Depends(get_current_user), db: Session = Depends(get_db)) -> Response:
    db.delete(_get_owned_goal(db, goal_id, user))
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# =============================================================================
# Analytics & forecasting
# =============================================================================

@app.get("/api/v1/analytics/summary/{user_id}", response_model=schemas.MonthlySummary, tags=["analytics"])
def monthly_summary(
    user_id: int,
    month: Optional[int] = Query(None, ge=1, le=12),
    year: Optional[int] = Query(None, ge=2000, le=2100),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> schemas.MonthlySummary:
    ensure_owner(user_id, user)
    month, year = _period(month, year, settings)
    start, end = month_bounds(year, month)

    income, expense, count = totals_for_period(db, user_id, start, end)
    _, prev_expense, _ = totals_for_period(db, user_id, add_months(start, -1), start)

    cat_rows = db.execute(
        select(Transaction.category, func.sum(Transaction.amount), func.count(Transaction.id))
        .where(Transaction.user_id == user_id, Transaction.type == "expense",
               Transaction.transaction_date >= start, Transaction.transaction_date < end)
        .group_by(Transaction.category)
        .order_by(func.sum(Transaction.amount).desc())
    ).all()
    by_category = [
        schemas.CategorySpend(category=c, amount=float(a), share=round(float(a) / expense * 100, 1) if expense else 0.0,
                              transaction_count=n)
        for c, a, n in cat_rows
    ]

    daily_rows = db.execute(
        select(
            Transaction.transaction_date,
            func.sum(case((Transaction.type == "expense", Transaction.amount), else_=0)),
            func.sum(case((Transaction.type == "income", Transaction.amount), else_=0)),
        )
        .where(Transaction.user_id == user_id, Transaction.transaction_date >= start, Transaction.transaction_date < end)
        .group_by(Transaction.transaction_date)
    ).all()
    by_day = {d: (float(e), float(i)) for d, e, i in daily_rows}
    last_day = min(end - timedelta(days=1), settings.today()) if start <= settings.today() else end - timedelta(days=1)
    daily = []
    d = start
    while d <= last_day:
        e, i = by_day.get(d, (0.0, 0.0))
        daily.append(schemas.DailyPoint(date=d, expense=e, income=i))
        d += timedelta(days=1)

    net = round(income - expense, 2)
    return schemas.MonthlySummary(
        month=month,
        year=year,
        total_income=income,
        total_expense=expense,
        net_savings=net,
        savings_rate=round(net / income * 100, 1) if income else 0.0,
        transaction_count=count,
        previous_month_expense=prev_expense,
        expense_change_pct=round((expense - prev_expense) / prev_expense * 100, 1) if prev_expense else None,
        by_category=by_category,
        daily=daily,
        budgets=[schemas.BudgetOut(**b) for b in budgets_with_spend(db, user_id, start)],
    )


@app.get("/api/v1/analytics/forecast/{user_id}", response_model=schemas.ForecastOut, tags=["analytics"])
def forecast(user_id: int, user: User = Depends(get_current_user), db: Session = Depends(get_db)) -> dict:
    """Month-end projection per category, overspending risk and next-month forecast."""
    ensure_owner(user_id, user)
    return build_forecast_report(db, user_id, settings.today()).to_dict()


# =============================================================================
# AI assistant
# =============================================================================

@app.post("/api/v1/ai/assistant", response_model=schemas.AssistantResponse, tags=["ai"])
def ask_assistant(payload: schemas.AssistantRequest, user: User = Depends(get_current_user),
                  db: Session = Depends(get_db)) -> schemas.AssistantResponse:
    """Context-aware financial guidance grounded in the user's own transactions, budgets and forecast."""
    result = ai_assistant.answer(
        db, settings, user, payload.message.strip(),
        [turn.model_dump() for turn in payload.history],
    )
    return schemas.AssistantResponse(
        reply=result.reply, intent=result.intent, provider=result.provider,
        suggestions=result.suggestions, log_id=result.log_id,
    )


@app.get("/api/v1/ai/assistant/history", response_model=list[schemas.AssistantHistoryItem], tags=["ai"])
def assistant_history(limit: int = Query(30, ge=1, le=100), user: User = Depends(get_current_user),
                      db: Session = Depends(get_db)) -> list[schemas.AssistantHistoryItem]:
    rows = db.scalars(
        select(AIFinancialLog)
        .where(AIFinancialLog.user_id == user.id, AIFinancialLog.interaction_type == "assistant")
        .order_by(AIFinancialLog.created_at.desc(), AIFinancialLog.id.desc())
        .limit(limit)
    ).all()
    return [
        schemas.AssistantHistoryItem(id=r.id, message=r.input_text, reply=r.output_text, intent=r.intent,
                                     provider=r.provider, created_at=r.created_at)
        for r in reversed(rows)
    ]


# =============================================================================
# Optional web app (mounted last so every API route above takes precedence)
# =============================================================================

if settings.web_dir:
    app.mount("/", StaticFiles(directory=settings.web_dir, html=True), name="web")
