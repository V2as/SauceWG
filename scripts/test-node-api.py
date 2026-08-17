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
from app.deps import get_current_admin, get_sudo_admin  # noqa: E402
from app.main import app  # noqa: E402
from app.services.tasks import tasks  # noqa: E402

logging.disable(logging.INFO)


class FakeAdmin:
    username = "ci"
    is_sudo = True
    is_active = True


app.dependency_overrides[get_current_admin] = lambda: FakeAdmin()
app.dependency_overrides[get_sudo_admin] = lambda: FakeAdmin()

workdir = tempfile.mkdtemp(prefix="saucewg-nodes-")
settings.node_registry_file = os.path.join(workdir, "exit-nodes.json")
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


def publish(*, age: float = 0.0, reload_id: str = "0", source: str = "file", nodes=()) -> None:
    """Writes the state file the way the node container would."""
    state = {
        "updated_at": time.time() - age,
        "reload_id": reload_id,
        "source": source,
        "config_error": None,
        "mode": "auto",
        "pinned": None,
        "active": None,
        "killswitch": True,
        "nodes": list(nodes),
    }
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
