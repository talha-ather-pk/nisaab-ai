"""Application settings, loaded from environment variables or a .env file."""

from __future__ import annotations

from datetime import date, datetime
from functools import lru_cache
from typing import Literal
from zoneinfo import ZoneInfo

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    app_name: str = "Nisaab AI API"
    environment: Literal["development", "production", "test"] = "development"

    # Database
    database_url: str = "postgresql+psycopg://nisaab:nisaab@localhost:5432/nisaab"
    db_pool_size: int = 5
    db_max_overflow: int = 10
    db_echo: bool = False

    # Auth
    jwt_secret: str = Field(default="change-me-in-production-use-a-64-char-random-string", min_length=32)
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 60 * 24 * 7  # 7 days for a mobile client

    # HTTP
    cors_origins: str = "*"

    # Locale
    timezone: str = "Asia/Karachi"
    default_currency: str = "PKR"

    # AI assistant: "auto" uses Claude when ANTHROPIC_API_KEY is set, otherwise the rule engine.
    assistant_provider: Literal["auto", "claude", "rules"] = "auto"
    anthropic_api_key: str | None = None
    assistant_model: str = "claude-opus-5-5"
    assistant_timeout_seconds: float = 45.0

    # Version of the terms & research-consent text shown in the app (mobile/lib/core/terms.dart).
    # Bump both together when the text changes; users who accepted an older version are asked again.
    terms_version: str = "2026.10"

    # Optional: path to a Flutter web build (mobile/build/web) to serve at "/" from the same origin.
    web_dir: str | None = None

    @field_validator("database_url")
    @classmethod
    def use_psycopg3_driver(cls, v: str) -> str:
        # Accept plain postgres URLs (Heroku/Railway style) and route them to psycopg 3.
        if v.startswith("postgres://"):
            v = "postgresql://" + v[len("postgres://"):]
        if v.startswith("postgresql://"):
            v = "postgresql+psycopg://" + v[len("postgresql://"):]
        return v

    @property
    def cors_origin_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]

    @property
    def tz(self) -> ZoneInfo:
        return ZoneInfo(self.timezone)

    def today(self) -> date:
        return datetime.now(self.tz).date()

    @property
    def use_claude(self) -> bool:
        if self.assistant_provider == "rules":
            return False
        if self.assistant_provider == "claude":
            return True
        return bool(self.anthropic_api_key)


@lru_cache
def get_settings() -> Settings:
    return Settings()
