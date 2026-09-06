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

#: Fallback modes, as CASCADE_FALLBACK spells them.
FALLBACK_DIRECT = "direct"
FALLBACK_BLOCK = "block"

#: Nodes already reported as stalled, so that a state read on every request does not
#: write the same warning to the log several times a second.
_stalled: set[str] = set()


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
    #: The AmneziaWG generation this uplink speaks. None from a node container that
    #: predates generation selection, which is serving 1.0 either way.
    protocol: str | None = None
    #: True when the cascade is still treating this uplink as usable — offering it as
    #: a failover target, or routing clients through it — while its last handshake is
    #: too old for anything to be coming out of it. See :func:`load_uplink_state`.
    stalled: bool = False

    @property
    def paired(self) -> bool:
        """False until the exit node's public key has been installed here."""
        return bool(self.peer_public_key and self.endpoint)

    @property
    def exit_ip(self) -> str | None:
        return self.endpoint.rsplit(":", 1)[0] if self.endpoint else None

    @property
    def handshake_age(self) -> float | None:
        """Seconds since the tunnel last handshaked, or None if it never has."""
        if self.last_handshake is None:
            return None
        return (datetime.now(timezone.utc) - self.last_handshake).total_seconds()


@dataclass
class UplinkState:
    mode: str = AUTO
    pinned: str | None = None
    active: str | None = None
    killswitch: bool = True
    #: What the node container does while no exit node can carry traffic: "direct"
    #: hands it to the entry node's own uplink, "block" drops it.
    fallback: str = FALLBACK_DIRECT
    #: Whether that is happening right now.
    fallback_active: bool = False
    updated_at: datetime | None = None
    #: How old a handshake the node container lets an uplink have before it fails it,
    #: and how long its own hysteresis may then take to act on that. Both come out of
    #: uplinks.json, so a node is judged by the container's rule rather than one the
    #: panel made up; the settings are the fallback for a container too old to publish
    #: them.
    handshake_timeout: int = 0
    failover_seconds: int = 0
    nodes: list[ExitNodeState] = field(default_factory=list)

    @property
    def handshake_deadline(self) -> int:
        """Beyond this age, a handshake cannot belong to a working uplink.

        The node container keeps a node healthy through ``CASCADE_FAIL_THRESHOLD``
        bad probes on purpose, so a handshake is allowed to be that much older than
        ``CASCADE_HANDSHAKE_TIMEOUT`` while the verdict is still legitimately
        "healthy". Judging a node any sooner than the container does would make the
        panel disagree with it every time a single probe was missed.
        """
        return self.handshake_timeout + self.failover_seconds

    @property
    def serving(self) -> bool:
        """True when a client's traffic is reaching the internet at all.

        Either an exit node is carrying it, or the entry node is while the cascade
        is down — which is a degraded state, not an outage.
        """
        return self.active is not None or (self.fallback_active and self.fallback == FALLBACK_DIRECT)

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


def _seconds(value: object, fallback: int) -> int:
    """A positive whole number of seconds out of the state file, or the fallback."""
    if isinstance(value, (int, float)) and value > 0:
        return int(value)
    return fallback


def load_uplink_state() -> UplinkState:
    """Never raises: a missing or half-written file just reads as 'nothing known'.

    The health flags in the file are checked against the handshake published beside
    them rather than taken at face value. They are only as fresh as the loop that
    wrote them, and the failure that costs clients their traffic is precisely the one
    where that loop is not running: the file then keeps saying "healthy" and "active"
    about an uplink whose last handshake is hours old, the panel reports an exit node
    that is carrying nothing, and recovery leaves it alone because it looks fine.
    """
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
                    protocol=item.get("protocol") or None,
                )
            )
        except (KeyError, TypeError, ValueError) as exc:
            logger.warning("skipping a malformed uplink entry: %s", exc)

    nodes.sort(key=lambda n: (n.priority, n.name))

    # A node container that predates the fallback modes only published "killswitch",
    # which said the same thing in fewer words.
    killswitch = bool(raw.get("killswitch", True))
    fallback = str(raw.get("fallback") or (FALLBACK_BLOCK if killswitch else FALLBACK_DIRECT))
    if fallback not in (FALLBACK_DIRECT, FALLBACK_BLOCK):
        fallback = FALLBACK_DIRECT

    state = UplinkState(
        mode=raw.get("mode") or AUTO,
        pinned=raw.get("pinned"),
        active=raw.get("active"),
        killswitch=killswitch,
        fallback=fallback,
        fallback_active=bool(raw.get("fallback_active", False)),
        updated_at=_timestamp(raw.get("updated_at")),
        # A node container that does not publish the rule it judged by is running the
        # defaults these settings carry, and they are kept equal to them.
        handshake_timeout=_seconds(
            raw.get("handshake_timeout"), settings.cascade_handshake_timeout
        ),
        failover_seconds=_seconds(
            raw.get("failover_seconds"), settings.cascade_failover_seconds
        ),
        nodes=nodes,
    )

    deadline = state.handshake_deadline
    for node in state.nodes:
        age = node.handshake_age
        if age is not None and age <= deadline:
            _stalled.discard(node.name)
            continue

        # Past the deadline nothing is coming out of this tunnel, so the only
        # question left is whether the cascade has noticed. It has not if it still
        # calls the node usable, and it has not acted if client traffic is still
        # pointed at it — either way the node is worth naming rather than quietly
        # counting among the down ones, because a peer that is merely down is not
        # costing anyone their connection.
        claimed = node.healthy or node.active
        node.healthy = False  # only ever a downgrade
        node.stalled = claimed
        if not claimed:
            _stalled.discard(node.name)
            continue
        if node.name not in _stalled:
            _stalled.add(node.name)
            logger.warning(
                "exit node %s last handshaked %s, longer than the %ds this cascade "
                "allows, but is still %s; treating it as down",
                node.name,
                f"{int(age)}s ago" if age is not None else "never",
                deadline,
                "carrying client traffic" if node.active else "offered as a failover target",
            )

    return state


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
