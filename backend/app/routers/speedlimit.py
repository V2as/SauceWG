"""The speed limit: one rate every client is held to, and whether it holds.

Set 50 and every client can download at up to 50 Mbit/s and upload at up to 50
Mbit/s, each on its own — the limit is per client and per direction, not a total
shared between them.

The panel writes ``config/speed-limit.json``; the node container watches it and
applies the difference within a second, without touching a tunnel. Nothing here
talks to the network — the same file exchange the exit node list uses.

What the container does with it is documented where it is implemented, in
``docker/awg/speedlimit.sh``. The short version is one hashlimit rule each way on
the client interface, keeping a token bucket per client address, so a client
created a second ago is limited from its first packet and nothing has to be kept in
step with the client list.
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException, status

from ..awg import registry
from ..awg import speedlimit as speed_registry
from ..config import settings
from ..deps import AdminDep, SudoAdminDep
from ..schemas import SpeedLimitCapabilities, SpeedLimitDrops, SpeedLimitStatus, SpeedLimitUpdate

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/speed-limit", tags=["speed-limit"])


def _snapshot() -> SpeedLimitStatus:
    """The setting on file, and what the container reports doing about it."""
    live = speed_registry.state()
    try:
        configured = speed_registry.load_settings()
    except speed_registry.SpeedLimitError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc

    return SpeedLimitStatus(
        enabled=bool(configured["enabled"]),
        rate_mbit=configured["rate_mbit"],
        active=bool(live["active"]),
        active_rate_mbit=live["rate_mbit"] if live["active"] else None,
        rules=int(live["rules"]),
        capabilities=(
            SpeedLimitCapabilities(**live["capabilities"]) if live["capabilities"] is not None else None
        ),
        dropped=SpeedLimitDrops(**live["dropped"]),
        live=bool(live["live"]),
        editable=settings.node_provision_enabled and live["source"] != "env",
        config_error=speed_registry.config_error(live),
    )


def _require_editable() -> None:
    if not settings.node_provision_enabled:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="NODE_PROVISION_ENABLED=false, so this panel does not change node settings",
        )
    error = speed_registry.config_error()
    if error and "SPEED_LIMIT" in error:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=error)


@router.get("", response_model=SpeedLimitStatus)
async def get_speed_limit(_: AdminDep) -> SpeedLimitStatus:
    """The rate every client is held to, and whether the node is enforcing it."""
    return _snapshot()


@router.put("", response_model=SpeedLimitStatus)
async def update_speed_limit(payload: SpeedLimitUpdate, admin: SudoAdminDep) -> SpeedLimitStatus:
    """Sets the rate, turns the limit on or off, or both at once.

    Both fields are optional and independent, so the rate can be chosen while the
    limit is off and survives it being switched off and on again — the switch and
    the dial are different controls. Turning it on needs a rate, either in this
    request or already on file.
    """
    _require_editable()
    try:
        current = speed_registry.load_settings()
    except speed_registry.SpeedLimitError as exc:
        # A file that cannot be read can still be replaced outright, which is the
        # one way to fix it from here.
        if payload.enabled is None or payload.rate_mbit is None:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"{exc}. Send both enabled and rate_mbit to replace it.",
            ) from exc
        current = {"enabled": False, "rate_mbit": None}

    enabled = current["enabled"] if payload.enabled is None else payload.enabled
    rate = current["rate_mbit"] if payload.rate_mbit is None else payload.rate_mbit
    if enabled and rate is None:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="There is no rate to hold clients to yet: send rate_mbit along with enabled",
        )
    try:
        speed_registry.save_settings(enabled, rate)
    except speed_registry.SpeedLimitError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

    # A change that cannot be signalled is still saved: the container reads the
    # file on startup, so it takes effect when it comes back.
    try:
        registry.request_reload()
    except registry.RegistryError as exc:
        logger.warning("could not signal the node container: %s", exc)

    logger.info(
        "admin %s set the speed limit to %s",
        admin.username,
        f"{speed_registry.normalize_rate(rate)} Mbit/s per client" if enabled else "off",
    )
    return _snapshot()
