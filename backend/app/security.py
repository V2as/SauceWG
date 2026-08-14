from __future__ import annotations

import hashlib
import secrets
from datetime import datetime, timedelta, timezone

import bcrypt
import jwt

from .config import settings


def _prehash(password: str) -> bytes:
    # bcrypt silently truncates at 72 bytes; hashing first keeps long passwords intact.
    return hashlib.sha256(password.encode("utf-8")).digest()


def hash_password(password: str) -> str:
    return bcrypt.hashpw(_prehash(password), bcrypt.gensalt()).decode()


def verify_password(password: str, hashed: str) -> bool:
    try:
        return bcrypt.checkpw(_prehash(password), hashed.encode())
    except (ValueError, TypeError):
        return False


def create_access_token(username: str, token_epoch: int = 0) -> tuple[str, int]:
    expires_in = settings.jwt_access_token_expire_minutes * 60
    now = datetime.now(timezone.utc)
    payload = {
        "sub": username,
        "epoch": token_epoch,
        "iat": now,
        "exp": now + timedelta(seconds=expires_in),
        "access": "admin",
    }
    token = jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)
    return token, expires_in


def decode_access_token(token: str) -> dict | None:
    try:
        payload = jwt.decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm])
    except jwt.PyJWTError:
        return None
    if payload.get("access") != "admin":
        return None
    return payload


def generate_token(length: int = 24) -> str:
    return secrets.token_urlsafe(length)
