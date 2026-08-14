"""Reads the state the AmneziaWG container persists and renders client configs."""

from __future__ import annotations

import os
from dataclasses import dataclass

from ..config import settings

LEGACY_PARAMS = ("JC", "JMIN", "JMAX", "S1", "S2", "H1", "H2", "H3", "H4")


def read_params_file(path: str) -> dict[str, str]:
    if not os.path.exists(path):
        return {}
    values: dict[str, str] = {}
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


@dataclass
class ServerParams:
    public_key: str = ""
    port: int = 0
    subnet: str = ""
    address: str = ""
    mtu: int = 1420
    obfuscation: dict[str, int] = None  # type: ignore[assignment]

    @property
    def ready(self) -> bool:
        return bool(self.public_key)


def load_server_params() -> ServerParams:
    raw = read_params_file(settings.server_params_file)
    obfuscation = {}
    for name in LEGACY_PARAMS:
        value = raw.get(f"SERVER_{name}")
        if value and value.isdigit():
            obfuscation[name] = int(value)
    return ServerParams(
        public_key=raw.get("SERVER_PUBLIC_KEY", ""),
        port=int(raw.get("SERVER_PORT") or settings.awg_endpoint_port),
        subnet=raw.get("SERVER_SUBNET") or settings.awg_subnet,
        address=raw.get("SERVER_ADDRESS", ""),
        mtu=int(raw.get("SERVER_MTU") or 1420),
        obfuscation=obfuscation,
    )


def load_cascade_params() -> dict[str, str]:
    return read_params_file(settings.cascade_params_file)


def render_client_config(
    *,
    private_key: str,
    address: str,
    preshared_key: str | None,
    server: ServerParams,
    endpoint_host: str,
    endpoint_port: int,
) -> str:
    """Builds an AmneziaWG *legacy* (.conf) profile.

    S1/S2 and H1-H4 are copied verbatim from the server: the handshake fails unless
    both sides agree on them. Jc/Jmin/Jmax are per-side, so the panel is free to hand
    out its own junk-packet profile when one is configured.
    """
    obf = server.obfuscation or {}
    jc = settings.client_jc or obf.get("JC", 0)
    jmin = settings.client_jmin or obf.get("JMIN", 0)
    jmax = settings.client_jmax or obf.get("JMAX", 0)

    lines = [
        "[Interface]",
        f"PrivateKey = {private_key}",
        f"Address = {address}",
        f"DNS = {settings.client_dns}",
        f"MTU = {settings.client_mtu}",
        f"Jc = {jc}",
        f"Jmin = {jmin}",
        f"Jmax = {jmax}",
        f"S1 = {obf.get('S1', 0)}",
        f"S2 = {obf.get('S2', 0)}",
        f"H1 = {obf.get('H1', 1)}",
        f"H2 = {obf.get('H2', 2)}",
        f"H3 = {obf.get('H3', 3)}",
        f"H4 = {obf.get('H4', 4)}",
        "",
        "[Peer]",
        f"PublicKey = {server.public_key}",
    ]
    if preshared_key:
        lines.append(f"PresharedKey = {preshared_key}")
    lines += [
        f"AllowedIPs = {settings.client_allowed_ips}",
        f"Endpoint = {endpoint_host}:{endpoint_port}",
        f"PersistentKeepalive = {settings.client_keepalive}",
        "",
    ]
    return "\n".join(lines)
