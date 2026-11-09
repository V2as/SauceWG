"""Keeping every exit node on the release this panel runs.

An exit node runs whatever it was installed with until something upgrades it, and an
entry node that moved ahead of its exit nodes is a cascade on two releases — harmless
until a release changes what the two ends say to each other, which is exactly what a
new AmneziaWG generation does. So after an update the panel walks its exit nodes over
to its own release, and then onto the generation a new install would get.

The walk never takes the cascade down to get there:

* one node at a time, standbys first and the node carrying traffic last;
* before that one is touched, traffic is pinned to a node that has already been
  upgraded (or any healthy one), and the operator's own choice is put back after;
* every step is followed by waiting for a fresh handshake and a passing probe, and a
  node that was healthy before and is not after stops the walk, since whatever broke
  it would break the next node too;
* a generation that does not come up is undone on that node, and no further node is
  moved to it;
* a node the panel cannot reach unattended — adopted by hand, or installed before the
  panel kept a key — is reported, never guessed at.

`saucewg update` runs the walk right after it restarts the panel, so the operator sees
how it went; the panel runs it again shortly after it starts and keeps retrying the
nodes that did not answer. A file lock keeps the two from walking at the same time.
"""

from __future__ import annotations

import asyncio
import fcntl
import json
import logging
import os
import re
import tempfile
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from typing import Any

from .. import __version__
from ..awg import protocol as awg_protocol
from ..awg import registry
from ..awg.uplinks import (
    AUTO,
    FALLBACK_DIRECT,
    MANUAL,
    UplinkState,
    load_uplink_state,
    read_control,
    write_control,
)
from ..config import settings
from . import cascade, provision, recovery
from .tasks import Task, tasks

logger = logging.getLogger(__name__)

#: What a fleet upgrade is registered under in the task list.
TARGET = "fleet"

#: The first release whose node image speaks AmneziaWG 3.x. A node left on anything
#: older — a pinned tag, a mirror serving an old script — keeps its generation.
GENERATIONS_RELEASE = "1.6.0"

#: One outcome per node, so the panel and the CLI can say what happened without
#: parsing a log.
CURRENT = "current"
UPGRADED = "upgraded"
SKIPPED = "skipped"
UNREACHABLE = "unreachable"
FAILED = "failed"

#: How long a node gets to show a fresh handshake and a passing probe after each
#: step. A restarted exit node is redialled within half a minute; one that had
#: already been redialled by the time the step returned only proves itself at the
#: next rekey, which comes two minutes after the last handshake.
HEALTH_TIMEOUT = 210
#: How long the cascade gets to move traffic off the node about to be upgraded.
SWITCH_TIMEOUT = 60
#: How long to wait, before anything is judged, for the node container to rebuild
#: every uplink and measure it. It has usually just been restarted itself.
SETTLE_TIMEOUT = 120


class FleetBusy(RuntimeError):
    """Another fleet upgrade is already running."""


@dataclass
class Outcome:
    name: str
    status: str = CURRENT
    detail: str = ""
    version_before: str | None = None
    version_after: str | None = None
    protocol_before: str | None = None
    protocol_after: str | None = None
    healthy: bool | None = None
    #: Worth trying again later: the node did not answer, or was not healthy
    #: enough to be moved to the new generation this time.
    pending: bool = False


# ---------------------------------------------------------------------------
# Releases
# ---------------------------------------------------------------------------


def _release(text: object) -> tuple[int, int, int] | None:
    match = re.match(r"v?(\d+)\.(\d+)(?:\.(\d+))?", str(text or "").strip())
    if match is None:
        return None
    major, minor, patch = match.groups()
    return int(major), int(minor), int(patch or 0)


def behind(version: object, release: str = __version__) -> bool:
    """True when a node's saucewg is older than ``release``, or does not say."""
    wanted = _release(release)
    if wanted is None:
        return False
    have = _release(version)
    return have is None or have < wanted


def target_protocol(value: str | None) -> str | None:
    """The generation to move nodes onto: None takes the setting, empty is none."""
    chosen = settings.node_upgrade_protocol if value is None else value
    return awg_protocol.normalize_or_none(chosen)


# ---------------------------------------------------------------------------
# One walk at a time
# ---------------------------------------------------------------------------


class _Lock:
    """An flock on a file both the panel and `saucewg update` can see."""

    def __init__(self) -> None:
        self._fd: int | None = None

    async def acquire(self) -> bool:
        path = settings.fleet_lock_file
        try:
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
            fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
        except OSError as exc:
            raise provision.ProvisionError(f"could not open the upgrade lock {path}: {exc}") from exc
        # running() takes the lock for an instant to test it, so a single refusal
        # may be nothing more than that.
        for _ in range(20):
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                await asyncio.sleep(0.1)
                continue
            self._fd = fd
            return True
        os.close(fd)
        return False

    def release(self) -> None:
        if self._fd is None:
            return
        try:
            fcntl.flock(self._fd, fcntl.LOCK_UN)
        finally:
            os.close(self._fd)
            self._fd = None


def running() -> bool:
    """True while a fleet upgrade is under way, in this process or another."""
    try:
        fd = os.open(settings.fleet_lock_file, os.O_RDWR)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return True
    else:
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    finally:
        os.close(fd)


def last_report() -> dict[str, Any] | None:
    """The progress of the walk under way, or how the last one ended."""
    try:
        with open(settings.fleet_state_file, encoding="utf-8") as handle:
            report = json.load(handle)
    except (OSError, ValueError):
        return None
    if not isinstance(report, dict):
        return None
    # A walk cut short by a restart never wrote its end; the lock says whether
    # anything is still behind it.
    if report.get("running") and not running():
        report["running"] = False
    return report


def _publish(report: dict[str, Any]) -> None:
    path = settings.fleet_state_file
    directory = os.path.dirname(path) or "."
    try:
        os.makedirs(directory, exist_ok=True)
        handle = tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=directory, prefix=".fleet", delete=False
        )
        with handle:
            json.dump(report, handle)
        os.chmod(handle.name, 0o644)
        os.replace(handle.name, path)
    except OSError as exc:
        logger.warning("could not record the fleet upgrade's progress: %s", exc)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


# ---------------------------------------------------------------------------
# The walk
# ---------------------------------------------------------------------------


async def upgrade(
    task: Task,
    *,
    names: list[str] | None = None,
    protocol: str | None = None,
    origin: str = "panel",
) -> dict[str, Any]:
    """Walks the managed exit nodes onto this release, one at a time.

    ``protocol`` is the generation to move them onto afterwards: None takes
    NODE_UPGRADE_PROTOCOL, an empty string leaves every node on its own. Raises
    :class:`FleetBusy` when another walk is under way.
    """
    target = target_protocol(protocol)
    lock = _Lock()
    if not await lock.acquire():
        raise FleetBusy("the exit nodes are already being upgraded")

    report: dict[str, Any] = {
        "ok": True,
        "running": True,
        "origin": origin,
        "release": __version__,
        "protocol": target,
        "started_at": _now(),
        "finished_at": None,
        "current": None,
        "halted": None,
        "error": None,
        "nodes": [],
    }
    _publish(report)
    try:
        await _Walk(task, report, target).run(names)
    except (provision.ProvisionError, registry.RegistryError) as exc:
        report["error"] = str(exc)
        task.emit(f"the exit nodes were not upgraded: {exc}")
    except BaseException as exc:
        report["error"] = str(exc) or exc.__class__.__name__
        raise
    finally:
        report["running"] = False
        report["current"] = None
        report["finished_at"] = _now()
        report["ok"] = (
            report["halted"] is None
            and report["error"] is None
            and not any(item["status"] == FAILED for item in report["nodes"])
        )
        _publish(report)
        lock.release()
    return report


class _Walk:
    def __init__(self, task: Task, report: dict[str, Any], target: str | None) -> None:
        self.task = task
        self.report = report
        self.target = target
        #: Nodes already on this release, preferred as somewhere to move traffic.
        self.done: set[str] = set()
        #: Set once a node did not come up on the new generation; no other node is
        #: moved to it after that.
        self.no_move: str | None = None
        #: The node traffic was pinned to while the active one was upgraded.
        self.pin: str | None = None

    async def run(self, names: list[str] | None) -> None:
        if not settings.node_provision_enabled:
            self.task.emit("provisioning is switched off on this panel; nothing to do")
            return
        entries = registry.load_nodes()
        if names:
            wanted = set(names)
            unknown = sorted(wanted - {str(item.get("name")) for item in entries})
            if unknown:
                raise provision.ProvisionError(f"no exit node named {', '.join(unknown)}")
            entries = [item for item in entries if item.get("name") in wanted]
        if not entries:
            self.task.emit("there are no exit nodes to upgrade")
            return

        state = await self._settle({str(item.get("name")) for item in entries})
        if state.stale:
            raise provision.ProvisionError(
                "the node container is not publishing its state, so there is no telling "
                "which exit node carries traffic; start it first (saucewg start)"
            )
        if self.target and self.target not in state.generations:
            self.task.emit(
                f"this entry node's own image speaks AmneziaWG "
                f"{', '.join(state.generations)} only, so no exit node is moved to "
                f"{self.target}; run `saucewg update` here first"
            )
            self.no_move = f"this entry node does not speak AmneziaWG {self.target} yet"
        elif self.target and not registry.writable():
            self.no_move = "the cascade is configured from the environment rather than by the panel"

        for entry in self._order(entries, state):
            name = str(entry.get("name"))
            if self.report["halted"]:
                outcome = Outcome(
                    name=name, status=SKIPPED, detail="not attempted: " + self.report["halted"]
                )
            else:
                self.report["current"] = name
                _publish(self.report)
                outcome = await self._node(entry)
                if outcome.status in (CURRENT, UPGRADED):
                    self.done.add(name)
            self.report["nodes"].append(asdict(outcome))
            _publish(self.report)

        summary = ", ".join(f"{item['name']} {item['status']}" for item in self.report["nodes"])
        self.task.emit(f"done: {summary}")

    async def _settle(self, names: set[str]) -> UplinkState:
        """Waits for the node container to have built and measured every uplink.

        A node that is simply down keeps this waiting for the whole timeout, which is
        the price of not judging the others by a container that has just restarted.
        """
        deadline = time.monotonic() + SETTLE_TIMEOUT
        announced = False
        while True:
            state = load_uplink_state()
            built = names <= {node.name for node in state.nodes}
            measured = all(node.healthy for node in state.nodes if node.paired)
            if (not state.stale and built and measured) or time.monotonic() >= deadline:
                return state
            if not announced:
                self.task.emit("waiting for the node container to measure every exit node")
                announced = True
            await asyncio.sleep(2)

    @staticmethod
    def _order(entries: list[dict[str, Any]], state: UplinkState) -> list[dict[str, Any]]:
        """Standbys first, the least preferred of them first, and the active node last."""

        def key(entry: dict[str, Any]) -> tuple[bool, int]:
            node = state.get(str(entry.get("name")))
            priority = node.priority if node is not None else int(entry.get("priority") or 0)
            return (entry.get("name") == state.active, -priority)

        return sorted(entries, key=key)

    def _protocol_of(self, entry: dict[str, Any]) -> str:
        node = load_uplink_state().get(str(entry.get("name")))
        for value in (entry.get("protocol"), node.protocol if node else None):
            try:
                normalized = awg_protocol.normalize_or_none(value)
            except awg_protocol.UnknownProtocol:
                continue
            if normalized:
                return normalized
        return awg_protocol.ASSUMED_PROTOCOL

    def _move_wanted(self, entry: dict[str, Any], current: str) -> bool:
        if not self.target or entry.get("keep_protocol"):
            return False
        return awg_protocol.older(current, self.target)

    async def _node(self, entry: dict[str, Any]) -> Outcome:
        name = str(entry.get("name"))
        current = self._protocol_of(entry)
        outcome = Outcome(name=name, protocol_before=current, protocol_after=current)

        credentials = recovery.unattended_credentials(entry)
        if credentials is None:
            outcome.status = SKIPPED
            outcome.detail = (
                "added by hand, so the panel has no way in; run `saucewg update` on that server"
                if not entry.get("ssh_host")
                else "the panel holds no key for this server; upgrade it once from the "
                "panel with its password, or run `saucewg update` there"
            )
            self.task.emit(f"{name}: {outcome.detail}")
            return outcome

        self.task.begin(f"{name}: checking its release")
        try:
            facts = await asyncio.wait_for(
                provision.node_status(self.task, credentials),
                timeout=settings.node_ssh_query_timeout_seconds,
            )
        except (provision.ProvisionError, asyncio.TimeoutError, OSError) as exc:
            outcome.status = UNREACHABLE
            outcome.detail = str(exc) or "it did not answer in time"
            outcome.pending = True
            self.task.emit(f"{name}: {outcome.detail}")
            return outcome

        outcome.version_before = facts.get("cli_version")
        outcome.version_after = outcome.version_before
        release = behind(outcome.version_before)
        move = self._move_wanted(entry, current)
        if not release and not move:
            outcome.detail = (
                f"kept on AmneziaWG {current}, which an operator chose for it"
                if entry.get("keep_protocol") and self.target and current != self.target
                else "already on this release"
            )
            self.task.emit(f"{name}: {outcome.detail}")
            return outcome

        before = load_uplink_state().get(name)
        was_healthy = bool(before and before.healthy)
        restore = await self._make_way(name)
        if restore is False:
            outcome.pending = True
            outcome.detail = "it carries the traffic and the cascade would not move off it"
            self.task.emit(f"{name}: {outcome.detail}; leaving it for later")
            return outcome

        try:
            if release:
                if not await self._upgrade_release(outcome, credentials, was_healthy):
                    return outcome
            if move:
                await self._move(outcome, credentials, was_healthy)
            return outcome
        except (provision.ProvisionError, asyncio.TimeoutError, OSError) as exc:
            outcome.status = FAILED
            outcome.detail = str(exc) or exc.__class__.__name__
            self.task.emit(f"{name}: {outcome.detail}")
            self._judge(outcome, was_healthy)
            return outcome
        finally:
            if isinstance(restore, tuple):
                self._put_back(*restore)

    async def _upgrade_release(
        self, outcome: Outcome, credentials: provision.Credentials, was_healthy: bool
    ) -> bool:
        name = outcome.name
        self.task.begin(f"{name}: upgrading saucewg {outcome.version_before or '(unknown)'} → {__version__}")
        result = await provision.upgrade_exit_node(self.task, credentials)
        # Taken once the update is over rather than before it: the cascade rekeys
        # every two minutes, so a handshake made while the update was still pulling
        # images would otherwise vouch for a container that was then replaced.
        updated = datetime.now(timezone.utc)
        outcome.version_after = str(result.get("cli_version") or "") or None
        outcome.status = UPGRADED
        if result.get("ok") is False:
            self.task.emit(f"{name} reports a container that did not stay up after the update")
        if not was_healthy:
            # Nothing to compare against, and nothing carried by it to protect.
            return True
        self.task.begin(f"{name}: waiting for the tunnel")
        if await cascade.await_health(name, HEALTH_TIMEOUT, since=updated):
            outcome.healthy = True
            self.task.emit(f"{name} is on {outcome.version_after or __version__} and healthy")
            return True
        outcome.status = FAILED
        outcome.detail = "upgraded, but its tunnel has not come back"
        self.task.emit(f"{name}: {outcome.detail}")
        self._judge(outcome, was_healthy)
        return False

    async def _move(
        self, outcome: Outcome, credentials: provision.Credentials, was_healthy: bool
    ) -> None:
        name, current, target = outcome.name, outcome.protocol_before or "", self.target or ""
        if self.no_move:
            outcome.detail = f"left on AmneziaWG {current}: {self.no_move}"
            self.task.emit(f"{name}: {outcome.detail}")
            return
        if behind(outcome.version_after, GENERATIONS_RELEASE):
            outcome.detail = (
                f"its saucewg {outcome.version_after or '(unknown)'} cannot serve AmneziaWG "
                f"{target}; left on {current}"
            )
            self.task.emit(f"{name}: {outcome.detail}")
            return
        if not was_healthy:
            outcome.pending = True
            outcome.detail = f"left on AmneziaWG {current} until its tunnel is healthy"
            self.task.emit(f"{name}: {outcome.detail}")
            return

        if await self._switch(name, credentials, target):
            outcome.status = UPGRADED
            outcome.protocol_after = target
            outcome.healthy = True
            self.task.emit(f"{name} speaks AmneziaWG {target} and is healthy")
            return

        # The generation itself is the likely culprit, so this node goes back to the
        # one that worked and no other node is moved to it — and it stays there, or
        # every restart of the panel would take it down to try again.
        self.no_move = f"AmneziaWG {target} did not come up on {name}"
        self.task.emit(f"{name}: AmneziaWG {target} did not come up; putting it back on {current}")
        outcome.status = FAILED
        if await self._switch(name, credentials, current):
            outcome.healthy = True
            self._keep(name)
            outcome.detail = (
                f"AmneziaWG {target} did not come up, so it was put back on {current} and "
                f"kept there; move it by hand once the cause is found"
            )
        else:
            outcome.healthy = False
            outcome.protocol_after = None
            outcome.detail = (
                f"AmneziaWG {target} did not come up, and neither did {current} after "
                f"putting it back"
            )
            self._judge(outcome, was_healthy)
        self.task.emit(f"{name}: {outcome.detail}")

    async def _switch(self, name: str, credentials: provision.Credentials, protocol: str) -> bool:
        """Moves both ends of one tunnel to a generation; True once it carries probes."""
        self.task.begin(f"{name}: moving to AmneziaWG {protocol}")
        reported = await provision.set_exit_node_protocol(self.task, credentials, protocol)
        # From here the two ends disagree until the uplink is rebuilt, so the next
        # handshake can only be one made on the new profile.
        started = datetime.now(timezone.utc)
        nodes = registry.load_nodes()
        stored = registry.find(nodes, name)
        if stored is None:
            raise provision.ProvisionError(f"{name} was removed while it was being upgraded")
        cascade.replace_profile(stored, reported, protocol)
        registry.save_nodes(nodes)
        await cascade.apply_and_wait(self.task)
        self.task.begin(f"{name}: waiting for the tunnel")
        return await cascade.await_health(name, HEALTH_TIMEOUT, since=started)

    def _keep(self, name: str) -> None:
        nodes = registry.load_nodes()
        stored = registry.find(nodes, name)
        if stored is not None:
            stored["keep_protocol"] = True
            registry.save_nodes(nodes)

    def _judge(self, outcome: Outcome, was_healthy: bool) -> None:
        """Stops the walk when a node that was working no longer is."""
        node = load_uplink_state().get(outcome.name)
        healthy_now = bool(node and node.healthy)
        if outcome.healthy is None:
            outcome.healthy = healthy_now
        if was_healthy and not healthy_now:
            self.report["halted"] = f"{outcome.name} stopped working during its upgrade"
            self.task.emit(
                f"stopping here: {outcome.name} was healthy before and is not now, and "
                f"whatever broke it would break the next node too"
            )

    async def _make_way(self, name: str) -> tuple[str, str | None] | bool | None:
        """Moves traffic off ``name`` if it carries it.

        Returns the failover choice to put back afterwards, None when nothing was
        moved, or False when the traffic would not move.
        """
        state = load_uplink_state()
        if state.active != name:
            return None
        others = [node for node in state.nodes if node.name != name and node.healthy]
        if not others:
            self.task.emit(
                f"{name} carries the traffic and no other exit node is healthy; "
                + (
                    "clients leave through the entry node while it restarts"
                    if state.fallback == FALLBACK_DIRECT
                    else "clients are cut off for the minute it restarts"
                )
            )
            return None
        others.sort(key=lambda node: (node.name not in self.done, node.priority))
        standby = others[0].name
        previous = (state.mode, state.pinned)
        write_control(MANUAL, standby)
        self.pin = standby
        self.task.emit(f"moving the traffic to {standby} while {name} is upgraded")
        for _ in range(SWITCH_TIMEOUT):
            if load_uplink_state().active == standby:
                self.task.emit(f"{standby} carries the traffic")
                return previous
            await asyncio.sleep(1)
        self._put_back(*previous)
        return False

    def _put_back(self, mode: str, pinned: str | None) -> None:
        ours, self.pin = self.pin, None
        # Switching nodes stays open to an operator during the walk, and what they
        # chose meanwhile is not the walk's to undo.
        if ours is not None and read_control() != (MANUAL, ours):
            self.task.emit("the choice of exit node was changed during the upgrade; leaving it as it is")
            return
        try:
            if mode == MANUAL and pinned:
                write_control(MANUAL, pinned)
            else:
                write_control(AUTO)
        except OSError as exc:
            self.task.emit(f"could not hand the choice of exit node back: {exc}")


# ---------------------------------------------------------------------------
# Running it from the panel
# ---------------------------------------------------------------------------


def start(origin: str = "panel", protocol: str | None = None) -> Task:
    """Starts a walk as a panel task. Raises :class:`FleetBusy` if one is running."""
    if running() or tasks.active_for(TARGET) is not None:
        raise FleetBusy("the exit nodes are already being upgraded")

    async def work(task: Task) -> None:
        task.result = await upgrade(task, protocol=protocol, origin=origin)

    return tasks.start("upgrade-fleet", TARGET, work)


def _unfinished(report: dict[str, Any] | None) -> bool:
    """Whether a walk left nodes behind that another one could still reach."""
    if not report or report.get("running") or report.get("halted"):
        return False
    return bool(report.get("error")) or any(item.get("pending") for item in report.get("nodes") or [])


async def loop() -> None:
    """Brings the fleet onto this release shortly after the panel starts.

    `saucewg update` has usually done it already, in which case every node reads as
    current and the walk is a status check over SSH. What is left for this loop is a
    node that was down at the time — after this walk or after one started from the
    panel or the CLI — which is retried until it has been upgraded. A walk that
    stopped because a node broke is left for an operator.
    """
    if not settings.node_auto_upgrade or not settings.node_provision_enabled:
        return
    await asyncio.sleep(settings.node_auto_upgrade_delay_seconds)
    due = True
    while True:
        if due and not running() and tasks.active_for(TARGET) is None:
            try:
                await tasks.run("upgrade-fleet", TARGET, _automatic)
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001 - a worker must never die on a transient error
                logger.exception("the exit node upgrade failed")
            report = last_report()
            if report and report.get("halted"):
                logger.warning(
                    "the exit node upgrade stopped: %s; run it again from the panel or with "
                    "`saucewg upgrade-nodes` once that is looked at",
                    report["halted"],
                )
        await asyncio.sleep(settings.node_auto_upgrade_retry_seconds)
        due = _unfinished(last_report())


async def _automatic(task: Task) -> None:
    try:
        task.result = await upgrade(task, origin="startup")
    except FleetBusy:
        task.emit("another upgrade of the exit nodes is already running")


__all__ = [
    "CURRENT",
    "FAILED",
    "SKIPPED",
    "TARGET",
    "UNREACHABLE",
    "UPGRADED",
    "FleetBusy",
    "behind",
    "last_report",
    "loop",
    "running",
    "start",
    "target_protocol",
    "upgrade",
]
