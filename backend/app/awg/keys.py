"""Curve25519 key helpers matching the base64 encoding used by wg/awg."""

from __future__ import annotations

import base64
import os

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    NoEncryption,
    PrivateFormat,
    PublicFormat,
)


def generate_private_key() -> str:
    key = X25519PrivateKey.generate()
    raw = key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
    return base64.b64encode(raw).decode()


def public_from_private(private_key: str) -> str:
    raw = base64.b64decode(private_key)
    key = X25519PrivateKey.from_private_bytes(raw)
    return base64.b64encode(
        key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    ).decode()


def generate_preshared_key() -> str:
    return base64.b64encode(os.urandom(32)).decode()


def is_valid_key(value: str) -> bool:
    try:
        return len(base64.b64decode(value, validate=True)) == 32
    except Exception:  # noqa: BLE001 - any decoding failure means "not a key"
        return False
