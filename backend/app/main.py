from __future__ import annotations

import asyncio
import contextlib
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import select

from . import __version__
from .config import settings
from .db import SessionLocal, init_db
from .models import Admin
from .routers import (
    admins,
    auth,
    bypass,
    clients,
    nodes,
    routes,
    subscription,
    system,
    torrents,
)
from .security import hash_password
from .services.collector import collect, purge_old_usage
from .services.recovery import loop as recovery_loop
from .services.sync import sync_peers
from .services.tasks import tasks

logging.basicConfig(
    level=settings.log_level.upper(),
    format="%(asctime)s  %(levelname)-7s  %(name)s  %(message)s",
)
logger = logging.getLogger("saucewg")


async def seed_admin() -> None:
    async with SessionLocal() as session:
        existing = (await session.execute(select(Admin).limit(1))).scalar_one_or_none()
        if existing is not None:
            return
        session.add(
            Admin(
                username=settings.admin_username,
                hashed_password=hash_password(settings.admin_password),
                is_sudo=True,
            )
        )
        await session.commit()
        logger.info("created the initial admin account %r", settings.admin_username)


async def collector_loop() -> None:
    while True:
        try:
            async with SessionLocal() as session:
                if await collect(session):
                    await sync_peers(session)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 - a worker must never die on a transient error
            logger.exception("collector iteration failed")
        await asyncio.sleep(settings.collector_interval_seconds)


async def sync_loop() -> None:
    while True:
        try:
            async with SessionLocal() as session:
                await sync_peers(session)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001
            logger.exception("peer sync iteration failed")
        await asyncio.sleep(settings.sync_interval_seconds)


async def housekeeping_loop() -> None:
    while True:
        await asyncio.sleep(3600)
        try:
            async with SessionLocal() as session:
                await purge_old_usage(session)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001
            logger.exception("housekeeping iteration failed")


@asynccontextmanager
async def lifespan(app: FastAPI):
    for attempt in range(30):
        try:
            await init_db()
            break
        except Exception as exc:  # noqa: BLE001 - postgres may still be booting
            logger.warning("waiting for the database (%s/30): %s", attempt + 1, exc)
            await asyncio.sleep(2)
    else:
        raise RuntimeError("could not reach the database")

    await seed_admin()

    workers = [
        asyncio.create_task(collector_loop()),
        asyncio.create_task(sync_loop()),
        asyncio.create_task(housekeeping_loop()),
        # The cascade routes around a failed exit node by itself; nothing but the
        # panel can put the server back, because nothing else can reach it.
        asyncio.create_task(recovery_loop()),
    ]
    logger.info("%s %s is ready", settings.panel_title, __version__)
    try:
        yield
    finally:
        await tasks.shutdown()
        for task in workers:
            task.cancel()
        for task in workers:
            with contextlib.suppress(asyncio.CancelledError):
                await task


app = FastAPI(
    title=settings.panel_title,
    version=__version__,
    lifespan=lifespan,
    docs_url="/api/docs" if settings.docs_enabled else None,
    redoc_url="/api/redoc" if settings.docs_enabled else None,
    openapi_url="/api/openapi.json" if settings.docs_enabled else None,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origin_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router, prefix="/api")
app.include_router(admins.router, prefix="/api")
app.include_router(clients.router, prefix="/api")
app.include_router(nodes.router, prefix="/api")
app.include_router(routes.router, prefix="/api")
app.include_router(bypass.router, prefix="/api")
app.include_router(torrents.router, prefix="/api")
app.include_router(system.router, prefix="/api")
app.include_router(subscription.router)


@app.get("/api/health", include_in_schema=False)
async def health() -> dict[str, str]:
    return {"status": "ok", "version": __version__}
