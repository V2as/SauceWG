"""Destinations the entry node reopens for itself.

Not the same thing as a direct route. A direct route decides *which way out* a
destination takes; this is for destinations where no way out works, because what is
blocked is the TCP handshake to their IPv4 rather than the route to it. The entry
node opens the outbound half itself — over the destination's IPv6 where the same
server answers there, or by dialling its IPv4 until one handshake gets through.

The panel edits ``config/bypass.json``; the node container watches it and applies the
difference within a second. Whether the redirect is installed at all is the node's
own decision, from ``BYPASS_MODE``: in the default ``auto`` it engages only while
client traffic is leaving through the entry node, since a flow already going out
through an exit node is not meeting this filter. That is why an entry can be listed,
correct and still inactive.

Nothing here talks to the network — the same file exchange the exit node list uses.
"""

from __future__ import annotations

import logging
from typing import Any

from fastapi import APIRouter, HTTPException, status

from ..awg import bypass as bypass_registry
from ..awg import registry
from ..config import settings
from ..deps import AdminDep, SudoAdminDep
from ..schemas import (
    BypassEntry,
    BypassEntryCreate,
    BypassEntryUpdate,
    BypassList,
    BypassRelay,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/bypass", tags=["bypass"])


def _relay(raw: dict[str, Any] | None) -> BypassRelay | None:
    if not raw:
        return None
    # Built field by field rather than splatted: the relay is a separate program and
    # a counter it gains should not turn a status page into a 500.
    return BypassRelay(
        listen=raw.get("listen"),
        prefixes=int(raw.get("prefixes") or 0),
        open=int(raw.get("open") or 0),
        accepted=int(raw.get("accepted") or 0),
        via_v6=int(raw.get("via_v6") or 0),
        via_retry=int(raw.get("via_retry") or 0),
        failed=int(raw.get("failed") or 0),
        attempts=int(raw.get("attempts") or 0),
        cooled=int(raw.get("cooled") or 0),
        rx_bytes=int(raw.get("rx_bytes") or 0),
        tx_bytes=int(raw.get("tx_bytes") or 0),
        last_error=raw.get("last_error"),
    )


def _snapshot() -> BypassList:
    """The file and the running state, merged into one answer.

    The built-in groups are listed alongside the operator's own entries because from
    an operator's point of view they are the same list: what is being reopened right
    now. Which of the two an entry came from is reported rather than hidden, since
    only one of them can be edited here.
    """
    state = bypass_registry.state()
    try:
        entries = bypass_registry.load_entries()
    except bypass_registry.BypassError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc

    applied = {item["cidr"]: item for item in state["applied"]}
    listed = {entry["cidr"] for entry in entries}

    out = [
        BypassEntry(
            cidr=entry["cidr"],
            # What the container resolved wins over what the file says: a group can
            # supply a counterpart for a prefix listed here without one.
            v6=(applied.get(entry["cidr"]) or {}).get("v6") or entry.get("v6"),
            note=entry.get("note"),
            enabled=bool(entry.get("enabled", True)),
            active=entry["cidr"] in applied,
        )
        for entry in entries
    ]
    out.extend(
        BypassEntry(
            cidr=item["cidr"],
            v6=item.get("v6"),
            note=item.get("note"),
            enabled=True,
            active=True,
            built_in=True,
        )
        for cidr, item in applied.items()
        if cidr not in listed
    )

    return BypassList(
        mode=state["mode"] or "auto",
        groups=state["groups"],
        entries=out,
        active=bool(state["active"]),
        relay=_relay(state["relay"]),
        live=bool(state["live"]),
        editable=settings.node_provision_enabled,
        config_error=bypass_registry.config_error(state),
    )


def _require_editable() -> None:
    if not settings.node_provision_enabled:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="NODE_PROVISION_ENABLED=false, so this panel does not edit routing",
        )
    error = bypass_registry.config_error()
    if error and "BYPASS_ROUTES" in error:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=error)


def _save(entries: list[dict[str, Any]]) -> None:
    """Writes the list and asks the node container to apply it.

    An entry that cannot be signalled is still saved: the container reads the file on
    startup, so a change made while it is down takes effect when it comes back.
    """
    try:
        bypass_registry.save_entries(entries)
    except bypass_registry.BypassError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc
    try:
        registry.request_reload()
    except registry.RegistryError as exc:
        logger.warning("could not signal the node container: %s", exc)


@router.get("", response_model=BypassList)
async def list_bypass(_: AdminDep) -> BypassList:
    """Everything being reopened, and whether the node is reopening it right now."""
    return _snapshot()


@router.post("", response_model=BypassList, status_code=status.HTTP_201_CREATED)
async def add_bypass(payload: BypassEntryCreate, admin: SudoAdminDep) -> BypassList:
    """Reopens one or more destinations through this entry node.

    A prefix already on the list is replaced rather than skipped: unlike a direct
    route, an entry carries *how* to reach the destination, and correcting that is the
    main reason to add one twice.
    """
    _require_editable()
    try:
        entries = bypass_registry.load_entries()
        target = bypass_registry.normalize_target(payload.v6 or "")
    except bypass_registry.BypassError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

    if target and len(payload.cidr) > 1:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=(
                "an IPv6 counterpart is one server, so it applies to one destination. "
                "Add the rest without it and they will be reached by retrying their own "
                "IPv4"
            ),
        )

    for raw in payload.cidr:
        try:
            cidr = bypass_registry.normalize_entry(raw)
        except bypass_registry.BypassError as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
        entry: dict[str, Any] = {"cidr": cidr, "enabled": payload.enabled}
        if target:
            entry["v6"] = target
        if payload.note:
            entry["note"] = payload.note
        entries = [existing for existing in entries if existing.get("cidr") != cidr]
        entries.append(entry)

    _save(entries)
    logger.info(
        "admin %s reopened %d destination(s)%s",
        admin.username,
        len(payload.cidr),
        f" ({payload.note})" if payload.note else "",
    )
    return _snapshot()


@router.put("/{cidr:path}", response_model=BypassList)
async def update_bypass(cidr: str, payload: BypassEntryUpdate, admin: SudoAdminDep) -> BypassList:
    """Corrects an entry's counterpart or label, or turns it off without losing it."""
    _require_editable()
    try:
        target = bypass_registry.normalize_entry(cidr)
        entries = bypass_registry.load_entries()
        counterpart = bypass_registry.normalize_target(payload.v6 or "")
    except bypass_registry.BypassError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

    entry = bypass_registry.find(entries, target)
    if entry is None:
        # A built-in group's entry is not in this file, and switching one off is
        # exactly what an operator needs when a group has outlived a destination —
        # so it is recorded here instead of being refused.
        if target not in {item["cidr"] for item in bypass_registry.state()["applied"]}:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail=f"{target} is not being reopened"
            )
        entry = {"cidr": target, "enabled": True, "v6": None, "note": None}
        entries.append(entry)

    changes = payload.model_dump(exclude_none=True)
    if counterpart:
        changes["v6"] = counterpart
    if changes:
        entry.update(changes)
        _save(entries)
        logger.info("admin %s updated bypass entry %s: %s", admin.username, target, sorted(changes))
    return _snapshot()


@router.delete("/{cidr:path}", response_model=BypassList)
async def delete_bypass(cidr: str, admin: SudoAdminDep) -> BypassList:
    """Stops reopening a destination.

    Only an entry in the file can be deleted. A built-in group's destination is
    switched off with ``PUT .../{cidr}`` and ``enabled: false``, which is what leaves
    a record of the decision for the next release of the group.
    """
    _require_editable()
    try:
        target = bypass_registry.normalize_entry(cidr)
        entries = bypass_registry.load_entries()
    except bypass_registry.BypassError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

    remaining = [entry for entry in entries if entry.get("cidr") != target]
    if len(remaining) == len(entries):
        if target in {item["cidr"] for item in bypass_registry.state()["applied"]}:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=(
                    f"{target} comes from a built-in group, so there is nothing here to "
                    f"delete. Turn it off instead and the choice survives an update"
                ),
            )
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"{target} is not being reopened")

    _save(remaining)
    logger.info("admin %s stopped reopening %s", admin.username, target)
    return _snapshot()
