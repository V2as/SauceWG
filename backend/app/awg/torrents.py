"""The torrent guard, as the panel sees it.

A swarm sees an exit node's address, and a datacentre answers a copyright notice
by suspending the server rather than by asking who was behind it — so one client
seeding for an evening costs every client on that node. The node container blocks
BitTorrent in the traffic it forwards; this is the switch for it.

``config/torrent-block.json`` holds two things kept deliberately apart: whether
the guard is on, and which mode it runs in. Folding them into one field would mean
that turning it off from the UI and back on lost the choice of mode, and the
switch and the dial are different controls.

The whole mechanism — what a signature is, which ports ``strict`` leaves open,
how long a caught peer stays blocked — belongs to the container, so the only work
here is keeping the file in a shape it will accept and reading back what it says
it did.
"""

from __future__ import annotations

import json
import logging
import os
import tempfile
from typing import Any

from ..config import settings

logger = logging.getLogger(__name__)

MODES = ("on", "strict")


class TorrentError(ValueError):
    """A setting the node container would not be able to use."""


def normalize_mode(value: str | None) -> str:
    mode = (value or "").strip().lower()
    if mode in MODES:
        return mode
    raise TorrentError(f"{value!r} is not one of {' or '.join(MODES)}")


def load_settings() -> dict[str, Any]:
    """The configured switch. A missing file means the guard was never turned on.

    ``enabled`` defaults to true for a file that has one without the other, which
    is how a hand-written ``{"mode": "strict"}`` does what its author meant.
    """
    path = settings.torrent_registry_file
    if not os.path.exists(path):
        return {"enabled": False, "mode": "on"}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
    except OSError as exc:
        raise TorrentError(f"could not read {path}: {exc}") from exc
    except ValueError as exc:
        raise TorrentError(f"{path} is not valid JSON: {exc}") from exc

    if not isinstance(raw, dict):
        raise TorrentError(f"{path} must contain a JSON object")

    mode = str(raw.get("mode") or "on").strip().lower()
    return {
        "enabled": raw.get("enabled", True) is not False,
        # An unreadable mode is reported as the standard one rather than refused:
        # the container makes the same substitution, and this has to describe what
        # is actually running.
        "mode": mode if mode in MODES else "on",
    }


def save_settings(enabled: bool, mode: str) -> None:
    """Replaces the file atomically, so the container never sees a half-written one."""
    path = settings.torrent_registry_file
    directory = os.path.dirname(path) or "."
    try:
        os.makedirs(directory, exist_ok=True)
        handle = tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=directory, prefix=".torrent-block", delete=False
        )
    except OSError as exc:
        raise TorrentError(
            f"could not write to {directory}: {exc}. Is ./config mounted read-write "
            f"into the panel container?"
        ) from exc

    try:
        with handle:
            json.dump({"enabled": bool(enabled), "mode": normalize_mode(mode)}, handle, indent=2)
            handle.write("\n")
        os.chmod(handle.name, 0o600)
        os.replace(handle.name, path)
    except OSError as exc:
        os.unlink(handle.name)
        raise TorrentError(f"could not replace {path}: {exc}") from exc


def _empty() -> dict[str, Any]:
    return {
        "live": False,
        "mode": None,
        "source": None,
        "active": False,
        "rules": 0,
        "capabilities": {},
        "blocked": {},
        "peers": 0,
        "clients": [],
        "error": None,
    }


def state() -> dict[str, Any]:
    """What the node container reports about the guard it is actually running.

    Published in its own file rather than in ``uplinks.json`` because the same
    code runs on an exit node, where there is no cascade to publish alongside.
    """
    try:
        with open(settings.torrent_state_file, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
    except (OSError, ValueError):
        return _empty()
    if not isinstance(raw, dict):
        return _empty()

    blocked = raw.get("blocked")
    clients = raw.get("clients")
    return {
        "live": True,
        "mode": raw.get("mode"),
        "source": raw.get("source"),
        "active": bool(raw.get("active")),
        "rules": int(raw.get("rules") or 0),
        "capabilities": raw.get("capabilities") if isinstance(raw.get("capabilities"), dict) else {},
        # Per layer, as counted off the rules themselves.
        "blocked": {str(k): int(v) for k, v in blocked.items()} if isinstance(blocked, dict) else {},
        "peers": int(raw.get("peers") or 0),
        "clients": [item for item in clients if isinstance(item, dict)] if isinstance(clients, list) else [],
        "error": raw.get("error"),
    }


def config_error(current: dict[str, Any] | None = None) -> str | None:
    """Why the setting in the file is not the setting in force, if it is not."""
    live = current if current is not None else state()
    if live.get("source") == "env":
        return (
            "TORRENT_BLOCK is set, so the node container takes the torrent setting "
            "from the environment and ignores the file this panel writes. Unset it "
            "to manage the switch from here."
        )
    error = live.get("error")
    if error:
        return f"The node container could not apply the torrent filter: {error}"

    # A kernel without the string match leaves the guard as a port filter, which
    # stops a default client and nothing more. That is worth saying out loud on a
    # page whose whole promise is that nothing gets through.
    caps = live.get("capabilities") or {}
    if live.get("active") and caps and not caps.get("string"):
        return (
            "This host's kernel has no iptables string match (xt_string), so only "
            "the port rules are in force. Encrypted peer traffic on an unusual port "
            "will get through unless the mode is strict."
        )
    return None
