# SauceWG — deployment and node management guide

Everything needed to install SauceWG on a bare server, manage it afterwards, and grow
or shrink the cascade — from a shell, from a script, or from a bot.

This file is written to be handed to a *different* project. Nothing here assumes you
have the SauceWG repository checked out: the installer is one self-contained script
fetched over HTTPS, and every command that produces data speaks JSON.

Its companion, [`AWG_USAGE.md`](AWG_USAGE.md), documents the panel's HTTP API for
managing *users*. This file covers *servers*.

---

## 1. The two kinds of server

```
   ┌──────────────────────────┐        ┌──────────────┐
   │  ENTRY NODE              │  awg1  │ EXIT eu-nl   │──► internet
   │  panel · postgres · caddy│────────┤              │
   │  awg0: client tunnels    │  awg2  ├──────────────┤
   │                          │────────┤ EXIT eu-de   │──► internet
   └──────────────────────────┘        └──────────────┘
        ▲                                     ▲
        │ saucewg install                     │ saucewg install-node
```

| | Entry node | Exit node |
| --- | --- | --- |
| Installed with | `saucewg install` | `saucewg install-node` |
| Runs | AmneziaWG, panel, PostgreSQL, Caddy | AmneziaWG only |
| Users connect to it | yes | no — only the entry node dials it |
| Has an API | yes | no — the entry node manages it over SSH |
| How many | one per deployment | as many as you like |

One entry node governs its own cascade. Several entry nodes are several independent
deployments; there is no cross-node coordination inside SauceWG.

The entry node is therefore the master server: adding, inspecting, restarting,
upgrading and removing exit nodes anywhere in the world are all calls to its API
([§5](#5-driving-it-from-a-bot)), and an exit node needs nothing open but SSH and its
AmneziaWG port.

**Requirements for either role:** a 64-bit Linux server with systemd and root access.
Docker is installed by the script if it is missing. Debian, Ubuntu, Fedora, CentOS,
Rocky, Alma, openSUSE, Arch and Alpine are all handled.

---

## 2. Installing

The installer is served straight from GitHub, so a bare server needs nothing but
`curl`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/V2as/SauceWG/main/saucewg.sh) install
```

`install` prepares the host (packages, Docker, IP forwarding, `/dev/net/tun`), writes
`/opt/saucewg/{.env,docker-compose.yml}`, pulls the images, starts everything, waits
for the panel to answer, and prints the URL and the generated admin password.

An exit node is the same shape:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/V2as/SauceWG/main/saucewg.sh) \
  install-node --name eu-nl
```

Both install `saucewg` into `/usr/local/bin`, so from then on the server is driven
with plain `saucewg …` commands.

### 2.1 Non-interactive installs

Everything can be supplied up front, which is what a bot does. `--yes` skips all
confirmations and `--json` turns the last line of stdout into one machine-readable
object:

```bash
curl -fsSL https://raw.githubusercontent.com/V2as/SauceWG/main/saucewg.sh -o /tmp/saucewg.sh
bash /tmp/saucewg.sh --json --yes install \
  --domain panel.example.com \
  --admin-username admin \
  --admin-password 'a-strong-one' \
  --port 443
```

```json
{
  "ok": true,
  "role": "entry",
  "dir": "/opt/saucewg",
  "panel_url": "https://panel.example.com",
  "admin_username": "admin",
  "admin_password": "a-strong-one",
  "endpoint": "203.0.113.7:443",
  "version": "1.3.0"
}
```

Global flags may appear before or after the subcommand, with one exception:
`add-node` owns every argument that follows it, because its payload is also spelled
`--json`. Asking for JSON output there means `saucewg --json add-node --json '{…}'`.

### 2.2 `install` options

| Flag | Default | Meaning |
| --- | --- | --- |
| `--domain HOST` | none | Serve the panel on this hostname over HTTPS with an automatic Let's Encrypt certificate. Without it the panel answers on plain HTTP by IP |
| `--admin-username NAME` | `admin` | Panel administrator |
| `--admin-password PASS` | generated | Printed on completion either way |
| `--port N` | `443` | UDP port clients dial |
| `--subnet CIDR` | `10.8.0.0/24` | Address pool for clients |
| `--uplink-subnet CIDR` | `10.77.0.0/24` | Address pool for cascade uplinks |
| `--endpoint-host HOST` | detected | Public address written into client configs. Set it on a NATed server |
| `--protocol V` | `2.0` | AmneziaWG generation clients connect with — `1.0` (alias `legacy`), `1.5` or `2.0` |
| `--signature NAME` | `quic` | The `I1` disguise on 1.5 and 2.0: `quic`, `dns`, `random`, `short`, `none`, or a literal spec |
| `--http-port N` / `--https-port N` | `80` / `443` | Caddy's listening ports |
| `--no-start` | — | Write the configuration but do not pull or start anything |
| `--reinstall` | — | Overwrite an existing installation in the same directory |

`--protocol` decides what every client profile this panel hands out will contain, so it
is the one flag worth thinking about before the first client is created. 2.0 resists DPI
best; 1.0 is what a router on KeeneticOS 5.0.8 or older can load. It is not a one-way
door — `saucewg set-protocol` changes it afterwards, and existing clients pick the new
profile up when they re-download it.

### 2.3 `install-node` options

| Flag | Default | Meaning |
| --- | --- | --- |
| `--name NAME` | hostname | Identity of this node in the cascade |
| `--port N` | `51820` | UDP port the entry node dials |
| `--subnet CIDR` | `10.77.0.0/24` | Uplink subnet; must match the entry node's `--uplink-subnet` |
| `--peer-key KEY` | — | The entry node's uplink key, if you already have it |
| `--psk KEY` / `--psk-stdin` | — | Optional pre-shared key. `--psk-stdin` reads it from stdin so it never appears in `ps` |
| `--endpoint-host HOST` | detected | Address the entry node should dial |
| `--protocol V` | `2.0` | AmneziaWG generation this uplink speaks — `1.0` (alias `legacy`), `1.5` or `2.0` |
| `--signature NAME` | `quic` | The `I1` disguise on 1.5 and 2.0 |
| `--no-start` | — | Configure without starting |
| `--reinstall` | — | Overwrite an existing installation |

An uplink's generation is independent of what the entry node serves its clients: the two
ends of the uplink have to agree with each other, and nothing else. Both ends are
configured from the object below, so agreeing is automatic — but a node whose `--protocol`
was set by hand on one end only will come up and never handshake.

On success it prints the object the entry node needs:

```json
{
  "name": "eu-nl",
  "endpoint": "198.51.100.20:51820",
  "public_key": "kQ3…=",
  "port": 51820,
  "protocol": "2.0",
  "s1": 96, "s2": 40, "s3": 31, "s4": 12,
  "h1": 1191142, "h2": 1298237, "h3": 1758452, "h4": 1854913,
  "i1": "<b 0xc30000000108><r 8><b 0x08><r 8><b 0x0045dc><t><r 16>"
}
```

`s3`, `s4` and `i1` are absent on a 1.0 node and `s3`/`s4` on a 1.5 one, since carrying
a parameter is what defines the generation. Pass the whole object to `add-node` rather
than picking fields out of it and the entry node ends up on the same generation by
construction.

### 2.4 Pinning versions and mirrors

Every knob is an environment variable, so a fleet can be pinned to a known-good
release:

| Variable | Default | Purpose |
| --- | --- | --- |
| `SAUCEWG_TAG` | `latest` | Image tag to install (also `--tag`) |
| `SAUCEWG_REGISTRY` | `docker.io` | Registry host (also `--registry`) |
| `SAUCEWG_NAMESPACE` | `v2as` | Image namespace (also `--namespace`) |
| `SAUCEWG_IMAGE_PREFIX` | `saucewg-` | Image name prefix |
| `SAUCEWG_DIR` | `/opt/saucewg` | Installation directory (also `--dir`) |
| `SAUCEWG_CLI_PATH` | `/usr/local/bin/saucewg` | Where the CLI installs itself |
| `SAUCEWG_REPO` / `SAUCEWG_REF` | `V2as/SauceWG` / `main` | Where the script fetches itself from |
| `NO_COLOR` | — | Any value disables ANSI colour |

```bash
SAUCEWG_TAG=1.3.0 bash /tmp/saucewg.sh --json --yes install --domain panel.example.com
```

`--dir` also means several deployments can share one server for testing; each is a
separate directory with its own compose project.

---

## 3. Running the server

Once installed, the whole server is managed with one command. This is the Marzban-like
surface, available on both roles:

| Command | What it does |
| --- | --- |
| `saucewg start` | Start every container (alias `up`) |
| `saucewg stop` | Stop every container (alias `down`) |
| `saucewg restart` | Recreate every container |
| `saucewg status` | Role, directory and container states (alias `ps`) |
| `saucewg logs [-f] [-n N] [service]` | Container logs; services are `awg`, `panel`, `postgres`, `caddy` |
| `saucewg shell [service]` | A shell inside a container — `panel` by default on an entry node, `awg` on an exit node |
| `saucewg edit` | Open `.env` in `$EDITOR` and offer to restart |
| `saucewg update [--tag T]` | Pull newer images, regenerate the compose file, restart |
| `saucewg uninstall [--purge]` | Remove containers and volumes; `--purge` also deletes the directory and the CLI |
| `saucewg info` | Machine-readable status — always JSON, whatever the flags |
| `saucewg protocol` | Which AmneziaWG generation this node serves, and what it is carrying |
| `saucewg set-protocol V [--signature N]` | Move it to another generation and restart the node container |
| `saucewg signatures` | The `I1` presets, with what each one imitates |
| `saucewg version` | CLI version |

`saucewg update` also replaces `/usr/local/bin/saucewg` with the current script and
adds any settings a new release introduced to `.env`, so an old installation keeps
working after an upgrade.

`saucewg info` is the health endpoint for a monitoring system:

```json
{
  "cli_version": "1.3.0",
  "role": "entry",
  "dir": "/opt/saucewg",
  "endpoint": "203.0.113.7:443",
  "panel_url": "https://panel.example.com",
  "containers": [
    {"name": "panel", "state": "running", "status": "Up 6 days (healthy)"},
    {"name": "awg", "state": "running", "status": "Up 6 days"}
  ],
  "cascade": { "mode": "auto", "active": "eu-nl", "nodes": [ … ] }
}
```

`cascade` is `null` on an exit node, and on an entry node whose node container is
down — which is itself the signal that something is wrong.

### Recovering panel access

```bash
saucewg admin-password                      # reset to a fresh generated password
saucewg admin-password --username ops --password 'new-one'
```

It updates the account in PostgreSQL *and* `.env`, and invalidates every token that
account had issued.

---

## 4. Adding and removing exit nodes

There are three ways to do it. They all end up writing the same file, so they can be
mixed freely.

### 4.1 From the panel (what an operator sees)

**Exit nodes → Add exit node**, then fill in a name, the server's IP and its root
password. The panel connects over SSH, installs everything, joins the node to the
cascade, exchanges keys, and waits for the first handshake — streaming the log into
the dialog as it goes. Removing a node offers the same in reverse, with a checkbox for
wiping the software off the server.

The root password is used for that one operation and never stored. What *is* stored is
the server's SSH host key, so a later repair can prove it is the same machine — and
what is left behind on the server is the panel's own public key, so nothing after the
install asks for a password again. The **⚙** button on each node uses it: remote
status, logs, restart and upgrade, without a shell.

### 4.2 From the API (what a bot uses)

See [§5](#5-driving-it-from-a-bot). Same code path as the UI.

### 4.3 From the shell (two commands, two servers)

```bash
# On the new exit server
saucewg --json install-node --name eu-fr
# → {"name":"eu-fr","endpoint":"203.0.113.9:51820","public_key":"…", …}

# On the entry server: paste that object
saucewg add-node --json '{"name":"eu-fr","endpoint":"203.0.113.9:51820","public_key":"…"}'
# → prints the entry node's uplink key for the new slot

# Back on the exit server
saucewg node-pair --peer-key '<the uplink key>'
```

| Command | Purpose |
| --- | --- |
| `saucewg nodes` | The cascade with health and which node is active (alias `list-nodes`) |
| `saucewg add-node --json '{…}'` | Add a node. Accepts `-` to read the object from stdin |
| `saucewg add-node --name … --endpoint … --public-key …` | The same, without composing JSON |
| `saucewg update-node NAME [--protocol V] [--priority N] …` | Change an existing entry in place |
| `saucewg remove-node NAME` | Remove a node from the cascade |
| `saucewg uplink-key [NAME]` | The entry node's public key for one uplink, or all of them |
| `saucewg reload` | Re-read the node list without restarting anything |
| `saucewg node-info` | *(exit node)* Print this node's pairing object again |
| `saucewg node-pair --peer-key K` | *(exit node)* Install the entry node's uplink key |

`add-node`, `update-node` and `remove-node` all take `--no-reload` when you want to make
several changes and apply them once with `saucewg reload`.

`add-node` allocates the uplink address and the failover priority itself: a new node is
appended *below* every existing one, so adding a node never moves live traffic. Pass
`--address` or `--priority` to override.

Moving an existing uplink to another generation is the same two-server dance as adding
one, because both ends have to change together:

```bash
# On the exit server — reconfigures it and prints its new pairing object
saucewg --json set-protocol 2.0

# On the entry server — paste that object; it already carries the new parameters
saucewg update-node --json '{"name":"eu-fr","protocol":"2.0","s3":31,"s4":12,"i1":"…"}'
```

`set-protocol` keeps the padding and headers the two ends already agreed on, so the
uplink is not rekeyed — only the parameters the new generation adds or drops move.
Individual flags (`--protocol`, `--s3`, `--i1`, `--priority`, `--endpoint`) work too when
you only need one of them. On a `managed` node, `POST /api/nodes/{name}/protocol` does
both halves in one call instead.

### 4.4 What actually happens underneath

`config/exit-nodes.json` in the installation directory is the single source of truth.
The node container reads it, the panel writes it, and the CLI edits it.

Changing it does **not** restart anything. The writer drops a reload request next to
the container's state file; the container picks it up within a second, rebuilds only
the interfaces whose configuration actually changed, and echoes the request id back
once it is done. Uplink interface numbers are pinned per node name, so removing one
node never renumbers the others.

Connected users are unaffected by any of this unless the node carrying their traffic is
the one being removed, in which case they fail over.

---

## 5. Driving it from a bot

The panel's HTTP API is the right integration point for anything user-facing: it does
the SSH work for you, reports progress, and enforces one operation per node at a time.
One entry node is the master: everything below is addressed to it, and it is the only
server the bot ever talks to.

Authenticate as described in [`AWG_USAGE.md` §2](AWG_USAGE.md#2-authentication) and
send `Authorization: Bearer <token>` on everything below.

**Anything that changes the cascade or touches an exit server needs a sudo admin** —
installing, adopting, updating, removing, repairing, restarting, upgrading a node, and
reading its status or logs. Reading the cascade and steering failover (`activate`,
`auto`) work with any admin token.

### 5.1 The panel's SSH key

```http
GET /api/nodes/ssh-key
```

```json
{
  "public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI… saucewg-panel",
  "fingerprint": "SHA256:9r4Tz…",
  "created_at": "2026-08-14T15:04:11Z",
  "enabled": true
}
```

The panel keeps one Ed25519 key pair of its own, generated the first time this is
read. It enrols the public half on every node it installs, and uses it for everything
afterwards — so **a root password is needed at most once per server, and often not at
all**:

* Create the European VPS with this public key in the provider's *SSH keys* field (or
  through cloud-init), then `POST /api/nodes` with no credentials in the body.
* Or pass a password once, at install time. The key is enrolled during that install and
  every later call — status, logs, restart, upgrade, repair, uninstall — needs nothing.

A node that has it reports `"ssh_key": true` in `GET /api/nodes`. Supplying credentials
to any call always re-enrols the key, which is also how a node installed before this
existed is brought forward: run one `repair` with a password.

The private half lives at `NODE_SSH_KEY_FILE`, mode `0600`, in the same bind-mounted
directory as `exit-nodes.json` — back them up together. Losing it costs one password
per node, not the nodes. `NODE_SSH_KEY_ENABLED=false` turns the whole mechanism off,
and then `enabled` is `false` and every call carries credentials as before.

### 5.2 Check a server first

```http
POST /api/nodes/check
```

```json
{ "host": "203.0.113.9", "ssh_password": "…" }
```

One SSH session that changes nothing, so a wrong password or a server that cannot act
as root fails in a second rather than four minutes into an install. `ssh_password` may
be omitted when the panel's key is already on the machine.

```json
{
  "reachable": true, "root": true, "used_panel_key": true,
  "os": "Debian GNU/Linux 12 (bookworm)", "kernel": "Linux 6.1.0-18-amd64",
  "arch": "x86_64", "cpus": 2, "memory_mb": 1966, "disk_free_mb": 18234,
  "uptime_seconds": 421, "docker": false, "saucewg": false, "role": null,
  "host_key": "ssh-ed25519 AAAA…", "error": null
}
```

An unreachable server is a `200` with `reachable: false` and a sentence in `error`,
not an HTTP error: not being able to connect is the answer to the question, not a
failure to answer it. `saucewg: true` means something is already installed there and
an install would reconfigure it.

### 5.3 Install an exit node

```http
POST /api/nodes
```

```json
{
  "name": "eu-fr",
  "host": "203.0.113.9",
  "ssh_password": "…",
  "port": 51820
}
```

| Field | Default | Meaning |
| --- | --- | --- |
| `name` | required | `^[A-Za-z0-9][A-Za-z0-9._-]*$`, unique, and permanent — renaming later regenerates keys |
| `host` | required | IP or hostname of the server to install on |
| `ssh_password` | — | Root password. Omit it, with `ssh_private_key`, on a server that already carries the panel's key ([§5.1](#51-the-panels-ssh-key)) |
| `ssh_private_key` | — | OpenSSH private key as text; use instead of a password |
| `ssh_port` / `ssh_user` | `22` / `root` | A non-root user needs passwordless sudo |
| `port` | `51820` | UDP port the exit node listens on |
| `subnet` | `10.77.0.0/24` | Uplink subnet on the exit node |
| `priority` | appended last | Lower wins |
| `address` | allocated | Uplink address on the entry side |
| `preshared_key` | — | Extra symmetric key on this uplink |
| `protocol` | `2.0` | AmneziaWG generation for this uplink — `1.0` (alias `legacy`), `1.5` or `2.0` |
| `signature` | `quic` | The `I1` disguise on 1.5 and 2.0 |
| `note` | — | Free text, carried through to `GET /api/nodes` |

The response is `202 Accepted` with a **task**, because a cold install takes minutes:

```json
{
  "id": "9f1c0e24b7a3416d8e5c2a71d0b93f84",
  "action": "install",
  "target": "eu-fr",
  "status": "pending",
  "step": "",
  "error": null,
  "result": null,
  "created_at": "2026-08-14T15:04:11Z",
  "finished_at": null,
  "log": []
}
```

The work starts the moment the response is written, so the first poll a fraction of a
second later already shows `running` and a populated log.

### 5.4 Follow the task

```http
GET /api/nodes/tasks/{id}
```

`status` is `running`, `succeeded` or `failed`. Poll every second or two; `log` is
cumulative, so a bot can edit one message in place with the tail of it. On success
`result` holds the outcome:

```json
{
  "name": "eu-fr",
  "endpoint": "203.0.113.9:51820",
  "address": "10.77.0.4/32",
  "priority": 40,
  "protocol": "2.0",
  "uplink_public_key": "Lkug…=",
  "ssh_key": true,
  "healthy": true
}
```

`ssh_key: true` says the panel can reach that server again on its own, which is what
lets every call in [§5.6](#56-managing-the-servers-themselves) go out with an empty
body.

`healthy: false` is not an error — the node is installed and in the cascade but has not
handshaked yet, which almost always means UDP to that port is blocked upstream. Report
it as a warning and let the operator check the provider's firewall.

On failure, `error` is a sentence written to be shown to a human ("could not connect to
root@203.0.113.9:22: Permission denied"). The steps are ordered so that a failure
before *Joining the cascade* leaves nothing behind.

`GET /api/nodes/tasks?limit=20` lists recent tasks, which survives a bot restart
mid-install.

### 5.5 Editing the cascade

| Call | Body | Result |
| --- | --- | --- |
| `GET /api/nodes` | — | The cascade. `provisioning: false` means this panel cannot edit it |
| `POST /api/nodes/adopt` | the object from `saucewg install-node --json` | `201` — registers a node installed by hand, no SSH |
| `PUT /api/nodes/{name}` | `{"priority": 5}`, `{"endpoint": "…"}`, `{"note": "…"}`, `{"protocol": "1.0"}` | Applied immediately; a priority change is only a routing decision |
| `DELETE /api/nodes/{name}` | `{}` or `{"uninstall": true}` | `202` + task. Without `uninstall` the server is left running and simply detached |
| `POST /api/nodes/{name}/repair` | `{}` | `202` + task. Reinstalls the uplink key on a node that shows as unpaired |
| `POST /api/nodes/{name}/protocol` | `{"protocol": "2.0", "signature": "quic"}` | `202` + task. Reconfigures both ends of the uplink |
| `POST /api/nodes/{name}/activate` | — | Prefer this node |
| `POST /api/nodes/auto` | — | Drop the preference |

`PUT` and `POST …/protocol` both change a generation, and the difference matters. `PUT`
edits the entry node's side of the uplink only — use it when the exit node was already
moved by hand, and expect the tunnel to be down until both ends agree. `POST …/protocol`
reconfigures the exit node over SSH first and then the entry side, so the uplink comes
back on its own; it only works on a `managed` node.

Every call that touches the server accepts `ssh_password` or `ssh_private_key` as well,
and needs one when the node does not carry the panel's key.

`DELETE … {"uninstall": true}` also takes the panel's key back off the server. Pass
`{"revoke_key": false}` to leave it there, which is what you want when the machine is
being rebuilt rather than handed back.

### 5.6 Managing the servers themselves

The calls above change the cascade. These change the exit server behind a node, and
none of them need credentials once it carries the panel's key.

| Call | Body | Result |
| --- | --- | --- |
| `GET /api/nodes/{name}/status` | — | What the server says about itself, live over SSH |
| `GET /api/nodes/{name}/logs?service=awg&lines=200` | — | The tail of its container logs |
| `POST /api/nodes/{name}/restart` | `{}` | `202` + task. Recreates its containers and waits for the uplink to come back |
| `POST /api/nodes/{name}/stop` | `{}` | `202` + task. The cascade fails over to the next healthy node |
| `POST /api/nodes/{name}/start` | `{}` | `202` + task |
| `POST /api/nodes/{name}/upgrade` | `{}` or `{"tag": "1.4.0"}` | `202` + task. Pulls newer images and recreates. Minutes, like an install |

```json
{
  "name": "eu-fr", "reachable": true, "error": null, "ssh_host": "203.0.113.9",
  "role": "exit", "cli_version": "1.3.0", "dir": "/opt/saucewg",
  "os": "Debian GNU/Linux 12 (bookworm)", "kernel": "Linux 6.1.0-18-amd64",
  "arch": "x86_64", "cpus": 2, "memory_mb": 1966, "disk_free_mb": 17980,
  "uptime_seconds": 934221, "docker": true, "saucewg": true,
  "containers": [{"name": "awg", "state": "running", "status": "Up 10 days"}]
}
```

`status` is the other half of `GET /api/nodes`: that one reports the uplink as the
entry node sees it, this one reports the machine. A node that is `healthy: false` in
the cascade but `reachable: true` here with its container `running` is a network
problem between the two servers, not a dead server — which is the distinction that
decides whether to restart anything. An unreachable server is again a `200` with
`reachable: false` rather than an error.

`upgrade` pins the node to the same registry, namespace and tag as the panel unless
`tag` says otherwise, so a fleet moves together instead of drifting one server at a
time.

### 5.7 What a node reports

Each node in `GET /api/nodes` carries, on top of the health fields documented in
[`AWG_USAGE.md` §6](AWG_USAGE.md#6-exit-nodes-and-failover):

| Field | Meaning |
| --- | --- |
| `managed` | The panel installed this node and can reach it over SSH again |
| `ssh_host`, `ssh_port`, `ssh_user` | How it reaches it. `null` on an adopted node |
| `ssh_key` | The panel's key is on that server, so calls about it need no credentials |
| `protocol` | The AmneziaWG generation this uplink speaks |
| `created_at` | When it joined the cascade |
| `task_id` | Set while an operation on this node is still running |

and at the top level `config_error`: a complete sentence, safe to show to a human,
explaining why the cascade is not what the panel thinks it is. It is `null` when all is
well, and non-null when the node container refused the list or when `CASCADE_NODES_JSON`
is overriding the file the panel writes.

### 5.8 Status codes worth handling

| Code | When |
| --- | --- |
| `409` | The name already exists, another task for that node is still running (`task_id` tells you which), or the cascade is not the panel's to edit (`CASCADE_NODES_JSON` is set) |
| `422` | No way in — neither credentials nor the panel's key — or a node with no SSH address at all, which cannot be repaired, wiped or managed |
| `403` | `NODE_PROVISION_ENABLED=false`, or the token is not a sudo admin |
| `502` / `504` | The exit server refused or did not answer a log request in time |
| `503` | The panel cannot read or write `config/exit-nodes.json` — usually `./config` mounted read-only |

Restarting, upgrading, reading status and reading logs keep working when
`CASCADE_NODES_JSON` is set: they manage a server rather than edit the list, so only
`NODE_PROVISION_ENABLED=false` turns them off.

### 5.9 A European node, end to end

Adding an exit node in another country is three calls to the master panel and no
shell anywhere:

```python
import time, requests

PANEL = "https://panel.example.com"
token = requests.post(
    f"{PANEL}/api/admin/token",
    data={"username": "admin", "password": "…"},
).json()["access_token"]
head = {"Authorization": f"Bearer {token}"}

# 1. The key to put in the provider's "SSH keys" box when creating the VPS. Do this
#    once; it is the same key for every node this panel will ever manage.
key = requests.get(f"{PANEL}/api/nodes/ssh-key", headers=head).json()
print(key["public_key"])

# 2. …create the server at the provider, with that key…

# 3. Look before leaping: wrong address or a firewalled port fails here in a second.
probe = requests.post(
    f"{PANEL}/api/nodes/check", headers=head, json={"host": "203.0.113.9"}
).json()
assert probe["reachable"] and probe["root"], probe["error"]

# 4. Install it. No password anywhere: the panel logs in with its own key.
task = requests.post(
    f"{PANEL}/api/nodes", headers=head,
    json={"name": "eu-fr", "host": "203.0.113.9", "protocol": "2.0"},
).json()

while task["status"] not in ("succeeded", "failed"):
    time.sleep(2)
    task = requests.get(f"{PANEL}/api/nodes/tasks/{task['id']}", headers=head).json()
    print(task["step"])

print(task["result"] if task["status"] == "succeeded" else task["error"])
```

From then on the same token restarts it, upgrades it, reads its logs and removes it,
all against the one master server. If the provider offers no key field, pass
`"ssh_password"` to step 4 and it is the last time that password is used: the install
enrols the key on the way through.

### 5.10 Installing servers instead of using an existing panel

To have a bot stand up whole *servers*, drive the script over SSH and read its JSON.
The panel does exactly this; there is nothing privileged about it:

```python
import asyncio, asyncssh, json

INSTALL = (
    "curl -fsSL https://raw.githubusercontent.com/V2as/SauceWG/main/saucewg.sh"
    " -o /usr/local/bin/saucewg && chmod 0755 /usr/local/bin/saucewg"
)

async def install_entry(host: str, password: str, domain: str) -> dict:
    async with asyncssh.connect(host, username="root", password=password,
                                known_hosts=None) as conn:
        await conn.run(INSTALL, check=True)
        result = await conn.run(
            f"/usr/local/bin/saucewg --json --yes install --domain {domain}",
            check=True,
        )
        # Progress goes to stderr, the object to stdout.
        return json.loads(result.stdout)

print(asyncio.run(install_entry("203.0.113.7", "…", "panel.example.com")))
```

Three properties make this safe to automate:

* **stdout is data, stderr is progress.** Parsing never has to skip log lines.
* **Every command is idempotent enough to retry.** A second `install` refuses unless
  `--reinstall` is passed; `add-node` refuses a duplicate name; `install-node` on an
  already-installed server reuses the configuration instead of regenerating keys.
* **Nothing prompts** under `--yes`, and a command that would have prompted without a
  terminal fails loudly rather than hanging.

Budget generously: a cold install on a small VPS is 2–5 minutes, most of it pulling
images.

---

## 6. Files on the server

| Path | What it is |
| --- | --- |
| `/opt/saucewg/.env` | Every setting. Edit with `saucewg edit`, or by hand followed by `saucewg restart` |
| `/opt/saucewg/docker-compose.yml` | Generated; regenerated on every `saucewg update` |
| `/opt/saucewg/config/exit-nodes.json` | The cascade. Written by the panel and the CLI |
| `/opt/saucewg/config/panel-ssh-key` | The panel's SSH identity, mode `0600`, with its `.pub` beside it |
| `/opt/saucewg/.role` | `entry` or `exit` |
| `/usr/local/bin/saucewg` | The CLI, which is a copy of the installer |
| `/etc/sysctl.d/99-saucewg.conf` | IP forwarding |

Docker volumes hold the AmneziaWG keys (`awg-config`), the database (`postgres-data`)
and Caddy's certificates. `saucewg uninstall` removes them; back up `.env`, the whole
of `config/` and the `awg-config` volume before rebuilding a server if you want the
same keys back — `config/` is both the cascade and the key that reaches it.

Settings that matter for node management specifically:

| Variable | Default | Purpose |
| --- | --- | --- |
| `NODE_PROVISION_ENABLED` | `true` | `false` makes the panel read-only with respect to the cascade — set it when the node list is owned by configuration management |
| `NODE_REGISTRY_FILE` | `/etc/saucewg/host/exit-nodes.json` | Where the panel sees the list *inside its container* |
| `NODE_SSH_KEY_FILE` | `/etc/saucewg/host/panel-ssh-key` | The panel's own SSH key, generated on first use |
| `NODE_SSH_KEY_ENABLED` | `true` | `false` stops the panel keeping a key, so every call carries credentials |
| `NODE_SSH_TIMEOUT_SECONDS` | `900` | Ceiling for one remote command |
| `NODE_SSH_QUERY_TIMEOUT_SECONDS` | `60` | Ceiling for the calls that answer inside one request: `check`, `status`, `logs` |
| `NODE_DEFAULT_PORT` | `51820` | Default offered in the UI |
| `SAUCEWG_TAG`, `SAUCEWG_REPO`, `SAUCEWG_REF` | | Pin what the panel installs on, and upgrades, new nodes to |

---

## 7. Things that will surprise you

* **`add-node` owns the flags after it.** `saucewg --json add-node --json '{…}'` reads
  correctly: the first asks for JSON output, the second is the payload. Every other
  command takes global flags on either side.
* **A node's name is its identity.** Uplink keys are stored per name, so renaming a
  node in `exit-nodes.json` generates a new key pair and breaks its pairing until the
  new key is installed on the exit server.
* **The panel's SSH key is a root key for every node it installed.** That is the point
  of it — one master server managing a fleet — but it means `config/panel-ssh-key` is
  as sensitive as the root passwords it replaces, and anyone with a sudo admin token
  can act on every exit server through the API. Removing a node with
  `{"uninstall": true}` takes the key back off that server; `NODE_SSH_KEY_ENABLED=false`
  opts out of the whole mechanism.
* **`s1`–`s4` and `h1`–`h4` must match on both ends** of an uplink, and each uplink
  should use a different set. `install-node` generates them and `add-node` carries them
  across, so this only bites when the object is assembled by hand. `jc`/`jmin`/`jmax` and
  `i1`–`i5` are built by the sender and never parsed, so those may differ freely.
* **A generation is a set of parameters, not a version number.** Nothing on the wire says
  "2.0" — a profile *is* 2.0 because it carries `S3`, `S4` and `I1`. That is why moving a
  node between generations adds and drops parameters rather than setting a field, and why
  a hand-edited profile with a stray `S3` will not connect to a 1.0 peer.
* **`set-protocol` on an exit node only does its own half.** It prints the pairing object
  precisely because the entry node still has to be told; until `update-node` runs there,
  that uplink is down. `POST /api/nodes/{name}/protocol` avoids the window.
* **A client-facing 2.0 interface pads by zero.** The AmneziaVPN app does not pass
  non-zero `S3`/`S4` to its own backend
  ([bug](https://github.com/amnezia-vpn/amnezia-client/issues/2582)), so it never strips
  the padding the server adds and the tunnel connects while carrying nothing. `install`
  and `set-protocol` therefore leave both at `0` on an entry node, while an exit node's
  own interface — which only ever faces the entry node's `amneziawg-go` — gets real
  padding. Pin `AWG_S3`/`AWG_S4` in `.env` if every client you serve is a router.
* **Non-zero `S3`/`S4` on the entry node make a generation change disconnect everyone.**
  The padding changes every transport packet, so a peer that does not expect it cannot
  read one, and each client has to re-import its config or re-fetch its subscription
  link. With the default zero padding the generations differ only in `I1`, which the
  receiver never parses, so already-issued profiles keep working — re-export them anyway
  so they declare the generation the node is actually on. `set-protocol` confirms before
  touching an entry node either way, and does not bother on an exit node.
* **The uplink address must be inside the exit node's `--subnet`.** The defaults
  (`10.77.0.0/24` everywhere, `.2`, `.3`, `.4`… on the entry side) satisfy this.
* **A priority pin is a preference, not a lock.** The cascade still fails over away
  from a pinned node that dies, and returns when it recovers.
* **Removing a node does not touch the server** unless you ask for `uninstall`. This is
  deliberate: a node is often removed *because* its server is already unreachable.
* **`saucewg` on an exit node has no panel commands** and will say so rather than
  guessing; `saucewg status` and `saucewg logs` work everywhere.
