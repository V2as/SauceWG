"""The exit node list, as the panel sees it.

``config/exit-nodes.json`` is the single source of truth for the cascade. The node
container bind-mounts it read-only and the panel read-write, so editing it here and
asking the container to re-read it is all it takes to add or remove an exit node —
no Docker socket, no privileged panel, no restart.

Everything the container does not understand is carried through untouched, which is
where the provisioning metadata (how to reach the server over SSH, when it was
added, which host key it presented) lives.
"""

from __future__ import annotations

import ipaddress
import json
import logging
import os
import tempfile
import time
from typing import Any

from ..config import settings
from . import protocol as proto

logger = logging.getLogger(__name__)

# Keys the node container reads. Anything else in an entry is metadata for us.
# The obfuscation parameters are derived from the generation table so that the two
# cannot drift apart: an entry the panel writes but the container ignores would look
# applied here and change nothing on the wire.
NODE_FIELDS = frozenset(
    {
        "name",
        "endpoint",
        "public_key",
        "peer_public_key",
        "preshared_key",
        "psk",
        "address",
        "priority",
        "mtu",
        "keepalive",
        "protocol",
        "version",
    }
    | {name.lower() for name in proto.ALL_PARAMS}
)


class RegistryError(RuntimeError):
    """The exit node list could not be read or written."""


def load_nodes() -> list[dict[str, Any]]:
    """The configured exit nodes, in file order. Missing file reads as empty."""
    path = settings.node_registry_file
    if not os.path.exists(path):
        return []
    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
    except OSError as exc:
        raise RegistryError(f"could not read {path}: {exc}") from exc
    except ValueError as exc:
        raise RegistryError(f"{path} is not valid JSON: {exc}") from exc

    if not isinstance(raw, list):
        raise RegistryError(f"{path} must contain a JSON array")
    return [item for item in raw if isinstance(item, dict)]


def save_nodes(nodes: list[dict[str, Any]]) -> None:
    """Replaces the list atomically, so the container never sees a half-written file."""
    path = settings.node_registry_file
    directory = os.path.dirname(path) or "."
    try:
        os.makedirs(directory, exist_ok=True)
        handle = tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=directory, prefix=".exit-nodes", delete=False
        )
    except OSError as exc:
        raise RegistryError(
            f"could not write to {directory}: {exc}. Is ./config mounted read-write "
            f"into the panel container?"
        ) from exc

    try:
        with handle:
            json.dump(nodes, handle, indent=2)
            handle.write("\n")
        os.chmod(handle.name, 0o600)
        os.replace(handle.name, path)
    except OSError as exc:
        os.unlink(handle.name)
        raise RegistryError(f"could not replace {path}: {exc}") from exc


def find(nodes: list[dict[str, Any]], name: str) -> dict[str, Any] | None:
    for node in nodes:
        if node.get("name") == name:
            return node
    return None


def allocate_address(nodes: list[dict[str, Any]], subnet: str | None = None) -> str:
    """The lowest free host address in the uplink subnet.

    Addresses are pinned when a node is added rather than derived from its position,
    so removing one never renumbers — and silently reconfigures — the survivors.
    """
    network = ipaddress.ip_network(subnet or settings.cascade_uplink_subnet, strict=False)
    taken = {str(node.get("address", "")).split("/")[0] for node in nodes}
    # .1 belongs to the exit node itself on the far side of every uplink.
    for host in list(network.hosts())[1:]:
        if str(host) not in taken:
            return f"{host}/32"
    raise RegistryError(f"no free uplink address left in {network}")


def next_priority(nodes: list[dict[str, Any]]) -> int:
    """Appends below every existing node so a new one never steals live traffic."""
    priorities = [int(node.get("priority", 100)) for node in nodes if node.get("priority") is not None]
    return (max(priorities) + 10) if priorities else 10


def request_reload() -> str:
    """Asks the node container to re-read the list, and returns the request id.

    The container polls for this file once a second and echoes the id back in
    ``uplinks.json`` once it has applied the change, which is what
    :func:`wait_for_reload` waits for.
    """
    # A nanosecond epoch overflows a JSON double, so the id travels as a string.
    request_id = str(time.time_ns())
    path = settings.uplink_reload_file
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)

    handle = tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=directory, prefix=".reload", delete=False
    )
    try:
        with handle:
            json.dump({"id": request_id}, handle)
        os.chmod(handle.name, 0o644)
        os.replace(handle.name, path)
    except OSError as exc:
        os.unlink(handle.name)
        raise RegistryError(f"could not signal the node container: {exc}") from exc
    return request_id


def reload_applied(request_id: str) -> bool:
    """True once the node container reports it has applied that reload request."""
    try:
        with open(settings.uplink_state_file, "r", encoding="utf-8") as handle:
            state = json.load(handle)
    except (OSError, ValueError):
        return False
    return str(state.get("reload_id", "")) == request_id


def config_error() -> str | None:
    """Why the cascade is not in the state this panel thinks it is, if it is not.

    Returns a complete sentence: it is shown to an operator verbatim and handed to
    API clients as-is.
    """
    try:
        with open(settings.uplink_state_file, "r", encoding="utf-8") as handle:
            state = json.load(handle)
    except (OSError, ValueError):
        return None
    error = state.get("config_error")
    if error:
        return f"The node container rejected the exit node list: {error}"
    if state.get("source") == "env":
        return (
            "CASCADE_NODES_JSON is set, so the node container reads the exit node list "
            "from the environment and ignores the file this panel edits. Unset it to "
            "manage the cascade from here."
        )
    return None


def writable() -> bool:
    """True when an edit made here would actually reach the node container."""
    if not settings.node_provision_enabled:
        return False
    try:
        with open(settings.uplink_state_file, "r", encoding="utf-8") as handle:
            state = json.load(handle)
    except (OSError, ValueError):
        # The container may simply not be up yet; that is not a reason to lock the UI.
        return True
    return state.get("source") != "env"


def uplink_public_key(name: str) -> str | None:
    """The entry node's own key for one uplink — what the exit node must trust."""
    try:
        with open(settings.uplink_state_file, "r", encoding="utf-8") as handle:
            state = json.load(handle)
    except (OSError, ValueError):
        return None
    for node in state.get("nodes") or []:
        if node.get("name") == name:
            return node.get("public_key") or None
    return None
