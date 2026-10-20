"""Pydantic request/response schemas (API contract v1)."""

from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal
from typing import Literal, Optional

from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator, model_validator

from nlp_engine import CATEGORIES, EXPENSE_CATEGORIES, INCOME_CATEGORIES

TransactionType = Literal["expense", "income"]
TransactionSource = Literal["text", "voice", "sms", "manual"]
BudgetStatus = Literal["ok", "warning", "exceeded"]

Money = Field(gt=0, max_digits=14, decimal_places=2)


def _currency(v: str) -> str:
    v = v.strip().upper()
    if len(v) != 3 or not v.isalpha():
        raise ValueError("currency must be a 3-letter ISO code")
    return v


def _category(v: str) -> str:
    if v not in CATEGORIES:
        raise ValueError(f"category must be one of: {', '.join(CATEGORIES)}")
    return v


class ORMModel(BaseModel):
    model_config = ConfigDict(from_attributes=True)


# =============================================================================
# Auth & users
# =============================================================================

class RegisterRequest(BaseModel):
    full_name: str = Field(min_length=2, max_length=120)
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    phone: Optional[str] = Field(default=None, max_length=20, pattern=r"^\+?[0-9\- ]{7,20}$")
    preferred_currency: str = "PKR"
    monthly_income: Optional[Decimal] = Field(default=None, ge=0, max_digits=14, decimal_places=2)
    # Consent is mandatory: the app is the research instrument of the pilot study.
    accept_terms: bool = Field(default=False, validate_default=True)  # missing counts as "not accepted"
    terms_version: Optional[str] = Field(default=None, max_length=20)

    @field_validator("preferred_currency")
    @classmethod
    def valid_currency(cls, v: str) -> str:
        return _currency(v)

    @field_validator("accept_terms")
    @classmethod
    def must_accept(cls, v: bool) -> bool:
        if not v:
            raise ValueError("you must accept the terms and research consent to create an account")
        return v

    @field_validator("password")
    @classmethod
    def strong_enough(cls, v: str) -> str:
        if not any(c.isalpha() for c in v) or not any(c.isdigit() for c in v):
            raise ValueError("password must contain at least one letter and one number")
        return v


class LoginRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1, max_length=128)


class UserOut(ORMModel):
    id: int
    full_name: str
    email: str
    phone: Optional[str]
    preferred_currency: str
    monthly_income: Optional[float]
    created_at: datetime
    terms_accepted_at: Optional[datetime]
    terms_version: Optional[str]
    # True when the user has not accepted the current terms version and must be asked (again).
    terms_required: bool = False


class AcceptTermsRequest(BaseModel):
    terms_version: str = Field(max_length=20)


class DeleteAccountRequest(BaseModel):
    password: str = Field(min_length=1, max_length=128)


class UserUpdate(BaseModel):
    full_name: Optional[str] = Field(default=None, min_length=2, max_length=120)
    phone: Optional[str] = Field(default=None, max_length=20, pattern=r"^\+?[0-9\- ]{7,20}$")
    monthly_income: Optional[Decimal] = Field(default=None, ge=0, max_digits=14, decimal_places=2)


class TokenResponse(BaseModel):
    access_token: str
    token_type: Literal["bearer"] = "bearer"
    expires_in: int
    user: UserOut


# =============================================================================
# NLP parsing
# =============================================================================

class ParseRequest(BaseModel):
    text: str = Field(min_length=1, max_length=1000, examples=["Spent 1,200 rupees on groceries at Carrefour"])
    source: TransactionSource = "text"


class ParsedTransaction(BaseModel):
    amount: Optional[float]
    currency: str
    type: TransactionType
    category: str
    merchant: Optional[str]
    description: Optional[str]
    transaction_date: date
    confidence: float
    missing_fields: list[str]
    raw_text: str
    normalized_text: str
    source: TransactionSource
    # "personal" when the category was learned from this user's own corrections.
    category_source: Literal["rules", "personal"] = "rules"


# =============================================================================
# Transactions
# =============================================================================

class TransactionCreate(BaseModel):
    amount: Decimal = Money
    currency: str = "PKR"
    type: TransactionType = "expense"
    category: str = "Other"
    merchant: Optional[str] = Field(default=None, max_length=120)
    description: Optional[str] = Field(default=None, max_length=255)
    raw_text: Optional[str] = Field(default=None, max_length=1000)
    source: TransactionSource = "manual"
    ai_confidence: Optional[float] = Field(default=None, ge=0, le=1)
    user_corrected: bool = False
    transaction_date: Optional[date] = None  # defaults to "today" in the user's timezone

    @field_validator("currency")
    @classmethod
    def valid_currency(cls, v: str) -> str:
        return _currency(v)

    @field_validator("category")
    @classmethod
    def valid_category(cls, v: str) -> str:
        return _category(v)

    @field_validator("merchant", "description", "raw_text")
    @classmethod
    def blank_to_none(cls, v: Optional[str]) -> Optional[str]:
        v = v.strip() if v else v
        return v or None

    @model_validator(mode="after")
    def category_matches_type(self) -> "TransactionCreate":
        allowed = INCOME_CATEGORIES if self.type == "income" else EXPENSE_CATEGORIES
        if self.category not in allowed:
            raise ValueError(f"category '{self.category}' is not valid for {self.type}")
        return self


class TransactionUpdate(BaseModel):
    amount: Optional[Decimal] = Field(default=None, gt=0, max_digits=14, decimal_places=2)
    currency: Optional[str] = None
    type: Optional[TransactionType] = None
    category: Optional[str] = None
    merchant: Optional[str] = Field(default=None, max_length=120)
    description: Optional[str] = Field(default=None, max_length=255)
    transaction_date: Optional[date] = None

    @field_validator("currency")
    @classmethod
    def cur(cls, v: Optional[str]) -> Optional[str]:
        return _currency(v) if v is not None else v

    @field_validator("category")
    @classmethod
    def cat(cls, v: Optional[str]) -> Optional[str]:
        return _category(v) if v is not None else v


class TransactionOut(ORMModel):
    id: int
    user_id: int
    amount: float
    currency: str
    type: TransactionType
    category: str
    merchant: Optional[str]
    description: Optional[str]
    raw_text: Optional[str]
    source: TransactionSource
    ai_confidence: Optional[float]
    user_corrected: bool
    transaction_date: date
    created_at: datetime
    updated_at: datetime


class TransactionPage(BaseModel):
    items: list[TransactionOut]
    total: int
    page: int
    page_size: int
    pages: int
    total_income: float
    total_expense: float


# =============================================================================
# Budgets
# =============================================================================

class BudgetUpsert(BaseModel):
    category: str
    monthly_limit: Decimal = Money
    currency: str = "PKR"
    month: Optional[int] = Field(default=None, ge=1, le=12)
    year: Optional[int] = Field(default=None, ge=2000, le=2100)
    alert_threshold: int = Field(default=80, ge=1, le=100)

    @field_validator("currency")
    @classmethod
    def valid_currency(cls, v: str) -> str:
        return _currency(v)

    @field_validator("category")
    @classmethod
    def spending_category(cls, v: str) -> str:
        if v not in EXPENSE_CATEGORIES:
            raise ValueError(f"budgets can only be set on spending categories: {', '.join(EXPENSE_CATEGORIES)}")
        return v


GoalStatus = Literal["completed", "on_track", "behind", "overdue", "no_deadline"]


class GoalCreate(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    target_amount: Decimal = Money
    saved_amount: Decimal = Field(default=Decimal("0"), ge=0, max_digits=14, decimal_places=2)
    currency: str = "PKR"
    target_date: Optional[date] = None

    @field_validator("currency")
    @classmethod
    def valid_currency(cls, v: str) -> str:
        return _currency(v)


class GoalUpdate(BaseModel):
    name: Optional[str] = Field(default=None, min_length=1, max_length=80)
    target_amount: Optional[Decimal] = Field(default=None, gt=0, max_digits=14, decimal_places=2)
    saved_amount: Optional[Decimal] = Field(default=None, ge=0, max_digits=14, decimal_places=2)
    target_date: Optional[date] = None


class GoalContribution(BaseModel):
    # Negative amounts record a withdrawal from the goal.
    amount: Decimal = Field(max_digits=14, decimal_places=2)

    @field_validator("amount")
    @classmethod
    def non_zero(cls, v: Decimal) -> Decimal:
        if v == 0:
            raise ValueError("amount cannot be zero")
        return v


class GoalOut(BaseModel):
    id: int
    user_id: int
    name: str
    target_amount: float
    saved_amount: float
    currency: str
    target_date: Optional[date]
    percent: float
    remaining: float
    monthly_needed: Optional[float]  # to reach the target by target_date
    status: GoalStatus
    created_at: datetime


class BudgetOut(BaseModel):
    id: int
    user_id: int
    category: str
    monthly_limit: float
    currency: str
    month: int
    year: int
    month_year: date
    alert_threshold: int
    spent: float
    remaining: float
    percent_used: float
    status: BudgetStatus


# =============================================================================
# Analytics
# =============================================================================

class CategorySpend(BaseModel):
    category: str
    amount: float
    share: float  # percent of total expense
    transaction_count: int


class DailyPoint(BaseModel):
    date: date
    expense: float
    income: float


class MonthlySummary(BaseModel):
    month: int
    year: int
    total_income: float
    total_expense: float
    net_savings: float
    savings_rate: float
    transaction_count: int
    previous_month_expense: float
    expense_change_pct: Optional[float]
    by_category: list[CategorySpend]
    daily: list[DailyPoint]
    budgets: list[BudgetOut]


class CategoryForecastOut(BaseModel):
    category: str
    spent_to_date: float
    projected_month_end: float
    historical_avg: Optional[float]
    next_month_forecast: Optional[float]
    trend_pct: Optional[float]
    monthly_limit: Optional[float]
    recommended_budget: Optional[float]
    risk: Literal["no_budget", "on_track", "at_risk", "likely_over", "exceeded"]
    projected_overrun: float
    message: str


class ForecastOut(BaseModel):
    as_of: date
    month: int
    year: int
    days_elapsed: int
    days_in_month: int
    projected_total_expense: float
    projected_total_income: float
    projected_savings: float
    next_month_total_forecast: Optional[float]
    categories: list[CategoryForecastOut]
    alerts: list[str]


# =============================================================================
# AI assistant
# =============================================================================

class ChatTurn(BaseModel):
    role: Literal["user", "assistant"]
    content: str = Field(min_length=1, max_length=4000)


class AssistantRequest(BaseModel):
    message: str = Field(min_length=1, max_length=1000)
    history: list[ChatTurn] = Field(default_factory=list, max_length=20)


class AssistantResponse(BaseModel):
    reply: str
    intent: str
    provider: Literal["rules", "claude"]
    suggestions: list[str]
    log_id: int


class AssistantHistoryItem(BaseModel):
    id: int
    message: str
    reply: Optional[str]
    intent: Optional[str]
    provider: str
    created_at: datetime


# =============================================================================
# Misc
# =============================================================================

class HealthOut(BaseModel):
    status: Literal["ok"]
    database: Literal["up", "down"]
    assistant_provider: Literal["rules", "claude"]
    version: str


class ErrorOut(BaseModel):
    detail: str | list
    request_id: Optional[str] = None
