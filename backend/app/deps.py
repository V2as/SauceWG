from __future__ import annotations

from typing import Annotated

from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .db import get_session
from .models import Admin
from .security import decode_access_token

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="api/admin/token", auto_error=False)

SessionDep = Annotated[AsyncSession, Depends(get_session)]


async def get_current_admin(
    session: SessionDep,
    token: Annotated[str | None, Depends(oauth2_scheme)],
) -> Admin:
    credentials_error = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Not authenticated",
        headers={"WWW-Authenticate": "Bearer"},
    )
    if not token:
        raise credentials_error

    payload = decode_access_token(token)
    if not payload:
        raise credentials_error

    admin = (
        await session.execute(select(Admin).where(Admin.username == payload.get("sub")))
    ).scalar_one_or_none()
    if admin is None or not admin.is_active or admin.token_epoch != payload.get("epoch", 0):
        raise credentials_error
    return admin


AdminDep = Annotated[Admin, Depends(get_current_admin)]


async def get_sudo_admin(admin: AdminDep) -> Admin:
    if not admin.is_sudo:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Sudo access required")
    return admin


SudoAdminDep = Annotated[Admin, Depends(get_sudo_admin)]
