from __future__ import annotations

import io

import segno
from fastapi import APIRouter, HTTPException, Response, status
from sqlalchemy import select

from ..awg.node import load_server_params
from ..deps import SessionDep
from ..models import Client, ClientStatus
from ..services import clients as client_service

router = APIRouter(prefix="/sub", tags=["subscription"], include_in_schema=False)


async def _resolve(session, token: str) -> Client:
    client = (
        await session.execute(select(Client).where(Client.sub_token == token))
    ).scalar_one_or_none()
    if client is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Subscription not found")
    if client.status in (ClientStatus.disabled,):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "This subscription is disabled")
    return client


@router.get("/{token}")
async def subscription(token: str, session: SessionDep) -> Response:
    client = await _resolve(session, token)
    config = client_service.build_config(client, load_server_params())
    return Response(
        content=config,
        media_type="text/plain; charset=utf-8",
        headers={
            "Content-Disposition": f'attachment; filename="{client.name}.conf"',
            "Profile-Title": client.name,
        },
    )


@router.get("/{token}/qr")
async def subscription_qr(token: str, session: SessionDep) -> Response:
    client = await _resolve(session, token)
    config = client_service.build_config(client, load_server_params())
    buffer = io.BytesIO()
    segno.make(config, error="m").save(buffer, kind="png", scale=6, border=2, dark="#0b0f14")
    return Response(content=buffer.getvalue(), media_type="image/png")
