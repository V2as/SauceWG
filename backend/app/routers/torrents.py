"""The torrent guard: one switch, and what it has caught.

A swarm sees the address of whichever server carries a client's traffic out, and a
datacentre answers a copyright notice by suspending that server rather than by
asking who was behind it. One client seeding for an evening takes the node down and
every other client on it with it, which is why this exists and why it is a switch
rather than a list of things to block.

The panel writes ``config/torrent-block.json``; the node container watches it and
applies the difference within a second, without touching a tunnel. Nothing here
talks to the network — the same file exchange the exit node list uses.

What the container does with it is documented where it is implemented, in
``docker/awg/torrents.sh``. The short version is three layers: peer discovery
(DHT, trackers, PEX, LSD) matched on signatures no client can drop, the peer wire
matched by shape before MSE can encrypt it, and an ipset of every address caught
speaking either — so the next connection to that peer dies without being read.
``strict`` adds a default-deny egress port policy, which is the only thing that
closes an encrypted connection to an address a client already knew.
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException, status
from sqlalchemy import select

from ..awg import registry
from ..awg import torrents as torrent_registry
from ..config import settings
from ..deps import AdminDep, SessionDep, SudoAdminDep
from ..models import Client
from ..schemas import TorrentCapabilities, TorrentOffender, TorrentStatus, TorrentUpdate

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/torrents", tags=["torrents"])


async def _snapshot(session: SessionDep) -> TorrentStatus:
    """The switch, what the container reports, and who has been tripping it."""
    live = torrent_registry.state()
    try:
        configured = torrent_registry.load_settings()
    except torrent_registry.TorrentError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc

    offenders = live["clients"]
    names: dict[str, Client] = {}
    if offenders:
        # A tunnel address is stored with its mask, and the container reports the
        # bare address it saw on the wire.
        rows = (await session.execute(select(Client))).scalars().all()
        names = {str(row.address).split("/")[0]: row for row in rows}

    return TorrentStatus(
        enabled=bool(configured["enabled"]),
        mode=str(configured["mode"]),
        active=bool(live["active"]),
        active_mode=live["mode"],
        rules=int(live["rules"]),
        capabilities=TorrentCapabilities(**(live["capabilities"] or {})),
        blocked=live["blocked"],
        peers=int(live["peers"]),
        clients=[
            TorrentOffender(
                address=str(item.get("address", "")),
                name=getattr(names.get(str(item.get("address", ""))), "name", None),
                client_id=getattr(names.get(str(item.get("address", ""))), "id", None),
                packets=int(item.get("packets") or 0),
                expires_in=int(item.get("expires_in") or 0),
            )
            for item in offenders
            if item.get("address")
        ],
        live=bool(live["live"]),
        editable=settings.node_provision_enabled,
        config_error=torrent_registry.config_error(live),
    )


def _require_editable() -> None:
    if not settings.node_provision_enabled:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="NODE_PROVISION_ENABLED=false, so this panel does not change node settings",
        )
    error = torrent_registry.config_error()
    if error and "TORRENT_BLOCK" in error:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=error)


@router.get("", response_model=TorrentStatus)
async def get_torrents(session: SessionDep, _: AdminDep) -> TorrentStatus:
    """Whether BitTorrent is being blocked, how, and what has been caught."""
    return await _snapshot(session)


@router.put("", response_model=TorrentStatus)
async def update_torrents(
    payload: TorrentUpdate, session: SessionDep, admin: SudoAdminDep
) -> TorrentStatus:
    """Turns the guard on or off, or moves it between modes.

    Both fields are optional and independent, so the mode can be chosen while the
    guard is off and survives being switched off and on again — the switch and the
    dial are different controls.
    """
    _require_editable()
    try:
        current = torrent_registry.load_settings()
        enabled = current["enabled"] if payload.enabled is None else payload.enabled
        mode = current["mode"] if payload.mode is None else payload.mode
        torrent_registry.save_settings(enabled, mode)
    except torrent_registry.TorrentError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

    # A change that cannot be signalled is still saved: the container reads the
    # file on startup, so it takes effect when it comes back.
    try:
        registry.request_reload()
    except registry.RegistryError as exc:
        logger.warning("could not signal the node container: %s", exc)

    logger.info(
        "admin %s set torrent blocking to %s",
        admin.username,
        f"{mode}" if enabled else "off",
    )
    return await _snapshot(session)
