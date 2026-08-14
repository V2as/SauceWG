from __future__ import annotations

from datetime import datetime, timedelta, timezone

from fastapi import HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..awg import keys as awg_keys
from ..awg.node import ServerParams, render_client_config
from ..config import settings
from ..models import Client, ClientStatus, ResetStrategy
from ..schemas import ClientCreate, ClientUpdate
from ..security import generate_token
from .addresses import allocate_address, normalize_address


def compute_status(client: Client, now: datetime | None = None) -> ClientStatus:
    now = now or datetime.now(timezone.utc)
    if not client.enabled:
        return ClientStatus.disabled
    if client.expire_at and client.expire_at <= now:
        return ClientStatus.expired
    if client.data_limit and client.used_total >= client.data_limit:
        return ClientStatus.limited
    return ClientStatus.active


def refresh_status(client: Client) -> ClientStatus:
    client.status = compute_status(client)
    return client.status


async def create_client(
    session: AsyncSession, payload: ClientCreate, admin_id: int | None, subnet: str
) -> Client:
    existing = (
        await session.execute(select(Client).where(Client.name == payload.name))
    ).scalar_one_or_none()
    if existing:
        raise HTTPException(status.HTTP_409_CONFLICT, "A client with this name already exists")

    if payload.public_key:
        if not awg_keys.is_valid_key(payload.public_key):
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Invalid public key")
        private_key = payload.private_key
        public_key = payload.public_key
    else:
        private_key = payload.private_key or awg_keys.generate_private_key()
        if not awg_keys.is_valid_key(private_key):
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Invalid private key")
        public_key = awg_keys.public_from_private(private_key)

    duplicate = (
        await session.execute(select(Client).where(Client.public_key == public_key))
    ).scalar_one_or_none()
    if duplicate:
        raise HTTPException(status.HTTP_409_CONFLICT, "This public key is already in use")

    address = normalize_address(payload.address) if payload.address else await allocate_address(
        session, subnet
    )

    expire_at = payload.expire_at
    if expire_at is None and payload.expire_in_days:
        expire_at = datetime.now(timezone.utc) + timedelta(days=payload.expire_in_days)

    client = Client(
        name=payload.name,
        admin_id=admin_id,
        private_key=private_key,
        public_key=public_key,
        preshared_key=awg_keys.generate_preshared_key() if payload.use_preshared_key else None,
        address=address,
        enabled=payload.enabled,
        data_limit=payload.data_limit,
        reset_strategy=payload.reset_strategy,
        expire_at=expire_at,
        note=payload.note,
        sub_token=generate_token(),
        used_up=0,
        used_down=0,
        lifetime_up=0,
        lifetime_down=0,
        counter_rx=0,
        counter_tx=0,
    )
    refresh_status(client)
    session.add(client)
    await session.commit()
    await session.refresh(client)
    return client


async def update_client(session: AsyncSession, client: Client, payload: ClientUpdate) -> Client:
    data = payload.model_dump(exclude_unset=True)

    if "name" in data and data["name"] != client.name:
        clash = (
            await session.execute(select(Client).where(Client.name == data["name"]))
        ).scalar_one_or_none()
        if clash:
            raise HTTPException(status.HTTP_409_CONFLICT, "A client with this name already exists")

    for key, value in data.items():
        setattr(client, key, value)

    refresh_status(client)
    await session.commit()
    await session.refresh(client)
    return client


async def reset_traffic(session: AsyncSession, client: Client) -> Client:
    client.used_up = 0
    client.used_down = 0
    client.traffic_reset_at = datetime.now(timezone.utc)
    refresh_status(client)
    await session.commit()
    await session.refresh(client)
    return client


def next_reset_due(client: Client, now: datetime) -> bool:
    if client.reset_strategy == ResetStrategy.no_reset:
        return False
    anchor = client.traffic_reset_at or client.created_at
    if anchor.tzinfo is None:
        anchor = anchor.replace(tzinfo=timezone.utc)
    spans = {
        ResetStrategy.day: timedelta(days=1),
        ResetStrategy.week: timedelta(weeks=1),
        ResetStrategy.month: timedelta(days=30),
    }
    return now - anchor >= spans[client.reset_strategy]


def build_config(client: Client, server: ServerParams) -> str:
    if not client.private_key:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            "This client was created with an externally generated key, so the panel cannot "
            "produce a full config",
        )
    if not server.ready:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "The AmneziaWG node is not ready")

    return render_client_config(
        private_key=client.private_key,
        address=f"{client.address}/32",
        preshared_key=client.preshared_key,
        server=server,
        endpoint_host=settings.awg_endpoint_host,
        endpoint_port=settings.awg_endpoint_port or server.port,
    )
