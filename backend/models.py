"""SQLAlchemy ORM models. Mirrors database/schema.sql (the production source of truth)."""

from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal
from typing import Any, Optional

from sqlalchemy import (
    JSON,
    BigInteger,
    Boolean,
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from database import Base

# BIGSERIAL on Postgres, INTEGER PRIMARY KEY (rowid alias) on SQLite for tests.
BigIntPK = BigInteger().with_variant(Integer, "sqlite")
JSONType = JSON().with_variant(JSONB, "postgresql")

TRANSACTION_TYPES = ("expense", "income")
TRANSACTION_SOURCES = ("text", "voice", "sms", "manual")
AI_INTERACTION_TYPES = ("parse", "assistant", "forecast")
AI_PROVIDERS = ("rules", "claude")


def _in(column: str, values: tuple[str, ...]) -> str:
    return f"{column} IN ({', '.join(repr(v) for v in values)})"


class TimestampMixin:
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )


class User(TimestampMixin, Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(BigIntPK, primary_key=True, autoincrement=True)
    full_name: Mapped[str] = mapped_column(String(120), nullable=False)
    email: Mapped[str] = mapped_column(String(255), nullable=False, unique=True)  # stored lower-case
    phone: Mapped[Optional[str]] = mapped_column(String(20))
    password_hash: Mapped[str] = mapped_column(Text, nullable=False)
    preferred_currency: Mapped[str] = mapped_column(String(3), nullable=False, default="PKR")
    monthly_income: Mapped[Optional[Decimal]] = mapped_column(Numeric(14, 2))
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    last_login_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    # Research consent: when and which version of the terms the user accepted (NULL = not yet).
    terms_accepted_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    terms_version: Mapped[Optional[str]] = mapped_column(String(20))

    transactions: Mapped[list["Transaction"]] = relationship(
        back_populates="user", cascade="all, delete-orphan", passive_deletes=True
    )
    budgets: Mapped[list["Budget"]] = relationship(
        back_populates="user", cascade="all, delete-orphan", passive_deletes=True
    )
    goals: Mapped[list["SavingsGoal"]] = relationship(
        back_populates="user", cascade="all, delete-orphan", passive_deletes=True
    )

    __table_args__ = (
        CheckConstraint("monthly_income IS NULL OR monthly_income >= 0", name="users_income_nonneg"),
    )


class Transaction(TimestampMixin, Base):
    __tablename__ = "transactions"

    id: Mapped[int] = mapped_column(BigIntPK, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(
        BigInteger().with_variant(Integer, "sqlite"),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    amount: Mapped[Decimal] = mapped_column(Numeric(14, 2), nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="PKR")
    type: Mapped[str] = mapped_column(String(10), nullable=False)
    category: Mapped[str] = mapped_column(String(40), nullable=False, default="Other")
    merchant: Mapped[Optional[str]] = mapped_column(String(120))
    description: Mapped[Optional[str]] = mapped_column(String(255))
    raw_text: Mapped[Optional[str]] = mapped_column(Text)
    source: Mapped[str] = mapped_column(String(10), nullable=False, default="manual")
    ai_confidence: Mapped[Optional[Decimal]] = mapped_column(Numeric(4, 3))
    user_corrected: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    transaction_date: Mapped[date] = mapped_column(Date, nullable=False)

    user: Mapped[User] = relationship(back_populates="transactions")

    __table_args__ = (
        CheckConstraint("amount > 0", name="transactions_amount_positive"),
        CheckConstraint(_in("type", TRANSACTION_TYPES), name="transactions_type_check"),
        CheckConstraint(_in("source", TRANSACTION_SOURCES), name="transactions_source_check"),
        CheckConstraint(
            "ai_confidence IS NULL OR (ai_confidence >= 0 AND ai_confidence <= 1)",
            name="transactions_confidence_range",
        ),
        Index("transactions_user_date_idx", "user_id", "transaction_date", "id"),
        Index("transactions_user_category_date_idx", "user_id", "category", "transaction_date"),
        Index("transactions_created_at_idx", "created_at"),
    )


class Budget(TimestampMixin, Base):
    __tablename__ = "budgets"

    id: Mapped[int] = mapped_column(BigIntPK, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(
        BigInteger().with_variant(Integer, "sqlite"),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    category: Mapped[str] = mapped_column(String(40), nullable=False)
    monthly_limit: Mapped[Decimal] = mapped_column(Numeric(14, 2), nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="PKR")
    month_year: Mapped[date] = mapped_column(Date, nullable=False)  # always the 1st of the month
    alert_threshold: Mapped[int] = mapped_column(Integer, nullable=False, default=80)  # percent

    user: Mapped[User] = relationship(back_populates="budgets")

    __table_args__ = (
        CheckConstraint("monthly_limit > 0", name="budgets_limit_positive"),
        CheckConstraint("alert_threshold BETWEEN 1 AND 100", name="budgets_threshold_range"),
        UniqueConstraint("user_id", "category", "month_year", name="budgets_user_category_period_uq"),
        Index("budgets_user_month_year_idx", "user_id", "month_year"),
    )


class SavingsGoal(TimestampMixin, Base):
    __tablename__ = "savings_goals"

    id: Mapped[int] = mapped_column(BigIntPK, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(
        BigInteger().with_variant(Integer, "sqlite"),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    name: Mapped[str] = mapped_column(String(80), nullable=False)
    target_amount: Mapped[Decimal] = mapped_column(Numeric(14, 2), nullable=False)
    saved_amount: Mapped[Decimal] = mapped_column(Numeric(14, 2), nullable=False, default=Decimal("0"))
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="PKR")
    target_date: Mapped[Optional[date]] = mapped_column(Date)

    user: Mapped[User] = relationship(back_populates="goals")

    __table_args__ = (
        CheckConstraint("target_amount > 0", name="goals_target_positive"),
        CheckConstraint("saved_amount >= 0", name="goals_saved_non_negative"),
        Index("goals_user_idx", "user_id"),
    )


class AIFinancialLog(Base):
    __tablename__ = "ai_financial_logs"

    id: Mapped[int] = mapped_column(BigIntPK, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(
        BigInteger().with_variant(Integer, "sqlite"),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    interaction_type: Mapped[str] = mapped_column(String(20), nullable=False)
    input_text: Mapped[str] = mapped_column(Text, nullable=False)
    output_text: Mapped[Optional[str]] = mapped_column(Text)
    intent: Mapped[Optional[str]] = mapped_column(String(40))
    provider: Mapped[str] = mapped_column(String(20), nullable=False, default="rules")
    model: Mapped[Optional[str]] = mapped_column(String(80))
    confidence: Mapped[Optional[Decimal]] = mapped_column(Numeric(4, 3))
    context: Mapped[Optional[dict[str, Any]]] = mapped_column(JSONType)
    latency_ms: Mapped[Optional[int]] = mapped_column(Integer)
    input_tokens: Mapped[Optional[int]] = mapped_column(Integer)
    output_tokens: Mapped[Optional[int]] = mapped_column(Integer)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    __table_args__ = (
        CheckConstraint(_in("interaction_type", AI_INTERACTION_TYPES), name="ai_logs_type_check"),
        CheckConstraint(_in("provider", AI_PROVIDERS), name="ai_logs_provider_check"),
        Index("ai_logs_user_created_idx", "user_id", "created_at"),
        Index("ai_logs_type_created_idx", "interaction_type", "created_at"),
    )
