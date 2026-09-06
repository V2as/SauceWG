"""Exit node inventory, provisioning and failover control."""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, HTTPException, Query, status

from ..awg import protocol as awg_protocol
from ..awg import registry
from ..awg.uplinks import AUTO, MANUAL, ExitNodeState, load_uplink_state, write_control
from ..config import settings
from ..deps import AdminDep, SudoAdminDep
from ..models import Admin
from ..schemas import (
    ExitNode,
    ExitNodeAdopt,
    ExitNodeCreate,
    ExitNodeDelete,
    ExitNodeList,
    ExitNodeProtocolChange,
    ExitNodeUpdate,
    NodeCheck,
    NodeCheckResult,
    NodeContainer,
    NodeCredentials,
    NodeLogs,
    NodeRecovery,
    NodeServiceRequest,
    NodeStatus,
    NodeUpgradeRequest,
    PanelSshKey,
    TaskLogLine,
    TaskOut,
)
from ..services import identity, provision, recovery
from ..services.tasks import Task, detached, tasks

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/nodes", tags=["nodes"])


# ---------------------------------------------------------------------------
# Serialisation
# ---------------------------------------------------------------------------


def _metadata() -> dict[str, dict[str, Any]]:
    """Provisioning metadata from the registry file, keyed by node name.

    The node container ignores these fields; they are how the panel remembers that
    it installed a node and how to reach it again.
    """
    try:
        return {str(node.get("name")): node for node in registry.load_nodes()}
    except registry.RegistryError as exc:
        logger.warning("could not read the exit node registry: %s", exc)
        return {}


def _serialise(
    node: ExitNodeState,
    meta: dict[str, Any] | None,
    recovering: dict[str, Any] | None = None,
) -> ExitNode:
    meta = meta or {}
    created = meta.get("created_at")
    created_at: datetime | None = None
    if isinstance(created, str):
        try:
            created_at = datetime.fromisoformat(created.replace("Z", "+00:00"))
        except ValueError:
            created_at = None

    running = tasks.active_for(node.name)
    return ExitNode(
        name=node.name,
        iface=node.iface,
        address=node.address,
        priority=node.priority,
        endpoint=node.endpoint,
        exit_ip=node.exit_ip,
        public_key=node.public_key,
        peer_public_key=node.peer_public_key,
        paired=node.paired,
        healthy=node.healthy,
        active=node.active,
        stalled=node.stalled,
        last_handshake_at=node.last_handshake,
        handshake_age_seconds=node.handshake_age,
        latency_ms=node.latency_ms,
        rx_bytes=node.rx_bytes,
        tx_bytes=node.tx_bytes,
        # The running interface is the authority; the registry entry is only what was
        # asked for, and an older node container reports neither.
        protocol=node.protocol or meta.get("protocol") or None,
        managed=bool(meta.get("managed")),
        ssh_host=meta.get("ssh_host"),
        ssh_port=meta.get("ssh_port"),
        ssh_user=meta.get("ssh_user"),
        ssh_key=bool(meta.get("ssh_key")) and settings.node_ssh_key_enabled,
        created_at=created_at,
        task_id=running.id if running else None,
        recovery=NodeRecovery(**recovering) if recovering else None,
    )


def _snapshot(mode: str | None = None, pinned: str | None = None) -> ExitNodeList:
    """The node's published state, optionally overlaid with an intent just written.

    The container only picks the control file up on its next health tick, so without
    the overlay a POST would answer with the state it was trying to change.
    """
    state = load_uplink_state()
    meta = _metadata()
    recovering = recovery.state()
    return ExitNodeList(
        mode=mode if mode is not None else state.mode,
        active=state.active,
        pinned=pinned if mode is not None else state.pinned,
        killswitch=state.killswitch,
        fallback=state.fallback,
        fallback_active=state.fallback_active,
        stale=state.stale,
        updated_at=state.updated_at,
        config_error=registry.config_error(),
        provisioning=registry.writable(),
        nodes=[
            _serialise(node, meta.get(node.name), recovering.get(node.name))
            for node in state.nodes
        ],
    )


def _task_out(task: Task) -> TaskOut:
    return TaskOut(
        id=task.id,
        action=task.action,
        target=task.target,
        status=task.status,
        step=task.step,
        error=task.error,
        result=task.result,
        created_at=task.created_at,
        finished_at=task.finished_at,
        log=[TaskLogLine(at=line.at, text=line.text) for line in task.log],
    )


# ---------------------------------------------------------------------------
# Shared plumbing
# ---------------------------------------------------------------------------


def _require_provision_enabled() -> None:
    if not settings.node_provision_enabled:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="exit node management is disabled (NODE_PROVISION_ENABLED=false)",
        )


def _require_provisioning() -> None:
    """For anything that edits the cascade, as opposed to the servers in it."""
    _require_provision_enabled()
    # Writing the file would succeed and change nothing at all, which is worse than
    # refusing: the operator would watch a node appear and never come up.
    if not registry.writable():
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=registry.config_error() or "the cascade is not managed by this panel",
        )


def _reject_if_busy(name: str) -> None:
    running = tasks.active_for(name)
    if running is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"another operation on {name!r} is still running (task {running.id})",
        )


async def _apply_and_wait(task: Task) -> None:
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


async def _wait_for_uplink_key(task: Task, name: str, timeout: int = 60) -> str:
    for _ in range(timeout * 2):
        key = registry.uplink_public_key(name)
        if key:
            return key
        await asyncio.sleep(0.5)
    raise provision.ProvisionError(
        f"the node container did not publish an uplink key for {name!r}"
    )


# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------


def _panel_private_key() -> str | None:
    """The panel's own key, when it has one and is allowed to use it."""
    if not settings.node_ssh_key_enabled:
        return None
    return identity.private_key()


def _panel_public_key() -> str | None:
    """The key to leave behind on a server we are logging into with a password.

    Generated on first use, so an installation that predates this gets an identity
    the first time it installs a node rather than needing a migration step.
    """
    if not settings.node_ssh_key_enabled:
        return None
    try:
        return identity.ensure().public_key
    except identity.IdentityError as exc:
        # Not fatal: the operation the caller asked for can still run with the
        # credentials they supplied, they will just have to supply them again.
        logger.warning("could not prepare the panel's SSH identity: %s", exc)
        return None


def _credentials(
    host: str,
    *,
    port: int,
    username: str,
    payload: NodeCredentials | None,
    host_key: str | None = None,
    enrolled: bool = False,
    missing_detail: str,
) -> provision.Credentials:
    """Whichever way in the caller has: their credentials, or the panel's key.

    Supplying credentials also enrols the panel's public key, so this is the last
    time they are needed for that server.
    """
    password = payload.ssh_password if payload else None
    private_key = payload.ssh_private_key if payload else None

    if password or private_key:
        return provision.Credentials(
            host=host,
            port=port,
            username=username,
            password=password,
            private_key=private_key,
            host_key=host_key,
            enroll_key=_panel_public_key(),
        )

    panel_key = _panel_private_key() if enrolled else None
    if not panel_key:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=missing_detail
        )
    return provision.Credentials(
        host=host,
        port=port,
        username=username,
        private_key=panel_key,
        host_key=host_key,
        # It is the key we are logging in with, so it is already in place.
        enrolled=True,
    )


def _credentials_from(payload: ExitNodeCreate) -> provision.Credentials:
    return _credentials(
        payload.host,
        port=payload.ssh_port,
        username=payload.ssh_user,
        payload=payload,
        # A server created with the panel's public key already injected needs no
        # password at all, which is the flow a bot should use.
        enrolled=True,
        missing_detail=(
            "an SSH password or private key is required to install the node, unless "
            "the panel's own key is already on the server. Fetch it from "
            "GET /api/nodes/ssh-key and add it to the server's authorised keys to "
            "install without a password."
        ),
    )


def _credentials_for(node: dict[str, Any], payload: NodeCredentials | None) -> provision.Credentials:
    """Reaches a node the panel already knows, for a repair, upgrade or removal."""
    name = node.get("name")
    host = node.get("ssh_host")
    if not host:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{name!r} has no SSH address recorded, so it cannot be reached from "
            f"here. It was added by hand, and is managed on that server with `saucewg`.",
        )
    return _credentials(
        str(host),
        port=int(node.get("ssh_port") or 22),
        username=str(node.get("ssh_user") or "root"),
        payload=payload,
        host_key=node.get("ssh_host_key"),
        enrolled=bool(node.get("ssh_key")),
        missing_detail=(
            f"SSH credentials are required: the panel's key is not installed on "
            f"{name!r}. Supply a password once and it will be, and later calls will "
            f"need none."
        ),
    )


def _remember_key(name: str, credentials: provision.Credentials) -> None:
    """Records that this node can be reached again without credentials."""
    if not credentials.enrolled:
        return
    try:
        nodes = registry.load_nodes()
        node = registry.find(nodes, name)
        if node is None or node.get("ssh_key"):
            return
        node["ssh_key"] = True
        # No reload: the node container ignores the provisioning metadata, so
        # rebuilding an interface over this would be gratuitous.
        registry.save_nodes(nodes)
    except registry.RegistryError as exc:
        logger.warning("could not record the SSH key for %s: %s", name, exc)


def _find_or_404(name: str) -> dict[str, Any]:
    try:
        nodes = registry.load_nodes()
    except registry.RegistryError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)
        ) from exc
    node = registry.find(nodes, name)
    if node is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail=f"no exit node named {name!r}"
        )
    return node


def _copy_profile(reported: dict[str, Any], entry: dict[str, Any]) -> dict[str, Any]:
    """Carries an exit node's obfuscation profile into its registry entry.

    S1-S4 and H1-H4 have to be repeated on the entry side because both ends of a
    tunnel must pad and label packets identically. Recording the generation alongside
    them is what keeps a later reload from rebuilding the uplink as something else.
    """
    if reported.get("protocol"):
        entry["protocol"] = reported["protocol"]
    for name in awg_protocol.ALL_PARAMS:
        key = name.lower()
        value = reported.get(key)
        if value is not None and str(value) != "":
            entry[key] = value
    return entry


def _register(node: dict[str, Any], nodes: list[dict[str, Any]]) -> dict[str, Any]:
    """Fills in the address and priority the entry node assigns, then persists."""
    if not node.get("address"):
        node["address"] = registry.allocate_address(nodes)
    if node.get("priority") is None:
        node["priority"] = registry.next_priority(nodes)
    node.setdefault("created_at", datetime.now(timezone.utc).isoformat())
    nodes.append(node)
    registry.save_nodes(nodes)
    return node


# ---------------------------------------------------------------------------
# Inventory
# ---------------------------------------------------------------------------


@router.get("", response_model=ExitNodeList)
async def list_nodes(_: AdminDep) -> ExitNodeList:
    return _snapshot()


@router.get("/tasks", response_model=list[TaskOut])
async def list_tasks(_: AdminDep, limit: int = Query(default=20, ge=1, le=50)) -> list[TaskOut]:
    return [_task_out(task) for task in tasks.recent(limit)]


@router.get("/tasks/{task_id}", response_model=TaskOut)
async def read_task(task_id: str, _: AdminDep) -> TaskOut:
    task = tasks.get(task_id)
    if task is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="unknown task")
    return _task_out(task)


# ---------------------------------------------------------------------------
# The panel's SSH identity
# ---------------------------------------------------------------------------


@router.get("/ssh-key", response_model=PanelSshKey)
async def read_ssh_key(_: AdminDep) -> PanelSshKey:
    """The public key this panel manages exit nodes with, generated on first read.

    Put it in a new server's authorised keys — most providers offer a field for
    that at creation time — and the server can then be installed and managed with
    no password ever leaving the caller.
    """
    if not settings.node_ssh_key_enabled:
        return PanelSshKey(public_key="", fingerprint="", enabled=False)
    try:
        key = identity.ensure()
    except identity.IdentityError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)
        ) from exc
    return PanelSshKey(
        public_key=key.public_key, fingerprint=key.fingerprint, created_at=key.created_at
    )


@router.post("/check", response_model=NodeCheckResult)
async def check_server(payload: NodeCheck, admin: SudoAdminDep) -> NodeCheckResult:
    """Looks at a server without touching it, before committing to an install.

    Answers in one round trip whether the credentials work, whether the account can
    act as root, what the machine is, and whether SauceWG is already on it — the
    things that otherwise only surface several minutes into a failed install.
    """
    _require_provision_enabled()
    credentials = _credentials(
        payload.host,
        port=payload.ssh_port,
        username=payload.ssh_user,
        payload=payload,
        enrolled=True,
        missing_detail=(
            "an SSH password or private key is required, unless the panel's own key "
            "(GET /api/nodes/ssh-key) is already on the server"
        ),
    )
    # A check is a dry run: it reports what it found rather than leaving a key behind.
    used_panel_key = credentials.enrolled
    credentials.enroll_key = None

    task = detached("check", payload.host)
    logger.info("admin %s is checking %s", admin.username, payload.host)
    try:
        facts = await asyncio.wait_for(
            provision.probe_server(task, credentials),
            timeout=settings.node_ssh_query_timeout_seconds,
        )
    except (provision.ProvisionError, asyncio.TimeoutError) as exc:
        detail = str(exc) or f"{payload.host} did not answer in time"
        return NodeCheckResult(reachable=False, error=detail, used_panel_key=used_panel_key)

    return NodeCheckResult(
        reachable=True,
        root=bool(facts.get("root")),
        os=facts.get("os"),
        kernel=facts.get("kernel"),
        arch=facts.get("arch"),
        cpus=int(facts.get("cpus") or 0),
        memory_mb=int(facts.get("memory_mb") or 0),
        disk_free_mb=int(facts.get("disk_free_mb") or 0),
        uptime_seconds=int(facts.get("uptime_seconds") or 0),
        docker=bool(facts.get("docker")),
        saucewg=bool(facts.get("saucewg")),
        role=facts.get("role"),
        host_key=facts.get("host_key"),
        used_panel_key=used_panel_key,
    )


# ---------------------------------------------------------------------------
# Provisioning
# ---------------------------------------------------------------------------


@router.post("", response_model=TaskOut, status_code=status.HTTP_202_ACCEPTED)
async def create_node(payload: ExitNodeCreate, admin: SudoAdminDep) -> TaskOut:
    """Installs an exit node on a server and joins it to the cascade.

    Answers as soon as the work is queued: a cold install pulls Docker and three
    images, so the caller polls ``GET /api/nodes/tasks/{id}`` for progress.
    """
    _require_provisioning()
    _reject_if_busy(payload.name)

    try:
        existing = registry.load_nodes()
    except registry.RegistryError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc
    if registry.find(existing, payload.name) is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"an exit node named {payload.name!r} already exists",
        )

    credentials = _credentials_from(payload)
    logger.info("admin %s is installing exit node %s on %s", admin.username, payload.name, payload.host)

    async def work(task: Task) -> None:
        request = provision.InstallRequest(
            name=payload.name,
            credentials=credentials,
            port=payload.port,
            subnet=payload.subnet,
            preshared_key=payload.preshared_key,
            protocol=payload.protocol,
            signature=payload.signature,
        )
        node = await provision.install_exit_node(task, request)

        task.begin("Joining the cascade")
        entry = {
            "name": node["name"],
            "endpoint": node["endpoint"],
            "public_key": node["public_key"],
            "managed": True,
            "ssh_host": payload.host,
            "ssh_port": payload.ssh_port,
            "ssh_user": payload.ssh_user,
            "ssh_host_key": node.get("ssh_host_key"),
            # Set by the install session above. Everything else this panel does to
            # the node — status, logs, restart, upgrade, repair — then needs no
            # credentials, which is what makes the API usable from a bot.
            "ssh_key": credentials.enrolled,
        }
        _copy_profile(node, entry)
        if payload.preshared_key:
            entry["preshared_key"] = payload.preshared_key
        if payload.address:
            entry["address"] = payload.address
        if payload.priority is not None:
            entry["priority"] = payload.priority
        if payload.note:
            entry["note"] = payload.note

        entry = _register(entry, registry.load_nodes())
        task.emit(f"uplink address {entry['address']}, priority {entry['priority']}")

        await _apply_and_wait(task)

        task.begin("Pairing the two ends")
        uplink_key = await _wait_for_uplink_key(task, payload.name)
        task.emit(f"entry uplink key {uplink_key}")
        await provision.pair_exit_node(
            task, credentials, uplink_key, payload.preshared_key
        )

        task.begin("Waiting for the tunnel")
        healthy = await _await_handshake(task, payload.name)
        _remember_key(payload.name, credentials)
        task.result = {
            "name": payload.name,
            "endpoint": entry["endpoint"],
            "address": entry["address"],
            "priority": entry["priority"],
            "uplink_public_key": uplink_key,
            "protocol": entry.get("protocol"),
            "ssh_key": credentials.enrolled,
            "healthy": healthy,
        }
        if healthy:
            task.emit(f"exit node {payload.name} is up and carrying handshakes")
        else:
            task.emit(
                f"exit node {payload.name} was added but has not handshaked yet; "
                f"check that UDP/{payload.port} reaches {payload.host}"
            )

    return _task_out(tasks.start("install", payload.name, work))


async def _await_handshake(task: Task, name: str, timeout: int = 90) -> bool:
    """True once the node container reports a live handshake on that uplink."""
    for _ in range(timeout):
        state = load_uplink_state()
        node = state.get(name)
        if node is not None and node.last_handshake is not None:
            return True
        await asyncio.sleep(1)
    return False


async def _await_health(task: Task, name: str, timeout: int = 120) -> bool:
    """True once an uplink that already existed is passing health checks again.

    A restart or an upgrade leaves the last handshake time in place, so recovery has
    to be read from the health flag the node container maintains rather than from
    the fact that a handshake once happened.
    """
    for _ in range(timeout):
        node = load_uplink_state().get(name)
        if node is not None and node.healthy:
            return True
        await asyncio.sleep(1)
    return False


@router.post("/adopt", response_model=ExitNodeList, status_code=status.HTTP_201_CREATED)
async def adopt_node(payload: ExitNodeAdopt, admin: SudoAdminDep) -> ExitNodeList:
    """Adds an exit node that was installed by hand, with no SSH involved.

    Takes exactly the object ``saucewg install-node --json`` prints. The uplink key
    the entry node generates in return still has to be installed on that server.
    """
    _require_provisioning()
    try:
        nodes = registry.load_nodes()
    except registry.RegistryError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc
    if registry.find(nodes, payload.name) is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"an exit node named {payload.name!r} already exists",
        )

    entry = payload.model_dump(exclude_none=True)
    entry["managed"] = False
    try:
        _register(entry, nodes)
        registry.request_reload()
    except registry.RegistryError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc

    logger.info("admin %s adopted exit node %s", admin.username, payload.name)
    return _snapshot()


@router.put("/{name}", response_model=ExitNodeList)
async def update_node(name: str, payload: ExitNodeUpdate, admin: SudoAdminDep) -> ExitNodeList:
    """Changes an exit node's failover priority, endpoint or note.

    A priority change is only a routing decision, so the tunnel is never rebuilt.
    """
    _require_provisioning()
    _reject_if_busy(name)
    try:
        nodes = registry.load_nodes()
        node = registry.find(nodes, name)
        if node is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail=f"no exit node named {name!r}"
            )
        changes = payload.model_dump(exclude_none=True)
        if not changes:
            return _snapshot()
        node.update(changes)
        registry.save_nodes(nodes)
        registry.request_reload()
    except registry.RegistryError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc

    # A new endpoint or SSH address is a different server as far as recovery is
    # concerned, so whatever it had given up on no longer applies.
    recovery.forget(name)
    logger.info("admin %s updated exit node %s: %s", admin.username, name, sorted(changes))
    return _snapshot()


@router.delete("/{name}", response_model=TaskOut, status_code=status.HTTP_202_ACCEPTED)
async def delete_node(
    name: str, admin: SudoAdminDep, payload: ExitNodeDelete | None = None
) -> TaskOut:
    """Removes an exit node from the cascade, and optionally wipes the server.

    The node leaves the cascade first and the remote cleanup runs afterwards, so a
    server that is already unreachable can still be removed. The body is optional:
    without one the node is only detached.
    """
    _require_provisioning()
    _reject_if_busy(name)
    payload = payload or ExitNodeDelete()

    node = _find_or_404(name)

    credentials: provision.Credentials | None = None
    revoke: str | None = None
    if payload.uninstall:
        if not node.get("ssh_host"):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=f"{name!r} was not installed by the panel, so it has no SSH address "
                f"to clean up; remove it without `uninstall` and wipe the server by hand",
            )
        credentials = _credentials_for(node, payload)
        # Nothing is coming back to this server, so leaving a key behind on it would
        # be the one thing this operation is supposed to prevent.
        credentials.enroll_key = None
        if payload.revoke_key and node.get("ssh_key"):
            revoke = _panel_public_key()

    logger.info("admin %s is removing exit node %s (uninstall=%s)", admin.username, name, payload.uninstall)

    async def work(task: Task) -> None:
        task.begin(f"Removing {name} from the cascade")
        current = registry.load_nodes()
        registry.save_nodes([item for item in current if item.get("name") != name])
        await _apply_and_wait(task)

        if credentials is not None:
            task.begin("Cleaning up the server")
            try:
                await provision.uninstall_exit_node(task, credentials, revoke_key=revoke)
            except provision.ProvisionError as exc:
                # The node is already out of the cascade; a leftover container on a
                # server we no longer use is not worth failing the whole operation.
                task.emit(f"could not clean up {credentials.host}: {exc}")
                task.emit("the node was still removed from the cascade")

        recovery.forget(name)
        task.result = {"name": name, "removed": True, "uninstalled": credentials is not None}

    return _task_out(tasks.start("remove", name, work))


@router.post("/{name}/repair", response_model=TaskOut, status_code=status.HTTP_202_ACCEPTED)
async def repair_node(name: str, payload: NodeCredentials, admin: SudoAdminDep) -> TaskOut:
    """Re-installs the entry node's uplink key on an exit node.

    This is the fix for an uplink that shows as unpaired or never handshakes: the
    exit node is reachable but is not trusting the key this entry node generated
    for it, usually because it was rebuilt or its .env was reset.
    """
    _require_provisioning()
    _reject_if_busy(name)

    node = _find_or_404(name)
    credentials = _credentials_for(node, payload)
    preshared_key = node.get("preshared_key") or None

    logger.info("admin %s is repairing exit node %s", admin.username, name)

    async def work(task: Task) -> None:
        task.begin("Fetching the uplink key")
        uplink_key = await _wait_for_uplink_key(task, name)
        task.emit(f"entry uplink key {uplink_key}")

        task.begin("Pairing the two ends")
        await provision.pair_exit_node(task, credentials, uplink_key, preshared_key)
        _remember_key(name, credentials)

        task.begin("Waiting for the tunnel")
        healthy = await _await_handshake(task, name)
        task.result = {"name": name, "uplink_public_key": uplink_key, "healthy": healthy}

    return _task_out(tasks.start("repair", name, work))


@router.post("/{name}/recover", response_model=TaskOut, status_code=status.HTTP_202_ACCEPTED)
async def recover_node(name: str, admin: SudoAdminDep) -> TaskOut:
    """Tries to put a failed exit node back, escalating until it handshakes.

    The same thing the panel does on its own timer, run now: probe the server, then
    restart its service, then re-install the uplink key. Takes no credentials — it
    uses the panel's own key, which is what makes it usable unattended, and a node
    the panel has no key on cannot be recovered from here at all.

    Asking for it clears whatever the automatic attempts had given up on, since an
    operator asking has usually just fixed the reason.
    """
    _require_provision_enabled()
    _reject_if_busy(name)

    node = _find_or_404(name)
    if not node.get("ssh_host"):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{name!r} was not installed by the panel, so it has no SSH address "
            f"to reach. Recover it on that server with `saucewg restart`.",
        )

    logger.info("admin %s is recovering exit node %s", admin.username, name)

    async def work(task: Task) -> None:
        task.begin(f"Recovering {name}")
        result = await recovery.recover_now(name)
        task.result = result
        if result["healthy"]:
            task.emit(f"{name} is carrying traffic again")
        elif not result["acted"]:
            task.emit(f"{name} is already healthy; nothing was touched")
        else:
            # Not a task failure: the attempt ran and reported what it found, and
            # what it found is the answer the operator asked for.
            task.emit(result.get("last_error") or f"{name} did not come back")
            if result.get("blocked") == recovery.UNREACHABLE:
                task.emit(
                    "the server does not answer at all, so there is nothing left to "
                    "try from here — check whether the VPS still exists"
                )

    return _task_out(tasks.start("recover", name, work))


@router.post("/{name}/protocol", response_model=TaskOut, status_code=status.HTTP_202_ACCEPTED)
async def change_node_protocol(
    name: str, payload: ExitNodeProtocolChange, admin: SudoAdminDep
) -> TaskOut:
    """Moves one exit node, and the uplink to it, to another AmneziaWG generation.

    The two ends have to agree on S1-S4 and H1-H4, so the exit node is reconfigured
    first and the uplink is then rebuilt with the profile it reports back. The tunnel
    is down for the few seconds in between, which is why this is a task rather than a
    plain edit.
    """
    _require_provisioning()
    _reject_if_busy(name)

    node = _find_or_404(name)
    if not node.get("ssh_host"):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{name!r} was not installed by the panel, so its generation cannot be "
            f"changed from here. Run `saucewg set-protocol {payload.protocol}` on that "
            f"server and re-adopt it with the profile it prints.",
        )
    credentials = _credentials_for(node, payload)

    logger.info(
        "admin %s is moving exit node %s to AmneziaWG %s", admin.username, name, payload.protocol
    )

    async def work(task: Task) -> None:
        task.begin(f"Reconfiguring {name} for AmneziaWG {payload.protocol}")
        reported = await provision.set_exit_node_protocol(
            task, credentials, payload.protocol, payload.signature
        )
        _remember_key(name, credentials)

        task.begin("Rebuilding the uplink")
        current = registry.load_nodes()
        entry = registry.find(current, name)
        if entry is None:
            raise provision.ProvisionError(
                f"{name} was removed from the cascade while it was being reconfigured"
            )
        # The old generation's parameters have to go, not just be overwritten: a
        # leftover S3 would keep the uplink advertising 2.0 to a 1.0 exit node.
        for param in awg_protocol.ALL_PARAMS:
            entry.pop(param.lower(), None)
        _copy_profile(reported, entry)
        entry["protocol"] = payload.protocol
        registry.save_nodes(current)
        await _apply_and_wait(task)

        task.begin("Waiting for the tunnel")
        healthy = await _await_handshake(task, name)
        task.result = {"name": name, "protocol": payload.protocol, "healthy": healthy}
        if not healthy:
            task.emit(
                f"{name} was moved to AmneziaWG {payload.protocol} but has not handshaked "
                f"yet; if it does not recover, run a repair to re-install the uplink key"
            )

    return _task_out(tasks.start("protocol", name, work))


# ---------------------------------------------------------------------------
# Managing the servers themselves
# ---------------------------------------------------------------------------


@router.get("/{name}/status", response_model=NodeStatus)
async def read_node_status(name: str, admin: SudoAdminDep) -> NodeStatus:
    """What the exit server says about itself: containers, version, host facts.

    ``GET /api/nodes`` reports the uplink as the entry node sees it, which says
    nothing about a server that is up but whose containers are not. This is the
    other half, and it is a live SSH session rather than cached state.
    """
    _require_provision_enabled()
    node = _find_or_404(name)
    credentials = _credentials_for(node, None)

    task = detached("status", name)
    try:
        facts = await asyncio.wait_for(
            provision.node_status(task, credentials),
            timeout=settings.node_ssh_query_timeout_seconds,
        )
    except (provision.ProvisionError, asyncio.TimeoutError) as exc:
        logger.info("admin %s could not reach exit node %s: %s", admin.username, name, exc)
        return NodeStatus(
            name=name,
            reachable=False,
            error=str(exc) or f"{node.get('ssh_host')} did not answer in time",
            ssh_host=node.get("ssh_host"),
        )

    return NodeStatus(
        name=name,
        reachable=True,
        error=facts.get("error"),
        ssh_host=node.get("ssh_host"),
        role=facts.get("role"),
        cli_version=facts.get("cli_version"),
        dir=facts.get("dir"),
        os=facts.get("os"),
        kernel=facts.get("kernel"),
        arch=facts.get("arch"),
        cpus=int(facts.get("cpus") or 0),
        memory_mb=int(facts.get("memory_mb") or 0),
        disk_free_mb=int(facts.get("disk_free_mb") or 0),
        uptime_seconds=int(facts.get("uptime_seconds") or 0),
        docker=bool(facts.get("docker")),
        saucewg=bool(facts.get("saucewg")),
        containers=[
            NodeContainer(
                name=str(item.get("name") or ""),
                state=str(item.get("state") or ""),
                status=str(item.get("status") or ""),
            )
            for item in facts.get("containers") or []
            if isinstance(item, dict)
        ],
    )


@router.get("/{name}/logs", response_model=NodeLogs)
async def read_node_logs(
    name: str,
    admin: SudoAdminDep,
    service: str | None = Query(default=None, pattern=r"^[a-z][a-z0-9_-]{0,31}$"),
    lines: int = Query(default=200, ge=1, le=2000),
) -> NodeLogs:
    """The tail of an exit node's container logs, without opening a shell on it."""
    _require_provision_enabled()
    node = _find_or_404(name)
    credentials = _credentials_for(node, None)

    task = detached("logs", name)
    logger.info("admin %s is reading the logs of exit node %s", admin.username, name)
    try:
        text = await asyncio.wait_for(
            provision.fetch_logs(task, credentials, service, lines),
            timeout=settings.node_ssh_query_timeout_seconds,
        )
    except asyncio.TimeoutError as exc:
        raise HTTPException(
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            detail=f"{node.get('ssh_host')} did not return its logs in time",
        ) from exc
    except provision.ProvisionError as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY, detail=str(exc)
        ) from exc
    return NodeLogs(name=name, service=service, lines=lines, text=text)


def _service_task(name: str, action: str, payload: NodeServiceRequest | None, admin: Admin) -> TaskOut:
    """Shared body of start, stop and restart."""
    _require_provision_enabled()
    _reject_if_busy(name)
    node = _find_or_404(name)
    credentials = _credentials_for(node, payload)

    logger.info("admin %s is running %s on exit node %s", admin.username, action, name)

    async def work(task: Task) -> None:
        task.begin(provision.SERVICE_ACTIONS[action])
        await provision.control_service(task, credentials, action)
        _remember_key(name, credentials)
        # The operator has just done by hand what recovery would have escalated
        # through, so its history is stale either way.
        recovery.forget(name)

        healthy: bool | None = None
        if action == "stop":
            task.emit(
                f"{name} is down; the cascade fails over to the next healthy node "
                f"within about 30 seconds"
            )
        else:
            task.begin("Waiting for the tunnel")
            healthy = await _await_health(task, name)
            if not healthy:
                task.emit(f"{name} is back up but the uplink has not recovered yet")
        task.result = {"name": name, "action": action, "healthy": healthy}

    return _task_out(tasks.start(action, name, work))


@router.post("/{name}/restart", response_model=TaskOut, status_code=status.HTTP_202_ACCEPTED)
async def restart_node(
    name: str, admin: SudoAdminDep, payload: NodeServiceRequest | None = None
) -> TaskOut:
    """Recreates the exit node's containers. Clients fail over while it is down."""
    return _service_task(name, "restart", payload, admin)


@router.post("/{name}/start", response_model=TaskOut, status_code=status.HTTP_202_ACCEPTED)
async def start_node(
    name: str, admin: SudoAdminDep, payload: NodeServiceRequest | None = None
) -> TaskOut:
    return _service_task(name, "start", payload, admin)


@router.post("/{name}/stop", response_model=TaskOut, status_code=status.HTTP_202_ACCEPTED)
async def stop_node(
    name: str, admin: SudoAdminDep, payload: NodeServiceRequest | None = None
) -> TaskOut:
    """Stops the exit node without removing it from the cascade."""
    return _service_task(name, "stop", payload, admin)


@router.post("/{name}/upgrade", response_model=TaskOut, status_code=status.HTTP_202_ACCEPTED)
async def upgrade_node(
    name: str, admin: SudoAdminDep, payload: NodeUpgradeRequest | None = None
) -> TaskOut:
    """Pulls newer images on the exit server and recreates it.

    The node is upgraded to the tag this panel installs unless another is named, so
    a fleet moves as one instead of drifting a server at a time.
    """
    _require_provision_enabled()
    _reject_if_busy(name)
    node = _find_or_404(name)
    credentials = _credentials_for(node, payload)
    tag = payload.tag if payload else None

    logger.info("admin %s is upgrading exit node %s", admin.username, name)

    async def work(task: Task) -> None:
        task.begin(f"Upgrading {name}")
        result = await provision.upgrade_exit_node(task, credentials, tag)
        _remember_key(name, credentials)

        task.begin("Waiting for the tunnel")
        healthy = await _await_health(task, name)
        task.result = {
            "name": name,
            "tag": result.get("tag") or tag,
            "cli_version": result.get("cli_version"),
            "healthy": healthy,
        }
        if not healthy:
            task.emit(
                f"{name} was upgraded but has not handshaked yet; give it a minute, "
                f"then run a repair if it stays down"
            )

    return _task_out(tasks.start("upgrade", name, work))


# ---------------------------------------------------------------------------
# Failover control
# ---------------------------------------------------------------------------


@router.post("/{name}/activate", response_model=ExitNodeList)
async def activate_node(name: str, admin: AdminDep) -> ExitNodeList:
    """Prefers one exit node.

    The preference is not a lock: the node container still fails over when the
    pinned node goes down, and comes back to it once it recovers.
    """
    state = load_uplink_state()
    if state.get(name) is None:
        known = ", ".join(node.name for node in state.nodes) or "none"
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"unknown exit node {name!r}; configured: {known}",
        )
    try:
        write_control(MANUAL, name)
    except OSError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"could not reach the node container: {exc}",
        ) from exc
    logger.info("admin %s pinned the cascade to exit node %s", admin.username, name)
    return _snapshot(mode=MANUAL, pinned=name)


@router.post("/auto", response_model=ExitNodeList)
async def automatic_failover(admin: AdminDep) -> ExitNodeList:
    """Drops any pin and lets priority plus health pick the uplink."""
    try:
        write_control(AUTO)
    except OSError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"could not reach the node container: {exc}",
        ) from exc
    logger.info("admin %s returned the cascade to automatic failover", admin.username)
    return _snapshot(mode=AUTO, pinned=None)
