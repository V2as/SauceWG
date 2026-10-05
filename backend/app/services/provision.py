"""Installs, pairs, inspects and removes exit nodes over SSH.

The panel drives ``saucewg.sh`` on the remote server rather than reimplementing the
install: the same script an operator would run by hand is uploaded and executed with
``--json``, so a node created from the UI and one created from a shell are byte for
byte the same installation.

Root credentials are used for the duration of one operation and never persisted.
What is remembered is the server's SSH host key, so the second connection to a node
can prove it is talking to the same machine as the first — and, when the caller lets
it, the panel's own public key is left in the account's ``authorized_keys`` so later
operations need no credentials at all.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import shlex
from dataclasses import dataclass, field
from typing import Any

from ..config import settings
from .tasks import Task

logger = logging.getLogger(__name__)

try:  # pragma: no cover - exercised only where the dependency is missing
    import asyncssh
except ImportError:  # pragma: no cover
    asyncssh = None  # type: ignore[assignment]


REMOTE_SCRIPT = "/usr/local/bin/saucewg"


class ProvisionError(RuntimeError):
    """Anything that went wrong while driving the remote server."""


class HostKeyMismatch(ProvisionError):
    """The server presented a different host key than the one recorded for it."""


@dataclass
class Credentials:
    host: str
    port: int = 22
    username: str = "root"
    password: str | None = field(default=None, repr=False)
    private_key: str | None = field(default=None, repr=False)
    # Recorded on the first connection and verified on every later one.
    host_key: str | None = None
    # The panel's public key, to leave behind in this account's authorized_keys.
    # Set whenever the caller supplied credentials of their own, so that the next
    # operation on this node does not have to ask for them again.
    enroll_key: str | None = None
    # True once the panel's key is known to be in place — either because it was just
    # installed, or because it is what this session logged in with.
    enrolled: bool = False

    def __str__(self) -> str:  # keeps secrets out of tracebacks and logs
        return f"{self.username}@{self.host}:{self.port}"


def _require_asyncssh() -> None:
    if asyncssh is None:
        raise ProvisionError(
            "the asyncssh package is not installed in the panel image, so exit nodes "
            "cannot be provisioned from the UI"
        )


class RemoteServer:
    """One SSH session, with command output streamed into a task log."""

    def __init__(self, credentials: Credentials, task: Task) -> None:
        self.credentials = credentials
        self.task = task
        self._conn: Any = None
        self.host_key: str | None = None

    async def __aenter__(self) -> RemoteServer:
        _require_asyncssh()
        creds = self.credentials

        known_hosts: Any = None
        if creds.host_key:
            try:
                known_hosts = ([asyncssh.import_public_key(creds.host_key)], [], [])
            except Exception as exc:  # noqa: BLE001 - a corrupt pin must not lock us out
                logger.warning("ignoring an unreadable stored host key for %s: %s", creds.host, exc)

        options: dict[str, Any] = {
            "username": creds.username,
            "known_hosts": known_hosts,
            "connect_timeout": settings.node_ssh_connect_timeout_seconds,
            "keepalive_interval": 15,
        }
        if creds.private_key:
            try:
                options["client_keys"] = [asyncssh.import_private_key(creds.private_key)]
            except Exception as exc:  # noqa: BLE001
                raise ProvisionError(f"the SSH private key could not be parsed: {exc}") from exc
        if creds.password:
            options["password"] = creds.password

        self.task.emit(f"connecting to {creds}")
        try:
            self._conn = await asyncio.wait_for(
                asyncssh.connect(creds.host, port=creds.port, **options),
                timeout=settings.node_ssh_connect_timeout_seconds + 10,
            )
        except asyncio.TimeoutError as exc:
            raise ProvisionError(f"{creds.host}:{creds.port} did not answer in time") from exc
        except Exception as exc:  # noqa: BLE001 - asyncssh raises a wide family here
            if asyncssh is not None and isinstance(exc, asyncssh.HostKeyNotVerifiable):
                raise HostKeyMismatch(
                    f"{creds.host} presented a different SSH host key than the one recorded "
                    f"when it was added. Either the server was rebuilt or the connection is "
                    f"being intercepted; remove the node and add it again if the change is "
                    f"expected."
                ) from exc
            if creds.enrolled and not creds.password:
                raise ProvisionError(
                    f"could not connect to {creds} with the panel's own SSH key: {exc}. "
                    f"Add the key from GET /api/nodes/ssh-key to that server's authorised "
                    f"keys, or supply a password once and it will be installed."
                ) from exc
            raise ProvisionError(f"could not connect to {creds}: {exc}") from exc

        key = self._conn.get_server_host_key()
        if key is not None:
            self.host_key = key.export_public_key().decode().strip()
        self.task.emit("connected")

        if creds.enroll_key:
            await self._enroll(creds.enroll_key)
            creds.enrolled = True
        return self

    async def _enroll(self, public_key: str) -> None:
        """Leaves the panel's public key in this account's authorized_keys.

        Idempotent, and deliberately not run through sudo: the key belongs to the
        account we are logged in as, which is the one we will come back to.
        """
        line = public_key.strip()
        script = (
            "set -e; "
            "mkdir -p ~/.ssh; chmod 700 ~/.ssh; "
            "touch ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; "
            f"if ! grep -qxF {shlex.quote(line)} ~/.ssh/authorized_keys; then "
            f"printf '%s\\n' {shlex.quote(line)} >> ~/.ssh/authorized_keys; fi"
        )
        await self.run(f"sh -c {shlex.quote(script)}", timeout=60, quiet=True)
        self.task.emit("the panel's SSH key is installed on this server")

    async def revoke(self, public_key: str) -> None:
        """Takes the panel's key back out again, for a server we are done with."""
        line = public_key.strip()
        script = (
            "if [ -f ~/.ssh/authorized_keys ]; then "
            f"grep -vxF {shlex.quote(line)} ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.saucewg "
            "|| true; "
            "cat ~/.ssh/authorized_keys.saucewg > ~/.ssh/authorized_keys; "
            "rm -f ~/.ssh/authorized_keys.saucewg; fi"
        )
        await self.run(f"sh -c {shlex.quote(script)}", check=False, timeout=60, quiet=True)

    async def __aexit__(self, *_: object) -> None:
        if self._conn is not None:
            self._conn.close()
            try:
                await self._conn.wait_closed()
            except Exception:  # noqa: BLE001 - a failed teardown is not interesting
                pass
            self._conn = None

    async def run(
        self,
        command: str,
        *,
        check: bool = True,
        timeout: int | None = None,
        stdin: str | None = None,
        quiet: bool = False,
    ) -> tuple[int, str]:
        """Runs one command, streaming its stderr into the task log.

        Returns the exit status and stdout. The remote scripts keep progress on
        stderr and data on stdout precisely so this split works.
        """
        if self._conn is None:
            raise ProvisionError("the SSH session is not open")

        stdout_chunks: list[str] = []

        async def pump(stream: Any, sink: Any) -> None:
            async for line in stream:
                sink(line)

        async def execute() -> int:
            async with self._conn.create_process(command, stdin=asyncssh.PIPE) as process:
                if stdin is not None:
                    process.stdin.write(stdin)
                process.stdin.write_eof()
                await asyncio.gather(
                    pump(process.stdout, stdout_chunks.append),
                    pump(process.stderr, (lambda _l: None) if quiet else self.task.emit),
                )
                result = await process.wait()
                return int(result.exit_status or 0)

        limit = timeout or settings.node_ssh_timeout_seconds
        try:
            status = await asyncio.wait_for(execute(), timeout=limit)
        except asyncio.TimeoutError as exc:
            raise ProvisionError(f"the remote command timed out after {limit}s") from exc
        except Exception as exc:  # noqa: BLE001
            raise ProvisionError(f"the remote command failed: {exc}") from exc

        output = "".join(stdout_chunks)
        if check and status != 0:
            raise ProvisionError(f"the remote command exited with status {status}")
        return status, output

    async def upload(self, content: str, remote_path: str, mode: int = 0o755) -> None:
        if self._conn is None:
            raise ProvisionError("the SSH session is not open")
        async with self._conn.start_sftp_client() as sftp:
            async with sftp.open(remote_path, "w") as handle:
                await handle.write(content)
            await sftp.chmod(remote_path, mode)


# ---------------------------------------------------------------------------
# The installer script
# ---------------------------------------------------------------------------


def installer_script() -> str:
    """The copy of saucewg.sh baked into the panel image."""
    path = settings.saucewg_installer_path
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read()
    except OSError as exc:
        raise ProvisionError(
            f"the installer script is missing from the panel image at {path}; "
            f"rebuild the image or set SAUCEWG_INSTALLER_PATH"
        ) from exc


async def _install_script(server: RemoteServer) -> None:
    """Puts the current saucewg.sh on the remote server, however we can."""
    try:
        script: str | None = installer_script()
    except ProvisionError as exc:
        server.task.emit(f"{exc}; fetching it from GitHub instead")
        script = None

    if script is not None:
        try:
            server.task.emit(f"uploading the installer to {REMOTE_SCRIPT}")
            await server.upload(script, REMOTE_SCRIPT)
            return
        except ProvisionError:
            raise
        except Exception as exc:  # noqa: BLE001 - SFTP may simply be disabled
            server.task.emit(f"SFTP upload failed ({exc}); falling back to a download")

    url = f"https://raw.githubusercontent.com/{settings.saucewg_repo}/{settings.saucewg_ref}/saucewg.sh"
    await server.run(
        f"curl -fsSL {shlex.quote(url)} -o {REMOTE_SCRIPT} && chmod 0755 {REMOTE_SCRIPT}"
    )


def _installer_env() -> str:
    """Pins the remote install to the same images and repository as this panel."""
    pairs = {
        "SAUCEWG_REPO": settings.saucewg_repo,
        "SAUCEWG_REF": settings.saucewg_ref,
        "SAUCEWG_NAMESPACE": settings.saucewg_namespace,
        "SAUCEWG_IMAGE_PREFIX": settings.saucewg_image_prefix,
        "SAUCEWG_TAG": settings.saucewg_tag,
    }
    return " ".join(f"{key}={shlex.quote(value)}" for key, value in pairs.items())


def _sudo_prefix(credentials: Credentials) -> str:
    # A non-root account needs passwordless sudo; the UI asks for root precisely so
    # that this is not something the operator has to have set up in advance.
    return "" if credentials.username == "root" else "sudo -n "


def _parse_json_output(output: str, what: str) -> dict[str, Any]:
    """Reads the last JSON object the script printed on stdout."""
    text = output.strip()
    if not text:
        raise ProvisionError(f"{what} produced no output")
    decoder = json.JSONDecoder()
    start = text.find("{")
    while start != -1:
        try:
            value, _ = decoder.raw_decode(text[start:])
        except ValueError:
            start = text.find("{", start + 1)
            continue
        if isinstance(value, dict):
            return value
        start = text.find("{", start + 1)
    raise ProvisionError(f"{what} did not return a JSON object: {text[:400]}")


# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------


@dataclass
class InstallRequest:
    name: str
    credentials: Credentials
    port: int = 51820
    subnet: str = "10.77.0.0/24"
    # This node's side of the IPv6 half of the bridge, which has to be the prefix the
    # entry node carries. Empty installs an IPv4-only exit node, which is the default
    # and what every node installed before this existed is.
    subnet6: str = ""
    preshared_key: str | None = field(default=None, repr=False)
    # Which AmneziaWG generation the exit node should serve. None leaves the choice
    # to the remote installer's own default.
    protocol: str | None = None
    # Preset name or literal spec for the exit node's signature packet.
    signature: str | None = None


async def install_exit_node(task: Task, request: InstallRequest) -> dict[str, Any]:
    """Installs AmneziaWG on a bare server and returns its pairing object.

    The result is exactly the object the entry node's exit node list expects, plus
    the host key we should pin for later connections.
    """
    creds = request.credentials
    async with RemoteServer(creds, task) as server:
        sudo = _sudo_prefix(creds)

        task.begin("Checking the server")
        _, uname = await server.run("uname -srm && cat /etc/os-release 2>/dev/null | head -2", quiet=True)
        for line in uname.strip().splitlines():
            task.emit(line)

        status, _ = await server.run(f"{sudo}test -w /", check=False, quiet=True)
        if status != 0:
            raise ProvisionError(
                f"{creds.username} cannot write as root on {creds.host}. Use the root "
                f"account, or give the account passwordless sudo."
            )

        task.begin("Installing SauceWG")
        await _install_script(server)

        command = (
            f"{sudo}{_installer_env()} {REMOTE_SCRIPT} --json --yes install-node"
            f" --name {shlex.quote(request.name)}"
            f" --port {int(request.port)}"
            f" --subnet {shlex.quote(request.subnet)}"
        )
        # The address the panel reached this server on, told to the installer as the
        # endpoint to publish. Whichever family it is: an IPv6-only VPS is reached
        # over IPv6 and joins the cascade on its IPv6 endpoint, and `--endpoint-host`
        # recognises a literal of either family.
        command += f" --endpoint-host {shlex.quote(creds.host)}"
        if request.subnet6:
            command += f" --subnet6 {shlex.quote(request.subnet6)}"
        if request.protocol:
            command += f" --protocol {shlex.quote(request.protocol)}"
        if request.signature:
            command += f" --signature {shlex.quote(request.signature)}"
        if request.preshared_key:
            command += " --psk-stdin"

        _, output = await server.run(command, stdin=request.preshared_key or None)
        node = _parse_json_output(output, "install-node")

        for required in ("name", "public_key"):
            if not node.get(required):
                raise ProvisionError(f"the remote installer did not report {required}")
        # One endpoint of either family is enough, and an IPv6-only server reports
        # only the one it has.
        if not node.get("endpoint") and not node.get("endpoint6"):
            raise ProvisionError("the remote installer did not report an endpoint")

        listening = node.get("endpoint") or node.get("endpoint6")
        if node.get("endpoint") and node.get("endpoint6"):
            listening = f"{node['endpoint']} and {node['endpoint6']}"
        task.emit(f"exit node {node['name']} is listening on {listening}")
        if node.get("subnet6"):
            task.emit(f"it carries IPv6 for the cascade on {node['subnet6']}")
        node["ssh_host_key"] = server.host_key
        return node


async def pair_exit_node(
    task: Task,
    credentials: Credentials,
    peer_public_key: str,
    preshared_key: str | None = None,
) -> None:
    """Installs the entry node's uplink key on the exit node and restarts it."""
    async with RemoteServer(credentials, task) as server:
        sudo = _sudo_prefix(credentials)
        command = (
            f"{sudo}{REMOTE_SCRIPT} --json --yes node-pair"
            f" --peer-key {shlex.quote(peer_public_key)}"
        )
        if preshared_key:
            command += " --psk-stdin"
        await server.run(command, stdin=preshared_key or None)
        task.emit("the exit node accepted the uplink key")


async def set_exit_node_protocol(
    task: Task,
    credentials: Credentials,
    protocol: str,
    signature: str | None = None,
) -> dict[str, Any]:
    """Moves an installed exit node to another AmneziaWG generation.

    Returns the node's refreshed pairing object: the padding and header parameters
    change with the generation, and the entry node has to be told the new ones or the
    handshake stops working.
    """
    async with RemoteServer(credentials, task) as server:
        sudo = _sudo_prefix(credentials)
        command = (
            f"{sudo}{REMOTE_SCRIPT} --json --yes set-protocol {shlex.quote(protocol)}"
        )
        if signature:
            command += f" --signature {shlex.quote(signature)}"
        _, output = await server.run(command, timeout=300)
        node = _parse_json_output(output, "set-protocol")
        task.emit(f"the exit node now serves AmneziaWG {node.get('protocol', protocol)}")
        return node


async def uninstall_exit_node(
    task: Task,
    credentials: Credentials,
    purge: bool = True,
    revoke_key: str | None = None,
) -> None:
    """Removes SauceWG from the exit server. Best effort: the node is already gone
    from the cascade by the time this runs, so a failure here is a leftover, not an
    outage."""
    async with RemoteServer(credentials, task) as server:
        sudo = _sudo_prefix(credentials)
        command = f"{sudo}{REMOTE_SCRIPT} --yes uninstall"
        if purge:
            command += " --purge"
        status, _ = await server.run(command, check=False, timeout=300)
        if status != 0:
            task.emit(f"the remote uninstall exited with status {status}")
        else:
            task.emit("SauceWG was removed from the server")

        # Wiping the software while leaving a key that still opens a root shell is
        # the kind of leftover nobody goes looking for, so it goes last and here.
        if revoke_key:
            await server.revoke(revoke_key)
            task.emit("the panel's SSH key was removed from the server")


# ---------------------------------------------------------------------------
# Inspection and lifecycle
# ---------------------------------------------------------------------------


#: One round trip that answers "what is this server, and is anything installed on
#: it already". Everything is optional: a bare VPS has neither docker nor saucewg.
_FACTS = r"""
printf 'kernel=%s\n' "$(uname -sr 2>/dev/null)"
printf 'arch=%s\n' "$(uname -m 2>/dev/null)"
( . /etc/os-release 2>/dev/null; printf 'os=%s\n' "${PRETTY_NAME:-unknown}" )
printf 'cpus=%s\n' "$(nproc 2>/dev/null || echo 0)"
printf 'memory_mb=%s\n' "$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
printf 'disk_free_mb=%s\n' "$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}')"
printf 'uptime_seconds=%s\n' "$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)"
command -v docker >/dev/null 2>&1 && printf 'docker=yes\n' || printf 'docker=no\n'
[ -x /usr/local/bin/saucewg ] && printf 'saucewg=yes\n' || printf 'saucewg=no\n'
[ -f /opt/saucewg/.role ] && printf 'role=%s\n' "$(cat /opt/saucewg/.role 2>/dev/null)"
"""


def _parse_facts(output: str) -> dict[str, Any]:
    facts: dict[str, Any] = {}
    for line in output.splitlines():
        key, separator, value = line.partition("=")
        key = key.strip()
        if not key or not separator:
            continue
        value = value.strip()
        if key in ("cpus", "memory_mb", "disk_free_mb", "uptime_seconds"):
            try:
                facts[key] = int(value)
            except ValueError:
                facts[key] = 0
        elif key in ("docker", "saucewg"):
            facts[key] = value == "yes"
        else:
            facts[key] = value or None
    return facts


async def probe_server(task: Task, credentials: Credentials) -> dict[str, Any]:
    """What a server is and whether it can be installed on, without changing it.

    Answers the question an operator asks before committing to a five-minute
    install: are the credentials right, is this the machine I think it is, and is
    something already running here.
    """
    async with RemoteServer(credentials, task) as server:
        _, facts = await server.run(f"sh -c {shlex.quote(_FACTS)}", check=False, quiet=True)
        result = _parse_facts(facts)

        sudo = _sudo_prefix(credentials)
        status, _ = await server.run(f"{sudo}test -w /", check=False, quiet=True)
        result["root"] = status == 0
        result["host_key"] = server.host_key
        result["reachable"] = True
        return result


async def node_status(task: Task, credentials: Credentials) -> dict[str, Any]:
    """The remote ``saucewg info`` plus the host facts around it."""
    async with RemoteServer(credentials, task) as server:
        sudo = _sudo_prefix(credentials)
        _, facts = await server.run(f"sh -c {shlex.quote(_FACTS)}", check=False, quiet=True)
        result = _parse_facts(facts)
        result["reachable"] = True

        status, output = await server.run(
            f"{sudo}{REMOTE_SCRIPT} info", check=False, quiet=True, timeout=120
        )
        if status != 0 or not output.strip():
            # An installed-but-broken node still answers the facts above, which is
            # what tells the operator whether the box or the software is the problem.
            result["containers"] = []
            result["error"] = (
                "the server is reachable but `saucewg info` failed; SauceWG may not be "
                "installed in /opt/saucewg"
            )
            return result

        info = _parse_json_output(output, "info")
        result["containers"] = info.get("containers") or []
        result["cli_version"] = info.get("cli_version")
        result["dir"] = info.get("dir")
        result["role"] = info.get("role") or result.get("role")
        return result


#: The service verbs the CLI understands, mapped to what to tell the operator.
SERVICE_ACTIONS = {
    "start": "Starting the exit node",
    "stop": "Stopping the exit node",
    "restart": "Restarting the exit node",
}


async def control_service(task: Task, credentials: Credentials, action: str) -> dict[str, Any]:
    """Runs ``saucewg start|stop|restart`` on the exit server."""
    if action not in SERVICE_ACTIONS:
        raise ProvisionError(f"unknown service action {action!r}")
    async with RemoteServer(credentials, task) as server:
        sudo = _sudo_prefix(credentials)
        await server.run(f"{sudo}{REMOTE_SCRIPT} --yes {action}", timeout=300)
        task.emit(f"the exit node accepted `saucewg {action}`")
        return {"action": action}


async def upgrade_exit_node(
    task: Task, credentials: Credentials, tag: str | None = None
) -> dict[str, Any]:
    """Pulls newer images on the exit server and recreates its containers.

    The node is pinned to the same registry and namespace as the panel, so a fleet
    moves together rather than drifting one server at a time.
    """
    async with RemoteServer(credentials, task) as server:
        sudo = _sudo_prefix(credentials)
        # The CLI replaces itself as part of an update, so it is refreshed first:
        # an old copy on the node cannot write the compose file a new release needs.
        await _install_script(server)
        command = f"{sudo}{_installer_env()} {REMOTE_SCRIPT} --json --yes update"
        if tag:
            command += f" --tag {shlex.quote(tag)}"
        _, output = await server.run(command, timeout=settings.node_ssh_timeout_seconds)
        result = _parse_json_output(output, "update")
        task.emit(f"the exit node is on {result.get('tag', tag or 'latest')}")
        return result


async def fetch_logs(
    task: Task, credentials: Credentials, service: str | None = None, lines: int = 200
) -> str:
    """The tail of the exit node's container logs."""
    async with RemoteServer(credentials, task) as server:
        sudo = _sudo_prefix(credentials)
        command = f"{sudo}{REMOTE_SCRIPT} logs -n {int(lines)}"
        if service:
            command += f" {shlex.quote(service)}"
        status, output = await server.run(command, check=False, quiet=True, timeout=120)
        if status != 0 and not output.strip():
            raise ProvisionError(
                "could not read the logs; SauceWG may not be installed on that server"
            )
        return output


async def check_reachable(credentials: Credentials, task: Task) -> str | None:
    """Opens a session and returns the server's host key, for a pre-flight check."""
    async with RemoteServer(credentials, task) as server:
        await server.run("true", quiet=True)
        return server.host_key


def installer_available() -> bool:
    return asyncssh is not None and os.path.exists(settings.saucewg_installer_path)
