"""Async client for the AmneziaWG/WireGuard userspace UAPI socket.

amneziawg-go exposes a line-oriented control protocol over a unix socket in
``/var/run/amneziawg/<iface>.sock``. Talking to it directly keeps the panel free of
any dependency on the ``awg`` binary or on sharing a network namespace with the node.
"""

from __future__ import annotations

import asyncio
import base64
import os
from dataclasses import dataclass, field
from datetime import datetime, timezone

ZERO_KEY = "0" * 64


class UAPIError(RuntimeError):
    pass


class DeviceUnavailable(UAPIError):
    pass


def b64_to_hex(value: str) -> str:
    raw = base64.b64decode(value)
    if len(raw) != 32:
        raise ValueError("a WireGuard key must be 32 bytes")
    return raw.hex()


def hex_to_b64(value: str) -> str:
    return base64.b64encode(bytes.fromhex(value)).decode()


@dataclass
class PeerState:
    public_key: str
    preshared_key: str | None = None
    endpoint: str | None = None
    allowed_ips: list[str] = field(default_factory=list)
    last_handshake: datetime | None = None
    rx_bytes: int = 0
    tx_bytes: int = 0
    persistent_keepalive: int = 0


@dataclass
class DeviceState:
    public_key: str | None = None
    private_key: str | None = None
    listen_port: int = 0
    fwmark: int = 0
    obfuscation: dict[str, int] = field(default_factory=dict)
    peers: dict[str, PeerState] = field(default_factory=dict)


_OBFUSCATION_KEYS = ("jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4")


class AWGDevice:
    def __init__(self, iface: str, socket_dir: str = "/var/run/amneziawg", timeout: float = 5.0):
        self.iface = iface
        self.socket_path = os.path.join(socket_dir, f"{iface}.sock")
        self.timeout = timeout
        self._lock = asyncio.Lock()

    @property
    def available(self) -> bool:
        return os.path.exists(self.socket_path)

    async def _request(self, payload: str) -> list[str]:
        if not self.available:
            raise DeviceUnavailable(f"{self.iface}: UAPI socket {self.socket_path} not found")
        async with self._lock:
            try:
                reader, writer = await asyncio.wait_for(
                    asyncio.open_unix_connection(self.socket_path, limit=8 * 1024 * 1024),
                    timeout=self.timeout,
                )
            except (OSError, asyncio.TimeoutError) as exc:
                raise DeviceUnavailable(f"{self.iface}: {exc}") from exc
            try:
                writer.write(payload.encode())
                await writer.drain()
                # The device keeps the connection open for further commands, so the
                # blank line that terminates the reply is the only end marker.
                data = await asyncio.wait_for(reader.readuntil(b"\n\n"), timeout=self.timeout)
            except asyncio.IncompleteReadError as exc:
                data = exc.partial
            finally:
                writer.close()
                try:
                    await writer.wait_closed()
                except Exception:  # noqa: BLE001 - closing errors are not actionable
                    pass

        lines = data.decode().split("\n")
        for line in lines:
            if line.startswith("errno="):
                errno = int(line.split("=", 1)[1])
                if errno != 0:
                    raise UAPIError(f"{self.iface}: UAPI returned errno={errno}")
        return lines

    async def get(self) -> DeviceState:
        lines = await self._request("get=1\n\n")
        state = DeviceState()
        current: PeerState | None = None

        for line in lines:
            if "=" not in line:
                continue
            key, value = line.split("=", 1)

            if key == "public_key":
                current = PeerState(public_key=hex_to_b64(value))
                state.peers[current.public_key] = current
                continue

            if current is None:
                if key == "private_key":
                    state.private_key = hex_to_b64(value) if value != ZERO_KEY else None
                elif key == "listen_port":
                    state.listen_port = int(value)
                elif key == "fwmark":
                    state.fwmark = int(value)
                elif key in _OBFUSCATION_KEYS:
                    try:
                        state.obfuscation[key] = int(value)
                    except ValueError:
                        pass
                continue

            if key == "preshared_key":
                current.preshared_key = hex_to_b64(value) if value != ZERO_KEY else None
            elif key == "endpoint":
                current.endpoint = value
            elif key == "allowed_ip":
                current.allowed_ips.append(value)
            elif key == "last_handshake_time_sec":
                seconds = int(value)
                current.last_handshake = (
                    datetime.fromtimestamp(seconds, tz=timezone.utc) if seconds else None
                )
            elif key == "rx_bytes":
                current.rx_bytes = int(value)
            elif key == "tx_bytes":
                current.tx_bytes = int(value)
            elif key == "persistent_keepalive_interval":
                current.persistent_keepalive = int(value)

        if state.private_key:
            from .keys import public_from_private

            state.public_key = public_from_private(state.private_key)
        return state

    async def _set(self, lines: list[str]) -> None:
        payload = "set=1\n" + "".join(f"{line}\n" for line in lines) + "\n"
        await self._request(payload)

    async def add_peer(
        self,
        public_key: str,
        allowed_ips: list[str],
        preshared_key: str | None = None,
        keepalive: int = 0,
        endpoint: str | None = None,
    ) -> None:
        # No "update_only" line: the device only accepts it with the value "true" and
        # rejects the whole command otherwise.
        lines = [f"public_key={b64_to_hex(public_key)}"]
        if preshared_key:
            lines.append(f"preshared_key={b64_to_hex(preshared_key)}")
        if endpoint:
            lines.append(f"endpoint={endpoint}")
        lines.append(f"persistent_keepalive_interval={keepalive}")
        lines.append("replace_allowed_ips=true")
        lines.extend(f"allowed_ip={cidr}" for cidr in allowed_ips)
        await self._set(lines)

    async def remove_peer(self, public_key: str) -> None:
        await self._set([f"public_key={b64_to_hex(public_key)}", "remove=true"])
