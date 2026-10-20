"""Password hashing, JWT access tokens and the authenticated-user dependency."""

from __future__ import annotations

import base64
import hashlib
from datetime import datetime, timedelta, timezone

import bcrypt
import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from config import get_settings
from database import get_db
from models import User

_bearer = HTTPBearer(auto_error=False, description="JWT from /api/v1/auth/login")


def _prehash(password: str) -> bytes:
    # bcrypt only reads the first 72 bytes; SHA-256 first so long passphrases keep full entropy.
    return base64.b64encode(hashlib.sha256(password.encode("utf-8")).digest())


def hash_password(password: str) -> str:
    return bcrypt.hashpw(_prehash(password), bcrypt.gensalt(rounds=12)).decode("ascii")


def verify_password(password: str, password_hash: str) -> bool:
    try:
        return bcrypt.checkpw(_prehash(password), password_hash.encode("ascii"))
    except ValueError:
        return False


def create_access_token(user_id: int) -> tuple[str, int]:
    """Return (token, expires_in_seconds)."""
    settings = get_settings()
    expires = timedelta(minutes=settings.access_token_expire_minutes)
    now = datetime.now(timezone.utc)
    payload = {"sub": str(user_id), "iat": now, "exp": now + expires, "type": "access"}
    token = jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)
    return token, int(expires.total_seconds())


def _unauthorized(detail: str) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=detail,
        headers={"WWW-Authenticate": "Bearer"},
    )


def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    db: Session = Depends(get_db),
) -> User:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise _unauthorized("Not authenticated")
    settings = get_settings()
    try:
        payload = jwt.decode(credentials.credentials, settings.jwt_secret, algorithms=[settings.jwt_algorithm])
    except jwt.ExpiredSignatureError:
        raise _unauthorized("Session expired. Please log in again.")
    except jwt.InvalidTokenError:
        raise _unauthorized("Invalid authentication token")
    if payload.get("type") != "access" or not str(payload.get("sub", "")).isdigit():
        raise _unauthorized("Invalid authentication token")

    user = db.get(User, int(payload["sub"]))
    if user is None or not user.is_active:
        raise _unauthorized("Account not found or disabled")
    return user


def ensure_owner(path_user_id: int, current_user: User) -> None:
    """Routes that take {user_id} in the path may only be used for the caller's own data."""
    if path_user_id != current_user.id:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "You can only access your own data")
