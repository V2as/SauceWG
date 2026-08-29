"""Administrative commands that run inside the panel container.

This is what ``saucewg admin-password`` drives, and the escape hatch for a bot that
has to bootstrap credentials before it can call the API:

    printf '%s' 's3cret' | docker compose exec -T panel \\
        python -m app.cli set-password --username admin --password-stdin --sudo
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys

from sqlalchemy import select

from .awg.uplinks import load_uplink_state
from .db import SessionLocal, init_db
from .models import Admin
from .security import hash_password
from .services import recovery


async def _set_password(username: str, password: str, sudo: bool) -> dict[str, object]:
    await init_db()
    async with SessionLocal() as session:
        admin = (
            await session.execute(select(Admin).where(Admin.username == username))
        ).scalar_one_or_none()

        if admin is None:
            admin = Admin(username=username, hashed_password=hash_password(password), is_sudo=sudo)
            session.add(admin)
            created = True
        else:
            admin.hashed_password = hash_password(password)
            admin.is_active = True
            if sudo:
                admin.is_sudo = True
            # Existing tokens were issued against the old password.
            admin.token_epoch = (admin.token_epoch or 0) + 1
            created = False

        await session.commit()
        return {"username": username, "created": created, "is_sudo": admin.is_sudo}


async def _list_admins() -> list[dict[str, object]]:
    await init_db()
    async with SessionLocal() as session:
        rows = (await session.execute(select(Admin).order_by(Admin.id))).scalars().all()
        return [
            {"username": row.username, "is_sudo": row.is_sudo, "is_active": row.is_active}
            for row in rows
        ]


async def _recover(names: list[str]) -> list[dict[str, object]]:
    """One recovery attempt per named node, or per unhealthy node when none are named.

    No database and no HTTP: this is the same code the panel's own timer runs, so it
    reaches the exit servers with the panel's SSH key. That is why it has to run in
    this container rather than from the shell CLI.
    """
    if not names:
        names = [node.name for node in load_uplink_state().nodes if not node.healthy]
    out: list[dict[str, object]] = []
    for name in names:
        try:
            out.append(await recovery.recover_now(name))
        except Exception as exc:  # noqa: BLE001 - one bad node must not stop the rest
            out.append({"name": name, "healthy": False, "acted": False, "last_error": str(exc)})
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="app.cli", description="SauceWG panel administration")
    sub = parser.add_subparsers(dest="command", required=True)

    set_password = sub.add_parser("set-password", help="create an admin or reset its password")
    set_password.add_argument("--username", required=True)
    source = set_password.add_mutually_exclusive_group(required=True)
    source.add_argument("--password")
    # Keeps the password out of the process list on the host.
    source.add_argument(
        "--password-stdin", action="store_true", help="read the password from stdin"
    )
    set_password.add_argument("--sudo", action="store_true", help="grant full privileges")

    sub.add_parser("list-admins", help="list the configured admins")

    recover = sub.add_parser("recover", help="try to bring unhealthy exit nodes back")
    recover.add_argument("names", nargs="*", help="node names; defaults to every unhealthy node")

    args = parser.parse_args(argv)

    if args.command == "set-password":
        password = sys.stdin.read().strip() if args.password_stdin else args.password
        if not password:
            parser.error("the password is empty")
        result = asyncio.run(_set_password(args.username, password, args.sudo))
        verb = "created" if result["created"] else "updated"
        print(f"{verb} admin {result['username']}", file=sys.stderr)
        print(json.dumps(result))
        return 0

    if args.command == "list-admins":
        print(json.dumps(asyncio.run(_list_admins()), indent=2))
        return 0

    if args.command == "recover":
        results = asyncio.run(_recover(args.names))
        print(json.dumps(results, indent=2))
        # Non-zero when a node is still down, so a cron or a bot can tell without
        # parsing. An empty fleet of unhealthy nodes is a success.
        return 0 if all(row.get("healthy") for row in results) else 1

    parser.error(f"unknown command {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
