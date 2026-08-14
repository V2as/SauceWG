from __future__ import annotations

from datetime import datetime, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy import select

from ..deps import AdminDep, SessionDep
from ..models import Admin
from ..schemas import AdminOut, Token
from ..security import create_access_token, verify_password

router = APIRouter(tags=["auth"])


@router.post("/admin/token", response_model=Token)
async def login(
    session: SessionDep,
    form: Annotated[OAuth2PasswordRequestForm, Depends()],
) -> Token:
    admin = (
        await session.execute(select(Admin).where(Admin.username == form.username))
    ).scalar_one_or_none()

    if admin is None or not verify_password(form.password, admin.hashed_password):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Incorrect username or password")
    if not admin.is_active:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "This account is disabled")

    admin.last_login_at = datetime.now(timezone.utc)
    await session.commit()

    token, expires_in = create_access_token(admin.username, admin.token_epoch)
    return Token(access_token=token, expires_in=expires_in)


@router.get("/admin", response_model=AdminOut)
async def current_admin(admin: AdminDep) -> Admin:
    return admin
