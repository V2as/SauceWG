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

Chosen destinations can be sent past the cascade on purpose: a range listed in
`config/direct-routes.json` leaves through the entry node's own address while everything
else still goes abroad, which is how a service that has to see a local IP keeps working.

Where the problem is the destination rather than the route — an address whose TCP
handshake is dropped on the way out, no matter which interface it leaves by — the entry
node can reopen it for itself: over the destination's IPv6, which the same filters
usually do not touch, or by retrying its IPv4 until one handshake survives. Telegram's
datacentres ship as a built-in group, because that is what this exists for today.

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

Optionally add a pre-shared key to an uplink for post-quantum resistance: generate one
with `docker run --rm --entrypoint awg saucewg/awg:1.3.0 genpsk` and pass it as
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
| `PUT/DELETE` | `/api/nodes/{name}` | change priority, endpoint or note / remove it |
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

**Lower `priority` wins.** Every 10 seconds each uplink is checked: a handshake older
than `CASCADE_HANDSHAKE_TIMEOUT` fails it outright, otherwise an ICMP probe is sent
through the tunnel to `CASCADE_PROBE_TARGET` — which is what catches an exit node that
is still up but has lost its own internet. Three consecutive failures take it out of
rotation and traffic moves to the next healthy node; two successes bring it back.

Switching rewrites one route and flushes stale NAT conntrack entries. Clients keep their
tunnel to the entry node the whole time — they see a new exit IP, not a disconnect.

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
  `.4` … on the entry node) satisfy this.

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
export IMAGE_AWG=yourname/saucewg-awg:1.3.0
export IMAGE_PANEL=yourname/saucewg-panel:1.3.0
export IMAGE_WEB=yourname/saucewg-web:1.3.0

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
- **Performance.** Both hops run the userspace `amneziawg-go`, which is CPU-bound. On a
  2-core VPS expect tens of Mbit/s per node. Installing the AmneziaWG kernel module on the
  host and pointing `WG_QUICK_USERSPACE_IMPLEMENTATION` at it is the usual next step if you
  outgrow that.
- **Ports.** The entry node defaults to UDP/443, which blends in with QUIC and survives
  networks that only allow well-known ports. The exit node uses UDP/51820 since only the
  entry node dials it.

## Layout

```
saucewg.sh        installer and service CLI; also the /usr/local/bin/saucewg command
backend/          FastAPI service (app/awg = UAPI client, app/services = workers)
frontend/         Vue 3 + Vite single-page UI
docker/awg/       AmneziaWG node image: entrypoint, generations, uplinks + failover monitor
docker/awg/bypass/  awg-bypass, the transparent relay for reopened destinations (Go)
docker/caddy/     frontend build + Caddy reverse proxy image
scripts/          bootstrap helpers, the exit node list manager, CI test harnesses
config/           exit-nodes.json, direct-routes.json and bypass.json, bind-mounted into the node
.github/workflows/  CI checks and the Docker Hub publish pipeline
AWG_USAGE.md      integration reference for managing users from a central API
SAUCEWG_USAGE.md  installing and managing servers, from a shell or a bot
docker-compose.yml       entry node: awg + panel + caddy + postgres
docker-compose.exit.yml  exit node: awg only
```
