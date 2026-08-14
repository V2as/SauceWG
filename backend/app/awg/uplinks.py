"""Reads the uplink state the node container publishes and steers its failover.

The node container owns the interfaces, the routing table and the health checks; it
publishes what it knows to ``uplinks.json`` and reads back a one-line intent from
``uplink-control.json``. Keeping the panel on that side of the fence is what lets it
run without NET_ADMIN and without sharing the node's network namespace.
"""

from __future__ import annotations

import json
import logging
import os
import tempfile
from dataclasses import dataclass, field
from datetime import datetime, timezone

from ..config import settings

logger = logging.getLogger(__name__)

AUTO = "auto"
MANUAL = "manual"


@dataclass
class ExitNodeState:
    name: str
    iface: str
    address: str
    priority: int
    public_key: str
    endpoint: str | None = None
    peer_public_key: str | None = None
    healthy: bool = False
    active: bool = False
    last_handshake: datetime | None = None
    latency_ms: float | None = None
    rx_bytes: int = 0
    tx_bytes: int = 0

    @property
    def paired(self) -> bool:
        """False until the exit node's public key has been installed here."""
        return bool(self.peer_public_key and self.endpoint)

    @property
    def exit_ip(self) -> str | None:
        return self.endpoint.rsplit(":", 1)[0] if self.endpoint else None


@dataclass
class UplinkState:
    mode: str = AUTO
    pinned: str | None = None
    active: str | None = None
    killswitch: bool = True
    updated_at: datetime | None = None
    nodes: list[ExitNodeState] = field(default_factory=list)

    @property
    def stale(self) -> bool:
        """True when the node container stopped refreshing the file."""
        if self.updated_at is None:
            return True
        age = (datetime.now(timezone.utc) - self.updated_at).total_seconds()
        return age > settings.uplink_state_max_age_seconds

    @property
    def active_node(self) -> ExitNodeState | None:
        for node in self.nodes:
            if node.active:
                return node
        return None

    def get(self, name: str) -> ExitNodeState | None:
        for node in self.nodes:
            if node.name == name:
                return node
        return None


def _timestamp(value: object) -> datetime | None:
    if not isinstance(value, (int, float)) or value <= 0:
        return None
    return datetime.fromtimestamp(value, tz=timezone.utc)


def load_uplink_state() -> UplinkState:
    """Never raises: a missing or half-written file just reads as 'nothing known'."""
    path = settings.uplink_state_file
    if not os.path.exists(path):
        return UplinkState()
    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
    except (OSError, ValueError) as exc:
        logger.debug("could not read %s: %s", path, exc)
        return UplinkState()

    nodes = []
    for item in raw.get("nodes") or []:
        try:
            nodes.append(
                ExitNodeState(
                    name=item["name"],
                    iface=item["iface"],
                    address=item.get("address", ""),
                    priority=int(item.get("priority", 0)),
                    public_key=item.get("public_key", ""),
                    endpoint=item.get("endpoint"),
                    peer_public_key=item.get("peer_public_key"),
                    healthy=bool(item.get("healthy")),
                    active=bool(item.get("active")),
                    last_handshake=_timestamp(item.get("last_handshake")),
                    latency_ms=item.get("latency_ms"),
                    rx_bytes=int(item.get("rx_bytes", 0)),
                    tx_bytes=int(item.get("tx_bytes", 0)),
                )
            )
        except (KeyError, TypeError, ValueError) as exc:
            logger.warning("skipping a malformed uplink entry: %s", exc)

    nodes.sort(key=lambda n: (n.priority, n.name))
    return UplinkState(
        mode=raw.get("mode") or AUTO,
        pinned=raw.get("pinned"),
        active=raw.get("active"),
        killswitch=bool(raw.get("killswitch", True)),
        updated_at=_timestamp(raw.get("updated_at")),
        nodes=nodes,
    )


def write_control(mode: str, node: str | None = None) -> None:
    """Asks the node container to prefer a specific uplink, or to choose on its own.

    A pinned node is a preference rather than a lock: the container still fails over
    when it goes down, and returns to the pin once it recovers.
    """
    payload = {"mode": mode, "node": node if mode == MANUAL else None}
    path = settings.uplink_control_file
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)

    # The container may read the file at any moment, so swap it in atomically.
    handle = tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=directory, prefix=".uplink-control", delete=False
    )
    try:
        with handle:
            json.dump(payload, handle)
        os.chmod(handle.name, 0o644)
        os.replace(handle.name, path)
    except OSError:
        os.unlink(handle.name)
        raise
