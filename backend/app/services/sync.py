"""Reconciles the peer list on the AmneziaWG device with the database.

The device is stateless across restarts, so the database is the single source of truth
and this reconciliation runs both on demand and on a timer.
"""

from __future__ import annotations

import logging

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..awg import server_device
from ..awg.uapi import UAPIError
from ..models import Client, ClientStatus
from .addresses import with_prefix

logger = logging.getLogger(__name__)


async def desired_peers(session: AsyncSession) -> dict[str, Client]:
    result = await session.execute(select(Client).where(Client.status == ClientStatus.active))
    return {client.public_key: client for client in result.scalars()}


async def sync_peers(session: AsyncSession) -> dict[str, int]:
    """Never raises: a device that is down or restarting is retried on the next tick."""
    stats = {"added": 0, "removed": 0, "updated": 0}
    try:
        state = await server_device.get()

        wanted = await desired_peers(session)
        current = state.peers

        for public_key, client in wanted.items():
            peer = current.get(public_key)
            expected_ips = [with_prefix(client.address)]
            if peer is None:
                await server_device.add_peer(
                    public_key=public_key,
                    allowed_ips=expected_ips,
                    preshared_key=client.preshared_key,
                )
                stats["added"] += 1
            elif sorted(peer.allowed_ips) != sorted(expected_ips) or (
                peer.preshared_key != client.preshared_key
            ):
                await server_device.add_peer(
                    public_key=public_key,
                    allowed_ips=expected_ips,
                    preshared_key=client.preshared_key,
                )
                stats["updated"] += 1

        for public_key in current:
            if public_key not in wanted:
                await server_device.remove_peer(public_key)
                stats["removed"] += 1
    except UAPIError as exc:
        logger.warning("peer sync incomplete: %s", exc)
        return stats

    if any(stats.values()):
        logger.info(
            "peer sync: +%d ~%d -%d", stats["added"], stats["updated"], stats["removed"]
        )
    return stats
