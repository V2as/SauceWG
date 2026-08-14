from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone
from typing import Annotated

import psutil
from fastapi import APIRouter, Query
from sqlalchemy import func, select

from .. import __version__
from ..awg import device_for
from ..awg.node import load_cascade_params, load_server_params
from ..awg.uapi import UAPIError
from ..awg.uplinks import load_uplink_state
from ..config import settings
from ..deps import AdminDep, SessionDep
from ..models import Client, ClientStatus, NodeUsage
from ..schemas import (
    CascadeStatus,
    NodeSettings,
    SystemStats,
    UsagePoint,
    UsageSeries,
)
from ..services.collector import speed
from ..services.sync import sync_peers

router = APIRouter(tags=["system"])


async def build_cascade_status() -> CascadeStatus:
    """Summarises the uplink the client traffic is currently leaving through."""
    state = load_uplink_state()
    status = CascadeStatus(
        enabled=settings.cascade_enabled,
        connected=False,
        iface=settings.cascade_iface,
        mode=state.mode,
        nodes_total=len(state.nodes),
        nodes_healthy=sum(1 for node in state.nodes if node.healthy),
    )
    if not settings.cascade_enabled:
        return status

    if not state.nodes:
        return await _legacy_cascade_status(status)

    active = state.active_node
    if active is None:
        return status

    status.node = active.name
    status.iface = active.iface
    status.endpoint = active.endpoint
    status.exit_ip = active.exit_ip
    status.peer_public_key = active.peer_public_key
    status.last_handshake_at = active.last_handshake
    status.rx_bytes = active.rx_bytes
    status.tx_bytes = active.tx_bytes
    # A stale state file means the node's monitor stopped, so its verdict on the
    # link cannot be trusted any more.
    status.connected = active.healthy and not state.stale
    return status


async def _legacy_cascade_status(status: CascadeStatus) -> CascadeStatus:
    """Fallback for a node container that predates the multi-uplink state file."""
    params = load_cascade_params()
    endpoint = params.get("UPLINK_ENDPOINT")
    status.endpoint = endpoint
    status.exit_ip = endpoint.rsplit(":", 1)[0] if endpoint else None

    try:
        device = await device_for(settings.cascade_iface).get()
    except UAPIError:
        return status

    for peer in device.peers.values():
        status.peer_public_key = peer.public_key
        status.last_handshake_at = peer.last_handshake
        status.rx_bytes = peer.rx_bytes
        status.tx_bytes = peer.tx_bytes
        if peer.endpoint:
            status.endpoint = peer.endpoint
            status.exit_ip = peer.endpoint.rsplit(":", 1)[0]
        if peer.last_handshake:
            age = datetime.now(timezone.utc) - peer.last_handshake
            status.connected = age.total_seconds() < settings.online_timeout_seconds
        break
    return status


@router.get("/system", response_model=SystemStats)
async def system_stats(session: SessionDep, _: AdminDep) -> SystemStats:
    server = load_server_params()
    memory = psutil.virtual_memory()
    disk = psutil.disk_usage("/")

    totals = (
        await session.execute(
            select(
                func.count(Client.id),
                func.coalesce(func.sum(Client.lifetime_up), 0),
                func.coalesce(func.sum(Client.lifetime_down), 0),
            )
        )
    ).one()
    active = (
        await session.execute(
            select(func.count(Client.id)).where(Client.status == ClientStatus.active)
        )
    ).scalar_one()
    online = (
        await session.execute(
            select(func.count(Client.id)).where(Client.online_at.isnot(None))
        )
    ).scalar_one()

    return SystemStats(
        panel_title=settings.panel_title,
        version=__version__,
        cpu_percent=psutil.cpu_percent(interval=None),
        cpu_cores=psutil.cpu_count() or 1,
        mem_total=memory.total,
        mem_used=memory.total - memory.available,
        disk_total=disk.total,
        disk_used=disk.used,
        uptime_seconds=int(time.time() - psutil.boot_time()),
        clients_total=totals[0],
        clients_active=active,
        clients_online=online,
        total_up=int(totals[1]),
        total_down=int(totals[2]),
        incoming_speed=speed.incoming,
        outgoing_speed=speed.outgoing,
        node_ready=server.ready,
        server_public_key=server.public_key,
        endpoint=f"{settings.awg_endpoint_host}:{settings.awg_endpoint_port or server.port}",
        cascade=await build_cascade_status(),
    )


@router.get("/system/usage", response_model=UsageSeries)
async def node_usage(
    session: SessionDep,
    _: AdminDep,
    hours: Annotated[int, Query(ge=1, le=24 * 90)] = 24,
) -> UsageSeries:
    since = datetime.now(timezone.utc) - timedelta(hours=hours)
    rows = (
        (
            await session.execute(
                select(NodeUsage).where(NodeUsage.bucket >= since).order_by(NodeUsage.bucket)
            )
        )
        .scalars()
        .all()
    )
    points = [UsagePoint(bucket=row.bucket, up=row.up, down=row.down) for row in rows]
    return UsageSeries(
        total_up=sum(p.up for p in points),
        total_down=sum(p.down for p in points),
        points=points,
    )


@router.get("/settings", response_model=NodeSettings)
async def node_settings(_: AdminDep) -> NodeSettings:
    server = load_server_params()
    return NodeSettings(
        iface=settings.awg_iface,
        subnet=server.subnet or settings.awg_subnet,
        address=server.address,
        listen_port=server.port,
        endpoint_host=settings.awg_endpoint_host,
        endpoint_port=settings.awg_endpoint_port or server.port,
        server_public_key=server.public_key,
        mtu=server.mtu,
        client_dns=settings.client_dns,
        client_mtu=settings.client_mtu,
        client_allowed_ips=settings.client_allowed_ips,
        obfuscation=server.obfuscation or {},
    )


@router.post("/system/sync")
async def force_sync(session: SessionDep, _: AdminDep) -> dict[str, int]:
    return await sync_peers(session)
