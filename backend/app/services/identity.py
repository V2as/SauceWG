"""The panel's own SSH identity.

Every operation on an exit node runs over SSH, and the root password used to install
one is deliberately never stored. That is fine for an operator typing it into a
dialog and useless for a bot: re-supplying a password on every restart, log fetch or
generation change means the caller has to keep root credentials for the whole fleet.

So the panel keeps one Ed25519 key pair of its own, enrols the public half on every
node it installs, and uses it for everything afterwards. A password is then needed
exactly once — or not at all, when the public key is injected into the server at
creation time and ``POST /api/nodes`` is called with no credentials.

The key lives next to ``exit-nodes.json`` in the bind-mounted config directory, so it
survives a container rebuild and is captured by the same backup that captures the
cascade. Losing it is not fatal: any node can be re-enrolled by passing a password
once more.
"""

from __future__ import annotations

import base64
import hashlib
import logging
import os
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519

from ..config import settings

logger = logging.getLogger(__name__)

#: Written into the public key so the line is recognisable in authorized_keys, and
#: so removing it again is an exact-match delete rather than a guess.
COMMENT = "saucewg-panel"


class IdentityError(RuntimeError):
    """The panel's key could not be read or created."""


@dataclass(frozen=True)
class Identity:
    public_key: str
    fingerprint: str
    created_at: datetime | None
    path: str


def _fingerprint(public_key: str) -> str:
    """The SHA256 fingerprint OpenSSH prints, so it can be compared by eye."""
    parts = public_key.split()
    if len(parts) < 2:
        return ""
    try:
        blob = base64.b64decode(parts[1])
    except ValueError:
        return ""
    digest = base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("=")
    return f"SHA256:{digest}"


def _public_path() -> str:
    return f"{settings.node_ssh_key_file}.pub"


def _generate() -> str:
    """Creates the key pair and returns the private half in OpenSSH format."""
    key = ed25519.Ed25519PrivateKey.generate()
    private = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.OpenSSH,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode()
    public = key.public_key().public_bytes(
        encoding=serialization.Encoding.OpenSSH,
        format=serialization.PublicFormat.OpenSSH,
    ).decode()
    public = f"{public.strip()} {COMMENT}\n"

    path = settings.node_ssh_key_file
    directory = os.path.dirname(path) or "."
    try:
        os.makedirs(directory, exist_ok=True)
        handle = tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=directory, prefix=".panel-ssh", delete=False
        )
        with handle:
            handle.write(private)
        # Before the rename, so the key is never briefly world-readable under its
        # real name — asyncssh refuses a key file other accounts can read anyway.
        os.chmod(handle.name, 0o600)
        os.replace(handle.name, path)
        with open(_public_path(), "w", encoding="utf-8") as pub:
            pub.write(public)
        os.chmod(_public_path(), 0o644)
    except OSError as exc:
        raise IdentityError(
            f"could not write the panel's SSH key to {path}: {exc}. Is ./config "
            f"mounted read-write into the panel container?"
        ) from exc

    logger.info("generated the panel's SSH identity %s", _fingerprint(public))
    return private


def ensure() -> Identity:
    """The panel's identity, generating it on first use."""
    path = settings.node_ssh_key_file
    if not os.path.exists(path):
        _generate()
    return describe()


def describe() -> Identity:
    """What to publish about the identity. Generates nothing."""
    path = settings.node_ssh_key_file
    try:
        with open(_public_path(), "r", encoding="utf-8") as handle:
            public = handle.read().strip()
    except OSError as exc:
        raise IdentityError(f"the panel has no SSH identity at {path}: {exc}") from exc

    created: datetime | None = None
    try:
        created = datetime.fromtimestamp(os.stat(path).st_mtime, tz=timezone.utc)
    except OSError:
        pass
    return Identity(
        public_key=public, fingerprint=_fingerprint(public), created_at=created, path=path
    )


def private_key() -> str | None:
    """The private half, for asyncssh. None when no identity exists yet."""
    try:
        with open(settings.node_ssh_key_file, "r", encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return None


def public_key() -> str | None:
    try:
        return describe().public_key
    except IdentityError:
        return None


def available() -> bool:
    return os.path.exists(settings.node_ssh_key_file) and os.path.exists(_public_path())
