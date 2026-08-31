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
| `SAUCEWG_RAW_BASE` | derived from the two above | The same, for a mirror that is not GitHub |
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
| `saucewg routes` | *(entry node)* Destinations that bypass the cascade — see §4.5 |
| `saucewg fallback [direct\|block]` | *(entry node)* What happens while every exit node is down — see §4.6 |
| `saucewg bypass` | *(entry node)* Destinations this node reopens for itself — see §4.7 |
| `saucewg torrents [on\|strict\|off]` | Whether BitTorrent is blocked in what this node forwards — see §4.8 |
| `saucewg recover [NAME…]` | *(entry node)* Try to put failed exit nodes back — see §4.9 |
| `saucewg protocol` | Which AmneziaWG generation this node serves, and what it is carrying |
| `saucewg set-protocol V [--signature N]` | Move it to another generation and restart the node container |
| `saucewg signatures` | The `I1` presets, with what each one imitates |
| `saucewg version` | CLI version |

`saucewg update` also adds any settings a new release introduced to `.env`, so an old
installation keeps working after an upgrade. Those settings, and the compose file, are
written by the script rather than by the images, so an update that pulled newer images
with an older script would configure them the way the previous release did. To avoid
that, `update` first replaces `/usr/local/bin/saucewg` with the copy published at
`SAUCEWG_REF` and re-runs the same command with it — the version it moves to is printed
before anything else happens.

Whatever the mirror publishes is what gets installed, downgrade included: a fleet pinned
with `SAUCEWG_REF` is asking for that ref. If the mirror cannot be reached, or serves
something that is not this script, the update carries on with the CLI already installed
rather than stopping.

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

## 4. The cascade: exit nodes and routing

Exit nodes can be added and removed in three ways. They all end up writing the same
file, so they can be mixed freely. Which destinations use the cascade at all (§4.5),
what happens when none of it is available (§4.6), which destinations this node reopens
for itself (§4.7) and what is done about a node that has failed (§4.9) are all set on
the entry node. Whether BitTorrent is carried at all (§4.8) is set on every node
separately, because either end can be the address a swarm sees.

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

### 4.5 Routing past the cascade

Some destinations are better off leaving through the entry node itself: a service that
refuses a foreign address, one that is only fast from the entry node's country, or one
you would rather not carry abroad. Listing a prefix takes it off the cascade; everything
else still goes to the active exit node.

```bash
saucewg routes                                       # with which ones are in effect
saucewg add-route 142.250.0.0/15 --note youtube      # a range
saucewg add-route 8.8.8.8                            # a single host
saucewg add-route --from-file ranges.txt --note youtube
saucewg remove-route 8.8.8.8
saucewg remove-route --note youtube                  # the whole group
```

| Command | Purpose |
| --- | --- |
| `saucewg routes` | The direct route list, and whether each entry is actually installed (alias `list-routes`) |
| `saucewg add-route CIDR…` | Route one or more destinations through this entry node |
| `saucewg add-route --from-file PATH` | The same, reading one prefix per line; `#` comments and blank lines are ignored |
| `saucewg remove-route CIDR…` | Put those destinations back on the cascade |
| `saucewg remove-route --note GROUP` | Remove every route carrying that label |

Both take `--note` to label a group and `--no-reload` to batch several edits, exactly
like the node commands. `saucewg routes` prints what the node container actually
installed, so a prefix that stays `pending` is one it could not apply:

```
PREFIX           STATUS   NOTE
142.250.0.0/15   direct   youtube
64.233.160.0/19  direct   youtube
8.8.8.8/32       pending  dns
198.51.100.0/24  off      paused
```

`direct` is in the routing table, `pending` is listed but not installed, `off` is
`enabled: false`, and `unknown` means the node container is not answering, so nothing
about the routing table is known either way.

A bare address means one host, and an address inside a range is stored as the range —
`10.20.30.40/24` becomes `10.20.30.0/24`, which is what it means and what the kernel
will accept. Names are never resolved: add the ranges a service actually uses.
`0.0.0.0/0` is refused, because taking every destination off the cascade is §4.6 rather
than a route.

Underneath, `config/direct-routes.json` is the source of truth, in the same directory
and with the same live-reload behaviour as the exit node list. It accepts bare strings
as well as objects:

```json
[
  "1.1.1.1",
  { "cidr": "142.250.0.0/15", "note": "youtube", "enabled": true },
  { "cidr": "198.51.100.0/24", "note": "kept but not routed", "enabled": false }
]
```

Each enabled prefix becomes one route in policy table `450`, which the entry node
consults before the cascade table, and traffic leaving that way is NATed to the entry
node's own address. Nothing changes on the client. `CASCADE_DIRECT_ROUTES` in `.env`
puts the list in the environment instead, which overrides the file and makes the panel's
**Routing** page read-only.

### 4.6 When every exit node is down

`CASCADE_FALLBACK` decides what a client experiences while no uplink is usable:

```bash
saucewg fallback           # what is configured, and whether it is in use right now
saucewg fallback direct    # keep clients online through this entry node (the default)
saucewg fallback block     # drop their traffic instead
```

| Mode | While no exit node is usable |
| --- | --- |
| `direct` | the entry node carries client traffic; users stay online, from its address |
| `block` | client traffic is dropped, which is what `CASCADE_KILLSWITCH=true` used to do |

It reverts on its own: the moment an uplink passes its health check again, traffic moves
back onto the cascade without touching a tunnel. Changing the mode recreates the node
container, so connected clients reconnect within a few seconds; `--no-restart` writes
the value and leaves that for later.

`direct` is the default because a reachable entry node is more useful than a silent one,
but during an outage a client's traffic does appear from the entry node's address —
choose `block` where that is the thing being avoided.

An installation from before this existed keeps its old behaviour until `saucewg update`,
which writes `CASCADE_FALLBACK=direct` into `.env` and prints a note saying so. Setting
it beforehand, by hand or with `saucewg fallback`, is respected and left alone.

The migration is part of the script, not of the images. A CLI from before it existed
does not perform it and leaves `CASCADE_FALLBACK` out of the compose file entirely, so
the node reads the `CASCADE_KILLSWITCH=true` the old installer wrote and blocks — which
looks exactly like an update that did nothing. `update` now replaces the CLI before it
does anything else (§3), but a server updated by an older one needs it handed over
directly:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/V2as/SauceWG/main/saucewg.sh) update
```

`saucewg fallback` reports what the node actually resolved, so it is the quickest way to
tell which of the two happened.

### 4.7 Destinations this node reopens for itself

§4.5 chooses which way out a destination takes. Some destinations cannot be reached by
any way out: the outbound TCP handshake to their IPv4 is dropped, so nothing connects,
while DNS resolves, ICMP is answered and anything already established keeps running. A
route does not help — the packets leave by another interface and are dropped the same
way — so the entry node opens the outbound half itself.

Telegram from a Russian hosting segment is the case this was built for. On a live entry
node in Moscow: the datacentre addresses resolve correctly, ICMP to them is answered, and
9 IPv4 SYNs in 10 to port 443 get no reply at all. The same datacentres over IPv6 answer
immediately, every time.

```bash
saucewg bypass                                  # what is listed, and whether it is engaged
saucewg bypass add 203.0.113.0/24 --v6 2001:db8::a --note "some service"
saucewg bypass add 149.154.167.51 --v6 2001:67c:4e8:f002::a
saucewg bypass add 91.108.56.0/22 --disable     # switch off one entry of a built-in group
saucewg bypass remove 203.0.113.0/24
saucewg bypass remove --note "some service"     # the whole group
saucewg bypass always | auto | off              # when it engages
```

`iptables` redirects TCP for the listed prefixes to a relay inside the node container,
which reads the original destination back off the socket and then either connects to the
destination's IPv6 — the same server, a protocol the filter is not watching — or re-dials
its IPv4, six handshakes at a time, within a bounded budget. The filter samples handshakes
rather than dropping all of them, so each one is an independent throw: measured live, two
thirds of these connections open within six handshakes, and going six at a time is what
makes that under a second instead of ten. The retry path is also the only one Telegram's
media CDN has, because `cdn1..5.telesco.pe` publish no IPv6 at all. The bytes are spliced
verbatim: nothing terminates TLS or reads MTProto, and to both ends this is the transport.

A destination that spends a whole budget answering nothing gets a short burst instead of a
long one for a while, widening each time it fails again, and a single connection clears the
record. That is not giving up; it is telling apart the two kinds of destination that arrive
here. Persistence is right for one whose handshakes are being sampled and worthless for one
blocked outright — and on the live node a single address of the second kind, retried by
clients several times a second, accounted for 98% of all failed flows and 300 000
handshakes a quarter of an hour. `saucewg bypass` reports it as a separate line when it is
happening.

| Mode | The redirect is installed |
| --- | --- |
| `auto` (default) | only while client traffic is leaving through this entry node — during a cascade outage, or with no exit node configured |
| `always` | whenever the node container is running |
| `off` | never |

`auto` exists because a flow already leaving from another country is not meeting this
filter, so relaying it would add a hop for nothing. The consequence to internalise:
**on a healthy cascade the entries read as listed and not active, and that is correct.**
`saucewg bypass` says which of the two it is on its first line.

`BYPASS_GROUPS=telegram` ships the datacentre prefixes with their IPv6 counterparts, so
the common case needs no list. `config/bypass.json` adds anything else, or corrects a
group entry — an entry that comes from a group can be switched off there but not deleted,
because the table itself lives in the node image:

```json
[
  { "cidr": "203.0.113.0/24", "v6": "2001:db8::a", "note": "some service", "enabled": true },
  { "cidr": "198.51.100.7/32", "note": "no v6 known — its own IPv4 is retried" },
  { "cidr": "91.108.56.0/22", "enabled": false, "note": "a built-in, switched off here" }
]
```

Changes reach the container within a second, like the other two lists. Re-adding an
entry **corrects** it rather than being skipped as a duplicate — unlike a direct route,
an entry carries how to reach the destination, so the second `add` is how a wrong `--v6`
is fixed. `BYPASS_ROUTES` in `.env` puts the list in the environment instead, overriding
the file and making the panel's section read-only. `BYPASS_MODE=off` disables the
feature; `saucewg update` writes `BYPASS_MODE=auto` into an installation that predates
it and prints a note, since it changes how those flows leave the server.

### 4.8 Blocking BitTorrent

The reason to care is not copyright, it is the server. A swarm sees the address of
whichever node takes a client's traffic out, and a datacentre answers the notice that
follows by suspending that server — no warning, no question about who was behind it.
One client seeding for an evening is the node gone and every client on it with it. A
European exit node is exactly the case, which is why this is on from the moment a node
is installed.

```bash
saucewg torrents             # what is in force here, and what it has caught
saucewg torrents on          # peer discovery, the peer wire, and caught peers
saucewg torrents strict      # the same, plus a default-deny egress port policy
saucewg torrents off         # forward it like anything else
```

```
  torrents  on
            peer discovery and the peer wire are blocked, and caught peers blacklisted
            in force on awg0 with 61 rule(s)
            1842 peer address(es) blacklisted
            13630 packet(s) dropped

CLIENT     PACKETS  EXPIRES IN
10.8.0.14  12800    84000s
10.8.0.9   40       3600s
```

It runs on **every** node, entry and exit alike, because either can be the address a
swarm sees. On an entry node it inspects what clients send; on an exit node, what the
entry node forwards. The rules sit in `mangle/FORWARD`, which is where a client's
traffic exists as plain IP — after AmneziaWG has decrypted it, before anything
re-encrypts it into an uplink.

There is nothing to list and nothing to keep up to date. Peers are found at runtime and
the connection to them is encrypted from its first byte, so a set of addresses or ports
would be stale before it was written. What is matched instead is the protocol: the
bencoded text of a DHT query, the fixed 64-bit constant a UDP tracker announce opens
with, `info_hash=` in an HTTP announce, the `0x13 "BitTorrent protocol"` handshake, the
20-byte uTP header whose first byte is fixed. None of that can be dropped by a client
that still wants to work, and none of it is encrypted, because at that point the two
ends have nothing to derive a key from.

Every address caught speaking any of it goes into an ipset for an hour, so the *next*
connection to that peer is dropped without being inspected. That is what carries the
block across a reconnection nothing can read inside, and it is why the guard gets
stronger the longer it runs.

**`strict`** adds the one case signatures cannot see: an encrypted connection to an
address the client already had, on a port nothing else uses. It refuses outbound TCP and
UDP except to the ports in `TORRENT_TCP_PORTS` and `TORRENT_UDP_PORTS`, which is a
general egress policy rather than a torrent signature — the only layer here that can
inconvenience somebody who was not torrenting. It will break anything on a port nobody
named, and deliberately includes a VPN a client runs inside the tunnel: that would carry
torrents where nothing downstream could see them. The CLI warns before applying it.

The two halves cover each other. The port policy catches what has no signature; the
signatures catch what is on an allowed port. A client set to run uTP and DHT over
UDP/443 to hide inside QUIC gets past the ports and straight into the shape and bencode
rules, which never look at a port.

The switch lives in `config/torrent-block.json` next to the other three lists, so the
panel, the CLI and the node container all see the same thing and a change applies within
a second without disturbing a tunnel. Turning it on also drops the conntrack entries for
client traffic, so a torrent running at that moment stops rather than finishing.

`TORRENT_BLOCK=off|on|strict` in `.env` pins it and takes the switch away from the panel
and the CLI both; `saucewg torrents off` then refuses rather than writing a file that
would be ignored. `saucewg update` turns the guard on for an installation that predates
it and prints a note, since it changes what the server will carry.

Two things to check on a host you did not build:

* **`saucewg torrents` reports what the kernel could actually do.** The filter is built
  on iptables match extensions, and a container host without `xt_string` gets a port
  filter instead of a signature filter — enough to stop a default client and nothing
  more. That is reported on the status line rather than left to be discovered.
* **A rule the kernel refuses is skipped, not fatal.** A partial kernel installs
  whatever it supports, and says how much of the ladder that was.

### 4.9 Putting a failed exit node back

Failover keeps clients online, and that is also the trap: nothing is broken from a
client's point of view, so a dead exit node can stay dead until the last one goes with
it. Recovering it needs a shell on that server, and the panel is the only part of the
installation that has one — it installed most of the nodes and holds an SSH key on each.
So it runs one escalating attempt at a time, on a timer:

| Step | When | What it does |
| --- | --- | --- |
| wait | first `NODE_RECOVERY_GRACE_SECONDS` (5 min) | nothing — a container reload or a reboot fixes itself |
| probe | the uplink is still unhealthy | opens an SSH session. Silent twice means the server is gone, not broken |
| restart | the server answers | `saucewg restart` on it, then waits for the handshake |
| repair | it is up and still silent | re-installs the entry node's uplink key: the two ends no longer agree |

```bash
saucewg recover              # every unhealthy node, now
saucewg recover pl-129       # just this one
# NAME    TRIED    RESULT                                  DETAIL
# pl-129  probe    unreachable — check the server exists    203.0.113.9 did not answer in time
```

The exit status is `0` only when every node named came back, so it works in a cron or a
health check. The command runs inside the panel container, because that is where the SSH
key is — an exit node has no panel and cannot recover anything, including itself. The
**Recover** button on the Exit nodes page and `POST /api/nodes/{name}/recover` are the
same code.

What it will not do is worth knowing:

* **It stops at a server that does not answer SSH.** That is a deleted or suspended VPS,
  not a broken service, and dialling it every minute would tell you nothing new. The
  panel reports `unreachable` and leaves it; `saucewg recover` says so on the node's row.
* **It never touches a healthy node**, or one an operator is already working on.
* **It works on one node per pass.** Restarting two at once could take the last healthy
  one with them, and an outage affecting several is one where this entry node's own
  uplink is the likelier cause.
* **It needs the panel's key.** A node adopted by hand has no SSH address recorded, so
  it is recoverable only on that server, with `saucewg restart`.

Attempts back off geometrically from `NODE_RECOVERY_INTERVAL_SECONDS` and stop after
`NODE_RECOVERY_MAX_ATTEMPTS`; a node that comes back clears its own history. Asking by
hand — the CLI, the button or the endpoint — clears a verdict it had given up on, since
an operator asking has usually just fixed the reason. So does restarting the panel, which
`saucewg update` does: the count is kept in memory, so an update gives even an
`unreachable` node a fresh run of attempts. `NODE_RECOVERY_ENABLED=false` switches the
automatic part off and leaves the manual one available.

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

Which destinations use the cascade is a separate list on the same panel:

| Call | Body | Result |
| --- | --- | --- |
| `GET /api/routes` | — | The direct route list, with `active` saying which entries are really installed |
| `POST /api/routes` | `{"cidr": ["142.250.0.0/15", "8.8.8.8"], "note": "youtube"}` | `201`. Prefixes already listed are skipped, not rejected |
| `PUT /api/routes/{cidr}` | `{"enabled": false}` or `{"note": "…"}` | Turns one off without losing it, or relabels it |
| `DELETE /api/routes/{cidr}` | — | Puts that destination back on the cascade |

The prefix goes in the path with its slash intact: `DELETE /api/routes/142.250.0.0/15`.
Full field semantics are in [`AWG_USAGE.md` §7](AWG_USAGE.md#7-routing-past-the-cascade);
the fallback that applies when the whole cascade is down is set on the entry node itself
(§4.6), not through the API.

Destinations the entry node reopens for itself (§4.7) are a third list, with the same
shape and one endpoint more:

| Call | Body | Result |
| --- | --- | --- |
| `GET /api/bypass` | — | The list, the mode, and the relay's counters while it is running |
| `POST /api/bypass` | `{"cidr": ["203.0.113.0/24"], "v6": "2001:db8::a", "note": "…"}` | `201`. Re-posting one **corrects** it rather than being skipped |
| `PUT /api/bypass/{cidr}` | `{"enabled": false}`, `{"v6": "…"}` or `{"note": "…"}` | The only way to switch off an entry that comes from a built-in group |
| `DELETE /api/bypass/{cidr}` | — | Stops reopening it; `409` on a built-in entry |

Whether it is engaged at all is `BYPASS_MODE` on the entry node, not an API call, for
the same reason as the fallback. Field semantics:
[`AWG_USAGE.md` §8](AWG_USAGE.md#8-destinations-the-entry-node-reopens).

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
| `POST /api/nodes/{name}/recover` | — | `202` + task. Restart, then re-pair if that was not enough — the escalation of §4.9, run now |

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

`recover` is the one to reach for when that distinction comes out the other way: the
node is unhealthy and you do not yet know why. It probes, restarts and re-pairs in that
order and reports where it stopped. Unlike the calls above its task **succeeds even when
the node stays down** — the attempt ran and answered the question — so branch on
`task.result.healthy`, and treat `task.result.blocked == "unreachable"` as "this server
is not answering at all; check it still exists". The full field list is in
[`AWG_USAGE.md` §6](AWG_USAGE.md#6-exit-nodes-and-failover).

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
| `recovery` | What the panel's own recovery has tried on it, or `null` while it is healthy — `blocked: "unreachable"` is the one that needs a human (§4.9) |

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
| `/opt/saucewg/config/direct-routes.json` | Destinations that bypass the cascade, written the same way |
| `/opt/saucewg/config/bypass.json` | Destinations this node reopens for itself (§4.7), written the same way |
| `/opt/saucewg/config/torrent-block.json` | Whether BitTorrent is blocked here (§4.8), and how hard |
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
| `NODE_PROVISION_ENABLED` | `true` | `false` makes the panel read-only with respect to the cascade and to routing — set it when both lists are owned by configuration management |
| `NODE_REGISTRY_FILE` | `/etc/saucewg/host/exit-nodes.json` | Where the panel sees the node list *inside its container* |
| `ROUTES_REGISTRY_FILE` | `/etc/saucewg/host/direct-routes.json` | The same for the direct route list |
| `BYPASS_REGISTRY_FILE` | `/etc/saucewg/host/bypass.json` | The same for the reopened destinations of §4.7 |
| `CASCADE_FALLBACK` | `direct` | What happens while every exit node is down — see §4.6 |
| `CASCADE_DIRECT_FILE` | `/etc/amnezia/host/direct-routes.json` | Where the *node container* reads the direct route list |
| `CASCADE_DIRECT_ROUTES` | | The same list inline, overriding the file |
| `BYPASS_MODE` | `auto` | When the destinations of §4.7 are reopened: `auto`, `always`, `off` |
| `BYPASS_GROUPS` | `telegram` | Built-in destination tables in force; empty ships none |
| `BYPASS_FILE` | `/etc/amnezia/host/bypass.json` | Where the *node container* reads the reopened destinations |
| `BYPASS_ROUTES` | | The same list inline, overriding the file |
| `BYPASS_PORT` | `8646` | Where the relay listens, on the client interface's address only |
| `BYPASS_ATTEMPTS` / `BYPASS_PARALLEL` | `96` / `6` | Handshakes the retry path may spend on one connection, and how many go out at once |
| `TORRENT_REGISTRY_FILE` | `/etc/saucewg/host/torrent-block.json` | Where the panel sees the torrent switch of §4.8 *inside its container* |
| `TORRENT_BLOCK` | | `off`, `on` or `strict` pins the switch and takes it away from the panel and the CLI; empty leaves it to the file |
| `TORRENT_BLOCK_FILE` | `/etc/amnezia/host/torrent-block.json` | Where the *node container* reads the switch |
| `TORRENT_TCP_PORTS` / `TORRENT_UDP_PORTS` | see §4.8 | The ports `strict` leaves open. Adding 500, 4500 or 51820 lets a client run its own VPN out of the tunnel and torrent inside it |
| `NODE_SSH_KEY_FILE` | `/etc/saucewg/host/panel-ssh-key` | The panel's own SSH key, generated on first use |
| `NODE_SSH_KEY_ENABLED` | `true` | `false` stops the panel keeping a key, so every call carries credentials |
| `NODE_SSH_TIMEOUT_SECONDS` | `900` | Ceiling for one remote command |
| `NODE_SSH_QUERY_TIMEOUT_SECONDS` | `60` | Ceiling for the calls that answer inside one request: `check`, `status`, `logs` |
| `NODE_RECOVERY_ENABLED` | `true` | Whether the panel tries to put a failed exit node back — see §4.9 |
| `NODE_RECOVERY_GRACE_SECONDS` | `300` | How long a node must be unhealthy before the first attempt |
| `NODE_RECOVERY_INTERVAL_SECONDS` | `60` | Sweep interval, and the base of the backoff between attempts |
| `NODE_RECOVERY_MAX_ATTEMPTS` | `6` | After this many, the node is left for an operator |
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
* **An outage no longer means users are offline.** With the default
  `CASCADE_FALLBACK=direct` the entry node carries their traffic while every exit node
  is down, so they stay connected — from the entry node's address. `saucewg fallback`
  says whether that is happening right now, and `saucewg fallback block` restores the
  old cut-off behaviour.
* **A direct route is a destination, not a client setting.** It applies to every client
  on the node, needs nothing on their side, and does not appear in their profile. It is
  also only as good as the addresses in it: a service that answers from a range you did
  not list keeps going through the exit node.
* **A reopened destination that is not active is usually correct.** In the default
  `auto` mode the redirect exists only while clients are leaving through the entry node,
  because a flow that already leaves from another country is not meeting the filter it
  works around. `saucewg bypass` says which state it is in, on its first line.
* **A big "unreachable" count in `saucewg bypass` is usually one address, and usually
  harmless.** Some destinations are blocked outright rather than having their handshakes
  sampled, and nothing this node does opens those — the measured one answered 0 handshakes
  in 20 from this server and 10 in 10 from a home connection, so it is the hosting
  network's filtering rather than a dead address. The line about destinations
  that "cost one handshake each" is the relay having worked that out and stopped spending
  on them: on the live node this took the handshake rate from 389 a second to 36 while
  opening *more* connections than before. Telegram keeps working through it, because every
  datacentre it needs is reachable over IPv6 and the app moves on from an endpoint that
  will not answer. Judge it by the "over IPv6" and "by retrying" counts, not by this one.
* **The torrent guard is on by default, on every node**, including one installed before
  it existed once `saucewg update` has run. It is not an opt-in policy because what it
  prevents is the loss of the server rather than a bill, and it is per node rather than
  per client because a swarm sees a server's address and nothing finer.
* **`strict` will break something eventually.** It is a default-deny egress port policy,
  so any service on a port nobody listed stops working — including a VPN a client runs
  inside the tunnel, which is the point. Reach for it on a node that has already had a
  complaint, not as a starting position.
* **The chosen mode survives being switched off.** `saucewg torrents off` after
  `strict` keeps `strict` on file, so turning the guard back on returns to it rather
  than to the standard mode.
* **The counters reset with the node container.** They are read off the iptables rules
  themselves, so a restart zeroes them. That is also why they cost nothing to keep.
* **Failing over is not repairing.** The cascade moves clients off a dead exit node in
  about 30 seconds and leaves it dead. The panel is what tries to bring it back (§4.9),
  and a node it reports as `unreachable` is one no software on this side can fix — that
  is a server that has stopped existing, and the honest fix is at the provider.
* **`saucewg recover` needs the panel.** It runs inside that container because the SSH
  key lives there, so it works on an entry node and nowhere else — and only for nodes
  the panel installed. An adopted node is recovered with `saucewg restart` on its own
  server.
* **`saucewg` on an exit node has no panel commands** and will say so rather than
  guessing; `saucewg status` and `saucewg logs` work everywhere.
