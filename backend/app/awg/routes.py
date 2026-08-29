"""Destinations that bypass the cascade, as the panel sees them.

``config/direct-routes.json`` lists the addresses and ranges that leave through the
entry node instead of an exit node — a service that has to see a local address, or
one that is better off never crossing the exit node at all. The panel edits the file
and the node container, which bind-mounts it read-only, applies the change within a
second.

The container is the one that turns a prefix into a route, so the only work here is
keeping the file in a shape it will accept: valid IPv4 prefixes, masked to their
network, without duplicates.
"""

from __future__ import annotations

import ipaddress
import json
import logging
import os
import tempfile
from typing import Any

from ..config import settings

logger = logging.getLogger(__name__)


class RouteError(ValueError):
    """A prefix the node container would not be able to route."""


def normalize_prefix(value: str) -> str:
    """``8.8.8.8`` -> ``8.8.8.8/32``, ``10.20.30.40/24`` -> ``10.20.30.0/24``.

    A bare address is a single host, and an address inside a range is stored as the
    range: the kernel refuses a route whose destination has host bits set, and the
    range is what was meant anyway.
    """
    text = (value or "").strip()
    if not text:
        raise RouteError("a route needs an address or a range")
    try:
        network = ipaddress.ip_network(text, strict=False)
    except ValueError as exc:
        raise RouteError(f"{text} is not an IPv4 address or range") from exc
    if network.version != 4:
        raise RouteError(
            f"{text} is IPv6; the cascade routes IPv4 only, so an IPv6 destination "
            f"already bypasses it"
        )
    if network.prefixlen == 0:
        raise RouteError(
            "0.0.0.0/0 would take every destination off the cascade. To send all "
            "traffic through the entry node while the exit nodes are down, set the "
            "fallback to direct instead"
        )
    return str(network)


def load_routes() -> list[dict[str, Any]]:
    """The configured routes, in file order. A missing file reads as empty.

    Entries written by hand may be bare strings, and may spell a single host without
    its ``/32`` — the node container accepts both and canonicalises them. The same is
    done here, so what the API reports lines up with what the container says it
    installed rather than looking permanently unapplied. A prefix that cannot be
    parsed is passed through untouched: it belongs in the list the operator sees,
    with whatever the container makes of it.
    """
    path = settings.routes_registry_file
    if not os.path.exists(path):
        return []
    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
    except OSError as exc:
        raise RouteError(f"could not read {path}: {exc}") from exc
    except ValueError as exc:
        raise RouteError(f"{path} is not valid JSON: {exc}") from exc

    if not isinstance(raw, list):
        raise RouteError(f"{path} must contain a JSON array")

    routes: list[dict[str, Any]] = []
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
            entry["cidr"] = normalize_prefix(str(cidr))
        except RouteError:
            entry["cidr"] = str(cidr)
        entry["enabled"] = entry.get("enabled", True) is not False
        if entry.get("note") is not None:
            entry["note"] = str(entry["note"])
        routes.append(entry)
    return routes


def save_routes(routes: list[dict[str, Any]]) -> None:
    """Replaces the list atomically, so the container never sees a half-written file."""
    path = settings.routes_registry_file
    directory = os.path.dirname(path) or "."
    try:
        os.makedirs(directory, exist_ok=True)
        handle = tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=directory, prefix=".direct-routes", delete=False
        )
    except OSError as exc:
        raise RouteError(
            f"could not write to {directory}: {exc}. Is ./config mounted read-write "
            f"into the panel container?"
        ) from exc

    try:
        with handle:
            json.dump(routes, handle, indent=2)
            handle.write("\n")
        os.chmod(handle.name, 0o600)
        os.replace(handle.name, path)
    except OSError as exc:
        os.unlink(handle.name)
        raise RouteError(f"could not replace {path}: {exc}") from exc


def find(routes: list[dict[str, Any]], cidr: str) -> dict[str, Any] | None:
    for route in routes:
        if route.get("cidr") == cidr:
            return route
    return None


def state() -> dict[str, Any]:
    """What the node container reports about the routes it has actually installed.

    A prefix can be in the file and not in effect — the container has not re-read it
    yet, or it has no route of its own to send it out of — so the applied set is read
    back rather than assumed.
    """
    try:
        with open(settings.uplink_state_file, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
    except (OSError, ValueError):
        return {"live": False, "applied": [], "via": None, "error": None, "source": None}

    direct = raw.get("direct") or {}
    return {
        # A container older than this feature publishes no "direct" key at all, which
        # is worth telling apart from one that has simply applied nothing.
        "live": isinstance(raw.get("direct"), dict),
        "applied": [str(item) for item in (direct.get("routes") or [])],
        "via": direct.get("via"),
        "error": direct.get("error"),
        "source": direct.get("source"),
    }


def config_error(direct_state: dict[str, Any] | None = None) -> str | None:
    """Why the routes in the file are not the routes in effect, if they are not."""
    current = direct_state if direct_state is not None else state()
    if current.get("source") == "env":
        return (
            "CASCADE_DIRECT_ROUTES is set, so the node container reads the direct "
            "routes from the environment and ignores the file this panel edits. "
            "Unset it to manage them from here."
        )
    error = current.get("error")
    return f"The node container could not apply the direct routes: {error}" if error else None
