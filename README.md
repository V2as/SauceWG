# SauceWG

A Marzban-style control panel for an **AmneziaWG** cascade ("double VPN").

Clients connect to an entry node whose IP is not blocked by the censor. The entry node
does not reach the internet directly: it forwards everything through a second obfuscated
AmneziaWG tunnel to an exit node in another country, which performs the NAT. Both hops
speak AmneziaWG, so neither the client link nor the inter-server link looks like
WireGuard to a DPI box.

Any number of exit nodes can be configured. All of them stay connected; one carries
traffic, and the node fails over to the next healthy one within about 30 seconds when it
stops answering. If none of them is usable, the entry node carries the traffic itself
rather than cutting clients off, and picks the cascade back up as soon as an exit node
recovers. Failing over is not the same as fixing: the panel also tries to put a failed
exit node back, over SSH, on its own timer.

An exit node can be reached over IPv6 — including one on a VPS with no IPv4 at all —
and the link between the servers can carry IPv6 as well as IPv4, so a destination
abroad sees the exit node's IPv6. Both are opt-in and independent of each other;
clients stay IPv4 either way. See [IPv6](#ipv6).

Chosen destinations can be sent past the cascade on purpose: a range listed in
`config/direct-routes.json` leaves through the entry node's own address while everything
else still goes abroad, which is how a service that has to see a local IP keeps working.

Where the problem is the destination rather than the route — an address whose TCP
handshake is dropped on the way out, no matter which interface it leaves by — the entry
node can reopen it for itself: over the destination's IPv6, which the same filters
usually do not touch, or by retrying its IPv4 until one handshake survives. Telegram's
datacentres ship as a built-in group, because that is what this exists for today.

What the nodes will not carry is BitTorrent. A swarm sees the address of whichever
server takes a client's traffic out, and a datacentre answers the copyright notice that
follows by suspending that server — so one client seeding costs every client on it. Peer
discovery, the peer wire and every address caught speaking either are blocked on the
forwarding path, on by default, with a switch in the panel.

```
   client                 entry node (unblocked IP)                exit nodes
 ┌────────┐  AmneziaWG   ┌───────────────────────┐  awg1  ┌──────────────┐
 │ phone  │ ───────────▶ │ awg0  10.8.0.1/24     │───────▶│ eu-nl  prio 10│──▶ internet
 │ laptop │   1.0 – 2.0  │ awg1  10.77.0.2/32    │  awg2  ├──────────────┤
 └────────┘              │ awg2  10.77.0.3/32    │╌╌╌╌╌╌▶ │ eu-de  prio 20│  (standby)
                         │ panel · api · caddy   │  awgN  ├──────────────┤
                         └───────────┬───────────┘╌╌╌╌╌╌▶ │ …             │  (standby)
                                     │                    └──────────────┘
                                     └──▶ internet    listed prefixes, and everything
                                          (this IP)   else while no exit node is up
```

Integrating this into a larger system? [`AWG_USAGE.md`](AWG_USAGE.md) is the reference
for managing *users* from a central API, and [`SAUCEWG_USAGE.md`](SAUCEWG_USAGE.md) for
installing and managing *servers* — from a shell, a script or a bot.

## AmneziaWG generations

Which generation a tunnel speaks is not a version number sent on the wire — it is decided
entirely by which obfuscation parameters the `[Interface]` section carries. That is also
how AmneziaVPN and KeeneticOS tell them apart, and it is why a profile can only be loaded
into a client that understands every parameter in it.

SauceWG serves the three generations that router firmware can load, and defaults new
installations to **2.0**:

| Generation | Parameters on top of WireGuard | KeeneticOS |
| --- | --- | --- |
| `1.0` | `Jc` `Jmin` `Jmax` `S1` `S2` `H1`–`H4` | 4.2 Alpha 2 and newer |
| `1.5` | the same, plus `I1` | 5.1 Alpha 3 and newer |
| `2.0` | the same, plus `I1` `S3` `S4` | 5.1 Alpha 3 and newer |

Loading a 1.5 or 2.0 profile into KeeneticOS 5.0.8 or older fails with
`"Wireguard": invalid H1 value` — the firmware is not rejecting `H1`, it simply does not
recognise the parameters that come with the newer generations. 5.1 is a developer-channel
build for most models; if a router cannot be moved to it, that node stays on 1.0, which
[Amnezia's own instructions](https://docs.amnezia.org/ru/documentation/instructions/keenetic-os-awg/)
also note is the more blockable of the three. AmneziaVPN calls 1.0 **AmneziaWG Legacy**;
`legacy` is accepted as a spelling of `1.0` everywhere in SauceWG for that reason.

AmneziaWG 3.0 — header protection, content padding, custom timings — is deliberately
absent. No router firmware speaks it, so a 3.0 profile could not be loaded into a
Keenetic at all.

| Parameter | Meaning | Must match on both sides |
| --- | --- | --- |
| `Jc` | number of junk packets sent before each handshake | no |
| `Jmin` / `Jmax` | junk packet size range in bytes | no |
| `S1` | padding of the handshake initiation (`S1 + 56 != S2`) | **yes** |
| `S2` | padding of the handshake response | **yes** |
| `S3` / `S4` | padding of the cookie reply and of every transport packet | **yes** |
| `H1`–`H4` | replacement values for the four packet type headers | **yes** |
| `I1`–`I5` | signature packets sent ahead of the handshake | no |

The asymmetry matters for what a profile has to contain. `S1`–`S4` change how long each
message is and `H1`–`H4` change its type header, so a mismatch is a tunnel that never
handshakes — the panel copies those verbatim into every client profile. Junk packets and
signature packets are only ever *built* by the sender and never parsed by the receiver, so
each side may use its own: the entry node keeps its own `I1` disguise while handing clients
whatever `CLIENT_SIGNATURE`, `CLIENT_JC`, `CLIENT_JMIN` and `CLIENT_JMAX` say.

A signature packet is what a censor's classifier sees first, so `I1` is chosen from a
preset rather than written by hand — `quic` (the default, matching the entry node's UDP/443),
`dns`, `random`, `short`, or `none`. `saucewg signatures` lists them; a literal
`<b 0x…><r n>` spec is accepted anywhere a preset name is.

Every node, uplink and client profile carries its own generation, so a cascade can serve
2.0 to phones while an uplink to an older exit node stays on 1.0. Moving a node between
generations is one command (`saucewg set-protocol`, or the **⇅** button on the Exit nodes
page) and only adds or drops parameters — the padding both ends already agreed on is
kept, so the tunnel is not rekeyed.

The node image pins `amneziawg-go` v0.2.x with `amneziawg-tools` v1.0.x, which implement
all three; `scripts/test-protocol-parity.sh` in CI keeps the three places that describe a
generation from drifting apart.

> **A client-facing 2.0 interface pads by zero.** `S3` and `S4` default to `0` on the
> interface app clients dial, because the AmneziaVPN app has an
> [open bug](https://github.com/amnezia-vpn/amnezia-client/issues/2582) where it does not
> hand non-zero `S3`/`S4` to its own backend: it strips no padding from transport packets
> that have it, so the handshake completes and nothing flows. The profile is still a valid
> 2.0 one, and routers using the AmneziaWG kernel module (Keenetic among them) work either
> way. Cascade hops keep real padding — both ends there run `amneziawg-go`, which honours
> it, and that is the hop a censor actually sees. Pin `AWG_S3`/`AWG_S4` in `.env` if every
> client you serve is a router.

## Components

| Service | Image | Role |
| --- | --- | --- |
| `awg` | `saucewg/awg` | amneziawg-go + amneziawg-tools, interfaces, routing, NAT, the bypass relay |
| `panel` | `saucewg/panel` | FastAPI: REST API, traffic collector, peer reconciliation |
| `caddy` | `saucewg/web` | Vue 3 single-page UI + reverse proxy for `/api` and `/sub` |
| `postgres` | `postgres:16-alpine` | clients, admins, usage history |

The panel talks to the node over the AmneziaWG UAPI unix socket (a shared Docker volume),
so it needs neither the `awg` binary nor `NET_ADMIN`. The database is the source of truth:
a reconciliation loop re-applies every peer after a node restart.

## Quick start

### 1. Entry node

On a bare server, as root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/V2as/SauceWG/main/saucewg.sh) \
  install --domain panel.example.com
```

That installs Docker if it is missing, writes `/opt/saucewg`, starts everything and
prints the panel URL with a generated admin password. `--domain` gets an automatic
Let's Encrypt certificate, so point the name at this server and leave TCP/80 reachable
before running it — that is the address the certificate is issued over. Leave `--domain`
out to serve the panel over plain HTTP by IP.

The entry node comes up on AmneziaWG 2.0 with no exit nodes, so the panel is usable
immediately. Add `--protocol 1.0` if the clients that will connect are routers on
KeeneticOS 5.0.8 or older — it can also be changed later with `saucewg set-protocol`.

### 2. Exit nodes

From the panel: **Exit nodes → Add exit node**, then give it a name, the server's IP
and its root password. SauceWG installs everything over SSH, joins the node to the
cascade, pairs both ends and waits for the first handshake, streaming the log as it
goes. The password is used once and never stored: the panel leaves an SSH key of its
own on the server, so managing it afterwards — status, logs, restart, upgrade, or
moving it to another AmneziaWG generation — needs no credentials at all. Preload that
key (**Exit nodes → This panel's SSH key**, or `GET /api/nodes/ssh-key`) into a new
server at creation time and even the install needs no password.

The whole of that is API, not just UI, so a bot adds a node in another country with
one call to the entry node and no shell anywhere — see
[`SAUCEWG_USAGE.md` §5](SAUCEWG_USAGE.md#5-driving-it-from-a-bot).

By hand, if you prefer — on the new exit server:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/V2as/SauceWG/main/saucewg.sh) \
  install-node --name eu-nl              # add --protocol 1.0 to pair with an older entry node
```

It prints a JSON object describing itself. On the entry server:

```bash
saucewg add-node --json '{"name":"eu-nl","endpoint":"…","public_key":"…", …}'
```

which allocates an uplink address and a priority and prints the entry node's uplink
key for that slot. Back on the exit server:

```bash
saucewg node-pair --peer-key '<that key>'
```

Adding or removing a node takes effect within a second and restarts nothing.

An exit node on an IPv6-only VPS works the same way in both directions: give the panel
its IPv6 address as the host, or by hand pass `--endpoint-host6` to `install-node` — it
detects the server's own addresses either way and reports both. See [IPv6](#ipv6).

Optionally add a pre-shared key to an uplink for post-quantum resistance: generate one
with `docker run --rm --entrypoint awg saucewg/awg:1.5.0 genpsk` and pass it as
`--psk` to `install-node` and `preshared_key` in the object above.

Private keys are generated inside the node container on first start and persisted in the
`awg-config` volume. They never need to be typed into `.env`.

### 3. Sign in

Open the URL the installer printed and log in. Create a client, then hand out the
`.conf` file, the QR code, or the subscription link.

> Serving the panel over plain HTTP sends the admin password in the clear. Re-run the
> installer with `--domain`, or set `PANEL_SITE_ADDRESS` and `CADDY_AUTO_HTTPS=on` in
> `.env`, to get TLS.

### Managing the server afterwards

The installer leaves a `saucewg` command behind on both roles:

```bash
saucewg status                 # what is running
saucewg start | stop | restart
saucewg logs -f awg            # awg, panel, postgres, caddy
saucewg update                 # pull newer images and recreate
saucewg nodes                  # the cascade, with health
saucewg recover                # try to bring failed exit nodes back
saucewg routes                 # destinations that bypass the cascade
saucewg bypass                 # destinations this node reopens for itself
saucewg fallback               # what happens while every exit node is down
saucewg protocol               # which AmneziaWG generation this node serves
saucewg set-protocol 2.0       # move it to another one
saucewg admin-password         # reset panel credentials
saucewg info                   # the same, as JSON, for monitoring
```

[`SAUCEWG_USAGE.md`](SAUCEWG_USAGE.md) documents every command and flag, the JSON
contracts for automating installs, and the node management API.

### From a git checkout

For development, or to run modified images, the repository still works the classic way:

```bash
cp .env.example .env            # fill in ADMIN_PASSWORD, JWT_SECRET, POSTGRES_PASSWORD
./scripts/bootstrap-entry.sh --endpoint-host <entry ip> [--protocol 1.0]
./scripts/bootstrap-exit.sh --name eu-nl        # on an exit server
./scripts/add-exit-node.sh --json '{…}'         # on the entry server
```

Both bootstrap scripts source `docker/awg/lib.sh` for their obfuscation profile, so the
`.env` they write is the same one the container would have generated for itself.

## API

Authentication follows the OAuth2 password flow; the token is a JWT bearer token.

```bash
TOKEN=$(curl -s -X POST http://<host>/api/admin/token \
  -d 'username=admin&password=...' | jq -r .access_token)

curl -H "Authorization: Bearer $TOKEN" http://<host>/api/clients
```

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/api/admin/token` | exchange username/password for a token |
| `GET` | `/api/admin` | the authenticated admin |
| `GET/POST` | `/api/admins` | list / create admins (sudo only) |
| `PUT/DELETE` | `/api/admins/{username}` | update / delete an admin (sudo only) |
| `GET` | `/api/clients` | list with `search`, `status`, `online`, `sort`, `order`, paging |
| `POST` | `/api/clients` | create a client (keys and address auto-allocated) |
| `GET/PUT/DELETE` | `/api/clients/{name}` | read / update / delete |
| `POST` | `/api/clients/{name}/enable\|disable\|reset` | toggle state, reset the traffic counter |
| `POST` | `/api/clients/{name}/revoke-subscription` | rotate the subscription token |
| `GET` | `/api/clients/{name}/config` | the `.conf` profile |
| `GET` | `/api/clients/{name}/qr` | the profile as a PNG QR code |
| `GET` | `/api/clients/{name}/usage?hours=` | per-bucket traffic history |
| `GET` | `/api/nodes` | exit node inventory with health, latency and which one is active |
| `POST` | `/api/nodes` | install an exit node on a server over SSH (returns a task) |
| `GET` | `/api/nodes/ssh-key` | the panel's public SSH key, to preload onto a new server |
| `POST` | `/api/nodes/check` | pre-flight a server: reachable, root, what it is, what is on it |
| `POST` | `/api/nodes/adopt` | register an exit node installed by hand |
| `PUT/DELETE` | `/api/nodes/{name}` | change priority, either endpoint, family or note / remove it |
| `POST` | `/api/nodes/{name}/repair` | reinstall the uplink key on an unpaired node |
| `POST` | `/api/nodes/{name}/protocol` | move a node to another AmneziaWG generation over SSH |
| `GET` | `/api/nodes/{name}/status` | the exit server as it describes itself: containers, version, host |
| `GET` | `/api/nodes/{name}/logs` | the tail of that server's container logs |
| `POST` | `/api/nodes/{name}/restart\|start\|stop` | control the exit node's containers |
| `POST` | `/api/nodes/{name}/upgrade` | pull newer images on the exit server |
| `POST` | `/api/nodes/{name}/recover` | try to put a failed node back: restart, then re-pair |
| `GET` | `/api/nodes/tasks[/{id}]` | progress and logs of a provisioning operation |
| `POST` | `/api/nodes/{name}/activate` | prefer one exit node |
| `POST` | `/api/nodes/auto` | drop the preference, back to priority order |
| `GET/POST` | `/api/routes` | destinations that bypass the cascade / add some |
| `PUT/DELETE` | `/api/routes/{cidr}` | relabel or disable one / put it back on the cascade |
| `GET/POST` | `/api/bypass` | destinations the entry node reopens for itself / add some |
| `PUT/DELETE` | `/api/bypass/{cidr}` | change its IPv6 counterpart or disable it / remove it |
| `GET/PUT` | `/api/torrents` | whether BitTorrent is blocked here, what it caught / switch it |
| `GET` | `/api/system` | host stats, client counts, live speed, cascade state |
| `GET` | `/api/system/usage?hours=` | node-wide traffic history |
| `POST` | `/api/system/sync` | force peer reconciliation |
| `GET` | `/api/settings` | interface, AmneziaWG generation and obfuscation parameters |
| `GET` | `/sub/{token}` | the client profile, no admin auth required |

Interactive docs are at `/api/docs` when `DOCS_ENABLED=true`.
[`AWG_USAGE.md`](AWG_USAGE.md) documents every field and its semantics;
[`SAUCEWG_USAGE.md`](SAUCEWG_USAGE.md) covers the node management calls in detail.

## Exit nodes and failover

The exit node list lives in `config/exit-nodes.json`, which the panel, the `saucewg`
command and the node container all share. Each entry becomes its own interface —
`awg1`, `awg2`, … — with its own persistent key pair and obfuscation profile. All of
them handshake continuously; only the one named in the client policy-routing table
carries traffic.

```json
[
  { "name": "eu-nl", "endpoint": "198.51.100.20:51820", "public_key": "…=",
    "address": "10.77.0.2/32", "priority": 10, "protocol": "2.0",
    "s1": 96, "s2": 40, "s3": 31, "s4": 12,
    "h1": 1148643707, "h2": 1420633205, "h3": 1817636915, "h4": 1996553108,
    "i1": "<b 0xc30000000108><r 8><b 0x08><r 8><b 0x0045dc><t><r 16>" },
  { "name": "eu-de", "endpoint": "203.0.113.31:51820", "public_key": "…=",
    "address": "10.77.0.3/32", "priority": 20, "protocol": "1.0", "…": "…" }
]
```

An entry with no `protocol` is read as 1.0 if it carries no `s3`/`s4`/`i1`, and otherwise
as whichever generation its parameters describe — so a list written before this existed
keeps working untouched.

An entry can also carry `endpoint6`, `family` and `address6`, which are what
[IPv6](#ipv6) is configured with. All three are optional and absent means IPv4 as
before.

**Lower `priority` wins.** Every 10 seconds each uplink is checked: a handshake older
than `CASCADE_HANDSHAKE_TIMEOUT` fails it outright, otherwise an ICMP probe is sent
through the tunnel to `CASCADE_PROBE_TARGET` — which is what catches an exit node that
is still up but has lost its own internet. Three consecutive failures take it out of
rotation and traffic moves to the next healthy node; two successes bring it back.

Switching rewrites one route and flushes stale NAT conntrack entries. Clients keep their
tunnel to the entry node the whole time — they see a new exit IP, not a disconnect.

**A health verdict is never older than the handshake it was made on.** The check above
is a loop, and a loop can stop — wedged, killed while the container keeps running, or
not yet past its first tick. Its last verdict would otherwise stand indefinitely: an
exit node reported as healthy and active with a last handshake hours old, carrying
client traffic and delivering none of it. So `healthy` is only published, and only
believed, while the handshake beside it is younger than
`CASCADE_HANDSHAKE_TIMEOUT + CASCADE_PROBE_INTERVAL × CASCADE_FAIL_THRESHOLD` — the
timeout plus the time the hysteresis is allowed to take to act on it. The node container
applies the rule when it writes `uplinks.json` and publishes both numbers in it; the
panel and `saucewg nodes` apply the same rule again when they read it, since the file
itself can be the stale thing. A node the cascade still counts on while its handshake
says otherwise is reported as **stalled**: `healthy` false, `active` possibly still
true, and named as such on the Exit nodes page, in `saucewg nodes` and in
`GET /api/nodes`.

`POST /api/nodes/{name}/activate` and the **Exit nodes** page pin a preferred node. The
pin is a preference, not a lock: a pinned node that goes down is still failed over, and
is taken back once it recovers.

Editing the list — from the panel, from `saucewg add-node`, or with a text editor —
does not restart anything. The node container notices within a second and rebuilds only
the interfaces whose configuration actually changed. Interface numbers are pinned per
node name, so removing one node never renumbers the others, and a node whose process
dies is rebuilt on the next tick.

Three invariants when adding nodes by hand:

- `s1`–`s4` and `h1`–`h4` must be identical on both ends of an uplink, and different
  between uplinks. `jc`/`jmin`/`jmax` and `i1` need not match.
- `protocol` must be one the exit node actually serves. Both ends have to carry the same
  parameters, and an exit node on 1.0 does not read `s3`, `s4` or `i1` at all.
- an uplink's `address` must be inside that exit node's `AWG_SUBNET`, since the exit
  node's NAT rule is scoped to it. The defaults (`10.77.0.0/24` everywhere, `.2`, `.3`,
  `.4` … on the entry node) satisfy this. The same holds for `address6` and the exit
  node's `AWG_SUBNET6` on a cascade that carries IPv6.

`saucewg add-node --json` from the exit node's own `install-node` output satisfies all
three, and `saucewg update-node <name> --protocol …` moves an existing uplink.

Setting `CASCADE_NODES_JSON` puts the list in the environment instead, which takes
precedence over the file and makes the panel read-only with respect to the cascade —
it says so on the Exit nodes page rather than silently ignoring your edits.

### When every exit node is down

`CASCADE_FALLBACK` decides what a total outage looks like to a client:

| Value | While no exit node is usable |
| --- | --- |
| `direct` (default) | the entry node carries the traffic; clients stay online, from its address |
| `block` | client traffic is dropped, as `CASCADE_KILLSWITCH=true` used to do |

Either way it is temporary and automatic: the moment an uplink passes its health check
again, traffic moves back onto the cascade without touching a tunnel. The node container
publishes `fallback` and `fallback_active` in `uplinks.json`, so `saucewg fallback`,
`GET /api/nodes` and the panel all show whether it is in use right now.

`direct` is the default because an entry node that is reachable is more useful than one
that is silent, but it does mean a client's traffic appears from the entry node's own
address during an outage. Where that is the thing being avoided, choose `block`:

```bash
saucewg fallback          # what is configured, and whether it is active
saucewg fallback block    # recreate the node container with the other mode
```

An installation made before this existed keeps its behaviour until `saucewg update`,
which writes `CASCADE_FALLBACK=direct` into `.env` and says so, since it changes what an
outage looks like. Setting it beforehand — by hand or with `saucewg fallback block` —
is respected and left alone.

### Putting a failed node back

Failover keeps clients online, and that is also its weakness: nothing is broken from a
client's point of view, so a dead exit node can stay dead until the last one goes with
it. Only the panel can do anything about it — it installed most of the nodes and keeps
an SSH key on each — so it runs one escalating attempt at a time, cheapest step first:

| Step | When | What it does |
| --- | --- | --- |
| wait | first `NODE_RECOVERY_GRACE_SECONDS` (5 min) | nothing: a reload or a reboot fixes itself |
| probe | the uplink is still unhealthy | opens an SSH session. Twice silent means the server is gone, not broken |
| restart | the server answers | `saucewg restart` on it, then waits for the handshake |
| repair | it is up and still silent | re-installs the entry node's uplink key, since the two ends no longer agree |

Attempts back off geometrically from `NODE_RECOVERY_INTERVAL_SECONDS`, stop after
`NODE_RECOVERY_MAX_ATTEMPTS`, and never run against a node an operator is already
working on. One node is worked on per pass: restarting two at once could take the last
healthy one with them, and an outage affecting several is one where the entry node's own
uplink is the likelier cause. A node that comes back clears its own history, so the next
outage is judged from scratch.

Two things it deliberately does not do. It never restarts a *healthy* node to prove a
point, and it stops as soon as a server does not answer SSH at all — that is a deleted
or suspended VPS, and saying so is more useful than dialling it every minute. Both the
panel and `saucewg recover` report which of the two happened:

```bash
saucewg recover              # every unhealthy node, now
saucewg recover eu-nl        # just this one
# NAME    TRIED    RESULT                                 DETAIL
# pl-129  probe    unreachable — check the server exists   203.0.113.9 did not answer in time
```

The command runs inside the panel container, because that is where the SSH key is; the
**Recover** button on the Exit nodes page and `POST /api/nodes/{name}/recover` are the
same code. Asking for it by hand also clears whatever the automatic attempts had given
up on, since an operator asking has usually just fixed the reason — as does restarting the
panel, the count being held in memory, so an update starts a node over. Set
`NODE_RECOVERY_ENABLED=false` to leave failed nodes alone entirely.

## IPv6

Two different questions, and answering one does not answer the other:

- **Which address is the uplink dialled on?** This is what a censor between the two
  servers sees, and what the exit node's VPS has to have. An exit node on an IPv6-only
  VPS can only be reached this way.
- **Which families travel inside the uplink?** This is what a destination sees. An
  uplink dialled over IPv4 can carry IPv6 to the exit node and out of it, and an uplink
  dialled over IPv6 can carry nothing but IPv4.

Both are off on a new installation and both stay off through an update, because turning
either on changes what the two servers must agree about. Clients are IPv4 in both cases:
nothing here is visible from a phone.

```
            dialled over 4 or 6                    inside: 4, or 4 and 6
 entry node ──────────────────────▶ exit node ───────────────────────────▶ internet
   awg1       198.51.100.20:51820     10.77.0.1      NAT 10.77.0.0/24
   10.77.0.2  [2001:db8::20]:51820    fd00:77::1     NAT fd00:77::/64
   fd00:77::2
```

### Dialling an exit node over IPv6

Give the node both endpoints and it works out which one to use:

```bash
saucewg add-node --name eu-nl --public-key '…=' \
  --endpoint 198.51.100.20:51820 \
  --endpoint6 '[2001:db8::20]:51820'
```

`saucewg install-node` on the exit server prints both, so
`saucewg add-node --json` from its output needs no flags. An IPv6 endpoint must be
bracketed — `[2001:db8::20]:51820` — since `amneziawg-tools` reads the last `:` group
as the port; the CLI, the API and the panel all bracket a bare address for you, and
reject one they cannot parse rather than writing a config that never handshakes.

Which of the two gets dialled follows, in order: the node's own `family` if it has one,
then `CASCADE_ENDPOINT_FAMILY`, then whichever family the entry node can actually reach
the exit node's host on. A node with one endpoint has no decision to make.

"Can actually reach" means a global IPv6 address *and* a route, not either alone. A VPS
whose provider advertises a router but allocates no address has a default route and
nothing to send from — which is also what enabling IPv6 forwarding does to a host that
was relying on router advertisements for its address, since the kernel stops accepting
them once it is forwarding. If `saucewg bridge` reports IPv4 everywhere on a server you
believe has IPv6, check `ip -6 addr show scope global` before anything else.

A unique local address does not count, which matters most on an entry node whose bridge
already carries IPv6: `fd00:77::2` has global scope as far as the kernel is concerned, so
counting it would let the cascade read its own uplinks as proof it can reach the IPv6
internet, and dial the next exit node over an address it could only reach through the
uplink it is building.

**An uplink that never handshakes is moved to its other endpoint.** The same
`CASCADE_FAIL_THRESHOLD` window that fails a node over also counts as evidence that the
address it is being dialled on does not work from here — a route that disappeared, a
provider that started dropping one family, an address that was wrong when it was typed.
The uplink is rebuilt on the other endpoint and the next window judges that one. A node
pinned to a family with `--family 4` or `--family 6` is never moved: it was told, not
asked. Nor is one moved onto a family this entry node cannot send from at all, by the
same test `auto` uses — an uplink that cannot handshake is not an alternative, and the
window it wastes is one the family that might answer would have spent retrying. The flip
survives a reload of the node list, so editing an unrelated node does not throw away
what the container found out, but changing `CASCADE_ENDPOINT_FAMILY` overrules it — the
operator said something newer.

`saucewg nodes` grows a `VIA` column — and an `IPV6` one — once the cascade has an
IPv6 half, and lists exactly as it always did while it does not:

```
PRIO  NAME   IFACE  STATUS   HANDSHAKE  VIA    IPV6  ENDPOINT
10    eu-nl  awg1   active   4s ago     IPv6   up    [2001:db8::20]:51820
20    eu-de  awg2   standby  7s ago     IPv4   down  203.0.113.31:51820
30    pl-01  awg3   standby  6s ago     IPv4   -     192.0.2.9:51820
```

`saucewg bridge` prints the same thing with the configured prefixes above it.

### Carrying IPv6 through the cascade

The bridge is the link between the entry node and its exit nodes — `10.77.0.0/24` by
default. Adding `CASCADE_UPLINK_SUBNET6` gives it a second half, and every uplink a
second address on it:

```bash
saucewg bridge on                       # fd00:77::/64, the default
saucewg bridge fd00:aa::/64             # or your own prefix
saucewg bridge                          # what it is now
saucewg bridge off                      # back to IPv4 only
```

A ULA by default, because the bridge is not meant to be reachable from outside; what
makes it useful is the exit node's own IPv6, which it NATs onto. `saucewg bridge on`
prints what to run on each exit server, which is the half that cannot be done from
here:

```bash
# on each exit node
saucewg install-node --subnet6 fd00:77::/64 --reinstall
```

The exit node then brings its interface up on both families, masquerades
`fd00:77::/64` out of its WAN, clamps MSS for both, and — only then — enables IPv6
forwarding. An exit server with no IPv6 route of its own says so in its log and stays
IPv4: NAT66 with nowhere to go would be a black hole rather than an error.

Uplink addresses are numbered to match their IPv4 ones, so `10.77.0.5/32` pairs with
`fd00:77::5/128` and one uplink reads as one link. That arithmetic is only done for a
prefix ending in `::`; anything else and the container asks for an explicit `address6`
rather than guessing where the host bits start. A node on a VPS with no IPv6 can sit
the bridge out with `--address6 none` while the rest of the cascade carries both.

**IPv6 health is reported, never acted on.** Each uplink with an address on the bridge
is probed at `CASCADE_PROBE_TARGET6` alongside the IPv4 probe, and the result is
published as `healthy6` and `latency6_ms` — on the Exit nodes page, in `saucewg nodes`,
in `GET /api/nodes`. It does not fail a node over. Clients are IPv4, so moving them off
a node that carries their traffic perfectly well, to fix a family none of them use,
would be a net loss. When clients get IPv6 this becomes a failover input; until then it
is a signal that an exit node's provider has broken something.

### Letting an exit node dial the entry node

An uplink is normally dialled from the entry node outwards. Filtering is not always
symmetrical, though: a path can drop what the entry node sends while carrying what the
exit node sends, and the symptom is an exit node that looks dead from the panel while
its own `awg show` reports the uplink's traffic arriving. A tunnel established from the
far end carries traffic both ways like any other, so turning the direction around is a
fix rather than a workaround.

It needs a port the exit node can be pointed at, which an uplink does not have by
default — the kernel picks one and picks a different one after every restart:

```bash
saucewg dial-in on            # fixed ports for the uplinks: 51822, 51823, …
saucewg dial-in               # each uplink's port, and what to run on each exit node
saucewg dial-in off           # back to whatever the kernel picks
```

Ports are counted up from the base by the uplink's own host number, so the node on
`10.77.0.4` listens on `51824` and keeps that port when the list around it is edited.
The whole range is opened in `ufw` or `firewalld` as one rule, so adding an exit node
later needs nothing here. Then, on the exit node that cannot be reached:

```bash
saucewg node-pair --peer-key <uplink key> --peer-endpoint 203.0.113.10:51824
```

`saucewg dial-in` prints that line per node with the keys and ports filled in. Nothing
starts dialling because the base is set: each exit node is told separately, and one
that is not told behaves exactly as before. Both ends may dial at once — whichever
handshake lands first establishes the tunnel, and the entry node adopts the source
address it hears from.

This is worth having even where both directions work. An exit node sends to the port it
last heard from, so a restarted entry node with a kernel-assigned port spends the next
keepalive interval being talked to at a port nobody is listening on.

### Installing an exit node on an IPv6-only VPS

`POST /api/nodes` and `saucewg install-node` both take an IPv6 `host`, so a VPS with no
IPv4 at all can be provisioned normally — SSH, install, pair, join. The panel needs
IPv6 of its own to reach it, which is the one prerequisite that cannot be worked around
from this side: without it the install fails at the first SSH connection and says so.

### What stays IPv4

Clients. `awg0` has no IPv6 address, the entry node installs no `ip -6 rule` for client
traffic, and client profiles carry an IPv4 `Address` and `AllowedIPs = 0.0.0.0/0`. The
bridge is deliberately built first and separately: it is the part that needs both ends
of a tunnel to agree, and getting it wrong breaks an uplink rather than a phone.

## Routing past the cascade

Some destinations are better off never reaching the exit node: a bank that refuses a
foreign address, a service that is only fast from the entry node's country, a video
platform whose CDN answers from the wrong continent. `config/direct-routes.json` lists
them, and they leave through the entry node's own uplink while everything else still goes
through the cascade.

```json
[
  { "cidr": "142.250.0.0/15", "note": "youtube", "enabled": true },
  { "cidr": "64.233.160.0/19", "note": "youtube", "enabled": true },
  { "cidr": "192.0.2.10/32", "note": "one host; a bare address means /32" }
]
```

A bare string works too, so `["142.250.0.0/15", "8.8.8.8"]` is a valid file. `enabled:
false` keeps an entry in the list without routing it, which is the reversible way to
test whether a prefix was the cause of something.

From the CLI, from the **Routing** page in the panel, or through `/api/routes`:

```bash
saucewg routes                                        # with which ones are in effect
saucewg add-route 142.250.0.0/15 --note youtube
saucewg add-route --from-file youtube-ranges.txt --note youtube
saucewg remove-route --note youtube                   # the whole group
```

The node container applies changes within a second, without disturbing a tunnel: each
prefix becomes one route in table `450`, which is consulted before the cascade table.
Traffic leaving that way is NATed to the entry node's address, so no configuration is
needed on the client.

Three things to know:

- **IPv4 only, and no names.** The cascade routes IPv4; a hostname is not resolved, so
  add the ranges a service actually uses. `scripts/keenetic/gen-routes.py` in this
  repository resolves a domain list into prefixes if you need a starting point.
- **`0.0.0.0/0` is refused.** Taking every destination off the cascade is what
  `saucewg fallback direct` does during an outage; as a route it would silently disable
  the cascade entirely.
- **A prefix can be listed and not in effect.** The `active` field, the `direct` column
  in `saucewg routes` and the badge in the panel all come from what the node container
  actually installed, not from the file.

`CASCADE_DIRECT_ROUTES` puts the list in the environment instead, with the same
precedence and the same read-only consequence for the panel as `CASCADE_NODES_JSON`.

## Reopening destinations the network drops

A route decides which way out a destination takes. Some destinations are blocked in a
way no route can address: the outbound TCP handshake to their IPv4 is dropped, so
nothing ever connects, while ICMP answers normally, DNS resolves correctly and any flow
that did get established keeps running. That is what a modern DPI box does instead of a
firewall rule, and it means a `direct-routes.json` entry cannot help — the packets leave
by a different interface and are dropped just the same.

Telegram, from a Moscow hosting segment, is the case this was built for. Measured on a
live entry node: DNS returns the right datacentre addresses, ICMP to them is answered,
and 9 IPv4 SYNs in 10 to port 443 get no reply at all — not a reset, silence. Ports 80 and
5222 to the same addresses are dropped at the same rate, so the filter is matching the
destination rather than the service, which is why the redirect is not limited to one port.
The same datacentres over IPv6 answer on the first try, every time.

So the entry node opens the outbound half itself. `iptables` redirects TCP for the
listed prefixes to a small relay in the node container (`awg-bypass`), which recovers
the original destination from the socket and then, per connection:

1. **connects to the destination's IPv6** when the list names one — the same server, a
   protocol the filter is not looking at;
2. **retries its IPv4**, several handshakes at a time within a bounded budget, when
   there is no IPv6 or IPv6 is unavailable. The filter samples handshakes rather than
   blocking them all, so each attempt is an independent throw: measured live, two
   thirds of these connections open within six handshakes and the rest trail out to
   sixty. They go out six at a time because the client is waiting through all of them —
   a burst opens in under a second where one attempt after another takes ten.

The second path is not just a fallback. Telegram's media CDN (`cdn1..5.telesco.pe`)
publishes no IPv6 at all, so photographs and video can only arrive that way.

A destination that spends a whole budget without answering is remembered, and for a
while afterwards costs a short burst rather than a long one, widening each time it goes
on failing. Nothing is given up on — a single connection clears the record — but the two
kinds of destination need opposite treatment, and telling them apart matters: on the live
node one address that answers *nothing* was being retried by clients several times a
second, and on its own accounted for 98% of all failed flows and 300 000 handshakes a
quarter of an hour. That address took 0 handshakes in 20 from the hosting segment and 10
in 10 from a Russian consumer ISP, so it is alive and the filtering is on the datacentre's
uplink; no budget would have opened it — only a path the block is not on would, which is
an IPv6 counterpart or an exit node.
Failing it in a second suits the client better too, because a Telegram client walks a list
of datacentre addresses and the sooner one is refused the sooner it tries the next.

Nothing about the client changes: it dials the same address it always did, and the
tunnel it is in is unchanged. Telegram's own MTProto is end-to-end from the app to the
datacentre, so the relay is carrying bytes it cannot read.

```bash
saucewg bypass                       # what is listed, and whether it is engaged now
saucewg bypass add 203.0.113.0/24 --v6 2001:db8::a --note "some service"
saucewg bypass add 91.108.56.0/22 --disable    # switch off one entry of a group
saucewg bypass off                             # stop reopening anything
```

`BYPASS_GROUPS=telegram` ships the datacentre prefixes and their IPv6 counterparts, so
the common case needs no list at all; `config/bypass.json` adds anything else, or
corrects a group entry:

```json
[
  { "cidr": "203.0.113.0/24", "v6": "2001:db8::a", "note": "some service" },
  { "cidr": "198.51.100.7/32", "note": "no v6 known — its own IPv4 is retried" },
  { "cidr": "91.108.56.0/22", "enabled": false, "note": "a built-in, switched off" }
]
```

`BYPASS_MODE` decides when it engages:

| Value | Behaviour |
| --- | --- |
| `auto` (default) | only while client traffic is leaving through the entry node — during a cascade outage, or with no exit node configured |
| `always` | whether or not an exit node is carrying traffic |
| `off` | never |

`auto` is the default because a flow that is already leaving from another country is
not meeting this filter, and relaying it would add a hop for nothing. It does mean that
on a healthy cascade the list reads as *listed, not active* — that is the intended
state, not a fault, and the panel and `saucewg bypass` both say which it is.

Four things to know:

- **IPv4 destinations, IPv6 counterparts.** The redirect matches IPv4 TCP; `v6` is
  where the same service answers. A prefix with no counterpart still works — it gets
  the retry path.
- **A counterpart is only ever named on evidence.** The built-in group pairs an address
  with an IPv6 address only where the two are known to be the same server: the
  datacentre tables the official clients ship, or an IPv6 record of the same hostname.
  A datacentre address a client discovers at runtime is left unpaired, because sending
  an MTProto session to the wrong datacentre is worse than not translating it at all.
- **TCP only.** UDP cannot be relayed this way and does not need it: the drop being
  worked around is in connection establishment.
- **The relay binds to the client interface address only**, on `BYPASS_PORT`, so it is
  reachable from inside the tunnel and not from the internet.

`BYPASS_ROUTES` puts the list in the environment, with the same precedence and the same
read-only consequence for the panel as the other two lists.

## Blocking BitTorrent

A swarm sees the address of whichever server carries a client's traffic out, and a
datacentre answers a copyright notice by suspending that server rather than by asking
who was behind it. One client seeding for an evening is the whole node gone and every
other client on it with it — which is why this is on by default, and why it is a switch
rather than a list.

There is nothing to list. Peers are discovered at runtime and the connection to them is
encrypted from its first byte by MSE, so any set of addresses or ports is out of date
before it is saved. What cannot change is the protocol, and the block is built on the
parts of it no client can drop and still work.

It runs on the forwarding path of the node, in `mangle/FORWARD` — the one place a
client's traffic exists as plain IP, after AmneziaWG has decrypted what the client sent
and before anything is re-encrypted into an uplink. The same code runs on an exit node,
where the interface faces an entry node instead of a client.

```bash
saucewg torrents                     # what is blocked here, and what has been caught
saucewg torrents strict              # add the egress port policy
saucewg torrents off                 # forward it like anything else
```

Or the **Torrents** page in the panel, which is the same switch and adds who has been
tripping it.

### The layers

*Discovery* — finding the peers of a swarm — cannot be encrypted, because the two ends
have nothing to derive a key from yet. Killing it means a client never learns an address
to talk to and, just as importantly, the swarm never learns this node's: a monitoring
peer cannot see an address that never announced.

| Layer | Matched on |
| --- | --- |
| DHT | the bencoded KRPC preamble (`d1:ad2:id20:`) and the query names — BEP 5 |
| Trackers | the UDP protocol's fixed connection id `0x41727101980`, and `info_hash=` / `peer_id=` in an HTTP announce — BEP 15 and BEP 3 |
| Local discovery | `BT-SEARCH` sent somewhere routable — BEP 14 |
| Tracker lookups | DNS queries for the bootstrap and tracker names clients fall back to |

*The peer wire* is the hard half, and two things are done about it. uTP — what a modern
client opens with before MSE starts — is a 20-byte header in a 48-byte datagram whose
first byte is fixed, so it is matched by shape and never gets as far as being encrypted.
And every address caught speaking any part of the protocol goes into an ipset for an
hour, so the *next* connection to that peer is dropped without being inspected, encrypted
or not. That is what carries a block across a reconnection nothing can read inside.

| Layer | Matched on |
| --- | --- |
| uTP | a 48-byte datagram whose payload starts `41 00` or `41 01` — BEP 29 |
| Peer handshakes | `0x13` + `"BitTorrent protocol"` — BEP 3 |
| Peer exchange | `ut_pex`, `ut_metadata`, `ut_holepunch` in the extension handshake — BEP 10 |
| Known peers | an address already caught, whatever it is speaking now |
| Default ports | 6881–6889, 6969, 51413 |
| `.torrent` files | `application/x-bittorrent` and `d8:announce` on the way back |

What is left after that is one case: a TCP/MSE connection to an address the client
already knew, on a port nothing else uses. `strict` closes it, by refusing outbound TCP
and UDP except to the ports real services answer on. That is a general egress policy
rather than a torrent signature, which is exactly why it is a separate mode — it is the
only layer here that can inconvenience somebody who was not torrenting, and it will
break a VPN a client runs inside the tunnel. That last part is deliberate: a tunnel
inside the tunnel would carry torrents where nothing downstream could ever see them.

The two halves are complementary rather than redundant. The port policy catches what
has no signature; the signatures catch what is on an allowed port. A client configured
to run uTP and DHT over UDP/443 to hide inside QUIC defeats the port policy and walks
straight into the shape and bencode rules, which never look at a port.

`TORRENT_TCP_PORTS` and `TORRENT_UDP_PORTS` are the allowlist `strict` enforces. 500,
4500 and 51820 are absent on purpose, for the reason above.

### What it costs, and what it reports

Every rule is bounded: the string matches only run over the first 32 packets of a
connection, because everything they can match is in the opening exchange and scanning
further would pay for bytes that cannot match. On a userspace tunnel that bound is the
difference between a filter and a bottleneck.

Each rule carries a comment naming its layer, which is where the per-layer counters on
the panel come from — read straight off `iptables-save -c` rather than kept in a file.
The addresses caught are reported too, joined to client names, so the answer to "who is
torrenting" is a person to talk to rather than an IP. Nothing about a client on that
list is blocked for being on it; it is a reporting window, kept for a day.

Turning the guard on drops the conntrack entries for client traffic, so a torrent
running at that moment stops rather than finishing — the handshake it would have been
identified by is already in the past.

The node probes its own kernel for `xt_string`, `ipset`, `connbytes` and `comment`, and
publishes what it found. Without `xt_string` there is no signature layer at all and the
guard degrades to a port filter; the panel says so rather than letting it be discovered
later. Everything the kernel does support is still installed — a rule it refuses is
skipped and counted, never fatal.

`TORRENT_BLOCK=off|on|strict` pins the setting in the environment and takes the switch
away from the panel, the same way `CASCADE_NODES_JSON` does for the node list. Left
empty — the default — the setting comes from `config/torrent-block.json`, which the
panel and `saucewg torrents` write and the node container applies within a second
without disturbing a tunnel.

## Monitoring

The collector polls the device every `COLLECTOR_INTERVAL_SECONDS` and:

- accumulates per-client upload/download from the UAPI counters, handling the reset that
  a node restart causes;
- marks a client online when its last handshake is newer than `ONLINE_TIMEOUT_SECONDS`;
- writes `USAGE_BUCKET_MINUTES`-sized buckets for the charts, pruned after
  `USAGE_RETENTION_DAYS`;
- applies data limits, expiry dates and periodic traffic resets, removing the peer from
  the device as soon as a client stops being active.

## Publishing to Docker Hub

### From GitHub Actions

`.github/workflows/docker-publish.yml` builds all three images for `linux/amd64` and
`linux/arm64` and pushes them on every push to `main`, and on every `v*` tag.

Create these two **secrets** under *Settings → Secrets and variables → Actions → Secrets*:

| Secret | Value |
| --- | --- |
| `DOCKERHUB_USERNAME` | your Docker Hub account name, e.g. `v2as` |
| `DOCKERHUB_TOKEN` | a Docker Hub **access token** with *Read & Write* scope |

Generate the token at [hub.docker.com](https://hub.docker.com) → *Account settings* →
*Personal access tokens* → *Generate new token*. Use a token rather than your account
password: it is scoped, it is revocable on its own, and it works when 2FA is enabled.

Two optional **variables** (same page, *Variables* tab) change where the images land:

| Variable | Default | Effect |
| --- | --- | --- |
| `DOCKERHUB_NAMESPACE` | `DOCKERHUB_USERNAME` | push to an organisation instead of a user |
| `IMAGE_PREFIX` | `saucewg-` | repository name prefix |

With the defaults and a username of `v2as`, a push to `main` publishes:

```
v2as/saucewg-awg:latest    v2as/saucewg-awg:main    v2as/saucewg-awg:sha-1a2b3c4
v2as/saucewg-panel:latest  ...
v2as/saucewg-web:latest    ...
```

Tagging a release adds semver tags, so `git tag v1.0.0 && git push --tags` also publishes
`:1.0.0`, `:1.0` and `:1`. The three Docker Hub repositories are created automatically on
first push; make them public in their settings if you want to pull without logging in.

A second workflow, `.github/workflows/ci.yml`, runs on pull requests. It builds the
frontend, shellchecks the scripts, validates the compose files in the repository and
the ones `saucewg.sh` generates, and exercises the paths that are easy to break without
noticing: the node container's live reload (`scripts/test-uplinks.sh`), the exit node API
(`scripts/test-node-api.py`), the bypass relay's behaviour under a censor that answers one
handshake in twenty (`docker/awg/bypass/main_test.go`, against a faked dialler — a leaked
socket or a wrong answer there is invisible from the outside), and the fact that the node
container, the panel and the installer still agree on what each AmneziaWG generation
contains (`scripts/test-protocol-parity.sh`) — all against stubs rather than real servers.
It needs no secrets.

### From your machine

```bash
export IMAGE_AWG=yourname/saucewg-awg:1.5.0
export IMAGE_PANEL=yourname/saucewg-panel:1.5.0
export IMAGE_WEB=yourname/saucewg-web:1.5.0

make build
make push
```

Set `PLATFORMS=linux/amd64,linux/arm64` to produce the same multi-arch manifests the
workflow does.

## Operating notes

- **Routing.** The entry node uses policy routing rather than a default route, so SSH and
  the panel keep using the normal one. Client traffic is looked up in table `450`
  (destinations that bypass the cascade) and then table `451` (everything else);
  failover is a single `ip route replace default dev awgN table 451`.
- **Fallback.** `CASCADE_FALLBACK` decides what happens while no exit node is usable:
  `direct` (the default) empties table 451 so the entry node carries the traffic itself,
  `block` fills it with an unreachable route so clients are cut off instead. The old
  `CASCADE_KILLSWITCH=true` is still read on an installation that has no
  `CASCADE_FALLBACK`, and means `block`.
- **Reopened destinations.** The bypass is `nat`/`PREROUTING` `REDIRECT` rules plus a
  relay process, both owned by the node container and both installed and withdrawn as
  the cascade's state changes. It touches no route and no table, so it composes with
  everything above: a prefix can be a direct route and a reopened destination at once,
  and neither is aware of the other.
- **Recovery.** Restarting a failed exit node is the panel's job, not the node
  container's, because the credentials for it are the panel's. The two do not
  coordinate: failover moves clients within 30 seconds regardless of whether recovery
  is running, or enabled, or getting anywhere.
- **The torrent guard** lives in `mangle`, not `filter`. Client traffic in
  `filter/FORWARD` is a set of ACCEPT rules that the failover monitor inserts at
  position 1 whenever a path appears, so a rule placed there would be jumped over the
  moment an exit node was added. `mangle/FORWARD` is traversed before `filter` in its
  entirety, which makes the ordering a property of the kernel rather than of who wrote
  a rule last. It is IPv4-only because client traffic is: the entry node installs no
  `ip -6 rule` for `awg0`, so no packet a client sends can reach the IPv6 bridge even
  when the cascade has one. Giving clients IPv6 means giving the guard an `ip6tables`
  half in the same change.
- **Performance.** Both hops run the userspace `amneziawg-go`, which is CPU-bound. On a
  2-core VPS expect tens of Mbit/s per node. Installing the AmneziaWG kernel module on the
  host and pointing `WG_QUICK_USERSPACE_IMPLEMENTATION` at it is the usual next step if you
  outgrow that.
- **Ports.** The entry node defaults to UDP/443, which blends in with QUIC and survives
  networks that only allow well-known ports. The exit node uses UDP/51820 since only the
  entry node dials it.
- **IPv6.** Off until asked for, and two independent switches when asked: an exit node
  can be *dialled* over IPv6 without the cascade carrying IPv6, and the cascade can
  carry IPv6 over uplinks dialled on IPv4. Neither reaches clients, who stay IPv4.
  See [IPv6](#ipv6).

## Layout

```
saucewg.sh        installer and service CLI; also the /usr/local/bin/saucewg command
backend/          FastAPI service (app/awg = UAPI client, app/services = workers)
frontend/         Vue 3 + Vite single-page UI
docker/awg/       AmneziaWG node image: entrypoint, generations, uplinks + failover monitor
docker/awg/torrents.sh  the layered BitTorrent filter, and what it publishes about itself
docker/awg/bypass/  awg-bypass, the transparent relay for reopened destinations (Go)
docker/caddy/     frontend build + Caddy reverse proxy image
scripts/          bootstrap helpers, the exit node list manager, CI test harnesses
config/           the four lists the panel and the node share, bind-mounted into the node
.github/workflows/  CI checks and the Docker Hub publish pipeline
AWG_USAGE.md      integration reference for managing users from a central API
SAUCEWG_USAGE.md  installing and managing servers, from a shell or a bot
docker-compose.yml       entry node: awg + panel + caddy + postgres
docker-compose.exit.yml  exit node: awg only
```
