from __future__ import annotations

from fastapi import APIRouter, HTTPException, Response, status
from sqlalchemy import select

from ..deps import SessionDep, SudoAdminDep
from ..models import Admin
from ..schemas import AdminCreate, AdminOut, AdminUpdate
from ..security import hash_password

router = APIRouter(prefix="/admins", tags=["admins"])


@router.get("", response_model=list[AdminOut])
async def list_admins(session: SessionDep, _: SudoAdminDep) -> list[Admin]:
    result = await session.execute(select(Admin).order_by(Admin.id))
    return list(result.scalars())


@router.post("", response_model=AdminOut, status_code=status.HTTP_201_CREATED)
async def create_admin(payload: AdminCreate, session: SessionDep, _: SudoAdminDep) -> Admin:
    exists = (
        await session.execute(select(Admin).where(Admin.username == payload.username))
    ).scalar_one_or_none()
    if exists:
        raise HTTPException(status.HTTP_409_CONFLICT, "This username is already taken")

    admin = Admin(
        username=payload.username,
        hashed_password=hash_password(payload.password),
        is_sudo=payload.is_sudo,
        is_active=payload.is_active,
    )
    session.add(admin)
    await session.commit()
    await session.refresh(admin)
    return admin


@router.put("/{username}", response_model=AdminOut)
async def update_admin(
    username: str, payload: AdminUpdate, session: SessionDep, actor: SudoAdminDep
) -> Admin:
    admin = (
        await session.execute(select(Admin).where(Admin.username == username))
    ).scalar_one_or_none()
    if admin is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Admin not found")

    data = payload.model_dump(exclude_unset=True)
    if password := data.pop("password", None):
        admin.hashed_password = hash_password(password)
        admin.token_epoch += 1
    if admin.id == actor.id and data.get("is_active") is False:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "You cannot disable your own account")
    for key, value in data.items():
        setattr(admin, key, value)

    await session.commit()
    await session.refresh(admin)
    return admin


@router.delete("/{username}", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def delete_admin(username: str, session: SessionDep, actor: SudoAdminDep):
    admin = (
        await session.execute(select(Admin).where(Admin.username == username))
    ).scalar_one_or_none()
    if admin is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Admin not found")
    if admin.id == actor.id:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "You cannot delete your own account")

    await session.delete(admin)
    await session.commit()
