"""Reads the state the AmneziaWG container persists and renders client configs."""

from __future__ import annotations

import os
import shlex
from dataclasses import dataclass, field

from ..config import settings
from . import protocol as proto


def _unquote(value: str) -> str:
    """Undoes the shell quoting ``params_store`` applies.

    A signature spec such as ``<r 128>`` has to be quoted in a file the node's
    entrypoint sources, so the panel has to read it back the same way.
    """
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        try:
            parts = shlex.split(value)
        except ValueError:
            return value
        return parts[0] if parts else ""
    return value


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
            values[key.strip()] = _unquote(value)
    return values


@dataclass
class ServerParams:
    public_key: str = ""
    port: int = 0
    subnet: str = ""
    address: str = ""
    mtu: int = 1420
    #: Which AmneziaWG generation the interface serves. Everything rendered for a
    #: client follows from this.
    protocol: str = proto.ASSUMED_PROTOCOL
    #: Every obfuscation parameter the interface carries, keyed by its upper-case
    #: name. Numbers are kept as the strings the node wrote so that an H-range such
    #: as ``5-100`` survives alongside a plain count.
    obfuscation: dict[str, str] = field(default_factory=dict)

    @property
    def ready(self) -> bool:
        return bool(self.public_key)

    @property
    def numeric_obfuscation(self) -> dict[str, int]:
        """The subset that is a plain number, for callers that want counts."""
        out: dict[str, int] = {}
        for name, value in self.obfuscation.items():
            try:
                out[name] = int(value)
            except (TypeError, ValueError):
                continue
        return out


def load_server_params() -> ServerParams:
    raw = read_params_file(settings.server_params_file)

    # An installation that predates generation selection has a profile but no
    # generation recorded, and its clients are speaking 1.0 right now.
    recorded = raw.get("SERVER_PROTOCOL")
    if recorded:
        try:
            version = proto.normalize(recorded)
        except proto.UnknownProtocol:
            version = proto.infer(raw, prefix="SERVER_")
    else:
        version = proto.infer(raw, prefix="SERVER_")

    obfuscation: dict[str, str] = {}
    for name in proto.ALL_PARAMS:
        if not proto.carries(version, name):
            continue
        value = (raw.get(f"SERVER_{name}") or "").strip()
        if value:
            obfuscation[name] = value

    return ServerParams(
        public_key=raw.get("SERVER_PUBLIC_KEY", ""),
        port=int(raw.get("SERVER_PORT") or settings.awg_endpoint_port),
        subnet=raw.get("SERVER_SUBNET") or settings.awg_subnet,
        address=raw.get("SERVER_ADDRESS", ""),
        mtu=int(raw.get("SERVER_MTU") or 1420),
        protocol=version,
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
    signature: str | None = None,
) -> str:
    """Builds an AmneziaWG profile of whatever generation the server speaks.

    Only the parameters of that generation are written: an extra one would make the
    file a different generation, which AmneziaVPN and KeeneticOS would then refuse
    to load or would load into a tunnel the server cannot answer.

    S1-S4 and H1-H4 are copied verbatim, since the handshake fails unless both ends
    agree. Jc/Jmin/Jmax and I1-I5 are built by the sender alone, so the panel is
    free to hand out its own — useful when a client sits behind a censor that drops
    the disguise the server picked for itself.
    """
    obf = server.obfuscation or {}
    version = server.protocol

    lines = [
        "[Interface]",
        f"PrivateKey = {private_key}",
        f"Address = {address}",
        f"DNS = {settings.client_dns}",
        f"MTU = {settings.client_mtu}",
    ]

    overrides: dict[str, str] = {}
    if settings.client_jc:
        overrides["JC"] = str(settings.client_jc)
    if settings.client_jmin:
        overrides["JMIN"] = str(settings.client_jmin)
    if settings.client_jmax:
        overrides["JMAX"] = str(settings.client_jmax)

    chosen = signature if signature is not None else settings.client_signature
    if chosen and proto.carries(version, "I1"):
        overrides["I1"] = proto.cps_spec(chosen)

    for name in proto.PROTOCOL_PARAMS[version]:
        value = overrides.get(name, obf.get(name, ""))
        if not value:
            continue
        lines.append(f"{proto.label(name)} = {value}")

    # I2-I5 are extras the server may or may not have set; they cost nothing to
    # mirror and some clients want the same padding profile in both directions.
    for name in ("I2", "I3", "I4", "I5"):
        if proto.carries(version, name) and obf.get(name):
            lines.append(f"{name} = {obf[name]}")

    lines += ["", "[Peer]", f"PublicKey = {server.public_key}"]
    if preshared_key:
        lines.append(f"PresharedKey = {preshared_key}")
    lines += [
        f"AllowedIPs = {settings.client_allowed_ips}",
        f"Endpoint = {endpoint_host}:{endpoint_port}",
        f"PersistentKeepalive = {settings.client_keepalive}",
        "",
    ]
    return "\n".join(lines)
