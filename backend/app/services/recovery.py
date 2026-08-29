"""Putting a failed exit node back, instead of only routing around it.

The node container's failover is about clients: when an uplink stops handshaking it
moves their traffic to the next healthy exit node within about thirty seconds, and
nobody loses a connection. Nothing in that brings the failed node back, and because
nothing is broken from a client's point of view, it can stay down until the last node
goes with it — at which point either every client is on the entry node's own address
or, with ``CASCADE_FALLBACK=block``, cut off entirely.

Recovering it needs the exit *server*, not the tunnel, and the panel is the only part
of the system that can reach one: it installed most of them and holds an SSH key on
each. So this runs there, on a timer, and does what an operator would do by hand.

Escalation, cheapest first, because each step is more disruptive than the last and
the common causes are in this order:

    1. wait      the uplink is unhealthy but the node container may just be mid-
                 reload, or the server mid-reboot. Nothing is done for the first
                 few minutes.
    2. probe     open an SSH session. A server that does not answer at all cannot
                 be fixed from here, and saying so is the whole value of the
                 attempt — that is a deleted or suspended VPS, not a broken
                 service, and it needs a human.
    3. restart   the server answers but its containers are not running, or are
                 running and not handshaking. `saucewg restart` fixes the
                 overwhelming majority of those.
    4. repair    it is up and still not handshaking, so the two ends no longer
                 agree on keys — the server was rebuilt, or its .env was reset.
                 Re-install the entry node's uplink key.

Everything here is best-effort and bounded. Attempts back off geometrically, stop
after a handful, and never touch a node that an operator is already working on. A
node that comes back resets its own state, so the next outage starts from step one.
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from typing import Any

from ..awg import registry
from ..awg.uplinks import ExitNodeState, load_uplink_state
from ..config import settings
from ..services import identity, provision
from ..services.tasks import detached, tasks

logger = logging.getLogger(__name__)

#: What the last attempt tried. Reported as-is, so the panel and the CLI can say
#: what happened without interpreting a free-text log line.
PROBE = "probe"
RESTART = "restart"
REPAIR = "repair"

#: Why a node is not being recovered right now, when it is not.
UNREACHABLE = "unreachable"
EXHAUSTED = "exhausted"


@dataclass
class Attempt:
    """One node's recovery history, kept only for as long as the process lives.

    In memory on purpose: it describes an outage that is happening now. A panel
    restart is also the moment to stop assuming anything about a node's state, and
    starting over costs one extra SSH session.
    """

    name: str
    # Consecutive failures. Reset the moment the uplink is healthy again.
    failures: int = 0
    attempts: int = 0
    first_seen: float = field(default_factory=time.monotonic)
    last_attempt: float = 0.0
    last_action: str | None = None
    last_error: str | None = None
    # Set when there is no point trying again: the server does not answer, or the
    # attempt budget is spent. Cleared by the node recovering or by a manual run.
    blocked: str | None = None
    recovered_at: float | None = None

    def due(self, now: float) -> bool:
        """Whether enough time has passed to try again.

        The first attempt waits out the grace period, so a reload or a reboot is not
        chased. Later ones back off geometrically from the sweep interval, which
        turns a server that is simply gone into a few probes an hour.
        """
        if self.blocked is not None:
            return False
        if self.last_attempt == 0.0:
            return now - self.first_seen >= settings.node_recovery_grace_seconds
        delay = settings.node_recovery_interval_seconds * (
            settings.node_recovery_backoff_factor ** max(self.attempts - 1, 0)
        )
        return now - self.last_attempt >= min(delay, settings.node_recovery_max_backoff_seconds)

    def snapshot(self, now: float) -> dict[str, Any]:
        """The shape the API publishes. Ages rather than clock times, because the
        monotonic clock this runs on has no relation to wall time."""
        return {
            "attempts": self.attempts,
            "last_action": self.last_action,
            "last_error": self.last_error,
            "blocked": self.blocked,
            "down_for_seconds": int(now - self.first_seen),
            "since_last_attempt_seconds": (
                int(now - self.last_attempt) if self.last_attempt else None
            ),
            "recovered": self.recovered_at is not None,
        }


#: Live state, keyed by node name.
_history: dict[str, Attempt] = {}


def state() -> dict[str, dict[str, Any]]:
    """What recovery has been doing, for the nodes API to publish."""
    now = time.monotonic()
    return {name: attempt.snapshot(now) for name, attempt in _history.items()}


def forget(name: str) -> None:
    """Drops a node's history, so the next attempt starts from the beginning.

    Called when an operator acts on the node themselves: whatever they did resets
    the assumptions this made, including a block it had given up on.
    """
    _history.pop(name, None)


# ---------------------------------------------------------------------------
# Deciding which nodes to work on
# ---------------------------------------------------------------------------


def _credentials(node: dict[str, Any]) -> provision.Credentials | None:
    """The way in, if the panel has one that needs no operator present.

    A node adopted by hand has no SSH address, and one installed before the panel
    kept a key of its own has no key to use — both are managed on their own server,
    so there is nothing to do from here.
    """
    host = node.get("ssh_host")
    if not host or not node.get("ssh_key") or not settings.node_ssh_key_enabled:
        return None
    private_key = identity.private_key()
    if not private_key:
        return None
    return provision.Credentials(
        host=str(host),
        port=int(node.get("ssh_port") or settings.node_ssh_port),
        username=str(node.get("ssh_user") or settings.node_ssh_user),
        private_key=private_key,
        host_key=node.get("ssh_host_key"),
        enrolled=True,
    )


def _candidates(
    state: Any, meta: dict[str, dict[str, Any]]
) -> list[tuple[ExitNodeState, dict[str, Any]]]:
    """Unhealthy uplinks whose server the panel can reach unattended."""
    out: list[tuple[ExitNodeState, dict[str, Any]]] = []
    for node in state.nodes:
        entry = meta.get(node.name)
        if entry is None or node.healthy:
            continue
        out.append((node, entry))
    return out


# ---------------------------------------------------------------------------
# One node
# ---------------------------------------------------------------------------


async def _healthy_within(name: str, timeout: int) -> bool:
    """Whether the node container reports the uplink healthy again in time.

    The container decides that, not this: it takes CASCADE_RECOVER_THRESHOLD good
    probes, so a tunnel that is up reads as unhealthy for a few seconds more.
    """
    for _ in range(timeout):
        node = load_uplink_state().get(name)
        if node is not None and node.healthy:
            return True
        await asyncio.sleep(1)
    return False


async def _recover(node: ExitNodeState, entry: dict[str, Any], attempt: Attempt) -> bool:
    """One escalating attempt at one node. True when the uplink came back."""
    name = node.name
    credentials = _credentials(entry)
    if credentials is None:
        # Not a failure to record: there is no way in and no amount of retrying
        # creates one. The node simply is not ours to recover.
        attempt.blocked = UNREACHABLE
        attempt.last_error = (
            "the panel has no unattended way into this server, so it cannot be "
            "recovered from here"
        )
        return False

    task = detached("recover", name)
    attempt.attempts += 1
    attempt.last_attempt = time.monotonic()

    task.begin(f"Recovering {name} ({credentials.host})")
    task.emit(f"the uplink has been unhealthy for {int(time.monotonic() - attempt.first_seen)}s")

    # 2. Does the server answer at all?
    attempt.last_action = PROBE
    try:
        facts = await asyncio.wait_for(
            provision.node_status(task, credentials),
            timeout=settings.node_ssh_query_timeout_seconds,
        )
    except (provision.ProvisionError, asyncio.TimeoutError, OSError) as exc:
        attempt.failures += 1
        attempt.last_error = str(exc) or f"{credentials.host} did not answer in time"
        # A server that does not answer SSH is not a broken service. Repeating the
        # probe a few times covers a reboot; past that it is a deleted or suspended
        # machine, and the honest thing is to stop and say so.
        if attempt.failures >= 2:
            attempt.blocked = UNREACHABLE
            logger.warning(
                "exit node %s (%s) does not answer; leaving it alone: %s",
                name,
                credentials.host,
                attempt.last_error,
            )
        task.emit(f"{credentials.host} did not answer: {attempt.last_error}")
        return False

    running = [
        item.get("name")
        for item in facts.get("containers") or []
        if isinstance(item, dict) and str(item.get("state") or "").lower() == "running"
    ]
    task.emit(
        f"{credentials.host} is up; "
        + (f"containers running: {', '.join(str(c) for c in running)}" if running else "no containers are running")
    )

    # 3. Restart the service. Right whether the containers are stopped or up and
    #    not handshaking, and cheap enough not to be worth telling the two apart.
    attempt.last_action = RESTART
    try:
        await provision.control_service(task, credentials, "restart")
    except (provision.ProvisionError, OSError) as exc:
        attempt.failures += 1
        attempt.last_error = str(exc)
        task.emit(f"could not restart {name}: {exc}")
        return False

    task.begin("Waiting for the tunnel")
    if await _healthy_within(name, 90):
        task.emit(f"{name} is carrying traffic again")
        return True

    # 4. Up and still silent: the two ends disagree about keys. This is the step
    #    that changes the exit server's configuration, so it is last.
    key = registry.uplink_public_key(name)
    if not key:
        attempt.failures += 1
        attempt.last_error = (
            "the node container has not published an uplink key for this node, so "
            "the two ends cannot be re-paired"
        )
        task.emit(attempt.last_error)
        return False

    attempt.last_action = REPAIR
    task.begin("Re-installing the uplink key")
    try:
        await provision.pair_exit_node(task, credentials, key, entry.get("preshared_key") or None)
    except (provision.ProvisionError, OSError) as exc:
        attempt.failures += 1
        attempt.last_error = str(exc)
        task.emit(f"could not re-pair {name}: {exc}")
        return False

    if await _healthy_within(name, 90):
        task.emit(f"{name} is carrying traffic again")
        return True

    attempt.failures += 1
    attempt.last_error = (
        "the server is up and the uplink key was re-installed, but the tunnel still "
        "does not handshake"
    )
    task.emit(attempt.last_error)
    return False


async def recover_now(name: str) -> dict[str, Any]:
    """Runs one attempt at one node immediately, whatever its history says.

    This is what ``POST /api/nodes/{name}/recover`` and ``saucewg recover`` call. It
    clears a block first: an operator asking for this has usually just fixed the
    reason for it.
    """
    state = load_uplink_state()
    node = state.get(name)
    entry = next((item for item in registry.load_nodes() if item.get("name") == name), None)
    if node is None or entry is None:
        raise provision.ProvisionError(f"no exit node named {name!r}")

    attempt = _history.setdefault(name, Attempt(name=name))
    attempt.blocked = None
    if node.healthy:
        # Nothing to do, and restarting a working exit node to prove it would take
        # its clients down for the duration.
        return {"name": name, "healthy": True, "acted": False} | attempt.snapshot(time.monotonic())

    healthy = await _recover(node, entry, attempt)
    if healthy:
        attempt.recovered_at = time.monotonic()
        attempt.failures = 0
    return {"name": name, "healthy": healthy, "acted": True} | attempt.snapshot(time.monotonic())


# ---------------------------------------------------------------------------
# The sweep
# ---------------------------------------------------------------------------


async def sweep() -> int:
    """One pass over the fleet. Returns how many nodes were acted on.

    Kept to one node per pass. Restarting two exit nodes at once could take the last
    healthy one down with them, and an outage that is affecting several is one where
    the entry node's own uplink or the panel's network is the more likely cause —
    neither of which is improved by hurrying.
    """
    if not settings.node_recovery_enabled or not settings.node_provision_enabled:
        return 0

    state = load_uplink_state()
    if state.stale:
        # The node container is not publishing, so "unhealthy" here means "unknown".
        # Acting on that would restart exit nodes because the panel lost sight of
        # them, which is the wrong end of the problem.
        return 0

    try:
        meta = {str(item.get("name")): item for item in registry.load_nodes()}
    except registry.RegistryError as exc:
        logger.warning("could not read the exit node registry: %s", exc)
        return 0

    candidates = _candidates(state, meta)
    healthy_names = {node.name for node in state.nodes if node.healthy}

    # A node that came back clears its history, so the next outage is judged on its
    # own and a block from the last one does not outlive it.
    for name in list(_history):
        if name in healthy_names or name not in meta:
            _history.pop(name, None)

    now = time.monotonic()
    for node, entry in candidates:
        # first_seen shares this pass's clock reading, so a zero grace period means
        # the first sweep that notices the outage is also the one that acts.
        attempt = _history.setdefault(node.name, Attempt(name=node.name, first_seen=now))
        if attempt.attempts >= settings.node_recovery_max_attempts:
            if attempt.blocked is None:
                attempt.blocked = EXHAUSTED
                logger.warning(
                    "gave up recovering exit node %s after %d attempts: %s",
                    node.name,
                    attempt.attempts,
                    attempt.last_error or "it did not come back",
                )
            continue
        if not attempt.due(now):
            continue
        # An operator's own install, repair or upgrade is authoritative; racing it
        # would fight over the same SSH session and the same registry file.
        if tasks.active_for(node.name) is not None:
            continue

        before = attempt.attempts
        healthy = await _recover(node, entry, attempt)
        if healthy:
            attempt.recovered_at = time.monotonic()
            attempt.failures = 0
            logger.info("recovered exit node %s", node.name)
        # A node with no way in records why and counts as untouched, so the next node
        # in the list still gets its turn this pass.
        if attempt.attempts == before:
            continue
        return 1
    return 0


async def loop() -> None:
    """The worker the panel runs. Never dies on a transient error."""
    while True:
        await asyncio.sleep(settings.node_recovery_interval_seconds)
        try:
            await sweep()
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 - a worker must never die on a transient error
            logger.exception("exit node recovery iteration failed")


__all__ = ["Attempt", "forget", "loop", "recover_now", "state", "sweep"]
