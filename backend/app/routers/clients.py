from __future__ import annotations

import io
from datetime import datetime, timedelta, timezone
from typing import Annotated, Literal

import segno
from fastapi import APIRouter, HTTPException, Query, Request, Response, status
from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..awg.node import load_server_params
from ..config import settings
from ..deps import AdminDep, SessionDep
from ..models import Client, ClientStatus, ClientUsage
from ..schemas import (
    ClientCreate,
    ClientList,
    ClientOut,
    ClientUpdate,
    UsagePoint,
    UsageSeries,
)
from ..security import generate_token
from ..services import clients as client_service
from ..services.sync import sync_peers

router = APIRouter(prefix="/clients", tags=["clients"])

SORTABLE = {
    "name": Client.name,
    "created_at": Client.created_at,
    "used_total": Client.used_up + Client.used_down,
    "expire_at": Client.expire_at,
    "last_handshake_at": Client.last_handshake_at,
    "status": Client.status,
}


def subscription_url(request: Request, client: Client) -> str:
    base = settings.subscription_url_prefix.rstrip("/")
    if not base:
        base = str(request.base_url).rstrip("/")
    return f"{base}/sub/{client.sub_token}"


def serialize(request: Request, client: Client) -> ClientOut:
    payload = ClientOut.model_validate(client)
    payload.subscription_url = subscription_url(request, client)
    return payload


async def get_client_or_404(session: AsyncSession, name: str) -> Client:
    client = (
        await session.execute(select(Client).where(Client.name == name))
    ).scalar_one_or_none()
    if client is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Client not found")
    return client


@router.get("", response_model=ClientList)
async def list_clients(
    request: Request,
    session: SessionDep,
    _: AdminDep,
    search: str | None = None,
    status_filter: ClientStatus | None = Query(default=None, alias="status"),
    online: bool | None = None,
    offset: int = Query(default=0, ge=0),
    limit: int = Query(default=50, ge=1, le=500),
    sort: str = "created_at",
    order: Literal["asc", "desc"] = "desc",
) -> ClientList:
    query = select(Client)
    count_query = select(func.count()).select_from(Client)

    conditions = []
    if search:
        pattern = f"%{search.lower()}%"
        conditions.append(
            or_(
                func.lower(Client.name).like(pattern),
                func.lower(func.coalesce(Client.note, "")).like(pattern),
                Client.address.like(f"%{search}%"),
            )
        )
    if status_filter:
        conditions.append(Client.status == status_filter)
    if online is not None:
        conditions.append(
            Client.online_at.isnot(None) if online else Client.online_at.is_(None)
        )
    for condition in conditions:
        query = query.where(condition)
        count_query = count_query.where(condition)

    column = SORTABLE.get(sort, Client.created_at)
    query = query.order_by(column.desc() if order == "desc" else column.asc())

    total = (await session.execute(count_query)).scalar_one()
    rows = (await session.execute(query.offset(offset).limit(limit))).scalars().all()
    return ClientList(total=total, items=[serialize(request, row) for row in rows])


@router.post("", response_model=ClientOut, status_code=status.HTTP_201_CREATED)
async def create_client(
    request: Request, payload: ClientCreate, session: SessionDep, admin: AdminDep
) -> ClientOut:
    server = load_server_params()
    subnet = server.subnet or settings.awg_subnet
    client = await client_service.create_client(session, payload, admin.id, subnet)
    await sync_peers(session)
    return serialize(request, client)


@router.get("/{name}", response_model=ClientOut)
async def get_client(request: Request, name: str, session: SessionDep, _: AdminDep) -> ClientOut:
    return serialize(request, await get_client_or_404(session, name))


@router.put("/{name}", response_model=ClientOut)
async def update_client(
    request: Request, name: str, payload: ClientUpdate, session: SessionDep, _: AdminDep
) -> ClientOut:
    client = await get_client_or_404(session, name)
    client = await client_service.update_client(session, client, payload)
    await sync_peers(session)
    return serialize(request, client)


@router.delete("/{name}", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def delete_client(name: str, session: SessionDep, _: AdminDep):
    client = await get_client_or_404(session, name)
    await session.delete(client)
    await session.commit()
    await sync_peers(session)


@router.post("/{name}/enable", response_model=ClientOut)
async def enable_client(
    request: Request, name: str, session: SessionDep, _: AdminDep
) -> ClientOut:
    client = await get_client_or_404(session, name)
    client = await client_service.update_client(session, client, ClientUpdate(enabled=True))
    await sync_peers(session)
    return serialize(request, client)


@router.post("/{name}/disable", response_model=ClientOut)
async def disable_client(
    request: Request, name: str, session: SessionDep, _: AdminDep
) -> ClientOut:
    client = await get_client_or_404(session, name)
    client = await client_service.update_client(session, client, ClientUpdate(enabled=False))
    await sync_peers(session)
    return serialize(request, client)


@router.post("/{name}/reset", response_model=ClientOut)
async def reset_client_traffic(
    request: Request, name: str, session: SessionDep, _: AdminDep
) -> ClientOut:
    client = await get_client_or_404(session, name)
    client = await client_service.reset_traffic(session, client)
    await sync_peers(session)
    return serialize(request, client)


@router.post("/{name}/revoke-subscription", response_model=ClientOut)
async def revoke_subscription(
    request: Request, name: str, session: SessionDep, _: AdminDep
) -> ClientOut:
    client = await get_client_or_404(session, name)
    client.sub_token = generate_token()
    await session.commit()
    await session.refresh(client)
    return serialize(request, client)


@router.get("/{name}/config", response_class=Response)
async def client_config(name: str, session: SessionDep, _: AdminDep) -> Response:
    client = await get_client_or_404(session, name)
    config = client_service.build_config(client, load_server_params())
    return Response(
        content=config,
        media_type="text/plain; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{client.name}.conf"'},
    )


@router.get("/{name}/qr", response_class=Response)
async def client_qr(name: str, session: SessionDep, _: AdminDep) -> Response:
    client = await get_client_or_404(session, name)
    config = client_service.build_config(client, load_server_params())
    buffer = io.BytesIO()
    segno.make(config, error="m").save(buffer, kind="png", scale=6, border=2, dark="#0b0f14")
    return Response(content=buffer.getvalue(), media_type="image/png")


@router.get("/{name}/usage", response_model=UsageSeries)
async def client_usage(
    name: str,
    session: SessionDep,
    _: AdminDep,
    hours: Annotated[int, Query(ge=1, le=24 * 90)] = 24,
) -> UsageSeries:
    client = await get_client_or_404(session, name)
    since = datetime.now(timezone.utc) - timedelta(hours=hours)
    rows = (
        (
            await session.execute(
                select(ClientUsage)
                .where(ClientUsage.client_id == client.id, ClientUsage.bucket >= since)
                .order_by(ClientUsage.bucket)
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
