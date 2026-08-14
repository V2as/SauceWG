"""Exit node inventory and failover control."""

from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException, status

from ..awg.uplinks import AUTO, MANUAL, ExitNodeState, load_uplink_state, write_control
from ..deps import AdminDep
from ..schemas import ExitNode, ExitNodeList

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/nodes", tags=["nodes"])


def _serialise(node: ExitNodeState) -> ExitNode:
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
        last_handshake_at=node.last_handshake,
        latency_ms=node.latency_ms,
        rx_bytes=node.rx_bytes,
        tx_bytes=node.tx_bytes,
    )


def _snapshot(mode: str | None = None, pinned: str | None = None) -> ExitNodeList:
    """The node's published state, optionally overlaid with an intent just written.

    The container only picks the control file up on its next health tick, so without
    the overlay a POST would answer with the state it was trying to change.
    """
    state = load_uplink_state()
    return ExitNodeList(
        mode=mode if mode is not None else state.mode,
        active=state.active,
        pinned=pinned if mode is not None else state.pinned,
        killswitch=state.killswitch,
        stale=state.stale,
        updated_at=state.updated_at,
        nodes=[_serialise(node) for node in state.nodes],
    )


@router.get("", response_model=ExitNodeList)
async def list_nodes(_: AdminDep) -> ExitNodeList:
    return _snapshot()


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
