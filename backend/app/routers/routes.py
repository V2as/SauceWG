"""Destinations that bypass the cascade and leave through the entry node.

The panel edits ``config/direct-routes.json``; the node container watches it and
applies the difference within a second, without touching the tunnels. Nothing here
talks to the network — the same file exchange the exit node list uses.
"""

from __future__ import annotations

import logging
from typing import Any

from fastapi import APIRouter, HTTPException, status

from ..awg import registry
from ..awg import routes as route_registry
from ..config import settings
from ..deps import AdminDep, SudoAdminDep
from ..schemas import DirectRoute, DirectRouteCreate, DirectRouteList, DirectRouteUpdate

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/routes", tags=["routes"])


def _snapshot() -> DirectRouteList:
    state = route_registry.state()
    applied = set(state["applied"])
    try:
        entries = route_registry.load_routes()
    except route_registry.RouteError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc

    return DirectRouteList(
        routes=[
            DirectRoute(
                cidr=entry["cidr"],
                note=entry.get("note"),
                enabled=bool(entry.get("enabled", True)),
                active=entry["cidr"] in applied,
            )
            for entry in entries
        ],
        via=state["via"],
        live=bool(state["live"]),
        editable=settings.node_provision_enabled,
        config_error=route_registry.config_error(state),
    )


def _require_editable() -> None:
    if not settings.node_provision_enabled:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="NODE_PROVISION_ENABLED=false, so this panel does not edit routing",
        )
    error = route_registry.config_error()
    if error and "CASCADE_DIRECT_ROUTES" in error:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=error)


def _save(entries: list[dict[str, Any]]) -> None:
    """Writes the list and asks the node container to apply it.

    A route that cannot be signalled is still saved: the container reads the file on
    startup, so a change made while it is down takes effect when it comes back.
    """
    try:
        route_registry.save_routes(entries)
    except route_registry.RouteError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc
    try:
        registry.request_reload()
    except registry.RegistryError as exc:
        logger.warning("could not signal the node container: %s", exc)


@router.get("", response_model=DirectRouteList)
async def list_routes(_: AdminDep) -> DirectRouteList:
    """The bypass list, with whether each entry is actually in the routing table."""
    return _snapshot()


@router.post("", response_model=DirectRouteList, status_code=status.HTTP_201_CREATED)
async def add_routes(payload: DirectRouteCreate, admin: SudoAdminDep) -> DirectRouteList:
    """Sends one or more destinations through the entry node.

    Prefixes already on the list are left alone rather than rejected, so re-importing
    a group after it has grown adds only what is new.
    """
    _require_editable()
    try:
        entries = route_registry.load_routes()
    except route_registry.RouteError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc

    added = 0
    for raw in payload.cidr:
        try:
            cidr = route_registry.normalize_prefix(raw)
        except route_registry.RouteError as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
        if route_registry.find(entries, cidr) is not None:
            continue
        entry: dict[str, Any] = {"cidr": cidr, "enabled": payload.enabled}
        if payload.note:
            entry["note"] = payload.note
        entries.append(entry)
        added += 1

    if added:
        _save(entries)
        logger.info(
            "admin %s added %d direct route(s)%s",
            admin.username,
            added,
            f" ({payload.note})" if payload.note else "",
        )
    return _snapshot()


@router.put("/{cidr:path}", response_model=DirectRouteList)
async def update_route(cidr: str, payload: DirectRouteUpdate, admin: SudoAdminDep) -> DirectRouteList:
    """Renames a route or turns it off without losing it."""
    _require_editable()
    try:
        target = route_registry.normalize_prefix(cidr)
        entries = route_registry.load_routes()
    except route_registry.RouteError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

    entry = route_registry.find(entries, target)
    if entry is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"{target} is not routed directly")

    changes = payload.model_dump(exclude_none=True)
    if changes:
        entry.update(changes)
        _save(entries)
        logger.info("admin %s updated direct route %s: %s", admin.username, target, sorted(changes))
    return _snapshot()


@router.delete("/{cidr:path}", response_model=DirectRouteList)
async def delete_route(cidr: str, admin: SudoAdminDep) -> DirectRouteList:
    """Puts a destination back on the cascade."""
    _require_editable()
    try:
        target = route_registry.normalize_prefix(cidr)
        entries = route_registry.load_routes()
    except route_registry.RouteError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

    remaining = [entry for entry in entries if entry.get("cidr") != target]
    if len(remaining) == len(entries):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"{target} is not routed directly")

    _save(remaining)
    logger.info("admin %s removed direct route %s", admin.username, target)
    return _snapshot()
