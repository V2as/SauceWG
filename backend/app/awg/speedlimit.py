"""The speed limit, as the panel sees it.

One number — the most any client may move through the entry node, in Mbit/s — that
the node container holds every client to separately, and each direction
separately. At 50 every client can download at up to 50 Mbit/s and upload at up to
50 Mbit/s whatever the others are doing; it is not a total divided between them.

``config/speed-limit.json`` keeps the switch and the rate apart, the way the torrent
switch keeps its mode, so that lifting the limit and putting it back does not lose
the number.

How the limit is enforced — a token bucket per client address on the client
interface — belongs to the container and is documented in
``docker/awg/speedlimit.sh``, so the work here is keeping the file in a shape it
accepts and reading back what it says it did.
"""

from __future__ import annotations

import json
import logging
import math
import os
import tempfile
from typing import Any

from ..config import settings

logger = logging.getLogger(__name__)

# The range the node container accepts. Below it a bucket holds a handful of
# packets; above it the kernel's byte accounting stops being precise.
MIN_MBIT = 0.1
MAX_MBIT = 10000


class SpeedLimitError(ValueError):
    """A setting the node container would not be able to use."""


def normalize_rate(value: Any) -> int | float:
    """A rate in Mbit/s as the container reads it.

    Rounded to whole kbit/s, which is the precision it works in, and a whole number
    of Mbit/s is written as one so that the file says 50 rather than 50.0.
    """
    if isinstance(value, bool):
        raise SpeedLimitError(f"{value!r} is not a number of Mbit/s")
    try:
        rate = float(value)
    except (TypeError, ValueError) as exc:
        raise SpeedLimitError(f"{value!r} is not a number of Mbit/s") from exc
    if not math.isfinite(rate) or rate < MIN_MBIT or rate > MAX_MBIT:
        raise SpeedLimitError(f"{value!r} is not between {MIN_MBIT} and {MAX_MBIT} Mbit/s")
    rate = round(rate, 3)
    return int(rate) if rate == int(rate) else rate


def _enabled(raw: dict[str, Any]) -> bool:
    # The container's own test, so that the two cannot disagree about an odd
    # value: absent, true, or the string "true".
    value = raw.get("enabled", True)
    return value is True or value == "true"


def load_settings() -> dict[str, Any]:
    """The configured switch and rate. A missing file is a limit never set.

    ``enabled`` defaults to true for a file that names a rate without it, which is
    how a hand-written ``{"rate_mbit": 50}`` does what its author meant.
    """
    path = settings.speed_limit_registry_file
    if not os.path.exists(path):
        return {"enabled": False, "rate_mbit": None}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
    except OSError as exc:
        raise SpeedLimitError(f"could not read {path}: {exc}") from exc
    except ValueError as exc:
        raise SpeedLimitError(f"{path} is not valid JSON: {exc}") from exc

    if not isinstance(raw, dict):
        raise SpeedLimitError(f"{path} must contain a JSON object")

    rate: int | float | None = None
    if raw.get("rate_mbit") is not None:
        try:
            rate = normalize_rate(raw["rate_mbit"])
        except SpeedLimitError:
            # Reported as unset rather than refused: the container keeps whatever
            # was in force, and says why in the error config_error() relays.
            rate = None
    return {"enabled": _enabled(raw), "rate_mbit": rate}


def save_settings(enabled: bool, rate_mbit: float | None) -> None:
    """Replaces the file atomically, so the container never sees a half-written one."""
    if enabled and rate_mbit is None:
        raise SpeedLimitError("there is no rate to hold clients to; send rate_mbit with it")
    body = {
        "enabled": bool(enabled),
        "rate_mbit": normalize_rate(rate_mbit) if rate_mbit is not None else None,
    }

    path = settings.speed_limit_registry_file
    directory = os.path.dirname(path) or "."
    try:
        os.makedirs(directory, exist_ok=True)
        handle = tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=directory, prefix=".speed-limit", delete=False
        )
    except OSError as exc:
        raise SpeedLimitError(
            f"could not write to {directory}: {exc}. Is ./config mounted read-write "
            f"into the panel container?"
        ) from exc

    try:
        with handle:
            json.dump(body, handle, indent=2)
            handle.write("\n")
        os.chmod(handle.name, 0o600)
        os.replace(handle.name, path)
    except OSError as exc:
        os.unlink(handle.name)
        raise SpeedLimitError(f"could not replace {path}: {exc}") from exc


def _empty() -> dict[str, Any]:
    return {
        "live": False,
        "rate_mbit": None,
        "source": None,
        "active": False,
        "rules": 0,
        "capabilities": None,
        "dropped": {},
        "error": None,
    }


def _number(value: Any) -> int | float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value


def state() -> dict[str, Any]:
    """What the node container reports about the limit it is actually enforcing."""
    try:
        with open(settings.speed_limit_state_file, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
    except (OSError, ValueError):
        return _empty()
    if not isinstance(raw, dict):
        return _empty()

    dropped = raw.get("dropped")
    return {
        "live": True,
        # Mbit/s in force, or None when nothing is.
        "rate_mbit": _number(raw.get("rate_mbit")),
        "source": raw.get("source"),
        "active": bool(raw.get("active")),
        "rules": int(raw.get("rules") or 0),
        # None until the container has asked its kernel, which it does once there is
        # a rate to install.
        "capabilities": raw.get("capabilities") if isinstance(raw.get("capabilities"), dict) else None,
        # Packets dropped for being over the limit, per direction.
        "dropped": {
            str(key): int(count)
            for key, count in dropped.items()
            if isinstance(count, int) and not isinstance(count, bool)
        }
        if isinstance(dropped, dict)
        else {},
        "error": raw.get("error"),
    }


def config_error(current: dict[str, Any] | None = None) -> str | None:
    """Why the setting in the file is not the setting in force, if it is not."""
    live = current if current is not None else state()
    if live.get("source") == "env":
        return (
            "SPEED_LIMIT is set, so the node container takes the speed limit from the "
            "environment and ignores the file this panel writes. Unset it to manage "
            "the limit from here."
        )
    error = live.get("error")
    if error:
        return f"The node container could not apply the speed limit: {error}"
    return None
