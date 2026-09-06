#!/usr/bin/env python3
"""Exercises the exit node API against a stubbed node container.

The panel and the node container talk to each other through two files: the exit
node list the panel writes, and the state file the container publishes. That makes
the whole add/remove path testable without Docker, a database or a real server —
this stands in for the container and drives the API in-process.

    pip install httpx && ./scripts/test-node-api.py
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "backend"))
os.environ.setdefault("JWT_SECRET", "ci")
os.environ.setdefault("ADMIN_PASSWORD", "ci-password")
os.environ.setdefault("POSTGRES_PASSWORD", "ci")
os.environ.setdefault("AWG_ENDPOINT_HOST", "127.0.0.1")

import httpx  # noqa: E402

from app.awg import registry  # noqa: E402
from app.config import settings  # noqa: E402
from app.db import get_session  # noqa: E402
from app.deps import get_current_admin, get_sudo_admin  # noqa: E402
from app.main import app  # noqa: E402
from app.routers.system import build_cascade_status  # noqa: E402
from app.services import recovery  # noqa: E402
from app.services.tasks import tasks  # noqa: E402

logging.disable(logging.INFO)


class FakeAdmin:
    username = "ci"
    is_sudo = True
    is_active = True


class FakeClient:
    """A row of the client table, for the endpoints that put a name to an address."""

    def __init__(self, client_id: int, name: str, address: str) -> None:
        self.id = client_id
        self.name = name
        self.address = address


class FakeSession:
    """Enough of an AsyncSession to answer `select(Client)` without a database."""

    rows: list[FakeClient] = []

    async def execute(self, *_args, **_kwargs):
        rows = self.rows

        class Result:
            def scalars(self):
                return self

            def all(self):
                return rows

        return Result()


session_stub = FakeSession()

app.dependency_overrides[get_current_admin] = lambda: FakeAdmin()
app.dependency_overrides[get_sudo_admin] = lambda: FakeAdmin()
app.dependency_overrides[get_session] = lambda: session_stub

workdir = tempfile.mkdtemp(prefix="saucewg-nodes-")
settings.node_registry_file = os.path.join(workdir, "exit-nodes.json")
settings.routes_registry_file = os.path.join(workdir, "direct-routes.json")
settings.bypass_registry_file = os.path.join(workdir, "bypass.json")
settings.torrent_registry_file = os.path.join(workdir, "torrent-block.json")
# torrent_state_file follows awg_socket_dir, the same way uplink_state_file does.
settings.awg_socket_dir = workdir
# Where the node container would persist the entry interface's profile.
settings.awg_config_dir = workdir
# The panel's own SSH key, which lets it manage a node without credentials.
settings.node_ssh_key_file = os.path.join(workdir, "panel-ssh-key")
# Every SSH call below is aimed at a closed port, so it has to give up quickly.
settings.node_ssh_connect_timeout_seconds = 2
settings.node_ssh_query_timeout_seconds = 10

checks = 0


def check(label: str, condition: bool, detail: object = "") -> None:
    global checks
    checks += 1
    if not condition:
        raise SystemExit(f"FAIL  {label}: {detail}")
    print(f"  ok  {label}")


def publish(
    *,
    age: float = 0.0,
    reload_id: str = "0",
    source: str = "file",
    nodes=(),
    fallback: str | None = "direct",
    fallback_active: bool = False,
    direct: dict | None = None,
    bypass: dict | None = None,
) -> None:
    """Writes the state file the way the node container would.

    ``fallback=None``, ``direct=None`` and ``bypass=None`` leave those keys out
    entirely, which is what a node container older than this panel publishes.
    """
    state = {
        "updated_at": time.time() - age,
        "reload_id": reload_id,
        "source": source,
        "config_error": None,
        "mode": "auto",
        "pinned": None,
        "active": None,
        "killswitch": fallback != "direct",
        "nodes": list(nodes),
    }
    if fallback is not None:
        state["fallback"] = fallback
        state["fallback_active"] = fallback_active
    if direct is not None:
        state["direct"] = direct
    if bypass is not None:
        state["bypass"] = bypass
    with open(settings.uplink_state_file, "w", encoding="utf-8") as handle:
        json.dump(state, handle)


async def container(stop: asyncio.Event) -> None:
    """A node container that applies every reload request it is handed."""
    while not stop.is_set():
        try:
            with open(settings.uplink_reload_file, encoding="utf-8") as handle:
                request_id = json.load(handle)["id"]
        except (OSError, ValueError):
            request_id = "0"
        publish(reload_id=request_id)
        await asyncio.sleep(0.1)


async def drain(client: httpx.AsyncClient, task_id: str, timeout: float = 30.0) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        task = (await client.get(f"/api/nodes/tasks/{task_id}")).json()
        if task["status"] in ("succeeded", "failed"):
            return task
        await asyncio.sleep(0.1)
    raise SystemExit(f"FAIL  task {task_id} never finished")


async def main() -> None:
    publish()
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://panel") as client:
        print("registry")
        response = await client.get("/api/nodes")
        body = response.json()
        check("an empty cascade is readable", response.status_code == 200, response.text)
        check("provisioning is offered", body["provisioning"] is True, body)
        check("no configuration error", body["config_error"] is None, body)

        print("adopting")
        payload = {"name": "eu-nl", "endpoint": "198.51.100.20:51820", "public_key": "KEY-NL"}
        response = await client.post("/api/nodes/adopt", json=payload)
        check("a hand-installed node is adopted", response.status_code == 201, response.text)
        stored = registry.load_nodes()
        check("it is stored once", len(stored) == 1, stored)
        check("with an allocated address", stored[0]["address"] == "10.77.0.2/32", stored)
        check("and the first priority", stored[0]["priority"] == 10, stored)
        check("marked as not panel-installed", stored[0]["managed"] is False, stored)

        response = await client.post("/api/nodes/adopt", json=payload)
        check("a duplicate name is refused", response.status_code == 409, response.text)

        response = await client.post(
            "/api/nodes/adopt", json={**payload, "name": "eu-de", "public_key": "KEY-DE"}
        )
        check("a second node is accepted", response.status_code == 201, response.text)
        stored = registry.load_nodes()
        check("without reusing the address", stored[1]["address"] == "10.77.0.3/32", stored)
        check("and appended below the first", stored[1]["priority"] == 20, stored)

        print("editing")
        response = await client.put("/api/nodes/eu-de", json={"priority": 5, "note": "primary"})
        check("priority is editable", response.status_code == 200, response.text)
        edited = registry.find(registry.load_nodes(), "eu-de")
        check("the change is persisted", edited["priority"] == 5 and edited["note"] == "primary", edited)

        response = await client.put("/api/nodes/ghost", json={"priority": 5})
        check("an unknown node is a 404", response.status_code == 404, response.text)

        print("generations")
        # A 2.0 exit node has to carry S3, S4 and I1 into the list, since both ends of
        # the tunnel must pad and label packets the same way.
        response = await client.post(
            "/api/nodes/adopt",
            json={
                "name": "eu-v2", "endpoint": "192.0.2.5:51820", "public_key": "KEY-V2",
                "protocol": "2.0", "s1": 58, "s2": 149, "s3": 55, "s4": 21,
                "h1": "42356304", "h2": "2002173728", "h3": "321222584", "h4": "822133763",
                "i1": "<r 128>",
            },
        )
        check("a 2.0 node is adopted", response.status_code == 201, response.text)
        stored = registry.find(registry.load_nodes(), "eu-v2")
        check("the generation is recorded", stored["protocol"] == "2.0", stored)
        check("with its padding", (stored["s3"], stored["s4"]) == (55, 21), stored)
        check("and its signature", stored["i1"] == "<r 128>", stored)

        response = await client.post(
            "/api/nodes/adopt",
            json={"name": "eu-legacy", "endpoint": "192.0.2.6:51820", "public_key": "KEY-L",
                  "protocol": "legacy"},
        )
        check("'legacy' is accepted as a spelling of 1.0", response.status_code == 201, response.text)
        check(
            "and stored canonically",
            registry.find(registry.load_nodes(), "eu-legacy")["protocol"] == "1.0",
            registry.load_nodes(),
        )

        response = await client.post(
            "/api/nodes/adopt",
            json={"name": "eu-v3", "endpoint": "192.0.2.7:51820", "public_key": "KEY-V3",
                  "protocol": "3.0"},
        )
        # 3.0 exists upstream but no router firmware speaks it, so a profile using it
        # could never be loaded into a Keenetic.
        check("a generation we cannot serve is refused", response.status_code == 422, response.text)

        response = await client.put("/api/nodes/eu-v2", json={"protocol": "1.5"})
        check("the generation is editable", response.status_code == 200, response.text)
        check(
            "and the change is persisted",
            registry.find(registry.load_nodes(), "eu-v2")["protocol"] == "1.5",
            registry.load_nodes(),
        )

        # Changing it on a node the panel did not install needs a shell on that server,
        # so the API says so rather than half-applying the change.
        response = await client.post(
            "/api/nodes/eu-v2/protocol", json={"protocol": "2.0", "ssh_password": "x"}
        )
        check("moving an adopted node over SSH is refused", response.status_code == 422, response.text)
        check("with the command to run instead", "set-protocol" in response.text, response.text)

        response = await client.post("/api/nodes/eu-v2/protocol", json={"protocol": "9.9"})
        check("an impossible target is refused outright", response.status_code == 422, response.text)

        # Back to the two nodes the removal tests below expect.
        registry.save_nodes(
            [n for n in registry.load_nodes() if n["name"] not in ("eu-v2", "eu-legacy")]
        )

        print("client profiles follow the entry interface's generation")
        params = Path(settings.server_params_file)
        base = (
            "SERVER_PUBLIC_KEY=SRVKEY\nSERVER_PORT=51820\nSERVER_SUBNET=10.8.0.0/24\n"
            "SERVER_ADDRESS=10.8.0.1\nSERVER_MTU=1420\nSERVER_JC=7\nSERVER_JMIN=50\n"
            "SERVER_JMAX=1000\nSERVER_S1=58\nSERVER_S2=149\nSERVER_H1=1\nSERVER_H2=2\n"
            "SERVER_H3=3\nSERVER_H4=4\n"
        )

        params.write_text(base + "SERVER_PROTOCOL=1.0\n", encoding="utf-8")
        body = (await client.get("/api/settings")).json()
        check("1.0 is reported", body["protocol"] == "1.0", body)
        check("with no S3 or I1", "S3" not in body["obfuscation"] and "I1" not in body["obfuscation"], body)

        params.write_text(
            base + "SERVER_PROTOCOL=2.0\nSERVER_S3=55\nSERVER_S4=21\nSERVER_I1='<r 128>'\n",
            encoding="utf-8",
        )
        body = (await client.get("/api/settings")).json()
        check("2.0 is reported", body["protocol"] == "2.0", body)
        check("with its padding", body["obfuscation"].get("S3") == "55", body)
        # params_store quotes a spec so the node's entrypoint can source the file; the
        # panel has to hand it to clients unquoted or AmneziaVPN rejects the profile.
        check("and an unquoted signature", body["obfuscation"].get("I1") == "<r 128>", body)
        check("every generation is offered", body["protocols_supported"] == ["1.0", "1.5", "2.0"], body)

        # An interface written before generations were named records none, but the
        # parameters it carries still say which one it is.
        params.write_text(base + "SERVER_S3=55\nSERVER_S4=21\nSERVER_I1='<r 128>'\n", encoding="utf-8")
        body = (await client.get("/api/settings")).json()
        check("an unnamed generation is inferred from the profile", body["protocol"] == "2.0", body)
        params.write_text(base, encoding="utf-8")
        body = (await client.get("/api/settings")).json()
        check("and a bare profile reads as 1.0", body["protocol"] == "1.0", body)

        print("credentials")
        response = await client.request("DELETE", "/api/nodes/eu-nl", json={"uninstall": True})
        check("wiping an adopted server is refused", response.status_code == 422, response.text)
        response = await client.post("/api/nodes/eu-nl/repair", json={"ssh_password": "x"})
        check("so is repairing one", response.status_code == 422, response.text)

        print("the panel's SSH identity")
        response = await client.get("/api/nodes/ssh-key")
        key = response.json()
        check("the panel publishes an SSH key", response.status_code == 200, response.text)
        check("an ed25519 one", key["public_key"].startswith("ssh-ed25519 "), key)
        check("with a fingerprint to compare", key["fingerprint"].startswith("SHA256:"), key)
        mode = os.stat(settings.node_ssh_key_file).st_mode & 0o777
        check("the private half is not readable by anyone else", mode == 0o600, oct(mode))
        again = (await client.get("/api/nodes/ssh-key")).json()
        check("and reading it again returns the same key", again["public_key"] == key["public_key"], again)

        print("managing the server behind a node")
        # A node the panel installed, pointed at a closed port: every call below has
        # to reach the point of dialling it, and fail there rather than earlier.
        keyed = {
            "name": "eu-keyed", "endpoint": "192.0.2.9:51820", "public_key": "KEY-K",
            "address": "10.77.0.9/32", "priority": 90, "managed": True,
            "ssh_host": "127.0.0.1", "ssh_port": 1, "ssh_user": "root", "ssh_key": True,
        }
        registry.save_nodes([*registry.load_nodes(), keyed])

        response = await client.get("/api/nodes/eu-keyed/status")
        body = response.json()
        check("a keyed node is reachable without credentials", response.status_code == 200, response.text)
        check("and reports why it could not be reached", body["reachable"] is False, body)
        check("as a sentence, not a stack trace", "127.0.0.1" in (body["error"] or ""), body)

        response = await client.post("/api/nodes/eu-keyed/restart")
        check("a restart needs no body at all", response.status_code == 202, response.text)
        task = await drain(client, response.json()["id"])
        check("and fails on the connection, having got that far", task["status"] == "failed", task)

        response = await client.get("/api/nodes/eu-keyed/logs?service=not%20a%20service")
        check("a service name is validated", response.status_code == 422, response.text)

        # The same node without the panel's key: there is now no way in, and saying
        # so is more use than a connection error a minute later.
        current = registry.load_nodes()
        registry.find(current, "eu-keyed").pop("ssh_key")
        registry.save_nodes(current)
        for path, method in (("status", "GET"), ("logs", "GET")):
            response = await client.request(method, f"/api/nodes/eu-keyed/{path}")
            check(f"{path} without a key asks for credentials", response.status_code == 422, response.text)
        response = await client.post("/api/nodes/eu-keyed/upgrade")
        check("so does an upgrade", response.status_code == 422, response.text)
        check("saying a password would fix it", "password" in response.text, response.text)

        for path in ("status", "logs"):
            response = await client.get(f"/api/nodes/ghost/{path}")
            check(f"{path} on an unknown node is a 404", response.status_code == 404, response.text)
        response = await client.post("/api/nodes/ghost/restart")
        check("and so is restarting one", response.status_code == 404, response.text)

        registry.save_nodes([n for n in registry.load_nodes() if n["name"] != "eu-keyed"])

        print("installing without a password")
        response = await client.post(
            "/api/nodes", json={"name": "eu-fr", "host": "127.0.0.1", "ssh_port": 1}
        )
        check("an install with no credentials is accepted", response.status_code == 202, response.text)
        task = await drain(client, response.json()["id"])
        check("and uses the panel's key", task["status"] == "failed", task)
        check("leaving nothing behind when it fails", registry.find(registry.load_nodes(), "eu-fr") is None, registry.load_nodes())

        settings.node_ssh_key_enabled = False
        response = await client.post(
            "/api/nodes", json={"name": "eu-fr", "host": "127.0.0.1", "ssh_port": 1}
        )
        check("without a key to fall back on, it is refused", response.status_code == 422, response.text)
        check("pointing at where to get one", "ssh-key" in response.text, response.text)
        settings.node_ssh_key_enabled = True

        print("checking a server before installing on it")
        response = await client.post("/api/nodes/check", json={"host": "127.0.0.1", "ssh_port": 1})
        body = response.json()
        check("a check answers rather than failing", response.status_code == 200, response.text)
        check("with the server marked unreachable", body["reachable"] is False, body)
        check("and a reason to show the operator", bool(body["error"]), body)
        response = await client.post("/api/nodes/check", json={"ssh_port": 22})
        check("a check without a host is refused", response.status_code == 422, response.text)

        print("removing, with the container running")
        stop = asyncio.Event()
        pump = asyncio.create_task(container(stop))
        response = await client.request("DELETE", "/api/nodes/eu-nl")
        check("removal is accepted", response.status_code == 202, response.text)
        task = await drain(client, response.json()["id"])
        stop.set()
        await pump
        check("the task succeeds", task["status"] == "succeeded", task)
        check("the container confirmed", "applied" in task["log"][-1]["text"], task["log"])
        check("the node is gone", registry.find(registry.load_nodes(), "eu-nl") is None, registry.load_nodes())

        print("removing, with the container stopped")
        publish(age=3600)
        started = time.monotonic()
        response = await client.request("DELETE", "/api/nodes/eu-de")
        task = await drain(client, response.json()["id"])
        elapsed = time.monotonic() - started
        check("the task still succeeds", task["status"] == "succeeded", task)
        check("without waiting out the timeout", elapsed < 15, f"{elapsed:.1f}s")
        check("saying it will apply on startup", "will be applied" in task["log"][-1]["text"], task["log"])
        check("and the list is empty", registry.load_nodes() == [], registry.load_nodes())

        print("the fallback while every exit node is down")
        publish(fallback="direct", fallback_active=True)
        body = (await client.get("/api/nodes")).json()
        check("the mode is reported", body["fallback"] == "direct", body)
        check("and that it is in use", body["fallback_active"] is True, body)
        check("the old flag agrees with it", body["killswitch"] is False, body)

        publish(fallback="block", fallback_active=True)
        body = (await client.get("/api/nodes")).json()
        check("blocking is reported too", body["fallback"] == "block", body)
        check("and the old flag follows", body["killswitch"] is True, body)

        # A node container that predates the fallback modes only publishes the flag.
        publish(fallback=None)
        body = (await client.get("/api/nodes")).json()
        check("an older container still reads as blocking", body["fallback"] == "block", body)

        print("direct routes")
        publish()
        response = await client.get("/api/routes")
        body = response.json()
        check("the bypass list is readable", response.status_code == 200, response.text)
        check("and starts empty", body["routes"] == [], body)
        check("with nothing applied yet", body["live"] is False, body)

        response = await client.post(
            "/api/routes", json={"cidr": ["142.250.0.0/15", "8.8.8.8"], "note": "youtube"}
        )
        body = response.json()
        check("a group of destinations is accepted", response.status_code == 201, response.text)
        check("both are listed", len(body["routes"]) == 2, body)
        check("a bare address became a host route", body["routes"][1]["cidr"] == "8.8.8.8/32", body)
        check("the label is kept", body["routes"][0]["note"] == "youtube", body)
        check("but nothing is active until the node says so", body["routes"][0]["active"] is False, body)

        response = await client.post("/api/routes", json={"cidr": ["10.20.30.40/24"]})
        body = response.json()
        check("an address inside a range is masked", body["routes"][2]["cidr"] == "10.20.30.0/24", body)

        response = await client.post("/api/routes", json={"cidr": ["8.8.8.8/32"]})
        check("adding one twice is not an error", response.status_code == 201, response.text)
        check("and does not duplicate it", len(response.json()["routes"]) == 3, response.json())

        for bad, why in (
            ("youtube.com", "a name is not a prefix"),
            ("10.0.0.0/33", "an impossible mask"),
            ("2001:db8::/32", "IPv6"),
        ):
            response = await client.post("/api/routes", json={"cidr": [bad]})
            check(f"{why} is refused", response.status_code == 400, response.text)

        response = await client.post("/api/routes", json={"cidr": ["0.0.0.0/0"]})
        check("so is everything at once", response.status_code == 400, response.text)
        check("pointing at the fallback instead", "fallback" in response.text, response.text)

        # What the node container reports is what decides whether a route is in force.
        publish(direct={"source": "file", "routes": ["142.250.0.0/15"], "applied": 1,
                        "via": "eth0", "error": None})
        body = (await client.get("/api/routes")).json()
        check("an applied route is marked active", body["routes"][0]["active"] is True, body)
        check("one still pending is not", body["routes"][1]["active"] is False, body)
        check("and the interface is reported", body["via"] == "eth0", body)
        check("the panel knows the node is answering", body["live"] is True, body)

        # A list written by hand may use bare strings and bare addresses. The container
        # routes them as /32, so the panel has to read them the same way or they would
        # look permanently unapplied.
        with open(settings.routes_registry_file, "w", encoding="utf-8") as handle:
            json.dump(["1.1.1.1", {"cidr": "9.9.9.9", "note": "quad9"}], handle)
        publish(direct={"source": "file", "routes": ["1.1.1.1/32"], "applied": 1,
                        "via": "eth0", "error": None})
        body = (await client.get("/api/routes")).json()
        check("a bare string entry is read", body["routes"][0]["cidr"] == "1.1.1.1/32", body)
        check("and matches what the node installed", body["routes"][0]["active"] is True, body)
        check("as does a bare address in an object", body["routes"][1]["cidr"] == "9.9.9.9/32", body)

        # Back to the three the removal checks below expect.
        with open(settings.routes_registry_file, "w", encoding="utf-8") as handle:
            json.dump(
                [
                    {"cidr": "142.250.0.0/15", "note": "youtube", "enabled": True},
                    {"cidr": "8.8.8.8/32", "note": "youtube", "enabled": True},
                    {"cidr": "10.20.30.0/24", "enabled": True},
                ],
                handle,
            )
        publish(direct={"source": "file", "routes": ["142.250.0.0/15"], "applied": 1,
                        "via": "eth0", "error": None})

        response = await client.put("/api/routes/8.8.8.8/32", json={"enabled": False})
        body = response.json()
        check("a route can be turned off", response.status_code == 200, response.text)
        check("without being lost", len(body["routes"]) == 3, body)
        check("and it is recorded", body["routes"][1]["enabled"] is False, body)

        response = await client.delete("/api/routes/142.250.0.0/15")
        check("a route can be removed", response.status_code == 200, response.text)
        check("leaving the others", len(response.json()["routes"]) == 2, response.json())
        response = await client.delete("/api/routes/203.0.113.0/24")
        check("removing one that is not there is a 404", response.status_code == 404, response.text)

        print("when the environment overrides the direct routes")
        publish(direct={"source": "env", "routes": ["1.2.3.0/24"], "applied": 1,
                        "via": "eth0", "error": None})
        body = (await client.get("/api/routes")).json()
        check("the panel says which one is in charge", "CASCADE_DIRECT_ROUTES" in (body["config_error"] or ""), body)
        response = await client.post("/api/routes", json={"cidr": ["9.9.9.9"]})
        check("and refuses writes that would not take effect", response.status_code == 409, response.text)

        print("destinations the entry node reopens for itself")

        def running(routes, *, mode="auto", active=True, groups=("telegram",)):
            """The bypass state a node container publishes while the relay is up."""
            return {
                "mode": mode,
                "groups": list(groups),
                "source": "file",
                "routes": list(routes),
                "applied": len(routes),
                "active": active,
                "relay": {
                    "listen": "10.8.0.1:8646",
                    "prefixes": len(routes),
                    "open": 1,
                    "accepted": 40,
                    "via_v6": 31,
                    "via_retry": 8,
                    "failed": 1,
                    "attempts": 96,
                    "cooled": 4,
                    "rx_bytes": 4096,
                    "tx_bytes": 2048,
                },
                "error": None,
            }

        publish()
        response = await client.get("/api/bypass")
        body = response.json()
        check("the list is readable", response.status_code == 200, response.text)
        check("and starts empty", body["entries"] == [], body)
        check("with the node not answering yet", body["live"] is False, body)

        response = await client.post(
            "/api/bypass", json={"cidr": ["203.0.113.0/24"], "note": "some service"}
        )
        body = response.json()
        check("a destination is accepted", response.status_code == 201, response.text)
        check("and listed", body["entries"][0]["cidr"] == "203.0.113.0/24", body)
        check("with no counterpart, so its own IPv4 is retried", body["entries"][0]["v6"] is None, body)
        check("nothing is active until the node says so", body["entries"][0]["active"] is False, body)

        response = await client.post(
            "/api/bypass", json={"cidr": ["198.51.100.7"], "v6": "2001:db8::a"}
        )
        body = response.json()
        check("a counterpart is kept", body["entries"][1]["v6"] == "2001:db8::a", body)
        check("and a bare address became a host route", body["entries"][1]["cidr"] == "198.51.100.7/32", body)

        # Unlike a direct route, an entry carries *how* to reach the destination, so
        # adding one twice has to correct it rather than be skipped as a duplicate.
        response = await client.post(
            "/api/bypass", json={"cidr": ["198.51.100.7"], "v6": "2001:db8::ff"}
        )
        body = response.json()
        check("re-adding one corrects its counterpart", body["entries"][1]["v6"] == "2001:db8::ff", body)
        check("without duplicating it", len(body["entries"]) == 2, body)

        for payload_, why in (
            ({"cidr": ["telegram.org"]}, "a name is not a prefix"),
            ({"cidr": ["0.0.0.0/0"]}, "every destination at once"),
            ({"cidr": ["1.2.3.4"], "v6": "not-an-address"}, "an unparseable counterpart"),
            ({"cidr": ["1.2.3.4"], "v6": "9.9.9.9"}, "an IPv4 counterpart"),
            ({"cidr": ["1.2.3.4", "5.6.7.8"], "v6": "2001:db8::1"}, "one counterpart for two destinations"),
        ):
            response = await client.post("/api/bypass", json=payload_)
            check(f"{why} is refused", response.status_code == 400, response.text)

        # What the node container reports is what decides whether an entry is in force,
        # and it also knows counterparts the file does not.
        publish(bypass=running([
            {"cidr": "203.0.113.0/24", "v6": None, "note": "some service"},
            {"cidr": "198.51.100.7/32", "v6": "2001:db8::ff", "note": None},
            {"cidr": "149.154.167.51/32", "v6": "2001:67c:4e8:f002::a", "note": "telegram-dc2"},
        ]))
        body = (await client.get("/api/bypass")).json()
        check("the panel knows the node is answering", body["live"] is True, body)
        check("the mode is reported", body["mode"] == "auto", body)
        check("so are the built-in groups", body["groups"] == ["telegram"], body)
        check("and that the redirect is in force", body["active"] is True, body)
        check("a listed entry is marked active", body["entries"][0]["active"] is True, body)
        check("the relay's counters come through", body["relay"]["via_v6"] == 31, body)
        check("including the destinations it has stopped bursting at",
              body["relay"]["cooled"] == 4, body)

        built_in = [entry for entry in body["entries"] if entry["built_in"]]
        check("a group's destination is shown alongside the list", len(built_in) == 1, body)
        check("with the counterpart the group gave it",
              built_in[0]["v6"] == "2001:67c:4e8:f002::a", built_in)
        response = await client.delete("/api/bypass/149.154.167.51/32")
        check("and cannot be deleted, only turned off", response.status_code == 409, response.text)
        response = await client.put("/api/bypass/149.154.167.51/32", json={"enabled": False})
        body = response.json()
        check("turning a group's destination off is recorded here", response.status_code == 200, response.text)
        check("so it survives an update",
              any(e["cidr"] == "149.154.167.51/32" and e["enabled"] is False for e in body["entries"]),
              body)

        # In `auto` the redirect is deliberately absent while an exit node is carrying
        # client traffic. That is the normal state, so it must not read as an error.
        publish(bypass=running([], active=False))
        body = (await client.get("/api/bypass")).json()
        check("an idle bypass is not an error", body["config_error"] is None, body)
        check("and says so plainly", body["active"] is False, body)
        check("while the entries stay listed", len(body["entries"]) == 3, body)

        publish(bypass=running([{"cidr": "203.0.113.0/24", "v6": None, "note": None}]) | {
            "error": "the bypass relay is not running, so the redirected destinations are unreachable"
        })
        body = (await client.get("/api/bypass")).json()
        check("a dead relay is reported", "relay is not running" in (body["config_error"] or ""), body)

        response = await client.delete("/api/bypass/203.0.113.0/24")
        check("an entry can be removed", response.status_code == 200, response.text)
        response = await client.delete("/api/bypass/192.0.2.0/24")
        check("removing one that is not there is a 404", response.status_code == 404, response.text)

        # A container older than this feature publishes no bypass key at all.
        publish()
        body = (await client.get("/api/bypass")).json()
        check("an older container reads as not answering", body["live"] is False, body)
        check("without pretending the redirect is up", body["active"] is False, body)

        print("when the environment overrides the bypass list")
        publish(bypass=running([{"cidr": "1.2.3.0/24", "v6": None, "note": None}]) | {"source": "env"})
        body = (await client.get("/api/bypass")).json()
        check("the panel says which one is in charge", "BYPASS_ROUTES" in (body["config_error"] or ""), body)
        response = await client.post("/api/bypass", json={"cidr": ["9.9.9.9"]})
        check("and refuses writes that would not take effect", response.status_code == 409, response.text)

        print("the torrent guard")

        def caught(state: dict | None) -> None:
            """Writes torrents.json the way the node container would, or removes it."""
            if state is None:
                if os.path.exists(settings.torrent_state_file):
                    os.unlink(settings.torrent_state_file)
                return
            with open(settings.torrent_state_file, "w", encoding="utf-8") as handle:
                json.dump({
                    "updated_at": time.time(), "mode": "on", "source": "file",
                    "iface": "awg0", "active": True, "rules": 61,
                    "capabilities": {"string": True, "ipset": True,
                                     "connbytes": True, "comment": True},
                    "blocked": {"total": 0}, "peers": 0, "clients": [], "error": None,
                } | state, handle)

        caught(None)
        body = (await client.get("/api/torrents")).json()
        check("a node that has never been asked forwards torrents", body["enabled"] is False, body)
        check("with the standard mode ready to be chosen", body["mode"] == "on", body)
        check("nothing is claimed about a container that is not answering", body["live"] is False, body)
        check("and that is not an error in itself", body["config_error"] is None, body)

        response = await client.put("/api/torrents", json={"enabled": True})
        check("the guard can be switched on", response.status_code == 200, response.text)
        check("and it comes back on", response.json()["enabled"] is True, response.text)
        with open(settings.torrent_registry_file, encoding="utf-8") as handle:
            written = json.load(handle)
        check("the file is the shape the container parses", written == {"enabled": True, "mode": "on"}, written)

        response = await client.put("/api/torrents", json={"mode": "strict"})
        check("the dial moves on its own", response.json()["mode"] == "strict", response.text)
        check("without turning the switch off", response.json()["enabled"] is True, response.text)

        # The switch and the dial are separate controls precisely so that this does
        # not silently drop an operator back to the standard mode.
        response = await client.put("/api/torrents", json={"enabled": False})
        check("switching off keeps the mode that was chosen", response.json()["mode"] == "strict", response.text)
        check("while the guard is down", response.json()["enabled"] is False, response.text)
        await client.put("/api/torrents", json={"enabled": True})

        response = await client.put("/api/torrents", json={"mode": "paranoid"})
        check("a mode the container has no rules for is refused", response.status_code == 422, response.text)

        print("what the guard caught")
        session_stub.rows = [
            FakeClient(7, "andrey-laptop", "10.8.0.14/32"),
            FakeClient(9, "spare-phone", "10.8.0.9/32"),
        ]
        caught({
            "mode": "strict", "rules": 61, "peers": 1842,
            "blocked": {"dht": 9100, "utp": 4400, "tracker": 130, "total": 13630},
            "clients": [
                {"address": "10.8.0.14", "packets": 12800, "expires_in": 84000},
                {"address": "10.8.0.99", "packets": 40, "expires_in": 3600},
            ],
        })
        body = (await client.get("/api/torrents")).json()
        check("the container's own reading is published", body["live"] is True, body)
        check("with the mode it is actually running", body["active_mode"] == "strict", body)
        check("and how many rules that took", body["rules"] == 61, body)
        check("the layers are reported one by one", body["blocked"]["dht"] == 9100, body)
        check("the blacklist is a number an operator can read", body["peers"] == 1842, body)
        check("a caught client is named, not just numbered", body["clients"][0]["name"] == "andrey-laptop", body)
        check("with the client the panel can act on", body["clients"][0]["client_id"] == 7, body)
        check("and what it cost them", body["clients"][0]["packets"] == 12800, body)
        # An address with no client behind it is somebody's own device on the
        # subnet, or a client deleted since. It is still worth showing.
        check("an unknown address is still listed", body["clients"][1]["name"] is None, body)
        check("nothing is wrong with any of it", body["config_error"] is None, body)

        print("when the kernel cannot do what was asked")
        caught({"capabilities": {"string": False, "ipset": True, "connbytes": True, "comment": True}})
        body = (await client.get("/api/torrents")).json()
        check("a missing string match is not left to be discovered", "xt_string" in (body["config_error"] or ""), body)
        check("and the panel says what still works", "port rules" in (body["config_error"] or ""), body)

        caught({"error": "the torrent rules are installed but nothing is being sent through them"})
        body = (await client.get("/api/torrents")).json()
        check("a ladder nothing walks through is reported", "nothing is being sent" in (body["config_error"] or ""), body)

        print("when the environment overrides the switch")
        caught({"source": "env", "mode": "strict"})
        body = (await client.get("/api/torrents")).json()
        check("the panel says which one is in charge", "TORRENT_BLOCK" in (body["config_error"] or ""), body)
        response = await client.put("/api/torrents", json={"enabled": False})
        check("and refuses a write that would not take effect", response.status_code == 409, response.text)

        caught(None)
        session_stub.rows = []
        os.unlink(settings.torrent_registry_file)

        print("putting a failed exit node back")

        def uplink(name: str, *, healthy: bool = False, handshake: float | None = None) -> dict:
            """One entry of the node container's view of the cascade.

            A healthy node handshaked a moment ago unless the caller says otherwise.
            The panel reads the two against each other rather than trusting the flag,
            so a test that sets one without the other is not testing a real cascade.
            """
            if handshake is None:
                handshake = time.time() if healthy else 0
            return {
                "name": name, "iface": f"awg-{name}", "address": "10.77.0.2/32",
                "priority": 10, "public_key": "KEY-D", "endpoint": "192.0.2.9:51820",
                "peer_public_key": "PEER", "healthy": healthy, "active": healthy,
                "last_handshake": handshake,
            }

        # A node the panel installed and holds a key for, whose SSH port is closed:
        # every attempt below has to reach the point of dialling it and give up there.
        registry.save_nodes([{
            "name": "eu-down", "endpoint": "192.0.2.9:51820", "public_key": "KEY-D",
            "address": "10.77.0.2/32", "priority": 10, "managed": True,
            "ssh_host": "127.0.0.1", "ssh_port": 1, "ssh_user": "root", "ssh_key": True,
        }])
        publish(nodes=[uplink("eu-down")])
        recovery.forget("eu-down")

        settings.node_recovery_grace_seconds = 600
        check("a node that has only just gone down is left alone", await recovery.sweep() == 0, recovery.state())

        # Nothing else in this file waits, so attempts are due the moment they are
        # considered; the backoff itself is checked below on its own.
        settings.node_recovery_grace_seconds = 0
        settings.node_recovery_interval_seconds = 0
        check("once the grace period is up it is worked on", await recovery.sweep() == 1, recovery.state())
        seen = recovery.state()["eu-down"]
        check("the server is probed before anything is changed", seen["last_action"] == "probe", seen)
        check("and why it could not be reached is kept", "127.0.0.1" in (seen["last_error"] or ""), seen)
        check("one failure is not yet a verdict", seen["blocked"] is None, seen)

        # Two silent probes is a server that is gone rather than restarting, and the
        # useful answer is to stop and say so.
        check("a second probe still runs", await recovery.sweep() == 1, recovery.state())
        seen = recovery.state()["eu-down"]
        check("after which it is left for a human", seen["blocked"] == "unreachable", seen)
        check("saying the machine may no longer exist", seen["attempts"] == 2, seen)
        check("and it is not dialled again", await recovery.sweep() == 0, recovery.state())

        body = (await client.get("/api/nodes")).json()
        reported = body["nodes"][0]["recovery"]
        check("the panel publishes what recovery did", reported["blocked"] == "unreachable", body["nodes"][0])
        check("with how long the node has been down", reported["down_for_seconds"] >= 0, reported)
        check("and how many attempts it took to decide", reported["attempts"] == 2, reported)

        print("recovering one on demand")
        response = await client.post("/api/nodes/eu-down/recover")
        check("an attempt can be asked for", response.status_code == 202, response.text)
        task = await drain(client, response.json()["id"])
        check("it reports rather than failing", task["status"] == "succeeded", task)
        check("having got as far as the server", "127.0.0.1" in json.dumps(task["log"]), task["log"])
        check("and says there is nothing left to try", "VPS" in json.dumps(task["log"]), task["log"])
        check("the node was not touched", task["result"]["healthy"] is False, task)

        response = await client.post("/api/nodes/ghost/recover")
        check("recovering an unknown node is a 404", response.status_code == 404, response.text)

        print("nodes recovery cannot help")
        current = registry.load_nodes()
        registry.find(current, "eu-down").pop("ssh_key")
        registry.save_nodes(current)
        recovery.forget("eu-down")
        check("a node with no key on it is not dialled", await recovery.sweep() == 0, recovery.state())
        seen = recovery.state()["eu-down"]
        check("but the reason is recorded once", seen["blocked"] == "unreachable", seen)
        check("without counting as an attempt", seen["attempts"] == 0, seen)
        check("and it explains what an operator must do", "unattended" in (seen["last_error"] or ""), seen)

        current = registry.load_nodes()
        registry.find(current, "eu-down")["ssh_key"] = True
        registry.save_nodes(current)

        print("when the node container has gone quiet")
        publish(age=3600, nodes=[uplink("eu-down")])
        recovery.forget("eu-down")
        check("an unhealthy reading nobody published is not acted on", await recovery.sweep() == 0, recovery.state())
        check("and nothing is recorded against the node", recovery.state() == {}, recovery.state())

        print("a node that comes back on its own")
        publish(nodes=[uplink("eu-down")])
        await recovery.sweep()
        check("a failing node has a history", "eu-down" in recovery.state(), recovery.state())
        publish(nodes=[uplink("eu-down", healthy=True)])
        check("a healthy one is not worked on", await recovery.sweep() == 0, recovery.state())
        check("and its history is dropped", recovery.state() == {}, recovery.state())
        response = await client.post("/api/nodes/eu-down/recover")
        task = await drain(client, response.json()["id"])
        check("asking anyway does not restart a working node", task["result"]["acted"] is False, task)

        print("an exit node that stopped handshaking hours ago")
        # The failure this exists for: the container's monitor is not evaluating
        # health any more, so the last verdict it wrote stands — healthy, active,
        # and contradicted by the timestamp published beside it.
        recovery.forget("eu-down")
        publish(nodes=[uplink("eu-down", healthy=True, handshake=time.time() - 6 * 3600)])
        body = (await client.get("/api/nodes")).json()
        node = body["nodes"][0]
        check("the container's verdict is not taken at its word", node["healthy"] is False, node)
        check("the node is reported as stalled", node["stalled"] is True, node)
        check("and still as the one traffic is routed to", node["active"] is True, node)
        check("with how long it has been silent", node["handshake_age_seconds"] > 21000, node)

        cascade = await build_cascade_status()
        check("the cascade is not called connected", cascade.connected is False, cascade)
        check("the exit node carrying nothing is named", cascade.node == "eu-down", cascade)
        check("and named as the reason", cascade.stalled is True, cascade)
        check("nothing is counted as a failover target", cascade.nodes_healthy == 0, cascade)

        check("recovery works on it like any other dead node", await recovery.sweep() == 1, recovery.state())
        recovery.forget("eu-down")

        # A single missed keepalive is not an outage: the container keeps a node
        # healthy through CASCADE_FAIL_THRESHOLD bad probes, and the panel is not
        # entitled to fail it over sooner than the container would.
        publish(nodes=[uplink("eu-down", healthy=True, handshake=time.time() - 185)])
        node = (await client.get("/api/nodes")).json()["nodes"][0]
        check("a handshake inside the failover window is left alone", node["healthy"] is True, node)
        check("and the node is not called stalled", node["stalled"] is False, node)

        print("an operator's own repair resets it")
        publish(nodes=[uplink("eu-down")])
        await recovery.sweep()
        await recovery.sweep()
        check("recovery had given up", recovery.state()["eu-down"]["blocked"] == "unreachable", recovery.state())
        response = await client.put("/api/nodes/eu-down", json={"endpoint": "192.0.2.10:51820"})
        check("moving the node to another server is accepted", response.status_code == 200, response.text)
        check("and clears what recovery assumed", recovery.state() == {}, recovery.state())

        registry.save_nodes([])
        publish()

        print("when the panel is not in charge")
        publish(source="env")
        body = (await client.get("/api/nodes")).json()
        check("provisioning is withdrawn", body["provisioning"] is False, body)
        check("with a reason to show", "CASCADE_NODES_JSON" in (body["config_error"] or ""), body)
        response = await client.post("/api/nodes/adopt", json=payload)
        check("and writes are refused", response.status_code == 409, response.text)

    await tasks.shutdown()


asyncio.run(main())
print(f"\n{checks} checks passed")
