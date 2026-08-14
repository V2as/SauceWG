from __future__ import annotations

import ipaddress

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..models import Client


class AddressPoolExhausted(RuntimeError):
    pass


async def allocate_address(session: AsyncSession, subnet: str) -> str:
    """Returns the lowest free host address in the subnet.

    ``.1`` belongs to the node itself, so allocation starts at ``.2``.
    """
    network = ipaddress.ip_network(subnet, strict=False)
    taken = {
        row[0].split("/")[0]
        for row in await session.execute(select(Client.address))
    }
    taken.add(str(next(network.hosts())))

    for host in network.hosts():
        candidate = str(host)
        if candidate not in taken:
            return candidate
    raise AddressPoolExhausted(f"no free addresses left in {subnet}")


def normalize_address(address: str) -> str:
    return address.split("/")[0]


def with_prefix(address: str, prefix: int = 32) -> str:
    return f"{normalize_address(address)}/{prefix}"
