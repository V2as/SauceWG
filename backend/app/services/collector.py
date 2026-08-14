"""Polls the AmneziaWG device for per-peer counters and online state."""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from ..awg import server_device
from ..awg.uapi import DeviceUnavailable
from ..config import settings
from ..models import Client, ClientUsage, NodeUsage
from .clients import next_reset_due, refresh_status

logger = logging.getLogger(__name__)


class SpeedTracker:
    """Keeps the most recent throughput sample so the dashboard can show live rates."""

    def __init__(self) -> None:
        self.incoming = 0
        self.outgoing = 0
        self._at: datetime | None = None

    def update(self, up_delta: int, down_delta: int, now: datetime) -> None:
        if self._at is not None:
            elapsed = (now - self._at).total_seconds()
            if elapsed > 0:
                self.incoming = int(up_delta / elapsed)
                self.outgoing = int(down_delta / elapsed)
        self._at = now


speed = SpeedTracker()


def _bucket(now: datetime) -> datetime:
    minutes = max(1, settings.usage_bucket_minutes)
    total = now.hour * 60 + now.minute
    aligned = (total // minutes) * minutes
    return now.replace(hour=aligned // 60, minute=aligned % 60, second=0, microsecond=0)


async def _record_usage(
    session: AsyncSession, client_id: int, bucket: datetime, up: int, down: int
) -> None:
    stmt = (
        pg_insert(ClientUsage)
        .values(client_id=client_id, bucket=bucket, up=up, down=down)
        .on_conflict_do_update(
            index_elements=[ClientUsage.client_id, ClientUsage.bucket],
            set_={
                "up": ClientUsage.up + up,
                "down": ClientUsage.down + down,
            },
        )
    )
    await session.execute(stmt)


async def _record_node_usage(
    session: AsyncSession, bucket: datetime, up: int, down: int
) -> None:
    stmt = (
        pg_insert(NodeUsage)
        .values(bucket=bucket, iface=settings.awg_iface, up=up, down=down)
        .on_conflict_do_update(
            index_elements=[NodeUsage.bucket, NodeUsage.iface],
            set_={"up": NodeUsage.up + up, "down": NodeUsage.down + down},
        )
    )
    await session.execute(stmt)


async def collect(session: AsyncSession) -> bool:
    """Returns True when a status changed and the peer list needs to be re-synced."""
    try:
        state = await server_device.get()
    except DeviceUnavailable as exc:
        logger.debug("collector skipped: %s", exc)
        return False

    now = datetime.now(timezone.utc)
    bucket = _bucket(now)
    online_cutoff = now - timedelta(seconds=settings.online_timeout_seconds)

    clients = (await session.execute(select(Client))).scalars().all()
    dirty = False
    node_up = node_down = 0

    for client in clients:
        if next_reset_due(client, now):
            client.used_up = 0
            client.used_down = 0
            client.traffic_reset_at = now
            dirty = True

        peer = state.peers.get(client.public_key)
        if peer is not None:
            # A restarted device resets counters to zero; treat a drop as a fresh start.
            up_delta = peer.rx_bytes - client.counter_rx
            down_delta = peer.tx_bytes - client.counter_tx
            if up_delta < 0:
                up_delta = peer.rx_bytes
            if down_delta < 0:
                down_delta = peer.tx_bytes

            client.counter_rx = peer.rx_bytes
            client.counter_tx = peer.tx_bytes

            if up_delta or down_delta:
                client.used_up += up_delta
                client.used_down += down_delta
                client.lifetime_up += up_delta
                client.lifetime_down += down_delta
                node_up += up_delta
                node_down += down_delta
                await _record_usage(session, client.id, bucket, up_delta, down_delta)

            client.last_handshake_at = peer.last_handshake
            if peer.endpoint:
                client.last_endpoint = peer.endpoint
            client.online_at = (
                peer.last_handshake
                if peer.last_handshake and peer.last_handshake >= online_cutoff
                else None
            )
        else:
            client.online_at = None

        previous = client.status
        if refresh_status(client) != previous:
            dirty = True

    if node_up or node_down:
        await _record_node_usage(session, bucket, node_up, node_down)
    speed.update(node_up, node_down, now)

    await session.commit()
    return dirty


async def purge_old_usage(session: AsyncSession) -> None:
    cutoff = datetime.now(timezone.utc) - timedelta(days=settings.usage_retention_days)
    await session.execute(ClientUsage.__table__.delete().where(ClientUsage.bucket < cutoff))
    await session.execute(NodeUsage.__table__.delete().where(NodeUsage.bucket < cutoff))
    await session.commit()
