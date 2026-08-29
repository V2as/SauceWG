"""Destinations the entry node reopens for itself, as the panel sees them.

Some destinations are not blocked by route but at the point where a TCP connection
is established: the SYN to their IPv4 is dropped, so nothing ever connects, while
ICMP to the same address and every already-established flow pass untouched. A route
cannot fix that, so ``direct-routes.json`` cannot either — the entry node has to
open the outbound half itself, over the destination's IPv6 where the same server
answers there, or by dialling its IPv4 until one handshake gets through.

``config/bypass.json`` is where an operator lists destinations for that, or corrects
one of the groups the node image ships. Each entry may carry the IPv6 counterpart of
the same server; without one the destination's own IPv4 is retried, which needs no
table to stay correct.

The container owns the whole mechanism — which groups exist, when the redirect is
installed, how hard to retry — so the only work here is keeping the file in a shape
it will accept.
"""

from __future__ import annotations

import ipaddress
import json
import logging
import os
import tempfile
from typing import Any

from ..config import settings
from .routes import RouteError, normalize_prefix

logger = logging.getLogger(__name__)


class BypassError(ValueError):
    """An entry the node container would not be able to use."""


def normalize_target(value: str) -> str:
    """The IPv6 address of the same server, if one was given.

    Rejected rather than silently dropped: an entry whose counterpart does not parse
    would fall back to retrying IPv4 and look like it was working, while the operator
    believes a translation is in place.
    """
    text = (value or "").strip()
    if not text:
        return ""
    try:
        address = ipaddress.ip_address(text)
    except ValueError as exc:
        raise BypassError(f"{text} is not an IPv6 address") from exc
    if address.version != 6:
        raise BypassError(
            f"{text} is IPv4. The counterpart has to be IPv6 — reaching the same "
            f"destination over a different IPv4 is what the retry path already does"
        )
    return str(address)


def normalize_entry(value: str) -> str:
    """The same masking the direct routes use, with this feature's reason for /0."""
    try:
        return normalize_prefix(value)
    except RouteError as exc:
        if "0.0.0.0/0" in str(exc):
            raise BypassError(
                "0.0.0.0/0 would send every destination through the relay, which is "
                "slower than the tunnel and helps only where a handshake is being "
                "dropped. List the destinations that are actually blocked"
            ) from exc
        raise BypassError(str(exc)) from exc


def load_entries() -> list[dict[str, Any]]:
    """The configured entries, in file order. A missing file reads as empty.

    Hand-written entries may be bare strings and may spell a single host without its
    ``/32``, both of which the node container accepts; they are canonicalised here so
    that what the API reports lines up with what the container says it applied. An
    unparseable prefix is passed through untouched: it belongs in the list the
    operator sees, with whatever the container makes of it.
    """
    path = settings.bypass_registry_file
    if not os.path.exists(path):
        return []
    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
    except OSError as exc:
        raise BypassError(f"could not read {path}: {exc}") from exc
    except ValueError as exc:
        raise BypassError(f"{path} is not valid JSON: {exc}") from exc

    if not isinstance(raw, list):
        raise BypassError(f"{path} must contain a JSON array")

    entries: list[dict[str, Any]] = []
    for item in raw:
        if isinstance(item, str):
            item = {"cidr": item}
        if not isinstance(item, dict):
            continue
        cidr = item.get("cidr") or item.get("prefix") or item.get("network") or item.get("ip")
        if not cidr:
            continue
        entry = dict(item)
        try:
            entry["cidr"] = normalize_entry(str(cidr))
        except BypassError:
            entry["cidr"] = str(cidr)
        # The container reads either name, so both are accepted and one is reported.
        target = entry.pop("ipv6", None) or entry.get("v6")
        entry["v6"] = str(target) if target else None
        entry["enabled"] = entry.get("enabled", True) is not False
        if entry.get("note") is not None:
            entry["note"] = str(entry["note"])
        entries.append(entry)
    return entries


def save_entries(entries: list[dict[str, Any]]) -> None:
    """Replaces the list atomically, so the container never sees a half-written file."""
    path = settings.bypass_registry_file
    directory = os.path.dirname(path) or "."
    try:
        os.makedirs(directory, exist_ok=True)
        handle = tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=directory, prefix=".bypass", delete=False
        )
    except OSError as exc:
        raise BypassError(
            f"could not write to {directory}: {exc}. Is ./config mounted read-write "
            f"into the panel container?"
        ) from exc

    # A null counterpart is the absence of one, and the container reads a missing key
    # the same way — so it is dropped rather than written out.
    payload = [{key: value for key, value in entry.items() if value is not None} for entry in entries]
    try:
        with handle:
            json.dump(payload, handle, indent=2)
            handle.write("\n")
        os.chmod(handle.name, 0o600)
        os.replace(handle.name, path)
    except OSError as exc:
        os.unlink(handle.name)
        raise BypassError(f"could not replace {path}: {exc}") from exc


def find(entries: list[dict[str, Any]], cidr: str) -> dict[str, Any] | None:
    for entry in entries:
        if entry.get("cidr") == cidr:
            return entry
    return None


def state() -> dict[str, Any]:
    """What the node container reports about the bypass it is actually running.

    ``active`` is the one to read: in ``auto`` the redirect is deliberately absent
    whenever an exit node is carrying client traffic, which is the normal state and
    not a fault.
    """
    empty = {
        "live": False,
        "mode": None,
        "groups": [],
        "applied": [],
        "count": 0,
        "active": False,
        "relay": None,
        "error": None,
        "source": None,
    }
    try:
        with open(settings.uplink_state_file, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
    except (OSError, ValueError):
        return empty

    # A container older than this feature publishes no "bypass" key at all, which is
    # worth telling apart from one that has simply applied nothing.
    if not isinstance(raw.get("bypass"), dict):
        return empty
    bypass = raw["bypass"]

    applied: list[dict[str, Any]] = []
    for item in bypass.get("routes") or []:
        if isinstance(item, str):
            applied.append({"cidr": item, "v6": None, "note": None})
        elif isinstance(item, dict) and item.get("cidr"):
            applied.append(
                {
                    "cidr": str(item["cidr"]),
                    "v6": str(item["v6"]) if item.get("v6") else None,
                    "note": str(item["note"]) if item.get("note") else None,
                }
            )

    return {
        "live": True,
        "mode": bypass.get("mode"),
        "groups": [str(group) for group in (bypass.get("groups") or [])],
        "applied": applied,
        "count": int(bypass.get("applied") or 0),
        "active": bool(bypass.get("active")),
        "relay": bypass.get("relay") if isinstance(bypass.get("relay"), dict) else None,
        "error": bypass.get("error"),
        "source": bypass.get("source"),
    }


def config_error(bypass_state: dict[str, Any] | None = None) -> str | None:
    """Why the list in the file is not the list in effect, if it is not."""
    current = bypass_state if bypass_state is not None else state()
    if current.get("source") == "env":
        return (
            "BYPASS_ROUTES is set, so the node container reads the bypass list from "
            "the environment and ignores the file this panel edits. Unset it to "
            "manage the list from here."
        )
    error = current.get("error")
    return f"The node container could not apply the bypass: {error}" if error else None
