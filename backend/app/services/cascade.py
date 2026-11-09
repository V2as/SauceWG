"""Changing the cascade under the node container, and waiting for it to catch up.

Shared by the nodes API and the fleet upgrade: both edit the exit node list, ask the
container to re-read it, and then have to tell a tunnel that came back from one that
only still looks as if it is up.
"""

from __future__ import annotations

import asyncio
from datetime import datetime, timedelta
from typing import Any

from ..awg import protocol as awg_protocol
from ..awg import registry
from ..awg.uplinks import load_uplink_state
from ..config import settings
from . import provision
from .tasks import Task


async def apply_and_wait(task: Task) -> None:
    """Publishes the current list and waits for the node container to apply it."""
    task.begin("Reloading the cascade")
    request_id = registry.request_reload()

    deadline = settings.node_reload_timeout_seconds
    for tick in range(deadline * 2):
        if registry.reload_applied(request_id):
            error = registry.config_error()
            if error:
                raise provision.ProvisionError(f"the node container rejected the list: {error}")
            task.emit("the node applied the new exit node list")
            return
        # A running container refreshes its state every health tick, so state this
        # old means it is stopped. It reads the list on startup anyway, and waiting
        # out the full timeout would only turn a saved change into a failure.
        if tick == 10 and load_uplink_state().stale:
            task.emit(
                "the node container is not running; the exit node list is saved and "
                "will be applied when it starts"
            )
            return
        await asyncio.sleep(0.5)
    raise provision.ProvisionError(
        f"the node container did not apply the new list within {deadline}s; "
        f"check `saucewg logs awg`"
    )


async def await_handshake(name: str, timeout: int = 90) -> bool:
    """True once the node container reports a live handshake on that uplink."""
    for _ in range(timeout):
        node = load_uplink_state().get(name)
        if node is not None and node.last_handshake is not None:
            return True
        await asyncio.sleep(1)
    return False


async def await_health(name: str, timeout: int = 120, *, since: datetime | None = None) -> bool:
    """True once an uplink that already existed is passing health checks again.

    A restart or an upgrade leaves the last handshake time in place, so recovery has
    to be read from the health flag the node container maintains rather than from
    the fact that a handshake once happened. That flag is itself held through a few
    failed probes, though, so a node restarted a moment ago still reads as healthy —
    ``since`` closes that gap by also asking for a handshake made after it.
    """
    # The container reports whole seconds, so a handshake in the same second as the
    # operation began would otherwise read as older than it.
    floor = since - timedelta(seconds=1) if since is not None else None
    for _ in range(timeout):
        node = load_uplink_state().get(name)
        if node is not None and node.healthy:
            if floor is None or (node.last_handshake is not None and node.last_handshake >= floor):
                return True
        await asyncio.sleep(1)
    return False


def copy_profile(reported: dict[str, Any], entry: dict[str, Any]) -> dict[str, Any]:
    """Carries an exit node's obfuscation profile into its registry entry.

    S1-S4 and H1-H4 — and under 3.x the header protection key and RandomTrailers —
    have to be repeated on the entry side because both ends of a tunnel must pad,
    label and encrypt packets identically. Recording the generation alongside them is
    what keeps a later reload from rebuilding the uplink as something else.
    """
    if reported.get("protocol"):
        entry["protocol"] = reported["protocol"]
    for name in awg_protocol.ALL_PARAMS:
        key = name.lower()
        value = reported.get(key)
        if value is not None and str(value) != "":
            entry[key] = value
    return entry


def replace_profile(entry: dict[str, Any], reported: dict[str, Any], protocol: str) -> dict[str, Any]:
    """Swaps an entry's whole profile for the one its exit node now reports.

    The old generation's parameters have to go, not just be overwritten: a leftover
    S3 would keep the uplink advertising 2.0 to a 1.0 exit node, and a leftover
    header protection key would encrypt headers a 2.0 node reads in the clear.
    """
    for param in awg_protocol.ALL_PARAMS:
        entry.pop(param.lower(), None)
    copy_profile(reported, entry)
    entry["protocol"] = protocol
    return entry


__all__ = ["apply_and_wait", "await_handshake", "await_health", "copy_profile", "replace_profile"]
